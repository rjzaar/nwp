#!/usr/bin/env bash
# lib/demo-smoke.sh — assert that what the invite email PROMISES is what the
# demo tier actually SERVES.
#
# WHY THIS EXISTS
# The demo pilot's failure mode is not a stack trace, it is a broken promise: an
# email tells a tester to click a link and land as a Sojourner, and the link
# 404s, or the page carries the partner site's name, or the consent version on
# the box is not the one that was ratified. None of that shows up in an uptime
# check — every one of those pages returns HTTP 200 while being wrong.
#
# So this checks CLAIMS, not liveness, and it does it the way a tester would:
# over plain HTTP from outside. Read-only by construction — every probe is a GET
# — which is what makes it safe to point at live and to run from CI on a
# schedule. It replaces a human re-verifying the same list by hand after every
# deploy, which is how the URL-placeholder bug reached a real invite email.
#
# It deliberately does NOT log in. An authenticated journey belongs in Behat
# against a disposable database, not in a verb aimed at a live site.

[[ -n "${_NWP_DEMO_SMOKE_LOADED:-}" ]] && return 0
_NWP_DEMO_SMOKE_LOADED=1

SMOKE_PASS=0
SMOKE_FAIL=0
SMOKE_WARN=0

# smoke_reset_counters
smoke_reset_counters() { SMOKE_PASS=0; SMOKE_FAIL=0; SMOKE_WARN=0; }

# smoke_fetch <url> [resolve-ip]
# Prints "<http_code>\n<body>". A resolve override lets the checks run against a
# specific box BEFORE its DNS is flipped — which is exactly when you most want
# to know whether the promises still hold.
smoke_fetch() {
    local url="$1" ip="${2:-}" host resolve=()
    if [[ -n "$ip" ]]; then
        host=$(printf '%s' "$url" | sed -E 's#^https?://##; s#/.*$##')
        resolve=(--resolve "${host}:443:${ip}" --resolve "${host}:80:${ip}")
    fi
    curl -sk -L --max-time 30 -w '\n__HTTP__%{http_code}' "${resolve[@]}" "$url" 2>/dev/null
}

smoke_code() { printf '%s' "$1" | sed -n 's/.*__HTTP__\([0-9]*\)$/\1/p' | tail -1; }
smoke_body() { printf '%s' "$1" | sed 's/__HTTP__[0-9]*$//'; }

# smoke_check_status <label> <url> <expected-csv> [ip]
smoke_check_status() {
    local label="$1" url="$2" expect="$3" ip="${4:-}" out code
    out=$(smoke_fetch "$url" "$ip"); code=$(smoke_code "$out")
    if [[ -z "$code" || "$code" == "000" ]]; then
        printf '  [FAIL] %-34s %s — no response\n' "$label" "$url"; SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    if printf '%s' ",${expect}," | grep -q ",${code},"; then
        printf '  [ok]   %-34s %s\n' "$label" "$code"; SMOKE_PASS=$((SMOKE_PASS+1)); return 0
    fi
    printf '  [FAIL] %-34s got %s, want one of %s — %s\n' "$label" "$code" "$expect" "$url"
    SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
}

# smoke_check_contains <label> <url> <needle> [ip]
# The promise-level check: the page loads AND says the thing the email claims.
smoke_check_contains() {
    local label="$1" url="$2" needle="$3" ip="${4:-}" out code body
    out=$(smoke_fetch "$url" "$ip"); code=$(smoke_code "$out"); body=$(smoke_body "$out")
    if [[ "$code" != "200" ]]; then
        printf '  [FAIL] %-34s page is %s, cannot check content — %s\n' "$label" "${code:-no-response}" "$url"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    if printf '%s' "$body" | grep -qiF -- "$needle"; then
        printf '  [ok]   %-34s found %s\n' "$label" "\"${needle}\""; SMOKE_PASS=$((SMOKE_PASS+1)); return 0
    fi
    printf '  [FAIL] %-34s page 200 but does NOT contain %s — %s\n' "$label" "\"${needle}\"" "$url"
    SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
}

