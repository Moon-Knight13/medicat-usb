# Golden installs

One folder per ISO. `make-stick.sh build` copies this whole folder onto the stick and
registers each `<name>/autoinstall.yaml` with Ventoy's auto-install plugin for the ISOs in
`isos/Live_Operating_Systems/<Name>/`. Picking that ISO in the Ventoy menu then offers:

- boot normally (interactive install, or a live session), or
- **golden install**: the recipe in `autoinstall.yaml`.

## golden/ubuntu

A wipe-and-encrypt Ubuntu desktop that ends up with your favourite apps and settings.

| Step | Where | What |
|---|---|---|
| Installer | `autoinstall.yaml` | Only **identity** and **storage** stay interactive, so no password, passphrase or key is ever stored on the stick or in git. Locale, keyboard, timezone, full desktop, drivers and codecs are preset. |
| Hand-off | `autoinstall.yaml` late commands | Unpacks this folder to `/opt/golden` on the laptop and arms `golden-firstboot.service`. The folder travels inside the recipe (packed by `tools/golden-pack.sh` when the stick is built), because the installer cannot read the stick while Ventoy has the ISO booted. |
| First boot | `firstboot/` | Waits for network, runs `ansible-pull` from this repo (falls back to the local copy), retries every 2 minutes and on every boot until it succeeds, then disables itself. Log: `/var/log/golden-firstboot.log`. |
| Apps and settings | `playbook.yml`, `vars/apps.yml`, `files/` | Repos, packages, snaps, flatpaks, .deb downloads, user groups, dotfiles, GNOME settings. |

### At the laptop

1. Boot the stick, choose Ubuntu, choose the golden template when Ventoy asks.
2. **Disk setup**: choose "Erase disk and install Ubuntu" ("Install alongside" is
   pre-selected), Next. **Check the drive on the next page**: the list includes the stick
   itself, and it can be the one pre-selected. Pick the laptop's internal drive.
3. **Encryption**: choose "Encrypt with a passphrase" ("No encryption" is pre-selected)
   and set the passphrase, Next. You type
   it at every boot. This is the tested path (LVM inside LUKS2). Leave hardware-backed (TPM)
   encryption alone: it is untested here and may not load the NVIDIA modules.
4. **Identity**: your name, username, password, Next.
5. **Review**: check the installation disk, then Install. The install needs no network.
6. When it says "installed and ready to use", choose Restart now and remove the stick
   when asked. Type the passphrase, log in. The first boot then pulls the playbook.
   On Wi-Fi only: log in and join the network; the first boot retries every 2 minutes.
   Give it 15 to 30 minutes with network; check progress with
   `journalctl -u golden-firstboot -f`.

### Personal values that stay out of git

`vars/local.yml` (git-ignored, copy from `vars/local.yml.example`) holds values that are
yours but not for a public repo, such as your git name and email. `build` copies it onto the
stick with the rest of this folder and the first boot applies it from there. Without it,
git is left in "ask me for an email" mode rather than guessing.

### Secure Boot

Nothing to do by hand: the recipe installs no out-of-tree kernel modules (deck runs on KVM,
which is part of the kernel; VirtualBox was dropped), so there is no signing key to enrol.
Laptops installed earlier keep their enrolled VirtualBox key in the firmware unused;
`sudo mokutil --delete /var/lib/shim-signed/mok/MOK.der` removes it (confirm at the next boot).

### Continuing work on the new machine: SSH, sign-ins

- **New SSH keys are made on every machine**: `~/.ssh/id_ed25519`, plus every other key the
  carried `ssh_config` names in an `IdentityFile` (e.g. a separate key for a work GitHub
  account or a GitLab). Private keys are never carried on the stick. The finish note shows the public key and the commands to add it to
  GitHub (`gh auth login`, `gh ssh-key add`) and to servers (`ssh-copy-id`). A lost laptop
  then means revoking one key, not all of them.
- **Your `~/.ssh/config` can ride on the stick**: copy it to `golden/ubuntu/local/ssh_config`
  (git-ignored). Each `IdentityFile` it names is created fresh on the new machine, and the
  finish note lists every public key with the hosts that need it. It holds host names,
  addresses and usernames, so it is on the stick, not in the public repo. Same folder for
  anything else personal but not secret.
- **Repositories** are not cloned by the recipe: clone what you need, when you need it.
- **VPNs**: list them under `vpns:` in `vars/local.yml` (name, gateway, protocol, authgroup,
  username). They appear in the panel menu; switch one on and enter your password. Nothing
  secret is stored.
