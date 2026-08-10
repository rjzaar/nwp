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

# demo_box_reset_status <site> → the box's own status block on stdout.
# rc: 0 = the box answered · 3 = could not look (never conflate with "no reset")
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
            if [[ "$rc" -eq 0 && -n "$out" ]]; then printf '%s\n' "$out"; return 0; fi
            rc=0
        fi
    fi

    # 2. Fall back to the ordinary admin path, exactly as `pl demo harvest
    #    --pull` does. Still read-only: the same `status` action word.
    if declare -F demo_live_ctx >/dev/null 2>&1 && declare -F demo_rssh >/dev/null 2>&1; then
        if demo_live_ctx "$site" >/dev/null 2>&1; then
            rc=0
            out="$(demo_rssh "$site" \
                     "timeout ${DEMO_BOX_STATUS_TIMEOUT} sudo /usr/local/bin/${site}-demo-reset-restricted status" \
                     2>/dev/null)" || rc=$?
            if [[ "$rc" -eq 0 && -n "$out" ]]; then printf '%s\n' "$out"; return 0; fi
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
demo_box_log_tail() {
    local raw="${1:-}" n="${2:-10}"
    printf '%s\n' "$raw" \
        | sed -n '/^--- last .* log lines ---$/,$p' \
        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\|' \
        | tail -n "$n"
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

    jq -cn --argjson fb "$fb_json" --argjson bk "$bk_json" \
        '{feedback_status:$fb, backups:$bk}'
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
