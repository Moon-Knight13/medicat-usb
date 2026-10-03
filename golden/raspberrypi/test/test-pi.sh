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

# pi share: the Pi must be the only device on the cable (FAILED/INCOMPLETE entries ignored)
printf '%s\n' "fe80::2 lladdr b8:27:eb:aa:bb:cc REACHABLE" "fe80::9 FAILED" "fe80::8 INCOMPLETE" > "$T/neigh"
cat > "$T/bin/ip" <<'EOC'
#!/bin/sh
for dev; do :; done                     # per-port file if there is one, else the shared one
case "$*" in
  "-6 neigh show dev "*) f=neigh ;;
  "-6 route show dev "*) f=routes ;;
  "-4 -o addr show dev "*) f=addrs ;;
  *) echo "ip: unexpected $*" >&2; exit 1 ;;
esac
if [ -e "$T/$f.$dev" ]; then cat "$T/$f.$dev"; else cat "$T/$f"; fi
EOC
chmod +x "$T/bin/ip"; export T; : > "$T/routes"; : > "$T/addrs"
only_pi_on_cable enxdock || { echo "refused a lone Pi"; exit 1; }
printf '%s\n' "fe80::2 lladdr b8:27:eb:aa:bb:cc REACHABLE" "2001:db8::2 lladdr B8:27:EB:AA:BB:CC STALE" > "$T/neigh"
only_pi_on_cable enxdock || { echo "counted one Pi twice"; exit 1; }
printf '%s\n' "fe80::1 lladdr 00:11:22:33:44:55 REACHABLE" "fe80::2 lladdr b8:27:eb:aa:bb:cc STALE" > "$T/neigh"
if only_pi_on_cable enxdock; then echo "allowed sharing with another device on the cable"; exit 1; fi
printf '%s\n' "fe80::1 lladdr 00:11:22:33:44:55 REACHABLE" > "$T/neigh"
if only_pi_on_cable enxdock; then echo "allowed sharing with no Pi"; exit 1; fi

# Signs of a real network on the port: a router neighbour, an RA or default route, a lease
printf '#!/bin/sh\n[ "$*" = "-g GENERAL.CONNECTION device show enxdock" ] && cat "$T/conn.enxdock" 2>/dev/null\nexit 0\n' > "$T/bin/nmcli"
chmod +x "$T/bin/nmcli"
printf '%s\n' "fe80::2 lladdr b8:27:eb:aa:bb:cc REACHABLE" > "$T/neigh"
echo "fe80::/64 proto kernel metric 256 pref medium" > "$T/routes"
echo "3: enxdock    inet 169.254.7.7/16 brd 169.254.255.255 scope link" > "$T/addrs"
cable_is_private enxdock || { echo "a lone Pi on link-local looked like a network"; exit 1; }
echo "fe80::2 lladdr b8:27:eb:aa:bb:cc router REACHABLE" > "$T/neigh"
if cable_is_private enxdock; then echo "missed a router neighbour"; exit 1; fi
echo "fe80::2 lladdr b8:27:eb:aa:bb:cc REACHABLE" > "$T/neigh"
echo "default via fe80::1 proto ra metric 100 pref medium" > "$T/routes"
if cable_is_private enxdock; then echo "missed a default route"; exit 1; fi
echo "2001:db8::/64 proto ra metric 100 pref medium" > "$T/routes"
if cable_is_private enxdock; then echo "missed an RA route"; exit 1; fi
: > "$T/routes"
echo "3: enxdock    inet 192.0.2.10/24 brd 192.0.2.255 scope global dynamic" > "$T/addrs"
echo "Wired connection 1" > "$T/conn.enxdock"
if cable_is_private enxdock; then echo "missed a DHCP lease"; exit 1; fi
echo "pi-shared" > "$T/conn.enxdock"
cable_is_private enxdock || { echo "pi-shared's own address looked like a network"; exit 1; }
: > "$T/addrs"; rm -f "$T/conn.enxdock"

