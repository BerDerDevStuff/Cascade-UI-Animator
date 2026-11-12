--!native
--!optimize 2

local Types = require(script.Parent.Types)
local Signal = require(script.Parent.Signal)
local Evaluator = require(script.Parent.Evaluator)

local sample = Evaluator.sample
local eventCursor = Evaluator.eventCursor

local AnimTrack = {}
AnimTrack.__index = AnimTrack

-- Event cursors sit this far before (forward) or after (reverse) the playhead, so an event placed
-- exactly on the start time fires on the first frame.
local EPSILON = 0.0001
-- Loop wraps handled one by one, with their events, in a single frame; further wraps are collapsed.
local MAX_WRAPS = 64

local function resolveInstance(root: Instance, pathParts: {string}): Instance?
	local current = root
	for _, childName in ipairs(pathParts) do
		if current then current = current:FindFirstChild(childName) end
	end
	return current
end

function AnimTrack.new(instance: Instance, config: Types.AnimationConfig | Types.ProcessedAnimation, options: Types.TrackOptions)
	local self = setmetatable({}, AnimTrack)
	options = options or {}

	self.Instance = instance
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

	self.AutoDestroy = options.DeleteOnComplete or false
	self.IsFinished = false
	self.IsDestroyed = false

	self.Completed = Signal.new()
	self.Looped = Signal.new()
	self.Cancelled = Signal.new()
	self.MarkerReached = Signal.new()

	self.ActiveTracks = {}
	self._BuildId = 0
	self.LoopsRemaining = 0

	self._lastUpdateTime = 0
	self._lastNow = 0
	self._gen = 0
	self._scrubReversed = false
	self._rewindOnPlay = false
	-- Read and cleared by AnimationService before the next frame (relative base capture).
	self._NewRun = false
	self._Rewound = false
	-- Read by AnimationService: a replay of a run in progress, and a Reset due after a finish.
	self._Takeover = false
	self._ResetPending = false
	self._DelayLeft = nil
	self._evCursor = nil

	if self.Data then
		self.Duration = self.Data.Length

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

-- Starts playback. A resume keeps the playhead and the event cursor. A new run applies Delay,
-- optionally rewinds to the start of the current direction and re-primes the event cursor.
function AnimTrack:_Begin(isResume: boolean, rewind: boolean?)
	local now = os.clock()
	if isResume then
		-- A pause during the delay keeps the rest of the delay (COR7).
		self.StartTime = now + (self._DelayLeft or 0)
	else
		local reverse = self.Speed < 0
		rewind = rewind or self._rewindOnPlay
		self._rewindOnPlay = false
		if rewind then
			self.CurrentTime = if reverse then self.Duration else 0
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
		self._lastUpdateTime = if reverse then self.CurrentTime + EPSILON else self.CurrentTime - EPSILON
	end
	self._DelayLeft = nil
	self._lastNow = self.StartTime
	self.State = "Playing"
	self.IsFinished = false
	self:_Wake()
end

-- Asks AnimationService to step this track again (set by the service; dormant tracks are skipped).
function AnimTrack:_Wake()
	local waker = self._Waker
	if waker then waker(self) end
end

function AnimTrack:Play()
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

function AnimTrack:Pause()
	if self.State == "Playing" then
		self.State = "Paused"
		local left = self.StartTime - os.clock()
		self._DelayLeft = if left > 0 then left else nil
	end
end

function AnimTrack:Suspend()
	self.State = "Suspended"
end

function AnimTrack:Stop()
	if self.IsDestroyed then return end
	self.State = "Suspended"
	self.IsFinished = false
	self._gen += 1
	if self.Options.ResetToStart then
		self:Scrub(0)
	else
		self.CurrentTime = if self.Speed < 0 then self.Duration else 0
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

function AnimTrack:Scrub(time: number)
	local prevTime = self.CurrentTime
	self.CurrentTime = math.clamp(time, 0, self.Duration)
	self._scrubReversed = self.CurrentTime < prevTime
	self._OneShotDirty = true
	self.IsFinished = false
	self._rewindOnPlay = false
	self._lastUpdateTime = if self.Speed < 0 then self.CurrentTime + EPSILON else self.CurrentTime - EPSILON
	self:_Wake()
end

-- The sign is the direction, the magnitude a time scale; 0 holds the playhead.
function AnimTrack:SetSpeed(speed: number)
	local held = self.Speed == 0 and self.State == "Playing"
	self.Speed = speed
	if held and speed ~= 0 then
		-- A held track sleeps (PER8): wake it without counting the hold as elapsed time.
		local now = os.clock()
		if now > self._lastNow then self._lastNow = now end
		self:_Wake()
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
	self._gen += 1
	self.State = "Suspended"
	self.Completed:Destroy()
	self.Looped:Destroy()
	self.Cancelled:Destroy()
	self.MarkerReached:Destroy()
	self:_Wake()
end

function AnimTrack:Contains(instance: Instance): boolean
	return not self.IsDestroyed and self.Instance == instance
end

function AnimTrack:IsValid(): boolean
	return not self.IsDestroyed and self.Instance ~= nil and self.Instance.Parent ~= nil
end

function AnimTrack:Prune(instance: Instance)
	if self.Instance == instance then
		self.Instance = nil
		self:Destroy()
	end
end

-- One channel per animated path, evaluated in place each frame (Value) and bound to its property
-- slot by AnimationService.
function AnimTrack:_BuildTracks()
	table.clear(self.ActiveTracks)
	self._BuildId += 1
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
					Data = trackData, Target = target, BaseProp = baseProp, Root = self.Instance,
					Keyframes = trackData.Keyframes, SubPath = trackData.SubPath, HasSub = #trackData.SubPath > 0,
					IsRelative = not not trackData.IsRelative, Seg = 1, T1 = math.huge, T2 = 0, K1 = nil, K2 = nil,
					Ease = nil, Value = nil, Held = nil, Slot = nil,
				})
			end
		end
	end
end

-- Fires the markers between the event cursor and curTime. Returns false when a handler started a
-- new run, stopped or destroyed the track, so the caller abandons the frame.
function AnimTrack:_FireEvents(events: {any}, curTime: number, reverse: boolean, gen: number): boolean
	local prevTime = self._lastUpdateTime
	self._lastUpdateTime = curTime
	local i = eventCursor(events, prevTime, reverse, self._evCursor)
	if reverse then
		while i > 0 do
			local ev = events[i]
			if ev.Time < curTime then break end
			i -= 1
			self.MarkerReached:Fire(ev.Name, ev)
			if self._gen ~= gen then return false end
		end
	else
		local n = #events
		while i <= n do
			local ev = events[i]
			if ev.Time > curTime then break end
			i += 1
			self.MarkerReached:Fire(ev.Name, ev)
			if self._gen ~= gen then return false end
		end
	end
	self._evCursor = i
	return true
end

-- Evaluates every channel at CurrentTime into its Value field.
function AnimTrack:_Evaluate()
	local isReversed = if self.State == "Playing" then self.Speed < 0 else self._scrubReversed
	local time = self.CurrentTime
	for _, ch in self.ActiveTracks do
		ch.Value = sample(ch, time, isReversed)
	end
end

function AnimTrack:_Update(now: number)
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
			-- Close the cycle: its remaining events fire before Looped / Completed.
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
			self._lastUpdateTime = if reverse then dur + EPSILON else -EPSILON
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
		-- Write the end value this frame, then go dormant: no writes until played or scrubbed again.
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

return AnimTrack