#!/bin/bash
# lib/demo.sh — daily-reset demo tier: pure helpers (ops#133 Phase 1)
#
# Logic layer for `pl demo` (scripts/commands/demo.sh). Everything here is
# side-effect-light and unit-testable (tests/unit/test-demo.bats): no ddev, no
# drush, no cron — those live in the command script. Follows the
# lib/canonical.sh + scripts/commands/canonical.sh split.
#
# Design (DAILY-DEMO-TIER-PROPOSAL-2026-07-25 §2, decisions §4):
#   * Golden image  = verified DB dump + files tar + manifest + .sha256
#     sidecars under sites/<site>/demo-golden/.
#   * Invite codes  = hashed (sha256) at rest, NEVER plaintext. The local
#     registry sites/<site>/demo-codes.json is the source of truth (it
#     survives the nightly DB wipe); it is synced into the site's state
#     entry `nwc_demo_access.codes` after every change and every reset.
#     ONE WRITABLE HOME — see "Registry home" below (nwp/ops#173).
#   * --if-idle     = sessions-table last-activity check; "active" is a
#     DISTINCT exit code (3) so the nightly wrapper can retry.
#
# Fail-closed everywhere: unparseable input refuses, missing tools refuse.

# Distinct exit code for "someone is active — retry later" (NOT an error).
DEMO_EXIT_ACTIVE=3

# Distinct exit code for "the data WAS restored, but the site did not pass its
# post-restore smoke check" (nwp/ops#170).
#
# WHY IT HAS TO BE ITS OWN CODE. In the PAIRED path the two situations below
# demand opposite reactions, and a single `return 1` cannot tell them apart:
#   * the restore FAILED       ⇒ stop; the other half must not be touched;
#   * the restore SUCCEEDED but the site smoked red ⇒ CARRY ON to the other
#     half, because stopping now is what leaves nwd at one cut and ssd at
#     another — the exact mismatch the pair exists to prevent.
# The caller still surfaces a degraded half as an overall FAILURE; it just does
# so after both halves are on the same cut.
DEMO_EXIT_DEGRADED=4

# Role bundles (decisions §4.4). Must stay in sync with
# Drupal\nwc_demo_access\Service\DemoAccountFactory::BUNDLES in the nwc
# profile repo (modules/nwc_features/nwc_demo_access).
DEMO_BUNDLES=(
    tester-member
    tester-guild-leader
    tester-content-manager
    tester-copyright-reviewer
    tester-safeguarding-reviewer
)

# Reset window (decisions §4.3): fire 01:00 Australia/Melbourne, retry every
# 30 min while someone is active, give up (skip + log) at the 04:00 floor.
DEMO_TZ="Australia/Melbourne"
DEMO_RESET_TIME="01:00"
DEMO_FLOOR_TIME="04:00"
DEMO_RETRY_SECONDS=1800

################################################################################
# REGISTRY HOME — one writable copy, and it is the host that can deliver
# (nwp/ops#173)
#
# WHAT WENT WRONG. `sites/<site>/demo-codes.json` was per-host local state and
# nothing reconciled the copies. On 2026-08-01 the workstation held 24 entries /
# 3 active and the console host held 29 / 25 — a COMPLETELY DISJOINT set. Every
# code in the invitation the operator had actually sent hashed to an entry the
# workstation had never heard of. Worse, the console host could not ssh to the
# box at all (`Host key verification failed`), so the machine where codes were
# actually issued had no path by which a code could ever reach the site: it
# minted, rendered a beautiful invitation, reported success, and delivered
# nothing. The nightly then restored the box's staged payload — `{"codes":[]}`,
# staged long ago from the other host — over the top, so the live site held ZERO
# invite codes while the operator held five valid ones.
#
# THE MODEL NOW. Delivery capability IS write capability:
#
#   * The registry file stays where it is. Its ONE WRITABLE HOME, per tier, is
#     whichever host can prove it can deliver to that tier. On any other host
#     the same file is a READ-ONLY REPLICA: `list`/`status` read it, and every
#     mutating verb REFUSES before it mints anything (demo_require_delivery in
#     scripts/commands/demo.sh).
#   * A replica that cannot be written cannot diverge by accretion. That is the
#     whole fix for fault 1 — not a merge tool, not a sync daemon: remove the
#     second writer and there is nothing left to reconcile.
#   * This is deliberately NOT "give the console host a key to the box". The
#     console runs where no prod credentials live and that property is worth
#     more than the convenience of issuing from it. A host with no prod key is
#     simply not the registry's home, and now it says so out loud instead of
#     pretending.
#   * The THREE numbers that must agree — registry-active, site-live,
#     staged-payload — are recorded per host in private/demo-codes/<site>.json
#     and graded AMBER by `pl todo`/`pl rag` when they disagree (fault 3: all
#     three were readable the whole time; nothing was looking).
################################################################################

# The box's state dir, where install-box.sh --stage-codes puts the payload the
# nightly wrapper treats as authoritative. MUST match STATE_DIR in
# servers/live/demo/install-box.sh and the wrapper's own STATE_DIR.
demo_box_state_dir() { echo "/var/lib/nwp-demo/${1:?site required}"; }
demo_box_codes_payload() { echo "$(demo_box_state_dir "$1")/codes-payload.json"; }

# Where this host records what it last observed about a demo site's codes.
# Under private/ (gitignored) because it is an observation made BY THIS HOST —
# a record copied between hosts would be exactly the lie ops#173 is about.
demo_drift_dir()  { echo "${PROJECT_ROOT:?PROJECT_ROOT not set}/private/demo-codes"; }
demo_drift_file() { echo "$(demo_drift_dir)/${1:?site required}.json"; }

