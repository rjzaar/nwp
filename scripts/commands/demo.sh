#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/demo.sh — daily-reset demo tier (ops#133 Phase 1)
#
# The nwd demo pair's operational surface (DAILY-DEMO-TIER-PROPOSAL-2026-07-25,
# decisions §4): capture a golden image, reset the site back to it nightly
# (activity-guarded), and manage the hashed invite-code registry the
# nwc_demo_access module redeems against.
#
#   pl demo golden <site>                     capture current state as golden
#   pl demo reset  <site> [--if-idle 30m]     verified restore + reseed + cr
#   pl demo nightly <site>                    scheduled entrypoint (retry loop)
#   pl demo status <site>                     last reset/skips, golden, codes
#   pl demo codes  <site> list|issue|revoke|rotate|sync
#   pl demo invite <site> [--bundles a,b] [--expiry 14d] [--all]
#                                             copy-ready invite email, one
#                                             fresh code per level (0600 draft)
#   pl demo schedule <site> [--remove]        install the 01:00 Melbourne cron
#
# GUARDS (fail-closed):
#   * reset prints a COMPUTED fate manifest before it destroys anything
#     (lib/impact.sh, nwp/ops#47): what is erased, what replaces it (golden
#     sha256 + capture time + age), what survives. `-y`/cron skip the PROMPT,
#     never the REPORT — the manifest is rendered and logged on every run,
#     including the unattended ones. --dry-run prints it and stops.
#   * reset only proceeds when the golden manifest names THIS site and both
#     artifacts pass sha256 verification (demo_golden_verify).
#   * reset is tier-scoped: dev|stg act on the local DDEV pair, live acts on
#     the remote demo host over ssh (Phase 2). --tier=prod is always REFUSED.
#     A LIVE reset additionally requires the remote site to report
#     demo_mode=true, and re-verifies the uploaded golden ON the remote host
#     BEFORE dropping anything — so a bad upload can never leave a wiped host
#     with nothing to restore.
#   * --if-idle treats a failed/garbled sessions query as ACTIVE (never
#     green-lights a wipe on bad data); "active" exits DEMO_EXIT_ACTIVE (3),
#     distinct from errors, so the nightly wrapper can retry.
#   * codes are hashed (sha256) before they ever touch disk or the site;
#     `issue`/`rotate` print the plaintext exactly ONCE and never store it.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/impact.sh"        # ops#47 impact contract (fate manifest)
source "$REPO_ROOT/lib/demo.sh"
source "$REPO_ROOT/lib/deploy-gate.sh"   # deploy_gate_require (live tier only)

# Names of the golden artifacts inside sites/<site>/demo-golden/.
GOLDEN_DB="golden.db.sql.gz"
GOLDEN_FILES="golden.files.tar.gz"

show_help() {
    cat <<EOF
${BOLD}NWP Demo — daily-reset demo tier (ops#133 Phase 1)${NC}

${BOLD}USAGE:${NC}
    pl demo <subcommand> <site> [options]

${BOLD}SUBCOMMANDS:${NC}
    golden <site>                 Capture the current state as the golden image
                                  (verified DB dump + files tar + manifest under
                                  sites/<site>/demo-golden/). REFUSES to capture
                                  a site whose own modules' shipped config was
                                  never installed — see --allow-config-gaps.
    reset <site> [--if-idle 30m] [--force] [--yes] [--skip-seed] [--dry-run]
                                  Prints a FATE MANIFEST (what is destroyed,
                                  what replaces it, what survives — all
                                  measured live), then: pre-wipe error harvest
                                  (watchdog → spool, fail-open), verified
                                  restore of the golden image, drush
                                  nwc:seed-demo, code re-sync, cache rebuild.
                                  --if-idle: skip (exit 3) if any session was
                                  active within the window. --dry-run: print
                                  the manifest and stop, touching nothing.
    nightly <site>                Scheduled entrypoint: reset --if-idle 30m,
                                  retrying every 30 min until the 04:00
                                  ${DEMO_TZ} floor, then skip + log.
    status <site>                 Golden capture info, recent resets/skips,
                                  invite-code summary.
    codes <site> list             List codes (hashes only — never plaintext)
    codes <site> issue <bundle> [--expires=14d]
                                  Issue a code; plaintext printed ONCE.
    codes <site> revoke <id>      Revoke a code (kept in registry as audit row)
    codes <site> rotate           Revoke every live code, reissue one per
                                  bundle that had one (new plaintexts, once)
    codes <site> sync             Re-push the hashed registry into the site
    invite <site> [--bundles a,b] [--expiry 14d] [--all]
                                  Issue ONE fresh code per level and render a
                                  copy-ready invitation email (stdout + a 0600
                                  draft under sites/<site>/demo-invites/ — the
                                  draft holds PLAINTEXT codes; delete unwanted
                                  level blocks, paste into any mail client).
                                  Default levels: member, guild-leader,
                                  content-manager; --all adds both reviewers.
    harvest-post <site> [--dry-run]
                                  Drain sites/<site>/demo-harvest/ into nwp/ops
                                  issues (labels ${DEMO_HARVEST_LABELS};
                                  least-privilege gitlab.ops_note_token).
                                  Retry-safe: only posted digests are moved to
                                  demo-harvest/posted/.
    schedule <site> [--tier=live] [--remove] [--via-key]
                                  Install/remove the nightly cron on THIS
                                  machine (intended host: met).
                                  --via-key schedules the RESTRICTED
                                  forced-command key (~/.ssh/<site>_demo_reset →
                                  /usr/local/bin/nwd-demo-reset-restricted on
                                  the box) instead of running pl locally: the
                                  scheduler then needs no repo checkout, no
                                  admin key, and gets no root on the box.
                                  Fires every 30 min 01:00–03:30 ${DEMO_TZ}
                                  (the wrapper is idempotent), giving the same
                                  ${DEMO_FLOOR_TIME} floor without holding a
                                  3-hour ssh session open.

${BOLD}OPTIONS:${NC}
    --tier=dev|stg|live  Which instance to act on (default: dev). dev|stg are
                       the local DDEV pair; live acts on the remote demo host
                       over ssh (golden = remote dump+tar pulled back and
                       sha-verified; reset = upload, re-verify ON the remote,
                       then drop/restore/reseed). --tier=prod is always
                       REFUSED, and a live reset additionally refuses unless
                       the remote site reports demo_mode=true.
    --if-idle <dur>    Only reset when no session activity within <dur>
                       (e.g. 30m). Active → exit ${DEMO_EXIT_ACTIVE} (retryable), logged as skip.
    --force            Skip the confirmation PROMPT (same as --yes). It never
                       skips the fate manifest — that always prints and is
                       always logged (ops#47 impact contract).
    --dry-run          reset: print the fate manifest and exit without touching
                       anything. harvest-post: list digests, post nothing.
    --skip-seed        Skip drush nwc:seed-demo after restore (non-nwc sites).
    --allow-config-gaps
                       golden: capture even though config-parity FAILED, i.e.
                       config shipped by the site's own modules is missing from
                       the database. Off by default and recorded in the demo
                       log, because a golden is a reference image: capturing an
                       incomplete site freezes the defect into every nightly
                       reset. That is how nwd came to serve a dead /apply link
                       (ops#133 → ops#145). Fix with 'drush nwc:config-heal'
                       instead of reaching for this flag.
    --expires=<dur>    Code lifetime for issue/rotate (default: 14d).

${BOLD}ROLE BUNDLES${NC} (decisions §4.4 — sitemanager is never offered):
    tester-member                 Open Social 'verified' member
    tester-guild-leader           member + Tester's Guild leadership role
    tester-content-manager        Open Social 'contentmanager' (NOT sitemanager)
    tester-copyright-reviewer     + copyright_reviewer role
    tester-safeguarding-reviewer  + safeguarding_reviewer role

${BOLD}FILES:${NC}
    sites/<site>/demo-golden/       local (dev|stg) golden + sidecars + manifest
    sites/<site>/demo-golden-live/  live golden — tier-scoped so a local image
                                    can never be restored over the live host
    sites/<site>/demo-codes.json    hashed code registry (survives the wipe)
    sites/<site>/demo-reset.log     every reset / skip / harvest, one line each
    sites/<site>/demo-harvest/      pre-wipe error digests awaiting posting
    sites/<site>/demo-harvest/posted/  digests confirmed posted to nwp/ops
EOF
}

################################################################################
# Small helpers (ddev plumbing — kept out of lib/demo.sh for testability)
################################################################################

# The site's DDEV project dir for the tier.
demo_project_dir() {
    local site="$1" tier="$2"
    local dir
    dir="$(resolve_project "$site" "$tier")" || return 1
    [[ -d "$dir" && -d "$dir/.ddev" ]] || {
        print_error "No DDEV project for '$site' tier '$tier' at $dir"
        return 1
    }
    echo "$dir"
}

# The docroot (web/ or html/) read from .ddev/config.yaml — fail-closed.
demo_docroot() {
    local proj="$1" droot
    droot="$(awk '/^docroot:/ {print $2; exit}' "$proj/.ddev/config.yaml" 2>/dev/null)"
    if [[ -z "$droot" ]]; then
        # ddev default docroot is the project root; nwp sites always set one.
        for d in web html; do [[ -d "$proj/$d/sites/default" ]] && { echo "$d"; return 0; }; done
        print_error "Cannot determine docroot for $proj"
        return 1
    fi
    echo "$droot"
}

demo_drush() {
    local proj="$1"; shift
    ( cd "$proj" && ddev drush "$@" )
}

# dev|stg act on the local DDEV pair; live acts on the remote demo host over
# ssh (Phase 2). prod is still REFUSED: a demo tier never touches a prod site.
demo_check_tier() {
    local tier="$1"
    case "$tier" in
        dev|stg|live) return 0 ;;
        prod)
            print_error "--tier=prod is REFUSED: the demo tier never resets a production site."
            return 1 ;;
        *)
            print_error "Unknown tier '$tier' (dev|stg|live)"
            return 1 ;;
    esac
}

