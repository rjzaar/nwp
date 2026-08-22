#!/bin/bash
################################################################################
# lib/pair.sh — paired-site versioning guard (NWP-ADR-0031 Phase C / nwp/ops#75)
#
# NWP runs PAIRED sites across two stacks that are coupled by OAuth2/OIDC SSO,
# copyright-policy sync and a feedback bridge:
#
#   nwc (Drupal/Open Social, PROVIDER)  ↔  ssc (Moodle, real students, CONSUMER)
#   nwd (Drupal demo,        PROVIDER)  ↔  ssd (Moodle demo,           CONSUMER)
#
# NWP-ADR-0031 D2 makes the *contract* — not the pair — the versioned artifact
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
#   A site that is not part of any pair (no `paired_with:` anywhere, and nothing
#   pointing at it) is untouched — pair_guard returns 0 immediately. Pairing is
#   opt-in; declaring `paired_with:` is the act of configuring it.
#
# FAIL-CLOSED: once a site IS declared paired, a MISSING or UNPARSEABLE pair
# contract means the invariants cannot be verified, so the guard REFUSES the
# deploy (set NWP_PAIR_GATE_SOFT=true to soften to a warning while an operator
# is mid-way through authoring a contract — mirrors deploy-gate's inverse).
#
# FAIL-CLOSED ON *MEMBERSHIP* TOO — the defect this was written to end:
#   "off-unless-configured" and "fail-closed" collide the moment the guard cannot
#   READ the configuration. Until 2026-07-27 the collision was resolved the wrong
#   way: membership was resolved from ONE file in ONE shape, and anything the
#   reader could not parse fell through the `not paired ⇒ return 0` door. The
#   real ssc↔nwc pair was declared in the OTHER file in a DIFFERENT shape
#   (`paired_with: {nwc_canonical: <url>}`), so `pl pair check ssc live` — a
#   full-DB push to the tier whose UID-locks the D6 rule exists to protect —
#   answered ALLOW. The guard was not weak; it was blind, and blindness read as
#   consent.
#
#   So: "I could not read this site's pairing" is now its own answer, distinct
#   from "this site is not paired", and it REFUSES. Same vocabulary as
#   `pl impact --honesty` / boundary_honesty_check: CANNOT VERIFY is NOT a clean
#   result. The only escape is the existing, audited NWP_PAIR_GATE_SOFT=true —
#   deliberately NOT --override-pair, which is a per-invariant override and must
#   not double as a licence to deploy past an unreadable config.
#
# ⚠ AUTH/OAUTH IS F26-GATED AND NOT IMPLEMENTED HERE. This lib consumes the
# contract's per-environment issuer URLs as *configuration only*. The actual
# OIDC client/issuer WIRING (Drupal simple_oauth client + Moodle issuer
# provisioning) is gated on the F26 human review (nwp/nwp!49) and lands
# separately — see docs/guides/ops75-pair-contract-schema.md §OAuth (STUB).
#
# Config (env overrides; sane defaults):
#   NWP_PAIR_CONTRACT_DIR   default: $PROJECT_ROOT/pairs   (SHIPPED contracts —
#                           the ssd↔nwd sample pair)
#   NWP_PAIR_OVERLAY_DIR    default: $PROJECT_ROOT/private/pairs (the PRIVATE
#                           OVERLAY: real instance contracts, searched second;
#                           ops#326 — a pair declared in both dirs fails closed)
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

# ops#326 (engine/site separation): REAL pair contracts live in the PRIVATE
# OVERLAY repo (private/pairs/ — its own reviewed git repo, remote nwp/private),
# searched AFTER the shipped pairs/ (which carries only the ssd↔nwd sample
# pair). The contract stays versioned and MR-reviewable — the MR simply lives
# on the overlay repo. NWP_PAIR_STATE_DIR already points into private/pairs;
# the contract now joins its state.
pair_contract_overlay_dir() {
    echo "${NWP_PAIR_OVERLAY_DIR:-${PROJECT_ROOT:-$HOME/nwp}/private/pairs}"
}

pair_state_dir() {
    echo "${NWP_PAIR_STATE_DIR:-${PROJECT_ROOT:-$HOME/nwp}/private/pairs}"
}

pair_actor() {
    echo "$(id -un)@$(hostname -s 2>/dev/null || hostname)"
}

# Contract file for a pair id. A pair id is the CONSUMER site name (each
# consumer has exactly one provider). Echoes the path (may not exist).
# ops#326: shipped dir first, then the private overlay. A contract declared in
# BOTH is ambiguity about the authority itself — the echoed path is one that
# cannot exist, so every `[ -f ]` / pair_contract_valid caller fails closed.
pair_contract_file() {
    local pair_id="$1" shipped overlay
    shipped="$(pair_contract_dir)/${pair_id}.pair-contract.yml"
    overlay="$(pair_contract_overlay_dir)/${pair_id}.pair-contract.yml"
    if [ -f "$shipped" ] && [ -f "$overlay" ] && [ "$shipped" != "$overlay" ]; then
        echo "pair contract for '${pair_id}' exists in BOTH $(pair_contract_dir) and $(pair_contract_overlay_dir) — remove one; refusing to pick between two reviewed declarations (fail-closed)." >&2
        echo "${shipped}.DUPLICATE-DECLARATION"
        return 2
    fi
    if [ ! -f "$shipped" ] && [ -f "$overlay" ]; then
        echo "$overlay"
    else
        echo "$shipped"
    fi
}

