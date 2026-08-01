#!/bin/bash
################################################################################
# lib/moodle-mail.sh — the mail IDENTITY of a Moodle site as a declared,
# checkable fact.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-01 a sweep found both live Moodle sites configured with addresses
# that could not work. With the estate's apex written <ESTATE> (the real one is
# not spelled out in a tracked file):
#
#   real site  supportemail   = admin@<sub>.<ESTATE>   <- that SUBDOMAIN has NO MX
#              noreplyaddress = noreply@<sub>.ddev.site <- a LOCAL DEV DOMAIN, on live
#   demo site  supportemail   = admin@<sub2>.<ESTATE>  <- same fault
#              noreplyaddress = noreply@<sub2>.ddev.site <- same leak
#
# Neither fault is subtle, and neither was caught for months, because the
# addresses were hand-set with a raw `admin/cli/cfg.php --set=` and nothing ever
# read them back. The repair was also hand-set, which reproduces the same
# exposure one value later.
#
# So the addresses are now a DECLARED FACT in sites/<site>/.nwp.yml:
#
#   mail:
#     support_email:   support@<estate-domain>
#     support_name:    Saint School Support
#     noreply_address: <sitekey>@<estate-domain>
#
# ...and `pl moodle mail <site> --tier=live` reads live, compares, and refuses
# to write an address that cannot receive mail. The four checks below are, in
# order, exactly the four that would have caught the two faults above:
#
#   [1] SYNTAX      localpart@domain, one @, no whitespace
#   [2] DEV-DOMAIN  .ddev.site / .local / .invalid / .test / .example / localhost
#                   are refused outright. A live site must never emit one.
#   [3] MX          the domain must actually accept mail. `<site>.<estate-domain>` has
#                   no MX, so admin@<site>.<estate-domain> was undeliverable BY
#                   CONSTRUCTION — a DNS lookup is the cheapest possible proof.
#   [4] ALIASED     for a domain the estate itself serves, the address must
#                   appear in servers/<server>/email/referenced-addresses.txt
#                   AND in the tracked postfix-virtual baseline. An @<estate-domain>
#                   address with no alias line is a silent black hole; that is
#                   the same promise `pl doctor`'s check_mail_aliases enforces,
#                   applied BEFORE the value can reach a live site rather than
#                   after.
#
# Every function here is pure except moodle_mail_has_mx, whose resolver command
# is injectable (MOODLE_MAIL_MX_CMD) so the whole validator is unit-testable
# with no network.
################################################################################

# Domains that must never appear in a live site's mail identity. Some are RFC
# 2606/6761 reserved, some are local-development conventions; all of them mean
# "this value was copied out of a dev environment".
MOODLE_MAIL_DEV_SUFFIXES=(
    ".ddev.site"
    ".local"
    ".localhost"
    ".invalid"
    ".test"
    ".example"
    ".internal"
)
MOODLE_MAIL_DEV_EXACT=(
    "localhost"
    "example.com"
    "example.net"
    "example.org"
)

# moodle_mail_syntax_ok <address>
# The narrow, boring definition: exactly one @, a non-empty localpart, and a
# domain with at least one dot and no whitespace. Deliberately not RFC 5322 —
# this is a guard against pasted junk, not an email parser.
moodle_mail_syntax_ok() {
    local addr="${1:-}"
    [[ -n "$addr" ]] || return 1
    [[ "$addr" != *[[:space:]]* ]] || return 1
    [[ "$addr" == *@* ]] || return 1
    local local_part="${addr%@*}" domain="${addr##*@}"
    [[ -n "$local_part" ]] || return 1
    [[ "$local_part" != *@* ]] || return 1   # more than one @
    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" != .* && "$domain" != *. ]] || return 1
    return 0
}

# moodle_mail_domain_of <address>
moodle_mail_domain_of() {
    local addr="${1:-}"
    printf '%s' "${addr##*@}"
}

# moodle_mail_is_dev_domain <domain>
# 0 = this is a dev/reserved domain and must be refused on a live site.
moodle_mail_is_dev_domain() {
    local domain
    domain="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    [[ -n "$domain" ]] || return 1
    local d
    for d in "${MOODLE_MAIL_DEV_EXACT[@]}"; do
        [[ "$domain" == "$d" ]] && return 0
    done
    for d in "${MOODLE_MAIL_DEV_SUFFIXES[@]}"; do
        [[ "$domain" == *"$d" ]] && return 0
    done
    return 1
}

# moodle_mail_has_mx <domain>
#   0 = has an MX (or an A/AAAA fallback, which RFC 5321 §5.1 permits)
#   1 = resolves, but accepts no mail
#   2 = CANNOT VERIFY (no resolver available) — never treated as a pass
#
# MOODLE_MAIL_MX_CMD lets the tests inject a resolver. It is called as
#   $MOODLE_MAIL_MX_CMD <type> <domain>
# and must print the records, one per line, or nothing.
moodle_mail_has_mx() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || return 1

    if [[ -n "${MOODLE_MAIL_MX_CMD:-}" ]]; then
        local out
        out="$($MOODLE_MAIL_MX_CMD MX "$domain" 2>/dev/null)"
        [[ -n "$out" ]] && return 0
        out="$($MOODLE_MAIL_MX_CMD A "$domain" 2>/dev/null)"
        [[ -n "$out" ]] && return 0
        return 1
    fi

    command -v dig >/dev/null 2>&1 || return 2

    local mx
    mx="$(dig +short +time=3 +tries=2 MX "$domain" 2>/dev/null)"
    [[ -n "$mx" ]] && return 0
    # No MX is not automatically fatal: a bare A record is an implicit MX.
    local a
    a="$(dig +short +time=3 +tries=2 A "$domain" 2>/dev/null)"
    [[ -n "$a" ]] && return 0
    return 1
}