# Whole runs with fakes only: nmcli and ssh record their calls, no real sleeping
cat > "$T/bin/nmcli" <<'EOC'
#!/bin/sh
echo "$*" >> "$NMLOG"
[ "$*" = "-t -f DEVICE,TYPE device" ] && cat "$T/devices"
case "$*" in "-g GENERAL.CONNECTION device show "*) cat "$T/conn.$5" 2>/dev/null ;; esac
exit 0
EOC
printf '#!/bin/sh\necho "$*" >> "$NMLOG"\nexit 0\n' > "$T/bin/ssh"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/ping"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*
export NMLOG="$T/nm.log" PI_CONF="$T/pi.conf"; echo "enxdock:ethernet" > "$T/devices"
: > "$T/pi.conf"
[[ "$(command -v nmcli)" == "$T/bin/nmcli" && "$(command -v ssh)" == "$T/bin/ssh" ]] || { echo "fakes not first on PATH"; exit 1; }
released() { grep -qx "connection down pi-shared" "$NMLOG" && grep -qx "connection down pi-local" "$NMLOG"; }

# No Pi on the cable: the port is released again, and the user is told
: > "$T/neigh"; : > "$NMLOG"
if "$RPI/pi" local > "$T/out" 2>&1; then echo "pi local succeeded with no Pi"; exit 1; fi
released || { echo "no-Pi path left the port held:"; cat "$NMLOG"; exit 1; }
grep -q "released" "$T/out" || { echo "no-Pi path did not say the port was released"; cat "$T/out"; exit 1; }

# Bare pi with no host: says what it tried before the cable
: > "$NMLOG"
if "$RPI/pi" > "$T/out" 2>&1; then echo "bare pi succeeded with no Pi"; exit 1; fi
grep -q "Wi-Fi skipped" "$T/out" && grep -q "USB" "$T/out" || { echo "bare pi did not say what it tried:"; cat "$T/out"; exit 1; }
released || { echo "bare pi left the port held"; exit 1; }

# pi share with another device on the cable: refused, pi-shared never brought up, port released
printf '%s\n' "fe80::1 lladdr 00:11:22:33:44:55 REACHABLE" "fe80::2 lladdr b8:27:eb:aa:bb:cc STALE" > "$T/neigh"; : > "$NMLOG"
if "$RPI/pi" share > "$T/out" 2>&1; then echo "pi share succeeded beside another device"; exit 1; fi
grep -q "other devices on this cable; is it plugged into a network? use: pi local" "$T/out" || { cat "$T/out"; exit 1; }
if grep -q "connection up pi-shared" "$NMLOG"; then echo "pi-shared brought up beside another device"; exit 1; fi
released || { echo "share refusal left the port held"; exit 1; }

# pi share with only the Pi: shares, then says which profile holds the port before ssh
printf '%s\n' "fe80::2 lladdr b8:27:eb:aa:bb:cc REACHABLE" > "$T/neigh"; : > "$NMLOG"
"$RPI/pi" share > "$T/out" 2>&1 || { echo "pi share failed with a lone Pi:"; cat "$T/out"; exit 1; }
grep -q "connection up pi-shared ifname enxdock" "$NMLOG" || { echo "did not share"; exit 1; }
grep -q "Ethernet port enxdock held by pi-shared; 'pi off' frees it." "$T/out" || { cat "$T/out"; exit 1; }
grep -q "@fe80::2%enxdock" "$NMLOG" || { echo "did not ssh to the Pi"; exit 1; }

# pi share where the one neighbour is a router: refused like any network
printf '%s\n' "fe80::2 lladdr b8:27:eb:aa:bb:cc router REACHABLE" > "$T/neigh"; : > "$NMLOG"
if "$RPI/pi" share > "$T/out" 2>&1; then echo "pi share succeeded beside a router"; exit 1; fi
grep -q "other devices on this cable; is it plugged into a network? use: pi local" "$T/out" || { cat "$T/out"; exit 1; }
if grep -q "connection up pi-shared" "$NMLOG"; then echo "pi-shared brought up beside a router"; exit 1; fi
released || { echo "router refusal left the port held"; exit 1; }

