#!/usr/bin/env bats
#
# B1 — public-release doc scrub.
#
# The 31 docs in tests/fixtures/pubrel-docs.txt are the public-release prose set
# that the stranded branch pubrel/scrub-and-gate genericised. That branch is
# 228 commits behind main and its .gitleaks.toml half is superseded by 92cf069,
# so its CONTENT was reproduced onto current main rather than its commits merged.
#
# The load-bearing assertion is not the grep: it is that the 75 `docs/…`
# fingerprints those files needed in .gitleaksignore are GONE and the gate still
# passes. That is what distinguishes a real scrub from a cosmetic one.

# Resolve the scanner ONCE, exactly as tests/unit/test-leakage-gate.bats does,
# and FAIL the file if we cannot. Deliberately not a `skip`: bats reports a skip
# as `ok`, and CI runs this suite with NWP_BATS_MAX_SKIPPED=0 precisely because
# "we could not check" must never read as "checked and clean". That is the same
# defect, one layer up, as the one this file's fail-closed cases pin.
GITLEAKS_PINNED_VERSION="8.30.0"
GITLEAKS_PINNED_SHA256="79a3ab579b53f71efd634f3aaf7e04a0fa0cf206b7ed434638d1547a2470a66e"

_pubrel_resolve_gitleaks() {
  if [ -n "${NWP_GITLEAKS_BIN:-}" ] && [ -x "${NWP_GITLEAKS_BIN}" ]; then
    printf '%s\n' "$NWP_GITLEAKS_BIN"; return 0
  fi
  if command -v gitleaks >/dev/null 2>&1; then command -v gitleaks; return 0; fi
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

setup_file() {
  GITLEAKS_BIN="$(_pubrel_resolve_gitleaks)" || {
    echo "CANNOT VERIFY the public-release scrub: no usable gitleaks binary." >&2
    echo "Set NWP_GITLEAKS_BIN=/path/to/gitleaks, install gitleaks, or allow" >&2
    echo "the pinned download (needs network). Refusing to report the scrub" >&2
    echo "clean on the strength of a scan that never ran." >&2
    return 1
  }
  export GITLEAKS_BIN
}

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/tests/helpers/pubrel-docs-check.sh"
  cd "$REPO_ROOT" || return 1
}

@test "pubrel: the in-scope doc list is present and non-empty" {
  run bash -c 'source tests/helpers/pubrel-docs-check.sh; pubrel_file_list | wc -l'
  [ "$status" -eq 0 ]
  [ "$output" -ge 30 ]
}

@test "pubrel: no in-scope doc carries an operator identifier" {
  run bash -c 'source tests/helpers/pubrel-docs-check.sh; pubrel_offending_files'
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "Files still carrying an operator identifier:"
    echo "$output"
    bash -c 'source tests/helpers/pubrel-docs-check.sh; pubrel_offending_lines'
  fi
  [ -z "$output" ]
}

# NEGATIVE CONTROL 1 — "scrub by deletion" must not pass.
# Emptying or removing the docs would satisfy the grep above trivially. Require
# every in-scope file to still exist with real content.
@test "pubrel: NEGATIVE CONTROL — every in-scope doc still exists with real content" {
  local missing=0 tiny=0 f
  while read -r f; do
    [ -n "$f" ] || continue
    if [ ! -f "$f" ]; then
      echo "MISSING: $f"; missing=$((missing+1)); continue
    fi
    # 400 bytes is well below any of these docs but well above "emptied".
    local sz
    sz=$(wc -c < "$f")
    if [ "$sz" -lt 400 ]; then
      echo "SUSPICIOUSLY SMALL ($sz bytes): $f"; tiny=$((tiny+1))
    fi
  done < <(pubrel_file_list)
  [ "$missing" -eq 0 ]
  [ "$tiny" -eq 0 ]
}

