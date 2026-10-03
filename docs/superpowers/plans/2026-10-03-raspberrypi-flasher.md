# Raspberry Pi Flasher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `golden/raspberrypi/` with `pi-flash` (write and configure a Pi SD card) and `pi` (open a shell on a Pi over Wi-Fi, USB or a direct Ethernet cable), installed on golden laptops and carried on the MediCat stick.

**Architecture:** Two bash scripts plus a small Python renderer that turns two cloud-init templates into the SD card's `user-data` and `network-config`. Secrets reach the renderer only through environment variables and are read from the laptop at flash time. The Ubuntu playbook installs the folder to `/usr/local/share/golden/raspberrypi/`, links the commands, writes `/etc/golden/pi.conf` from `vars/local.yml`, and adds two NetworkManager cable profiles. `make-stick.sh update` downloads the pinned image to `isos/RaspberryPi/`.

**Tech Stack:** bash, Python 3 (`string.Template`, `json`, PyYAML for tests), cloud-init (netplan v2, NetworkManager renderer), NetworkManager/nmcli, udisksctl, Ansible.

**Spec:** `docs/superpowers/specs/2026-10-03-raspberrypi-flasher-design.md`

## Global Constraints

- The repository is public: no Wi-Fi names or passwords, MAC addresses (except public Raspberry Pi vendor prefixes), hostnames, interface names, user names or keys in git, commit messages or PR text. Test fixtures use obviously fake values (`testpi`, `tester`, `example-wifi`, `AAAA...TestKey...`).
- No secrets on the stick or in the repo. Secrets are read at flash time and passed to `render.py` through environment variables only, never as command-line arguments, never printed.
- Supported boards: Pi 3 B+, Pi 4, Pi 5, Zero 2 W, 64-bit Raspberry Pi OS. USB gadget mode only on Zero 2 W, Pi 4, Pi 5; never on a Pi 3 B+.
- `pi-flash` writes only to removable disks of at most 256 GB, never to a disk mounted at `/`, `/boot` or `/boot/efi`, and only after the user types `yes`.
- `--name` is required and must match `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`.
- Exit codes of `pi-flash`: 0 done, 1 user error or refused safety check, 2 checksum or write failure.
- Laptop cable profiles `pi-local` and `pi-shared` have autoconnect off.
- Pi cable profile `eth-direct`: DHCP with no timeout, IPv4 link-local enabled, route metric 700.
- Claude cannot run `sudo` in this setup. Any step that needs it gives the user the exact command.
- shellcheck runs from `golden/raspberrypi/test/run.sh`, not a pre-commit hook: the repo's hooks run in a devcontainer with restricted egress, and the shellcheck hook downloads a binary. (Deviation from the spec's "added to pre-commit", for that reason.)
- Commit messages: Conventional Commits, plain English, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **`vars/local.yml` exists but has no `pi_*` keys** (every laptop today): the playbook loads only one of `local.yml` / `local.defaults.yml`, so every `pi_*` use must carry `| default(...)`, or `golden-update` breaks on all laptops. Pinned by the Task 5 check that renders the block with an empty vars file.
2. **`--device` naming a non-removable or system disk**: must be refused before anything is written. Pinned by the `check_device` test in Task 2.
3. **Wi-Fi password or SSID with quotes, colons, `#`, backslashes or leading spaces**: must reach the Pi byte for byte. Pinned by the render test in Task 1 and the nmcli escaping check in Task 2.
4. **Laptop with a Zero 2 W's USB link and a dock Ethernet port at the same time**: `pi local` must pick the dock, not the USB link. Pinned by the `cable_iface` test in Task 3.
5. **Old hand-made `~/.local/bin/pi` still on the PATH**: it comes before `/usr/local/bin` and would shadow the new command. Task 8 removes it and checks `command -v pi`.

---

## File Structure

| File | Responsibility |
|---|---|
| `golden/raspberrypi/image.conf` | Pinned image URL, file name, SHA-256 (shell `KEY=VALUE`, sourced) |
| `golden/raspberrypi/user-data.tmpl` | cloud-init user-data template (`string.Template`, `$$` for literal `$`) |
| `golden/raspberrypi/network-config.tmpl` | netplan v2 Wi-Fi template |
| `golden/raspberrypi/render.py` | Validates values from the environment and renders both templates into a directory |
| `golden/raspberrypi/pi-flash` | Collects values, picks and checks the card, finds and verifies the image, writes, configures |
| `golden/raspberrypi/pi` | Connects to a Pi: Wi-Fi, USB, cable (link-local or shared) |
| `golden/raspberrypi/README.md` | How to flash and connect |
| `golden/raspberrypi/test/run.sh` | Runs every `test-*.sh` and shellcheck |
| `golden/raspberrypi/test/test-render.sh` | Tests for `render.py` |
| `golden/raspberrypi/test/test-pi-flash.sh` | Tests for `pi-flash` (render-only, card filter, Wi-Fi lookup) |
| `golden/raspberrypi/test/test-pi.sh` | Tests for `pi` (cable port choice, Pi discovery, arguments) |
| `golden/ubuntu/playbook.yml` | New "raspberry pi" block |
| `golden/ubuntu/vars/local.defaults.yml`, `local.yml.example` | `pi_*` defaults and documentation |
| `golden/ubuntu/files/golden-help` | Raspberry Pi section |
| `make-stick.sh` | `update_raspberrypi`, status lists `.img.xz` |
| `golden/README.md`, `README.md` | Docs |

`docs/explainer/index.html` has no golden content today (checked: no "golden" in the file), so it needs no change; the PR says so.

---

### Task 1: Templates and renderer

**Files:**
- Create: `golden/raspberrypi/user-data.tmpl`
- Create: `golden/raspberrypi/network-config.tmpl`
- Create: `golden/raspberrypi/render.py`
- Create: `golden/raspberrypi/test/run.sh`
- Test: `golden/raspberrypi/test/test-render.sh`

**Interfaces:**
- Produces: `python3 render.py TEMPLATE_DIR OUT_DIR`, reading `PI_HOSTNAME`, `PI_USER`, `PI_TIMEZONE`, `PI_SSH_KEYS` (one key per line), `PI_PASSWORD_HASH` (optional), `PI_WIFI_SSID` (optional; empty means no Wi-Fi), `PI_WIFI_PSK` (optional; empty means open network), `PI_WIFI_COUNTRY` (default `GB`). Writes `OUT_DIR/user-data` and `OUT_DIR/network-config` (mode 0600 where the file system allows). Exits non-zero with a message on an invalid hostname, invalid user name, or no keys.

- [ ] **Step 1: Write the test runner**

`golden/raspberrypi/test/run.sh`:

```bash
#!/usr/bin/env bash
# Run the golden/raspberrypi tests: no hardware, no sudo, no network.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "$HERE"/test-*.sh; do
    if bash "$t"; then echo "PASS $(basename "$t")"; else echo "FAIL $(basename "$t")"; fail=1; fi
done
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x "$HERE/../pi" "$HERE/../pi-flash" "$HERE"/*.sh; then echo "PASS shellcheck"; else echo "FAIL shellcheck"; fail=1; fi
else
    echo "SKIP shellcheck (install: sudo apt install shellcheck)"
fi
exit "$fail"
```

Run: `chmod +x golden/raspberrypi/test/run.sh`

- [ ] **Step 2: Write the failing render test**

`golden/raspberrypi/test/test-render.sh`:

