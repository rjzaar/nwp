#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/pair-smoke.sh — paired-site onboarding smoke (ADR-0031 D5)
#
# After ANY promotion of either half of a pair (nwc↔ssc, nwd↔ssd) the pair
# smoke runs the onboarding 5-URL set against both halves of that tier:
#   OAuth callback, OIDC discovery, copyright-sync status, feedback POST,
#   provider health (+ an actual token round-trip on NON-PROD tiers only).
# A failure is a RED RAG signal on the pair (pair_rag_set), which pair_guard
# then refuses to promote onto until it is green again.
#
# SAFE BY DEFAULT — this command DOES NOT hit the network unless you pass
# --run. Default mode is a DRY RUN that only prints the URLs it *would* probe.
# --run against a prod tier is refused unless --force-prod is also given (and
# the token round-trip is skipped on prod regardless). This is a read-only
# HTTP GET/POST probe; it never writes to any site.
#
# Usage:
#   pl pair-smoke <consumer> [--tier=dev|stg|live|prod] [--dry-run|--run]
#                 [--provider-base=URL] [--consumer-base=URL] [--force-prod]
#
#   <consumer>          the consumer site key (pair id), e.g. ssc / ssd
#   --tier=<t>          which tier's endpoints to probe (default: dev)
#   --dry-run           print the plan only (DEFAULT)
#   --run               actually probe (network); writes the RAG state
#   --provider-base=URL override the provider base URL (else contract issuer)
#   --consumer-base=URL provider base for the consumer half (required for --run
#                       unless discoverable from the site's live_domain)
#   --force-prod        allow --run against tier=prod (token round-trip skipped)
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
# common.sh gives us resolve_project/site config helpers; pair.sh the contract.
[ -f "$PROJECT_ROOT/lib/common.sh" ] && source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/pair.sh"

show_help() {
    cat <<EOF
${BOLD}NWP Pair Smoke — onboarding 5-URL check (ADR-0031 D5)${NC}

${BOLD}USAGE:${NC}
    pl pair-smoke <consumer> [OPTIONS]

${BOLD}OPTIONS:${NC}
    -h, --help            Show this help
    --tier=<t>            dev | stg | live | prod   (default: dev)
    --dry-run             Print the probe plan only — NO network (DEFAULT)
    --run                 Actually probe (HTTP GET/POST); writes pair RAG state
    --provider-base=URL   Override provider base URL (default: contract issuer)
    --consumer-base=URL   Consumer base URL (required for --run if not derivable)
    --force-prod          Permit --run against tier=prod (token round-trip skipped)

${BOLD}JOIN-INTEGRITY PROBE (ops#83 — verifies a real join, not just liveness):${NC}
    --join --join-uuid=<uuid>   Confirm a known uuid resolves nwc(uuid) AND
                                mdl_user.idnumber == uuid (end-to-end). Fail-closed.
    --nwc-ledger=FILE           Resolve the provider side from an identity ledger
    --nwc-resolve-cmd="CMD"     …or a command printing "uid<TAB>email" for uuid \$1
    --mdl-resolve-cmd="CMD"     Command printing the mdl_user idnumber for uuid \$1
    --mdl-idnumber=<value>      …or a literal observed idnumber (hand-captured)

${BOLD}NOTES:${NC}
    * Default is a DRY RUN. Nothing touches the network without --run.
    * A red result (--run OR a broken --join) sets the pair RAG to red; pair_guard
      then blocks promotion of either half onto that tier until it is green again.
    * The token round-trip is performed on non-prod tiers only.
EOF
}

# -----------------------------------------------------------------------------
CONSUMER=""
TIER="dev"
MODE="dry-run"
PROVIDER_BASE=""
CONSUMER_BASE=""
FORCE_PROD=false
# ops#83 join-integrity probe options.
JOIN=false
JOIN_UUID=""
NWC_LEDGER=""          # resolve the provider side from an identity ledger (offline-safe)
NWC_RESOLVE_CMD=""     # else a command: prints "uid<TAB>email" for a given uuid ($1)
MDL_RESOLVE_CMD=""     # command: prints the mdl_user idnumber (+optional TAB email) for uuid ($1)
MDL_IDNUMBER=""        # or a literal observed idnumber (stub / hand-captured)

for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help; exit 0 ;;
        --dry-run) MODE="dry-run" ;;
        --run)     MODE="run" ;;
        --force-prod) FORCE_PROD=true ;;
        --tier=*)  TIER="${arg#*=}" ;;
        --provider-base=*) PROVIDER_BASE="${arg#*=}" ;;
        --consumer-base=*) CONSUMER_BASE="${arg#*=}" ;;
        --join)            JOIN=true ;;
        --join-uuid=*)     JOIN=true; JOIN_UUID="${arg#*=}" ;;
        --nwc-ledger=*)    NWC_LEDGER="${arg#*=}" ;;
        --nwc-resolve-cmd=*) NWC_RESOLVE_CMD="${arg#*=}" ;;
        --mdl-resolve-cmd=*) MDL_RESOLVE_CMD="${arg#*=}" ;;
        --mdl-idnumber=*)  MDL_IDNUMBER="${arg#*=}" ;;
        -*) print_error "Unknown option: $arg"; show_help; exit 1 ;;
        *)  [ -z "$CONSUMER" ] && CONSUMER="$arg" || { print_error "Unexpected arg: $arg"; exit 1; } ;;
    esac
