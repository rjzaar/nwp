#!/bin/bash
# lib/demo-pair.sh — paired golden/reset for the demo tier (ops#133 Phase 2)
#
# WHY A PAIR NEEDS ITS OWN GOLDEN CONTRACT
# ----------------------------------------
# nwd (Drupal, OIDC issuer) and ssd (Moodle, OIDC client) are one demo product:
# a tester redeems a code on nwd and walks into ssd courses over SSO. The join
# is `mdl_user.idnumber == <nwd account uuid>` (auth_nwc's UID-lock), plus the
# guild→cohort memberships auth_nwc writes at login.
#
# If the two halves were reset independently, the wipe would restore an ssd
# whose locked identities point at nwd accounts that the nwd restore did not
# bring back (or vice-versa) — SSO logins would bind to strangers' rows or be
# DENIED outright. ADR-0031 D9 already names this exact hazard for the REAL
# pair and states the invariant:
#
#     identity.restore.invariant: both-or-forward
#     "restore BOTH halves to one logical cut"
#
# The demo pair is uid_lock:false (throwaway users), so ADR-0031's *deploy*
# refusal does not fire here — but the operational requirement is identical and
# stricter in one way: a demo reset happens EVERY NIGHT, unattended. So this
# library makes "one logical cut" a mechanically verified fact rather than an
# operator convention.
#
# WHY THE PAIR CONTRACT IS THE SOURCE (not a new `pairs:` key in nwp.yml)
# ----------------------------------------------------------------------
# `pairs/<consumer>.pair-contract.yml` is ALREADY the committed, CI-validated,
# single source of truth for "these two sites are one system" (lib/pair.sh
# reads it at every deploy choke-point). Adding a second registry would be a
# drift source: the file that governs deploys must be the file that governs
# resets. So a pair joins the demo tier by declaring it IN THE CONTRACT:
#
#     demo:
#       enabled: true          # opt-in — no contract is swept in implicitly
#       paired_golden: true
#       paired_reset: true
#
# Fail-closed: absent/false `demo.enabled` ⇒ the paired paths refuse. A pair
# carrying real members can never be dragged into a nightly wipe by accident.
#
# THE CUT MANIFEST
# ----------------
# `pl demo golden <site> --with-pair` captures both halves back-to-back and
# writes ONE cut manifest into the provider's golden dir, binding the two
# golden images by the sha256s they had at capture time. `pl demo reset
# --with-pair` re-derives both shas and refuses unless they still match the
# cut — so re-capturing ONE half alone (the realistic way to break the pair)
# is detected before anything is destroyed, not after.

# Cut manifest lives in the PROVIDER's golden dir (the provider is the identity
# origin — ADR-0031 D5 provider-first).
DEMO_PAIR_CUT="pair.cut.json"

_dp_err()  { if command -v print_error >/dev/null 2>&1; then print_error "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi; }
_dp_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf 'WARN: %s\n' "$*" >&2; fi; }

################################################################################
# Contract resolution
################################################################################

demo_pair_dir() {
    echo "${NWP_PAIR_CONTRACT_DIR:-${PROJECT_ROOT:-$HOME/nwp}/pairs}"
}

# demo_pair_get <contract> <yq-path> [default]
# Scalar read. Echoes the default (or "") when absent/null/yq-missing.
demo_pair_get() {
    local file="$1" path="$2" default="${3:-}"
    local val=""
    if [[ -f "$file" ]] && command -v yq >/dev/null 2>&1; then
        val="$(yq e "${path} // \"\"" "$file" 2>/dev/null || true)"
        [[ "$val" == "null" ]] && val=""
    fi
    if [[ -z "$val" ]]; then
        printf '%s\n' "$default"
        return 0
    fi
    printf '%s\n' "$val"
}

