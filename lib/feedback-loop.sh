#!/bin/bash
################################################################################
# lib/feedback-loop.sh — the tester-feedback closure: state model + guards.
#
# WHY THIS FILE EXISTS
#   A tester files feedback on the demo tier. It becomes a GitLab issue. A fix
#   is proposed as an MR. The operator approves it. It lands. It goes live. The
#   tester sees the outcome and either accepts it or reopens it.
#
#   Every one of those steps existed on 2026-08-02, and none of them were
#   joined up end to end:
#     * `nwc-feedback:sync-to-gitlab` pushes Drupal → GitLab every 15 min.
#     * `nwc-feedback:sync-status` reads GitLab → Drupal … and is scheduled
#       NOWHERE. So `/my/feedback` renders a local `status` column that no
#       process ever advances past `escalated`. The reporter-facing half is
#       built and starved.
#     * There is no operator approval verb at all.
#     * There is no record anywhere of WHICH COMMIT a live site runs, so
#       "merged" and "in force" are indistinguishable (ops#206).
#
#   This library holds the parts of that closure that are PURE — the state
#   derivation and the guards — so they are unit-testable without a forge, a
#   site, or a network. `scripts/commands/feedback.sh` is the I/O around them.
#
# THE ONE RULE THAT MATTERS MOST
#   `fb_autodeploy_phase_verdict` is the auto-deploy guard, and it keys on the
#   per-site CANONICAL PHASE (lib/canonical.sh, ops#33) — not on a site name,
#   not on a suffix, not on a second registry. Today every site in the estate
#   is `canonical: dev`, so the guard refuses nothing and IS INERT. It arms
#   itself the moment `pl canonical set <site> prod` runs, with no code change
#   and nobody having to remember. See tests/unit/test-feedback-loop.bats,
#   which proves it REFUSES on a fixture site marked prod — an inert guard that
#   has never been seen to fire is not a guard.
#
# FAIL-CLOSED VOCABULARY
#   Shared with lib/canonical.sh and lib/boundary.sh: "I could not look" is its
#   own answer and is never folded into "it is fine". A phase of
#   `cannot-verify:*` or `invalid:*` REFUSES.
################################################################################

# ── Labels (the GitLab-side vocabulary this loop reads and writes) ───────────
# Written by nwc_feedback's GitLabSyncService at issue creation:
FB_LABEL_FEEDBACK="feedback"
FB_LABEL_DEMO_TESTER="demo-tester"
FB_LABEL_NEEDS_HUMAN="needs-human"
# Written by a human promoting an item to the agent loop (the A14 boundary):
FB_LABEL_AGENT_ELIGIBLE="agent-eligible"
# Written by the agent loop:
FB_LABEL_PR_OPENED="pr-opened"
FB_LABEL_REFUSED_PREFIX="loop::refused"
# Written by `pl feedback approve` — the operator's recorded decision:
FB_LABEL_APPROVED_REVIEW="approved::review-first"
FB_LABEL_APPROVED_AUTO="approved::auto-merge"

# The two approval modes, exactly. `review` is the default everywhere.
FB_APPROVE_MODES="review auto"

# Rungs of the status ladder, in ascending order. Every rung is DERIVED at read
# time from the issue, the MR and the deploy record; none is stored, so none can
# go stale. (Same discipline as the console feedback-tab spec §10.1.)
FB_RUNGS="captured filed needs-human armed conflict refused mr-open held merged-not-deployed merged-deploy-unknown deployed? deployed closed-no-fix checked follow-up"

################################################################################
# fb_has_label <labels-csv> <label>
#   Exact membership in a comma-separated GitLab label list. Substring matching
#   would make `needs-human-review` satisfy `needs-human`, which is precisely
#   the direction a safety label must never fail in.
################################################################################
fb_has_label() {
    local csv="${1:-}" want="${2:-}" item
    [ -n "$want" ] || return 1
    local IFS=','
    for item in $csv; do
        item="${item#"${item%%[![:space:]]*}"}"   # ltrim
        item="${item%"${item##*[![:space:]]}"}"   # rtrim
        [ "$item" = "$want" ] && return 0
    done
    return 1
}

# fb_has_label_prefix <labels-csv> <prefix> — any label starting with <prefix>.
fb_has_label_prefix() {
    local csv="${1:-}" pfx="${2:-}" item
    [ -n "$pfx" ] || return 1
    local IFS=','
    for item in $csv; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        case "$item" in "$pfx"*) return 0 ;; esac
    done
    return 1
}

