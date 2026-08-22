#!/usr/bin/env bash
#
# lib/dns-inventory.sh — the engine behind `pl dns list [domain]`.
#
# WHY THIS FILE EXISTS
# --------------------
# Until now there was NO WAY TO ENUMERATE DNS in this estate. DNS is a side
# effect of other verbs: `pl live <site>` creates an A record on the way past
# (scripts/commands/live.sh::add_dns_record), `pl live --delete` removes it,
# lib/podcast.sh writes a couple more, and the NS-delegation primitives in
# lib/linode.sh are exercised by hand. Nothing ever asked the provider what the
# zone actually contains.
#
# The consequence was not hypothetical. "~50 junk DNS records" appeared in TWO
# separate handovers without ever being actioned, because nothing could see
# them — and the second, worse half was never even counted: 22 lame NS
# delegations, one of which was silently NXDOMAIN-ing an A record that looked
# perfectly healthy in every other view. A record that resolves to nothing while
# reading as live is the exact shape of fault that a list you cannot enumerate
# produces.
#
# So this is the DNS counterpart of lib/served-roots.sh, and it obeys the same
# design rules, for the same reasons:
#
#  1. FAIL CLOSED ON BLINDNESS. No token, no answer from the API, an
#     unparseable body, a zone the token cannot see, or zero records is
#     CANNOT-VERIFY (rc=3) — NEVER a clean 0. An empty enumeration must never
#     read as "nothing undeclared".
#  2. NO HAND-MAINTAINED ALLOWLIST. There is no `ignore:` list in this file. A
#     name goes green by being DECLARED in the inventory the rest of `pl`
#     already reads (sites/<n>/.nwp.yml, nwp.yml, servers/<n>/.nwp-server.yml),
#     which is also what makes it visible to every other gate.
#  3. READ-ONLY BY CONSTRUCTION. Every request this file makes is a GET.
#  4. UNDECLARED IS A QUESTION, NOT A DELETE LIST. This is the load-bearing one,
#     and it is the rule that saved `pl server prune`: its first cut built the
#     delete set DOWN by subtracting a keep-list and duly proposed deleting
#     every Moodle's _moodledata, two live databases and a serving site's
#     certificate. In this zone the undeclared set contains an SSH alias the
#     operator connects through, a live third-party-hosted service on a
#     non-estate IP, and a site nginx really does serve with no .nwp.yml at all.
#     Undeclared means "nothing here explains this" — it is the beginning of an
#     investigation, and this library will never emit a removal command.
#  5. yq-FIRST for YAML (NWP-ADR-0015) and yq -p=json for the API body. No jq
#     dependency, no regex-scraping of JSON.
#
# WHAT IT GRADES RED (rc=1) — and, just as deliberately, what it does not:
#   SHADOWED-BY-NS   a name carries an NS delegation AND other records, so the
#                    delegation wins and those records are unreachable. A live-
#                    looking A record that cannot resolve.
#   MISPOINTED       a DECLARED site's A record points somewhere other than the
#                    server that site declares. (The cccrdf shape.)
# UNDECLARED and MISSING-RECORD are reported but do NOT redden the verb: a gate
# that is permanently red is a gate nobody reads, which is how a hand-maintained
# corpus came to be trusted in the first place.

# ---------------------------------------------------------------------------
# dns_inv_domains TOKEN
#   Prints one "id<TAB>domain" line per zone visible to the token.
#   rc=3 on blindness (no answer / unparseable / no zones).
# ---------------------------------------------------------------------------
dns_inv_domains() {
    local token="$1"
    local yq="${YQ:-yq}"
    local raw body code rc

    raw=$(linode_api_get "$token" "/v4/domains?page_size=500"); rc=$?
    code=$(linode_api_code "$raw"); body=$(linode_api_body "$raw")
    if [ "$rc" -ne 0 ] || [ "$code" = "000" ]; then
        printf 'CANNOT-VERIFY: no answer from the Linode API listing domains — this is NOT "no zones"\n' >&2
        return 3
    fi
    if [ "$code" != "200" ]; then
        printf 'CANNOT-VERIFY: Linode API returned HTTP %s listing domains\n' "$code" >&2
        return 3
    fi

    local out
    out=$(printf '%s' "$body" | "$yq" -p=json -r '.data[]? | [(.id), (.domain)] | @tsv' 2>/dev/null)
    if [ -z "$out" ]; then
        printf 'CANNOT-VERIFY: could not parse the domain list from the Linode API\n' >&2
        return 3
    fi
    printf '%s\n' "$out"
    return 0
}

