--!native
--!optimize 2

local Types = require(script.Parent.Types)
local Signal = require(script.Parent.Signal)
local Evaluator = require(script.Parent.Evaluator)

local BatchedAnimTrack = {}
BatchedAnimTrack.__index = BatchedAnimTrack

local function resolveInstance(root: Instance, pathParts: {string}): Instance?
	local current = root
	for _, childName in ipairs(pathParts) do
		if current then current = current:FindFirstChild(childName) end
	end
	return current
end

function BatchedAnimTrack.new(instances: {Instance}, config: Types.AnimationConfig | Types.ProcessedAnimation, options: Types.TrackOptions)
	local self = setmetatable({}, BatchedAnimTrack)

	self.Instances = table.clone(instances)
	self.InstanceMap = {} 
	for _, inst in ipairs(instances) do self.InstanceMap[inst] = true end

	self.RawConfig = config
	self.Data = (config :: any).IsProcessed and (config :: Types.ProcessedAnimation) or nil 
	self.Options = options or {} :: Types.TrackOptions

	self.State = "Suspended"
	self._OneShotDirty = false

	self.CurrentTime = options.StartTime or 0
	self.CycleStartTime = 0
	self.StartTime = 0
	self.Speed = options.Reverse and -1 or 1
	self.Duration = 0

	self.Stagger = options.Stagger or 0

	self.AutoDestroy = options.DeleteOnComplete or false
	self.IsFinished = false
	self.IsDestroyed = false 

	self.Completed = Signal.new()
	self.Looped = Signal.new()
	self.Cancelled = Signal.new()
	self.MarkerReached = Signal.new()

	self.ActiveTracks = {}
	self.LoopsRemaining = 0

	self._eventEntries = {}
	self._loopedThisFrame = false

	if self.Data then
		self:_RecalculateDuration()

		if self.Speed < 0 and self.Options.StartTime == nil then
			self.CurrentTime = self.Duration
		end

		local initialLoop = self.Options.Loop
		if initialLoop == nil then initialLoop = self.Data.Loop end
		if type(initialLoop) == "boolean" then self.LoopsRemaining = initialLoop and -1 or 0
		elseif type(initialLoop) == "number" then self.LoopsRemaining = math.floor(initialLoop) end

		self:_BuildTracks()
	end

	return self
end

function BatchedAnimTrack:Matches(instances: {Instance}, configData: any): boolean
	if self.Data ~= configData then return false end
	if #self.Instances ~= #instances then return false end
	for _, inst in ipairs(instances) do
		if not self.InstanceMap[inst] then return false end
	end
	return true
end

function BatchedAnimTrack:Play()
	if self.IsDestroyed then return end
	if self.State == "Playing" then return end
	local now = os.clock()
	if self.State == "Suspended" then
		local delay = self.Options.Delay or 0
		self.StartTime = now + delay
		if self.Speed > 0 then
			self.CycleStartTime = self.StartTime - self.CurrentTime
		else
			self.CycleStartTime = self.StartTime - (self.Duration - self.CurrentTime)
		end
	else
		self.StartTime = now
		if self.Speed > 0 then
			self.CycleStartTime = now - self.CurrentTime
		else
			self.CycleStartTime = now - (self.Duration - self.CurrentTime)
		end
	end
	self.State = "Playing"
	self.IsFinished = false
	local animLen = self.Data and self.Data.Length or 0
	local startLocal = self.Speed < 0 and (animLen + 0.0001) or -0.0001
	for _, entry in ipairs(self._eventEntries) do
		entry.LastLocalTime = startLocal
	end
end

function BatchedAnimTrack:Pause()
	if self.State == "Paused" then return end
	self.State = "Paused"
end

function BatchedAnimTrack:Suspend()
	self.State = "Suspended"
end

