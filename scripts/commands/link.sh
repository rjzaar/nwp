#!/usr/bin/env bash
################################################################################
# scripts/commands/link.sh — nwc(IdP)↔ssc(Moodle) SSO/token LINK health gate
#                            (PL-STG2LIVE-INTEGRATION-DESIGN §5.5 / §5.6 / §5.7)
#
# The link between the Drupal provider (nwc) and the Moodle consumer (ssc) is
# THREE channels / three secrets / two registrations (design §5.0), none of
# which is carried by a code deploy:
#
#   1  OIDC SSO login   nwc IdP → ssc client   (signing keypair + client_id/secret)
#   2  copyright/policy  nwc → Moodle POST      (admin_token)
#   3  learner signal    Moodle → nwc POST      (bearer_token = signal + feedback)
#
# `pl link verify` is a DEPLOY-GATE-SHAPED, READ-ONLY superset of `pl pair-smoke`
# (§5.5): it runs the 5-URL liveness probe AND adds the structural cross-checks a
# bare liveness probe cannot make — plus the §5.6 SUB-CLAIM assertion that is a
# known pre-go-live BLOCKER.
#
#   * NEVER prints a secret. Any token needed to authenticate a synthetic POST is
#     read tokenlessly (yq → a 0600 curl config header, exactly the mechanism
#     `pl secrets get`/`pl secrets whose` use) so it never lands in argv/ps/stdout.
#   * READ-ONLY: GET probes + synthetic no-op POSTs asserted by hash_equals only;
#     never publishes a policy, never leaves a durable signal (channel 3 cleans up).
#   * FAIL-CLOSED: any failed assertion sets the pair RAG red (pair_rag_set) and
#     exits non-zero, so a caller / pair_guard blocks the next promotion (§5.4).
#   * On --tier=prod the round-trip is SKIPPED (read-only 5-URL probe only, §5.5).
#
# §5.6 SUB-CLAIM BLOCKER (the assertion this gate exists to make): the nwc
# UserInfoController historically emits `sub => (string)$user->id()` — a NUMERIC
# Drupal uid — but the contract declares `sub_stability: uuid` and the depthcontent
# forwarder keys on idnumber. A numeric uid is NOT stable across dev/stg/live user
# tables, so signal attribution silently returns null. The Drupal-side emit fix
# (sub => $account->uuid()) lives in the profile repo and is handled separately;
# THIS gate is the assertion that catches a numeric sub and fails RED.
#
# Usage:
#   pl link verify <pair> --tier=stg|live|prod [--round-trip] [options]
#   pl link provision   <pair> --tier=<t>     # STUB — see §5.7 (P1-5)
#   pl link token rotate <pair> --tier=<t>    # STUB — see §5.3/§5.7 (P1-5)
#   pl link keys  rotate <pair> --tier=<t>    # STUB — see §5.1/§5.7 (P1-5)
#
#   <pair>                consumer key ("ssc") or a hyphenated pair ("nwc-ssc")
#   --tier=<t>            stg | live | prod       (dev has no separate link gate)
#   --round-trip          add channel 1/2/3 authenticated round-trips (non-prod)
#   --provider-base=URL   override the nwc issuer base (else contract issuer)
#   --consumer-base=URL   override the Moodle wwwroot  (else site .nwp.yml domain)
#   --observed-sub=VALUE  a captured userinfo `sub` to run the §5.6 assertion on
#                         (lets the blocker be checked without live creds / CI)
#   --expected-idnumber=V the UID-lock target the sub must equal (mdl_user.idnumber)
#   --client-id=ID        expected OIDC client_id (else site .moodle.oauth.client_id)
#   --provider-client-id-cmd="CMD"  prints the provider consumer-entity client_id
#   --consumer-client-id-cmd="CMD"  prints the Moodle issuer clientid
#   --no-network          skip all HTTP probes; run offline structural asserts only
#   --force-prod          permit a prod --round-trip (still skipped by design)
#   -h, --help
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# shellcheck source=../../lib/ui.sh
source "$PROJECT_ROOT/lib/ui.sh"
[ -f "$PROJECT_ROOT/lib/common.sh" ] && source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=../../lib/pair.sh
source "$PROJECT_ROOT/lib/pair.sh"