# demo_pair_contract_for <site>
# Echo the path of the DEMO-ENABLED pair contract naming <site> as provider or
# consumer. Returns 1 when there is none — the paired paths then refuse.
demo_pair_contract_for() {
    local site="${1:-}" dir f prov cons
    [[ -n "$site" ]] || return 1
    dir="$(demo_pair_dir)"
    [[ -d "$dir" ]] || return 1
    for f in "$dir"/*.pair-contract.yml; do
        [[ -f "$f" ]] || continue
        prov="$(demo_pair_get "$f" '.provider')"
        cons="$(demo_pair_get "$f" '.consumer')"
        [[ "$prov" == "$site" || "$cons" == "$site" ]] || continue
        # Opt-in gate: only a contract that DECLARES itself part of the demo
        # tier is eligible. This is what keeps the real ssc↔nwc pair out.
        [[ "$(demo_pair_get "$f" '.demo.enabled' 'false')" == "true" ]] || continue
        printf '%s\n' "$f"
        return 0
    done
    return 1
}

demo_pair_provider() { demo_pair_get "$1" '.provider'; }
demo_pair_consumer() { demo_pair_get "$1" '.consumer'; }
demo_pair_label()    { demo_pair_get "$1" '.pair'; }

# demo_pair_partner <site> <contract> → the OTHER site in the pair.
demo_pair_partner() {
    local site="$1" contract="$2" prov cons
    prov="$(demo_pair_provider "$contract")"
    cons="$(demo_pair_consumer "$contract")"
    if   [[ "$site" == "$prov" ]]; then printf '%s\n' "$cons"
    elif [[ "$site" == "$cons" ]]; then printf '%s\n' "$prov"
    else return 1; fi
}

# demo_pair_role <site> <contract> → provider|consumer
demo_pair_role() {
    local site="$1" contract="$2"
    if   [[ "$site" == "$(demo_pair_provider "$contract")" ]]; then echo provider
    elif [[ "$site" == "$(demo_pair_consumer "$contract")" ]]; then echo consumer
    else return 1; fi
}

# demo_pair_issuer <contract> <tier> — the provider base URL for the tier.
# Fail-closed: no issuer ⇒ return 1 (callers must refuse, never guess).
demo_pair_issuer() {
    local contract="$1" tier="$2" v
    v="$(demo_pair_get "$contract" ".endpoints.${tier}.issuer")"
    [[ -n "$v" ]] || return 1
    printf '%s\n' "${v%/}"
}

# Feature switches (default OFF — a contract must say yes).
demo_pair_golden_enabled() { [[ "$(demo_pair_get "$1" '.demo.paired_golden' 'false')" == "true" ]]; }
demo_pair_reset_enabled()  { [[ "$(demo_pair_get "$1" '.demo.paired_reset'  'false')" == "true" ]]; }

################################################################################
# Site kind — the two halves are different stacks and need different verbs.
################################################################################

# demo_site_kind <site> → drupal|moodle (from sites/<site>/.nwp.yml project.type)
# Fail-closed: an unknown/absent type returns 1 rather than guessing "drupal"
# and tarring the wrong directory.
demo_site_kind() {
    local site="${1:-}" yml t
    yml="${PROJECT_ROOT:-$HOME/nwp}/sites/${site}/.nwp.yml"
    [[ -f "$yml" ]] || return 1
    command -v yq >/dev/null 2>&1 || return 1
    t="$(yq e '.project.type // ""' "$yml" 2>/dev/null)"
    case "$t" in
        drupal|moodle) printf '%s\n' "$t"; return 0 ;;
        *) return 1 ;;
    esac
}

################################################################################
# The cut manifest — "these two golden images are one logical cut"
################################################################################

demo_pair_cut_file() { echo "${1}/${DEMO_PAIR_CUT}"; }

# demo_pair_cut_id — a capture identifier: sortable + collision-resistant.
demo_pair_cut_id() {
    printf '%s-%s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" \
        "$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 8)"
}

# _dp_manifest_sha <golden_dir> <db|files>
_dp_manifest_sha() {
    local dir="$1" which="$2"
    command -v jq >/dev/null 2>&1 || return 1
    jq -r ".${which}_sha256 // empty" "${dir}/golden.manifest.json" 2>/dev/null
}

# demo_pair_cut_write <cut_file> <pair_label> <contract> <tier> <cut_id> \
#                     <provider_site> <provider_golden_dir> \
#                     <consumer_site> <consumer_golden_dir>
#
# Binds the two golden images by the sha256s recorded in their own manifests.
# Refuses if either manifest is missing a sha (fail-closed: an unbindable cut
# is worse than none, because reset would "verify" against nothing).
demo_pair_cut_write() {
    local cut="$1" label="$2" contract="$3" tier="$4" cut_id="$5"
    local psite="$6" pdir="$7" csite="$8" cdir="$9"
    local pdb pfiles cdb cfiles
    pdb="$(_dp_manifest_sha    "$pdir" db)"    || true
    pfiles="$(_dp_manifest_sha "$pdir" files)" || true
    cdb="$(_dp_manifest_sha    "$cdir" db)"    || true
    cfiles="$(_dp_manifest_sha "$cdir" files)" || true
    local s
    for s in "$pdb" "$pfiles" "$cdb" "$cfiles"; do
        [[ "$s" =~ ^[0-9a-f]{64}$ ]] || {
            _dp_err "REFUSED: cannot bind the pair cut — a golden manifest is missing a sha256 (provider=$pdir consumer=$cdir)"
            return 1
        }
    done
    mkdir -p "$(dirname "$cut")"
    cat > "$cut" <<EOF
{
  "type": "demo-golden-pair-cut",
  "pair": "${label}",
  "contract": "${contract##*/}",
  "tier": "${tier}",
  "cut_id": "${cut_id}",
  "captured_utc": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "provider": {
    "site": "${psite}",
    "golden_dir": "${pdir}",
    "db_sha256": "${pdb}",
    "files_sha256": "${pfiles}"
  },
  "consumer": {
    "site": "${csite}",
    "golden_dir": "${cdir}",
    "db_sha256": "${cdb}",
    "files_sha256": "${cfiles}"
  }
}
EOF
}

