--!native
--!optimize 2

local Types = require(script.Parent.Types)
local Signal = require(script.Parent.Signal)
local Evaluator = require(script.Parent.Evaluator)

local sample = Evaluator.sample
local eventCursor = Evaluator.eventCursor

local BatchedAnimTrack = {}
BatchedAnimTrack.__index = BatchedAnimTrack

-- Event cursors sit this far before (forward) or after (reverse) the playhead, so an event placed
-- exactly on the start time fires on the first frame.
local EPSILON = 0.0001
-- Loop wraps handled one by one, with their events, in a single frame; further wraps are collapsed.
local MAX_WRAPS = 64
-- Duration - Offset can round just below Length (0.3 + 2 * 0.3 = 0.8999999999999999): local times
-- this close to the end are the end, so the last instance reaches its end keyframe and marker (COR1).
local SNAP = 1e-6

local function resolveInstance(root: Instance, pathParts: {string}): Instance?
	local current = root
	for _, childName in ipairs(pathParts) do
		if current then current = current:FindFirstChild(childName) end
	end
	return current
end

function BatchedAnimTrack.new(instances: {Instance}, config: Types.AnimationConfig | Types.ProcessedAnimation, options: Types.TrackOptions)
	local self = setmetatable({}, BatchedAnimTrack)
	options = options or {}

	self.Instances = table.clone(instances)
	self.InstanceMap = {}
	for _, inst in ipairs(instances) do self.InstanceMap[inst] = true end

	self.RawConfig = config
	self.Data = (config :: any).IsProcessed and (config :: Types.ProcessedAnimation) or nil
	self.Options = options

	self.State = "Suspended"
	self._OneShotDirty = false

	self.CurrentTime = (options :: any).StartTime or 0
	self.StartTime = 0
	self.Speed = options.Reverse and -1 or 1
	self.Duration = 0
	-- Among absolute writers of one property, the most recent run wins.
	self.RunStamp = os.clock()

	self.Stagger = options.Stagger or 0

	self.AutoDestroy = options.DeleteOnComplete or false
	self.IsFinished = false
	self.IsDestroyed = false

	self.Completed = Signal.new()
	self.Looped = Signal.new()
	self.Cancelled = Signal.new()
	self.MarkerReached = Signal.new()

	self.ActiveTracks = {}
	self._BuildId = 0
	self._EvalGen = 0
	self.LoopsRemaining = 0

	self._eventEntries = {}
	self._lastNow = 0
	self._gen = 0
	self._rewindOnPlay = false
	-- Read and cleared by AnimationService before the next frame (relative base capture).
	self._NewRun = false
	self._Rewound = false
	-- Read by AnimationService: a replay of a run in progress, and a Reset due after a finish.
	self._Takeover = false
	self._ResetPending = false
	self._DelayLeft = nil

	if self.Data then
		self:_RecalculateDuration()

		if self.Speed < 0 and (options :: any).StartTime == nil then
			self.CurrentTime = self.Duration
		end

		local initialLoop = options.Loop
		if initialLoop == nil then initialLoop = self.Data.Loop end
		if type(initialLoop) == "boolean" then self.LoopsRemaining = initialLoop and -1 or 0
		elseif type(initialLoop) == "number" then self.LoopsRemaining = math.floor(initialLoop) end

		self:_BuildTracks()
	end

	return self
end

function BatchedAnimTrack:Matches(instances: {Instance}, configData: any): boolean
	if self.IsDestroyed or self.Data ~= configData or not self.Instances then return false end
	if #self.Instances ~= #instances then return false end
	for _, inst in ipairs(instances) do
		if not self.InstanceMap[inst] then return false end
	end
	return true
end

-- Adopts the order of `instances` (same set) so the stagger cascade follows the latest call (R21).
function BatchedAnimTrack:_SetOrder(instances: {Instance})
	local current = self.Instances
	if not current then return end
	for i, inst in ipairs(instances) do
		if current[i] ~= inst then
			self.Instances = table.clone(instances)
			self:_RecalculateDuration()
			self:_BuildTracks()
			return
		end
	end
end

-- Moves every event cursor to its instance's local time at batch time `time`.
function BatchedAnimTrack:_PrimeEntries(time: number)
	local animLength = self.Data and self.Data.Length or 0
	local reverse = self.Speed < 0
	for _, entry in ipairs(self._eventEntries) do
		local localTime = math.clamp(time - entry.Offset, 0, animLength)
		entry.LastLocalTime = if reverse then localTime + EPSILON else localTime - EPSILON
	end
end

