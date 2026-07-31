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
#   * --if-idle     = sessions-table last-activity check; "active" is a
#     DISTINCT exit code (3) so the nightly wrapper can retry.
#
# Fail-closed everywhere: unparseable input refuses, missing tools refuse.

# Distinct exit code for "someone is active — retry later" (NOT an error).
DEMO_EXIT_ACTIVE=3

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
demo_log() {
    local site="$1" event="$2"; shift 2 || true
    local file; file="$(demo_log_file "$site")"
    mkdir -p "$(dirname "$file")"
    printf '%s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$event" "$*" >> "$file"
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
# Invitation email (pl demo invite) — pure rendering, unit-testable
################################################################################

# The community's public-facing name in the invitation. The demo tier is the
# Saint School pilot (ops#133); override via env for another community.
DEMO_INVITE_SITE_NAME="${DEMO_INVITE_SITE_NAME:-Saint School}"

# demo_invite_join_url <site> → "https://<live.domain>/demo/join" read from
# sites/<site>/.nwp.yml, or a visible placeholder when the domain (or yq)
# is unavailable. Never fails — the draft must always render.
demo_invite_join_url() {
    local site="$1" domain="" yml
    yml="$(demo_site_dir "$site")/.nwp.yml"
    if command -v yq >/dev/null 2>&1 && [[ -f "$yml" ]]; then
        domain="$(yq eval '.live.domain' "$yml" 2>/dev/null || true)"
        [[ "$domain" == "null" ]] && domain=""
    fi
    # Fall back to the global nwp.yml. The per-site sites/<site>/.nwp.yml does
    # not exist on a host that carries no sites tree — notably the console
    # host, which is exactly where `pl demo invite` runs when the operator
    # clicks the button. Without this the invite email showed the
    # <YOUR-SITE-URL> placeholder instead of the real join link.
    if [[ -z "$domain" ]] && command -v yq >/dev/null 2>&1; then
        local gcfg="${PROJECT_ROOT:-$HOME/nwp}/nwp.yml"
        if [[ -f "$gcfg" ]]; then
            domain="$(SITE="$site" yq eval '.sites[strenv(SITE)].live.domain // ""' "$gcfg" 2>/dev/null || true)"
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

# demo_invite_courses_url <community-site> — the login page of the paired demo
# COURSES site (Moodle), where the tester clicks "Log in using your account on:
# <community>". Resolved generically from the demo pair contract (provider ==
# this site, demo.enabled). Empty when there is no demo pair or the consumer's
# domain is unresolvable — the email then simply omits the courses section.
demo_invite_courses_url() {
    local site="$1" consumer="" domain="" yml gcfg f prov demo
    command -v yq >/dev/null 2>&1 || { echo ""; return 0; }
    local pairs_dir="${NWP_PAIR_CONTRACT_DIR:-${PROJECT_ROOT:-$HOME/nwp}/pairs}"
    for f in "$pairs_dir"/*.pair-contract.yml; do
        [[ -f "$f" ]] || continue
        prov="$(yq eval '.provider // ""' "$f" 2>/dev/null)"
        demo="$(yq eval '.demo.enabled // false' "$f" 2>/dev/null)"
        if [[ "$prov" == "$site" && "$demo" == "true" ]]; then
            consumer="$(yq eval '.consumer // ""' "$f" 2>/dev/null)"
            break
        fi
    done
    [[ -n "$consumer" && "$consumer" != "null" ]] || { echo ""; return 0; }
    yml="$(demo_site_dir "$consumer")/.nwp.yml"
    [[ -f "$yml" ]] && { domain="$(yq eval '.live.domain // ""' "$yml" 2>/dev/null)"; [[ "$domain" == "null" ]] && domain=""; }
    if [[ -z "$domain" ]]; then
        gcfg="${PROJECT_ROOT:-$HOME/nwp}/nwp.yml"
        [[ -f "$gcfg" ]] && { domain="$(CONS="$consumer" yq eval '.sites[strenv(CONS)].live.domain // ""' "$gcfg" 2>/dev/null)"; [[ "$domain" == "null" ]] && domain=""; }
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
guild. Everyone begins here, and you move up simply by completing courses —
every honest path reaches the top. (Sojourners sit under the Theology Guild,
the mature guild you can grow into later.)

Try these in the community — ${cb}
- Open the guilds index at /all-groups, join one, and look inside.
- Browse the activity stream at /explore.
- Open your profile and try the privacy and sharing choices — change them
  and see what it affects.
- Watch your Sojourner progress build at /nwc/achievements.
- Do some of this on your phone — does it still feel easy?

Then try the courses (Step 2 above)
- Open the Saint School catalogue and start a course.
- Come back and see whether finishing it moved your progress.
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
- Look at member progress — you only see what members chose to share; check
  that boundary feels right.
- Post a welcome or announcement to the guild.
- Try managing who is in the guild.
BLOCK
            ;;
        tester-content-manager)
            cat <<BLOCK
The perspective of someone who writes and arranges the teaching material —
the craft side the Writers and Pedagogy guilds care for.

Try these in the community — ${cb}
- Edit an existing page or course item and save it.
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
    local community_base courses_url
    community_base="$(demo_invite_community_base "$site_arg")"
    courses_url="$(demo_invite_courses_url "$site_arg")"

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
broken, confusing, or just feels wrong — even slightly — use the "Report a
problem" link and tell us in a sentence or two. Every report goes straight
into our fix queue. There are no silly reports; "this confused me" is
exactly what we need to hear.

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
  3. You're in — you'll land on the community home.

STEP 2 — Walk into the courses (whenever you like):
  1. Open:  ${courses_url:-<COURSES-SITE>/login}
  2. Click the button "Log in using your account on: nwd".
  3. You're now in Saint School with the same identity — browse the courses
     and start one. (There's no code box on the courses site; it uses your
     community sign-in, not a code.)

WHERE TO REPORT PROBLEMS

On the community site: ${community_base:-<COMMUNITY-SITE>}/feedback/submit —
or the "Report a problem" link you'll see around both sites. One sentence is
plenty.

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
# Golden manifest
################################################################################

# demo_manifest_write <dir> <site> <db_basename> <files_basename>
# Writes <dir>/golden.manifest.json. Assumes the .sha256 sidecars already
# exist next to the artifacts (written by the capture step).
demo_manifest_write() {
    local dir="$1" site="$2" db="$3" files="$4"
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
        printf '  "files_sha256": "%s"\n' "$files_sha"
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
