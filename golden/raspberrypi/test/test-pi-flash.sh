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

# Missing PI_CONF is tolerated: pi-flash succeeds and produces valid user-data with exactly 1 SSH key
export PI_CONF="$T/nonexistent.conf"
"$RPI/pi-flash" --name testpi --no-wifi --render-only "$T/m" >/dev/null
python3 - "$T/m" <<'PY'
import sys, yaml
d = sys.argv[1]
ud = yaml.safe_load(open(f"{d}/user-data"))
assert ud["hostname"] == "testpi"
assert len(ud["users"][0]["ssh_authorized_keys"]) == 1, f"Expected 1 key, got {len(ud['users'][0]['ssh_authorized_keys'])}"
PY

# Mount points: only /media and /run/media mounts may be on a card
mounts_ok <<<"" || { echo "refused an unmounted card"; exit 1; }
printf '%s\n' "/media/u/bootfs" "" "/run/media/u/rootfs" | mounts_ok || { echo "refused desktop mounts"; exit 1; }
for m in / /boot /boot/efi /home /cdrom "[SWAP]" /mediax; do
    if printf '%s\n' "/media/u/bootfs" "$m" | mounts_ok; then echo "accepted a card with $m mounted"; exit 1; fi
done

# choose_card through a fake lsblk and findmnt. The image is on sdb (the MediCat stick);
# sdc has / mounted (a live system); sda and sdd are cards.
F="$T/fake"; mkdir -p "$F"
cat > "$T/bin/lsblk" <<'EOC'
#!/bin/sh
case "$*" in
  "-dnbo NAME,RM,SIZE,TYPE") [ -e "$F/lsblk-fails" ] && exit 1; cat "$F/disks" ;;
  "-lnpo MOUNTPOINTS /dev/"*) d=${3#/dev/}; [ -e "$F/mnt.$d" ] && cat "$F/mnt.$d"; exit 0 ;;
  "-lnso NAME,TYPE /dev/sdb1") printf '%s\n' "sdb1 part" "sdb  disk" ;;
  "-o NAME,SIZE,MODEL,LABEL /dev/"*) echo "INFO ${3#/dev/}" ;;
  "-lnpo NAME,TYPE,MOUNTPOINTS /dev/sda") printf '%s\n' "/dev/sda disk" "/dev/sda1 part /media/u/bootfs" "/dev/sda2 part" ;;
  *) echo "lsblk: unexpected $*" >&2; exit 1 ;;
esac
EOC
cat > "$T/bin/findmnt" <<'EOC'
#!/bin/sh
[ -e "$F/findmnt-fails" ] && exit 1
echo /dev/sdb1
EOC
chmod +x "$T/bin/lsblk" "$T/bin/findmnt"; export F
printf '%s\n' "sda 1 31914983424 disk" "sdb 1 61530439680 disk" "sdc 1 15931539456 disk" "sdd 1 7969177600 disk" \
              "nvme0n1 0 1000204886016 disk" > "$F/disks"
echo "/" > "$F/mnt.sdc"; echo "/media/u/bootfs" > "$F/mnt.sdd"
IMAGE=/media/u/MEDICAT/RaspberryPi/image.img.xz
pick() { (DEVICE=$1; choose_card; echo "CHOSEN $DEVICE") <<<"yes" > "$T/out" 2>&1; }
if pick ""; then echo "chose with two cards in"; exit 1; fi
grep -q "INFO sda" "$T/out" && grep -q "INFO sdd" "$T/out" || { echo "did not list the cards:"; cat "$T/out"; exit 1; }
if grep -q "INFO sd[bc]" "$T/out"; then echo "listed the image stick or a system disk"; cat "$T/out"; exit 1; fi
if pick /dev/sdb; then echo "accepted the disk holding the image"; exit 1; fi
grep -q "holds the Raspberry Pi image" "$T/out" || { cat "$T/out"; exit 1; }
if pick /dev/sdc; then echo "accepted a disk with / mounted"; exit 1; fi
grep -q "mounted outside /media" "$T/out" || { cat "$T/out"; exit 1; }
pick /dev/sdd || { echo "refused a card mounted by the desktop"; cat "$T/out"; exit 1; }
rm "$F/mnt.sdd"; sed -i '/^sdd /d' "$F/disks"
pick "" || { echo "refused the one card"; cat "$T/out"; exit 1; }
grep -q "CHOSEN /dev/sda" "$T/out" || { cat "$T/out"; exit 1; }
touch "$F/findmnt-fails"
if pick ""; then echo "chose a card without knowing where the image is"; exit 1; fi
rm "$F/findmnt-fails"; touch "$F/lsblk-fails"
if pick ""; then echo "chose a card when lsblk failed"; exit 1; fi
rm "$F/lsblk-fails"

# write_card: a partition that will not unmount stops everything before dd (exit 2)
printf '#!/bin/sh\necho "$*" >> "$F/udisks.log"\nexit 1\n' > "$T/bin/udisksctl"
printf '#!/bin/sh\necho "$*" >> "$F/sudo.log"\nexit 0\n' > "$T/bin/sudo"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/xzcat"
chmod +x "$T/bin/udisksctl" "$T/bin/sudo" "$T/bin/xzcat"
set +e; (DEVICE=/dev/sda; write_card) > "$T/out" 2>&1; rc=$?; set -e
[[ $rc == 2 ]] || { echo "write_card with a busy partition exited $rc"; cat "$T/out"; exit 1; }
[[ ! -e "$F/sudo.log" ]] || { echo "wrote to a card with a mounted partition"; exit 1; }
grep -qx "unmount -b /dev/sda1" "$F/udisks.log" || { echo "did not unmount the mounted partition"; exit 1; }
if grep -q sda2 "$F/udisks.log"; then echo "unmounted a partition that was not mounted"; exit 1; fi

# Download: to a .part file, resumed, renamed only when complete; failure exits 1
cat > "$T/bin/curl" <<'EOC'
#!/bin/sh
echo "$*" > "$F/curl.args"
for a; do [ "$prev" = -o ] && out=$a; prev=$a; done
printf 'part' >> "$out"
[ -e "$F/curl-fails" ] && exit 18
printf 'rest' >> "$out"
EOC
chmod +x "$T/bin/curl"; touch "$F/curl-fails"
dl() { (HERE="$T/nohere" USER=nobody-test CACHE="$T/cache" PI_IMAGE_FILE=pi.img.xz PI_IMAGE_URL=https://example.invalid/pi.img.xz; find_image) > "$T/out" 2>&1; }
set +e; dl; rc=$?; set -e
[[ $rc == 1 ]] || { echo "failed download exited $rc"; cat "$T/out"; exit 1; }
[[ ! -e "$T/cache/pi.img.xz" && -s "$T/cache/pi.img.xz.part" ]] || { echo "partial download not kept as .part"; ls -l "$T/cache"; exit 1; }
rm "$F/curl-fails"
dl || { echo "resumed download failed"; cat "$T/out"; exit 1; }
grep -q -- "-C - -o $T/cache/pi.img.xz.part" "$F/curl.args" || { echo "not resumed into .part:"; cat "$F/curl.args"; exit 1; }
[[ "$(cat "$T/cache/pi.img.xz")" == partpartrest && ! -e "$T/cache/pi.img.xz.part" ]] || { echo "download not resumed and renamed"; exit 1; }
[[ "$(tail -n1 "$T/out")" == "$T/cache/pi.img.xz" ]] || { echo "find_image printed: $(cat "$T/out")"; exit 1; }
