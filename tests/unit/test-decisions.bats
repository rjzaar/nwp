#!/usr/bin/env bats
#
# `pl decisions` — the operator's open decisions, read from the tracker (ops#292).
#
# WHY THE VERB EXISTS. Three decision DOCUMENTS were written in a week and every
# one went stale. PICKUP-2026-08-05.md went stale twice in one night and the
# operator caught both — the wrong way round:
#
#     "PICKUP-2026-08-05.md is not up to date. 363 has been merged."
#
# A document is a copy of the tracker's state, and copies drift invisibly until
# someone acts on the stale half. This verb holds no state, so there is nothing
# to go stale.
#
# WHAT THE OPERATOR ASKED FOR, in their words:
#
#     "can you add a clear explanation of what that decision entails rather than
#      having to wade through the jargon with a clear recommendation and why?"
#     "it should provide a link to the issue for reference"
#     "will pl decisions order them and in some way sequence them and group them"
#
# So the tests below are about READABILITY as much as correctness: the block
# parses, the options survive, the recommendation is shown, the link is there,
# and the ordering is by what the decision gates.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    RENDER="$REPO_ROOT/scripts/lib/decisions-render.py"
    TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/dec.XXXXXX")"
}
teardown() { rm -rf "$TMP"; }

# One issue with a full Decision block.
_issue() { # iid gate title
    python3 - "$1" "$2" "$3" <<'PY'
import json,sys
iid, gate, title = sys.argv[1], sys.argv[2], sys.argv[3]
body = f"""## Decision

**Gate:** {gate}

**What:** The thing being chosen, in one sentence.

**Options:**
- **A. First.** Cheap and limited.
- **B. Second.** Slow but carries weight.

**Recommend:** A, because it is reversible.

**Unblocks:** the thing downstream.

---
Diagnosis nobody needs to read to answer the question.
"""
print(json.dumps([{"iid": int(iid), "title": title, "web_url": f"https://h/nwp/ops/-/issues/{iid}",
                   "labels": ["needs-decision"], "description": body}]))
PY
}

@test "the ## Decision block parses: what, options, recommendation, unblocks" {
    _issue 1 blocks-testers "A test decision" > "$TMP/j"
    run bash -c "python3 '$RENDER' text '' h < '$TMP/j'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"The thing being chosen"* ]]
    [[ "$output" == *"Recommend:"* ]]
    [[ "$output" == *"reversible"* ]]
    [[ "$output" == *"Unblocks:"* ]]
}

@test "RED-PROOF: the OPTIONS list survives — it is the part that broke" {
    # The first parser allowed a field to start with an optional "- ", so the
    # option items (themselves "- **A. …**") were read as the NEXT FIELD and the
    # list came back empty. Silently, and Options is what the operator most
    # needs. Both options must appear.
    _issue 1 blocks-testers "A test decision" > "$TMP/j"
    run bash -c "python3 '$RENDER' text '' h < '$TMP/j'"
    [[ "$output" == *"First."* ]]
    [[ "$output" == *"Second."* ]]
}

@test "the issue link is always shown — the operator asked for it by name" {
    _issue 7 blocks-prod "Linked" > "$TMP/j"
    run bash -c "python3 '$RENDER' text '' h < '$TMP/j'"
    [[ "$output" == *"/nwp/ops/-/issues/7"* ]]
}

@test "grouped and ordered by what the decision GATES" {
    python3 - > "$TMP/j" <<'PY'
import json
def mk(iid, gate, title):
    return {"iid": iid, "title": title, "web_url": f"https://h/i/{iid}", "labels": [],
            "description": f"## Decision\n\n**Gate:** {gate}\n\n**What:** w\n\n**Recommend:** r\n"}
# deliberately out of order
print(json.dumps([mk(1,"housekeeping","H"), mk(2,"blocks-prod","P"), mk(3,"blocks-testers","T")]))
PY
    run bash -c "python3 '$RENDER' text '' h < '$TMP/j'"
    local t p h
    t=$(echo "$output" | grep -n "BLOCKS TESTERS" | cut -d: -f1)
    p=$(echo "$output" | grep -n "BLOCKS PROD" | cut -d: -f1)
    h=$(echo "$output" | grep -n "HOUSEKEEPING" | cut -d: -f1)
    [ "$t" -lt "$p" ]
    [ "$p" -lt "$h" ]
}

@test "a decision others depend on sorts FIRST within its group" {
    # The sequencing the operator asked for: later questions may not make sense
    # until earlier ones are answered.
    python3 - > "$TMP/j" <<'PY'
import json
dep = {"iid": 10, "title": "Depends", "web_url": "u", "labels": [],
       "description": "## Decision\n\n**Gate:** blocks-testers\n\n**What:** w\n\nDepends-on: #11\n"}
base = {"iid": 11, "title": "Foundational", "web_url": "u", "labels": [],
        "description": "## Decision\n\n**Gate:** blocks-testers\n\n**What:** w\n"}
print(json.dumps([dep, base]))
PY
    run bash -c "python3 '$RENDER' text '' h < '$TMP/j'"
    local a b
    a=$(echo "$output" | grep -n "#11" | head -1 | cut -d: -f1)
    b=$(echo "$output" | grep -n "#10" | head -1 | cut -d: -f1)
    [ "$a" -lt "$b" ]
    [[ "$output" == *"Answer after: #11"* ]]
}

