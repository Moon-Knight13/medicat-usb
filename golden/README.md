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
   encryption alone: it is untested here and may not load the VirtualBox or NVIDIA modules.
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

### Manual step on every machine with Secure Boot: trust the VirtualBox signing key

VirtualBox builds its own kernel modules and signs them with a key made on the laptop
(`/var/lib/shim-signed/mok/MOK.der`). With Secure Boot on, the firmware refuses those modules
until that key is enrolled, which needs a one-time password and a confirmation at the next
boot. Nothing unattended can do it, so the install finishes and `golden-status` says:

```
Still to do by hand:
  VirtualBox cannot start VMs until its signing key is trusted (Secure Boot is on).
  Once, at this laptop:  sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
  then reboot, choose "Enroll MOK" on the blue screen and enter the password you set.
```

Steps: run that `mokutil --import`, set a password, reboot. A blue "MOK management" screen
appears (it times out in about 10 seconds): **Enroll MOK**, Continue, Yes, type the password,
reboot. `VBoxManage --version` then prints only the version, and the note disappears at the
next playbook run. Everything else (KVM, libvirt, Docker) works with Secure Boot on regardless.

- **Fresh hardware**: always needed once per machine; the enrolment lives in that machine's
  firmware.
- **Reinstalling the same laptop**: the enrolment survives, but the reinstall makes a new key,
  so enrol again. (The old key stays in the firmware unused; `mokutil --delete` removes it.)
  Reusing one key across reinstalls would avoid this, at the cost of carrying the private key
  on the stick; not done by default.
- Choose "Enroll MOK", not "Enroll key from disk": the latter browses the EFI partition and
  the key is not there.

### Continuing work on the new machine: SSH, projects, sign-ins

- **A new SSH key is made on every machine** (`~/.ssh/id_ed25519`); private keys are never
  carried on the stick. The finish note shows the public key and the commands to add it to
  GitHub (`gh auth login`, `gh ssh-key add`) and to servers (`ssh-copy-id`). A lost laptop
  then means revoking one key, not all of them.
- **Your `~/.ssh/config` can ride on the stick**: copy it to `golden/ubuntu/local/ssh_config`
  (git-ignored), with `IdentityFile ~/.ssh/id_ed25519` for the hosts. It holds host names,
  addresses and usernames, so it is on the stick, not in the public repo. Same folder for
  anything else personal but not secret.
- **Projects**: list repositories under `projects:` in `vars/local.yml`. Public ones clone
  into `~/Documents` at first boot; after signing in, `golden-projects` clones the rest.
- **Sign-ins stay manual** by design: GitHub CLI, Firefox, Discord, Spotify, Steam, Proton
  VPN, Obsidian Sync, Claude Code. Their tokens are the one thing a stick must not carry.

### Claude Code

`claude` (the command-line tool) is installed for your user with the official plugins
(superpowers, code-review, commit-commands, skill-creator, frontend-design) and the caveman
plugin, pinned by version and installer checksum in `files/claude-setup.sh`. Run `claude` once
to sign in. (The VS Code extension is not installed; everything is CLI.)

### deck: a disposable browser VM

For research that should leave no trace on the laptop. `deck-create` builds a VirtualBox VM
called `deck` (minimal Ubuntu with Firefox, throwaway login `deck`/`deck`, no shared folders
or clipboard) from the Ubuntu ISO the install kept at `/opt/golden/ubuntu.iso`, then snapshots
it as "Ready". About 15 minutes, unattended. Sizes scale to the host (half the CPUs, a quarter
of the RAM, within `deck_*` in `vars/apps.yml`).

- `deck-reset`: throw away everything since the last snapshot and start it. Use this every time.
- To update the guest: start it, update inside, then `VBoxManage snapshot deck take "updated <month>"`.
- The first boot creates it when VirtualBox can run. On a Secure Boot machine that is only
  after the key enrolment above, so the finish note says to run `deck-create` yourself.

### Staying current after deployment

| What | How | When |
|---|---|---|
| Ubuntu security and updates, plus the third-party repos (VS Code, Docker, GitHub CLI, Terraform, VirtualBox, Proton) | unattended-upgrades, `auto_update_origins` in `vars/apps.yml` | daily, never reboots by itself |
| Snaps (Firefox, Spotify, Steam) | snapd | several times a day |
| Flatpaks (Bambu Studio) | `golden-flatpak-update.timer` | weekly, on mains power |
| Discord, Obsidian | update themselves | on launch |
| ClamAV signatures | freshclam | 4 times a day |
| Firmware and BIOS | fwupd metadata daily; updates listed by `golden-status`, applied by you | daily |
| This recipe | `sudo golden-update.sh` when you choose to | never by itself |

`golden-status` says when a reboot is pending. Nothing re-applies the recipe by itself: run
`sudo golden-update.sh` to bring a laptop up to date. An update never wipes, reboots or removes
anything, and it leaves your personal preferences alone: desktop settings, VS Code settings, git
and ssh config and dotfiles are applied once at first boot, and changes you make afterwards
stay. To re-apply them: `sudo golden-update.sh --preferences`.

### Watching the first boot

A "Golden install" terminal window opens at login and lists each step until it finishes (it
can open behind Ubuntu's welcome screen; a notification points to it). At any time:

```bash
golden-status            # one line: waiting for a network, step N of about M, failed, finished
golden-status --watch    # keep watching
```

### Repairing or updating a laptop without reinstalling

```bash
sudo /opt/golden/ubuntu/firstboot/golden-update.sh          # from main
sudo /opt/golden/ubuntu/firstboot/golden-update.sh <branch>  # from a branch
```

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
