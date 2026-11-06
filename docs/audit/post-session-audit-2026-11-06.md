# Post-Session Security Audit — 2026-11-06

**Scope:** Full repository (`MoonKnight13/medicat-usb`), with focus on `tools/hw-survey.sh` added in `b95b5c3`.

**Auditor:** Claude Opus 4.6 (automated)

---

## Summary

| Severity | Count |
|----------|-------|
| HIGH     | 2     |
| MEDIUM   | 3     |
| LOW      | 3     |
| INFO     | 3     |
| **Total**| **11** |

---

## HIGH

### H1 — `hw-survey.sh` collects system serial number

**File:** `tools/hw-survey.sh:68`

`dmidecode -s system-serial-number` captures hardware serial, which is PII under
some frameworks (uniquely identifies a physical device/owner). The script writes
it to stdout JSON. While there is no network exfiltration (confirmed: zero
`curl`/`wget`/`nc`/`ssh` calls), the serial is still in the output file.

**Risk:** If output files are committed, shared, or uploaded, serial numbers leak.
This is amplified by the homelab use case where outputs may be pasted into issues
or stored in repos.

**Recommendation:** Redact or hash serial number by default. Add a `--full` flag
to include it when deliberately inventorying hardware.

### H2 — `tools/hwtest.sh` performs destructive raw writes with no confirmation

**File:** `tools/hwtest.sh:14-28`

Opens device with `O_RDWR|O_DIRECT|O_SYNC` and writes pattern data directly to
block device LBAs. Also calls `f3probe --destructive`. This is by design (USB
verification tool), but:

- No confirmation prompt before destructive write
- `DEV` defaults to `/dev/sdb` — wrong device = data loss
- `umount ${DEV}*` without quoting risks glob expansion on unusual device names

**Risk:** Accidental data destruction if run against wrong device. Not hw-survey.sh
itself, but in the same `tools/` directory and runs on live hardware.

**Recommendation:** Add interactive confirmation (`"About to DESTROY all data on $DEV. Type YES to continue"`). Quote `${DEV}*` as `"${DEV}"*`.

---

## MEDIUM

### M1 — `vm-test.sh` contains hardcoded test password hash

**File:** `tools/vm-test.sh:108`

SHA-512 crypt hash for password `"goldentest"` and LUKS passphrase
`"goldentest-luks"` are committed in source. These are intentionally throwaway
VM-only credentials (documented in comments), so no immediate secret leak, but:

- If someone reuses these strings in production, they are public
- Gitleaks allowlist does not explicitly cover SHA-512 crypt hashes

**Risk:** Low actual, medium if copied to non-test contexts.

**Recommendation:** Add a comment in the file stating these are test-only and
must never be reused. Consider generating them at runtime.

### M2 — `claude-setup.sh` pipes curl to bash

**File:** `golden/ubuntu/files/claude-setup.sh:15`

`curl -fsSL https://claude.ai/install.sh | bash` is a standard install pattern
but has no integrity verification (unlike the caveman installer at line 37 which
pins version + SHA256).

**Risk:** Supply-chain compromise if claude.ai/install.sh is tampered.

**Recommendation:** Pin a version and verify checksum, as done for caveman at
lines 36-37 of the same file.

### M3 — template-sync workflow failing since at least 2026-10-05

**File:** `.github/workflows/template-sync.yml`

Last 5 runs all failed. Nov 2 failure confirmed: sync includes workflow-file
changes but `TEMPLATE_SYNC_TOKEN` secret is not configured.

```
This sync changes files under .github/workflows/, which the default
GITHUB_TOKEN can never push
```

This means template security patches to workflow files are not reaching this repo.

**Risk:** Missing upstream security fixes in CI workflows.

**Recommendation:** Add `TEMPLATE_SYNC_TOKEN` fine-grained PAT secret (Contents +
Pull requests + Workflows read-write on this repo).

---

## LOW

### L1 — Stale remote branches

**Branches:**
- `origin/feat/raspberrypi-flasher` — appears merged/superseded
- `origin/fix/golden-protonvpn-downgrade` — merged via PR #27
- `origin/fix/golden-weekly-deck-retry` — merged via PR #28
- 3 dependabot branches (golang, node, codeql-action)

**Risk:** Branch clutter; stale branches may confuse contributors.

**Recommendation:** Delete merged branches. Verify `feat/raspberrypi-flasher`
status (plan file exists at `docs/superpowers/plans/2026-10-03-raspberrypi-flasher.md`
but branch may be abandoned).

