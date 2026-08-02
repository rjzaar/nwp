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
#   pl host apply   <target> [--kind=K] [--execute]   dry-run by default;
#                                                     --kind=php IS executable
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
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/php-floor.sh"

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
  pl host apply   <target> --kind=php [--execute]  put a DECLARED php setting floor
  pl host apply   <target> --kind=gitlab [--execute]  put DECLARED GitLab tunables
                                                   in force, reconfigure, re-measure
                                                   in force, then re-measure it
  pl host apply   <target> [--kind=K]         other kinds: dry-run / declare-only
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

# pl host apply — dry-run DEFAULT.
#
# `--kind=php` IS EXECUTABLE; every other kind is still declare-only.
#
# That asymmetry is deliberate and is the whole of this verb's 2026-08-02
# change. Item 6 shipped `apply` with `--execute` disabled across the board
# (rollback-registry CP-I6), which was the right call for `cron`/`nginx`/`ssh`
# — pushing a whole captured tree back at a box that serves every live site is
# operator work, and the capture is identity-redacted, so it is a faithful
# RECORD and not a byte-restorable backup.
#
# A php SETTING FLOOR is a different shape of thing, and the difference is what
# makes it safe to automate:
#   * it is DECLARED, not captured — `servers/<h>/php/conf.d/*.ini` is authored
#     and reviewed, so there is no redaction round-trip to lose;
#   * it is ADDITIVE and single-purpose — one conf.d file containing one floor;
#   * it is MEASURABLE after the fact — the verb asks the target SAPI what it
#     now believes, so "applied" is a reading, not an assumption;
#   * and leaving it un-automated has a proven cost: the declared remedy sat
#     "NOT YET APPLIED" from 2026-07-26, and on 2026-08-01 it reached the live
#     box by `scp` + `sudo cp` instead — with no backup, no verification and no
#     rollback row. A gap you route around stays a gap forever.
#
# See lib/php-floor.sh for the engine and its seven guarantees.
cmd_apply() {
    local target="${1:-}"; shift || true
    [ -n "$target" ] || { print_error "usage: pl host apply <target> [--kind=K] [--execute]"; return 2; }
    local execute=0 a
    for a in "$@"; do [ "$a" = "--execute" ] && execute=1; done
    local kinds; mapfile -t kinds < <(_parse_kinds "$@") || return 1

    local name; name="$(host_resolve_name "$target")"

    # --- the kinds this verb can actually put in force ----------------------
    # php (lib/php-floor.sh) and gitlab (lib/gitlab-tunables.sh). Both are
    # DECLARED-not-captured, additive, single-purpose and MEASURABLE afterwards,
    # which is the test for whether an apply is safe to automate. The rest stay
    # declare-only.
    local php_selected=0 gitlab_selected=0 rest=() k
    for k in "${kinds[@]}"; do
        case "$k" in
            php)    php_selected=1 ;;
            gitlab) gitlab_selected=1 ;;
            *)      rest+=("$k") ;;
        esac
    done

    local php_rc=0
    if [ "$php_selected" -eq 1 ]; then
        php_floor_run "$target" "$@" || php_rc=$?
        # An explicit --kind=php run is the floor run and nothing else.
        [ "${#rest[@]}" -eq 0 ] && [ "$gitlab_selected" -eq 0 ] && return "$php_rc"
        echo ""
    fi

    local gitlab_rc=0
    if [ "$gitlab_selected" -eq 1 ]; then
        if ! declare -F gitlab_tunables_run >/dev/null 2>&1; then
            # shellcheck source=/dev/null
            source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/gitlab-tunables.sh"
        fi
        gitlab_tunables_run "$target" "$@" || gitlab_rc=$?
        [ "${#rest[@]}" -eq 0 ] && return "$(( php_rc > gitlab_rc ? php_rc : gitlab_rc ))"
        echo ""
    fi

    # --- every other kind: declare-only, exactly as before ------------------
    kinds=("${rest[@]}")
    print_header "pl host apply — $name"
    local rc=0
    host_diff "$target" "${kinds[@]}" || rc=$?

    if [ "$rc" -ge 2 ]; then
        print_error "refusing to apply: the host's current state could not be read (rc=$rc)"
        return "$rc"
    fi
    if [ "$rc" -eq 0 ]; then
        print_success "nothing to apply — host already matches the repo"
        return "$php_rc"
    fi

    if [ "$execute" -eq 0 ]; then
        echo ""
        print_warning "DRY RUN — nothing was written to $name."
        echo "  The lines marked '+' above are what the repo would install."
        echo "  Re-run with --execute to apply (you will be asked to type the host name)."
        echo ""
        print_hint "On a box that serves live sites, hand this diff to the operator instead."
        print_hint "--kind=php IS executable: pl host apply $name --kind=php --execute"
        return "$php_rc"
    fi

    # --execute: typed confirmation, pre-state snapshot, rollback registry row.
    print_warning "About to overwrite host state on '$name' from the repo."
    printf "Type the host name to continue: "
    local typed=""; read -r typed || true
    if [ "$typed" != "$name" ]; then
        print_error "confirmation did not match — nothing applied"
        return 1
    fi
    print_error "pl host apply --execute is not enabled for kind(s): ${kinds[*]}"
    print_hint "Only --kind=php is executable (lib/php-floor.sh); the rest are declare-only."
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
                # Validate BEFORE writing. A malformed /etc/cron.d entry is not
                # rejected loudly by cron — it is skipped, silently, and the
                # schedule you believe you installed never runs. Five or six
                # fields, and nothing outside cron's own vocabulary.
                local nfields; nfields="$(printf '%s\n' "$expr" | awk '{print NF}')"
                [[ "$nfields" == "5" || "$nfields" == "6" ]] || {
                    print_error "--schedule must have 5 (or 6, with year) fields (got ${nfields}: '${expr}')"; return 2; }
                [[ "$expr" =~ ^[0-9A-Za-z*/,\ -]+$ ]] || {
                    print_error "--schedule contains characters cron does not accept: '${expr}'"; return 2; }
                # The command is written into a quoted heredoc so the remote
                # shell never expands it, but a newline would forge a second
                # crontab line, and the delimiter would end the heredoc early.
                case "$cmd" in
                    *$'\n'*)      print_error "--command must be a single line"; return 2 ;;
                    *NWPCRONEOF*) print_error "--command may not contain the heredoc delimiter"; return 2 ;;
                esac
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
                print_hint "Re-run with --execute to write it."
                return 0
            fi

            # ── --execute ─────────────────────────────────────────────────────
            # Enabled 2026-08-02. It was previously a deliberate stub that told
            # the operator to install the entry by hand. That made every verb
            # needing a remote schedule un-completable through `pl`, which is how
            # box-level DR ended up with a nightly cron nobody could reinstall
            # from the repo. The write is a single managed file, idempotent,
            # read back and re-verified, with the cron DAEMON state reported
            # (ops#164: a cron file on a stopped daemon is not a schedule).
            local script rc=0
            if [ "$action" = "install" ]; then
                script="$(cat <<REMOTE
