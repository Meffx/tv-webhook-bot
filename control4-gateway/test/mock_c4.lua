-- Minimal stand-in for the Control4 DriverWorks runtime, used by run_test.py.
Properties = {
	["Broker Address"] = "10.0.0.5", ["Port"] = "1883", ["Username"] = "unit101",
	["Password"] = "secret", ["Unit ID"] = "unit 101", ["Device Filter"] = "", ["Debug"] = "Off",
}
Mock = { published = {}, sent = {}, listeners = {}, timers = {}, props = {}, subs = {}, client = nil }

local variables = {
	[41] = { ["1000"] = { name = "LIGHT_STATE", value = "0" }, ["1001"] = { name = "LIGHT_LEVEL", value = "0" } },
	[52] = { ["1100"] = { name = "TEMPERATURE_C", value = "21.5" } },
}

C4 = {}
function C4:UpdateProperty(name, value) Mock.props[name] = value end
function C4:GetUniqueMAC() return "000FFF112233" end
function C4:GetDeviceID() return 99 end
function C4:JsonEncode(value) return py_json_encode(value) end
function C4:JsonDecode(text) return py_json_decode(text) end
function C4:GetDevices()
	return {
		[41] = { driverFileName = "light_v2.c4i", deviceName = "Kitchen Dimmer", roomId = "16", roomName = "Kitchen" },
		[52] = { driverFileName = "thermostatV2.c4i", deviceName = "Thermostat", roomId = "16", roomName = "Kitchen" },
		[60] = { driverFileName = "novars.c4z", deviceName = "No Vars", roomId = "16", roomName = "Kitchen" },
		[99] = { driverFileName = "building_gateway.c4z", deviceName = "Gateway", roomId = "16", roomName = "Kitchen" },
	}
end
function C4:GetDeviceVariables(id) return variables[id] or {} end
function C4:RegisterVariableListener(dev, var)
	Mock.listeners[dev .. "/" .. var] = true
	OnWatchedVariableChanged(dev, var, variables[dev][tostring(var)].value)
end
function C4:UnregisterVariableListener(dev, var) Mock.listeners[dev .. "/" .. var] = nil end
function C4:SendToDevice(dev, cmd, params) table.insert(Mock.sent, { dev = dev, cmd = cmd, params = params }) end
function C4:SetTimer(delay, fn)
	local t = { delay = delay, fn = fn, cancelled = false }
	function t:Cancel() self.cancelled = true end
	table.insert(Mock.timers, t)
	return t
end
function C4:MQTT(clientId)
	local c = { clientId = clientId, cb = {}, disconnected = false }
	function c:SetUsernameAndPassword(u, p) self.user, self.pass = u, p; return 0 end
	function c:SetWill(t, p, q, r) self.will = { t, p, q, r }; return 0 end
	function c:OnConnect(f) self.cb.connect = f end
	function c:OnDisconnect(f) self.cb.disconnect = f end
	function c:OnMessage(f) self.cb.message = f end
	function c:Connect(h, p, k) self.host, self.port = h, p; return 0 end
	function c:Disconnect() self.disconnected = true; return 0 end
	function c:Subscribe(t, q) Mock.subs[t] = true; return 0, 1 end
	function c:Publish(t, p, q, r) table.insert(Mock.published, { topic = t, payload = p, retain = r }); return 0, #Mock.published end
	Mock.client = c
	return c
end
