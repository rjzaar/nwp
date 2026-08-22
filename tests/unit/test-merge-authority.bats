#!/usr/bin/env bats
#
# BOUNDED STANDING MERGE AUTHORITY (nwp/ops#385).
#
# Operator ruling, 2026-08-22, given in session: the click-fail-paste-wait loop on
# the merge queue is to stop, and the queue is delegated — inside a bound he stated
# himself. "do it all and get it working."
#
#     never a prod-phase site · never a sensitive path · never CLAUDE.md itself
#
# WHAT THIS FILE HAS TO PROVE, and why each part is here:
#
#  1. THE INVARIANT STILL HOLDS WHERE NOTHING WAS GRANTED. `_mr_merge_actor_ok` is
#     incident-born (2026-08-01: a sweeper merged an MR nobody had approved). The
#     carve-out must be a carve-out, not a hole: with no `merge_authority:` block,
#     a bot is refused exactly as it was yesterday.
#
#  2. THE BOUND IS MECHANICAL, AND IT HAS BEEN WATCHED TO FIRE. CLAUDE.md: "Give
#     such a guard a test proving it REFUSES against a fixture marked prod — an
#     inert guard nobody has seen fire is the 'check that has never been proven to
#     fail' class (ops#214)." No real site is canonical: prod, so the prod case is
#     driven from a fixture nwp.yml. Same for the sensitive-path and CLAUDE.md
#     cases, which are the two an armed automation would meet first.
#
#  3. FAIL CLOSED, IN THE DIRECTION THAT COSTS FRICTION NOT PROTECTION. Unreadable
#     registry, malformed block, unrecognised scope, unmeasurable diff — every one
#     of them means A HUMAN MERGES. The permissive direction would read "I could
#     not find the policy" as "there is no policy", which is how a typo silently
#     grants standing merge authority over the estate.
#
#  4. TRUTHFUL ATTRIBUTION (ops#361). The note a machine merge posts must name the
#     MACHINE. Borrowed attribution is the defect ops#361 recorded from the other
#     direction — an agent recording an operator approval that was never given —
#     and it is the same defect if a machine's merge later reads as the operator's
#     click. The operator's handle must appear nowhere in that note.
#
#  5. NO SECOND PLACE TO SET IT. The anti-drift clause, copied in shape from
#     tests/unit/test-review-mode.bats, which fails if a second reader of
#     `approvers:` appears. One accessor decides; a grep proves nothing else
#     re-derives the grant, and nothing can grant it from an env var or a flag.
#
# HOW RED WAS PROVEN. Each RED-PROOF below was run against a tree with ONLY the
# source reverted — never the test — and the failure quoted in the MR. A test
# written after the fix has never been shown capable of failing.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export MR_STATUS_FILE="$(mktemp)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/ui.sh" 2>/dev/null || true
    # A FAILING CASE HERE MUST REPORT RED, NOT VANISH.
    #
    # lib/gitlab-mr.sh installs `trap _mr_status_cleanup EXIT` at source time,
    # which CLOBBERS the EXIT trap bats uses to report a test's result. The effect
    # is invisible while everything passes and vicious the moment something fails:
    # under bats' errexit the test shell exits, bats never gets its trap, and the
    # case disappears from the run with no `not ok` line — bats only mutters
    # "Executed 19 instead of expected 27" at the end. That is the ops#214 class
    # wearing a disguise: a red-proof that cannot go red where anybody sees it.
    # Measured while writing this file — eight cases silently evaporated. So bats'
    # own handler is saved and put back.
    local _bats_exit_trap; _bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/gitlab-mr.sh"
    eval "$_bats_exit_trap"
    # AFTER the source — lib/gitlab-mr.sh resolves YQ on load (ops#293). Left as
    # the real value here (unlike test-review-mode.bats): the yq-less path gets its
    # own case, and the rest should exercise what a workstation actually runs.
    TMPD="$(mktemp -d)"
    unset NWP_REVIEW_MODE
    # Every case drives the actor check explicitly; nothing may dial the forge.
    _mr_get(){ return 1; }
    _mr_api(){ return 1; }
    _mr_fetch(){ return 1; }
}
teardown() { rm -f "$MR_STATUS_FILE"; rm -rf "$TMPD"; }

