-- Building Gateway
-- Mirrors the state of Control4 devices in this project to an MQTT broker
-- and executes commands received from it.
--
-- Topics (prefix: c4/<Unit ID>/):
--   status                    "online" / "offline" (retained, last will)
--   devices                   JSON list of mirrored devices and their variables (retained)
--   state/<deviceId>/<varId>  current variable value (retained)
--   cmd                       incoming commands (JSON)
--   cmd/result                result of each command (JSON)

DRIVER_VERSION = "0.1.0"

local RECONNECT_MIN_MS = 2000
local RECONNECT_MAX_MS = 60000

local mqtt = nil
local generation = 0 -- incremented on every connect; stale callbacks are ignored
local connected = false
local reconnectTimer = nil
local reconnectDelay = RECONNECT_MIN_MS

local devices = {} -- [deviceId] = { name, driver, roomId, room, variables = { [varId] = name } }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function prop(name)
	return (Properties and Properties[name]) or ""
end

local function log(msg)
	if prop("Debug") == "On" then
		print("[gateway] " .. tostring(msg))
	end
end

local function setStatus(text)
	log("status: " .. text)
	C4:UpdateProperty("Status", text)
end

local function unitId()
	local id = prop("Unit ID")
	if id == "" then
		id = C4:GetUniqueMAC() or "unknown"
	end
	-- MQTT topic levels must not contain separators or wildcards
	return (string.gsub(id, "[/#+%s]", "_"))
end

local function topic(suffix)
	return "c4/" .. unitId() .. "/" .. suffix
end

local function publish(suffix, payload, retain)
	if not (mqtt and connected) then
		return false
	end
	local rc, _, err = mqtt:Publish(topic(suffix), payload, 1, retain == true)
	if rc ~= 0 then
		log("publish to " .. suffix .. " failed: " .. tostring(err or rc))
		return false
	end
	return true
end

local function encode(value)
	local ok, json, err = pcall(function()
		return C4:JsonEncode(value)
	end)
	if ok and json then
		return json
	end
	log("JSON encode failed: " .. tostring(err or json))
	return nil
end

---------------------------------------------------------------------------
-- Device discovery and variable mirroring
---------------------------------------------------------------------------

local function matchesFilter(driverFileName)
	local filter = prop("Device Filter")
	if filter == "" then
		return true
	end
	local name = string.lower(driverFileName or "")
	for word in string.gmatch(filter, "[^,%s]+") do
		if string.find(name, string.lower(word), 1, true) then
			return true
		end
	end
	return false
end

local function unwatchAll()
	for deviceId, device in pairs(devices) do
		for varId in pairs(device.variables) do
			C4:UnregisterVariableListener(deviceId, varId)
		end
	end
	devices = {}
end

local function readVariables(deviceId)
	local result = {}
	local ok, vars = pcall(function()
		return C4:GetDeviceVariables(deviceId)
	end)
	if not ok or type(vars) ~= "table" then
		return result
	end
	for key, var in pairs(vars) do
		if type(var) == "table" then
			local varId = tonumber(key) or tonumber(var.id)
			if varId then
				result[varId] = tostring(var.name or varId)
			end
		end
	end
	return result
end