SECRETS_FILE="${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}"

# =============================================================================
# Extractable, side-effect-free assertion helpers (unit-tested in isolation).
# =============================================================================

# link_sub_is_uuid <sub> — 0 if <sub> is a stable account UUID (RFC-4122 8-4-4-4-12),
# non-zero otherwise. A BARE Drupal serial uid (all digits, e.g. "42") is the §5.6
# blocker and MUST fail here. Kept tiny + pure so tests can drive it directly.
link_sub_is_uuid() {
    local sub="${1:-}"
    [ -n "$sub" ] || return 1
    # A bare numeric uid is the known blocker — reject before anything else.
    case "$sub" in ''|*[!0-9]*) : ;; *) return 1 ;; esac
    [[ "$sub" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# link_sub_verdict <sub> [<expected_idnumber>] — echoes one of:
#   pass | red-numeric-uid | red-not-uuid | red-mismatch
# and returns 0 only for "pass". This is the §5.6 gate logic, isolated so both
# the round-trip path and the unit tests call the same code.
link_sub_verdict() {
    local sub="${1:-}" expect="${2:-}"
    if [ -z "$sub" ]; then echo "red-empty"; return 1; fi
    # numeric uid = the specific known blocker → distinct verdict for a clear message
    case "$sub" in *[!0-9]*) : ;; *) echo "red-numeric-uid"; return 1 ;; esac
    if ! link_sub_is_uuid "$sub"; then echo "red-not-uuid"; return 1; fi
    if [ -n "$expect" ] && [ "$sub" != "$expect" ]; then echo "red-mismatch"; return 1; fi
    echo "pass"; return 0
}

# link_endpoints_match_native <authorize> <token> <userinfo> <jwks> — 0 iff every
# path equals nwc's native simple_oauth route AND jwks is the well-known URI (NOT
# /oauth/jwks, which 301-redirects and silently breaks signature verification).
link_endpoints_match_native() {
    local az="${1:-}" tk="${2:-}" ui="${3:-}" jwks="${4:-}"
    [ "$az" = "/oauth/authorize" ]        || return 1
    [ "$tk" = "/oauth/token" ]            || return 1
    [ "$ui" = "/oauth/userinfo" ]         || return 1
    [ "$jwks" = "/.well-known/jwks.json" ] || return 1
    [ "$jwks" != "/oauth/jwks" ]          || return 1
    return 0
}

# link_redirect_ok <redirect> <moodle_wwwroot> — 0 iff <redirect> EXACTLY equals
# https://<moodle_wwwroot>/admin/oauth2callback.php (RFC 9700 exact-match). When
# the wwwroot is unknown, still require the mandatory callback suffix.
link_redirect_ok() {
    local redirect="${1:-}" www="${2:-}"
    [ -n "$redirect" ] || return 1
    if [ -n "$www" ]; then
        [ "$redirect" = "${www%/}/admin/oauth2callback.php" ] && return 0 || return 1
    fi
    case "$redirect" in */admin/oauth2callback.php) return 0 ;; *) return 1 ;; esac
}

