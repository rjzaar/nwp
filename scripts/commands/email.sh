#!/bin/bash
set -euo pipefail

################################################################################
# NWP Email Management Wrapper
#
# Provides unified interface for email setup, testing, and configuration
#
# Usage: pl email <command> [options]
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# The email tooling moved into the per-server config tree (F17 Phase 8):
# servers/nwpcode/email/ is the checked-in home (the box carries an installed
# copy under /opt/nwp/email/). The old top-level email/ is kept as a fallback
# for pre-migration checkouts.
EMAIL_DIR="$PROJECT_ROOT/servers/nwpcode/email"
[ -d "$EMAIL_DIR" ] || EMAIL_DIR="$PROJECT_ROOT/email"

# Called by every dispatching branch (help works without the tooling present).
require_email_dir() {
    if [ ! -d "$EMAIL_DIR" ]; then
        print_error "Email tooling not found (looked in servers/nwpcode/email/ and email/)"
        exit 1
    fi
}

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

################################################################################
# Remote execution (--host=<server>)
#
# The alias map that decides which @<estate-domain> addresses are DELIVERABLE lives
# on the MX box, not here — so `pl email add` was only ever half a verb: it
# edited a local Postfix that no mail ever reaches. Every real alias was
# therefore added by hand with `ssh box 'sudo /opt/nwp/email/add_site_email.sh …'`,
# which is exactly the raw-remote-CLI idiom the standing order forbids and which
# leaves `doctor`'s check_mail_aliases as the only thing that notices.
#
# --host=<server> resolves the route from the tracked servers/<name>/.nwp-server.yml
# (never a typed IP or key path) and runs the box-installed copy of the same
# checked-in script. `pl email baseline <server>` then pulls /etc/postfix/virtual
# back into the tracked baseline, which is what check_mail_aliases reads.
################################################################################

BOX_EMAIL_DIR="/opt/nwp/email"

# Strip --host=<server> out of an argument list. Sets EMAIL_HOST and rewrites
# EMAIL_ARGS to the remaining arguments.
EMAIL_HOST=""
EMAIL_ARGS=()
email_extract_host() {
    local arg
    EMAIL_HOST=""
    EMAIL_ARGS=()
    for arg in "$@"; do
        case "$arg" in
            --host=*) EMAIL_HOST="${arg#--host=}" ;;
            *) EMAIL_ARGS+=("$arg") ;;
        esac
    done
}

# email_remote <server> <box-script> [args...]
# Runs a box-installed email script over the resolved SSH route, under sudo.
email_remote() {
    local server="$1" script="$2"; shift 2
    local ssh_cmd
    if ! ssh_cmd=$(get_server_ssh_command "$server"); then
        print_error "Cannot resolve an SSH route for server '$server'"
        print_hint "Expected servers/$server/.nwp-server.yml with ip/ssh_user/ssh_key"
        return 1
    fi
    # Quote every argument for the remote shell — a localpart is operator input.
    local remote="sudo $BOX_EMAIL_DIR/$script"
    local a
    for a in "$@"; do
        remote+=" $(printf '%q' "$a")"
    done
    print_info "→ $server: $script $*"
    # shellcheck disable=SC2086
    $ssh_cmd "$remote"
}

# Refresh the tracked baseline of /etc/postfix/virtual for a server. This is the
# other half of the loop: without it, an alias added on the box stays invisible
# to check_mail_aliases and the next doctor run still reports the address as a
# black hole.
email_baseline() {
    local server="${1:-}"
    if [ -z "$server" ]; then
        print_error "Usage: pl email baseline <server>"
        return 1
    fi
    local dir="$PROJECT_ROOT/servers/$server/email"
    local baseline="$dir/postfix-virtual"
    if [ ! -d "$dir" ]; then
        print_error "No servers/$server/email/ directory to hold the baseline"
        return 1
    fi
    local ssh_cmd
    if ! ssh_cmd=$(get_server_ssh_command "$server"); then
        print_error "Cannot resolve an SSH route for server '$server'"
        return 1
    fi

    # Preserve everything above the verbatim marker (the maintenance header);
    # replace only the live-map section. A baseline that loses its header stops
    # telling the next reader how to regenerate it.
    local marker="# --- live map below (verbatim) ---"
    local tmp; tmp="$(mktemp)"
    if [ -f "$baseline" ] && grep -qF "$marker" "$baseline"; then
        sed -n "1,/$(printf '%s' "$marker" | sed 's/[][\\.*^$/]/\\&/g')/p" "$baseline" > "$tmp"
    else
        printf '%s\n' "$marker" > "$tmp"
    fi

    # shellcheck disable=SC2086
    if ! $ssh_cmd 'sudo cat /etc/postfix/virtual' >> "$tmp"; then
        rm -f "$tmp"
        print_error "Could not read /etc/postfix/virtual on '$server'"
        return 1
    fi
    mv "$tmp" "$baseline"
    print_success "Refreshed $baseline from $server"
    print_hint "Commit it in the server-local repo: git -C servers/$server commit -m 'email: refresh virtual baseline'"
}