@test "an issue with NO Decision block is listed as incomplete, never hidden" {
    # Hiding it would recreate the problem: an unreadable decision still blocks.
    printf '%s' '[{"iid":5,"title":"Bare","web_url":"u","labels":[],"description":"just prose"}]' > "$TMP/j"
    run bash -c "python3 '$RENDER' text '' h < '$TMP/j'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"#5"* ]]
    [[ "$output" == *"no ## Decision block yet"* ]]
}

@test "--json is machine-readable for the console" {
    _issue 3 blocks-prod "J" > "$TMP/j"
    run bash -c "python3 '$RENDER' json '' h < '$TMP/j'"
    run python3 -c "import json,sys; d=json.load(sys.stdin); print(d['count'], d['decisions'][0]['gate'], len(d['decisions'][0]['options']))" <<<"$output"
    [ "$output" = "1 blocks-prod 2" ]
}

@test "an unreadable tracker response is CANNOT-VERIFY, not 'no decisions'" {
    printf 'not json' > "$TMP/j"
    run bash -c "python3 '$RENDER' text '' h < '$TMP/j'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "the verb fails closed when there is no token" {
    # "I could not look" is never "there is nothing to decide".
    grep -q 'CANNOT-VERIFY: no GitLab token available' "$REPO_ROOT/scripts/commands/decisions.sh"
    grep -q "it is 'I could not look'" "$REPO_ROOT/scripts/commands/decisions.sh"
}

@test "no forge domain is hardcoded — gitleaks banned it, and rightly" {
    # The first version defaulted the host to the real forge domain. gitleaks
    # rejected the commit (rule: live-internal-domain), which was correct: a
    # "default" naming the real host is how a generic tool quietly hardcodes one
    # estate. An unresolvable host is CANNOT-VERIFY, not a guess.
    ! grep -qE 'nwpcode\.org' "$REPO_ROOT/scripts/commands/decisions.sh"
    ! grep -qE 'nwpcode\.org' "$REPO_ROOT/scripts/lib/decisions-render.py"
    grep -q 'no gitlab.server.domain configured' "$REPO_ROOT/scripts/commands/decisions.sh"
    grep -q 'will not guess which forge is yours' "$REPO_ROOT/scripts/commands/decisions.sh"
}

# ── open MRs in the same queue (ops#295) ──────────────────────────────────────
# Under solo review mode (ADR-0032) the merge click IS the approval, so an open
# MR is an operator action exactly like a needs-decision issue. The renderer
# takes a manifest of per-project MR fetches; a project whose fetch failed is
# CANNOT-READ, never an empty (= clean-looking) list.

_mr_manifest() { # writes manifest with one readable project (1 MR) + one failed
    printf '%s' '[{"iid":371,"title":"review pane","web_url":"https://h/nwp/nwp/-/merge_requests/371","draft":false,"detailed_merge_status":"mergeable","has_conflicts":false,"source_branch":"b","author":{"username":"bot"},"updated_at":"2026-08-06T09:00:00Z","labels":[],"description":"What: the pane."}]' > "$TMP/mrs1.json"
    printf 'nwp/nwp\t%s\tok\n'        "$TMP/mrs1.json" >  "$TMP/manifest"
    printf 'nwp/nwc\t%s\tunreadable\n' "$TMP/mrs2.json" >> "$TMP/manifest"
}

@test "open MRs render in the queue, before the decisions" {
    _issue 1 blocks-testers "A decision" > "$TMP/j"
    _mr_manifest
    run bash -c "python3 '$RENDER' text '' h '$TMP/manifest' < '$TMP/j'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AWAITING YOUR MERGE"* ]]
    [[ "$output" == *"nwp/nwp!371"* ]]
    # ordering: the MR section comes before the decisions header
    first="${output%%decision(s) waiting*}"
    [[ "$first" == *"AWAITING YOUR MERGE"* ]]
}

@test "RED-PROOF: an unreadable MR project is CANNOT-READ, not an empty list" {
    # The walled ops token 404s outside nwp/ops; without this, its projects
    # would render as 'no open MRs' — unreadable masquerading as clean.
    _issue 1 blocks-testers "A decision" > "$TMP/j"
    _mr_manifest
    run bash -c "python3 '$RENDER' text '' h '$TMP/manifest' < '$TMP/j'"
    [[ "$output" == *"nwp/nwc"* ]]
    [[ "$output" == *"CANNOT-READ"* ]]
}

