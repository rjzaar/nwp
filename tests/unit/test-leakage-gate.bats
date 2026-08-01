#!/usr/bin/env bats
# tests/unit/test-leakage-gate.bats — the leakage gate must actually gate.
#
# nwp fix-programme item 6 (`leakage-gate-scope`).
#
# `.gitleaks.toml` is the ONE blocking security gate on every MR and every push
# to main (`lint:leakage`, allow_failure: false). Two independent holes made it
# report clean on content it is supposed to stop, and a third was found while
# fixing them:
#
#   1. The path exemptions lived in the TOP-LEVEL [allowlist], which disables
#      *every* rule for those paths — including the inherited AWS / GCP /
#      GitHub / GitLab-PAT credential rules. A byte-identical file was flagged
#      3x under lib/ and 0x under tests/, docs/reports/, docs/archive/,
#      docs/onboarding/, templates/ and servers/<host>/.
#   2. The three rules that catch the operator's public IP, personal email and
#      bare domain apex existed only on an unmerged branch.
#   3. gitleaks >= 8.25 ships a DEFAULT global allowlist containing
#      `^/(?:bin|etc|home|opt|tmp|usr|var)/[\w ./-]+$`, which matches the whole
#      secret reported by `operator-home-path` and silently killed that rule.
#      The gate downloads gitleaks 8.30.0 in CI while the dev box had 8.21.2,
#      so the rule worked locally and was dead in CI. `secretGroup` (report the
#      username, not the absolute path) makes it fire on both.
#
# EVERY assertion here is a "make it go red" assertion: remove a rule, widen a
# path exemption back into [allowlist], or drop `secretGroup`, and a case fails.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export REPO_ROOT
  export GITLEAKS_BIN
  GITLEAKS_BIN="$(_resolve_gitleaks)" || {
    echo "CANNOT VERIFY the leakage gate: no usable gitleaks binary." >&2
    echo "Set NWP_GITLEAKS_BIN=/path/to/gitleaks, or install gitleaks, or" >&2
    echo "allow the pinned download (needs network)." >&2
    return 1
  }
  export GITLEAKS_BIN
}

# Pinned to the same release the lint:leakage CI job installs, so the unit test
# and the gate agree about what the config means.
GITLEAKS_PINNED_VERSION="8.30.0"
GITLEAKS_PINNED_SHA256="79a3ab579b53f71efd634f3aaf7e04a0fa0cf206b7ed434638d1547a2470a66e"

_resolve_gitleaks() {
  if [ -n "${NWP_GITLEAKS_BIN:-}" ] && [ -x "${NWP_GITLEAKS_BIN}" ]; then
    printf '%s\n' "$NWP_GITLEAKS_BIN"; return 0
  fi
  if command -v gitleaks >/dev/null 2>&1; then
    command -v gitleaks; return 0
  fi
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/nwp/gitleaks-${GITLEAKS_PINNED_VERSION}"
  if [ -x "$cache/gitleaks" ]; then printf '%s\n' "$cache/gitleaks"; return 0; fi
  mkdir -p "$cache" || return 1
  local url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_PINNED_VERSION}/gitleaks_${GITLEAKS_PINNED_VERSION}_linux_x64.tar.gz"
  curl -sSfL --max-time 120 "$url" -o "$cache/gl.tgz" >/dev/null 2>&1 || return 1
  echo "${GITLEAKS_PINNED_SHA256}  $cache/gl.tgz" | sha256sum -c - >/dev/null 2>&1 || return 1
  tar -xzf "$cache/gl.tgz" -C "$cache" gitleaks >/dev/null 2>&1 || return 1
  [ -x "$cache/gitleaks" ] || return 1
  printf '%s\n' "$cache/gitleaks"
}

