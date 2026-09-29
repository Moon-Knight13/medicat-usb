#!/usr/bin/env bash
# make-stick.sh — build a MediCat USB (Ventoy + MediCat + your own ISOs).
#
#   ./make-stick.sh update            fetch latest Ventoy, MediCat and Ubuntu ISO (skips what is current)
#   ./make-stick.sh list              show USB drives
#   ./make-stick.sh build /dev/sdX    wipe that USB drive and build the stick (asks for confirmation + sudo)
#   ./make-stick.sh status            show what is staged in this folder
#
# Options for build:  --skip-test   skip the f3probe counterfeit/health test
#                     --gpt / --mbr override the partition style from make-stick.conf
#
# Layout of this folder:
#   MediCat.USB.<ver>.7z        the MediCat archive (SHA-256 verified, marker file <name>.ok)
#   ventoy/                     Ventoy release, extracted
#   isos/<Folder>/<file>.iso    anything here is copied to the same path on the stick.
#                               Ubuntu goes in isos/Live_Operating_Systems/Ubuntu/ automatically.
#   golden/<name>/autoinstall.yaml  unattended install recipe for isos/Live_Operating_Systems/<Name>/*.iso
#   extra-isos.txt              optional, one "Folder/Sub|URL" per line, downloaded by update
#   make-stick.conf             repeatable settings (LTS-only, flavour, partition style, stick test)
#   logs/                       build and update logs
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISOS="$KIT/isos"
LOGS="$KIT/logs"
INSTALLER_URL="https://github.com/mon5termatt/medicat_installer/releases/latest/download/Medicat_Installer.sh"
UBUNTU_BASE="https://releases.ubuntu.com"
# Repeatable settings live in make-stick.conf (committed); env vars override it.
# shellcheck disable=SC1091
[[ -f "$KIT/make-stick.conf" ]] && source "$KIT/make-stick.conf"
UBUNTU_FLAVOUR="${UBUNTU_FLAVOUR:-desktop}"   # desktop or server
UBUNTU_LTS_ONLY="${UBUNTU_LTS_ONLY:-0}"        # 1 = track only LTS releases (xx.04 of even years)
PARTITION_STYLE="${PARTITION_STYLE:-mbr}"      # mbr or gpt
STICK_TEST="${STICK_TEST:-1}"                  # 1 = f3probe before writing
UBUNTU_DIR="$ISOS/Live_Operating_Systems/Ubuntu"
mkdir -p "$ISOS" "$LOGS" "$UBUNTU_DIR"

c_info() { printf '\033[1;36m%s\033[0m\n' "$*"; }
c_ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
die()    { c_err "ERROR: $*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1  (install with: sudo apt install $2)"; }

fetch() {  # fetch URL OUTFILE  — resumable multi-connection download
    local url=$1 out=$2
    if command -v aria2c >/dev/null 2>&1; then
        aria2c -x 8 -s 8 -k 1M -c --file-allocation=none --console-log-level=warn \
               --summary-interval=30 -d "$(dirname "$out")" -o "$(basename "$out")" "$url"
    else
        wget -c --show-progress -O "$out" "$url"
    fi
}

verify_sha256() {  # verify_sha256 FILE EXPECTED
    c_info "Verifying SHA-256 of $(basename "$1") (takes a minute or two)..."
    local got; got=$(sha256sum "$1" | awk '{print $1}')
    [[ "$got" == "$2" ]] || { rm -f "$1.ok"; die "checksum mismatch for $1: got $got expected $2"; }
    echo "$2" > "$1.ok"
    c_ok "Checksum OK"
}

