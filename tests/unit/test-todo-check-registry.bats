#!/usr/bin/env bats
# ops#204 — `pl todo`'s check registry must agree with itself.
#
# THE BUG. `check_rag_sync_freshness` was DEFINED twice in lib/todo-checks.sh and
# LISTED twice in TODO_CHECK_LIST. Bash binds the last definition, so one body
# was dead code from the day it was shadowed; and the duplicated list entry made
# one check run twice per sweep. Nothing reported either fact: `pl todo` printed
# a complete-looking sweep and `pl rag` consumed it. The estate's only oversight
# surface was grading itself against a registry it had never read.
#
# The dedupe fixed that instance. `todo_check_registry_defects` is the part that
# makes the CLASS impossible to reintroduce silently — the list is 28 lines of
# near-identical text sitting 2,000 lines away from the definitions.
#
# Per ops#214 ("a check that has never been proven to fail is not a check")
# every invariant below is proven BOTH ways: the mutation that breaks it is
# applied to a real copy of the library and the guard must go RED, and a
# harmless edit of the same line must stay GREEN. Without the green-proof this
# file would be satisfied by a guard that simply always fails.
#
# MEASUREMENT NOTE, recorded because it nearly fooled the author: an earlier
# manual harness read `${PIPESTATUS[0]}` after `out=$(cmd | grep ...)`. That is
# the status of the ASSIGNMENT, i.e. grep's, so three genuinely-red mutations
# read as exit 0. bats' `run`/`$status` is used here for exactly that reason.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LIB="$ROOT/lib/todo-checks.sh"
  TMP="$BATS_TEST_TMPDIR/reg"
  mkdir -p "$TMP"
  cp "$LIB" "$TMP/todo-checks.sh"
}

# Run todo_check_registry_defects against a (possibly mutated) COPY of the lib.
# The copy is both sourced and passed as the file to text-scan, so the runtime
# array and the file text are the same artifact — a mutation cannot be seen by
# one half and missed by the other.
_defects() {
  bash -c '
    set -u
    . "'"$TMP"'/todo-checks.sh" >/dev/null 2>&1
    todo_check_registry_defects "'"$TMP"'/todo-checks.sh"
  '
}

################################################################################
# BASELINE — the shipped registry is clean. If this ever fails, the estate has
# the ops#204 bug back and every count `pl todo` prints is suspect.
################################################################################

