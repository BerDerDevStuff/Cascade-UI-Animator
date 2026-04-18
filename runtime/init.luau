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
local AnimTrack = require(script.AnimTrack)
local BatchedAnimTrack = require(script.BatchedAnimTrack)
local Types = require(script.Types)
local Merger = require(script.Merger)
local Signal = require(script.Signal)

local AnimationService = {}
AnimationService.Version = script:GetAttribute("Version") or "unknown"

local _activeTracks = {}
local _processedConfigs = setmetatable({}, { __mode = "k" })
local _globalBaseCache = setmetatable({}, { __mode = "k" })
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

local function _restoreState(instance: Instance)
	local cache = _globalBaseCache[instance]
	if cache then
		for prop, val in pairs(cache) do
			pcall(function() (instance :: any)[prop] = val end)
		end
	end
end

local function _ensureBaseState(instance: Instance, prop: string)
	if not _globalBaseCache[instance] then _globalBaseCache[instance] = {} end
	local cache = _globalBaseCache[instance]

	if cache[prop] == nil then
		local s, c = pcall(function() return (instance :: any)[prop] end)
		if s then 
			if typeof(c) == "table" then c = table.clone(c) end
			cache[prop] = c 
		end
	end
	return cache[prop]
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

	for rawPath, keyframes in pairs(config.Tracks) do
		local instancePath, baseProp, subPath = Merger.parseFullPath(rawPath)
		local instanceKey = table.concat(instancePath, "/")
		local groupKey = instanceKey .. "|" .. baseProp

		if not groups[groupKey] then groups[groupKey] = {} end
		table.sort(keyframes, function(a, b) return a.Time < b.Time end)

		local isRelative = settings[rawPath] and settings[rawPath].IsRelative or false
		table.insert(groups[groupKey], { 
			SubPath = subPath, Keyframes = keyframes, IsRelative = isRelative, 
			RawPath = rawPath, InstancePath = instancePath 
		})
	end

	local events = config.Events or {}
	if #events > 1 then
		events = table.clone(events)
		table.sort(events, function(a, b) return a.Time < b.Time end)
	end

	local data = {
		IsProcessed = true, Length = config.Length, Loop = config.Loop or false,
		Delay = config.Delay or 0, PropertyGroups = groups,
		Events = events
	}
	_processedConfigs[config] = data 
	return data
end

function AnimationService.Play(instance: Instance,
	config: Types.AnimationConfig | Types.ProcessedAnimation | string,
	options: Types.TrackOptions?): Signal.Signal?
	_ensureLoopRunning()

	local processed = _resolveConfig(config)
	if not processed then return nil end
	local opts = options or {}

	local track = nil
	for _, t in ipairs(_activeTracks) do
		if t.Instance == instance and t.Data == processed then
			track = t
			break
		end
	end

	if track then
		track.Options = opts
		local loopOpt = opts.Loop
		if loopOpt == nil then loopOpt = processed.Loop end
		if type(loopOpt) == "boolean" then track.LoopsRemaining = loopOpt and -1 or 0
		elseif type(loopOpt) == "number" then track.LoopsRemaining = math.floor(loopOpt)
		else track.LoopsRemaining = 0 end

		local speed = (opts.Reverse and -1) or 1
		track:SetSpeed(speed)

		if speed < 0 then
			track:Scrub(track.Duration)
		elseif speed > 0 then
			track:Scrub(0)
		end
	else
		track = AnimTrack.new(instance, processed, opts)
		table.insert(_activeTracks, track)
	end

	local proxy = Signal.new()
	track.Completed:Connect(function() proxy:Fire("Completed") end)
	track.Looped:Connect(function() proxy:Fire("Looped") end)
	track.Cancelled:Connect(function() proxy:Fire("Cancelled") end)
	track.MarkerReached:Connect(function(name, data) proxy:Fire("MarkerReached", name, data) end)

	track:Play()
	return proxy
end

function AnimationService.PlayBatch(instances: {Instance},
	config: Types.AnimationConfig | Types.ProcessedAnimation | string,
	options: Types.TrackOptions?): Signal.Signal?
	_ensureLoopRunning()

	local processed = _resolveConfig(config)
	if not processed then return nil end
	local opts = options or {}

	local track = nil
	for _, t in ipairs(_activeTracks) do
		if getmetatable(t) == BatchedAnimTrack and t:Matches(instances, processed) then
			track = t
			break
		end
	end

	if track then
		track.Options = opts
		local loopOpt = opts.Loop
		if loopOpt == nil then loopOpt = processed.Loop end
		if type(loopOpt) == "boolean" then track.LoopsRemaining = loopOpt and -1 or 0
		elseif type(loopOpt) == "number" then track.LoopsRemaining = math.floor(loopOpt)
		else track.LoopsRemaining = 0 end

		track:SetStagger(opts.Stagger)
		local speed = (opts.Reverse and -1) or 1
		track:SetSpeed(speed)

		if speed < 0 then
			track:Scrub(track.Duration)
		elseif speed > 0 then
			track:Scrub(0)
		end
	else
		track = BatchedAnimTrack.new(instances, processed, opts)
		table.insert(_activeTracks, track)
	end

	local proxy = Signal.new()
	track.Completed:Connect(function() proxy:Fire("Completed") end)
	track.Looped:Connect(function() proxy:Fire("Looped") end)
	track.Cancelled:Connect(function() proxy:Fire("Cancelled") end)
	track.MarkerReached:Connect(function(name, data, instance) proxy:Fire("MarkerReached", name, data, instance) end)

	track:Play()
	return proxy
