"""Runs driver.lua against a mock Control4 runtime and a real MQTT broker.

The driver's own MQTT implementation talks over real TLS and TCP sockets to an
amqtt broker; a paho-mqtt client observes and sends commands.

Usage: pip install lupa amqtt paho-mqtt && python3 test/run_test.py
"""
import asyncio
import json
import logging
import pathlib
import select
import socket
import ssl
import subprocess
import tempfile
import threading
import time

import lupa.lua51 as lupa  # Control4 runs Lua 5.1
import paho.mqtt.client as paho
from amqtt.broker import Broker

PORT = 18883  # plain TCP
TLS_PORT = 18884
root = pathlib.Path(__file__).resolve().parent.parent
logging.disable(logging.CRITICAL)

# --- test certificates: own CA and a server certificate for 127.0.0.1 ---------
certs = pathlib.Path(tempfile.mkdtemp())


def openssl(*args):
    subprocess.run(["openssl", *args], cwd=certs, check=True, capture_output=True)


openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=Test CA",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-keyout", "ca.key", "-out", "ca.pem")
openssl("req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1", "-keyout", "server.key", "-out", "server.csr")
(certs / "ext").write_text("subjectAltName=IP:127.0.0.1\n")
openssl("x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
        "-days", "2", "-extfile", "ext", "-out", "server.pem")

# --- broker ---------------------------------------------------------------
loop = asyncio.new_event_loop()
broker = None


