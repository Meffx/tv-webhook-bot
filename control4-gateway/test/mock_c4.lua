-- Minimal stand-in for the Control4 DriverWorks runtime, used by run_test.py.
-- Network bindings are bridged to real TCP/TLS sockets by the Python side.
Properties = {
	["Broker Address"] = "127.0.0.1", ["Port"] = "18884", ["Encryption"] = "TLS", ["Verify Certificate"] = "On", ["Username"] = "unit101",
	["Password"] = "secret", ["Unit ID"] = "unit 101", ["Device Filter"] = "", ["Debug"] = "Off",
}
Mock = { sent = {}, listeners = {}, timers = {}, props = {}, net = nil }

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
function C4:CreateNetworkConnection(binding, host, kind) Mock.net = { binding = binding, host = host, kind = kind } end
function C4:NetPortOptions(binding, port, kind, options) Mock.net.port, Mock.net.portKind, Mock.net.options = port, kind, options end
function C4:NetConnect(binding, port) py_net_connect(binding, port, Mock.net.host, Mock.net.kind, Mock.net.options) end
function C4:NetDisconnect(binding, port) py_net_disconnect(binding, port) end
function C4:SendToNetwork(binding, port, data) py_net_send(binding, port, data) end