-- Starts playback. A resume keeps the playhead and the event cursors. A new run applies Delay,
-- optionally rewinds to the start of the current direction and re-primes the event cursors.
function BatchedAnimTrack:_Begin(isResume: boolean, rewind: boolean?)
	local now = os.clock()
	if isResume then
		-- A pause during the delay keeps the rest of the delay (COR7).
		self.StartTime = now + (self._DelayLeft or 0)
	else
		rewind = rewind or self._rewindOnPlay
		self._rewindOnPlay = false
		if rewind then
			self.CurrentTime = if self.Speed < 0 then self.Duration else 0
		end
		self.StartTime = now + (self.Options.Delay or 0)
		self.RunStamp = now
		self._gen += 1
		if not self._NewRun then
			-- A replay of a run in progress keeps that run's Reset values.
			self._Takeover = self.State == "Playing" or self.State == "Paused"
		end
		self._Rewound = (self._NewRun and self._Rewound) or rewind == true
		self._NewRun = true
		self:_PrimeEntries(self.CurrentTime)
	end
	self._DelayLeft = nil
	self._lastNow = self.StartTime
	self.State = "Playing"
	self.IsFinished = false
	self:_Wake()
end

-- Asks AnimationService to step this track again (set by the service; dormant tracks are skipped).
function BatchedAnimTrack:_Wake()
	local waker = self._Waker
	if waker then waker(self) end
end

function BatchedAnimTrack:Play()
	if self.IsDestroyed or self.State == "Playing" then return end
	if self.IsFinished then
		-- Like Tween:Play() after completion: a finished track plays again from the start of its
		-- direction (COR8). One whose direction was flipped already sits there and continues, so it
		-- unwinds what it left instead of restarting on top of it.
		local atStart = if self.Speed < 0 then self.CurrentTime >= self.Duration else self.CurrentTime <= 0
		self:_Begin(false, not atStart)
	else
		self:_Begin(self.State == "Paused")
	end
end

function BatchedAnimTrack:Pause()
	if self.State == "Playing" then
		self.State = "Paused"
		local left = self.StartTime - os.clock()
		self._DelayLeft = if left > 0 then left else nil
	end
end

function BatchedAnimTrack:Suspend()
	self.State = "Suspended"
end

function BatchedAnimTrack:Stop()
	if self.IsDestroyed then return end
	self.State = "Suspended"
	self.IsFinished = false
	self._gen += 1
	if self.Options.ResetToStart then
		self:Scrub(0)
	else
		self.CurrentTime = if self.Speed < 0 then self.Duration else 0
		self:_PrimeEntries(self.CurrentTime)
	end
	self._rewindOnPlay = true
	self.Cancelled:Fire()
	if self.AutoDestroy and self.State ~= "Playing" and not self.IsDestroyed then
		if self.Options.ResetToStart then
			self:_Evaluate()
			self._FinalPending = true
		end
		self:Destroy()
	end
end

function BatchedAnimTrack:Scrub(time: number)
	self.CurrentTime = math.clamp(time, 0, self.Duration)
	self._OneShotDirty = true
	self.IsFinished = false
	self._rewindOnPlay = false
	self:_PrimeEntries(self.CurrentTime)
	self:_Wake()
end

-- The sign is the direction, the magnitude a time scale; 0 holds the playhead.
function BatchedAnimTrack:SetSpeed(speed: number)
	local held = self.Speed == 0 and self.State == "Playing"
	self.Speed = speed
	if held and speed ~= 0 then
		-- A held track sleeps (PER8): wake it without counting the hold as elapsed time.
		local now = os.clock()
		if now > self._lastNow then self._lastNow = now end
		self:_Wake()
	end
end

function BatchedAnimTrack:SetStagger(stagger: number)
	local newStagger = stagger or 0
	if self.Stagger == newStagger then return end

	self.Stagger = newStagger
	self:_RecalculateDuration()

	self:_BuildTracks()
end

function BatchedAnimTrack:SetLoop(loop: boolean | number)
	if type(loop) == "boolean" then self.LoopsRemaining = loop and -1 or 0
	elseif type(loop) == "number" then self.LoopsRemaining = math.floor(loop) end
end

function BatchedAnimTrack:InvalidateBaseState()
	self:_BuildTracks()
end

-- ActiveTracks is kept so AnimationService can still restore Reset values and release the
-- track's contributions when it removes the destroyed track.
function BatchedAnimTrack:Destroy()
	if self.IsDestroyed then return end
	self.IsDestroyed = true
	self._gen += 1
	self.State = "Suspended"
	self.Completed:Destroy()
	self.Looped:Destroy()
	self.Cancelled:Destroy()
	self.MarkerReached:Destroy()
	self.Instances = nil
	table.clear(self.InstanceMap)
	self:_Wake()