################################################################################
# fb_derive_rung <issue_state> <labels_csv> <mr_state> <mr_is_draft> \
#                <deploy_verdict> <local_status>
#
#   issue_state    opened | closed | none
#   labels_csv     the issue's labels
#   mr_state       opened | merged | closed | none
#   mr_is_draft    yes | no
#   deploy_verdict after | before | none | unknown   (see fb_deploy_verdict)
#   local_status   the nwc_feedback entity status, or "" if not consulted
#
# Prints one rung from FB_RUNGS. Always returns 0 — the rung IS the answer.
#
# Precedence is deliberate and is the whole state model:
#   1. What the REPORTER said last wins over everything. They are the judge.
#   2. A refusal by the loop is louder than any progress claim.
#   3. A contradiction between `needs-human` and `agent-eligible` is reported as
#      `conflict`, never silently resolved. Silently picking one is how a
#      needs-human item gets handed to an agent.
#   4. `deployed` is NEVER returned on merge alone. See fb_deploy_verdict.
################################################################################
fb_derive_rung() {
    local issue_state="${1:-none}" labels="${2:-}" mr_state="${3:-none}"
    local mr_draft="${4:-no}" deploy="${5:-unknown}" local_status="${6:-}"

    # 1. The reporter's own verdict is terminal.
    case "$local_status" in
        closed_poster_confirmed) echo "checked";   return 0 ;;
        follow_up)               echo "follow-up"; return 0 ;;
    esac

    # 2. A refusal outranks everything downstream of it.
    if fb_has_label_prefix "$labels" "$FB_LABEL_REFUSED_PREFIX"; then
        echo "refused"; return 0
    fi

    # 3. A contradiction is reported, not resolved.
    if fb_has_label "$labels" "$FB_LABEL_NEEDS_HUMAN" \
       && fb_has_label "$labels" "$FB_LABEL_AGENT_ELIGIBLE"; then
        echo "conflict"; return 0
    fi

    # 4. The MR half.
    case "$mr_state" in
        merged)
            case "$deploy" in
                after)   echo "deployed?" ;;
                before|none) echo "merged-not-deployed" ;;
                proven)  echo "deployed" ;;
                *)       echo "merged-deploy-unknown" ;;
            esac
            return 0 ;;
        opened)
            if [ "$mr_draft" = "yes" ]; then echo "held"; else echo "mr-open"; fi
            return 0 ;;
    esac

    # 5. The issue half.
    if [ "$issue_state" = "closed" ]; then echo "closed-no-fix"; return 0; fi
    if fb_has_label "$labels" "$FB_LABEL_AGENT_ELIGIBLE"; then echo "armed"; return 0; fi
    if fb_has_label "$labels" "$FB_LABEL_NEEDS_HUMAN";     then echo "needs-human"; return 0; fi
    if [ "$issue_state" = "opened" ]; then echo "filed"; return 0; fi
    echo "captured"
}

################################################################################
# fb_plain_rung <rung> — the sentence the REPORTER reads.
#
# Plain language, no jargon, and — this is the point — it never claims more than
# was proven. `merged-not-deployed` says so out loud rather than rendering a
# green tick, because "merged" reading as "fixed" is exactly the failure the
# estate keeps rediscovering (ops#206).
################################################################################
fb_plain_rung() {
    case "${1:-}" in
        captured)   echo "Received — not yet filed with the team" ;;
        filed)      echo "Received — with the team" ;;
        needs-human) echo "With a person (this one needs human judgement)" ;;
        armed)      echo "A fix is being drafted" ;;
        conflict)   echo "Needs attention — this item has contradictory routing labels" ;;
        refused)    echo "Needs a person — the automated helper stood down on this one" ;;
        mr-open)    echo "A fix is written and waiting for approval" ;;
        held)       echo "A fix is written and held for review" ;;
        merged-not-deployed)   echo "Fix approved — NOT on the site yet" ;;
        merged-deploy-unknown) echo "Fix approved — cannot confirm whether it is on the site yet" ;;
        "deployed?") echo "Fix approved and a deploy has run since — please check it" ;;
        deployed)   echo "Fixed and live — please check it" ;;
        closed-no-fix) echo "Closed without a code change — see the reply" ;;
        checked)    echo "You confirmed this is sorted" ;;
        follow-up)  echo "You reopened this — a follow-up is open" ;;
        *)          echo "Unknown" ;;
    esac
}

