#!/bin/bash
# golden-update.sh — bring an installed laptop up to date with the repo, without reinstalling.
#
#   curl -fsSL https://raw.githubusercontent.com/Moon-Knight13/medicat-usb/main/golden/ubuntu/firstboot/golden-update.sh | sudo bash
#   sudo /opt/golden/ubuntu/firstboot/golden-update.sh [branch]        (default branch: main)
#
# Replaces /opt/golden with the repo's golden/ folder (keeping this laptop's vars/local.yml),
# reinstalls the first-boot script, its unit and golden-status, then runs the playbook again
# through the first-boot unit. Safe to repeat: the playbook only changes what differs.
set -euo pipefail
REPO="${GOLDEN_REPO:-https://github.com/Moon-Knight13/medicat-usb.git}"
BRANCH="${1:-${GOLDEN_BRANCH:-main}}"
[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo" >&2; exit 1; }

command -v git >/dev/null || { apt-get -q update && apt-get -qy install git; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$tmp/repo"
[[ -f "$tmp/repo/golden/ubuntu/playbook.yml" ]] || { echo "ERROR: branch $BRANCH has no golden/ubuntu/playbook.yml" >&2; exit 1; }

local_vars=/opt/golden/ubuntu/vars/local.yml
[[ -f "$local_vars" ]] && cp -p "$local_vars" "$tmp/local.yml"
rm -rf /opt/golden/README.md /opt/golden/ubuntu
mkdir -p /opt/golden && cp -r "$tmp/repo/golden/." /opt/golden/
[[ -f "$tmp/local.yml" ]] && cp -p "$tmp/local.yml" "$local_vars"

fb=/opt/golden/ubuntu/firstboot
install -m 0755 "$fb/golden-firstboot.sh" /usr/local/sbin/golden-firstboot.sh
install -m 0644 "$fb/golden-firstboot.service" /etc/systemd/system/golden-firstboot.service
install -m 0755 "$fb/golden-status" /usr/local/bin/golden-status
install -D -m 0644 "$fb/golden-status.desktop" /etc/xdg/autostart/golden-status.desktop

# Run it again through the unit, so retries and the log behave as on a first boot.
rm -f /var/lib/golden/done
systemctl daemon-reload
systemctl enable -q golden-firstboot.service
systemctl restart --no-block golden-firstboot.service
echo "Updated /opt/golden from $REPO ($BRANCH, $(git -C "$tmp/repo" rev-parse --short HEAD)) and started the install."
echo "Watch it with: golden-status --watch"