# ---- fixtures ---------------------------------------------------------------

BOT='group_9_bot_53ae5a1df066ec501e8867f7276f66b1'

# _granted [handle] — a registry that DOES declare standing authority.
_granted() {
    local to="${1:-$BOT}"
    cat > "$TMPD/registry.yml" <<EOF
approvers:
  - rjzaar
merge_authority:
  granted_to: $to
  granted_by: rjzaar
  granted_on: "2026-08-22"
  ref: nwp/ops#385
  scope: non-sensitive-non-prod
EOF
    export NWP_SECRETS_REGISTRY="$TMPD/registry.yml"
}

# _ungranted — a registry shaped exactly like today's, with no grant in it.
_ungranted() {
    printf 'approvers:\n  - rjzaar\n' > "$TMPD/registry.yml"
    export NWP_SECRETS_REGISTRY="$TMPD/registry.yml"
}

# _asbot — the token's forge-verified identity is the granted machine.
_asbot()  { _mr_token_user(){ printf '%s' "$BOT"; }; }
_ashuman(){ _mr_token_user(){ printf 'rjzaar'; }; _mr_handle_is_bot(){ return 1; }; }

# _diff <path>... — what !9 changed.
#
# MR_TEST_DIFF is deliberately NOT `local`: bash has no closures, so a nested
# function body sees whatever the variable holds AT CALL TIME, and a `local` in
# the defining function is long gone by then. My first version did exactly that
# and every diff came back EMPTY — which the scope check correctly graded
# "blindness", so the cases failed for a reason that had nothing to do with what
# they were testing.
_diff() { MR_TEST_DIFF="$(printf '%s\n' "$@")"; _mr_changed_files(){ printf '%s\n' "$MR_TEST_DIFF"; }; }

# _prod_fixture <site> — an nwp.yml declaring one site canonical: prod.
# NO REAL SITE IS PROD (prod does not exist yet — PROGRAMME-PHASES, ops#203), so
# the only way to watch this guard fire is to build the thing it refuses.
_prod_fixture() {
    local site="$1" phase="${2:-prod}"
    cat > "$TMPD/nwp.yml" <<EOF
sites:
  $site:
    canonical: $phase
EOF
    export NWP_YML="$TMPD/nwp.yml"
}

# ---- 1. nothing granted: today's behaviour, unchanged -----------------------

@test "RED-PROOF (a): with NO merge_authority declared, a bot is REFUSED" {
    # The incident-born invariant, untouched. If this ever passes, the carve-out
    # became a hole.
    _ungranted; _asbot
    _diff 'README.md'
    run _mr_merge_actor_ok 9
    [ "$status" -eq 1 ] || { echo "a bot merged with no grant on record (rc $status)"; false; }
    _mr_merge_actor_ok 9 || true
    [[ "$MR_MERGE_ACTOR_REASON" == *"no standing merge authority is declared"* ]] \
      || { echo "reason was: $MR_MERGE_ACTOR_REASON"; false; }
}

@test "RED-PROOF (a'): the REAL registry decides — this is not a fixture-only feature" {
    # Reads the registry the estate actually ships, so the repo cannot claim a
    # grant in prose while declaring nothing (or vice versa). Whatever it says,
    # the accessor and CLAUDE.md must agree about it.
    unset NWP_SECRETS_REGISTRY
    if auth=$(_mr_merge_authority); then
        [[ "$auth" == *"granted_to="* ]]
        # A grant to a HUMAN handle would be meaningless — humans already merge.
        local to; to=$(_mr_ma_get "$auth" granted_to)
        run _mr_handle_is_bot "$to"
        [ "$status" -eq 0 ] || { echo "the estate granted standing merge authority to @$to, which is not a machine"; false; }
        grep -q 'granted' "$REPO_ROOT/CLAUDE.md" \
          || { echo "the registry declares a grant and CLAUDE.md does not mention one"; false; }
    else
        echo "no grant declared in the real registry — the feature is INERT here" >&3
    fi
}

