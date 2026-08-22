#!/bin/bash
set -euo pipefail

################################################################################
# NWP Unified CLI Wrapper (pl)
#
# Single entry point for all NWP operations
#
# Usage: pl <command> [options] [arguments]
################################################################################

# Get script directory (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

# Version
VERSION="0.30.0"
NWP_VERSION="$VERSION"

# Freshness (item C) — VERSION above is a hardcoded string, so it is identical
# on a checkout sitting on origin/main and on one forty commits behind it.
# This machine runs every `pl secrets audit`, `pl rag` and `pl deploy-gate` out
# of ONE shared checkout, so "which code produced this verdict?" is a real
# question with no answer until now. lib/pl-freshness.sh answers it in at most
# one line on stderr, reading only refs already on disk (never the network),
# never on a deliberately-pinned checkout, and failing open in every error case
# so it can never be the reason an emergency `pl rollback` does not run.
if [[ -f "${SCRIPT_DIR}/lib/pl-freshness.sh" ]]; then
    source "${SCRIPT_DIR}/lib/pl-freshness.sh"
    pl_freshness_banner "$SCRIPT_DIR" || true
fi

# Source verification auto-logging if available
[[ -f "${SCRIPT_DIR}/lib/verify-autolog.sh" ]] && source "${SCRIPT_DIR}/lib/verify-autolog.sh"

################################################################################
# Color Definitions
################################################################################

# Determine if color output should be used
# Respects NO_COLOR standard (https://no-color.org/)
should_use_color() {
    # NO_COLOR standard - if set (any value), disable color
    if [ -n "${NO_COLOR:-}" ]; then
        return 1
    fi
    # Also disable if not a terminal
    if [ ! -t 1 ]; then
        return 1
    fi
    return 0
}

if should_use_color; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

################################################################################
# Command inventory  (item 4 — "the CLI must not hide its own surface")
#
# WHY: the curated help below is hand-maintained and had drifted badly — 43 of
# 96 commands, INCLUDING `pl rag`, `pl todo`, `pl moodle`, `pl loop`, `pl issue`
# and `pl secrets`, appeared nowhere in `pl --help`. They worked only because
# the `*)` arm of the dispatcher falls back to "is there a script with this
# name?". That is a discoverability hole (an operator cannot find the verb that
# exists) and a correctness hole (the same fallback happily resolves any
# executable file in the repo root, so a typo can run something unintended).
#
# The ALL COMMANDS section is therefore GENERATED from the filesystem, so it
# cannot drift, and the fallback now refuses anything not in this inventory.
################################################################################

# Commands that exist as scripts but are not standalone user verbs. Each entry
# carries its reason; they are still LISTED (tagged `internal`) so nothing is
# hidden — they are merely excluded from the fallback's "did you mean" hints.
PL_INTERNAL_COMMANDS=(
    "uninstall_nwp:invoked as \`pl uninstall\`"
    "run-tests:CI helper, invoked by the pipeline"
    "fixture-load:test-fixture loader used by the bats suites"
    "bootstrap-coder:one-shot bootstrap, run by coder-setup"
)

_pl_is_internal_command() {
    local want="$1" e
    for e in "${PL_INTERNAL_COMMANDS[@]}"; do
        [ "${e%%:*}" = "$want" ] && return 0
    done
    return 1
}

_pl_internal_reason() {
    local want="$1" e
    for e in "${PL_INTERNAL_COMMANDS[@]}"; do
        if [ "${e%%:*}" = "$want" ]; then printf '%s' "${e#*:}"; return 0; fi
    done
    printf ''
}

# Every command name pl can dispatch: one per line, sorted.
_pl_all_commands() {
    {
        local f
        for f in "${SCRIPT_DIR}"/scripts/commands/*.sh; do
            [ -e "$f" ] || continue
            basename "$f" .sh
        done
        # Verbs implemented inside pl itself (no script of their own).
        printf '%s\n' uninstall list status version help gitlab-create gitlab-list commands
    } | sort -u
}

_pl_command_exists() {
    local want="$1" c
    while IFS= read -r c; do
        [ "$c" = "$want" ] && return 0
    done < <(_pl_all_commands)
    return 1
}

# One-line synopsis for a command, read from the script's own header so the
# help text is generated from the code rather than restated beside it.
_pl_command_synopsis() {
    local name="$1"
    local f="${SCRIPT_DIR}/scripts/commands/${name}.sh"
    [ -f "$f" ] || { printf '%s' "$(_pl_builtin_synopsis "$name")"; return 0; }

    local line
    # 1. A self-describing header: "# pl foo — does the thing"
    line=$(grep -m1 -E "^#[[:space:]]*pl[[:space:]]+${name}\b" "$f" 2>/dev/null \
           | sed -E 's/^#[[:space:]]*//; s/^pl[[:space:]]+[^[:space:]]+[[:space:]]*[-—–:]*[[:space:]]*//')
    # 2. Otherwise the first real comment line that is not a divider/shebang.
    if [ -z "$line" ]; then
        line=$(sed -n '2,25p' "$f" 2>/dev/null \
               | grep -E '^#' \
               | grep -vE '^#[[:space:]]*$|^#{3,}|^#!' \
               | head -1 \
               | sed -E 's/^#[[:space:]]*//')
    fi
    [ -z "$line" ] && line="(no synopsis in $(basename "$f"))"
    printf '%s' "${line:0:96}"
}

_pl_builtin_synopsis() {
    case "$1" in
        uninstall)     printf 'Uninstall NWP completely (alias for uninstall_nwp)' ;;
        list)          printf 'List all tracked sites' ;;
        status)        printf 'Show site status table (RAG grade + phase)' ;;
        version)       printf 'Show NWP version (--check fetches and reports checkout freshness)' ;;
        help)          printf 'Show this help' ;;
        commands)      printf 'List every dispatchable command (--json for machine use)' ;;
        gitlab-create) printf 'Create a GitLab project' ;;
        gitlab-list)   printf 'List GitLab projects' ;;
        *)             printf '(built-in)' ;;
    esac
}

