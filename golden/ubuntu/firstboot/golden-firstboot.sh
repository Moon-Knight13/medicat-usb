#!/bin/bash
# Runs as root at first boot (and again on every boot until it succeeds).
# 1. Try ansible-pull from GitHub so the laptop gets the latest playbook.
# 2. Fall back to the copy carried over from the stick (/opt/golden).
# On success, mark done and disable the unit. Log: /var/log/golden-firstboot.log
set -uo pipefail
REPO="${GOLDEN_REPO:-https://github.com/Moon-Knight13/medicat-usb.git}"
BRANCH="${GOLDEN_BRANCH:-main}"
PLAYBOOK="golden/ubuntu/playbook.yml"
LOG=/var/log/golden-firstboot.log
export ANSIBLE_FORCE_COLOR=0 DEBIAN_FRONTEND=noninteractive

{
echo "=== golden-firstboot $(date -Is) ==="
LOCAL=/opt/golden/ubuntu/vars/local.yml; EXTRA=(); [[ -f "$LOCAL" ]] && EXTRA=(-e "@$LOCAL")
if ansible-pull -U "$REPO" -C "$BRANCH" -d /opt/golden/repo -i localhost, "${EXTRA[@]}" "$PLAYBOOK"; then
    echo "=== playbook applied from $REPO"
elif [[ -f /opt/golden/ubuntu/playbook.yml ]] \
     && ansible-playbook -i localhost, -c local /opt/golden/ubuntu/playbook.yml; then
    echo "=== playbook applied from local copy /opt/golden"
else
    echo "=== playbook FAILED; will retry in 2 minutes and on next boot"
    exit 1
fi
mkdir -p /var/lib/golden && date -Is > /var/lib/golden/done
systemctl disable golden-firstboot.service
echo "=== done; re-run any time with: sudo ansible-pull -U $REPO $PLAYBOOK"
} >> "$LOG" 2>&1