# Port on the laptop's own network: pi does not touch it, in any mode
echo "Wired connection 1" > "$T/conn.enxdock"
echo "fe80::1 lladdr 00:11:22:33:44:55 router REACHABLE" > "$T/neigh"
for mode in local share ""; do
    : > "$NMLOG"
    if "$RPI/pi" $mode > "$T/out" 2>&1; then echo "pi $mode took over a network port"; exit 1; fi
    grep -q "every Ethernet port is in use (enxdock on Wired connection 1); unplug one from the network or plug in a USB Ethernet adapter for the Pi" "$T/out" || { cat "$T/out"; exit 1; }
    if grep -q "^connection \(up\|down\)" "$NMLOG"; then echo "pi $mode touched a network port:"; cat "$NMLOG"; exit 1; fi
done

# A port only trying (waiting for DHCP, no router, no lease) may be taken
: > "$T/neigh"; : > "$NMLOG"
if "$RPI/pi" local > "$T/out" 2>&1; then echo "pi local found a Pi that is not there"; exit 1; fi
grep -q "connection up pi-local ifname enxdock" "$NMLOG" || { echo "did not take a port that was only trying"; cat "$T/out"; exit 1; }
rm -f "$T/conn.enxdock"

# pi off only brings the pi profiles down
: > "$NMLOG"; "$RPI/pi" off >/dev/null
[[ "$(cat "$NMLOG")" == $'connection down pi-shared\nconnection down pi-local' ]] || { echo "pi off did more:"; cat "$NMLOG"; exit 1; }

# Docked on a wired network plus a USB adapter for the Pi: the adapter is chosen, the dock skipped
mkdir -p "$T/sys/enxpi/device"; ln -s ../../../drivers/ax88179_178a "$T/sys/enxpi/device/driver"
printf '%s\n' "enxdock:ethernet" "enxpi:ethernet" > "$T/devices"
echo "Wired connection 1" > "$T/conn.enxdock"
echo "fe80::1 lladdr 00:11:22:33:44:55 router REACHABLE" > "$T/neigh.enxdock"
echo "fe80::2 lladdr b8:27:eb:aa:bb:cc REACHABLE" > "$T/neigh"
: > "$NMLOG"
"$RPI/pi" local > "$T/out" 2>&1 || { echo "pi local failed beside a docked network:"; cat "$T/out"; exit 1; }
grep -q "connection up pi-local ifname enxpi" "$NMLOG" || { echo "adapter not chosen"; cat "$NMLOG"; exit 1; }
grep -q "in use.*enxdock on Wired connection 1" "$T/out" || { echo "skipped port not reported"; cat "$T/out"; exit 1; }
if grep -q "connection .* enxdock" "$NMLOG"; then echo "touched the docked port"; exit 1; fi

# pi_cable_iface pointing at a port in use: refused, port untouched
echo "CABLE_IFACE=enxdock" > "$T/pi.conf"; : > "$NMLOG"
if "$RPI/pi" local > "$T/out" 2>&1; then echo "took over the configured port on a network"; exit 1; fi
grep -q "enxdock is connected to a network (Wired connection 1); pi will not take it over" "$T/out" || { cat "$T/out"; exit 1; }
if grep -q "^connection up" "$NMLOG"; then echo "brought a profile up on a configured port in use"; exit 1; fi
: > "$T/pi.conf"

# Two free ports and no pi_cable_iface: refuse, listing them
rm -f "$T/conn.enxdock" "$T/neigh.enxdock"; : > "$NMLOG"
if "$RPI/pi" local > "$T/out" 2>&1; then echo "guessed between two free ports"; exit 1; fi
grep -q "enxdock" "$T/out" && grep -q "enxpi" "$T/out" && grep -q "pi_cable_iface" "$T/out" || { cat "$T/out"; exit 1; }
if grep -q "^connection up" "$NMLOG"; then echo "brought a profile up without a port"; exit 1; fi