demo_is_live() { [[ "$1" == "live" ]]; }

################################################################################
# LIVE tier plumbing (Phase 2) — remote demo host over ssh
#
# Mirrors the `pl backup --remote` / stg2live idiom: resolve the live target
# from sites/<site>/.nwp.yml, run privileged remote work under sudo as the
# ssh user, and bind every artifact to a sha256 computed on the FAR side.
#
# Live reset is destructive on a real host, so it is guarded by FOUR
# independent fail-closed checks before anything is dropped:
#   1. live.enabled is not false                    (operator intent)
#   2. the remote site reports demo_mode = TRUE     (it is really a demo site)
#   3. the local golden verifies (manifest + sha256) (we have something to restore)
#   4. the golden, once PUSHED, re-verifies ON THE REMOTE before the wipe
#      (we can still restore after we destroy)
################################################################################

DEMO_LIVE_IP=""; DEMO_LIVE_USER=""; DEMO_LIVE_PATH=""; DEMO_LIVE_DOMAIN=""
DEMO_LIVE_WEBROOT=""; DEMO_LIVE_SUDO=""; DEMO_LIVE_DRUSHSUDO=""

# Resolve (and memoise) the live target for <site>. Fail-closed on a missing
# server_ip: there is no host to act on.
demo_live_ctx() {
    local site="$1"
    [[ -n "$DEMO_LIVE_IP" ]] && return 0

    local enabled; enabled="$(get_site_config_value "$site" '.live.enabled' "")"
    if [[ "$enabled" == "false" ]]; then
        print_error "Live deployment disabled for '$site' (live.enabled: false in sites/$site/.nwp.yml)"
        return 1
    fi

    local server_name; server_name="$(get_site_config_value "$site" '.live.server' "")"
    if [[ -n "$server_name" ]] && declare -F get_server_config >/dev/null 2>&1; then
        DEMO_LIVE_IP="$(get_server_config "$server_name" "ip" "" 2>/dev/null)"
    fi
    [[ -z "$DEMO_LIVE_IP" ]] && DEMO_LIVE_IP="$(get_site_config_value "$site" '.live.server_ip' "")"
    if [[ -z "$DEMO_LIVE_IP" ]]; then
        print_error "No live server configured for '$site' (live.server / live.server_ip empty) — refusing."
        return 1
    fi

    DEMO_LIVE_PATH="$(get_site_config_value "$site" '.live.remote_path' "")"
    [[ -z "$DEMO_LIVE_PATH" ]] && DEMO_LIVE_PATH="/var/www/${site}"
    DEMO_LIVE_DOMAIN="$(get_site_config_value "$site" '.live.domain' "")"
    DEMO_LIVE_USER="$(get_ssh_user "$site")"

    # The gitlab ssh user runs privileged remote work via sudo; root does not.
    if [[ "$DEMO_LIVE_USER" == "gitlab" ]]; then
        DEMO_LIVE_SUDO="sudo"
        DEMO_LIVE_DRUSHSUDO="sudo -u www-data"
    fi

    if ! demo_rssh "$site" "echo ok" >/dev/null 2>&1; then
        print_error "Cannot reach live host ${DEMO_LIVE_USER}@${DEMO_LIVE_IP}"
        return 1
    fi

    # Docroot auto-detect (html | web | "" root-served), same as backup --remote.
    if demo_rssh "$site" "test -d ${DEMO_LIVE_PATH}/web" 2>/dev/null; then
        DEMO_LIVE_WEBROOT="web"
    elif demo_rssh "$site" "test -d ${DEMO_LIVE_PATH}/html" 2>/dev/null; then
        DEMO_LIVE_WEBROOT="html"
    else
        DEMO_LIVE_WEBROOT=""
    fi
    return 0
}

demo_rssh() {
    local site="$1"; shift
    # shellcheck disable=SC2046  # nwp_ssh_opts intentionally word-splits
    ssh $(nwp_ssh_opts "$site") -o BatchMode=yes -o ConnectTimeout=15 \
        "${DEMO_LIVE_USER}@${DEMO_LIVE_IP}" "$@"
}

# Remote drush, run from the site root as www-data. Args are shell-quoted so
# SQL fragments and JSON payloads survive the round trip intact.
demo_rdrush() {
    local site="$1"; shift
    local q="" a
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    demo_rssh "$site" "cd ${DEMO_LIVE_PATH} && ${DEMO_LIVE_DRUSHSUDO} ./vendor/bin/drush${q}"
}

# GUARD 2 — the remote site must actually be in demo mode. This is what stops
# `pl demo reset <anything> --tier=live` from wiping a real site: a site that
# has not opted into nwc_demo_access with demo_mode:true is never resettable.
demo_live_require_demo_mode() {
    local site="$1" val
    val="$(demo_rdrush "$site" cget nwc_demo_access.settings demo_mode --format=string 2>/dev/null \
           | tr -d '[:space:]')" || val=""
    case "$val" in
        1|true|TRUE) return 0 ;;
    esac
    print_error "REFUSING: ${site} live does not report demo_mode=true (got '${val:-<none>}')."
    print_info  "A live demo reset is only ever allowed against a site running nwc_demo_access with demo_mode: true."
    return 1
}

################################################################################
# CONFIG PARITY (nwp/ops#145) — a golden may not be captured from a site whose
# shipped config was never installed.
#
# Drupal reads a module's config/install ONCE, at install time, and
# ConfigInstaller silently skips anything whose dependencies are unmet at that
# instant — which, under site:install / drush recipe (config syncing is on for
# the whole run), can be most of it. The site boots and looks healthy.
#
# On 2026-07-25 the ops#133 nwd parity rebuild hit exactly that: the rebuilt
# site was 99 config entities short, including the /apply webform the homepage
# links to, the entire nwc_help topic set, the growth tiers and four content
# types. Nothing failed. `pl demo golden` then captured that site 66 minutes
# later and froze the defect into the image the nightly reset restores — so the
# demo tier served a dead /apply link to testers, and would have kept restoring
# it every night.
#
# So the gate belongs HERE, at capture: a golden is a reference image, and an
# incomplete site must never become one.
################################################################################

DEMO_PARITY_PROBE="${PROJECT_ROOT}/lib/probes/config-parity.php"

# Parse the probe's output. Fail-CLOSED: no TOTAL_CUSTOM line means the probe
# did not complete, which is never a pass.
#
# $1 site  $2 tier  $3 probe stdout
demo_parity_verdict() {
    local site="$1" tier="$2" out="$3"
    local custom vendor
    custom="$(printf '%s\n' "$out" | awk '/^TOTAL_CUSTOM /{print $2; exit}')"
    vendor="$(printf '%s\n' "$out" | awk '/^TOTAL_VENDOR /{print $2; exit}')"

    if [[ ! "$custom" =~ ^[0-9]+$ ]]; then
        print_error "Config-parity probe did not complete on ${site} (${tier}) — no TOTAL_CUSTOM line."
        print_info  "Treated as a FAILURE: an unverifiable site is never captured as a golden."
        demo_log "$site" parity-failed "tier=${tier} reason=probe-incomplete"
        return 1
    fi

    if [[ "$custom" -eq 0 ]]; then
        print_status "OK" "Config parity: every config item shipped by the site's own modules is installed${vendor:+ (${vendor} core/contrib default(s) absent — normal, not gating)}"
        return 0
    fi

    print_error "Config parity FAILED: ${custom} config item(s) shipped by ${site}'s OWN modules are missing from the database."
    printf '%s\n' "$out" | awk '/^MISSING custom /{printf "        %-58s (%s)\n", $3, $4}' | head -40
    local shown; shown="$(printf '%s\n' "$out" | awk '/^MISSING custom /' | wc -l)"
    [[ "$shown" -gt 40 ]] && print_info "… and $((shown - 40)) more."
    print_info "This site is INCOMPLETE — capturing it as a golden would freeze the defect"
    print_info "into every future nightly reset (this is exactly nwp/ops#145 / ops#133)."
    print_hint "Remedy on an nwc-profile site, then re-run the capture:"
    print_hint "  drush nwc:config-heal      # idempotent; only creates config that is absent"
    print_hint "Override (recorded in the demo log) with: --allow-config-gaps"
    demo_log "$site" parity-failed "tier=${tier} custom=${custom} vendor=${vendor:-unknown}"
    return 1
}

# Run the probe against the LOCAL (dev|stg) DDEV project.
demo_parity_check_local() {
    local site="$1" tier="$2" proj="$3"
    [[ -f "$DEMO_PARITY_PROBE" ]] || {
        print_error "Config-parity probe missing: $DEMO_PARITY_PROBE"
        return 1
    }
    # The probe must be inside the project so the web container can see it;
    # DDEV mounts the project root at /var/www/html.
    local tmp=".nwp-config-parity.$$.php"
    cp "$DEMO_PARITY_PROBE" "$proj/$tmp" || return 1
    local out rc=0
    out="$( cd "$proj" && ddev drush php:script "/var/www/html/$tmp" 2>/dev/null )" || rc=$?
    rm -f "$proj/$tmp"
    [[ $rc -eq 0 || -n "$out" ]] || { out=""; }
    demo_parity_verdict "$site" "$tier" "$out"
}

# Run the probe against the LIVE demo host. Read-only; the probe is removed
# again whether it succeeded or not.
demo_parity_check_live() {
    local site="$1"
    [[ -f "$DEMO_PARITY_PROBE" ]] || {
        print_error "Config-parity probe missing: $DEMO_PARITY_PROBE"
        return 1
    }
    local rname="nwp-config-parity-$$.php"
    # shellcheck disable=SC2046
    if ! scp $(nwp_ssh_opts "$site") -o BatchMode=yes \
        "$DEMO_PARITY_PROBE" "${DEMO_LIVE_USER}@${DEMO_LIVE_IP}:/tmp/${rname}" >/dev/null 2>&1; then
        print_error "Could not stage the config-parity probe on the live host"
        return 1
    fi
    local out
    out="$(demo_rssh "$site" "chmod a+r /tmp/${rname}; cd ${DEMO_LIVE_PATH} && ${DEMO_LIVE_DRUSHSUDO} ./vendor/bin/drush php:script /tmp/${rname} 2>/dev/null")" || out="${out:-}"
    demo_rssh "$site" "rm -f /tmp/${rname}" >/dev/null 2>&1 || true
    demo_parity_verdict "$site" live "$out"
}

