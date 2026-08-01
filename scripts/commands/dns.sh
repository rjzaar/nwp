#!/usr/bin/env bash
# scripts/commands/dns.sh
#
# `pl dns` — enumeration of the estate's DNS, reconciled against what NWP
# declares, plus a guarded removal path for records PROVEN dead.
#
# Usage:
#   pl dns list                 Every zone the DNS token can see (READ-ONLY)
#   pl dns list <domain>        One zone
#   pl dns list --json          Machine-readable (the same classification)
#   pl dns rm <domain> <id>...  Remove records BY ID — dry-run unless --execute
#
# WHY THIS VERB EXISTS
# --------------------
# There was no way to enumerate DNS in this estate. DNS is a side effect of
# other verbs — `pl live <site>` creates an A record on the way past, `pl live
# --delete` removes it, the NS-delegation primitives in lib/linode.sh get
# exercised by hand — and nothing ever asked the provider what the zone
# contains. "~50 junk DNS records" therefore appeared in two consecutive
# handovers without being actioned, and the worse half of the drift (22 lame NS
# delegations, one of them silently NXDOMAIN-ing a healthy-looking A record) was
# never even counted.
#
# This verb answers, in one screen: WHAT POINTS WHERE, AND IS IT DECLARED?
#
# `list` writes nothing. Every request it makes is a GET. It will never print a
# removal command, because the DECLARED/UNDECLARED column is not a delete list —
# see lib/dns-inventory.sh design rule 4, and `pl server prune`, whose first cut
# built its delete set by subtracting a keep-list and proposed deleting two live
# databases and a serving site's certificate.
#
# `rm` (nwp/ops#176) is the apply path `list` deliberately is not. Before it,
# removing a proven-dead record meant hand-rolled curl against the API — the
# exact idiom the standing order forbids — so 54 fixture records outlived two
# handovers and a full audit. Its guards, in order:
#   - records are named BY ID, never by name or pattern: the caller must have
#     enumerated first (`pl dns list --json`) and must mean each one.
#   - only A / AAAA / CNAME are deletable. NS is an offboarding decision
#     (delegations belong to coders), and MX/TXT/CAA/SRV/SOA + the apex are
#     zone policy — this verb refuses all of them, always.
#   - a record whose FQDN any declaration names is refused. `rm` will not be
#     the verb that deletes a declared site's record; that is `pl live --delete`.
#   - ALL-OR-NOTHING: one refused ID aborts the whole set before any DELETE.
#     A partially applied delete list is drift with a receipt.
#   - dry-run by default; --execute asks for the zone domain typed back; every
#     record's verbatim recreation row (type name target ttl) is appended to
#     private/dns-rollback.log BEFORE its DELETE is sent.
#
# Exit codes (the `pl server roots` convention — an unknown is never a clean):
#   0  list: reconciled · rm: dry-run complete, or every record deleted
#   1  list: SHADOWED-BY-NS / MISPOINTED · rm: a refusal, a failed confirm,
#      or a DELETE that did not succeed
#   2  usage error
#   3  CANNOT-VERIFY — blindness. No token, no answer from the API, an
#      unparseable body, a zone the token cannot see, a partial page, or zero
#      records. NEVER conflated with 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NWP_DIR="${NWP_DIR:-$PROJECT_ROOT}"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/yaml-write.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/linode.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/dns-inventory.sh"

YQ="${YQ_BIN:-yq}"
if ! command -v "$YQ" &>/dev/null; then
    if [[ -x "$HOME/.local/bin/yq" ]]; then
        YQ="$HOME/.local/bin/yq"
    else
        echo "CANNOT-VERIFY: yq is required to read the API response and the inventory" >&2
        exit 3
    fi
fi
export YQ

# Record types that configure the ZONE rather than name a host. No site or
# server declaration will ever mention one, so they are reconciled against the
# zone being declared, not against the site inventory.
_dns_is_zone_policy() {
    case "$1" in MX|TXT|CAA|SRV|SOA) return 0 ;; *) return 1 ;; esac
}

