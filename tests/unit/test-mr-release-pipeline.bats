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

@test "cmd_release still says merging is a human action" {
    # The two-person property must not be weakened by automating the retry: the
    # verb re-runs the CHECK, it never merges.
    grep -q 'merging is still a human action' "$REPO_ROOT/scripts/commands/mr.sh"
    ! awk '/^cmd_release\(\)/,/^}/' "$REPO_ROOT/scripts/commands/mr.sh" | grep -qE '_mr_api PUT .*/merge"|cmd_merge'
}
