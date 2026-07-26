#!/usr/bin/env bats
# pl branch stranded — CONTENT classification must be a SET, not a scalar.
#
# WHY THIS FILE EXISTS: the classifier reported the DOMINANT class only. Two
# real branches (pubrel/scrub-and-gate, fix/moodle-deploy-snapshot-cli-script)
# were labelled "SHRINKS — DO NOT MERGE WHOLESALE", which was true, while ALSO
# carrying content main lacks (31 un-genericised docs; 35 lines of non-vacuous
# regression tests). An operator acting on the scalar label alone would delete
# real work. A branch can be both subtractive and additive at once and the
# report has to say so.
#
# Fixture: four branches off one base — pure-identical, pure-shrink,
# pure-unlanded, and mixed (deletes lines main has AND adds a file main lacks).

setup() {
  TEST_TMP=$(mktemp -d)
  ROOT="$TEST_TMP/nwp"
  REPO="${BATS_TEST_DIRNAME}/../.."

  mkdir -p "$ROOT/scripts/commands" "$ROOT/lib"
  cp "$REPO/scripts/commands/branch.sh" "$ROOT/scripts/commands/"
  cp "$REPO"/lib/{ui,common,impact,canonical,yaml-write,project-resolver,server-resolver,ssh,verify-autolog}.sh \
     "$ROOT/lib/" 2>/dev/null || true

  G() { git -C "$ROOT" -c user.email=t@t -c user.name=t "$@"; }

  # ---- base commit on main: keep.txt has 30 lines -------------------------
  seq 1 30 | sed 's/^/line /' > "$ROOT/keep.txt"
  G init -q -b main
  G add -A
  G commit -q -m base

  # ---- pure-identical: adds new.txt; main later gains the SAME content ----
  # (this is the "landed by re-application" shape: unmerged, but its files
  #  already match main byte for byte)
  G checkout -q -b pure/identical main
  echo "landed by re-application" > "$ROOT/new.txt"
  G add -A && G commit -q -m "add new.txt"

  # ---- pure-shrink: keeps 3 of 30 lines, adds 1 --------------------------
  G checkout -q -b pure/shrink main
  { head -3 "$ROOT/keep.txt"; echo "line 31"; } > "$ROOT/keep.tmp"
  mv "$ROOT/keep.tmp" "$ROOT/keep.txt"
  G add -A && G commit -q -m "gut keep.txt"

  # ---- pure-unlanded: adds a file main lacks -----------------------------
  G checkout -q -b pure/unlanded main
  seq 1 5 | sed 's/^/feature /' > "$ROOT/feature.txt"
  G add -A && G commit -q -m "add feature.txt"

  # ---- mixed: deletes 20 lines main has AND adds a file main lacks -------
  # Net direction is subtractive (5 added, 20 removed), so a scalar
  # "dominant class" reporter calls this SHRINKS and hides the added file.
  G checkout -q -b mixed/shrink-and-add main
  head -10 "$ROOT/keep.txt" > "$ROOT/keep.tmp"
  mv "$ROOT/keep.tmp" "$ROOT/keep.txt"
  seq 1 5 | sed 's/^/regression test /' > "$ROOT/tests.txt"
  G add -A && G commit -q -m "trim keep.txt, add tests.txt"

  # ---- main advances: same new.txt content, different commit -------------
  G checkout -q main
  echo "landed by re-application" > "$ROOT/new.txt"
  G add -A && G commit -q -m "re-apply new.txt on main"
  G update-ref refs/remotes/origin/main main

  export NO_COLOR=1
}

teardown() {
  rm -rf "$TEST_TMP"
}

_stranded() {
  ( cd "$ROOT" && ./scripts/commands/branch.sh stranded "$@" </dev/null )
}

# Class label printed for a branch, e.g. "SHRINKS+UNLANDED".
_class_of() {
  printf '%s\n' "$output" | awk -v b="$1" '$0 ~ ("[[:space:]]" b "[[:space:]]") {print $1; exit}'
}

@test "stranded: pure-identical branch is IDENTICAL (its files already match main)" {
  run _stranded
  [ "$status" -eq 0 ]
  [ "$(_class_of pure/identical)" = "IDENTICAL" ]
}