# NEGATIVE CONTROL 2 — the detector must actually detect.
# A checker that matches nothing would make every other test vacuously green.
@test "pubrel: NEGATIVE CONTROL — the checker flags a planted operator identifier" {
  local tmp
  tmp="$(mktemp -d)"
  printf 'Visit nwc.nwpcode.org for details.\n' > "${tmp}/planted.md"
  run grep -cE "$PUBREL_DOMAIN_RE" "${tmp}/planted.md"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

# NEGATIVE CONTROL 3 — the allowlist mask must be narrow.
# The mask exempts public forge issue/MR/blob/tree URLs. If it were written too
# loosely it would hide ordinary leaks and make the suite vacuous.
@test "pubrel: NEGATIVE CONTROL — allowlist mask does not hide ordinary leaks" {
  local tmp
  tmp="$(mktemp -d)"
  # Allowlisted: a real forge issue link. Must be masked.
  printf 'see https://git.nwpcode.org/nwp/ops/-/issues/61 ok\n' > "${tmp}/allow.md"
  # NOT allowlisted: same host, no /-/issues/ path. Must still be caught.
  printf 'ssh into git.nwpcode.org now\n' > "${tmp}/leak.md"

  run bash -c "sed '$PUBREL_ALLOWLIST_SED' '${tmp}/allow.md' | grep -cE '$PUBREL_DOMAIN_RE'"
  [ "$output" -eq 0 ]

  run bash -c "sed '$PUBREL_ALLOWLIST_SED' '${tmp}/leak.md' | grep -cE '$PUBREL_DOMAIN_RE'"
  rm -rf "$tmp"
  [ "$output" -eq 1 ]
}

# The load-bearing half: the suppressions are really gone.
@test "pubrel: .gitleaksignore no longer suppresses any in-scope doc" {
  local f leftover=0
  while read -r f; do
    [ -n "$f" ] || continue
    if grep -q "^${f}:" .gitleaksignore; then
      echo "STILL SUPPRESSED: $f"
      leftover=$((leftover+1))
    fi
  done < <(pubrel_file_list)
  [ "$leftover" -eq 0 ]
}

# POSITIVE / NEGATIVE CONTROL for the backstop itself: a real tree with a
# working scanner must still pass. The fail-closed hardening below must not
# degenerate into "fail always".
@test "pubrel: tracked-tree gitleaks scan is clean with the committed ledger" {
  run pubrel_scan full
  echo "$output"
  [ "$status" -eq 0 ]
}

# Belt and braces: even if someone re-adds fingerprints for these files later,
# pruning them must not resurrect a finding.
@test "pubrel: scan stays clean even with in-scope suppressions stripped" {
  run pubrel_scan pruned
  echo "$output"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FAIL-CLOSED CONTRACT (2026-07-27).
#
# pubrel_scan used to discard gitleaks' exit status and decode a missing or
# unparseable report as "0 findings = clean". With one malformed rule appended
# to .gitleaks.toml — a file another workstream edits — the entire suite went
# 8/8 GREEN while a real /home/rob/… operator-home-path leak sat in
# docs/governance/roles.md. These cases pin the repair.
#
# Contract: 0 = clean, 1 = findings, 2 = COULD NOT SCAN. Only 0 means clean.
# ---------------------------------------------------------------------------

# Install a fake `gitleaks` on PATH. $1 = exit code, $2 = report body ("" = none).
pubrel_stub_gitleaks() {
  PUBREL_STUB_DIR="$(mktemp -d)"
  {
    echo '#!/usr/bin/env bash'
    echo 'report=""'
    echo 'while [ $# -gt 0 ]; do'
    echo '  case "$1" in --report-path) report="$2"; shift 2 ;; *) shift ;; esac'
    echo 'done'
    if [ -n "${2-}" ]; then
      printf '[ -n "$report" ] && printf %%s %s > "$report"\n' "'$2'"
    else
      echo '[ -n "$report" ] && : > "$report"'
    fi
    echo "exit $1"
  } > "${PUBREL_STUB_DIR}/gitleaks"
  chmod +x "${PUBREL_STUB_DIR}/gitleaks"
  PATH="${PUBREL_STUB_DIR}:${PATH}"
  # setup_file exported a real GITLEAKS_BIN; the stub must win over it.
  GITLEAKS_BIN="${PUBREL_STUB_DIR}/gitleaks"
  NWP_GITLEAKS_BIN="${PUBREL_STUB_DIR}/gitleaks"
}

@test "pubrel: FAIL-CLOSED — a scanner that ERRORS is not a clean scrub" {
  pubrel_stub_gitleaks 2 ""
  run pubrel_scan full
  rm -rf "$PUBREL_STUB_DIR"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to report clean"* ]]
}

@test "pubrel: FAIL-CLOSED — a missing report is not a clean scrub" {
  # rc=0 (scanner claims success) but writes nothing. The old code read this
  # as zero findings.
  pubrel_stub_gitleaks 0 ""
  run pubrel_scan pruned
  rm -rf "$PUBREL_STUB_DIR"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no report"* ]]
}

@test "pubrel: FAIL-CLOSED — an unparseable report is not a clean scrub" {
  pubrel_stub_gitleaks 0 'not json at all'
  run pubrel_scan full
  rm -rf "$PUBREL_STUB_DIR"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to report clean"* ]]
}

@test "pubrel: FAIL-CLOSED — rc/report disagreement is not a clean scrub" {
  # rc=0 but the report carries a finding: we do not know which to believe.
  pubrel_stub_gitleaks 0 '[{"File":"docs/x.md","StartLine":1,"RuleID":"operator-home-path"}]'
  run pubrel_scan full
  rm -rf "$PUBREL_STUB_DIR"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"disagrees"* ]]
}