# Minimal JSON string escaping. SPF/DKIM/DMARC targets are free text and a bare
# quote or backslash in one would otherwise emit a document no consumer can
# parse — a --json mode that silently produces invalid JSON is worse than none.
_dns_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//	/\\t}"
    printf '%s' "$s"
}

################################################################################
# Subcommand: list [domain] [--json]
################################################################################
cmd_list() {
    local want_domain="" as_json=0 arg
    for arg in "$@"; do
        case "$arg" in
            --json) as_json=1 ;;
            -*)     echo "Unknown option: $arg" >&2; return 2 ;;
            *)      want_domain="${arg,,}" ;;
        esac
    done

    # The token is read here and passed only into lib/linode.sh's transport,
    # which keeps it inside a 0600 curl config. It is never echoed, never
    # interpolated into a message, and never reaches argv.
    local secrets_file token
    secrets_file="${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}"
    export NWP_SECRETS_FILE="$secrets_file"
    token=$(get_linode_token "$(dirname "$secrets_file")")
    if [ -z "$token" ]; then
        echo "CANNOT-VERIFY: no linode.api_token in .secrets.yml (and no LINODE_API_TOKEN)."
        echo "               Without a credential this command knows NOTHING about the zone;"
        echo "               that is blindness, not an empty zone."
        return 3
    fi

    local zones
    if ! zones=$(dns_inv_domains "$token"); then
        return 3
    fi

    if [ -n "$want_domain" ]; then
        local filtered
        filtered=$(printf '%s\n' "$zones" | awk -F'\t' -v d="$want_domain" 'tolower($2)==d')
        if [ -z "$filtered" ]; then
            printf 'CANNOT-VERIFY: this token cannot see the zone %s.\n' "$want_domain"
            printf '               The estate has zones spread across more than one provider\n'
            printf '               account, so "not visible to this token" is NOT "not there".\n'
            return 3
        fi
        zones="$filtered"
    fi

    local rc=0 zid zdom first=1
    [ "$as_json" -eq 1 ] && printf '{\n  "generated": "%s",\n  "zones": [\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    while IFS=$'\t' read -r zid zdom; do
        [ -n "$zid" ] || continue
        if [ "$as_json" -eq 1 ]; then
            [ "$first" -eq 0 ] && printf ',\n'
            first=0
        fi
        _list_zone "$token" "$zid" "$zdom" "$as_json" || rc=$?
    done <<< "$zones"
    [ "$as_json" -eq 1 ] && printf '\n  ]\n}\n'

    return "$rc"
}