- **Double VPN** (`vpn-chain`): Proton VPN to `vpn_chain_country` (EE) with its kill switch on,
  then the first `vpns:` entry (your work VPN) inside it, so the work VPN's server sees a Proton address.
  It checks that traffic to the work gateway really goes through Proton before and after
  connecting, and gives the work VPN's DNS servers its own domains (with Proton up they never
  reached the resolver, so work names failed). `vpn-chain off` undoes it in reverse order. Launchers per country in
  `vpn_chain_countries` (Estonia, UK) and "VPN: chain off": press Super and type "VPN". Short
  commands per country too: `vpn-chain-ee`, `vpn-chain-gb`. If large transfers stall over the
  double tunnel, lower the work VPN's MTU (e.g. 1300).
- **Sign-ins stay manual** by design: GitHub CLI, Firefox, Discord, Spotify, Steam, Proton
  VPN, Obsidian Sync, Claude Code. Their tokens are the one thing a stick must not carry.
- **Firefox defaults**: DuckDuckGo as the search engine and dark web pages
  (`firefox_search_engine`, `firefox_dark_pages`), as starting values you can change.
- **Firefox**: signing in to the Firefox account restores bookmarks, add-ons (Bitwarden,
  Proton Pass, FoxyProxy and the rest, including which are disabled) and settings through
  Firefox Sync; history and passwords are not synced by choice. Then sign in to Bitwarden and
  Proton Pass inside the browser. Nothing Firefox-related is carried on the stick.

### Claude Code

`claude` (the command-line tool) is installed for your user with the official plugins
(superpowers, code-review, commit-commands, skill-creator, frontend-design) and the caveman
plugin, pinned by version and installer checksum in `files/claude-setup.sh`. Run `claude` once
to sign in. (The VS Code extension is not installed; everything is CLI.)

### deck: a disposable media and browsing VM

For watching media and for research that should leave no trace on the laptop. `deck` is a
per-user KVM VM (`qemu:///session`): minimal Ubuntu, dark mode, private Firefox (DuckDuckGo,
uBlock Origin, strict tracking protection, HTTPS-only, no password saving, no onboarding),
throwaway login `deck`/`deck`, no clipboard or shared folders, no microphone. Sound goes
straight into your PipeWire and video uses 3D on the host GPU (virtio-gpu with virgl), so
media plays in sync. Its disk is **transient**: whatever happens inside is thrown away when it
stops, with no snapshot to restore.

- `deck`: start it full screen. Close the window (or Power Off inside) to stop and wipe it.
  Ctrl+Alt releases the mouse and keyboard; Shift+F11 leaves full screen.
- Time zone matches deck's VPN country (`deck_timezone: auto`; Europe/Zurich for CH), so a
  London clock behind a Swiss IP doesn't give the VPN away. `deck-update` applies changes.
- Proton VPN: `deck` connects to the fastest server in `deck_vpn_country` (CH by default)
  before starting, unless a VPN is already up, and disconnects afterwards if it connected it.
  While deck's VPN is up the kill switch is on (internet blocked if the VPN drops); the previous
  kill-switch setting comes back afterwards.
  If the VPN cannot connect, deck does not start (`deck --no-vpn` skips it). Needs a one-time
  `protonvpn signin`.
- `deck-update`: install updates into its clean base (deck closed; about 2 minutes). The
  weekly update does this too.
- `deck-create` / `deck-create --rebuild`: build it, or delete and build it again, from the ISO
  the install kept at `/opt/golden/ubuntu.iso`. About 15 minutes, unattended. Sizes scale to the
  host (half the CPUs, a quarter of the RAM, within `deck_*` in `vars/apps.yml`).
- It is built in the background at your first login (it needs your desktop session for sound),
  with a notification when ready. Until then the finish note mentions it.

### Power and lid

- Closing the lid on mains power does nothing, so a download or a film keeps going
  (`lid_close_on_power` in `vars/apps.yml`); on battery it suspends. With an external screen
  attached the lid is ignored either way.
- On mains power the laptop never suspends by itself; on battery it suspends after 15 minutes
  idle. While a `deck` window is open it does not dim, lock or suspend.

- The sound theme is `golden-quiet`: Yaru without the charger plug/unplug sounds, which GNOME
  plays even with alert sounds off and which repeated every half minute when the charger
  dropped out near full charge. Setting a BIOS charge limit (80%) avoids those dropouts.

### Staying current after deployment

| What | How | When |
|---|---|---|
| Ubuntu security and updates, plus the third-party repos (VS Code, Docker, GitHub CLI, Terraform, Proton) | unattended-upgrades, `auto_update_origins` in `vars/apps.yml` | daily, never reboots by itself |
| Everything else, in one go: full apt upgrade, snaps, Flatpaks, deck's clean base | `golden-weekly-update.timer`, with a notification at start and end (and if a restart is needed) | weekly: Monday, or the first chance after, when on mains power and idle 10+ minutes |
| Snaps (Firefox, Spotify, Steam) | snapd | several times a day |
| Discord, Obsidian | update themselves | on launch |
| ClamAV signatures | freshclam | 4 times a day |
| Firmware and BIOS | fwupd metadata daily; updates listed by `golden-status`, applied by you | daily |
| This recipe | `golden-update` when you choose to | never by itself |