# --- role / membership resolution --------------------------------------------
#
# WHERE A PAIR IS DECLARED, AND IN WHAT SHAPE
#
#   SOURCE OF TRUTH  pairs/<consumer>.pair-contract.yml  →  provider: / consumer:
#   ALSO HONOURED    sites/<consumer>/.nwp.yml           →  paired_with: <site>
#   ALSO HONOURED    nwp.yml sites.<consumer>            →  paired_with: <site>
#
# THE CONTRACT IS THE SOURCE OF TRUTH because it is the only one of the three
# that git can see. `sites/*` and `nwp.yml` are BOTH gitignored operator config
# (.gitignore:14, and nwp.yml by hard rule in CLAUDE.md), so a guard whose
# membership came only from them could not be reviewed in a diff, could not be
# exercised by CI, and could not be observed to be wrong. That is not incidental
# to this defect — it IS the defect: `pairs/ssc.pair-contract.yml` has said
# `provider: nwc / consumer: ssc` in a committed, signed-schema file the whole
# time, while the guard asked a file nobody could see and got silence.
#
# This is also what NWP-ADR-0031 D2 already asserts — "the CONTRACT, not the pair,
# is the versioned artifact". Reading membership from it is that decision
# carried through to the choke-point instead of stopping at the doc.
#
# `paired_with:` keys remain honoured (they are the documented opt-in, and ssd
# uses one today), and they must AGREE with the contract. Disagreement is
# ambiguity, and ambiguity fails closed.
#
# THE SHAPE is a BARE SCALAR site key. That is the only shape the rest of the
# system speaks: example.nwp.yml documents `paired_with: nwc`, pairs/README.md
# documents it, `provider:`/`consumer:` are site keys, and a pair id IS the
# consumer's site key. A map of label→URL cannot name a provider SITE at all, so
# it can never resolve a pair — it can only look like configuration.
#
# Every reader below is TRI-STATE:
#   rc 0  resolved      (echoes the value)
#   rc 1  not declared  (echoes nothing) — the genuine off-unless-configured case
#   rc 2  CANNOT VERIFY (echoes a human reason) — declared but unreadable
# Never collapse 2 into 1. That collapse is the whole bug.

# Per-site (v2) config file for <site>. May not exist.
pair_site_config_file() {
    local site="$1"
    echo "${PROJECT_ROOT:-$HOME/nwp}/sites/${site}/.nwp.yml"
}

# 0 if <value> is a bare site key (what `paired_with:` must name).
_pair_valid_site_key() {
    case "${1:-}" in
        ''|null) return 1 ;;
    esac
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

# awk fallback for _pair_read_decl when yq is unavailable. Same tri-state.
# <site> empty ⇒ top-level `paired_with:` in a per-site file; otherwise the
# `sites.<site>.paired_with` key of a global nwp.yml.
_pair_read_decl_awk() {
    local file="$1" site="${2:-}" raw
    if [ -z "$site" ]; then
        raw="$(awk '
            /^paired_with:/ { line = $0; sub(/^paired_with:[ \t]*/, "", line); print line; found = 1; exit }
            END { exit !found }' "$file" 2>/dev/null)" || return 1
    else
        raw="$(awk -v site="$site" '
            /^sites:/ { in_sites = 1; next }
            in_sites && /^[^ \t]/ { in_sites = 0 }
            in_sites && $0 ~ "^  " site ":[ \t]*(#.*)?$" { in_site = 1; next }
            in_site && /^  [^ \t]/ { in_site = 0 }
            in_site && /^    paired_with:/ { line = $0; sub(/^    paired_with:[ \t]*/, "", line); print line; found = 1; exit }
            END { exit !found }' "$file" 2>/dev/null)" || return 1
    fi
    raw="${raw%%#*}"                                    # strip trailing comment
    raw="${raw#"${raw%%[![:space:]]*}"}"                # ltrim
    raw="${raw%"${raw##*[![:space:]]}"}"                # rtrim
    raw="${raw%\"}"; raw="${raw#\"}"; raw="${raw%\'}"; raw="${raw#\'}"
    if [ -z "$raw" ]; then
        printf "'paired_with:' is present but carries no scalar on its own line (block/map form?) — expected 'paired_with: <provider-site-key>'\n"
        return 2
    fi
    if ! _pair_valid_site_key "$raw"; then
        printf "'paired_with: %s' is not a bare provider site key (a URL or expression cannot name a site)\n" "$raw"
        return 2
    fi
    printf '%s\n' "$raw"
    return 0
}

# _pair_read_decl <file> [site] — read ONE `paired_with:` declaration. Tri-state.
_pair_read_decl() {
    local file="$1" site="${2:-}"
    [ -f "$file" ] || return 1
    if [ ! -r "$file" ]; then
        # A file that EXISTS but cannot be read is blindness, not absence. The
        # yq path already reports this (yq fails to open it), but the awk
        # fallback would exit 1 and read as "not declared" — fail-open on a
        # no-yq host. Say it explicitly, on both paths.
        printf "file exists but is not readable — its 'paired_with:' cannot be read\n"
        return 2
    fi
    local yq_bin; yq_bin="$(command -v yq || true)"
    if [ -z "$yq_bin" ]; then
        _pair_read_decl_awk "$file" "$site"
        return $?
    fi
    local path
    if [ -n "$site" ]; then path='.sites[strenv(PSITE)].paired_with'; else path='.paired_with'; fi
    local tag
    # A yq failure here means the FILE does not parse — that is blindness, not
    # absence. (Deliberately no "\t"/@tsv anywhere: yq versions disagree on
    # escape expansion inside string ops — see the server-state redaction bug.)
    if ! tag="$(PSITE="$site" "$yq_bin" e "$path | tag" "$file" 2>/dev/null)"; then
        printf "file does not parse as YAML, so its 'paired_with:' cannot be read\n"
        return 2
    fi
    case "$tag" in
        '!!null'|'') return 1 ;;
        '!!str')     ;;
        *)
            printf "'paired_with:' is a %s, not a provider site name — expected a bare scalar such as 'paired_with: nwc'\n" "${tag#!!}"
            return 2
            ;;
    esac
    local val
    val="$(PSITE="$site" "$yq_bin" e -r "$path" "$file" 2>/dev/null)" || val=""
    if ! _pair_valid_site_key "$val"; then
        printf "'paired_with: %s' is not a bare provider site key (a URL or expression cannot name a site)\n" "$val"
        return 2
    fi
    printf '%s\n' "$val"
    return 0
}

# Read `provider:`/`consumer:` from a pair contract. yq-first, awk fallback, so a
# host without yq does not read as "every pair contract is unreadable" (which,
# fail-closed, would refuse every deploy in the fleet). rc 1 = absent/unreadable.
_pair_contract_side() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 1
    local yq_bin; yq_bin="$(command -v yq || true)"
    if [ -n "$yq_bin" ]; then
        local v
        v="$("$yq_bin" e -r ".${key} // \"\"" "$file" 2>/dev/null)" || return 1
        [ -n "$v" ] && [ "$v" != "null" ] || return 1
        printf '%s\n' "$v"
        return 0
    fi
    awk -v k="$key" '
        $0 ~ "^" k ":[ \t]" {
            line = $0
            sub("^" k ":[ \t]*", "", line)
            sub(/[ \t]*#.*$/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line != "") { print line; found = 1; exit }
        }
        END { exit !found }' "$file" 2>/dev/null
}