@test "--json carries the MRs for the console Review pane" {
    _issue 1 blocks-testers "A decision" > "$TMP/j"
    _mr_manifest
    run bash -c "python3 '$RENDER' json '' h '$TMP/manifest' < '$TMP/j'"
    run python3 -c "
import json,sys
d=json.load(sys.stdin)
ps=d['mrs']['projects']
print(d['mrs']['open_total'], ps[0]['ok'], ps[0]['items'][0]['iid'], ps[1]['ok'], 'CANNOT-READ' in ps[1]['error'])" <<<"$output"
    [ "$output" = "1 True 371 False True" ]
}

@test "no decisions + open MRs still renders the queue, not 'nothing is blocked'" {
    printf '%s' '[]' > "$TMP/j"
    _mr_manifest
    run bash -c "python3 '$RENDER' text '' h '$TMP/manifest' < '$TMP/j'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nwp/nwp!371"* ]]
    [[ "$output" == *"merge requests above are the whole queue"* ]]
}

@test "callers without a manifest keep the old contract (no MR section)" {
    _issue 1 blocks-testers "A decision" > "$TMP/j"
    run bash -c "python3 '$RENDER' text '' h < '$TMP/j'"
    [ "$status" -eq 0 ]
    [[ "$output" != *"AWAITING YOUR MERGE"* ]]
    run bash -c "python3 '$RENDER' json '' h < '$TMP/j'"
    run python3 -c "import json,sys; d=json.load(sys.stdin); print(d['mrs']['open_total'], len(d['mrs']['projects']))" <<<"$output"
    [ "$output" = "0 0" ]
}

# ── staleness + the declared label split (audit 2026-08-06) ───────────────────
# ops#143 sat four days as the sole blocks-prod item after two comments said
# "recommend close" — the ## Decision block is a snapshot and nothing compared
# it to the conversation. The renderer now flags it. And ~50 decision::wanted
# issues were invisible: the footer declares the split instead of hiding it.

_note() { # iid text -> writes notes/<iid>.json in the API's newest-first shape
    mkdir -p "$TMP/notes"
    python3 - "$1" "$2" > "$TMP/notes/$1.json" <<'PY'
import json,sys
print(json.dumps([{"body": sys.argv[2], "created_at": "2026-08-06T00:00:00Z"}]))
PY
}

@test "a decision whose newest comment says 'recommend close' is FLAGGED, not hidden" {
    _issue 143 blocks-prod "A solved problem" > "$TMP/j"
    _note 143 "**FIXED — both decision points answered. Recommend close.**"
    run bash -c "python3 '$RENDER' text '' h '' '$TMP/notes' '' < '$TMP/j'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"possibly already resolved"* ]]
    [[ "$output" == *"Recommend close"* ]]
    # flagged, NOT dropped — the issue still renders in full
    [[ "$output" == *"#143"* ]]
    [[ "$output" == *"Recommend:"* ]]
}

@test "an ordinary comment does NOT trip the staleness flag" {
    _issue 1 blocks-testers "A live decision" > "$TMP/j"
    _note 1 "Adding more context about the options here."
    run bash -c "python3 '$RENDER' text '' h '' '$TMP/notes' '' < '$TMP/j'"
    [[ "$output" != *"possibly already resolved"* ]]
}

@test "no notes dir = no staleness signal, old callers keep their contract" {
    _issue 1 blocks-testers "A decision" > "$TMP/j"
    run bash -c "python3 '$RENDER' text '' h < '$TMP/j'"
    [ "$status" -eq 0 ]
    [[ "$output" != *"possibly already resolved"* ]]
}

@test "the footer declares the decision::wanted backlog with a count" {
    _issue 1 blocks-testers "A decision" > "$TMP/j"
    run bash -c "python3 '$RENDER' text '' h '' '' 48 < '$TMP/j'"
    [[ "$output" == *"48 open issue(s) carry decision::wanted"* ]]
    [[ "$output" == *"pl issue label"* ]]
}

@test "an unreadable outside count still DECLARES the split (no silent omission)" {
    _issue 1 blocks-testers "A decision" > "$TMP/j"
    run bash -c "python3 '$RENDER' text '' h '' '' '' < '$TMP/j'"
    [[ "$output" == *"could not be read"* ]]
    [[ "$output" == *"needs-decision only"* ]]
}

@test "--json carries possibly_stale, stale_hint and outside_queue" {
    _issue 143 blocks-prod "Solved" > "$TMP/j"
    _note 143 "Triage: ALREADY DONE (bucket C). Recommend close."
    run bash -c "python3 '$RENDER' json '' h '' '$TMP/notes' 48 < '$TMP/j'"
    run python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d['decisions'][0]
print(r['possibly_stale'], 'ALREADY DONE' in r['stale_hint'], d['outside_queue']['count'], d['outside_queue']['label'])" <<<"$output"
    [ "$output" = "True True 48 decision::wanted" ]
}

@test "the single-decision view (<iid>) renders no footer" {
    _issue 7 blocks-testers "One decision" > "$TMP/j"
    run bash -c "python3 '$RENDER' text 7 h '' '' 48 < '$TMP/j'"
    [[ "$output" != *"decision::wanted"* ]]
}
