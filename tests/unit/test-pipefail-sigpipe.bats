#!/usr/bin/env bats
#
# test-pipefail-sigpipe.bats — the red proof for lint:pipefail-sigpipe (ops#351).
#
# TWO THINGS HAVE TO BE PROVEN HERE, and only one of them is about the lint.
#
#   1. THE MECHANISM IS REAL. Case group 0 runs the flagged idiom for real and
#      asserts it returns 141 on a corpus past the pipe buffer. A lint policing
#      a race nobody has watched happen is folklore; this is the estate rule
#      ("a check that has never been proven to fail is not a check") applied to
#      the premise rather than to the tool.
#
#   2. THE LINT DISCRIMINATES. The whole value of this gate is telling a
#      CONSUMED site from a BENIGN one — ~250 sites of this idiom exist and a
#      tool that called them all bugs would license exactly the mass rewrite
#      ops#351 says not to do. So there are as many cases here asserting
#      "reports NOTHING" as asserting "reports a finding".
#
# Every case drives the REAL script against a SYNTHETIC tree, so the result does
# not drift with whatever main happens to contain — except the two cases that
# deliberately scan the real tree, which is how we know the lint fires on
# production code and not only on fixtures.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LINT="$PROJECT_ROOT/scripts/ci/lint-pipefail-sigpipe.sh"
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/lib" "$FIX/scripts"
  BASE="$FIX/.baseline"
  : > "$BASE"
}

