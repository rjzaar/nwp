#!/bin/bash
################################################################################
# lib/pair.sh — paired-site versioning guard (ADR-0031 Phase C / nwp/ops#75)
#
# NWP runs PAIRED sites across two stacks that are coupled by OAuth2/OIDC SSO,
# copyright-policy sync and a feedback bridge:
#
#   nwc (Drupal/Open Social, PROVIDER)  ↔  ssc (Moodle, real students, CONSUMER)
#   nwd (Drupal demo,        PROVIDER)  ↔  ssd (Moodle demo,           CONSUMER)
#
# ADR-0031 D2 makes the *contract* — not the pair — the versioned artifact
# (`pair-contract.yml`, one per pair). This lib is `pair_guard`: a deploy-time
# choke-point check that reads that contract + both sides' recorded deployed
# versions and refuses a promotion that would violate the pair invariants:
#
#   1. Provider-first ordering (D5): on a contract_version bump the PROVIDER
#      (nwc) promotes before the CONSUMER (ssc). A consumer promotion past its
#      provider is refused.
#   2. UID-lock / --code-only rule (D6): a full-DB push to an identity-coupled
#      live/prod tier is refused — on the PROVIDER it would renumber Drupal uids
#      and sever every ssc SSO identity; on the CONSUMER it would clobber real
#      students' learning records (minors' PII, plane 5b). Use --code-only.
#   3. Red-pair block: while the pair's last pair-smoke is RED, promotion of
#      either half is refused.
#
# OFF-UNLESS-CONFIGURED (same additive pattern as lib/deploy-gate.sh):
#   A site that is not part of any pair (no `paired_with:` and nothing points at
#   it) is untouched — pair_guard returns 0 immediately. Pairing is opt-in;
#   declaring `paired_with:` in nwp.yml is the act of configuring it.
#
# FAIL-CLOSED: once a site IS declared paired, a MISSING or UNPARSEABLE pair
# contract means the invariants cannot be verified, so the guard REFUSES the
# deploy (set NWP_PAIR_GATE_SOFT=true to soften to a warning while an operator
# is mid-way through authoring a contract — mirrors deploy-gate's inverse).
#
# ⚠ AUTH/OAUTH IS F26-GATED AND NOT IMPLEMENTED HERE. This lib consumes the
# contract's per-environment issuer URLs as *configuration only*. The actual
# OIDC client/issuer WIRING (Drupal simple_oauth client + Moodle issuer
# provisioning) is gated on the F26 human review (nwp/nwp!49) and lands
# separately — see docs/guides/ops75-pair-contract-schema.md §OAuth (STUB).
#
# Config (env overrides; sane defaults):
#   NWP_PAIR_CONTRACT_DIR   default: $PROJECT_ROOT/pairs   (real contracts;
#                           empty today → no real pair configured → no-op)
#   NWP_PAIR_STATE_DIR      default: $PROJECT_ROOT/private/pairs (deployed-version
#                           + RAG state, never committed)
#   NWP_PAIR_GATE_SOFT      "true" ⇒ declared-pair-with-missing-contract WARNS
#                           instead of failing closed
#   NWP_YML                 override the global nwp.yml path (tests/fixtures)
################################################################################

# Requires: lib/ui.sh (print_*), lib/yaml-write.sh (yaml_get_site_field).
_pair_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v yaml_get_site_field >/dev/null 2>&1; then
    # shellcheck source=yaml-write.sh
    source "$_pair_lib_dir/yaml-write.sh"
fi

# --- path resolution ---------------------------------------------------------

pair_config_file() {
    echo "${NWP_YML:-${PROJECT_ROOT:-$HOME/nwp}/nwp.yml}"
}

pair_contract_dir() {
    echo "${NWP_PAIR_CONTRACT_DIR:-${PROJECT_ROOT:-$HOME/nwp}/pairs}"
}

pair_state_dir() {
    echo "${NWP_PAIR_STATE_DIR:-${PROJECT_ROOT:-$HOME/nwp}/private/pairs}"
}

pair_actor() {
    echo "$(id -un)@$(hostname -s 2>/dev/null || hostname)"
}

# Contract file for a pair id. A pair id is the CONSUMER site name (each
# consumer has exactly one provider). Echoes the path (may not exist).
pair_contract_file() {
    local pair_id="$1"
    echo "$(pair_contract_dir)/${pair_id}.pair-contract.yml"
}

# --- role / membership resolution --------------------------------------------

# Echo the provider named by <site>'s `paired_with:` key (i.e. <site> is a
# consumer), or nothing.
pair_provider_of() {
    local site="$1"
    local config="${2:-$(pair_config_file)}"
    [ -n "$site" ] && [ -f "$config" ] || return 0
    yaml_get_site_field "$site" "paired_with" "$config" 2>/dev/null || true
}

