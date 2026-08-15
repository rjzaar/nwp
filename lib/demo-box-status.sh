#!/bin/bash
################################################################################
# lib/demo-box-status.sh — ask the BOX when it last reset itself (nwp/ops#198).
#
# WHY THIS FILE EXISTS
#   On a night when BOTH unattended demo resets ran perfectly — nwd at 15:00 and
#   ssd at 15:15, Melbourne — `pl demo status` reported "last reset 06:32".
#   It was not lying about its data. It was wrong about WHOSE data it was:
#
#     sites/<site>/demo-reset.log            written by THIS checkout,
#                                            space-separated, dev workstation
#     /var/log/nwp-demo/<site>-demo-reset.log written by the box wrapper,
#                                            PIPE-separated, on the server
#     /var/lib/nwp-demo/<site>/last-reset     the box's idempotence stamp
#
#   `cmd_status` read only the first, through `demo_log_file`, which — unlike
#   its sibling `demo_golden_dir` — ignores the tier entirely. So at
#   `--tier=live` it showed the last time a HUMAN ran a reset from this laptop
#   and presented it as the site's last reset. Nothing in scripts/ or lib/
#   referenced /var/log/nwp-demo at all.
#
#   06:32 was a true fact about the wrong machine. That is the worst kind of
#   monitoring output, because it looks like an answer.
#
# WHAT THIS DOES
#   Asks the box, over the SAME read-only restricted-key route the nightly cron
#   already uses (`<site>-demo-reset-restricted status` — an action word the
#   shipped wrapper already implements and which only reads). No box writes, no
#   new credential, no new surface.
#
# THE DISTINCTION THAT MATTERS
#   Three outcomes, never collapsed into two:
#     rc 0 + a stamp   the box reset, and here is when
#     rc 0 + "none"    the box has NEVER reset — a real, honest negative
#     rc 3             COULD NOT LOOK (no key, ssh failed, timed out)
#   rc 3 is not "no reset". Reporting "no resets logged" because the ssh failed
#   is precisely how a silent nightly failure would stay silent.
################################################################################

# How long to wait on the box before giving up and saying so.
: "${DEMO_BOX_STATUS_TIMEOUT:=25}"

# ops#329 D4: the return leg fires HOURLY (met's cron at :07 over the
# restricted key), so a newest feedback-status event older than TWO cycles
# means the leg has stopped and nobody has said so. Beyond this age the
# reading is CANNOT VERIFY (stale return leg), never quietly green.
: "${DEMO_RETURN_LEG_MAX_AGE:=7200}"

# demo_box_is_status_block <raw> → 0 when this really is a `status` answer.
#
# ops#329 D6. The one field every consumer here needs is `last reset:`; the
# wrapper always prints it (as a stamp or as the literal `none`). Anything
# without it is not a status block, and the case that made this necessary was
# not a dialect but a DIFFERENT ANSWER: the box had run a nightly RESET and
# handed back its transcript. See demo_box_reset_status's rc 4.
demo_box_is_status_block() {
    printf '%s\n' "${1:-}" | grep -q '^[[:space:]]*last reset:'
}