# _list_zone TOKEN ZONE_ID ZONE_DOMAIN AS_JSON
_list_zone() {
    local token="$1" zid="$2" zdom="$3" as_json="$4"

    local records
    if ! records=$(dns_inv_records "$token" "$zid"); then
        return 3
    fi
    # Grouped by type, then by name — the order an operator reads a zone in.
    records=$(printf '%s\n' "$records" | sort -t$'\t' -k2,2 -k3,3)

    local -A DNS_DECL_SRC=() DNS_DECL_IP=() DNS_DECL_KIND=()
    dns_inv_declarations "$NWP_DIR"

    # Names carrying an NS delegation. A delegation hands the whole name to
    # another nameserver, so ANY other record on that name is unreachable —
    # which is how a perfectly good A record ends up NXDOMAIN while looking
    # correct in every list that does not cross-check the two.
    local -A ns_names=()
    local id type name target ttl
    while IFS=$'\t' read -r id type name target ttl; do
        [ "$type" = "NS" ] && [ "$name" != "@" ] && ns_names["${name,,}"]=1
    done <<< "$records"

    # Names present in the zone, for the reverse check (declared, no record).
    local -A have_fqdn=()
    while IFS=$'\t' read -r id type name target ttl; do
        case "$type" in A|AAAA|CNAME) have_fqdn["$(dns_inv_fqdn "${name,,}" "$zdom")"]=1 ;; esac
    done <<< "$records"

    local total=0 declared=0 undeclared=0 shadowed=0 mispointed=0 missing=0
    local -a findings=()
    local rows="" jrows=""

    while IFS=$'\t' read -r id type name target ttl; do
        [ -n "$id" ] || continue
        total=$((total + 1))
        local fqdn status src note
        fqdn=$(dns_inv_fqdn "${name,,}" "$zdom")
        if [ -n "${DNS_DECL_SRC[$fqdn]+x}" ]; then
            status="DECLARED"; src="${DNS_DECL_SRC[$fqdn]}"; declared=$((declared + 1))
        elif _dns_is_zone_policy "$type" && [ -n "${DNS_DECL_SRC[$zdom]+x}" ]; then
            # MX / TXT / SPF / DKIM / DMARC / CAA / SRV are ZONE POLICY, not
            # hosts. No site declares them and none ever will, so grading them
            # against the site inventory would put the estate's mail records in
            # the same column as `bats-test-backup` — 4 permanent false alarms
            # in a list whose only job is to make the real ones visible. They
            # reconcile against the ZONE being declared (servers/*/.nwp-server.yml
            # `domain:`), and `pl monitor mail <site>` is the verb that actually
            # validates their contents.
            status="ZONE-INFRA"; src="zone policy for ${zdom} (${DNS_DECL_SRC[$zdom]})"
            declared=$((declared + 1))
        else
            status="UNDECLARED"; src="—"; undeclared=$((undeclared + 1))
        fi

        note=""
        # (1) SHADOWED-BY-NS — the lame-delegation fault. RED.
        if [ "$type" != "NS" ] && [ "$name" != "@" ] && [ -n "${ns_names[${name,,}]+x}" ]; then
            note="SHADOWED-BY-NS"
            shadowed=$((shadowed + 1))
            findings+=("  SHADOWED-BY-NS        ${fqdn} (${type} → ${target}) is unreachable: an NS record on the")
            findings+=("                        same name delegates it away, so the delegation answers first.")
        fi
        # (2) MISPOINTED — declared, but not at the server it declares. RED.
        if [ "$type" = "A" ] && [ "$status" = "DECLARED" ] && [ -n "${DNS_DECL_IP[$fqdn]:-}" ] \
           && [ "${DNS_DECL_IP[$fqdn]}" != "$target" ]; then
            note="${note:+$note }MISPOINTED"
            mispointed=$((mispointed + 1))
            findings+=("  MISPOINTED            ${fqdn} → ${target}, but ${src} declares ${DNS_DECL_IP[$fqdn]}")
        fi
        # (3) An NS delegation below the apex is worth naming even when nothing
        #     is shadowed: it hands a name to a nameserver that may hold no zone
        #     for it, and a lame delegation is invisible until someone reuses
        #     the name.
        if [ "$type" = "NS" ] && [ "$name" != "@" ]; then
            note="${note:+$note }SUBZONE-DELEGATION"
        fi

        if [ "$as_json" -eq 1 ]; then
            jrows+=$(printf '      {"id": %s, "type": "%s", "name": "%s", "fqdn": "%s", "target": "%s", "ttl": %s, "status": "%s", "declared_in": "%s", "flags": "%s"},\n' \
                "$id" "$(_dns_json_escape "$type")" "$(_dns_json_escape "$name")" \
                "$(_dns_json_escape "$fqdn")" "$(_dns_json_escape "$target")" "${ttl:-0}" \
                "$status" "$(_dns_json_escape "$src")" "$note")
        else
            rows+=$(printf '  %-24s %-5s %-32.32s %-6s %-11s %s\n' \
                "$name" "$type" "$target" "${ttl:-0}" "$status" "${note:+[$note] }$src")
            rows+=$'\n'
        fi
    done <<< "$records"

    # (4) DECLARED, but no record in the zone. WARN, not red: a declaration for
    #     a site that has not been provisioned yet is legitimate and routine.
    #     It is still worth a line — the declaration and the world disagree.
    local d
    for d in "${!DNS_DECL_SRC[@]}"; do
        case "$d" in
            *".$zdom") ;;
            *) continue ;;   # the apex itself is the ZONE, not a host: a zone
                             # is under no obligation to carry an A record
        esac
        # Only a SITE declaration promises a host record exists.
        [ "${DNS_DECL_KIND[$d]:-infra}" = "site" ] || continue
        [ -n "${have_fqdn[$d]+x}" ] && continue
        missing=$((missing + 1))
        findings+=("  WARN MISSING-RECORD   ${d} is declared in ${DNS_DECL_SRC[$d]} but has no A/AAAA/CNAME in this zone")
    done

    if [ "$as_json" -eq 1 ]; then
        printf '    {\n      "domain": "%s",\n      "id": %s,\n      "total": %s,\n      "declared": %s,\n      "undeclared": %s,\n      "shadowed": %s,\n      "mispointed": %s,\n      "missing": %s,\n      "records": [\n%s\n      ]\n    }' \
            "$zdom" "$zid" "$total" "$declared" "$undeclared" "$shadowed" "$mispointed" "$missing" \
            "$(printf '%s' "$jrows" | sed '$ s/,$//')"
    else
        printf '\nzone %s (id %s): %d records — %d declared, %d undeclared\n\n' \
            "$zdom" "$zid" "$total" "$declared" "$undeclared"
        printf '  %-24s %-5s %-32s %-6s %-11s %s\n' NAME TYPE TARGET TTL STATUS 'DECLARED IN / FLAGS'
        printf '  %-24s %-5s %-32s %-6s %-11s %s\n' ------------------------ ----- -------------------------------- ------ ----------- -------------------
        printf '%s' "$rows"
        echo
        if [ ${#findings[@]} -gt 0 ]; then
            printf '%s\n' "${findings[@]}"
            echo
        fi
        cat <<'EOF'
  DECLARED    a site/server/console declaration names this host.
  ZONE-INFRA  zone policy (MX/TXT/SPF/DKIM/DMARC/CAA) for a declared zone;
              `pl monitor mail <site>` is what validates the contents.
  UNDECLARED  nothing in nwp.yml, sites/*/.nwp.yml, servers/*/ or the console
              settings explains this name.

  UNDECLARED IS A QUESTION, NOT A DELETE LIST. SSH aliases the operator connects
  through, third-party-hosted services on non-estate IPs, and sites nginx really
  does serve without a .nwp.yml are all legitimately undeclared — and all three
  are in this zone right now. Build a delete set UP from records you have proven
  dead; never DOWN by subtracting a keep-list.
EOF
    fi

    if [ "$shadowed" -gt 0 ] || [ "$mispointed" -gt 0 ]; then
        [ "$as_json" -eq 0 ] && printf '\nRESULT: %d shadowed, %d mispointed (%d undeclared, %d missing) — FAIL\n' \
            "$shadowed" "$mispointed" "$undeclared" "$missing"
        return 1
    fi
    [ "$as_json" -eq 0 ] && printf '\nRESULT: every record resolves as written and every declaration points at the server it declares (%d undeclared, %d missing)\n' \
        "$undeclared" "$missing"
    return 0
}

################################################################################
# Subcommand: rm <domain> <record-id>... [--execute] [--yes]
################################################################################
# The guarded apply path. See the header block for the guard rationale; the
# shape of every check is "prove the record is one this verb is allowed to
# touch, or refuse the WHOLE set".
cmd_rm() {
    local domain="" execute=0 yes=0 arg
    local -a want_ids=()
    for arg in "$@"; do
        case "$arg" in
            --execute) execute=1 ;;
            --yes)     yes=1 ;;
            -*)        echo "Unknown option: $arg" >&2; return 2 ;;
            *)
                if [ -z "$domain" ]; then
                    domain="${arg,,}"
                elif [[ "$arg" =~ ^[0-9]+$ ]]; then
                    want_ids+=("$arg")
                else
                    echo "Records are removed BY NUMERIC ID, not by name: '$arg'." >&2
                    echo "Enumerate first: pl dns list ${domain} --json" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [ -z "$domain" ] || [ "${#want_ids[@]}" -eq 0 ]; then
        echo "Usage: pl dns rm <domain> <record-id>... [--execute] [--yes]" >&2
        return 2
    fi

    # Same credential path as cmd_list: the token travels only inside
    # lib/linode.sh's 0600 curl config, never argv, never output.
    local secrets_file token
    secrets_file="${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}"
    export NWP_SECRETS_FILE="$secrets_file"
    token=$(get_linode_token "$(dirname "$secrets_file")")
    if [ -z "$token" ]; then
        echo "CANNOT-VERIFY: no linode.api_token in .secrets.yml (and no LINODE_API_TOKEN)."
        return 3
    fi

    local zones zid zdom
    zones=$(dns_inv_domains "$token") || return 3
    IFS=$'\t' read -r zid zdom < <(printf '%s\n' "$zones" | awk -F'\t' -v d="$domain" 'tolower($2)==d')
    if [ -z "${zid:-}" ]; then
        printf 'CANNOT-VERIFY: this token cannot see the zone %s.\n' "$domain"
        return 3
    fi

    local records
    records=$(dns_inv_records "$token" "$zid") || return 3

    local -A DNS_DECL_SRC=() DNS_DECL_IP=() DNS_DECL_KIND=()
    dns_inv_declarations "$NWP_DIR"

    # Every requested ID must be found, of a deletable type, and undeclared.
    # Refusals do not shrink the set — they abort it.
    local -a refusals=() rollback=()
    local rid found id type name target ttl fqdn
    for rid in "${want_ids[@]}"; do
        found=""
        while IFS=$'\t' read -r id type name target ttl; do
            [ "$id" = "$rid" ] && { found="$id"$'\t'"$type"$'\t'"$name"$'\t'"$target"$'\t'"$ttl"; break; }
        done <<< "$records"
        if [ -z "$found" ]; then
            refusals+=("  REFUSED  id ${rid}: not in zone ${zdom} — already gone, or the wrong zone. Refusing to guess.")
            continue
        fi
        IFS=$'\t' read -r id type name target ttl <<< "$found"
        fqdn=$(dns_inv_fqdn "${name,,}" "$zdom")
        case "$type" in
            A|AAAA|CNAME) ;;
            NS)
                refusals+=("  REFUSED  id ${rid} (NS ${fqdn}): a delegation is an offboarding decision, not a prune. Not this verb.")
                continue ;;
            *)
                refusals+=("  REFUSED  id ${rid} (${type} ${fqdn}): zone policy. \`pl monitor mail\` validates these; nothing deletes them.")
                continue ;;
        esac
        if [ "$name" = "@" ] || [ -z "$name" ]; then
            refusals+=("  REFUSED  id ${rid}: the apex is the zone, not a host.")
            continue
        fi
        if [ -n "${DNS_DECL_SRC[$fqdn]+x}" ]; then
            refusals+=("  REFUSED  id ${rid} (${type} ${fqdn}): DECLARED in ${DNS_DECL_SRC[$fqdn]}. A declared site's record is \`pl live --delete\`'s to remove, with its declaration.")
            continue
        fi
        rollback+=("$id"$'\t'"$type"$'\t'"$name"$'\t'"$target"$'\t'"${ttl:-0}")
    done

    if [ "${#refusals[@]}" -gt 0 ]; then
        printf 'ALL-OR-NOTHING: %d of %d requested records refused — NOTHING was deleted.\n\n' \
            "${#refusals[@]}" "${#want_ids[@]}"
        printf '%s\n' "${refusals[@]}"
        return 1
    fi

    printf 'zone %s (id %s): %d record(s) selected for removal\n\n' "$zdom" "$zid" "${#rollback[@]}"
    printf '  %-10s %-6s %-24s %-32s %s\n' ID TYPE NAME TARGET TTL
    local row
    for row in "${rollback[@]}"; do
        IFS=$'\t' read -r id type name target ttl <<< "$row"
        printf '  %-10s %-6s %-24s %-32s %s\n' "$id" "$type" "$name" "$target" "$ttl"
    done

    if [ "$execute" -eq 0 ]; then
        printf '\nDRY RUN — nothing deleted. The rows above are the verbatim recreation data;\n'
        printf 're-run with --execute to apply.\n'
        return 0
    fi

    if [ "$yes" -eq 0 ]; then
        local typed
        printf '\nType the zone domain (%s) to confirm deletion of %d record(s): ' "$zdom" "${#rollback[@]}"
        read -r typed
        if [ "$typed" != "$zdom" ]; then
            echo "Confirmation did not match — NOTHING was deleted."
            return 1
        fi
    fi

    # The ledger row is written BEFORE the DELETE is sent: a deletion that
    # cannot be recreated verbatim is not allowed to happen.
    local ledger="$NWP_DIR/private/dns-rollback.log"
    mkdir -p "$(dirname "$ledger")"
    local now failed=0 deleted=0
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for row in "${rollback[@]}"; do
        IFS=$'\t' read -r id type name target ttl <<< "$row"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$now" "$zdom" "$zid" "$id" "$type" "$name" "$target" "$ttl" >> "$ledger"
        if linode_delete_dns_record "$token" "$zid" "$id"; then
            deleted=$((deleted + 1))
        else
            failed=$((failed + 1))
            echo "  FAILED   id ${id} (${type} ${name}) — NOT deleted; ledger row stands for the attempt." >&2
        fi
    done

    printf '\n%d deleted, %d failed — rollback rows in %s\n' "$deleted" "$failed" "$ledger"
    [ "$failed" -eq 0 ] || return 1
    return 0
}