@test "pubrel: findings are reported as findings (rc 1), not as an error" {
  pubrel_stub_gitleaks 1 '[{"File":"docs/x.md","StartLine":1,"RuleID":"operator-home-path"}]'
  run pubrel_scan full
  rm -rf "$PUBREL_STUB_DIR"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"operator-home-path"* ]]
}

@test "pubrel: FAIL-CLOSED — an absent scanner is an error, and python3 is guarded too" {
  # Both tools are guarded the same way. Absence is visible (the suite skips);
  # it must never be silently clean.
  run env -u GITLEAKS_BIN -u NWP_GITLEAKS_BIN PATH=/nonexistent /bin/bash -c \
    "source '${REPO_ROOT}/tests/helpers/pubrel-docs-check.sh'; pubrel_scan_missing_tool"
  [ "$output" = "gitleaks" ]

  local only_gl
  only_gl="$(mktemp -d)"
  printf '#!/bin/sh\nexit 0\n' > "${only_gl}/gitleaks"
  chmod +x "${only_gl}/gitleaks"
  run env -u GITLEAKS_BIN -u NWP_GITLEAKS_BIN PATH="$only_gl" /bin/bash -c \
    "source '${REPO_ROOT}/tests/helpers/pubrel-docs-check.sh'; pubrel_scan_missing_tool"
  rm -rf "$only_gl"
  [ "$output" = "python3" ]
}

# NEGATIVE CONTROL — the widened identity regex must cover all six gate rules,
# including the two (operator-home-path, operator-organisation) that were
# previously left to the backstop alone.
@test "pubrel: NEGATIVE CONTROL — the checker covers all six identity rules" {
  # NB: the planted identifiers are assembled at runtime. Spelling them out
  # literally here would make THIS FILE a leak — operator-personal-email and
  # operator-public-ip have no `^tests/.*` path allowlist (the email one has no
  # path allowlist at all, by design: it is PII). Verified: an earlier draft
  # with a literal `rjzaar@…` turned tests 7 and 8 red, correctly.
  local tmp; tmp="$(mktemp -d)"
  local user=rob org=Mazen local_part=rjzaar octet=133
  printf 'run /home/%s/nwp/lib/common.sh\n' "$user" > "${tmp}/home.md"
  printf 'a %sod College project\n' "$org"          > "${tmp}/org.md"
  printf 'ssh 45.33.94.%s\n' "$octet"               > "${tmp}/ip2.md"
  printf 'mail %s@example.org\n' "$local_part"      > "${tmp}/mail.md"
  printf 'see nwpcode.org\n'                        > "${tmp}/apex.md"
  printf 'see git.mayostudios.org\n'                > "${tmp}/sub.md"
  local f
  for f in home org ip2 mail apex sub; do
    run bash -c "sed '$PUBREL_ALLOWLIST_SED' '${tmp}/${f}.md' | grep -ciE '$PUBREL_IDENTITY_RE'"
    echo "pattern class ${f} -> ${output}"
    [ "$output" -eq 1 ]
  done
  # …and the documented service-account home is NOT an operator identifier.
  printf 'chown -R gitlab:gitlab /home/gitlab/.ssh\n' > "${tmp}/svc.md"
  run bash -c "sed '$PUBREL_ALLOWLIST_SED' '${tmp}/svc.md' | grep -ciE '$PUBREL_IDENTITY_RE'"
  rm -rf "$tmp"
  [ "$output" -eq 0 ]
}
