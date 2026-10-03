#!/usr/bin/env bash
# render.py: cloud-init files from fixed, fake inputs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; RPI="$HERE/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
KEY1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOne test@one"
KEY2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyTwo test@two"
PSK=' p"a'\''ss: #\x '          # quotes, colon, hash, backslash, leading and trailing space
render() { python3 "$RPI/render.py" "$RPI" "$1"; }

# Wi-Fi with an awkward SSID and password, two keys, no login password
PI_HOSTNAME=testpi PI_USER=tester PI_TIMEZONE=Europe/London PI_SSH_KEYS="$KEY1
$KEY2" PI_WIFI_SSID='Net: "x"' PI_WIFI_PSK="$PSK" PI_WIFI_COUNTRY=GB render "$T/a"
python3 - "$T/a" "$PSK" <<'PY'
import sys, yaml
d, psk = sys.argv[1], sys.argv[2]
raw = open(f"{d}/user-data").read()
assert raw.startswith("#cloud-config\n")
ud = yaml.safe_load(raw)
nc = yaml.safe_load(open(f"{d}/network-config"))
assert ud["hostname"] == "testpi" and ud["timezone"] == "Europe/London"
u = ud["users"][0]
assert u["name"] == "tester" and u["lock_passwd"] is True and "passwd" not in u
assert u["sudo"] == "ALL=(ALL) NOPASSWD:ALL"
assert len(u["ssh_authorized_keys"]) == 2
assert ud["ssh_pwauth"] is False
assert "unattended-upgrades" in ud["packages"]
paths = [f["path"] for f in ud["write_files"]]
assert "/etc/NetworkManager/system-connections/eth-direct.nmconnection" in paths
assert "/etc/profile.d/golden-power.sh" in paths
eth = [f for f in ud["write_files"] if f["path"].endswith("eth-direct.nmconnection")][0]
for line in ("link-local=enabled", "route-metric=700", "dhcp-timeout=2147483647"):
    assert line in eth["content"], line
assert eth["permissions"] == "0600"
power = [f for f in ud["write_files"] if f["path"].endswith("golden-power.sh")][0]["content"]
assert "$(vcgencmd get_throttled" in power          # $$ in the template became $
usb = [c[2] for c in ud["runcmd"] if isinstance(c, list) and "rpi-usb-gadget" in c[-1]][0]
assert "rpi-usb-gadget on && touch /run/golden-reboot" in usb and '"Pi 4 Model"' in usb and "Pi 3" not in usb
assert "systemctl reboot" not in raw and "reboot" not in str(ud["runcmd"]).replace("golden-reboot", "")
ps = ud["power_state"]
assert ps["mode"] == "reboot" and ps["condition"] == "test -e /run/golden-reboot", ps
cleanup = ud["runcmd"][-1][2]                       # last step: Wi-Fi password off the card
assert "/boot/firmware/network-config" in cleanup and "wifis" in cleanup, cleanup
assert "# Wi-Fi applied on first boot and removed from this card by golden/raspberrypi." in cleanup
w = nc["network"]["wifis"]["wlan0"]
assert nc["network"]["renderer"] == "NetworkManager"
assert w["access-points"] == {'Net: "x"': {"password": psk}}, w["access-points"]
assert w["regulatory-domain"] == "GB"
PY

# Login password, no Wi-Fi: sudo asks, no Wi-Fi anywhere
PI_HOSTNAME=testpi PI_USER=tester PI_SSH_KEYS="$KEY1" PI_PASSWORD_HASH='$6$salt$hash' render "$T/b"
python3 - "$T/b" <<'PY'
import sys, yaml
d = sys.argv[1]
ud = yaml.safe_load(open(f"{d}/user-data")); nc = yaml.safe_load(open(f"{d}/network-config"))
u = ud["users"][0]
assert u["lock_passwd"] is False and u["passwd"] == "$6$salt$hash"
assert u["sudo"] == "ALL=(ALL) ALL"
assert "wifis" not in nc["network"]
PY

# Open network: access point with no password
PI_HOSTNAME=testpi PI_USER=tester PI_SSH_KEYS="$KEY1" PI_WIFI_SSID=OpenNet render "$T/c"
python3 -c 'import sys,yaml; n=yaml.safe_load(open(sys.argv[1])); assert n["network"]["wifis"]["wlan0"]["access-points"]=={"OpenNet":{}}' "$T/c/network-config"

# Non-ASCII SSID and password round-trip (emoji is outside the BMP)
PI_HOSTNAME=testpi PI_USER=tester PI_SSH_KEYS="$KEY1" PI_WIFI_SSID='Café 📶' PI_WIFI_PSK='pässwörd 🔑' render "$T/u"
python3 - "$T/u/network-config" <<'PY'
import sys, yaml
raw = open(sys.argv[1], encoding="utf-8").read()
assert "Café 📶" in raw, raw
n = yaml.safe_load(raw)
assert n["network"]["wifis"]["wlan0"]["access-points"] == {"Café 📶": {"password": "pässwörd 🔑"}}
PY

# Refusals
if PI_HOSTNAME=Bad_Name PI_USER=tester PI_SSH_KEYS="$KEY1" render "$T/d" 2>/dev/null; then echo "accepted bad hostname"; exit 1; fi
if PI_HOSTNAME=testpi PI_USER=tester PI_SSH_KEYS="" render "$T/e" 2>/dev/null; then echo "accepted no keys"; exit 1; fi
if PI_HOSTNAME=testpi PI_USER='bad user' PI_SSH_KEYS="$KEY1" render "$T/f" 2>/dev/null; then echo "accepted bad user"; exit 1; fi

# cloud-init's own schema check, when cloud-init is installed
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init schema -c "$T/a/user-data" >/dev/null
fi
