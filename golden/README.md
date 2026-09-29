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
