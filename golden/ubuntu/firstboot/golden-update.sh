#!/bin/bash
# golden-update.sh — bring an installed laptop up to date with the repo, without reinstalling.
#
#   sudo /opt/golden/ubuntu/firstboot/golden-update.sh [branch]   (default: the branch last used, else main)
#   From a laptop that does not have it yet (replace <branch> with main once golden/ is merged):
#   curl -fsSL https://raw.githubusercontent.com/Moon-Knight13/medicat-usb/<branch>/golden/ubuntu/firstboot/golden-update.sh | sudo bash -s <branch>
#
# Replaces /opt/golden with the repo's golden/ folder (keeping this laptop's vars/local.yml),
# reinstalls the first-boot script, its unit and golden-status, remembers the branch in
# /etc/default/golden so first-boot's ansible-pull uses the same one, then runs the playbook
# again through the first-boot unit. Safe to repeat: the playbook only changes what differs.
set -euo pipefail
[[ -f /etc/default/golden ]] && . /etc/default/golden
REPO="${GOLDEN_REPO:-https://github.com/Moon-Knight13/medicat-usb.git}"
BRANCH="${1:-${GOLDEN_BRANCH:-main}}"
[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo" >&2; exit 1; }

# Never cut a running install short: stopping apt or snap halfway leaves packages half set up.
if pgrep -f 'ansible-playbook|ansible-pull' >/dev/null; then
    echo "An install is running; waiting for it to end before updating (golden-status shows where it is)."
    while pgrep -f 'ansible-playbook|ansible-pull' >/dev/null; do sleep 10; done
fi

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
printf 'GOLDEN_REPO=%s\nGOLDEN_BRANCH=%s\n' "$REPO" "$BRANCH" > /etc/default/golden

# Run it again through the unit, so retries and the log behave as on a first boot.
rm -f /var/lib/golden/done
systemctl daemon-reload
systemctl enable -q golden-firstboot.service
systemctl restart --no-block golden-firstboot.service
echo "Updated /opt/golden from $REPO ($BRANCH, $(git -C "$tmp/repo" rev-parse --short HEAD)) and started the install."
echo "Watch it with: golden-status --watch"
