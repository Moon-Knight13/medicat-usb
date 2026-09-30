#!/usr/bin/env python3
"""Print one line per device with a firmware update waiting: "<name>: <current> -> <new>".

Refreshes LVFS metadata first. Never applies anything. Used by playbook.yml to fill in
golden-status's "still to do by hand" note.
"""
import json
import subprocess

subprocess.run(["fwupdmgr", "refresh", "--force"], capture_output=True, check=False)
out = subprocess.run(["fwupdmgr", "get-updates", "--json"], capture_output=True, text=True, check=False).stdout
try:
    devices = json.loads(out).get("Devices", [])
except ValueError:
    devices = []
for dev in devices:
    releases = dev.get("Releases") or []
    if releases:
        print(f"{dev.get('Name', '?')}: {dev.get('Version', '?')} -> {releases[0].get('Version', '?')}")