# `pl commands [--json]` — the machine-readable inventory. `pl --help` renders
# the same data; anything that can dispatch appears in both.
cmd_commands() {
    local as_json=false
    [ "${1:-}" = "--json" ] && as_json=true

    if [ "$as_json" = true ]; then
        local first=true c syn kind
        printf '[\n'
        while IFS= read -r c; do
            kind="command"
            _pl_is_internal_command "$c" && kind="internal"
            syn=$(_pl_command_synopsis "$c")
            [ "$first" = true ] && first=false || printf ',\n'
            printf '  {"name":"%s","kind":"%s","synopsis":"%s"}' \
                "$c" "$kind" "$(printf '%s' "$syn" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        done < <(_pl_all_commands)
        printf '\n]\n'
        return 0
    fi

    local c syn
    while IFS= read -r c; do
        syn=$(_pl_command_synopsis "$c")
        if _pl_is_internal_command "$c"; then
            printf '  %-22s %s\n' "$c" "[internal: $(_pl_internal_reason "$c")]"
        else
            printf '  %-22s %s\n' "$c" "$syn"
        fi
    done < <(_pl_all_commands)
}

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP CLI (pl) v${VERSION} - Unified Command Interface${NC}

${BOLD}USAGE:${NC}
    pl <command> [options] [arguments]

${BOLD}SITE MANAGEMENT:${NC}
    install <recipe> <sitename>     Install a new Drupal site
    delete <sitename>               Delete a site (backups archived to sitebackups/)
    delete --purge <sitename>       Delete EVERYTHING incl. backups (type name to confirm)
    make <sitename>                 Switch dev/prod mode (-v dev, -p prod)
    uninstall                       Uninstall NWP completely

${BOLD}BACKUP & RESTORE:${NC}
    backup <sitename> [message]     Create backup (full site)
    backup -b <sitename>            Database-only backup
    backup -g <sitename>            Backup with git commit
    backup --bundle <sitename>      Create git bundle archive
    backup --sanitize <sitename>    Create sanitized backup (no PII)
    backup sweep [--dry-run]        Back up every site with stale/missing backups
    restore <sitename> [backup]     Restore from backup
    restore -b <sitename>           Restore database only
    copy <source> <dest>            Copy site to new location

${BOLD}DEPLOYMENT (Local):${NC}
    dev2stg <sitename>              Deploy dev to staging (local)

${BOLD}DEPLOYMENT (Remote):${NC}
    stg2prod <sitename>             Deploy staging to production
    prod2stg <sitename>             Pull production to staging
    stg2live <sitename>             Deploy staging to live server
    live2stg <sitename>             Pull live to staging
    live2prod <sitename>            Deploy live to production
    drush <site> --tier=stg|live    Sanctioned drush runner (retires raw ssh drush);
          [--dry-run|--execute] -- <args>   live is dry-run by default
    cutover <site> --rehearse       One-time nwc un-fork migration orchestrator
            | --execute [--from=N]        (guarded, fail-closed, resumable; §3.7/P1-4)

