#!/bin/bash
#
# pretooluse-raw-remote.sh — F4, the act-time raw-remote-idiom interceptor
# (ops#319, knowledge-honesty Tranche 0; spec: meta-pass2 §2.4, empirically
# proven viable in meta-pass3 §3 on harness 2.1.225, residue meta-pass4 R7).
#
# WHAT: a Claude Code PreToolUse hook (registered in the repo's
# .claude/settings.json, matcher "Bash"). It reads the PreToolUse JSON
# envelope on stdin and applies the SAME raw-remote-cli pattern class the
# doc-truth lint uses (lib/raw-remote-patterns.sh — one oracle, two
# consumers: doc-truth lints the docs, this hook lints the live command
# stream) to the command about to run. On a match it exits 2; the stderr
# text is fed back to the model as the deny reason, so the denial TEACHES
# the pl verb instead of just refusing.
#
# WHY act-time: CLAUDE.md's pl-first standing order already forbids these
# idioms, and the 2026-07-28 ops#149 deploy ran one anyway — knowledge decays
# with salience; a hook does not. PreToolUse hooks fire and block even under
# --dangerously-skip-permissions (observed, meta-pass3 §3), so this covers
# the autonomous agent-loop's exact mode.
#
# WHAT IT IS NOT: a sandbox against an adversarial AI. Evasion (bash -c,
# eval, base64) is out of scope by design — the threat model handles
# adversarial AI by architecture (the NWP-ADR-0017 offline-deploy-host
# boundary), not by hooks the AI can read. F4 is a seatbelt against habit.
#
# HEAD-TOKEN GUARD (meta-pass2 §2.4): the patterns are applied only to
# command segments whose executable position (first word of each &&/;/|/
# newline-separated segment, after env-assignment/wrapper stripping) is
# ssh/scp/sudo. A grep, echo or heredoc that merely MENTIONS the idiom is
# prose, not an act, and must pass. Segmentation is quote-aware and skips
# heredoc bodies. `pl`/`./pl` heads are by construction never matched — the
# sanctioned path cannot be blocked here.
#
# One deliberate strengthening carried over from doc-truth's own shape (b)
# rationale: if the command contains an ssh/scp-headed segment, the patterns
# are ALSO applied to that command's other segments (assignments), so
#   D="sudo -u www-data … drush …"; ssh host "$D updatedb -y"
# is caught. A gate that a shell variable defeats is a vacuous gate.
#
# LEDGERED OVERRIDE — never a silent one: NWP_RAW_REMOTE_OK='<why>' (in the
# hook's environment, or as a prefix inside the command itself) allows the
# command through AND appends when/mode/why/command to
# private/raw-remote-overrides.log (0600, created if absent). If the ledger
# cannot be written the override is REFUSED: an override that leaves no
# trace is not an override, it's a hole. The ledger doubles as "should this
# verb exist?" evidence.
#
# FAIL-CLOSED: an envelope this hook cannot parse is a deny (exit 2), never
# a quiet allow — the swallowed-verdict rule. The failure is loud by design;
# `--selftest` (the R7 pin, run by the bats suite in CI on every MR) catches
# a silently-broken pattern source before it disarms the gate.
#
# Exit codes: 0 allow · 2 deny (stderr → model). --selftest: 0 ok, 2 broken.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

deny() { printf '%s\n' "$*" >&2; exit 2; }

# shellcheck source=lib/raw-remote-patterns.sh
if ! source "$REPO_ROOT/lib/raw-remote-patterns.sh" 2>/dev/null \
   || [ -z "${RAW_REMOTE_CLI_REGEX:-}" ] || [ -z "${RAW_REMOTE_DEPLOY_REGEX:-}" ]; then
    deny "F4 raw-remote hook: cannot load lib/raw-remote-patterns.sh (the shared pattern source). Failing closed; fix the hook before running raw Bash. [ops#319]"
fi

