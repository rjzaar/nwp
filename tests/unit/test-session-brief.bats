#!/usr/bin/env bats
# The generated session brief.
#
# THE ONE PROPERTY THIS FILE EXISTS TO PROVE
# ------------------------------------------
#   MUTATE THE WORLD → REGENERATE → THE BRIEF CHANGED.
#
# That is the whole anti-staleness argument, and it is not provable by reading
# the code. On 2026-08-02 an orchestrating session fed four wrong premises to
# its sub-agents from memory — an MR "merged" that was open, a branch "on main"
# that was not, a wrong root cause, and a missing video that was present. Prose
# cannot fail that way loudly; it just keeps saying what it said. A derived
# brief can only be wrong if the derivation is wrong, and a derivation can be
# tested. Each mutation test below changes one fact in the estate and asserts
# the brief moved with it.
#
# THE SECOND PROPERTY: BLIND IS NOT EMPTY.
#   "no open MRs" and "I was not allowed to look" are opposite facts that render
#   identically if you are careless. Several tests below take away the brief's
#   ability to see and assert that it SAYS SO rather than reporting zero.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PROJECT_ROOT="$REPO_ROOT"
  export NWP_BATON_FILE="$BATS_TEST_TMPDIR/BATON.md"
  export NWP_RAG_STATE="$BATS_TEST_TMPDIR/rag.json"
  export NWP_SITES_DIR="$BATS_TEST_TMPDIR/sites"
  export NWP_SESSION_STATE_DIR="$BATS_TEST_TMPDIR/state"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/session.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/session-bounds.sh"
  printf 'STATUS: READY\nHEARTBEAT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$NWP_BATON_FILE"
}

mk_rag() { # $1=generated $2=RED
  cat > "$NWP_RAG_STATE" <<EOF
{"generated":"$1","summary":{"RED":$2,"AMBER":1,"GREEN":2,"UNSCANNED":3}}
EOF
}

mk_golden() { # $1=site $2=captured
  mkdir -p "$NWP_SITES_DIR/$1/demo-golden-live"
  cat > "$NWP_SITES_DIR/$1/demo-golden-live/golden.manifest.json" <<EOF
{"type":"demo-golden","site":"$1","captured_utc":"$2","db_sha256":"deadbeefcafe0000"}
EOF
}

field() { printf '%s' "$1" | yq e -p=json ".$2 // \"\"" -; }

# ═════════════════════════════════════════════════════════════════════════════
# THE MUTATION PROOF — the brief tracks the world
# ═════════════════════════════════════════════════════════════════════════════

@test "MUTATION rag: change the rollup, regenerate, the brief changed" {
  mk_rag "2026-08-02T01:00:00Z" 7
  local before; before=$(session_section_rag)
  [ "$(field "$before" RED)" = "7" ]

  # the world moves
  mk_rag "2026-08-02T02:00:00Z" 2

  local after; after=$(session_section_rag)
  [ "$(field "$after" RED)" = "2" ]
  [ "$before" != "$after" ]
}

@test "MUTATION golden: recapture a golden, regenerate, the brief shows the NEW timestamp" {
  mk_golden nwd "2026-08-02T05:35:47Z"
  local before; before=$(session_section_goldens)
  [[ "$(field "$before" rows)" == *"2026-08-02T05:35:47Z"* ]]

  mk_golden nwd "2026-08-02T09:99:00Z"   # deliberately distinctive
  local after; after=$(session_section_goldens)
  [[ "$(field "$after" rows)" == *"2026-08-02T09:99:00Z"* ]]
  [[ "$(field "$after" rows)" != *"05:35:47Z"* ]]
}

@test "MUTATION golden: adding a SECOND site appears without touching any code" {
  mk_golden nwd "2026-08-02T05:35:47Z"
  local one; one=$(session_section_goldens)
  mk_golden ssd "2026-08-02T06:46:22Z"
  local two; two=$(session_section_goldens)
  [[ "$(field "$one" rows)" != *"ssd"* ]]
  [[ "$(field "$two" rows)" == *"ssd"* ]]
  [[ "$(field "$two" rows)" == *"06:46:22Z"* ]]
}

@test "MUTATION baton: flip the baton, regenerate, the brief's mode changed" {
  [ "$(session_baton_effective_status)" = "READY" ]
  session_baton_set_status ABANDONED
  [ "$(session_baton_effective_status)" = "ABANDONED" ]
}

@test "MUTATION git: a new commit moves the brief's git section" {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"; cd "$repo"
  git init -q .; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m one
  local before; before=$(session_section_git "$repo")
  git commit -q --allow-empty -m two
  local after; after=$(session_section_git "$repo")
  [ "$(field "$before" head)" != "$(field "$after" head)" ]
}