function BatchedAnimTrack:Stop()
	if self.Options.ResetToStart then
		self:Scrub(0)
	end
	
	self.State = "Suspended"
	self.CurrentTime = 0
	self.IsFinished = false
	self._loopedThisFrame = false
	for _, entry in ipairs(self._eventEntries) do
		entry.LastLocalTime = 0
	end
	self.Cancelled:Fire()
	if self.AutoDestroy then
		self:Destroy()
	end
end

function BatchedAnimTrack:Scrub(time: number)
	self.CurrentTime = math.clamp(time, 0, self.Duration)
	if self.State == "Playing" then
		local now = os.clock()
		if self.Speed > 0 then
			self.CycleStartTime = now - self.CurrentTime
		else
			self.CycleStartTime = now - (self.Duration - self.CurrentTime)
		end
	elseif self.State == "Suspended" then
		self._OneShotDirty = true
	end
end

function BatchedAnimTrack:SetSpeed(speed: number)
	if self.Speed == speed then return end
	self.Speed = speed
	if self.State == "Playing" then
		local now = os.clock()
		if self.Speed > 0 then
			self.CycleStartTime = now - self.CurrentTime
		else
			self.CycleStartTime = now - (self.Duration - self.CurrentTime)
		end
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

function BatchedAnimTrack:Destroy()
	if self.IsDestroyed then return end
	self.IsDestroyed = true
	self.State = "Suspended"
	self.Completed:Destroy()
	self.Looped:Destroy()
	self.Cancelled:Destroy()
	self.MarkerReached:Destroy()
	self.ActiveTracks = nil
	self.Instances = nil
end

function BatchedAnimTrack:Contains(instance: Instance): boolean
	return self.InstanceMap[instance] == true
end

function BatchedAnimTrack:IsValid(): boolean
	if not self.Instances then return false end
	local anyAlive = false
	local count = #self.Instances
	local i = 1

	while i <= count do
		if self.Instances[i].Parent == nil then
			self.InstanceMap[self.Instances[i]] = nil
			self.Instances[i] = self.Instances[count]
			self.Instances[count] = nil
			count -= 1
		else
			anyAlive = true
			i += 1
		end
	end

	return anyAlive
end

function BatchedAnimTrack:Prune(instance: Instance)
	if self.InstanceMap[instance] then
		self.InstanceMap[instance] = nil
		for i, inst in ipairs(self.Instances) do
			if inst == instance then
				table.remove(self.Instances, i)
				break
			end
		end

		if #self.Instances == 0 then
			self:Destroy()
		else
			self:_BuildTracks()
		end
	end
end