# pair_scan [config] — ONE pass over every pair declaration reachable from this
# checkout: the committed contracts first, then the two operator-config shapes.
# Emits TAB-separated rows, sorted:
#   ok<TAB><consumer><TAB><provider><TAB><file>
#   blind<TAB><site><TAB><file><TAB><reason>          ("?" site = source-wide)
# Always returns 0; the CALLER decides what a blind row means.
pair_scan() {
    local config="${1:-$(pair_config_file)}"
    local root="${PROJECT_ROOT:-$HOME/nwp}"
    local tab=$'\t' nl=$'\n'
    declare -A _p_prov=() _p_file=()
    local f site val rc out="" stem cons prov

    # 0. SOURCE OF TRUTH — the committed pair contracts. A contract DIRECTORY
    # that exists but cannot be listed makes every contract in it invisible —
    # on a bare checkout (CI) the contracts are the ONLY declaration, so a
    # silent skip here would read as "no pairs anywhere". Blindness, not absence.
    local cdir; cdir="$(pair_contract_dir)"
    if [ -d "$cdir" ] && { [ ! -r "$cdir" ] || [ ! -x "$cdir" ]; }; then
        out+="blind${tab}?${tab}${cdir}${tab}pair contract directory exists but is not readable — any contract in it is invisible${nl}"
    fi
    # ops#326: the private overlay is a contract source of equal standing —
    # an unreadable overlay dir is blindness there too.
    local odir; odir="$(pair_contract_overlay_dir)"
    if [ -d "$odir" ] && { [ ! -r "$odir" ] || [ ! -x "$odir" ]; }; then
        out+="blind${tab}?${tab}${odir}${tab}pair contract OVERLAY directory exists but is not readable — any contract in it is invisible${nl}"
    fi
    local sdir="${root}/sites"
    if [ -d "$sdir" ] && { [ ! -r "$sdir" ] || [ ! -x "$sdir" ]; }; then
        out+="blind${tab}?${tab}${sdir}${tab}sites directory exists but is not readable — any per-site 'paired_with:' in it is invisible${nl}"
    fi
    local _cdirs=("$cdir")
    [ "$odir" != "$cdir" ] && _cdirs+=("$odir")
    local _dir
    for _dir in "${_cdirs[@]}"; do
    for f in "$_dir"/*.pair-contract.yml; do
        [ -f "$f" ] || continue
        stem="$(basename "$f")"; stem="${stem%.pair-contract.yml}"
        cons="$(_pair_contract_side "$f" consumer || true)"
        prov="$(_pair_contract_side "$f" provider || true)"
        if [ -z "$cons" ] || [ -z "$prov" ]; then
            # A file that is named like a contract but cannot yield both sides is
            # a declaration we cannot read — not an absence of one.
            out+="blind${tab}?${tab}${f}${tab}pair contract does not yield both 'provider:' and 'consumer:' site keys${nl}"
            continue
        fi
        if ! _pair_valid_site_key "$cons" || ! _pair_valid_site_key "$prov"; then
            out+="blind${tab}?${tab}${f}${tab}'provider: ${prov}' / 'consumer: ${cons}' are not bare site keys${nl}"
            continue
        fi
        if [ "$cons" != "$stem" ]; then
            # pair_contract_file() resolves by pair id == consumer name, so a
            # mismatched filename means the guard would look for this pair's
            # contract somewhere it is not.
            out+="blind${tab}${cons}${tab}${f}${tab}contract declares 'consumer: ${cons}' but is filed as '${stem}.pair-contract.yml' — pair_guard resolves contracts by consumer name and would not find it${nl}"
            continue
        fi
        if [ "$_dir" = "$odir" ] && [ -n "${_p_prov[$cons]:-}" ]; then
            # ops#326: declared in BOTH the shipped and overlay dirs. Two
            # reviewed declarations for one pair is ambiguity about the
            # authority itself — blind, never a precedence rule.
            out+="blind${tab}${cons}${tab}${f}${tab}pair contract for '${cons}' exists in BOTH ${cdir} and ${odir} — remove one (fail-closed)${nl}"
            continue
        fi
        _p_prov["$cons"]="$prov"; _p_file["$cons"]="$f"
    done
    done

    # 1. Per-site v2 operator config.
    for f in "$root"/sites/*/.nwp.yml; do
        [ -f "$f" ] || continue
        site="$(basename "$(dirname "$f")")"
        val="$(_pair_read_decl "$f" "")"; rc=$?
        if [ "$rc" -eq 2 ]; then
            out+="blind${tab}${site}${tab}${f}${tab}${val}${nl}"
            unset "_p_prov[$site]"
        elif [ "$rc" -eq 0 ]; then
            if [ -n "${_p_prov[$site]:-}" ] && [ "${_p_prov[$site]}" != "$val" ]; then
                out+="blind${tab}${site}${tab}${f}${tab}conflicting pairing: ${_p_file[$site]} says '${_p_prov[$site]}' but this file says '${val}'${nl}"
                unset "_p_prov[$site]"
            elif [ -z "${_p_prov[$site]:-}" ]; then
                _p_prov["$site"]="$val"; _p_file["$site"]="$f"
            fi
        fi
    done

    # 2. Global nwp.yml sites: block.
    if [ -f "$config" ]; then
        while IFS= read -r site; do
            [ -n "$site" ] || continue
            val="$(_pair_read_decl "$config" "$site")"; rc=$?
            if [ "$rc" -eq 2 ]; then
                out+="blind${tab}${site}${tab}${config}${tab}${val}${nl}"
                unset "_p_prov[$site]"
            elif [ "$rc" -eq 0 ]; then
                if [ -n "${_p_prov[$site]:-}" ] && [ "${_p_prov[$site]}" != "$val" ]; then
                    out+="blind${tab}${site}${tab}${config}${tab}conflicting pairing: ${_p_file[$site]} says '${_p_prov[$site]}' but this file says '${val}'${nl}"
                    unset "_p_prov[$site]"
                elif [ -z "${_p_prov[$site]:-}" ]; then
                    _p_prov["$site"]="$val"; _p_file["$site"]="$config"
                fi
            fi
        done < <(_pair_site_keys "$config")
    fi

    for site in "${!_p_prov[@]}"; do
        out+="ok${tab}${site}${tab}${_p_prov[$site]}${tab}${_p_file[$site]}${nl}"
    done
    [ -n "$out" ] && printf '%s' "$out" | LC_ALL=C sort
    return 0
}