# ═════════════════════════════════════════════════════════════════════════════
# BLIND IS NOT EMPTY
# ═════════════════════════════════════════════════════════════════════════════

@test "RED-PROOF blind: a MISSING rag rollup is BLIND, not GREEN" {
  rm -f "$NWP_RAG_STATE"
  local s; s=$(session_section_rag)
  [ -n "$(field "$s" provenance.blind)" ]
  [[ "$(field "$s" provenance.blind)" == *"UNKNOWN, not GREEN"* ]]
}

@test "RED-PROOF blind: a rollup with a NULL timestamp reports UNKNOWN AGE, not a fake one" {
  # Caught in the wild 2026-08-02. `date -u -d "" +%s` does NOT fail — it
  # returns midnight today, exit 0 — so a mid-write rollup rendered as a
  # confident "507 min old". The brief manufacturing its own stale premise is
  # the exact failure it exists to prevent, so this one is pinned hard.
  printf '{"generated":null,"summary":{"RED":1,"AMBER":1,"GREEN":1,"UNSCANNED":1}}\n' > "$NWP_RAG_STATE"
  local s; s=$(session_section_rag)
  [ "$(field "$s" age_min)" = "" ]
  [[ "$(field "$s" provenance.blind)" == *"NO generated timestamp"* ]]
}

@test "RED-PROOF blind: an UNPARSEABLE timestamp is UNKNOWN age, not zero" {
  mk_rag "not-a-date" 1
  local s; s=$(session_section_rag)
  [ "$(field "$s" age_min)" = "" ]
  [ -n "$(field "$s" provenance.blind)" ]
}

@test "RED-PROOF blind: NO staged golden is stated, not silently omitted" {
  mkdir -p "$NWP_SITES_DIR"
  local s; s=$(session_section_goldens)
  [[ "$(field "$s" provenance.blind)" == *"not the same as"* ]]
}

@test "RED-PROOF blind: a token that cannot see the project reports MR-BLIND" {
  # mini holds only gitlab.ops_note_token (Reporter on nwp/ops), which returns
  # 404 on nwp/nwp. An empty MR list there would be the single most dangerous
  # line this brief could print.
  local sf="$BATS_TEST_TMPDIR/secrets.yml"
  printf 'gitlab:\n  server:\n    domain: "127.0.0.1:1"\n  api_token: "x"\n' > "$sf"
  NWP_SECRETS_FILE="$sf" run session_section_mrs 9 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"MR-BLIND"* ]]
}

@test "RED-PROOF blind: with no token at all the MR section is BLIND, not zero open MRs" {
  local sf="$BATS_TEST_TMPDIR/empty.yml"
  printf '{}\n' > "$sf"
  NWP_SECRETS_FILE="$sf" run session_section_mrs 9 0
  [[ "$output" == *"MR-BLIND"* ]]
  [[ "$output" != *'"open_count":"1'* ]]
}

@test "RED-PROOF blind: holds are UNKNOWN when the forge cannot be read" {
  local sf="$BATS_TEST_TMPDIR/empty.yml"
  printf '{}\n' > "$sf"
  NWP_SECRETS_FILE="$sf" run session_section_holds 9
  [[ "$output" == *"HOLD-BLIND"* ]]
}

# ═════════════════════════════════════════════════════════════════════════════
# TRUNCATION HONESTY
# ═════════════════════════════════════════════════════════════════════════════

@test "truncation: the brief states whether the PAGINATING issue verb is present" {
  # !320 (fix/issue-ls-truncation) was unmerged when this was written and
  # nwp/ops is AT the 100-row cap, so `pl issue ls` here returns a SHORT list.
  # The brief must say which world it is in rather than presenting either as
  # complete. When !320 lands, `paginating_verb_present` flips to 1 and the
  # warning disappears — with no edit to this file.
  #
  # The invariant asserted here is the one that matters and holds in all three
  # worlds: THE SECTION NEVER PRESENTS A LIST WITHOUT QUALIFYING IT. Either it
  # could not read the queue (blind), or it read it with the short verb (warned),
  # or it read it with the paginating verb (complete). What it may never do is
  # hand over a list with no statement about whether that list is all of them.
  local s; s=$(session_section_issues)
  local present blind warn
  present=$(field "$s" paginating_verb_present)
  blind=$(field "$s" provenance.blind)
  warn=$(field "$s" truncation_warning)

  if [ -n "$blind" ]; then
    [[ "$blind" == *"NOT an empty queue"* ]]
  elif [ "$present" = "1" ]; then
    [ -z "$warn" ]
  else
    [[ "$warn" == *"may be SHORT"* ]]
  fi
}