@test "a HUMAN token merges regardless — the grant is about machines only" {
    _ungranted; _ashuman
    _diff 'CLAUDE.md'          # even the most sensitive diff there is
    run _mr_merge_actor_ok 9
    [ "$status" -eq 0 ] || { echo "a human was refused (rc $status)"; false; }
}

# ---- 2. the mechanical bound, watched firing --------------------------------

@test "RED-PROOF (e): an ORDINARY in-scope MR IS allowed when granted" {
    # The refusal must be CONDITIONAL, or the feature is just a broken verb and
    # every other case in this file passes for the wrong reason.
    _granted; _asbot
    _diff 'docs/reports/milestones.md' 'lib/frontend.sh'
    run _mr_merge_actor_ok 9
    [ "$status" -eq 0 ] || { echo "an in-scope MR was refused (rc $status)"; echo "$output"; false; }
    _mr_merge_actor_ok 9 || true
    [[ "$MR_MERGE_ACTOR_REASON" == *"standing authorization nwp/ops#385"* ]] \
      || { echo "reason was: $MR_MERGE_ACTOR_REASON"; false; }
}

@test "RED-PROOF (b): a SENSITIVE-PATH diff is refused even when granted" {
    _granted; _asbot
    _diff 'docs/README.md' '.gitlab-ci.yml'
    run _mr_merge_scope_ok 9
    [ "$status" -eq 1 ] || { echo "the sensitive path was not caught (rc $status): $output"; false; }
    [[ "$output" == *"sensitive path"* ]] && [[ "$output" == *".gitlab-ci.yml"* ]]
    run _mr_merge_actor_ok 9
    [ "$status" -eq 1 ] || { echo "a granted bot merged a sensitive-path MR (rc $status)"; false; }
}

@test "RED-PROOF (b'): the bound FOLLOWS CLAUDE.md's list, with no code change" {
    # lib/sensitive-paths.sh parses the standing order at RUN TIME. That claim is
    # the reason no glob is copied into this feature, so it is verified rather
    # than believed: a path that is ordinary under the real CLAUDE.md becomes
    # out-of-scope the moment a fixture standing order lists it.
    _granted; _asbot
    _diff 'lib/frontend.sh'
    run _mr_merge_scope_ok 9
    [ "$status" -eq 0 ] || { echo "lib/frontend.sh is not sensitive today: $output"; false; }

    cat > "$TMPD/CLAUDE.md" <<'EOF'
### Sensitive File Paths

- `lib/frontend.sh` - invented for this test only
EOF
    NWP_CLAUDE_MD="$TMPD/CLAUDE.md" run _mr_merge_scope_ok 9
    [ "$status" -eq 1 ] || { echo "adding a glob to the standing order did NOT tighten the bound (rc $status): $output"; false; }
    [[ "$output" == *"lib/frontend.sh"* ]]
}

@test "RED-PROOF: CLAUDE.md is refused even when the sensitive list does NOT name it" {
    # THE CASE THAT MAKES THE EXPLICIT CHECK EARN ITS KEEP. The globs are parsed
    # OUT OF CLAUDE.md, so an MR that edits CLAUDE.md's own Sensitive File Paths
    # section could otherwise widen the bound it is being judged by. The standing
    # order that defines the bound is not a file the bound may be talked out of.
    _granted; _asbot
    _diff 'CLAUDE.md'
    cat > "$TMPD/CLAUDE.md" <<'EOF'
### Sensitive File Paths

- `keys/**` - the list no longer mentions CLAUDE.md
EOF
    NWP_CLAUDE_MD="$TMPD/CLAUDE.md" run _mr_merge_scope_ok 9
    [ "$status" -eq 1 ] || { echo "CLAUDE.md was machine-mergeable once it removed itself from the list (rc $status): $output"; false; }
    [[ "$output" == *"CLAUDE.md"* ]] && [[ "$output" == *"standing orders"* ]]
}