# smoke_check_absent <label> <url> <needle> [ip]
# For claims that are about something NOT being there — e.g. the partner site's
# name leaking onto every page title.
smoke_check_absent() {
    local label="$1" url="$2" needle="$3" ip="${4:-}" out code body
    out=$(smoke_fetch "$url" "$ip"); code=$(smoke_code "$out"); body=$(smoke_body "$out")
    if [[ "$code" != "200" ]]; then
        printf '  [FAIL] %-34s page is %s, cannot check content\n' "$label" "${code:-no-response}"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    if printf '%s' "$body" | grep -qiF -- "$needle"; then
        printf '  [FAIL] %-34s page still contains %s\n' "$label" "\"${needle}\""
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    printf '  [ok]   %-34s no %s\n' "$label" "\"${needle}\""; SMOKE_PASS=$((SMOKE_PASS+1)); return 0
}

# smoke_extract_title <body> — the FIRST <title> element's text, trimmed.
#
# The FIRST <title> is the document's. A greedy match walks past it to the
# last one on the page, and these themes embed <title> inside inline SVG
# icons — which is how this first reported the page title as "Close search
# window".
smoke_extract_title() {
    printf '%s' "$1" | tr '\n' ' ' \
        | grep -oiE '<title[^>]*>[^<]*</title>' | head -1 \
        | sed -E 's/<[^>]*>//g' | sed -E 's/^[[:space:]|]+//; s/[[:space:]]+$//'
}

# smoke_check_title <label> <url> <expect-substr> <forbid-substr> [ip]
# Checks the <title> element specifically, not the whole document.
#
# Scanning the whole body for the partner's name is wrong: nwd legitimately
# LINKS to Saint School — that is the point of a two-site pilot, and the invite
# email says so. The actual defect (A1-2) is narrower and worse:
# system.site.name is the PARTNER's name, so it is the site's own identity on
# every page title. Checking the body would both miss the distinction and cry
# wolf about a correct link.
smoke_check_title() {
    local label="$1" url="$2" expect="$3" forbid="$4" ip="${5:-}" out code body title
    out=$(smoke_fetch "$url" "$ip"); code=$(smoke_code "$out"); body=$(smoke_body "$out")
    if [[ "$code" != "200" ]]; then
        printf '  [FAIL] %-34s page is %s\n' "$label" "${code:-no-response}"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    title=$(smoke_extract_title "$body")
    if [[ -z "$title" ]]; then
        printf '  [FAIL] %-34s page has no <title>\n' "$label"; SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    if [[ -n "$forbid" ]] && printf '%s' "$title" | grep -qiF -- "$forbid"; then
        printf '  [FAIL] %-34s <title> is "%s" — that is the PARTNER (%s), not this site\n' \
               "$label" "$title" "$forbid"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    if [[ -n "$expect" ]] && ! printf '%s' "$title" | grep -qiF -- "$expect"; then
        printf '  [FAIL] %-34s <title> is "%s", expected it to name "%s"\n' "$label" "$title" "$expect"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    printf '  [ok]   %-34s <title> = "%s"\n' "$label" "$title"; SMOKE_PASS=$((SMOKE_PASS+1)); return 0
}

# smoke_check_title_regex <label> <url> <expect-substr> <forbid-ere> [ip]
# As smoke_check_title, but the FORBIDDEN pattern is an extended regex, which
# is what a machine-shortname rule needs: forbidding the fixed string "ssd"
# would cry wolf at any word containing it, while `\bssd\b` catches exactly the
# defect that shipped — ssd's own front page titled "Home | ssd" (A14).
smoke_check_title_regex() {
    local label="$1" url="$2" expect="$3" forbid="$4" ip="${5:-}" out code body title
    out=$(smoke_fetch "$url" "$ip"); code=$(smoke_code "$out"); body=$(smoke_body "$out")
    if [[ "$code" != "200" ]]; then
        printf '  [FAIL] %-34s page is %s\n' "$label" "${code:-no-response}"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    title=$(smoke_extract_title "$body")
    if [[ -z "$title" ]]; then
        printf '  [FAIL] %-34s page has no <title>\n' "$label"; SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    if [[ -n "$forbid" ]] && printf '%s' "$title" | grep -qiE -- "$forbid"; then
        printf '  [FAIL] %-34s <title> is "%s" — it leaks the machine name (%s)\n' \
               "$label" "$title" "$forbid"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    if [[ -n "$expect" ]] && ! printf '%s' "$title" | grep -qiF -- "$expect"; then
        printf '  [FAIL] %-34s <title> is "%s", expected it to name "%s"\n' "$label" "$title" "$expect"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    printf '  [ok]   %-34s <title> = "%s"\n' "$label" "$title"; SMOKE_PASS=$((SMOKE_PASS+1)); return 0
}