```bash
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
usb = ud["runcmd"][-1][2]
assert "rpi-usb-gadget on" in usb and '"Pi 4 Model"' in usb and "Pi 3" not in usb
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

# Refusals
if PI_HOSTNAME=Bad_Name PI_USER=tester PI_SSH_KEYS="$KEY1" render "$T/d" 2>/dev/null; then echo "accepted bad hostname"; exit 1; fi
if PI_HOSTNAME=testpi PI_USER=tester PI_SSH_KEYS="" render "$T/e" 2>/dev/null; then echo "accepted no keys"; exit 1; fi
if PI_HOSTNAME=testpi PI_USER='bad user' PI_SSH_KEYS="$KEY1" render "$T/f" 2>/dev/null; then echo "accepted bad user"; exit 1; fi

# cloud-init's own schema check, when cloud-init is installed
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init schema -c "$T/a/user-data" >/dev/null
fi
```

- [ ] **Step 3: Run it to check it fails**

Run: `bash golden/raspberrypi/test/test-render.sh`
Expected: FAIL, `python3: can't open file '.../render.py'`.

- [ ] **Step 4: Write the templates**

`golden/raspberrypi/user-data.tmpl`:

```yaml
#cloud-config
# Written by golden/raspberrypi/pi-flash at flash time. Applied once, on first boot.
hostname: ${hostname}
manage_etc_hosts: true
timezone: ${timezone}
users:
- name: ${user}
  groups: [users, adm, dialout, audio, netdev, video, plugdev, cdrom, games, input, gpio, spi, i2c, render, sudo]
  shell: /bin/bash
  ${password_lines}
  sudo: ${sudo}
  ssh_authorized_keys: ${ssh_keys}
ssh_pwauth: false
package_update: true
packages: [unattended-upgrades]
write_files:
# Pi end of a direct Ethernet cable to a laptop (pi local / pi share): DHCP when the laptop
# shares its connection, link-local otherwise. Metric 700 keeps Wi-Fi the default route.
- path: /etc/NetworkManager/system-connections/eth-direct.nmconnection
  permissions: '0600'
  content: |
    [connection]
    id=eth-direct
    type=ethernet
    interface-name=eth0
    autoconnect-priority=10

    [ethernet]

    [ipv4]
    method=auto
    link-local=enabled
    dhcp-timeout=2147483647
    may-fail=true
    route-metric=700

    [ipv6]
    method=auto
- path: /etc/profile.d/golden-power.sh
  permissions: '0644'
  content: |
    # Warn at login when the Pi has seen under-voltage since boot (a cause of SD card corruption).
    t=$$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    if [ -n "$$t" ] && [ "$$t" != "0x0" ]; then
        echo "WARNING: under-voltage or throttling since boot (get_throttled=$$t). Use a stronger power supply."
    fi
runcmd:
- [systemctl, enable, --now, ssh]
- [nmcli, connection, reload]
# USB networking only on boards with a device-mode USB port; never on a Pi 3 B+.
- - sh
  - -c
  - |
    case "$$(tr -d '\0' </proc/device-tree/model)" in
        *"Zero 2 W"*|*"Pi 4 Model"*|*"Pi 5 Model"*) rpi-usb-gadget on && systemctl reboot ;;
    esac
```

`golden/raspberrypi/network-config.tmpl`:

```yaml
# Written by golden/raspberrypi/pi-flash at flash time. Applied once, on first boot.
network:
  version: 2
  renderer: NetworkManager
  wifis:
    wlan0:
      dhcp4: true
      optional: true
      regulatory-domain: ${country}
      access-points:
        ${ssid}: ${access_point}
```

- [ ] **Step 5: Write the renderer**

`golden/raspberrypi/render.py`:

```python
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
    return json.dumps(value)


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
    with open(path, "w") as f:
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
    with open(os.path.join(tdir, "user-data.tmpl")) as f:
        write(os.path.join(out, "user-data"), Template(f.read()).substitute(v), 0o600)
    if os.environ.get("PI_WIFI_SSID"):
        with open(os.path.join(tdir, "network-config.tmpl")) as f:
            net = Template(f.read()).substitute(v)
    else:
        net = NO_WIFI
    write(os.path.join(out, "network-config"), net, 0o600)


if __name__ == "__main__":
    main(sys.argv)
```

Run: `chmod +x golden/raspberrypi/render.py`

- [ ] **Step 6: Run the test to check it passes**

Run: `bash golden/raspberrypi/test/test-render.sh && echo OK`
Expected: `OK`. If `cloud-init schema` complains about a key, fix the template, not the test.

- [ ] **Step 7: Commit**

```bash
git add golden/raspberrypi/user-data.tmpl golden/raspberrypi/network-config.tmpl golden/raspberrypi/render.py golden/raspberrypi/test/run.sh golden/raspberrypi/test/test-render.sh
git commit -m "feat(raspberrypi): cloud-init templates and renderer for Pi SD cards

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: pi-flash

**Files:**
- Create: `golden/raspberrypi/image.conf`
- Create: `golden/raspberrypi/pi-flash`
- Test: `golden/raspberrypi/test/test-pi-flash.sh`

**Interfaces:**
- Consumes: `render.py TEMPLATE_DIR OUT_DIR` and its environment variables (Task 1).
- Produces: `pi-flash --name HOST [--no-wifi] [--password] [--device /dev/sdX] [--render-only DIR]`. Reads `PI_CONF` (default `/etc/golden/pi.conf`, lines `DEFAULT_HOST=`, `WIFI_SSID=`, `WIFI_COUNTRY=`, `CABLE_IFACE=`, and any number of `KEY=`) and `PI_SSH_PUBKEY` (default `~/.ssh/id_ed25519.pub`). With `PI_FLASH_SOURCE_ONLY=1`, sourcing defines the functions `card_candidates`, `check_device`, `wifi_connection_for`, `active_wifi_uuid`, `unescape` and returns without running.

- [ ] **Step 1: Check how nmcli escapes `-g` output**

The Wi-Fi lookup depends on it. Run (creates and deletes a throwaway, never-activated profile; no sudo needed for a profile owned by you):

```bash
nmcli connection add type wifi con-name zz-escape-test ifname '*' ssid 'a:b\c' wifi-sec.key-mgmt wpa-psk wifi-sec.psk 'p:q\r12345' connection.autoconnect no connection.permissions "user:$USER" >/dev/null
nmcli -g 802-11-wireless.ssid connection show zz-escape-test
nmcli -s -g 802-11-wireless-security.psk connection show zz-escape-test
nmcli connection delete zz-escape-test >/dev/null
```

Expected: `a\:b\\c` and `p\:q\\r12345` (escaped). If the output is not escaped, remove `| unescape` from the psk and ssid reads in Step 4 and from the stub in Step 2, and note it in the commit message.

- [ ] **Step 2: Write the failing test**

`golden/raspberrypi/test/test-pi-flash.sh`:

```bash
#!/usr/bin/env bash
# pi-flash: render-only output, card filter, device check, Wi-Fi lookup. No card, no sudo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; RPI="$HERE/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOne test@one" > "$T/key.pub"
cat > "$T/pi.conf" <<'EOF'
WIFI_SSID=example-wifi
WIFI_COUNTRY=DE
KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyTwo test@two
EOF
export PI_CONF="$T/pi.conf" PI_SSH_PUBKEY="$T/key.pub"

# --name is required and must be a hostname
if "$RPI/pi-flash" --render-only "$T/x" 2>/dev/null; then echo "ran without --name"; exit 1; fi
if "$RPI/pi-flash" --name Bad_Name --render-only "$T/x" 2>/dev/null; then echo "accepted bad --name"; exit 1; fi

