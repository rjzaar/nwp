#!/usr/bin/env bats
#
# `pl mr release` must leave the PIPELINE reflecting the release, and every
# printed MR link must point at the project the repo actually is (nwp/ops#283).
#
# THE CATCH-22 THIS PINS. On 2026-08-04 the operator ran
#
#     pl mr release 350 --approved-by=rjzaar --reason='...'
#     SUCCESS: !350 released by @rjzaar, bound to head c1c6ce9a8acc
#     HINT: merging is still a human action — this only removed the hold
#
# and then found the MR still marked blocked in the web UI. Both statements were
# true at once: the release WAS recorded and the Draft WAS lifted (layer 1), but
# layer 2 of the hold is the gate job's own RED result, and a release does not
# re-run a job that has already finished. So the MR was released and unmergeable
# simultaneously, with nothing on screen explaining the contradiction. Retrying
# the job by hand turned it green on the same head commit.
#
# Retrying is NOT self-approval, and that distinction is what makes this safe to
# automate: the retried job re-executes scripts/ci/sensitive-path-hold-gate.sh,
# which looks for a release record bound to the CURRENT head. A real release
# passes on the gate's own evidence; a fake one goes red again. Nothing is
# asserted here that the gate does not independently re-verify.
#
# THE SECOND DEFECT. _mr_web_url() hardcoded /nwp/nwp/, so `pl mr create` in the
# nwc profile repo announced ".../nwp/nwp/-/merge_requests/70" for an MR living
# in nwp/nwc. The operator followed it to a Project Not Found, and `pl mr status`
# repeated the same wrong field. A verb that hands you a wrong link costs more
# time than one that hands you none — and it now matters more, because the
# release hint prints that link as the next action.

setup() {
    # PINNED TO TEAM MODE. This suite tests the two-person machinery — the Draft
    # hold, the release record, the sensitive-path refusal — and that machinery is
    # switched OFF in solo mode (ADR-0032), which is what the estate now declares.
    # Pinning keeps these cases meaningful: team mode is disabled, NOT deleted, so
    # its tests must keep passing or the switch would arm onto untested code.
    export NWP_REVIEW_MODE=team
    # A HUMAN token. cmd_merge now refuses a bot, and refuses when it cannot tell
    # (ADR-0032: "a machine never merges"). Unstubbed, _mr_token_user has no API to
    # reach, returns rc 1, and every case here died on that refusal before reaching
    # its own assertion.
    _mr_token_user(){ printf 'a-human'; }
    _mr_handle_is_bot(){ return 1; }
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mrrel.XXXXXX")"
    export MR_STATUS_FILE="$TMP/status"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/ui.sh" 2>/dev/null || true
    YQ="$(command -v yq || true)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/gitlab-mr.sh"
    # _mr_web_url lives in the command, not the lib; pull in just that function.
    eval "$(awk '/^_mr_web_url\(\)/,/^}/' "$REPO_ROOT/scripts/commands/mr.sh")"
    _mr_host(){ printf 'git.example.test'; }
}
teardown() { rm -rf "$TMP"; }

# ---------------------------------------------------------------- web url ----

@test "the MR link names the project the repo IS, not a hardcoded one" {
    _mr_project(){ printf 'nwp%%2Fnwc'; }
    run _mr_web_url 70
    [ "$status" -eq 0 ]
    [ "$output" = "https://git.example.test/nwp/nwc/-/merge_requests/70" ]
}

@test "RED-PROOF: no CODE line hardcodes a project into an MR url" {
    # The exact shape that produced two 404s, pinned as absent so it cannot
    # return by copy-paste.
    #
    # COMMENTS ARE EXEMPT, deliberately. The first version of this assertion
    # grepped the whole file and so condemned the comment that EXPLAINS the bug —
    # the same "a gate that fails its own remedy" mistake this repo has hit
    # before. Taxing the explanation is how you train people to delete it.
    local offenders
    offenders="$(grep -n 'merge_requests' "$REPO_ROOT/scripts/commands/mr.sh" \
                 | grep -vE '^[0-9]+:[[:space:]]*#' \
                 | grep -E '/nwp/nwp/|/[a-z]+/[a-z]+/-/merge_requests' || true)"
    [ -z "$offenders" ] || { echo "hardcoded project in: $offenders"; false; }
}

