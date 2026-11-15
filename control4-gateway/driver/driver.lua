-- Building Gateway
-- Mirrors the state of Control4 devices in this project to an MQTT broker
-- and executes commands received from it.
--
-- Topics (prefix: c4/<Unit ID>/):
--   status                    "online" / "offline" (retained, last will)
--   devices                   JSON list of mirrored devices, their type and variables (retained)
--   state/<deviceId>/<varId>  current variable value (retained)
--   cmd                       incoming commands (JSON)
--   cmd/result                result of each command (JSON)

DRIVER_VERSION = "0.4.0"

local RECONNECT_MIN_MS = 2000
local RECONNECT_MAX_MS = 60000

local KEEPALIVE_S = 60
local TICK_MS = 20000
local CONNECT_TIMEOUT_S = 15

local NET_BINDING = 6001 -- dynamic network connection used for the broker
local CA_FILE = "./ca.pem" -- bundled in the .c4z, used to verify the broker

local activePort = nil -- port of the connection attempt in progress, nil when idle
local online = false -- true while the TCP/TLS connection is up
local connected = false -- true after the broker accepted the MQTT session
local connectStarted = 0
local lastReceived = 0
local rxBuffer = ""
local tickTimer = nil
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

---------------------------------------------------------------------------
-- JSON (pure Lua, so the driver does not depend on the OS version)
---------------------------------------------------------------------------

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function jsonString(text)
	text = string.gsub(text, '[%c"\\]', function(c)
		return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. text .. '"'
end

-- Tables are always encoded as objects with string keys.
local function jsonEncode(value)
	local kind = type(value)
	if kind == "table" then
		local parts = {}
		for k, v in pairs(value) do
			parts[#parts + 1] = jsonString(tostring(k)) .. ":" .. jsonEncode(v)
		end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	elseif kind == "string" then
		return jsonString(value)
	elseif kind == "number" or kind == "boolean" then
		return tostring(value)
	end
	return "null"
end

local function utf8Char(code)
	if code < 0x80 then
		return string.char(code)
	elseif code < 0x800 then
		return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
	end
	return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local UNESCAPES = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- Returns the decoded value, or nil and an error message.
local function jsonDecode(text)
	local pos = 1
	local parseValue

	local function skip()
		pos = string.find(text, "[^ \t\r\n]", pos) or (#text + 1)
	end

	local function parseString()
		local out = {}
		pos = pos + 1
		while true do
			local c = string.sub(text, pos, pos)
			if c == "" then
				error("unterminated string")
			elseif c == '"' then
				pos = pos + 1
				return table.concat(out)
			elseif c == "\\" then
				local e = string.sub(text, pos + 1, pos + 1)
				if e == "u" then
					local hex = string.match(text, "^%x%x%x%x", pos + 2)
					if not hex then
						error("bad unicode escape")
					end
					out[#out + 1] = utf8Char(tonumber(hex, 16))
					pos = pos + 6
				else
					out[#out + 1] = UNESCAPES[e] or e
					pos = pos + 2
				end
			else
				local stop = string.find(text, '["\\]', pos) or (#text + 1)
				out[#out + 1] = string.sub(text, pos, stop - 1)
				pos = stop
			end
		end
	end

	parseValue = function()
		skip()
		local c = string.sub(text, pos, pos)
		if c == "{" then
			local obj = {}
			pos = pos + 1
			skip()
			if string.sub(text, pos, pos) == "}" then
				pos = pos + 1
				return obj
			end
			while true do
				skip()
				if string.sub(text, pos, pos) ~= '"' then
					error("expected key")
				end
				local key = parseString()
				skip()
				if string.sub(text, pos, pos) ~= ":" then
					error("expected ':'")
				end
				pos = pos + 1
				obj[key] = parseValue()
				skip()
				local sep = string.sub(text, pos, pos)
				pos = pos + 1
				if sep == "}" then
					return obj
				elseif sep ~= "," then
					error("expected ',' or '}'")
				end
			end
		elseif c == "[" then
			local arr = {}
			pos = pos + 1
			skip()
			if string.sub(text, pos, pos) == "]" then
				pos = pos + 1
				return arr
			end
			while true do
				arr[#arr + 1] = parseValue()
				skip()
				local sep = string.sub(text, pos, pos)
				pos = pos + 1
				if sep == "]" then
					return arr
				elseif sep ~= "," then
					error("expected ',' or ']'")
				end
			end
		elseif c == '"' then
			return parseString()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos = pos + 4
			return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos = pos + 5
			return false
		elseif string.sub(text, pos, pos + 3) == "null" then
			pos = pos + 4
			return nil
		end
		local num = string.match(text, "^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
		if not num or not tonumber(num) then
			error("unexpected character at " .. pos)
		end
		pos = pos + #num
		return tonumber(num)
	end

	local ok, result = pcall(function()
		local value = parseValue()
		skip()
		if pos <= #text then
			error("trailing data")
		end
		return value
	end)
	if ok then
		return result
	end
	return nil, tostring(result)
end

---------------------------------------------------------------------------
-- MQTT 3.1.1 packet encoding (QoS 0 only)
---------------------------------------------------------------------------

local function mqttString(text)
	return string.char(math.floor(#text / 256), #text % 256) .. text
end

local function mqttPacket(firstByte, body)
	local len, header = #body, ""
	repeat
		local digit = len % 128
		len = math.floor(len / 128)
		if len > 0 then
			digit = digit + 128
		end
		header = header .. string.char(digit)
	until len == 0
	return string.char(firstByte) .. header .. body
end

local function mqttConnectPacket(clientId, username, password, willTopic, willPayload)
	local flags = 2 + 4 + 32 -- clean session, will, will retain
	local payload = mqttString(clientId) .. mqttString(willTopic) .. mqttString(willPayload)
	if username ~= "" then
		flags = flags + 128
		payload = payload .. mqttString(username)
		if password ~= "" then
			flags = flags + 64
			payload = payload .. mqttString(password)
		end
	end
	local body = mqttString("MQTT") .. string.char(4, flags, math.floor(KEEPALIVE_S / 256), KEEPALIVE_S % 256)
	return mqttPacket(0x10, body .. payload)
end

-- Takes one complete packet off the front of the buffer.
-- Returns firstByte, body, rest - or nil when more data is needed.
local function mqttTakePacket(buffer)
	local multiplier, len, index = 1, 0, 2
	while true do
		local digit = string.byte(buffer, index)
		if not digit then
			return nil
		end
		len = len + (digit % 128) * multiplier
		if digit < 128 then
			break
		end
		multiplier = multiplier * 128
		index = index + 1
		if index > 5 then
			return false -- malformed length
		end
	end
	if #buffer < index + len then
		return nil
	end
	return string.byte(buffer, 1), string.sub(buffer, index + 1, index + len), string.sub(buffer, index + len + 1)
end

local function send(data)
	if activePort and online then
		C4:SendToNetwork(NET_BINDING, activePort, data)
	end
end

local function publish(suffix, payload, retain)
	if not connected then
		return false
	end
	send(mqttPacket(retain and 0x31 or 0x30, mqttString(topic(suffix)) .. payload))
	return true
end

local function encode(value)
	return jsonEncode(value)
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

-- Device classes recognised from the proxy driver file name. Only these are
-- mirrored, whatever the Device Filter says: other drivers (cameras, voice
-- services, intercoms) keep passwords and pairing codes in their variables.
local DEVICE_TYPES = {
	{ pattern = "^light", type = "light" },
	{ pattern = "^blind", type = "blind" },
	{ pattern = "^thermostat", type = "thermostat" },
	{ pattern = "^contactsingle_(.-)_c4%.c4i$", type = "contact" },
	{ pattern = "^relaycontact_(.-)_c4%.c4i$", type = "relay" },
	{ pattern = "^relaysingle_(.-)_c4%.c4i$", type = "relay" },
}

-- Returns the device type and, for contacts and relays, the kind
-- (e.g. "watersensor", "garagedoor"); nil for drivers that are not mirrored.
local function classify(driverFileName)
	local name = string.lower(driverFileName or "")
	for _, entry in ipairs(DEVICE_TYPES) do
		local found, _, kind = string.find(name, entry.pattern)
		if found then
			return entry.type, kind
		end
	end
	return nil
end

local function isTrue(value)
	return value == true or string.lower(tostring(value)) == "true"
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
	local dimmable = nil
	for key, var in pairs(vars) do
		if type(var) == "table" then
			local varId = tonumber(key) or tonumber(var.id)
			if varId and not isTrue(var.hidden) then
				result[varId] = tostring(var.name or varId)
			elseif var.name == "Navigator Dynamic Capabilities" then
				dimmable = string.find(tostring(var.value), "<dimmer>True</dimmer>", 1, true) ~= nil
			end
		end
	end
	return result, dimmable
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
		local deviceType, kind = nil, nil
		if type(info) == "table" then
			deviceType, kind = classify(info.driverFileName)
		end
		if deviceId and deviceId ~= selfId and deviceType and matchesFilter(info.driverFileName) then
			local variables, dimmable = readVariables(deviceId)
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
					type = deviceType,
					kind = kind,
					dimmable = dimmable,
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
	local msg = jsonDecode(payload)
	if type(msg) ~= "table" then
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

local function onMessage(msgTopic, payload)
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
-- MQTT connection over a dynamic network binding (plain TCP or TLS)
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

local function dropSocket()
	local port = activePort
	activePort = nil
	online = false
	connected = false
	rxBuffer = ""
	if port then
		C4:NetDisconnect(NET_BINDING, port)
	end
end

local function connectionLost(reason)
	dropSocket()
	setStatus("Disconnected: " .. tostring(reason))
	scheduleReconnect()
end

local function onSessionAccepted()
	connected = true
	reconnectDelay = RECONNECT_MIN_MS
	send(mqttPacket(0x82, string.char(0, 1) .. mqttString(topic("cmd")) .. string.char(0)))
	publish("status", "online", true)
	local count = rescan()
	setStatus("Connected, mirroring " .. count .. " devices")
end

local function onPacket(firstByte, body)
	local kind = math.floor(firstByte / 16)
	if kind == 2 then -- CONNACK
		local code = string.byte(body, 2) or 255
		if code == 0 then
			onSessionAccepted()
		else
			connectionLost("broker refused the connection (code " .. code .. ")")
		end
	elseif kind == 3 and connected then -- PUBLISH
		local qos = math.floor(firstByte / 2) % 4
		local topicLen = (string.byte(body, 1) or 0) * 256 + (string.byte(body, 2) or 0)
		local msgTopic = string.sub(body, 3, 2 + topicLen)
		local payloadStart = 3 + topicLen
		if qos > 0 then
			if qos == 1 then
				send(mqttPacket(0x40, string.sub(body, payloadStart, payloadStart + 1)))
			end
			payloadStart = payloadStart + 2
		end
		onMessage(msgTopic, string.sub(body, payloadStart))
	end
	-- SUBACK and PINGRESP need no action; lastReceived is updated by the caller.
end

local function onData(data)
	lastReceived = os.time()
	rxBuffer = rxBuffer .. data
	while activePort do
		local firstByte, body, rest = mqttTakePacket(rxBuffer)
		if firstByte == false then
			connectionLost("malformed data from broker")
			return
		elseif not firstByte then
			return
		end
		rxBuffer = rest
		onPacket(firstByte, body)
	end
end

connect = function()
	cancelReconnect()
	dropSocket()

	local host = prop("Broker Address")
	if host == "" then
		setStatus("Not configured: set Broker Address")
		return
	end

	local tls = prop("Encryption") ~= "None"
	local kind = tls and "SSL" or "TCP"
	local port = tonumber(prop("Port")) or (tls and 8883 or 1883)
	local options = {
		AUTO_CONNECT = false,
		MONITOR_CONNECTION = false,
		KEEP_CONNECTION = false, -- reconnecting is handled here, with backoff
		KEEP_ALIVE = true,
		DELIMITER = "",
		SUPPRESS_CONNECTION_EVENTS = true,
	}
	if tls then
		if prop("Verify Certificate") == "Off" then
			options.VERIFY_MODE = "none"
		else
			options.VERIFY_MODE = "peer"
			options.CACERTFILE = CA_FILE
		end
	end

	connectStarted = os.time()
	lastReceived = connectStarted
	setStatus("Connecting to " .. host .. ":" .. port .. (tls and " (TLS)" or " (no encryption)"))

	activePort = port
	C4:CreateNetworkConnection(NET_BINDING, host, kind)
	C4:NetPortOptions(NET_BINDING, port, kind, options)
	C4:NetConnect(NET_BINDING, port)
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	if tonumber(idBinding) ~= NET_BINDING or tonumber(nPort) ~= activePort then
		return
	end
	if strStatus == "ONLINE" then
		if not online then
			online = true
			lastReceived = os.time()
			send(mqttConnectPacket("c4-gateway-" .. unitId(), prop("Username"), prop("Password"), topic("status"), "offline"))
		end
	elseif online then
		-- OFFLINE before ONLINE is left to the connect timeout in tick()
		connectionLost("connection closed")
	end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
	if tonumber(idBinding) == NET_BINDING and tonumber(nPort) == activePort and online then
		onData(strData or "")
	end
end

-- Runs every TICK_MS: keeps the session alive and detects dead connections.
local function tick()
	if not activePort then
		return
	end
	local now = os.time()
	if connected then
		if now - lastReceived > KEEPALIVE_S * 1.5 then
			connectionLost("broker not responding")
		else
			send(mqttPacket(0xC0, ""))
		end
	elseif now - connectStarted > CONNECT_TIMEOUT_S then
		connectionLost("connection timed out")
	end
end

---------------------------------------------------------------------------
-- Diagnostics
---------------------------------------------------------------------------

-- Prints what would be published (mirrored devices and their visible
-- variables) to the Lua output window in Composer. Nothing else is printed,
-- so the output is safe to share.
local function dump()
	local selfId = C4:GetDeviceID()
	local count = 0
	for id, info in pairs(C4:GetDevices({}) or {}) do
		local deviceId = tonumber(id)
		local deviceType, kind = nil, nil
		if type(info) == "table" then
			deviceType, kind = classify(info.driverFileName)
		end
		if deviceId and deviceId ~= selfId and deviceType and matchesFilter(info.driverFileName) then
			local variables, dimmable = readVariables(deviceId)
			if next(variables) ~= nil then
				count = count + 1
				print(string.format("[%d] %s / %s  type=%s kind=%s dimmable=%s driver=%s", deviceId,
					tostring(info.roomName), tostring(info.deviceName), deviceType, tostring(kind),
					tostring(dimmable), tostring(info.driverFileName)))
				for varId, varName in pairs(variables) do
					print(string.format("    %d %s = %s", varId, varName, tostring(C4:GetDeviceVariable(deviceId, varId))))
				end
			end
		end
	end
	print("=== " .. count .. " devices would be mirrored ===")
end

---------------------------------------------------------------------------
-- Driver entry points
---------------------------------------------------------------------------

function OnDriverLateInit()
	C4:UpdateProperty("Driver Version", DRIVER_VERSION)
	tickTimer = C4:SetTimer(TICK_MS, tick, true)
	connect()
end

function OnDriverDestroyed()
	cancelReconnect()
	if tickTimer then
		tickTimer:Cancel()
		tickTimer = nil
	end
	unwatchAll()
	if connected then
		publish("status", "offline", true)
		send(mqttPacket(0xE0, ""))
	end
	dropSocket()
end

function OnPropertyChanged(strProperty)
	if strProperty == "Device Filter" then
		if connected then
			local count = rescan()
			setStatus("Connected, mirroring " .. count .. " devices")
		end
	elseif strProperty == "Broker Address" or strProperty == "Port" or strProperty == "Username"
		or strProperty == "Password" or strProperty == "Unit ID"
		or strProperty == "Encryption" or strProperty == "Verify Certificate" then
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