# Echo the site keys under a global nwp.yml `sites:` block. yq-first.
_pair_site_keys() {
    local config="$1"
    [ -f "$config" ] || return 0
    local yq_bin; yq_bin="$(command -v yq || true)"
    if [ -n "$yq_bin" ]; then
        "$yq_bin" e -r '.sites // {} | keys | .[]' "$config" 2>/dev/null | grep -v '^null$' || true
        return 0
    fi
    awk '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[^ \t]/ { in_sites = 0 }
        in_sites && /^  [A-Za-z0-9][A-Za-z0-9_.-]*:[ \t]*(#.*)?$/ { k = $1; sub(":", "", k); print k }
    ' "$config" 2>/dev/null || true
}

# Echo the provider <site> is paired to (i.e. <site> is a consumer). Tri-state:
# 0 = provider echoed · 1 = not declared · 2 = CANNOT VERIFY (reason echoed).
pair_provider_of() {
    local site="$1"
    local config="${2:-$(pair_config_file)}"
    [ -n "$site" ] || return 1
    local rows; rows="$(pair_scan "$config")"
    local blind prov
    blind="$(printf '%s\n' "$rows" | awk -F'\t' -v s="$site" '$1 == "blind" && $2 == s { printf "%s: %s\n", $3, $4 }')"
    [ -n "$blind" ] && { printf '%s\n' "$blind"; return 2; }
    prov="$(printf '%s\n' "$rows" | awk -F'\t' -v s="$site" '$1 == "ok" && $2 == s { print $3; exit }')"
    [ -n "$prov" ] || return 1
    printf '%s\n' "$prov"
    return 0
}

# Echo the consumer site(s) paired to <site> (i.e. <site> is a provider), one per
# line. Blind declarations are NOT reported here — ask pair_scan_problems, which
# is what pair_membership_of does.
pair_consumers_of() {
    local site="$1"
    local config="${2:-$(pair_config_file)}"
    [ -n "$site" ] || return 0
    pair_scan "$config" | awk -F'\t' -v p="$site" '$1 == "ok" && $3 == p { print $2 }' || true
    return 0
}

# Echo one "site (file): reason" line per UNREADABLE pair declaration in the
# tree. Empty output = every declaration reachable from here was legible.
pair_scan_problems() {
    local config="${1:-$(pair_config_file)}"
    pair_scan "$config" | awk -F'\t' '$1 == "blind" { printf "%s (%s): %s\n", $2, $3, $4 }' || true
    return 0
}

# pair_membership_of <site> [config] — THE guard-facing resolver. Tri-state:
#   rc 0  echoes "<role> <pair_id>"   role = consumer|provider, pair_id = consumer
#   rc 1  echoes nothing              genuinely unpaired ⇒ pair_guard no-ops
#   rc 2  echoes the reason(s)        CANNOT VERIFY ⇒ pair_guard REFUSES
# If a site is somehow both, consumer wins (its own declaration is authoritative
# for its own promotions). One scan, so the three questions cannot disagree.
pair_membership_of() {
    local site="$1"
    local config="${2:-$(pair_config_file)}"
    [ -n "$site" ] || return 1
    local rows; rows="$(pair_scan "$config")"

    local blind prov cons problems
    blind="$(printf '%s\n' "$rows" | awk -F'\t' -v s="$site" '$1 == "blind" && $2 == s { printf "%s: %s\n", $3, $4 }')"
    if [ -n "$blind" ]; then printf '%s\n' "$blind"; return 2; fi

    prov="$(printf '%s\n' "$rows" | awk -F'\t' -v s="$site" '$1 == "ok" && $2 == s { print $3; exit }')"
    if [ -n "$prov" ]; then echo "consumer $site"; return 0; fi

    cons="$(printf '%s\n' "$rows" | awk -F'\t' -v s="$site" '$1 == "ok" && $3 == s { print $2; exit }')"
    if [ -n "$cons" ]; then echo "provider $cons"; return 0; fi

    # Nothing legible points at <site> — but if ANY declaration in the tree is
    # illegible, "nothing points at it" is a guess, not a finding. Say so.
    problems="$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "blind" { printf "%s (%s): %s\n", $2, $3, $4 }')"
    if [ -n "$problems" ]; then
        printf "cannot determine whether any site is paired to '%s' — unreadable declaration(s):\n%s\n" "$site" "$problems"
        return 2
    fi
    return 1
}

# BACK-COMPAT wrapper: echoes "<role> <pair_id>" or nothing, always rc 0.
# ⚠ It reports blindness as "unpaired". NEVER use it in a guard decision — use
# pair_membership_of. Kept for display/labelling callers (pl link, pl status).
pair_role_of() {
    local out rc
    out="$(pair_membership_of "$@")"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out"
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

# pair_contract_couples_tier <file> <tier> — does the contract declare identity
# coupling at <tier>? TRI-STATE, same vocabulary as pair_membership_of:
#   rc 0  couples       (uid_lock is boolean true AND <tier> is listed in a
#                        legible identity.coupled_tiers sequence)
#   rc 1  does not couple — but ONLY via a LEGIBLE statement: no identity
#         coupling declared at all, an explicit `uid_lock: false`, or a legible
#         tier list that does not name <tier>. Off-unless-configured.
#   rc 2  CANNOT VERIFY (echoes a human reason) — coupling is DECLARED but the
#         declaration is illegible. `uid_lock: yes` (a string in YAML 1.2),
#         a map where a bool belongs, `coupled_tiers: live` (scalar, not list),
#         `[Live]` (not a bare lowercase tier key), or uid_lock:true with no
#         coupled_tiers at all. Every one of those used to collapse into
#         "not coupled" — the same fail-open shape that made the membership
#         resolver inert. Never collapse 2 into 1.
pair_contract_couples_tier() {
    local file="$1"
    local tier="$2"
    local yq_bin; yq_bin="$(command -v yq || true)"
    if [ -z "$yq_bin" ]; then
        printf "yq unavailable — cannot read identity coupling from %s\n" "$file"
        return 2
    fi
    local tag
    if ! tag="$("$yq_bin" e '.identity.uid_lock | tag' "$file" 2>/dev/null)"; then
        printf "%s does not parse, so identity.uid_lock cannot be read\n" "$file"
        return 2
    fi
    case "$tag" in
        '!!null'|'') return 1 ;;   # no identity coupling declared — legibly off
        '!!bool')    ;;
        *)
            printf "identity.uid_lock is a %s, not the boolean true/false — 'yes'/'on' are strings in YAML 1.2 and would silently read as UNcoupled\n" "${tag#!!}"
            return 2
            ;;
    esac
    local uid_lock
    uid_lock="$("$yq_bin" e -r '.identity.uid_lock' "$file" 2>/dev/null)" || uid_lock=""
    [ "$uid_lock" = "true" ] || return 1   # explicit false — legibly off
    # uid_lock:true ⇒ the tier list is load-bearing and must be legible.
    local ttag
    ttag="$("$yq_bin" e '.identity.coupled_tiers | tag' "$file" 2>/dev/null)" || ttag=""
    case "$ttag" in
        '!!seq') ;;
        '!!null'|'')
            printf "identity.uid_lock is true but identity.coupled_tiers is not declared — cannot say WHICH tiers are identity-coupled\n"
            return 2
            ;;
        *)
            printf "identity.coupled_tiers is a %s, not a list of tiers (expected e.g. [live, prod])\n" "${ttag#!!}"
            return 2
            ;;
    esac
    local bad
    bad="$("$yq_bin" e -r '[.identity.coupled_tiers[] | select((tag != "!!str") or (test("^[a-z][a-z0-9_-]*$") | not))] | length' "$file" 2>/dev/null)" || bad=""
    if [ "$bad" != "0" ]; then
        printf "identity.coupled_tiers contains entries that are not bare lowercase tier keys — a garbled tier name would silently read as UNcoupled\n"
        return 2
    fi
    if TIER="$tier" "$yq_bin" e -e \
        '[.identity.coupled_tiers[] | select(. == strenv(TIER))] | length > 0' \
        "$file" >/dev/null 2>&1; then
        return 0
    fi
    return 1
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
    local _couples_reason _couples_rc=0
    _couples_reason="$(pair_contract_couples_tier "$contract" "$target")" || _couples_rc=$?
    if [ "$_couples_rc" -eq 2 ]; then
        # Declared but illegible coupling is CANNOT VERIFY, not "uncoupled" —
        # rc 2 is this guard's documented "declared but unverifiable" verdict.
        _pair_err "pair sub-shape: cannot verify — identity coupling in $(basename "$contract") is illegible: ${_couples_reason}"
        return 2
    fi
    [ "$_couples_rc" -eq 0 ] || return 0

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
    _pair_err "'$stability' sub and sever every consumer UID-lock (NWP-ADR-0031 D9 / nwp/ops#83)."
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

