#!/bin/bash
#
# pl host — own host state: resolve roles, CAPTURE what a box actually is,
#           DIFF the repo against it, and APPLY declared state back.
#
# Historically this file did one thing: role -> hostname. That left every other
# host fact — DR crons, nginx snippets, php.ini overrides, systemd units, ufw
# rules, authorized_keys jails — living only on boxes, ungreppable and
# unrebuildable (fix-programme item 6). The capture/diff/apply verbs below give
# those artifacts an owner. See lib/host-capture.sh for the engine and its five
# design rules (read-only, fail-closed, cheap, scrubbed, no hardcoded hosts).
#
# The role/hostname decoupling (ADR-0020 + docs/reference/role-vocabulary.md, F32)
# means code and docs refer to ROLES ("ci-host", "ver"), never raw box names.
# This is the ONE resolver from role -> hostname, reading the operator's private
# instance-manifest.yml. NO hostname is hardcoded here (leakage gate): every value
# comes from the manifest via yq. Boxes are multi-role, so a role may resolve to a
# host that also carries other roles — that's expected; the resolver is role-first.
#
# Usage:
#   pl host <role|alias>        print the hostname(s) bound to the role
#   pl host <role|alias> --all  same, all hosts if the role binds several
#   pl host --list              print the whole role -> host table
#   pl host --aliases           print the short-alias map
#   pl host capture <target> [--kind=K|--all]   read host state into servers/<h>/system/
#   pl host diff    <target> [--kind=K|--all]   non-zero on drift / blindness
#   pl host apply   <target> [--kind=K] [--execute]   dry-run by default
#   pl host schedule <target> <install|remove|list> ...  remote cron, idempotent
#   pl host -h|--help
#
# Env: NWP_INSTANCE_MANIFEST overrides the manifest path.
#      NWP_SERVERS_DIR       overrides where captured state is filed.
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
NWP_DIR="${NWP_DIR:-$PROJECT_ROOT}"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/server-resolver.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/host-capture.sh"

MANIFEST="${NWP_INSTANCE_MANIFEST:-$HOME/nwp-instances/instance-manifest.yml}"
YQ="$(command -v yq || true)"

# short alias -> canonical role label (canonical labels per role-vocabulary.md)
_canon() {
    case "$1" in
        auth)  echo authoring ;;
        cih)   echo ci-host ;;
        bh)    echo build-host ;;
        aih)   echo ai-host ;;
        lmh)   echo llm-host ;;
        va)    echo voice-agent ;;
        tw)    echo transcription-worker ;;
        tg)    echo transcription-gpu ;;
        ms)    echo mirror-store ;;
        rag)   echo rag-backend ;;
        ver)   echo verifier ;;
        gh)    echo gitlab-host ;;
        prod)  echo prod-cluster ;;
        pa)    echo prod-agent ;;
        *)     echo "$1" ;;
    esac
}