-- Finds devices, publishes the device list and starts watching their variables.
-- Registering a listener makes Director call OnWatchedVariableChanged right
-- away, which publishes the initial state of every variable.
local function rescan()
	unwatchAll()
	local selfId = C4:GetDeviceID()
	local found = C4:GetDevices({}) or {}
	local list = {}
	local count = 0

	for id, info in pairs(found) do
		local deviceId = tonumber(id)
		if deviceId and deviceId ~= selfId and type(info) == "table" and matchesFilter(info.driverFileName) then
			local variables = readVariables(deviceId)
			if next(variables) ~= nil then
				devices[deviceId] = {
					name = info.deviceName,
					driver = info.driverFileName,
					roomId = info.roomId,
					room = info.roomName,
					variables = variables,
				}
				local varList = {}
				for varId, varName in pairs(variables) do
					varList[tostring(varId)] = varName
				end
				list[tostring(deviceId)] = {
					name = info.deviceName or "",
					driver = info.driverFileName or "",
					roomId = tostring(info.roomId or ""),
					room = info.roomName or "",
					variables = varList,
				}
				count = count + 1
			end
		end
	end

	local json = encode({ version = DRIVER_VERSION, devices = list })
	if json then
		publish("devices", json, true)
	end

	for deviceId, device in pairs(devices) do
		for varId in pairs(device.variables) do
			C4:RegisterVariableListener(deviceId, varId)
		end
	end

	log("mirroring " .. count .. " devices")
	return count
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
	local deviceId, varId = tonumber(idDevice), tonumber(idVariable)
	if not (deviceId and varId and devices[deviceId]) then
		return
	end
	publish("state/" .. deviceId .. "/" .. varId, tostring(strValue or ""), true)
end

---------------------------------------------------------------------------
-- Incoming commands
---------------------------------------------------------------------------

-- Payload: {"id":"abc","device":41,"command":"RAMP_TO_LEVEL","params":{"LEVEL":60,"TIME":1000}}
-- Gateway commands (no "device"): {"command":"RESCAN"}
local function handleCommand(payload)
	local ok, msg = pcall(function()
		return C4:JsonDecode(payload)
	end)
	if not ok or type(msg) ~= "table" then
		return nil, "invalid JSON"
	end
	local command = msg.command
	if type(command) ~= "string" or command == "" then
		return msg.id, "missing command"
	end

	if msg.device == nil then
		if command == "RESCAN" then
			rescan()
			return msg.id, nil
		end
		return msg.id, "unknown gateway command"
	end

	local deviceId = tonumber(msg.device)
	if not (deviceId and devices[deviceId]) then
		return msg.id, "unknown device"
	end

	local params = {}
	if type(msg.params) == "table" then
		for key, value in pairs(msg.params) do
			local kind = type(value)
			if kind == "string" or kind == "number" or kind == "boolean" then
				params[tostring(key)] = value
			end
		end
	end

	log("command " .. command .. " -> device " .. deviceId)
	C4:SendToDevice(deviceId, command, params)
	return msg.id, nil
end

local function onMessage(_, _, msgTopic, payload)
	if msgTopic ~= topic("cmd") then
		return
	end
	local id, err = handleCommand(payload or "")
	local result = { ok = (err == nil) }
	if id ~= nil then
		result.id = tostring(id)
	end
	if err then
		result.error = err
		log("command rejected: " .. err)
	end
	local json = encode(result)
	if json then
		publish("cmd/result", json, false)
	end
end

---------------------------------------------------------------------------
-- MQTT connection
---------------------------------------------------------------------------

local connect -- forward declaration

local function cancelReconnect()
	if reconnectTimer then
		reconnectTimer:Cancel()
		reconnectTimer = nil
	end
end

local function scheduleReconnect()
	cancelReconnect()
	local delay = reconnectDelay
	reconnectDelay = math.min(reconnectDelay * 2, RECONNECT_MAX_MS)
	log("reconnecting in " .. (delay / 1000) .. " s")
	reconnectTimer = C4:SetTimer(delay, function()
		reconnectTimer = nil
		connect()
	end)
end

local function dropClient()
	generation = generation + 1
	connected = false
	if mqtt then
		local old = mqtt
		mqtt = nil
		pcall(function()
			old:Disconnect()
		end)
	end
end