@test "baseline: the shipped TODO_CHECK_LIST has no defects" {
  run _defects
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "baseline: list, definitions and the three-way set all agree" {
  # Stated as numbers so a future reader can see the invariant, not just trust it.
  listed=$(grep -cE '^\s+"check_[a-z0-9_]+:' "$LIB")
  defined=$(grep -cE '^check_[a-z0-9_]+\(\) \{' "$LIB")
  [ "$listed" -eq "$defined" ]
  run bash -c "diff <(grep -oE '^[[:space:]]+\"check_[a-z0-9_]+:' '$LIB' | tr -d ' \"' | sed 's/:\$//' | sort) \
                    <(grep -oE '^check_[a-z0-9_]+\(\) \{' '$LIB' | sed 's/() {\$//' | sort)"
  [ "$status" -eq 0 ]
}

################################################################################
# INVARIANT 1 — no function name appears twice in TODO_CHECK_LIST.
# This is the literal ops#204 defect: one check ran twice per sweep.
################################################################################

@test "RED: a duplicated TODO_CHECK_LIST entry is reported" {
  sed -i 's|"check_disk_usage:Disk usage"|"check_disk_usage:Disk usage"\n    "check_disk_usage:Disk usage"|' \
    "$TMP/todo-checks.sh"
  run _defects
  [ "$status" -ne 0 ]
  [[ "$output" == *"'check_disk_usage' appears 2 times in TODO_CHECK_LIST"* ]]
}

################################################################################
# INVARIANT 2 — every listed name resolves to exactly ONE definition.
#
# Two halves, and BOTH are needed:
#   a) runtime (`declare -F`) catches a renamed/typo'd entry — an entry that
#      quietly does nothing.
#   b) file text catches SHADOWING, which `declare -F` cannot possibly see:
#      by the time the library is sourced bash has already discarded the loser.
#      This is the half that would have caught ops#204 itself.
################################################################################

@test "RED: a listed check with no definition is reported (typo'd entry)" {
  sed -i 's|"check_disk_usage:Disk usage"|"check_dsk_usage:Disk usage"|' "$TMP/todo-checks.sh"
  run _defects
  [ "$status" -ne 0 ]
  [[ "$output" == *"names 'check_dsk_usage' but no such function is defined"* ]]
}

@test "RED: a SHADOWED second definition is reported (the actual ops#204 shape)" {
  printf '\ncheck_disk_usage() {\n    :\n}\n' >> "$TMP/todo-checks.sh"
  run _defects
  [ "$status" -ne 0 ]
  [[ "$output" == *"'check_disk_usage' is defined 2 times"* ]]
  # And prove the runtime half alone would NOT have caught it: declare -F
  # reports exactly one function either way, which is why the text pass exists.
  run bash -c ". '$TMP/todo-checks.sh' >/dev/null 2>&1; declare -F check_disk_usage | wc -l"
  [ "$output" = "1" ]
}

################################################################################
# INVARIANT 3 — every defined check is listed. An unlisted check is code that
# can never run; the sweep is smaller than it looks and says nothing.
################################################################################

@test "RED: a defined-but-unlisted check is reported" {
  sed -i '/"check_disk_usage:Disk usage"/d' "$TMP/todo-checks.sh"
  run _defects
  [ "$status" -ne 0 ]
  [[ "$output" == *"'check_disk_usage' is defined but absent from TODO_CHECK_LIST"* ]]
}

################################################################################
# GREEN-PROOF — the guard discriminates. Without this, every RED case above is
# equally satisfied by a guard that always fails.
################################################################################

@test "GREEN: relabelling a check (same function, new display name) stays clean" {
  sed -i 's|"check_disk_usage:Disk usage"|"check_disk_usage:Disk usage and headroom"|' "$TMP/todo-checks.sh"
  run _defects
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "GREEN: adding a properly-registered check stays clean" {
  # The whole point of the registry: adding a check the RIGHT way must not trip
  # the guard, or the guard becomes something people work around.
  printf '\ncheck_fixture_probe() {\n    :\n}\n' >> "$TMP/todo-checks.sh"
  sed -i 's|    "check_disk_usage:Disk usage"|    "check_disk_usage:Disk usage"\n    "check_fixture_probe:Fixture probe"|' \
    "$TMP/todo-checks.sh"
  run _defects
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

################################################################################
# THE VERB — `pl todo registry`. A library function nobody can invoke is not an
# operator-usable check (STANDING ORDER: everything goes through `pl`).
################################################################################

@test "pl todo registry reports the shipped registry consistent and exits 0" {
  run "$ROOT/pl" todo registry
  [ "$status" -eq 0 ]
  [[ "$output" == *"check registry consistent"* ]]
}

@test "the sweep files a REG item when the registry is broken" {
  # run_all_checks must SURFACE the defect, not just have a function that could
  # find it — 'nothing reports this' was the substance of ops#204.
  sed -i 's|"check_disk_usage:Disk usage"|"check_disk_usage:Disk usage"\n    "check_disk_usage:Disk usage"|' \
    "$TMP/todo-checks.sh"
  run bash -c '
    set -u
    . "'"$TMP"'/todo-checks.sh" >/dev/null 2>&1
    todo_clear_items
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      todo_add_item "REG" "" "high" "pl todo check registry is inconsistent" "${d#defect: }" "" "pl todo registry"
    done < <(todo_check_registry_defects "'"$TMP"'/todo-checks.sh" || true)
    printf "%s\n" "${TODO_ITEMS[@]:-}"
  '
  [[ "$output" == *'"category":"REG"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"appears 2 times in TODO_CHECK_LIST"* ]]
}
