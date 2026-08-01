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

# demo_box_reset_status <site> → the box's own status block on stdout.
# rc: 0 = the box answered · 3 = could not look (never conflate with "no reset")
demo_box_reset_status() {
    local site="${1:?site required}"
    local out="" rc=0
    local keyfile="${HOME}/.ssh/${site}_demo_reset"

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