# Push a local artifact to the remote home dir and verify its sha256 ON THE
# REMOTE against the local sidecar. Fail-closed: a corrupt upload must be
# caught BEFORE anything is destroyed.
demo_push_verified() {
    local site="$1" local_path="$2" remote_name="$3"
    local want; want="$(awk '{print $1}' "${local_path}.sha256" 2>/dev/null)"
    if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
        print_error "No usable sha256 sidecar for $(basename "$local_path")"
        return 1
    fi
    # shellcheck disable=SC2046
    if ! scp $(nwp_ssh_opts "$site") -o BatchMode=yes \
        "$local_path" "${DEMO_LIVE_USER}@${DEMO_LIVE_IP}:${remote_name}" >/dev/null 2>&1; then
        print_error "Failed to push $(basename "$local_path") to the live host"
        return 1
    fi
    local got
    got="$(demo_rssh "$site" "sha256sum ~/${remote_name} 2>/dev/null | awk '{print \$1}'" 2>/dev/null)"
    if [[ "$got" != "$want" ]]; then
        print_error "sha256 MISMATCH after push for ${remote_name} (local=$want remote=${got:-none}) — aborting BEFORE any destructive step."
        demo_rssh "$site" "rm -f ~/${remote_name}" >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

# Compute the sha on the remote, pull, re-verify locally, write the sidecar.
# Fail-closed on mismatch (identical contract to backup_pull_verified).
demo_pull_verified() {
    local site="$1" remote_name="$2" local_path="$3"
    local remote_sha
    remote_sha="$(demo_rssh "$site" "sha256sum ~/${remote_name} 2>/dev/null | awk '{print \$1}'" 2>/dev/null)"
    if [[ ! "$remote_sha" =~ ^[0-9a-f]{64}$ ]]; then
        print_error "Could not compute remote sha256 for ~/${remote_name}"
        return 1
    fi
    # shellcheck disable=SC2046
    if ! scp $(nwp_ssh_opts "$site") -o BatchMode=yes \
        "${DEMO_LIVE_USER}@${DEMO_LIVE_IP}:${remote_name}" "$local_path" >/dev/null 2>&1; then
        print_error "Failed to pull ~/${remote_name} from the live host"
        return 1
    fi
    local local_sha; local_sha="$(sha256sum "$local_path" 2>/dev/null | awk '{print $1}')"
    if [[ "$local_sha" != "$remote_sha" ]]; then
        print_error "sha256 MISMATCH for $(basename "$local_path") (remote=$remote_sha local=$local_sha) — discarding."
        rm -f "$local_path"
        return 1
    fi
    printf '%s  %s\n' "$local_sha" "$(basename "$local_path")" > "${local_path}.sha256"
    return 0
}

demo_live_files_parent() {
    local p="$DEMO_LIVE_PATH"
    [[ -n "$DEMO_LIVE_WEBROOT" ]] && p="${p}/${DEMO_LIVE_WEBROOT}"
    echo "${p}/sites/default"
}

# Live counterpart of demo_harvest_collect: watchdog is destroyed by the
# restore, so the digest is taken over ssh before the wipe.
demo_harvest_collect_live() {
    local site="$1"
    demo_rdrush "$site" watchdog:show --severity=Error --count=100 --format=table 2>/dev/null || true
    demo_rdrush "$site" watchdog:show --severity=Critical --count=100 --format=table 2>/dev/null || true
}

# Push the live (non-revoked, non-expired) hashed codes into the site's state
# entry. Runs after every code change and after every reset.
demo_sync_codes_to_site() {
    local site="$1" tier="$2"
    local proj payload
    payload="$(demo_codes_payload "$(demo_codes_file "$site")")" || return 1

    if demo_is_live "$tier"; then
        demo_live_ctx "$site" || return 1
        if demo_rdrush "$site" state:set nwc_demo_access.codes "$payload" >/dev/null 2>&1; then
            demo_log "$site" codes-synced "tier=$tier"
            return 0
        fi
        print_warning "Could not sync codes into ${site} live (is nwc_demo_access enabled there?)"
        print_hint "Re-run later: pl demo codes $site sync --tier=live"
        return 1
    fi

    proj="$(demo_project_dir "$site" "$tier")" || return 1
    if demo_drush "$proj" state:set nwc_demo_access.codes "$payload" >/dev/null 2>&1; then
        demo_log "$site" codes-synced "tier=$tier"
        return 0
    fi
    print_warning "Could not sync codes into the site (is $site-$tier running with nwc_demo_access enabled?)"
    print_hint "Re-run later: pl demo codes $site sync"
    return 1
}

# Collector for the pre-wipe error harvest: watchdog Error + Critical rows
# (the wipe destroys watchdog) plus a best-effort PHP error-log tail. Output
# on stdout; demo_harvest spools it if non-empty. Any failure here is caught
# by demo_harvest's fail-open contract.
demo_harvest_collect() {
    local proj="$1"
    demo_drush "$proj" watchdog:show --severity=Error --count=100 --format=table 2>/dev/null || true
    demo_drush "$proj" watchdog:show --severity=Critical --count=100 --format=table 2>/dev/null || true
    # PHP error log, when the container exposes one (best-effort, never fatal).
    ( cd "$proj" && ddev exec 'test -f /var/log/php-fpm-error.log && tail -n 50 /var/log/php-fpm-error.log' 2>/dev/null ) || true
}

################################################################################
# FATE MANIFEST (nwp/ops#47 impact contract — lib/impact.sh)
#
# `pl demo reset` wipes a running site and puts a golden image back over it,
# on the LIVE tier, unattended, every night. That is the exact class of action
# the impact contract exists for, and being scheduled makes it worse rather
# than safer: nobody is watching when it goes wrong.
#
# So the manifest is COMPUTED (never assumed): the current DB size, the current
# files size and the number of accounts created since the golden was captured
# are probed live off the very instance about to be destroyed; the replacement
# is named by sha256, capture time and age out of the golden manifest. A probe
# that fails yields "" and the report SAYS so — it never fills the gap with a
# guess.
#
# `-y` / cron skip the PROMPT, never the REPORT: the manifest still renders to
# stdout (which the nightly cron captures into logs/demo-nightly-<site>.log)
# and a one-line digest is appended to demo-reset.log, so every unattended wipe
# leaves an audit record of what it believed it was destroying.
################################################################################

# Bytes-of-data query, shared by both tiers so local and live measure the same
# thing. Returns megabytes as a bare number (the manifest adds the unit).
DEMO_SQL_DBSIZE="SELECT ROUND(SUM(data_length+index_length)/1048576,1) FROM information_schema.tables WHERE table_schema=DATABASE()"

# Live measurements of the state about to be destroyed. Globals, because a
# probe that fails must be distinguishable from one that returned zero.
DEMO_M_DB=""; DEMO_M_FILES=""; DEMO_M_ACCTS=""

_demo_clean_num() {  # keep only a plausible number; anything else = failed probe
    local v; v="$(tr -d '[:space:]' <<< "${1:-}")"
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$v"
}

demo_measure_local() {  # $1 proj  $2 files_parent  $3 since_epoch ("" to skip)
    local proj="$1" files_parent="$2" since="$3" raw
    DEMO_M_DB=""; DEMO_M_FILES=""; DEMO_M_ACCTS=""
    raw="$(demo_drush "$proj" sqlq "$DEMO_SQL_DBSIZE" 2>/dev/null)" || raw=""
    DEMO_M_DB="$(_demo_clean_num "$raw")"
    DEMO_M_FILES="$(du -sh "$files_parent/files" 2>/dev/null | cut -f1)" || DEMO_M_FILES=""
    if [[ -n "$since" ]]; then
        raw="$(demo_drush "$proj" sqlq "SELECT COUNT(*) FROM users_field_data WHERE created > $since" 2>/dev/null)" || raw=""
        DEMO_M_ACCTS="$(_demo_clean_num "$raw")"
    fi
}

demo_measure_live() {  # $1 site  $2 files_parent  $3 since_epoch ("" to skip)
    local site="$1" files_parent="$2" since="$3" raw
    DEMO_M_DB=""; DEMO_M_FILES=""; DEMO_M_ACCTS=""
    raw="$(demo_rdrush "$site" sqlq "$DEMO_SQL_DBSIZE" 2>/dev/null)" || raw=""
    DEMO_M_DB="$(_demo_clean_num "$raw")"
    DEMO_M_FILES="$(demo_rssh "$site" "${DEMO_LIVE_SUDO} du -sh ${files_parent}/files 2>/dev/null | cut -f1" 2>/dev/null | tr -d '[:space:]')" || DEMO_M_FILES=""
    if [[ -n "$since" ]]; then
        raw="$(demo_rdrush "$site" sqlq "SELECT COUNT(*) FROM users_field_data WHERE created > $since" 2>/dev/null)" || raw=""
        DEMO_M_ACCTS="$(_demo_clean_num "$raw")"
    fi
}

# One field out of golden.manifest.json (jq when available, awk otherwise).
demo_golden_field() {  # $1 gdir  $2 field
    local m="$1/golden.manifest.json" f="$2"
    [[ -f "$m" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$f" '.[$k] // ""' "$m" 2>/dev/null || true
    else
        awk -F'"' -v k="$f" '$2 == k { print $4; exit }' "$m" 2>/dev/null || true
    fi
}

demo_epoch_of() {  # $1 iso8601 → epoch seconds, "" when unparseable
    [[ -n "${1:-}" ]] || return 0
    date -u -d "$1" +%s 2>/dev/null || true
}

demo_human_age() {  # $1 epoch → "3h old" / "12d old"
    local then="${1:-}" d
    [[ "$then" =~ ^[0-9]+$ ]] || { printf 'age unknown'; return 0; }
    d=$(( $(date -u +%s) - then ))
    (( d < 0 )) && { printf 'captured in the future?!'; return 0; }
    if   (( d < 3600 ));  then printf '%dm old' $(( d / 60 ))
    elif (( d < 86400 )); then printf '%dh old' $(( d / 3600 ))
    else                       printf '%dd old' $(( d / 86400 )); fi
}

# demo_reset_manifest <site> <tier> <gdir> <target> [dry_run]
# Builds AND renders the fate manifest, then appends a one-line digest to
# demo-reset.log. Call demo_measure_{local,live} first. Returns 0 always: the
# report never decides, it only informs — the guards above it decide.
# dry_run is carried into the log line so a rehearsal can never be misread as
# a real wipe when someone reads the audit trail back.
demo_reset_manifest() {
    local site="$1" tier="$2" gdir="$3" target="$4" dry_run="${5:-false}"
    local captured cap_epoch age db_sha gdb gfiles cfile live_codes

    captured="$(demo_golden_field "$gdir" captured_utc)"
    db_sha="$(demo_golden_field "$gdir" db_sha256)"
    cap_epoch="$(demo_epoch_of "$captured")"
    age="$(demo_human_age "$cap_epoch")"
    gdb="$(du -h "$gdir/$GOLDEN_DB" 2>/dev/null | cut -f1)"
    gfiles="$(du -h "$gdir/$GOLDEN_FILES" 2>/dev/null | cut -f1)"

    impact_reset

    impact_overwrite "Database" \
        "${site} ${tier} DB${DEMO_M_DB:+ (${DEMO_M_DB}M)} — every table DROPPED, replaced by ${GOLDEN_DB} (${gdb:-?}, sha256 ${db_sha:0:12}…, captured ${captured:-unknown}, ${age})"
    impact_delete "Files" \
        "${target}/sites/default/files${DEMO_M_FILES:+ (${DEMO_M_FILES})} — removed, then restored from ${GOLDEN_FILES} (${gfiles:-?})"
    impact_delete "Tester work" \
        "every account, post, comment, upload and log row created since the golden was captured (${age})${DEMO_M_ACCTS:+ — ${DEMO_M_ACCTS} account(s) created since then}"

    # Honest about blind spots: a failed probe is reported, never guessed past.
    [[ -z "$DEMO_M_DB" ]]    && impact_warn "could not measure the current database size — the wipe proceeds without knowing what is there"
    [[ -z "$DEMO_M_FILES" ]] && impact_warn "could not measure the current uploads directory — same"
    [[ -z "$captured" ]]     && impact_warn "golden manifest carries no capture time — provenance of the replacement is unknown"
    if [[ "$cap_epoch" =~ ^[0-9]+$ ]] && (( $(date -u +%s) - cap_epoch > 2592000 )); then
        impact_warn "the golden image is ${age} — the site will be rolled back a long way; recapture with 'pl demo golden $site --tier=$tier'"
    fi
    if demo_is_live "$tier"; then
        impact_warn "LIVE TIER: ${target} is the site real testers are using right now; their work is not backed up anywhere else"
    fi

    cfile="$(demo_codes_file "$site")"
    live_codes=""
    if [[ -f "$cfile" ]] && command -v jq >/dev/null 2>&1; then
        live_codes="$(jq -r --argjson now "$(date +%s)" \
            '[.codes[] | select(.revoked == false and .expires > $now)] | length' "$cfile" 2>/dev/null)" || live_codes=""
    fi
    impact_keep "Invite-code registry ${cfile}${live_codes:+ (${live_codes} live code(s))} — hashed codes survive the wipe and are re-synced afterwards"
    impact_keep "The golden image itself (${gdir}) — verified (sha256 + site match) before this report was built"
    impact_keep "Pre-wipe error digests — watchdog is harvested to demo-harvest/ BEFORE anything is destroyed"
    if demo_is_live "$tier"; then
        impact_keep "Code, vendor/, settings.php, TLS certificates and DNS on the host — only the DB and sites/default/files are touched"
    fi

    impact_render

    # The audit half of the contract: this line lands even when -y/cron skipped
    # the prompt, so an unattended wipe is still accounted for.
    demo_log "$site" reset-manifest \
        "tier=$tier dry_run=$dry_run target=$target golden_sha=${db_sha:0:12} captured=${captured:-unknown} age=${age// /_} db_now=${DEMO_M_DB:-unknown} files_now=${DEMO_M_FILES:-unknown} new_accounts=${DEMO_M_ACCTS:-unknown}"
}

################################################################################
# golden — capture the current state as the golden image
################################################################################

cmd_golden() {
    local site="$1" tier="$2" allow_gaps="${3:-false}"
    if demo_is_live "$tier"; then
        cmd_golden_live "$site" "$allow_gaps"
        return $?
    fi
    local proj droot gdir
    proj="$(demo_project_dir "$site" "$tier")" || return 1
    droot="$(demo_docroot "$proj")" || return 1
    gdir="$(demo_golden_dir "$site" "$tier")"
    mkdir -p "$gdir"

    print_header "Capturing golden image: $site ($tier)"

    # 0. CONFIG PARITY (ops#145) — refuse to freeze an incomplete site into the
    #    image the nightly reset restores. Runs BEFORE the dump so a failure
    #    costs nothing and leaves the previous golden untouched.
    if ! demo_parity_check_local "$site" "$tier" "$proj"; then
        if [[ "$allow_gaps" != "true" ]]; then
            print_error "Golden NOT captured — the existing image is unchanged."
            return 1
        fi
        print_status "WARN" "--allow-config-gaps: capturing anyway (recorded in the demo log)"
        demo_log "$site" parity-overridden "tier=$tier"
    fi

    # 1. DB dump (ddev export-db handles credentials + gzip).
    print_info "Exporting database…"
    ( cd "$proj" && ddev export-db --file="$gdir/$GOLDEN_DB" --gzip ) >/dev/null || {
        print_error "ddev export-db failed"
        return 1
    }

    # 2. Files tar (sites/default/files).
    local files_parent="$proj/$droot/sites/default"
    [[ -d "$files_parent/files" ]] || {
        print_error "No files directory at $files_parent/files"
        return 1
    }
    print_info "Archiving files…"
    tar -czf "$gdir/$GOLDEN_FILES" -C "$files_parent" files || {
        print_error "files tar failed"
        return 1
    }

    # 3. sha256 sidecars (format matches sha256sum -c).
    local f
    for f in "$GOLDEN_DB" "$GOLDEN_FILES"; do
        ( cd "$gdir" && sha256sum "$f" > "$f.sha256" ) || {
            print_error "sha256 sidecar failed for $f"
            return 1
        }
    done

    # 4. Manifest, then verify the whole set exactly as reset will.
    demo_manifest_write "$gdir" "$site" "$GOLDEN_DB" "$GOLDEN_FILES" || return 1
    demo_golden_verify "$gdir" "$site" || {
        print_error "Post-capture verification failed — golden NOT usable"
        return 1
    }

    demo_log "$site" golden-captured "tier=$tier db=$(du -h "$gdir/$GOLDEN_DB" | cut -f1) files=$(du -h "$gdir/$GOLDEN_FILES" | cut -f1)"
    print_status "OK" "Golden image captured + verified: $gdir"
    print_hint "Nightly restore will return $site to exactly this state."
}

# --- live capture (read-only against the demo host) --------------------------
# Dumps the DB and tars sites/default/files ON the live host, computes each
# sha256 there, pulls both back and re-verifies locally. Nothing on live is
# modified; the only writes are two temp files in ~ that are removed again.
cmd_golden_live() {
    local site="$1" allow_gaps="${2:-false}"
    local gdir; gdir="$(demo_golden_dir "$site" live)"

    demo_live_ctx "$site" || return 1
    print_header "Capturing golden image: $site (live)"
    print_info "Live host:   ${DEMO_LIVE_USER}@${DEMO_LIVE_IP}"
    print_info "Remote path: ${DEMO_LIVE_PATH}"
    [[ -n "$DEMO_LIVE_DOMAIN" ]] && print_info "Domain:      https://${DEMO_LIVE_DOMAIN}"

    # Capturing a NON-demo site as a "golden" would be a loaded gun pointed at
    # the reset path — refuse it here too, not just at restore time.
    demo_live_require_demo_mode "$site" || return 1
    print_status "OK" "Remote site reports demo_mode=true"

    # CONFIG PARITY (ops#145). Read-only, and before the dump: a failure costs
    # nothing and leaves the previous golden in place.
    if ! demo_parity_check_live "$site"; then
        if [[ "$allow_gaps" != "true" ]]; then
            print_error "Golden NOT captured — the existing image is unchanged."
            return 1
        fi
        print_status "WARN" "--allow-config-gaps: capturing anyway (recorded in the demo log)"
        demo_log "$site" parity-overridden "tier=live"
    fi

    mkdir -p "$gdir"
    local stamp="demo-golden-$$-$(date -u '+%Y%m%d%H%M%S')"
    local rdb="${stamp}.db.sql.gz" rfiles="${stamp}.files.tar.gz"
    local files_parent; files_parent="$(demo_live_files_parent)"

    # 1. Remote DB dump.
    print_info "Dumping database on the live host…"
    if ! demo_rssh "$site" "cd ${DEMO_LIVE_PATH} && ${DEMO_LIVE_DRUSHSUDO} ./vendor/bin/drush sql:dump --gzip 2>/dev/null > ~/${rdb}"; then
        print_error "Remote drush sql:dump failed"
        demo_rssh "$site" "rm -f ~/${rdb}" >/dev/null 2>&1 || true
        return 1
    fi

    # 2. Remote files tar (as root: files/ is www-data-owned), then chown back
    #    so scp can pull it without sudo.
    print_info "Archiving files on the live host…"
    if ! demo_rssh "$site" "${DEMO_LIVE_SUDO} tar czf ~/${rfiles} -C ${files_parent} files && ${DEMO_LIVE_SUDO} chown ${DEMO_LIVE_USER}:${DEMO_LIVE_USER} ~/${rfiles}"; then
        print_error "Remote files tar failed (${files_parent}/files)"
        demo_rssh "$site" "rm -f ~/${rdb} ~/${rfiles}" >/dev/null 2>&1 || true
        return 1
    fi

    # 3. Pull both back, sha-verified fail-closed.
    print_info "Pulling artifacts back (sha256 verified)…"
    local ok=true
    demo_pull_verified "$site" "$rdb"    "$gdir/$GOLDEN_DB"    || ok=false
    if [[ "$ok" == "true" ]]; then
        demo_pull_verified "$site" "$rfiles" "$gdir/$GOLDEN_FILES" || ok=false
    fi
    demo_rssh "$site" "rm -f ~/${rdb} ~/${rfiles}" >/dev/null 2>&1 || true
    [[ "$ok" == "true" ]] || { print_error "Golden capture aborted — artifact verification failed."; return 1; }

    # 4. Manifest + the same verification the restore will run.
    demo_manifest_write "$gdir" "$site" "$GOLDEN_DB" "$GOLDEN_FILES" || return 1
    demo_golden_verify "$gdir" "$site" || {
        print_error "Post-capture verification failed — golden NOT usable"
        return 1
    }

    demo_log "$site" golden-captured "tier=live host=${DEMO_LIVE_IP} db=$(du -h "$gdir/$GOLDEN_DB" | cut -f1) files=$(du -h "$gdir/$GOLDEN_FILES" | cut -f1)"
    print_status "OK" "Live golden image captured + verified: $gdir"
    print_hint "Nightly restore will return ${DEMO_LIVE_DOMAIN:-$site} to exactly this state."
}

################################################################################
# reset — verified restore of the golden image
################################################################################

cmd_reset() {
    local site="$1" tier="$2" if_idle="$3" auto_yes="$4" skip_seed="$5" dry_run="${6:-false}"
    if demo_is_live "$tier"; then
        cmd_reset_live "$site" "$if_idle" "$auto_yes" "$skip_seed" "$dry_run"
        return $?
    fi
    local proj droot gdir start_ts
    start_ts=$(date +%s)
    proj="$(demo_project_dir "$site" "$tier")" || return 1
    droot="$(demo_docroot "$proj")" || return 1
    gdir="$(demo_golden_dir "$site" "$tier")"

    print_header "Demo reset: $site ($tier)"

    # 1. Fail-closed golden verification (site match + sha256 both artifacts).
    demo_golden_verify "$gdir" "$site" || {
        demo_log "$site" reset-failed "tier=$tier reason=golden-verify"
        return 1
    }
    print_status "OK" "Golden image verified (sha256 + manifest site match)"

    # 2. Activity guard (--if-idle). A failed sessions query counts as ACTIVE:
    #    never wipe on bad data.
    if [[ -n "$if_idle" ]]; then
        local window newest
        window="$(demo_parse_duration "$if_idle")" || {
            print_error "Bad --if-idle duration: '$if_idle' (use e.g. 30m)"
            return 1
        }
        newest="$(demo_drush "$proj" sqlq \
            'SELECT COALESCE(MAX(timestamp),0) FROM sessions' 2>/dev/null | tr -d '[:space:]')" || newest=""
        if ! demo_idle_ok "$newest" "$window"; then
            demo_log "$site" skip-active "tier=$tier window=${if_idle} newest=${newest:-query-failed}"
            print_status "WARN" "Session activity within ${if_idle} (newest=${newest:-query-failed}) — NOT resetting (exit ${DEMO_EXIT_ACTIVE})"
            return "$DEMO_EXIT_ACTIVE"
        fi
        print_status "OK" "Idle for ≥ ${if_idle} — safe to reset"
    fi

    # 3. FATE MANIFEST (ops#47). Measured off the live instance, rendered
    #    unconditionally, logged. --force/--yes skips only the prompt below it.
    local files_parent="$proj/$droot/sites/default"
    demo_measure_local "$proj" "$files_parent" "$(demo_epoch_of "$(demo_golden_field "$gdir" captured_utc)")"
    demo_reset_manifest "$site" "$tier" "$gdir" "$proj" "$dry_run"

    if [[ "$dry_run" == "true" ]]; then
        print_status "OK" "[dry-run] nothing was touched — the report above is what a real reset would do."
        return 0
    fi

    impact_confirm standard "ERASE ${site} (${tier}) and restore the golden image" "$auto_yes" \
        || { print_info "Aborted."; return 1; }

    # 3.5 PRE-WIPE ERROR HARVEST (fail-OPEN — must never block the reset).
    #     Runs strictly BEFORE import-db: the restore destroys watchdog, and
    #     testers only report what they notice. demo_harvest always returns 0;
    #     the `|| true` is belt-and-braces against set -e.
    print_info "Harvesting error signals before the wipe…"
    demo_harvest "$site" "$tier" demo_harvest_collect "$proj" || true

    # 4. Restore DB.
    print_info "Restoring database from golden…"
    ( cd "$proj" && ddev import-db --file="$gdir/$GOLDEN_DB" ) >/dev/null || {
        demo_log "$site" reset-failed "tier=$tier reason=import-db"
        print_error "ddev import-db failed"
        return 1
    }

    # 5. Restore files (delete-then-untar so removed files don't linger).
    print_info "Restoring files from golden…"
    rm -rf "$files_parent/files"
    tar -xzf "$gdir/$GOLDEN_FILES" -C "$files_parent" || {
        demo_log "$site" reset-failed "tier=$tier reason=files-untar"
        print_error "files untar failed"
        return 1
    }

    # 6. Reseed the demo account matrix (nwc profile sites). Deliberately NOT
    #    --force: if real members somehow appear post-restore, seed-demo's own
    #    guard refuses and the reset fails loudly.
    if [[ "$skip_seed" != "true" ]]; then
        print_info "Reseeding demo accounts (drush nwc:seed-demo)…"
        if ! demo_drush "$proj" nwc:seed-demo >/dev/null 2>&1; then
            demo_log "$site" reset-failed "tier=$tier reason=seed-demo"
            print_error "drush nwc:seed-demo failed (use --skip-seed for non-nwc sites)"
            return 1
        fi
    fi

    # 7. Re-push the invite-code registry (the wipe just erased the state
    #    entry; the local registry is the source of truth). Non-fatal: codes
    #    can be re-synced, the reset itself succeeded.
    demo_sync_codes_to_site "$site" "$tier" || true

    # 8. Cache rebuild.
    demo_drush "$proj" cr >/dev/null 2>&1 || print_warning "drush cr failed (non-fatal)"

    local took=$(( $(date +%s) - start_ts ))
    demo_log "$site" reset-ok "tier=$tier took=${took}s"
    print_status "OK" "Demo reset complete in ${took}s — $site ($tier) is back at the golden image"
}

################################################################################
# reset (live) — verified restore of the golden image onto the remote demo host
#
# Step order is the safety property. Everything that can refuse, refuses BEFORE
# the first destructive command; the golden is uploaded and re-verified on the
# far side while the site is still intact, so a failed upload can never leave
# the host wiped with nothing to restore.
################################################################################

cmd_reset_live() {
    local site="$1" if_idle="$2" auto_yes="$3" skip_seed="$4" dry_run="${5:-false}"
    local gdir start_ts
    start_ts=$(date +%s)
    gdir="$(demo_golden_dir "$site" live)"

    demo_live_ctx "$site" || return 1
    print_header "Demo reset: $site (live — ${DEMO_LIVE_DOMAIN:-$DEMO_LIVE_IP})"

    # 1. GUARD 3 — fail-closed golden verification (site match + sha256 both).
    demo_golden_verify "$gdir" "$site" || {
        demo_log "$site" reset-failed "tier=live reason=golden-verify"
        return 1
    }
    print_status "OK" "Golden image verified locally (sha256 + manifest site match)"

    # 2. GUARD 2 — the remote really is a demo site.
    demo_live_require_demo_mode "$site" || {
        demo_log "$site" reset-failed "tier=live reason=not-demo-mode"
        return 1
    }
    print_status "OK" "Remote site reports demo_mode=true"

    # 3. Activity guard. A failed/garbled sessions query counts as ACTIVE.
    if [[ -n "$if_idle" ]]; then
        local window newest
        window="$(demo_parse_duration "$if_idle")" || {
            print_error "Bad --if-idle duration: '$if_idle' (use e.g. 30m)"
            return 1
        }
        newest="$(demo_rdrush "$site" sqlq 'SELECT COALESCE(MAX(timestamp),0) FROM sessions' 2>/dev/null \
                  | tr -d '[:space:]')" || newest=""
        if ! demo_idle_ok "$newest" "$window"; then
            demo_log "$site" skip-active "tier=live window=${if_idle} newest=${newest:-query-failed}"
            print_status "WARN" "Session activity within ${if_idle} (newest=${newest:-query-failed}) — NOT resetting (exit ${DEMO_EXIT_ACTIVE})"
            return "$DEMO_EXIT_ACTIVE"
        fi
        print_status "OK" "Idle for ≥ ${if_idle} — safe to reset"
    fi

    # 4. FATE MANIFEST (ops#47) — measured on the REMOTE instance that is about
    #    to be wiped, rendered unconditionally, logged. It sits above the deploy
    #    gate on purpose: the operator sees what the Solo touch is authorising
    #    BEFORE being asked to touch it, and --dry-run leaves without one.
    local files_parent; files_parent="$(demo_live_files_parent)"
    demo_measure_live "$site" "$files_parent" "$(demo_epoch_of "$(demo_golden_field "$gdir" captured_utc)")"
    demo_reset_manifest "$site" live "$gdir" "https://${DEMO_LIVE_DOMAIN:-$DEMO_LIVE_IP}" "$dry_run"

    if [[ "$dry_run" == "true" ]]; then
        print_status "OK" "[dry-run] nothing was touched — the report above is what a real reset would do."
        return 0
    fi

    # 4b. Deploy gate. Unconfigured (met/dev) → a printed notice and proceed, so
    #    the nightly cron still runs; configured (ver) → a real Solo touch.
    if declare -F deploy_gate_require >/dev/null 2>&1; then
        deploy_gate_require "$site" "live" \
            "restore the demo golden image over ${DEMO_LIVE_DOMAIN:-$site} (DB + uploads are ERASED and replaced)" || {
            demo_log "$site" reset-failed "tier=live reason=deploy-gate"
            return 1
        }
    fi

    # 5. Confirm. A LIVE wipe destroys the LAST copy of everything the testers
    #    made (nothing else holds it), so this is the TYPED tier — a y/N reflex
    #    is not proportionate to erasing a site people are using. --force/--yes
    #    skips the prompt for the scheduler; the report above already ran.
    impact_confirm typed "${DEMO_LIVE_DOMAIN:-$site}" "$auto_yes" \
        || { print_info "Aborted."; return 1; }

    # 6. PRE-WIPE ERROR HARVEST (fail-OPEN — must never block the reset).
    print_info "Harvesting error signals before the wipe…"
    demo_harvest "$site" live demo_harvest_collect_live "$site" || true

    # 7. GUARD 4 — push both artifacts and re-verify their sha256 ON THE REMOTE
    #    while the site is still intact. Nothing below this line is reversible.
    local stamp="demo-restore-$$-$(date -u '+%Y%m%d%H%M%S')"
    local rdb="${stamp}.db.sql.gz" rfiles="${stamp}.files.tar.gz"
    print_info "Uploading golden image to the live host (sha256 verified on arrival)…"
    if ! demo_push_verified "$site" "$gdir/$GOLDEN_DB" "$rdb"; then
        demo_log "$site" reset-failed "tier=live reason=push-db"
        return 1
    fi
    if ! demo_push_verified "$site" "$gdir/$GOLDEN_FILES" "$rfiles"; then
        demo_rssh "$site" "rm -f ~/${rdb}" >/dev/null 2>&1 || true
        demo_log "$site" reset-failed "tier=live reason=push-files"
        return 1
    fi
    print_status "OK" "Golden image staged on the live host and re-verified there"

    local cleanup="rm -f ~/${rdb} ~/${rfiles}"

    # 8. Restore DB (drop then import — a plain import would leave orphan
    #    tables that the golden no longer has).
    print_info "Restoring database…"
    if ! demo_rssh "$site" "cd ${DEMO_LIVE_PATH} && ${DEMO_LIVE_DRUSHSUDO} ./vendor/bin/drush sql:drop -y >/dev/null 2>&1 && gunzip -c ~/${rdb} | ${DEMO_LIVE_DRUSHSUDO} ./vendor/bin/drush sql:cli"; then
        demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true
        demo_log "$site" reset-failed "tier=live reason=import-db"
        print_error "Remote database restore FAILED — the golden is still at $gdir; restore by hand before reopening the site."
        return 1
    fi

    # 9. Restore files (delete-then-untar so removed files don't linger), and
    #    hand ownership back to the web user.
    print_info "Restoring files…"
    if ! demo_rssh "$site" "${DEMO_LIVE_SUDO} rm -rf ${files_parent}/files && ${DEMO_LIVE_SUDO} tar xzf ~/${rfiles} -C ${files_parent} && ${DEMO_LIVE_SUDO} chown -R www-data:www-data ${files_parent}/files"; then
        demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true
        demo_log "$site" reset-failed "tier=live reason=files-untar"
        print_error "Remote files restore FAILED"
        return 1
    fi

    demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true

    # 10. Reseed the demo account matrix. Deliberately NOT --force.
    if [[ "$skip_seed" != "true" ]]; then
        print_info "Reseeding demo accounts (drush nwc:seed-demo)…"
        if ! demo_rdrush "$site" nwc:seed-demo >/dev/null 2>&1; then
            demo_log "$site" reset-failed "tier=live reason=seed-demo"
            print_error "Remote drush nwc:seed-demo failed (use --skip-seed for non-nwc sites)"
            return 1
        fi
    fi

    # 11. Re-push the invite-code registry (the wipe erased the state entry;
    #     the local registry is the source of truth). Non-fatal.
    demo_sync_codes_to_site "$site" live || true

    # 12. Cache rebuild.
    demo_rdrush "$site" cr >/dev/null 2>&1 || print_warning "remote drush cr failed (non-fatal)"

    # 13. Post-restore smoke. RETRIED on purpose: the first request after a
    #     cache rebuild is a cold full render, and on a small shared host that
    #     can exceed the php-fpm worker pool and return 5xx once before the
    #     caches warm. A single sample would report a healthy site as broken.
    #     Persistent failure is real, so it degrades the exit status.
    local degraded=false
    if [[ -n "$DEMO_LIVE_DOMAIN" ]]; then
        local code="" attempt
        for attempt in 1 2 3 4 5; do
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 45 "https://${DEMO_LIVE_DOMAIN}/" 2>/dev/null || echo 000)"
            [[ "$code" == "200" ]] && break
            sleep 5
        done
        if [[ "$code" == "200" ]]; then
            local jcode
            jcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 45 "https://${DEMO_LIVE_DOMAIN}/demo/join" 2>/dev/null || echo 000)"
            if [[ "$jcode" == "200" ]]; then
                print_status "OK" "https://${DEMO_LIVE_DOMAIN}/ and /demo/join both serve 200"
            else
                degraded=true
                demo_log "$site" reset-degraded "tier=live join_http=${jcode}"
                print_status "FAIL" "/demo/join returned ${jcode} after the restore — testers cannot join."
            fi
        else
            degraded=true
            demo_log "$site" reset-degraded "tier=live http=${code} attempts=5"
            print_status "FAIL" "https://${DEMO_LIVE_DOMAIN}/ still ${code} after 5 attempts — investigate."
        fi
    fi

    local took=$(( $(date +%s) - start_ts ))
    if [[ "$degraded" == "true" ]]; then
        demo_log "$site" reset-ok-degraded "tier=live took=${took}s host=${DEMO_LIVE_IP}"
        print_warning "Data restored, but the site did not pass its smoke check — treat as FAILED."
        return 1
    fi
    demo_log "$site" reset-ok "tier=live took=${took}s host=${DEMO_LIVE_IP}"
    print_status "OK" "Live demo reset complete in ${took}s — ${DEMO_LIVE_DOMAIN:-$site} is back at the golden image"
}

################################################################################
# nightly — scheduled entrypoint with the §4.3 retry loop
################################################################################

cmd_nightly() {
    local site="$1" tier="$2"
    local rc now
    while true; do
        set +e
        # -y for the scheduler: skips the PROMPT, never the fate manifest —
        # the report lands in logs/demo-nightly-<site>.log + demo-reset.log.
        cmd_reset "$site" "$tier" "30m" "true" "false" "false"
        rc=$?
        set -e
        if [[ "$rc" -ne "$DEMO_EXIT_ACTIVE" ]]; then
            return "$rc"   # success (0) or hard failure (≠0,≠3) — both final
        fi
        now="$(TZ="$DEMO_TZ" date '+%H:%M')"
        if demo_past_floor "$now"; then
            demo_log "$site" skip-floor "tier=$tier now=$now floor=$DEMO_FLOOR_TIME"
            print_status "WARN" "Still active at the ${DEMO_FLOOR_TIME} ${DEMO_TZ} floor — skipping tonight's reset (logged)"
            return 0
        fi
        print_info "Active session — retrying in $(( DEMO_RETRY_SECONDS / 60 )) min (floor ${DEMO_FLOOR_TIME} ${DEMO_TZ}, now ${now})"
        sleep "$DEMO_RETRY_SECONDS"
    done
}

################################################################################
# status
################################################################################

cmd_status() {
    local site="$1" tier="${2:-dev}"
    local gdir cfile lfile
    gdir="$(demo_golden_dir "$site" "$tier")"
    cfile="$(demo_codes_file "$site")"
    lfile="$(demo_log_file "$site")"

    print_header "Demo status: $site ($tier)"

    if [[ -f "$gdir/golden.manifest.json" ]]; then
        echo "  Golden image:"
        echo "    captured: $(jq -r '.captured_utc' "$gdir/golden.manifest.json" 2>/dev/null)"
        echo "    db:       $GOLDEN_DB ($(du -h "$gdir/$GOLDEN_DB" 2>/dev/null | cut -f1))"
        echo "    files:    $GOLDEN_FILES ($(du -h "$gdir/$GOLDEN_FILES" 2>/dev/null | cut -f1))"
        if demo_golden_verify "$gdir" "$site" >/dev/null 2>&1; then
            print_status "OK" "Golden verifies (sha256)"
        else
            print_status "FAIL" "Golden does NOT verify — recapture before the next reset"
        fi
    else
        print_status "WARN" "No golden image captured yet (pl demo golden $site --tier=$tier)"
    fi

    # Unposted harvest digests — until the GitLab poster runs they are the only
    # place pre-wipe errors survive, so surface the backlog loudly.
    local hdir; hdir="$(demo_harvest_dir "$site")"
    if [[ -d "$hdir" ]]; then
        local pending; pending=$(find "$hdir" -maxdepth 1 -name 'harvest-*.md' 2>/dev/null | wc -l)
        if (( pending > 0 )); then
            echo ""
            print_status "WARN" "${pending} harvest digest(s) in the spool — post with: pl demo harvest-post $site"
        fi
    fi

    echo ""
    echo "  Invite codes:"
    if [[ -f "$cfile" ]] && command -v jq >/dev/null 2>&1; then
        local now; now="$(date +%s)"
        jq -r --argjson now "$now" '
            .codes[] |
            [ .id, .bundle,
              (if .revoked then "revoked" elif .expires <= $now then "expired" else "live" end),
              (.expires | todate) ] | @tsv' "$cfile" 2>/dev/null \
        | awk -F'\t' 'BEGIN { printf "    %-5s %-30s %-8s %s\n", "id", "bundle", "state", "expires" }
                      { printf "    %-5s %-30s %-8s %s\n", $1, $2, $3, $4 }'
    else
        echo "    (no code registry — pl demo codes $site issue <bundle>)"
    fi

    echo ""
    echo "  Recent resets/skips (last 10):"
    if [[ -f "$lfile" ]]; then
        tail -n 10 "$lfile" | sed 's/^/    /'
        if tail -n 3 "$lfile" | grep -q "skip-"; then
            print_status "WARN" "Recent skip present — check activity guard / floor"
        fi
    else
        echo "    (no resets logged yet)"
    fi
}

################################################################################
# codes
################################################################################

cmd_codes() {
    local site="$1" tier="$2" action="$3"; shift 3 || true
    local cfile; cfile="$(demo_codes_file "$site")"
    demo_require_jq || return 1

    case "$action" in
        list)
            cmd_status "$site" "$tier" | sed -n '/Invite codes:/,/Recent resets/p' | head -n -1
            print_info "Only sha256 hashes are stored — plaintext codes are shown once at issue time."
            ;;
        issue)
            local bundle="${1:-}" expires_in="14d" a
            for a in "$@"; do [[ "$a" == --expires=* ]] && expires_in="${a#--expires=}"; done
            [[ -n "$bundle" ]] || { print_error "Usage: pl demo codes <site> issue <bundle> [--expires=14d]"; return 1; }
            demo_bundle_valid "$bundle" || {
                print_error "Unknown bundle '$bundle'. Valid: ${DEMO_BUNDLES[*]}"
                return 1
            }
            local secs code hash id expires
            secs="$(demo_parse_duration "$expires_in")" || { print_error "Bad --expires duration '$expires_in'"; return 1; }
            code="$(demo_generate_code)" || { print_error "Code generation failed"; return 1; }
            hash="$(demo_hash_code "$code")"
            id="$(demo_next_code_id "$cfile")"
            expires=$(( $(date +%s) + secs ))
            demo_code_add "$cfile" "$id" "$bundle" "$hash" "$expires" || return 1
            demo_log "$site" codes-issued "id=$id bundle=$bundle expires_in=$expires_in"
            print_header "Invite code issued (${bundle})"
            echo ""
            echo "    ${BOLD}${code}${NC}"
            echo ""
            print_status "WARN" "Shown ONCE — only its sha256 hash is stored ($id, expires $(date -d "@$expires" '+%Y-%m-%d'))."
            print_info "Distribute to INVITED helpers only (decisions §4.2 — never post publicly)."
            demo_sync_codes_to_site "$site" "$tier" || true
            ;;
        revoke)
            local id="${1:-}"
            [[ -n "$id" ]] || { print_error "Usage: pl demo codes <site> revoke <id>"; return 1; }
            demo_code_revoke "$cfile" "$id" || return 1
            demo_log "$site" codes-revoked "id=$id"
            print_status "OK" "Revoked $id"
            demo_sync_codes_to_site "$site" "$tier" || true
            ;;
        rotate)
            local bundles b now
            bundles="$(demo_active_bundles "$cfile")"
            [[ -n "$bundles" ]] || { print_info "No live codes to rotate."; return 0; }
            now="$(date +%s)"
            # Revoke every live code…
            while IFS= read -r cid; do
                demo_code_revoke "$cfile" "$cid"
            done < <(jq -r --argjson now "$now" \
                '.codes[] | select(.revoked == false and .expires > $now) | .id' "$cfile")
            demo_log "$site" codes-rotated ""
            print_status "OK" "All live codes revoked."
            # …then reissue one per bundle that had one (each prints once).
            while IFS= read -r b; do
                cmd_codes "$site" "$tier" issue "$b"
            done <<< "$bundles"
            ;;
        sync)
            demo_sync_codes_to_site "$site" "$tier"
            ;;
        *)
            print_error "Unknown codes action '$action' (list|issue|revoke|rotate|sync)"
            return 1
            ;;
    esac
}

