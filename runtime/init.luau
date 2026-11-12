--!native
--!optimize 2

--[[
	Cascade Animation Runtime
	Copyright (c) 2025 BerDeryaDev1010. All rights reserved.

	Source-available under the Cascade Runtime License.
	  - Free to use in your Roblox games.
	  - Free to include in UI kits, templates, and commissioned work.
	  - May not be resold or used to build a competing animation runtime.
	  - Keep this header intact when redistributing.

	Full license: https://github.com/BerDerDevStuff/Cascade-UI-Animator/blob/main/runtime/LICENSE.md
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local AnimTrack = require(script.AnimTrack)
local BatchedAnimTrack = require(script.BatchedAnimTrack)
local Types = require(script.Types)
local Merger = require(script.Merger)
local Signal = require(script.Signal)

local AnimationService = {}
AnimationService.Version = script:GetAttribute("Version") or "unknown"

-- Every registered track, for the API lookups and the dormant sweep.
local _activeTracks = {}
-- The tracks the frame loop steps: playing, or with a pending scrub, start or retirement. Finished,
-- paused and suspended tracks sleep outside it and cost nothing per frame (O1). A track method that
-- needs a frame calls the track's _Waker.
local _liveTracks = {}
-- Lookups without a scan (O6, PER4): [instance][processed] = {tracks}, [processed] = {batches} and
-- [instance] = {batches}, so Play, Stop and ClearInstance never walk every track.
local _tracksByInstance = {}
local _batchesByData = {}
local _batchesByInstance = {}
local _processedConfigs = setmetatable({}, { __mode = "k" })
-- Per animated target: { Slots = {[prop] = slot}, AliveGen, Alive }. Per (target, property) slot:
--   Original     value before the engine animated it (restored by Reset)
--   Base         value under the relative deltas (set by absolute ops, refreshed at Play())
--   LastWritten  what the property held after the engine's last write, to tell game edits from it
--   Held         [track] = the track's relative channels here; each channel's Held field is the
--                delta last written, so dormant tracks keep their deltas
--   Tracks       the tracks bound to the slot (weak keys); they rebind when the slot is dropped
-- plus the frame's accumulators, reset lazily by the frame generation: a frame allocates nothing (O2).
local _targets = setmetatable({}, { __mode = "k" })
local WEAK_KEYS = { __mode = "k" }
local _frameGen = 0
local _runSeq = 0
local _dirty = {} -- slots touched this frame, resolved in order
local _dirtyN = 0
local _resolveIndex = 0
local _resolving = nil
local _resolvingTarget = nil
local _stepIndex = 1
local _stepping = nil
local _warned = {}
local _easingSupported = {}
local _animationsFolder: Instance? = nil
local _animationsByName = {}
local _sequencesFolder: Instance? = nil
local _sequencesByName = {}

local _renderConnection: RBXScriptConnection? = nil

local _renderStep

local function _ensureLoopRunning()
	if not _renderConnection then
		_renderConnection = RunService.PreRender:Connect(_renderStep)
	end
end

local function _warnOnce(key: string, message: string)
	if _warned[key] then return end
	_warned[key] = true
	warn("[Cascade] " .. message)
end

local function _readProp(target: Instance, prop: string): any
	return (target :: any)[prop]
end

-- Writes `value` and returns what the property then holds: integer and clamped properties store
-- something else than what was written (COR3).
local function _writeBack(target: Instance, prop: string, value: any): any
	(target :: any)[prop] = value
	return (target :: any)[prop]
end

local function _getSlot(target: Instance, prop: string)
	local rec = _targets[target]
	if not rec then
		rec = { Slots = {}, AliveGen = 0, Alive = false }
		_targets[target] = rec
	end
	local slot = rec.Slots[prop]
	if not slot then
		local ok, value = pcall(_readProp, target, prop)
		-- The target is not stored: from a value of the weak-keyed table it would keep its key alive.
		-- Each frame passes it along with the slot instead.
		slot = {
			Original = value, Base = value, LastWritten = nil, Held = {}, Broken = not ok, WriteFailed = false,
			Rec = rec, Prop = prop, RunSeq = 0, Tracks = setmetatable({}, WEAK_KEYS),
			Gen = 0, Abs = nil, AbsStamp = 0, Running = false, SubN = 0, RelN = 0,
		}
		rec.Slots[prop] = slot
		if not ok then
			_warnOnce(target.ClassName .. "." .. prop, string.format("%s cannot be animated on %s, skipped: %s", prop, target.ClassName, tostring(value)))
		end
	end
	return slot
end

local function _findSlot(target: Instance, prop: string)
	local rec = _targets[target]
	return rec and rec.Slots[prop]
end

-- Forgets the slots of cleared targets, so their next animation captures fresh values (`roots`: the
-- cleared instances). A slot that still holds the delta of a track animating it from another root
-- (a parent's track on a cleared child) is kept, or that delta would be added twice (PER10). Only
-- the tracks bound to a dropped slot rebind (PER5).
local function _dropTargets(cleared: {[Instance]: boolean}, roots: {[Instance]: boolean})
	for target in cleared do
		local rec = _targets[target]
		if not rec then continue end
		local slots = rec.Slots
		for prop, slot in slots do
			local held = slot.Held
			for holder, channels in held do
				if holder.IsDestroyed or roots[channels[1].Root] then
					held[holder] = nil
				end
			end
			if next(held) == nil then
				slots[prop] = nil
				slot.Broken, slot.WriteFailed = true, false -- never collected again
				for track in slot.Tracks do
					track._BoundBuild = nil
				end
			end
		end
		if next(slots) == nil then
			_targets[target] = nil
		end
	end
end

-- True when `live` still holds what the engine wrote. Blended writes record the value read back;
-- the single-value fast path records what it wrote, so the comparison allows for integer offsets
-- and single-precision storage.
local function _isWritten(live: any, written: any): boolean
	if live == written then return true end
	local t = typeof(written)
	if typeof(live) ~= t then return false end
	if t == "number" then
		return math.abs(live - written) <= 1e-4
	elseif t == "UDim2" then
		local lx, ly, wx, wy = live.X, live.Y, written.X, written.Y
		return math.abs(lx.Scale - wx.Scale) <= 1e-4 and math.abs(ly.Scale - wy.Scale) <= 1e-4
			and math.abs(lx.Offset - wx.Offset) < 1 and math.abs(ly.Offset - wy.Offset) < 1
	elseif t == "UDim" then
		return math.abs(live.Scale - written.Scale) <= 1e-4 and math.abs(live.Offset - written.Offset) < 1
	elseif t == "Vector2" or t == "Vector3" then
		return (live - written).Magnitude <= 1e-3
	elseif t == "Color3" then
		return math.abs(live.R - written.R) <= 1e-3 and math.abs(live.G - written.G) <= 1e-3 and math.abs(live.B - written.B) <= 1e-3
	end
	return false
end

local function _negate(value: any): any
	local t = typeof(value)
	if t == "number" then return -value
	elseif t == "UDim2" then return UDim2.new(-value.X.Scale, -value.X.Offset, -value.Y.Scale, -value.Y.Offset)
	elseif t == "Vector2" or t == "Vector3" then return -value
	elseif t == "UDim" then return UDim.new(-value.Scale, -value.Offset)
	elseif t == "Color3" then return Color3.new(-value.R, -value.G, -value.B)
	end
	return value
end

-- Adds (sign 1) or removes (sign -1) the deltas one track last wrote (its relative channels'
-- Held values): full-property deltas when wantSub is false, sub-path deltas when it is true.
local function _addPass(value: any, ops: {any}, wantSub: boolean, sign: number): any
	if value == nil then return nil end
	for _, ch in ipairs(ops) do
		local delta = ch.Held
		if delta ~= nil and ch.HasSub == wantSub then
			if sign < 0 then delta = _negate(delta) end
			if wantSub then
				value = Merger.merge(value, ch.SubPath, Merger.add(Merger.extractSub(value, ch.SubPath), delta))
			else
				value = Merger.add(value, delta)
			end
		end
	end
	return value
end

local function _addOps(value: any, ops: {any}, sign: number): any
	return _addPass(_addPass(value, ops, false, sign), ops, true, sign)
end

local function _isRunning(track): boolean
	return not track.IsDestroyed and (track.State == "Playing" or track.State == "Paused")
end

-- The game changed the value: it becomes the new base under the deltas of running tracks, and the
-- deltas of dormant tracks are dropped (the game's value replaces them). Returns whether a running
-- track still contributes.
local function _rebase(slot, live: any): boolean
	local base = live
	local running = false
	for holder, ops in slot.Held do
		if _isRunning(holder) then
			base = _addOps(base, ops, -1)
			running = true
		else
			slot.Held[holder] = nil
		end
	end
	slot.Base = base
	return running
end

-- Removes a track's held deltas. bake = true keeps what it left on screen in the base, so a
-- finished animation stays where it ended.
local function _releaseTrack(track, bake: boolean)
	local heldSlots = track._HeldSlots
	if not heldSlots then return end
	track._HeldSlots = nil
	for slot in heldSlots do
		local ops = slot.Held[track]
		if ops then
			if bake then
				slot.Base = _addOps(slot.Base, ops, 1)
			end
			slot.Held[track] = nil
		end
	end
end

-- Reset: writes back the values the properties had before the track's run (root nil = all), or the
-- slot's Original for a track that never started a run (Scrub / SetTime only) (COR5).
local function _restore(track, root: Instance?)
	local entries = track.ActiveTracks
	if not entries then return end
	local snapshot = track._ResetValues
	local done = {}
	for _, entry in entries do
		if root == nil or entry.Root == root then
			local slot = _findSlot(entry.Target, entry.BaseProp)
			if slot and not slot.Broken and not done[slot] then
				done[slot] = true
				slot.Held[track] = nil
				local value = snapshot and snapshot[slot]
				if value == nil then value = slot.Original end
				local ok, stored = pcall(_writeBack, entry.Target, entry.BaseProp, value)
				if ok then
					-- Like a game edit: the restored value is the base under any running deltas.
					_rebase(slot, stored)
					slot.LastWritten = stored
				end
			end
		end
	end
	if root == nil then
		track._ResetValues = nil
	end
end

-- Moves a track onto the live list (no-op when it is live or not registered).
local function _wake(track)
	if track._LiveIndex == nil and track._ActiveIndex ~= nil then
		local n = #_liveTracks + 1
		_liveTracks[n] = track
		track._LiveIndex = n
	end
end

local function _sleep(track)
	local i = track._LiveIndex
	if i == nil then return end
	local last = #_liveTracks
	local moved = _liveTracks[last]
	_liveTracks[i] = moved
	moved._LiveIndex = i
	_liveTracks[last] = nil
	track._LiveIndex = nil
end

-- Watches a root for removal. Liveness is checked once after registration and again only when a
-- root loses its parent, instead of every frame for live tracks and by a sweep for sleeping ones
-- (PER3, PER6).
local function _watch(track, inst: Instance)
	local conns = track._Watch
	if not conns then
		conns = {}
		track._Watch = conns
	end
	table.insert(conns, inst.AncestryChanged:Connect(function()
		if inst.Parent == nil then
			track._CheckValid = true
			_wake(track)
		end
	end))
end

local function _unwatch(track)
	local conns = track._Watch
	if conns then
		track._Watch = nil
		for _, conn in conns do
			conn:Disconnect()
		end
	end
end

local function _register(track)
	local n = #_activeTracks + 1
	_activeTracks[n] = track
	track._ActiveIndex = n
	track._Waker = _wake
	track._CheckValid = true

	if getmetatable(track) == BatchedAnimTrack then
		local instances = track.Instances
		if instances then
			track._Indexed = table.clone(instances)
			for _, inst in instances do
				local list = _batchesByInstance[inst]
				if list then table.insert(list, track) else _batchesByInstance[inst] = { track } end
				_watch(track, inst)
			end
		end
	elseif track.Instance ~= nil then
		_watch(track, track.Instance)
	end

	local data = track.Data
	if data then
		if getmetatable(track) == BatchedAnimTrack then
			local list = _batchesByData[data]
			if list then table.insert(list, track) else _batchesByData[data] = { track } end
		elseif track.Instance ~= nil then
			local key = track.Instance
			track._IndexKey = key
			local byData = _tracksByInstance[key]
			if not byData then
				byData = {}
				_tracksByInstance[key] = byData
			end
			local list = byData[data]
			if list then table.insert(list, track) else byData[data] = { track } end
		end
	end
	_wake(track)
end

local function _unregister(track)
	local i = track._ActiveIndex
	if i ~= nil then
		local last = #_activeTracks
		local moved = _activeTracks[last]
		_activeTracks[i] = moved
		moved._ActiveIndex = i
		_activeTracks[last] = nil
		track._ActiveIndex = nil
	end
	_sleep(track)

	local data = track.Data
	if data then
		local index
		if getmetatable(track) == BatchedAnimTrack then
			index = _batchesByData
		elseif track._IndexKey ~= nil then
			index = _tracksByInstance[track._IndexKey]
		end
		local list = index and index[data]
		if list then
			local pos = table.find(list, track)
			if pos then table.remove(list, pos) end
			if #list == 0 then
				index[data] = nil
				if index ~= _batchesByData and next(index) == nil then
					_tracksByInstance[track._IndexKey] = nil
				end
			end
		end
	end

	local indexed = track._Indexed
	if indexed then
		track._Indexed = nil
		for _, inst in indexed do
			local list = _batchesByInstance[inst]
			local pos = list and table.find(list, track)
			if pos then
				table.remove(list, pos)
				if #list == 0 then _batchesByInstance[inst] = nil end
			end
		end
	end
	_unwatch(track)
end

local function _retire(track)
	track._Retired = true
	local reset = track.Options and track.Options.Reset
	if reset then
		_restore(track, nil)
	end
	_releaseTrack(track, track.IsFinished and not reset)
	if not track.IsDestroyed then track:Destroy() end
	_unregister(track)
end

-- Semantics 3: a relative animation applies its deltas to the property value at Play() time.
-- While the engine still owns the live value the shared base is already right, so concurrent
-- relative tracks never stack (D3). Runs once per new run, before the track's next frame.
local function _startRun(track)
	local entries = track.ActiveTracks
	if not entries then return end
	_runSeq += 1
	local seq = _runSeq
	-- Reset restores the values from before the run; a takeover keeps those of the run it replaced.
	local snapshot = nil
	if track.Options and track.Options.Reset then
		snapshot = track._ResetValues
		if not snapshot then
			snapshot = {}
			track._ResetValues = snapshot
		elseif not track._Takeover then
			table.clear(snapshot)
		end
	end
	for _, entry in entries do
		local target, prop = entry.Target, entry.BaseProp
		local slot = _getSlot(target, prop)
		if slot.RunSeq == seq then continue end
		slot.RunSeq = seq
		if slot.Broken then
			-- A failed write belongs to the values that caused it, not to the property (INT4).
			if not slot.WriteFailed then continue end
			slot.Broken, slot.WriteFailed = false, false
		end

		local held = slot.Held[track]
		if held and track._Rewound then
			-- A restart keeps what the previous run left on screen.
			slot.Base = _addOps(slot.Base, held, 1)
			slot.Held[track] = nil
		end

		local ok, live = pcall(_readProp, target, prop)
		if ok then
			if snapshot and snapshot[slot] == nil then
				snapshot[slot] = live
			end
			if slot.LastWritten == nil or not _isWritten(live, slot.LastWritten) then
				if not _rebase(slot, live) then
					slot.Original = live
				end
			end
		end
	end
	track._Rewound = false
end

-- Points every channel at its slot and groups the relative channels per slot (a track's held
-- contribution; HasFull / HasSub say which delta passes it needs). Runs again when the track
-- rebuilds its channels or slots were dropped.
local function _bindTrack(track)
	local lists = {}
	for _, ch in track.ActiveTracks do
		local slot = _getSlot(ch.Target, ch.BaseProp)
		ch.Slot = slot
		slot.Tracks[track] = true
		if slot.WriteFailed then
			slot.Broken, slot.WriteFailed = false, false
		end
		if ch.IsRelative then
			local list = lists[slot]
			if not list then
				list = { HasFull = false, HasSub = false }
				lists[slot] = list
			end
			table.insert(list, ch)
			if ch.HasSub then list.HasSub = true else list.HasFull = true end
		end
	end
	track._Lists = lists
	track._BoundBuild = track._BuildId
end

-- Accumulates one track's evaluated channels into their slots. Absolute: the newest run wins per
-- property and sub-path values merge in run order. Relative: the track's channels become its held
-- contribution when the slot resolves.
local function _collectTrack(track)
	if track._BoundBuild ~= track._BuildId then
		_bindTrack(track)
	end
	local gen = _frameGen
	local stamp = track.RunStamp
	local running = track.State ~= "Suspended"
	for _, ch in track.ActiveTracks do
		local slot = ch.Slot
		if slot.Gen ~= gen then
			-- A broken slot never takes this frame's generation, so it is skipped here every time.
			if slot.Broken then continue end
			slot.Gen = gen
			slot.Target = ch.Target
			slot.Abs = nil
			slot.AbsStamp = -math.huge
			slot.Running = false
			slot.SubN = 0
			slot.RelN = 0
			local n = _dirtyN + 1
			_dirtyN = n
			_dirty[n] = slot
		end

		if ch.IsRelative then
			local n = slot.RelN
			local rel = slot.RelTracks
			if not rel then
				rel = {}
				slot.RelTracks = rel
			end
			if n == 0 or rel[n] ~= track then
				n += 1
				rel[n] = track
				slot.RelN = n
			end
			if running then
				slot.Running = true
			end
		else
			local value = ch.Value
			if value ~= nil then
				if not ch.HasSub then
					if stamp >= slot.AbsStamp then
						slot.Abs = value
						slot.AbsStamp = stamp
					end
				else
					local vals, paths, stamps = slot.SubVals, slot.SubPaths, slot.SubStamps
					if not vals then
						vals, paths, stamps = {}, {}, {}
						slot.SubVals, slot.SubPaths, slot.SubStamps = vals, paths, stamps
					end
					local i = slot.SubN
					slot.SubN = i + 1
					while i > 0 and stamps[i] > stamp do
						vals[i + 1], paths[i + 1], stamps[i + 1] = vals[i], paths[i], stamps[i]
						i -= 1
					end
					vals[i + 1], paths[i + 1], stamps[i + 1] = value, ch.SubPath, stamp
				end
			end
		end
	end
end

-- Resolves and writes one property: absolute base, then every held full-property delta, then every
-- held sub-path delta.
local function _resolveSlot(slot, target: Instance)
	local prop = slot.Prop
	local value = slot.Abs
	local subN = slot.SubN
	if value == nil and (subN > 0 or slot.Running) then
		-- Sub-path absolute and playing relative ops build on the live value, so a game edit made
		-- meanwhile survives (USP1). The engine's own last write is recognised, so deltas never
		-- compound (R2). Scrubbed (suspended) tracks keep their base, as the editor preview needs.
		local live = (target :: any)[prop]
		local written = slot.LastWritten
		if written == nil or not _isWritten(live, written) then
			_rebase(slot, live)
		end
		value = slot.Base
	end

	-- Holds are replaced only now: until here they describe what the last write contained.
	local relN = slot.RelN
	if relN > 0 then
		local held, rel = slot.Held, slot.RelTracks
		for i = 1, relN do
			local track = rel[i]
			rel[i] = nil
			if not track._Retired then
				local channels = track._Lists[slot]
				for _, ch in ipairs(channels) do
					ch.Held = ch.Value
				end
				channels.Gen = _frameGen
				held[track] = channels
				local heldSlots = track._HeldSlots
				if not heldSlots then
					heldSlots = {}
					track._HeldSlots = heldSlots
				end
				heldSlots[slot] = true
			end
		end
	end

	if subN > 0 then
		local minStamp = slot.AbsStamp
		local vals, paths, stamps = slot.SubVals, slot.SubPaths, slot.SubStamps
		for i = 1, subN do
			if stamps[i] >= minStamp then
				value = Merger.merge(value, paths[i], vals[i])
			end
		end
	end

	if value ~= nil then
		slot.Base = value
	else
		value = slot.Base
	end
	local held = slot.Held
	if next(held) ~= nil and slot.Abs ~= nil then
		-- An absolute value from a newer run replaces the deltas of finished relative animations
		-- (COR6); one that finished while that absolute animation ran keeps its delta.
		local gen, stamp = _frameGen, slot.AbsStamp
		for holder, channels in held do
			if channels.Gen ~= gen and holder.RunStamp < stamp and not _isRunning(holder) then
				held[holder] = nil
			end
		end
	end
	if next(held) ~= nil then
		local anySub = false
		for _, channels in held do
			if channels.HasFull then value = _addPass(value, channels, false, 1) end
			if channels.HasSub then anySub = true end
		end
		if anySub then
			for _, channels in held do
				if channels.HasSub then value = _addPass(value, channels, true, 1) end
			end
		end
	end
	if value == nil then return end

	(target :: any)[prop] = value
	-- Integer properties (ZIndex, TextSize) and clamped ones (CanvasPosition) hold something else
	-- than what was written, and the next blended frame builds on it: remember what the property
	-- holds (COR3). UDim2 / Color3 values already hold what the property stores, so they skip the
	-- read and its allocation.
	if type(value) == "number" or typeof(value) == "Vector2" then
		slot.LastWritten = (target :: any)[prop]
	else
		slot.LastWritten = value
	end
end

-- Resolves the dirty slots from _resolveIndex on. Runs under one pcall per frame; after an error
-- the caller marks _resolving broken and calls again for the rest.
local function _resolveDirty()
	local dirty, gen, n = _dirty, _frameGen, _dirtyN
	local i = _resolveIndex
	while i < n do
		i += 1
		_resolveIndex = i
		local slot = dirty[i]
		dirty[i] = nil
		local target = slot.Target
		slot.Target = nil
		_resolving, _resolvingTarget = slot, target
		local rec = slot.Rec
		if rec.AliveGen ~= gen then
			rec.AliveGen = gen
			rec.Alive = target.Parent ~= nil
		end
		if rec.Alive then
			local value = slot.Abs
			if value ~= nil and slot.SubN == 0 and slot.RelN == 0 and next(slot.Held) == nil then
				-- The common case, one absolute value and nothing to blend: _resolveSlot inlined.
				slot.Base = value;
				(target :: any)[slot.Prop] = value
				slot.LastWritten = value
			else
				_resolveSlot(slot, target)
			end
		end
	end
	_resolving, _resolvingTarget = nil, nil
end

local function _isEasingSupported(style: any, direction: any): boolean
	local key = tostring(style) .. "|" .. tostring(direction)
	local supported = _easingSupported[key]
	if supported == nil then
		supported = pcall(TweenService.GetValue, TweenService, 0.5, style, direction)
		_easingSupported[key] = supported
	end
	return supported
end

-- Keyframes whose easing TweenService:GetValue rejects (Bezier, Spring, unknown names) fall back
-- to Linear once here, instead of throwing every frame (B8).
local function _sanitizeEasing(keyframes: {any}, rawPath: string): {any}
	local out = keyframes
	for i, kf in ipairs(keyframes) do
		local easing = kf.Easing
		if easing ~= nil and easing ~= "Step" and not _isEasingSupported(easing, kf.Direction or Enum.EasingDirection.Out) then
			if out == keyframes then out = table.clone(keyframes) end
			out[i] = { Time = kf.Time, Value = kf.Value, Easing = Enum.EasingStyle.Linear, Direction = Enum.EasingDirection.Out }
			_warnOnce("easing:" .. tostring(easing), string.format("Easing %s is not supported at runtime; '%s' uses Linear instead", tostring(easing), rawPath))
		end
	end
	return out
end

function AnimationService.SetAnimationsFolder(folder: Instance?)
	_animationsFolder = folder
	table.clear(_animationsByName)
end

function AnimationService.GetAnimationsFolder(): Instance
	if _animationsFolder then return _animationsFolder end
	local rs = game:GetService("ReplicatedStorage")
	local folder = rs:FindFirstChild("CascadeAnimations")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "CascadeAnimations"
		folder.Parent = rs
	end
	return folder
end

function AnimationService.InvalidateAnimationCache(name: string?)
	if name then
		_animationsByName[name] = nil
	else
		table.clear(_animationsByName)
	end
end

function AnimationService.SetSequencesFolder(folder: Instance?)
	_sequencesFolder = folder
	table.clear(_sequencesByName)
end

function AnimationService.GetSequencesFolder(): Instance
	if _sequencesFolder then return _sequencesFolder end
	local Players = game:GetService("Players")
	local localPlayer = Players.LocalPlayer
	if localPlayer then
		local playerGui = localPlayer:FindFirstChild("PlayerGui")
		if playerGui then
			local folder = playerGui:FindFirstChild("CascadeSequences")
			if folder then return folder end
		end
	end

	local starterGui = game:GetService("StarterGui")
	local folder = starterGui:FindFirstChild("CascadeSequences")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "CascadeSequences"
		folder.Parent = starterGui
	end
	return folder
end

function AnimationService.InvalidateSequenceCache(name: string?)
	if name then
		_sequencesByName[name] = nil
	else
		table.clear(_sequencesByName)
	end
end

function AnimationService.PlaySequence(name: string): boolean
	local cached = _sequencesByName[name]
	if cached then
		local ok, err = pcall(cached.Play)
		if not ok then
			warn("[Cascade] Sequence '" .. name .. "' errored: " .. tostring(err))
			return false
		end
		return true
	end

	local folder = AnimationService.GetSequencesFolder()
	local parts = string.split(name, "/")
	local current: Instance = folder
	for _, part in ipairs(parts) do
		local child = current:FindFirstChild(part)
		if not child then
			warn("[Cascade] Sequence not found: " .. name)
			return false
		end
		current = child
	end
	if not current:IsA("ModuleScript") then
		warn("[Cascade] Sequence not found: " .. name)
		return false
	end

	local ok, moduleResult = pcall(require, current)
	if not ok or type(moduleResult) ~= "table" or type(moduleResult.Play) ~= "function" then
		warn("[Cascade] Failed to load sequence '" .. name .. "': module must return a table with a Play() function")
		return false
	end

	_sequencesByName[name] = moduleResult

	local playOk, playErr = pcall(moduleResult.Play)
	if not playOk then
		warn("[Cascade] Sequence '" .. name .. "' errored: " .. tostring(playErr))
		return false
	end
	return true
end

local function _findModule(name: string): ModuleScript?
	local folder = AnimationService.GetAnimationsFolder()
	local parts = string.split(name, "/")
	local current: Instance = folder
	for _, part in ipairs(parts) do
		local child = current:FindFirstChild(part)
		if not child then return nil end
		current = child
	end
	return current:IsA("ModuleScript") and current or nil
end

local function _resolveConfig(configOrName)
	if type(configOrName) == "string" then
		local cached = _animationsByName[configOrName]
		if cached then return cached end

		local module = _findModule(configOrName)
		if not module then
			warn("[Cascade] Animation not found: " .. configOrName)
			return nil
		end
		local ok, config = pcall(require, module)
		if not ok or type(config) ~= "table" then
			warn("[Cascade] Failed to load animation: " .. configOrName)
			return nil
		end
		local processed = AnimationService.Preprocess(config)
		_animationsByName[configOrName] = processed
		return processed
	end
	return AnimationService.Preprocess(configOrName :: any)
end

function AnimationService.Preprocess(configOrProcessed: Types.AnimationConfig | Types.ProcessedAnimation): Types.ProcessedAnimation
	if (configOrProcessed :: any).IsProcessed then
		return configOrProcessed :: Types.ProcessedAnimation
	end

	local config = configOrProcessed :: Types.AnimationConfig

	if _processedConfigs[config] then return _processedConfigs[config] end

	local groups = {}
	local settings = config.Settings or {}
	local lastKeyTime = 0

	for rawPath, keyframes in pairs(config.Tracks) do
		local instancePath, baseProp, subPath = Merger.parseFullPath(rawPath)
		local instanceKey = table.concat(instancePath, "/")
		local groupKey = instanceKey .. "|" .. baseProp

		if not groups[groupKey] then groups[groupKey] = {} end
		table.sort(keyframes, function(a, b) return a.Time < b.Time end)
		local last = keyframes[#keyframes]
		if last and last.Time > lastKeyTime then lastKeyTime = last.Time end

		local isRelative = settings[rawPath] and settings[rawPath].IsRelative or false
		table.insert(groups[groupKey], {
			SubPath = subPath, Keyframes = _sanitizeEasing(keyframes, rawPath), IsRelative = isRelative,
			RawPath = rawPath, InstancePath = instancePath
		})
	end

	local events = config.Events or {}
	if #events > 1 then
		events = table.clone(events)
		table.sort(events, function(a, b) return a.Time < b.Time end)
	end

	-- A missing Length falls back to the last keyframe; Length <= 0 plays one frame and never loops.
	local length = tonumber(config.Length) or lastKeyTime
	if length ~= length or length < 0 then length = 0 end

	local data = {
		IsProcessed = true, Length = length, Loop = config.Loop or false,
		Delay = config.Delay or 0, PropertyGroups = groups,
		Events = events
	}
	_processedConfigs[config] = data
	return data
end

-- Validate ----------------------------------------------------------------------------------------
-- Checks an animation config against what Preprocess, the Evaluator and Merger read, and returns
-- readable errors. Nothing calls it at play time: call it yourself (tests, authoring tools).

-- Value types the runtime interpolates, and the ones it holds until the next keyframe.
local LERP_TYPES = { number = true, UDim2 = true, UDim = true, Vector2 = true, Vector3 = true, Color3 = true }
local HOLD_TYPES = {
	boolean = true, string = true, EnumItem = true, Rect = true,
	NumberSequence = true, ColorSequence = true, NumberRange = true,
}
local NUMBER_ONLY = { number = true }
local NUMBER_OR_UDIM = { number = true, UDim = true }
local TIME_EPSILON = 1e-6

-- The value types a sub-path's keyframes take (Merger.merge / extractSub), or nil when the runtime
-- cannot animate that sub-path.
local function _subPathKinds(subPath: {string}): {[string]: boolean}?
	local a, b = subPath[1], subPath[2]
	if #subPath == 1 then
		if a == "R" or a == "G" or a == "B" or a == "Z" or a == "Scale" or a == "Offset" then
			return NUMBER_ONLY
		elseif a == "X" or a == "Y" then
			return NUMBER_OR_UDIM -- a Vector2 / Vector3 component, or a UDim2 axis
		end
	elseif #subPath == 2 and (a == "X" or a == "Y") and (b == "Scale" or b == "Offset") then
		return NUMBER_ONLY
	end
	return nil
end

local function _isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function _fmtNumber(n: number): string
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%.1f", n)
	end
	return string.format("%.6g", n)
end

local function _sortedKeys(t: {[any]: any}): {any}
	local keys = {}
	for key in t do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

-- Returns an error for a track path the runtime cannot parse or animate, else nil and the sub-path.
local function _checkPath(path: string): (string?, {string}?)
	if path == "" then
		return "the path is empty", nil
	end
	local segments = string.split(path, "/")
	for _, segment in segments do
		if segment == "" then
			return "the path has an empty part (check for '//' or a leading or trailing '/')", nil
		end
	end
	local propParts = string.split(segments[#segments], ".")
	local baseProp = propParts[1]
	if not string.match(baseProp, "^[%a_][%w_]*$") then
		return string.format("'%s' is not a property name", baseProp), nil
	end
	local subPath = {}
	for i = 2, #propParts do
		if propParts[i] == "" then
			return "the property has an empty part (check for '..' or a trailing '.')", nil
		end
		table.insert(subPath, propParts[i])
	end
	if #subPath > 0 and not _subPathKinds(subPath) then
		return string.format("'.%s' is not a sub-path the runtime can animate (X, Y, Z, R, G, B, Scale, Offset, or X.Scale-style on a UDim2)", table.concat(subPath, ".")), nil
	end
	return nil, subPath
end

-- AnimationService.Validate(config) -> (ok, errors)
-- `config` is an animation table or a name under the animations folder (as Play takes it). `ok` is
-- true when `errors` is empty. The config is never changed.
function AnimationService.Validate(config: Types.AnimationConfig | string): (boolean, {string})
	local errors = {}
	local function fail(message: string, ...)
		table.insert(errors, string.format(message, ...))
	end

	if type(config) == "string" then
		local name = config
		local module = _findModule(name)
		if not module then
			return false, { string.format("Animation '%s' was not found", name) }
		end
		local ok, result = pcall(require, module)
		if not ok or type(result) ~= "table" then
			return false, { string.format("Animation '%s' could not be loaded: %s", name, if ok then "the module does not return a table" else tostring(result)) }
		end
		config = result
	end
	if type(config) ~= "table" then
		return false, { "The config must be a table, got " .. typeof(config) }
	end
	local cfg = config :: any
	if cfg.IsProcessed then
		return false, { "The config is already processed; validate the animation table itself" }
	end

	local length = cfg.Length
	if length ~= nil and not (_isFiniteNumber(length) and length >= 0) then
		fail("Length %s must be a number of seconds, 0 or more", tostring(length))
		length = nil
	end
	if cfg.Loop ~= nil and type(cfg.Loop) ~= "boolean" and not _isFiniteNumber(cfg.Loop) then
		fail("Loop %s must be true, false or a number of loops", tostring(cfg.Loop))
	end
	if cfg.Delay ~= nil and not (_isFiniteNumber(cfg.Delay) and cfg.Delay >= 0) then
		fail("Delay %s must be a number of seconds, 0 or more", tostring(cfg.Delay))
	end

	local tracks = cfg.Tracks
	if type(tracks) ~= "table" then
		fail("Tracks is missing or not a table")
		tracks = {}
	end
	local trackKinds = {} -- [path] = the value type of the track's first keyframe
	local lastKeyTime = 0
	for _, path in _sortedKeys(tracks) do
		local label = string.format("Tracks['%s']", tostring(path))
		if type(path) ~= "string" then
			fail("%s: the key must be a path string", label)
			continue
		end
		local pathError, subPath = _checkPath(path)
		if pathError then
			fail("%s: %s", label, pathError)
		end
		local keyframes = tracks[path]
		if type(keyframes) ~= "table" then
			fail("%s: must be a list of keyframes, got %s", label, typeof(keyframes))
			continue
		end
		local allowed = if subPath and #subPath > 0 then _subPathKinds(subPath) else nil
		local firstKind, firstIndex, prevTime = nil, 0, nil
		for i, kf in ipairs(keyframes) do
			local at = string.format("%s keyframe %d", label, i)
			if type(kf) ~= "table" then
				fail("%s: must be a table like { Time = 0, Value = ... }, got %s", at, typeof(kf))
				continue
			end

			local t = kf.Time
			if not _isFiniteNumber(t) then
				fail("%s: Time %s is not a number", at, tostring(t))
			else
				if t < 0 then
					fail("%s: Time %s is before 0", at, _fmtNumber(t))
				end
				if length and t > length + TIME_EPSILON then
					fail("%s: Time %s is after Length %s", at, _fmtNumber(t), _fmtNumber(length))
				end
				if prevTime and t < prevTime then
					fail("%s: Time %s is before keyframe %d's Time %s (keyframes must be sorted by Time)", at, _fmtNumber(t), i - 1, _fmtNumber(prevTime))
				end
				prevTime = t
				if t > lastKeyTime then lastKeyTime = t end
			end

			local value = kf.Value
			local kind = typeof(value)
			if value == nil then
				fail("%s: Value is missing", at)
			elseif allowed then
				if not allowed[kind] then
					fail("%s: Value is %s, but the sub-path '.%s' takes %s", at, kind, table.concat(subPath :: {string}, "."), if allowed == NUMBER_ONLY then "a number" else "a number or a UDim")
				end
			elseif not LERP_TYPES[kind] and not HOLD_TYPES[kind] then
				fail("%s: Value type %s is not supported", at, kind)
			end
			if value ~= nil then
				if firstKind == nil then
					firstKind, firstIndex = kind, i
				elseif kind ~= firstKind then
					fail("%s: Value is %s, expected %s like keyframe %d", at, kind, firstKind, firstIndex)
				end
			end

			local easing, direction = kf.Easing, kf.Direction
			if direction ~= nil and not _isEasingSupported(Enum.EasingStyle.Linear, direction) then
				fail("%s: Direction %s is not an easing direction (In, Out or InOut)", at, tostring(direction))
			elseif easing ~= nil and easing ~= "Step" and not _isEasingSupported(easing, direction or Enum.EasingDirection.Out) then
				fail("%s: Easing %s is not a supported easing style (an Enum.EasingStyle other than Bezier or Spring, or \"Step\")", at, tostring(easing))
			end
		end
		trackKinds[path] = firstKind
	end

	local settings = cfg.Settings
	if settings ~= nil and type(settings) ~= "table" then
		fail("Settings must be a table, got %s", typeof(settings))
	elseif settings ~= nil then
		for _, key in _sortedKeys(settings) do
			local entry = settings[key]
			local label = string.format("Settings['%s']", tostring(key))
			if key == "FPS" then
				if not (_isFiniteNumber(entry) and entry > 0) then
					fail("Settings.FPS %s must be a number above 0", tostring(entry))
				end
			elseif type(entry) ~= "table" then
				fail("%s: must be a table like { IsRelative = true }, got %s", label, typeof(entry))
			else
				if tracks[key] == nil then
					fail("%s: there is no track with that path", label)
				end
				local relative = entry.IsRelative
				if relative ~= nil and type(relative) ~= "boolean" then
					fail("%s: IsRelative %s must be true or false", label, tostring(relative))
				elseif relative and trackKinds[key] and not LERP_TYPES[trackKinds[key]] then
					fail("%s: IsRelative has no effect on %s values", label, trackKinds[key])
				end
			end
		end
	end

	local events = cfg.Events
	if events ~= nil and type(events) ~= "table" then
		fail("Events must be a list, got %s", typeof(events))
	elseif events ~= nil then
		-- Without a Length the runtime plays up to the last keyframe.
		local eventLength = length or lastKeyTime
		for i, ev in ipairs(events) do
			local at = string.format("Events[%d]", i)
			if type(ev) ~= "table" then
				fail("%s: must be a table like { Time = 0, Name = \"Hit\" }, got %s", at, typeof(ev))
				continue
			end
			if type(ev.Name) ~= "string" or ev.Name == "" then
				fail("%s: Name must be a non-empty string", at)
			else
				at = string.format("Events[%d] '%s'", i, ev.Name)
			end
			if not _isFiniteNumber(ev.Time) then
				fail("%s: Time %s is not a number", at, tostring(ev.Time))
			elseif ev.Time < 0 or ev.Time > eventLength + TIME_EPSILON then
				fail("%s: Time %s is outside [0, Length %s]", at, _fmtNumber(ev.Time), _fmtNumber(eventLength))
			end
		end
	end

	return #errors == 0, errors
end

local function _findTrack(instance: Instance, processed): any
	local byData = _tracksByInstance[instance]
	local list = byData and byData[processed]
	if list then
		for _, t in list do
			if not t.IsDestroyed and t.Instance == instance then
				return t
			end
		end
	end
	return nil
end

local function _findBatch(instances: {Instance}, processed): any
	local list = _batchesByData[processed]
	if list then
		for _, t in list do
			if t:Matches(instances, processed) then
				return t
			end
		end
	end
	return nil
end

local function _loopCount(opts: Types.TrackOptions, processed): number
	local loopOpt = opts.Loop
	if loopOpt == nil then loopOpt = processed.Loop end
	if type(loopOpt) == "boolean" then return if loopOpt then -1 else 0 end
	if type(loopOpt) == "number" then return math.floor(loopOpt) end
	return 0
end

-- The Delay option overrides the animation's own Delay (R13).
local function _playOptions(options: Types.TrackOptions?, processed): Types.TrackOptions
	local opts = options or {}
	if opts.Delay == nil and processed.Delay and processed.Delay > 0 then
		opts = table.clone(opts)
		opts.Delay = processed.Delay
	end
	return opts
end

-- Semantics 2 and 4: a track forwards only to the signal returned by its latest Play()/PlayBatch(),
-- so a replay takes over. The earlier signal gets Cancelled if its run had not ended (Completed or
-- Cancelled), so code waiting on it never hangs, and nothing after that. Four connections per
-- track, ever (R8). The forwarders run inline; the proxy still gives every user callback its own
-- thread.
local function _newProxy(track): Signal.Signal
	local proxy = Signal.new()
	local previous: any = track._Proxy
	track._Proxy = proxy
	if not track._ProxyBound then
		track._ProxyBound = true
		track.Completed:_ConnectDirect(function()
			local p: any = track._Proxy
			if p then
				p._Ended = true
				p:Fire("Completed")
			end
		end)
		track.Looped:_ConnectDirect(function()
			local p = track._Proxy
			if p then p:Fire("Looped") end
		end)
		track.Cancelled:_ConnectDirect(function()
			local p: any = track._Proxy
			if p then
				p._Ended = true
				p:Fire("Cancelled")
			end
		end)
		track.MarkerReached:_ConnectDirect(function(name, data, instance)
			local p = track._Proxy
			if p then p:Fire("MarkerReached", name, data, instance) end
		end)
	end
	-- After the swap, so the new signal never sees it (CLAUDE.md semantics 4, COR2).
	if previous and not previous._Ended then
		previous._Ended = true
		previous:Fire("Cancelled")
	end
	return proxy
end

-- Play()/PlayBatch() on an existing track. A direction change on a running or finished track
-- continues from the current time (no snap); anything else restarts from the start of the
-- requested direction.
local function _replay(track, opts: Types.TrackOptions, processed)
	track.Options = opts
	track.AutoDestroy = opts.DeleteOnComplete or false
	track.LoopsRemaining = _loopCount(opts, processed)

	local speed = if opts.Reverse then -1 else 1
	local continues = (track.State ~= "Suspended" or track.IsFinished) and (track.Speed < 0) ~= (speed < 0)
	track:SetSpeed(speed)
	if not continues then
		track:Scrub(if speed < 0 then track.Duration else 0)
	end
	track:_Begin(false, not continues)
end

function AnimationService.Play(instance: Instance,
	config: Types.AnimationConfig | Types.ProcessedAnimation | string,
	options: Types.TrackOptions?): Signal.Signal?
	_ensureLoopRunning()

	local processed = _resolveConfig(config)
	if not processed then return nil end
	local opts = _playOptions(options, processed)

	local track = _findTrack(instance, processed)
	if track then
		_replay(track, opts, processed)
	else
		track = AnimTrack.new(instance, processed, opts)
		_register(track)
		track:Play()
	end
	return _newProxy(track)
end

function AnimationService.PlayBatch(instances: {Instance},
	config: Types.AnimationConfig | Types.ProcessedAnimation | string,
	options: Types.TrackOptions?): Signal.Signal?
	_ensureLoopRunning()

	local processed = _resolveConfig(config)
	if not processed then return nil end
	local opts = _playOptions(options, processed)

	local track = _findBatch(instances, processed)
	if track then
		track:SetStagger(opts.Stagger)
		track:_SetOrder(instances)
		_replay(track, opts, processed)
	else
		track = BatchedAnimTrack.new(instances, processed, opts)
		_register(track)
		track:Play()
	end
	return _newProxy(track)
end

function AnimationService.Pause(instance: Instance, config: Types.AnimationConfig | Types.ProcessedAnimation | string)
	local processed = _resolveConfig(config)
	if not processed then return end
	local t = _findTrack(instance, processed)
	if t then t:Pause() end
end

function AnimationService.Resume(instance: Instance, config: Types.AnimationConfig | Types.ProcessedAnimation | string)
	local processed = _resolveConfig(config)
	if not processed then return end
	local t = _findTrack(instance, processed)
	if t and not t.IsFinished then t:Play() end
end

function AnimationService.PauseBatch(instances: {Instance}, config: Types.AnimationConfig | Types.ProcessedAnimation | string)
	local processed = _resolveConfig(config)
	if not processed then return end
	local t = _findBatch(instances, processed)
	if t then t:Pause() end
end

function AnimationService.ResumeBatch(instances: {Instance}, config: Types.AnimationConfig | Types.ProcessedAnimation | string)
	local processed = _resolveConfig(config)
	if not processed then return end
	local t = _findBatch(instances, processed)
	if t and not t.IsFinished then t:Play() end
end

function AnimationService.CreateTrack(instance: Instance,
	config: Types.AnimationConfig | Types.ProcessedAnimation | string,
	options: Types.TrackOptions?) : Types.AnimTrack?
	_ensureLoopRunning()

	local processed = _resolveConfig(config)
	if not processed then return nil end
	local track = AnimTrack.new(instance, processed, options or {})
	_register(track)
	return track
end

function AnimationService.CreateBatchedTrack(instances: {Instance},
	config: Types.AnimationConfig | Types.ProcessedAnimation | string,
	options: Types.TrackOptions?) : Types.BatchedAnimTrack?
	_ensureLoopRunning()

	local processed = _resolveConfig(config)
	if not processed then return nil end
	local track = BatchedAnimTrack.new(instances, processed, options or {})
	_register(track)
	return track
end

function AnimationService.SetTime(instance: Instance, config: Types.AnimationConfig | Types.ProcessedAnimation | string, time: number)
	_ensureLoopRunning()

	local processed = _resolveConfig(config)
	if not processed then return end

	local foundTrack = _findTrack(instance, processed)
	if not foundTrack then
		foundTrack = AnimationService.CreateTrack(instance, config)
	end

	foundTrack:Scrub(time)
	foundTrack:Suspend()
end

function AnimationService.SetFrame(instance: Instance, config: Types.AnimationConfig | Types.ProcessedAnimation | string, frame: number)
	local conf: any = config
	local fps = conf.FPS or conf.FrameRate or (conf.Settings and conf.Settings.FPS) or 60
	AnimationService.SetTime(instance, config, frame / fps)
end

function AnimationService.SetTimeBatch(instances: {Instance}, config: Types.AnimationConfig | Types.ProcessedAnimation | string, time: number)
	_ensureLoopRunning()
	local processed = _resolveConfig(config)
	if not processed then return end

	local foundTrack = _findBatch(instances, processed)
	if not foundTrack then
		foundTrack = AnimationService.CreateBatchedTrack(instances, config)
	end

	foundTrack:Scrub(time)
	foundTrack:Suspend()
end

function AnimationService.SetFrameBatch(instances: {Instance}, config: Types.AnimationConfig | Types.ProcessedAnimation | string, frame: number)
	local conf: any = config
	local fps = conf.FPS or conf.FrameRate or (conf.Settings and conf.Settings.FPS) or 60
	AnimationService.SetTimeBatch(instances, config, frame / fps)
end

-- Every registered track rooted at `instance`, from the indexes (PER4). Collected before acting,
-- because Stop and ClearInstance fire signals whose handlers may register or remove tracks.
local function _tracksOf(instance: Instance, out: {any}, seen: {[any]: boolean}): {any}
	local byData = _tracksByInstance[instance]
	if byData then
		for _, list in byData do
			for _, t in list do
				if not seen[t] then
					seen[t] = true
					table.insert(out, t)
				end
			end
		end
	end
	local batches = _batchesByInstance[instance]
	if batches then
		for _, t in batches do
			if not seen[t] then
				seen[t] = true
				table.insert(out, t)
			end
		end
	end
	return out
end

function AnimationService.Stop(instance: Instance)
	for _, t in _tracksOf(instance, {}, {}) do
		if t:Contains(instance) then
			t:Stop()
		end
	end
end

function AnimationService.StopBatch(instances: {Instance})
	local found, seen = {}, {}
	for _, inst in ipairs(instances) do
		local batches = _batchesByInstance[inst]
		if batches then
			for _, t in batches do
				if not seen[t] and t:Contains(inst) then
					seen[t] = true
					table.insert(found, t)
				end
			end
		end
	end
	for _, t in found do
		t:Stop()
	end
end

function AnimationService.ClearPreProcessedCache()
	table.clear(_processedConfigs)
	table.clear(_animationsByName)
	table.clear(_sequencesByName)
end

function AnimationService.ClearInstance(instance: Instance)
	local cleared = { [instance] = true }
	for _, t in _tracksOf(instance, {}, {}) do
		if not t:Contains(instance) then continue end
		for _, entry in t.ActiveTracks do
			if entry.Root == instance then cleared[entry.Target] = true end
		end
		if t.Options.Reset then
			_restore(t, instance)
		end

		t:Prune(instance)

		if t.IsDestroyed or not t:IsValid() then
			t._Retired = true
			_releaseTrack(t, false)
			t:Destroy()
			_unregister(t)
		end
	end
	_dropTargets(cleared, { [instance] = true })
end

function AnimationService.ClearInstanceBatch(instances: {Instance})
	local toStop = {}
	local cleared = {}
	local found, seen = {}, {}
	for _, inst in ipairs(instances) do
		toStop[inst] = true
		cleared[inst] = true
		_tracksOf(inst, found, seen)
	end

	for _, track in found do
		if track.IsDestroyed then continue end
		for _, entry in track.ActiveTracks do
			if toStop[entry.Root] then cleared[entry.Target] = true end
		end

		local remove = false
		if getmetatable(track) == BatchedAnimTrack then
			local changed = false
			for inst in toStop do
				if track.InstanceMap[inst] then
					if track.Options.Reset then
						_restore(track, inst)
					end
					-- Survivors keep their stagger offsets (R19).
					track:_RemoveInstance(inst)
					changed = true
				end
			end
			remove = changed and #track.Instances == 0
		elseif toStop[track.Instance] then
			if track.Options.Reset then
				_restore(track, track.Instance)
			end
			remove = true
		end

		if remove then
			track._Retired = true
			_releaseTrack(track, false)
			track:Destroy()
			_unregister(track)
		end
	end

	_dropTargets(cleared, toStop)
end

function AnimationService.Suspend()
	if _renderConnection then
		_renderConnection:Disconnect()
		_renderConnection = nil
	end
end

function AnimationService.Destroy()
	AnimationService.Suspend()
	for _, t in ipairs(_activeTracks) do
		-- Unhooked first: a handle kept by game code must never re-enter the cleared lists.
		t._Waker, t._ActiveIndex, t._LiveIndex = nil, nil, nil
		_unwatch(t)
		t:Destroy()
	end
	table.clear(_activeTracks)
	table.clear(_liveTracks)
	table.clear(_tracksByInstance)
	table.clear(_batchesByData)
	table.clear(_batchesByInstance)
	table.clear(_targets)
	table.clear(_dirty)
	_dirtyN = 0
	table.clear(_processedConfigs)
	table.clear(_animationsByName)
	table.clear(_sequencesByName)
end

-- Steps the live tracks from _stepIndex on. Runs under one pcall per frame: after an error the
-- caller stops _stepping and calls again for the rest, so one failing track never freezes the
-- others (O11).
local function _stepTracks(now: number)
	local live, gen = _liveTracks, _frameGen
	local i = _stepIndex
	while true do
		local track = live[i]
		if not track then break end
		if track._StepGen == gen then
			-- Woken again after its step this frame: it runs next frame.
			i += 1
			continue
		end
		track._StepGen = gen
		_stepIndex, _stepping = i, track

		local invalid = track.IsDestroyed
		if not invalid and track._CheckValid then
			-- Set at registration and when a watched root loses its parent (PER3, PER6).
			track._CheckValid = false
			invalid = not track:IsValid()
		end
		if invalid then
			_retire(track) -- swaps another track into index i
			-- Stop() with ResetToStart on a DeleteOnComplete track leaves its reset frame to render.
			if track._FinalPending then
				track._FinalPending = nil
				_collectTrack(track)
			end
			continue
		end

		if track._ResetPending then
			-- Semantics 5: the final frame was written last frame; restore, then go dormant (COR4).
			track._ResetPending = false
			if track.IsFinished then
				_restore(track, nil)
				_releaseTrack(track, false)
			end
		end
		if track._NewRun then
			track._NewRun = false
			_startRun(track)
		end
		if track:_Update(now) then
			_collectTrack(track)
		end

		-- Paused, suspended, finished and held (speed 0, PER8) tracks sleep once rendered.
		local resting = track.State ~= "Playing" or (track.Speed == 0 and now >= track.StartTime)
		if resting and not track._OneShotDirty and not track._NewRun and not track.IsDestroyed and not track._ResetPending then
			_sleep(track) -- swaps another track into index i
		else
			i += 1
		end
	end
	_stepping = nil
end

_renderStep = function()
	local now = os.clock()
	_frameGen += 1
	_dirtyN = 0

	_stepIndex = 1
	while true do
		local ok, err = pcall(_stepTracks, now)
		if ok then break end
		_warnOnce("update:" .. tostring(err), "An animation stopped after an error: " .. tostring(err))
		local track = _stepping
		if not track then break end
		_stepping = nil
		track.State = "Suspended"
		track._OneShotDirty = false
		track._NewRun = false
		_sleep(track)
	end

	_resolveIndex = 0
	while true do
		local ok, err = pcall(_resolveDirty)
		if ok then break end
		local slot, target = _resolving, _resolvingTarget
		_resolving, _resolvingTarget = nil, nil
		-- Skipped until a track binds to it again or starts a new run on it (INT4).
		slot.Broken, slot.WriteFailed = true, true
		_warnOnce(target.ClassName .. "." .. slot.Prop .. ":" .. tostring(err), string.format("%s cannot be animated on %s, skipped: %s", slot.Prop, target.ClassName, tostring(err)))
	end
end

return AnimationService