# smoke_check_button_label <label> <url> <a-class> <expected-text> [ip]
# EQUALITY on the text of the first <a> carrying the css class (whitespace
# collapsed — Moodle pads the label with spaces and newlines).
#
# A contains-check is not enough here: the smoke ran 9/9 green while the
# invite email named the SSO button wrongly, because the old check only proved
# the page said "Log in using your account on" somewhere — it never read what
# the button the tester must actually click is CALLED (A10). The expected text
# is the pair contract's oidc.issuer_name, the same value the email renders,
# so the email, the contract and the live button cannot drift apart silently.
smoke_check_button_label() {
    local label="$1" url="$2" cls="$3" want="$4" ip="${5:-}" out code body text
    out=$(smoke_fetch "$url" "$ip"); code=$(smoke_code "$out"); body=$(smoke_body "$out")
    if [[ "$code" != "200" ]]; then
        printf '  [FAIL] %-34s page is %s, cannot read the button — %s\n' \
               "$label" "${code:-no-response}" "$url"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    text=$(printf '%s' "$body" | tr '\n' ' ' \
           | grep -oE "<a[^>]*${cls}[^>]*>[^<]*</a>" | head -1 \
           | sed -E 's/<[^>]*>//g' | tr -s '[:space:]' ' ' \
           | sed -E 's/^ //; s/ $//')
    if [[ -z "$text" ]]; then
        printf '  [FAIL] %-34s page 200 but has no <a class="%s"> button — %s\n' \
               "$label" "$cls" "$url"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    if [[ "$text" == "$want" ]]; then
        printf '  [ok]   %-34s button = "%s"\n' "$label" "$text"
        SMOKE_PASS=$((SMOKE_PASS+1)); return 0
    fi
    printf '  [FAIL] %-34s button reads "%s", the contract/email says "%s"\n' \
           "$label" "$text" "$want"
    SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
}

# smoke_check_redirect <label> <url> <expected-code-csv> <location-path-suffix> [ip]
# Fetches WITHOUT following and asserts both the status code and where the
# Location header points. The suffix is compared against the Location's PATH
# (query string stripped): a login bounce carrying ?destination=/apply must
# not impersonate the /apply redirect itself (A12 — the gated-signup promise).
smoke_check_redirect() {
    local label="$1" url="$2" expect="$3" suffix="$4" ip="${5:-}"
    local host resolve=() hdrs code loc
    if [[ -n "$ip" ]]; then
        host=$(printf '%s' "$url" | sed -E 's#^https?://##; s#/.*$##')
        resolve=(--resolve "${host}:443:${ip}" --resolve "${host}:80:${ip}")
    fi
    hdrs=$(curl -sk --max-time 30 -o /dev/null -D - "${resolve[@]}" "$url" 2>/dev/null | tr -d '\r')
    code=$(printf '%s' "$hdrs" | awk 'toupper($1) ~ /^HTTP\// {c=$2} END {print c}')
    if [[ -z "$code" || "$code" == "000" ]]; then
        printf '  [FAIL] %-34s %s — no response\n' "$label" "$url"; SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    if ! printf '%s' ",${expect}," | grep -q ",${code},"; then
        printf '  [FAIL] %-34s got %s, want one of %s — %s\n' "$label" "$code" "$expect" "$url"
        SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1
    fi
    loc=$(printf '%s' "$hdrs" | grep -i '^location:' | tail -1 \
          | sed -E 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//; s/[[:space:]]+$//')
    loc="${loc%%\?*}"
    case "$loc" in
        *"$suffix")
            printf '  [ok]   %-34s %s → %s\n' "$label" "$code" "$loc"
            SMOKE_PASS=$((SMOKE_PASS+1)); return 0 ;;
        *)
            printf '  [FAIL] %-34s %s redirects to "%s", expected it to end "%s"\n' \
                   "$label" "$code" "${loc:-<no Location>}" "$suffix"
            SMOKE_FAIL=$((SMOKE_FAIL+1)); return 1 ;;
    esac
}

# smoke_summary  — 0 clean, 1 failures. WARNs never mask a FAIL.
smoke_summary() {
    printf '\n  %d passed, %d failed, %d warning(s)\n' "$SMOKE_PASS" "$SMOKE_FAIL" "$SMOKE_WARN"
    [[ "$SMOKE_FAIL" -eq 0 ]]
}