# _pair_blind_refuse <site> <cmd> <target> <reasons>
# Shared handling for "the pairing declaration exists but I cannot read it".
# Returns 0 ⇒ the caller may PROCEED (NWP_PAIR_GATE_SOFT=true, audited);
# returns 1 ⇒ the caller must REFUSE. Same shape of words as
# boundary_honesty_check's CANNOT VERIFY verdict — one vocabulary, not two.
_pair_blind_refuse() {
    local site="$1" cmd="$2" target="$3" reasons="$4"
    if [ "${NWP_PAIR_GATE_SOFT:-false}" = "true" ]; then
        _pair_note "pair_guard: CANNOT VERIFY '$site' pair membership — NWP_PAIR_GATE_SOFT=true, proceeding:"
        while IFS= read -r _r; do [ -n "$_r" ] && _pair_note "  - $_r"; done <<< "$reasons"
        pair_ledger_append "_unresolved" "action=blind-soft-skip cmd=$cmd site=$site target=$target"
        return 0
    fi
    _pair_err "REFUSED: CANNOT VERIFY whether '$site' is part of a pair — a pairing declaration"
    _pair_err "this decision depends on is present but unreadable:"
    while IFS= read -r _r; do [ -n "$_r" ] && _pair_err "  - $_r"; done <<< "$reasons"
    _pair_info "This is NOT a clean result: the guard found no pair because it could not look, and a"
    _pair_info "full-DB promotion past an unread pairing is exactly what severs the ssc UID-locks"
    _pair_info "(NWP-ADR-0031 D6). Unreadable therefore REFUSES, it does not fall through to 'unpaired'."
    _pair_info "Fix: declare it in the canonical shape — 'paired_with: <provider-site-key>' as a bare"
    _pair_info "     scalar in sites/<consumer>/.nwp.yml (see pairs/README.md); or remove the key if"
    _pair_info "     the site is genuinely unpaired."
    _pair_info "Escape (audited): NWP_PAIR_GATE_SOFT=true. --override-pair does NOT cover this."
    pair_ledger_append "_unresolved" "action=blind-refuse cmd=$cmd site=$site target=$target"
    return 1
}

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

    # 1. Membership — tri-state. Not paired ⇒ no-op (off-unless-configured);
    #    UNREADABLE ⇒ refuse (blindness is not consent).
    local role pair_id rest mrc
    rest="$(pair_membership_of "$site")"; mrc=$?
    if [ "$mrc" -eq 2 ]; then
        if ! _pair_blind_refuse "$site" "$cmd" "$target" "$rest"; then return 1; fi
        return 0
    fi
    [ "$mrc" -eq 0 ] || return 0
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
        _pair_info "The pair invariants (NWP-ADR-0031 D2/D5/D6) cannot be verified without it — failing closed."
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
        _pair_err "Promoting either half onto a broken pair is refused (NWP-ADR-0031 D5)."
        _pair_info "Investigate: pl pair status $consumer   /   pl pair-smoke $consumer --tier=$target --dry-run"
        _pair_info "To override once resolved (ledgered): re-run with --override-pair."
        return 1
    fi

    # 3b. Identity-coupling legibility. Both D6 branches below hang off "does
    # this contract couple <target>?", so an ILLEGIBLE answer is CANNOT VERIFY,
    # not "uncoupled" — the same tri-state discipline as membership itself
    # (`uid_lock: yes`, a scalar coupled_tiers, or uid_lock:true with no tier
    # list all used to collapse into ALLOW). Refused even for --code-only,
    # matching the membership-blind rule: a declaration this decision depends on
    # is present but unreadable. Escape: NWP_PAIR_GATE_SOFT only (audited);
    # --override-pair deliberately does NOT cover blindness.
    local couples_rc=0 couples_reason
    couples_reason="$(pair_contract_couples_tier "$contract" "$target")" || couples_rc=$?
    if [ "$couples_rc" -eq 2 ]; then
        if [ "${NWP_PAIR_GATE_SOFT:-false}" = "true" ]; then
            _pair_note "pair_guard: CANNOT VERIFY identity coupling for '$pair_id' at $target — NWP_PAIR_GATE_SOFT=true, proceeding as UNcoupled:"
            _pair_note "  - $couples_reason"
            pair_ledger_append "$pair_id" "action=coupling-blind-soft-skip cmd=$cmd site=$site target=$target"
            couples_rc=1
        else
            _pair_err "REFUSED: CANNOT VERIFY whether pair '$pair_id' identity-couples tier '$target' —"
            _pair_err "the contract declares identity coupling but the declaration is illegible:"
            _pair_err "  - $couples_reason"
            _pair_info "This is NOT a clean result: treating an unreadable coupling clause as 'uncoupled'"
            _pair_info "is exactly the fail-open shape that let a full-DB push sever the ssc UID-locks"
            _pair_info "(NWP-ADR-0031 D6). Fix the identity: block in $(basename "$contract")."
            _pair_info "Escape (audited): NWP_PAIR_GATE_SOFT=true. --override-pair does NOT cover this."
            pair_ledger_append "$pair_id" "action=coupling-blind-refuse cmd=$cmd site=$site target=$target"
            return 1
        fi
    fi

    # 4. Role-specific invariants.
    if [ "$role" = "consumer" ]; then
        # 4a. Provider-first ordering on a contract bump (D5). The consumer may
        # not run a contract_version the provider has not reached at this tier.
        local prov_cv; prov_cv="$(pair_state_get "$pair_id" "provider" "$target")"
        if [ -z "$prov_cv" ]; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED: consumer '$site' promotion to $target, but provider '$provider' has no"
                _pair_err "recorded deployment at $target — provider must promote first (NWP-ADR-0031 D5)."
                _pair_info "Deploy the provider to $target first (pl stg2live $provider ...), then retry."
                _pair_info "Override (ledgered): --override-pair."
                return 1
            fi
        elif [ "${cv:-0}" -gt "${prov_cv:-0}" ] 2>/dev/null; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED: consumer '$site' wants contract_version $cv but provider '$provider' is at"
                _pair_err "contract_version $prov_cv at $target — provider promotes first (NWP-ADR-0031 D5)."
                _pair_info "Deploy the provider to $target first, then retry. Override (ledgered): --override-pair."
                return 1
            fi
        fi
        # 4b. Consumer user-state rule: never full-DB to a paired live consumer.
        if [ "$code_only" != "true" ] && [ "$couples_rc" -eq 0 ]; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED: '$site' is an identity-coupled CONSUMER at $target — a full-DB push would"
                _pair_err "clobber real users' learning state (minors' records, plane 5b). (NWP-ADR-0031 D6)."
                _pair_info "Deploy code/config only: re-run with --code-only."
                _pair_info "Override (ledgered): --override-pair."
                return 1
            fi
        fi
    elif [ "$role" = "provider" ]; then
        # 4c. D6 provider invariant: full-DB push to an identity-coupled live/prod
        # provider renumbers uids and severs the consumer's UID-locks.
        if [ "$code_only" != "true" ] && [ "$couples_rc" -eq 0 ]; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED: '$site' is an identity-coupled PROVIDER at $target — a full-DB push would"
                _pair_err "renumber Drupal uids and sever every '$consumer' SSO identity (NWP-ADR-0031 D6)."
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
# ops#83 — RESTORE choke-point (NWP-ADR-0031 D9, both-or-forward invariant)
#
# NWP-ADR-0031 D5 says CODE rollback is safe per-site (expand-contract). That is
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
# PAIRED CHECKPOINTS — the "both" half of both-or-forward (ops#83)
#
# The invariant has always had two legal branches: restore BOTH halves to one
# logical cut, or move the provider only FORWARD. Only "forward" was ever
# expressible in code. "Both" had no representation, so an operator doing the
# CORRECT thing — restoring nwc and ssc to the same instant — had to reach for
# the same blanket `--override-pair` as an operator doing the dangerous thing.
# One signal for two opposite intentions is not an audit trail.
#
# A paired checkpoint is a RECORDED joint cut: an id plus the identity anchor
# each half sits at within it. `--paired-restore-ack CP-<id>` then names it, and
# the guard CHECKS the name against the record instead of accepting a promise.
#
#   private/pairs/<pair>.<tier>.checkpoints.tsv
#   cp_id <TAB> provider_anchor <TAB> consumer_anchor <TAB> iso_ts <TAB> actor
#
# Append-only. Re-recording an id with identical anchors is idempotent;
# re-recording it with DIFFERENT anchors is ambiguity, and ambiguity refuses —
# a checkpoint that means two things cannot authorise anything.
################################################################################