# ---------------------------------------------------------------------------
# dns_inv_records TOKEN DOMAIN_ID
#   Prints one TSV line per record: id, type, name, target, ttl_sec.
#   The zone APEX is emitted as the name "@", never as an empty field. That is
#   not cosmetic: `IFS=$'\t' read` treats TAB as IFS *whitespace*, so consecutive
#   tabs collapse into one and an empty middle field silently shifts every
#   later column left. The apex MX then reads as a host called
#   "git.example.org" pointing at "300" — wrong, and wrong in a way that looks
#   like data rather than like a bug.
#   rc=3 on blindness, INCLUDING a zero-record answer.
# ---------------------------------------------------------------------------
dns_inv_records() {
    local token="$1" domain_id="$2"
    local yq="${YQ:-yq}"
    local raw body code rc

    raw=$(linode_api_get "$token" "/v4/domains/${domain_id}/records?page_size=500"); rc=$?
    code=$(linode_api_code "$raw"); body=$(linode_api_body "$raw")
    if [ "$rc" -ne 0 ] || [ "$code" = "000" ]; then
        printf 'CANNOT-VERIFY: no answer from the Linode API reading zone %s\n' "$domain_id" >&2
        return 3
    fi
    if [ "$code" != "200" ]; then
        printf 'CANNOT-VERIFY: Linode API returned HTTP %s reading zone %s\n' \
            "$code" "$domain_id" >&2
        return 3
    fi

    # `results` is authoritative for the page count; if it exceeds what we were
    # handed we are looking at a PARTIAL zone and must not grade it.
    local results pages
    results=$(printf '%s' "$body" | "$yq" -p=json -r '.results // ""' 2>/dev/null)
    pages=$(printf '%s' "$body" | "$yq" -p=json -r '.pages // ""' 2>/dev/null)
    if [ -n "$pages" ] && [ "$pages" != "null" ] && [ "$pages" -gt 1 ] 2>/dev/null; then
        printf 'CANNOT-VERIFY: zone %s returned %s pages — the enumeration would be partial\n' \
            "$domain_id" "$pages" >&2
        return 3
    fi

    local out
    out=$(printf '%s' "$body" | "$yq" -p=json -r \
        '.data[]? | [(.id), (.type), (.name | select(. != "") // "@"), (.target), (.ttl_sec)] | @tsv' 2>/dev/null)
    if [ -z "$out" ]; then
        printf 'CANNOT-VERIFY: zone %s enumerated ZERO records — an empty zone read is not a clean zone\n' \
            "$domain_id" >&2
        return 3
    fi
    if [ -n "$results" ] && [ "$results" != "null" ]; then
        local got; got=$(printf '%s\n' "$out" | wc -l)
        if [ "$got" -ne "$results" ] 2>/dev/null; then
            printf 'CANNOT-VERIFY: zone %s says %s records but %s parsed — refusing to grade a partial read\n' \
                "$domain_id" "$results" "$got" >&2
            return 3
        fi
    fi
    printf '%s\n' "$out"
    return 0
}