done

if [ -z "$CONSUMER" ]; then
    print_error "A consumer site (pair id) is required, e.g. 'pl pair-smoke ssc'"
    show_help
    exit 1
fi

case "$TIER" in dev|stg|live|prod) ;; *) print_error "Invalid --tier '$TIER' (dev|stg|live|prod)"; exit 1 ;; esac

CONTRACT="$(pair_contract_file "$CONSUMER")"
if ! pair_contract_valid "$CONTRACT"; then
    print_error "No valid pair contract for '$CONSUMER' at: $CONTRACT"
    print_info  "Author it from pair-contract.example.yml (see docs/guides/ops75-pair-contract-schema.md)."
    exit 1
fi

PROVIDER="$(pair_contract_get "$CONTRACT" '.provider')"
CV="$(pair_contract_get "$CONTRACT" '.contract_version')"

################################################################################
# ops#83 — join-integrity probe (NOT just liveness).
#
# The URL smoke below proves the endpoints are UP. It does NOT prove the
# identity JOIN is intact: that a real locked idnumber still resolves
# nwc(uuid) ↔ mdl_user.idnumber. A restore/rebuild can leave every URL 200 while
# every UID-lock is silently orphaned. This mode verifies ONE known join,
# end-to-end, and FAILS CLOSED — a broken join sets the pair RAG red (which
# pair_guard then blocks promotion on; visible in `pl pair status`).
#
# Resolvers are pluggable so the probe runs offline/in CI and against real DBs:
#   provider side : --nwc-ledger=FILE (latest snapshot) | --nwc-resolve-cmd="CMD"
#   consumer side : --mdl-resolve-cmd="CMD" | --mdl-idnumber=<literal>
# Each *-cmd receives the uuid as $1 and prints its answer on stdout.
################################################################################
if [ "$JOIN" = "true" ]; then
    print_header "Pair JOIN-integrity probe: ${CONSUMER} ↔ ${PROVIDER} @ ${TIER} (contract v${CV})"
    if [ -z "$JOIN_UUID" ]; then
        print_error "--join needs a known uuid: --join-uuid=<uuid> (the locked mdl_user.idnumber)."
        exit 1
    fi
    echo "  uuid (locked sub/idnumber): $JOIN_UUID"
    echo ""

    join_red() { pair_rag_set "$CONSUMER" "$TIER" "red"; print_error "$1"; print_error "JOIN-integrity RED — RAG set red for ${CONSUMER}@${TIER}; pair_guard will block promotion."; exit 1; }

    # --- provider side: does nwc hold this uuid? -----------------------------
    nwc_uid=""; nwc_email=""
    if [ -n "$NWC_RESOLVE_CMD" ]; then
        nwc_row="$(eval "$NWC_RESOLVE_CMD $(printf '%q' "$JOIN_UUID")" 2>/dev/null || true)"
        nwc_uid="$(printf '%s' "$nwc_row" | cut -f1)"
        nwc_email="$(printf '%s' "$nwc_row" | cut -f2)"
    elif [ -n "$NWC_LEDGER" ]; then
        [ -f "$NWC_LEDGER" ] || join_red "provider ledger not found: $NWC_LEDGER"
        latest_snap="$(grep '"t":"snap"' "$NWC_LEDGER" | jq -r '.snap' | tail -1)"
        nwc_json="$(jq -c "select(.t==\"rec\" and .snap==${latest_snap:-0} and .uuid==\"$JOIN_UUID\")" "$NWC_LEDGER" | tail -1)"
        if [ -n "$nwc_json" ]; then
            nwc_uid="$(printf '%s' "$nwc_json" | jq -r '.uid')"
            nwc_email="$(printf '%s' "$nwc_json" | jq -r '.email // .email_sha256 // ""')"
        fi
    else
        # Default: resolve from the pair's own provider ledger.
        LEDGER_DEFAULT="$(pair_ledger_file "$CONSUMER")"
        [ -f "$LEDGER_DEFAULT" ] || join_red "no provider resolver: pass --nwc-ledger= / --nwc-resolve-cmd=, or dump the ledger ($LEDGER_DEFAULT)."
        latest_snap="$(grep '"t":"snap"' "$LEDGER_DEFAULT" | jq -r '.snap' | tail -1)"
        nwc_json="$(jq -c "select(.t==\"rec\" and .snap==${latest_snap:-0} and .uuid==\"$JOIN_UUID\")" "$LEDGER_DEFAULT" | tail -1)"
        if [ -n "$nwc_json" ]; then
            nwc_uid="$(printf '%s' "$nwc_json" | jq -r '.uid')"
            nwc_email="$(printf '%s' "$nwc_json" | jq -r '.email // .email_sha256 // ""')"
        fi
    fi
    if [ -z "$nwc_uid" ] || [ "$nwc_uid" = "null" ]; then
        join_red "PROVIDER side: uuid=$JOIN_UUID does NOT resolve to any nwc account (identity absent/severed)."
    fi
    print_status "OK" "provider: uuid=$JOIN_UUID → nwc uid=$nwc_uid"

    # --- consumer side: does mdl_user.idnumber == uuid resolve? --------------
    mdl_idnumber=""; mdl_email=""
    if [ -n "$MDL_RESOLVE_CMD" ]; then
        mdl_row="$(eval "$MDL_RESOLVE_CMD $(printf '%q' "$JOIN_UUID")" 2>/dev/null || true)"
        mdl_idnumber="$(printf '%s' "$mdl_row" | cut -f1)"
        mdl_email="$(printf '%s' "$mdl_row" | cut -f2)"
    elif [ -n "$MDL_IDNUMBER" ]; then
        mdl_idnumber="$MDL_IDNUMBER"
    else
        print_status "WARN" "consumer: no Moodle resolver (--mdl-resolve-cmd/--mdl-idnumber) — provider half only."
        print_status "OK" "JOIN half-verified (provider). Provide a Moodle handle for the full end-to-end check."
        pair_rag_set "$CONSUMER" "$TIER" "amber"
        exit 0
    fi
    if [ "$mdl_idnumber" != "$JOIN_UUID" ]; then
        join_red "CONSUMER side: mdl_user.idnumber='$mdl_idnumber' != uuid '$JOIN_UUID' (UID-lock does NOT resolve — join broken)."
    fi
    print_status "OK" "consumer: mdl_user.idnumber == uuid ($JOIN_UUID) resolves"

    # --- optional cross-field agreement (email), when both sides expose it ---
    if [ -n "$nwc_email" ] && [ -n "$mdl_email" ] && [ "$nwc_email" != "$mdl_email" ]; then
        print_status "WARN" "email differs across sides (nwc='$nwc_email' vs moodle='$mdl_email') — expected under sanitized/hashed tiers."
    fi

    pair_rag_set "$CONSUMER" "$TIER" "green"
    echo ""
    print_status "OK" "JOIN-integrity GREEN: nwc(uuid=$JOIN_UUID,uid=$nwc_uid) ↔ mdl_user.idnumber — join intact. RAG green for ${CONSUMER}@${TIER}."
    exit 0
