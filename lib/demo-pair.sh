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
#
# `pairs/*.pair-contract.yml` is COMMITTED and the repo is publicly dedicated, so
# every live endpoint in it is deliberately redacted to the placeholder domain
# `<example-prod-domain>` (same convention in the ssc contract). A placeholder is
# not an issuer: resolving it would send a tester's browser to a domain we do not
# control. So when the contract carries the placeholder we resolve the real host
# from the PROVIDER's gitignored site config (`sites/<provider>/.nwp.yml →
# live.domain`) — the one place the fleet's real domains legitimately live — and
# fail closed if that is absent too.
demo_pair_issuer() {
    local contract="$1" tier="$2" v prov dom yml
    v="$(demo_pair_get "$contract" ".endpoints.${tier}.issuer")"
    [[ -n "$v" ]] || return 1
    if [[ "$v" == *"<example-prod-domain>"* ]]; then
        prov="$(demo_pair_provider "$contract")"
        yml="${PROJECT_ROOT:-$HOME/nwp}/sites/${prov}/.nwp.yml"
        [[ -f "$yml" ]] && command -v yq >/dev/null 2>&1 || return 1
        dom="$(yq e '.live.domain // ""' "$yml" 2>/dev/null)"
        [[ -n "$dom" && "$dom" != "null" ]] || return 1
        v="https://${dom}"
    fi
    printf '%s\n' "${v%/}"
}