################################################################################
# yq resolution (nwp/ops#173 item 4)
#
# `command -v yq` was the guard on every domain lookup below. On the console
# host yq is at ~/.local/bin/yq, which systemd does not put on a user service's
# PATH — so the guard fell through, `live.domain` never resolved, and EVERY
# invitation the operator sent went out with <YOUR-SITE-URL>, <COMMUNITY-SITE>
# and <COURSES-SITE> placeholders where the links should have been. Nothing
# failed; the fallbacks exist precisely so the draft always renders.
#
# Two halves to the fix: `pl console deploy` now writes a PATH into
# ~/.config/nwp-console/env (so the service has one), and these helpers look in
# the usual user-local spots themselves (so they do not depend on it).
################################################################################
demo_yq() {
    # An EXPLICIT override is honoured or it FAILS — it is never silently
    # replaced by a different yq. Falling through used to mean that pointing
    # DEMO_YQ_BIN at a typo'd path ran some other binary than the one asked
    # for, which is the surprising direction for an override to fail in. It
    # also made "no yq is reachable" untestable on any host carrying
    # /usr/local/bin/yq (every CI runner), because the absolute-path sweep
    # below always found one — see tests/unit/test-demo.bats ops#173.4.
    if [[ -n "${DEMO_YQ_BIN:-}" ]]; then
        [[ -x "${DEMO_YQ_BIN}" ]] && { echo "$DEMO_YQ_BIN"; return 0; }
        return 1
    fi
    if command -v yq >/dev/null 2>&1; then echo yq; return 0; fi
    local c
    for c in "$HOME/.local/bin/yq" /usr/local/bin/yq /snap/bin/yq; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

################################################################################
# Paths
################################################################################

demo_site_dir() {
    local site="$1"
    echo "${PROJECT_ROOT:?PROJECT_ROOT not set}/sites/${site}"
}

# demo_golden_dir <site> [tier]
# The golden image is TIER-SCOPED: a local dev capture and a live capture are
# different images of different databases, and restoring one into the other
# would be a silent cross-tier clobber. dev|stg share sites/<site>/demo-golden
# (they are the same local pair and the Phase 1 layout); live gets its own
# sites/<site>/demo-golden-live. Called with one arg (legacy) → local dir.
demo_golden_dir() {
    local site="$1" tier="${2:-dev}"
    case "$tier" in
        live|prod) echo "$(demo_site_dir "$site")/demo-golden-live" ;;
        *)         echo "$(demo_site_dir "$site")/demo-golden" ;;
    esac
}
demo_codes_file()  { echo "$(demo_site_dir "$1")/demo-codes.json"; }
demo_log_file()    { echo "$(demo_site_dir "$1")/demo-reset.log"; }
demo_harvest_dir() { echo "$(demo_site_dir "$1")/demo-harvest"; }

################################################################################
# Logging — every reset / skip is a line in sites/<site>/demo-reset.log
################################################################################

# demo_log <site> <event> [detail...]
# Events: golden-captured reset-ok reset-failed skip-active skip-floor
#         codes-issued codes-revoked codes-rotated codes-synced
# DEMO_LOG_EXTRA — appended to EVERY line this process writes, when set.
# The paired live reset (nwp/ops#170) sets it to `pair=1 cut=<cut_id>` for the
# whole run, so a reader of sites/<site>/demo-reset.log can tell a half that was
# wiped as part of a bound pair from one wiped alone — including the lines the
# per-half code writes and knows nothing about the pair (harvest, skip-active,
# reset-manifest). Attribution by construction beats remembering to pass a flag.
demo_log() {
    local site="$1" event="$2"; shift 2 || true
    local file; file="$(demo_log_file "$site")"
    mkdir -p "$(dirname "$file")"
    local detail="$*"
    [[ -n "${DEMO_LOG_EXTRA:-}" ]] && detail="${detail:+${detail} }${DEMO_LOG_EXTRA}"
    printf '%s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$event" "$detail" >> "$file"
}

################################################################################
# Durations & clock helpers
################################################################################

# demo_parse_duration "30m" | "2h" | "14d" | "90s" → seconds on stdout.
# Fail-closed: anything unparseable returns 1 (callers must abort, not guess).
demo_parse_duration() {
    local raw="${1:-}"
    [[ "$raw" =~ ^([0-9]+)([smhd])$ ]] || return 1
    local n="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    case "$unit" in
        s) echo "$n" ;;
        m) echo $(( n * 60 )) ;;
        h) echo $(( n * 3600 )) ;;
        d) echo $(( n * 86400 )) ;;
        *) return 1 ;;
    esac
}

# demo_idle_ok <newest_activity_epoch> <window_seconds> [now_epoch]
# Returns 0 when the site is IDLE (no activity within the window) — safe to
# reset. Returns 1 when someone was active within the window.
# Fail-closed on garbage input: non-numeric activity → treated as ACTIVE
# (return 1) so a broken sessions query can never green-light a wipe.
demo_idle_ok() {
    local newest="${1:-}" window="${2:-}" now="${3:-$(date +%s)}"
    [[ "$newest" =~ ^[0-9]+$ ]] || return 1
    [[ "$window" =~ ^[0-9]+$ ]] || return 1
    [[ "$now"    =~ ^[0-9]+$ ]] || return 1
    (( now - newest >= window ))
}