@test "RED-PROOF (c): a PROD-PHASE site is refused even when granted" {
    # ops#214's class, head on. No site in this estate is canonical: prod, so the
    # guard would otherwise ship having never been observed to fire even once.
    _granted; _asbot
    _prod_fixture 'fixtureprod'
    _diff 'sites/fixtureprod/dev/web/index.php'
    run _mr_merge_scope_ok 9
    [ "$status" -eq 1 ] || { echo "a prod-phase site was IN scope (rc $status): $output"; false; }
    [[ "$output" == *"fixtureprod"* ]] && [[ "$output" == *"prod"* ]]
    run _mr_merge_actor_ok 9
    [ "$status" -eq 1 ] || { echo "a granted bot merged a change to a prod-phase site (rc $status)"; false; }
}

@test "RED-PROOF (c'): the guard keys off the PHASE, never off the site's NAME" {
    # CLAUDE.md: "'Refuse nwc and ss' is wrong today (it blocks real work) and
    # wrong later (it would miss a new prod site)." Same fixture, same file paths,
    # one field changed — and the verdict must follow the field.
    _granted; _asbot
    _diff 'sites/nwc/dev/web/index.php'
    _prod_fixture 'nwc' live
    run _mr_merge_scope_ok 9
    [ "$status" -eq 0 ] || { echo "a LIVE site was refused by name (rc $status): $output"; false; }
    _prod_fixture 'nwc' prod
    run _mr_merge_scope_ok 9
    [ "$status" -eq 1 ] || { echo "the same site went unrefused at canonical: prod (rc $status)"; false; }
}

@test "an UNPARSEABLE canonical phase is cannot-verify, not 'not prod'" {
    _granted; _asbot
    _prod_fixture 'oddsite' 'production'      # not one of dev|live|prod
    _diff 'sites/oddsite/dev/x.php'
    run _mr_merge_scope_ok 9
    [ "$status" -eq 2 ] || { echo "an invalid phase graded $status, expected 2: $output"; false; }
    [[ "$output" == *"cannot-verify"* ]]
    run _mr_merge_actor_ok 9
    [ "$status" -eq 2 ]
}

# ---- 3. fail closed ---------------------------------------------------------

@test "RED-PROOF (d): an UNREADABLE registry refuses — a human merges" {
    _asbot
    _diff 'README.md'
    NWP_SECRETS_REGISTRY=/nonexistent/nope run _mr_merge_actor_ok 9
    [ "$status" -eq 1 ] || { echo "an unreadable registry granted authority (rc $status)"; false; }
    NWP_SECRETS_REGISTRY=/nonexistent/nope run _mr_merge_authority
    [ "$status" -ne 0 ] || { echo "the accessor reported a grant it could not read"; false; }
}

@test "RED-PROOF: an unrecognised or missing field refuses — a typo never grants" {
    _asbot
    _diff 'README.md'
    local reg="$TMPD/registry.yml"; export NWP_SECRETS_REGISTRY="$reg"
    # scope word this build does not understand
    printf 'merge_authority:\n  granted_to: %s\n  granted_by: rjzaar\n  ref: nwp/ops#385\n  scope: everything\n' "$BOT" > "$reg"
    run _mr_merge_actor_ok 9
    [ "$status" -eq 1 ] || { echo "an unrecognised scope: granted authority"; false; }
    # no ref — a grant with no record of who decided it
    printf 'merge_authority:\n  granted_to: %s\n  granted_by: rjzaar\n  scope: non-sensitive-non-prod\n' "$BOT" > "$reg"
    run _mr_merge_actor_ok 9
    [ "$status" -eq 1 ] || { echo "a grant with no ref: was honoured"; false; }
    # no granted_by
    printf 'merge_authority:\n  granted_to: %s\n  ref: nwp/ops#385\n  scope: non-sensitive-non-prod\n' "$BOT" > "$reg"
    run _mr_merge_actor_ok 9
    [ "$status" -eq 1 ] || { echo "a grant with no granted_by: was honoured"; false; }
    # a malformed ref
    printf 'merge_authority:\n  granted_to: %s\n  granted_by: rjzaar\n  ref: "because I said so"\n  scope: non-sensitive-non-prod\n' "$BOT" > "$reg"
    run _mr_merge_actor_ok 9
    [ "$status" -eq 1 ] || { echo "a prose ref: was honoured"; false; }
}