pair_checkpoint_file() {
    local pair_id="$1" tier="$2"
    echo "$(pair_state_dir)/${pair_id}.${tier}.checkpoints.tsv"
}

# 0 if <value> is a well-formed checkpoint id.
_pair_valid_cp_id() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# 0 if <value> is a non-negative integer OR empty (empty = "this side's anchor
# is not part of the record", which the ack path then refuses on its own terms).
_pair_valid_anchor() {
    case "${1:-}" in
        '') return 0 ;;
        *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# pair_checkpoint_record <pair_id> <tier> <cp_id> <provider_anchor> <consumer_anchor>
pair_checkpoint_record() {
    local pair_id="${1:-}" tier="${2:-}" cp_id="${3:-}" pa="${4:-}" ca="${5:-}"
    [ -n "$pair_id" ] && [ -n "$tier" ] || { _pair_err "pair_checkpoint_record: pair id and tier required"; return 2; }
    if ! _pair_valid_cp_id "$cp_id"; then
        _pair_err "pair_checkpoint_record: malformed checkpoint id '${cp_id}' (expected e.g. CP-2026-07-28-live)"
        return 2
    fi
    if ! _pair_valid_anchor "$pa" || ! _pair_valid_anchor "$ca"; then
        _pair_err "pair_checkpoint_record: anchors must be non-negative integers (got provider='${pa}' consumer='${ca}')"
        return 2
    fi

    # Idempotent re-record; a DIFFERENT value under the same id is left to
    # pair_checkpoint_get to report as ambiguous rather than silently resolved
    # here — the guard must be able to SEE the contradiction.
    local dir; dir="$(pair_state_dir)"; mkdir -p "$dir" 2>/dev/null || true
    local f; f="$(pair_checkpoint_file "$pair_id" "$tier")"
    if [ -f "$f" ] && awk -F'\t' -v c="$cp_id" -v p="$pa" -v q="$ca" \
            '$1==c && $2==p && $3==q {found=1} END{exit !found}' "$f" 2>/dev/null; then
        return 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$cp_id" "$pa" "$ca" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(pair_actor)" >> "$f" 2>/dev/null || {
        _pair_err "pair_checkpoint_record: could not write $f"; return 2; }
    pair_ledger_append "$pair_id" "action=checkpoint-record tier=$tier cp=$cp_id provider=${pa:-none} consumer=${ca:-none}"
    return 0
}

