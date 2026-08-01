#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/drush.sh — sanctioned remote/stg drush runner (`pl drush`)
#
# Replaces the raw one-liners that appear in NWC-LIVE-DEPLOY-RUNBOOK and
# elsewhere, e.g.
#
#   ssh -i ~/.ssh/gitlab_linode gitlab@97.107.137.88 \
#       "cd /var/www/nwc && sudo -u www-data drush pm:uninstall tracer -y"
#
# with a single guarded command:
#
#   pl drush <site> --tier=stg|live [--dry-run|--execute] -- <drush args...>
#
# WHY: PL-STG2LIVE-INTEGRATION-DESIGN-2026-07-19.md §6 P1-4 requires the un-fork
# `pm:uninstall` and every other live drush step to route through `pl drush`
# ("via pl drush, raw ssh refused") so the deploy gate (ADR-0028), the
# live.enabled flag and the config-driven host resolution apply uniformly — the
# guard vocabulary block at the top of §6 names GATE = lib/deploy-gate.sh.
#
# HOUSE STYLE (matches moodle-promote.sh / stg2live.sh):
#   * --tier=live is DRY-RUN BY DEFAULT. It prints the exact remote command and
#     runs nothing; --execute is required to actually run against live.
#   * --tier=stg runs directly against the local DDEV staging site (ddev drush).
#   * GUARD: a live --execute calls deploy_gate_require (fail-closed on ver,
#     no-op on the AI test tier) before running, honours the per-site
#     live.enabled flag, and REFUSES when the live target is not configured
#     (empty server_ip). It never provisions.
#   * Never prints a secret value. Drush args after `--` are passed verbatim.
#
# The remote-drush idiom (sudo -u www-data drush, with the html/web + ../vendor
# fallback) is reused verbatim from stg2live.sh (~:1297-1299).
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# Libs always load from the repo; sites/config resolve from PROJECT_ROOT, which
# defaults to the repo but is honoured if pre-set (test isolation).
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/ssh.sh"
# server-resolver.sh: get_server_config (live.server → server ip/user).
[ -f "$REPO_ROOT/lib/server-resolver.sh" ] && source "$REPO_ROOT/lib/server-resolver.sh"
# deploy-gate.sh: hardware+signature gate on live writes (ADR-0028). No-op
# unless configured (ver); the AI test tier is unaffected.
source "$REPO_ROOT/lib/deploy-gate.sh"

# get_live_config — resolve a live-tier field from the per-site .nwp.yml,
# falling back to nwp.yml. A verbatim copy of the resolver stg2live.sh uses
# (stg2live.sh:72-96) so `pl drush` reads the same host/user/path config the
# deploy path does, without sourcing stg2live.sh (which would run its main()).
get_live_config() {
    local sitename="$1"
    local field="$2"
    local base
    base=$(get_base_name "$sitename")

    local yq_path
    case "$field" in
        server_ip)
            local server_name
            server_name=$(get_site_config_value "$base" '.live.server' "")
            if [[ -n "$server_name" ]] && declare -F get_server_config &>/dev/null; then
                get_server_config "$server_name" "ip" ""
                return
            fi
            get_site_config_value "$base" '.live.server_ip' ""
            return
            ;;
        domain)      yq_path='.live.domain' ;;
        type)        yq_path='.live.type' ;;
        server)      yq_path='.live.server' ;;
        remote_path) yq_path='.live.remote_path' ;;
        *)           yq_path=".live.$field" ;;
    esac
    get_site_config_value "$base" "$yq_path" ""
}

