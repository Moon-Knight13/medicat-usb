#!/usr/bin/env bash
# vm-test.sh — prove a golden install in a QEMU/KVM virtual machine before trusting it on a laptop.
#
#   tools/vm-test.sh iso                 boot the staged Ubuntu ISO with golden/ubuntu/autoinstall.yaml
#                                        (identity + storage stay interactive, exactly as on the stick)
#   tools/vm-test.sh iso --unattended    same, but identity/storage are pre-answered with throwaway
#                                        test values so the whole chain runs hands-off: install,
#                                        reboot, first-boot playbook. Disk is NOT encrypted in this mode.
#       ... --unattended --encrypt=luks  same, on LVM inside LUKS (test passphrase "goldentest-luks";
#                                        type it at boot with: vm-test.sh type goldentest-luks)
#       ... --unattended --encrypt=tpm   same, with TPM-backed encryption (emulated TPM + secure boot).
#                                        Ubuntu 26.04.1 refuses this in any VM ("not available:
#                                        running-in-vm"), so it only proves the refusal; test on hardware.
#   tools/vm-test.sh boot                boot the disk an `iso` run installed (the VM powers off when the
#                                        installer finishes, because a reset would start the installer again)
#   tools/vm-test.sh stick /dev/sdX      boot the real MediCat stick read-only (nothing is written to it)
#   tools/vm-test.sh stick /dev/sdX --install   same, onto a blank disk that is kept: the closest
#                                        thing to a laptop. You drive the three pages (shot/click/key/type),
#                                        the VM powers off when the install ends, then: vm-test.sh boot
#   tools/vm-test.sh shot [file.png]     screenshot the running VM
#   tools/vm-test.sh click X Y           click at guest screen pixel X,Y via QMP
#   tools/vm-test.sh key KEY             send a key (QEMU key names, e.g. ret, tab, spc)
#   tools/vm-test.sh ssh [cmd]           ssh into an --unattended VM as user golden (port 2222)
#   tools/vm-test.sh offline | online    unplug or replug the VM's network cable. OFFLINE=1 with `iso`
#                                        or `boot` starts unplugged, like a laptop with no Wi-Fi joined
#   tools/vm-test.sh stop                power off the VM
#
# The VM shows on VNC display :9 (e.g. `vncviewer localhost:9`) and also on a local window if
# DISPLAY is set and --headless is not given. State lives in .vm/ (git-ignored).
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="$KIT/.vm"; mkdir -p "$VM"
MON="$VM/monitor.sock"
QMP="$VM/qmp.sock"
RAM="${VM_RAM:-6G}"; CPUS="${VM_CPUS:-4}"; DISK_SIZE="${VM_DISK:-40G}"
ISO=$(ls "$KIT"/isos/Live_Operating_Systems/Ubuntu/ubuntu-*-desktop-amd64.iso 2>/dev/null | sort -V | tail -1 || true)
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.fd

die() { echo "ERROR: $*" >&2; exit 1; }
mon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" 2>/dev/null | tail -n +2 || true; }

MODE=$(cat "$VM/mode" 2>/dev/null || echo plain)   # plain | luks | tpm, set by the last `iso` run

stop_tpm() { [[ -f "$VM/tpm/pid" ]] && kill "$(cat "$VM/tpm/pid")" 2>/dev/null; rm -f "$VM/tpm/pid"; return 0; }

common_args() {
    local machine=q35
    if [[ "$MODE" == tpm ]]; then   # TPM-backed encryption needs secure boot and a TPM
        OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.ms.fd; OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
        machine=q35,smm=on
        command -v swtpm >/dev/null || die "swtpm missing (sudo apt install swtpm)"
        mkdir -p "$VM/tpm"; stop_tpm
        swtpm socket --tpm2 --tpmstate dir="$VM/tpm" --ctrl type=unixio,path="$VM/tpm/sock" --pid file="$VM/tpm/pid" --daemon
        echo -global driver=cfi.pflash01,property=secure,value=on \
             -chardev socket,id=chrtpm,path="$VM/tpm/sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
             -device tpm-crb,tpmdev=tpm0
    fi
    [[ -f "$VM/OVMF_VARS.fd" ]] || cp "$OVMF_VARS_SRC" "$VM/OVMF_VARS.fd"
    echo -enable-kvm -cpu host -smp "$CPUS" -m "$RAM" -machine "$machine" \
         -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
         -drive if=pflash,format=raw,file="$VM/OVMF_VARS.fd" \
         -device virtio-vga -vnc :9 -monitor "unix:$MON,server,nowait" -qmp "unix:$QMP,server,nowait" \
         -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0,id=nic0 \
         -device qemu-xhci -device usb-tablet -pidfile "$VM/qemu.pid" -daemonize
    if [[ -z "${DISPLAY:-}" || "${HEADLESS:-0}" == "1" ]]; then echo -display none; else echo -display gtk; fi
}