end

function BatchedAnimTrack:Contains(instance: Instance): boolean
	return not self.IsDestroyed and self.InstanceMap[instance] == true
end

function BatchedAnimTrack:IsValid(): boolean
	local instances = self.Instances
	if self.IsDestroyed or not instances then return false end
	for i = #instances, 1, -1 do
		local inst = instances[i]
		if inst.Parent == nil then
			self:_RemoveInstance(inst)
		end
	end
	return #instances > 0
end

function BatchedAnimTrack:Prune(instance: Instance)
	if self.IsDestroyed or not self.InstanceMap[instance] then return end
	self:_RemoveInstance(instance)
	if #self.Instances == 0 then
		self:Destroy()
	end
end

-- Drops one instance mid-play. The survivors keep their stagger offsets and event cursors, and
-- Duration shrinks to the last remaining slot (R19).
function BatchedAnimTrack:_RemoveInstance(instance: Instance)
	if not self.InstanceMap[instance] then return end
	self.InstanceMap[instance] = nil

	local instances = self.Instances
	for i = #instances, 1, -1 do
		if instances[i] == instance then table.remove(instances, i) end
	end
	local tracks = self.ActiveTracks
	for i = #tracks, 1, -1 do
		if tracks[i].Root == instance then table.remove(tracks, i) end
	end
	local entries = self._eventEntries
	local maxOffset = 0
	for i = #entries, 1, -1 do
		local entry = entries[i]
		if entry.Instance == instance then
			table.remove(entries, i)
		elseif entry.Offset > maxOffset then
			maxOffset = entry.Offset
		end
	end

	if self.Data then
		self.Duration = self.Data.Length + maxOffset
		if self.CurrentTime > self.Duration then
			self.CurrentTime = self.Duration
		end
	end
end

