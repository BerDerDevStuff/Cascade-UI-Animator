--!native
--!optimize 2

local TweenService = game:GetService("TweenService")

local Evaluator = {}

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

return Evaluator