@test "RED-PROOF: a grant to a DIFFERENT handle does not cover this token" {
    _granted 'project_12_bot_someone_else'
    _asbot
    _diff 'README.md'
    run _mr_merge_actor_ok 9
    [ "$status" -eq 1 ] || { echo "a bot merged under somebody else's grant (rc $status)"; false; }
    _mr_merge_actor_ok 9 || true
    [[ "$MR_MERGE_ACTOR_REASON" == *"not for it"* ]] || { echo "reason: $MR_MERGE_ACTOR_REASON"; false; }
}

@test "RED-PROOF: an EMPTY change set is blindness, not a clean diff" {
    # Every observed way of reaching here — no token, a yq-less parse, a broken
    # paginated read — produces an empty list, and ops#293 is the entire history
    # of that being read as "nothing sensitive". rc 2, never 0.
    _granted; _asbot
    _mr_changed_files(){ printf ''; }
    run _mr_merge_scope_ok 9
    [ "$status" -eq 2 ] || { echo "an empty diff graded $status, expected 2: $output"; false; }
    [[ "$output" == *"blindness"* ]]
    run _mr_merge_actor_ok 9
    [ "$status" -eq 2 ] || { echo "a granted bot proceeded on a diff it could not see"; false; }
}

@test "RED-PROOF: an unreadable diff is cannot-verify" {
    _granted; _asbot
    _mr_changed_files(){ return 1; }
    run _mr_merge_actor_ok 9
    [ "$status" -eq 2 ]
}

@test "RED-PROOF: an unreadable CLAUDE.md is cannot-verify, never 'no sensitive paths'" {
    _granted; _asbot
    _diff 'README.md'
    NWP_CLAUDE_MD=/nonexistent/nope run _mr_merge_scope_ok 9
    [ "$status" -eq 2 ] || { echo "an unreadable standing order graded $status, expected 2"; false; }
    NWP_CLAUDE_MD=/nonexistent/nope run _mr_merge_actor_ok 9
    [ "$status" -eq 2 ]
}

@test "RED-PROOF: a grant with NO MR named cannot be exercised — rc 2" {
    # A grant is not a permission. The bound is measured per MR or not at all, so
    # a caller that forgets the iid must not silently get the old blanket answer.
    _granted; _asbot
    run _mr_merge_actor_ok
    [ "$status" -eq 2 ] || { echo "a grant answered without measuring anything (rc $status)"; false; }
}

@test "RED-PROOF: an unknown forge identity may NOT merge — rc 2, not 0" {
    _granted
    _mr_token_user(){ return 1; }
    run _mr_merge_actor_ok 9
    [ "$status" -eq 2 ]
}

@test "the accessor works with NO yq — CI-shaped hosts included" {
    # _mr_approver_count was written with a bare "$YQ" once and silently counted
    # zero without it. Zero reads as fail-closed here, which would hide the bug
    # rather than fix it, so the yq-less path is measured directly.
    _granted
    YQ="" run _mr_merge_authority
    [ "$status" -eq 0 ] || { echo "the yq-less reader could not parse a valid grant"; false; }
    [[ "$output" == *"granted_to=$BOT"* ]]
    [[ "$output" == *"ref=nwp/ops#385"* ]]
}

# ---- 4. truthful attribution (ops#361) --------------------------------------

@test "the attribution note names the MACHINE and says no human clicked" {
    run _mr_merge_attribution_body "$BOT" 'nwp/ops#385' 'not recorded'
    [ "$status" -eq 0 ]
    [[ "$output" == *"merged by @$BOT"* ]]
    [[ "$output" == *"under standing authorization nwp/ops#385"* ]]
    [[ "$output" == *"cross-model review: not recorded"* ]]
    [[ "$output" == *"A MACHINE merged this merge request"* ]]
    [[ "$output" == *"No human clicked Merge"* ]]
}

