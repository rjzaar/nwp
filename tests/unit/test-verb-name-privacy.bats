#!/usr/bin/env bats
#
# tests/unit/test-verb-name-privacy.bats — ops#326 Phase 1 tranche 3.
#
# THE DEFECT THIS GUARDS: a `pl` VERB or an engine LIBRARY whose FILENAME is a
# private site instance's name. `scripts/ci/lint-site-names.sh` already sees
# these (it scans tracked paths as well as content) but it is baseline-tolerant
# by design — the baseline holds the migration debt for ~400 doc and test rows.
# A verb name is different in kind: it is API surface, it is printed by
# `pl --help` and by `pl commands`, and it is the one class of reference a
# reader cannot avoid seeing. So this gate carries NO baseline: the engine's
# command and library namespace must be clean, always.
#
# OBSERVED RED before the tranche-3 retirement (real run, this tree):
#   not ok 1 no `pl` verb and no engine library is NAMED after a private site
#   # lib/<private-name>-moodle.sh  (private name in the filename)  [5 files]
#
# The deny-list is deliberately NOT in this repo (see the lint's header). This
# file resolves it exactly as the lint does — $NWP_SITE_NAME_DENYLIST (a path,
# as the CI file-type variable provides) else private/site-names.deny — and
# FAILS CLOSED when it cannot read one: "I could not read the policy" must
# never look like a pass (NWP-ADR-0037 direction, CLAUDE.md standing order).
#
# The third case sabotages the checker against a fixture so the gate is proven
# capable of failing even once the real tree is clean — a check that has never
# been seen red is a hypothesis, not a gate.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export REPO_ROOT
  TMP="${BATS_TEST_TMPDIR}"
}

# _deny_file — echo a readable deny-list path, or nothing.
_deny_file() {
  if [ -n "${NWP_SITE_NAME_DENYLIST:-}" ] && [ -r "${NWP_SITE_NAME_DENYLIST}" ]; then
    printf '%s' "${NWP_SITE_NAME_DENYLIST}"
  elif [ -r "${REPO_ROOT}/private/site-names.deny" ]; then
    printf '%s' "${REPO_ROOT}/private/site-names.deny"
  fi
}

# _scan <deny-file> <root> [path...] — print "<path>\t<token>" for every path
# whose BASENAME contains a denied name as a dot/dash-delimited token.
# Prints nothing and returns 2 when the deny-list yields no usable name.
_scan() {
  local deny="$1" root="$2"; shift 2
  local -a names=()
  local n
  while read -r n _; do
    case "$n" in ''|'#'*) continue ;; esac
    names+=("$n")
  done < "$deny"
  [ "${#names[@]}" -gt 0 ] || return 2

  local f b t
  for f in "$@"; do
    b="$(basename "$f")"
    for t in $(printf '%s' "$b" | tr '.-' '  '); do
      for n in "${names[@]}"; do
        [ "$t" = "$n" ] && printf '%s\t%s\n' "$f" "$t"
      done
    done
  done
  return 0
}

@test "no \`pl\` verb and no engine library is NAMED after a private site" {
  local deny; deny="$(_deny_file)"
  if [ -z "$deny" ]; then
    echo "CANNOT VERIFY: no readable deny-list (NWP_SITE_NAME_DENYLIST or private/site-names.deny)"
    false
  fi
  cd "$REPO_ROOT"
  local -a paths=()
  while IFS= read -r p; do paths+=("$p"); done < <(git ls-files 'scripts/commands/*.sh' 'lib/*.sh' 'lib/*/*.sh')
  [ "${#paths[@]}" -gt 0 ]   # an empty corpus is a blind pass, not a clean one

  run _scan "$deny" "$REPO_ROOT" "${paths[@]}"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "engine verb/library named after a private site:"
    echo "$output"
  fi
  [ -z "$output" ]
}

@test "the gate FAILS CLOSED when no deny-list is readable" {
  NWP_SITE_NAME_DENYLIST="${TMP}/absent.deny"
  local deny; deny="$(REPO_ROOT="${TMP}/no-such-root" _deny_file)"
  [ -z "$deny" ]
}

@test "an EMPTY deny-list is CANNOT VERIFY, not a pass" {
  : > "${TMP}/empty.deny"
  run _scan "${TMP}/empty.deny" "$REPO_ROOT" "lib/example.sh"
  [ "$status" -eq 2 ]
}

@test "the scan CAN fail — a planted verb name is flagged (sabotage)" {
  printf 'fxprivate\n' > "${TMP}/fixture.deny"
  run _scan "${TMP}/fixture.deny" "$TMP" \
    "scripts/commands/fxprivate-moodle-setup.sh" "lib/pair.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/commands/fxprivate-moodle-setup.sh"$'\t'"fxprivate"* ]]
  [[ "$output" != *"lib/pair.sh"* ]]
}

@test "a denied name EMBEDDED in a longer word is not a false positive" {
  printf 'fx\n' > "${TMP}/fixture.deny"
  run _scan "${TMP}/fixture.deny" "$TMP" "lib/fxture-helper.sh" "lib/fx-helper.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"fxture-helper"* ]]
  [[ "$output" == *"lib/fx-helper.sh"* ]]
}
