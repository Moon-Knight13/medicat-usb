# Raspberry Pi flasher (golden/raspberrypi) — design

Date: 2026-10-03
Status: draft for review

## Goal

Make working with a Raspberry Pi as a separate device easy from any golden laptop:

- `pi-flash` writes a clean, pinned Raspberry Pi OS Lite image to an SD card and
  configures it for first boot, so the Pi comes up on Wi-Fi with SSH key login.
- `pi` opens a shell on the Pi over Wi-Fi, a direct Ethernet cable, or USB (boards
  that support USB gadget mode).
- The MediCat stick carries the pinned image, so a Pi can be flashed with no internet.

To change a Pi, re-flash it. Nothing on a Pi is patched in place.

## Non-goals

- Roles (Pi-hole, sheep dip, others). They get their own designs later.
- Long-lived service configuration and in-place updates. Those belong to the homelab
  repository's server-led Ansible, later.
- Building custom images (pi-gen).

## Constraints

- **The repository is public.** No Wi-Fi names or passwords, MAC addresses, hostnames,
  interface names, user names or keys in git, commit messages or PR text. Personal values
  live in the git-ignored `golden/ubuntu/vars/local.yml`; secrets stay on the laptop and are
  read at flash time.
- **No secrets on the stick.** The stick carries only the public image and public scripts.
- Supported boards: Pi 3 B+, Pi 4, Pi 5, Zero 2 W (64-bit Raspberry Pi OS). USB networking
  only on boards with a USB device-mode port (Zero 2 W, Pi 4, Pi 5). On a Pi 3 B+ the USB
  controller feeds the onboard hub and Ethernet, so device mode must never be enabled there.

## Layout

```
golden/raspberrypi/
  README.md             how to flash and connect
  image.conf            pinned image: URL, file name, SHA-256
  user-data.tmpl        cloud-init user-data template
  network-config.tmpl   cloud-init network-config template (Wi-Fi)
  pi-flash              write and configure an SD card
  pi                    connect to a Pi
  test/                 render test (no hardware)
golden/ubuntu/playbook.yml   installs pi-flash, pi and the two cable profiles on laptops
make-stick.sh                update also downloads the pinned Pi image to isos/RaspberryPi/
```

`install_golden` already copies the whole `golden/` folder to the stick and
`tools/golden-pack.sh` already packs it into the Ubuntu recipe, so laptops get
`/opt/golden/raspberrypi/` with no change to either.

The image goes in `isos/RaspberryPi/`, which `build` copies to the stick as it does all of
`isos/`. Ventoy does not list `.img.xz` files, so the boot menu is unaffected.

## pi-flash

```
pi-flash [--name HOST] [--password] [--device /dev/sdX] [--render-only DIR]
```

1. **Find the card.** Removable block devices only, at most 256 GB, not mounted as `/`
   or `/boot`. With one candidate it is pre-selected; with several, or with `--device`,
   the user picks. Model, size and current partition labels are shown and the user types
   `yes` to continue.
2. **Find the image**, first match wins: a mounted MediCat stick (`*/RaspberryPi/<file>`),
   the kit's `isos/RaspberryPi/`, `~/.cache/golden/raspberrypi/`. If none, download to the
   cache. The SHA-256 from `image.conf` is checked every time before writing.
3. **Collect values** (never printed):
   - user name: the laptop user (`$USER`);
   - SSH public key: `~/.ssh/id_ed25519.pub` (fail with a clear message if missing);
   - Wi-Fi name: `pi_wifi_ssid` from `/etc/golden/pi.conf`, otherwise the laptop's active Wi-Fi;
   - Wi-Fi password: `sudo nmcli -s -g 802-11-wireless-security.psk connection show <name>`;
     open networks are supported (no password line written);
   - Wi-Fi country: `pi_wifi_country` from `/etc/golden/pi.conf`, default `GB`;
   - time zone: the laptop's time zone;
   - hostname: `--name`, default `raspberrypi`; validated as a hostname;
   - optional login password: `--password` prompts twice, stores only a SHA-512 crypt hash.
4. **Write** with `xzcat | sudo dd ... conv=fsync status=progress`, then `partprobe`.
5. **Configure** the boot partition: render the two templates into `user-data` and
   `network-config`, keep the image's `meta-data`. Unmount and sync.
6. Print the next steps: insert the card, power the Pi, `pi HOST` after about 2 minutes.

`--render-only DIR` does steps 3 and 5 into `DIR` with placeholder secrets and no device,
for tests and review.

Exit codes: 0 done, 1 user error or refused safety check, 2 checksum or write failure.

## First boot (cloud-init)