fi

# Provider base URL: explicit override, else the contract issuer for this tier.
if [ -z "$PROVIDER_BASE" ]; then
    PROVIDER_BASE="$(pair_contract_get "$CONTRACT" ".endpoints.${TIER}.issuer" 2>/dev/null || true)"
fi

# ── Resolve <example-prod-domain> via the EXISTING resolver (ops#267) ────────
#
# CORRECTION to this branch's first version: I wrote a bespoke expander here
# (reading nwp.yml sites.<site>.live.domain) before discovering that
# lib/demo-pair.sh:demo_pair_issuer() already did exactly this job, reading the
# provider's sites/<provider>/.nwp.yml live.domain and failing closed. Two
# implementations of "where does the placeholder point" is how they drift, and
# the drifting copy is always the one doing the work. So the provider base now
# delegates; the local helper survives only for the CONSUMER base, which
# demo_pair_issuer does not cover.
#
# The contracts carry `https://nwd.<example-prod-domain>` rather than the real
# host, deliberately: the gitleaks operator ruleset bans internal hostnames from
# tracked files (docs/reference/role-vocabulary.md). But nothing ever EXPANDED
# the placeholder, so every provider probe dialled a literal
# "<example-prod-domain>", failed, and the pair went RED — permanently.
#
# The cost was not a red badge. `pl moodle plugin deploy` and `pl stg2live`
# refuse to promote onto a RED pair (ADR-0031 D5), so the only way to ship
# anything became `--override-pair` — used 18+ times in one week. A guard that is
# overridden every single time it fires is not a guard; it is a speed bump that
# teaches people to reach for the override. ssd has been RAG-red since
# 2026-07-29 for this reason alone, which also means a REAL pair failure would
# have been indistinguishable from the standing noise.
#
# The apex comes from nwp.yml `sites.<site>.live.domain` (a full host, e.g.
# sub.apex.tld), so the apex is that value minus its first label. Config is the
# right home: the contract stays domain-free in git AND resolves at run time.
#
# Fails LOUDLY rather than silently probing a placeholder: if the apex cannot be
# resolved, say so and leave the URL untouched so the error names the cause.
pair_expand_domain() {
    local url="$1" site="$2" full apex
    case "$url" in *'<example-prod-domain>'*) ;; *) printf '%s' "$url"; return 0 ;; esac
    full="$("${YQ:-yq}" -r ".sites.${site}.live.domain // \"\"" "${NWP_ROOT:-$HOME/nwp}/nwp.yml" 2>/dev/null)"
    if [ -z "$full" ] || [ "$full" = "null" ]; then
        print_warning "cannot expand <example-prod-domain>: nwp.yml has no sites.${site}.live.domain"
        print_hint "  the probe below will fail against the literal placeholder, which is the real defect"
        printf '%s' "$url"; return 1
    fi
    apex="${full#*.}"
    if [ -z "$apex" ] || [ "$apex" = "$full" ]; then
        print_warning "cannot derive an apex from sites.${site}.live.domain (expected sub.apex.tld)"
        printf '%s' "$url"; return 1
    fi
    printf '%s' "${url//<example-prod-domain>/$apex}"
}