################################################################################
# invite — copy-ready invitation email with one fresh code per level
################################################################################

# Default invite levels (decisions §4.4). The two reviewer bundles are
# opt-in (--all / --bundles=…): reviewer queues are a narrower ask and the
# operator usually recruits for them separately.
DEMO_INVITE_DEFAULT_BUNDLES=(tester-member tester-guild-leader tester-content-manager)

cmd_invite() {
    local site="$1" tier="$2"; shift 2 || true
    demo_require_jq || return 1

    # ---- invite-specific options (arrive via passthru) ----
    local bundles_csv="" expiry="14d" all="false" a
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bundles=*) bundles_csv="${1#--bundles=}"; shift ;;
            --bundles)   [[ $# -ge 2 ]] || { print_error "--bundles needs a value"; return 1; }
                         bundles_csv="$2"; shift 2 ;;
            --expiry=*|--expires=*) expiry="${1#*=}"; shift ;;
            --expiry|--expires)     [[ $# -ge 2 ]] || { print_error "--expiry needs a value"; return 1; }
                         expiry="$2"; shift 2 ;;
            --all)       all="true"; shift ;;
            *) print_error "Unknown invite option '$1'"; return 1 ;;
        esac
    done

    # ---- resolve the bundle list (fail-closed on unknown names) ----
    local bundles=()
    if [[ -n "$bundles_csv" ]]; then
        IFS=',' read -r -a bundles <<< "$bundles_csv"
        local b
        for b in "${bundles[@]}"; do
            demo_bundle_valid "$b" || {
                print_error "Unknown bundle '$b'. Valid: ${DEMO_BUNDLES[*]}"
                return 1
            }
        done
    elif [[ "$all" == "true" ]]; then
        bundles=("${DEMO_BUNDLES[@]}")
    else
        bundles=("${DEMO_INVITE_DEFAULT_BUNDLES[@]}")
    fi

    local secs expiry_days
    secs="$(demo_parse_duration "$expiry")" || {
        print_error "Bad --expiry duration '$expiry' (use e.g. 14d)"
        return 1
    }
    expiry_days=$(( (secs + 86399) / 86400 ))

    # ---- issue ONE fresh code per bundle (hashed at rest; plaintext lives
    #      only in this process and the 0600 draft) ----
    local cfile pairs=() code hash id expires
    cfile="$(demo_codes_file "$site")"
    expires=$(( $(date +%s) + secs ))
    local b
    for b in "${bundles[@]}"; do
        code="$(demo_generate_code)" || { print_error "Code generation failed"; return 1; }
        hash="$(demo_hash_code "$code")"
        id="$(demo_next_code_id "$cfile")"
        demo_code_add "$cfile" "$id" "$b" "$hash" "$expires" || return 1
        demo_log "$site" codes-issued "id=$id bundle=$b expires_in=$expiry invite"
        pairs+=("${b}=${code}")
    done

    # ---- render the draft: stdout + 0600 file (it holds plaintext codes) ----
    local join_url invite_dir invite_file draft
    join_url="$(demo_invite_join_url "$site")"
    invite_dir="$(demo_site_dir "$site")/demo-invites"
    invite_file="${invite_dir}/invite-$(date -u '+%Y%m%d-%H%M%S').md"
    # Never clobber an earlier draft (its plaintext codes exist nowhere else).
    local n=2
    while [[ -e "$invite_file" ]]; do
        invite_file="${invite_dir}/invite-$(date -u '+%Y%m%d-%H%M%S')-${n}.md"
        n=$(( n + 1 ))
    done
    draft="$(demo_invite_email "$join_url" "$expiry_days" "${pairs[@]}")"

    ( umask 077; mkdir -p "$invite_dir" && printf '%s\n' "$draft" > "$invite_file" ) || {
        print_error "Could not write draft to $invite_file"
        return 1
    }

    print_header "Invitation draft — $site (${#bundles[@]} level(s), codes expire in ${expiry_days}d)"
    echo ""
    printf '%s\n' "$draft"
    echo ""
    print_status "OK" "Draft saved: $invite_file (mode 0600 — it contains PLAINTEXT codes)"
    print_info "Delete any level blocks the recipient shouldn't get, then paste into your mail client."
    print_info "Distribute to INVITED helpers only (decisions §4.2 — never post publicly)."
    if [[ "$join_url" == "<YOUR-SITE-URL>"* ]]; then
        print_warning "No live.domain in sites/$site/.nwp.yml — replace the <YOUR-SITE-URL> placeholder before sending."
    fi
    print_hint "Consider deleting the draft file after sending (the registry keeps only hashes)."

    # Push the new hashes into the running site (non-fatal — codes can be
    # re-synced with `pl demo codes $site sync`).
    demo_sync_codes_to_site "$site" "$tier" || true
}