`user-data.tmpl` sets:

- hostname, `manage_etc_hosts`, time zone;
- one user with sudo, key-only SSH (`ssh_pwauth: false`). Without `--password` the
  account password is locked and sudo needs no password (console login is then
  impossible; `--password` is the recovery path);
- SSH enabled;
- `unattended-upgrades` for security updates;
- the Pi end of the direct cable: a NetworkManager profile `eth-direct` on `eth0` with
  DHCP (no timeout) plus IPv4 link-local, route metric 700 so Wi-Fi stays the default route;
- USB networking, only when `/proc/device-tree/model` names a Zero 2 W, Pi 4 or Pi 5:
  run `rpi-usb-gadget on` and reboot once. Other boards skip this step.

`network-config.tmpl` is netplan v2 with the NetworkManager renderer: one Wi-Fi network,
DHCP, the regulatory domain. The password is YAML-escaped. The boot partition is FAT, so
the file is readable by anyone holding the card until first boot; cloud-init then moves the
network into NetworkManager's root-only store. Treat a flashed but unused card as holding
the Wi-Fi password.

## pi (laptop)

```
pi [HOST] [local|share|off]
```

- No mode: SSH to `HOST.local` (default `raspberrypi`) if it answers; else try USB
  (`10.12.194.1`, the address `rpi-usb-gadget` gives the Pi); else bring up the cable in
  link-local mode and SSH to the Pi found there.
- `local`: cable, link-local only. No DHCP server, no routing.
- `share`: cable, NetworkManager shared mode (DHCP and NAT through the laptop). Refused
  unless a Raspberry Pi is already seen on the cable, so the laptop never serves DHCP on
  someone else's network. Asks the Pi to renew its lease so it gets an address at once.
- `off`: takes the cable profiles down.
- Finds the Pi on the cable by pinging all IPv6 link-local nodes and matching Raspberry Pi
  MAC prefixes (public vendor prefixes); SSH goes to that link-local address with
  `HostKeyAlias=HOST.local`, so no name resolution is needed.
- The cable interface: the only wired Ethernet device, or `pi_cable_iface` from `/etc/golden/pi.conf`
  when there are several. The laptop profiles `pi-local` and `pi-shared` are created
  without an interface and activated on the chosen one (`nmcli con up ... ifname`).

Both profiles have autoconnect off. While one is up, that Ethernet port cannot join a
normal wired network; `pi off` releases it.

## Laptop playbook

`golden/ubuntu/playbook.yml` gains one block:

- copy `pi-flash` and `pi` to `/usr/local/bin` (mode 0755);
- create `pi-local` (link-local) and `pi-shared` (shared) with
  `community.general.nmcli` or `nmcli` commands, autoconnect off, no interface;
- write `/etc/golden/pi.conf` from `local.yml` values (`pi_wifi_ssid`, `pi_wifi_country`,
  `pi_cable_iface`); `pi-flash` and `pi` read only this file, so neither needs Ansible or
  the stick at run time;
- add both commands to `golden-help`.

`local.defaults.yml` gains public-safe defaults for `pi_wifi_ssid` (empty: use the active
Wi-Fi), `pi_wifi_country` (`GB`) and `pi_cable_iface` (empty: auto). `local.yml.example`
documents them.

## Stick

`make-stick.sh update` reads `golden/raspberrypi/image.conf`, downloads the image to
`isos/RaspberryPi/` when missing, verifies its SHA-256 and writes the usual `.ok` marker.
`status` lists it. Moving to a newer image is a reviewed PR that changes `image.conf`.

## Error handling

- Every safety check fails closed with a one-line reason: not removable, too large,
  mounted as system disk, checksum mismatch, no SSH key, no Wi-Fi password found for a
  secured network.
- Interrupted writes leave a card that will not boot cleanly; re-running `pi-flash` is the fix.
- `pi` prints which path it tried and why it gave up (not plugged in, no Pi seen on the
  cable after 30 seconds).

## Testing

- `shellcheck` on `pi-flash` and `pi` (added to pre-commit).
- `test/render.sh`: runs `pi-flash --render-only` with fixed inputs, checks the output
  parses as YAML, contains the expected keys, contains no real secrets, and (if installed)
  passes `cloud-init schema`.
- Manual: flash the Pi 3 B+, check Wi-Fi, `pi`, `pi local`, `pi share`, USB step skipped.
  Flash a Zero 2 W when available and check `pi` over USB.
- Privacy grep of the diff, commit messages and PR body before every push.

## Open points

None blocking. Roles, the sheep dip and the homelab hand-off are later designs; the
hand-off needs only what this design already fixes: hostname, user name and SSH key.
