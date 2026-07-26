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

@test "pubrel: tracked-tree gitleaks scan is clean with the committed ledger" {
  if ! command -v gitleaks >/dev/null 2>&1; then
    skip "gitleaks not installed"
  fi
  run pubrel_scan full
  [ "$status" -eq 0 ]
}

# Belt and braces: even if someone re-adds fingerprints for these files later,
# pruning them must not resurrect a finding.
@test "pubrel: scan stays clean even with in-scope suppressions stripped" {
  if ! command -v gitleaks >/dev/null 2>&1; then
    skip "gitleaks not installed"
  fi
  run pubrel_scan pruned
  [ "$status" -eq 0 ]
}