show_help() {
    cat << EOF
${BOLD}NWP Email Management${NC}

${BOLD}USAGE:${NC}
    pl email <command> [options]

${BOLD}COMMANDS:${NC}
    setup                   Setup email infrastructure (Postfix, DKIM, SPF)
    add <localpart>         Add email account / alias for a site or role
    test [sitename]         Test email deliverability
    reroute <sitename>      Configure email rerouting for development
    reroute --disable       Disable email rerouting
    list                    List configured site emails
    baseline <server>       Refresh servers/<server>/email/postfix-virtual
                            from the box (what 'pl doctor' reads)

${BOLD}OPTIONS:${NC}
    --host=<server>         Run on the MX box over the route in
                            servers/<server>/.nwp-server.yml, instead of the
                            local Postfix. Deliverability for @<estate-domain> is
                            decided on the box, so an alias you actually intend
                            to receive mail on needs this.

${BOLD}EXAMPLES:${NC}
    pl email setup                  # Initial server email setup
    pl email add mysite             # Add email for mysite (local Postfix)
    pl email test mysite            # Test mysite email delivery
    pl email reroute mysite         # Route mysite email to Mailpit

    # Add a forward-only alias on the MX box, then re-track the baseline:
    pl email add demo-support --forward-only <forward-target> -y --host=<server>
    pl email baseline <server>
    pl doctor                       # check_mail_aliases now sees it

EOF
}

case "${1:-}" in
    setup)
        shift
        email_extract_host "$@"
        if [ -n "$EMAIL_HOST" ]; then
            email_remote "$EMAIL_HOST" setup_email.sh "${EMAIL_ARGS[@]+"${EMAIL_ARGS[@]}"}"
        else
            require_email_dir
            "$EMAIL_DIR/setup_email.sh" "$@"
        fi
        ;;
    add)
        shift
        email_extract_host "$@"
        if [ -n "$EMAIL_HOST" ]; then
            email_remote "$EMAIL_HOST" add_site_email.sh "${EMAIL_ARGS[@]+"${EMAIL_ARGS[@]}"}"
        else
            require_email_dir
            "$EMAIL_DIR/add_site_email.sh" "$@"
        fi
        ;;
    test)
        shift
        email_extract_host "$@"
        if [ -n "$EMAIL_HOST" ]; then
            email_remote "$EMAIL_HOST" test_email.sh "${EMAIL_ARGS[@]+"${EMAIL_ARGS[@]}"}"
        else
            require_email_dir
            "$EMAIL_DIR/test_email.sh" "$@"
        fi
        ;;
    reroute)
        shift
        require_email_dir
        "$EMAIL_DIR/configure_reroute.sh" "$@"
        ;;
    list)
        shift
        email_extract_host "$@"
        if [ -n "$EMAIL_HOST" ]; then
            email_remote "$EMAIL_HOST" add_site_email.sh --list "${EMAIL_ARGS[@]+"${EMAIL_ARGS[@]}"}"
        else
            require_email_dir
            "$EMAIL_DIR/add_site_email.sh" --list "$@"
        fi
        ;;
    baseline)
        shift
        email_baseline "${1:-}"
        ;;
    -h|--help|help|"")
        show_help
        ;;
    *)
        print_error "Unknown email command: $1"
        show_help
        exit 1
        ;;
esac