setup() {
  FIXROOT="${BATS_TEST_TMPDIR}/tree"
  rm -rf "$FIXROOT"
  mkdir -p "$FIXROOT"
  cp "${REPO_ROOT}/.gitleaks.toml" "$FIXROOT/.gitleaks.toml"
  # Report OUTSIDE the scanned tree — a report file inside it gets rescanned.
  REPORT="${BATS_TEST_TMPDIR}/report.json"
}

# The synthetic secrets are ASSEMBLED AT RUNTIME from fragments rather than
# written as literals. This file would otherwise trip the very gate it tests —
# it did, on the pre-commit hook, first try. Keeping the fragments split means
# no fingerprints for this file have to be parked in .gitleaksignore, so the
# ledger stays a real scrub backlog instead of accumulating test noise.
# If you "simplify" these back into literals, the commit will be refused.
_payload() {
  local pat="glpat-" akia="AKIA" at="@"
  cat <<EOF
gitlab_token = "${pat}ABCDEFGHIJKLMNOPQRST"
aws_key      = "${akia}QWERTYUIOPASDFGH"
home         = "/home/rob/nwp"
fqdn         = "carlo.local"
bare         = "metabox"
org          = "mazenod"
subdomain    = "nwd.nwpcode.org"
public_ip    = "97.107.137.88"
email        = "rjzaar${at}gmail.com"
apex         = "nwpcode.org"
EOF
}

# Write the identical leak payload at $FIXROOT/<relpath>.
_plant() {
  local rel="$1"
  mkdir -p "$FIXROOT/$(dirname "$rel")"
  _payload > "$FIXROOT/$rel"
}

# Run gitleaks over $FIXROOT with the repo config; echo "<file>|<rule>" lines.
_scan() {
  rm -f "$REPORT"
  ( cd "$FIXROOT" && "$GITLEAKS_BIN" detect --no-git --source . \
      --config .gitleaks.toml --report-format json --report-path "$REPORT" \
      --no-banner ) >/dev/null 2>&1 || true
  [ -s "$REPORT" ] || { echo ""; return 0; }
  python3 -c '
import json,sys
for f in json.load(open(sys.argv[1])):
    print("%s|%s" % (f["File"], f["RuleID"]))
' "$REPORT" | sort -u
}

_assert_hit() {   # _assert_hit "<findings>" <file> <rule>
  if ! printf '%s\n' "$1" | grep -qx "$2|$3"; then
    echo "EXPECTED $3 to fire in $2 — it did NOT." >&2
    echo "--- findings ---" >&2; printf '%s\n' "$1" >&2
    return 1
  fi
}

_assert_no_hit() {
  if printf '%s\n' "$1" | grep -qx "$2|$3"; then
    echo "EXPECTED $3 to be exempt in $2 — it FIRED." >&2
    return 1
  fi
}

# Directories the top-level [allowlist] used to blind completely.
EXEMPT_DIRS="tests docs/reports docs/archive docs/onboarding templates servers/mini"
CRED_RULES="gitlab-pat aws-access-token"
IDENTITY_RULES="operator-home-path internal-hostname-fqdn internal-bare-hostname operator-organisation live-internal-domain operator-public-ip live-domain-apex"

@test "credential rules fire in EVERY directory, including operator-exempt trees" {
  _plant "lib/probe.md"
  for d in $EXEMPT_DIRS; do _plant "$d/probe.md"; done
  run _scan
  [ "$status" -eq 0 ]
  local findings="$output"
  for r in $CRED_RULES; do
    _assert_hit "$findings" "lib/probe.md" "$r"
    for d in $EXEMPT_DIRS; do
      _assert_hit "$findings" "$d/probe.md" "$r"
    done
  done
}

@test "every operator-identity rule fires on non-exempt code (lib/)" {
  _plant "lib/probe.md"
  run _scan
  [ "$status" -eq 0 ]
  for r in $IDENTITY_RULES operator-personal-email; do
    _assert_hit "$output" "lib/probe.md" "$r"
  done
}