# fb_rung_is_terminal <rung> — 0 when nothing further will happen unprompted.
fb_rung_is_terminal() {
    case "${1:-}" in checked|closed-no-fix) return 0 ;; *) return 1 ;; esac
}

# fb_rung_needs_operator <rung> — 0 when a human must act for this to progress.
# Used by `pl feedback list --stuck` and by the (staged) Gotify event.
fb_rung_needs_operator() {
    case "${1:-}" in
        conflict|refused|mr-open|held|merged-not-deployed|merged-deploy-unknown|needs-human) return 0 ;;
        *) return 1 ;;
    esac
}

################################################################################
# THE AUTO-DEPLOY GUARD
#
# fb_autodeploy_phase_verdict <phase>
#   <phase> is whatever lib/canonical.sh's canonical_get_phase() returned.
#   Prints "allow" or "refuse:<reason>". Returns 0 for allow, 1 for refuse.
#
# WHAT IT REFUSES, AND WHEN IT STARTS REFUSING IT
#   Today (2026-08-02) every site in the estate reads `dev`, so this returns
#   `allow` for all of nwd, ssd, nwc and ss, and the guard is INERT. That is
#   correct: none of them is prod, and none holds real member data.
#
#   The condition that ARMS it is exactly one command:
#       pl canonical set <site> prod
#   which is how Phase 2 begins for a site (prod provisioned from `ver`, no AI,
#   real users). From that moment this function refuses that site, the
#   auto-deploy path goes quiet for it, and — because fb_autodeploy_allowed
#   prints the reason — the operator is told what stopped rather than finding
#   out later that a loop they relied on is no longer running.
#
#   Keying on the canonical phase rather than a site-name allowlist is the
#   whole design: a name list is a thing somebody must remember to edit on the
#   day it matters most, and the day it matters most is the day everybody is
#   busy doing the cutover.
################################################################################
fb_autodeploy_phase_verdict() {
    local phase="${1:-}"
    case "$phase" in
        dev|live)         echo "allow"; return 0 ;;
        prod)             echo "refuse:prod-phase"; return 1 ;;
        invalid:*)        echo "refuse:phase-unparseable"; return 1 ;;
        cannot-verify:*)  echo "refuse:phase-unreadable"; return 1 ;;
        "")               echo "refuse:phase-empty"; return 1 ;;
        *)                echo "refuse:phase-unknown"; return 1 ;;
    esac
}

# fb_autodeploy_refusal_text <verdict> — why, in the operator's words.
fb_autodeploy_refusal_text() {
    case "${1:-}" in
        refuse:prod-phase)
            echo "the site is canonical: prod — prod is provisioned from ver with no AI (Phase 2); automated deploys from this loop stop here by design" ;;
        refuse:phase-unparseable)
            echo "the site's canonical phase is present but not one of dev|live|prod — refusing rather than guessing" ;;
        refuse:phase-unreadable)
            echo "nwp.yml exists but could not be parsed — 'I could not look' is not 'it is fine'" ;;
        refuse:phase-empty|refuse:phase-unknown)
            echo "no canonical phase could be resolved for this site" ;;
        *) echo "unknown refusal" ;;
    esac
}

################################################################################
# fb_autodeploy_allowed <site> [nwp.yml path]
#   The wrapper the commands call. Needs lib/canonical.sh sourced (for
#   canonical_get_phase). Prints "allow" or "refuse:<reason>"; rc mirrors it.
################################################################################
fb_autodeploy_allowed() {
    local site="${1:-}" config="${2:-}"
    if ! declare -F canonical_get_phase >/dev/null 2>&1; then
        echo "refuse:no-phase-reader"; return 1
    fi
    local phase
    if [ -n "$config" ]; then phase="$(canonical_get_phase "$site" "$config")"
    else phase="$(canonical_get_phase "$site")"; fi
    fb_autodeploy_phase_verdict "$phase"
}