# ---------------------------------------------------------------------------
# Segmentation: emit one executable segment per line. Splits on ; | & and
# newline OUTSIDE quotes; keeps quoted text inside its segment (so the
# payload of `ssh host 'sudo -u www-data drush cr'` stays attached to its
# ssh); skips heredoc bodies (a runbook being WRITTEN is prose, not an act).
# ---------------------------------------------------------------------------
segment_command() {
    awk '
    BEGIN { seg=""; sq=0; dq=0; inhd=0; hdtag=""; hdstrip=0; pending=0 }
    function flush() { if (seg ~ /[^ \t\n]/) print seg; seg="" }
    {
        if (inhd) {
            t=$0
            if (hdstrip) sub(/^\t+/,"",t)
            if (t==hdtag) inhd=0
            next
        }
        n=length($0); i=1
        while (i<=n) {
            c=substr($0,i,1)
            if (c=="\\" && !sq) { seg=seg c substr($0,i+1,1); i+=2; continue }
            if (c=="\047" && !dq) { sq=!sq; seg=seg c; i++; continue }
            if (c=="\"" && !sq)   { dq=!dq; seg=seg c; i++; continue }
            if (!sq && !dq) {
                if (c=="<" && substr($0,i+1,1)=="<" && substr($0,i+2,1)!="<") {
                    j=i+2; strip=0
                    if (substr($0,j,1)=="-") { strip=1; j++ }
                    while (substr($0,j,1) ~ /[ \t]/) j++
                    q=substr($0,j,1); tag=""
                    if (q=="\047" || q=="\"") {
                        j++
                        while (j<=n && substr($0,j,1)!=q) { tag=tag substr($0,j,1); j++ }
                        j++
                    } else {
                        while (j<=n && substr($0,j,1) ~ /[A-Za-z0-9_]/) { tag=tag substr($0,j,1); j++ }
                    }
                    if (tag!="") { hdtag=tag; hdstrip=strip; pending=1 }
                    seg=seg substr($0,i,j-i); i=j; continue
                }
                if (c==";" || c=="|" || c=="&") { flush(); i++; continue }
            }
            seg=seg c; i++
        }
        if (pending)      { pending=0; inhd=1; flush() }
        else if (sq||dq)  { seg=seg "\n" }        # quote spans lines: same segment
        else                flush()
    }
    END { flush() }'
}

# First word of a segment in executable position: leading whitespace, env
# assignments (VAR=val, VAR='v v', VAR="v v") and transparent wrappers
# stripped; basename'd so /usr/bin/ssh is still ssh. Quote-aware assignment
# stripping matters: NWP_RAW_REMOTE_OK='two words' ssh … must still expose
# ssh as the head token, or the override prefix would HIDE the idiom.
ASSIGN_RE="^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=('[^']*'|\"[^\"]*\"|[^[:space:]]*)"
head_token() {
    local seg="$1" tok
    while :; do
        if [[ "$seg" =~ $ASSIGN_RE ]]; then
            seg="${seg:${#BASH_REMATCH[0]}}"
            continue
        fi
        seg="${seg#"${seg%%[![:space:]]*}"}"
        [ -n "$seg" ] || return 0
        tok="${seg%%[[:space:]]*}"
        case "$tok" in
            command|builtin|exec|nohup|time|env) seg="${seg:${#tok}}" ;;
            *) break ;;
        esac
    done
    printf '%s' "${tok##*/}"
}

# ---------------------------------------------------------------------------
# Classify one command string. Prints "idiom-label<TAB>segment" for the first
# hit and returns 0; returns 1 when clean.
# ---------------------------------------------------------------------------
scan_command() {
    local cmd="$1" seg head has_remote=0
    local -a segs=() heads=()
    while IFS= read -r seg; do
        [ -n "$seg" ] || continue
        segs+=("$seg")
        head="$(head_token "$seg")"
        heads+=("$head")
        case "$head" in ssh|scp) has_remote=1 ;; esac
    done < <(printf '%s\n' "$cmd" | segment_command)

    local i
    for i in "${!segs[@]}"; do
        seg="${segs[$i]}"; head="${heads[$i]}"
        case "$head" in
            ssh|scp|sudo) ;;
            *) # assignments feeding a remote segment in the SAME command are
               # still the idiom (the alias trick); anything else is prose.
               [ "$has_remote" = 1 ] || continue ;;
        esac
        if [[ "$seg" =~ $RAW_REMOTE_CLI_REGEX ]]; then
            case "$seg" in
                *drush*) printf 'ssh/sudo + drush\t%s\n' "$seg" ;;
                *)       printf 'ssh/sudo + admin/cli\t%s\n' "$seg" ;;
            esac
            return 0
        fi
        if [[ "$seg" =~ $RAW_REMOTE_DEPLOY_REGEX ]]; then
            printf 'ssh + sudo file-write (scp/sudo-cp deploy)\t%s\n' "$seg"
            return 0
        fi
    done
    return 1
}

verb_for() {
    case "$1" in
        *drush*)     echo "  pl drush <site> --tier=live --execute -- <args>" ;;
        *admin/cli*) echo "  pl moodle cli <site> --tier=live --execute -- <script>" ;;
        *)           echo "  pl moodle plugin deploy <site> <plugin> --tier=live --apply   (--from=DIR is supported)
  # or the matching pl verb: pl deploy / pl server … — fix the verb if it does not fit" ;;
    esac
}