# Run the lint over the fixture tree only.
#
# ROOTS ARE PASSED ABSOLUTE, on purpose. The lint `cd`s to PROJECT_ROOT before
# scanning, so a relative root like `scripts` resolves against the REAL repo —
# the first draft of this file did exactly that, and ten "reports nothing" cases
# went red because they were quietly measuring main instead of the fixture.
# A fixture that is not the thing under test is worse than no fixture.
_lint() {
  local args=() a
  for a in "$@"; do
    case "$a" in
      -*) args+=("$a") ;;
      /*) args+=("$a") ;;
      *)  args+=("$FIX/$a") ;;
    esac
  done
  run env NWP_PIPEFAIL_SIGPIPE_BASELINE="$BASE" \
      bash "$LINT" --baseline="$BASE" "${args[@]}"
}

_write() {   # _write <relpath> <line>...
  local f="$FIX/$1"; shift
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$@" > "$f"
}

################################################################################
# 0. THE MECHANISM — prove the race before policing it
################################################################################

@test "MECHANISM: the flagged idiom really returns 141 on a corpus past the pipe buffer" {
  local corpus="$BATS_TEST_TMPDIR/big.tsv"
  # ~1.9 MB: far past the 64 KiB pipe buffer, so `cut` still has bytes to write
  # when `grep -q` leaves on the first match.
  seq 1 40000 | awk '{printf "row%s\tfiller-column-to-make-lines-wide-%s\n", $1, $1}' > "$corpus"

  local wrong=0 st
  for _ in $(seq 1 50); do
    st=0
    ( set -o pipefail; cut -f1 "$corpus" | grep -qxF "row3" ) || st=$?
    [ "$st" -ne 0 ] && wrong=$((wrong + 1))
  done
  # row3 IS in the corpus. Every non-zero answer is the race, not a miss.
  [ "$wrong" -gt 0 ]
  echo "racy idiom misreported $wrong / 50 times" >&2
}

@test "MECHANISM: process substitution — the prescribed fix — never misreports" {
  local corpus="$BATS_TEST_TMPDIR/big.tsv"
  seq 1 40000 | awk '{printf "row%s\tfiller-column-to-make-lines-wide-%s\n", $1, $1}' > "$corpus"

  local wrong=0 st
  for _ in $(seq 1 50); do
    st=0
    ( set -o pipefail; grep -qxF "row3" < <(cut -f1 "$corpus") ) || st=$?
    [ "$st" -ne 0 ] && wrong=$((wrong + 1))
  done
  [ "$wrong" -eq 0 ]
}

################################################################################
# 1. IT GOES RED on the thing it exists to catch
################################################################################

@test "a NEW consumed site with no baseline row FAILS" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'if cut -f1 data.tsv | grep -qxF "$1"; then echo yes; fi'
  _lint scripts
  [ "$status" -eq 1 ]
  [[ "$output" == *"NEW SIGPIPE-RACE SITE"* ]]
  [[ "$output" == *"COND"* ]]
}

@test "the last statement of a function is a TAIL finding — the ops#343 shape" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -uo pipefail' \
    'has_red_proof() {' \
    '    cut -f1 "$proofs_file" | grep -qxF "$1"' \
    '}'
  _lint --list scripts
  [ "$status" -eq 0 ]
  [[ "$output" == *"TAIL"* ]]
  [[ "$output" == *"has_red_proof"* ]]
}

@test "a plain assignment capture under set -e is an ERREXIT finding" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'ver=$(git tag --list | head -1)'
  _lint --list scripts
  [[ "$output" == *"ERREXIT"* ]]
  [[ "$output" == *"a.sh:3"* ]]
}

@test "a && consequent after the reader is consumption" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -uo pipefail' \
    'printf "%s" "$rows" | grep -q INSECURE && had_sec=1 || true'
  _lint --list scripts
  [[ "$output" == *"COND"* ]]
}

@test "PIPEFAIL IS INHERITED: a lib with no set line, sourced by a pipefail script, is in scope" {
  _write scripts/main.sh \
    '#!/bin/bash' 'set -euo pipefail' 'source "$DIR/lib/helper.sh"'
  _write lib/helper.sh \
    'helper() {' \
    '    if find . -name "*.x" | grep -q .; then return 0; fi' \
    '}'
  _lint --list scripts lib
  [[ "$output" == *"lib/helper.sh"* ]]
}

################################################################################
# 2. IT DISCRIMINATES — the half that stops a mass rewrite
################################################################################

@test "a bare statement whose status nobody reads is NOT a finding" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -uo pipefail' \
    'printf "%s\n" "$plan" | grep -E "^POINT " | head -20'
  _lint --list scripts
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOTAL 0 consumed site(s)"* ]]
}

@test "local x=\$(… | head -1) is NOT a finding — local returns its own status" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'f() { local ver; local ver=$(git tag --list | head -1); }'
  _lint --list scripts
  [[ "$output" == *"TOTAL 0 consumed site(s)"* ]]
}

@test "a substitution that is not the whole RHS is NOT a finding" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'printf "value: %s\n" "$(git tag --list | head -1)"'
  _lint --list scripts
  [[ "$output" == *"TOTAL 0 consumed site(s)"* ]]
}

@test "a trailing || true neutralises the verdict and is NOT a finding" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'raw="$(tr -dc A-Z < /dev/urandom | head -c 20)" || true'
  _lint --list scripts
  [[ "$output" == *"TOTAL 0 consumed site(s)"* ]]
}

@test "NO PIPEFAIL, NO FINDING: the same racy text without pipefail is out of scope" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -eu' \
    'if cut -f1 data.tsv | grep -qxF "$1"; then echo yes; fi'
  _lint --list scripts
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOTAL 0 consumed site(s)"* ]]
}

@test "a reader that drains its input (grep -c, wc, tail) is NOT flagged" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'if cut -f1 data.tsv | grep -c foo; then echo yes; fi' \
    'if cut -f1 data.tsv | wc -l; then echo yes; fi' \
    'if cut -f1 data.tsv | tail -1; then echo yes; fi'
  _lint --list scripts
  [[ "$output" == *"TOTAL 0 consumed site(s)"* ]]
}

@test "a heredoc body that contains the idiom is NOT code and is NOT flagged" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'cat <<EOF' \
    'if cut -f1 data.tsv | grep -qxF x; then echo yes; fi' \
    'EOF'
  _lint --list scripts
  [[ "$output" == *"TOTAL 0 consumed site(s)"* ]]
}

################################################################################
# 3. POLARITY — which way a lost match pushes
################################################################################

@test "if ! … | grep -q  is NEGATED (false red only)" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -uo pipefail' \
    'if ! printf "%s\n" "$enum" | grep -qxF "$v"; then die; fi'
  _lint --list scripts
  [[ "$output" == *"NEGATED"* ]]
}

@test "a ! inside a bracket test does NOT make the pipeline negated" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -uo pipefail' \
    'if [[ ! -f "$x" ]] && printf "%s" "$t" | grep -qiF -- "$forbid"; then die; fi'
  _lint --list scripts
  [[ "$output" == *"POSITIVE"* ]]
  [[ "$output" != *"NEGATED"* ]]
}

@test "a pipeline at the END of an || chain is POSITIVE, not NEGATED" {
  # `[ -f a ] || [ -f b ] || find … | grep -q .` — the pipeline is the LAST
  # operand, so a lost match SKIPS the body. An earlier draft read the leading
  # `||` and called this NEGATED, which is the wrong direction entirely: it
  # would have ranked a fail-open site as harmless noise.
  _write scripts/a.sh \
    '#!/bin/bash' 'set -uo pipefail' \
    'if [ -f a ] || [ -f b ] || find . -name "x*" | grep -q .; then have=1; fi'
  _lint --list scripts
  [[ "$output" == *"POSITIVE"* ]]
}

@test "--rank puts the fail-open (POSITIVE) sites in RANK 1" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -uo pipefail' \
    'if grep -R secret . | grep -q AKIA; then refuse; fi' \
    'if ! grep -R marker . | grep -q OK; then warn; fi'
  _lint --rank scripts
  [[ "$output" == *"RANK 1"* ]]
  [[ "$output" == *"Can FAIL OPEN"* ]]
  [[ "$output" == *"1 POSITIVE"* ]]
  [[ "$output" == *"1 NEGATED"* ]]
}

################################################################################
# 4. THE BASELINE IS SHRINK-ONLY
################################################################################

@test "a baselined site passes" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'if cut -f1 data.tsv | grep -qxF "$1"; then echo yes; fi'
  _lint --update-baseline scripts
  [ "$status" -eq 0 ]
  _lint scripts
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK —"* ]]
}

@test "a STALE baseline row FAILS — fixing a site must delete its row" {
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'if cut -f1 data.tsv | grep -qxF "$1"; then echo yes; fi'
  _lint --update-baseline scripts
  # apply the prescribed fix; the row must now be stale
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'if grep -qxF "$1" < <(cut -f1 data.tsv); then echo yes; fi'
  _lint scripts
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE BASELINE ROW"* ]]
}

@test "the baseline does not bless a SECOND site in the same function" {
  # Key granularity matters: with a path::function key, fixing one of two sites
  # in a function would leave the other silently blessed.
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'f() {' \
    '  if cut -f1 a.tsv | grep -qxF "$1"; then echo one; fi' \
    '}'
  _lint --update-baseline scripts
  _write scripts/a.sh \
    '#!/bin/bash' 'set -euo pipefail' \
    'f() {' \
    '  if cut -f1 a.tsv | grep -qxF "$1"; then echo one; fi' \
    '  if cut -f1 b.tsv | grep -qxF "$2"; then echo two; fi' \
    '}'
  _lint scripts
  [ "$status" -eq 1 ]
  [[ "$output" == *"NEW SIGPIPE-RACE SITE"* ]]
  [[ "$output" == *"b.tsv"* ]]
}

################################################################################
# 5. FAIL CLOSED
################################################################################

@test "an unreadable root is CANNOT VERIFY (2), never a pass" {
  _lint "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "an empty corpus is CANNOT VERIFY (2), never a pass" {
  mkdir -p "$FIX/empty"
  _lint "$FIX/empty"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "an unknown option is a usage error (2), not a silent pass" {
  _lint --no-such-flag
  [ "$status" -eq 2 ]
}

################################################################################
# 6. IT FIRES ON THE REAL TREE — not only on fixtures
#
# A lint proven only against its own fixtures has never been shown to see
# production code. These two cases are the ones that would notice if a future
# refactor quietly stopped the scanner from resolving the real corpus.
################################################################################

@test "REAL TREE: the lint finds consumed sites in the shipped code" {
  run bash "$LINT" --list
  [ "$status" -eq 0 ]
  local n
  n=$(printf '%s\n' "$output" | sed -n 's/^TOTAL \([0-9]*\) consumed site(s).*/\1/p')
  [ -n "$n" ]
  [ "$n" -ge 100 ]
}

@test "REAL TREE: the lint also finds BENIGN sites — it is not just counting the idiom" {
  run bash "$LINT" --list-all
  [ "$status" -eq 0 ]
  local n
  n=$(printf '%s\n' "$output" | sed -n 's/.*CONSUMED, \([0-9]*\) BENIGN.*/\1/p')
  [ -n "$n" ]
  [ "$n" -ge 10 ]
}

@test "REAL TREE: the shipped baseline is exact — no new sites, no stale rows" {
  run bash "$LINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK —"* ]]
}

@test "REAL TREE: this lint does not contain the defect it polices" {
  run bash "$LINT" --list-all
  [ "$status" -eq 0 ]
  [[ "$output" != *"lint-pipefail-sigpipe.sh"* ]]
}