@test "RED-PROOF: the attribution note never borrows the OPERATOR's identity" {
    # ops#361 recorded the same defect from the other direction — an agent
    # recording an operator approval that was never given. A machine merge that
    # later reads as the operator's click is that defect, mirrored.
    local approver
    approver=$(_mr_ma_get "$(printf 'granted_by=rjzaar\n')" granted_by)
    run _mr_merge_attribution_body "$BOT" 'nwp/ops#385' 'not recorded'
    ! grep -qi "$approver" <<<"$output" \
      || { echo "the note names the operator (@$approver):"; echo "$output"; false; }
    ! grep -qiE 'approved by|reviewed by|on behalf of' <<<"$output" \
      || { echo "the note implies a human act:"; echo "$output"; false; }
}

@test "cross-model review state is REPORTED, and 'not recorded' when absent" {
    _mr_fetch(){ printf '%s' '{"description":"a body with nothing in it"}'; }
    run _mr_cross_model_review_state 9
    [ "$output" = "not recorded" ]
    _mr_fetch(){ printf '%s' '{"description":"blah\n\nCross-model review: Fable, 2026-08-22, no findings\n"}'; }
    run _mr_cross_model_review_state 9
    [[ "$output" == *"Fable"* ]] || { echo "state read as [$output]"; false; }
}

@test "an unreadable MR gives an HONEST cross-model state, not a clean one" {
    _mr_fetch(){ return 1; }
    run _mr_cross_model_review_state 9
    [[ "$output" == *"unknown"* ]] || { echo "state read as [$output]"; false; }
    [[ "$output" != *"not recorded"* ]]
}

# ---- 5. no second place to set it -------------------------------------------

@test "ANTI-DRIFT: exactly ONE place reads merge_authority: out of the registry" {
    # The shape of test-review-mode.bats's approvers: clause, for the same reason:
    # a policy expressed in several places drifts, and the drifted copy is the one
    # that gates the merge.
    local readers
    readers=$(grep -rn '\.merge_authority\|merge_authority:' "$REPO_ROOT/lib" "$REPO_ROOT/scripts" 2>/dev/null \
              | grep -vE ':[0-9]+:[[:space:]]*#' \
              | grep -vE '(echo|printf|print_[a-z]+|cat <<)' || true)
    [ "$(printf '%s\n' "$readers" | grep -c .)" -ge 1 ]
    ! printf '%s\n' "$readers" | grep -v 'lib/gitlab-mr.sh' | grep -q . \
      || { echo "merge_authority: is read outside the accessor's library:";
           printf '%s\n' "$readers" | grep -v 'lib/gitlab-mr.sh'; false; }
    # and within that library, only the accessor opens the file
    local opens
    opens=$(awk '/^_mr_merge_authority\(\)/,/^}/' "$REPO_ROOT/lib/gitlab-mr.sh" | grep -c 'merge_authority\.' || true)
    [ "$opens" -ge 1 ] || { echo "the accessor does not read the block it claims to"; false; }
}

@test "ANTI-DRIFT: NO env var and NO flag can grant merge authority" {
    # The whole switch is the registry block. A console toggle, an --i-mean-it
    # flag or an NWP_* override would each be a second place to set one fact —
    # and the one an automation would reach for when the bound refused it.
    local envs
    envs=$(grep -rnE 'NWP_[A-Z_]*MERGE_AUTHORITY|NWP_[A-Z_]*STANDING_(MERGE|AUTH)' \
             "$REPO_ROOT/lib" "$REPO_ROOT/scripts" 2>/dev/null || true)
    [ -z "$envs" ] || { echo "an env-var grant path exists:"; echo "$envs"; false; }
    local flags
    flags=$(grep -rnE -- '--(grant-merge|merge-authority|standing-authority|allow-bot-merge)' \
              "$REPO_ROOT/lib" "$REPO_ROOT/scripts" 2>/dev/null || true)
    [ -z "$flags" ] || { echo "a CLI flag can grant it:"; echo "$flags"; false; }
}

