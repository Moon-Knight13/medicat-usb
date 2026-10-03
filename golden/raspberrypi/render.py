#!/usr/bin/env python3
"""Render cloud-init user-data and network-config for a Raspberry Pi SD card.

Usage: render.py TEMPLATE_DIR OUT_DIR

Values come from environment variables, so secrets never show in a process list:
  PI_HOSTNAME, PI_USER, PI_TIMEZONE, PI_SSH_KEYS (one key per line)   required
  PI_PASSWORD_HASH          optional; with it the account has a password and sudo asks for it
  PI_WIFI_SSID, PI_WIFI_PSK optional; no SSID means no Wi-Fi, no PSK means an open network
  PI_WIFI_COUNTRY           default GB
"""
import json
import os
import re
import sys
from string import Template

NO_WIFI = "# Written by golden/raspberrypi/pi-flash: no Wi-Fi on this Pi.\nnetwork:\n  version: 2\n  renderer: NetworkManager\n"


def q(value):
    """A JSON value is valid YAML, and json.dumps escapes everything that matters."""
    return json.dumps(value, ensure_ascii=False)


def values(env):
    host = env.get("PI_HOSTNAME", "")
    if not re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?", host):
        sys.exit(f"render.py: invalid hostname {host!r}")
    user = env.get("PI_USER", "")
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user):
        sys.exit(f"render.py: invalid user name {user!r}")
    keys = [k.strip() for k in env.get("PI_SSH_KEYS", "").splitlines() if k.strip()]
    if not keys:
        sys.exit("render.py: no SSH public key")
    pw = env.get("PI_PASSWORD_HASH", "")
    if pw:
        password_lines, sudo = f"lock_passwd: false\n  passwd: {q(pw)}", "ALL=(ALL) ALL"
    else:
        password_lines, sudo = "lock_passwd: true", "ALL=(ALL) NOPASSWD:ALL"
    psk = env.get("PI_WIFI_PSK", "")
    return {
        "hostname": q(host),
        "user": q(user),
        "timezone": q(env.get("PI_TIMEZONE") or "Etc/UTC"),
        "ssh_keys": q(keys),
        "password_lines": password_lines,
        "sudo": q(sudo),
        "country": q(env.get("PI_WIFI_COUNTRY") or "GB"),
        "ssid": q(env.get("PI_WIFI_SSID", "")),
        "access_point": q({"password": psk} if psk else {}),
    }


def write(path, text, mode):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    try:
        os.chmod(path, mode)
    except OSError:
        pass  # FAT boot partition: permissions do not apply


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    tdir, out = argv[1], argv[2]
    v = values(os.environ)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(tdir, "user-data.tmpl"), encoding="utf-8") as f:
        write(os.path.join(out, "user-data"), Template(f.read()).substitute(v), 0o600)
    if os.environ.get("PI_WIFI_SSID"):
        with open(os.path.join(tdir, "network-config.tmpl"), encoding="utf-8") as f:
            net = Template(f.read()).substitute(v)
    else:
        net = NO_WIFI
    write(os.path.join(out, "network-config"), net, 0o600)


if __name__ == "__main__":
    main(sys.argv)