# =============================================================================
# Tokenless secret → curl: read a value from .secrets.yml INTO a 0600 curl config
# as an HTTP header, run the request, echo the http_code. The value NEVER reaches
# argv/ps/stdout — same discipline as secrets.sh `_audit_body`/`cmd_whose`.
# Usage: link_probe_authed <url> <method> <header-name> <dotted.secret.key> [body]
# Returns http_code on stdout (000 on transport error / missing secret).
# =============================================================================
link_probe_authed() {
    local url="$1" method="$2" hdr="$3" key="$4" body="${5:-}"
    command -v curl >/dev/null 2>&1 || { echo "000"; return 1; }
    [ -f "$SECRETS_FILE" ] || { echo "000"; return 1; }
    local yq_bin; yq_bin="$(command -v yq || true)"
    [ -n "$yq_bin" ] || { echo "000"; return 1; }
    local val; val="$("$yq_bin" e ".$key // \"\"" "$SECRETS_FILE" 2>/dev/null)"
    if [ -z "$val" ] || [ "$val" = "null" ]; then echo "000"; return 2; fi
    local cfg; cfg="$(mktemp "${TMPDIR:-/tmp}/nwp-link.XXXXXX")" || { echo "000"; return 1; }
    chmod 600 "$cfg"
    {
        printf 'silent\noutput = "/dev/null"\nwrite-out = "%%{http_code}"\nmax-time = 12\n'
        printf 'request = "%s"\nurl = "%s"\nheader = "%s: %s"\n' "$method" "$url" "$hdr" "$val"
        [ -n "$body" ] && printf 'data = "%s"\n' "$body"
    } > "$cfg"
    val=""   # drop the secret from memory immediately
    local code; code="$(curl -K "$cfg" 2>/dev/null || echo 000)"
    rm -f "$cfg"
    echo "${code:-000}"
}

# =============================================================================
# Small predicates for the check() harness (keep set -e happy).
# =============================================================================
_streq() { [ "$1" = "$2" ]; }
_nonempty() { [ -n "${1:-}" ]; }

# =============================================================================
# pair / tier / base resolution
# =============================================================================

# link_resolve_pair <arg> — echo the pair id (consumer key). Accepts "ssc" or a
# hyphenated "nwc-ssc"/"ssc-nwc"; picks the token that has a valid contract.
link_resolve_pair() {
    local arg="$1" tok rest pid
    if pair_contract_valid "$(pair_contract_file "$arg")" 2>/dev/null; then echo "$arg"; return 0; fi
    if [[ "$arg" == *-* ]]; then
        local toks; IFS='-' read -ra toks <<< "$arg"
        for tok in "${toks[@]}"; do
            pair_contract_valid "$(pair_contract_file "$tok")" 2>/dev/null && { echo "$tok"; return 0; }
        done
        for tok in "${toks[@]}"; do
            rest="$(pair_role_of "$tok")"; pid="$(echo "$rest" | awk '{print $2}')"
            [ -n "$pid" ] && { echo "$pid"; return 0; }
        done
    fi
    rest="$(pair_role_of "$arg")"; pid="$(echo "$rest" | awk '{print $2}')"
    [ -n "$pid" ] && { echo "$pid"; return 0; }
    return 1
}

# Read a scalar from a site's .nwp.yml (echoes value or "").
_link_site_field() {
    local site="$1" path="$2" f="$PROJECT_ROOT/sites/$1/.nwp.yml"
    local yq_bin; yq_bin="$(command -v yq || true)"
    [ -f "$f" ] && [ -n "$yq_bin" ] || return 0
    "$yq_bin" e "$path // \"\"" "$f" 2>/dev/null | grep -v '^null$' || true
}

# A base that still carries a "<...>" placeholder is NOT resolved.
_link_is_placeholder() { case "${1:-}" in *"<"*">"*|"") return 0 ;; *) return 1 ;; esac; }

# =============================================================================
# verify — the health gate
# =============================================================================
FAILS=0
check() {   # <label> <cmd...> : run cmd; OK on 0, FAIL (+RED) otherwise
    local label="$1"; shift
    if "$@"; then print_status "OK" "$label"; else print_status "FAIL" "$label"; FAILS=$((FAILS+1)); fi
}
skip() { print_status "WARN" "$1 — SKIPPED ($2)"; }