set -eu
umask 022
cat > /tmp/nwp-cron-${id}.tmp <<'NWPCRONEOF'
# Managed by NWP — pl host schedule install --name=${id}
# Edits here are overwritten on the next install. Remove with:
#   pl host schedule <target> remove --name=${id} --execute
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${expr} root ${cmd}
NWPCRONEOF
sudo -n install -m 644 -o root -g root /tmp/nwp-cron-${id}.tmp ${file}
rm -f /tmp/nwp-cron-${id}.tmp
echo "--- installed ---"
sudo -n cat ${file}
REMOTE
)"
            else
                script="$(cat <<REMOTE
set -eu
if sudo -n test -f ${file}; then sudo -n rm -f ${file}; echo "--- removed ${file} ---";
else echo "--- ${file} was not present ---"; fi
REMOTE
)"
            fi
            local out
            out="$(host_run "$prefix" "$script")" || rc=$?
            if [ "$rc" -ne 0 ]; then
                print_error "could not ${action} ${file} on ${name} (rc=${rc}) — nothing is confirmed"
                [ -n "$out" ] && printf '%s\n' "$out"
                return 1
            fi
            printf '%s\n' "$out" | sed 's/^/    /'

            # Verify by READING BACK, not by trusting the write's exit status.
            local check
            check="$(host_run "$prefix" "sudo -n test -f ${file} && echo PRESENT || echo ABSENT")" || check=""
            if [ "$action" = "install" ] && [ "$check" != "PRESENT" ]; then
                print_error "${file} is not present on ${name} after install — the schedule does NOT exist"; return 1
            fi
            if [ "$action" = "remove" ] && [ "$check" = "PRESENT" ]; then
                print_error "${file} is still present on ${name} after remove"; return 1
            fi

            if [ "$action" = "install" ]; then
                local daemon
                daemon="$(host_run "$prefix" 'systemctl is-active cron 2>/dev/null || systemctl is-active crond 2>/dev/null || echo unknown')" || daemon="unknown"
                case "$daemon" in
                    active) print_status "OK" "${name}: ${file} installed; cron daemon is active" ;;
                    unknown) print_warning "${name}: ${file} installed, but the cron daemon state could not be read — do NOT record this as scheduled until it can" ;;
                    *) print_error "${name}: ${file} installed but the cron daemon is '${daemon}' — this entry will NOT run"; return 1 ;;
                esac
            else
                print_status "OK" "${name}: ${file} removed"
            fi
            return 0
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