@test "ANTI-DRIFT: cmd_merge passes the IID, so the bound is always measured" {
    # A caller that drops the argument gets rc 2 (proven above), so this cannot
    # silently fail open — but the verb must still ask the question properly.
    grep -q '_mr_merge_actor_ok "$iid"' "$REPO_ROOT/scripts/commands/mr.sh" \
      || { echo "cmd_merge does not name the MR it is asking about"; false; }
}

@test "ANTI-DRIFT: CLAUDE.md records the grant, the bound, and the surviving rule" {
    local md="$REPO_ROOT/CLAUDE.md"
    grep -qi 'a machine never merges' "$md"
    grep -q 'ops#385' "$md"                      # the grant record
    grep -q 'merge_authority' "$md"              # where it is declared
    grep -qi '2026-08-01' "$md"                  # the incident is NOT deleted
    grep -qiE 'canonical phase is .?prod|phase .?prod' "$md"
    grep -qi 'inert' "$md"                       # it does nothing until declared
}

################################################################################
# THE BOUND MUST PROTECT ITS OWN ENFORCEMENT MACHINERY (ops#385, finding A1).
#
# Raised by cross-model review of !474 (Fable, 2026-08-23), and reproduced before
# it was fixed: `_mr_merge_scope_ok` returned rc 0 — MACHINE-MERGEABLE — for a
# single-file diff touching the bound itself, the parser it reads the list with,
# the phase reader, the verb that merges, and its own three test suites.
#
# THE ATTACK. An MR that edits `_mr_merge_scope_ok` AND ITS OWN TESTS together
# stays CI-green (CI runs the MR's own tests), matches no other sensitive glob,
# and machine-merges with ZERO human eyes — because the merging process runs the
# OLD code, so the MR is judged by the version it is about to replace. Every
# merge after the next pull is then unbounded.
#
# The fix is a LIST EDIT, not a code change: lib/sensitive-paths.sh parses
# CLAUDE.md's "Sensitive File Paths" section at run time. That premise is itself
# verified below rather than believed.
################################################################################

@test "RED-PROOF (A1): the bound refuses a diff touching its OWN enforcement machinery" {
    # Measured file by file, and every one of these returned rc 0 before the fix.
    _granted; _asbot
    local f rc out failed=""
    for f in lib/gitlab-mr.sh lib/sensitive-paths.sh lib/canonical.sh \
             scripts/commands/mr.sh tests/unit/test-merge-authority.bats \
             tests/unit/test-mr-merge.bats tests/unit/test-review-mode.bats; do
        _diff "$f"
        rc=0; out=$(_mr_merge_scope_ok 9) || rc=$?
        [ "$rc" -eq 1 ] || failed="${failed}${f} (rc $rc) "
    done
    [ -z "$failed" ] \
      || { echo "MACHINE-MERGEABLE, so an MR editing it is judged by the code it replaces: $failed"; false; }
}

@test "RED-PROOF (A1'): THE ATTACK — editing the bound AND its own tests together is refused" {
    # The whole point. Each file alone is covered by the case above; this is the
    # combination that stays CI-green because CI runs the tests the MR ships.
    _granted; _asbot
    _diff 'lib/gitlab-mr.sh' 'tests/unit/test-merge-authority.bats'
    run _mr_merge_scope_ok 9
    [ "$status" -eq 1 ] \
      || { echo "a machine merged a rewrite of its own bound plus the tests that check it (rc $status)"; echo "$output"; false; }
    run _mr_merge_actor_ok 9
    [ "$status" -eq 1 ] || { echo "actor check allowed the self-widening MR (rc $status)"; false; }
}