# render-only: both keys, Wi-Fi from pi.conf, placeholder password, country from pi.conf
"$RPI/pi-flash" --name testpi --render-only "$T/r" >/dev/null
python3 - "$T/r" <<'PY'
import sys, yaml
d = sys.argv[1]
ud = yaml.safe_load(open(f"{d}/user-data")); nc = yaml.safe_load(open(f"{d}/network-config"))
assert ud["hostname"] == "testpi"
assert len(ud["users"][0]["ssh_authorized_keys"]) == 2
w = nc["network"]["wifis"]["wlan0"]
assert w["access-points"] == {"example-wifi": {"password": "placeholder-password"}}
assert w["regulatory-domain"] == "DE"
PY

# --no-wifi: nothing about Wi-Fi on the card
"$RPI/pi-flash" --name testpi --no-wifi --render-only "$T/n" >/dev/null
if grep -rq "example-wifi\|placeholder-password" "$T/n"; then echo "--no-wifi leaked Wi-Fi values"; exit 1; fi

# Functions
PI_FLASH_SOURCE_ONLY=1 source "$RPI/pi-flash"
got=$(printf '%s\n' "sda 1 62537072640 disk" "nvme0n1 0 1000204886016 disk" "sdb 1 2000398934016 disk" \
                    "sdc 1 0 disk" "sr0 1 1073741312 rom" | card_candidates)
[[ "$got" == "sda" ]] || { echo "card_candidates gave: $got"; exit 1; }
check_device /dev/sda sda || { echo "refused a candidate"; exit 1; }
if check_device /dev/nvme0n1 sda; then echo "accepted a non-candidate"; exit 1; fi
if check_device /dev/sda; then echo "accepted with no candidates"; exit 1; fi

# Wi-Fi lookup through a fake nmcli: SSIDs with escaped colons, active network
mkdir -p "$T/bin"
cat > "$T/bin/nmcli" <<'EOF'
#!/bin/sh
case "$*" in
  "-t -f UUID,TYPE connection show") printf '%s\n' "u1:802-11-wireless" "u2:802-3-ethernet" "u3:802-11-wireless" ;;
  "-t -f UUID,TYPE connection show --active") printf '%s\n' "u2:802-3-ethernet" "u3:802-11-wireless" ;;
  "-g 802-11-wireless.ssid connection show uuid u1") echo 'Home\: Net' ;;
  "-g 802-11-wireless.ssid connection show uuid u3") echo 'Cafe' ;;
esac
EOF
chmod +x "$T/bin/nmcli"
PATH="$T/bin:$PATH"
[[ "$(wifi_connection_for 'Home: Net')" == u1 ]] || { echo "wifi_connection_for failed"; exit 1; }
[[ -z "$(wifi_connection_for 'Nowhere')" ]] || { echo "found a network that does not exist"; exit 1; }
[[ "$(active_wifi_uuid)" == u3 ]] || { echo "active_wifi_uuid failed"; exit 1; }
```

- [ ] **Step 3: Run it to check it fails**

Run: `bash golden/raspberrypi/test/test-pi-flash.sh`
Expected: FAIL, `.../pi-flash: No such file or directory`.

- [ ] **Step 4: Write image.conf and pi-flash**

`golden/raspberrypi/image.conf`:

```bash
# Pinned Raspberry Pi OS image for pi-flash and make-stick.sh (sourced by both).
# Change only in a reviewed PR. URL and SHA-256 from
# https://www.raspberrypi.com/software/operating-systems/ (Raspberry Pi OS Lite, 64-bit).
PI_IMAGE_URL=https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-09-15/2026-09-15-raspios-trixie-arm64-lite.img.xz
PI_IMAGE_FILE=2026-09-15-raspios-trixie-arm64-lite.img.xz
PI_IMAGE_SHA256=cdf4f3bfac35ae947b46e4e767f935453810549779ac3290e05a6754aee627e5
```

Check the pin before committing: `curl -sL "$(sed -n 's/^PI_IMAGE_URL=//p' golden/raspberrypi/image.conf).sha256"` must print the same SHA-256.

`golden/raspberrypi/pi-flash`:

```bash
#!/usr/bin/env bash
# pi-flash — write Raspberry Pi OS Lite to an SD card, set up for this laptop.
#
#   pi-flash --name HOST [--no-wifi] [--password] [--device /dev/sdX] [--render-only DIR]
#
#   --name HOST        the Pi's hostname (required); reach it later with: pi HOST
#   --no-wifi          no Wi-Fi on the card at all; reach the Pi by cable or USB only
#   --password         also set a login password (asked twice); sudo on the Pi then asks for it
#   --device /dev/sdX  the card, when more than one is plugged in
#   --render-only DIR  write the first-boot files to DIR with placeholder secrets; no card
#
# The Pi gets your user name, your SSH key (plus KEY= lines in /etc/golden/pi.conf) and the
# Wi-Fi WIFI_SSID from that file, or this laptop's current Wi-Fi. The Wi-Fi password is read
# from this laptop's saved connection and never printed.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PI_CONF="${PI_CONF:-/etc/golden/pi.conf}"
PI_SSH_PUBKEY="${PI_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/golden/raspberrypi"
MAX_BYTES=256000000000            # 256 GB: bigger "removable" disks are not SD cards

die()      { echo "pi-flash: $1" >&2; exit "${2:-1}"; }
conf_get() { sed -n "s/^$1=//p" "$PI_CONF" 2>/dev/null | head -n1; }
conf_all() { sed -n "s/^$1=//p" "$PI_CONF" 2>/dev/null; }
usage()    { sed -n '2,14s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 1; }
unescape() { sed 's/\\\(.\)/\1/g'; }    # nmcli -g escapes ':' and '\'

# SD card candidates from "NAME RM SIZE TYPE" lines (lsblk -dnbo NAME,RM,SIZE,TYPE).
card_candidates() {
    awk -v max="$MAX_BYTES" '$2 == 1 && $4 == "disk" && $3 > 0 && $3 <= max { print $1 }'
}

# check_device DEV CANDIDATE...: succeed only if DEV is one of the candidates.
check_device() {
    local dev=${1#/dev/} c; shift
    for c in "$@"; do
        if [[ "$c" == "$dev" ]]; then return 0; fi
    done
    return 1
}

# UUID of this laptop's saved Wi-Fi connection for SSID; empty if there is none.
wifi_connection_for() {
    local uuid type
    while IFS=: read -r uuid type; do
        [[ "$type" == 802-11-wireless ]] || continue
        if [[ "$(nmcli -g 802-11-wireless.ssid connection show uuid "$uuid" | unescape)" == "$1" ]]; then
            echo "$uuid"; return 0
        fi
    done < <(nmcli -t -f UUID,TYPE connection show)
    return 0
}

active_wifi_uuid() {
    nmcli -t -f UUID,TYPE connection show --active | awk -F: '$2 == "802-11-wireless" { print $1; exit }'
}

collect_values() {
    PI_USER=$USER
    [[ -f "$PI_SSH_PUBKEY" ]] || die "no SSH key at $PI_SSH_PUBKEY (make one: ssh-keygen -t ed25519)"
    PI_SSH_KEYS=$(cat "$PI_SSH_PUBKEY"; conf_all KEY)
    PI_TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    PI_TIMEZONE=${PI_TIMEZONE:-Etc/UTC}
    PI_WIFI_COUNTRY=$(conf_get WIFI_COUNTRY); PI_WIFI_COUNTRY=${PI_WIFI_COUNTRY:-GB}
    PI_WIFI_SSID="" PI_WIFI_PSK=""
    if [[ "$NO_WIFI" == 1 ]]; then return 0; fi
    PI_WIFI_SSID=$(conf_get WIFI_SSID)
    if [[ -n "$RENDER_ONLY" ]]; then
        PI_WIFI_SSID=${PI_WIFI_SSID:-example-wifi}; PI_WIFI_PSK=placeholder-password; return 0
    fi
    local uuid mgmt
    if [[ -n "$PI_WIFI_SSID" ]]; then
        uuid=$(wifi_connection_for "$PI_WIFI_SSID")
        [[ -n "$uuid" ]] || die "this laptop has no saved Wi-Fi called \"$PI_WIFI_SSID\"; join it once, or use --no-wifi"
    else
        uuid=$(active_wifi_uuid)
        [[ -n "$uuid" ]] || die "not on Wi-Fi and no WIFI_SSID in $PI_CONF; join a network, or use --no-wifi"
        PI_WIFI_SSID=$(nmcli -g 802-11-wireless.ssid connection show uuid "$uuid" | unescape)
    fi
    mgmt=$(nmcli -g 802-11-wireless-security.key-mgmt connection show uuid "$uuid")
    case "$mgmt" in
        "") ;;      # open network
        wpa-psk|sae)
            echo "Reading the Wi-Fi password for \"$PI_WIFI_SSID\" (sudo may ask for your password)..."
            PI_WIFI_PSK=$(sudo nmcli -s -g 802-11-wireless-security.psk connection show uuid "$uuid" | unescape)
            [[ -n "$PI_WIFI_PSK" ]] || die "no saved Wi-Fi password for \"$PI_WIFI_SSID\"" ;;
        *) die "\"$PI_WIFI_SSID\" uses $mgmt (enterprise Wi-Fi), which pi-flash does not support; use --no-wifi" ;;
    esac
}