@test "truncation: with a paginating verb present, no warning is emitted" {
  # The paired positive, so the warning cannot become permanent furniture that
  # survives !320 landing. A fake pl that advertises --pending must silence it.
  local fake="$BATS_TEST_TMPDIR/pl"
  cat > "$fake" <<'EOF'
#!/bin/sh
case "$*" in
  *"--help"*) echo "  pl issue ls [--all] [--pending] [--project=ops|all]"; exit 0 ;;
esac
echo "  1  opened  a thing"
exit 0
EOF
  chmod +x "$fake"
  NWP_PL="$fake" run session_section_issues
  [[ "$output" == *'"paginating_verb_present":"1"'* ]]
  [[ "$output" == *'"truncation_warning":""'* ]]
}

@test "RED-PROOF truncation: WITHOUT the paginating verb the warning DOES fire" {
  # And the red-proof for the same thing: a pl whose help lacks --pending must
  # produce the SHORT-list warning. Without this the test above would pass on a
  # section that never warns at all.
  local fake="$BATS_TEST_TMPDIR/pl-old"
  cat > "$fake" <<'EOF'
#!/bin/sh
case "$*" in
  *"--help"*) echo "  pl issue ls [--all]"; exit 0 ;;
esac
echo "  1  opened  a thing"
exit 0
EOF
  chmod +x "$fake"
  NWP_PL="$fake" run session_section_issues
  [[ "$output" == *'"paginating_verb_present":"0"'* ]]
  [[ "$output" == *"may be SHORT"* ]]
  [[ "$output" == *"!320"* ]]
}

@test "RED-PROOF truncation: a failing issue verb is BLIND, not an empty queue" {
  local fake="$BATS_TEST_TMPDIR/pl"
  printf '#!/bin/sh\nexit 7\n' > "$fake"; chmod +x "$fake"
  NWP_PL="$fake" run session_section_issues
  [[ "$output" == *"NOT an empty queue"* ]]
}

# ═════════════════════════════════════════════════════════════════════════════
# STALE MERGE STATUS (ops#213)
# ═════════════════════════════════════════════════════════════════════════════

@test "ops#213: an unrecomputed conflict is rendered as a CLAIM, not a finding" {
  # The forge reports stale `cannot_be_merged` for branches that merge cleanly
  # (verified by local test-merge). Reading that as fact is how a session
  # decides a mergeable MR is broken and goes off to 'fix' it.
  grep -q 'STALE-SUSPECT' "$REPO_ROOT/lib/session.sh"
  grep -q 'cannot_be_merged?' "$REPO_ROOT/lib/session.sh"
}

@test "ops#213: 'checking' is retried, not treated as failure" {
  grep -qE 'checking.*unchecked|unchecked.*checking' "$REPO_ROOT/lib/session.sh"
  grep -q 'rebase' "$REPO_ROOT/lib/session.sh"
}

# ═════════════════════════════════════════════════════════════════════════════
# THE GENERATED / PROSE SPLIT
# ═════════════════════════════════════════════════════════════════════════════

@test "split: every derived section carries its own provenance" {
  mk_rag "2026-08-02T01:00:00Z" 1
  mk_golden nwd "2026-08-02T05:35:47Z"
  local s
  for s in "$(session_section_rag)" "$(session_section_goldens)" "$(session_section_git "$REPO_ROOT")"; do
    [ -n "$(field "$s" provenance.source)" ]
    [ -n "$(field "$s" provenance.at)" ]
  done
}

@test "split: prose is quarantined and stamped UNVERIFIED" {
  local sh="$REPO_ROOT/scripts/commands/session.sh"
  grep -q 'PROSE — judgement that cannot be derived' "$sh"
  grep -q 'UNVERIFIED' "$sh"
  # and the prose must come AFTER all derived sections, so a reader who stops
  # early has read only facts.
  local prose_line derived_line
  prose_line=$(grep -n 'PROSE — judgement' "$sh" | head -1 | cut -d: -f1)
  derived_line=$(grep -n '_hdr "\$h" "Holds' "$sh" | head -1 | cut -d: -f1)
  [ "$prose_line" -gt "$derived_line" ]
}

@test "split: an ABANDONED baton puts the brief into RE-DERIVE mode" {
  session_baton_set_status ABANDONED
  run "$REPO_ROOT/pl" session baton status
  [ "$status" -eq 2 ]
  [[ "$output" == *"ABANDONED"* ]]
}

@test "split: with no baton at all, NOTHING is carried" {
  rm -f "$NWP_BATON_FILE"
  grep -q 'no prose available' "$REPO_ROOT/scripts/commands/session.sh"
  [ "$(session_baton_effective_status)" = "ABANDONED(missing)" ]
}