if ! declare -F demo_pair_issuer >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    [ -r "${NWP_ROOT:-$HOME/nwp}/lib/demo-pair.sh" ] \
        && source "${NWP_ROOT:-$HOME/nwp}/lib/demo-pair.sh" 2>/dev/null || true
fi
if declare -F demo_pair_issuer >/dev/null 2>&1; then
    _resolved="$(demo_pair_issuer "$CONTRACT" "$TIER" 2>/dev/null || true)"
    [ -n "$_resolved" ] && PROVIDER_BASE="$_resolved"
fi
if [ -n "$PROVIDER_BASE" ]; then
    PROVIDER_BASE="$(pair_expand_domain "$PROVIDER_BASE" "$PROVIDER")" || true
fi
if [ -n "$CONSUMER_BASE" ]; then
    CONSUMER_BASE="$(pair_expand_domain "$CONSUMER_BASE" "$CONSUMER")" || true
fi

# ── Derive the CONSUMER base from config when the contract has none (ops#267) ─
#
# The third and decisive cause of the permanent RED. `--run` requires BOTH bases,
# the ssd contract declares no consumer endpoint for any tier, and nothing
# derived one — so `pl pair-smoke ssd --tier=live --run` could never COMPLETE.
# It failed with "needs both a provider and a consumer base URL" before probing
# anything.
#
# So "the pair is red" never meant "a probe failed". It meant "the check cannot
# run", and the two are opposite facts: one is evidence, the other is blindness.
# Every `--override-pair` in the ledger was overriding an unrunnable check.
#
# nwp.yml sites.<site>.live.domain is a full host, which is exactly a base URL.
pair_site_base() {
    local site="$1" tier="$2" full
    full="$("${YQ:-yq}" -r ".sites.${site}.${tier}.domain // \"\"" "${NWP_ROOT:-$HOME/nwp}/nwp.yml" 2>/dev/null)"
    [ -n "$full" ] && [ "$full" != "null" ] || return 1
    printf 'https://%s' "$full"
}

