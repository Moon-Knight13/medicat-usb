#!/usr/bin/env bash
# pi-flash: render-only output, card filter, device check, Wi-Fi lookup. No card, no sudo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; RPI="$HERE/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOne test@one" > "$T/key.pub"
cat > "$T/pi.conf" <<'EOC'
WIFI_SSID=example-wifi
WIFI_COUNTRY=DE
KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyTwo test@two
EOC
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
cat > "$T/bin/nmcli" <<'EOC'
#!/bin/sh
case "$*" in
  "-t -f UUID,TYPE connection show") printf '%s\n' "u1:802-11-wireless" "u2:802-3-ethernet" "u3:802-11-wireless" ;;
  "-t -f UUID,TYPE connection show --active") printf '%s\n' "u2:802-3-ethernet" "u3:802-11-wireless" ;;
  "-g 802-11-wireless.ssid connection show uuid u1") echo 'Home\: Net' ;;
  "-g 802-11-wireless.ssid connection show uuid u3") echo 'Cafe' ;;
esac
EOC
chmod +x "$T/bin/nmcli"
PATH="$T/bin:$PATH"
[[ "$(wifi_connection_for 'Home: Net')" == u1 ]] || { echo "wifi_connection_for failed"; exit 1; }
[[ -z "$(wifi_connection_for 'Nowhere')" ]] || { echo "found a network that does not exist"; exit 1; }
[[ "$(active_wifi_uuid)" == u3 ]] || { echo "active_wifi_uuid failed"; exit 1; }