# Echo the consumer site(s) whose `paired_with:` equals <site> (i.e. <site> is
# a provider). One per line. yq-first; grep/awk fallback.
pair_consumers_of() {
    local site="$1"
    local config="${2:-$(pair_config_file)}"
    [ -n "$site" ] && [ -f "$config" ] || return 0
    local yq_bin; yq_bin="$(command -v yq || true)"
    if [ -n "$yq_bin" ]; then
        PROV="$site" "$yq_bin" e -r \
            '.sites | to_entries | .[] | select(.value.paired_with == strenv(PROV)) | .key' \
            "$config" 2>/dev/null | grep -v '^null$' || true
        return 0
    fi
    # Fallback: walk the sites: block, remembering the current site key, and
    # print it when a `paired_with: <site>` line is seen inside its block.
    awk -v prov="$site" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && /^  [a-zA-Z0-9_-]+:/ { cur = $1; sub(":", "", cur) }
        in_sites && $0 ~ "^    paired_with: *" prov "[[:space:]]*$" { print cur }
    ' "$config" || true
}

# Resolve <site>'s role in a pair. Echoes "<role> <pair_id>" where role is
# "consumer" or "provider"; echoes nothing when <site> is not paired.
# If a site is both (not expected), consumer wins (its own paired_with is
# authoritative for its promotions).
pair_role_of() {
    local site="$1"
    local config="${2:-$(pair_config_file)}"
    local prov
    prov="$(pair_provider_of "$site" "$config")"
    if [ -n "$prov" ] && [ "$prov" != "null" ]; then
        echo "consumer $site"      # pair id == consumer name
        return 0
    fi
    local cons
    cons="$(pair_consumers_of "$site" "$config" | head -n1)"
    if [ -n "$cons" ]; then
        echo "provider $cons"      # pair id == consumer name
        return 0
    fi
    return 0
}

# --- contract reading --------------------------------------------------------

# Read a scalar field from a pair contract file via yq. Echoes value or "".
pair_contract_get() {
    local file="$1"
    local path="$2"
    [ -f "$file" ] || return 1
    local yq_bin; yq_bin="$(command -v yq || true)"
    [ -n "$yq_bin" ] || return 1
    local val
    val=$("$yq_bin" e "${path} // \"\"" "$file" 2>/dev/null)
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        return 1
    fi
    printf '%s\n' "$val"
    return 0
}

# 0 if the contract file exists and parses as YAML with the required keys.
pair_contract_valid() {
    local file="$1"
    [ -f "$file" ] || return 1
    local yq_bin; yq_bin="$(command -v yq || true)"
    [ -n "$yq_bin" ] || return 1
    "$yq_bin" e '.' "$file" >/dev/null 2>&1 || return 1
    # Required keys: contract_version, provider, consumer.
    pair_contract_get "$file" '.contract_version' >/dev/null || return 1
    pair_contract_get "$file" '.provider'         >/dev/null || return 1
    pair_contract_get "$file" '.consumer'         >/dev/null || return 1
    return 0
}

# 0 if the contract declares identity coupling at <tier> (uid_lock true AND
# tier listed in identity.coupled_tiers).
pair_contract_couples_tier() {
    local file="$1"
    local tier="$2"
    local uid_lock
    uid_lock="$(pair_contract_get "$file" '.identity.uid_lock' 2>/dev/null || echo false)"
    [ "$uid_lock" = "true" ] || return 1
    local yq_bin; yq_bin="$(command -v yq || true)"
    [ -n "$yq_bin" ] || return 1
    TIER="$tier" "$yq_bin" e -e \
        '[.identity.coupled_tiers // [] | .[] | select(. == strenv(TIER))] | length > 0' \
        "$file" >/dev/null 2>&1
}

# --- deployed-version + RAG state (private/, never committed) -----------------
#
# The deployed contract_version each side reached at each tier is recorded on a
# successful promotion (pair_guard_record) so the ordering rule can compare
# provider vs consumer. Absent record ⇒ "never deployed at this tier".

pair_state_get() {
    local pair_id="$1" side="$2" tier="$3"
    local f; f="$(pair_state_dir)/${pair_id}.${side}.${tier}.cv"
    [ -f "$f" ] && cat "$f" 2>/dev/null || true
}