end

function AnimationService.Pause(instance: Instance, config: Types.AnimationConfig | Types.ProcessedAnimation | string)
	local processed = _resolveConfig(config)
	if not processed then return end
	for _, t in ipairs(_activeTracks) do
		if t.Instance == instance and t.Data == processed then
			t:Pause()
			return
		end
	end
end

function AnimationService.Resume(instance: Instance, config: Types.AnimationConfig | Types.ProcessedAnimation | string)
	local processed = _resolveConfig(config)
	if not processed then return end
	for _, t in ipairs(_activeTracks) do
		if t.Instance == instance and t.Data == processed then
			t:Play()
			return
		end
	end
end

function AnimationService.PauseBatch(instances: {Instance}, config: Types.AnimationConfig | Types.ProcessedAnimation | string)
	local processed = _resolveConfig(config)
	if not processed then return end
	for _, t in ipairs(_activeTracks) do
		if getmetatable(t) == BatchedAnimTrack and t:Matches(instances, processed) then
			t:Pause()
			return
		end
	end
end

function AnimationService.ResumeBatch(instances: {Instance}, config: Types.AnimationConfig | Types.ProcessedAnimation | string)
	local processed = _resolveConfig(config)
	if not processed then return end
	for _, t in ipairs(_activeTracks) do
		if getmetatable(t) == BatchedAnimTrack and t:Matches(instances, processed) then
			t:Play()
			return
		end
	end
end

function AnimationService.CreateTrack(instance: Instance,
	config: Types.AnimationConfig | Types.ProcessedAnimation | string,
	options: Types.TrackOptions?) : Types.AnimTrack?
	_ensureLoopRunning()

	local processed = _resolveConfig(config)
	if not processed then return nil end
	local track = AnimTrack.new(instance, processed, options or {})
	table.insert(_activeTracks, track)
	return track
end

function AnimationService.CreateBatchedTrack(instances: {Instance},
	config: Types.AnimationConfig | Types.ProcessedAnimation | string,
	options: Types.TrackOptions?) : Types.BatchedAnimTrack?
	_ensureLoopRunning()

	local processed = _resolveConfig(config)
	if not processed then return nil end
	local track = BatchedAnimTrack.new(instances, processed, options or {})
	table.insert(_activeTracks, track)
	return track
end

function AnimationService.SetTime(instance: Instance, config: Types.AnimationConfig | Types.ProcessedAnimation | string, time: number)
	_ensureLoopRunning()

	local processed = _resolveConfig(config)
	if not processed then return end

	local foundTrack = nil
	for _, t in ipairs(_activeTracks) do
		if t.Instance == instance and t.Data == processed then
			foundTrack = t
			break
		end
	end

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

	local foundTrack = nil
	for _, t in ipairs(_activeTracks) do
		if getmetatable(t) == BatchedAnimTrack and t:Matches(instances, processed) then
			foundTrack = t
			break
		end
	end

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

function AnimationService.Stop(instance: Instance)
	local i = 1
	local count = #_activeTracks
	while i <= count do
		local t = _activeTracks[i]
		if t:Contains(instance) then
			t:Stop()
		end
		i += 1
	end
end

function AnimationService.StopBatch(instances: {Instance})
	for _, t in ipairs(_activeTracks) do
		if getmetatable(t) == BatchedAnimTrack then
			for _, inst in ipairs(instances) do
				if t:Contains(inst) then
					t:Stop()
					break
				end
			end
		end
	end
end

function AnimationService.ClearPreProcessedCache()
	table.clear(_processedConfigs)
	table.clear(_animationsByName)
	table.clear(_sequencesByName)
end

function AnimationService.ClearInstance(instance: Instance)
	local i = 1
	local count = #_activeTracks
	while i <= count do
		local t = _activeTracks[i]
		if t:Contains(instance) then

			if t.Options.Reset then
				_restoreState(instance)
			end

			t:Prune(instance)

			if t.IsDestroyed or not t:IsValid() then
				t:Destroy()
				_activeTracks[i] = _activeTracks[count]
				_activeTracks[count] = nil
				count -= 1
			else
				i += 1
			end
		else
			i += 1
		end
	end
	
	if _globalBaseCache[instance] then
		_globalBaseCache[instance] = nil
	end
end