link_verify() {
    local PAIR="" TIER="" ROUND_TRIP=false PROVIDER_BASE="" CONSUMER_BASE=""
    local OBSERVED_SUB="" EXPECTED_IDNUMBER="" CLIENT_ID="" NO_NETWORK=false FORCE_PROD=false
    local PROV_CID_CMD="" CONS_CID_CMD="" ADMIN_TOKEN_KEY="" BEARER_TOKEN_KEY=""

    local arg
    for arg in "$@"; do
        case "$arg" in
            --tier=*)              TIER="${arg#*=}" ;;
            --round-trip)          ROUND_TRIP=true ;;
            --provider-base=*)     PROVIDER_BASE="${arg#*=}" ;;
            --consumer-base=*)     CONSUMER_BASE="${arg#*=}" ;;
            --observed-sub=*)      OBSERVED_SUB="${arg#*=}" ;;
            --expected-idnumber=*) EXPECTED_IDNUMBER="${arg#*=}" ;;
            --client-id=*)         CLIENT_ID="${arg#*=}" ;;
            --provider-client-id-cmd=*) PROV_CID_CMD="${arg#*=}" ;;
            --consumer-client-id-cmd=*) CONS_CID_CMD="${arg#*=}" ;;
            --admin-token-key=*)   ADMIN_TOKEN_KEY="${arg#*=}" ;;
            --bearer-token-key=*)  BEARER_TOKEN_KEY="${arg#*=}" ;;
            --no-network)          NO_NETWORK=true ;;
            --force-prod)          FORCE_PROD=true ;;
            -h|--help)             link_help; return 0 ;;
            -*)                    print_error "Unknown option: $arg"; return 1 ;;
            *)  [ -z "$PAIR" ] && PAIR="$arg" || { print_error "Unexpected arg: $arg"; return 1; } ;;
        esac
    done

    [ -n "$PAIR" ] || { print_error "A pair is required, e.g. 'pl link verify ssc --tier=live'"; return 1; }
    case "$TIER" in
        stg|live|prod) ;;
        "") print_error "--tier is required (stg|live|prod)"; return 1 ;;
        *)  print_error "Invalid --tier '$TIER' (stg|live|prod)"; return 1 ;;
    esac

    local pair_id; pair_id="$(link_resolve_pair "$PAIR")" \
        || { print_error "Could not resolve a pair from '$PAIR' (no valid contract; try 'ssc')"; return 1; }
    local contract; contract="$(pair_contract_file "$pair_id")"
    if ! pair_contract_valid "$contract"; then
        print_error "No valid pair contract for '$pair_id' at: $contract"; return 1
    fi
    local provider consumer
    provider="$(pair_contract_get "$contract" '.provider' || true)"
    consumer="$(pair_contract_get "$contract" '.consumer' || true)"

    print_header "Link verify: ${consumer} ↔ ${provider} @ ${TIER}  (pair '${pair_id}')"

    # --- resolve bases -------------------------------------------------------
    [ -n "$PROVIDER_BASE" ] || PROVIDER_BASE="$(pair_contract_get "$contract" ".endpoints.${TIER}.issuer" 2>/dev/null || true)"
    if [ -z "$CONSUMER_BASE" ]; then
        local dom; dom="$(_link_site_field "$consumer" '.live.domain')"
        [ "$TIER" = "live" ] && [ -n "$dom" ] && CONSUMER_BASE="https://${dom}"
    fi
    PROVIDER_BASE="${PROVIDER_BASE%/}"; CONSUMER_BASE="${CONSUMER_BASE%/}"
    echo "  provider base: ${PROVIDER_BASE:-<unresolved>}"
    echo "  consumer base: ${CONSUMER_BASE:-<unresolved>}"
    echo "  round-trip:    ${ROUND_TRIP}    network: $([ "$NO_NETWORK" = true ] && echo off || echo on)"
    echo ""

    # ======================================================================
    # CHANNEL 1 — OIDC SSO (structural, offline; always runs)
    # ======================================================================
    print_info "Channel 1 — OIDC SSO (nwc IdP → ssc client)"
    local az tk ui jwks
    az="$(pair_contract_get "$contract" '.oidc.endpoints.authorization' 2>/dev/null || true)"
    tk="$(pair_contract_get "$contract" '.oidc.endpoints.token'         2>/dev/null || true)"
    ui="$(pair_contract_get "$contract" '.oidc.endpoints.userinfo'      2>/dev/null || true)"
    jwks="$(pair_contract_get "$contract" '.oidc.endpoints.jwks'        2>/dev/null || true)"
    check "  endpoints match nwc native routes; JWKS=/.well-known/jwks.json (not /oauth/jwks 301)" \
        link_endpoints_match_native "$az" "$tk" "$ui" "$jwks"

    # sub_stability must be uuid in the contract (the §5.6 invariant, declared side)
    local substab; substab="$(pair_contract_get "$contract" '.identity.sub_stability' 2>/dev/null || true)"
    check "  contract declares identity.sub_stability: uuid (§5.6)" _streq "$substab" "uuid"

    # redirect_uri EXACT-match (RFC 9700). Template lives in the contract prereqs;
    # substitute the resolved wwwroot when we have it.
    local redir_tmpl redir
    redir_tmpl="$(pair_contract_get "$contract" '.oidc.provider_prereqs.consumer_redirect' 2>/dev/null || true)"
    if [ -n "$CONSUMER_BASE" ]; then
        redir="${CONSUMER_BASE}/admin/oauth2callback.php"
        check "  consumer redirect_uri == ${redir} (exact-match)" link_redirect_ok "$redir" "$CONSUMER_BASE"
    else
        check "  consumer redirect template ends with /admin/oauth2callback.php" link_redirect_ok "$redir_tmpl" ""
    fi

    # client_id single-source (§5.2); compare both live sides when resolvers given.
    [ -n "$CLIENT_ID" ] || CLIENT_ID="$(_link_site_field "$consumer" '.moodle.oauth.client_id')"
    [ -n "$CLIENT_ID" ] || CLIENT_ID="ss_moodle"   # substrate default (lib/moodle-promote.sh)
    check "  client_id resolved (single per-env source: ${CLIENT_ID})" _nonempty "$CLIENT_ID"
    if [ -n "$PROV_CID_CMD" ] && [ -n "$CONS_CID_CMD" ]; then
        local pcid ccid
        pcid="$(eval "$PROV_CID_CMD" 2>/dev/null | head -n1 || true)"
        ccid="$(eval "$CONS_CID_CMD" 2>/dev/null | head -n1 || true)"
        check "  client_id matches on BOTH sides (provider='$pcid' consumer='$ccid')" _streq "$pcid" "$ccid"
    else
        skip "  client_id cross-side equality (needs --provider/consumer-client-id-cmd)" "no live resolver"
    fi

    # ======================================================================
    # 5-URL read-only liveness probe (superset of pl pair-smoke, §5.5)
    # ======================================================================
    echo ""
    print_info "Read-only 5-URL liveness probe (channels 1/2/3 endpoints)"
    if [ "$NO_NETWORK" = true ]; then
        skip "  liveness probe" "--no-network"
    elif [ -z "$PROVIDER_BASE" ] || [ -z "$CONSUMER_BASE" ] || _link_is_placeholder "$PROVIDER_BASE" || _link_is_placeholder "$CONSUMER_BASE"; then
        skip "  liveness probe" "provider/consumer base unresolved for tier=$TIER (pass --provider-base/--consumer-base)"
    else
        local smoke_args=("$consumer" "--tier=$TIER" "--run" "--provider-base=$PROVIDER_BASE" "--consumer-base=$CONSUMER_BASE")
        [ "$TIER" = "prod" ] && smoke_args+=("--force-prod")
        if "$SCRIPT_DIR/pair-smoke.sh" "${smoke_args[@]}"; then
            print_status "OK" "  5-URL liveness probe green (delegated to pair-smoke)"
        else
            print_status "FAIL" "  5-URL liveness probe RED (see pair-smoke output above)"
            FAILS=$((FAILS+1))
        fi
    fi

    # ======================================================================
    # SUB-CLAIM assertion (§5.6). Runs on an --observed-sub if given, else on a
    # live userinfo fetch under --round-trip. This is the pre-go-live blocker.
    # ======================================================================
    echo ""
    print_info "§5.6 sub-claim assertion (numeric uid ⇒ RED; UUID ⇒ pass)"
    local sub_source="" sub_val="$OBSERVED_SUB"
    if [ -n "$sub_val" ]; then
        sub_source="--observed-sub"
    elif [ "$ROUND_TRIP" = true ] && [ "$TIER" != "prod" ] && [ "$NO_NETWORK" != true ] \
         && [ -n "$PROVIDER_BASE" ] && ! _link_is_placeholder "$PROVIDER_BASE"; then
        # Fetch a real userinfo claim with a bearer access token from the store.
        local tokkey; tokkey="${BEARER_TOKEN_KEY:-link.${pair_id}.${TIER}.probe_access_token}"
        local body_file code yq_bin; yq_bin="$(command -v yq || true)"
        body_file="$(mktemp)"; chmod 600 "$body_file"
        # (see link_probe_authed; here we need the body, so a parallel 0600 cfg.)
        local valcfg; valcfg="$(mktemp)"; chmod 600 "$valcfg"
        local tval=""
        if [ -n "$yq_bin" ] && [ -f "$SECRETS_FILE" ]; then
            tval="$("$yq_bin" e ".$tokkey // \"\"" "$SECRETS_FILE" 2>/dev/null || true)"
        fi
        if [ -n "$tval" ] && [ "$tval" != "null" ] && command -v curl >/dev/null 2>&1; then
            printf 'silent\noutput = "%s"\nwrite-out = "%%{http_code}"\nmax-time = 12\nurl = "%s/oauth/userinfo"\nheader = "Authorization: Bearer %s"\n' \
                "$body_file" "$PROVIDER_BASE" "$tval" > "$valcfg"; tval=""
            code="$(curl -K "$valcfg" 2>/dev/null || echo 000)"
            if [ "$code" = "200" ] && [ -n "$yq_bin" ]; then
                sub_val="$("$yq_bin" e -p=json '.sub // ""' "$body_file" 2>/dev/null | grep -v '^null$' || true)"
                sub_source="live userinfo ($code)"
            else
                skip "  live userinfo fetch" "HTTP $code (no bearer probe token '$tokkey', or endpoint down)"
            fi
        else
            skip "  live userinfo fetch" "no bearer probe token at '$tokkey'"
        fi
        rm -f "$body_file" "$valcfg"
    fi

    if [ -n "$sub_val" ]; then
        local verdict; verdict="$(link_sub_verdict "$sub_val" "$EXPECTED_IDNUMBER" || true)"
        case "$verdict" in
            pass) print_status "OK" "  sub is a stable account UUID${EXPECTED_IDNUMBER:+ and == idnumber} (source: $sub_source)" ;;
            red-numeric-uid)
                print_status "FAIL" "  sub is a NUMERIC Drupal uid — the §5.6 blocker (source: $sub_source)"
                print_info "  Fix in the profile repo: UserInfoController must emit sub => \$account->uuid(). Resolve before go-live."
                FAILS=$((FAILS+1)) ;;
            red-not-uuid) print_status "FAIL" "  sub is neither a UUID nor a bare uid (unexpected shape) (source: $sub_source)"; FAILS=$((FAILS+1)) ;;
            red-mismatch) print_status "FAIL" "  sub != expected idnumber '$EXPECTED_IDNUMBER' — UID-lock would not resolve"; FAILS=$((FAILS+1)) ;;
            *)            print_status "FAIL" "  sub assertion failed ($verdict)"; FAILS=$((FAILS+1)) ;;
        esac
    else
        skip "  sub-claim assertion" "no observed sub (pass --observed-sub=VALUE or --round-trip with a probe token)"
    fi

    # ======================================================================
    # Channels 2 & 3 authenticated round-trip (non-prod only; §5.5)
    # ======================================================================
    echo ""
    if [ "$ROUND_TRIP" != true ]; then
        print_info "Round-trip (channels 2/3 synthetic POSTs) not requested (pass --round-trip)."
    elif [ "$TIER" = "prod" ]; then
        print_info "Round-trip SKIPPED on prod by design (read-only 5-URL probe is the prod gate). §5.5"
    elif [ "$NO_NETWORK" = true ]; then
        skip "  channels 2/3 round-trip" "--no-network"
    elif [ -z "$CONSUMER_BASE" ] || [ -z "$PROVIDER_BASE" ] || _link_is_placeholder "$CONSUMER_BASE" || _link_is_placeholder "$PROVIDER_BASE"; then
        skip "  channels 2/3 round-trip" "bases unresolved"
    else
        print_info "Round-trip (channels 2/3 — synthetic, no-publish; hash_equals authenticated)"
        # Channel 2: synthetic no-op copyright/policy POST → 200 means hash_equals
        # passed WITHOUT publishing (X-Cross-Site-Token header, §5.0 constraint).
        local a_key; a_key="${ADMIN_TOKEN_KEY:-link.${pair_id}.${TIER}.admin_token}"
        local c2; c2="$(link_probe_authed \
            "${CONSUMER_BASE}/local/nwc_copyright_sync/policy_set.php" "POST" \
            "X-Cross-Site-Token" "$a_key" "noop=1&dry_run=1" || true)"
        if [ "$c2" = "000" ]; then
            skip "  channel 2 policy no-op POST" "no admin_token at '$a_key' or endpoint unreachable"
        else
            check "  channel 2: synthetic no-op policy accepted (hash_equals ok, not published) → $c2" _streq "$c2" "200"
        fi
        # Channel 3: synthetic learner signal → 200 + side-effect; then cleanup.
        local b_key; b_key="${BEARER_TOKEN_KEY:-link.${pair_id}.${TIER}.bearer_token}"
        local c3; c3="$(link_probe_authed \
            "${PROVIDER_BASE}/api/learner-signal" "POST" \
            "X-Cross-Site-Token" "$b_key" "synthetic=1&cleanup=1" || true)"
        if [ "$c3" = "000" ]; then
            skip "  channel 3 learner-signal POST" "no bearer_token at '$b_key' or endpoint unreachable"
        else
            check "  channel 3: synthetic signal accepted → $c3 (synthetic row cleaned up)" _streq "$c3" "200"
        fi
    fi

    # ======================================================================
    # Verdict → pair RAG + exit code (§5.4/§5.5: red blocks the next promotion)
    # ======================================================================
    echo ""
    local rag="green"; [ "$FAILS" -gt 0 ] && rag="red"
    pair_rag_set "$pair_id" "$TIER" "$rag"
    if [ "$rag" = "red" ]; then
        print_error "Link verify RED: $FAILS assertion(s) failed. RAG set red for ${pair_id}@${TIER}."
        print_info  "pair_guard will refuse the next promotion of either half onto ${TIER} until green (§5.4)."
        return 1
    fi
    print_status "OK" "Link verify GREEN: all assertions passed. RAG set green for ${pair_id}@${TIER}."
    return 0
}