# Record that <side> reached contract_version <cv> at <tier>. Called by the
# deploy verbs on SUCCESS (best-effort; never fatal to a deploy).
pair_guard_record() {
    local pair_id="$1" side="$2" tier="$3" cv="$4"
    [ -n "$pair_id" ] && [ -n "$side" ] && [ -n "$tier" ] && [ -n "$cv" ] || return 0
    local dir; dir="$(pair_state_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s\n' "$cv" > "$dir/${pair_id}.${side}.${tier}.cv" 2>/dev/null || true
    echo "$(date -u +%FT%TZ) who=$(pair_actor) recorded side=$side tier=$tier cv=$cv" \
        >> "$dir/${pair_id}.log" 2>/dev/null || true
    return 0
}

# Echo the pair RAG for a tier: green|amber|red|unknown. Written by the pair
# smoke suite (pair-smoke.sh). Only "red" blocks a promotion.
pair_rag_get() {
    local pair_id="$1" tier="$2"
    local f; f="$(pair_state_dir)/${pair_id}.${tier}.rag"
    if [ -f "$f" ]; then
        cat "$f" 2>/dev/null || echo unknown
    else
        echo unknown
    fi
}

# Set the pair RAG for a tier (green|amber|red). Written by pair-smoke.sh after
# a run. Best-effort; never fatal.
pair_rag_set() {
    local pair_id="$1" tier="$2" rag="$3"
    [ -n "$pair_id" ] && [ -n "$tier" ] && [ -n "$rag" ] || return 0
    local dir; dir="$(pair_state_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s\n' "$rag" > "$dir/${pair_id}.${tier}.rag" 2>/dev/null || true
    echo "$(date -u +%FT%TZ) who=$(pair_actor) rag tier=$tier value=$rag" \
        >> "$dir/${pair_id}.log" 2>/dev/null || true
    return 0
}

# --- ledger (private/, never committed) --------------------------------------

pair_ledger_append() {
    local pair_id="$1"; shift
    local dir; dir="$(pair_state_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    echo "$(date -u +%FT%TZ) who=$(pair_actor) $*" >> "$dir/${pair_id}.log" 2>/dev/null || true
    return 0
}

# --- messaging (TTY-safe) -----------------------------------------------------