################################################################################
# fb_arm_verdict <labels_csv> <loop_killed:yes|no> <has_open_mr:yes|no>
#   May this feedback item be handed to the AGENT loop right now?
#   Prints "allow" or "refuse:<reason>"; rc mirrors it.
#
#   `needs-human` is the load-bearing refusal. GitLabSyncService applies it to
#   every tier-3 classification, and the agent loop's contract is that such an
#   item is written by a person. Arming it would hand a doctrine/safeguarding
#   judgement to a code generator. There is no --force for this: the operator's
#   route is to write the fix, or to re-classify the issue and remove the label
#   deliberately, which leaves a trace on the issue.
################################################################################
fb_arm_verdict() {
    local labels="${1:-}" killed="${2:-no}" has_mr="${3:-no}"
    if fb_has_label "$labels" "$FB_LABEL_NEEDS_HUMAN"; then
        echo "refuse:needs-human"; return 1
    fi
    if [ "$killed" = "yes" ]; then echo "refuse:loop-paused"; return 1; fi
    if [ "$has_mr" = "yes" ]; then echo "refuse:mr-already-open"; return 1; fi
    if fb_has_label "$labels" "$FB_LABEL_AGENT_ELIGIBLE"; then
        echo "refuse:already-armed"; return 1
    fi
    echo "allow"; return 0
}

fb_arm_refusal_text() {
    case "${1:-}" in
        refuse:needs-human)
            echo "this item carries 'needs-human' — a person writes this fix. Arming it would hand a tier-3 judgement to a code generator. Remove the label deliberately on the issue first if the classification is wrong." ;;
        refuse:loop-paused)
            echo "the agent loop is globally paused (.loop-paused / parts.state). Arming now would queue work nothing will pick up — resume with 'pl loop resume' first." ;;
        refuse:mr-already-open)
            echo "an MR is already open against this issue — the loop would refuse it anyway." ;;
        refuse:already-armed)
            echo "already armed (agent-eligible is present)." ;;
        *) echo "unknown refusal" ;;
    esac
}

################################################################################
# fb_approve_verdict <mode> <labels_csv> <mr_state> <mr_is_draft>
#   May the operator's approval of <mode> be applied to this item?
#   Prints "allow" or "refuse:<reason>"; rc mirrors it.
#
#   The two modes ARE the operator's ask, and nothing else is offered:
#     review — "I want to check it first."  The MR is HELD (pl mr hold → GitLab
#              Draft, which the forge itself enforces with a 405 on merge) and
#              the issue is labelled approved::review-first. This is the
#              DEFAULT, because the failure mode of the wrong default here is a
#              change reaching a live site nobody looked at.
#     auto   — "approve it; merge it when CI is green."  The hold is released
#              (pl mr release, which records the approver and binds the record
#              to the current head sha) and auto-merge is armed.
################################################################################
fb_approve_verdict() {
    local mode="${1:-}" labels="${2:-}" mr_state="${3:-none}" mr_draft="${4:-no}"
    case " $FB_APPROVE_MODES " in *" $mode "*) ;; *) echo "refuse:bad-mode"; return 1 ;; esac
    case "$mr_state" in
        none)   echo "refuse:no-mr"; return 1 ;;
        merged) echo "refuse:already-merged"; return 1 ;;
        closed) echo "refuse:mr-closed"; return 1 ;;
    esac
    if [ "$mode" = "review" ] && [ "$mr_draft" = "yes" ]; then
        echo "refuse:already-held"; return 1
    fi
    echo "allow"; return 0
}

fb_approve_refusal_text() {
    case "${1:-}" in
        refuse:bad-mode)       echo "mode must be 'review' (check it first) or 'auto' (merge on green)" ;;
        refuse:no-mr)          echo "there is no open merge request for this item yet — nothing to approve. Use 'pl feedback arm' to have a fix drafted, or write one." ;;
        refuse:already-merged) echo "the fix is already merged — approving it again would change nothing. Check whether it is DEPLOYED with 'pl feedback status'." ;;
        refuse:mr-closed)      echo "the merge request was closed without merging" ;;
        refuse:already-held)   echo "already held for your review — release it with 'pl feedback approve <ref> --mode=auto'" ;;
        *) echo "unknown refusal" ;;
    esac
}