@test "stranded: pure-shrink branch is SHRINKS and nothing else" {
  run _stranded
  [ "$status" -eq 0 ]
  [ "$(_class_of pure/shrink)" = "SHRINKS" ]
}

@test "stranded: pure-unlanded branch is UNLANDED and nothing else" {
  run _stranded
  [ "$status" -eq 0 ]
  [ "$(_class_of pure/unlanded)" = "UNLANDED" ]
}

# THE RED TEST: today this prints SHRINKS, hiding tests.txt.
@test "stranded: mixed branch reports SHRINKS+UNLANDED, not just the dominant class" {
  run _stranded
  [ "$status" -eq 0 ]
  [ "$(_class_of mixed/shrink-and-add)" = "SHRINKS+UNLANDED" ]
  # and it must tell the operator not to delete it, not merely not to merge it
  [[ "$output" == *"cherry-pick, do not merge, do not delete"* ]]
}

@test "stranded --prune-merged --yes deletes ONLY the pure-identical branch" {
  run _stranded --prune-merged --yes
  [ "$status" -eq 0 ]
  local after
  after=$(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads)
  [[ "$after" != *"pure/identical"* ]]
  [[ "$after" == *"pure/shrink"* ]]
  [[ "$after" == *"pure/unlanded"* ]]
  # the exact accident this guards: the mixed branch carries unlanded work
  [[ "$after" == *"mixed/shrink-and-add"* ]]
}

@test "stranded --files names the additive and subtractive paths per branch" {
  run _stranded --files
  [ "$status" -eq 0 ]
  # mixed branch: tests.txt is content main lacks, keep.txt is content it would remove
  [[ "$output" == *"+ tests.txt"* ]]
  [[ "$output" == *"- keep.txt"* ]]
  # pure-unlanded's file is additive only
  [[ "$output" == *"+ feature.txt"* ]]
  # and a purely additive branch must not be given a subtractive path
  ! printf '%s\n' "$output" | grep -q -- "- feature.txt"
}

@test "stranded --json carries the full class set, not one label" {
  run _stranded --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
rows = {r["branch"]: r for r in json.load(sys.stdin)}
m = rows["mixed/shrink-and-add"]
assert sorted(m["classes"]) == ["SHRINKS","UNLANDED"], m
assert m["class"] == "SHRINKS+UNLANDED", m
assert m["prunable"] is False, m
assert rows["pure/identical"]["classes"] == ["IDENTICAL"], rows["pure/identical"]
assert rows["pure/identical"]["prunable"] is True, rows["pure/identical"]
assert rows["pure/shrink"]["classes"] == ["SHRINKS"], rows["pure/shrink"]
assert rows["pure/unlanded"]["classes"] == ["UNLANDED"], rows["pure/unlanded"]
assert sorted(m["additive"]) == ["tests.txt"], m
assert sorted(m["subtractive"]) == ["keep.txt"], m
'
}

# NEGATIVE CONTROL: a classifier that "plays it safe" by calling everything
# SHRINKS+UNLANDED, or by never pruning anything, would satisfy the mixed-branch
# test above. These two assertions make that cheat fail: the pure branches must
# keep their single class, and the identical branch must still be pruned.
@test "negative control: blanket-mixed labelling or blanket-refusal fails" {
  run _stranded --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
rows = {r["branch"]: r for r in json.load(sys.stdin)}
# not everything is mixed
multi = [b for b,r in rows.items() if len(r["classes"]) > 1]
assert multi == ["mixed/shrink-and-add"], multi
# not everything is unprunable
prunable = [b for b,r in rows.items() if r["prunable"]]
assert prunable == ["pure/identical"], prunable
'
}

@test "stranded: REVERT (adds nothing anywhere) is still its own class" {
  git -C "$ROOT" -c user.email=t@t -c user.name=t checkout -q -b pure/revert main
  head -10 "$ROOT/keep.txt" > "$ROOT/keep.tmp"
  mv "$ROOT/keep.tmp" "$ROOT/keep.txt"
  git -C "$ROOT" -c user.email=t@t -c user.name=t commit -q -aqm "revert-only"
  git -C "$ROOT" -c user.email=t@t -c user.name=t checkout -q main
  run _stranded
  [ "$status" -eq 0 ]
  [ "$(_class_of pure/revert)" = "REVERT" ]
}