# ---------------------------------------------------------------------------
# Declaration loading — yq only (NWP-ADR-0015).
#
# Populates, in the caller's scope:
#   DNS_DECL_SRC[fqdn]   where the declaration lives (human-readable)
#   DNS_DECL_IP[fqdn]    the IP that declaration implies, or "" if it implies
#                        none. Empty means "declared, but nothing says where" —
#                        which is NOT the same as "declared to point at 0.0.0.0"
#                        and must never produce a MISPOINTED finding.
#   DNS_DECL_KIND[fqdn]  "site" or "infra". Only a SITE declaration promises
#                        that a host record should exist: a server declaring
#                        `domain: example.org` declares the ZONE, and a zone
#                        apex is not obliged to carry an A record.
#
# Sources, in the order a human would look:
#   nwp.yml                    .sites[].live.{domain,server,server_ip}
#   sites/<n>/.nwp.yml         .live.{domain,server,server_ip}   (wins on merge)
#   servers/<n>/.nwp-server.yml  .server.{domain,ip}
#                                .infrastructure_roots[].domain (→ server ip)
#   nwp.yml                    .settings.console.{fqdn,tailnet_ip}
#                              .settings.console.headscale_url  (host part)
#   .secrets.yml               .gitlab.server.domain  (the forge host; read at
#                              runtime only — the live domain stays out of git,
#                              exactly as lib/gitlab-issues.sh::_host does it)
#
# A server's own `.server.domain` is what declares the zone APEX: the live
# server record declares the estate apex, which is why the apex MX/TXT records
# reconcile instead
# of showing up as unexplained.
#
# WHICH IP A DECLARATION IMPLIES — `.live.server` BEATS `.live.server_ip`.
# The symbolic name is a reference into servers/<n>/.nwp-server.yml, the record
# an operator maintains; `server_ip` is a CACHED LITERAL that the 2026-07-31 box
# split left stale in several site configs (nwc, sso, avctest and cccrdf all
# still carry the old box's address while declaring `server: live`). Believing
# the literal would have reported three correctly-pointed live sites as
# mispointed and, worse, would have said nothing about cccrdf — the one that
# really is pointing at the wrong box. Resolve the reference; fall back to the
# literal only when there is no server record to resolve.
# ---------------------------------------------------------------------------
dns_inv_declarations() {
    local root="$1"
    local yq="${YQ:-yq}"
    DNS_DECL_SRC=(); DNS_DECL_IP=(); DNS_DECL_KIND=()

    local name domain srv srv_ip cfg ip

    _dns_decl_add() { # fqdn source ip kind
        local f="${1,,}" s="$2" i="${3:-}" k="${4:-infra}"
        [ -n "$f" ] || return 0
        f="${f%.}"
        case "$f" in ""|null|"~") return 0 ;; esac
        # First declaration wins for the source string, but a later one may fill
        # in an IP the first left empty.
        if [ -n "${DNS_DECL_SRC[$f]+x}" ]; then
            [ -z "${DNS_DECL_IP[$f]}" ] && [ -n "$i" ] && DNS_DECL_IP["$f"]="$i"
            [ "${DNS_DECL_KIND[$f]}" = "infra" ] && [ "$k" = "site" ] && DNS_DECL_KIND["$f"]="site"
            return 0
        fi
        DNS_DECL_SRC["$f"]="$s"
        DNS_DECL_IP["$f"]="$i"
        DNS_DECL_KIND["$f"]="$k"
    }

    # --- the global inventory ------------------------------------------------
    local gcfg="$root/nwp.yml"
    if [ -f "$gcfg" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            domain=$(n="$name" "$yq" -r '.sites[strenv(n)].live.domain // ""' "$gcfg" 2>/dev/null)
            [ -n "$domain" ] && [ "$domain" != "null" ] || continue
            srv=$(n="$name" "$yq" -r '.sites[strenv(n)].live.server // ""' "$gcfg" 2>/dev/null)
            srv_ip=$(n="$name" "$yq" -r '.sites[strenv(n)].live.server_ip // ""' "$gcfg" 2>/dev/null)
            srv_ip=$(_dns_expected_ip "$root" "$srv" "$srv_ip")
            _dns_decl_add "$domain" "nwp.yml sites.$name" "$srv_ip" site
        done < <("$yq" -r '.sites // {} | keys | .[]' "$gcfg" 2>/dev/null)
    fi

    # --- per-site configs (authoritative where they disagree) ----------------
    for cfg in "$root"/sites/*/.nwp.yml; do
        [ -f "$cfg" ] || continue
        name="$(basename "$(dirname "$cfg")")"
        domain=$("$yq" -r '.live.domain // ""' "$cfg" 2>/dev/null)
        [ -n "$domain" ] && [ "$domain" != "null" ] || continue
        srv=$("$yq" -r '.live.server // ""' "$cfg" 2>/dev/null)
        srv_ip=$("$yq" -r '.live.server_ip // ""' "$cfg" 2>/dev/null)
        srv_ip=$(_dns_expected_ip "$root" "$srv" "$srv_ip")
        local key="${domain,,}"; key="${key%.}"
        # The per-site config wins outright: it is the file `pl` gates read.
        DNS_DECL_SRC["$key"]="sites/$name/.nwp.yml"
        DNS_DECL_KIND["$key"]="site"
        if [ -n "$srv_ip" ] || [ -z "${DNS_DECL_IP[$key]+x}" ]; then
            DNS_DECL_IP["$key"]="$srv_ip"
        fi
    done

    # --- server inventory: the zone apex + infrastructure names --------------
    local sdir
    for sdir in "$root"/servers/*/; do
        [ -d "$sdir" ] || continue
        cfg="$sdir/.nwp-server.yml"
        [ -f "$cfg" ] || continue
        name="$(basename "$sdir")"
        ip=$("$yq" -r '.server.ip // ""' "$cfg" 2>/dev/null)
        domain=$("$yq" -r '.server.domain // ""' "$cfg" 2>/dev/null)
        [ -n "$domain" ] && [ "$domain" != "null" ] && \
            _dns_decl_add "$domain" "servers/$name/.nwp-server.yml" "$ip" infra
        while IFS= read -r domain; do
            [ -n "$domain" ] && [ "$domain" != "null" ] && \
                _dns_decl_add "$domain" "servers/$name/.nwp-server.yml infrastructure_roots" "$ip" site
        done < <("$yq" -r '.infrastructure_roots // [] | .[] | .domain // ""' "$cfg" 2>/dev/null)
    done

    # --- the forge host, declared in .secrets.yml ----------------------------
    # Read at runtime, never written down: lib/gitlab-issues.sh does the same,
    # and .gitleaks.toml is why. Without this the GitLab host — the most
    # load-bearing A record in the zone and the target of its only MX — reads
    # UNDECLARED, which is precisely the false alarm that trains an operator to
    # stop reading the column.
    local sfile="${NWP_SECRETS_FILE:-$root/.secrets.yml}"
    if [ -f "$sfile" ]; then
        domain=$("$yq" -r '.gitlab.server.domain // ""' "$sfile" 2>/dev/null)
        [ -n "$domain" ] && [ "$domain" != "null" ] && \
            _dns_decl_add "$domain" ".secrets.yml gitlab.server.domain" "" site
    fi

    # --- console / mesh settings --------------------------------------------
    if [ -f "$gcfg" ]; then
        domain=$("$yq" -r '.settings.console.fqdn // ""' "$gcfg" 2>/dev/null)
        ip=$("$yq" -r '.settings.console.tailnet_ip // ""' "$gcfg" 2>/dev/null)
        [ -n "$domain" ] && [ "$domain" != "null" ] && \
            _dns_decl_add "$domain" "nwp.yml settings.console.fqdn" "$ip" site
        domain=$("$yq" -r '.settings.console.headscale_url // ""' "$gcfg" 2>/dev/null)
        domain="${domain#http://}"; domain="${domain#https://}"; domain="${domain%%/*}"
        [ -n "$domain" ] && [ "$domain" != "null" ] && \
            _dns_decl_add "$domain" "nwp.yml settings.console.headscale_url" "" site
    fi

    unset -f _dns_decl_add
    return 0
}