function BatchedAnimTrack:_RecalculateDuration()
	if not self.Data then return end
	local staggerDelay = (#self.Instances - 1) * self.Stagger
	if staggerDelay < 0 then staggerDelay = 0 end
	self.Duration = self.Data.Length + staggerDelay
end

function BatchedAnimTrack:_BuildTracks()
	table.clear(self.ActiveTracks)
	if not self.Data then return end

	for index, instance in ipairs(self.Instances) do
		local staggerOffset = (index - 1) * self.Stagger

		for groupKey, tracks in pairs(self.Data.PropertyGroups) do
			local template = tracks[1]
			local target = resolveInstance(instance, template.InstancePath)
			if target then
				local splitKey = string.split(groupKey, "|")
				local baseProp = splitKey[#splitKey]

				for _, trackData in ipairs(tracks) do
					table.insert(self.ActiveTracks, {
						Data = trackData, 
						Target = target, 
						BaseProp = baseProp,
						Offset = staggerOffset
					})
				end
			end
		end
	end

	if self._eventEntries then table.clear(self._eventEntries) else self._eventEntries = {} end
	for index, instance in ipairs(self.Instances) do
		local staggerOffset = (index - 1) * self.Stagger
		table.insert(self._eventEntries, {
			Instance = instance,
			Offset = staggerOffset,
			LastLocalTime = 0
		})
	end
end

function BatchedAnimTrack:_Update(now: number)
	if self.IsDestroyed then return nil end
	if self.State == "Suspended" and not self._OneShotDirty then return nil end
	if self._OneShotDirty then self._OneShotDirty = false end

	if self.State == "Playing" and now < self.StartTime then return nil end

	local wasPlaying = self.State == "Playing"

	if self.State == "Playing" then
		local rawElapsed = now - self.CycleStartTime
		local t = rawElapsed
		local dur = self.Duration

		if rawElapsed > dur then
			if self.LoopsRemaining == -1 then
				self.CycleStartTime = now - (rawElapsed % dur)
				t = rawElapsed % dur
				self._loopedThisFrame = true
				self.Looped:Fire()
			elseif self.LoopsRemaining > 0 then
				self.LoopsRemaining -= 1
				self.CycleStartTime = now - (rawElapsed % dur)
				t = rawElapsed % dur
				self._loopedThisFrame = true
				self.Looped:Fire()
			else
				t = dur
				self.IsFinished = true
				self.State = "Paused" 
				self.Completed:Fire()
				if self.AutoDestroy then 
					self:Destroy() 
					return nil
				end
			end
		end

		if self.Speed < 0 then
			t = dur - t
			if self.IsFinished then t = 0 end
		end

		self.CurrentTime = t
	end

	local events = self.Data.Events
	if events and #events > 0 and wasPlaying then
		local animLength = self.Data.Length
		local isReverse = self.Speed < 0

		for _, entry in ipairs(self._eventEntries) do
			local rawLocalTime = self.CurrentTime - entry.Offset

			if rawLocalTime < 0 then continue end
			if isReverse and rawLocalTime > animLength then continue end
			local localTime = math.min(rawLocalTime, animLength)

			local prevLocal = entry.LastLocalTime

			if self._loopedThisFrame then
				if not isReverse then
					for _, ev in ipairs(events) do
						if ev.Time > prevLocal and ev.Time <= animLength then
							self.MarkerReached:Fire(ev.Name, ev, entry.Instance)
						end
					end
					prevLocal = -0.001
				else
					for i = #events, 1, -1 do
						local ev = events[i]
						if ev.Time < prevLocal and ev.Time >= 0 then
							self.MarkerReached:Fire(ev.Name, ev, entry.Instance)
						end
					end
					prevLocal = animLength + 0.001
				end
			end

			if not isReverse then
				for _, ev in ipairs(events) do
					if ev.Time > localTime then break end
					if ev.Time > prevLocal then
						self.MarkerReached:Fire(ev.Name, ev, entry.Instance)
					end
				end
			else
				for i = #events, 1, -1 do
					local ev = events[i]
					if ev.Time < localTime then break end
					if ev.Time < prevLocal then
						self.MarkerReached:Fire(ev.Name, ev, entry.Instance)
					end
				end
			end

			entry.LastLocalTime = localTime
		end

		self._loopedThisFrame = false
	end

		local buffer = {}
	local animLength = self.Data.Length
	local isReversed = self.Speed < 0

	for _, track in ipairs(self.ActiveTracks) do
		local localTime = self.CurrentTime - track.Offset

		if localTime < 0 then
			localTime = 0
		end

		local val
		if localTime > animLength then
			val = Evaluator.getValueAtTime(track.Data.Keyframes, animLength, isReversed)
		else
			val = Evaluator.getValueAtTime(track.Data.Keyframes, localTime, isReversed)
		end

		if not buffer[track.Target] then buffer[track.Target] = {} end
		local targetBuffer = buffer[track.Target]

		if track.Data.IsRelative then
			if not targetBuffer[track.BaseProp] then targetBuffer[track.BaseProp] = {} end
			table.insert(targetBuffer[track.BaseProp], {
				Type = "Relative", Value = val, SubPath = track.Data.SubPath
			})
		else
			if not targetBuffer[track.BaseProp] then targetBuffer[track.BaseProp] = {} end
			table.insert(targetBuffer[track.BaseProp], {
				Type = "Absolute", Value = val, SubPath = track.Data.SubPath
			})
		end
	end

	return buffer
end

return BatchedAnimTrack