#!/bin/bash
# Runs as root at first boot (and again on every boot until it succeeds).
# 0. Install git and ansible if missing (needs network; join Wi-Fi after the first login).
# 1. Try ansible-pull from GitHub so the laptop gets the latest playbook.
# 2. Fall back to the copy carried over from the stick (/opt/golden).
# On success, mark done and disable the unit. Log: /var/log/golden-firstboot.log
set -uo pipefail
# /etc/default/golden (written by golden-update.sh) can pin GOLDEN_REPO and GOLDEN_BRANCH.
[[ -f /etc/default/golden ]] && . /etc/default/golden
REPO="${GOLDEN_REPO:-https://github.com/Moon-Knight13/medicat-usb.git}"
BRANCH="${GOLDEN_BRANCH:-main}"
PLAYBOOK="golden/ubuntu/playbook.yml"
LOG=/var/log/golden-firstboot.log
export ANSIBLE_FORCE_COLOR=0 DEBIAN_FRONTEND=noninteractive

{
echo "=== golden-firstboot $(date -Is) ==="
[[ "$BRANCH" == main ]] || echo "=== following branch $BRANCH (no branch protection); golden-update main to switch back"
# The installer adds nothing beyond the ISO, so fetch what the playbook run needs.
need=(); for p in git ansible curl python3-apt; do dpkg -s "$p" >/dev/null 2>&1 || need+=("$p"); done
if (( ${#need[@]} )); then
    echo "=== installing ${need[*]}"
    if ! { apt-get -q update && apt-get -qy install "${need[@]}"; }; then
        echo "=== could not install ${need[*]} (is the laptop online?); will retry in 2 minutes and on next boot"
        exit 1
    fi
fi
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
[[ -f /var/lib/golden/todo ]] && { echo "=== still to do by hand:"; cat /var/lib/golden/todo; }
systemctl disable golden-firstboot.service
rm -f /etc/xdg/autostart/golden-status.desktop      # no progress window at later logins
echo "=== done; re-run any time with: sudo ansible-pull -U $REPO $PLAYBOOK"
} >> "$LOG" 2>&1
