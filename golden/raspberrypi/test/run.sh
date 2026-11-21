#!/usr/bin/env bash
# Run the golden/raspberrypi tests: no hardware, no sudo, no network.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "$HERE"/test-*.sh; do
    if bash "$t"; then echo "PASS $(basename "$t")"; else echo "FAIL $(basename "$t")"; fail=1; fi
done
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x "$HERE/../pi" "$HERE/../pi-flash" "$HERE"/*.sh; then echo "PASS shellcheck"; else echo "FAIL shellcheck"; fail=1; fi
else
    echo "SKIP shellcheck (install: sudo apt install shellcheck)"
fi
exit "$fail"
