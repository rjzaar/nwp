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

# --- schema-pin verification (P74 Phase 3) -----------------------------------
#
# Each surface in the pair contract MAY carry `schema:` (a repo-relative path to
# the surface's JSON Schema in contracts/) + `schema_sha256:` (its pin). P74
# Phase 0 wired the pins in but left them inert; Phase 3 makes pair_guard
# fail-closed on a mismatch — the deploy-time realization of "the consumer
# trusts the schema by signature/hash, not host" (research §2).
#
# OFF-UNLESS-DECLARED: a surface without both keys is skipped, so a contract
# with no schema pins is a no-op (returns 0). Where a pin IS declared:
#   * the schema file MISSING            → FAIL (can't verify → fail-closed)
#   * the on-disk sha256 ≠ the pin       → FAIL (the wire shape drifted from the
#                                          pinned/signed contract)
# Echoes one problem per line on failure; returns non-zero if any surface fails.
pair_schema_verify() {
    local file="$1"
    local root="${PROJECT_ROOT:-$HOME/nwp}"
    [ -f "$file" ] || return 0
    local yq_bin; yq_bin="$(command -v yq || true)"
    [ -n "$yq_bin" ] || return 0     # no yq ⇒ cannot read pins ⇒ no-op

    local rc=0 surface schema pin actual abspath
    while IFS= read -r surface; do
        [ -n "$surface" ] || continue
        # Export SURF so strenv(SURF) in the yq subshell can read it (a plain
        # prefix assignment before an assignment word is NOT exported).
        export SURF="$surface"
        schema="$("$yq_bin" e -r '.surfaces[strenv(SURF)].schema // ""' "$file" 2>/dev/null)"
        pin="$("$yq_bin" e -r '.surfaces[strenv(SURF)].schema_sha256 // ""' "$file" 2>/dev/null)"
        unset SURF
        [ -n "$schema" ] && [ "$schema" != "null" ] && [ -n "$pin" ] && [ "$pin" != "null" ] || continue
        abspath="$root/$schema"
        if [ ! -f "$abspath" ]; then
            echo "surface '$surface': schema file missing ($schema)"
            rc=1; continue
        fi
        actual="$(sha256sum "$abspath" 2>/dev/null | awk '{print $1}')"
        if [ "$actual" != "$pin" ]; then
            echo "surface '$surface': schema_sha256 mismatch — $schema is $actual, contract pins $pin"
            rc=1
        fi
    done < <("$yq_bin" e -r '.surfaces // {} | keys | .[]' "$file" 2>/dev/null | grep -v '^null$')
    return "$rc"
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

# pair_provider_sub_shape_guard <contract> <provider_code_root> <target_tier>
#
# The `sub_stability` gap that let nwp/ops#83's drift ship: pair_guard's D6 rule
# only blocks a FULL-DB push. But a --code-only push (which D6 permits) also
# severs every consumer UID-lock if the provider CODE reverts the `sub` shape —
# e.g. deploying a branch whose nwc_oidc_claims module emits sub=$account->id()
# (the serial uid) instead of sub=$user->uuid(). The contract declares
# `identity.sub_stability: uuid`, but nothing verified the code honoured it —
# `sub_stability` was read by NO code, only comments.
#
# This is that missing check. It is a STATIC assertion on the provider source
# about to be deployed: the file(s) matching `identity.sub_source` (a glob under
# the provider code root) must contain `identity.sub_assert` (a grep -E pattern
# that proves the contracted sub shape is emitted).
#
# OPT-IN and fail-SAFE: no-op (returns 0) unless the contract couples the tier
# AND declares sub_stability AND declares BOTH sub_source and sub_assert. So it
# stays inert until an operator wires those fields — it can never block a deploy
# it was not explicitly configured to guard. When wired and the assertion is
# absent from the code, it returns 1 (REFUSE).
#
# Returns: 0 = pass or not-applicable · 1 = REFUSE (assertion missing) ·
#          2 = misconfigured (declared but unverifiable — treated as refuse by
#              callers, but distinguishable for diagnostics).
pair_provider_sub_shape_guard() {
    local contract="$1"
    local code_root="$2"
    local target="$3"

    [ -f "$contract" ] || return 0
    pair_contract_couples_tier "$contract" "$target" || return 0

    local stability
    stability="$(pair_contract_get "$contract" '.identity.sub_stability' 2>/dev/null || true)"
    [ -n "$stability" ] || return 0   # not declared → nothing to enforce.

    local source_glob assert_re
    source_glob="$(pair_contract_get "$contract" '.identity.sub_source' 2>/dev/null || true)"
    assert_re="$(pair_contract_get "$contract" '.identity.sub_assert' 2>/dev/null || true)"

    # Declared stability but no enforceable assertion → advisory only, never block.
    if [ -z "$source_glob" ] || [ -z "$assert_re" ]; then
        _pair_info "pair sub-shape: '$stability' declared but no sub_source/sub_assert to enforce it (advisory)."
        return 0
    fi

    if [ -z "$code_root" ] || [ ! -d "$code_root" ]; then
        _pair_err "pair sub-shape: cannot verify — provider code root '$code_root' not found."
        return 2
    fi

    # Resolve the glob under the code root and grep the matches for the assertion.
    # The ls runs in a subshell cd'd to code_root (so the glob is relative to the
    # provider tree), but the grep runs here, so re-anchor each match with
    # "$code_root/$f".
    local matches matched=0 found=0 f
    matches="$(cd "$code_root" 2>/dev/null && eval "ls -1 $source_glob" 2>/dev/null)" || true
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$code_root/$f" ] || continue
        matched=1
        if grep -Eq "$assert_re" "$code_root/$f"; then
            found=1
            break
        fi
    done <<< "$matches"

    if [ "$matched" -eq 0 ]; then
        _pair_err "pair sub-shape: no file matched sub_source '$source_glob' under '$code_root'."
        return 2
    fi
    if [ "$found" -eq 1 ]; then
        return 0
    fi

    _pair_err "REFUSED: provider code does not emit the contracted sub shape (sub_stability: $stability)."
    _pair_err "Expected /$assert_re/ in $source_glob — a --code-only deploy of this tree would revert the"
    _pair_err "'$stability' sub and sever every consumer UID-lock (ADR-0031 D9 / nwp/ops#83)."
    return 1
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
    # Optional: the provider's code root, so the sub-shape guard can statically
    # verify the deployed source honours the contracted sub_stability. Omitted by
    # current callers → that check stays inert (opt-in at the caller layer too).
    local code_root="${6:-}"

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

    # 2b. Schema-pin integrity (P74 Phase 3). Fail-closed if a surface's declared
    # schema_sha256 no longer matches the on-disk schema file — the wire shape
    # drifted from the pinned/signed contract and the deploy could break the
    # other side silently. Off-unless-declared (no pins ⇒ pair_schema_verify 0).
    local schema_problems
    if ! schema_problems="$(pair_schema_verify "$contract")"; then
        if [ "${NWP_PAIR_GATE_SOFT:-false}" = "true" ] || [ "$override" = "true" ]; then
            _pair_note "pair_guard: schema-pin mismatch on '$pair_id' (soft/override — proceeding):"
            while IFS= read -r _p; do [ -n "$_p" ] && _pair_note "  - $_p"; done <<< "$schema_problems"
            pair_ledger_append "$pair_id" "action=schema-pin-override cmd=$cmd site=$site target=$target"
        else
            _pair_err "REFUSED: pair '$pair_id' schema pin(s) do not match the on-disk contract schemas:"
            while IFS= read -r _p; do [ -n "$_p" ] && _pair_err "  - $_p"; done <<< "$schema_problems"
            _pair_info "The wire shape drifted from the pinned/signed contract (contracts/*.schema.json)."
            _pair_info "Fixes: re-run 'pl contracts sums' + 'pl contracts sign' and update schema_sha256 in"
            _pair_info "       $(basename "$contract") after an intended (backward-compatible) change; or restore the schema."
            _pair_info "Override (ledgered): --override-pair, or NWP_PAIR_GATE_SOFT=true."
            return 1
        fi
    fi

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
        # 4d. sub-shape invariant (nwp/ops#83): even a --code-only push severs
        # every consumer UID-lock if the provider CODE reverts the contracted sub
        # shape. Opt-in — inert unless a code_root is passed AND the contract
        # declares sub_source/sub_assert.
        if [ -n "$code_root" ]; then
            pair_provider_sub_shape_guard "$contract" "$code_root" "$target"
            local sub_rc=$?
            if [ "$sub_rc" -ne 0 ] && [ "$override" != "true" ]; then
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

################################################################################
# ops#83 — RESTORE choke-point (ADR-0031 D9, both-or-forward invariant)
#
# ADR-0031 D5 says CODE rollback is safe per-site (expand-contract). That is
# FALSE for a DB restore/rebuild at a coupled tier: it can change or drop the
# provider (uuid,uid) map and orphan every consumer UID-lock. sub_stability:uuid
# neutralises WITHIN-half renumber; this guard governs CROSS-half point-in-time
# consistency — the "both-or-forward" invariant:
#
#   You may not restore ONE member to a state OLDER than the OTHER member's
#   identity anchor. Either restore BOTH halves to one logical cut, or move the
#   restored member's identity set only FORWARD (>=) of the counterpart's anchor.
#
# FAIL-CLOSED: at a coupled tier, a restore is REFUSED unless (a) the contract's
# identity.restore block is present, (b) the provider identity ledger exists,
# (c) a consumer join-snapshot exists (pre_check_required), and (d) the target
# anchor is known AND not behind the counterpart. The ONLY escape is a loud,
# typed, ledgered --override-pair. Unpaired / uncoupled-tier restores are no-ops.
#
# ⚠ AI BLAST RADIUS: prod restores stay ver/Solo-gated (per the operator threat model + deploy-gate).
# This guard is the LOGIC layer; it does not itself run a restore.
################################################################################

# Identity anchor per side/tier: a monotonically-increasing integer marking the
# newest identity cut recorded for that side (bumped on a provider ledger dump /
# consumer SSO-lock / promotion). Absent ⇒ "unknown" (empty).
pair_anchor_get() {
    local pair_id="$1" side="$2" tier="$3"
    local f; f="$(pair_state_dir)/${pair_id}.${side}.${tier}.anchor"
    [ -f "$f" ] && cat "$f" 2>/dev/null || true
}

# Set the identity anchor (monotonic guard: never moves an anchor backwards).
pair_anchor_set() {
    local pair_id="$1" side="$2" tier="$3" val="$4"
    [ -n "$pair_id" ] && [ -n "$side" ] && [ -n "$tier" ] && [ -n "$val" ] || return 0
    case "$val" in ''|*[!0-9]*) _pair_err "pair_anchor_set: anchor must be a non-negative integer"; return 1 ;; esac
    local dir; dir="$(pair_state_dir)"; mkdir -p "$dir" 2>/dev/null || return 0
    local cur; cur="$(pair_anchor_get "$pair_id" "$side" "$tier")"
    if [ -n "$cur" ] && [ "$val" -lt "$cur" ] 2>/dev/null; then
        _pair_err "pair_anchor_set: refusing to move ${side}@${tier} anchor BACKWARD ($cur → $val)"
        return 1
    fi
    printf '%s\n' "$val" > "$dir/${pair_id}.${side}.${tier}.anchor" 2>/dev/null || true
    pair_ledger_append "$pair_id" "action=anchor-set side=$side tier=$tier value=$val"
    return 0
}

# Path to the provider identity ledger (written by scripts/f26/nwc-identity-ledger.sh).
pair_ledger_file() {
    local pair_id="$1"
    local dir="${NWP_PAIR_LEDGER_DIR:-$(pair_state_dir)/ledger}"
    echo "${dir}/${pair_id}.provider-identity.jsonl"
}

# 0 if the provider ledger exists and is non-empty with at least one snapshot
# commit line. (Deep hash-chain integrity is verified by the f26 tool; the guard
# only needs presence + structural sanity to decide it CAN reconcile.)
pair_ledger_present() {
    local pair_id="$1"
    local f; f="$(pair_ledger_file "$pair_id")"
    [ -f "$f" ] && [ -s "$f" ] || return 1
    grep -q '"t":"snap"' "$f" 2>/dev/null || return 1
    return 0
}

# Path to the consumer join-snapshot (the ground-truth locked-idnumber list an
# operator captures on the consumer before a coupled-tier restore, ops#83 §3).
pair_join_snapshot_file() {
    local pair_id="$1" tier="$2"
    echo "$(pair_state_dir)/${pair_id}.${tier}.join-snapshot.tsv"
}

################################################################################
# pair_reconcile_classify <ledger-file> <snapshot-file>
#
# ops#83 §3, mechanised. Reads the provider identity ledger's NEWEST snapshot
# and the consumer join-snapshot, and classifies every live UID-lock:
#
#   intact      locked_sub resolves to a uuid the provider still holds
#   repairable  locked_sub is not a uuid but IS a serial uid the ledger carries
#               — the legacy uid-`sub` era. The durable uuid is known, so the
#               repair is deterministic: repoint idnumber at that uuid.
#   orphaned    locked_sub resolves to nothing at all. NOT auto-repairable:
#               ops#83 makes the email fallback a human-gated last resort
#               because recycled/changed addresses can re-point a lock at the
#               wrong person.
#
# Emits one TSV row per live lock: <class> <mdl_id> <locked_sub> <target_uuid>
# (target_uuid empty unless repairable). Returns 0 always; the CALLER decides
# what a non-empty repairable/orphaned set means. Deleted rows (deleted != 0)
# are skipped — a deleted consumer account cannot be a severed identity.
#
# Deliberately does NOT fall back to email matching anywhere.
################################################################################
pair_reconcile_classify() {
    local ledger="$1" snapshot="$2"
    command -v jq >/dev/null 2>&1 || return 2
    [ -f "$ledger" ] && [ -f "$snapshot" ] || return 2

    local latest
    latest="$(grep '"t":"snap"' "$ledger" 2>/dev/null | jq -r '.snap' 2>/dev/null | tail -1)"
    [ -n "$latest" ] && [ "$latest" != "null" ] || return 2

    # Two lookup tables from the newest ledger snapshot: uuid -> 1, uid -> uuid.
    local uuids uids
    uuids="$(jq -r --argjson s "$latest" 'select(.t=="rec" and .snap==$s) | .uuid' "$ledger" 2>/dev/null)"
    uids="$(jq -r --argjson s "$latest" 'select(.t=="rec" and .snap==$s) | "\(.uid)\t\(.uuid)"' "$ledger" 2>/dev/null)"

    local mdl_id locked_sub email deleted first=1
    while IFS=$'\t' read -r mdl_id locked_sub email deleted; do
        # Skip a header row and blanks.
        if [ "$first" -eq 1 ]; then first=0; [ "$mdl_id" = "mdl_id" ] && continue; fi
        [ -n "${mdl_id:-}" ] || continue
        [ -n "${locked_sub:-}" ] || continue
        case "${deleted:-0}" in 0|'') ;; *) continue ;; esac

        if printf '%s\n' "$uuids" | grep -qxF "$locked_sub"; then
            printf 'intact\t%s\t%s\t\n' "$mdl_id" "$locked_sub"
            continue
        fi
        local target
        target="$(printf '%s\n' "$uids" | awk -F'\t' -v k="$locked_sub" '$1==k {print $2; exit}')"
        if [ -n "$target" ]; then
            printf 'repairable\t%s\t%s\t%s\n' "$mdl_id" "$locked_sub" "$target"
        else
            printf 'orphaned\t%s\t%s\t\n' "$mdl_id" "$locked_sub"
        fi
    done < "$snapshot"
    return 0
}

