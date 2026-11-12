--!native
--!optimize 2

local TweenService = game:GetService("TweenService")

local QUAD = Enum.EasingStyle.Quad
local IN = Enum.EasingDirection.In
local OUT = Enum.EasingDirection.Out
local IN_OUT = Enum.EasingDirection.InOut

local Evaluator = {}

local function identity(t: number): number
	return t
end

local function directions(easeIn: (number) -> number)
	return {
		[IN] = easeIn,
		[OUT] = function(t: number): number
			return 1 - easeIn(1 - t)
		end,
		[IN_OUT] = function(t: number): number
			if t < 0.5 then
				return easeIn(2 * t) / 2
			end
			return 1 - easeIn(2 - 2 * t) / 2
		end,
	}
end

local function bounceIn(t: number): number
	t = 1 - t
	local v
	if t < 1 / 2.75 then
		v = 7.5625 * t * t
	elseif t < 2 / 2.75 then
		t -= 1.5 / 2.75
		v = 7.5625 * t * t + 0.75
	elseif t < 2.5 / 2.75 then
		t -= 2.25 / 2.75
		v = 7.5625 * t * t + 0.9375
	else
		t -= 2.625 / 2.75
		v = 7.5625 * t * t + 0.984375
	end
	return 1 - v
end

-- Luau forms of TweenService's curves for the runtime path. Each matches GetValue on every
-- direction within GetValue's own float32 precision (max 3e-7, Circular 2e-6). Elastic and
-- anything unknown still go through GetValue.
local CURVES = {
	[Enum.EasingStyle.Linear] = { [IN] = identity, [OUT] = identity, [IN_OUT] = identity },
	[Enum.EasingStyle.Quad] = directions(function(t) return t * t end),
	[Enum.EasingStyle.Cubic] = directions(function(t) return t * t * t end),
	[Enum.EasingStyle.Quart] = directions(function(t) return t * t * t * t end),
	[Enum.EasingStyle.Quint] = directions(function(t) return t * t * t * t * t end),
	[Enum.EasingStyle.Sine] = directions(function(t) return 1 - math.cos(t * math.pi / 2) end),
	[Enum.EasingStyle.Circular] = directions(function(t) return 1 - math.sqrt(1 - t * t) end),
	[Enum.EasingStyle.Exponential] = directions(function(t) return if t == 0 then 0 else 2 ^ (10 * t - 10) end),
	[Enum.EasingStyle.Back] = directions(function(t) return t * t * (2.70158 * t - 1.70158) end),
	[Enum.EasingStyle.Bounce] = directions(bounceIn),
}
Evaluator.Curves = CURVES

local function lerpNumber(a, b, t)
	return a + (b - a) * t
end

local function lerpUDim2(a, b, t)
	return a:Lerp(b, t)
end

local function lerpVector3(a, b, t)
	return a:Lerp(b, t)
end

local function lerpVector2(a, b, t)
	return a:Lerp(b, t)
end

local function lerpColor3(a, b, t)
	return a:Lerp(b, t)
end

local function lerpUDim(a, b, t)
	local startS, startO = a.Scale, a.Offset
	local endS, endO = b.Scale, b.Offset
	return UDim.new(
		startS + (endS - startS) * t,
		startO + (endO - startO) * t
	)
end