ask_password() {
    local a b
    read -rsp "Login password for the Pi: " a; echo
    read -rsp "Same again: " b; echo
    [[ -n "$a" && "$a" == "$b" ]] || die "passwords empty or different"
    PI_PASSWORD_HASH=$(printf '%s\n' "$a" | openssl passwd -6 -stdin)
}

render_to() {
    PI_HOSTNAME=$NAME PI_USER=$PI_USER PI_TIMEZONE=$PI_TIMEZONE PI_SSH_KEYS=$PI_SSH_KEYS \
    PI_PASSWORD_HASH=$PI_PASSWORD_HASH PI_WIFI_SSID=$PI_WIFI_SSID PI_WIFI_PSK=$PI_WIFI_PSK \
    PI_WIFI_COUNTRY=$PI_WIFI_COUNTRY python3 "$HERE/render.py" "$HERE" "$1"
}

find_image() {
    local d
    for d in /media/"$USER"/*/RaspberryPi /run/media/"$USER"/*/RaspberryPi "$HERE/../../isos/RaspberryPi" "$CACHE"; do
        if [[ -f "$d/$PI_IMAGE_FILE" ]]; then echo "$d/$PI_IMAGE_FILE"; return 0; fi
    done
    mkdir -p "$CACHE"
    echo "Downloading $PI_IMAGE_FILE (about 550 MB)..." >&2
    curl -fL --retry 3 -C - -o "$CACHE/$PI_IMAGE_FILE" "$PI_IMAGE_URL" >&2 || die "download failed" 2
    echo "$CACHE/$PI_IMAGE_FILE"
}

verify_image() {
    echo "Checking $(basename "$1") (SHA-256)..."
    local got; got=$(sha256sum "$1" | awk '{print $1}')
    if [[ "$got" != "$PI_IMAGE_SHA256" ]]; then
        if [[ "$1" == "$CACHE/"* ]]; then rm -f "$1"; fi
        die "checksum mismatch for $1" 2
    fi
}

choose_card() {
    local cands ok
    mapfile -t cands < <(lsblk -dnbo NAME,RM,SIZE,TYPE | card_candidates)
    if [[ -n "$DEVICE" ]]; then
        check_device "$DEVICE" "${cands[@]}" || die "$DEVICE is not a removable card of 256 GB or less"
    else
        case ${#cands[@]} in
            0) die "no SD card found (removable, 256 GB or less)" ;;
            1) DEVICE=${cands[0]} ;;
            *) die "several cards found (${cands[*]}); choose one with --device /dev/NAME" ;;
        esac
    fi
    DEVICE=/dev/${DEVICE#/dev/}
    if lsblk -lnpo MOUNTPOINTS "$DEVICE" | grep -qxE '/|/boot|/boot/efi'; then die "$DEVICE holds this laptop's system"; fi
    echo; lsblk -o NAME,SIZE,MODEL,LABEL "$DEVICE"; echo
    read -rp "Everything on $DEVICE will be erased. Type yes to continue: " ok
    [[ "$ok" == yes ]] || die "stopped; nothing was written"
}

write_card() {
    local p boot mnt
    while read -r p; do udisksctl unmount -b "$p" >/dev/null 2>&1 || true; done \
        < <(lsblk -lnpo NAME,TYPE "$DEVICE" | awk '$2 == "part" { print $1 }')
    echo "Writing $(basename "$IMAGE") to $DEVICE (sudo may ask for your password)..."
    xzcat "$IMAGE" | sudo dd of="$DEVICE" bs=4M conv=fsync status=progress || die "writing $DEVICE failed" 2
    sudo partprobe "$DEVICE"; sudo udevadm settle
    boot=$(lsblk -lnpo NAME,TYPE "$DEVICE" | awk '$2 == "part" { print $1; exit }')
    [[ -n "$boot" ]] || die "no boot partition on $DEVICE after writing" 2
    mnt=$(lsblk -lnpo MOUNTPOINTS "$boot" | head -n1)     # the desktop may have mounted it already
    if [[ -z "$mnt" ]]; then
        mnt=$(udisksctl mount -b "$boot" | sed -n 's/^Mounted .* at \(.*\)$/\1/p' | sed 's/\.$//')
    fi
    [[ -d "$mnt" ]] || die "could not mount $boot" 2
    render_to "$mnt" || die "could not write the first-boot files" 2
    touch "$mnt/ssh"
    sync; udisksctl unmount -b "$boot" >/dev/null
}