################################################################################
# harvest-post — drain the pre-wipe harvest spool into nwp/ops issues
#
# The nightly reset destroys watchdog, so demo_harvest writes a digest to
# sites/<site>/demo-harvest/ BEFORE the wipe. This drains that spool into
# GitLab issues using the least-privilege gitlab.ops_note_token (lib/gitlab-
# issues.sh) — never the root PAT, and the token value is never printed or
# placed in argv.
#
# Retry-safe: a digest is only moved to demo-harvest/posted/ after GitLab
# confirms an iid. A failed post leaves the file in the spool for next time,
# and `pl demo status` reports the backlog.
################################################################################

DEMO_HARVEST_LABELS="demo-tester,auto-harvest"

cmd_harvest_post() {
    local site="$1" dry_run="${2:-false}"
    local hdir; hdir="$(demo_harvest_dir "$site")"

    print_header "Demo harvest → nwp/ops: $site"

    if [[ ! -d "$hdir" ]]; then
        print_info "No harvest spool at $hdir — nothing to post."
        return 0
    fi
    local -a spooled=()
    while IFS= read -r f; do [[ -n "$f" ]] && spooled+=("$f"); done \
        < <(find "$hdir" -maxdepth 1 -name 'harvest-*.md' -type f 2>/dev/null | sort)
    if (( ${#spooled[@]} == 0 )); then
        print_info "Harvest spool is empty — nothing to post."
        return 0
    fi
    print_info "${#spooled[@]} digest(s) queued."

    if [[ "$dry_run" == "true" ]]; then
        local f
        for f in "${spooled[@]}"; do
            echo "  would post: $(basename "$f") → nwp/ops issue (labels: ${DEMO_HARVEST_LABELS})"
        done
        print_status "OK" "[dry-run] nothing posted, spool untouched."
        return 0
    fi

    # Lazy-source: only harvest-post needs yq + a token, so `pl demo golden`
    # keeps working on a host with neither.
    # shellcheck source=../../lib/gitlab-issues.sh
    source "$REPO_ROOT/lib/gitlab-issues.sh" || {
        print_error "Could not load lib/gitlab-issues.sh"
        return 1
    }

    mkdir -p "$hdir/posted"
    local posted=0 failed=0 f
    for f in "${spooled[@]}"; do
        local when title body payload resp iid
        when="$(awk -F': ' '/^harvested_utc:/ {print $2; exit}' "$f" 2>/dev/null)"
        [[ -n "$when" ]] || when="$(basename "$f" .md)"
        title="Demo harvest — ${site}: errors before the ${when} reset"
        body="$(cat "$f")"
        payload="$(jq -nc --arg t "$title" --arg d "$body" --arg l "$DEMO_HARVEST_LABELS" \
            '{title:$t, description:$d, labels:$l}')" || {
            print_status "FAIL" "$(basename "$f") — could not build payload"
            failed=$(( failed + 1 )); continue
        }
        resp="$(_api_send POST "/projects/${PROJECT_ID}/issues" "$payload" 2>/dev/null)" || resp=""
        iid="$(printf '%s' "$resp" | _jget 'iid')"
        if [[ -n "$iid" ]]; then
            mv "$f" "$hdir/posted/$(basename "$f")"
            demo_log "$site" harvest-posted "file=$(basename "$f") issue=#${iid}"
            print_status "OK" "$(basename "$f") → nwp/ops#${iid}"
            posted=$(( posted + 1 ))
        else
            demo_log "$site" harvest-post-failed "file=$(basename "$f")"
            print_status "FAIL" "$(basename "$f") — not posted (left in the spool for retry)"
            failed=$(( failed + 1 ))
        fi
    done

    echo ""
    print_info "Posted: ${posted}   Failed: ${failed}   (posted digests moved to ${hdir}/posted/)"
    (( failed == 0 ))
}

################################################################################
# schedule — nightly cron on THIS machine (intended host: met)
################################################################################

# The restricted forced-command path (ops#133 / Option A): the scheduler host
# holds only ~/.ssh/<site>_demo_reset, whose authorized_keys entry pins
# command="/usr/local/bin/nwd-demo-reset-restricted". It can invoke the reset
# and nothing else — no shell, no sudo, no scp, no forwarding.
#
# IdentitiesOnly=yes AND IdentityAgent=none are LOAD-BEARING: without them ssh
# offers an agent-held admin key first and lands on the UNRESTRICTED gitlab
# entry instead of the forced command (found the hard way — see the guide).
DEMO_KEY_PATH="${DEMO_KEY_PATH:-\$HOME/.ssh/<site>_demo_reset}"

# demo_schedule_key_cmd <site> → the ssh invocation the cron line will run.
# Host and user come from sites/<site>/.nwp.yml (live.server_ip → live.domain,
# get_ssh_user), never from a hardcoded hostname.
demo_schedule_key_cmd() {
    local site="$1" host="" user="" key="" server_name=""
    # Same resolution order as demo_live_ctx: named server → server_ip → domain.
    server_name="$(get_site_config_value "$site" '.live.server' "")"
    if [[ -n "$server_name" ]] && declare -F get_server_config >/dev/null 2>&1; then
        host="$(get_server_config "$server_name" "ip" "" 2>/dev/null)"
    fi
    [[ -z "$host" ]] && host="$(get_site_config_value "$site" '.live.server_ip' "")"
    [[ -z "$host" ]] && host="$(get_site_config_value "$site" '.live.domain' "")"
    [[ -n "$host" ]] || { print_error "No live.server_ip / live.domain for '$site' — cannot schedule --via-key"; return 1; }
    user="$(get_ssh_user "$site")"
    key="${DEMO_KEY_PATH//<site>/$site}"
    printf 'ssh -i %s -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=30 %s@%s' \
        "$key" "$user" "$host"
}

cmd_schedule() {
    local site="$1" remove="$2" tier="${3:-dev}" via_key="${4:-false}"
    local marker="# NWP Demo Reset - $site"
    local current
    current="$(crontab -l 2>/dev/null || true)"
    # Drop any existing entry (idempotent install / clean removal). The install
    # writes a 3-line block (marker, CRON_TZ, command) — remove the whole block
    # by marker, plus any stray command line as belt-and-braces (either flavour).
    local cleaned
    cleaned="$(printf '%s\n' "$current" \
        | awk -v m="$marker" 'index($0, m) == 1 { skip = 3 } skip > 0 { skip--; next } { print }' \
        | grep -v "pl demo nightly $site\b" \
        | grep -v "${site}_demo_reset" || true)"

    if [[ "$remove" == "true" ]]; then
        printf '%s\n' "$cleaned" | crontab -
        print_status "OK" "Removed demo-reset cron for $site (if present)"
        return 0
    fi

    mkdir -p "$PROJECT_ROOT/logs"
    local log="${PROJECT_ROOT}/logs/demo-nightly-${site}.log"
    local entry

    if [[ "$via_key" == "true" ]]; then
        # Restricted-key flavour. The retry loop lives in CRON, not in a
        # 3-hour-long ssh session: the box-side wrapper is idempotent (one
        # reset per Melbourne day) and returns 3 while sessions are active, so
        # firing every 30 min from 01:00 to 03:30 gives the same "retry to the
        # 04:00 floor" semantics without holding a connection open on a 3.8 GB
        # host. No repo checkout is needed on the scheduler at all.
        local sshcmd
        sshcmd="$(demo_schedule_key_cmd "$site")" || return 1
        entry="CRON_TZ=${DEMO_TZ}
0,30 1-3 * * * ${sshcmd} nightly >> ${log} 2>&1"
    else
        # CRON_TZ pins the fire time to Melbourne regardless of host TZ (handles
        # DST; supported by ISC/vixie cron on Ubuntu 22.04+). The retry semantics
        # (every 30 min to a 04:00 floor) live in `pl demo nightly`, keeping cron
        # itself a single dumb line.
        entry="CRON_TZ=${DEMO_TZ}
0 1 * * * ${PROJECT_ROOT}/pl demo nightly ${site} --tier=${tier} >> ${log} 2>&1"
    fi

    # The marker line stays a PREFIX (the removal awk matches index==1), so the
    # suffix is free for provenance — which matters because the laptop copy is
    # interim and someone has to know to delete it when met takes over.
    local marker_line="$marker"
    [[ "$via_key" == "true" ]] && marker_line="${marker} (restricted key; see docs/guides/demo-nightly-on-met.md)"
    printf '%s\n%s\n%s\n' "$cleaned" "$marker_line" "$entry" | crontab -
    if [[ "$via_key" == "true" ]]; then
        print_status "OK" "Installed nightly demo reset for $site via the RESTRICTED key (01:00–03:30 ${DEMO_TZ}, every 30 min, ${DEMO_FLOOR_TIME} floor)"
        print_info "This host needs only ~/.ssh/${site}_demo_reset — no repo, no admin key, no root on the box."
    else
        print_status "OK" "Installed nightly demo reset for $site --tier=${tier} (01:00 ${DEMO_TZ}, retries to ${DEMO_FLOOR_TIME})"
        print_info "Runs on THIS machine's crontab — the production schedule belongs on met (pl schedule host)."
    fi
    print_hint "Verify: crontab -l | grep -A2 'NWP Demo Reset'"
}

################################################################################
# main
################################################################################

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        -h|--help|"") show_help; return 0 ;;
    esac

    local site="${1:-}"; shift || true
    [[ -n "$site" ]] || { print_error "Site name required."; show_help; return 1; }

    # Common option parse (subcommand-specific positionals pass through).
    local tier="dev" if_idle="" auto_yes="false" skip_seed="false" remove="false" dry_run="false" via_key="false"
    local allow_gaps="false"
    local passthru=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tier=*)   tier="${1#--tier=}"; shift ;;
            --allow-config-gaps) allow_gaps="true"; shift ;;
            --dry-run)  dry_run="true"; shift ;;
            --if-idle)  if_idle="${2:-}"; shift 2 ;;
            --if-idle=*) if_idle="${1#--if-idle=}"; shift ;;
            --force|--yes|-y) auto_yes="true"; shift ;;
            --skip-seed) skip_seed="true"; shift ;;
            --remove)   remove="true"; shift ;;
            --via-key)  via_key="true"; shift ;;
            *)          passthru+=("$1"); shift ;;
        esac
    done

    demo_check_tier "$tier" || return 1

    case "$sub" in
        golden)   cmd_golden "$site" "$tier" "$allow_gaps" ;;
        reset)    cmd_reset "$site" "$tier" "$if_idle" "$auto_yes" "$skip_seed" "$dry_run" ;;
        nightly)  cmd_nightly "$site" "$tier" ;;
        status)   cmd_status "$site" "$tier" ;;
        codes)    cmd_codes "$site" "$tier" "${passthru[@]:-list}" ;;
        invite)   cmd_invite "$site" "$tier" "${passthru[@]}" ;;
        schedule) cmd_schedule "$site" "$remove" "$tier" "$via_key" ;;
        harvest-post) cmd_harvest_post "$site" "$dry_run" ;;
        *)        print_error "Unknown subcommand: $sub"; show_help; return 1 ;;
    esac
}

# Sourced by tests (bats) to exercise the manifest builders without
# dispatching (same idiom as ver-test.sh). Executed normally, this is `main`.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
