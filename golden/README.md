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
| Hand-off | `autoinstall.yaml` late commands | Copies this folder to `/opt/golden` on the laptop and arms `golden-firstboot.service`. |
| First boot | `firstboot/` | Waits for network, runs `ansible-pull` from this repo (falls back to the local copy), retries every 2 minutes and on every boot until it succeeds, then disables itself. Log: `/var/log/golden-firstboot.log`. |
| Apps and settings | `playbook.yml`, `vars/apps.yml`, `files/` | Repos, packages, snaps, flatpaks, .deb downloads, user groups, dotfiles, GNOME settings. |

### At the laptop

1. Boot the stick, choose Ubuntu, choose the golden template when Ventoy asks.
2. **Disk setup**: choose "Erase disk and install Ubuntu" (a machine that already has an
   operating system pre-selects "Install alongside"), Next.
3. **Encryption**: choose "Encrypt with a passphrase" (or hardware-backed encryption on a
   machine with a TPM, which unlocks automatically), set the passphrase, Next.
4. **Identity**: your name, username, password, Next.
5. Walk away. The install finishes, reboots, and the first boot pulls the playbook.
   Give it 15 to 30 minutes with network; check progress with
   `journalctl -u golden-firstboot -f`.

### Personal values that stay out of git

`vars/local.yml` (git-ignored, copy from `vars/local.yml.example`) holds values that are
yours but not for a public repo, such as your git name and email. `build` copies it onto the
stick with the rest of this folder and the first boot applies it from there. Without it,
git is left in "ask me for an email" mode rather than guessing.

### Re-converging a laptop later

```bash
sudo ansible-pull -U https://github.com/Moon-Knight13/medicat-usb.git golden/ubuntu/playbook.yml
```

### Changing what gets installed

Edit `vars/apps.yml`. Packages are grouped so a whole group can be deleted; repos are deb822
entries with their signing key URL; snaps, flatpaks and dconf settings are plain lists.
Lint before committing: `ansible-lint golden/ubuntu/playbook.yml`.

### Testing without a laptop

```bash
tools/vm-test.sh iso                 # boots the ISO with this recipe in a KVM VM (window + VNC :9)
tools/vm-test.sh iso --unattended    # identity/storage pre-answered with throwaway values: full hands-off run
tools/vm-test.sh stick /dev/sdX      # boots the real stick read-only to check the Ventoy menu
```