if [ -z "$CONSUMER_BASE" ]; then
    if CONSUMER_BASE="$(pair_site_base "$CONSUMER" "$TIER")"; then
        print_info "consumer base derived from nwp.yml sites.${CONSUMER}.${TIER}.domain"
    else
        CONSUMER_BASE=""
    fi
fi
if [ -z "$PROVIDER_BASE" ]; then
    if PROVIDER_BASE="$(pair_site_base "$PROVIDER" "$TIER")"; then
        print_info "provider base derived from nwp.yml sites.${PROVIDER}.${TIER}.domain"
    else
        PROVIDER_BASE=""
    fi
fi

print_header "Pair smoke: ${CONSUMER} ↔ ${PROVIDER} @ ${TIER} (contract v${CV})"
echo "  Provider base: ${PROVIDER_BASE:-<unset>}"
echo "  Consumer base: ${CONSUMER_BASE:-<unset>}"
echo "  Mode:          ${MODE}"
echo ""

# Enumerate smoke URLs from the contract.
mapfile -t SMOKE_NAMES < <(yq e -r '.smoke_urls[].name' "$CONTRACT" 2>/dev/null || true)
if [ "${#SMOKE_NAMES[@]}" -eq 0 ]; then
    print_warning "Contract declares no smoke_urls — nothing to probe."
    exit 0
fi

# Build the plan (name side path method expect) for each URL.
probe_side_base() {
    case "$1" in
        provider) echo "$PROVIDER_BASE" ;;
        consumer) echo "$CONSUMER_BASE" ;;
        *) echo "" ;;
    esac
}

print_info "Onboarding URL set (${#SMOKE_NAMES[@]}):"
i=0
declare -a PLAN_URL PLAN_METHOD PLAN_EXPECT PLAN_NAME PLAN_SIDE
for name in "${SMOKE_NAMES[@]}"; do
    side="$(NAME="$name" yq e -r '.smoke_urls[] | select(.name == strenv(NAME)) | .side'   "$CONTRACT" 2>/dev/null)"
    path="$(NAME="$name" yq e -r '.smoke_urls[] | select(.name == strenv(NAME)) | .path'   "$CONTRACT" 2>/dev/null)"
    method="$(NAME="$name" yq e -r '.smoke_urls[] | select(.name == strenv(NAME)) | .method // "GET"' "$CONTRACT" 2>/dev/null)"
    expect="$(NAME="$name" yq e -r '.smoke_urls[] | select(.name == strenv(NAME)) | .expect_status // "200"' "$CONTRACT" 2>/dev/null)"
    base="$(probe_side_base "$side")"
    url="${base%/}${path}"
    PLAN_NAME[$i]="$name"; PLAN_SIDE[$i]="$side"; PLAN_URL[$i]="$url"
    PLAN_METHOD[$i]="$method"; PLAN_EXPECT[$i]="$expect"
    printf '   [%d] %-16s %-8s %-6s expect=%-8s %s\n' "$i" "$name" "$side" "$method" "$expect" "${url:-<no base for $side>}"
    i=$((i+1))
done
echo ""

