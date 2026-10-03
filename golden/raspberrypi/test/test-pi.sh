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

# Missing PI_CONF is tolerated: cable_iface works and conf_get returns empty
export PI_CONF="$T/nonexistent.conf"
# Reset to single port for this test: remove eth9 setup
rm -rf "$T/sys/eth9"
cat > "$T/bin/nmcli" <<'EOF'
#!/bin/sh
[ "$*" = "-t -f DEVICE,TYPE device" ] && printf '%s\n' "wlp1s0:wifi" "enxdock:ethernet" "enxusb:ethernet" "veth0:ethernet" "docker0:bridge"
exit 0
EOF
[[ "$(cable_iface)" == enxdock ]] || { echo "cable_iface with missing conf returned: $(cable_iface)"; exit 1; }
result=$(conf_get DEFAULT_HOST); [[ $? -eq 0 ]] || { echo "conf_get failed with missing file"; exit 1; }
[[ -z "$result" ]] || { echo "conf_get DEFAULT_HOST returned: '$result'"; exit 1; }