# =============================================================================
# Stubs (§5.7 P1-5) — provision / token rotate / keys rotate
# =============================================================================
link_stub() {
    local verb="$1"
    print_header "pl link ${verb}"
    print_warning "not yet implemented — see PL-STG2LIVE-INTEGRATION-DESIGN §5.7 (P1-5)."
    case "$verb" in
        provision)   print_info "Will wrap scripts/f26/nwc-provider-oidc-setup.sh (consumer entity upsert) THEN moodle_run_oidc_apply (issuer), provider-first (§5.2)." ;;
        "token rotate") print_info "Will run the dual-accept atomic rotation over channels 2/3, health-gated by 'pl link verify --round-trip' (§5.3)." ;;
        "keys rotate")  print_info "Will hard_swap oauth-keys in place + run post_rotate_checks (jwks_200_new_modulus, browser_sso_login) (§5.1)." ;;
    esac
    print_info "Health-gate today: pl link verify ${consumer:-<pair>} --tier=<t> [--round-trip]"
    return 0
}

link_help() {
    cat <<EOF
${BOLD}pl link — nwc(IdP)↔ssc(Moodle) SSO/token link health gate${NC}  (PL-STG2LIVE §5.5–§5.7)

${BOLD}USAGE${NC}
    pl link verify <pair> --tier=stg|live|prod [--round-trip] [options]
    pl link provision    <pair> --tier=<t>     ${DIM}# STUB (§5.7)${NC}
    pl link token rotate <pair> --tier=<t>     ${DIM}# STUB (§5.3/§5.7)${NC}
    pl link keys  rotate <pair> --tier=<t>     ${DIM}# STUB (§5.1/§5.7)${NC}

${BOLD}verify${NC} — read-only 3-channel deploy-gate. Never prints a secret; sets the pair
RAG red + exits non-zero on any failed assertion (so pair_guard blocks promotion).

  <pair>                consumer key ("ssc") or hyphenated ("nwc-ssc")
  --tier=<t>            stg | live | prod          (prod: round-trip skipped, §5.5)
  --round-trip          add channel 1/2/3 authenticated round-trips (non-prod)
  --provider-base=URL   nwc issuer base (else contract endpoints.<tier>.issuer)
  --consumer-base=URL   Moodle wwwroot (else sites/<consumer>/.nwp.yml live.domain)
  --observed-sub=VALUE  run the §5.6 sub-claim assertion on a captured claim
  --expected-idnumber=V UID-lock target the sub must equal (mdl_user.idnumber)
  --client-id=ID        expected OIDC client_id (else .moodle.oauth.client_id)
  --provider-client-id-cmd / --consumer-client-id-cmd   live client_id resolvers
  --admin-token-key / --bearer-token-key   .secrets.yml keys for round-trip auth
  --no-network          offline structural assertions only
  --force-prod          permit a prod --round-trip (still skipped by design)

${BOLD}CHANNELS${NC} (§5.0)
  1  OIDC SSO   nwc → ssc   endpoints/redirect/client_id + §5.6 sub == account UUID
  2  copyright  nwc → ssc   synthetic no-op policy POST; hash_equals, no publish
  3  signal     ssc → nwc   synthetic learner-signal POST; 200 + cleanup
EOF
}

# =============================================================================
# dispatch
# =============================================================================
link_main() {
    local sub="${1:-help}"; shift || true
    case "$sub" in
        verify)       link_verify "$@" ;;
        provision)    link_stub "provision" ;;
        token)
            local v="${1:-}"; [ "$v" = "rotate" ] && link_stub "token rotate" \
                || { print_error "usage: pl link token rotate <pair> --tier=<t>"; return 1; } ;;
        keys)
            local v="${1:-}"; [ "$v" = "rotate" ] && link_stub "keys rotate" \
                || { print_error "usage: pl link keys rotate <pair> --tier=<t>"; return 1; } ;;
        -h|--help|help) link_help ;;
        *) print_error "unknown subcommand: $sub (try: pl link help)"; return 1 ;;
    esac
}

# Sourced (unit tests) → only define functions. Executed → run the dispatcher.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    link_main "$@"
fi
