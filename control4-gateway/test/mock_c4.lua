-- Minimal stand-in for the Control4 DriverWorks runtime, used by run_test.py.
-- The TCP client is bridged to a real socket by the Python side.
Properties = {
	["Broker Address"] = "127.0.0.1", ["Port"] = "18883", ["Username"] = "unit101",
	["Password"] = "secret", ["Unit ID"] = "unit 101", ["Device Filter"] = "", ["Debug"] = "Off",
}
Mock = { sent = {}, listeners = {}, timers = {}, props = {}, clients = {} }

local variables = {
	[41] = { ["1000"] = { name = "LIGHT_STATE", value = "0" }, ["1001"] = { name = "LIGHT_LEVEL", value = "0" } },
	[52] = { ["1100"] = { name = "TEMPERATURE_C", value = "21.5" } },
}

C4 = {}
function C4:UpdateProperty(name, value) Mock.props[name] = value end
function C4:GetUniqueMAC() return "000FFF112233" end
function C4:GetDeviceID() return 99 end
function C4:GetDevices()
	return {
		[41] = { driverFileName = "light_v2.c4i", deviceName = "Kitchen \"Dimmer\"", roomId = "16", roomName = "Kuchnia ąę" },
		[52] = { driverFileName = "thermostatV2.c4i", deviceName = "Thermostat", roomId = "16", roomName = "Kuchnia ąę" },
		[60] = { driverFileName = "novars.c4z", deviceName = "No Vars", roomId = "16", roomName = "Kuchnia ąę" },
		[99] = { driverFileName = "building_gateway.c4z", deviceName = "Gateway", roomId = "16", roomName = "Kuchnia ąę" },
	}
end
function C4:GetDeviceVariables(id) return variables[id] or {} end
function C4:RegisterVariableListener(dev, var)
	Mock.listeners[dev .. "/" .. var] = true
	OnWatchedVariableChanged(dev, var, variables[dev][tostring(var)].value)
end
function C4:UnregisterVariableListener(dev, var) Mock.listeners[dev .. "/" .. var] = nil end
function C4:SendToDevice(dev, cmd, params) table.insert(Mock.sent, { dev = dev, cmd = cmd, params = params }) end
function C4:SetTimer(delay, fn, repeating)
	local t = { delay = delay, fn = fn, repeating = repeating, cancelled = false }
	function t:Cancel() self.cancelled = true end
	table.insert(Mock.timers, t)
	return t
end
function C4:CreateTCPClient()
	local c = { cb = {}, wantRead = false, closed = false }
	c.index = #Mock.clients + 1
	function c:OnConnect(f) self.cb.connect = f; return self end
	function c:OnRead(f) self.cb.read = f; return self end
	function c:OnDisconnect(f) self.cb.disconnect = f; return self end
	function c:OnError(f) self.cb.error = f; return self end
	function c:Connect(host, port) py_tcp_connect(self.index, host, port); return self end
	function c:Write(data) py_tcp_write(self.index, data); return self end
	function c:ReadUpTo(max) self.wantRead = true; return self end
	function c:Close(flush) self.closed = true; py_tcp_close(self.index) end
	table.insert(Mock.clients, c)
	return c
end