def run_broker():
    global broker
    asyncio.set_event_loop(loop)
    broker = Broker(
        {
            "listeners": {
                "default": {"type": "tcp", "bind": f"127.0.0.1:{PORT}"},
                "tls": {"type": "tcp", "bind": f"127.0.0.1:{TLS_PORT}", "ssl": True,
                        "certfile": str(certs / "server.pem"), "keyfile": str(certs / "server.key")},
            },
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

# --- Lua runtime with network bindings bridged to real sockets --------------
lua = lupa.LuaRuntime(unpack_returned_tuples=True, encoding=None)  # strings are bytes
g = lua.globals()
conns = {}  # (binding, port) -> socket
events = []  # pending OnConnectionStatusChanged calls
ca_file = certs / "ca.pem"  # what the driver's "./ca.pem" resolves to in this test
handshake_errors = []


def net_connect(binding, port, host, kind, options):
    sock = socket.create_connection((host.decode(), int(port)))
    if kind == b"SSL":
        if options.VERIFY_MODE == b"peer":
            assert options.CACERTFILE == b"./ca.pem", options.CACERTFILE
            ctx = ssl.create_default_context(cafile=str(ca_file))
        else:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        try:
            sock = ctx.wrap_socket(sock, server_hostname=host.decode())
        except ssl.SSLError as exc:
            handshake_errors.append(exc)
            return  # like Director: no ONLINE event when the handshake fails
    conns[(binding, port)] = sock
    events.append((binding, port, b"ONLINE"))


def net_disconnect(binding, port):
    sock = conns.pop((binding, port), None)
    if sock:
        sock.close()
        events.append((binding, port, b"OFFLINE"))


def net_send(binding, port, data):
    conns[(binding, port)].sendall(data)


g.py_net_connect, g.py_net_disconnect, g.py_net_send = net_connect, net_disconnect, net_send
lua.execute((root / "test" / "mock_c4.lua").read_bytes())
lua.execute((root / "driver" / "driver.lua").read_bytes())
mock = g.Mock


def pump(seconds=0.6):
    """Delivers network events to the driver, like Director would."""
    end = time.time() + seconds
    while time.time() < end:
        while events:
            g.OnConnectionStatusChanged(*events.pop(0))
        for key, sock in list(conns.items()):
            pending = getattr(sock, "pending", lambda: 0)()
            if pending or select.select([sock], [], [], 0.02)[0]:
                data = sock.recv(4096)
                if data:
                    g.ReceivedFromNetwork(key[0], key[1], data)
                else:
                    conns.pop(key).close()
                    events.append((key[0], key[1], b"OFFLINE"))
        time.sleep(0.01)


def last(topic):
    return [p for t, p, _ in seen if t == topic][-1]


def status():
    return mock.props[b"Status"].decode()


# Start-up over TLS with certificate verification: session accepted, status,
# device list and initial state published.
g.OnDriverLateInit()
pump()
assert isinstance(conns[(6001, TLS_PORT)], ssl.SSLSocket)
assert mock.net.options.VERIFY_MODE == b"peer" and mock.net.options.KEEP_CONNECTION is False
assert status() == "Connected, mirroring 3 devices", status()
assert last("c4/unit_101/status") == "online"
devices = json.loads(last("c4/unit_101/devices"))["devices"]
assert set(devices) == {"41", "52", "80"}, devices  # proxies only; no camera, no self
assert devices["41"]["variables"] == {"1000": "LIGHT_STATE", "1001": "Brightness Percent"}  # hidden dropped
assert (devices["41"]["type"], devices["41"]["dimmable"]) == ("light", True)
assert (devices["80"]["type"], devices["80"]["kind"]) == ("contact", "watersensor")
assert devices["52"]["type"] == "thermostat" and "kind" not in devices["52"]
assert not any("hunter2" in p or "SNAPSHOT" in p or "/70/" in t for t, p, _ in seen)  # secrets stay local
assert devices["41"]["name"] == 'Kitchen "Dimmer"' and devices["41"]["room"] == "Kuchnia ąę"
assert ("c4/unit_101/state/52/1131", "21.5") in [(t, p) for t, p, _ in seen]

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
assert cmd('{"id":"a2","device":70,"command":"ON"}') == {"id": "a2", "ok": False, "error": "unknown device"}
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
assert set(mock.listeners.keys()) == {b"52/1131"}, list(mock.listeners.keys())

# Keep-alive tick sends a ping and the session survives it.
tick = mock.timers[1]
assert tick.repeating and tick.delay == 20000
tick.fn(tick, 0)
pump(0.3)
assert status().startswith("Connected"), status()

# Broker drops the connection: last will is published, driver reconnects.
conns[(6001, TLS_PORT)].shutdown(socket.SHUT_RDWR)
pump(0.5)
assert last("c4/unit_101/status") == "offline"
assert status().startswith("Disconnected"), status()
timer = mock.timers[len(list(mock.timers.values()))]
assert timer.delay == 2000 and not timer.cancelled
timer.fn(timer)
pump()
assert status() == "Connected, mirroring 1 devices", status()
assert last("c4/unit_101/status") == "online"

# A broker certificate from an untrusted CA is rejected: no session, no data sent.
ca_file = pathlib.Path("/etc/ssl/certs/ca-certificates.crt")
g.OnPropertyChanged(b"Verify Certificate")
pump(0.5)
assert handshake_errors and status().startswith("Connecting"), status()
assert last("c4/unit_101/status") == "offline"
assert not conns
ca_file = certs / "ca.pem"

# Switching encryption off reconnects over plain TCP.
g.Properties[b"Encryption"] = b"None"
g.Properties[b"Port"] = str(PORT).encode()
g.OnPropertyChanged(b"Port")
pump()
assert status() == "Connected, mirroring 1 devices", status()
assert not isinstance(conns[(6001, PORT)], ssl.SSLSocket) and mock.net.kind == b"TCP"
assert last("c4/unit_101/status") == "online"

# The diagnostic dump lists only what is mirrored.
printed = []
g.print = lambda *a: printed.append(b" ".join(a).decode())
g.ExecuteCommand(b"LUA_ACTION", lua.table_from({b"ACTION": b"Dump"}))
assert printed[-1] == "=== 1 devices would be mirrored ===" and not any("hunter2" in line for line in printed), printed

# Clean shutdown reports offline.
g.OnDriverDestroyed()
pump(0.4)
assert last("c4/unit_101/status") == "offline"
assert not conns

print("all tests passed")
