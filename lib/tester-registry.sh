#!/usr/bin/env bash
################################################################################
# lib/tester-registry.sh — THE TESTER REGISTRY
#
# WHAT IT IS
#   The authority for WHO SURVIVES THE NIGHTLY RESET on the demo pair. The
#   reset leg preserves exactly the accounts named here and wipes everything
#   else. One sentence for the whole access model:
#
#       APPROVAL IS THE PERSISTENCE DECISION — an unapproved join is a request
#       that never became an account, and an approved tester persists with
#       their own password.
#
#   Casual visitors therefore do not accumulate, and a tester the operator
#   approved keeps their login night after night.
#
# WHAT IT IS NOT
#   It is NOT a credential store. It holds identity only. The password hash the
#   reset leg restores is harvested from the live sites at capture time,
#   because the live DB is the only place the password the tester actually
#   chose exists — and because a hash at rest in a file this library writes
#   would be a credential this library became responsible for.
#
#   It is NOT where pending join requests live. Those are in the request store
#   (see lib/join-requests.sh), which the reset leg never reads. That is
#   fail-closed BY CONSTRUCTION rather than by a flag somebody has to remember
#   to filter on: a bug in this file cannot preserve an unapproved person,
#   because an unapproved person is not in this file at all.
#
# THE INTERFACE CONTRACT (agreed with the reset leg, 2026-08-16)
#   The file this library writes IS the payload the reset leg stages and reads.
#
#     home (this host):  sites/<site>/demo-testers.json                 0600
#     staged on the box: /var/lib/nwp-demo/<site>/testers-payload.json  0644
#
#     { "version": 1,
#       "generated_utc": "2026-08-16T01:23:45Z",
#       "site": "nwd",
#       "testers": [ { "account": "Benedict-0000", ... } ] }
#
#   REQUIRED per entry: `account` — the exact Drupal username, matching
#   TESTER_ACCOUNT_RE below. That is the ONLY field the reader requires.
#   Everything else this library writes (display_name, bundle, guild, level,
#   admin, source, request_id, approved_by, approved_at) is OPTIONAL and
#   IGNORED by the reader, which is what lets the console carry its own columns
#   in the same one file.
#
#   The reader's failure modes, which the writes here are shaped to avoid:
#     * payload unparseable / version != 1 / testers not an array
#         -> NOTHING is preserved and the reset run FAILS. Hence: this library
#            never writes a partial document, and refuses to overwrite a
#            registry it could not first read.
#     * one bad entry (bad name shape, or `approved:false`/`status:"pending"`)
#         -> that entry is refused and named; the run is degraded. Hence: the
#            account shape is validated HERE, and a pending row is
#            unrepresentable.
#     * payload absent -> WARN, nothing preserved, run not failed.
#
#   NO CACHING anywhere on either side: the reader opens the file fresh every
#   invocation. A tester approved at 23:59 is preserved at 01:00 the same
#   night — which is the requirement that made caching unacceptable.
#
#   STAGING IS PART OF APPROVAL. Writing this file on the registry home is not
#   enough; the reset leg reads the BOX copy. The approve path must re-stage
#   and must treat a staging failure as loudly as a registry failure.
#
# ONE WRITABLE HOME
#   Same declared-fact policy as the invite-code registry (ops#328 D1) and
#   deliberately the SAME declaration file, read through lib/demo.sh's
#   accessors rather than re-derived here — a policy expressed twice is a
#   policy that drifts. Writes refuse anywhere but the declared home; reads
#   work anywhere; an undeclared home fails writes CLOSED.
################################################################################

# The home-declaration accessors live in lib/demo.sh (ops#328 D1). Source it
# only if they are not already present, so this library is usable standalone
# (tests, and any future caller that does not want all of demo.sh).
if ! declare -f demo_registry_home_state >/dev/null 2>&1; then
    _TR_LIB_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
    [[ -n "$_TR_LIB_DIR" ]] || _TR_LIB_DIR="$PWD"
    # shellcheck source=lib/demo.sh
    source "${_TR_LIB_DIR}/demo.sh"
fi

################################################################################
# Shapes
################################################################################

# EXACTLY the reset leg's account regex. Not "close enough": a name this side
# accepts and that side refuses is a person who was told they were approved and
# is then named as a refused entry in a log nobody reads.
TESTER_ACCOUNT_RE='^[A-Za-z0-9][A-Za-z0-9_.@-]{0,79}$'