cmd_iso() {
    local unattended=0 encrypt=plain a
    for a in "$@"; do
        case "$a" in
            --unattended) unattended=1 ;;
            --encrypt=luks|--encrypt=tpm) encrypt=${a#--encrypt=} ;;
            *) die "unknown argument: $a" ;;
        esac
    done
    [[ $encrypt == plain || $unattended -eq 1 ]] || die "--encrypt needs --unattended (otherwise you choose on the storage page)"
    [[ -n "$ISO" ]] || die "no Ubuntu ISO staged; run ./make-stick.sh update"
    command -v xorriso >/dev/null || die "xorriso missing (sudo apt install xorriso)"
    command -v socat >/dev/null || die "socat missing (sudo apt install socat)"
    cmd_stop >/dev/null 2>&1 || true
    rm -rf "$VM/disk.qcow2" "$VM/OVMF_VARS.fd" "$VM/tpm"; echo "$encrypt" > "$VM/mode"; MODE=$encrypt
    qemu-img create -q -f qcow2 "$VM/disk.qcow2" "$DISK_SIZE"

    # cloud-init NoCloud seed: user-data is the golden template, optionally with test answers.
    local seed="$VM/seed"; rm -rf "$seed"; mkdir -p "$seed"
    "$KIT/tools/golden-pack.sh" ubuntu > "$seed/user-data"     # the same packed recipe the stick gets
    if [[ $unattended -eq 1 ]]; then
        [[ -f "$VM/test_key" ]] || ssh-keygen -q -t ed25519 -N "" -f "$VM/test_key" -C golden-vm-test
        python3 - "$seed/user-data" "$(cat "$VM/test_key.pub")" "$encrypt" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read(); pub = sys.argv[2]
layout = {"plain": "name: lvm\n      sizing-policy: all",
          "luks":  "name: lvm\n      sizing-policy: all\n      password: goldentest-luks",
          "tpm":   "name: hybrid\n      encrypted: true"}[sys.argv[3]]
s = re.sub(r"  interactive-sections:\n(    - .*\n)+", "", s)
s = s.replace("  shutdown: reboot", "  ssh:\n    install-server: true\n    authorized-keys: ['%s']\n  shutdown: reboot" % pub)
s = s.replace("  locale: en_GB.UTF-8", """  identity:
    realname: Golden Test
    username: golden
    hostname: golden-vm
    password: "$6$goldentest$lDeVWCxzgXmFPZFaHcwXf8WlVHHhOnimOLPv0n2aHV1tj9WL4eS8RnAWnUuByeWj3m8TalckiACJX4soQbEjg."
  storage:
    layout:
      LAYOUT
  locale: en_GB.UTF-8""".replace("LAYOUT", layout))
    # test password is "goldentest" (throwaway, VM only)
open(p, "w").write(s)
PY
    fi
    printf 'instance-id: golden-vm\nlocal-hostname: golden-vm\n' > "$seed/meta-data"
    xorriso -as mkisofs -quiet -o "$VM/seed.iso" -V cidata -J -r "$seed" 2>/dev/null

    # Boot the ISO's own kernel so we can put "autoinstall" on the command line, as Ventoy does.
    # (Not under secure boot: the firmware only accepts the ISO's own signed boot chain.)
    local direct=(-kernel "$VM/vmlinuz" -initrd "$VM/initrd" -append "boot=casper autoinstall quiet splash ---")
    [[ "$MODE" == tpm ]] && direct=(-boot d)
    7z e -y -o"$VM" "$ISO" casper/vmlinuz casper/initrd >/dev/null
    echo "Booting $(basename "$ISO") ($( [[ $unattended -eq 1 ]] && echo unattended || echo 'identity + storage interactive' )) on VNC :9"
    # shellcheck disable=SC2046
    qemu-system-x86_64 $(common_args) \
        -drive file="$VM/disk.qcow2",if=virtio,format=qcow2 \
        -drive file="$ISO",media=cdrom,readonly=on \
        -drive file="$VM/seed.iso",media=cdrom,readonly=on \
        "${direct[@]}" -no-reboot
    [[ "${OFFLINE:-0}" == "1" ]] && cmd_link off
    echo "pid $(cat "$VM/qemu.pid"); screenshot with: tools/vm-test.sh shot"
    echo "The VM powers off when the install finishes; then run: tools/vm-test.sh boot"
}

