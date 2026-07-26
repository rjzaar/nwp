#!/usr/bin/env bash
#
# pl logs — read a host's or a site's logs through a `pl` verb.
#
# WHY THIS EXISTS (fix-programme item 6): there was no `pl logs`. docs/SECURITY.md
# admits "(no equivalent)" twice. So every incident began with an unsanctioned
# ssh into the box you are least supposed to poke — the 3.8 GB forge that serves
# GitLab and five live sites — with an unbounded `tail -f` typed from memory.
#
# READ-ONLY BY CONSTRUCTION:
#   * --source is matched against a FIXED case list (lib/host-capture.sh's
#     host_log_source_cmd). Operator text never reaches the remote shell.
#   * --tail is validated as an integer and CLAMPED (max 5000 lines) so a
#     fat-fingered request cannot pull a gigabyte off a memory-starved box.
#   * --since is shape-checked before it is passed to journalctl.
#   * There is no --command, no passthrough and no -f. Deliberately.
#
# Usage:
#   pl logs <role|server|host> [--source=<s>] [--tail=N] [--since=<when>]
#   pl logs --sources
#   pl logs -h|--help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NWP_DIR="${NWP_DIR:-$PROJECT_ROOT}"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/server-resolver.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/host-capture.sh"

show_help() {
    cat << EOF
${BOLD}pl logs${NC} — read-only, resource-bounded log access over the resolved ssh route

${BOLD}USAGE:${NC}
  pl logs <role|server|host> [--source=<s>] [--tail=N] [--since=<when>]
  pl logs --sources
  pl logs -h|--help

${BOLD}SOURCES${NC} (fixed set — anything else is refused, not forwarded):
  nginx      /var/log/nginx/{error,access}.log
  php-fpm    /var/log/php*-fpm.log
  auth       /var/log/auth.log
  systemd    journalctl (honours --since)
  watchdog   /var/log/syslog

${BOLD}BOUNDS:${NC}
  --tail defaults to 200 and is clamped to 5000. There is no follow mode and no
  arbitrary-command passthrough: this verb exists so that reading a log never
  requires an interactive shell on a production box.
EOF
}

main() {
    local target="" source="nginx" tail="200" since="" arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help)  show_help; return 0 ;;
            --sources)  printf '%s\n' "${HOST_LOG_SOURCES[@]}"; return 0 ;;
            --source=*) source="${arg#--source=}" ;;
            --tail=*)   tail="${arg#--tail=}" ;;
            --since=*)  since="${arg#--since=}" ;;
            -*)         print_error "unknown option: $arg"; return 2 ;;
            *)          target="$arg" ;;
        esac
    done

    [ -n "$target" ] || { show_help; return 1; }

    if [[ ! "$tail" =~ ^[0-9]+$ ]]; then
        print_error "--tail must be an integer (got '$tail')"
        return 2
    fi

    local remote
    if ! remote="$(host_log_source_cmd "$source" "$tail" "$since")"; then
        print_error "unknown source: '$source'"
        printf '  known: %s\n' "${HOST_LOG_SOURCES[*]}" >&2
        return 2
    fi

    local prefix name
    prefix="$(host_resolve_dest "$target")" || { print_error "cannot resolve target: $target"; return 1; }
    name="$(host_resolve_name "$target")"

    # Always say which machine was interrogated. The `pl loop` bug this whole
    # item exists to fix was a dashboard that reported on the wrong host.
    printf '%s─── %s · %s (last %s lines) ───%s\n' "${DIM:-}" "$name" "$source" "$tail" "${NC:-}"

    local rc=0
    host_run "$prefix" "$remote" || rc=$?
    if [ "$rc" -ne 0 ]; then
        print_error "UNREACHABLE: could not read logs on $name (rc=$rc) — this is not 'no errors'"
        return 3
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