@test "a numeric project id becomes a /projects/<id> URL, not a fake slug" {
    # CI_PROJECT_ID / NWP_MR_PROJECT can be numeric. Inventing a slug from a
    # number would be a confidently wrong link, which is the thing being fixed.
    _mr_project(){ printf '21'; }
    run _mr_web_url 5
    [ "$output" = "https://git.example.test/projects/21/-/merge_requests/5" ]
}

@test "an unresolvable project SAYS so rather than guessing" {
    _mr_project(){ return 1; }
    run _mr_web_url 9
    [[ "$output" == *"project unresolved"* ]]
}

# -------------------------------------------------------- gate job retry ----

# _mr_retry_gate_job calls _mr_project, _mr_fetch, _mr_jget and _mr_api. Stub
# the transport only; the selection logic under test stays real.
_stub_api() { # <jobs-json> <retry-rc>
    _mr_project(){ printf 'nwp%%2Fnwp'; }
    _mr_fetch(){ printf '{"head_pipeline":{"id":1910}}'; }
    export STUB_JOBS="$1" STUB_RETRY_RC="$2"
    _mr_api(){
        case "$1 $2" in
            "GET /projects/nwp%2Fnwp/pipelines/1910/jobs?per_page=100") printf '%s' "$STUB_JOBS" ;;
            "POST"*"/retry")  printf '{"id":15075}'; return "$STUB_RETRY_RC" ;;
            *) return 1 ;;
        esac
    }
}

@test "retries the FAILED mr-hold job and reports its id" {
    _stub_api '[{"id":10,"name":"test:unit","status":"success"},
                {"id":14721,"name":"security:mr-hold","status":"failed"}]' 0
    run _mr_retry_gate_job 350
    [ "$status" -eq 0 ]
    [ "$output" = "14721" ]
}

@test "matches the gate job by NAME, not by position in the list" {
    # The jobs array is not ordered by contract, so picking "the failed one" or
    # "the last one" would work by luck. Put an unrelated failure first.
    _stub_api '[{"id":99,"name":"lint:doc-truth","status":"failed"},
                {"id":14721,"name":"security:mr-hold","status":"failed"}]' 0
    run _mr_retry_gate_job 350
    [ "$output" = "14721" ]
}