show_help() {
    cat <<EOF
${BOLD}NWP Drush — sanctioned remote/stg drush runner (retires raw ssh drush)${NC}

${BOLD}USAGE:${NC}
    pl drush <site> --tier=dev|stg|live [--dry-run|--execute] -- <drush args...>

${BOLD}OPTIONS:${NC}
    -h, --help          Show this help
    --tier=<t>          dev | stg | live   (REQUIRED). Any other tier is REFUSED.
    --dry-run           Print the exact command, run nothing (DEFAULT for live)
    --execute           Actually run the command (required for --tier=live)
    --root <path>       (live only) run drush against a NON-canonical docroot on
                        the live host instead of the resolved remote_path — for
                        the pl cutover fresh-build side docroot before the flip.
                        Must be absolute and its basename must start with <site>.
    --                  Everything after this is passed to drush VERBATIM

${BOLD}BEHAVIOUR:${NC}
    --tier=dev          Runs \`ddev drush <args>\` against the local DDEV
                        development site (sites/<site>/dev). Runs directly.
    --tier=stg          Runs \`ddev drush <args>\` against the local DDEV
                        staging site (sites/<site>/stg). Runs directly.
    --tier=live         DRY-RUN BY DEFAULT — prints the exact remote command
                        and runs nothing. Add --execute to run it. On --execute
                        it honours live.enabled, requires the deploy gate
                        (ADR-0028), and refuses if no live server is configured.

${BOLD}EXAMPLES:${NC}
    pl drush nwc --tier=live -- cr                    # dry-run: prints command
    pl drush nwc --tier=live --execute -- cr          # runs drush cr on live
    pl drush nwc --tier=live --execute -- pm:uninstall tracer nwp_lockdown -y
    pl drush nwc --tier=stg -- updatedb -y            # local DDEV staging
    pl drush nwc --tier=live --root=/var/www/nwc-20260720 --execute -- site:install social -y

${BOLD}NOTES:${NC}
    * Replaces raw \`ssh … "… drush …"\` one-liners (§6 P1-4). Raw ssh drush is
      retired; the un-fork pm:uninstall routes through here.
    * Never prints a secret value. Drush args are passed to drush verbatim.
EOF
}

################################################################################
# Argument parsing
#   Positional: <site>. Flags: --tier, --dry-run, --execute. Everything after a
#   literal `--` is collected verbatim into DRUSH_ARGS (never re-parsed).
################################################################################

SITE=""
TIER=""
# Mode is decided per-tier below: live defaults to dry-run, stg runs directly.
# EXPLICIT_MODE records an operator-supplied --dry-run/--execute.
EXPLICIT_MODE=""
# ROOT_OVERRIDE: run drush against a NON-canonical docroot on the live host
# (e.g. a fresh-build side docroot /var/www/<site>-<ts> during pl cutover, before
# the symlink flip) instead of the resolved live remote_path. live tier only.
ROOT_OVERRIDE=""
DRUSH_ARGS=()
SAW_SEP="no"

while [[ $# -gt 0 ]]; do
    if [[ "$SAW_SEP" == "yes" ]]; then
        DRUSH_ARGS+=("$1"); shift; continue
    fi
    case "$1" in
        -h|--help)   show_help; exit 0 ;;
        --)          SAW_SEP="yes" ;;
        --dry-run)   EXPLICIT_MODE="dry-run" ;;
        --execute)   EXPLICIT_MODE="execute" ;;
        --tier=*)    TIER="${1#*=}" ;;
        --tier)      shift; TIER="${1:-}" ;;
        --root=*)    ROOT_OVERRIDE="${1#*=}" ;;
        --root)      shift; ROOT_OVERRIDE="${1:-}" ;;
        -*)          print_error "Unknown option: $1"; show_help; exit 1 ;;
        *)           if [[ -z "$SITE" ]]; then SITE="$1"; else
                         print_error "Unexpected argument: $1 (drush args go after --)"; exit 1
                     fi ;;
    esac
    shift
done

################################################################################
# Validation
################################################################################

if [[ -z "$SITE" ]]; then
    print_error "Site name required"
    show_help
    exit 1
fi

case "$TIER" in
    dev|stg|live) ;;
    "")  print_error "--tier is required (dev|stg|live)"; exit 1 ;;
    *)   print_error "Unknown tier: '$TIER' — only dev|stg|live are allowed"; exit 1 ;;
esac

if [[ ${#DRUSH_ARGS[@]} -eq 0 ]]; then
    print_error "No drush arguments given — pass them after '--', e.g. pl drush $SITE --tier=$TIER -- cr"
    exit 1
fi

BASE_NAME=$(get_base_name "$SITE")

# --root: live tier only, absolute path, and its basename must start with the
# site name (guards against a typo pointing drush at the wrong site's docroot).
if [[ -n "$ROOT_OVERRIDE" ]]; then
    if [[ "$TIER" != "live" ]]; then
        print_error "--root is only valid with --tier=live (stg runs against local DDEV)"
        exit 1
    fi
    if [[ "$ROOT_OVERRIDE" != /* ]]; then
        print_error "--root must be an absolute path (got '$ROOT_OVERRIDE')"
        exit 1
    fi
    if [[ "$(basename "$ROOT_OVERRIDE")" != "$BASE_NAME"* ]]; then
        print_error "--root basename must start with the site name '$BASE_NAME' (got '$(basename "$ROOT_OVERRIDE")') — refusing (wrong-site guard)"
        exit 1
    fi
fi

# _display_drush_args — DRUSH_ARGS rendered for printing, with the value of any
# `--token=<v>` / `--token <v>` redacted. The nwc-feedback sync commands accept
# a --token; without this, the plan-print below would echo it verbatim. Never
# print a secret value.
_display_drush_args() {
    local out="" a redact_next="no"
    for a in "${DRUSH_ARGS[@]}"; do
        if [[ "$redact_next" == "yes" ]]; then
            out+=" <redacted>"; redact_next="no"; continue
        fi
        case "$a" in
            --token=*)      out+=" --token=<redacted>" ;;
            --token)        out+=" --token"; redact_next="yes" ;;
            *)              out+=" $a" ;;
        esac
    done
    printf '%s' "${out# }"
}

################################################################################
# DEV tier — local DDEV development site. Runs directly (no gate; local only).
# Mirrors STG; resolves the dev project (sites/<site>/dev) instead of stg. Added
# so feedback/agent-loop drush verbs (nwc-feedback:*) can be exercised on the
# nwd demo's dev DDEV through the sanctioned verb rather than a raw ddev drush.
################################################################################

run_dev() {
    local dev_dir
    dev_dir=$(resolve_project "$BASE_NAME" "dev") || {
        print_error "Cannot resolve dev directory for '$BASE_NAME'"
        exit 1
    }
    if [[ ! -d "$dev_dir" ]]; then
        print_error "Dev site not found at $dev_dir"
        exit 1
    fi

    print_info "Target: local DDEV dev ($dev_dir)"
    print_info "Command: ddev drush $(_display_drush_args)"

    if [[ "$EXPLICIT_MODE" == "dry-run" ]]; then
        print_status "OK" "[dry-run] would run: (cd $dev_dir && ddev drush $(_display_drush_args))"
        return 0
    fi

    ( cd "$dev_dir" && ddev drush "${DRUSH_ARGS[@]}" )
}

################################################################################
# STG tier — local DDEV staging site. Runs directly (no gate; local only).
################################################################################

run_stg() {
    local stg_dir
    stg_dir=$(resolve_project "$BASE_NAME" "stg") || {
        print_error "Cannot resolve staging directory for '$BASE_NAME'"
        exit 1
    }
    if [[ ! -d "$stg_dir" ]]; then
        print_error "Staging site not found at $stg_dir — run 'pl dev2stg $BASE_NAME' first"
        exit 1
    fi

    # Print the plan (drush args verbatim except a redacted --token).
    print_info "Target: local DDEV staging ($stg_dir)"
    print_info "Command: ddev drush $(_display_drush_args)"

    if [[ "$EXPLICIT_MODE" == "dry-run" ]]; then
        print_status "OK" "[dry-run] would run: (cd $stg_dir && ddev drush $(_display_drush_args))"
        return 0
    fi

    ( cd "$stg_dir" && ddev drush "${DRUSH_ARGS[@]}" )
}

################################################################################
# LIVE tier — remote host resolved from nwp.yml. Dry-run by default; --execute
# required. Reuses stg2live's get_live_config / get_ssh_user / sudo idiom.
################################################################################

# Shell-quote the drush args for safe transport through the single remote shell
# that ssh spawns (one shell layer). Keeps them verbatim to drush.
_quote_drush_args() {
    local out="" a
    for a in "${DRUSH_ARGS[@]}"; do
        out+=" $(printf '%q' "$a")"
    done
    printf '%s' "$out"
}

run_live() {
    # Effective mode: live is DRY-RUN unless the operator passed --execute.
    local mode="dry-run"
    [[ "$EXPLICIT_MODE" == "execute" ]] && mode="execute"

    # Honour the per-site live.enabled flag (same guard as stg2live). Refuse a
    # real run against a site whose live tier is explicitly disabled.
    local live_enabled
    live_enabled=$(get_live_config "$BASE_NAME" "enabled")
    if [[ "$live_enabled" == "false" && "$mode" == "execute" ]]; then
        print_error "Live disabled for '$BASE_NAME' (live.enabled: false in sites/$BASE_NAME/.nwp.yml)"
        exit 1
    fi

    # Resolve the live host. REFUSE (never provision) when it is not configured.
    local server_ip
    server_ip=$(get_live_config "$BASE_NAME" "server_ip")
    if [[ -z "$server_ip" ]]; then
        print_error "No live server configured for '$BASE_NAME' (empty server_ip)"
        print_info "Configure sites/$BASE_NAME/.nwp.yml live.server / live.server_ip. 'pl drush' does not provision."
        exit 1
    fi

    local ssh_user
    ssh_user=$(get_ssh_user "$BASE_NAME")

    local remote_path
    remote_path=$(get_live_config "$BASE_NAME" "remote_path")
    [[ -z "$remote_path" ]] && remote_path="/var/www/${BASE_NAME}"

    # A --root override targets a non-canonical docroot on the SAME host (the
    # fresh-build side docroot during pl cutover). The host/user/gate are
    # unchanged; only the cd target moves.
    if [[ -n "$ROOT_OVERRIDE" ]]; then
        print_warning "targeting NON-canonical docroot via --root: ${ROOT_OVERRIDE} (not the live ${remote_path})"
        remote_path="$ROOT_OVERRIDE"
    fi

    # Webroot: read the staging DDEV docroot if present, else default to web —
    # exactly how stg2live resolves it (html vs web).
    local webroot="web"
    local stg_dir
    stg_dir=$(resolve_project "$BASE_NAME" "stg" 2>/dev/null || true)
    if [[ -n "$stg_dir" && -f "$stg_dir/.ddev/config.yaml" ]]; then
        webroot=$(grep "^docroot:" "$stg_dir/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
        [[ -z "$webroot" ]] && webroot="web"
    fi

    # sudo -u www-data on the gitlab-ssh live host (stg2live idiom).
    local sudo_prefix=""
    [[ "$ssh_user" == "gitlab" ]] && sudo_prefix="sudo"

    local qargs
    qargs=$(_quote_drush_args)

    # Three candidate remote commands. The first two match stg2live.sh
    # (~:1297-1299): PATH drush from the project root, then the
    # webroot/../vendor/bin/drush fallback. The third (ops#155) is the
    # project-root composer layout, ${remote_path}/vendor/bin/drush — required
    # for sites with NO local stg tree, where the webroot guess defaults to
    # "web" but the live docroot is "html" (e.g. avctest, Open Social
    # template): there the first command fails (no drush on PATH for www-data)
    # and the second cd fails (no web/ dir), yet vendor/bin/drush exists at the
    # project root regardless of what the webroot is called.
    local primary="cd ${remote_path} && ${sudo_prefix} -u www-data drush${qargs}"
    local fallback="cd ${remote_path}/${webroot} && ${sudo_prefix} -u www-data ../vendor/bin/drush${qargs}"
    local fallback2="cd ${remote_path} && ${sudo_prefix} -u www-data vendor/bin/drush${qargs}"

    # Redact any --token value in the printed plan (never print a secret value).
    local primary_disp fallback_disp fallback2_disp
    primary_disp=$(printf '%s' "$primary" | sed -E 's/(--token[= ])[^ ]+/\1<redacted>/g')
    fallback_disp=$(printf '%s' "$fallback" | sed -E 's/(--token[= ])[^ ]+/\1<redacted>/g')
    fallback2_disp=$(printf '%s' "$fallback2" | sed -E 's/(--token[= ])[^ ]+/\1<redacted>/g')
    print_info "Target: live ${ssh_user}@${server_ip}:${remote_path}"
    print_info "Remote command: ${primary_disp}"
    print_info "Fallback:       ${fallback_disp}"
    print_info "Fallback 2:     ${fallback2_disp}"

    if [[ "$mode" != "execute" ]]; then
        print_status "OK" "[dry-run] nothing executed. Re-run with --execute to run this on live."
        return 0
    fi

    # Hardware+signature gate on the live write (ADR-0028). No-op on the test
    # tier (unconfigured); on ver it requires a live Solo touch. Fail-closed.
    deploy_gate_require "$BASE_NAME" "live" \
        "run drush on live: drush ${DRUSH_ARGS[*]}" || exit 1

    print_header "Running drush on live"
    # Candidate probing is EXPECTED to fail on some layouts (no PATH drush for
    # www-data, no web/ dir), so each candidate's stderr is captured, not shown:
    # before this, every live call on such a layout printed a noisy
    # `sudo: drush: command not found` before the working candidate ran.
    #   * a candidate that SUCCEEDS replays its own stderr (drush reports
    #     [success]/[warning] via stderr — that is real output, keep it) and the
    #     held noise from earlier failed probes is discarded;
    #   * if ALL candidates fail, every probe's stderr is replayed so the final
    #     failure stays loud — the cause is never swallowed.
    local _cand _cand_err _held_err _ok="no"
    _cand_err=$(mktemp); _held_err=$(mktemp)
    for _cand in "$primary" "$fallback" "$fallback2"; do
        if ssh $(nwp_ssh_opts "$BASE_NAME") "${ssh_user}@${server_ip}" "$_cand" 2>"$_cand_err"; then
            _ok="yes"
            cat "$_cand_err" >&2
            break
        fi
        cat "$_cand_err" >> "$_held_err"
    done
    if [[ "$_ok" != "yes" ]]; then
        cat "$_held_err" >&2
        rm -f "$_cand_err" "$_held_err"
        print_error "Remote drush failed (tried PATH drush, webroot/../vendor and project-root vendor/bin paths)"
        exit 1
    fi
    rm -f "$_cand_err" "$_held_err"
    print_status "OK" "drush completed on live"
}

################################################################################
# Dispatch
################################################################################

case "$TIER" in
    dev)  run_dev ;;
    stg)  run_stg ;;
    live) run_live ;;
esac