_pair_note() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf '%s\n' "$*" >&2; fi; }
_pair_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf '%s\n' "$*" >&2; fi; }
_pair_info() { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n' "$*"; fi; }

################################################################################
# pair_guard <site> <target-tier> <cmd> <code-only> <override-pair>
#
#   site          the site being promoted (base name)
#   target-tier   live | prod
#   cmd           label for messages/ledger (stg2live|stg2prod|live2prod)
#   code-only     true|false  (was --code-only passed?)
#   override-pair true|false  (was --override-pair passed?)
#
# Returns 0 = proceed, non-zero = refuse the deploy. Called at the same
# choke-point as canonical_guard_content_push / maturity_guard_deploy, AFTER
# maturity_guard_deploy and BEFORE deploy_gate_require.
################################################################################
pair_guard() {
    local site="${1:?pair_guard: site required}"
    local target="${2:?pair_guard: target tier required}"
    local cmd="${3:-deploy}"
    local code_only="${4:-false}"
    local override="${5:-false}"

    # 1. Membership — not paired ⇒ no-op (off-unless-configured).
    local role pair_id rest
    rest="$(pair_role_of "$site")"
    role="$(echo "$rest" | awk '{print $1}')"
    pair_id="$(echo "$rest" | awk '{print $2}')"
    if [ -z "$role" ] || [ -z "$pair_id" ]; then
        return 0
    fi

    # 2. Contract — required once a pair is declared. Fail closed if missing.
    local contract; contract="$(pair_contract_file "$pair_id")"
    if ! pair_contract_valid "$contract"; then
        if [ "${NWP_PAIR_GATE_SOFT:-false}" = "true" ]; then
            _pair_note "pair_guard: '$site' is paired ($pair_id) but its contract is missing/invalid"
            _pair_note "  ($contract) — NWP_PAIR_GATE_SOFT=true, proceeding WITHOUT pair checks."
            pair_ledger_append "$pair_id" "action=soft-skip cmd=$cmd site=$site target=$target reason=no-contract"
            return 0
        fi
        _pair_err "REFUSED: '$site' is declared paired ($pair_id) but its pair contract is missing or invalid:"
        _pair_err "  expected a valid pair-contract.yml at: $contract"
        _pair_info "The pair invariants (ADR-0031 D2/D5/D6) cannot be verified without it — failing closed."
        _pair_info "Fixes: author the contract (see docs/guides/ops75-pair-contract-schema.md +"
        _pair_info "       pair-contract.example.yml), or remove the 'paired_with:' key if this site is not paired,"
        _pair_info "       or set NWP_PAIR_GATE_SOFT=true to proceed without pair checks (audited)."
        return 1
    fi

    local provider consumer cv
    provider="$(pair_contract_get "$contract" '.provider')"
    consumer="$(pair_contract_get "$contract" '.consumer')"
    cv="$(pair_contract_get "$contract" '.contract_version')"

    # 3. Red-pair block — a red pair means the coupling is currently broken.
    local rag; rag="$(pair_rag_get "$pair_id" "$target")"
    if [ "$rag" = "red" ] && [ "$override" != "true" ]; then
        _pair_err "REFUSED: pair '$pair_id' is RED at $target (last pair-smoke failed)."
        _pair_err "Promoting either half onto a broken pair is refused (ADR-0031 D5)."
        _pair_info "Investigate: pl pair status $consumer   /   pl pair-smoke $consumer --tier=$target --dry-run"
        _pair_info "To override once resolved (ledgered): re-run with --override-pair."
        return 1
    fi

    # 4. Role-specific invariants.
    if [ "$role" = "consumer" ]; then
        # 4a. Provider-first ordering on a contract bump (D5). The consumer may
        # not run a contract_version the provider has not reached at this tier.
        local prov_cv; prov_cv="$(pair_state_get "$pair_id" "provider" "$target")"
        if [ -z "$prov_cv" ]; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED: consumer '$site' promotion to $target, but provider '$provider' has no"
                _pair_err "recorded deployment at $target — provider must promote first (ADR-0031 D5)."
                _pair_info "Deploy the provider to $target first (pl stg2live $provider ...), then retry."
                _pair_info "Override (ledgered): --override-pair."
                return 1
            fi
        elif [ "${cv:-0}" -gt "${prov_cv:-0}" ] 2>/dev/null; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED: consumer '$site' wants contract_version $cv but provider '$provider' is at"
                _pair_err "contract_version $prov_cv at $target — provider promotes first (ADR-0031 D5)."
                _pair_info "Deploy the provider to $target first, then retry. Override (ledgered): --override-pair."
                return 1
            fi
        fi
        # 4b. Consumer user-state rule: never full-DB to a paired live consumer.
        if [ "$code_only" != "true" ] && pair_contract_couples_tier "$contract" "$target"; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED: '$site' is an identity-coupled CONSUMER at $target — a full-DB push would"
                _pair_err "clobber real users' learning state (minors' records, plane 5b). (ADR-0031 D6)."
                _pair_info "Deploy code/config only: re-run with --code-only."
                _pair_info "Override (ledgered): --override-pair."
                return 1
            fi
        fi
    elif [ "$role" = "provider" ]; then
        # 4c. D6 provider invariant: full-DB push to an identity-coupled live/prod
        # provider renumbers uids and severs the consumer's UID-locks.
        if [ "$code_only" != "true" ] && pair_contract_couples_tier "$contract" "$target"; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED: '$site' is an identity-coupled PROVIDER at $target — a full-DB push would"
                _pair_err "renumber Drupal uids and sever every '$consumer' SSO identity (ADR-0031 D6)."
                _pair_info "Deploy code/config only: re-run with --code-only (the standing rule until this)."
                _pair_info "Override (ledgered): --override-pair."
                return 1
            fi
        fi
    fi

    # 5. Override path — proceed loudly + ledger who/when/what.
    if [ "$override" = "true" ]; then
        echo "" >&2
        _pair_note "════════════════════════════════════════════════════════════════"
        _pair_note "PAIR OVERRIDE: promoting '$site' ($role of pair '$pair_id') despite a"
        _pair_note "pair-invariant condition (ordering / identity-coupling / red-pair)."
        _pair_note "This is recorded in $(pair_state_dir)/${pair_id}.log."
        _pair_note "════════════════════════════════════════════════════════════════"
        echo "" >&2
        pair_ledger_append "$pair_id" \
            "action=override cmd=$cmd site=$site role=$role target=$target cv=$cv rag=$rag code_only=$code_only"
    fi

    return 0
}

# pair_guard_record_success <site> <tier>
#   Convenience wrapper the deploy verbs call AFTER a successful promotion:
#   resolves the pair + contract_version for <site> and records it. No-op when
#   the site is not paired or has no valid contract. Never fatal.
pair_guard_record_success() {
    local site="$1" tier="$2"
    [ -n "$site" ] && [ -n "$tier" ] || return 0
    local rest role pair_id
    rest="$(pair_role_of "$site")"
    role="$(echo "$rest" | awk '{print $1}')"
    pair_id="$(echo "$rest" | awk '{print $2}')"
    [ -n "$role" ] && [ -n "$pair_id" ] || return 0
    local contract; contract="$(pair_contract_file "$pair_id")"
    pair_contract_valid "$contract" || return 0
    local cv; cv="$(pair_contract_get "$contract" '.contract_version')"
    [ -n "$cv" ] || return 0
    pair_guard_record "$pair_id" "$role" "$tier" "$cv"
    return 0
}