function Evaluator.getValueAtTime(keyframes: {any}, time: number, isReversed: boolean?)
	if #keyframes == 0 then return nil end

	if time <= keyframes[1].Time then
		return keyframes[1].Value
	end

	if time >= keyframes[#keyframes].Time then
		return keyframes[#keyframes].Value
	end

	for i = 1, #keyframes - 1 do
		local k1 = keyframes[i]
		local k2 = keyframes[i+1]

		if time >= k1.Time and time < k2.Time then
			local duration = k2.Time - k1.Time
			if duration == 0 then return k1.Value end

			-- Step: forward holds k1 until k2.Time; reverse holds k2 until k1.Time
			if k2.Easing == "Step" then
				return if isReversed then k2.Value else k1.Value
			end

			local elapsed = time - k1.Time
			local alpha = elapsed / duration

			local easedAlpha = TweenService:GetValue(alpha, k2.Easing or Enum.EasingStyle.Quad, k2.Direction or Enum.EasingDirection.Out)

			local v1, v2 = k1.Value, k2.Value
			local typeV = typeof(v1)

			if typeV == "number" then return lerpNumber(v1, v2, easedAlpha)
			elseif typeV == "UDim2" then return lerpUDim2(v1, v2, easedAlpha)
			elseif typeV == "Vector2" then return lerpVector2(v1, v2, easedAlpha)
			elseif typeV == "Vector3" then return lerpVector3(v1, v2, easedAlpha)
			elseif typeV == "Color3" then return lerpColor3(v1, v2, easedAlpha)
			elseif typeV == "UDim" then return lerpUDim(v1, v2, easedAlpha)
			else return v1 
			end
		end
	end

	return keyframes[#keyframes].Value
end

-- getValueAtTime for a runtime channel ({Keyframes, Seg, T1, T2, K1, K2, Ease}). The channel
-- caches the segment of the last call and its curve: while time stays strictly inside it nothing
-- is searched, and otherwise the search walks from that segment instead of the first keyframe.
function Evaluator.sample(channel: any, time: number, isReversed: boolean?): any
	local k1, k2
	if time > channel.T1 and time < channel.T2 then
		k1, k2 = channel.K1, channel.K2
	else
		local keyframes = channel.Keyframes
		local n = #keyframes
		if n == 0 then return nil end
		k1 = keyframes[1]
		if time <= k1.Time then return k1.Value end
		local last = keyframes[n]
		if time >= last.Time or time ~= time then return last.Value end

		-- Segment i: keyframes[i].Time <= time < keyframes[i + 1].Time (n >= 2 here).
		local i = channel.Seg
		if i >= n then i = n - 1 end
		k1 = keyframes[i]
		if time < k1.Time then
			repeat
				i -= 1
				k1 = keyframes[i]
			until time >= k1.Time
			k2 = keyframes[i + 1]
		else
			k2 = keyframes[i + 1]
			while time >= k2.Time do
				i += 1
				k1 = k2
				k2 = keyframes[i + 1]
			end
		end
		channel.Seg = i
		channel.T1, channel.T2, channel.K1, channel.K2 = k1.Time, k2.Time, k1, k2
		local curves = CURVES[k2.Easing or QUAD]
		channel.Ease = curves and curves[k2.Direction or OUT]
	end

	-- Step: forward holds k1 until k2.Time; reverse holds k2 until k1.Time
	local easing = k2.Easing
	if easing == "Step" then
		return if isReversed then k2.Value else k1.Value
	end

	local t1 = channel.T1
	local alpha = (time - t1) / (channel.T2 - t1)
	local curve = channel.Ease
	if curve then
		alpha = curve(alpha)
	else
		alpha = TweenService:GetValue(alpha, easing or QUAD, k2.Direction or OUT)
	end

	local v1 = k1.Value
	local kind = typeof(v1)
	if kind == "number" then
		return v1 + (k2.Value - v1) * alpha
	elseif kind == "UDim2" or kind == "Color3" or kind == "Vector2" or kind == "Vector3" then
		return v1:Lerp(k2.Value, alpha)
	elseif kind == "UDim" then
		local v2 = k2.Value
		return UDim.new(v1.Scale + (v2.Scale - v1.Scale) * alpha, v1.Offset + (v2.Offset - v1.Offset) * alpha)
	end
	return v1
end

-- Event cursor for the track modules: the index of the first event after `prev` (forward) or of the
-- last one before it (reverse) in a list sorted by Time. `hint` is the previous answer; it is
-- checked in O(1) and the list is searched again only after the playhead jumped (PER7).
function Evaluator.eventCursor(events: {any}, prev: number, reverse: boolean, hint: number?): number
	local n = #events
	if reverse then
		if hint and hint >= 0 and hint <= n and (hint == 0 or events[hint].Time < prev) and (hint == n or events[hint + 1].Time >= prev) then
			return hint
		end
		local i = n
		while i > 0 and events[i].Time >= prev do i -= 1 end
		return i
	end
	if hint and hint >= 1 and hint <= n + 1 and (hint == 1 or events[hint - 1].Time <= prev) and (hint > n or events[hint].Time > prev) then
		return hint
	end
	local i = 1
	while i <= n and events[i].Time <= prev do i += 1 end
	return i
end

return Evaluator