# ---------------------------------------------------------------------------
# --selftest — the R7 pin. Proves the pattern source loads and the classifier
# still classifies the canonical specimens, so a silently-broken hook goes
# red in CI (tests/unit/test-pretooluse-raw-remote.bats runs this) instead of
# silently disarming. A check that has never been proven to fail is not a
# check; this one's red is exercised in the bats suite.
# ---------------------------------------------------------------------------
selftest() {
    local pass=0 fail=0
    command -v jq >/dev/null 2>&1 && pass=$((pass+1)) || { echo "FAIL: jq not found"; fail=$((fail+1)); }
    must_block() {
        if scan_command "$1" >/dev/null; then pass=$((pass+1)); else echo "FAIL: not blocked: $1"; fail=$((fail+1)); fi
    }
    must_pass() {
        if scan_command "$1" >/dev/null; then echo "FAIL: wrongly blocked: $1"; fail=$((fail+1)); else pass=$((pass+1)); fi
    }
    must_block "ssh host 'sudo -u www-data php /var/www/nwc/vendor/bin/drush cr'"
    must_block "ssh host 'sudo -u www-data php admin/cli/purge_caches.php'"
    must_block "scp f host:/tmp/ && ssh host 'sudo cp /tmp/f /var/www/f'"
    must_pass  "./pl drush nwc --tier=live --execute -- cr"
    must_pass  'grep -rn "ssh.*drush" docs/'
    must_pass  "ssh host 'tail -n 200 /var/log/nginx/error.log'"
    echo "F4 raw-remote hook selftest: $pass OK, $fail FAIL"
    [ "$fail" -eq 0 ] || exit 2
    exit 0
}
[ "${1:-}" = "--selftest" ] && selftest

# ---------------------------------------------------------------------------
# Normal hook path: parse the PreToolUse envelope from stdin.
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
    || deny "F4 raw-remote hook: jq is required to parse the PreToolUse envelope and is not installed. Failing closed — install jq. [ops#319]"

envelope="$(cat)"
tool_name="$(jq -r '.tool_name // empty' <<<"$envelope" 2>/dev/null)" \
    || deny "F4 raw-remote hook: could not parse the PreToolUse JSON envelope. Failing closed. [ops#319]"
[ -n "$tool_name" ] \
    || deny "F4 raw-remote hook: PreToolUse envelope has no tool_name (malformed input). Failing closed. [ops#319]"
[ "$tool_name" = "Bash" ] || exit 0

cmd="$(jq -r '.tool_input.command // empty' <<<"$envelope")"
[ -n "$cmd" ] && [ "$cmd" != "null" ] || exit 0
permission_mode="$(jq -r '.permission_mode // "unknown"' <<<"$envelope")"

hit="$(scan_command "$cmd")" || exit 0
idiom="${hit%%$'\t'*}"
segment="${hit#*$'\t'}"

# ---------------------------------------------------------------------------
# Override: NWP_RAW_REMOTE_OK='<why>' — from the hook's env, or written as a
# prefix inside the command itself. Allowed ONLY if the reason is non-empty
# AND the ledger row lands.
# ---------------------------------------------------------------------------
reason="${NWP_RAW_REMOTE_OK:-}"
if [ -z "$reason" ]; then
    override_re="^[[:space:]]*NWP_RAW_REMOTE_OK=('([^']*)'|\"([^\"]*)\"|([^[:space:]]+))"
    if [[ "$cmd" =~ $override_re ]]; then
        reason="${BASH_REMATCH[2]:-}${BASH_REMATCH[3]:-}${BASH_REMATCH[4]:-}"
    fi
fi

if [ -n "$reason" ]; then
    ledger="${NWP_RAW_REMOTE_LEDGER:-${CLAUDE_PROJECT_DIR:-$REPO_ROOT}/private/raw-remote-overrides.log}"
    cmd_flat="${cmd//$'\n'/\\n}"
    if { mkdir -p "$(dirname "$ledger")" \
         && { [ -e "$ledger" ] || { : > "$ledger" && chmod 600 "$ledger"; }; } \
         && printf '%s\tmode=%s\tidiom=%s\treason=%s\tcmd=%s\n' \
                "$(date -Is 2>/dev/null || date)" "$permission_mode" "$idiom" "$reason" "$cmd_flat" >> "$ledger"; } 2>/dev/null; then
        exit 0
    fi
    deny "F4 raw-remote hook: NWP_RAW_REMOTE_OK was set but the override ledger ($ledger) could not be written. An override that leaves no trace is not an override — refusing. [ops#319]"
fi

# ---------------------------------------------------------------------------
# Deny — and teach. This text is fed back to the model as the reason.
# ---------------------------------------------------------------------------
deny "BLOCKED by the F4 raw-remote gate (ops#319): this Bash command runs the forbidden raw-remote idiom [$idiom]:
    ${segment:0:200}
Raw ssh/scp/sudo one-liners bypass every guarantee the pl verbs carry: the dry-run default, the typed live confirm, live.enabled, the NWP-ADR-0028 deploy gate, pair_guard, the fate manifest and the rollback ledger (CLAUDE.md standing order, 2026-07-28; recorded failure: ops#149). Use the pl verb instead:
$(verb_for "$idiom")
If the verb is broken or missing for your case, FIX THE VERB — that is the standing order, not a preference. If this exact raw command is genuinely necessary right now, re-run it with a ledgered override:
    NWP_RAW_REMOTE_OK='<why>' <your command>
(the reason and command are appended to private/raw-remote-overrides.log — an untraced override is a hole, not an override)."