################################################################################
# pair_guard_restore <site> <target-tier> <cmd> <target-anchor> <override-pair> [confirm]
#
#   site           the member being restored (base name)
#   target-tier    dev | stg | live | prod
#   cmd            label for messages/ledger (restore|rollback)
#   target-anchor  integer identity cut the backup represents (empty = unknown)
#   override-pair  true|false  (was --override-pair passed?)
#   confirm        typed confirmation token for the override (must == RESTORE-OVERRIDE);
#                  or set NWP_PAIR_OVERRIDE_CONFIRM=RESTORE-OVERRIDE in the env.
#
# Returns 0 = proceed, non-zero = refuse the restore. Called at the restore
# choke-point (restore.sh destructive DB step; lib/rollback.sh remote path)
# alongside deploy_gate_require — same place pair_guard sits for deploys.
################################################################################
pair_guard_restore() {
    local site="${1:?pair_guard_restore: site required}"
    local target="${2:?pair_guard_restore: target tier required}"
    local cmd="${3:-restore}"
    local target_anchor="${4:-}"
    local override="${5:-false}"
    local confirm="${6:-${NWP_PAIR_OVERRIDE_CONFIRM:-}}"

    # 1. Membership — not paired ⇒ no-op (off-unless-configured).
    local role pair_id rest
    rest="$(pair_role_of "$site")"
    role="$(echo "$rest" | awk '{print $1}')"
    pair_id="$(echo "$rest" | awk '{print $2}')"
    [ -n "$role" ] && [ -n "$pair_id" ] || return 0

    # 2. Contract — required once paired. Fail closed if missing/invalid.
    local contract; contract="$(pair_contract_file "$pair_id")"
    if ! pair_contract_valid "$contract"; then
        if [ "${NWP_PAIR_GATE_SOFT:-false}" = "true" ]; then
            _pair_note "pair_guard_restore: '$site' paired ($pair_id) but contract missing/invalid — SOFT skip."
            pair_ledger_append "$pair_id" "action=restore-soft-skip cmd=$cmd site=$site target=$target reason=no-contract"
            return 0
        fi
        _pair_err "REFUSED restore: '$site' is paired ($pair_id) but its pair contract is missing/invalid ($contract)."
        _pair_info "The both-or-forward invariant (ADR-0031 D9) cannot be verified — failing closed."
        return 1
    fi

    local provider consumer
    provider="$(pair_contract_get "$contract" '.provider')"
    consumer="$(pair_contract_get "$contract" '.consumer')"

    # 3. Only coupled tiers are gated. An uncoupled tier (dev/stg, or a pair with
    #    uid_lock:false) cannot orphan a lock ⇒ restore freely.
    if ! pair_contract_couples_tier "$contract" "$target"; then
        return 0
    fi

    # 4. Contract must carry the ops#83 restore block, else we cannot assert the
    #    invariant — fail closed (a pre-ops#83 contract at a coupled tier).
    local inv precheck
    inv="$(pair_contract_get "$contract" '.identity.restore.invariant' 2>/dev/null || true)"
    precheck="$(pair_contract_get "$contract" '.identity.restore.pre_check_required' 2>/dev/null || echo false)"
    if [ "$inv" != "both-or-forward" ]; then
        if [ "$override" != "true" ]; then
            _pair_err "REFUSED restore: '$site' coupled at $target but contract has no identity.restore.invariant=both-or-forward (ops#83)."
            _pair_info "Add the identity.restore block, or override (ledgered): --override-pair."
            return 1
        fi
    fi

    # 5. Fail-closed pre-checks (design §3): provider ledger + consumer join-snapshot.
    local missing=""
    if ! pair_ledger_present "$pair_id"; then
        missing="provider-identity-ledger ($(pair_ledger_file "$pair_id"))"
    fi
    if [ "$precheck" = "true" ]; then
        local snap; snap="$(pair_join_snapshot_file "$pair_id" "$target")"
        if [ ! -s "$snap" ]; then
            missing="${missing:+$missing; }consumer-join-snapshot ($snap)"
        fi
    fi
    if [ -n "$missing" ] && [ "$override" != "true" ]; then
        _pair_err "REFUSED restore: '$site' ($role of pair '$pair_id') at coupled tier $target — required reconcile inputs are MISSING:"
        _pair_err "  $missing"
        _pair_info "Capture them first: run  scripts/f26/nwc-identity-ledger.sh dump  (provider) and the"
        _pair_info "consumer join-snapshot query (ops#83 §3), then retry. Override (ledgered): --override-pair."
        return 1
    fi

    # 6. Both-or-forward: the restored member's target anchor must be >= the
    #    counterpart's current anchor.
    local counter_side counter_anchor
    if [ "$role" = "provider" ]; then counter_side="consumer"; else counter_side="provider"; fi
    counter_anchor="$(pair_anchor_get "$pair_id" "$counter_side" "$target")"

    if [ -z "$counter_anchor" ]; then
        # Counterpart has never recorded an anchor ⇒ nothing to strand yet.
        _pair_info "pair_guard_restore: counterpart '$counter_side' has no recorded identity anchor at $target — no lock to orphan."
    else
        if [ -z "$target_anchor" ]; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED restore: '$site' target identity anchor is UNKNOWN while '$counter_side' is at anchor $counter_anchor ($target)."
                _pair_err "Cannot prove the restore moves the identity set FORWARD (ADR-0031 D9 both-or-forward) — failing closed."
                _pair_info "Provide the backup's identity anchor (pl pair anchor …), or override (ledgered): --override-pair."
                return 1
            fi
        elif [ "$target_anchor" -lt "$counter_anchor" ] 2>/dev/null; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED restore: restoring '$site' ($role) to anchor $target_anchor is OLDER than '$counter_side' anchor $counter_anchor at $target."
                _pair_err "That would strand every '$counter_side' UID-lock newer than $target_anchor (ADR-0031 D9)."
                _pair_info "Restore BOTH halves to one cut, or to an anchor >= $counter_anchor. Override (ledgered): --override-pair."
                return 1
            fi
        fi
    fi

    # 7. Override path — loud + TYPED confirm + audit. Fail-closed even here: a
    #    bare --override-pair without the typed token is refused.
    if [ "$override" = "true" ]; then
        if [ "$confirm" != "RESTORE-OVERRIDE" ]; then
            if [ -t 0 ]; then
                echo "" >&2
                _pair_note "You are about to OVERRIDE the ops#83 both-or-forward restore invariant for '$site' @ $target."
                _pair_note "This can permanently orphan consumer UID-locks. Type RESTORE-OVERRIDE to proceed:"
                read -r confirm || confirm=""
            fi
        fi
        if [ "$confirm" != "RESTORE-OVERRIDE" ]; then
            _pair_err "REFUSED restore: --override-pair requires the typed confirmation 'RESTORE-OVERRIDE' (got none/mismatch)."
            pair_ledger_append "$pair_id" "action=restore-override-DENIED cmd=$cmd site=$site role=$role target=$target target_anchor=${target_anchor:-unknown}"
            return 1
        fi
        echo "" >&2
        _pair_note "════════════════════════════════════════════════════════════════"
        _pair_note "RESTORE OVERRIDE: '$site' ($role of pair '$pair_id') restored at $target"
        _pair_note "DESPITE the both-or-forward invariant (target_anchor=${target_anchor:-unknown},"
        _pair_note "counterpart=${counter_anchor:-none}). Reconcile per ops#83 §3 immediately after."
        _pair_note "Audited in $(pair_state_dir)/${pair_id}.log."
        _pair_note "════════════════════════════════════════════════════════════════"
        echo "" >&2
        pair_ledger_append "$pair_id" \
            "action=restore-override cmd=$cmd site=$site role=$role target=$target target_anchor=${target_anchor:-unknown} counter=${counter_anchor:-none}"
    fi

    return 0
}
