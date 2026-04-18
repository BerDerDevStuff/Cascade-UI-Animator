--!native
--!optimize 2

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean
}

export type Signal = {
	Connect: (self: Signal, callback: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	Destroy: (self: Signal) -> (),
	Wait: (self: Signal) -> ...any
}

function Signal.new(): Signal
	local self = setmetatable({ _head = nil }, Signal)
	return self :: any
end

function Signal:Connect(callback)
	local node = {
		Connected = true,
		_signal = self,
		_callback = callback,
		_next = self._head,
		_prev = nil,
	}

	if self._head then
		self._head._prev = node
	end
	self._head = node

	return {
		Disconnect = function()
			if not node.Connected then return end
			node.Connected = false

			if node._signal._head == node then
				node._signal._head = node._next
			end
			if node._prev then
				node._prev._next = node._next
			end
			if node._next then
				node._next._prev = node._prev
			end

			node._signal = nil
			node._callback = nil
			node._prev = nil 
			node._next = nil
		end
	}
end

function Signal:Fire(...)
	local node = self._head
	while node do
		local nextNode = node._next 
		if node.Connected then
			task.spawn(node._callback, ...)
		end
		node = nextNode
	end
end

function Signal:Destroy()
	local node = self._head
	while node do
		local nextNode = node._next
		node.Connected = false
		node._signal = nil
		node = nextNode
	end
	self._head = nil
end

function Signal:Wait()
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection.Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

return Signal