### L2 — `scripts/ci/` directory missing

**File:** `.github/workflows/ci.yml:66-83`

CI workflow references `scripts/ci/*.sh` hook scripts (lint-node, test-node,
lint-python, etc.) but `scripts/ci/` does not exist. The workflow handles this
gracefully (prints a `::notice::` and skips), but means CI currently validates
only template integrity — no project-specific linting or testing runs.

**Risk:** No automated test gate on PRs beyond template validation.

**Recommendation:** Acceptable for a shell-script-heavy project. Consider adding
`shellcheck` as `scripts/ci/lint-node.sh` equivalent for bash.

### L3 — Uncommitted change to `golden/ubuntu/files/deck/deck`

**File:** `golden/ubuntu/files/deck/deck` (modified, 13 insertions, 4 deletions)

Working tree has uncommitted changes to deck script. Not a security issue but
noted for completeness.

---

## INFO

### I1 — `hw-survey.sh` safety assessment: PASS

Verified all safety criteria:

| Check | Result |
|-------|--------|
| No destructive ops (no writes to disk, no package installs) | **PASS** — read-only commands only (`lscpu`, `free`, `dmidecode -s`, `lsblk`, `smartctl`, `lspci`, `ip`, `upower`). No `mkfs`/`dd`/`fdisk`/`apt`/`pip`. |
| No network calls | **PASS** — zero instances of `curl`/`wget`/`nc`/`ssh`/`http` |
| Graceful degradation without root | **PASS** — `needs_root()` function (line 15) warns and skips. `have()` checks tool availability. |
| No eval or command injection | **PASS** — no `eval` anywhere. `$()` subshells only capture tool output, not user-controlled input. `json_escape` uses Python's `json.dumps` for safe escaping. |
| No data exfiltration | **PASS** — output goes to stdout only. No file writes, no network calls. |

Only finding: serial number collection (see H1).

### I2 — Secrets scan: PASS

No hardcoded passwords, tokens, or API keys found in repository files.

- Gitleaks config (`.gitleaks.toml`) covers Anthropic keys, PII, credit cards, SSN, UK NINO, phone numbers
- Pre-commit hooks enforce gitleaks on every commit
- CI runs gitleaks with full history scan weekly + on every PR/push
- Semgrep CI runs `p/secrets` + `p/security-audit` + custom ATLAS rules
- `check-day0.sh` actively rejects `GITHUB_TOKEN` in environment (browser OAuth enforced)
- `vm-test.sh` passwords are intentional throwaway test credentials (documented)

No secret files (`.key`, `.pem`, `.env`, etc.) found in git history.

### I3 — No large binaries in git history

Largest blob is 57KB (a planning document). No binary artifacts, images, or
compiled files tracked in git. `.vm/` and `.ai/` directories are gitignored.

---

## Deleted Files / Dead Code

| Deleted File | Status |
|---|---|
| `golden/ubuntu/firstboot/golden-projects` | Clean — playbook.yml:339 has explicit removal task |
| `golden/ubuntu/files/deck/deck-reset` | Clean — playbook.yml:687 has explicit removal task |

Both deletions are handled by Ansible cleanup tasks. No orphaned references.

---

## CI Health Summary

| Workflow | Status | Notes |
|----------|--------|-------|
| `ci.yml` | Healthy | Template validation passes; stack-specific hooks absent but handled gracefully |
| `secret-scan.yml` | Healthy | Gitleaks full-history scan, weekly + PR/push |
| `semgrep.yml` | Healthy | Custom rules + p/secrets + p/security-audit |
| `container-scan.yml` | Healthy | Trivy scan, CRITICAL gate, SARIF upload |
| `repository-audit.yml` | Healthy | Weekly required-files check |
| `pages.yml` | Healthy | Deploys docs/explainer to Pages |
| `template-sync.yml` | **FAILING** | Missing `TEMPLATE_SYNC_TOKEN` — see M3 |

All workflows use pinned action SHAs (not tags). Good practice.

---

## Recommendations Priority

1. **M3** — Add `TEMPLATE_SYNC_TOKEN` secret to unblock template sync (blocks upstream security fixes)
2. **H1** — Redact/hash serial number in hw-survey.sh output
3. **H2** — Add confirmation prompt to hwtest.sh before destructive writes
4. **M2** — Pin Claude Code installer with checksum verification
5. **L1** — Clean up merged remote branches