@test "does NOT retry a gate job that already passed" {
    # Re-running a green gate is pointless churn and would cancel nothing useful.
    _stub_api '[{"id":14721,"name":"security:mr-hold","status":"success"}]' 0
    run _mr_retry_gate_job 350
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "no pipeline yet is rc 1 (nothing to do), not a failure" {
    _mr_project(){ printf 'nwp%%2Fnwp'; }
    _mr_fetch(){ printf '{}'; }
    run _mr_retry_gate_job 350
    [ "$status" -eq 1 ]
}

@test "a failed retry CALL is rc 2 — distinct from nothing-to-retry" {
    # cmd_release must be able to tell "no job needed retrying" (benign) from
    # "I tried and could not" (the operator has to finish by hand). Collapsing
    # them would reintroduce the silent version of the same catch-22.
    _stub_api '[{"id":14721,"name":"security:mr-hold","status":"failed"}]' 1
    run _mr_retry_gate_job 350
    [ "$status" -eq 2 ]
}

# ------------------------------------------------------------ cmd_release ----

@test "cmd_release retries the gate and distinguishes all three outcomes" {
    local src="$REPO_ROOT/scripts/commands/mr.sh"
    grep -q '_mr_retry_gate_job "$iid"' "$src"
    # rc 2 must WARN that the pipeline stays red — the release is recorded, so a
    # silent failure here is precisely the state that confused the operator.
    grep -q 'could not re-run the gate job' "$src"
    grep -q 'pipeline will stay red' "$src"
    # and the hint now points at where to merge
    grep -q 'Wait for the pipeline to go green' "$src"
}

@test "cmd_release still says merging is a human action BY DEFAULT" {
    # Unchanged: with no --merge, the verb re-runs the CHECK and stops.
    grep -q 'merging is still a human action' "$REPO_ROOT/scripts/commands/mr.sh"
}

@test "cmd_release merges ONLY behind an explicit --merge" {
    # THE ORIGINAL FORM OF THIS TEST FORBADE MERGING OUTRIGHT, and it was right
    # to. Its reasoning — "the two-person property must not be weakened" — is
    # load-bearing: dropping the human Merge click removes the only step whose
    # actor the FORGE can identify, because --approved-by is a string the caller
    # types and nothing checks the caller IS that person.
    #
    # The operator asked for one command ("why do I need to release and merge.
    # Can't the merge be the release?" — 2026-08-05), so the assertion is
    # narrowed rather than deleted: merging is allowed, but only under an
    # explicit flag AND only when the forge-verified token identity differs from
    # the author. See the two cases below, which are the replacement backstop.
    local body
    body=$(awk '/^cmd_release\(\)/,/^}/' "$REPO_ROOT/scripts/commands/mr.sh")
    # no merge except via cmd_merge (one merge path, which owns the
    # stale-detailed_merge_status and one-rebase-per-run rules)
    ! printf '%s' "$body" | grep -qE '_mr_api PUT .*/merge"'
    # and it is gated on the flag
    printf '%s' "$body" | grep -q 'do_merge' 
    printf '%s' "$body" | grep -q 'if \[ "\$do_merge" != true \]'
}

@test "RED-PROOF: --merge REFUSES when the token belongs to the MR author" {
    # The replacement for the human click, and stronger than it: the UI let an
    # author merge their own MR once somebody had left a release note. This does
    # not, and it keys off the identity the FORGE reports, not a typed handle.
    local src="$REPO_ROOT/scripts/commands/mr.sh"
    grep -q 'REFUSING --merge: this token belongs to @\$tok_user, who AUTHORED' "$src"
    grep -q '\[ "\$tok_user" = "\$mr_author" \]' "$src"
    # the check must come BEFORE the wait, so a refusal costs nothing
    local guard wait_l
    guard=$(grep -n 'tok_user" = "\$mr_author' "$src" | head -1 | cut -d: -f1)
    wait_l=$(grep -n 'waiting for the pipeline to re-evaluate' "$src" | head -1 | cut -d: -f1)
    [ "$guard" -lt "$wait_l" ] || { echo "author check runs AFTER the wait"; false; }
}

@test "RED-PROOF: an unestablished token identity REFUSES, never assumes" {
    # "I could not establish who I am" is not "I am somebody else". Fail closed.
    local src="$REPO_ROOT/scripts/commands/mr.sh"
    grep -q "could not establish this token's forge identity" "$src"
    grep -q 'could not read !\$iid.s author' "$src"
    # _mr_token_user itself must fail rather than return a guess
    grep -q '_mr_token_user(){' "$REPO_ROOT/lib/gitlab-mr.sh"
    awk '/^_mr_token_user\(\)/,/^}/' "$REPO_ROOT/lib/gitlab-mr.sh" | grep -q 'return 1'
}

# ---- behavioural: the --merge refusals, run rather than grepped -------------
#
# The three cases above are grep-on-source, and mutation testing on the sibling
# suite proved that shape walks past a deleted call. These run cmd_release for
# real with every write stubbed, and assert cmd_merge is NEVER reached.

_load_release(){
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/commands/mr.sh" 2>/dev/null || true
    set +u +o pipefail
    MERGE_LOG="$(mktemp)"; API_LOG="$(mktemp)"
    export NWP_GITLAB_HOST="forge.invalid.test"
    _mr_project(){ printf 'nwp%%2Fnwp'; }
    _mr_have_token(){ return 0; }
    # every write recorded, none performed
    _mr_api(){ printf '%s %s\n' "$1" "$2" >> "$API_LOG"; printf '{}'; }
    _mr_get(){ printf '{}'; }
    _mr_notes(){ printf '[]'; }
    _mr_retry_gate_job(){ return 0; }
    _mr_assert_releasable(){ printf 'held'; return 0; }
    # STATEFUL, and it has to be: cmd_release lifts the Draft and then re-reads
    # to confirm it went. A stub that always says draft:true makes the verb bail
    # with "still a draft after release" long before the merge logic, and the case
    # then proves nothing about --merge. The counter lives in a FILE because
    # _mr_fetch is called inside $( ), a subshell.
    FETCH_N="$(mktemp)"; echo 0 > "$FETCH_N"
    _mr_fetch(){
        local n; n=$(( $(cat "$FETCH_N") + 1 )); echo "$n" > "$FETCH_N"
        if [ "$n" -le 1 ]; then
            printf '%s' '{"iid":9,"title":"Draft: t","state":"opened","draft":true,"author":{"username":"alice"},"sha":"abc"}'
        else
            printf '%s' '{"iid":9,"title":"t","state":"opened","draft":false,"author":{"username":"alice"},"sha":"abc"}'
        fi
    }
    cmd_merge(){ printf 'CMD_MERGE_CALLED iid=%s\n' "$1" >> "$MERGE_LOG"; return 0; }
    _mr_pipeline_status(){ printf 'success'; }
}
_teardown_release(){ rm -f "$MERGE_LOG" "$API_LOG" "$FETCH_N"; }

@test "BEHAVIOURAL: --merge does NOT merge when the token IS the author" {
    _load_release
    _mr_token_user(){ printf 'alice'; }      # same as the MR author
    run cmd_release 9 --approved-by=bob --reason=probe --merge
    [ "$status" -ne 0 ]
    [ ! -s "$MERGE_LOG" ] || { echo "MERGED as the author:"; cat "$MERGE_LOG"; false; }
    [[ "$output" == *"REFUSING --merge"* ]]
    _teardown_release
}

@test "BEHAVIOURAL: --merge DOES merge when the token is a different person" {
    # The other direction, so the refusal is proven conditional rather than total.
    _load_release
    _mr_token_user(){ printf 'carol'; }
    run cmd_release 9 --approved-by=carol --reason=probe --merge
    grep -q 'CMD_MERGE_CALLED iid=9' "$MERGE_LOG" \
      || { echo "did NOT merge for a distinct identity; output:"; echo "$output"; false; }
    _teardown_release
}

@test "BEHAVIOURAL: --merge refuses when the token identity is unknown" {
    _load_release
    _mr_token_user(){ return 1; }
    run cmd_release 9 --approved-by=bob --reason=probe --merge
    [ "$status" -ne 0 ]
    [ ! -s "$MERGE_LOG" ] || { echo "merged on an unknown identity"; false; }
    [[ "$output" == *"could not establish this token's forge identity"* ]]
    _teardown_release
}

@test "BEHAVIOURAL: without --merge, cmd_merge is never called at all" {
    _load_release
    _mr_token_user(){ printf 'carol'; }
    run cmd_release 9 --approved-by=carol --reason=probe
    [ ! -s "$MERGE_LOG" ] || { echo "merged without being asked"; cat "$MERGE_LOG"; false; }
    [[ "$output" == *"merging is still a human action"* ]]
    _teardown_release
}

@test "BEHAVIOURAL: --merge refuses on a red pipeline, and says the release stands" {
    _load_release
    _mr_token_user(){ printf 'carol'; }
    _mr_pipeline_status(){ printf 'failed'; }
    run cmd_release 9 --approved-by=carol --reason=probe --merge
    [ "$status" -ne 0 ]
    [ ! -s "$MERGE_LOG" ] || { echo "merged over a red pipeline"; false; }
    [[ "$output" == *"NOT merging"* ]]
    _teardown_release
}

@test "BEHAVIOURAL: a username-less /user body refuses — it must not read as \"\"" {
    # Mutation testing found this: delete `[ -n "$u" ] || return 1` from
    # _mr_token_user and it returns EMPTY with rc 0. "" != "alice", so the
    # two-person check PASSES and the MR merges — a fail-OPEN reached by removing
    # one guard. The real _mr_token_user runs here, against a body with no
    # username, so the case exercises that guard rather than a stub of it.
    _load_release
    _mr_get(){ printf '%s' '{"id":7,"name":"No Username Here"}'; }
    run cmd_release 9 --approved-by=bob --reason=probe --merge
    [ "$status" -ne 0 ]
    [ ! -s "$MERGE_LOG" ] || { echo "merged on an EMPTY token identity"; false; }
    [[ "$output" == *"could not establish this token's forge identity"* ]]
    _teardown_release
}

@test "BEHAVIOURAL: an unreadable MR author refuses — never merges on a blank" {
    # The mirror of the above: if the AUTHOR reads empty, "carol" != "" passes the
    # comparison and it merges. Both sides of the check need a non-empty value.
    _load_release
    _mr_token_user(){ printf 'carol'; }
    FETCH_N="$(mktemp)"; echo 0 > "$FETCH_N"
    _mr_fetch(){
        local n; n=$(( $(cat "$FETCH_N") + 1 )); echo "$n" > "$FETCH_N"
        if [ "$n" -le 1 ]; then
            printf '%s' '{"iid":9,"title":"Draft: t","state":"opened","draft":true,"author":{"username":"alice"},"sha":"abc"}'
        else
            # no author at all on the re-read
            printf '%s' '{"iid":9,"title":"t","state":"opened","draft":false,"sha":"abc"}'
        fi
    }
    run cmd_release 9 --approved-by=carol --reason=probe --merge
    [ "$status" -ne 0 ]
    [ ! -s "$MERGE_LOG" ] || { echo "merged with an unknown author"; false; }
    [[ "$output" == *"author"* ]]
    _teardown_release
}