# demo_box_reset_status <site> → the box's own status block on stdout.
# rc: 0 = the box answered with a status block
#     3 = could not look (no key, ssh refused, timed out) — never "no reset"
#     4 = the box ANSWERED, but not with a status block. Its words are still
#         printed so the caller can quote them. This is its own state because
#         it leads to its own action (redeploy the wrapper), and because the
#         one time it happened for real the box had been asked — by a
#         monitoring probe — to wipe a live site.
demo_box_reset_status() {
    local site="${1:?site required}"
    local out="" rc=0
    local keyfile="${HOME}/.ssh/${site}_demo_reset"

    # Testability seam (the CLAUDE.md host-blind rule: an ssh-only path is a
    # path no test can prove wrong). A file standing in for the box's status
    # output; an unreadable file is still rc 3 "could not look". Never set in
    # production.
    if [[ -n "${NWP_DEMO_BOX_STATUS_FILE:-}" ]]; then
        [[ -r "$NWP_DEMO_BOX_STATUS_FILE" ]] || return 3
        cat "$NWP_DEMO_BOX_STATUS_FILE"
        demo_box_is_status_block "$(cat "$NWP_DEMO_BOX_STATUS_FILE")" || return 4
        return 0
    fi

    # 1. The restricted key: the route the unattended cron itself uses. It is a
    #    forced command, so `status` is the ONLY thing this key can ask for.
    if [[ -r "$keyfile" ]] && declare -F demo_schedule_key_cmd >/dev/null 2>&1; then
        local sshcmd
        # DEMO_KEY_PATH is deliberately the LITERAL string `$HOME/.ssh/<site>_demo_reset`
        # because its main consumer is a crontab line, where the shell cron
        # spawns expands it. Running the same string directly does NOT re-expand
        # it: ssh gets `-i '$HOME/...'`, fails, and this probe silently fell
        # through to the admin path. Hand it the already-resolved path instead,
        # so we still inherit the hardened flag set (-F /dev/null,
        # IdentitiesOnly, IdentityAgent=none) from the one place that defines it.
        if sshcmd="$(DEMO_KEY_PATH="$keyfile" demo_schedule_key_cmd "$site" 2>/dev/null)" && [[ -n "$sshcmd" ]]; then
            out="$(timeout "$DEMO_BOX_STATUS_TIMEOUT" $sshcmd status 2>/dev/null)" || rc=$?
            if [[ "$rc" -eq 0 && -n "$out" ]]; then
                printf '%s\n' "$out"
                demo_box_is_status_block "$out" || return 4
                return 0
            fi
            rc=0
        fi
    fi

    # 2. Fall back to the ordinary admin path, exactly as `pl demo harvest
    #    --pull` does. Still read-only: the same `status` action word.
    if declare -F demo_live_ctx >/dev/null 2>&1 && declare -F demo_rssh >/dev/null 2>&1; then
        if demo_live_ctx "$site" >/dev/null 2>&1; then
            rc=0
            # The action word travels as a POSITIONAL argument here: sudo's
            # env_reset strips SSH_ORIGINAL_COMMAND, so there is nowhere else
            # to put it. Wrappers before ops#329 D6 read only the environment
            # variable, resolved this to the empty string, and ran a nightly
            # RESET. That is what rc 4 below exists to catch and name.
            out="$(demo_rssh "$site" \
                     "timeout ${DEMO_BOX_STATUS_TIMEOUT} sudo /usr/local/bin/${site}-demo-reset-restricted status" \
                     2>/dev/null)" || rc=$?
            if [[ "$rc" -eq 0 && -n "$out" ]]; then
                printf '%s\n' "$out"
                demo_box_is_status_block "$out" || return 4
                return 0
            fi
        fi
    fi

    return 3
}

# demo_box_last_reset <raw-status-output> → the stamp, or the literal "none".
#
# The wrapper prints `last reset:  <melbourne-date> <epoch>` (or `none`). Parsed
# rather than regex-guessed so a format change shows up as an empty result — and
# an empty result is reported as UNKNOWN by the caller, not as "never".
demo_box_last_reset() {
    printf '%s\n' "${1:-}" \
        | sed -n 's/^[[:space:]]*last reset:[[:space:]]*//p' \
        | head -1
}

# demo_box_log_tail <raw-status-output> [n] → the box log lines it echoed.
#
# The box block is `--- last 15 log lines ---` followed by PIPE-separated
# records: <ISO8601-UTC>|<event>|<detail>. Deliberately different from the local
# space-separated format, so a reader that confuses the two is obvious.
# The `|| true` is load-bearing, not cosmetic (ops#329 D6). Every caller runs
# under `set -euo pipefail`, where this helper's rc becomes the assignment's rc.
# A box whose log holds no PIPE records — a fresh box, a rotated log — made grep
# exit 1, and `pl demo status <site> --tier=live` died mid-render at exit 1 with
# the return-leg and backups blocks simply missing. An empty tail is a reading,
# not a failure; the states that ARE failures are rc 3 and rc 4 above.
demo_box_log_tail() {
    local raw="${1:-}" n="${2:-10}"
    printf '%s\n' "$raw" \
        | sed -n '/^--- last .* log lines ---$/,$p' \
        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\|' \
        | tail -n "$n" || true
}

# demo_box_reset_age_days <last-reset-string> → whole days since the stamp.
# Prints nothing when the stamp carries no epoch (so the caller says UNKNOWN).
demo_box_reset_age_days() {
    local s="${1:-}" epoch
    epoch="$(printf '%s\n' "$s" | grep -oE '[0-9]{9,}' | tail -1)"
    [[ -n "$epoch" ]] || return 1
    printf '%s' "$(( ( $(date +%s) - epoch ) / 86400 ))"
}

