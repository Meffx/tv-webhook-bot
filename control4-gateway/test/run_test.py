"""Runs driver.lua against a mock Control4 runtime. Usage: python3 test/run_test.py"""
import json
import pathlib

import lupa

root = pathlib.Path(__file__).resolve().parent.parent
lua = lupa.LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()


def to_py(value):
    if lupa.lua_type(value) == "table":
        return {str(k): to_py(v) for k, v in value.items()}
    return value


def to_lua(value):
    if isinstance(value, dict):
        return lua.table_from({k: to_lua(v) for k, v in value.items()})
    if isinstance(value, list):
        return lua.table_from([to_lua(v) for v in value])
    return value


g.py_json_encode = lambda value: json.dumps(to_py(value), sort_keys=True)
g.py_json_decode = lambda text: to_lua(json.loads(text))
lua.execute((root / "test" / "mock_c4.lua").read_text())
lua.execute((root / "driver" / "driver.lua").read_text())
mock = g.Mock


def published():
    return [(m.topic, m.payload, m.retain) for m in mock.published.values()]


def last(topic):
    return [p for t, p, _ in published() if t == topic][-1]


# Start-up: connects with credentials and a last will, publishes nothing yet.
g.OnDriverLateInit()
client = mock.client
assert client.clientId == "c4-gateway-unit_101", client.clientId
assert (client.host, client.port, client.user) == ("10.0.0.5", 1883, "unit101")
assert list(client.will.values()) == ["c4/unit_101/status", "offline", 1, True]
assert published() == []

# Broker accepts: status, device list and initial state are published.
client.cb.connect(client, 0, 0, "ok")
assert mock.subs["c4/unit_101/cmd"]
assert last("c4/unit_101/status") == "online"
devices = json.loads(last("c4/unit_101/devices"))["devices"]
assert set(devices) == {"41", "52"}, devices  # no self, no variable-less device
assert devices["41"]["variables"] == {"1000": "LIGHT_STATE", "1001": "LIGHT_LEVEL"}
assert ("c4/unit_101/state/52/1100", "21.5", True) in published()
assert mock.props["Status"] == "Connected, mirroring 2 devices"

# A variable change is mirrored; unknown devices are ignored.
g.OnWatchedVariableChanged(41, 1001, "60")
assert last("c4/unit_101/state/41/1001") == "60"
before = len(published())
g.OnWatchedVariableChanged(777, 1, "x")
assert len(published()) == before

# Commands: valid, unknown device, bad JSON, gateway command.
def cmd(payload):
    client.cb.message(client, 1, "c4/unit_101/cmd", payload, 1, False)
    return json.loads(last("c4/unit_101/cmd/result"))

assert cmd('{"id":"a1","device":41,"command":"RAMP_TO_LEVEL","params":{"LEVEL":60,"TIME":1000}}') == {"id": "a1", "ok": True}
sent = mock.sent[1]
assert (sent.dev, sent.cmd, sent.params.LEVEL, sent.params.TIME) == (41, "RAMP_TO_LEVEL", 60, 1000)
assert cmd('{"id":"a2","device":60,"command":"ON"}') == {"id": "a2", "ok": False, "error": "unknown device"}
assert cmd("not json") == {"ok": False, "error": "invalid JSON"}
assert cmd('{"id":"a3","command":"RESCAN"}') == {"id": "a3", "ok": True}
assert len(list(mock.sent.values())) == 1

# Device filter narrows the mirrored set and drops old listeners.
g.Properties["Device Filter"] = "thermostat"
g.OnPropertyChanged("Device Filter")
assert set(json.loads(last("c4/unit_101/devices"))["devices"]) == {"52"}
assert set(mock.listeners.keys()) == {"52/1100"}, list(mock.listeners.keys())

# Unexpected disconnect schedules a reconnect that builds a fresh client.
client.cb.disconnect(client, 7, "connection lost")
timer = mock.timers[len(list(mock.timers.values()))]
assert timer.delay == 2000 and not timer.cancelled
timer.fn(timer)
assert mock.client is not client and client.disconnected
before = len(published())
client.cb.connect(client, 0, 0, "ok")  # stale callback from the old client is ignored
assert len(published()) == before

print("all tests passed")