@test "operator-home-path survives the gitleaks >=8.25 default global allowlist" {
  # Regression for the CI-only kill: the default config allowlists any secret
  # matching ^/(bin|etc|home|opt|tmp|usr|var)/[\w ./-]+$, so a rule whose whole
  # reported secret is a bare absolute path is silently dropped. Includes the
  # hardest shape: the path alone at column 0.
  mkdir -p "$FIXROOT/lib"
  printf '/home/rob/nwp/scripts/thing.sh\n' > "$FIXROOT/lib/bare.md"
  run _scan
  [ "$status" -eq 0 ]
  _assert_hit "$output" "lib/bare.md" "operator-home-path"
}

@test "operator-personal-email is enforced everywhere — no path exemptions" {
  # PII. Historical files carrying it are pinned by fingerprint in
  # .gitleaksignore with a rationale, never by widening a path exemption.
  for d in $EXEMPT_DIRS; do _plant "$d/probe.md"; done
  run _scan
  [ "$status" -eq 0 ]
  for d in $EXEMPT_DIRS; do
    _assert_hit "$output" "$d/probe.md" "operator-personal-email"
  done
}

@test "operator-identity rules stay exempt in the declared operator-bound trees" {
  # The exemptions still exist — they were moved onto the identity rules, not
  # deleted. If a future edit drops them, this goes red and the decision is
  # explicit rather than accidental.
  for d in $EXEMPT_DIRS; do _plant "$d/probe.md"; done
  run _scan
  [ "$status" -eq 0 ]
  for r in $IDENTITY_RULES; do
    for d in $EXEMPT_DIRS; do
      _assert_no_hit "$output" "$d/probe.md" "$r"
    done
  done
}

@test "ops#131 test-links.md exemption suppresses domains but NOT credentials" {
  mkdir -p "$FIXROOT/docs/guides"
  local pat="glpat-"
  cat > "$FIXROOT/docs/guides/test-links.md" <<EOF
- https://nwd.nwpcode.org/user/login
- https://ssc.nwpcode.org/
token = "${pat}ABCDEFGHIJKLMNOPQRST"
EOF
  run _scan
  [ "$status" -eq 0 ]
  _assert_no_hit "$output" "docs/guides/test-links.md" "live-internal-domain"
  _assert_hit    "$output" "docs/guides/test-links.md" "gitlab-pat"
}

@test "Decision-14 allowlist passes public GitLab URLs but not bare subdomains" {
  mkdir -p "$FIXROOT/lib"
  printf 'see https://git.nwpcode.org/nwp/ops/-/issues/131\n' > "$FIXROOT/lib/d14a.md"
  printf 'host: avc.nwpcode.org\n'                            > "$FIXROOT/lib/d14b.md"
  run _scan
  [ "$status" -eq 0 ]
  _assert_no_hit "$output" "lib/d14a.md" "live-internal-domain"
  _assert_hit    "$output" "lib/d14b.md" "live-internal-domain"
}