main() {
    NAME="" NO_WIFI=0 WANT_PASSWORD=0 DEVICE="" RENDER_ONLY="" PI_PASSWORD_HASH=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)        [[ $# -ge 2 ]] || usage; NAME=$2; shift 2 ;;
            --device)      [[ $# -ge 2 ]] || usage; DEVICE=$2; shift 2 ;;
            --render-only) [[ $# -ge 2 ]] || usage; RENDER_ONLY=$2; shift 2 ;;
            --no-wifi)     NO_WIFI=1; shift ;;
            --password)    WANT_PASSWORD=1; shift ;;
            *)             usage ;;
        esac
    done
    [[ -n "$NAME" ]] || die "--name HOST is required (the Pi's hostname)"
    [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "--name must be a hostname: lower-case letters, digits and -"

    if [[ -n "$RENDER_ONLY" ]]; then
        collect_values
        if [[ "$WANT_PASSWORD" == 1 ]]; then PI_PASSWORD_HASH='$6$placeholder$hash'; fi
        render_to "$RENDER_ONLY"
        echo "First-boot files written to $RENDER_ONLY"
        return 0
    fi

    local cmd
    for cmd in lsblk udisksctl xzcat python3 curl sha256sum openssl; do
        command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"
    done
    # shellcheck source=image.conf
    source "$HERE/image.conf"
    collect_values                                   # Wi-Fi problems stop us before anything is erased
    if [[ "$WANT_PASSWORD" == 1 ]]; then ask_password; fi
    IMAGE=$(find_image)
    verify_image "$IMAGE"
    choose_card
    write_card
    ssh-keygen -R "$NAME.local" >/dev/null 2>&1 || true   # a re-flashed Pi has new host keys
    echo
    echo "Done. Put the card in the Pi, power it, and after about 2 minutes: pi $NAME"
}

if [[ -n "${PI_FLASH_SOURCE_ONLY:-}" ]]; then return 0; fi
main "$@"
```

Run: `chmod +x golden/raspberrypi/pi-flash`

- [ ] **Step 5: Run the test to check it passes**

Run: `bash golden/raspberrypi/test/test-pi-flash.sh && echo OK`
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add golden/raspberrypi/image.conf golden/raspberrypi/pi-flash golden/raspberrypi/test/test-pi-flash.sh
git commit -m "feat(raspberrypi): pi-flash writes and configures a Pi SD card

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: pi

**Files:**
- Create: `golden/raspberrypi/pi`
- Test: `golden/raspberrypi/test/test-pi.sh`

**Interfaces:**
- Consumes: `PI_CONF` lines `DEFAULT_HOST=`, `CABLE_IFACE=` (same file as Task 2). Laptop profiles `pi-local` and `pi-shared` (Task 5). Pi profile `eth-direct` (Task 1).
- Produces: `pi [HOST] [local|share|off]`. With `PI_SOURCE_ONLY=1`, sourcing defines `cable_iface`, `pi_on_cable`, `main` and returns. `SYS_NET` (default `/sys/class/net`) is overridable for tests.

- [ ] **Step 1: Write the failing test**

`golden/raspberrypi/test/test-pi.sh`:

```bash
#!/usr/bin/env bash
# pi: cable port choice, Pi discovery on the cable, argument handling. Fake nmcli, ip, ping.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; RPI="$HERE/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Fake /sys/class/net: a dock port (r8152), a Zero 2 W's USB link (cdc_ether), a virtual port
mkdir -p "$T/sys/enxdock/device" "$T/sys/enxusb/device" "$T/sys/veth0"
ln -s ../../../drivers/r8152 "$T/sys/enxdock/device/driver"
ln -s ../../../drivers/cdc_ether "$T/sys/enxusb/device/driver"
mkdir -p "$T/bin"
cat > "$T/bin/nmcli" <<'EOF'
#!/bin/sh
[ "$*" = "-t -f DEVICE,TYPE device" ] && printf '%s\n' "wlp1s0:wifi" "enxdock:ethernet" "enxusb:ethernet" "veth0:ethernet" "docker0:bridge"
exit 0
EOF
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "fe80::1 lladdr 00:11:22:33:44:55 REACHABLE" "fe80::2 lladdr B8:27:EB:AA:BB:CC STALE"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/ping"
chmod +x "$T/bin/"*
: > "$T/pi.conf"
export PI_CONF="$T/pi.conf" SYS_NET="$T/sys" PATH="$T/bin:$PATH"

PI_SOURCE_ONLY=1 source "$RPI/pi"
[[ "$(cable_iface)" == enxdock ]] || { echo "cable_iface picked: $(cable_iface)"; exit 1; }
echo "CABLE_IFACE=eth9" > "$T/pi.conf"
[[ "$(cable_iface)" == eth9 ]] || { echo "CABLE_IFACE not honoured"; exit 1; }
[[ "$(pi_on_cable enxdock)" == "fe80::2" ]] || { echo "pi_on_cable gave: $(pi_on_cable enxdock)"; exit 1; }

# Two physical ports and no CABLE_IFACE: refuse rather than guess
: > "$T/pi.conf"
mkdir -p "$T/sys/eth9/device"; ln -s ../../../drivers/e1000e "$T/sys/eth9/device/driver"
cat > "$T/bin/nmcli" <<'EOF'
#!/bin/sh
[ "$*" = "-t -f DEVICE,TYPE device" ] && printf '%s\n' "enxdock:ethernet" "eth9:ethernet"
exit 0
EOF
if (cable_iface) 2>/dev/null; then echo "guessed between two ports"; exit 1; fi

# Unknown arguments: usage, exit 1
if "$RPI/pi" --bogus >/dev/null 2>&1; then echo "accepted --bogus"; exit 1; fi
if "$RPI/pi" one two >/dev/null 2>&1; then echo "accepted two hosts"; exit 1; fi
```

- [ ] **Step 2: Run it to check it fails**

Run: `bash golden/raspberrypi/test/test-pi.sh`
Expected: FAIL, `.../pi: No such file or directory`.

- [ ] **Step 3: Write pi**

`golden/raspberrypi/pi`:

```bash
#!/usr/bin/env bash
# pi — open a shell on a Raspberry Pi set up by pi-flash.
#
#   pi [HOST]          Wi-Fi (HOST.local) if it answers, else USB, else the Ethernet cable
#   pi [HOST] local    Ethernet cable only, link-local: no DHCP server, no routing
#   pi [HOST] share    Ethernet cable, and the Pi gets internet through this laptop
#   pi off             free the Ethernet port again
#
# HOST defaults to DEFAULT_HOST in /etc/golden/pi.conf. Without one, pi skips Wi-Fi and finds
# the Pi on USB or the cable by its MAC address.
set -euo pipefail

PI_CONF="${PI_CONF:-/etc/golden/pi.conf}"
SYS_NET="${SYS_NET:-/sys/class/net}"
PI_OUIS="b8:27:eb dc:a6:32 e4:5f:01 d8:3a:dd 28:cd:c1 2c:cf:67 88:a2:9e"   # Raspberry Pi vendor prefixes
USB_ADDR=10.12.194.1                                                       # the Pi on USB (rpi-usb-gadget)

die()      { echo "pi: $*" >&2; exit 1; }
conf_get() { sed -n "s/^$1=//p" "$PI_CONF" 2>/dev/null | head -n1; }
usage()    { sed -n '2,10s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 1; }

# The Ethernet port the Pi is plugged into: CABLE_IFACE, or the only physical wired port.
# A Pi's own USB link (cdc_ether, rndis_host, cdc_ncm) is not a cable port.
cable_iface() {
    local want dev type drv found=()
    want=$(conf_get CABLE_IFACE)
    if [[ -n "$want" ]]; then echo "$want"; return 0; fi
    while IFS=: read -r dev type; do
        [[ "$type" == ethernet && -e "$SYS_NET/$dev/device" ]] || continue
        drv=$(basename "$(readlink "$SYS_NET/$dev/device/driver" 2>/dev/null || true)")
        case "$drv" in cdc_ether|rndis_host|cdc_ncm) continue ;; esac
        found+=("$dev")
    done < <(nmcli -t -f DEVICE,TYPE device)
    case ${#found[@]} in
        1) echo "${found[0]}" ;;
        0) die "no Ethernet port found; plug in the adapter or dock" ;;
        *) die "several Ethernet ports (${found[*]}); set pi_cable_iface in vars/local.yml" ;;
    esac
}

# Link-local IPv6 address of a Raspberry Pi on the port; empty if none answers.
pi_on_cable() {
    ping -6 -c2 -W1 "ff02::1%$1" >/dev/null 2>&1 || true
    ip -6 neigh show dev "$1" | awk -v ouis="$PI_OUIS" '
        BEGIN { n = split(ouis, o, " ") }
        $1 ~ /^fe80/ { mac = tolower($3); for (i = 1; i <= n; i++) if (index(mac, o[i]) == 1) { print $1; exit } }'
}

# Bring PROFILE up on the cable port and wait up to 30 s for a Pi. Sets IFACE and ADDR.
cable_up() {
    IFACE=$(cable_iface)
    nmcli -w 15 connection up "$1" ifname "$IFACE" >/dev/null || die "could not bring up $1 on $IFACE"
    echo "Ethernet $IFACE up ($1), looking for the Pi..."
    local i
    for i in $(seq 1 30); do
        ADDR=$(pi_on_cable "$IFACE")
        if [[ -n "$ADDR" ]]; then return 0; fi
        sleep 1
    done
    die "no Raspberry Pi seen on $IFACE after 30 seconds"
}