# Resolve a server name to its declared IP without depending on
# lib/server-resolver.sh having been sourced (this lib is used by a command that
# deliberately loads very little).
_dns_server_ip() {
    local root="$1" srv="$2"
    local yq="${YQ:-yq}"
    [ -n "$srv" ] && [ "$srv" != "null" ] || return 0
    local cfg="$root/servers/$srv/.nwp-server.yml"
    [ -f "$cfg" ] || return 0
    "$yq" -r '.server.ip // ""' "$cfg" 2>/dev/null | grep -v '^null$' || true
}

# The IP a declaration implies: the resolved server record first, the cached
# literal only as a fallback. See the header note on why that order matters.
_dns_expected_ip() {
    local root="$1" srv="$2" literal="$3" resolved
    resolved=$(_dns_server_ip "$root" "$srv")
    if [ -n "$resolved" ]; then printf '%s' "$resolved"; return 0; fi
    case "$literal" in ""|null) printf '' ;; *) printf '%s' "$literal" ;; esac
}

# ---------------------------------------------------------------------------
# dns_inv_fqdn NAME DOMAIN — the fully-qualified name of a record.
# Linode stores the apex as an empty name; some tooling shows it as "@".
# ---------------------------------------------------------------------------
dns_inv_fqdn() {
    local name="$1" domain="$2"
    case "$name" in
        ""|"@") printf '%s' "$domain" ;;
        *.)     printf '%s' "${name%.}" ;;
        *)      printf '%s.%s' "$name" "$domain" ;;
    esac
}