@test "the top-level [allowlist] declares no path exemptions" {
  # Structural backstop for case 1: a top-level path exemption disables the
  # inherited credential ruleset for that path. Exemptions belong on the
  # operator-identity rules.
  run python3 - "${REPO_ROOT}/.gitleaks.toml" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# Grab the top-level [allowlist] / [[allowlists]] section(s) only: everything
# from the header to the next top-level [ ... ] table that is not part of it.
bad = []
for m in re.finditer(r'^\[\[?allowlists?\]\]?\s*$', src, re.M):
    start = m.end()
    nxt = re.search(r'^\[', src[start:], re.M)
    body = src[start:start + (nxt.start() if nxt else len(src))]
    body = "\n".join(l for l in body.splitlines() if not l.lstrip().startswith('#'))
    if re.search(r'^\s*paths\s*=', body, re.M):
        bad.append(body.strip()[:200])
if bad:
    print("top-level allowlist still carries path exemptions:")
    for b in bad: print(b)
    sys.exit(1)
print("ok")
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "SHARED-EXEMPTIONS blocks are byte-identical across the identity rules" {
  # The exemption list is duplicated per rule because gitleaks TOML has no
  # includes and `targetRules` is silently ignored below gitleaks 8.25 (which
  # would make the config mean different things on different runners). This
  # test is what makes the duplication safe.
  run python3 - "${REPO_ROOT}/.gitleaks.toml" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
blocks = re.findall(
    r'# --- SHARED-EXEMPTIONS BEGIN ---\n(.*?)# --- SHARED-EXEMPTIONS END ---',
    src, re.S)
if len(blocks) < 2:
    print("expected >=2 SHARED-EXEMPTIONS blocks, found %d" % len(blocks)); sys.exit(1)
if len(set(blocks)) != 1:
    print("SHARED-EXEMPTIONS blocks have drifted apart (%d distinct of %d)"
          % (len(set(blocks)), len(blocks)))
    sys.exit(1)
print("ok: %d identical blocks" % len(blocks))
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "doc-leaked-bearer-token fires on a high-entropy inline-code token next to leak-shaped prose (ops#182)" {
  # The real incident: a 23-char prefix of a live bearer token printed in a
  # doc as an inline code span, in prose saying "the live value is ...".
  # Synthetic stand-in only — high entropy (4.50 bits), never a real value.
  # Safe as a literal here: the rule is path-scoped to prose/doc files, so it
  # never scans .bats sources.
  mkdir -p "$FIXROOT/lib"
  {
    printf 'The gateway expects a bearer credential in the auth header.\n'
    printf 'the live value is `ydS23kQ9mZx7Wr4LpJ8Tn2Vb` — rotate it quarterly.\n'
  } > "$FIXROOT/lib/leaky-doc.md"
  run _scan
  [ "$status" -eq 0 ]
  _assert_hit "$output" "lib/leaky-doc.md" "doc-leaked-bearer-token"
}

@test "doc-leaked-bearer-token stays quiet on ordinary code spans" {
  # Three shapes that must NOT fire: two low-entropy identifiers adjacent to
  # the word "token" (measured 3.20 / 3.64 bits, under the 4.0 floor), and a
  # high-entropy span with no leak-announcing prose near it.
  mkdir -p "$FIXROOT/lib"
  {
    printf 'rotate the token with `pl_secrets_rotate_all` when it expires.\n'
    printf 'the token is `composer_registry_token` in .secrets.yml.\n'
    printf 'checksum `ydS23kQ9mZx7Wr4LpJ8Tn2Vb` for the tarball.\n'
  } > "$FIXROOT/lib/ordinary-doc.md"
  run _scan
  [ "$status" -eq 0 ]
  _assert_no_hit "$output" "lib/ordinary-doc.md" "doc-leaked-bearer-token"
}

@test "operator-public-ip covers the sites1 live box IP from the 2026-07-31 split" {
  # 45.33.76.180 read off DNS (sites1/nwc/ssc.nwpcode.org) 2026-08-02.
  # Safe as a literal here: tests/ is in SHARED-EXEMPTIONS for identity rules.
  mkdir -p "$FIXROOT/lib"
  printf 'host: 45.33.76.180\n' > "$FIXROOT/lib/new-box-ip.md"
  run _scan
  [ "$status" -eq 0 ]
  _assert_hit "$output" "lib/new-box-ip.md" "operator-public-ip"
}

@test "the repo config parses cleanly on the resolved gitleaks" {
  mkdir -p "$FIXROOT/lib"
  printf 'nothing to see here\n' > "$FIXROOT/lib/clean.md"
  run bash -c "cd '$FIXROOT' && '$GITLEAKS_BIN' detect --no-git --source . --config .gitleaks.toml --no-banner 2>&1"
  [ "$status" -eq 0 ]
  ! grep -qiE 'failed to load|error' <<<"$output"
}