ssh_opts() { if [[ -n "$HOST" ]]; then printf '%s\n' -o "HostKeyAlias=$HOST.local"; fi; }

ssh_pi() {
    local opts; mapfile -t opts < <(ssh_opts)
    exec ssh "${opts[@]}" "$USER@$1"
}

vpn_up() { nmcli -t -f TYPE connection show --active | grep -qE '^(vpn|wireguard|tun)$'; }

main() {
    HOST="" MODE=""
    local a
    for a in "$@"; do
        case "$a" in
            local|share|off) MODE=$a ;;
            -*) usage ;;
            *) [[ -z "$HOST" ]] || usage; HOST=$a ;;
        esac
    done
    HOST=${HOST:-$(conf_get DEFAULT_HOST)}

    case "$MODE" in
        off)
            nmcli connection down pi-shared >/dev/null 2>&1 || true
            nmcli connection down pi-local >/dev/null 2>&1 || true
            echo "Ethernet port released" ;;
        local)
            cable_up pi-local
            ssh_pi "$ADDR%$IFACE" ;;
        share)
            cable_up pi-local        # a Pi must be on this cable before we serve DHCP on it
            if vpn_up; then echo "Warning: a VPN is up; the Pi's internet traffic will go through it." >&2; fi
            nmcli -w 15 connection up pi-shared ifname "$IFACE" >/dev/null || die "could not share on $IFACE"
            echo "Sharing this laptop's connection with the Pi"
            local opts i; mapfile -t opts < <(ssh_opts)
            # Ask the Pi for a DHCP lease now rather than at its next retry; its link drops briefly.
            ssh "${opts[@]}" "$USER@$ADDR%$IFACE" 'sudo -n nmcli -w 0 connection up eth-direct' >/dev/null 2>&1 || true
            ADDR=""
            for i in $(seq 1 20); do
                sleep 1; ADDR=$(pi_on_cable "$IFACE")
                if [[ -n "$ADDR" ]]; then break; fi
            done
            [[ -n "$ADDR" ]] || die "lost the Pi after turning on sharing"
            ssh_pi "$ADDR%$IFACE" ;;
        "")
            if [[ -n "$HOST" ]] && ping -c1 -W1 "$HOST.local" >/dev/null 2>&1; then ssh_pi "$HOST.local"; fi
            if ping -c1 -W1 "$USB_ADDR" >/dev/null 2>&1; then ssh_pi "$USB_ADDR"; fi
            cable_up pi-local
            ssh_pi "$ADDR%$IFACE" ;;
    esac
}

if [[ -n "${PI_SOURCE_ONLY:-}" ]]; then return 0; fi
main "$@"
```

Run: `chmod +x golden/raspberrypi/pi`

- [ ] **Step 4: Run the test to check it passes**

Run: `bash golden/raspberrypi/test/test-pi.sh && echo OK`
Expected: `OK`.

- [ ] **Step 5: Run all tests and shellcheck**

Run: `command -v shellcheck || echo "ask the user: sudo apt install shellcheck"`, then `golden/raspberrypi/test/run.sh`
Expected: `PASS` for test-pi-flash.sh, test-pi.sh, test-render.sh and shellcheck. Fix any shellcheck finding in the scripts; add a `# shellcheck disable=SCxxxx` only with a comment saying why.

- [ ] **Step 6: Commit**

```bash
git add golden/raspberrypi/pi golden/raspberrypi/test/test-pi.sh
git commit -m "feat(raspberrypi): pi command connects over Wi-Fi, USB or a direct cable

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Image on the stick (make-stick.sh)

**Files:**
- Modify: `make-stick.sh` (add `update_raspberrypi` after `update_extra`; call it from `cmd_update`; list `.img.xz` in `cmd_status`; mention it in the header comment)

**Interfaces:**
- Consumes: `golden/raspberrypi/image.conf` (`PI_IMAGE_URL`, `PI_IMAGE_FILE`, `PI_IMAGE_SHA256`), existing `fetch`, `verify_sha256`, `c_info`, `c_ok`, `c_warn`, `ISOS`.
- Produces: `isos/RaspberryPi/<PI_IMAGE_FILE>` plus `.ok`, found by `pi-flash` on the stick as `*/RaspberryPi/<PI_IMAGE_FILE>`.

- [ ] **Step 1: Write the failing check**

Save as `$SCRATCH/test-update-pi.sh` (outside the repo; a one-off check) and run it with `bash`. It runs only the new function against a temporary `ISOS`, with `fetch` copying a local copy of the image instead of downloading:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd ~/Documents/medicat-usb
SRC=${SRC:?set SRC to a local copy of the pinned .img.xz}
KIT=$PWD ISOS=$(mktemp -d)
c_info() { :; }; c_ok() { echo "ok: $*"; }; c_warn() { echo "warn: $*"; }; die() { echo "die: $*"; exit 1; }
fetch() { cp "$SRC" "$2"; }
eval "$(sed -n '/^verify_sha256()/,/^}/p;/^update_raspberrypi()/,/^}/p' make-stick.sh)"
update_raspberrypi                  # downloads (copies) and verifies
update_raspberrypi | grep -q "current and verified"   # second run: nothing to do
ls "$ISOS/RaspberryPi"
rm -rf "$ISOS"
```

Run: `SRC=<path to a local copy of the pinned .img.xz> bash $SCRATCH/test-update-pi.sh`. If there is no local copy, download one into `$SCRATCH` first: `curl -fL -o "$SCRATCH/pi.img.xz" "$(sed -n 's/^PI_IMAGE_URL=//p' golden/raspberrypi/image.conf)"`.
Expected: FAIL, `update_raspberrypi: command not found`.

- [ ] **Step 2: Add the function**

In `make-stick.sh`, after the closing `}` of `update_extra()`, add:

```bash
# Pinned Raspberry Pi OS image (golden/raspberrypi/image.conf) for pi-flash, carried on the
# stick under RaspberryPi/. Ventoy does not list .img.xz files, so the boot menu is unchanged.
update_raspberrypi() {
    local conf="$KIT/golden/raspberrypi/image.conf"
    [[ -f "$conf" ]] || return 0
    c_info "== Raspberry Pi OS image =="
    local PI_IMAGE_URL PI_IMAGE_FILE PI_IMAGE_SHA256 old
    # shellcheck disable=SC1090
    source "$conf"
    local dir="$ISOS/RaspberryPi" file="$ISOS/RaspberryPi/$PI_IMAGE_FILE"
    mkdir -p "$dir"
    if [[ -f "$file.ok" && "$(cat "$file.ok")" == "$PI_IMAGE_SHA256" && -f "$file" ]]; then
        c_ok "$PI_IMAGE_FILE is current and verified"; return
    fi
    [[ -f "$file" ]] || { c_info "Downloading $PI_IMAGE_FILE..."; fetch "$PI_IMAGE_URL" "$file"; }
    verify_sha256 "$file" "$PI_IMAGE_SHA256"
    for old in "$dir"/*.img.xz; do
        [[ "$old" != "$file" && -f "$old" ]] && { c_warn "Removing older $(basename "$old")"; rm -f "$old" "$old.ok"; }
    done
    c_ok "$PI_IMAGE_FILE ready"
}
```

In `cmd_update`, change `update_ventoy; update_medicat; update_ubuntu; update_extra` to:

```bash
    update_ventoy; update_medicat; update_ubuntu; update_extra; update_raspberrypi
```

In `cmd_status`, change the `find` filter `\( -iname '*.iso' -o -iname '*.img' -o -iname '*.wim' -o -iname '*.vhd*' \)` to:

```bash
\( -iname '*.iso' -o -iname '*.img' -o -iname '*.img.xz' -o -iname '*.wim' -o -iname '*.vhd*' \)
```