${BOLD}CANONICALITY (content-flow phases, ops#33):${NC}
    canonical show [site]           Show per-site canonical phase (dev|live|prod)
    canonical set <site> <phase>    Explicit phase transition (records who/when)
    canonical check <site>          Show which content-flow guards are in force
    canonical log <site>            Transition/override ledger for a site

${BOLD}MATURITY (code-flow classes, P67/ops#48):${NC}
    maturity show [site]            Show per-site class (incubating|stabilizing|production)
    maturity set <site> <class>     Explicit transition (ledgered; downgrades typed-confirm)
    maturity check <site>           Show which code-deploy gate is in force

${BOLD}SITE CLASS (data/identity classes, ADR-0036/ops#153):${NC}
    class show [site]               Show per-site class (what the site IS)
    class check <site>              Which data invariants apply + what fails
    class set <site> <class>        Declare a class (tracked, reviewable)
    class list                      The closed class set + each one's invariants
    class evidence <site>           Art.9 evidence behind a none-stored exemption

${BOLD}INTERSITE BOUNDARY (P74 change-impact gate):${NC}
    impact [--base=main] [--json]   Classify a diff INTERNAL vs BOUNDARY-TOUCHING (nwc↔ssc)
    impact --honesty                Check no boundary symbol leaks outside its declared paths
    contracts compat [--base=main]  Expand-and-contract (BACKWARD) schema gate
    contracts sign|verify|bundle    Sign/verify the minisign schema bundle (trust root)
    contracts crossref [<pair>]     Cross-repo promise gate (WS fns + probe paths exist)

${BOLD}GDPR ART.17 ERASURE + IDENTITY REPAIR (ops#81 / ops#83):${NC}
    erasure plan <pair> --sub=<uuid>       Build + schema-validate the erasure command
    erasure verify <pair> --sub=<uuid>     Probe BOTH halves for residual rows (+ backup ceiling)
    erasure status <request-id>            What happened to a request
    erasure execute <pair> --request-id=   Fails closed until the ops#81 channel is deployed
    pair reconcile <consumer> [--apply]    Detect/repair severed UID-locks (ops#83 §3)

${BOLD}CONTRIB PATCHES (a patch composer dropped is not a fix, ops#223):${NC}
    patches <site> [--tier=dev|stg|live]   Every patch declared in extra.patches
                                           is present AND applied in the built
                                           tree (reverse dry-run), and the two
                                           composer flags the scheme rests on
                                           are still true. --tier=live compares
                                           the live copies against dev.
    patches --all                          Same, across every site with a project

${BOLD}SNAPSHOT BUNDLES (a backup that cannot restore is not a backup):${NC}
    snapshot bundle <repo> [--out=F]  Bundle a repo and PROVE it stands alone first
    snapshot verify <bundle>...       Verify in a pristine scratch repo (no borrowing)
    snapshot audit                    Every committed *.bundle must be restorable

${BOLD}BRANCH TWINS (P67/ops#48):${NC}
    branch <site> <git-ref>         Create a disposable twin on a branch
    branch list [site]              Twins nested under parents, code Δ + content age
    branch content <twin> --from=parent   Refresh twin DB (re-stamps provenance)
    branch merge <twin>             Push twin branch + print MR URL
    branch delete <twin>            Delete twin (impact report, backups archived)

${BOLD}PROVISIONING:${NC}
    live <sitename>                 Provision live test server
    live --type=shared <sitename>   Provision on shared GitLab server
    live --type=temporary <sitename> Temporary server (auto-delete)
    live --delete <sitename>        Delete live server
    live --status <sitename>        Show live server status

${BOLD}TESTING:${NC}
    test <sitename>                 Run all tests
    test -l <sitename>              Lint only (PHPCS, PHPStan)
    test -u <sitename>              Unit tests only
    test -k <sitename>              Kernel tests only
    test -f <sitename>              Functional tests only
    test -s <sitename>              Smoke tests only (Behat @smoke)
    test -b <sitename>              Full Behat tests
    test -p <sitename>              Parallel Behat tests
    testos <sitename>               Open Social specific tests
    test-nwp                        Run NWP infrastructure tests

${BOLD}THEMING:${NC}
    theme setup <sitename>          Install theme Node.js dependencies
    theme watch <sitename>          Start dev mode with live reload
    theme build <sitename>          Production build (minified)
    theme lint <sitename>           Run ESLint/Stylelint
    theme info <sitename>           Show theme build tool info

${BOLD}SCHEDULING:${NC}
    schedule install <sitename>     Install backup schedule (cron)
    schedule remove <sitename>      Remove backup schedule
    schedule install-sweep          Install nightly 'pl backup sweep' cron
    schedule remove-sweep           Remove the backup-sweep cron entry
    schedule list                   List all scheduled backups
    schedule show                   Show cron entries
    schedule run <sitename>         Run scheduled backup now

${BOLD}DEMO TIER (daily reset, ops#133):${NC}
    demo golden <sitename>          Capture current state as the golden image
    demo reset <sitename>           Verified restore of the golden (+reseed)
    demo status <sitename>          Last reset/skips, golden, invite codes
    demo codes <sitename> ...       list | issue <bundle> | revoke <id> | rotate
    demo schedule <sitename>        Install the 01:00 Melbourne nightly cron

${BOLD}SECURITY:${NC}
    security check <sitename>       Check for security updates
    security check --all            Check all sites
    security update <sitename>      Apply security updates
    security update --auto <site>   Auto-update with testing
    security audit <sitename>       Full security audit
    security-check <url>            Check HTTP security headers on URL
    headers <url>                   Alias for security-check (headers check)

${BOLD}GIT & GITLAB:${NC}
    gitlab-create <project> [group] Create GitLab project
    gitlab-list [group]             List GitLab projects

${BOLD}IMPORT & SYNC:${NC}
    import <server>                 Import sites from remote server
    onboard <site> --server=…       Chain a prod site into the fleet (create repo →
            --source=… --recipe=…   supervised sanitize → PII gate → scaffold → register).
                                    Dry-run by default; add --execute to run.
    sync <sitename>                 Sync database/files from source
    modify <sitename>               Modify site options interactively

${BOLD}MIGRATION:${NC}
    migration <sitename>            Run migration tasks

${BOLD}PODCASTING:${NC}
    podcast <sitename>              Setup Castopod podcast infrastructure

${BOLD}EMAIL:${NC}
    email setup                     Setup email infrastructure
    email add <sitename>            Add email account for site
    email test <sitename>           Test email deliverability
    email reroute <sitename>        Route email to Mailpit (dev)

${BOLD}BUILD TARGETS:${NC}
    build-server                    Assemble the AI-free nwp-server artifact
                                    (allowlist + fail-closed AI/CI/SaaS deny-scan; ADR-0022/0024)
    build-server --list             Show the include allowlist
    build-server --scan-only DIR    Re-scan an assembled artifact (independent verify)
    server-backup --site-dir DIR    DR backup of a prod site to a local restic repo
                                    (raw; pulled by ver). Dry-run by default. ADR-0025
    ver-pull --from R --to R        ver drains prod's snapshots, prunes, verifies (ADR-0025)
    test-ver <provision|assert|…>   Validate the ver (signed-deploy) tier on throwaway
                                    Linodes: WG tunnel + fail-closed invariant sweep (ops#29)
    ver-test <provision|provision-prod|cycle|teardown|status>
                                    pl-driven ver DR test harness: throwaway test-ver +
                                    test-prod Linodes run the FULL raw+sanitised backup →
                                    pull-session → restore-drill chain (ops#25/#127)

${BOLD}CI/CD:${NC}
    badges show <sitename>          Show GitLab badge URLs
    badges add <sitename>           Add badges to README.md
    badges coverage <sitename>      Check test coverage threshold

${BOLD}CLOUD STORAGE:${NC}
    storage auth                    Authenticate with Backblaze B2
    storage list                    List B2 buckets
    storage upload <file> <bucket>  Upload file to B2
    storage files <bucket>          List files in bucket

${BOLD}ROLLBACK:${NC}
    rollback list [sitename]        List available rollback points
    rollback execute <sitename>     Rollback to pre-deployment state
    rollback cleanup                Remove old rollback points

${BOLD}MONITORING (launch gate, P13/#71):${NC}
    fleet publish [--to <host>]     Publish fleet state (rag + todo + backup freshness)
                                    to the console host — the console DISPLAYS
                                    fleet state, it cannot compute it (no sites there)
    fleet status                    What is published, where, and how old
    fleet schedule                  Publish periodically from this machine (cron)
    fleet sync status               Is any nwp host running stale main? (ops#360)
    fleet sync install --host=<role>  Provision the */15 engine-code pull cron
                                    (ff-only, verified, health-checked; prod
                                    roles refused — see pl fleet --help)
    monitor uptime [--tier=live]    Fleet HTTP status + TLS expiry (red/amber/green)
    monitor mail <site>             Outbound mail readiness (SPF/DKIM/DMARC/PTR/MX)
    monitor mail <site> --send-test <addr> --execute   Opt-in live probe (gated)

${BOLD}HOST STATE (own the box, don't ssh into it):${NC}
    server health [name|--all]      Load / memory / disk / swap HEADROOM.
                                    THE preflight before anything heavy on a
                                    shared box. rc=1 no headroom, rc=3 UNKNOWN
                                    (an unmeasurable host is never "healthy").
    server forge status <name>      Forge package version, apt signing-key
                                    expiry, pending upgrades (package manager
                                    only — never the Rails console)
    dns list [domain] [--json]      READ-ONLY: every DNS record the DNS token can
                                    see, reconciled against sites/*/.nwp.yml and
                                    servers/*/. "What points where, and is it
                                    declared?" rc=1 a record shadowed by an NS
                                    delegation or a declared site pointing at the
                                    wrong box; rc=3 CANNOT-VERIFY. The
                                    DECLARED/UNDECLARED column is NOT a delete list.
    host <role|alias>               Resolve a role label to its hostname(s)
    host capture <target> [--all]   Read cron/systemd/nginx/php/ssh/firewall
                                    state into servers/<host>/system/
    host diff <target>              Non-zero on drift, blindness or an
                                    incomplete read — never a silent "clean"
    host apply <target>             Dry-run: prints the exact declared change
    host schedule <target> list     Cron on a REMOTE role, over ssh
    schedule where                  Which HOST owns each schedule
    schedule host <target> ...      Install/remove a remote cron entry
    logs <target> --source=nginx    Read-only, clamped (max 5000 lines), fixed
                                    source set: nginx php-fpm auth systemd watchdog
    loop --host <role>              The loop's state on ANOTHER machine, and it
                                    says which machine it read

${BOLD}VERIFICATION:${NC}
    verify                          Interactive verification TUI
    verify --run                    Run machine verification tests
    verify --run --depth=basic      Quick machine tests
    verify --run --feature=backup   Test specific feature
    verify ci                       CI mode with JUnit output
    verify ci --export-json         Generate .badges.json
    verify badges                   Show badge URLs
    verify status                   Show verification summary
    verify report                   Show verification report
    verify gates                    Which CI gates have EVER been proven to go RED
    verify honesty                  Lint checks that assert less than they appear to

${BOLD}DEVELOPER TOOLS:${NC}
    coder add <name>                Add developer coder environment
    coder list                      List configured coders
    report                          Generate bug report

${BOLD}SETUP & UTILITIES:${NC}
    init                            Install ALL required software (Docker, DDEV, Composer, …) — one command
    setup                           Run setup wizard (18 components; --all/--auto = non-interactive)
    setup-ssh                       Setup SSH keys for deployment
    list                            List all tracked sites
    status [options] [sitename]     Show site status (-f for fast text)
    config export|import <file>     Export/import site+server configs as a checksummed bundle (ops#79)
    deploy-gate status|test         Inspect / self-test the hardware deploy gate (ADR-0028)
    doctor                          Diagnose common issues and verify configuration
    mini llm health [--json|--quick] Check the local LLM stack on mini (F21 Phase 3a)
    version [--check]               Show NWP version; --check fetches and reports how far
                                    this checkout is behind its remote (the only pl path
                                    that touches the network for freshness)

${BOLD}MAINTENANCE:${NC}
    migrate-secrets                 Migrate secrets to new format

${BOLD}GLOBAL OPTIONS:${NC}
    -h, --help                      Show this help message
    -v, --version                   Show version
    -d, --debug                     Enable debug output
    -y, --yes                       Auto-confirm prompts

${BOLD}SCRIPT-SPECIFIC OPTIONS:${NC}
    backup:    -b (db-only), -g (git), --bundle, --sanitize, --push-all
    backup sweep: --dry-run, --start-stopped, --site <name>
    restore:   -b (db-only), -f (force), -o (overwrite)
    copy:      -f (files-only), -y (yes), -o (overwrite)
    delete:    -b (backup first), --purge (incl. backups), -y (yes; report still prints)
    make:      -v (dev mode), -p (prod mode)
    test:      -l -u -k -f -s -b -p (see TESTING above)

${BOLD}EXAMPLES:${NC}
    pl install d mysite             Install Drupal site 'mysite'
    pl backup -g mysite "Update"    Backup with git commit
    pl backup --sanitize mysite     GDPR-safe backup (no PII)
    pl test -s mysite               Run smoke tests
    pl verify --run                 Run all machine verification tests
    pl verify ci --export-json      Generate verification badges
    pl dev2stg mysite               Deploy to local staging
    pl stg2prod mysite              Deploy to production server
    pl live mysite                  Provision mysite.nwpcode.org
    pl schedule install mysite      Setup daily backups
    pl security check --all         Check all sites for updates

${BOLD}WORKFLOW:${NC}
    Development:  pl install d mysite
    Testing:      pl test -s mysite
    Staging:      pl dev2stg mysite
    Live Preview: pl live mysite && pl stg2live mysite
    Production:   pl stg2prod mysite

${BOLD}TAB COMPLETION:${NC}
    Generated from the live inventory — never a second list to maintain.
    Add to ~/.bashrc:
    complete -W "\$(pl commands --json | sed -n 's/.*"name":"\\([^"]*\\)".*/\\1/p')" pl

${BOLD}MORE HELP:${NC}
    pl <command> --help             Show help for specific command
    See docs/README.md for full documentation

EOF

    # ── ALL COMMANDS (generated — never hand-edited) ──────────────────────────
    # The curated sections above are a guided tour and will always lag. This
    # section is derived from scripts/commands/*.sh plus pl's own built-ins, so
    # a command cannot exist without being documented here.
    printf '%sALL COMMANDS (generated from scripts/commands/ — %s total):%s\n' \
        "$BOLD" "$(_pl_all_commands | wc -l | tr -d ' ')" "$NC"
    cmd_commands
    printf '\n  Machine-readable: pl commands --json\n\n'
}

################################################################################
# Utility Functions
################################################################################

print_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Check if a script exists (checks root and scripts/commands/)
script_exists() {
    local script="$1"
    if [ -f "${SCRIPT_DIR}/${script}" ] && [ -x "${SCRIPT_DIR}/${script}" ]; then
        return 0
    elif [ -f "${SCRIPT_DIR}/scripts/commands/${script}" ] && [ -x "${SCRIPT_DIR}/scripts/commands/${script}" ]; then
        return 0
    fi
    return 1
}

# Get the full path to a script
get_script_path() {
    local script="$1"
    if [ -f "${SCRIPT_DIR}/${script}" ] && [ -x "${SCRIPT_DIR}/${script}" ]; then
        echo "${SCRIPT_DIR}/${script}"
    elif [ -f "${SCRIPT_DIR}/scripts/commands/${script}" ] && [ -x "${SCRIPT_DIR}/scripts/commands/${script}" ]; then
        echo "${SCRIPT_DIR}/scripts/commands/${script}"
    fi
}

# Run a script with arguments
run_script() {
    local script="$1"
    shift

    local script_path=$(get_script_path "$script")
    if [ -z "$script_path" ]; then
        print_error "Script not found: $script"
        return 1
    fi

    # Execute script and capture exit code
    "$script_path" "$@"
    local exit_code=$?

    # Auto-log verification if enabled
    if type log_verification_if_enabled &>/dev/null; then
        log_verification_if_enabled "$script" "$exit_code"
    fi

    # Prompt for error report if enabled
    if type prompt_error_report &>/dev/null; then
        prompt_error_report "$script" "$exit_code"
    fi

    return $exit_code
}

################################################################################
# Command Handlers
################################################################################

# List all tracked sites
cmd_list() {
    local cnwp_file="${SCRIPT_DIR}/nwp.yml"

    if [ ! -f "$cnwp_file" ]; then
        print_error "nwp.yml not found"
        return 1
    fi

    echo -e "${BOLD}Tracked Sites:${NC}"
    echo ""

    # F36 A-C2: yq-first per ADR-0015 (replaces legacy AWK YAML parser)
    yq eval '.sites | keys | .[]' "$cnwp_file" 2>/dev/null | sed 's/^/  /'
}

# Get a field from a site in nwp.yml
# F36 A-C2: yq-first per ADR-0015. Scalar filter preserves the old
# AWK behaviour of returning empty for non-scalar fields and missing keys
# (caller variables passed via env() for injection-safety).
get_site_field() {
    local site="$1"
    local field="$2"
    local config_file="${SCRIPT_DIR}/nwp.yml"

    site="$site" field="$field" yq eval \
        '.sites[env(site)] | .[env(field)] | select(tag == "!!str" or tag == "!!int" or tag == "!!float" or tag == "!!bool") // ""' \
        "$config_file" 2>/dev/null
}

# Get a nested field (e.g., live.domain) from a site in nwp.yml
# F36 A-C2: yq-first per ADR-0015. See get_site_field for caveats.
get_site_nested_field() {
    local site="$1"
    local section="$2"
    local field="$3"
    local config_file="${SCRIPT_DIR}/nwp.yml"

    site="$site" section="$section" field="$field" yq eval \
        '.sites[env(site)] | .[env(section)] | .[env(field)] | select(tag == "!!str" or tag == "!!int" or tag == "!!float" or tag == "!!bool") // ""' \
        "$config_file" 2>/dev/null
}

# Show status for a single site
show_site_status() {
    local sitename="$1"
    local site_dir="${SCRIPT_DIR}/sites/$sitename"
    local cnwp_file="${SCRIPT_DIR}/nwp.yml"
    local ddev_running=false

    echo -e "${BOLD}$sitename${NC}"

    # Get config details
    local recipe=$(get_site_field "$sitename" "recipe")
    local purpose=$(get_site_field "$sitename" "purpose")
    local domain=$(get_site_nested_field "$sitename" "live" "domain")

    # Show recipe and purpose if available
    if [ -n "$recipe" ] || [ -n "$purpose" ]; then
        local info=""
        [ -n "$recipe" ] && info="$recipe"
        [ -n "$purpose" ] && info="${info:+$info, }$purpose"
        echo -e "  ${CYAN}ℹ${NC} Config: $info"
    fi

    # Check directory
    if [ ! -d "$site_dir" ]; then
        echo -e "  ${YELLOW}○${NC} Local: not present (remote only?)"
        echo ""
        return 0
    fi

    # Check DDEV
    if [ -f "$site_dir/.ddev/config.yaml" ]; then
        local ddev_status=$(cd "$site_dir" && ddev describe -j 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
        if [ "$ddev_status" = "running" ]; then
            echo -e "  ${GREEN}●${NC} DDEV: running"
            ddev_running=true
        elif [ "$ddev_status" = "stopped" ]; then
            echo -e "  ${RED}●${NC} DDEV: stopped"
        else
            echo -e "  ${YELLOW}●${NC} DDEV: $ddev_status"
        fi
    else
        echo -e "  ${YELLOW}○${NC} DDEV: not configured"
    fi

    # Show URL if DDEV running
    if [ "$ddev_running" = true ]; then
        echo -e "  ${CYAN}→${NC} URL: https://${sitename}.ddev.site"
    fi

    # Check git
    if [ -d "$site_dir/.git" ]; then
        local branch=$(cd "$site_dir" && git branch --show-current 2>/dev/null || echo "unknown")
        local last_commit=$(cd "$site_dir" && git log -1 --format="%ar" 2>/dev/null || echo "")
        if [ -n "$last_commit" ]; then
            echo -e "  ${GREEN}●${NC} Git: $branch (${last_commit})"
        else
            echo -e "  ${GREEN}●${NC} Git: $branch"
        fi
    else
        echo -e "  ${YELLOW}○${NC} Git: not initialized"
    fi

    # Check nwp.yml registration
    if grep -q "^  ${sitename}:" "$cnwp_file" 2>/dev/null; then
        echo -e "  ${GREEN}●${NC} Registered"
    else
        echo -e "  ${YELLOW}○${NC} Not registered"
    fi

    # Disk usage
    local disk_usage=$(du -sh "$site_dir" 2>/dev/null | awk '{print $1}')
    if [ -n "$disk_usage" ]; then
        echo -e "  ${CYAN}◆${NC} Disk: $disk_usage"
    fi

    # Database size (only if DDEV running)
    if [ "$ddev_running" = true ]; then
        local db_size=$(cd "$site_dir" && ddev mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) FROM information_schema.tables WHERE table_schema = DATABASE();" 2>/dev/null | tail -1)
        if [ -n "$db_size" ] && [ "$db_size" != "NULL" ]; then
            echo -e "  ${CYAN}◆${NC} Database: ${db_size}MB"
        fi

        # Health check
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "https://${sitename}.ddev.site" 2>/dev/null || echo "000")
        case "$http_code" in
            200|301|302|303) echo -e "  ${GREEN}●${NC} Health: OK (HTTP $http_code)" ;;
            401|403) echo -e "  ${YELLOW}●${NC} Health: auth required (HTTP $http_code)" ;;
            404) echo -e "  ${YELLOW}●${NC} Health: not found (HTTP 404)" ;;
            500|502|503) echo -e "  ${RED}●${NC} Health: error (HTTP $http_code)" ;;
            000) echo -e "  ${RED}●${NC} Health: unreachable" ;;
            *) echo -e "  ${YELLOW}●${NC} Health: HTTP $http_code" ;;
        esac
    fi

    # Live domain
    if [ -n "$domain" ]; then
        echo -e "  ${BLUE}◆${NC} Domain: $domain"
    fi

    echo ""
}

# Show site status (all sites or specific site)
cmd_status() {
    local arg="${1:-}"

    # Valid subcommands that should be passed to status.sh
    local -a subcommands=(health production info delete start stop restart servers)

    # If first arg is a flag, pass all args to status.sh
    if [[ "$arg" == -* ]]; then
        exec "${SCRIPT_DIR}/scripts/commands/status.sh" "$@"
    elif [ -z "$arg" ]; then
        # Launch interactive TUI for overview
        exec "${SCRIPT_DIR}/scripts/commands/status.sh"
    elif [[ " ${subcommands[*]} " =~ " ${arg} " ]]; then
        # Valid subcommand - pass through to status.sh
        exec "${SCRIPT_DIR}/scripts/commands/status.sh" "$@"
    else
        # Show detailed single site view
        echo -e "${BOLD}Site Status:${NC}"
        echo ""
        show_site_status "$arg"
    fi
}

# GitLab create project
cmd_gitlab_create() {
    # lib/git.sh and lib/common.sh both read ${PROJECT_ROOT} at source time, and
    # `pl` runs under `set -u`. On the run_script path a subcommand sets it for
    # itself; on this INLINE path nobody did, so both gitlab verbs died with
    # `PROJECT_ROOT: unbound variable` before they could read a token — and then
    # reported the symptom as "ERROR: API token required", which is a different
    # and much more misleading fault. Not exported: the run_script children keep
    # resolving it exactly as they do today.
    PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
    source "${SCRIPT_DIR}/lib/ui.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/git.sh"

    local project="${1:-}"
    local group="${2:-sites}"

    if [ -z "$project" ]; then
        print_error "Project name required"
        return 1
    fi

    gitlab_api_create_project "$project" "$group"
}

# GitLab list projects
cmd_gitlab_list() {
    # See cmd_gitlab_create for why PROJECT_ROOT is defaulted here.
    PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
    source "${SCRIPT_DIR}/lib/ui.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/git.sh"

    local group="${1:-sites}"

    gitlab_api_list_projects "$group"
}

################################################################################
# Main
################################################################################

main() {
    # Handle no arguments
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi

    # Parse global options
    local DEBUG=false
    local YES=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "NWP CLI (pl) version $VERSION"
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                export DEBUG
                shift
                ;;
            -y|--yes)
                YES=true
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    # Get command
    local command="${1:-}"
    shift || true

    # Route to appropriate handler
    case "$command" in
        # Site management
        install)
            run_script "install.sh" "$@"
            ;;
        delete)
            run_script "delete.sh" "$@"
            ;;
        make)
            run_script "make.sh" "$@"
            ;;
        uninstall)
            run_script "uninstall_nwp.sh" "$@"
            ;;

        # Backup & restore
        backup)
            run_script "backup.sh" "$@"
            ;;
        restore)
            run_script "restore.sh" "$@"
            ;;
        copy)
            run_script "copy.sh" "$@"
            ;;

        # Deployment (local)
        dev2stg)
            run_script "dev2stg.sh" "$@"
            ;;

        # Deployment (remote)
        stg2prod)
            run_script "stg2prod.sh" "$@"
            ;;
        prod2stg)
            run_script "prod2stg.sh" "$@"
            ;;
        stg2live)
            run_script "stg2live.sh" "$@"
            ;;
        live2stg)
            run_script "live2stg.sh" "$@"
            ;;
        live2prod)
            run_script "live2prod.sh" "$@"
            ;;

        # Sanctioned remote/stg drush runner (retires raw ssh drush; §6 P1-4)
        drush)
            run_script "drush.sh" "$@"
            ;;

        # One-time nwc un-fork migration orchestrator (PL-STG2LIVE §3.7 / P1-4):
        # guarded, fail-closed, resumable wrapper around the cutover step sequence.
        cutover)
            run_script "cutover.sh" "$@"
            ;;

        # Canonicality phases + content-flow guards (nwp/ops#33)
        canonical)
            run_script "canonical.sh" "$@"
            ;;

        # Maturity classes + code-flow guards (P67 / nwp/ops#48)
        maturity)
            run_script "maturity.sh" "$@"
            ;;

        # Site classes: what a site IS → which invariants apply (ADR-0036 / ops#153)
        class)
            run_script "class.sh" "$@"
            ;;

        # Paired-site versioning: contract status/guard (ADR-0031 / nwp/ops#75)
        pair)
            run_script "pair.sh" "$@"
            ;;
        pair-smoke)
            run_script "pair-smoke.sh" "$@"
            ;;

        # nwc(IdP)↔ssc(Moodle) SSO/token link health gate + lifecycle
        # (PL-STG2LIVE §5.5/§5.7). `pl link verify` is the read-only 3-channel
        # deploy-gate; provision/token/keys rotate are stubs pending §5.7.
        link)
            run_script "link.sh" "$@"
            ;;

        # Moodle promotion substrate + smoke (ADR-0031 D8 / ops D)
        # Intersite change-impact classifier (P74 Phase 2 / boundary gate)
        impact)
            run_script "impact.sh" "$@"
            ;;

        # Intersite contract compat + signed schema bundle (P74 Phase 3)
        contracts)
            run_script "contracts.sh" "$@"
            ;;

        # GDPR Art.17 right-to-be-forgotten across the nwc↔ssc pair (ops#81).
        # plan/verify are real today; execute FAILS CLOSED until the ops#81
        # P1/P2 channel is deployed and the operator has approved the semantics.
        erasure)
            run_script "erasure.sh" "$@"
            ;;

        # Are this site's DECLARED contrib patches actually in the built tree?
        # (ops#223). The Drupal twin of `pl moodle core-patch`: a patch that
        # composer silently stopped applying is not a fix, and the Art.17
        # erasure fix is a patch.
        patches)
            run_script "patches.sh" "$@"
            ;;

        # Git bundles that can actually rebuild what they claim to hold
        # (fix programme item 8 — two committed "safety" bundles were bricks)
        snapshot)
            run_script "snapshot.sh" "$@"
            ;;

        # Moodle command family (PL-STG2LIVE §4 / P1-2): guarded plugin
        # build/deploy/upgrade/backup/rollback. moodle-promote/moodle-smoke stay
        # as back-compat aliases (also reachable as `pl moodle config|smoke`).
        moodle)
            run_script "moodle.sh" "$@"
            ;;
        moodle-promote)
            run_script "moodle-promote.sh" "$@"
            ;;
        moodle-smoke)
            run_script "moodle-smoke.sh" "$@"
            ;;

        # Branch twin sites (P67 §5c / nwp/ops#48)
        branch)
            run_script "branch.sh" "$@"
            ;;

        # Provisioning
        live)
            run_script "live.sh" "$@"
            ;;
        produce)
            run_script "produce.sh" "$@"
            ;;

        # Testing
        test)
            run_script "test.sh" "$@"
            ;;
        testos)
            run_script "testos.sh" "$@"
            ;;
        test-nwp)
            # Deprecated: redirects to verify --run (P50)
            echo "Note: 'pl test-nwp' is deprecated. Use 'pl verify --run' instead."
            run_script "verify.sh" --run "$@"
            ;;

        # Theming
        theme)
            run_script "theme.sh" "$@"
            ;;

        # Scheduling
        schedule)
            run_script "schedule.sh" "$@"
            ;;

        # Daily-reset demo tier (ops#133 Phase 1)
        demo)
            run_script "demo.sh" "$@"
            ;;

        # Security - handle both forms
        security)
            run_script "security.sh" "$@"
            ;;
        security-check)
            # Check if argument looks like a URL (HTTP security headers check)
            if [[ "${1:-}" =~ ^https?:// ]] || [[ "${1:-}" =~ \. ]]; then
                run_script "security-check.sh" "$@"
            else
                run_script "security.sh" "check" "$@"
            fi
            ;;
        security-update)
            run_script "security.sh" "update" "$@"
            ;;
        security-audit)
            run_script "security.sh" "audit" "$@"
            ;;
        headers)
            # HTTP security headers check (alias for security-check <url>)
            run_script "security-check.sh" "$@"
            ;;

        # Import & Sync
        import)
            run_script "import.sh" "$@"
            ;;
        onboard)
            run_script "onboard.sh" "$@"
            ;;
        sync)
            run_script "sync.sh" "$@"
            ;;
        modify)
            run_script "modify.sh" "$@"
            ;;

        # Migration
        migration)
            run_script "migration.sh" "$@"
            ;;

        # Podcasting
        podcast)
            run_script "podcast.sh" "$@"
            ;;

        # Email
        email)
            run_script "email.sh" "$@"
            ;;

        # CI/CD
        badges)
            run_script "badges.sh" "$@"
            ;;

        # Cloud Storage
        storage)
            run_script "storage.sh" "$@"
            ;;

        # Rollback
        rollback)
            run_script "rollback.sh" "$@"
            ;;

        # Build targets
        build-server)
            run_script "scripts/build-nwp-server.sh" "$@"
            ;;

        # Validate the ver (signed-deploy) tier setup on throwaway Linodes (nwp/ops#29)
        test-ver)
            run_script "test-ver.sh" "$@"
            ;;

        # pl-driven ver DR test harness — full raw+sanitised → pull → drill chain
        # on throwaway Linodes (task #11; ops#25 + ops#127)
        ver-test)
            run_script "ver-test.sh" "$@"
            ;;

        # Production agent (nwp-server) — DR backup (ADR-0025)
        server-backup)
            run_script "server-backup.sh" "$@"
            ;;
        ver-pull)
            run_script "ver-backup-pull.sh" "$@"
            ;;

        # Developer tools
        coder)
            run_script "coder-setup.sh" "$@"
            ;;

        # Per-site config / schema management (F23)
        site)
            run_script "site.sh" "$@"
            ;;

        # Per-server config / schema management (F23 Phase 8)
        # + `health` (headroom preflight) and `forge status` (item 6)
        server)
            run_script "server.sh" "$@"
            ;;

        # Forge box (git.nwpcode.org): named, scoped identities across the Linux
        # and GitLab-application planes (ops#331, ADR-0038). Read-only default.
        forge)
            run_script "forge.sh" "$@"
            ;;

        # DNS enumeration — the one thing the estate could not see (read-only)
        dns)
            run_script "dns.sh" "$@"
            ;;

        # Host state: role resolution + capture/diff/apply/schedule (item 6)
        host)
            run_script "host.sh" "$@"
            ;;

        # Read-only, resource-bounded log access — replaces "just ssh in"
        logs)
            run_script "logs.sh" "$@"
            ;;

        # AI/LLM-host utilities (F21 Phase 3a). The canonical verb is the ROLE
        # label `ai-host`, which dispatches through the generic fallback from
        # scripts/commands/ai-host.sh — so `pl commands` (the doc-truth oracle)
        # lists it and `docs/guides/miniterm.md` stops citing a verb that could
        # not be dispatched. `pl mini` stays as an alias: it is what the
        # operator's fingers and the miniterm shim already type.
        mini)
            run_script "ai-host.sh" "$@"
            ;;

        # Cross-site proposal aggregator (F23 §7.4)
        proposals)
            run_script "proposals.sh" "$@"
            ;;

        # Config bundle export/import (ops#79)
        config)
            run_script "config.sh" "$@"
            ;;

        # Fleet uptime + mail deliverability launch gate (P13 / nwp/ops#71)
        monitor)
            run_script "monitor.sh" "$@"
            ;;

        # Diagnostics
        deploy-gate)
            run_script "deploy-gate.sh" "$@"
            ;;
        doctor)
            run_script "doctor.sh" "$@"
            ;;
        verify)
            run_script "verify.sh" "$@"
            ;;
        vrt)
            run_script "vrt.sh" "$@"
            ;;
        report)
            run_script "report.sh" "$@"
            ;;

        # Git
        gitlab-create)
            cmd_gitlab_create "$@"
            ;;
        gitlab-list)
            cmd_gitlab_list "$@"
            ;;

        # Setup & utilities
        setup)
            run_script "setup.sh" "$@"
            ;;
        setup-ssh)
            run_script "setup-ssh.sh" "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        version)
            echo "NWP CLI (pl) version $VERSION"
            # --check is the ONLY thing in pl allowed to touch the network for
            # freshness, and only because it was asked to. See lib/pl-freshness.sh.
            if [[ "${1:-}" == "--check" ]]; then
                if declare -F pl_freshness_check >/dev/null 2>&1; then
                    pl_freshness_check "$SCRIPT_DIR"
                else
                    echo "freshness: lib/pl-freshness.sh is missing from this checkout" >&2
                fi
            fi
            ;;

        # Secrets lifecycle (registry-driven; no token stored on host)
        secrets)
            run_script "secrets.sh" "$@"
            ;;

        # Maintenance
        migrate-secrets)
            run_script "migrate-secrets.sh" "$@"
            ;;

        # Help
        help)
            show_help
            ;;

        # Command inventory
        commands)
            cmd_commands "$@"
            ;;

        # Script-name fallback — bounded by the inventory.
        #
        # This arm used to resolve ANY executable file it could find, including
        # ones that are not commands at all (`$SCRIPT_DIR/$command` matches the
        # repo root, so `pl pl` re-entered pl). It now dispatches only names
        # that `pl commands` lists, so what runs is exactly what is documented.
        *)
            if _pl_command_exists "$command" && script_exists "${command}.sh"; then
                run_script "${command}.sh" "$@"
            elif script_exists "${command}.sh" || script_exists "${command}"; then
                print_error "Undocumented command: $command"
                echo ""
                echo "A file matching '$command' exists but it is not a registered NWP command."
                echo "Registered commands: pl commands"
                exit 1
            else
                print_error "Unknown command: $command"
                echo ""
                local _suggest
                _suggest=$(_pl_all_commands | grep -F "$command" | head -3 | tr '\n' ' ' || true)
                [ -n "${_suggest// /}" ] && echo "Did you mean: $_suggest"
                echo "Run 'pl --help' or 'pl commands' for usage information."
                exit 1
            fi
            ;;
    esac
}

# Run main
main "$@"