# demo_pair_cut_verify <cut_file> <provider_site> <provider_golden_dir> \
#                      <consumer_site> <consumer_golden_dir>
#
# 0 iff the cut exists, names THESE two sites, and both halves' CURRENT golden
# manifests still carry exactly the sha256s the cut recorded. Any drift means
# one half was re-captured alone — the pair is no longer one logical cut and a
# paired restore would produce mismatched identities.
demo_pair_cut_verify() {
    local cut="$1" psite="$2" pdir="$3" csite="$4" cdir="$5"
    command -v jq >/dev/null 2>&1 || { _dp_err "jq required for pair-cut verification"; return 1; }
    [[ -s "$cut" ]] || {
        _dp_err "No pair cut manifest at $cut — run 'pl demo golden $psite --with-pair' first."
        return 1
    }
    jq -e . "$cut" >/dev/null 2>&1 || { _dp_err "pair cut manifest is not valid JSON"; return 1; }

    local got_p got_c
    got_p="$(jq -r '.provider.site // empty' "$cut")"
    got_c="$(jq -r '.consumer.site // empty' "$cut")"
    [[ "$got_p" == "$psite" && "$got_c" == "$csite" ]] || {
        _dp_err "Pair cut is for ${got_p}↔${got_c}, not ${psite}↔${csite} — refusing."
        return 1
    }

    local half site dir key cur want
    for half in provider consumer; do
        if [[ "$half" == provider ]]; then site="$psite"; dir="$pdir"; else site="$csite"; dir="$cdir"; fi
        for key in db files; do
            want="$(jq -r ".${half}.${key}_sha256 // empty" "$cut")"
            cur="$(_dp_manifest_sha "$dir" "$key")" || cur=""
            [[ -n "$want" && "$want" == "$cur" ]] || {
                _dp_err "PAIR CUT BROKEN: ${site} ${key} sha256 ${cur:-<missing>} ≠ cut ${want:-<missing>}."
                _dp_err "One half was re-captured alone. A paired restore would leave SSO identities mismatched."
                _dp_warn "Fix: re-capture BOTH — 'pl demo golden ${psite} --with-pair'."
                return 1
            }
        done
    done
    return 0
}

# demo_pair_cut_id_of <cut_file> — for logs/status.
demo_pair_cut_id_of() {
    command -v jq >/dev/null 2>&1 || return 1
    jq -r '.cut_id // empty' "$1" 2>/dev/null
}