In the header comment, after the `isos/<Folder>/<file>.iso` lines, add:

```bash
#   isos/RaspberryPi/<image>.img.xz  pinned Raspberry Pi OS (golden/raspberrypi/image.conf), for pi-flash
```

- [ ] **Step 3: Run the check to see it pass**

Run: the Step 1 command again, then `bash -n make-stick.sh && echo syntax-ok`
Expected: `ok: ... ready`, a listing with the `.img.xz` and `.img.xz.ok`, then `syntax-ok`.

- [ ] **Step 4: Commit**

```bash
git add make-stick.sh
git commit -m "feat(make-stick): carry the pinned Raspberry Pi OS image on the stick

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Laptop playbook, defaults, golden-help

**Files:**
- Modify: `golden/ubuntu/playbook.yml` (new block just before `# ------------------------------------------------------------------ help --`)
- Modify: `golden/ubuntu/vars/local.defaults.yml`
- Modify: `golden/ubuntu/vars/local.yml.example`
- Modify: `golden/ubuntu/files/golden-help` (new section before `  Other useful commands`)

**Interfaces:**
- Consumes: the whole `golden/raspberrypi/` folder (Tasks 1–3).
- Produces: `/usr/local/share/golden/raspberrypi/`, links `/usr/local/bin/pi-flash` and `/usr/local/bin/pi`, `/etc/golden/pi.conf` (`DEFAULT_HOST=`, `WIFI_SSID=`, `WIFI_COUNTRY=`, `CABLE_IFACE=`, `KEY=` lines), NetworkManager profiles `pi-local` and `pi-shared`.

- [ ] **Step 1: Write the failing check (Review Focus 1)**

Save as `$SCRATCH/check-pi-block.yml`. It runs only the new `pi.conf` task's template with a vars file that has no `pi_*` keys, the way every laptop's `local.yml` is today:

```yaml
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - "{{ playbook_dir }}/empty-vars.yml"
  tasks:
    - name: Render pi.conf as the playbook does
      ansible.builtin.debug:
        msg: "{{ lookup('ansible.builtin.template', lookup('ansible.builtin.env', 'REPO') + '/golden/ubuntu/templates/pi.conf.j2') }}"
```

Run: `echo '{}' > $SCRATCH/empty-vars.yml && REPO=$PWD ansible-playbook $SCRATCH/check-pi-block.yml`
Expected: FAIL, template `pi.conf.j2` not found.

- [ ] **Step 2: Add the template and the playbook block**

Create `golden/ubuntu/templates/pi.conf.j2`:

```jinja
# Managed by golden/ubuntu/playbook.yml (pi_* in vars/local.yml). Read by pi-flash and pi.
DEFAULT_HOST={{ pi_default_host | default('') }}
WIFI_SSID={{ pi_wifi_ssid | default('') }}
WIFI_COUNTRY={{ pi_wifi_country | default('GB') }}
CABLE_IFACE={{ pi_cable_iface | default('') }}
{% for key in pi_authorized_keys | default([]) %}
KEY={{ key }}
{% endfor %}
```

Add the block to `golden/ubuntu/playbook.yml` immediately before the `# ------------------------------------------------------------------ help --` line:

```yaml
    # ---------------------------------------------------------- raspberry pi --
    # pi-flash writes a Pi's SD card; pi opens a shell on it (golden/raspberrypi).
    - name: Raspberry Pi tools
      ansible.builtin.copy:
        src: "{{ playbook_dir }}/../raspberrypi/"
        dest: /usr/local/share/golden/raspberrypi/
        mode: preserve
        directory_mode: "0755"

    - name: Raspberry Pi commands
      ansible.builtin.file:
        src: "/usr/local/share/golden/raspberrypi/{{ item }}"
        dest: "/usr/local/bin/{{ item }}"
        state: link
        force: true
      loop: [pi-flash, pi]

    - name: Raspberry Pi settings (pi_* in vars/local.yml)
      ansible.builtin.template:
        src: pi.conf.j2
        dest: /etc/golden/pi.conf
        mode: "0644"

    # Never start on their own: while one is up, the port cannot join a normal wired network.
    - name: Ethernet cable profiles for a Pi (pi local, pi share)
      ansible.builtin.copy:
        dest: "/etc/NetworkManager/system-connections/{{ item.name }}.nmconnection"
        mode: "0600"
        content: |
          [connection]
          id={{ item.name }}
          type=ethernet
          autoconnect=false

          [ethernet]

          [ipv4]
          method={{ item.ipv4 }}

          [ipv6]
          method={{ item.ipv6 }}
      loop:
        - { name: pi-local, ipv4: link-local, ipv6: link-local }
        - { name: pi-shared, ipv4: shared, ipv6: ignore }
      loop_control:
        label: "{{ item.name }}"
      notify: Reload NetworkManager connections
```

Append to `golden/ubuntu/vars/local.defaults.yml`:

```yaml
# Raspberry Pi (pi-flash, pi): see vars/local.yml.example.
pi_default_host: ""
pi_wifi_ssid: ""
pi_wifi_country: GB
pi_cable_iface: ""
pi_authorized_keys: []
```

Append to `golden/ubuntu/vars/local.yml.example`:

```yaml
# Raspberry Pi (pi-flash, pi). All optional.
pi_default_host: ""        # hostname `pi` uses when you give none, e.g. kitchen-pi
pi_wifi_ssid: ""           # Wi-Fi for new Pis; this laptop must have it saved. Empty: the current Wi-Fi
pi_wifi_country: GB        # Wi-Fi regulatory country
pi_cable_iface: ""         # Ethernet port for `pi local|share` when the laptop has several
pi_authorized_keys: []     # extra public keys, e.g. your other machines: ["ssh-ed25519 AAAA... you@pc"]
```

In `golden/ubuntu/files/golden-help`, insert before the line `  Other useful commands`:

```
  Raspberry Pi
    pi-flash --name HOST       Write Raspberry Pi OS to an SD card, set up for this laptop
                               (--no-wifi: cable/USB only; --password: also a login password)
    pi [HOST]                  Shell on the Pi: Wi-Fi, else USB, else the Ethernet cable
    pi [HOST] local | share    Ethernet cable only; share also gives the Pi this laptop's internet
    pi off                     Free the Ethernet port again

```

- [ ] **Step 3: Run the checks**

Run: `REPO=$PWD ansible-playbook $SCRATCH/check-pi-block.yml`
Expected: PASS; the message shows `WIFI_COUNTRY=GB`, empty `DEFAULT_HOST=`, no `KEY=` lines.

Run: `cd golden/ubuntu && ansible-playbook --syntax-check -i localhost, playbook.yml && cd -`
Expected: `playbook: playbook.yml`.

Run: `bash -n golden/ubuntu/files/golden-help && golden/ubuntu/files/golden-help | grep -A6 'Raspberry Pi'`
Expected: the new section.

- [ ] **Step 4: Commit**

```bash
git add golden/ubuntu/playbook.yml golden/ubuntu/templates/pi.conf.j2 golden/ubuntu/vars/local.defaults.yml golden/ubuntu/vars/local.yml.example golden/ubuntu/files/golden-help
git commit -m "feat(golden): install pi-flash and pi on golden laptops

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Documentation

**Files:**
- Create: `golden/raspberrypi/README.md`
- Modify: `golden/README.md` (new `## golden/raspberrypi` section at the end)
- Modify: `README.md` (Golden installs paragraph and Layout table)

- [ ] **Step 1: Write golden/raspberrypi/README.md**

