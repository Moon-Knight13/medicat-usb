#!/usr/bin/env bash
# golden-pack.sh — print golden/<name>/autoinstall.yaml with the golden folder packed inside it.
#
#   tools/golden-pack.sh ubuntu > /path/on/stick/golden/ubuntu/autoinstall.yaml
#
# The installer cannot read the folder from the stick (Ventoy holds the partition while the
# ISO is booted), so the recipe carries it: the "# @GOLDEN_PAYLOAD@" line in the template is
# replaced with a late-command that unpacks the folder to /opt/golden on the new system.
# make-stick.sh and vm-test.sh call this; the template in git stays readable.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name=${1:?usage: golden-pack.sh <name>}
tmpl="$KIT/golden/$name/autoinstall.yaml"
[[ -f "$tmpl" ]] || { echo "ERROR: $tmpl not found" >&2; exit 1; }
grep -q '^ *# @GOLDEN_PAYLOAD@$' "$tmpl" || { echo "ERROR: $tmpl has no # @GOLDEN_PAYLOAD@ line" >&2; exit 1; }

payload=$(tar -czf - -C "$KIT/golden" --exclude='autoinstall.yaml' --exclude='__pycache__' --sort=name --owner=0 --group=0 --mtime='2000-01-01' . | base64 -w 100)
while IFS= read -r line; do
    if [[ "$line" =~ ^(\ *)#\ @GOLDEN_PAYLOAD@$ ]]; then
        pad=${BASH_REMATCH[1]}
        printf '%s- mkdir -p /target/opt/golden\n' "$pad"
        printf '%s- |\n' "$pad"
        printf "%s  base64 -d <<'GOLDEN_EOF' | tar -xz -C /target/opt/golden\n" "$pad"
        while IFS= read -r b; do printf '%s  %s\n' "$pad" "$b"; done <<< "$payload"
        printf '%s  GOLDEN_EOF\n' "$pad"
    else
        printf '%s\n' "$line"
    fi
done < "$tmpl"