# The instant-tester bundles. Must stay in sync with DEMO_BUNDLES in
# lib/demo.sh and DemoAccountFactory::BUNDLES in the nwc profile.
#
# The apply-route bundles (apply-review, apply-auto) are DELIBERATELY ABSENT
# and are refused by name below. They are redeemed on the site's real /apply
# form, where the account is created by the registration provisioner on
# approval; letting one into the tester registry would assert that an
# applicant is a tester who must survive the reset.
TESTER_BUNDLES=(
    tester-member
    tester-guild-leader
    tester-content-manager
    tester-copyright-reviewer
    tester-safeguarding-reviewer
)

################################################################################
# Paths
################################################################################

# tester_registry_file <site> — the registry on THIS host.
tester_registry_file() {
    local site="${1:-}"
    if [[ -z "$site" ]]; then
        echo "ERROR: tester_registry_file requires a site" >&2
        return 1
    fi
    echo "${PROJECT_ROOT:?PROJECT_ROOT not set}/sites/${site}/demo-testers.json"
}

# The staged copy on the demo box — what the reset leg actually reads.
tester_registry_payload_path() {
    echo "/var/lib/nwp-demo/${1:?site required}/testers-payload.json"
}

################################################################################
# Validators
#
# Every one of these prints a NAMED reason. A validator that only returns
# non-zero produces the "blind negation" failure this repo keeps getting bitten
# by: the caller's test proves an exit code and nothing about which rule fired.
################################################################################