```markdown
# golden/raspberrypi

Flash a Raspberry Pi's SD card from a golden laptop and open a shell on the Pi.
To change a Pi, flash it again: nothing on a Pi is patched in place.

Boards: Pi 3 B+, Pi 4, Pi 5, Zero 2 W (Raspberry Pi OS Lite, 64-bit).

## Flash

    pi-flash --name kitchen-pi

- Writes the pinned image (`image.conf`) from the MediCat stick if it is plugged in,
  otherwise downloads it, and checks its SHA-256 first.
- Only removable cards of 256 GB or less; it shows the card and asks you to type `yes`.
- The Pi gets your user name, your SSH key (`~/.ssh/id_ed25519.pub`, plus
  `pi_authorized_keys`), this laptop's time zone, and Wi-Fi: `pi_wifi_ssid` or the
  network you are on. The Wi-Fi password comes from this laptop's saved connection.
- `--no-wifi`: no Wi-Fi on the card; reach the Pi by cable (or USB on a Zero 2 W).
- `--password`: also a login password. Without it the Pi accepts SSH keys only and sudo
  asks for no password.
- Until the Pi's first boot, the card holds the Wi-Fi password in readable form.

## Connect

    pi kitchen-pi          Wi-Fi, else USB, else the Ethernet cable
    pi kitchen-pi local    cable only: link-local addresses, no routing
    pi kitchen-pi share    cable, and the Pi gets internet through this laptop
    pi off                 free the Ethernet port

Away from home the Pi knows no Wi-Fi, so use the cable: `pi local` needs no other
network; `pi share` adds internet (and so the right time). A Zero 2 W has no Ethernet
port; on boards with a USB device port (Zero 2 W, Pi 4, Pi 5) its USB cable works the same way.

`pi share` refuses to start unless a Raspberry Pi is on the cable, so the laptop never
serves addresses on someone else's network. It warns when a VPN is up, since the Pi's
traffic would go through it.

At login the Pi warns if it has seen under-voltage since boot: use a stronger supply.

## Settings

In `golden/ubuntu/vars/local.yml` (git-ignored): `pi_default_host`, `pi_wifi_ssid`,
`pi_wifi_country`, `pi_cable_iface`, `pi_authorized_keys`. See `local.yml.example`.

## Tests

    golden/raspberrypi/test/run.sh

No card, sudo or network needed. `pi-flash --name x --render-only DIR` writes the
first-boot files to DIR with placeholder secrets, for a look before flashing.

## Newer image

Edit `image.conf` (URL, file name, SHA-256 from raspberrypi.com) in a PR, then
`./make-stick.sh update` and `./make-stick.sh golden <stick>`.
```

- [ ] **Step 2: Add the section to golden/README.md**

Append:

```markdown
## golden/raspberrypi

Not an installer recipe: `pi-flash` writes a Raspberry Pi's SD card from a golden laptop,
and `pi` opens a shell on the Pi over Wi-Fi, USB or a direct Ethernet cable. The playbook
installs both and the stick carries the pinned image (`isos/RaspberryPi/`), so a Pi can be
flashed offline. Details: [raspberrypi/README.md](raspberrypi/README.md).
```

- [ ] **Step 3: Update README.md**

After the paragraph ending `[golden/README.md](golden/README.md).` in `## Golden installs`, add:

```markdown
`golden/raspberrypi/` flashes Raspberry Pi SD cards from a golden laptop (`pi-flash`) and
connects to the Pi (`pi`); `update` puts the pinned Raspberry Pi OS image on the stick.
```

In the Layout table, after the `golden/<name>/` row, add:

```markdown
| `golden/raspberrypi/` | `pi-flash` and `pi`: flash a Raspberry Pi's SD card and open a shell on it |
```

- [ ] **Step 4: Privacy check and commit**

Run: `git diff | grep -niE -f "$PRIVATE_PATTERNS" || echo clean`, where `$PRIVATE_PATTERNS` is a file outside the repo listing the user's network, host, device, work and personal names (one regex per line), plus `enx[0-9a-f]{12}` and `b8:27:eb:[0-9a-f]{2}:` for real interface names and MAC addresses.
Expected: `clean`.

```bash
git add golden/raspberrypi/README.md golden/README.md README.md
git commit -m "docs(raspberrypi): how to flash and connect to a Pi

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Push and open the PR

- [ ] **Step 1: Full test run and whole-branch privacy check**

Run: `golden/raspberrypi/test/run.sh`
Expected: all PASS (shellcheck PASS or SKIP with the install hint).

Run: `git log main..HEAD --format=%B | grep -niE -f "$PRIVATE_PATTERNS" || echo clean` and `git diff main...HEAD | grep -niE -f "$PRIVATE_PATTERNS" || echo clean` (same pattern file as Task 6)
Expected: `clean` twice.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/raspberrypi-flasher
gh pr create --title "feat(raspberrypi): pi-flash and pi for Raspberry Pis" --body "$(cat <<'EOF'
Adds golden/raspberrypi: pi-flash writes a pinned Raspberry Pi OS Lite image to an SD card and sets it up for first boot (user, SSH keys, Wi-Fi from the laptop's saved connection, a direct-cable network profile, USB networking on boards that support it). pi opens a shell on the Pi over Wi-Fi, USB or a direct Ethernet cable (link-local, or shared with the laptop's internet).

- Golden laptops get both commands, /etc/golden/pi.conf from vars/local.yml and two cable profiles that never start on their own.
- make-stick.sh update puts the pinned image on the stick (isos/RaspberryPi/).
- No secrets in the repo or on the stick; the Wi-Fi password is read at flash time.
- docs/explainer/index.html has no golden content, so it is unchanged.

Design: docs/superpowers/specs/2026-10-03-raspberrypi-flasher-design.md
Tests: golden/raspberrypi/test/run.sh (no hardware). Hardware test: Task 8 of the plan.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Tell the main PC's Claude session**

Give the user this to paste there: "A PR from the laptop adds a raspberry pi block to golden/ubuntu/playbook.yml just before the help section, plus pi_* defaults and a golden-help section. Please avoid editing those spots until it is merged, or rebase on it."

---

### Task 8: Hardware verification on the laptop (user runs the sudo parts)

- [ ] **Step 1: Apply the branch to this laptop**

User runs: `golden-update feat/raspberrypi-flasher`
Then: `rm -f ~/.local/bin/pi && hash -r && command -v pi pi-flash`
Expected: `/usr/local/bin/pi` and `/usr/local/bin/pi-flash`. (Review Focus 5: the old hand-made script must be gone.)

Check: `cat /etc/golden/pi.conf; nmcli -t -f NAME,AUTOCONNECT connection show | grep '^pi-'`
Expected: the settings file; `pi-local:no` and `pi-shared:no`.

- [ ] **Step 2: Flash the Pi 3 B+**

With a proper power supply for the Pi and its card in the laptop, user runs: `pi-flash --name <name>`
Expected: card shown, `yes` asked, write with progress, `Done. ... pi <name>`.

- [ ] **Step 3: Connect every way**

After about 2 minutes with the Pi on Wi-Fi: `pi <name>` (Wi-Fi). Then, with the Ethernet cable: `pi <name> local`, `pi <name> share` (check `ping -c1 1.1.1.1` on the Pi), `pi off`.
Expected: a shell each time; no host-key warning after the re-flash; `cloud-init status` on the Pi says `done`; `nmcli connection show` on the Pi lists `eth-direct`; no USB gadget set up (`rpi-usb-gadget status` says off) on the 3 B+.

- [ ] **Step 4: Under-voltage message**

On the old weak supply, log in: the `WARNING: under-voltage...` line shows. On the good supply after a reboot: no line.

- [ ] **Step 5: Merge**

When all pass: user merges the PR, then runs `golden-update` to return the laptop to main.