@test "RED-PROOF (A1''): the machinery is named in CLAUDE.md, which is where the bound reads it" {
    # NOT a grep for a comment: the premise of the fix is that the list is parsed
    # at RUN TIME, so the list and the behaviour cannot drift apart. Proven by
    # pointing the parser at a COPY with the entries removed and watching the
    # bound go permissive again — the same file, one section edited.
    _granted; _asbot
    local copy="$TMPD/CLAUDE.md"
    grep -v '^- `lib/gitlab-mr\.sh`' "$REPO_ROOT/CLAUDE.md" > "$copy"
    _diff 'lib/gitlab-mr.sh'
    NWP_CLAUDE_MD="$copy" run _mr_merge_scope_ok 9
    [ "$status" -eq 0 ] \
      || { echo "the entry is not what makes this refuse — something else is, so the list is decoration"; false; }
    NWP_CLAUDE_MD="$REPO_ROOT/CLAUDE.md" run _mr_merge_scope_ok 9
    [ "$status" -eq 1 ] \
      || { echo "the real CLAUDE.md does not cover lib/gitlab-mr.sh"; false; }
}

################################################################################
# A TRUNCATED DIFF IS NOT A CLEAN DIFF (ops#385, finding A2).
#
# `_mr_changed_files` capped pagination and `break`ed with rc 0, so an MR too big
# to read whole came back looking like one that had been read whole. Reproduced:
# 30 full pages of padding plus `.gitlab-ci.yml` on page 31 gave rc 0, 3000
# paths, the sensitive path ABSENT, and the bound graded the MR IN SCOPE.
#
# Pre-existing code — but before ops#385 it only failed to APPLY A HOLD, and now
# a bot merges on it. Same defect, opposite consequence.
################################################################################

@test "RED-PROOF (A2): a diff too big to read whole is CANNOT VERIFY, never 'in scope'" {
    _granted; _asbot
    # The cap is a knob so this needs 2 pages, not 3001 files (CLAUDE.md's
    # host-blind-branches rule: make the untestable path testable).
    export NWP_MR_DIFF_MAX_PAGES=1
    _mr_project(){ printf '9'; }
    # Page 1 is FULL (so the reader must go on); the sensitive path is on page 2.
    _mr_get(){
        local page="${1##*page=}"
        if [ "$page" = 1 ]; then
            { printf '['
              local i first=1
              for i in $(seq 1 100); do
                  [ $first -eq 1 ] || printf ','; first=0
                  printf '{"new_path":"pad/f%s.txt","old_path":"pad/f%s.txt"}' "$i" "$i"
              done
              printf ']'; }
        else
            printf '[{"new_path":".gitlab-ci.yml","old_path":".gitlab-ci.yml"}]'
        fi
    }
    run _mr_changed_files 9
    [ "$status" -eq 1 ] \
      || { echo "a TRUNCATED file list was reported as a complete one (rc $status) — the sensitive path was never seen"; false; }

    run _mr_merge_scope_ok 9
    [ "$status" -eq 2 ] \
      || { echo "expected 2 CANNOT VERIFY, got $status: $output"; false; }
    [[ "$output" == *"cannot-verify"* ]] || { echo "$output"; false; }

    run _mr_merge_actor_ok 9
    [ "$status" -eq 2 ] || { echo "a bot was allowed to merge an unreadable diff (rc $status)"; false; }
}

@test "NEGATIVE CONTROL (A2): a diff that fits IS read, and the cap does not fire" {
    # Without this, the case above would also pass if the reader simply refused
    # every paginated diff.
    _granted; _asbot
    export NWP_MR_DIFF_MAX_PAGES=1
    _mr_project(){ printf '9'; }
    _mr_get(){ printf '[{"new_path":"docs/x.md","old_path":"docs/x.md"}]'; }
    run _mr_changed_files 9
    [ "$status" -eq 0 ] || { echo "a short, complete diff was refused (rc $status)"; false; }
    [[ "$output" == *"docs/x.md"* ]]
    run _mr_merge_scope_ok 9
    [ "$status" -eq 0 ] || { echo "an ordinary in-scope MR was refused (rc $status): $output"; false; }
}
