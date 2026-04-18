--!native
--!optimize 2

local Types = require(script.Parent.Types)
local Signal = require(script.Parent.Signal)
local Evaluator = require(script.Parent.Evaluator)

local AnimTrack = {}
AnimTrack.__index = AnimTrack

local function resolveInstance(root: Instance, pathParts: {string}): Instance?
	local current = root
	for _, childName in ipairs(pathParts) do
		if current then current = current:FindFirstChild(childName) end
	end
	return current
end

function AnimTrack.new(instance: Instance, config: Types.AnimationConfig | Types.ProcessedAnimation, options: Types.TrackOptions)
	local self = setmetatable({}, AnimTrack)

	self.Instance = instance
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

	self.AutoDestroy = options.DeleteOnComplete or false
	self.IsFinished = false
	self.IsDestroyed = false 

	self.Completed = Signal.new()
	self.Looped = Signal.new()
	self.Cancelled = Signal.new()
	self.MarkerReached = Signal.new()

	self.ActiveTracks = {}
	self.LoopsRemaining = 0

	self._lastUpdateTime = 0
	self._loopedThisFrame = false
	self._scrubReversed = false

	if self.Data then
		self.Duration = self.Data.Length

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

function AnimTrack:Play()
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
	self._lastUpdateTime = self.CurrentTime + (self.Speed < 0 and 0.0001 or -0.0001)
end

function AnimTrack:Pause()
	if self.State == "Paused" then return end
	self.State = "Paused"
end

function AnimTrack:Suspend()
	self.State = "Suspended"
end

function AnimTrack:Stop()
	if self.Options.ResetToStart then
		self:Scrub(0)
	end
	
	self.State = "Suspended"
	self.CurrentTime = 0
	self.IsFinished = false
	self._lastUpdateTime = 0
	self._loopedThisFrame = false
	self.Cancelled:Fire()
	if self.AutoDestroy then
		self:Destroy()
	end
end

function AnimTrack:Scrub(time: number)
	local prevTime = self.CurrentTime
	self.CurrentTime = math.clamp(time, 0, self.Duration)
	self._scrubReversed = self.CurrentTime < prevTime
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

function AnimTrack:SetSpeed(speed: number)
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

function AnimTrack:SetLoop(loop: boolean | number)
	if type(loop) == "boolean" then self.LoopsRemaining = loop and -1 or 0
	elseif type(loop) == "number" then self.LoopsRemaining = math.floor(loop) end
end

function AnimTrack:InvalidateBaseState()
	self:_BuildTracks()
end

function AnimTrack:Destroy()
	if self.IsDestroyed then return end
	self.IsDestroyed = true 
	self.State = "Suspended"
	self.Completed:Destroy()
	self.Looped:Destroy()
	self.Cancelled:Destroy()
	self.MarkerReached:Destroy()
end

function AnimTrack:Contains(instance: Instance): boolean
	return self.Instance == instance
end

function AnimTrack:IsValid(): boolean
	return self.Instance and self.Instance.Parent ~= nil
end

function AnimTrack:Prune(instance: Instance)
	if self.Instance == instance then
		self.Instance = nil
		self:Destroy()
	end
end

function AnimTrack:_BuildTracks()
	table.clear(self.ActiveTracks)
	if not self.Data then return end

	for groupKey, tracks in pairs(self.Data.PropertyGroups) do
		local template = tracks[1]
		local target = resolveInstance(self.Instance, template.InstancePath)
		if not target then
			warn("[Cascade] resolveInstance failed for path:", table.concat(template.InstancePath, "/"), "from root:", self.Instance and self.Instance:GetFullName() or "nil")
		end
		if target then
			local splitKey = string.split(groupKey, "|")
			local baseProp = splitKey[#splitKey]

			for _, trackData in ipairs(tracks) do
				table.insert(self.ActiveTracks, {
					Data = trackData, Target = target, BaseProp = baseProp
				})
			end
		end
	end
end

function AnimTrack:_Update(now: number)
	if self.IsDestroyed then return nil end
	if self.State == "Suspended" and not self._OneShotDirty then return nil end

	if self._OneShotDirty then
		self._OneShotDirty = false
	end

	if self.State == "Playing" and now < self.StartTime then
		return nil
	end

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

	-- Fire MarkerReached events
	local events = self.Data.Events
	if events and #events > 0 and wasPlaying then
		local prevTime = self._lastUpdateTime
		local curTime = self.CurrentTime

		if self._loopedThisFrame then
			for _, ev in ipairs(events) do
				if ev.Time > prevTime and ev.Time <= self.Duration then
					self.MarkerReached:Fire(ev.Name, ev)
				end
			end
			prevTime = -0.001
			self._loopedThisFrame = false
		end

		if self.Speed >= 0 then
			for _, ev in ipairs(events) do
				if ev.Time > curTime then break end
				if ev.Time > prevTime then
					self.MarkerReached:Fire(ev.Name, ev)
				end
			end
		else
			for i = #events, 1, -1 do
				local ev = events[i]
				if ev.Time < curTime then break end
				if ev.Time < prevTime then
					self.MarkerReached:Fire(ev.Name, ev)
				end
			end
		end

		self._lastUpdateTime = curTime
	end

		local buffer = {}
	local isReversed = if self.State == "Playing" then self.Speed < 0 else self._scrubReversed
	for _, track in ipairs(self.ActiveTracks) do
		local val = Evaluator.getValueAtTime(track.Data.Keyframes, self.CurrentTime, isReversed)
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

return AnimTrack