# demo_pair_consumer_redirect <contract> <tier> — the consumer's OAuth callback
# for the tier. The contract records ONE redirect (the dev one) because the live
# host is redacted for the same reason the live issuer is; for any other tier we
# keep the contract's PATH (the part that is a protocol fact) and re-base it on
# the consumer's own wwwroot for that tier. Fail-closed: no wwwroot ⇒ return 1,
# because guessing a redirect URI is how you hand an auth code to the wrong host.
demo_pair_consumer_redirect() {
    local contract="$1" tier="$2" base path cons yml www
    base="$(demo_pair_get "$contract" '.oidc.provider_prereqs.consumer_redirect')"
    [[ -n "$base" ]] || return 1
    if [[ "$tier" == "dev" ]]; then printf '%s\n' "$base"; return 0; fi
    # strip scheme://host, keep the path
    local rest="${base#*://}"
    [[ "$rest" == */* ]] || return 1     # no path at all ⇒ refuse, never guess
    path="/${rest#*/}"
    cons="$(demo_pair_consumer "$contract")"
    yml="${PROJECT_ROOT:-$HOME/nwp}/sites/${cons}/.nwp.yml"
    [[ -f "$yml" ]] && command -v yq >/dev/null 2>&1 || return 1
    www="$(yq e ".moodle.tiers.${tier}.wwwroot // \"\"" "$yml" 2>/dev/null)"
    [[ -n "$www" && "$www" != "null" ]] || return 1
    printf '%s\n' "${www%/}${path}"
}

# Feature switches (default OFF — a contract must say yes).
demo_pair_golden_enabled() { [[ "$(demo_pair_get "$1" '.demo.paired_golden' 'false')" == "true" ]]; }
demo_pair_reset_enabled()  { [[ "$(demo_pair_get "$1" '.demo.paired_reset'  'false')" == "true" ]]; }

################################################################################
# Staged-PHP transport (ops#146)
#
# The three consumer-side demo scripts (oidc-wire, demo-posture, seed-courses)
# all do the same thing: stage a PHP file next to a Moodle install and run it
# with the CLI php. Only the transport differs by tier, so it lives here once
# instead of three times.
#
#   dev : copy into the Moodle root, run via `ddev exec`  (unchanged behaviour)
#   live: pipe into MOODLEDATA — which is OUTSIDE the docroot and therefore not
#         web-servable — 0600, owned by www-data, run with cwd = the Moodle root
#         so the script's own getcwd() config.php probe still works, and always
#         with -d max_input_vars=5000 (the box ships 1000, below Moodle's floor;
#         omitting it fails the env check AFTER maintenance mode is on).
#
# Deliberately carries NO secret path: a value that must not appear on a command
# line is staged as its own 0600 file by the caller (see ssd-oidc-wire.sh).
#
# demo_moodle_php_run <site> <tier> <local_php> <cli_php> <env_kv...> -- <args...>
################################################################################
demo_moodle_php_run() {
    local site="$1" tier="$2" local_php="$3" cli_php="$4"; shift 4
    local envs=() args=() seen_sep="false" a
    for a in "$@"; do
        if [[ "$a" == "--" && "$seen_sep" == "false" ]]; then seen_sep="true"; continue; fi
        if [[ "$seen_sep" == "true" ]]; then args+=("$a"); else envs+=("$a"); fi
    done
    [[ "$cli_php" == php* ]] || cli_php="php${cli_php}"

    local envstr="" q
    for a in "${envs[@]}"; do envstr+=" $(printf '%q' "$a")"; done
    local argstr=""
    for a in "${args[@]:-}"; do [[ -n "$a" ]] && argstr+=" $(printf '%q' "$a")"; done

    if [[ "$tier" == "live" ]]; then
        local root ip user opts staged
        root="$(get_site_config_value "$site" '.live.remote_path' "/var/www/${site}")"
        local sname; sname="$(get_site_config_value "$site" '.live.server' '')"
        ip=""; [[ -n "$sname" ]] && ip="$(get_server_ip "$sname" 2>/dev/null || true)"
        [[ -n "$ip" ]] || ip="$(get_site_config_value "$site" '.live.server_ip' '')"
        [[ -n "$ip" ]] || { _dp_err "no live server for '$site'"; return 1; }
        user="$(get_ssh_user "$site" 2>/dev/null || echo gitlab)"
        opts="$(nwp_ssh_opts "$site" 2>/dev/null || true)"
        local tgt="${user}@${ip}"
        local dataroot
        # shellcheck disable=SC2086
        dataroot="$(ssh $opts -o BatchMode=yes -o ConnectTimeout=20 "$tgt" \
            "sudo sed -n \"s/.*\\\$CFG->dataroot[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\1/p\" $(printf '%q' "$root/config.php")" | head -1 | tr -d '\r')"
        [[ -n "$dataroot" ]] || { _dp_err "could not read \$CFG->dataroot from $site live config.php"; return 1; }
        staged="${dataroot%/}/.nwp-demo-staged-$$.php"
        # shellcheck disable=SC2086
        ssh $opts -o BatchMode=yes -o ConnectTimeout=20 "$tgt" \
            "umask 077 && sudo -u www-data tee $(printf '%q' "$staged") >/dev/null && sudo chmod 600 $(printf '%q' "$staged")" \
            < "$local_php" || { _dp_err "could not stage $(basename "$local_php") on $site live"; return 1; }
        local rc=0
        # shellcheck disable=SC2086
        ssh $opts -o BatchMode=yes -o ConnectTimeout=60 "$tgt" \
            "cd $(printf '%q' "$root") && sudo -u www-data env${envstr} ${cli_php} -d max_input_vars=5000 $(printf '%q' "$staged")${argstr}" || rc=$?
        # shellcheck disable=SC2086
        ssh $opts -o BatchMode=yes -o ConnectTimeout=20 "$tgt" "sudo rm -f $(printf '%q' "$staged")" >/dev/null 2>&1 || true
        return $rc
    fi

    local mroot; mroot="$(resolve_project "$site" "$tier")" || return 1
    local staged="$mroot/.nwp-demo-staged-$$.php"
    cp "$local_php" "$staged" || return 1
    local rc=0
    ( cd "$mroot" && ddev exec "env${envstr} ${cli_php} -d max_input_vars=5000 $(basename "$staged")${argstr}" ) || rc=$?
    rm -f "$staged"
    return $rc
}

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
#                      <consumer_site> <consumer_golden_dir> [expect_tier]
#
# 0 iff the cut exists, names THESE two sites, and both halves' CURRENT golden
# manifests still carry exactly the sha256s the cut recorded. Any drift means
# one half was re-captured alone — the pair is no longer one logical cut and a
# paired restore would produce mismatched identities.
#
# expect_tier (nwp/ops#170, optional): also require the cut to declare THAT
# tier. The golden dirs are already tier-scoped (demo-golden vs
# demo-golden-live), so a dev cut cannot normally be read at live — but a
# hand-copied or restored-from-backup golden dir can carry one across, and a
# dev cut is a licence to wipe two LIVE sites if nothing checks. Fail-closed:
# an untiered cut refuses when a tier is demanded.
demo_pair_cut_verify() {
    local cut="$1" psite="$2" pdir="$3" csite="$4" cdir="$5" expect_tier="${6:-}"
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

    if [[ -n "$expect_tier" ]]; then
        local got_t; got_t="$(jq -r '.tier // empty' "$cut")"
        [[ "$got_t" == "$expect_tier" ]] || {
            _dp_err "Pair cut was captured at tier '${got_t:-<none>}', not '${expect_tier}' — refusing."
            _dp_warn "Re-capture at this tier: 'pl demo golden ${psite} --with-pair --tier=${expect_tier}'."
            return 1
        }
    fi

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

################################################################################
# LIVE PAIRED RESET: serialisation and the half-applied failure mode (ops#170)
#
# Two coupled LIVE sites, two databases, two file trees, one box, and NO shared
# transaction. Nothing here pretends to make the restore atomic — it cannot be.
# What it does is bound the window and make the one bad state RECOVERABLE and
# VISIBLE instead of silent:
#
#   1. ONE WRITER  — a local flock, fail-closed, so two sessions (or an operator
#      and a cron) cannot interleave two paired restores of the same pair.
#   2. THE BOX'S OWN PAIR LOCK — the two box-resident wrappers
#      (servers/live/demo/{nwd,ssd}-demo-reset-restricted) already serialise
#      themselves on /var/lock/<site>-demo-reset.lock, and the ssd wrapper takes
#      nwd's as an advisory pair lock. A workstation-driven paired reset goes to
#      the box over a DIFFERENT ssh route (the admin key, not the forced-command
#      key), so it does not pass through those wrappers and would otherwise be
#      invisible to them. It therefore takes BOTH locks for the duration.
#   3. TTL-BOUNDED HOLDER — the holder is `sleep <ttl>` with the two lock fds
#      open, so if this workstation crashes mid-run the locks are released by
#      themselves. This matters more than it looks: a lock leaked forever on
#      /var/lock/nwd-demo-reset.lock would SILENTLY stop the nightly for ever,
#      which is exactly the failure mode the ssd wrapper's [G6] comment refuses
#      to invent. A bounded lock cannot do that.
#   4. INCONSISTENCY BREADCRUMB — if the second half fails after the first was
#      restored, the pair is on two different cuts. That is recorded in a file
#      (and in both halves' logs), printed with the exact repair command, and
#      surfaced by `pl demo status`. Re-running the same paired reset repairs it,
#      because provider-first (ADR-0031 D5) makes the operation idempotent.
################################################################################

# The box-side lock file for a site — the SAME path the box wrapper opens.
# tests/unit/test-demo-pair.bats asserts this equals the constant in the shipped
# wrapper, so a rename on either side goes red instead of silently unlocking.
demo_pair_box_lock_file() { echo "/var/lock/${1:?site required}-demo-reset.lock"; }

# How long the box-side holder may live if nobody releases it. The nightly
# retries every 30 min, so a stuck holder costs at most one slot.
DEMO_PAIR_BOX_LOCK_TTL="${DEMO_PAIR_BOX_LOCK_TTL:-1800}"

# demo_pair_box_lock_cmd <lock_a> <lock_b> <ttl> — the remote command, as a
# STRING, that takes both box locks and leaves a TTL-bounded holder behind.
#
# PURE: no ssh, no globals, so the exact shell that runs on a live box is
# assertable in a unit test instead of only observable by running it there.
#
# Prints, on the far side:
#   BUSY <lock>    one of the wrappers is mid-reset  → the caller must REFUSE
#   NOTHELD <lock> the holder failed to take a lock  → the caller must REFUSE
#   HOLDER <pid>   both locks held; release with demo_pair_box_unlock_cmd <pid>
#
# The `exec 8>` / `exec 9>` + `exec sleep` shape is load-bearing: the locks live
# on the OPEN FILE DESCRIPTIONS, and `exec sleep` keeps that one process (and so
# one killable pid) holding both. `flock -n` throughout — a paired reset never
# waits on a lock, it refuses and says so.
#
# The POSITIVE CONTROL is the second probe loop: after starting the holder we
# re-probe and expect the locks to be BUSY. A probe that still succeeds means the
# holder never took them, and we refuse rather than believing a lock we do not
# hold. (Never trust a negative from a probe you have not seen return positive.)
demo_pair_box_lock_cmd() {
    local a="$1" b="$2" ttl="$3"
    printf '%s' "set -u; A=$(printf '%q' "$a"); B=$(printf '%q' "$b"); T=$(printf '%q' "$ttl"); \
for L in \"\$A\" \"\$B\"; do flock -n \"\$L\" -c true 2>/dev/null || { echo \"BUSY \$L\"; exit 3; }; done; \
nohup sh -c 'exec 8>\"\$1\"; exec 9>\"\$2\"; flock -n 8 || exit 1; flock -n 9 || exit 1; exec sleep \"\$3\"' sh \"\$A\" \"\$B\" \"\$T\" >/dev/null 2>&1 & \
P=\$!; sleep 1; \
for L in \"\$A\" \"\$B\"; do if flock -n \"\$L\" -c true 2>/dev/null; then kill \"\$P\" 2>/dev/null; echo \"NOTHELD \$L\"; exit 4; fi; done; \
echo \"HOLDER \$P\""
}

# demo_pair_box_unlock_cmd <pid> — release the holder started above. Killing the
# one process closes both fds, which is the whole reason the holder is one
# process. Idempotent and silent about a pid that is already gone.
demo_pair_box_unlock_cmd() {
    local pid="$1"
    printf 'kill %s 2>/dev/null; exit 0' "$(printf '%q' "$pid")"
}

# demo_pair_box_lock_probe_cmd <lock_a> <lock_b> — read-only "is either half
# mid-reset?", for --dry-run and for status. Takes nothing, leaves nothing.
demo_pair_box_lock_probe_cmd() {
    local a="$1" b="$2"
    printf '%s' "set -u; for L in $(printf '%q' "$a") $(printf '%q' "$b"); do \
flock -n \"\$L\" -c true 2>/dev/null || { echo \"BUSY \$L\"; exit 3; }; done; echo FREE"
}

# --- the local one-writer lock ------------------------------------------------

# Local, because the thing being serialised is THIS repo's paired verb. Lives
# beside the provider's golden, which is where every other artifact of a cut is.
demo_pair_local_lock_file() {
    echo "${PROJECT_ROOT:-$HOME/nwp}/sites/${1:?provider required}/.demo-pair.lock"
}

# --- the half-applied breadcrumb ---------------------------------------------

demo_pair_inconsistent_file() {
    echo "${PROJECT_ROOT:-$HOME/nwp}/sites/${1:?provider required}/demo-pair-INCONSISTENT.json"
}

# demo_pair_mark_inconsistent <provider> <consumer> <cut_id> <failed_half> <detail>
# One half is at the cut and the other is not. Recorded as a FILE because the
# session that caused it is the session that is about to exit, and the next
# reader (a person, or `pl demo status`) has to be able to find out without it.
demo_pair_mark_inconsistent() {
    local prov="$1" cons="$2" cut_id="$3" half="$4" detail="${5:-}"
    local f; f="$(demo_pair_inconsistent_file "$prov")"
    mkdir -p "$(dirname "$f")"
    cat > "$f" <<EOF
{
  "type": "demo-pair-inconsistent",
  "provider": "${prov}",
  "consumer": "${cons}",
  "cut_id": "${cut_id}",
  "failed_half": "${half}",
  "detail": "${detail//\"/\'}",
  "recorded_utc": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "repair": "pl demo reset ${prov} --with-pair --tier=live"
}
EOF
}

# Cleared ONLY by a paired reset in which BOTH halves reached the same cut.
demo_pair_clear_inconsistent() {
    rm -f "$(demo_pair_inconsistent_file "${1:?provider required}")" 2>/dev/null || true
}

# demo_pair_inconsistent_summary <provider> — one line, or nothing at all.
demo_pair_inconsistent_summary() {
    local f; f="$(demo_pair_inconsistent_file "${1:?provider required}")"
    [[ -s "$f" ]] || return 1
    command -v jq >/dev/null 2>&1 || { echo "pair inconsistent (see $f)"; return 0; }
    jq -r '"PAIR INCONSISTENT since \(.recorded_utc): \(.failed_half) half failed at cut \(.cut_id) — repair with: \(.repair)"' \
        "$f" 2>/dev/null || echo "pair inconsistent (see $f)"
}