show_help() {
    cat << EOF
${BOLD}pl host${NC} — resolve a role label (or short alias) to its hostname(s)

${BOLD}USAGE:${NC}
  pl host <role|alias>        print the hostname(s) bound to the role
  pl host <role|alias> --all  same (a role may bind several hosts)
  pl host --list              the whole role -> host table
  pl host --aliases           the short-alias map

${BOLD}HOST STATE:${NC}
  pl host capture <target> [--kind=K|--all]   read real state into servers/<h>/system/
  pl host diff    <target> [--kind=K|--all]   non-zero on drift, blindness or incompleteness
  pl host apply   <target> [--kind=K]         dry-run by default; prints the exact change
  pl host schedule <target> list|install|remove   remote cron, idempotent, absolute PATH

  pl host -h|--help

Reads the private ${DIM}${MANIFEST/#$HOME/\~}${NC} (override: NWP_INSTANCE_MANIFEST).
Roles are the canonical vocabulary (docs/reference/role-vocabulary.md); boxes are
multi-role, so the same host answers for several roles.
EOF
}

_require() {
    [ -f "$MANIFEST" ] || { print_error "instance manifest not found: $MANIFEST"; exit 1; }
    [ -n "$YQ" ] || { print_error "yq is required (go-yq / mikefarah)"; exit 1; }
}

list_all() {
    _require
    print_header "Role -> host bindings"
    role="" "$YQ" e '.roles | to_entries | .[] | .key + "\t" + ((.value // []) | join(", "))' "$MANIFEST" \
        | while IFS=$'\t' read -r role hosts; do
            printf "  ${BOLD}%-20s${NC} %s\n" "$role" "${hosts:-${DIM}(unbound)${NC}}"
        done
    printf "\n  ${DIM}aliases: pl host --aliases${NC}\n"
}

list_aliases() {
    cat << EOF
  auth=authoring   cih=ci-host    bh=build-host   aih=ai-host   lmh=llm-host
  va=voice-agent   tw=transcription-worker        tg=transcription-gpu
  ms=mirror-store  rag=rag-backend                ver=verifier
  gh=gitlab-host   prod=prod-cluster              pa=prod-agent
EOF
}

resolve() {
    _require
    local in="$1" role hosts
    role="$(_canon "$in")"
    hosts="$(role="$role" "$YQ" e '.roles[strenv(role)] // [] | .[]' "$MANIFEST" 2>/dev/null || true)"
    if [ -z "$hosts" ]; then
        print_error "no host bound to role '$role'${role:+ (from '$in')}. Try: pl host --list"
        return 1
    fi
    echo "$hosts"
}

################################################################################
# capture / diff / apply / schedule
################################################################################

# Split "--kind=a,b" / "--all" out of argv. Echoes the selected kinds.
_parse_kinds() {
    local kinds=() a
    for a in "$@"; do
        case "$a" in
            --all) kinds=("${HOST_CAPTURE_KINDS[@]}") ;;
            --kind=*)
                local IFS=','
                # shellcheck disable=SC2206
                local list=(${a#--kind=})
                local k
                for k in "${list[@]}"; do
                    if host_kind_is_known "$k"; then kinds+=("$k")
                    else print_error "unknown kind: $k (known: ${HOST_CAPTURE_KINDS[*]})"; return 1; fi
                done
                ;;
        esac
    done
    [ "${#kinds[@]}" -eq 0 ] && kinds=("${HOST_CAPTURE_KINDS[@]}")
    printf '%s\n' "${kinds[@]}"
}

_capture_help() {
    cat << EOF
${BOLD}pl host capture${NC} — read a host's real state into servers/<host>/system/

${BOLD}USAGE:${NC}
  pl host capture <role|server|host> [--kind=<k>[,<k>]] [--all] [-y|--yes]

${BOLD}KINDS:${NC}
  ${HOST_CAPTURE_KINDS[*]}

    cron       root crontab, /etc/crontab, every /etc/cron.d entry
    systemd    enabled unit files + timers (installed-but-disabled is visible)
    nginx      conf.d, snippets, letsencrypt deploy hooks
    php        per-SAPI conf.d overrides + the EFFECTIVE ini values per binary
    ssh        authorized_keys POLICY — options and comments, never key material
    firewall   ufw status (numbered)
    headscale  the ACL policy of the estate's VPN control plane

Capture is READ-ONLY on the HOST and fails CLOSED: if the host cannot read part
of its own state the tree is left untouched and the exit code is non-zero. An
unreachable host is never recorded as "no change".

Replacing an existing capture is a destructive LOCAL write, so it renders a fate
manifest (lib/impact.sh) first and asks. Pass -y to skip the prompt; with no TTY
and no -y it aborts rather than guessing.
EOF
}

cmd_capture() {
    local target="${1:-}"; shift || true
    if [ -z "$target" ] || [ "$target" = "-h" ] || [ "$target" = "--help" ]; then
        _capture_help; [ -z "$target" ] && return 1 || return 0
    fi
    local kinds; mapfile -t kinds < <(_parse_kinds "$@") || return 1
    local yes=() a
    for a in "$@"; do case "$a" in -y|--yes) yes=(--yes) ;; esac; done
    print_header "Capturing $(host_resolve_name "$target")"
    host_capture "$target" "${kinds[@]}" "${yes[@]}"
}

cmd_diff() {
    local target="${1:-}"; shift || true
    [ -n "$target" ] || { print_error "usage: pl host diff <target> [--kind=K|--all]"; return 2; }
    local kinds; mapfile -t kinds < <(_parse_kinds "$@") || return 1
    local rc=0
    host_diff "$target" "${kinds[@]}" || rc=$?
    case "$rc" in
        0) print_success "no drift" ;;
        1) print_error   "DRIFT — the repo does not describe this host" ;;
        2) print_error   "CAPTURE-INCOMPLETE — could not read part of the host; NOT 'clean'" ;;
        3) print_error   "UNREACHABLE — could not talk to the host; NOT 'clean'" ;;
    esac
    return $rc
}