cmd_boot() {
    [[ -f "$VM/disk.qcow2" ]] || die "no installed disk; run: vm-test.sh iso"
    cmd_stop >/dev/null 2>&1 || true
    echo "Booting the installed disk on VNC :9"
    # shellcheck disable=SC2046
    qemu-system-x86_64 $(common_args) -drive file="$VM/disk.qcow2",if=virtio,format=qcow2
    [[ "${OFFLINE:-0}" == "1" ]] && cmd_link off
    echo "pid $(cat "$VM/qemu.pid")"
}

cmd_stick() {
    local dev=${1:-} install=0; [[ "${2:-}" == "--install" ]] && install=1
    [[ -b "$dev" ]] || die "usage: vm-test.sh stick /dev/sdX [--install]"
    [[ "$(lsblk -dno TRAN "$dev")" == "usb" ]] || die "$dev is not a USB drive"
    [[ -r "$dev" ]] || die "need read access to $dev (e.g. sudo setfacl -m u:$USER:r $dev)"
    cmd_stop >/dev/null 2>&1 || true
    local disk_opts=snapshot=on extra=()
    if [[ $install -eq 1 ]]; then   # a real install from the stick: blank disk that keeps what is written
        rm -rf "$VM/disk.qcow2" "$VM/OVMF_VARS.fd" "$VM/tpm"; echo plain > "$VM/mode"; MODE=plain
        disk_opts=snapshot=off; extra=(-no-reboot)
    fi
    [[ -f "$VM/disk.qcow2" ]] || qemu-img create -q -f qcow2 "$VM/disk.qcow2" "$DISK_SIZE"
    echo "Booting $dev read-only (snapshot: writes go to a temporary overlay, never to the stick) on VNC :9"
    # shellcheck disable=SC2046
    qemu-system-x86_64 $(common_args) "${extra[@]}" \
        -drive file="$dev",if=none,id=stick,format=raw,snapshot=on -device usb-storage,drive=stick,bootindex=0 \
        -drive "file=$VM/disk.qcow2,if=virtio,format=qcow2,$disk_opts"
    [[ "${OFFLINE:-0}" == "1" ]] && cmd_link off
    echo "pid $(cat "$VM/qemu.pid")"
}

cmd_shot() { local out=${1:-$VM/shot-$(date +%H%M%S).png}; mon "screendump $VM/shot.ppm" >/dev/null; sleep 1; python3 -c "
from PIL import Image; Image.open('$VM/shot.ppm').save('$out')" 2>/dev/null || convert "$VM/shot.ppm" "$out"; echo "$out"; }
cmd_click() {  # pixel coordinates in the guest's current resolution (read from a fresh screendump)
    mon "screendump $VM/shot.ppm" >/dev/null; sleep 0.5
    read -r _ w h _ < <(head -c 32 "$VM/shot.ppm" | tr '\n' ' ') || true   # no trailing newline: read reports EOF
    "$KIT/tools/vm-click.py" "$QMP" $(( ${1:?x} * 32767 / w )) $(( ${2:?y} * 32767 / h ))
}
cmd_link() { mon "set_link nic0 $1" >/dev/null; echo "network cable: $1"; }
cmd_key() { mon "sendkey ${1:?key}" >/dev/null; }
cmd_type() {  # type lower-case letters, digits and dashes, then Enter (e.g. a LUKS passphrase)
    local t=${1:?text} i c
    for (( i = 0; i < ${#t}; i++ )); do c=${t:i:1}; [[ $c == - ]] && c=minus; cmd_key "$c"; sleep 0.1; done
    cmd_key ret
}
cmd_ssh() { ssh -p 2222 -i "$VM/test_key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR golden@127.0.0.1 "$@"; }
cmd_stop() { stop_tpm; [[ -f "$VM/qemu.pid" ]] && kill "$(cat "$VM/qemu.pid")" 2>/dev/null && echo "VM stopped"; rm -f "$VM/qemu.pid"; }

case "${1:-}" in
    iso)   shift; cmd_iso "$@" ;;
    boot)  cmd_boot ;;
    stick) shift; cmd_stick "$@" ;;
    shot)  shift; cmd_shot "$@" ;;
    click) shift; cmd_click "$@" ;;
    key)   shift; cmd_key "$@" ;;
    type)  shift; cmd_type "$@" ;;
    ssh)   shift; cmd_ssh "$@" ;;
    offline) cmd_link off ;;
    online)  cmd_link on ;;
    stop)  cmd_stop ;;
    *) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