function AnimationService.ClearInstanceBatch(instances: {Instance})
	local toStop = {}
	for _, inst in ipairs(instances) do toStop[inst] = true end

	local i = 1
	local count = #_activeTracks
	while i <= count do
		local track = _activeTracks[i]

		if getmetatable(track) == BatchedAnimTrack then
			local changed = false
			local instList = track.Instances

			for j = #instList, 1, -1 do
				local inst = instList[j]
				if toStop[inst] then
					if track.Options.Reset then
						_restoreState(inst)
					end

					track.InstanceMap[inst] = nil
					table.remove(instList, j)
					changed = true
				end
			end

			if changed then
				if #instList == 0 then
					track:Destroy()
					_activeTracks[i] = _activeTracks[count]
					_activeTracks[count] = nil
					count -= 1
					continue 
				else
					track:InvalidateBaseState()
				end
			end

		elseif getmetatable(track) == AnimTrack then
			if toStop[track.Instance] then
				if track.Options.Reset then
					_restoreState(track.Instance)
				end

				track:Destroy()
				_activeTracks[i] = _activeTracks[count]
				_activeTracks[count] = nil
				count -= 1
				continue
			end
		end

		i += 1
	end

	for _, instance in ipairs(instances) do
		if _globalBaseCache[instance] then
			_globalBaseCache[instance] = nil
		end
	end
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
		t:Destroy()
	end
	table.clear(_activeTracks)
	table.clear(_globalBaseCache)
	table.clear(_processedConfigs)
	table.clear(_animationsByName)
	table.clear(_sequencesByName)
end

_renderStep = function()
	local now = os.clock()
	local globalBuffer = {} 

	local trackCount = #_activeTracks
	local i = 1

	while i <= trackCount do
		local track = _activeTracks[i]

		local shouldRemove = false
		if track.IsDestroyed then
			shouldRemove = true
		elseif track.State == "Suspended" and track.AutoDestroy and track.IsFinished then
			shouldRemove = true
		elseif not track:IsValid() then
			shouldRemove = true
		end

		if shouldRemove then
			if getmetatable(track) == BatchedAnimTrack then
				if track.Instances and track.Options.Reset then 
					for _, inst in ipairs(track.Instances) do
						_restoreState(inst)
					end
				end
			elseif getmetatable(track) == AnimTrack then
				if track.Instance and track.Options.Reset then
					_restoreState(track.Instance)
				end
			end

			if not track.IsDestroyed then track:Destroy() end
			_activeTracks[i] = _activeTracks[trackCount]
			_activeTracks[trackCount] = nil
			trackCount -= 1
		else
			i += 1
		end
	end

	for _, track in pairs(_activeTracks) do
		local result = track:_Update(now)

		if result then
			for target, props in pairs(result) do
				if not globalBuffer[target] then globalBuffer[target] = {} end
				local objBuf = globalBuffer[target]

				for propName, ops in pairs(props) do
					if not objBuf[propName] then objBuf[propName] = { Absolute = nil, Deltas = nil, SubDeltas = nil } end
					local propBuf = objBuf[propName]

					for _, op in ipairs(ops) do
						_ensureBaseState(target, propName)

						if op.Type == "Absolute" then
							if #op.SubPath > 0 then
								if propBuf.Absolute == nil then
									propBuf.Absolute = (target :: any)[propName]
								end
								if propBuf.Absolute then
									propBuf.Absolute = Merger.merge(propBuf.Absolute, op.SubPath, op.Value)
								end
							else
								propBuf.Absolute = op.Value
							end

						elseif op.Type == "Relative" then
							if #op.SubPath > 0 then
								if not propBuf.SubDeltas then propBuf.SubDeltas = {} end
								local key = table.concat(op.SubPath, ".")
								if propBuf.SubDeltas[key] then
									propBuf.SubDeltas[key].Delta = Merger.add(propBuf.SubDeltas[key].Delta, op.Value)
								else
									propBuf.SubDeltas[key] = { SubPath = op.SubPath, Delta = op.Value }
								end
							else
								if propBuf.Deltas == nil then propBuf.Deltas = op.Value
								else propBuf.Deltas = Merger.add(propBuf.Deltas, op.Value) end
							end
						end
					end
				end
			end
		end
	end

	for target, props in pairs(globalBuffer) do
		if target.Parent then
			for propName, buf in pairs(props) do
				local finalVal = buf.Absolute

				if finalVal == nil and (buf.Deltas ~= nil or buf.SubDeltas ~= nil) then
					finalVal = _globalBaseCache[target][propName]
				end

				if buf.Deltas ~= nil and finalVal ~= nil then
					finalVal = Merger.add(finalVal, buf.Deltas)
				end

				if buf.SubDeltas ~= nil and finalVal ~= nil then
					for _, subDelta in pairs(buf.SubDeltas) do
						local baseSub = Merger.extractSub(finalVal, subDelta.SubPath)
						finalVal = Merger.merge(finalVal, subDelta.SubPath, Merger.add(baseSub, subDelta.Delta))
					end
				end

				if finalVal ~= nil then
					(target :: any)[propName] = finalVal
				end
			end
		end
	end
end

_ensureLoopRunning()

return AnimationService