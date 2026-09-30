#!/usr/bin/env python3
"""Left-click in the test VM: vm-click.py <qmp socket> <x> <y>, coordinates scaled to 0..32767.

Called by vm-test.sh click. One QMP session that waits for each reply; sending the move and
the button over separate connections dropped events.
"""
import json
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX)
sock.connect(sys.argv[1])
qmp = sock.makefile("rw")
qmp.readline()  # greeting


def cmd(name, **args):
    qmp.write(json.dumps({"execute": name, "arguments": args} if args else {"execute": name}) + "\n")
    qmp.flush()
    while True:
        reply = json.loads(qmp.readline())
        if "return" in reply or "error" in reply:
            return reply


def send(*events):
    cmd("input-send-event", events=list(events))


cmd("qmp_capabilities")
send({"type": "abs", "data": {"axis": "x", "value": int(sys.argv[2])}},
     {"type": "abs", "data": {"axis": "y", "value": int(sys.argv[3])}})
time.sleep(0.3)
send({"type": "btn", "data": {"down": True, "button": "left"}})
time.sleep(0.1)
send({"type": "btn", "data": {"down": False, "button": "left"}})
