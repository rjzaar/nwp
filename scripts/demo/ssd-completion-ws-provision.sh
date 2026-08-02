#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/ssd-completion-ws-provision.sh — provision (or --check) the
# read-only Moodle web service that lets nwd pull course completions back out
# of ssd. ONE DIRECTION: ssd -> nwd. ops#213-scoped.
#
#   scripts/demo/ssd-completion-ws-provision.sh [--site=ssd] [--tier=dev]
#                                               [--check|--apply]
#                                               [--token-to-nwd]
#
# Stages ssd-completion-ws-provision.php into the Moodle dataroot, runs it as
# www-data, removes it again — the same transport every other scripts/demo
# provisioner uses (demo_moodle_php_run in lib/demo-pair.sh).
#
# DRY-RUN BY DEFAULT: without --apply the PHP runs in --check mode and writes
# nothing. The token value is never printed by either half.
#
# DEMO TIER ONLY. The guard below refuses any site whose pair contract does not
# declare `demo.enabled: true`, which is exactly what keeps the real ssc<->nwc
# pair out of this. See the Phase-2 note in docs/guides/ssd-nwd-completion.md.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/demo-pair.sh"

SITE="ssd"; TIER="dev"; MODE="--check"; PASS=""; TOKEN_OUT=""
ASSUME_YES="${NWP_ASSUME_YES:-false}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*)       SITE="${1#--site=}"; shift ;;
        --tier=*)       TIER="${1#--tier=}"; shift ;;
        --check)        MODE="--check"; shift ;;
        --apply)        MODE="--apply"; shift ;;
        --token-to-nwd) PASS="$PASS --token-to-nwd"; shift ;;
        --nwd-root=*)   PASS="$PASS $1"; shift ;;
        --token-out=*)  TOKEN_OUT="${1#--token-out=}"; shift ;;
        -y|--yes)       ASSUME_YES="true"; shift ;;
        *) print_error "Unknown option '$1'"; exit 1 ;;
    esac
done

case "$TIER" in
    dev|stg|live) ;;
    *) print_error "REFUSED: tier '$TIER' — dev|stg|live only. A prod Moodle holds real learners' records."; exit 1 ;;
esac

# --- the tier boundary, mechanically ----------------------------------------
# demo_pair_contract_for only resolves a site named by a contract carrying
# `demo.enabled: true`. ssc has no `demo:` block, so this refuses there.
CONTRACT="$(demo_pair_contract_for "$SITE")" || {
    print_error "REFUSED: no demo-enabled pair contract names '$SITE'."
    print_info  "This provisioner is demo-tier only by design. Arming the same"
    print_info  "channel on the real pair is a Phase-2 decision, not a flag."
    exit 1
}
CLI_PHP="${CLI_PHP:-$(demo_pair_get "$CONTRACT" '.oidc.cli_php_version' '8.3')}"

if [[ "$TIER" == "live" ]]; then
    print_warning "LIVE: $SITE ($CONTRACT)"
    if [[ "$MODE" == "--apply" ]]; then
        print_warning "This mints a Moodle web-service token and (with --token-to-nwd)"
        print_warning "writes it into nwd's settings.local.overrides.php on the same box."
        source "$REPO_ROOT/lib/impact.sh"
        impact_confirm typed "$SITE" "$ASSUME_YES" \
            "This mints a read-only web-service credential on LIVE $SITE. It is reversible (see --check and the rollback registry), but it is a credential." \
            || { print_error "Aborted."; exit 1; }
    fi
fi

# --token-out: the ONE path on which the value crosses the wire. It goes
# straight from the ssh pipe into a 0600 file; the marked line is stripped
# before anything is shown, so the value is never rendered to a terminal, a
# log or an agent transcript. Seeding `.secrets.yml` is its only use — after
# that `pl secrets rotate|audit|sync` owns the value.
if [[ -n "$TOKEN_OUT" ]]; then
    [[ "$MODE" == "--apply" ]] || { print_error "--token-out requires --apply"; exit 1; }
    umask 077
    : > "$TOKEN_OUT"; chmod 600 "$TOKEN_OUT"
    set +e
    _raw="$(demo_moodle_php_run "$SITE" "$TIER" "$SCRIPT_DIR/ssd-completion-ws-provision.php" "$CLI_PHP" -- $MODE $PASS --emit-token 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$_raw" | sed -n 's/^NWP-WS-TOKEN://p' | tr -d '\r\n' > "$TOKEN_OUT"
    printf '%s\n' "$_raw" | grep -v '^NWP-WS-TOKEN:' || true
    unset _raw
    if [[ -s "$TOKEN_OUT" ]]; then
        print_status "OK" "token written to $TOKEN_OUT (0600, value not displayed)"
    else
        print_error "no token captured"; rc=1
    fi
else
    set +e
    demo_moodle_php_run "$SITE" "$TIER" "$SCRIPT_DIR/ssd-completion-ws-provision.php" "$CLI_PHP" -- $MODE $PASS
    rc=$?
    set -e
fi

if [[ "$MODE" == "--check" ]]; then
    (( rc == 0 )) && print_status "OK"   "$SITE completion web service present + narrow" \
                  || print_status "FAIL" "$SITE completion web service incomplete or drifted"
    exit "$rc"
fi
(( rc == 0 )) || { print_error "Provisioning failed (rc=$rc)"; exit "$rc"; }
print_status "OK" "$SITE completion web service provisioned (token value never printed)"