tester_valid_account() {
    local v="${1-}"
    if [[ -z "$v" ]]; then
        echo "ERROR: account name is empty — the registry addresses testers by their exact Drupal username" >&2
        return 1
    fi
    if (( ${#v} > 80 )); then
        echo "ERROR: account name is too long (${#v} chars, max 80) — refused rather than truncated, because a truncated name is a different account" >&2
        return 1
    fi
    if [[ ! "$v" =~ $TESTER_ACCOUNT_RE ]]; then
        echo "ERROR: '${v}' is not a valid account name — must start alphanumeric, then letters/digits/._@- only (this is EXACTLY the reset leg's shape; a name it refuses is a tester it silently will not preserve)" >&2
        return 1
    fi
    return 0
}

tester_valid_display() {
    local v="${1-}"
    if [[ -z "$v" ]]; then
        echo "ERROR: display name is empty — a tester the operator cannot recognise in the list is one they cannot manage" >&2
        return 1
    fi
    if (( ${#v} > 100 )); then
        echo "ERROR: display name is too long (${#v} chars, max 100)" >&2
        return 1
    fi
    # Control characters would break the JSON line and the console table; angle
    # brackets are refused at the door rather than escaped at every render.
    if [[ "$v" == *[[:cntrl:]]* ]]; then
        echo "ERROR: display name contains a control character (newline/tab) — refused" >&2
        return 1
    fi
    if [[ "$v" == *"<"* || "$v" == *">"* ]]; then
        echo "ERROR: display name contains markup characters (< or >) — refused at the door, not escaped at every render" >&2
        return 1
    fi
    return 0
}

tester_valid_bundle() {
    local v="${1-}" b
    for b in "${TESTER_BUNDLES[@]}"; do
        [[ "$v" == "$b" ]] && return 0
    done
    if [[ "$v" == apply-* ]]; then
        echo "ERROR: '${v}' is an /apply invite bundle, not a tester bundle — those are redeemed on the site's real application form and the account is created there on approval. Putting one in the tester registry would assert an applicant must survive the nightly reset." >&2
        return 1
    fi
    echo "ERROR: '${v}' is not a known tester bundle (one of: ${TESTER_BUNDLES[*]})" >&2
    return 1
}

tester_valid_level() {
    local v="${1-}"
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then
        echo "ERROR: level '${v}' is not a non-negative integer" >&2
        return 1
    fi
    if (( 10#$v > 10 )); then
        echo "ERROR: level ${v} is out of range (0-10)" >&2
        return 1
    fi
    return 0
}

################################################################################
# The home guard — writes only where the declaration says
################################################################################

tester_registry_require_home() {
    local state home
    state="$(demo_registry_home_state)"
    home="${state#*|}"
    case "${state%%|*}" in
        home) return 0 ;;
        undeclared)
            echo "ERROR: the registry home is UNDECLARED (${home} is missing or unparseable) — REFUSING to write the tester registry. An undeclared home fails CLOSED: a second writer is how two registries accreted in ops#328, and here it would mean two disagreeing answers to 'who survives tonight'." >&2
            return 2
            ;;
        *)
            echo "ERROR: this host is not the declared registry home ('${home}' is) — REFUSING to write the tester registry. Reads work anywhere; run the write on ${home}." >&2
            return 2
            ;;
    esac
}

_tester_require_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    echo "ERROR: jq is not available on this host — CANNOT VERIFY or write the tester registry" >&2
    return 2
}

################################################################################
# Reads
#
# ops#281, restated: a broken registry must NEVER render as an empty clean
# list. "Nobody is approved" and "I could not read who is approved" are
# different answers, and only one of them is safe to act on.
################################################################################

# tester_registry_list_json <site> — the console's read contract.
#   absent     -> ok:true,  registry:"absent",     testers:[], count:0, exit 0
#   present    -> ok:true,  registry:"present",    testers:[…], count:N, exit 0
#   unreadable -> ok:false, registry:"unreadable", NO testers key,      exit 2
tester_registry_list_json() {
    local site="${1:?site required}" file out
    file="$(tester_registry_file "$site")" || return 1
    _tester_require_jq || {
        printf '{"ok":false,"site":"%s","registry":"unreadable","reason":"jq missing on this host - CANNOT VERIFY"}\n' "$site"
        return 2
    }
    if [[ ! -f "$file" ]]; then
        jq -cn --arg site "$site" --arg file "$file" \
           '{ok:true, site:$site, registry:"absent", registry_path:$file,
             testers:[], count:0}'
        return 0
    fi
    if [[ ! -r "$file" ]]; then
        jq -cn --arg site "$site" --arg file "$file" \
           '{ok:false, site:$site, registry:"unreadable", registry_path:$file,
             reason:"the registry exists but cannot be read - CANNOT VERIFY, not empty"}'
        return 2
    fi
    out="$(jq -c --arg site "$site" --arg file "$file" '
        if (.version != 1) or (.testers | type != "array")
        then error("bad shape")
        else {ok:true, site:$site, registry:"present", registry_path:$file,
              generated_utc:(.generated_utc // null),
              testers:.testers, count:(.testers|length)}
        end' "$file" 2>/dev/null)" || out=""
    if [[ -z "$out" ]]; then
        jq -cn --arg site "$site" --arg file "$file" \
           '{ok:false, site:$site, registry:"unreadable", registry_path:$file,
             reason:"the registry exists but could not be parsed as a version-1 tester payload - CANNOT VERIFY, not empty"}'
        return 2
    fi
    printf '%s\n' "$out"
    return 0
}

# tester_registry_has <site> <account> — 0 when present, 1 when absent,
# 2 when the registry could not be read (never conflate 1 and 2).
tester_registry_has() {
    local site="${1:?site required}" acct="${2:?account required}" file n
    file="$(tester_registry_file "$site")" || return 2
    _tester_require_jq || return 2
    [[ -f "$file" ]] || return 1
    n="$(jq -r --arg a "$acct" '[.testers[]? | select(.account == $a)] | length' "$file" 2>/dev/null)" || return 2
    [[ "$n" =~ ^[0-9]+$ ]] || return 2
    (( n > 0 ))
}

################################################################################
# The write
################################################################################

# tester_registry_add <site> <account> <display> <bundle> [options]
#   --guild=<seed-key>  --level=<0-10>  --admin
#   --source=<console-add|join-request>  --request=<request-id>
#
# FAIL-CLOSED CONTRACT, and it is the reason this function exists rather than a
# jq one-liner at each call site:
#
#   returns 0  ONLY when the row has been written AND read back successfully.
#   returns >0 on ANY doubt whatsoever.
#
# The caller — the approval path — must treat non-zero as "the approval did not
# happen" and must NOT go on to create the account. An account whose tester is
# not in the registry is a person told "you're approved" who is wiped tonight,
# and that is the worst outcome in this whole feature.
tester_registry_add() {
    local site="${1:?site required}" acct="${2-}" display="${3-}" bundle="${4-}"
    shift 4 2>/dev/null || { echo "ERROR: usage: tester_registry_add <site> <account> <display> <bundle> [opts]" >&2; return 1; }

    local guild="" level="" admin="false" source="console-add" request=""
    local a
    for a in "$@"; do
        case "$a" in
            --guild=*)   guild="${a#*=}" ;;
            --level=*)   level="${a#*=}" ;;
            --admin)     admin="true" ;;
            --source=*)  source="${a#*=}" ;;
            --request=*) request="${a#*=}" ;;
            *) echo "ERROR: unrecognised option '${a}' for tester_registry_add" >&2; return 1 ;;
        esac
    done

    # 1. VALIDATE FIRST — before the home check and before touching anything.
    #    A bad name must never create a registry file as a side effect.
    tester_valid_account "$acct"   || return 1
    tester_valid_display "$display" || return 1
    tester_valid_bundle "$bundle"  || return 1
    [[ -z "$guild" ]] || [[ "$guild" =~ ^[a-z0-9_-]+$ ]] || {
        echo "ERROR: guild '${guild}' is not a seed key (lowercase machine id, e.g. 'writers') — guilds are addressed by field_group_seed_key, never by label" >&2
        return 1
    }
    [[ -z "$level" ]] || tester_valid_level "$level" || return 1
    case "$source" in
        console-add|join-request) ;;
        *) echo "ERROR: source '${source}' is not one of console-add|join-request" >&2; return 1 ;;
    esac
    [[ -z "$request" ]] || [[ "$request" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || {
        echo "ERROR: request id '${request}' has an invalid shape" >&2; return 1; }

    # 2. HOME GUARD.
    tester_registry_require_home || return 2
    _tester_require_jq || return 2

    local file dir
    file="$(tester_registry_file "$site")" || return 1
    dir="${file%/*}"

    # 3. READ WHAT IS THERE — and REFUSE on a registry we cannot parse.
    #    Overwriting it would destroy the only copy of everyone already
    #    approved, so an unreadable registry is a hard stop, not a fresh start.
    local existing='[]'
    if [[ -f "$file" ]]; then
        existing="$(jq -c 'if (.version != 1) or (.testers | type != "array") then error("bad shape") else .testers end' "$file" 2>/dev/null)" || existing=""
        if [[ -z "$existing" ]]; then
            echo "ERROR: ${file} exists but is unreadable as a version-1 tester payload — REFUSING to write. It is NOT being overwritten: it may hold the only record of everyone already approved. Fix or restore it, then retry." >&2
            return 2
        fi
        local n
        n="$(jq -r --arg a "$acct" '[.[] | select(.account == $a)] | length' <<<"$existing" 2>/dev/null)" || n=""
        [[ "$n" =~ ^[0-9]+$ ]] || { echo "ERROR: could not check ${file} for an existing '${acct}' — CANNOT VERIFY, refusing" >&2; return 2; }
        if (( n > 0 )); then
            echo "ERROR: '${acct}' is already in ${site}'s tester registry — refusing rather than writing a second row for the same person (which would make 'who survives' ambiguous)" >&2
            return 1
        fi
    fi

    # 4. BUILD the whole new document, then replace atomically. Never append in
    #    place: a half-written registry is the reader's total-failure mode.
    local now_utc actor tmp
    now_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    actor="${NWP_TESTER_ACTOR:-${SUDO_USER:-${USER:-unknown}}}"

    mkdir -p "$dir" 2>/dev/null || true
    tmp="$(mktemp "${dir}/.demo-testers.XXXXXX" 2>/dev/null)" || {
        echo "ERROR: could not create a temporary file in ${dir} — the tester registry was NOT written and the approval must NOT proceed" >&2
        return 2
    }
    chmod 600 "$tmp" 2>/dev/null || true

    if ! jq -cn --arg site "$site" --arg now "$now_utc" --argjson existing "$existing" \
        --arg account "$acct" --arg display "$display" --arg bundle "$bundle" \
        --arg guild "$guild" --arg level "$level" --argjson admin "$admin" \
        --arg source "$source" --arg request "$request" \
        --arg actor "$actor" --argjson at "$(date +%s)" '
        {version:1, generated_utc:$now, site:$site,
         testers: ($existing + [
           ({account:$account, display_name:$display, bundle:$bundle,
             admin:$admin, source:$source,
             approved_by:$actor, approved_at:$at}
            + (if $guild   == "" then {} else {guild:$guild} end)
            + (if $level   == "" then {} else {level:($level|tonumber)} end)
            + (if $request == "" then {} else {request_id:$request} end))
         ])}' > "$tmp" 2>/dev/null
    then
        rm -f "$tmp"
        echo "ERROR: could not build the new tester registry document — ${file} is UNCHANGED and the approval must NOT proceed" >&2
        return 2
    fi

    if ! mv -f "$tmp" "$file" 2>/dev/null; then
        rm -f "$tmp"
        echo "ERROR: could not write ${file} — the tester registry was NOT updated and the approval must NOT proceed" >&2
        return 2
    fi
    chmod 600 "$file" 2>/dev/null || true

    # 5. VERIFY THE READBACK. Reporting success on a write we have not proven
    #    landed is exactly the "check that has never been proven to fail" shape:
    #    the caller would tell somebody they are approved on the strength of a
    #    return code that measured nothing.
    if ! tester_registry_has "$site" "$acct"; then
        echo "ERROR: '${acct}' is NOT readable back from ${file} after the write — CANNOT VERIFY the approval landed. Do NOT create the account; nobody has been approved." >&2
        return 2
    fi
    return 0
}