################################################################################
# Dispatcher
################################################################################
sub="${1:-}"
shift || true

case "$sub" in
    list) cmd_list "$@" ;;
    rm)   cmd_rm "$@" ;;
    ""|help|--help|-h)
        cat <<'EOF'
Usage: pl dns <subcommand> [args]

Subcommands:
  list [domain] [--json]   READ-ONLY: every DNS record the estate's DNS token can
                           see, reconciled against what NWP declares. Answers
                           "what points where, and is it declared?".
                           Exit 1 = a record shadowed by an NS delegation, or a
                           declared site pointing at the wrong server.
                           Exit 3 = CANNOT-VERIFY (no token, no answer, partial
                           read) — never treated as a clean zone.

  rm <domain> <id>... [--execute] [--yes]
                           Remove records BY NUMERIC ID (enumerate first with
                           `pl dns list <domain> --json`). Dry-run by default.
                           Refuses, and refuses the WHOLE set: NS records, zone
                           policy (MX/TXT/CAA/SRV/SOA, the apex), any DECLARED
                           record, any ID not in the zone. --execute asks for
                           the domain typed back (--yes skips); every record's
                           recreation row is appended to private/dns-rollback.log
                           BEFORE its DELETE is sent.

`list` writes nothing: every request it makes is a GET, and its
DECLARED/UNDECLARED column is a reconciliation, not a delete list. `rm` is the
one apply path, and it only accepts records the caller has already enumerated
and proven — see nwp/ops#176.
EOF
        ;;
    *)
        echo "Unknown subcommand: $sub" >&2
        echo "Run 'pl dns help' for usage." >&2
        exit 2
        ;;
esac