# moodle_mail_manifest_for <domain> <project_root>
# Echo the path of the referenced-addresses.txt manifest that governs <domain>,
# if the estate serves that domain. Empty when the domain is somebody else's.
#
# A manifest governs a domain when any address already listed in it is at that
# domain — i.e. the estate has already promised to deliver mail there.
moodle_mail_manifest_for() {
    local domain="${1:-}" root="${2:-}"
    [[ -n "$domain" && -n "$root" ]] || return 1
    local manifest
    for manifest in "$root"/servers/*/email/referenced-addresses.txt; do
        [[ -f "$manifest" ]] || continue
        if grep -Eqi "^[^#[:space:]]+@${domain//./\\.}([[:space:]]|#|$)" "$manifest"; then
            printf '%s' "$manifest"
            return 0
        fi
    done
    return 1
}

# moodle_mail_listed_in <address> <file>
# True when <address> appears as the first field of a non-comment line.
moodle_mail_listed_in() {
    local addr="${1:-}" file="${2:-}"
    [[ -f "$file" ]] || return 1
    grep -Eq "^${addr//./\\.}([[:space:]]|#|$)" "$file"
}

################################################################################
# moodle_mail_validate <address> <project_root>
#
# The gate. Prints a one-line reason and returns:
#   0  OK           deliverable, and aliased if the estate owns the domain
#   1  REFUSE       provably wrong — never write this to a live site
#   2  CANNOT-VERIFY  no resolver; the caller must not treat this as a pass
################################################################################
moodle_mail_validate() {
    local addr="${1:-}" root="${2:-}"

    if ! moodle_mail_syntax_ok "$addr"; then
        printf 'REFUSE: not a well-formed address: %s\n' "${addr:-(empty)}"
        return 1
    fi

    local domain; domain="$(moodle_mail_domain_of "$addr")"

    if moodle_mail_is_dev_domain "$domain"; then
        printf 'REFUSE: %s is a development/reserved domain — never valid on a live site (%s)\n' \
            "$domain" "$addr"
        return 1
    fi

    moodle_mail_has_mx "$domain"
    case $? in
        0) ;;
        2) printf 'CANNOT-VERIFY: no resolver available to check MX for %s\n' "$domain"
           return 2 ;;
        *) printf 'REFUSE: %s has no MX and no A record — mail to %s is undeliverable\n' \
               "$domain" "$addr"
           return 1 ;;
    esac

    # Domains the estate itself serves must also be ALIASED, or the address is a
    # black hole that DNS alone cannot detect.
    local manifest
    if manifest="$(moodle_mail_manifest_for "$domain" "$root")"; then
        local baseline="${manifest%/referenced-addresses.txt}/postfix-virtual"
        if ! moodle_mail_listed_in "$addr" "$manifest"; then
            printf 'REFUSE: %s is not declared in %s — the estate has not promised to deliver it\n' \
                "$addr" "${manifest#"$root"/}"
            return 1
        fi
        if [[ ! -f "$baseline" ]]; then
            printf 'CANNOT-VERIFY: %s exists but its postfix-virtual baseline does not\n' \
                "${manifest#"$root"/}"
            return 2
        fi
        if ! moodle_mail_listed_in "$addr" "$baseline"; then
            printf 'REFUSE: %s has no alias in %s — mail to it is silently discarded\n' \
                "$addr" "${baseline#"$root"/}"
            return 1
        fi
    fi

    printf 'OK: %s is deliverable\n' "$addr"
    return 0
}

################################################################################
# moodle_mail_verdict <declared> <actual>
#   OK       actual matches the declaration
#   DRIFT    actual differs (including "declared but unset live")
#   UNSET    nothing declared — this verb has no opinion
# Return code mirrors the verdict: 0 OK, 1 DRIFT, 0 UNSET (nothing to enforce).
################################################################################
moodle_mail_verdict() {
    local declared="${1:-}" actual="${2:-}"
    if [[ -z "$declared" ]]; then
        printf 'UNSET'
        return 0
    fi
    if [[ "$declared" == "$actual" ]]; then
        printf 'OK'
        return 0
    fi
    printf 'DRIFT'
    return 1
}

# The three settings this verb governs, as "<yq key>|<Moodle $CFG name>".
# supportname is included because it is displayed NEXT TO the support address
# on every "contact site support" surface; leaving it at Moodle's installer
# default ("Admin User") makes an institutional address look like a stray
# personal one.
MOODLE_MAIL_FIELDS=(
    "support_email|supportemail"
    "support_name|supportname"
    "noreply_address|noreplyaddress"
)

# Fields whose value is an ADDRESS and therefore passes through the gate.
# supportname is free text and is only checked for the dev-domain leak.
moodle_mail_field_is_address() {
    case "${1:-}" in
        supportemail|noreplyaddress) return 0 ;;
        *) return 1 ;;
    esac
}
