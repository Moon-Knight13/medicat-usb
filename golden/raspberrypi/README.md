# golden/raspberrypi

Flash a Raspberry Pi's SD card from a golden laptop and open a shell on the Pi.
To change a Pi, flash it again: nothing on a Pi is patched in place.

Boards: Pi 3 B+, Pi 4, Pi 5, Zero 2 W (Raspberry Pi OS Lite, 64-bit).

## Flash

    pi-flash --name kitchen-pi

- Writes the pinned image (`image.conf`) from the MediCat stick if it is plugged in,
  otherwise downloads it, and checks its SHA-256 first.
- Only removable cards of 256 GB or less, never the stick holding the image or a disk with
  anything mounted outside `/media`; it shows the card and asks you to type `yes`.
- `--device /dev/sdX`: the card to write, needed when several cards are plugged in.
- The Pi gets your user name, your SSH key (`~/.ssh/id_ed25519.pub`, plus
  `pi_authorized_keys`), this laptop's time zone, and Wi-Fi: `pi_wifi_ssid` or the
  network you are on. The Wi-Fi password comes from this laptop's saved connection.
- `--no-wifi`: no Wi-Fi on the card; reach the Pi by cable, or by USB on boards with a
  USB device port (Zero 2 W, Pi 4, Pi 5).
- `--password`: also a login password. Without it the Pi accepts SSH keys only and sudo
  asks for no password.
- The card holds the Wi-Fi password in readable form until the Pi's first boot, which
  removes it from the card. With `--password` the card holds only a hash of the login password.

## Connect

    pi kitchen-pi          Wi-Fi, else USB, else the Ethernet cable
    pi kitchen-pi local    cable only: link-local addresses, no routing
    pi kitchen-pi share    cable, and the Pi gets internet through this laptop for the session
    pi off                 free the Ethernet port

A bare `pi` with no host and no `pi_default_host` skips Wi-Fi and tries USB, then the cable.

Away from home the Pi knows no Wi-Fi, so use the cable: `pi local` needs no other
network; `pi share` adds internet (and so the right time). A Zero 2 W has no Ethernet
port; on boards with a USB device port (Zero 2 W, Pi 4, Pi 5) its USB cable works the same way.

`pi` never takes over an Ethernet port the laptop is using on a network (a router on it, a
router-advertised or default IPv6 route, or a DHCP lease). It picks the one wired port
that is free, so a laptop docked on a wired network uses a second USB Ethernet adapter for
the Pi; with several free ports, set `pi_cable_iface`. After a cable connection the port
stays held until `pi off`, which hands it back to NetworkManager; when `pi` fails it frees
the port itself.

`pi share` refuses to start unless the Pi is the only device on the cable and the cable
shows no sign of a network (no router, no router-advertised or default route), so the
laptop never serves addresses on someone else's network. Sharing lasts only for that SSH
session: when it ends, `pi` takes sharing down and frees the port. It warns when a VPN is
up, since the Pi's traffic would go through it.

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
