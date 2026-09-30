#!/bin/bash
# claude-setup.sh — Claude Code (CLI) for the current user, with the plugin set and caveman.
# Run by the golden playbook as the primary user; safe to repeat. Signing in stays manual:
# run `claude` once and follow the login prompt.
set -euo pipefail
read -r -a PLUGINS <<< "${CLAUDE_PLUGINS:-superpowers code-review commit-commands skill-creator frontend-design}"
CAVEMAN_VERSION=${CAVEMAN_VERSION:-v1.9.0}
CAVEMAN_SHA256=${CAVEMAN_SHA256:-8ddef49c15f089c26affed3c31d97142c683e1d37a1499ae557281ca09c2712c}
CAVEMAN_MODE=${CAVEMAN_MODE:-lite}
export PATH="$HOME/.local/bin:$PATH"
changed=0

if ! command -v claude >/dev/null; then
    echo "installing Claude Code"
    curl -fsSL https://claude.ai/install.sh | bash >/dev/null
    changed=1
fi
command -v claude >/dev/null || { echo "claude not on PATH after install" >&2; exit 1; }

# Plugins from the official marketplace (no sign-in needed for this part).
claude plugin marketplace add anthropics/claude-plugins-official >/dev/null 2>&1 || true
claude plugin marketplace update claude-plugins-official >/dev/null 2>&1 || true
installed=$(claude plugin list 2>/dev/null || true)
for p in "${PLUGINS[@]}"; do
    if ! grep -q "^\s*❯ $p@" <<< "$installed"; then
        echo "installing plugin $p"
        claude plugin install "$p@claude-plugins-official" --scope user >/dev/null && changed=1
    fi
done

# caveman (terse-output plugin), pinned to a version and the checksum of its installer.
marker="$HOME/.claude/.template-caveman-version"
if ! { [[ -f "$marker" ]] && grep -qx "$CAVEMAN_VERSION" "$marker"; }; then
    echo "installing caveman $CAVEMAN_VERSION"
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    curl -fsSL "https://raw.githubusercontent.com/JuliusBrussee/caveman/$CAVEMAN_VERSION/install.sh" -o "$tmp"
    echo "$CAVEMAN_SHA256  $tmp" | sha256sum -c --quiet
    CAVEMAN_MODE="$CAVEMAN_MODE" bash "$tmp" --only claude --non-interactive >/dev/null
    mkdir -p "$HOME/.claude" && echo "$CAVEMAN_VERSION" > "$marker"
    changed=1
fi
[[ $changed -eq 1 ]] && echo "changed" || echo "up to date"