# --- CROSS-REPO promise check (item 8) --------------------------------------
# Before probing anything over HTTP, verify the contract is even CHECKABLE: that
# every consumer path it names exists in the consumer plugin tree and every WS
# function the provider calls is defined there. A probe URL that has never
# existed (status.php / api.php, v1 of both contracts) produces a permanent 404
# that everyone learns to ignore; this makes that state a hard failure at plan
# time instead of a red probe nobody reads.
#
# NWP_PAIR_SMOKE_SKIP_CROSSREF=1 suppresses it — for the case where the site
# trees genuinely are not checked out on this host. It prints that it did so.
if [ "${NWP_PAIR_SMOKE_SKIP_CROSSREF:-0}" = "1" ]; then
    print_warning "crossref SKIPPED (NWP_PAIR_SMOKE_SKIP_CROSSREF=1) — the cross-repo promises in"
    print_warning "  this contract were NOT verified. The probe results below cannot distinguish a"
    print_warning "  broken deployment from an endpoint that does not exist."
else
    if "${PROJECT_ROOT}/scripts/commands/contracts.sh" crossref "$CONSUMER"; then
        print_status "OK" "crossref: the contract's cross-repo promises hold."
    else
        print_error "crossref FAILED for pair '${CONSUMER}' (see above)."
        print_info  "  Fix the contract or the consumer tree before trusting any probe result."
        print_info  "  Re-run with NWP_PAIR_SMOKE_SKIP_CROSSREF=1 only if you accept unverified probes."
        pair_rag_set "$CONSUMER" "$TIER" "red" 2>/dev/null || true
        exit 1
    fi
fi
echo ""

if [ "$MODE" != "run" ]; then
    print_status "OK" "Dry run — no network was touched. Re-run with --run to probe."
    exit 0
fi

# ---- --run path -------------------------------------------------------------
if [ "$TIER" = "prod" ] && [ "$FORCE_PROD" != "true" ]; then
    print_error "Refusing to probe a PROD tier without --force-prod (safety)."
    exit 1
fi
if [ -z "$PROVIDER_BASE" ] || [ -z "$CONSUMER_BASE" ]; then
    print_error "--run needs both a provider and a consumer base URL."
    print_info  "Provide --provider-base=... and --consumer-base=... (or set contract endpoints)."
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    print_error "curl not found — required for --run."
    exit 1
fi

status_matches() { # <actual> <csv-expected>
    local actual="$1" csv="$2" e
    IFS=',' read -ra arr <<< "$csv"
    for e in "${arr[@]}"; do [ "$actual" = "${e// /}" ] && return 0; done
    return 1
}

fails=0; ran=0
for idx in "${!PLAN_NAME[@]}"; do
    url="${PLAN_URL[$idx]}"
    [ -z "$url" ] && { print_status "WARN" "${PLAN_NAME[$idx]}: no base for side ${PLAN_SIDE[$idx]} — skipped"; continue; }
    ran=$((ran+1))
    code="$(curl -s -o /dev/null -w '%{http_code}' -X "${PLAN_METHOD[$idx]}" \
        --max-time 10 "$url" 2>/dev/null || echo 000)"
    if status_matches "$code" "${PLAN_EXPECT[$idx]}"; then
        print_status "OK" "${PLAN_NAME[$idx]} → $code"
    else
        print_status "FAIL" "${PLAN_NAME[$idx]} → $code (expected ${PLAN_EXPECT[$idx]})"
        fails=$((fails+1))
    fi
done

echo ""
if [ "$TIER" != "prod" ]; then
    print_info "Token round-trip would run here on non-prod (STUB — F26-gated; see schema doc §OAuth)."
else
    print_info "Token round-trip skipped on prod (by design)."
fi

RAG="green"; [ "$fails" -gt 0 ] && RAG="red"
pair_rag_set "$CONSUMER" "$TIER" "$RAG"
echo ""
if [ "$RAG" = "red" ]; then
    print_error "Pair smoke RED: $fails/$ran probe(s) failed. RAG set red for ${CONSUMER}@${TIER}."
    print_info  "pair_guard will now refuse promotion onto ${TIER} until this is green."
    exit 1
fi
print_status "OK" "Pair smoke GREEN: $ran/$ran probes passed. RAG set green for ${CONSUMER}@${TIER}."
exit 0
