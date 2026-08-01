#!/bin/bash
################################################################################
# lib/golden-hygiene.sh — "is anybody's identity baked into a golden image?"
#
# WHY THIS EXISTS
# ---------------
# A demo golden is not a backup. A backup ages out; a golden is *restored over
# the live site every night*, so anything inside it is immortal — it survives
# every reset, it is copied to the demo box, and it is duplicated at rest into
# every backup of that box. On 2026-08-01 the ssd golden was found carrying a
# Moodle **site-administrator** row with the operator's real given name, family
# name and personal mailbox. It had been there since the site was installed on
# 2026-05-19, and the nightly restore had been putting it back every night.
#
# The demo tier's entire promise to a tester is "you never give us your name or
# your email, and nothing about you is kept". An admin account in the image that
# carries a real person's name and personal mailbox contradicts that promise on
# a site that is handed to strangers.
#
# WHAT IT ASSERTS — and how it avoids becoming the leak
# -----------------------------------------------------
# The obvious check ("grep the golden for <the operator's address>") cannot be
# written down: this repo's leakage gate (P61 / .gitleaks.toml, rules
# `operator-personal-email` and `live-domain-apex`) blocks both the personal
# mailbox AND the operator's own domains from every tracked file. A guard that
# has to name the thing it guards is a guard that leaks it.
#
# So, exactly as nwc's CanonicalTextHygieneTest does for published legal text,
# the rule is expressed STRUCTURALLY and the specifics are resolved at runtime:
#
#   RULE 1 (always on, no configuration)
#     Every mailbox in a golden must be on a domain that is either
#       (a) an RFC 2606 / RFC 6761 reserved sentinel — .invalid, .test,
#           .example, .localhost, localhost, example.{com,net,org} — i.e. a
#           provably undeliverable address, which is what a demo account should
#           have; or
#       (b) a domain this estate declares for itself, read at run time out of
#           the (gitignored) nwp.yml. Never spelled out here.
#     Anything else — a consumer mailbox, a colleague, a customer — fails.
#     This catches a personal address without anyone ever writing one down.
#
#   RULE 2 (opt-in, for personal NAMES)
#     Names have no structure to exploit — a real family name and a generated
#     patron-saint demo username are both just words, and only local knowledge
#     tells them apart. So the name tokens live in ONE untracked file,
#     private/golden-identity-denylist.txt (private/* is gitignored), and the
#     check reads it if it is there. If it is NOT there, the result is UNKNOWN,
#     never CLEAR — a host holding goldens that has never been told whose name
#     to look for has not been checked, and `pl rag` refuses to grade an UNKNOWN
#     site green.
#
# Read-only. No network. Decompresses each golden once and streams it.
################################################################################

# Reserved/sentinel mail domains. RFC 2606 (.test/.example/.invalid/.localhost +
# example.com|net|org) and RFC 6761 — all guaranteed never to resolve, which is
# exactly the property a demo account's address needs.
GOLDEN_SENTINEL_DOMAINS_RE='^(localhost|(.+\.)?(invalid|test|example|localhost)|example\.(com|net|org)|(.+\.)?ddev\.site)$'

# Exact mailboxes that CONTRIB MODULES SHIP as placeholder test data. These are
# allowlisted as whole addresses, never as domains: test.com and random.com are
# real registered domains, so exempting the domain would blind the check to a
# real person who happened to have an address there. Webform's
# webform.settings:test.types ships this pair in every install; without this the
# check would report the same impersonal lorem-ipsum fixture on every capture
# forever, and a guard that cries wolf every night is a guard that gets ignored.
GOLDEN_VENDOR_FIXTURE_MAILBOXES='^(test@test\.com|random@random\.com)$'

# Where the optional personal-name tokens live. Untracked by construction.
golden_hygiene_denylist_file() {
    printf '%s/private/golden-identity-denylist.txt' "${1:-$PWD}"
}

# Every domain this estate declares for itself, harvested from nwp.yml at run
# time (domain: / mail_domain: / anything domain-shaped under sites:). nwp.yml
# is gitignored, so the operator's real domains are read, never stored here.
# Args: $1 = path to nwp.yml
golden_hygiene_declared_domains() {
    local config="$1"
    [ -f "$config" ] || return 0
    grep -hoE '^[[:space:]]*[a-z_]*domain:[[:space:]]*[A-Za-z0-9.-]+' "$config" 2>/dev/null \
        | sed -E 's/.*:[[:space:]]*//' \
        | tr 'A-Z' 'a-z' \
        | grep -E '^[a-z0-9-]+(\.[a-z0-9-]+)+$' \
        | sort -u
}

# Stream a golden artifact's readable text.
# Args: $1 = path to golden.db.sql.gz or golden.files.tar.gz
golden_hygiene_stream() {
    local artifact="$1"
    case "$artifact" in
        *.tar.gz) gzip -dc -- "$artifact" 2>/dev/null | tar -xO 2>/dev/null ;;
        *.gz)     gzip -dc -- "$artifact" 2>/dev/null ;;
        *)        cat -- "$artifact" 2>/dev/null ;;
    esac
}

