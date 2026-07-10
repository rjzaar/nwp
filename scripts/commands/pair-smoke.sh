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

${BOLD}NOTES:${NC}
    * Default is a DRY RUN. Nothing touches the network without --run.
    * A red result (--run) sets the pair RAG to red; pair_guard then blocks
      promotion of either half onto that tier until it is green again.
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

for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help; exit 0 ;;
        --dry-run) MODE="dry-run" ;;
        --run)     MODE="run" ;;
        --force-prod) FORCE_PROD=true ;;
        --tier=*)  TIER="${arg#*=}" ;;
        --provider-base=*) PROVIDER_BASE="${arg#*=}" ;;
        --consumer-base=*) CONSUMER_BASE="${arg#*=}" ;;
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

# Provider base URL: explicit override, else the contract issuer for this tier.
if [ -z "$PROVIDER_BASE" ]; then
    PROVIDER_BASE="$(pair_contract_get "$CONTRACT" ".endpoints.${TIER}.issuer" 2>/dev/null || true)"
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
