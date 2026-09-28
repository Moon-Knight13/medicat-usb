# medicat-usb

[![ci](https://github.com/Moon-Knight13/medicat-usb/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/medicat-usb/actions/workflows/ci.yml)
[![semgrep](https://github.com/Moon-Knight13/medicat-usb/actions/workflows/semgrep.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/medicat-usb/actions/workflows/semgrep.yml)
[![secret-scan](https://github.com/Moon-Knight13/medicat-usb/actions/workflows/secret-scan.yml/badge.svg?branch=main)](https://github.com/Moon-Knight13/medicat-usb/actions/workflows/secret-scan.yml)

> **Created from the [`claude_template_repo`](https://github.com/Moon-Knight13/claude_template_repo) template.**
> That template supplies the secure Claude-first scaffolding (AI routing, security
> gates, BMAD, Kanban, devcontainer) this repo is *built with*. What this repo *does*
> is build a bootable rescue stick — see below.

**Build a [MediCat USB](https://medicatusb.com/) rescue stick from official sources with
one script.** `make-stick.sh` fetches the latest [Ventoy](https://www.ventoy.net/),
the current MediCat toolkit, and the newest Ubuntu ISO, verifies every download against
its publisher's checksum, tests the stick for counterfeit capacity, and writes it.

Nothing bootable is stored in this repo. Every archive and ISO is downloaded from its
own publisher at build time, so the repo carries only the recipe.

## Make a stick

```bash
git clone https://github.com/Moon-Knight13/medicat-usb.git
cd medicat-usb
./make-stick.sh update          # fetch Ventoy, MediCat (~21 GB) and the latest Ubuntu ISO
./make-stick.sh list            # find the stick, e.g. /dev/sdb
./make-stick.sh build /dev/sdb  # wipes that stick and builds it (asks you to confirm, then for sudo)
```

Requirements: a 64 GB or larger USB stick, about 30 GB of free disk for the downloads,
and on Debian/Ubuntu: `sudo apt install p7zip-full ntfs-3g parted dosfstools aria2 f3`.

The build takes 20 to 40 minutes, mostly extracting the 28 GB MediCat tree. The script
refuses anything that is not a whole USB disk, and runs `f3probe` first so a
counterfeit-capacity stick is rejected before anything is written (`--skip-test` skips
that). MBR layout is the default because it boots on old BIOS machines as well as UEFI;
`--gpt` is available if you need it.

## Keep it fresh

`./make-stick.sh update` refreshes each source, skipping anything already current and
verified:

| Source | How the latest version is found | Verified by |
|---|---|---|
| Ventoy | newest GitHub release | release tarball |
| MediCat | version + SHA-256 read from the [official installer](https://github.com/mon5termatt/medicat_installer), downloaded from the official mirrors | SHA-256 |
| Ubuntu | newest desktop amd64 ISO on releases.ubuntu.com; older ISOs are removed | SHA256SUMS |
| `extra-isos.txt` | fixed URLs, one `Folder/on/stick \| URL` per line | none, downloaded once |

## Settings

`make-stick.conf` is committed, so every stick built from this repo comes out the same:

```sh
: "${UBUNTU_LTS_ONLY:=1}"        # LTS releases only (recommended for a rescue stick)
: "${UBUNTU_FLAVOUR:=desktop}"   # desktop | server
: "${PARTITION_STYLE:=mbr}"      # mbr boots BIOS + UEFI; gpt if you need it
: "${STICK_TEST:=1}"             # f3probe before writing, rejects counterfeit sticks
```

Edit the file to change the defaults for the repo, or set the same name as an environment
variable for a one-off run, e.g. `UBUNTU_LTS_ONLY=0 ./make-stick.sh update`. The build
flags `--gpt`, `--mbr` and `--skip-test` override the file for a single build.

## Adding your own ISOs

Drop files anywhere under `isos/`; the tree is copied to the stick as-is and Ventoy lists
everything bootable. Match MediCat's folders so the boot menu stays tidy, for example
`isos/Live_Operating_Systems/Linux_Mint/linuxmint-22.2.iso`. Files under `isos/` are
git-ignored.

## Layout

| Path | What |
|---|---|
| `make-stick.sh` | the tool: `update`, `list`, `build`, `status` |
| `make-stick.conf` | repeatable settings, committed |
| `extra-isos.txt` | extra downloads for `update`, committed |
| `tools/hwtest.sh` | deeper write/read-back test for a suspect stick: `sudo tools/hwtest.sh /dev/sdX` |
| `MediCat.USB.<ver>.7z`, `ventoy/`, `isos/`, `logs/` | fetched or generated locally, git-ignored |

## Licensing

The scripts here are Apache 2.0 (see `LICENSE`). MediCat, Ventoy, Ubuntu and the tools
inside the MediCat archive are each licensed by their own publishers and are never
redistributed by this repo; `update` downloads them from their official sources onto
your machine, exactly as MediCat's own installer does.

## Notes

- First boot on a Secure Boot machine asks you to enrol Ventoy's key through MokManager once.
- If a stick fails `f3probe`, or the build reports that the partitions vanished after the
  Ventoy install, the stick is faulty. Bin it; no formatting will fix it.
- The repo itself is developed inside the devcontainer inherited from the template; see
  [docs/TEMPLATE_GUIDE.md](docs/TEMPLATE_GUIDE.md).