# RULE 1 — mailbox domains that are neither sentinel nor estate-declared.
# Prints one offending domain per line (deduplicated). Empty output = clean.
# Args: $1 = artifact path, $2 = newline-separated declared domains
golden_hygiene_foreign_mail_domains() {
    local artifact="$1" declared="$2"
    local domains d allowed
    domains=$(golden_hygiene_stream "$artifact" \
        | grep -aoiE '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+' \
        | tr 'A-Z' 'a-z' | sort -u \
        | grep -vE "$GOLDEN_VENDOR_FIXTURE_MAILBOXES" \
        | sed -E 's/.*@//' | sort -u)
    [ -n "$domains" ] || return 0

    while IFS= read -r d; do
        [ -n "$d" ] || continue
        # Trailing dots / version-looking strings (mathjax@2.7.9) are not mail.
        printf '%s' "$d" | grep -qE '[a-z]' || continue
        if printf '%s' "$d" | grep -qE "$GOLDEN_SENTINEL_DOMAINS_RE"; then
            continue
        fi
        allowed=false
        local decl
        while IFS= read -r decl; do
            [ -n "$decl" ] || continue
            if [ "$d" = "$decl" ] || [ "${d%".$decl"}" != "$d" ]; then
                allowed=true; break
            fi
        done <<< "$declared"
        [ "$allowed" = true ] || printf '%s\n' "$d"
    done <<< "$domains"
}

# RULE 2 — personal-name tokens from the untracked denylist.
# Prints one MASKED token per line (first char + length) so a finding can be
# reported, logged and mailed without re-publishing the identifier it found.
# Args: $1 = artifact path, $2 = denylist file
golden_hygiene_denylisted_tokens() {
    local artifact="$1" list="$2"
    [ -f "$list" ] || return 0

    local tmp; tmp=$(mktemp) || return 0
    grep -vE '^[[:space:]]*(#|$)' "$list" 2>/dev/null \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' > "$tmp"
    [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }

    # ONE streaming pass, one grep. The obvious loop — slurp the decompressed
    # golden into a shell variable and grep it once per token — took 60s on five
    # goldens, which blows the 45s budget `pl todo check` runs inside and would
    # have made `pl rag` report UNKNOWN instead of the finding. -o -i -F -f gets
    # every match in one pass; sort -u collapses them.
    local hits; hits=$(golden_hygiene_stream "$artifact" \
        | grep -aoiF -f "$tmp" 2>/dev/null | tr 'A-Z' 'a-z' | sort -u)
    rm -f "$tmp"
    [ -n "$hits" ] || return 0

    local tok
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        printf '%s%s (%d chars)\n' "${tok:0:1}" \
            "$(printf '%*s' $(( ${#tok} - 1 )) '' | tr ' ' '*')" "${#tok}"
    done <<< "$hits"
}

# Both rules for one artifact, memoised on CONTENT.
#
# Decompressing a multi-megabyte golden twice per artifact costs ~20s across the
# five images this workstation holds. `pl todo check` budgets 45s for ~24 checks
# and `pl rag` calls a check that overruns UNKNOWN, so an honest-but-slow check
# degrades into no check at all. Goldens change at most once a day, so the result
# is cached against the sha256 of the artifact AND of the inputs that decide the
# verdict (the denylist, the declared-domain set). Any recapture, any edit to
# either input, is a different key and forces a fresh scan — the cache can go
# stale-positive but never stale-negative.
#
# Prints:  MAIL <domain>   (one per line)
#          NAME <masked>   (one per line)
# Args: $1=artifact  $2=declared domains  $3=denylist file  $4=cache dir
golden_hygiene_scan() {
    local artifact="$1" declared="$2" list="$3" cache_dir="$4"
    [ -f "$artifact" ] || return 0

    local key="" cache=""
    if [ -n "$cache_dir" ] && command -v sha256sum >/dev/null 2>&1; then
        key=$(printf '%s|%s|%s' \
                "$(sha256sum -- "$artifact" 2>/dev/null | cut -d' ' -f1)" \
                "$([ -f "$list" ] && sha256sum -- "$list" 2>/dev/null | cut -d' ' -f1)" \
                "$(printf '%s' "$declared" | sha256sum 2>/dev/null | cut -d' ' -f1)" \
              | sha256sum | cut -d' ' -f1)
        cache="$cache_dir/golden-hygiene/$key"
        if [ -f "$cache" ]; then cat -- "$cache"; return 0; fi
    fi

    local out=""
    local d m
    while IFS= read -r d; do
        [ -n "$d" ] && out+="MAIL $d"$'\n'
    done <<< "$(golden_hygiene_foreign_mail_domains "$artifact" "$declared")"
    while IFS= read -r m; do
        [ -n "$m" ] && out+="NAME $m"$'\n'
    done <<< "$(golden_hygiene_denylisted_tokens "$artifact" "$list")"

    if [ -n "$cache" ]; then
        mkdir -p "$(dirname "$cache")" 2>/dev/null && printf '%s' "$out" > "$cache" 2>/dev/null
    fi
    printf '%s' "$out"
}