# demo_past_floor <now_HH:MM> [floor_HH:MM]
# Returns 0 when the (site-local) time has reached the give-up floor.
# Only meaningful inside the 01:00→04:00 nightly window; the wrapper passes
# TZ=Australia/Melbourne time.
demo_past_floor() {
    local now="${1:-}" floor="${2:-$DEMO_FLOOR_TIME}"
    [[ "$now"   =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
    [[ "$floor" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
    [[ "${now/:/}" -ge "${floor/:/}" ]]
}

################################################################################
# Invite codes — hashed at rest, plaintext printed exactly once by the caller
################################################################################

demo_require_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    echo "ERROR: jq is required for the demo code registry (apt install jq)" >&2
    return 1
}

# demo_bundle_valid <bundle> — is this one of the sanctioned role bundles?
demo_bundle_valid() {
    local b="${1:-}" x
    for x in "${DEMO_BUNDLES[@]}"; do [[ "$x" == "$b" ]] && return 0; done
    return 1
}

# demo_generate_code → friendly high-entropy code, e.g. R7MKD-Q2XWH-9ZPBF-E4JTN
# Alphabet drops 0/O/1/I to stay transcribable; 20 chars ≈ 100 bits.
demo_generate_code() {
    local raw
    raw="$(LC_ALL=C tr -dc 'A-HJ-NP-Z2-9' < /dev/urandom | head -c 20)" || true
    [[ ${#raw} -eq 20 ]] || return 1
    echo "${raw:0:5}-${raw:5:5}-${raw:10:5}-${raw:15:5}"
}

# demo_hash_code <plaintext> → sha256 hex. Redemption hashes the submitted
# code the same way (PHP hash('sha256', $code)) — dashes/case significant.
demo_hash_code() {
    local code="${1:?code required}"
    printf '%s' "$code" | sha256sum | awk '{print $1}'
}

# demo_codes_init <file> — create an empty registry if absent (mode 0600:
# hashes are not secrets, but the registry is operational state).
demo_codes_init() {
    local file="${1:?file required}"
    [[ -f "$file" ]] && return 0
    mkdir -p "$(dirname "$file")"
    ( umask 077; printf '{"version":1,"codes":[]}\n' > "$file" )
}

# demo_code_add <file> <id> <bundle> <sha256-hash> <expires_epoch>
# Refuses unknown bundles, duplicate ids, and anything that smells like a
# plaintext code being stored (hash must be exactly 64 hex chars).
demo_code_add() {
    local file="$1" id="$2" bundle="$3" hash="$4" expires="$5"
    demo_require_jq || return 1
    demo_bundle_valid "$bundle" || {
        echo "ERROR: unknown bundle '$bundle' (valid: ${DEMO_BUNDLES[*]})" >&2
        return 1
    }
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || {
        echo "ERROR: refusing to store a non-sha256 value in the code registry" >&2
        return 1
    }
    [[ "$expires" =~ ^[0-9]+$ ]] || { echo "ERROR: bad expiry epoch '$expires'" >&2; return 1; }
    demo_codes_init "$file" || return 1
    if jq -e --arg id "$id" '.codes[] | select(.id == $id)' "$file" >/dev/null 2>&1; then
        echo "ERROR: code id '$id' already exists" >&2
        return 1
    fi
    local tmp="${file}.tmp.$$"
    jq --arg id "$id" --arg bundle "$bundle" --arg hash "$hash" \
       --argjson expires "$expires" --argjson created "$(date +%s)" \
       '.codes += [{id:$id, bundle:$bundle, hash:$hash, expires:$expires, created:$created, revoked:false}]' \
       "$file" > "$tmp" && mv "$tmp" "$file"
}

# demo_code_revoke <file> <id> — mark revoked (kept for the audit trail).
demo_code_revoke() {
    local file="$1" id="$2"
    demo_require_jq || return 1
    [[ -f "$file" ]] || { echo "ERROR: no code registry at $file" >&2; return 1; }
    jq -e --arg id "$id" '.codes[] | select(.id == $id)' "$file" >/dev/null 2>&1 || {
        echo "ERROR: no code with id '$id'" >&2
        return 1
    }
    local tmp="${file}.tmp.$$"
    jq --arg id "$id" '(.codes[] | select(.id == $id) | .revoked) = true' \
       "$file" > "$tmp" && mv "$tmp" "$file"
}

# demo_next_code_id <file> → c1, c2, … (monotonic, never reuses).
demo_next_code_id() {
    local file="$1" max=0
    if [[ -f "$file" ]] && demo_require_jq; then
        max=$(jq -r '[.codes[].id | ltrimstr("c") | tonumber? // 0] | max // 0' "$file" 2>/dev/null || echo 0)
        [[ "$max" =~ ^[0-9]+$ ]] || max=0
    fi
    echo "c$(( max + 1 ))"
}

# demo_active_bundles <file> → distinct bundles that have a live
# (non-revoked, non-expired) code. One per line.
demo_active_bundles() {
    local file="$1" now
    now="$(date +%s)"
    [[ -f "$file" ]] || return 0
    demo_require_jq || return 1
    jq -r --argjson now "$now" \
       '[.codes[] | select(.revoked == false and .expires > $now) | .bundle] | unique | .[]' \
       "$file" 2>/dev/null
}

# demo_codes_payload <file> → the compact JSON pushed into the site's state
# entry (nwc_demo_access.codes). Live codes only — no ids/audit fields, so a
# demo-tier DB leak reveals nothing about revoked history.
demo_codes_payload() {
    local file="$1" now
    now="$(date +%s)"
    demo_require_jq || return 1
    if [[ ! -f "$file" ]]; then
        printf '{"version":1,"codes":[]}'
        return 0
    fi
    jq -c --argjson now "$now" \
       '{version:1, codes:[.codes[] | select(.revoked == false and .expires > $now) | {bundle, hash, expires}]}' \
       "$file"
}

################################################################################
# Code DRIFT — the three numbers that must agree (nwp/ops#173 item 3)
#
# A code only works if it is present in all three places at once:
#
#   registry-active  sites/<site>/demo-codes.json, non-revoked + non-expired.
#                    What the operator believes they have handed out.
#   site-live        the running site's state entry nwc_demo_access.codes.
#                    What a tester's code is actually checked against TODAY.
#   staged-payload   /var/lib/nwp-demo/<site>/codes-payload.json on the box.
#                    What the nightly reset restores over the top at 01:00 —
#                    authoritative by design, so it decides what works TOMORROW.
#
# On 2026-08-01 those were 3, 25 and 0 across two hosts. Every one of them was a
# single command away the whole time and nothing compared them, so the live site
# served zero invite codes for an unknown number of nights while the operator
# was mailing out five. These helpers are pure so the comparison can be unit
# tested and then wired straight into `pl todo`/`pl rag` (check_demo_code_drift)
# rather than living in a parallel monitoring script.
#
# VOCABULARY for a count, and the distinction is load-bearing:
#   <n>  measured.
#   ""   COULD NOT TELL (host unreachable, drush silent). Never the same as 0 —
#        collapsing unknown into zero is the exact failure this issue is about.
#   "-"  NOT APPLICABLE at this tier (dev|stg have no box, so no staged payload).
################################################################################

# demo_codes_active_count <file> → live (non-revoked, non-expired) code count.
# A missing registry is 0 — the file genuinely holds no codes. A registry that
# exists but cannot be parsed is "" (unknown), not 0.
demo_codes_active_count() {
    local file="$1" now
    now="$(date +%s)"
    if [[ ! -f "$file" ]]; then echo 0; return 0; fi
    demo_require_jq >/dev/null 2>&1 || { echo ""; return 0; }
    local n
    n="$(jq -r --argjson now "$now" \
        '[.codes[] | select(.revoked == false and .expires > $now)] | length' \
        "$file" 2>/dev/null)" || n=""
    [[ "$n" =~ ^[0-9]+$ ]] || n=""
    echo "$n"
}

# demo_payload_count <json-text> → number of codes in a payload document.
# "" when the text is empty or not a payload. An EMPTY payload ({"codes":[]})
# is 0 and must read as 0: that is precisely what was on the box, and it is a
# finding, not a missing measurement.
demo_payload_count() {
    local doc="${1:-}"
    [[ -n "${doc//[[:space:]]/}" ]] || { echo ""; return 0; }
    demo_require_jq >/dev/null 2>&1 || { echo ""; return 0; }
    local n
    n="$(printf '%s' "$doc" | jq -r 'if (.codes | type) == "array" then (.codes | length) else empty end' 2>/dev/null)" || n=""
    [[ "$n" =~ ^[0-9]+$ ]] || n=""
    echo "$n"
}

# demo_drift_state <registry> <site_live> <staged> → "<state>|<detail>"
#
# states: ok | drift | unknown  (drift beats unknown — a proven disagreement is
# more actionable than a missing reading, and we already know something is wrong)
demo_drift_state() {
    local reg="${1:-}" live="${2:-}" staged="${3:-}"
    local -a nums=() names=() unknowns=()
    local i v n
    local pairs=("registry:$reg" "site:$live" "staged:$staged")
    for i in "${pairs[@]}"; do
        n="${i%%:*}"; v="${i#*:}"
        [[ "$v" == "-" ]] && continue                     # not applicable here
        if [[ "$v" =~ ^[0-9]+$ ]]; then
            nums+=("$v"); names+=("$n")
        else
            unknowns+=("$n")
        fi
    done

    # Disagreement first.
    local base="" mismatch=""
    for ((i=0; i<${#nums[@]}; i++)); do
        if [[ -z "$base" ]]; then base="${nums[$i]}"; continue; fi
        [[ "${nums[$i]}" != "$base" ]] && mismatch="yes"
    done
    local shown=""
    for ((i=0; i<${#names[@]}; i++)); do shown+="${names[$i]}=${nums[$i]} "; done
    for ((i=0; i<${#unknowns[@]}; i++)); do shown+="${unknowns[$i]}=? "; done
    shown="${shown% }"

    if [[ -n "$mismatch" ]]; then
        echo "drift|${shown}"
        return 0
    fi
    if (( ${#unknowns[@]} > 0 )); then
        echo "unknown|${shown}"
        return 0
    fi
    if (( ${#nums[@]} == 0 )); then
        echo "unknown|nothing measurable"
        return 0
    fi
    echo "ok|${shown}"
}

# demo_drift_record <site> <tier> <registry> <site_live> <staged> [host]
# Renders the observation record on stdout (the caller places it). Unknown
# counts are JSON null, "-" is the string "n/a" — the reader must be able to
# tell "I could not look" from "there is nothing here to look at".
demo_drift_record() {
    local site="$1" tier="$2" reg="$3" live="$4" staged="$5" host="${6:-$(hostname -s 2>/dev/null || echo unknown)}"
    local verdict; verdict="$(demo_drift_state "$reg" "$live" "$staged")"
    # The tier travels with the numbers: "site=25" means nothing until you know
    # WHICH site was asked, and a dev-tier reading must never be mistaken for
    # evidence about the live one.
    verdict="${verdict%%|*}|tier=${tier} ${verdict#*|}"
    _demo_json_num() {
        case "${1:-}" in
            -)              printf '"n/a"' ;;
            ''|*[!0-9]*)    printf 'null' ;;
            *)              printf '%s' "$1" ;;
        esac
    }
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "site": "%s",\n' "$site"
    printf '  "tier": "%s",\n' "$tier"
    printf '  "host": "%s",\n' "$host"
    printf '  "checked_utc": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  "checked_epoch": %s,\n' "$(date +%s)"
    printf '  "registry_active": %s,\n' "$(_demo_json_num "$reg")"
    printf '  "site_live": %s,\n' "$(_demo_json_num "$live")"
    printf '  "staged_payload": %s,\n' "$(_demo_json_num "$staged")"
    printf '  "verdict": "%s",\n' "${verdict%%|*}"
    printf '  "detail": "%s"\n' "${verdict#*|}"
    printf '}\n'
    unset -f _demo_json_num
}

# demo_drift_report <record_file> [max_age_seconds] [now_epoch] → "<state>|<detail>"
#
# The todo/RAG-facing evaluation of a record on disk. States:
#   missing  no record — THIS HOST HAS NEVER LOOKED. Not clean; it is the exact
#            state that let a live site serve zero codes unnoticed.
#   stale    a record, but older than the window; the numbers are history.
#   drift / unknown / ok  as recorded.
demo_drift_report() {
    local file="${1:-}" max_age="${2:-172800}" now="${3:-$(date +%s)}"
    if [[ ! -s "$file" ]]; then
        echo "missing|no record at ${file}"
        return 0
    fi
    demo_require_jq >/dev/null 2>&1 || { echo "unknown|jq unavailable, cannot read ${file}"; return 0; }
    local checked verdict detail
    checked="$(jq -r '.checked_epoch // empty' "$file" 2>/dev/null)"
    verdict="$(jq -r '.verdict // empty'       "$file" 2>/dev/null)"
    detail="$(jq  -r '.detail  // empty'       "$file" 2>/dev/null)"
    [[ "$checked" =~ ^[0-9]+$ ]] || { echo "unknown|unreadable record at ${file}"; return 0; }
    [[ -n "$verdict" ]] || { echo "unknown|record at ${file} carries no verdict"; return 0; }
    local age=$(( now - checked ))
    if (( age > max_age )); then
        echo "stale|last checked $(( age / 3600 ))h ago (${detail})"
        return 0
    fi
    echo "${verdict}|${detail}"
}

################################################################################
# Invitation email (pl demo invite) — pure rendering, unit-testable
################################################################################

# The community's public-facing name in the invitation. The demo tier is the
# Saint School pilot (ops#133); override via env for another community.
DEMO_INVITE_SITE_NAME="${DEMO_INVITE_SITE_NAME:-Saint School}"

# demo_invite_join_url <site> → "https://<live.domain>/demo/join" read from
# sites/<site>/.nwp.yml, or a visible placeholder when the domain (or yq)
# is unavailable. Never fails — the draft must always render.
demo_invite_join_url() {
    local site="$1" domain="" yml yqb
    yqb="$(demo_yq 2>/dev/null || true)"
    yml="$(demo_site_dir "$site")/.nwp.yml"
    if [[ -n "$yqb" && -f "$yml" ]]; then
        domain="$("$yqb" eval '.live.domain' "$yml" 2>/dev/null || true)"
        [[ "$domain" == "null" ]] && domain=""
    fi
    # Fall back to the global nwp.yml. The per-site sites/<site>/.nwp.yml does
    # not exist on a host that carries no sites tree — notably the console
    # host, which is exactly where `pl demo invite` runs when the operator
    # clicks the button. Without this the invite email showed the
    # <YOUR-SITE-URL> placeholder instead of the real join link.
    if [[ -z "$domain" && -n "$yqb" ]]; then
        local gcfg="${PROJECT_ROOT:-$HOME/nwp}/nwp.yml"
        if [[ -f "$gcfg" ]]; then
            domain="$(SITE="$site" "$yqb" eval '.sites[strenv(SITE)].live.domain // ""' "$gcfg" 2>/dev/null || true)"
            [[ "$domain" == "null" ]] && domain=""
        fi
    fi
    if [[ -n "$domain" ]]; then
        echo "https://${domain}/demo/join"
    else
        echo "<YOUR-SITE-URL>/demo/join"
    fi
}

# demo_invite_community_base <site> — the https base of the community site
# (the join URL minus /demo/join), or "" if it could not be resolved.
demo_invite_community_base() {
    local ju; ju="$(demo_invite_join_url "$1")"
    [[ "$ju" == https://* ]] || { echo ""; return 0; }
    echo "${ju%/demo/join}"
}

# demo_invite_pair_contract <site> — the demo pair contract naming <site> as
# PROVIDER (demo.enabled: true), or "" when there is none. The email reads two
# member-facing facts from it: which site is the courses half, and what the
# SSO button there is called.
demo_invite_pair_contract() {
    local site="$1" f prov demo yqb
    yqb="$(demo_yq 2>/dev/null)" || { echo ""; return 0; }
    local pairs_dir="${NWP_PAIR_CONTRACT_DIR:-${PROJECT_ROOT:-$HOME/nwp}/pairs}"
    for f in "$pairs_dir"/*.pair-contract.yml; do
        [[ -f "$f" ]] || continue
        prov="$("$yqb" eval '.provider // ""' "$f" 2>/dev/null)"
        demo="$("$yqb" eval '.demo.enabled // false' "$f" 2>/dev/null)"
        [[ "$prov" == "$site" && "$demo" == "true" ]] && { echo "$f"; return 0; }
    done
    echo ""
}

# demo_invite_sso_button_label <community-site> — the EXACT text on the courses
# site's SSO login button, read from the contract's oidc.issuer_name (the one
# declared source of that label; the wire script puts the same value on the
# live button). The email must name the button verbatim — "click the button X"
# with the wrong X is precisely the broken promise the smoke verb's A10 check
# exists to catch. Empty when there is no demo pair contract.
demo_invite_sso_button_label() {
    local c v yqb
    c="$(demo_invite_pair_contract "$1")"
    [[ -n "$c" ]] || { echo ""; return 0; }
    yqb="$(demo_yq 2>/dev/null)" || { echo ""; return 0; }
    v="$("$yqb" eval '.oidc.issuer_name // ""' "$c" 2>/dev/null)"
    [[ "$v" == "null" ]] && v=""
    echo "$v"
}

# demo_invite_courses_url <community-site> — the login page of the paired demo
# COURSES site (Moodle), where the tester clicks the SSO button. Resolved
# generically from the demo pair contract (provider == this site,
# demo.enabled). Empty when there is no demo pair or the consumer's domain is
# unresolvable — the email then simply omits the courses section.
demo_invite_courses_url() {
    local site="$1" consumer="" domain="" yml gcfg contract yqb
    yqb="$(demo_yq 2>/dev/null)" || { echo ""; return 0; }
    contract="$(demo_invite_pair_contract "$site")"
    [[ -n "$contract" ]] || { echo ""; return 0; }
    consumer="$("$yqb" eval '.consumer // ""' "$contract" 2>/dev/null)"
    [[ -n "$consumer" && "$consumer" != "null" ]] || { echo ""; return 0; }
    yml="$(demo_site_dir "$consumer")/.nwp.yml"
    [[ -f "$yml" ]] && { domain="$("$yqb" eval '.live.domain // ""' "$yml" 2>/dev/null)"; [[ "$domain" == "null" ]] && domain=""; }
    if [[ -z "$domain" ]]; then
        gcfg="${PROJECT_ROOT:-$HOME/nwp}/nwp.yml"
        [[ -f "$gcfg" ]] && { domain="$(CONS="$consumer" "$yqb" eval '.sites[strenv(CONS)].live.domain // ""' "$gcfg" 2>/dev/null)"; [[ "$domain" == "null" ]] && domain=""; }
    fi
    [[ -n "$domain" ]] && echo "https://${domain}/login/index.php" || echo ""
}

# demo_invite_level_label <bundle> → the plain-language block heading.
demo_invite_level_label() {
    case "$1" in
        tester-member)                echo "MEMBER TESTER" ;;
        tester-guild-leader)          echo "GUILD LEADER TESTER" ;;
        tester-content-manager)       echo "CONTENT MANAGER TESTER" ;;
        tester-copyright-reviewer)    echo "COPYRIGHT REVIEWER TESTER" ;;
        tester-safeguarding-reviewer) echo "SAFEGUARDING REVIEWER TESTER" ;;
        *)                            echo "TESTER" ;;
    esac
}

# demo_invite_level_block <bundle> <code>
# One self-contained, deletable block: heading, code, what this level is,
# 3-5 concrete things to try. Plain text / markdown-safe, no jargon.
demo_invite_level_block() {
    local bundle="$1" code="$2" cb="${3:-<COMMUNITY-SITE>}"
    local label; label="$(demo_invite_level_label "$bundle")"
    printf '──────── %s ────────\n\n' "$label"
    printf 'Your code:  %s\n\n' "$code"
    case "$bundle" in
        tester-member)
            cat <<BLOCK
This is the everyday member experience — what most people who join will see.

In the community you start as a SOJOURNER: the open, entry-level formation
guild everyone begins in. (Sojourners sit under the Theology Guild, the mature
guild you can grow into later.) The intention is that completing courses will
carry you upward through the guilds — that link is still being wired, so we'd
love to hear how you'd expect progression to feel.

Try these in the community — ${cb}
- Open the guilds index at /all-groups, join one, and look inside.
- Browse the activity stream at /explore.
- Open your profile and try the privacy and sharing choices — change them
  and see what it affects.
- See your Sojourner membership at /nwc/achievements.
- Do some of this on your phone — does it still feel easy?

Then try the courses (Step 2 above)
- Open the Saint School catalogue and start a course.
- Then tell us: would you expect finishing a course to move your community
  progress? (That connection is still being built — your instinct helps us.)
BLOCK
            ;;
        tester-guild-leader)
            cat <<BLOCK
Everything a member can do, plus the tools for someone who LEADS a guild.
You lead within the Tester's Guild — the guild every tester belongs to, whose
job is a careful editorial eye on the Saint School courses.

Try these in the community — ${cb}
- From /all-groups, enter your guild, then open its leader views: the guild
  dashboard, the leaderboard, and the verification / ratification queues.
  (Those queues start empty until someone completes work — do the
  work-queue items first, then come back to verify and ratify.)
- Look at member progress — you only see what members chose to share; check
  that boundary feels right.
- Post a welcome or announcement to the guild.
- Try managing who is in the guild.
BLOCK
            ;;
        tester-content-manager)
            cat <<BLOCK
The perspective of someone who writes and arranges the teaching material —
the craft side the Writers and Pedagogy guilds care for. Your editing
powers live on the community site only: on the courses side you browse as
an ordinary member.

Try these in the community — ${cb}
- Edit an existing page and save it.
- Create a brand-new piece of content.
- Rearrange the structure — move things around, change the order.
- Then look at your changes the way an ordinary member would see them.
BLOCK
            ;;
        tester-copyright-reviewer)
            cat <<BLOCK
The perspective of the Copyright Guild — checking that material used on the
site is properly cleared: licences, attribution, permissions. This is one
gate in the editorial pipeline; the Shepherds Guild gives the final sign-off.

Try these in the community — ${cb}
- Open the copyright clearance queue and look through what is waiting.
- Approve or decline an item and leave a note explaining why.
- Check what happens to the content after your decision.
BLOCK
            ;;
        tester-safeguarding-reviewer)
            cat <<BLOCK
IMPORTANT — this level only matters for the YOUTH side of Saint School.
Saint School is used by young people, and where a site serves minors the
community carries real child-safety duties: background checks, parental
consent, and handling any concern that gets reported. This does NOT apply to
the general community — it is specific to the youth-serving courses. You are
the person who works that review queue.

Try these in the community — ${cb}
- Work through the safeguarding items in the editorial review flow.
- Open the safeguarding check records at /admin/nwc/safeguarding/checks.
- Leave a review note and complete an item.
- Notice what is visible to you and what is kept private — does the boundary
  feel right? (You have the reviewer's view, not the full safeguarding admin
  console — that is a separate, higher role.)
BLOCK
            ;;
        *)
            printf 'Things to try: explore whatever this level unlocks.\n'
            ;;
    esac
    printf '\n'
}

# demo_invite_email <join_url> <expiry_days> <bundle=code>...
# Renders the COMPLETE copy-ready invitation email on stdout. Each level is
# a self-contained block the operator can delete before sending. Plain
# text / markdown-safe; warm, non-technical tone; no jargon.
demo_invite_email() {
    local join_url="$1" expiry_days="$2"; shift 2
    local pair bundle code site_arg="${DEMO_INVITE_PROVIDER_SITE:-nwd}"
    local community_base courses_url sso_label
    community_base="$(demo_invite_community_base "$site_arg")"
    courses_url="$(demo_invite_courses_url "$site_arg")"
    # The button's exact text, from the pair contract (never hardcoded here:
    # a hardcoded name is how the email came to promise a button that read
    # "nwd" while the live one read "Narrow Way Commons").
    sso_label="$(demo_invite_sso_button_label "$site_arg")"
    [[ -n "$sso_label" ]] || sso_label="<COMMUNITY-SITE-NAME>"

    cat <<INTRO
Subject: Would you help us test ${DEMO_INVITE_SITE_NAME}?

Hi!

Thank you so much for being willing to help. It takes about a minute to get
started, and you'll be trying two connected sites.

THE TWO SITES

${DEMO_INVITE_SITE_NAME} is a Catholic faith-formation project with two
halves that work together, joined by a single sign-in:

  1. THE COMMUNITY — Narrow Way Commons. Guilds (small communities to walk
     with), your profile and privacy choices, the activity stream, and the
     place to report anything that feels off. This is where you join.

  2. THE COURSES — Saint School itself, where the actual formation courses
     live. You reach it from the community with the SAME sign-in — no second
     account and no second password.

We're getting both ready for real members, and before we open the doors we
need friendly humans to try to break them.

WHAT WE'RE ASKING

Spend 20-60 minutes clicking around as if you were a real member — on BOTH
halves. Try the things your level unlocks (below). And whenever anything is
broken, confusing, or just feels wrong — even slightly — report it (the two
ways are listed below) and tell us in a sentence or two. Every report goes
straight into our fix queue. There are no silly reports; "this confused me"
is exactly what we need to hear.

COMPLETELY SAFE, COMPLETELY PRIVATE

Both sites are practice copies. The whole thing is ERASED EVERY NIGHT
at 1am Melbourne time — everything anyone did that day is wiped. You never
enter your email or your real name; the site gives you a saint's name to use
instead. Nothing about you is kept. So please: poke at everything, break
anything you like — that is genuinely the point.

HOW TO GET IN

STEP 1 — Join the community:
  1. Open:  ${join_url}
  2. Paste YOUR code (from your section below).
  3. First you'll meet a short discernment page — the examen — asking
     whether now is truly the right time; answer honestly, and it either
     carries you straight on or asks you to come back when you're free.
  4. You're in — you'll land on the community home.

STEP 2 — Walk into the courses (whenever you like):
  1. Open:  ${courses_url:-<COURSES-SITE>/login}
  2. Under the heading "Log in using your account on:", click the button
     "${sso_label}".
  3. You're now in Saint School with the same identity — browse the courses
     and start one. (There's no code box on the courses site; it uses your
     community sign-in, not a code.)

WHERE TO REPORT PROBLEMS

On the community site, sign in and open:
  ${community_base:-<COMMUNITY-SITE>}/feedback/submit
On the courses site, use the floating "Report a problem" button you'll see
on its pages. Either way, one sentence is plenty.

INTRO

    for pair in "$@"; do
        bundle="${pair%%=*}"
        code="${pair#*=}"
        demo_invite_level_block "$bundle" "$code" "$community_base"
    done

    cat <<CLOSING
────────────────────────────────

Thank you — truly. This kind of unhurried, honest clicking-around is the
most valuable help we can get right now.

If you have any trouble at all (or the code doesn't work), just reply to
this email and I'll sort it out.

One last practical note: your code expires in ${expiry_days} days. The
site forgets everyone nightly, but your code keeps working until it
expires — so if you come back tomorrow, just join again with the same
code.

God bless,
CLOSING
}

################################################################################
# Pre-wipe error harvest (fail-OPEN by contract)
################################################################################

# demo_harvest <site> <tier> <collector-cmd> [args...]
#
# Runs the collector (anything that prints the site's error signals since the
# last reset — watchdog Error/Critical rows, PHP log tail) and, if it produced
# anything, writes ONE digest into sites/<site>/demo-harvest/ tagged with the
# labels `demo-tester,auto-harvest`. Testers only report what they notice; the
# harvest catches the errors they hit but didn't report — and it MUST run
# before the restore, because the wipe destroys watchdog.
#
# CONTRACT: this function ALWAYS returns 0. A failed harvest must NEVER block
# the nightly reset — it logs harvest-failed and gets out of the way. (This is
# the one deliberate fail-OPEN spot in the demo tier; everything destructive
# stays fail-closed.)
#
# Posting: Phase 1 spools locally. The nwd cutover wires the digest into a
# GitLab issue via the feedback fast-path token convention
# (.secrets.yml:gitlab.ops_note_token — never the root PAT); until then
# `pl demo status` + the spool dir surface unposted digests.
demo_harvest() {
    local site="${1:-}" tier="${2:-}"; shift 2 || true
    demo_harvest_as "$site" "$site" "$tier" "$@"
}

# demo_harvest_as <spool_site> <subject_site> <tier> <collector-cmd> [args...]
#
# As demo_harvest, but the digest is written into <spool_site>'s spool while
# being ABOUT <subject_site>. ops#133 Phase 2 uses this so the Moodle half's
# error signals land in the PROVIDER's spool: a paired reset then produces ONE
# nightly digest covering both halves instead of two issues that a triager has
# to correlate by timestamp. (The subject is named in the digest header and in
# the reset log, so nothing is lost by co-locating them.)
#
# Same fail-OPEN contract: ALWAYS returns 0.
demo_harvest_as() {
    local spool_site="${1:-}" subject="${2:-}" tier="${3:-}"; shift 3 || true
    [[ $# -gt 0 ]] || { demo_log "$spool_site" harvest-failed "subject=$subject reason=no-collector"; return 0; }
    local out rc=0
    out="$("$@" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        demo_log "$spool_site" harvest-failed "subject=$subject tier=$tier rc=$rc"
        return 0
    fi
    # Empty forms drush emits for "no rows": whitespace, [], {}.
    local trimmed="${out//[[:space:]]/}"
    if [[ -z "$trimmed" || "$trimmed" == "[]" || "$trimmed" == "{}" ]]; then
        demo_log "$spool_site" harvest-empty "subject=$subject tier=$tier"
        return 0
    fi
    local hdir spool ts
    hdir="$(demo_harvest_dir "$spool_site")"
    ts="$(date -u '+%Y%m%d-%H%M%S')"
    spool="${hdir}/harvest-${ts}.md"
    # Two halves harvested in the same second must not clobber each other.
    local n=2
    while [[ -e "$spool" ]]; do
        spool="${hdir}/harvest-${ts}-${n}.md"
        n=$(( n + 1 ))
    done
    if ! mkdir -p "$hdir" 2>/dev/null; then
        demo_log "$spool_site" harvest-failed "subject=$subject tier=$tier reason=mkdir"
        return 0
    fi
    {
        printf '## Demo-tier pre-wipe error harvest — %s (%s)\n\n' "$subject" "$tier"
        printf 'labels: demo-tester,auto-harvest\n'
        printf 'harvested_utc: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'Errors captured from the demo site immediately before the nightly wipe\n'
        printf '(the site log is destroyed by the restore — this digest is what survives).\n\n'
        printf '```\n%s\n```\n' "$out"
    } > "$spool" 2>/dev/null || {
        demo_log "$spool_site" harvest-failed "subject=$subject tier=$tier reason=write"
        return 0
    }
    demo_log "$spool_site" harvest-ok "subject=$subject tier=$tier file=$(basename "$spool")"
    return 0
}

################################################################################
# Pre-wipe TESTER-FEEDBACK sync (fail-OPEN by contract) — nwp/ops#161,
# interlocked with nwp/ops#140
#
# WHAT WAS BROKEN (ops#161). The nwc_feedback → GitLab sync was proven working
# on nwd, but nothing ran it for nwd on any schedule: the only */15 cron targets
# the real nwc, and the pre-wipe harvest above collects watchdog rows, not
# Feedback entities. So a tester's report filed through /feedback/submit was
# destroyed by the nightly golden restore before it could become an issue —
# unless a human remembered to drain it. The harvest is the safety net for
# errors nobody reported; it is not the channel for reports people DID file.
#
# WHY IT LIVES HERE, BESIDE THE HARVEST. The one moment at which "have we kept
# the tester's report?" is answerable is immediately before the wipe. Putting
# the sync on a separate schedule leaves a window in which a report can arrive
# after the last sync and before the restore; putting it in the reset closes
# that window by construction. Same placement, same contract as demo_harvest.
#
# THE ops#140 INTERLOCK — the reason this function is not three lines.
# GitLabSyncService used to interpolate "**Submitter:** <display name>" into
# the issue body, and the Moodle forwarder sent username + e-mail. GitLab is
# self-hosted but has a WIDER reader set than the member site, and appears in no
# RoPA. So switching this sync on against a site whose deployed code predates
# the ops#140 minimisation would switch ON a member-identity leak — the two
# issues were filed independently and neither referenced the other. Therefore:
# this function PROBES the deployed code and refuses to push from a site it
# cannot PROVE is minimised. "I could not look" is not "it is safe".
#
# The interlock is fail-CLOSED on the leak and fail-OPEN on the reset: a refusal
# is logged and returns 0. Losing one night of feedback is recoverable; copying
# member identity into a tracker is not.
#
# CONTRACT (identical to demo_harvest): ALWAYS returns 0. A failed sync must
# NEVER block or fail a reset. Callers use `|| true` as belt-and-braces against
# set -e. The outcome is in $DEMO_FEEDBACK_STATUS for the standalone verb, which
# DOES need an exit status.
################################################################################

# The drush command that owns the push, the classifier, the doctrine
# body-withholding and the agent-eligibility fence. This function never builds
# an issue body itself — that logic has exactly one home (nwc_feedback), and a
# second renderer here is how ops#140 would come back.
DEMO_FEEDBACK_SYNC_CMD="nwc-feedback:sync-to-gitlab"
DEMO_FEEDBACK_LIMIT="${DEMO_FEEDBACK_LIMIT:-100}"

# The sentinel the drush command prints when the pending set is empty. If this
# string ever changes upstream we fail OPEN on the probe (treat it as "might be
# pending") and let the real sync no-op — never the other way round.
DEMO_FEEDBACK_NONE_MARKER="No feedback items pending GitLab sync"

# ops#140 minimisation marker. buildIssueDescription() is the pure renderer that
# MR nwp/nwc!50 introduced; it does not exist on the pre-ops#140 service.
# renderIssueBody() is deliberately NOT the marker — it exists on both sides of
# the fix, so probing for it would always say "minimised".
DEMO_FEEDBACK_MIN_METHOD="buildIssueDescription"
DEMO_FEEDBACK_MIN_PROBE='echo method_exists(\Drupal::service("nwc_feedback.gitlab_sync"), "buildIssueDescription") ? "MINIMISED-OK" : "MINIMISATION-MISSING";'

# Set by demo_feedback_sync: ok | empty | refused | skipped | failed
DEMO_FEEDBACK_STATUS=""

# demo_feedback_redact <text> <secret>
# A token must not reach a log, a terminal or an issue body even when the tool
# that received it echoes it back in an error.
demo_feedback_redact() {
    local text="${1:-}" secret="${2:-}"
    if [[ -n "$secret" ]]; then
        text="${text//"$secret"/<redacted>}"
    fi
    printf '%s' "$(printf '%s' "$text" | sed -E 's/(--token[= ])[^[:space:]]+/\1<redacted>/g')"
}

# demo_feedback_token → the token on stdout, or 1 if there is none.
#
# gitlab.api_token is the NON-ADMIN group bot (group_9_bot / nwp-automation-dev,
# Developer) — the identity ops#161 verified the sync with. Not
# gitlab.ops_note_token: that one is walled to nwp/ops and cannot create an
# issue in nwp/nwc, which is where a classified feedback signal is routed.
# A dedicated gitlab.feedback_sync_token is honoured first if one is ever
# registered, so downscoping later needs no code change.
demo_feedback_token() {
    local f="${DEMO_FEEDBACK_SECRETS:-${SECRETS_FILE:-${PROJECT_ROOT:-}/.secrets.yml}}"
    [[ -s "$f" ]] || return 1
    local y; y="$(demo_yq)" || return 1
    local t
    t="$("$y" e '.gitlab.feedback_sync_token // .gitlab.api_token // ""' "$f" 2>/dev/null \
         | grep -v '^null$')" || return 1
    [[ -n "$t" ]] || return 1
    printf '%s' "$t"
}

# demo_feedback_minimised <runner> [runner-args...]
# 0 only when the DEPLOYED nwc_feedback provably carries the ops#140
# minimisation. Any other answer — including no answer — is 1.
demo_feedback_minimised() {
    local -a run=( "$@" )
    (( ${#run[@]} > 0 )) || return 1
    local out rc=0
    out="$("${run[@]}" php:eval "$DEMO_FEEDBACK_MIN_PROBE" 2>/dev/null)" || rc=$?
    (( rc == 0 )) || return 1
    [[ "$out" == *MINIMISED-OK* ]]
}

# demo_feedback_sync <site> <tier> <runner> [runner-args...]
#
# The RUNNER is an injected drush invoker, called as
#   "$runner" "${runner_args[@]}" <drush-arg>…
# so the dev path passes `demo_drush "$proj"` and the live path
# `demo_rdrush "$site"`. Injecting it is what makes this unit-testable offline
# and what keeps lib/demo.sh free of ddev and ssh.
#
# Set DEMO_FEEDBACK_DRY_RUN=true to probe and report without pushing.
demo_feedback_sync() {
    local site="${1:-}" tier="${2:-}"; shift 2 || true
    DEMO_FEEDBACK_STATUS="failed"
    if (( $# == 0 )); then
        demo_log "$site" feedback-sync-failed "tier=$tier reason=no-runner"
        return 0
    fi
    local -a run=( "$@" )
    local out rc=0

    # --- 1. Is anything pending? ---------------------------------------------
    # --dry-run needs NO token and makes no network call, so a night with no
    # tester activity never reads a secret at all.
    out="$("${run[@]}" "$DEMO_FEEDBACK_SYNC_CMD" --dry-run --limit=1 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        demo_log "$site" feedback-sync-failed "tier=$tier stage=probe rc=$rc"
        return 0
    fi
    if [[ "$out" == *"$DEMO_FEEDBACK_NONE_MARKER"* ]]; then
        DEMO_FEEDBACK_STATUS="empty"
        demo_log "$site" feedback-sync-empty "tier=$tier"
        return 0
    fi

    # --- 2. ops#140 INTERLOCK — minimised, or nothing leaves ------------------
    if ! demo_feedback_minimised "${run[@]}"; then
        DEMO_FEEDBACK_STATUS="refused"
        demo_log "$site" feedback-sync-refused "tier=$tier reason=minimisation-unverified"
        return 0
    fi

    if [[ "${DEMO_FEEDBACK_DRY_RUN:-false}" == "true" ]]; then
        DEMO_FEEDBACK_STATUS="ok"
        demo_log "$site" feedback-sync-dry-run "tier=$tier pending=yes minimised=yes"
        return 0
    fi

    # --- 3. Token (read only once there is something to send) -----------------
    local token=""
    token="$(demo_feedback_token)" || {
        DEMO_FEEDBACK_STATUS="skipped"
        demo_log "$site" feedback-sync-skipped "tier=$tier reason=no-token"
        return 0
    }

    # --- 4. Push through the module's own command ----------------------------
    # KNOWN EXPOSURE, stated rather than hidden: `--token=` puts the value in
    # the drush process's argv, so it is visible to `ps` for the life of the
    # call on a shared host. This is the estate's existing convention — the
    # sanctioned `pl drush` verb takes `--token` too and redacts it only from
    # what it PRINTS — and the identity is a non-admin Developer bot, so the
    # blast radius is bounded. It is not printed, not logged, and not written to
    # any file here; anything the tool echoes back is redacted below.
    rc=0
    out="$("${run[@]}" "$DEMO_FEEDBACK_SYNC_CMD" \
            "--limit=${DEMO_FEEDBACK_LIMIT}" "--token=${token}" 2>&1)" || rc=$?
    out="$(demo_feedback_redact "$out" "$token")"
    token=""
    if (( rc != 0 )); then
        demo_log "$site" feedback-sync-failed "tier=$tier stage=push rc=$rc"
        printf '%s\n' "$out"
        return 0
    fi
    local n
    n="$(printf '%s\n' "$out" | grep -c '\[OK\] feedback #' || true)"
    DEMO_FEEDBACK_STATUS="ok"
    demo_log "$site" feedback-sync-ok "tier=$tier synced=${n}"
    printf '%s\n' "$out"
    return 0
}

################################################################################
# Golden manifest
################################################################################

# demo_manifest_write <dir> <site> <db_basename> <files_basename> [pending_db_updates]
# Writes <dir>/golden.manifest.json. Assumes the .sha256 sidecars already
# exist next to the artifacts (written by the capture step).
#
# pending_db_updates is the capture-time attestation from the ops#226 gate:
#   "0"              the site owed no hook_update_N when this image was taken
#   "not-applicable" the gate does not cover this kind of site (Moodle)
#   "unknown"        the image predates the gate, or was written by something
#                    that does not run it — NOT a clean bill
# It is recorded so a reset can say which of those it is restoring.
demo_manifest_write() {
    local dir="$1" site="$2" db="$3" files="$4" pending="${5:-unknown}"
    local db_sha files_sha
    db_sha="$(awk '{print $1}' "${dir}/${db}.sha256" 2>/dev/null)" || true
    files_sha="$(awk '{print $1}' "${dir}/${files}.sha256" 2>/dev/null)" || true
    [[ "$db_sha" =~ ^[0-9a-f]{64}$ && "$files_sha" =~ ^[0-9a-f]{64}$ ]] || {
        echo "ERROR: manifest refused — missing/invalid .sha256 sidecars in $dir" >&2
        return 1
    }
    {
        printf '{\n'
        printf '  "type": "demo-golden",\n'
        printf '  "site": "%s",\n' "$site"
        printf '  "captured_utc": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '  "db_file": "%s",\n' "$db"
        printf '  "db_sha256": "%s",\n' "$db_sha"
        printf '  "files_file": "%s",\n' "$files"
        printf '  "files_sha256": "%s",\n' "$files_sha"
        printf '  "pending_db_updates": "%s"\n' "$pending"
        printf '}\n'
    } > "${dir}/golden.manifest.json"
}

# demo_golden_verify <dir> <site>
# Fail-closed pre-restore check: manifest exists, is for THIS site, and both
# artifacts pass `sha256sum -c` against their sidecars. Any failure → 1.
demo_golden_verify() {
    local dir="$1" site="$2"
    local manifest="${dir}/golden.manifest.json"
    demo_require_jq || return 1
    [[ -s "$manifest" ]] || { echo "ERROR: no golden manifest at $manifest — run 'pl demo golden $site' first" >&2; return 1; }
    jq -e . "$manifest" >/dev/null 2>&1 || { echo "ERROR: golden manifest is not valid JSON" >&2; return 1; }
    local msite; msite="$(jq -r '.site // empty' "$manifest")"
    [[ "$msite" == "$site" ]] || { echo "ERROR: golden manifest is for site '$msite', not '$site' — refusing" >&2; return 1; }
    local db files
    db="$(jq -r '.db_file // empty' "$manifest")"
    files="$(jq -r '.files_file // empty' "$manifest")"
    [[ -n "$db" && -n "$files" ]] || { echo "ERROR: golden manifest missing artifact names" >&2; return 1; }
    local f
    for f in "$db" "$files"; do
        [[ -f "${dir}/${f}" && -f "${dir}/${f}.sha256" ]] || {
            echo "ERROR: golden artifact or sidecar missing: ${dir}/${f}(.sha256)" >&2
            return 1
        }
        ( cd "$dir" && sha256sum -c "${f}.sha256" >/dev/null 2>&1 ) || {
            echo "ERROR: sha256 MISMATCH for ${f} — golden image corrupt, refusing to restore" >&2
            return 1
        }
    done
    return 0
}
