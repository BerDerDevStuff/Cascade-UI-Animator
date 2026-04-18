local Merger = {}

function Merger.parseFullPath(fullPath: string)
	local segments = string.split(fullPath, "/")
	local propertySegment = table.remove(segments, #segments)

	local propParts = string.split(propertySegment, ".")
	local baseProperty = table.remove(propParts, 1)

	return segments, baseProperty, propParts
end

function Merger.parsePath(path: string)
	local parts = string.split(path, ".")
	local baseProperty = table.remove(parts, 1)
	return baseProperty, parts 
end

function Merger.add(base: any, delta: any)
	local t = typeof(base)
	if t == "number" then return base + delta
	elseif t == "UDim2" then return base + delta
	elseif t == "Vector2" then return base + delta
	elseif t == "Vector3" then return base + delta
	elseif t == "Color3" then
		return Color3.new(math.clamp(base.R+delta.R,0,1), math.clamp(base.G+delta.G,0,1), math.clamp(base.B+delta.B,0,1))
	elseif t == "UDim" then
		return UDim.new(base.Scale + delta.Scale, base.Offset + delta.Offset)
	end
	return base
end

function Merger.extractSub(value: any, subPath: {string}): any
	local t = typeof(value)
	if t == "Color3" then
		local k = subPath[1]
		if k == "R" then return value.R elseif k == "G" then return value.G elseif k == "B" then return value.B end
	elseif t == "Vector2" then
		local k = subPath[1]
		if k == "X" then return value.X elseif k == "Y" then return value.Y end
	elseif t == "Vector3" then
		local k = subPath[1]
		if k == "X" then return value.X elseif k == "Y" then return value.Y elseif k == "Z" then return value.Z end
	elseif t == "UDim" then
		local k = subPath[1]
		if k == "Scale" then return value.Scale elseif k == "Offset" then return value.Offset end
	elseif t == "UDim2" then
		local axis, dim = subPath[1], subPath[2]
		if axis == "X" then
			if dim == "Scale" then return value.X.Scale elseif dim == "Offset" then return value.X.Offset else return value.X end
		elseif axis == "Y" then
			if dim == "Scale" then return value.Y.Scale elseif dim == "Offset" then return value.Y.Offset else return value.Y end
		end
	end
	return value
end

function Merger.merge(currentValue: any, subPath: {string}, targetSubValue: any)
	local valueType = typeof(currentValue)

	if valueType == "Color3" then
		local key = subPath[1]
		local r = key == "R" and targetSubValue or currentValue.R
		local g = key == "G" and targetSubValue or currentValue.G
		local b = key == "B" and targetSubValue or currentValue.B
		return Color3.new(r, g, b)

	elseif valueType == "Vector2" then
		local key = subPath[1]
		local x = key == "X" and targetSubValue or currentValue.X
		local y = key == "Y" and targetSubValue or currentValue.Y
		return Vector2.new(x, y)

	elseif valueType == "Vector3" then
		local key = subPath[1]
		local x = key == "X" and targetSubValue or currentValue.X
		local y = key == "Y" and targetSubValue or currentValue.Y
		local z = key == "Z" and targetSubValue or currentValue.Z
		return Vector3.new(x, y, z)

	elseif valueType == "UDim" then
		local key = subPath[1]
		local s = key == "Scale" and targetSubValue or currentValue.Scale
		local o = key == "Offset" and targetSubValue or currentValue.Offset
		return UDim.new(s, o)

	elseif valueType == "UDim2" then
		local axis = subPath[1]
		local dim = subPath[2]

		if not dim then
			local x = (axis == "X") and targetSubValue or currentValue.X
			local y = (axis == "Y") and targetSubValue or currentValue.Y
			return UDim2.new(x.Scale, x.Offset, y.Scale, y.Offset)
		else
			local xs = (axis == "X" and dim == "Scale") and targetSubValue or currentValue.X.Scale
			local xo = (axis == "X" and dim == "Offset") and targetSubValue or currentValue.X.Offset

			local ys = (axis == "Y" and dim == "Scale") and targetSubValue or currentValue.Y.Scale
			local yo = (axis == "Y" and dim == "Offset") and targetSubValue or currentValue.Y.Offset

			return UDim2.new(xs, xo, ys, yo)
		end
	end

	return targetSubValue
end

return Merger