# pair_checkpoint_get <pair_id> <tier> <cp_id>
#   rc 0  resolved  — echoes "<provider_anchor>\t<consumer_anchor>"
#   rc 1  absent    — echoes nothing
#   rc 2  AMBIGUOUS or unreadable — echoes a human reason
# Tri-state on purpose. rc 2 is never collapsed into rc 1: "this checkpoint says
# two different things" and "there is no such checkpoint" are different facts,
# and treating the first as the second is precisely how this family of bug is
# born (see the membership fix, 2026-07-27).
pair_checkpoint_get() {
    local pair_id="${1:-}" tier="${2:-}" cp_id="${3:-}"
    local f; f="$(pair_checkpoint_file "$pair_id" "$tier")"
    [ -f "$f" ] || return 1
    if [ ! -r "$f" ]; then
        printf 'checkpoint file exists but is unreadable: %s\n' "$f"
        return 2
    fi
    local rows n
    rows="$(awk -F'\t' -v c="$cp_id" '$1==c {print $2"\t"$3}' "$f" 2>/dev/null | sort -u)"
    [ -n "$rows" ] || return 1
    n="$(printf '%s\n' "$rows" | grep -c .)"
    if [ "$n" -ne 1 ]; then
        printf 'checkpoint %s is ambiguous at %s — %s conflicting anchor pairs recorded in %s\n' \
            "$cp_id" "$tier" "$n" "$f"
        return 2
    fi
    printf '%s\n' "$rows"
    return 0
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
    local code_only="${7:-false}"
    local paired_ack="${8:-}"

    # 1. Membership — tri-state; unreadable ⇒ refuse (see _pair_blind_refuse).
    local role pair_id rest mrc
    rest="$(pair_membership_of "$site")"; mrc=$?
    if [ "$mrc" -eq 2 ]; then
        if ! _pair_blind_refuse "$site" "$cmd" "$target" "$rest"; then return 1; fi
        return 0
    fi
    [ "$mrc" -eq 0 ] || return 0
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
        _pair_info "The both-or-forward invariant (NWP-ADR-0031 D9) cannot be verified — failing closed."
        return 1
    fi

    local provider consumer
    provider="$(pair_contract_get "$contract" '.provider')"
    consumer="$(pair_contract_get "$contract" '.consumer')"

    # 3. Only coupled tiers are gated. An uncoupled tier (dev/stg, or a pair with
    #    uid_lock:false) cannot orphan a lock ⇒ restore freely. But that answer
    #    must be LEGIBLE: an illegible coupling clause is CANNOT VERIFY and
    #    refuses (soft-escapable), it does not fall through to "restore freely".
    local _r_couples_reason _r_couples_rc=0
    _r_couples_reason="$(pair_contract_couples_tier "$contract" "$target")" || _r_couples_rc=$?
    if [ "$_r_couples_rc" -eq 2 ]; then
        if [ "${NWP_PAIR_GATE_SOFT:-false}" = "true" ]; then
            _pair_note "pair_guard_restore: CANNOT VERIFY identity coupling for '$pair_id' at $target — NWP_PAIR_GATE_SOFT=true, proceeding as UNcoupled:"
            _pair_note "  - $_r_couples_reason"
            pair_ledger_append "$pair_id" "action=restore-coupling-blind-soft-skip cmd=$cmd site=$site target=$target"
            return 0
        fi
        _pair_err "REFUSED restore: CANNOT VERIFY whether pair '$pair_id' identity-couples tier '$target' —"
        _pair_err "the contract declares identity coupling but the declaration is illegible:"
        _pair_err "  - $_r_couples_reason"
        _pair_info "An unreadable coupling clause must not read as 'restore freely' (NWP-ADR-0031 D9)."
        _pair_info "Escape (audited): NWP_PAIR_GATE_SOFT=true. --override-pair does NOT cover this."
        pair_ledger_append "$pair_id" "action=restore-coupling-blind-refuse cmd=$cmd site=$site target=$target"
        return 1
    fi
    if [ "$_r_couples_rc" -ne 0 ]; then
        return 0
    fi

    # 3b. CODE-ONLY. A restore that loads no database cannot renumber an identity
    #     set, so it cannot orphan a UID-lock — the same reasoning NWP-ADR-0031 D5
    #     uses for code rollback, and the reason D6's escape is `--code-only`.
    #     It must be POSITIVELY asserted by the caller: the default is false, so
    #     a caller that says nothing is treated as DB-touching and gated.
    if [ "$code_only" = "true" ]; then
        _pair_info "pair_guard_restore: '$site' restore at $target is CODE-ONLY — no DB is loaded, so no identity set moves."
        pair_ledger_append "$pair_id" "action=restore-code-only cmd=$cmd site=$site role=$role target=$target"
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

    local counter_side counter_anchor
    if [ "$role" = "provider" ]; then counter_side="consumer"; else counter_side="provider"; fi

    # 5b. BOTH — the paired-restore ack. This is the invariant's other legal
    #     branch, and it is checked against a RECORDED joint checkpoint rather
    #     than accepted as an assertion. An ack that cannot be resolved REFUSES;
    #     it never degrades into "no ack was given", which would make naming a
    #     nonexistent checkpoint safer than naming none.
    if [ -n "$paired_ack" ]; then
        local cp_row cp_rc
        cp_row="$(pair_checkpoint_get "$pair_id" "$target" "$paired_ack")"; cp_rc=$?
        if [ "$cp_rc" -eq 1 ]; then
            _pair_err "REFUSED restore: --paired-restore-ack names checkpoint '${paired_ack}', which is NOT RECORDED for pair '${pair_id}' at ${target}."
            _pair_info "An ack is a reference to a recorded joint cut, not an assertion. Record it on BOTH halves first:"
            _pair_info "  pl pair checkpoint ${pair_id} ${target} ${paired_ack} --provider-anchor=<N> --consumer-anchor=<M>"
            pair_ledger_append "$pair_id" "action=restore-ack-DENIED reason=unknown-checkpoint cmd=$cmd site=$site target=$target cp=$paired_ack"
            return 1
        fi
        if [ "$cp_rc" -ne 0 ]; then
            _pair_err "REFUSED restore: checkpoint '${paired_ack}' is ambiguous or unreadable — ${cp_row}"
            _pair_info "This is NOT a clean result: the guard could not resolve the cut you named, so it cannot say the two halves agree."
            pair_ledger_append "$pair_id" "action=restore-ack-DENIED reason=ambiguous cmd=$cmd site=$site target=$target cp=$paired_ack"
            return 1
        fi

        local cp_prov cp_cons cp_mine cp_theirs
        cp_prov="$(printf '%s' "$cp_row" | awk -F'\t' '{print $1}')"
        cp_cons="$(printf '%s' "$cp_row" | awk -F'\t' '{print $2}')"
        if [ "$role" = "provider" ]; then cp_mine="$cp_prov"; cp_theirs="$cp_cons";
        else                              cp_mine="$cp_cons"; cp_theirs="$cp_prov"; fi

        if [ -z "$cp_theirs" ]; then
            _pair_err "REFUSED restore: checkpoint '${paired_ack}' records no ${counter_side} anchor, so it is not a PAIRED cut."
            _pair_info "The whole point of the ack is that it names where the OTHER half lands. Re-record it with both anchors."
            pair_ledger_append "$pair_id" "action=restore-ack-DENIED reason=no-counterpart-anchor cmd=$cmd site=$site target=$target cp=$paired_ack"
            return 1
        fi
        if [ -z "$cp_mine" ]; then
            _pair_err "REFUSED restore: checkpoint '${paired_ack}' records no ${role} anchor — it cannot describe THIS restore."
            pair_ledger_append "$pair_id" "action=restore-ack-DENIED reason=no-own-anchor cmd=$cmd site=$site target=$target cp=$paired_ack"
            return 1
        fi
        if [ -n "$target_anchor" ] && [ "$target_anchor" != "$cp_mine" ]; then
            _pair_err "REFUSED restore: the backup's identity anchor (${target_anchor}) does not match checkpoint '${paired_ack}', which puts ${role} at ${cp_mine}."
            _pair_info "You are restoring a different cut from the one you acknowledged. Pick the backup that IS ${paired_ack}, or record the checkpoint that matches."
            pair_ledger_append "$pair_id" "action=restore-ack-DENIED reason=anchor-mismatch cmd=$cmd site=$site target=$target cp=$paired_ack want=$cp_mine got=$target_anchor"
            return 1
        fi

        echo "" >&2
        _pair_note "════════════════════════════════════════════════════════════════"
        _pair_note "PAIRED RESTORE: '$site' ($role of '$pair_id') → checkpoint ${paired_ack} @ ${target}"
        _pair_note "  ${role} anchor ${cp_mine}   ${counter_side} anchor ${cp_theirs}"
        _pair_note "This is the BOTH branch of both-or-forward. The pair is INCONSISTENT"
        _pair_note "until '${counter_side}' is also restored to ${paired_ack} — do that next,"
        _pair_note "then re-verify the join: pl pair-smoke ${pair_id} --tier=${target} --join"
        _pair_note "════════════════════════════════════════════════════════════════"
        echo "" >&2
        pair_ledger_append "$pair_id" \
            "action=restore-paired-ack cmd=$cmd site=$site role=$role target=$target cp=$paired_ack mine=$cp_mine theirs=$cp_theirs"
        # A half-restored pair must not look promotable. RED until the join probe
        # says the identity rail survived (pair_guard reads this on promotion).
        pair_rag_set "$pair_id" "$target" "red" 2>/dev/null || true
        return 0
    fi

    # 6. FORWARD — the restored member's target anchor must be >= the
    #    counterpart's current anchor.
    counter_anchor="$(pair_anchor_get "$pair_id" "$counter_side" "$target")"

    if [ -z "$counter_anchor" ]; then
        # ⚠ THIS BRANCH USED TO PASS. It read "no anchor recorded" as "no lock to
        # orphan" — but nothing in the tree has ever WRITTEN an anchor
        # (pair_anchor_set has no production caller; only the manual `pl pair
        # anchor` verb and tests), so on every real pair the counterpart anchor
        # is empty and the both-or-forward comparison never ran. The gate was
        # inert exactly where it mattered, and its inertness was invisible
        # because the two fail-closed pre-checks above refused first — until an
        # operator followed the DR runbook, captured the ledger and the
        # join-snapshot, and thereby disarmed the last thing standing between a
        # single-half restore and every severed UID-lock.
        #
        # An unrecorded anchor is not evidence of an empty identity set. It is
        # the absence of evidence, and at a coupled tier that is CANNOT VERIFY.
        if [ "$override" != "true" ]; then
            _pair_err "REFUSED restore: '$site' ($role of pair '$pair_id') at coupled tier $target — the '$counter_side' half has NO recorded identity anchor."
            _pair_err "CANNOT VERIFY: this is NOT a clean result. The guard cannot say the restore moves the identity set forward, because it does not know where the counterpart stands."
            _pair_info "Do ONE of these:"
            _pair_info "  • restore BOTH halves to one cut:  record it, then pass --paired-restore-ack <CP-id>"
            _pair_info "      pl pair checkpoint ${pair_id} ${target} CP-<id> --provider-anchor=<N> --consumer-anchor=<M>"
            _pair_info "  • establish where the counterpart is:  pl pair anchor ${pair_id} ${counter_side} ${target} <N>"
            _pair_info "  • restore code only (no DB) — that cannot move an identity set at all."
            _pair_info "Override (loud, typed, ledgered): --override-pair."
            pair_ledger_append "$pair_id" "action=restore-DENIED reason=counterpart-anchor-unknown cmd=$cmd site=$site role=$role target=$target"
            return 1
        fi
        _pair_note "pair_guard_restore: counterpart '$counter_side' has no recorded identity anchor at $target — proceeding only because --override-pair was given."
    else
        if [ -z "$target_anchor" ]; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED restore: '$site' target identity anchor is UNKNOWN while '$counter_side' is at anchor $counter_anchor ($target)."
                _pair_err "Cannot prove the restore moves the identity set FORWARD (NWP-ADR-0031 D9 both-or-forward) — failing closed."
                _pair_info "Provide the backup's identity anchor (pl pair anchor …), or override (ledgered): --override-pair."
                return 1
            fi
        elif [ "$target_anchor" -lt "$counter_anchor" ] 2>/dev/null; then
            if [ "$override" != "true" ]; then
                _pair_err "REFUSED restore: restoring '$site' ($role) to anchor $target_anchor is OLDER than '$counter_side' anchor $counter_anchor at $target."
                _pair_err "That would strand every '$counter_side' UID-lock newer than $target_anchor (NWP-ADR-0031 D9)."
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