# ─────────────────────────────────────────────────────────────────────────────
# ops#329 D4/D5 — the return leg + the box's nightly pull backups, as carried
# by the wrapper's `status` word:
#
#   last_feedback_status: <utc>|feedback-status-<ok|failed|no-token>|<detail>
#   last_feedback_status: none                        (leg has never run)
#   last_feedback_status: CANNOT-VERIFY log-unreadable
#   backups: /var/backups/nwp-pull[ MISSING| UNREADABLE]
#   backup: <subdir>|newest=<file>|bytes=<n>|mtime=<utc>
#   backup: <subdir>|empty
#   backup: none                                      (dir exists, no subdirs)
#
# Parsed here — ONE parser for both consumers (`pl demo status` renders text,
# `pl demo seal-status --json` merges the JSON document), so the two surfaces
# cannot disagree about what the box said.
# ─────────────────────────────────────────────────────────────────────────────

# demo_box_feedback_status <raw-status-output> → the value after the label, or
# empty (= the deployed wrapper predates ops#329 D4: caller says NOT REPORTED).
demo_box_feedback_status() {
    printf '%s\n' "${1:-}" \
        | sed -n 's/^last_feedback_status: //p' \
        | head -1
}

# demo_box_backup_lines <raw-status-output> → the backups:/backup: lines only.
demo_box_backup_lines() {
    printf '%s\n' "${1:-}" | grep -E '^(backups|backup): ' || true
}

# demo_epoch_of_utc <iso8601> → epoch, or empty when unparseable.
demo_epoch_of_utc() {
    date -u -d "${1:-}" +%s 2>/dev/null || true
}

# demo_box_extras_by_design_json <provider> → the extras document for the pair
# CONSUMER, whose wrapper reports neither block ON PURPOSE.
#
# ops#329 D4/D5 gave the return leg and the backup census to the PROVIDER's
# wrapper only: the leg is a /my/feedback round trip that exists on nwd alone
# (ssd's wrapper REFUSES `feedback-status`, a pinned negative), and the pull
# dir is one box-level fact with one reporter. So on the consumer half these
# are not-applicable, not missing — and the generic "the deployed wrapper does
# not report … (redeploy)" reason is an instruction that can never come true.
#
# ONE builder because there are two consumers (`pl demo status` renders text,
# `pl demo seal-status --json` emits the document) and two hand-written copies
# of the same literal is exactly how two surfaces come to disagree.
demo_box_extras_by_design_json() {
    local provider="${1:-the pair provider}" raw="${2:-}"
    # ops#369 — TESTERS IS NOT ONE OF THE BY-DESIGN ABSENCES. The return leg
    # and the backup census genuinely belong to the provider, so the consumer
    # declaring them absent is correct. The UID-LOCK verdict does not: it is a
    # fact about THIS half's own user table, and the consumer is its only
    # reporter. Folding it into the by-design block would have hidden the one
    # tester-facing check the Moodle side actually owns.
    local tt='{"reported":false,"state":"not-read","reason":"this half'"'"'s box status was not read, so tester persistence is UNKNOWN"}'
    if [[ -n "$raw" ]]; then
        tt="$(demo_box_extras_json "$raw" | jq -c '.testers')"
    fi
    jq -cn --arg reason "reported by the pair provider (${provider}), not by this half" \
           --argjson tt "$tt" \
        '{feedback_status:{reported:false, by_design:true, reason:$reason},
          backups:        {reported:false, by_design:true, reason:$reason},
          testers:        $tt}'
}