`golden-status` says when a reboot is pending. Nothing re-applies the recipe by itself: run
`golden-update` to bring a laptop up to date. An update never wipes, reboots or removes
anything, and it leaves your personal preferences alone: desktop settings, VS Code settings, git
and ssh config and dotfiles are applied once at first boot, and changes you make afterwards
stay. To re-apply them: `golden-update --preferences`. `golden-help` lists every command; `mictest` shows the microphone's live level.

### Hardware quirks

Fixes tied to one model, applied only when the DMI vendor and product match:

- **Framework Laptop 13 (AMD Ryzen AI 300 Series)**: the internal microphone. The ALSA UCM
  profiles expose an ACP digital mic that records garbage on this model and hide the working
  Realtek one; a WirePlumber drop-in turns UCM off. If the mic sounds harsh, lower
  "Internal Mic Boost" in `alsamixer`. Headset-jack mic under this setup is untested.

### Fingerprint login

When a supported reader is present, `fingerprint: true` lets the lock screen, sudo and polkit
accept a finger (the password always works too). Enrolling a finger is manual, in Settings >
System > Users > Fingerprint Login, and the finish note reminds you until one is enrolled. Apply
any fingerprint-sensor firmware update listed by `golden-status` first.

### Power profile

`power_profile: performance` in `vars/apps.yml` sets the laptop to performance mode once, at
first boot (a preference, so switching it later sticks). Performance costs battery life. Skipped
on machines that do not offer that profile.

### Watching the first boot

A "Golden install" terminal window opens at login and lists each step until it finishes (it
can open behind Ubuntu's welcome screen; a notification points to it). At any time:

```bash
golden-status            # one line: waiting for a network, step N of about M, failed, finished
golden-status --watch    # keep watching
```

### Repairing or updating a laptop without reinstalling

```bash
golden-update              # from main (the branch last used); asks for your password
golden-update <branch>     # from a branch, to try a change before merging it
```

(`golden-update` runs `sudo /opt/golden/ubuntu/firstboot/golden-update.sh`.)

It replaces `/opt/golden` with the repo's copy (keeping the laptop's `vars/local.yml`),
reinstalls the first-boot pieces and runs the playbook again. A laptop installed before this
script existed can fetch it with the `curl` line at the top of the script.

### Re-converging a laptop later

```bash
sudo ansible-pull -U https://github.com/Moon-Knight13/medicat-usb.git golden/ubuntu/playbook.yml
```

### Updating a stick after changing anything here

```bash
./make-stick.sh golden /media/$USER/Medicat    # seconds, no wipe; then eject the stick
```

Do not copy the folder by hand: the recipe on the stick is the packed one.

### Changing what gets installed

Edit `vars/apps.yml`. Packages are grouped so a whole group can be deleted; repos are deb822
entries with their signing key URL; snaps, flatpaks and dconf settings are plain lists.
Lint before committing: `ansible-lint golden/ubuntu/playbook.yml`.

### ClamAV

Set up to cost nothing while idle. Settings live under `clamav_*` in `vars/apps.yml`.

- Signatures update in the background (`clamav-freshclam`, 4 checks a day).
- The scanner (`clamd`, about 1 GB of RAM once loaded) is not kept running. It starts on
  demand when something scans, for example `clamdscan --fdpass ~/Downloads`.
- `golden-clamscan.timer` scans `/home` weekly at the lowest CPU and disk priority, on
  mains power only, then stops the scanner. Caches, Steam libraries and VM disks are skipped.
- `clamav_exclude_paths` applies to the scanner daemon, so to the weekly scan and to
  `clamdscan`. A plain `clamscan` ignores it; pass `--exclude-dir` yourself.
- Findings: `/var/log/clamav/golden-scan.log`. A scan that finds something leaves
  `golden-clamscan.service` in the failed state (`systemctl --failed`). Nothing is deleted
  or quarantined automatically.

### Testing without a laptop

```bash
tools/vm-test.sh iso                 # boots the ISO with this recipe in a KVM VM (window + VNC :9)
tools/vm-test.sh iso --unattended    # identity/storage pre-answered with throwaway values: full hands-off run
tools/vm-test.sh stick /dev/sdX      # boots the real stick read-only to check the Ventoy menu
OFFLINE=1 tools/vm-test.sh stick /dev/sdX --install   # the real thing: install from the stick, no network
```

## golden/raspberrypi

Not an installer recipe: `pi-flash` writes a Raspberry Pi's SD card from a golden laptop,
and `pi` opens a shell on the Pi over Wi-Fi, USB or a direct Ethernet cable. The playbook
installs both and the stick carries the pinned image (`isos/RaspberryPi/`), so a Pi can be
flashed offline. Details: [raspberrypi/README.md](raspberrypi/README.md).
