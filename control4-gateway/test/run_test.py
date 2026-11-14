"""Runs driver.lua against a mock Control4 runtime and a real MQTT broker.

The driver's own MQTT implementation talks over a real TCP socket to an amqtt
broker; a paho-mqtt client observes and sends commands.

Usage: pip install lupa amqtt paho-mqtt && python3 test/run_test.py
"""
import asyncio
import json
import logging
import pathlib
import select
import socket
import threading
import time

import lupa.lua51 as lupa  # Control4 runs Lua 5.1
import paho.mqtt.client as paho
from amqtt.broker import Broker

PORT = 18883
root = pathlib.Path(__file__).resolve().parent.parent
logging.disable(logging.CRITICAL)

# --- broker ---------------------------------------------------------------
loop = asyncio.new_event_loop()
broker = None


def run_broker():
    global broker
    asyncio.set_event_loop(loop)
    broker = Broker(
        {
            "listeners": {"default": {"type": "tcp", "bind": f"127.0.0.1:{PORT}"}},
            "plugins": {"amqtt.plugins.authentication.AnonymousAuthPlugin": {"allow_anonymous": True}},
        },
        loop=loop,
    )
    loop.run_until_complete(broker.start())
    loop.run_forever()


threading.Thread(target=run_broker, daemon=True).start()
for _ in range(50):
    try:
        socket.create_connection(("127.0.0.1", PORT), timeout=0.2).close()
        break
    except OSError:
        time.sleep(0.1)
else:
    raise SystemExit("broker did not start")

# --- observer client ------------------------------------------------------
seen = []
observer = paho.Client(paho.CallbackAPIVersion.VERSION2, client_id="observer")
observer.on_message = lambda c, u, m: seen.append((m.topic, m.payload.decode(), m.retain))
observer.connect("127.0.0.1", PORT)
observer.subscribe("c4/#")
observer.loop_start()

# --- Lua runtime with the TCP client bridged to real sockets ---------------
lua = lupa.LuaRuntime(unpack_returned_tuples=True, encoding=None)  # strings are bytes
g = lua.globals()
socks = {}
pending_connect = set()


def tcp_connect(index, host, port):
    socks[index] = socket.create_connection((host.decode(), int(port)))
    pending_connect.add(index)


def tcp_write(index, data):
    socks[index].sendall(data)


def tcp_close(index):
    sock = socks.pop(index, None)
    if sock:
        sock.close()


g.py_tcp_connect, g.py_tcp_write, g.py_tcp_close = tcp_connect, tcp_write, tcp_close
lua.execute((root / "test" / "mock_c4.lua").read_bytes())
lua.execute((root / "driver" / "driver.lua").read_bytes())
mock = g.Mock


def pump(seconds=0.6):
    """Delivers socket events to the driver, like Director would."""
    end = time.time() + seconds
    while time.time() < end:
        for index in list(pending_connect):
            pending_connect.discard(index)
            client = mock.clients[index]
            client.cb.connect(client)
        for index, sock in list(socks.items()):
            client = mock.clients[index]
            if client.wantRead and select.select([sock], [], [], 0.02)[0]:
                data = sock.recv(4096)
                if data:
                    client.wantRead = False
                    client.cb.read(client, data)
                else:
                    socks.pop(index).close()
                    client.cb.disconnect(client, 0, b"")
        time.sleep(0.01)


def last(topic):
    return [p for t, p, _ in seen if t == topic][-1]


def status():
    return mock.props[b"Status"].decode()


# Start-up: session accepted, status, device list and initial state published.
g.OnDriverLateInit()
pump()
assert status() == "Connected, mirroring 2 devices", status()
assert last("c4/unit_101/status") == "online"
devices = json.loads(last("c4/unit_101/devices"))["devices"]
assert set(devices) == {"41", "52"}, devices  # no self, no variable-less device
assert devices["41"]["variables"] == {"1000": "LIGHT_STATE", "1001": "LIGHT_LEVEL"}
assert devices["41"]["name"] == 'Kitchen "Dimmer"' and devices["41"]["room"] == "Kuchnia ąę"
assert ("c4/unit_101/state/52/1100", "21.5") in [(t, p) for t, p, _ in seen]

# A variable change is mirrored; unknown devices are ignored.
g.OnWatchedVariableChanged(41, 1001, b"60")
count = len(seen)
g.OnWatchedVariableChanged(777, 1, b"x")
pump(0.3)
assert last("c4/unit_101/state/41/1001") == "60"
assert len(seen) == count + 1

# State is retained: a client connecting later still receives it.
late = []
latecomer = paho.Client(paho.CallbackAPIVersion.VERSION2, client_id="late")
latecomer.on_message = lambda c, u, m: late.append((m.topic, m.payload.decode()))
latecomer.connect("127.0.0.1", PORT)
latecomer.subscribe("c4/unit_101/state/#")
latecomer.loop_start()
pump(0.4)
assert ("c4/unit_101/state/41/1001", "60") in late, late


# Commands: valid, unknown device, bad JSON, gateway command, QoS 1 delivery.
def cmd(payload, qos=0):
    observer.publish("c4/unit_101/cmd", payload, qos=qos)
    pump(0.4)
    return json.loads(last("c4/unit_101/cmd/result"))


assert cmd('{"id":"a1","device":41,"command":"RAMP_TO_LEVEL","params":{"LEVEL":60,"TIME":1000}}') == {"id": "a1", "ok": True}
sent = mock.sent[1]
assert (sent.dev, sent.cmd, sent.params.LEVEL, sent.params.TIME) == (41, b"RAMP_TO_LEVEL", 60, 1000)
assert cmd('{"id":"a2","device":60,"command":"ON"}') == {"id": "a2", "ok": False, "error": "unknown device"}
assert cmd("not json") == {"ok": False, "error": "invalid JSON"}
assert cmd('{"id":"a3","command":"RESCAN"}') == {"id": "a3", "ok": True}
assert cmd('{"id":"a4","device":52,"command":"SET_SETPOINT_HEAT","params":{"CELSIUS":21.5}}', qos=1) == {"id": "a4", "ok": True}
assert mock.sent[2].params.CELSIUS == 21.5
assert len(list(mock.sent.values())) == 2

# Device filter narrows the mirrored set and drops old listeners.
g.Properties[b"Device Filter"] = b"thermostat"
g.OnPropertyChanged(b"Device Filter")
pump(0.3)
assert set(json.loads(last("c4/unit_101/devices"))["devices"]) == {"52"}
assert set(mock.listeners.keys()) == {b"52/1100"}, list(mock.listeners.keys())

# Keep-alive tick sends a ping and the session survives it.
tick = mock.timers[1]
assert tick.repeating and tick.delay == 20000
tick.fn(tick, 0)
pump(0.3)
assert status().startswith("Connected"), status()

# Broker drops the connection: last will is published, driver reconnects.
first = mock.clients[1]
socks[1].shutdown(socket.SHUT_RDWR)
pump(0.5)
assert last("c4/unit_101/status") == "offline"
assert status().startswith("Disconnected"), status()
timer = mock.timers[len(list(mock.timers.values()))]
assert timer.delay == 2000 and not timer.cancelled
timer.fn(timer)
pump()
assert status() == "Connected, mirroring 1 devices", status()
assert last("c4/unit_101/status") == "online"
assert len(list(mock.clients.values())) == 2 and first.closed

# Clean shutdown reports offline.
g.OnDriverDestroyed()
pump(0.4)
assert last("c4/unit_101/status") == "offline"

print("all tests passed")