# ---------------------------------------------------------------- update ----
update_ventoy() {
    c_info "== Ventoy =="
    local json latest; json=$(curl -sL https://api.github.com/repos/ventoy/Ventoy/releases/latest) || json=""
    latest=$(printf '%s' "$json" | grep -m1 '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/' || true)
    [[ -n "$latest" ]] || { c_warn "Could not query GitHub for the latest Ventoy; keeping current."; return; }
    local current="none"; [[ -f "$KIT/ventoy/ventoy/version" ]] && current=$(cat "$KIT/ventoy/ventoy/version")
    if [[ "$current" == "$latest" ]]; then c_ok "Ventoy $current is current"; return; fi
    c_info "Downloading Ventoy $latest (had $current)..."
    local tgz="$KIT/ventoy-$latest-linux.tar.gz"
    fetch "https://github.com/ventoy/Ventoy/releases/download/v$latest/ventoy-$latest-linux.tar.gz" "$tgz"
    rm -rf "$KIT/ventoy.new" && mkdir "$KIT/ventoy.new"
    tar -xf "$tgz" -C "$KIT/ventoy.new"
    rm -rf "$KIT/ventoy" && mv "$KIT/ventoy.new/ventoy-$latest" "$KIT/ventoy" && rm -rf "$KIT/ventoy.new" "$tgz"
    c_ok "Ventoy $latest ready"
}

update_medicat() {
    c_info "== MediCat =="
    local script="$KIT/Medicat_Installer.sh"
    curl -sL -o "$script.tmp" "$INSTALLER_URL" && mv "$script.tmp" "$script" \
        || { c_warn "Could not fetch the MediCat installer to learn the latest version; keeping current."; return; }
    local ver hash url1 url2
    ver=$(grep -m1 '^MedicatVersion=' "$script" | cut -d'"' -f2 || true)
    hash=$(grep -m1 '^Medicat256Hash=' "$script" | cut -d"'" -f2 || true)
    [[ -n "$ver" && -n "$hash" ]] || die "could not parse MedicatVersion/Medicat256Hash from installer script"
    local file="$KIT/MediCat.USB.$ver.7z"
    url1="https://files.medicatusb.com/files/$ver/MediCat.USB.$ver.7z"
    url2="https://files.dog/OD%20Rips/MediCat/$ver/MediCat.USB.$ver.7z"
    if [[ -f "$file.ok" && "$(cat "$file.ok")" == "$hash" && -f "$file" ]]; then
        c_ok "MediCat $ver is current and verified"; return
    fi
    if [[ ! -f "$file" ]]; then
        c_info "Downloading MediCat $ver (about 21 GB, resumable)..."
        fetch "$url1" "$file" || fetch "$url2" "$file" || die "MediCat download failed from both mirrors"
    fi
    verify_sha256 "$file" "$hash"
    local old
    for old in "$KIT"/MediCat.USB.*.7z; do
        [[ -f "$old" && "$old" != "$file" ]] && c_warn "Older MediCat archive still present (delete to free space): $(basename "$old")"
    done
    c_ok "MediCat $ver ready"
}

update_ubuntu() {
    c_info "== Ubuntu ($UBUNTU_FLAVOUR, amd64$( [[ "$UBUNTU_LTS_ONLY" == "1" ]] && echo ", LTS only")) =="
    local index rel; index=$(curl -sL "$UBUNTU_BASE/") || index=""
    local filter='.'; [[ "$UBUNTU_LTS_ONLY" == "1" ]] && filter='^[0-9]*[02468]\.04(\.[0-9]+)?$'
    rel=$(printf '%s' "$index" | grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' \
                     | sed -E 's/href="([^/]+)\/"/\1/' | grep -E "$filter" | sort -uV | tail -1 || true)
    [[ -n "$rel" ]] || { c_warn "Could not read $UBUNTU_BASE; keeping current Ubuntu ISO."; return; }
    local sums; sums=$(curl -sL "$UBUNTU_BASE/$rel/SHA256SUMS") || { c_warn "No SHA256SUMS for $rel"; return; }
    local line; line=$(echo "$sums" | grep -E "ubuntu-[0-9.]+-$UBUNTU_FLAVOUR-amd64\.iso" | sort -V | tail -1 || true)
    [[ -n "$line" ]] || { c_warn "No $UBUNTU_FLAVOUR amd64 ISO listed for Ubuntu $rel"; return; }
    local hash iso; hash=$(echo "$line" | awk '{print $1}'); iso=$(echo "$line" | awk '{print $2}' | sed 's/^\*//')
    local file="$UBUNTU_DIR/$iso"
    if [[ -f "$file.ok" && "$(cat "$file.ok")" == "$hash" && -f "$file" ]]; then
        c_ok "Ubuntu $iso is current and verified"; return
    fi
    [[ -f "$file" ]] || { c_info "Downloading $iso..."; fetch "$UBUNTU_BASE/$rel/$iso" "$file"; }
    verify_sha256 "$file" "$hash"
    for old in "$UBUNTU_DIR"/ubuntu-*-"$UBUNTU_FLAVOUR"-amd64.iso; do
        [[ "$old" != "$file" && -f "$old" ]] && { c_warn "Removing older $(basename "$old")"; rm -f "$old" "$old.ok"; }
    done
    c_ok "Ubuntu $iso ready"
}

update_extra() {
    local list="$KIT/extra-isos.txt"
    [[ -f "$list" ]] || return 0
    c_info "== Extra ISOs from extra-isos.txt =="
    while IFS='|' read -r folder url; do
        [[ -z "$folder" || "$folder" == \#* ]] && continue
        folder=$(echo "$folder" | xargs); url=$(echo "$url" | xargs)
        local dest; dest="$ISOS/$folder/$(basename "$url")"
        mkdir -p "$(dirname "$dest")"
        if [[ -f "$dest" ]]; then c_ok "have $folder/$(basename "$url")"; else c_info "Downloading $url"; fetch "$url" "$dest"; fi
    done < "$list"
}

cmd_update() {
    need curl curl; need sha256sum coreutils; need tar tar
    update_ventoy; update_medicat; update_ubuntu; update_extra
    echo; cmd_status
}

# ---------------------------------------------------------------- status ----
cmd_status() {
    c_info "Staged in $KIT:"
    [[ -f "$KIT/ventoy/ventoy/version" ]] && echo "  Ventoy   $(cat "$KIT/ventoy/ventoy/version")" || echo "  Ventoy   (missing, run update)"
    local m; m=$(ls "$KIT"/MediCat.USB.*.7z 2>/dev/null | sort -V | tail -1 || true)
    if [[ -n "$m" ]]; then echo "  MediCat  $(basename "$m")  $( [[ -f "$m.ok" ]] && echo verified || echo UNVERIFIED )"; else echo "  MediCat  (missing, run update)"; fi
    echo "  ISOs to copy (from isos/):"
    find "$ISOS" -type f \( -iname '*.iso' -o -iname '*.img' -o -iname '*.wim' -o -iname '*.vhd*' \) -printf '    %P  (%s bytes)\n' 2>/dev/null | sort || true
}

# ------------------------------------------------------------------ list ----
cmd_list() {
    c_info "USB drives:"
    lsblk -dno NAME,SIZE,TRAN,MODEL,VENDOR | awk '$3=="usb"{printf "  /dev/%s  %s  %s %s\n",$1,$2,$4,$5}'
    [[ -n "$(lsblk -dno TRAN | grep usb || true)" ]] || echo "  (none plugged in)"
}

# ---------------------------------------------------------------- golden ----
# Copy golden/ onto the stick and register each golden/<name>/autoinstall.yaml
# with Ventoy's auto_install plugin for the ISOs in isos/Live_Operating_Systems/<Name>/.
# Ventoy then offers "interactive install" or "golden install" when that ISO is picked.
install_golden() {
    local mnt=$1
    [[ -d "$KIT/golden" ]] || { echo "  (no golden/ folder)"; return; }
    sudo rm -rf "$mnt/golden" && sudo cp -a "$KIT/golden" "$mnt/golden"
    sudo python3 - "$mnt" "$KIT" <<'PY'
import json, os, sys, glob
mnt, kit = sys.argv[1], sys.argv[2]
cfg_path = os.path.join(mnt, "ventoy", "ventoy.json")
cfg = json.load(open(cfg_path)) if os.path.exists(cfg_path) else {}
auto = [e for e in cfg.get("auto_install", []) if not str(e.get("parent", e.get("image", ""))).startswith("/Live_Operating_Systems/")]
alias = [e for e in cfg.get("menu_alias", []) if "golden" not in str(e.get("alias", "")).lower()]
for tmpl in sorted(glob.glob(os.path.join(kit, "golden", "*", "autoinstall.yaml"))):
    name = os.path.basename(os.path.dirname(tmpl))            # e.g. ubuntu
    folder = os.path.join(mnt, "Live_Operating_Systems", name.capitalize())
    isos = sorted(glob.glob(os.path.join(folder, "*.iso")))
    if not isos:
        print(f"  golden/{name}: no ISO under Live_Operating_Systems/{name.capitalize()}, skipped"); continue
    auto.append({"parent": f"/Live_Operating_Systems/{name.capitalize()}",
                 "template": [f"/golden/{name}/autoinstall.yaml"], "timeout": 15})
    for iso in isos:
        rel = "/Live_Operating_Systems/" + name.capitalize() + "/" + os.path.basename(iso)
        alias.append({"image": rel, "alias": f"{name.capitalize()} {os.path.basename(iso).split('-')[1]} (golden install available)"})
    print(f"  golden/{name}: registered for {len(isos)} ISO(s)")
cfg["auto_install"], cfg["menu_alias"] = auto, alias
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
json.dump(cfg, open(cfg_path, "w"), indent=2)
PY
}

# ----------------------------------------------------------------- build ----
cmd_build() {
    local dev="" skip_test=0 gpt=""
    [[ "$STICK_TEST" == "0" ]] && skip_test=1
    [[ "$PARTITION_STYLE" == "gpt" ]] && gpt="-g"
    for a in "$@"; do
        case "$a" in
            --skip-test) skip_test=1 ;;
            --gpt) gpt="-g" ;;
            --mbr) gpt="" ;;
            /dev/*) dev=$a ;;
            *) die "unknown argument: $a" ;;
        esac
    done
    [[ -n "$dev" ]] || { cmd_list; die "usage: $0 build /dev/sdX [--skip-test] [--gpt]"; }
    [[ -b "$dev" ]] || die "$dev is not a block device"
    [[ "$(lsblk -dno TRAN "$dev")" == "usb" ]] || die "$dev is not a USB drive, refusing"
    [[ "$(lsblk -dno TYPE "$dev")" == "disk" ]] || die "$dev is a partition; give the whole disk (e.g. /dev/sdb)"
    need 7z p7zip-full; need mkntfs ntfs-3g; need parted parted; need mkfs.vfat dosfstools
    [[ -f "$KIT/ventoy/Ventoy2Disk.sh" ]] || die "Ventoy not staged; run: $0 update"
    local archive; archive=$(ls "$KIT"/MediCat.USB.*.7z 2>/dev/null | sort -V | tail -1 || true)
    [[ -n "$archive" ]] || die "MediCat archive not staged; run: $0 update"
    [[ -f "$archive.ok" ]] || die "$(basename "$archive") is not verified; run: $0 update"

    echo; lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev"; echo
    c_warn "EVERYTHING on $dev ($(lsblk -dno SIZE,MODEL "$dev")) will be erased."
    read -r -p "Type the device name to confirm ($(basename "$dev")): " ans < /dev/tty
    [[ "$ans" == "$(basename "$dev")" ]] || die "cancelled"

    local log; log="$LOGS/build-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$log") 2>&1
    c_info "Log: $log"

    sudo -v
    ( while true; do sleep 60; sudo -n true 2>/dev/null || exit; done ) &   # keep sudo alive during the long extract
    local keepalive=$!
    # shellcheck disable=SC2064  # expand now: keepalive is local and out of scope when EXIT fires
    trap "kill $keepalive 2>/dev/null || true" EXIT

    sudo umount "$dev"* 2>/dev/null || true

    if [[ $skip_test -eq 0 ]]; then
        if command -v f3probe >/dev/null 2>&1; then
            c_info "== Testing the stick for counterfeit capacity (f3probe, a few minutes) =="
            local out; out=$(sudo f3probe --destructive "$dev" 2>&1 | tee /dev/tty) || true
            echo "$out" | grep -q "Good news" || die "f3probe did not pass this stick. Do not use it. (use --skip-test to override)"
        else
            c_warn "f3probe not installed (sudo apt install f3); skipping counterfeit test"
        fi
    fi

    c_info "== [1/5] Ventoy install ($( [[ -n "$gpt" ]] && echo GPT || echo MBR )) =="
    ( cd "$KIT/ventoy" && printf 'y\ny\n' | sudo sh ./Ventoy2Disk.sh -I $gpt "$dev" )
    sync; sudo partprobe "$dev" || true; sudo udevadm settle
    local p1="${dev}1"; [[ "$dev" == *[0-9] ]] && p1="${dev}p1"
    for _ in $(seq 1 20); do [[ -b "$p1" ]] && break; sleep 1; done
    [[ -b "$p1" ]] || die "$p1 never appeared after Ventoy install; the stick may be faulty"
    sudo umount "$p1" 2>/dev/null || true

    c_info "== [2/5] NTFS format (label Medicat) =="
    sudo mkntfs --fast --label Medicat "$p1"
    sync; sudo udevadm settle; sudo umount "$p1" 2>/dev/null || true

    c_info "== [3/5] Mount =="
    local mnt="$KIT/.mnt"; mkdir -p "$mnt"
    sudo mount -t ntfs3 "$p1" "$mnt" 2>/dev/null || sudo mount -t ntfs-3g "$p1" "$mnt" || sudo ntfs-3g "$p1" "$mnt"
    mountpoint -q "$mnt" || die "mount failed"

    c_info "== [4/5] Extract $(basename "$archive") (20-40 minutes) =="
    sudo 7z x -y -bsp1 -bso0 -o"$mnt" "$archive"

    c_info "== [5/6] Copy ISOs from isos/ =="
    if [[ -n "$(find "$ISOS" -type f | head -1)" ]]; then
        sudo cp -av "$ISOS"/. "$mnt"/
    else
        echo "  (isos/ is empty)"
    fi

    c_info "== [6/6] Golden installs (golden/) =="
    install_golden "$mnt"
    sync
    df -h "$mnt" | tail -1
    sudo umount "$mnt"; sync; sleep 2
    lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev"
    [[ "$(sudo dd if="$dev" bs=1 skip=510 count=2 status=none | xxd -p)" == "55aa" ]] || c_warn "MBR boot signature not found; re-check the stick"
    c_ok "Done. The stick can be removed."
}

case "${1:-}" in
    update) shift; cmd_update "$@" ;;
    build)  shift; cmd_build "$@" ;;
    list)   cmd_list ;;
    status) cmd_status ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