function BatchedAnimTrack:_RecalculateDuration()
	if not self.Data or not self.Instances then return end
	local staggerDelay = (#self.Instances - 1) * self.Stagger
	if staggerDelay < 0 then staggerDelay = 0 end
	self.Duration = self.Data.Length + staggerDelay
end

-- One channel per (instance, animated path), evaluated in place each frame (Value) and bound to its
-- property slot by AnimationService. Channels of one path share a memo, so instances at the same
-- local time (stagger 0, or clamped before their start or after their end) evaluate once (O8).
function BatchedAnimTrack:_BuildTracks()
	table.clear(self.ActiveTracks)
	self._BuildId += 1
	if not self.Data or not self.Instances then return end

	local memos = {}
	for index, instance in ipairs(self.Instances) do
		local staggerOffset = (index - 1) * self.Stagger

		for groupKey, tracks in pairs(self.Data.PropertyGroups) do
			local template = tracks[1]
			local target = resolveInstance(instance, template.InstancePath)
			if target then
				local splitKey = string.split(groupKey, "|")
				local baseProp = splitKey[#splitKey]

				for _, trackData in ipairs(tracks) do
					local memo = memos[trackData]
					if not memo then
						memo = { Gen = 0, Time = 0, Value = nil }
						memos[trackData] = memo
					end
					table.insert(self.ActiveTracks, {
						Data = trackData,
						Target = target,
						BaseProp = baseProp,
						Offset = staggerOffset,
						Root = instance,
						Keyframes = trackData.Keyframes, SubPath = trackData.SubPath, HasSub = #trackData.SubPath > 0,
						IsRelative = not not trackData.IsRelative, Seg = 1, T1 = math.huge, T2 = 0, K1 = nil, K2 = nil,
						Ease = nil, Value = nil, Held = nil, Slot = nil, Memo = memo,
					})
				end
			end
		end
	end

	table.clear(self._eventEntries)
	for index, instance in ipairs(self.Instances) do
		table.insert(self._eventEntries, {
			Instance = instance,
			Offset = (index - 1) * self.Stagger,
			LastLocalTime = 0
		})
	end
	self:_PrimeEntries(self.CurrentTime)
end

-- Fires each instance's markers between its cursor and its local time at batch time `time`.
-- Returns false when a handler started a new run, stopped or destroyed the track.
function BatchedAnimTrack:_FireEvents(events: {any}, time: number, reverse: boolean, gen: number): boolean
	local animLength = self.Data.Length
	local n = #events
	for _, entry in ipairs(self._eventEntries) do
		local localTime = time - entry.Offset
		if reverse then
			if localTime > animLength + SNAP then continue end -- not started yet
			if localTime < 0 then
				localTime = 0
			elseif localTime > animLength - SNAP then
				localTime = animLength
			end
		else
			if localTime < 0 then continue end -- not started yet
			if localTime > animLength - SNAP then localTime = animLength end
		end

		local prevLocal = entry.LastLocalTime
		if localTime == prevLocal then continue end -- clamped and unchanged: nothing to fire (PER7)
		entry.LastLocalTime = localTime
		local i = eventCursor(events, prevLocal, reverse, entry.Cursor)
		if reverse then
			while i > 0 do
				local ev = events[i]
				if ev.Time < localTime then break end
				i -= 1
				self.MarkerReached:Fire(ev.Name, ev, entry.Instance)
				if self._gen ~= gen then return false end
			end
		else
			while i <= n do
				local ev = events[i]
				if ev.Time > localTime then break end
				i += 1
				self.MarkerReached:Fire(ev.Name, ev, entry.Instance)
				if self._gen ~= gen then return false end
			end
		end
		entry.Cursor = i
	end
	return true
end

-- Evaluates every channel at its instance's local time into its Value field.
function BatchedAnimTrack:_Evaluate()
	local animLength = self.Data.Length
	local isReversed = self.Speed < 0
	local time = self.CurrentTime
	local gen = self._EvalGen + 1
	self._EvalGen = gen

	for _, ch in self.ActiveTracks do
		local localTime = time - ch.Offset
		if localTime <= 0 then
			localTime = 0
		elseif localTime > animLength - SNAP then
			localTime = animLength
		end
		local memo = ch.Memo
		if memo.Gen == gen and memo.Time == localTime then
			ch.Value = memo.Value
		else
			local value = sample(ch, localTime, isReversed)
			ch.Value = value
			memo.Gen, memo.Time, memo.Value = gen, localTime, value
		end
	end
end

function BatchedAnimTrack:_Update(now: number)
	if self.IsDestroyed then return nil end
	if self.State ~= "Playing" then
		-- Suspended, Paused and finished tracks are dormant: they render only after a Scrub.
		if not self._OneShotDirty then return nil end
		self._OneShotDirty = false
		self:_Evaluate()
		return true
	end
	self._OneShotDirty = false
	if now < self.StartTime then return nil end

	local dt = now - self._lastNow
	self._lastNow = now
	local gen = self._gen
	local dur = self.Duration
	local reverse = self.Speed < 0
	local events = self.Data.Events
	local hasEvents = events ~= nil and #events > 0
	local finished = false

	if dur <= 0 then
		-- Zero length: show the keyframe once and complete; it cannot loop.
		finished = true
		self.CurrentTime = 0
	else
		local progress = (if reverse then dur - self.CurrentTime else self.CurrentTime) + dt * math.abs(self.Speed)
		local wraps = 0
		while progress > dur do
			-- Close the cycle for every instance: its remaining events fire before Looped / Completed.
			if hasEvents and not self:_FireEvents(events, if reverse then 0 else dur, reverse, gen) then return nil end
			local loops = self.LoopsRemaining
			if loops ~= -1 and loops <= 0 then
				finished = true
				break
			end
			progress -= dur
			if loops > 0 then self.LoopsRemaining = loops - 1 end
			wraps += 1
			if wraps >= MAX_WRAPS and progress > dur then
				local skipped = math.floor(progress / dur)
				if self.LoopsRemaining > 0 then
					skipped = math.min(skipped, self.LoopsRemaining)
					self.LoopsRemaining -= skipped
				end
				progress -= skipped * dur
			end
			self:_PrimeEntries(if reverse then dur else 0)
			self.Looped:Fire()
			if self._gen ~= gen then return nil end
		end

		if finished then
			self.CurrentTime = if reverse then 0 else dur
		else
			self.CurrentTime = if reverse then dur - progress else progress
		end
	end

	if hasEvents and not self:_FireEvents(events, self.CurrentTime, reverse, gen) then return nil end

	self:_Evaluate()
	if finished then
		-- Write the end values this frame, then go dormant: no writes until played or scrubbed again.
		-- With Reset, AnimationService restores the values on the next frame (semantics 5).
		self.State = "Suspended"
		self.IsFinished = true
		self._ResetPending = not not self.Options.Reset
		self.Completed:Fire()
		-- A Completed handler may have replayed the track; only destroy a track that stayed finished.
		if self.AutoDestroy and self.IsFinished and self.State ~= "Playing" then
			self:Destroy()
		end
	end
	return true
end

return BatchedAnimTrack