connect = function()
	cancelReconnect()
	dropClient()

	local host = prop("Broker Address")
	if host == "" then
		setStatus("Not configured: set Broker Address")
		return
	end

	local hasApi = pcall(function()
		return C4.MQTT ~= nil or error("missing")
	end)
	if not hasApi then
		setStatus("MQTT API not available on this OS version")
		return
	end

	local myGeneration = generation
	local client = C4:MQTT("c4-gateway-" .. unitId())
	mqtt = client

	local username = prop("Username")
	if username ~= "" then
		client:SetUsernameAndPassword(username, prop("Password"))
	end
	client:SetWill(topic("status"), "offline", 1, true)

	client:OnConnect(function(_, reasonCode, _, message)
		if myGeneration ~= generation then
			return
		end
		if reasonCode ~= 0 then
			setStatus("Connection refused: " .. tostring(message or reasonCode))
			scheduleReconnect()
			return
		end
		connected = true
		reconnectDelay = RECONNECT_MIN_MS
		client:Subscribe(topic("cmd"), 1)
		publish("status", "online", true)
		local count = rescan()
		setStatus("Connected, mirroring " .. count .. " devices")
	end)

	client:OnDisconnect(function(_, reasonCode, message)
		if myGeneration ~= generation then
			return
		end
		connected = false
		setStatus("Disconnected: " .. tostring(message or reasonCode))
		scheduleReconnect()
	end)

	client:OnMessage(function(...)
		if myGeneration == generation then
			onMessage(...)
		end
	end)

	setStatus("Connecting to " .. host)
	local port = tonumber(prop("Port")) or 1883
	local rc, err = client:Connect(host, port, 60)
	if rc ~= nil and rc ~= 0 then
		setStatus("Connect failed: " .. tostring(err or rc))
		scheduleReconnect()
	end
end

---------------------------------------------------------------------------
-- Diagnostics
---------------------------------------------------------------------------

-- Prints raw API results to the Lua output window in Composer.
local function dump()
	local function show(value, indent, depth)
		if type(value) ~= "table" or depth > 4 then
			return tostring(value)
		end
		local lines = {}
		for k, v in pairs(value) do
			lines[#lines + 1] = indent .. "  " .. tostring(k) .. " = " .. show(v, indent .. "  ", depth + 1)
		end
		return "{\n" .. table.concat(lines, "\n") .. "\n" .. indent .. "}"
	end

	local found = C4:GetDevices({}) or {}
	print("=== C4:GetDevices({}) ===")
	print(show(found, "", 0))
	for id in pairs(found) do
		local ok, vars = pcall(function()
			return C4:GetDeviceVariables(tonumber(id))
		end)
		print("=== C4:GetDeviceVariables(" .. tostring(id) .. ") ===")
		print(ok and show(vars, "", 0) or ("error: " .. tostring(vars)))
	end
end

---------------------------------------------------------------------------
-- Driver entry points
---------------------------------------------------------------------------

function OnDriverLateInit()
	C4:UpdateProperty("Driver Version", DRIVER_VERSION)
	connect()
end

function OnDriverDestroyed()
	cancelReconnect()
	unwatchAll()
	if mqtt and connected then
		publish("status", "offline", true)
	end
	dropClient()
end

function OnPropertyChanged(strProperty)
	if strProperty == "Device Filter" then
		if connected then
			local count = rescan()
			setStatus("Connected, mirroring " .. count .. " devices")
		end
	elseif strProperty == "Broker Address" or strProperty == "Port" or strProperty == "Username"
		or strProperty == "Password" or strProperty == "Unit ID" then
		reconnectDelay = RECONNECT_MIN_MS
		connect()
	end
end

function ExecuteCommand(strCommand, tParams)
	if strCommand ~= "LUA_ACTION" or type(tParams) ~= "table" then
		return
	end
	local action = tParams.ACTION
	if action == "Reconnect" then
		reconnectDelay = RECONNECT_MIN_MS
		connect()
	elseif action == "Rescan" then
		if connected then
			local count = rescan()
			setStatus("Connected, mirroring " .. count .. " devices")
		end
	elseif action == "Dump" then
		dump()
	end
end