# demo_box_extras_json <raw-status-output> → one JSON object on stdout:
#   {"feedback_status": {...}, "backups": {...}}
# Every shape is explicit — value / not-reported-with-reason / could-not-look —
# and staleness is computed HERE (age vs DEMO_RETURN_LEG_MAX_AGE) so a consumer
# that forgets to ask still carries the verdict.
demo_box_extras_json() {
    local raw="${1:-}" now; now="$(date +%s)"

    # ---- feedback_status ----------------------------------------------------
    local fb_json
    if [[ -z "$raw" ]]; then
        fb_json='{"reported":false,"reason":"could not read the box'\''s status word"}'
    else
        local fb_line; fb_line="$(demo_box_feedback_status "$raw")"
        if [[ -z "$fb_line" ]]; then
            fb_json='{"reported":false,"reason":"the deployed wrapper does not report the return leg (redeploy: bash servers/live/demo/install-box.sh <site> --no-key)"}'
        elif [[ "$fb_line" == "none" ]]; then
            fb_json='{"reported":true,"result":"none"}'
        elif [[ "$fb_line" == CANNOT-VERIFY* ]]; then
            fb_json='{"reported":true,"result":"unreadable"}'
        else
            local fb_ts="${fb_line%%|*}" fb_rest="${fb_line#*|}"
            local fb_event="${fb_rest%%|*}" fb_detail="${fb_rest#*|}"
            local fb_result
            case "$fb_event" in
                feedback-status-ok)       fb_result="ok" ;;
                feedback-status-failed)   fb_result="fail" ;;
                feedback-status-no-token) fb_result="no-token" ;;
                *)                        fb_result="$fb_event" ;;
            esac
            local fb_epoch fb_age="" fb_stale=false
            fb_epoch="$(demo_epoch_of_utc "$fb_ts")"
            if [[ -n "$fb_epoch" ]]; then
                fb_age=$(( now - fb_epoch ))
                (( fb_age > DEMO_RETURN_LEG_MAX_AGE )) && fb_stale=true
            fi
            local fb_adv="" fb_drafts="" fb_checked=""
            if [[ "$fb_detail" =~ advanced=([0-9]+)\ drafts_captured=([0-9]+)\ checked=([0-9]+) ]]; then
                fb_adv="${BASH_REMATCH[1]}"; fb_drafts="${BASH_REMATCH[2]}"; fb_checked="${BASH_REMATCH[3]}"
            fi
            fb_json="$(jq -cn --arg result "$fb_result" --arg ts "$fb_ts" \
                             --arg summary "$fb_detail" --arg age "$fb_age" \
                             --arg adv "$fb_adv" --arg drafts "$fb_drafts" \
                             --arg checked "$fb_checked" --argjson stale "$fb_stale" \
                '{reported:true, result:$result, ts:$ts, summary:$summary,
                  advanced:(($adv|tonumber?) // null),
                  drafts_captured:(($drafts|tonumber?) // null),
                  checked:(($checked|tonumber?) // null),
                  age_seconds:(($age|tonumber?) // null),
                  stale:$stale}')"
        fi
    fi

    # ---- backups ------------------------------------------------------------
    local bk_json
    if [[ -z "$raw" ]]; then
        bk_json='{"reported":false,"reason":"could not read the box'\''s status word"}'
    else
        local bk_head
        bk_head="$(printf '%s\n' "$raw" | sed -n 's/^backups: //p' | head -1)"
        if [[ -z "$bk_head" ]]; then
            bk_json='{"reported":false,"reason":"the deployed wrapper does not report the box backups (redeploy: bash servers/live/demo/install-box.sh <site> --no-key)"}'
        elif [[ "$bk_head" == *" MISSING" ]]; then
            bk_json="$(jq -cn --arg dir "${bk_head% MISSING}" \
                '{reported:true, state:"missing", dir:$dir}')"
        elif [[ "$bk_head" == *" UNREADABLE" ]]; then
            bk_json="$(jq -cn --arg dir "${bk_head% UNREADABLE}" \
                '{reported:true, state:"unreadable", dir:$dir}')"
        else
            local entries="[]" line sub rest newest bytes mtime mt_epoch mt_age
            while IFS= read -r line; do
                line="${line#backup: }"
                [[ "$line" == "none" ]] && continue
                sub="${line%%|*}"; rest="${line#*|}"
                if [[ "$rest" == "empty" ]]; then
                    entries="$(jq -c --arg sub "$sub" '. + [{subdir:$sub, empty:true}]' <<<"$entries")"
                    continue
                fi
                newest=""; bytes=""; mtime=""
                [[ "$rest" =~ newest=([^|]*) ]] && newest="${BASH_REMATCH[1]}"
                [[ "$rest" =~ bytes=([0-9]+) ]] && bytes="${BASH_REMATCH[1]}"
                [[ "$rest" =~ mtime=([^|]*) ]] && mtime="${BASH_REMATCH[1]}"
                mt_epoch="$(demo_epoch_of_utc "$mtime")"; mt_age=""
                [[ -n "$mt_epoch" ]] && mt_age=$(( now - mt_epoch ))
                entries="$(jq -c --arg sub "$sub" --arg newest "$newest" \
                                 --arg bytes "$bytes" --arg mtime "$mtime" --arg age "$mt_age" \
                    '. + [{subdir:$sub, newest:$newest,
                           bytes:(($bytes|tonumber?) // null),
                           mtime:$mtime,
                           age_seconds:(($age|tonumber?) // null)}]' <<<"$entries")"
            done < <(printf '%s\n' "$raw" | grep '^backup: ')
            bk_json="$(jq -cn --arg dir "$bk_head" --argjson entries "$entries" \
                '{reported:true, state:"ok", dir:$dir, entries:$entries}')"
        fi
    fi

    # ---- testers (ops#369) --------------------------------------------------
    # THE PROMISE THIS SURFACES: a tester can come back tomorrow with the
    # password they chose. Three separate facts, never collapsed into one — is
    # a roster staged, did last night's run actually carry the logins across,
    # and (consumer half) did anybody's Moodle identity fork. "No line at all"
    # was the old answer to all three, and silence is the one answer a tester
    # cannot act on: an unpreserved tester who believes they are preserved is
    # worse than a known gap.
    # THREE STATES, and the difference is not cosmetic. "I did not look"
    # (not-read) and "I looked and this wrapper is too old to answer"
    # (old-wrapper) lead to different actions: the second earns a redeploy
    # instruction, the first must never carry one — an instruction that cannot
    # be acted on truthfully is the ops#329 D6 defect, one block over.
    local tt_json
    if [[ -z "$raw" ]]; then
        tt_json='{"reported":false,"state":"not-read","reason":"this half'"'"'s box status was not read, so tester persistence is UNKNOWN"}'
    else
        local tt_reg tt_last tt_lock
        tt_reg="$(printf '%s\n' "$raw" | sed -n 's/^testers_registry: //p' | head -1)"
        tt_last="$(printf '%s\n' "$raw" | sed -n 's/^last_testers_preserved: //p' | head -1)"
        tt_lock="$(printf '%s\n' "$raw" | sed -n 's/^testers_uidlock: //p' | head -1)"
        if [[ -z "$tt_reg" && -z "$tt_last" && -z "$tt_lock" ]]; then
            tt_json='{"reported":false,"state":"old-wrapper","reason":"the deployed wrapper predates tester identity persistence (redeploy: bash servers/live/demo/install-box.sh <site> --no-key)"}'
        else
            # The verdict is the middle field of the persisted last-verdict line
            # (<utc>|<verdict>|<detail>). `none` means the leg has never run.
            local tt_verdict="none" tt_detail="" tt_ts="" _rest
            if [[ -n "$tt_last" && "$tt_last" != "none" ]]; then
                tt_ts="${tt_last%%|*}"; _rest="${tt_last#*|}"
                tt_verdict="${_rest%%|*}"; tt_detail="${_rest#*|}"
            fi
            # PRESERVED IS TRUE FOR EXACTLY ONE VERDICT. Every other value —
            # including the ones that sound harmless, like `exported` — means
            # some tester has to ask for a login again, so they must not render
            # as success. Fail-closed direction: an unrecognised verdict is not
            # preserved.
            local tt_preserved=false
            [[ "$tt_verdict" == "restored" ]] && tt_preserved=true
            tt_json="$(jq -cn --arg reg "$tt_reg" --arg verdict "$tt_verdict" \
                             --arg detail "$tt_detail" --arg ts "$tt_ts" \
                             --arg lock "$tt_lock" --argjson preserved "$tt_preserved" \
                '{reported:true, state:"ok", registry:$reg, verdict:$verdict, detail:$detail,
                  ts:(if $ts == "" then null else $ts end),
                  uid_lock:(if $lock == "" then null else $lock end),
                  preserved:$preserved}')"
        fi
    fi

    jq -cn --argjson fb "$fb_json" --argjson bk "$bk_json" --argjson tt "$tt_json" \
        '{feedback_status:$fb, backups:$bk, testers:$tt}'
}

# demo_box_human_age <seconds> → "34m" / "5h" / "3d" — for the text renderer.
demo_box_human_age() {
    local s="${1:-}"
    [[ "$s" =~ ^[0-9]+$ ]] || { printf '?'; return 0; }
    if   (( s < 3600 ));  then printf '%dm' $(( s / 60 ))
    elif (( s < 86400 )); then printf '%dh' $(( s / 3600 ))
    else                       printf '%dd' $(( s / 86400 ))
    fi
}