################################################################################
# THE DEPLOY VERDICT — the honest half of "is it live?"
#
# fb_deploy_verdict <last_deploy_epoch> <merged_at_epoch>
#   Prints one of:
#     none    — no code deploy has EVER been recorded for this site
#     before  — the last recorded deploy predates the merge  ⇒ PROVABLY not live
#     after   — a deploy ran after the merge                 ⇒ necessary, not sufficient
#     unknown — one of the timestamps could not be read
#
# WHAT THIS CAN AND CANNOT PROVE, stated plainly because the difference is the
# whole reason this function is separate:
#   * `before`/`none` is a SOUND NEGATIVE. If no deploy has run since the merge,
#     the merged code cannot be on the site. This is the alarm that matters, and
#     it is the one that is cheap.
#   * `after` is NOT proof of presence. A deploy ran; whether it carried THIS
#     commit is unknowable from a timestamp. So the ladder renders `deployed?`,
#     never `deployed`.
#   * `deployed` (the rung) requires a commit-ancestry anchor — a deploy stamp
#     recording WHICH profile commit the site runs. private/deploys/<site>/
#     manifests record `nwp_sha` (the TOOL's commit), which is the wrong repo
#     for a fix that lands in the site profile. Adding `profile_sha` to the
#     manifest is the staged work; until it exists, `deployed` is unreachable by
#     construction and the ladder says so rather than rounding up.
################################################################################
fb_deploy_verdict() {
    local last="${1:-}" merged="${2:-}"
    case "$last" in ""|0) echo "none"; return 0 ;; esac
    case "$last$merged" in *[!0-9]*) echo "unknown"; return 0 ;; esac
    [ -n "$merged" ] || { echo "unknown"; return 0; }
    if [ "$last" -ge "$merged" ]; then echo "after"; else echo "before"; fi
}

################################################################################
# fb_last_deploy_epoch <site> [deploys_dir]
#   Newest stg2live manifest timestamp for <site>, as unix epoch, or "" if none.
#   Manifests are named  <action>-YYYYmmddTHHMMSSZ.json  by
#   canonical_deploy_manifest(). Only stg2live counts: dev2stg does not put code
#   on a live site.
################################################################################
fb_last_deploy_epoch() {
    local site="${1:-}" dir="${2:-${PROJECT_ROOT:-$HOME/nwp}/private/deploys}"
    local newest="" f base stamp
    [ -d "$dir/$site" ] || { echo ""; return 0; }
    for f in "$dir/$site"/stg2live-*.json; do
        [ -e "$f" ] || continue
        base="$(basename "$f" .json)"
        stamp="${base#stg2live-}"
        [ -n "$newest" ] && [ "$stamp" \< "$newest" ] && continue
        newest="$stamp"
    done
    [ -n "$newest" ] || { echo ""; return 0; }
    # 20260728T124622Z -> 2026-07-28T12:46:22Z
    local iso="${newest:0:4}-${newest:4:2}-${newest:6:2}T${newest:9:2}:${newest:11:2}:${newest:13:2}Z"
    date -u -d "$iso" +%s 2>/dev/null || echo ""
}

################################################################################
# fb_parse_issue_ref <ref>
#   Accepts the two shapes that exist in this estate and prints "<pid> <iid>":
#     16#42        the nwc_feedback entity's gitlab_issue_id field, verbatim
#     #42 / 42     bare iid, defaulting to project 16 (nwp/nwc) where every
#                  feedback issue is filed by GitLabSyncService::routeProject
#   Returns 1 on anything else. Refusing to guess is deliberate: an ambiguous
#   ref here would put an operator's approval on a different project's MR.
################################################################################
FB_DEFAULT_PROJECT_ID="${NWP_FEEDBACK_PROJECT_ID:-16}"

fb_parse_issue_ref() {
    local ref="${1:-}"
    case "$ref" in
        [0-9]*'#'[0-9]*)
            local pid="${ref%%#*}" iid="${ref##*#}"
            case "$pid$iid" in *[!0-9]*) return 1 ;; esac
            [ -n "$pid" ] && [ -n "$iid" ] || return 1
            printf '%s %s' "$pid" "$iid"; return 0 ;;
        '#'[0-9]*)
            local i="${ref#\#}"
            case "$i" in *[!0-9]*) return 1 ;; esac
            printf '%s %s' "$FB_DEFAULT_PROJECT_ID" "$i"; return 0 ;;
        [0-9]*)
            case "$ref" in *[!0-9]*) return 1 ;; esac
            printf '%s %s' "$FB_DEFAULT_PROJECT_ID" "$ref"; return 0 ;;
        *) return 1 ;;
    esac
}