# pl host apply — dry-run DEFAULT. Writing declared state back to a box that
# serves live sites is operator work (CLAUDE.md: server configuration is
# high-risk). This verb's job is to produce the exact diff and fate manifest an
# operator executes, and to refuse to do it silently.
cmd_apply() {
    local target="${1:-}"; shift || true
    [ -n "$target" ] || { print_error "usage: pl host apply <target> [--kind=K] [--execute]"; return 2; }
    local execute=0 a
    for a in "$@"; do [ "$a" = "--execute" ] && execute=1; done
    local kinds; mapfile -t kinds < <(_parse_kinds "$@") || return 1

    local name; name="$(host_resolve_name "$target")"
    print_header "pl host apply — $name"
    local rc=0
    host_diff "$target" "${kinds[@]}" || rc=$?

    if [ "$rc" -ge 2 ]; then
        print_error "refusing to apply: the host's current state could not be read (rc=$rc)"
        return "$rc"
    fi
    if [ "$rc" -eq 0 ]; then
        print_success "nothing to apply — host already matches the repo"
        return 0
    fi

    if [ "$execute" -eq 0 ]; then
        echo ""
        print_warning "DRY RUN — nothing was written to $name."
        echo "  The lines marked '+' above are what the repo would install."
        echo "  Re-run with --execute to apply (you will be asked to type the host name)."
        echo ""
        print_hint "On a box that serves live sites, hand this diff to the operator instead."
        return 0
    fi

    # --execute: typed confirmation, pre-state snapshot, rollback registry row.
    print_warning "About to overwrite host state on '$name' from the repo."
    printf "Type the host name to continue: "
    local typed=""; read -r typed || true
    if [ "$typed" != "$name" ]; then
        print_error "confirmation did not match — nothing applied"
        return 1
    fi
    print_error "pl host apply --execute is not enabled in this release."
    print_hint "The declared state and its diff are above; an operator applies it."
    print_hint "Record the change with: pl rollback register"
    return 1
}

# pl host schedule — install/remove/verify cron on a REMOTE role over ssh.
# `pl demo schedule` has been telling operators to run `pl schedule host` for a
# while; this is the implementation it pointed at.
cmd_schedule() {
    local target="${1:-}" action="${2:-list}"; shift 2 2>/dev/null || true
    if [ -z "$target" ] || [ "$target" = "-h" ] || [ "$target" = "--help" ]; then
        cat << EOF
${BOLD}pl host schedule${NC} — own cron on a REMOTE role, over ssh, idempotently

${BOLD}USAGE:${NC}
  pl host schedule <target> list
  pl host schedule <target> install --name=<id> --schedule="<cron expr>" --command="<cmd>" [--execute]
  pl host schedule <target> remove  --name=<id> [--execute]

Entries are written as a single managed block in /etc/cron.d/nwp-<id>, so a
re-install rewrites rather than duplicates. Install/remove are DRY-RUN by
default. Every managed entry carries an absolute PATH (the class of bug behind
"fix(fleet): bake a working PATH into the publish cron entry").
EOF
        [ -z "$target" ] && return 1 || return 0
    fi

    local prefix; prefix="$(host_resolve_dest "$target")" || {
        print_error "cannot resolve target: $target"; return 1; }
    local name; name="$(host_resolve_name "$target")"

    case "$action" in
        list)
            print_header "Schedules on $name"
            local out rc
            out="$(host_run "$prefix" 'ls -1 /etc/cron.d 2>/dev/null; echo "--- user crontab ---"; crontab -l 2>/dev/null')"; rc=$?
            if [ "$rc" -ne 0 ]; then
                print_error "UNREACHABLE: could not list cron on $name — this is NOT 'no schedules'"
                return 3
            fi
            printf '%s\n' "$out"
            ;;
        install|remove)
            local id="" expr="" cmd="" execute=0 a
            for a in "$@"; do
                case "$a" in
                    --name=*)     id="${a#--name=}" ;;
                    --schedule=*) expr="${a#--schedule=}" ;;
                    --command=*)  cmd="${a#--command=}" ;;
                    --execute)    execute=1 ;;
                esac
            done
            [[ "$id" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || {
                print_error "--name must be [a-z0-9-] (got: '${id}')"; return 2; }
            if [ "$action" = "install" ]; then
                [ -n "$expr" ] && [ -n "$cmd" ] || {
                    print_error "install needs --schedule and --command"; return 2; }
                [[ "$cmd" == /* ]] || {
                    print_error "--command must be an ABSOLUTE path (cron has no useful PATH)"; return 2; }
            fi
            local file="/etc/cron.d/nwp-${id}"
            echo "  target : $name"
            echo "  file   : $file"
            [ "$action" = "install" ] && {
                echo "  content: SHELL=/bin/bash"
                echo "           PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                echo "           ${expr} root ${cmd}"
            }
            if [ "$execute" -eq 0 ]; then
                echo ""
                print_warning "DRY RUN — nothing was written to $name. Re-run with --execute."
                return 0
            fi
            print_error "pl host schedule --execute is not enabled in this release."
            print_hint "The declared entry is above; an operator installs it and records it."
            return 1
            ;;
        *)
            print_error "unknown action: $action (list|install|remove)"; return 2 ;;
    esac
}

main() {
    case "${1:-}" in
        ""|-h|--help)  show_help ;;
        --list|list)   list_all ;;
        --aliases)     list_aliases ;;
        capture)  shift; cmd_capture "$@" ;;
        diff)     shift; cmd_diff "$@" ;;
        apply)    shift; cmd_apply "$@" ;;
        schedule) shift; cmd_schedule "$@" ;;
        *)             resolve "$1" ;;   # --all is implied (all bound hosts printed)
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
