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
pi-flash --name HOST [--no-wifi] [--password] [--device /dev/sdX] [--render-only DIR]
```

1. **Find the card.** Removable block devices only, at most 256 GB, not mounted as `/`
   or `/boot`. With one candidate it is pre-selected; with several, or with `--device`,
   the user picks. Model, size and current partition labels are shown and the user types
   `yes` to continue.
2. **Find the image**, first match wins: a mounted MediCat stick (`*/RaspberryPi/<file>`),
   the kit's `isos/RaspberryPi/`, `~/.cache/golden/raspberrypi/`. If none, download to the
   cache. The SHA-256 pinned in `image.conf` is checked every time before writing. The pin
   changes only through a reviewed PR, which is what makes the image trustworthy.
3. **Collect values** (never printed):
   - user name: the laptop user (`$USER`);
   - SSH public keys: `~/.ssh/id_ed25519.pub` (fail with a clear message if missing), plus
     every key in `pi_authorized_keys` from `/etc/golden/pi.conf`, so other golden machines
     (each has its own key) can log in too;
   - Wi-Fi name: `pi_wifi_ssid` from `/etc/golden/pi.conf` (for example a separate IoT
     network), otherwise the laptop's active Wi-Fi. The laptop must have that network saved;
   - Wi-Fi password: `sudo nmcli -s -g 802-11-wireless-security.psk connection show <name>`;
     open networks are supported (no password line written). Only WPA-PSK/SAE and open
     networks; enterprise (802.1X) networks are refused with a message;
   - `--no-wifi`: no Wi-Fi at all. No network name or password touches the card; the Pi is
     reachable only by cable or USB (for isolated devices such as a future sheep dip);
   - Wi-Fi country: `pi_wifi_country` from `/etc/golden/pi.conf`, default `GB`;
   - time zone: the laptop's time zone;
   - hostname: `--name`, required and validated as a hostname. Two Pis with the same name
     would make mDNS rename one behind the user's back;
   - optional login password: `--password` prompts twice, stores only a SHA-512 crypt hash.
4. **Write** with `xzcat | sudo dd ... conv=fsync status=progress`, then `partprobe`.
5. **Configure** the boot partition: render the two templates into `user-data` and
   `network-config`, keep the image's `meta-data`. Unmount and sync.
6. **Forget the old host key**: `ssh-keygen -R HOST.local`, because a re-flashed Pi has new
   SSH host keys and `pi` would otherwise stop at "REMOTE HOST IDENTIFICATION HAS CHANGED".
7. Print the next steps: insert the card, power the Pi, `pi HOST` after about 2 minutes.

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
- a login message (`/etc/profile.d/`) that warns when `vcgencmd get_throttled` is not `0x0`:
  the Pi has seen under-voltage since boot, a cause of SD card corruption;
- USB networking, only when `/proc/device-tree/model` names a Zero 2 W, Pi 4 or Pi 5:
  run `rpi-usb-gadget on` and reboot once, through cloud-init's `power_state` after it has
  finished. Other boards skip this step;
- last, overwrite `network-config` on the boot partition with a one-line comment when it
  holds Wi-Fi, so the password does not stay on the card.

`network-config.tmpl` is netplan v2 with the NetworkManager renderer: one Wi-Fi network,
DHCP, the regulatory domain. The password is YAML-escaped. The boot partition is FAT, so
the file is readable by anyone holding the card until first boot. cloud-init does not delete
its seed: it applies the network to root-only files on the Pi, and the last first-boot step
then overwrites `network-config` with a comment. Treat a flashed but unused card as holding
the Wi-Fi password. `user-data` stays on the card but holds no Wi-Fi password, only the
login password's hash when `--password` was given.

## pi (laptop)

```
pi [HOST] [local|share|off]
```

`HOST` defaults to `pi_default_host` from `/etc/golden/pi.conf`. With neither, `pi` uses the
cable or USB, which find the Pi by its MAC address and need no name.

- No mode: SSH to `HOST.local` if it answers (mDNS answers can be stale, so a name that
  resolves but does not answer falls through); else try USB
  (`10.12.194.1`, the address `rpi-usb-gadget` gives the Pi); else bring up the cable in
  link-local mode and SSH to the Pi found there, saying which paths it tried first.
- `local`: cable, link-local only. No DHCP server, no routing.
- `share`: cable, NetworkManager shared mode (DHCP and NAT through the laptop). Refused
  unless the Pi is the only device on the cable (exactly one link-layer address in the
  IPv6 neighbour table after the all-nodes ping, with a Raspberry Pi prefix) and the cable
  shows no network (no neighbour flagged `router`, no IPv6 default or `proto ra` route), so
  the laptop never serves DHCP on someone else's network. Prints a warning when the laptop has a VPN up, since the Pi's
  traffic would then leave through it (for example into a work network).
  Asks the Pi to renew its lease so it gets an address at once.
- `off`: takes the cable profiles down. Any failure after a cable profile is up (no Pi,
  refused share, lost Pi) takes them down again and says so; before SSH over the cable,
  `pi` names the profile holding the port and that `pi off` frees it.
- Finds the Pi on the cable by pinging all IPv6 link-local nodes and matching Raspberry Pi
  MAC prefixes (public vendor prefixes); SSH goes to that link-local address with
  `HostKeyAlias=HOST.local`, so no name resolution is needed. The USB path uses the same
  alias, so each Pi has one `known_hosts` entry whichever way it is reached, and step 6 of
  `pi-flash` clears it.
- The cable interface: the only wired Ethernet device not in use on a network, or
  `pi_cable_iface` from `/etc/golden/pi.conf` when there are several. A port is in use when
  it is active on a connection other than `pi-local`/`pi-shared` and shows a real network
  (a `router` neighbour, an IPv6 default or `proto ra` route, or a non-link-local IPv4
  lease); `pi` never takes such a port over, also not when `pi_cable_iface` names it, and
  reports the in-use ports it skipped. A port only trying to connect is free. The laptop profiles `pi-local` and `pi-shared` are created
  without an interface and activated on the chosen one (`nmcli con up ... ifname`).

**Away from home** the Pi knows no Wi-Fi network, so the cable (or USB on a Zero 2 W) is the
way in: `pi local` works with no other network present, `pi share` adds internet through
the laptop (which also lets the Pi set its clock). Extra Wi-Fi networks for the Pi (a phone
hotspot) and a Pi-hosted fallback hotspot are left out for now.

Both profiles have autoconnect off. While one is up, that Ethernet port cannot join a
normal wired network; `pi off` releases it.

## Laptop playbook

`golden/ubuntu/playbook.yml` gains one block:

- copy `pi-flash` and `pi` to `/usr/local/bin` (mode 0755);
- create `pi-local` (link-local) and `pi-shared` (shared) with
  `community.general.nmcli` or `nmcli` commands, autoconnect off, no interface;
- write `/etc/golden/pi.conf` from `local.yml` values (`pi_default_host`, `pi_wifi_ssid`,
  `pi_wifi_country`, `pi_cable_iface`, `pi_authorized_keys`); `pi-flash` and `pi` read only
  this file, so neither needs Ansible or the stick at run time;
- add both commands to `golden-help`.

`local.defaults.yml` gains public-safe defaults: `pi_default_host` (empty), `pi_wifi_ssid`
(empty: use the active Wi-Fi), `pi_wifi_country` (`GB`), `pi_cable_iface` (empty: auto) and
`pi_authorized_keys` (empty list). `local.yml.example` documents them.

## Stick

`make-stick.sh update` reads `golden/raspberrypi/image.conf`, downloads the image to
`isos/RaspberryPi/` when missing, verifies its SHA-256 and writes the usual `.ok` marker. `status` lists it and its release date. Moving to a newer image is a
reviewed PR that changes `image.conf`; aim for every few months, since an old image makes
the first boot spend time on security updates.

## Error handling

- Every safety check fails closed with a one-line reason: not removable, too large,
  mounted as system disk, checksum mismatch, no SSH key,
  no Wi-Fi password found for a secured network, enterprise Wi-Fi, missing `--name`.
- Interrupted writes leave a card that will not boot cleanly; re-running `pi-flash` is the fix.
- `pi` prints which path it tried and why it gave up (not plugged in, no Pi seen on the
  cable after 30 seconds).

## Testing

- `shellcheck` on `pi-flash` and `pi` (added to pre-commit).
- `test/render.sh`: runs `pi-flash --render-only` with fixed inputs, checks the output
  parses as YAML, contains the expected keys, contains no real secrets, and (if installed)
  passes `cloud-init schema`.
- `test/render.sh` also covers `--no-wifi` (no `network-config` Wi-Fi block, no Wi-Fi
  values anywhere on the card) and several `pi_authorized_keys`.
- Manual: flash the Pi 3 B+, check Wi-Fi, `pi`, `pi local`, `pi share`, USB step skipped,
  re-flash and reconnect with no host-key error, under-voltage message at login on a weak
  supply. Flash a Zero 2 W when available and check `pi` over USB.
- Privacy grep of the diff, commit messages and PR body before every push.

## Accepted risks

- **Passwordless sudo with key-only login.** Whoever holds a listed SSH private key has
  root on the Pi. Reasonable for home devices; `--password` makes sudo ask for a password.
- **Wi-Fi password readable on the card until the Pi's first boot**, which removes it (FAT
  boot partition, see First boot).
- **Wrong clock offline.** A Pi has no clock battery; on `pi local` with no internet its
  time is wrong until `pi share` or Wi-Fi gives it NTP. Revisit in the sheep-dip design.
- **Image age.** A pinned image is only as current as its last bump; unattended-upgrades
  closes the gap after first boot.

## Delivery

- One branch and one PR. Tell the main PC's Claude session before merging, since it also
  edits `golden/ubuntu/playbook.yml`.
- Update `golden/README.md`, the top-level `README.md` and `docs/explainer/index.html` in
  the same PR (the repository contract requires the explainer to follow component changes).

## Open points

None blocking. Roles, the sheep dip and the homelab hand-off are later designs; the
hand-off needs only what this design already fixes: hostname, user name and SSH keys.
