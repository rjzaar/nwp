#!/usr/bin/env bash
#
# lib/php-floor.sh — the engine behind `pl host apply <host> --kind=php`.
#
# WHY THIS FILE EXISTS
# --------------------
# On 2026-07-26 a Moodle course-edit form blew the `max_input_vars` ceiling and
# took the site down. The remedy — `max_input_vars = 5000` — was applied by hand
# to PHP **8.3**. Moodle runs on **8.2** (`ss.conf`/`ssd.conf` pass to
# `php8.2-fpm.sock`; Moodle cron runs `/usr/bin/php8.2`), so the fix was never in
# force, and every subsequent grep for "max_input_vars" found 5000 and concluded
# the matter was handled.
#
# `pl server-state php-check` (item 7) made that measurable: it asserts the value
# on the SAPI the site actually uses, and it goes RED. What did not exist was a
# verb that could make it GREEN. `servers/<host>/php/conf.d/90-nwp-moodle.ini`
# was written as DECLARED state carrying an explicit "NOT YET APPLIED" header,
# because `pl host apply --execute` was disabled (rollback-registry CP-I6).
#
# So the declared remedy could only ever reach a box by hand — and on
# 2026-08-01 that is exactly what happened on the `live` box: `scp` + `sudo cp`,
# the precise pl-first violation CLAUDE.md's standing order forbids. No backup
# was recorded by any verb, no post-write measurement was taken, nothing would
# have caught the write silently not taking effect, and no rollback row named
# the file. This file closes that gap.
#
# WHAT IT GUARANTEES (each one is a defect this estate has actually suffered)
# --------------------------------------------------------------------------
#  1. DRY-RUN BY DEFAULT. The plan prints the exact unified diff between the
#     declared ini and the bytes currently on the box, per host AND per SAPI.
#  2. IT MEASURES, IT DOES NOT GREP. The floor's value is read by ASKING the
#     target SAPI's own interpreter with that SAPI's ini scan dir
#     (`PHP_INI_SCAN_DIR=/etc/php/<v>/<sapi>/conf.d php<v> -c …/php.ini`), not
#     by grepping "is 5000 set anywhere on this box".
#  3. FAIL CLOSED ON BLINDNESS. A host that cannot be reached, a SAPI whose
#     conf.d directory does not exist, or a value that cannot be parsed is
#     CANNOT-MEASURE / SAPI-ABSENT with a non-zero exit — never "applied".
#     The SAPI-ABSENT case is the one the declared ini's own header names: a
#     PHP minor-version upgrade moves `/etc/php/8.2/…` to `/etc/php/8.4/…` and
#     the floor's remedy silently stops existing.
#  4. EVERY REPLACED FILE IS BACKED UP, WITH ITS sha256, on the box, before the
#     write, at a path the verb prints (so the rollback row can be honest).
#  5. IT RE-MEASURES AFTERWARDS and refuses to report success unless the floor
#     is in force *after* the reload. A write that lands in a conf.d PHP does
#     not scan is indistinguishable from a write that worked, until an outage.
#  6. IT RELOADS ONLY THE AFFECTED SERVICE, once per PHP version, and only when
#     an fpm SAPI was actually written. A failed reload is auto-rolled-back
#     from the backup taken in (4) and re-reloaded.
#  7. IT REFUSES ON A BOX WITH NO HEADROOM. `--execute` runs the same
#     `host_health_require` preflight CLAUDE.md mandates: an fpm reload on the
#     3.8 GB forge box is not free (2026-07-25, 5-8 min OOM outage).
#
# NOTHING FROM ARGV REACHES A REMOTE SHELL. Every interpolated component comes
# from the tracked inventory and is validated against a strict pattern first
# (`_pf_valid`); the file CONTENT is transported base64-encoded, so no quoting
# accident in a declared ini can become a remote command.
#
# Env:
#   NWP_SERVERS_DIR / NWP_DIR   where servers/<host>/ is read from (see
#                               lib/host-capture.sh — same precedence)

[ -n "${_NWP_PHP_FLOOR_SOURCED:-}" ] && return 0
_NWP_PHP_FLOOR_SOURCED=1

_PF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$_PF_LIB_DIR/.." && pwd)}"

declare -F print_status  >/dev/null 2>&1 || { . "$_PF_LIB_DIR/ui.sh"; }
declare -F host_run      >/dev/null 2>&1 || { . "$_PF_LIB_DIR/host-capture.sh"; }
declare -F impact_render >/dev/null 2>&1 || { . "$_PF_LIB_DIR/impact.sh"; }

# Where a replaced conf.d file is preserved on the box. Root-owned, outside
# /etc/php so a PHP package upgrade cannot sweep it away, and outside the
# conf.d scan dir so a `.bak` can never itself be loaded as an ini.
PF_BACKUP_DIR="${NWP_PHP_FLOOR_BACKUP_DIR:-/var/backups/nwp-php-floor}"

_pf_servers_dir() { printf '%s' "${HOST_SERVERS_DIR:-${NWP_SERVERS_DIR:-${NWP_DIR:-$PF_PROJECT_ROOT}/servers}}"; }
_pf_inv()         { printf '%s/%s/system/inventory.yml' "$(_pf_servers_dir)" "$1"; }

################################################################################
# Declaration validation. A declared component that does not match these
# patterns is a BUG IN THE INVENTORY, and the only safe response is to refuse:
# these strings are the only things this file ever interpolates into a remote
# shell or a PHP one-liner.
################################################################################
_pf_valid() {
    local ver="$1" sapi="$2" setting="$3" base="$4"
    [[ "$ver"     =~ ^[0-9]+\.[0-9]+$ ]]                  || return 1
    [[ "$sapi"    =~ ^(fpm|cli)$ ]]                       || return 1
    [[ "$setting" =~ ^[a-z_][a-z0-9_.]*$ ]]               || return 1
    [ -z "$base" ] || [[ "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.ini$ ]] || return 1
    return 0
}

################################################################################
# SSH destination.
#
# Resolved from the INVENTORY's `ssh_role` first, exactly as `pl server-state`
# does, because that is what makes the verb work from a git worktree or a
# release checkout where the gitignored servers/<host>/.nwp-server.yml is
# absent. Falls back to host_resolve_dest for hosts that have a server record
# but no inventory ssh_role. No hostname is ever written here (leakage gate).
################################################################################
_pf_dest() {
    local host="$1" inv role user hostname dest identity
    inv="$(_pf_inv "$host")"

    if [ -f "$inv" ] && command -v yq >/dev/null 2>&1; then
        role="$(yq e '.ssh_role // ""' "$inv" 2>/dev/null)"
        user="$(yq e '.ssh_user // ""' "$inv" 2>/dev/null)"
        [ "$role" = "null" ] && role=""
        [ "$user" = "null" ] && user=""
        if [ -n "$role" ]; then
            hostname="$(host_resolve_name "$role")"
            [ -n "$hostname" ] || return 1
            dest="" ; identity=""
            if [ -f "$HOST_MANIFEST" ]; then
                dest="$(h="$hostname" yq e '.ssh_targets[strenv(h)].dest // ""' "$HOST_MANIFEST" 2>/dev/null)"
                identity="$(h="$hostname" yq e '.ssh_targets[strenv(h)].identity // ""' "$HOST_MANIFEST" 2>/dev/null)"
            fi
            [ "$dest" = "null" ] && dest=""
            [ "$identity" = "null" ] && identity=""
            # A manifest ssh_targets entry already encodes the account; only
            # fall back to the inventory's ssh_user when it does not.
            [ -n "$dest" ] || dest="${user:+${user}@}${hostname}"
            if [ -n "$identity" ]; then
                printf 'ssh %s -o IdentitiesOnly=yes -i %s %s\n' "$HOST_SSH_OPTS" "${identity/#\~/$HOME}" "$dest"
            else
                printf 'ssh %s %s\n' "$HOST_SSH_OPTS" "$dest"
            fi
            return 0
        fi
    fi

    host_resolve_dest "$host"
}

################################################################################
# The probe. Fixed script; the only interpolated values are inventory-declared
# and `_pf_valid`-checked. Read-only and O(ms) — one stat, one sha256sum and
# one `php -r` per floor.
################################################################################
_pf_probe_script() {
    local ver="$1" sapi="$2" setting="$3" target="$4"
    cat <<EOF
set -u
V='${ver}'; S='${sapi}'; T='${target}'
CD="/etc/php/\$V/\$S/conf.d"
printf 'NWPPHPFLOOR v1\n'
printf 'confdir=%s\n' "\$CD"
if [ -d "\$CD" ]; then printf 'confdir_exists=yes\n'; else printf 'confdir_exists=no\n'; fi
if [ -f "\$T" ]; then
  printf 'file_exists=yes\n'
  printf 'file_sha256=%s\n' "\$(sha256sum "\$T" 2>/dev/null | awk '{print \$1}')"
else
  printf 'file_exists=no\n'
  printf 'file_sha256=-\n'
fi
B="/usr/bin/php\$V"
if [ -x "\$B" ] && [ -d "\$CD" ]; then
  printf 'binary=%s\n' "\$B"
  printf 'value=%s\n' "\$(PHP_INI_SCAN_DIR="\$CD" "\$B" -c "/etc/php/\$V/\$S/php.ini" \\
      -r 'echo ini_get("${setting}");' 2>/dev/null)"
else
  printf 'binary=-\n'
  printf 'value=-\n'
fi
if [ "\$S" = fpm ]; then
  printf 'service=php%s-fpm\n' "\$V"
  if systemctl cat "php\$V-fpm" >/dev/null 2>&1; then
    printf 'service_exists=yes\n'
  else
    printf 'service_exists=no\n'
  fi
else
  printf 'service=-\n'
  printf 'service_exists=-\n'
fi
printf '==NWPPHPFLOOR-FILE==\n'
[ -f "\$T" ] && cat "\$T"
exit 0
EOF
}

# _pf_probe <dest> <ver> <sapi> <setting> <target> -> raw probe output.
# Returns 3 when the host could not be read at all — NEVER treat that as clean.
_pf_probe() {
    local dest="$1" out rc
    shift
    out="$(host_run "$dest" "$(_pf_probe_script "$@")" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [[ "$out" != *"NWPPHPFLOOR v1"* ]]; then
        return 3
    fi
    printf '%s\n' "$out"
    return 0
}

# _pf_field <raw> <key>  — read one key=value from the probe header.
_pf_field() {
    printf '%s\n' "$1" | sed -n '/^==NWPPHPFLOOR-FILE==$/q;p' \
        | grep -m1 -E "^$2=" | cut -d= -f2-
}

# _pf_body <raw> — the remote file's content (empty when absent).
_pf_body() { printf '%s\n' "$1" | sed -n '/^==NWPPHPFLOOR-FILE==$/,$p' | tail -n +2; }

################################################################################
# The write. base64 in, `sudo -n install` out, backup first.
################################################################################
_pf_write_script() {
    local target="$1" b64="$2" backup="$3"
    cat <<EOF
set -u
T='${target}'; BK='${backup}'
CD="\$(dirname "\$T")"
[ -d "\$CD" ] || { printf 'ERR confdir-missing %s\n' "\$CD"; exit 5; }
TMP="\$(mktemp)" || { printf 'ERR no-tmp\n'; exit 6; }
printf '%s' '${b64}' | base64 -d > "\$TMP" || { rm -f "\$TMP"; printf 'ERR decode-failed\n'; exit 7; }
if [ -f "\$T" ]; then
  sudo -n mkdir -p '${PF_BACKUP_DIR}' || { rm -f "\$TMP"; printf 'ERR backup-dir\n'; exit 8; }
  sudo -n cp -a "\$T" "\$BK"          || { rm -f "\$TMP"; printf 'ERR backup-failed\n'; exit 8; }
  printf 'backup=%s\n' "\$BK"
  printf 'backup_sha256=%s\n' "\$(sudo -n sha256sum "\$BK" 2>/dev/null | awk '{print \$1}')"
else
  printf 'backup=-\n'
  printf 'backup_sha256=-\n'
fi
sudo -n install -o root -g root -m 0644 "\$TMP" "\$T" || { rm -f "\$TMP"; printf 'ERR install-failed\n'; exit 9; }
rm -f "\$TMP"
printf 'installed=%s\n' "\$T"
printf 'installed_sha256=%s\n' "\$(sha256sum "\$T" 2>/dev/null | awk '{print \$1}')"
exit 0
EOF
}

_pf_reload_script() {
    local svc="$1"
    cat <<EOF
set -u
sudo -n systemctl reload '${svc}' 2>&1 || { printf 'ERR reload-failed %s\n' '${svc}'; exit 3; }
printf 'reloaded=%s\n' '${svc}'
exit 0
EOF
}

# Undo one write. With a backup, restore it; without one (the file did not
# exist before), remove what we installed. Either way the box returns to the
# state the probe measured.
_pf_restore_script() {
    local target="$1" backup="$2"
    cat <<EOF
set -u
T='${target}'; BK='${backup}'
if [ "\$BK" != "-" ] && sudo -n test -f "\$BK"; then
  sudo -n install -o root -g root -m 0644 "\$BK" "\$T" || { printf 'ERR restore-failed\n'; exit 4; }
  printf 'restored=%s\n' "\$T"
else
  sudo -n rm -f "\$T" || { printf 'ERR remove-failed\n'; exit 4; }
  printf 'removed=%s\n' "\$T"
fi
exit 0
EOF
}

################################################################################
# php_floor_run <target> [--execute] [-y|--yes]
#
# Exit codes — each is a DIFFERENT verdict and they are never conflated:
#   0  in sync, or a dry-run plan was produced
#   1  applied but the floor is STILL not in force (or a write/reload failed)
#   2  the DECLARATION is unusable (no inventory, bad sapi, missing ini file)
#   3  UNREACHABLE / CANNOT-MEASURE — blindness, never "clean"
#   4  SAPI-ABSENT — the box has no such conf.d; the declaration names a SAPI
#      this host does not have (the PHP-minor-upgrade regression)
################################################################################
php_floor_run() {
    local target="${1:-}"; shift || true
    local execute=0 auto=false a
    for a in "$@"; do
        case "$a" in
            --execute) execute=1 ;;
            -y|--yes)  auto=true ;;
        esac
    done

    local host inv
    host="$(host_resolve_name "$target")"
    inv="$(_pf_inv "$host")"
    if [ ! -f "$inv" ]; then
        print_error "no inventory for '${host}': ${inv}"
        print_hint  "php floors are declared in servers/<host>/system/inventory.yml"
        return 2
    fi
    command -v yq >/dev/null 2>&1 || { print_error "yq is required (go-yq / mikefarah)"; return 2; }

    local n; n="$(yq e '.php_floors // [] | length' "$inv")"
    if [ "${n:-0}" -eq 0 ]; then
        print_info "no php_floors declared for ${host} — nothing for --kind=php to apply"
        return 0
    fi

    local dest
    dest="$(_pf_dest "$host")" || { print_error "cannot resolve an ssh destination for '${host}'"; return 3; }

    print_header "PHP floors — ${host}"

    # -- Plan ---------------------------------------------------------------
    # Parallel arrays, one slot per declared floor.
    local -a f_sapi=() f_set=() f_min=() f_why=() f_ini=() f_remote=() f_state=()
    local -a f_svc=() f_declsha=() f_livesha=() f_value=() f_diff=()
    local worst=0 pending=0 i

    for ((i = 0; i < n; i++)); do
        local sapi setting min why ini ver sname base remote declared declsha
        sapi="$(i="$i"    yq e ".php_floors[strenv(i)|tonumber].sapi"          "$inv")"
        setting="$(i="$i" yq e ".php_floors[strenv(i)|tonumber].setting"       "$inv")"
        min="$(i="$i"     yq e ".php_floors[strenv(i)|tonumber].min"           "$inv")"
        why="$(i="$i"     yq e ".php_floors[strenv(i)|tonumber].why // \"\""   "$inv")"
        ini="$(i="$i"     yq e ".php_floors[strenv(i)|tonumber].declared_ini // \"\"" "$inv")"

        ver="${sapi%%/*}"; sname="${sapi##*/}"
        base=""; remote=""; declared=""; declsha="-"
        if [ -n "$ini" ]; then
            base="$(basename "$ini")"
            declared="$(_pf_servers_dir)/${host}/${ini}"
        fi

        if ! _pf_valid "$ver" "$sname" "$setting" "$base"; then
            print_status "FAIL" "BAD-DECLARATION ${sapi} ${setting} — refusing to build a remote command from it"
            [ "$worst" -lt 2 ] && worst=2
            f_sapi+=("$sapi"); f_set+=("$setting"); f_min+=("$min"); f_why+=("$why")
            f_ini+=(""); f_remote+=(""); f_state+=("BAD-DECLARATION"); f_svc+=("-")
            f_declsha+=("-"); f_livesha+=("-"); f_value+=("-"); f_diff+=("")
            continue
        fi

        if [ -n "$ini" ]; then
            if [ ! -f "$declared" ]; then
                print_status "FAIL" "DECLARED-INI-MISSING ${sapi} — inventory names ${ini}, which is not in the repo"
                [ "$worst" -lt 2 ] && worst=2
                f_sapi+=("$sapi"); f_set+=("$setting"); f_min+=("$min"); f_why+=("$why")
                f_ini+=("$ini"); f_remote+=(""); f_state+=("DECLARED-INI-MISSING"); f_svc+=("-")
                f_declsha+=("-"); f_livesha+=("-"); f_value+=("-"); f_diff+=("")
                continue
            fi
            remote="/etc/php/${ver}/${sname}/conf.d/${base}"
            declsha="$(sha256sum "$declared" | awk '{print $1}')"
        fi

        local raw
        if ! raw="$(_pf_probe "$dest" "$ver" "$sname" "$setting" "${remote:-/dev/null}")"; then
            print_status "FAIL" "UNREACHABLE ${sapi} ${setting} — could not read the host; this is NOT 'in force'"
            [ "$worst" -lt 3 ] && worst=3
            f_sapi+=("$sapi"); f_set+=("$setting"); f_min+=("$min"); f_why+=("$why")
            f_ini+=("$ini"); f_remote+=("$remote"); f_state+=("UNREACHABLE"); f_svc+=("-")
            f_declsha+=("$declsha"); f_livesha+=("-"); f_value+=("-"); f_diff+=("")
            continue
        fi

        local cd_ok value livesha svc state diff
        cd_ok="$(_pf_field "$raw" confdir_exists)"
        value="$(_pf_field "$raw" value)"
        livesha="$(_pf_field "$raw" file_sha256)"
        svc="$(_pf_field "$raw" service)"
        diff=""

        if [ "$cd_ok" != "yes" ]; then
            # THE PHP-MINOR-UPGRADE REGRESSION. /etc/php/8.2 is gone because the
            # box moved to 8.4: the declared remedy now has nowhere to live and
            # the floor cannot be in force. Creating the directory would install
            # a setting into a SAPI that does not exist, which is worse than the
            # bug — so this fails closed and asks for the DECLARATION to move.
            state="SAPI-ABSENT"
            [ "$worst" -lt 4 ] && worst=4
        elif ! [[ "$value" =~ ^[0-9]+$ ]]; then
            state="CANNOT-MEASURE"
            [ "$worst" -lt 3 ] && worst=3
        elif [ "$value" -lt "$min" ]; then
            state="BELOW-FLOOR"
            pending=$((pending + 1))
        elif [ -z "$ini" ]; then
            # Asserted but with no declared remedy: satisfied today, unowned.
            state="IN-FORCE-UNMANAGED"
        elif [ "$livesha" = "$declsha" ]; then
            state="IN-SYNC"
        else
            # The floor holds, but not from the file this repo declares — the
            # 2026-08-01 hand-placed-by-scp shape. Bring it under management.
            state="FILE-DRIFT"
            pending=$((pending + 1))
        fi

        if [ -n "$ini" ] && [ "$state" != "SAPI-ABSENT" ] && [ "$state" != "IN-SYNC" ]; then
            local livetmp; livetmp="$(mktemp)"
            _pf_body "$raw" > "$livetmp"
            diff="$(diff -u --label "${host}:${remote} (live)" "$livetmp" \
                            --label "${ini} (declared)" "$declared" 2>/dev/null || true)"
            rm -f "$livetmp"
        fi

        f_sapi+=("$sapi"); f_set+=("$setting"); f_min+=("$min"); f_why+=("$why")
        f_ini+=("$ini"); f_remote+=("$remote"); f_state+=("$state"); f_svc+=("$svc")
        f_declsha+=("$declsha"); f_livesha+=("$livesha"); f_value+=("$value"); f_diff+=("$diff")
    done

    _pf_report f_sapi f_set f_min f_why f_ini f_remote f_state f_value f_diff "$host"

    if [ "$worst" -ge 2 ]; then
        echo ""
        case "$worst" in
            2) print_error "refusing: the DECLARATION could not be used (see above)" ;;
            3) print_error "refusing: the host's current state could not be measured — blindness is not 'in force'" ;;
            4) print_error "refusing: a declared SAPI does not exist on this host"
               print_hint  "A PHP minor-version upgrade moves /etc/php/<v>/…; update php_floors[].sapi in"
               print_hint  "servers/${host}/system/inventory.yml to the version the sites now run, then re-run." ;;
        esac
        return "$worst"
    fi

    if [ "$pending" -eq 0 ]; then
        echo ""
        print_success "every declared floor is in force and managed by this verb — nothing to apply"
        print_hint "assert it independently with: pl server-state php-check ${host}"
        return 0
    fi

    # -- Dry run ------------------------------------------------------------
    if [ "$execute" -eq 0 ]; then
        echo ""
        print_warning "DRY RUN — nothing was written to ${host}."
        echo "  ${pending} floor(s) would be changed. Re-run with --execute (you will be"
        echo "  asked to type the host name; -y skips only that prompt, never the report,"
        echo "  the health preflight, the backup or the post-apply re-measurement)."
        return 0
    fi

    # -- Execute ------------------------------------------------------------
    # FATE MANIFEST first, unconditionally (lib/impact.sh, ops#143 [G9]).
    impact_reset
    for ((i = 0; i < ${#f_state[@]}; i++)); do
        case "${f_state[$i]}" in
            BELOW-FLOOR|FILE-DRIFT) ;;
            *) continue ;;
        esac
        if [ "${f_livesha[$i]}" = "-" ]; then
            impact_keep "${host}:${f_remote[$i]} does not exist yet — it will be CREATED, nothing is replaced"
        else
            impact_overwrite "${host} conf.d" "${f_remote[$i]} (backed up to ${PF_BACKUP_DIR}/ first, sha256 recorded)"
        fi
        [ "${f_svc[$i]}" != "-" ] && impact_overwrite "reload" "${f_svc[$i]} (reload, not restart — no worker is killed)"
    done
    impact_keep "every site's code, database, uploads and vhost — this verb writes ONLY php conf.d files"
    impact_keep "every other setting in the SAPI: the declared ini contains the floor and nothing else"
    impact_render

    if ! impact_confirm typed "$host" "$auto" \
        "WRITES TO A LIVE BOX. Reversible: the replaced file is preserved on ${host} under ${PF_BACKUP_DIR}/ (path + sha256 printed below)."; then
        print_error "confirmation did not match — nothing applied"
        return 1
    fi

    # HEADROOM PREFLIGHT. An fpm reload on a 3.8 GB box that also runs GitLab is
    # not free; on 2026-07-25 a heavy op there OOM-killed prod for 5-8 minutes.
    # Blindness is also a refusal.
    if ! host_health_require "$dest" "" "pl host apply --kind=php on ${host}"; then
        print_error "refusing to apply — the host has no measurable headroom for an fpm reload"
        return 3
    fi

    local stamp; stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local -a reload_svcs=() undo_target=() undo_backup=()
    local rc=0

    for ((i = 0; i < ${#f_state[@]}; i++)); do
        case "${f_state[$i]}" in BELOW-FLOOR|FILE-DRIFT) ;; *) continue ;; esac

        local declared b64 backup out
        declared="$(_pf_servers_dir)/${host}/${f_ini[$i]}"
        b64="$(base64 -w0 < "$declared")"
        backup="${PF_BACKUP_DIR}/$(basename "${f_remote[$i]}").${f_sapi[$i]//\//-}.${stamp}.bak"

        if ! out="$(host_run "$dest" "$(_pf_write_script "${f_remote[$i]}" "$b64" "$backup")" 2>&1)"; then
            print_status "FAIL" "WRITE-FAILED ${f_sapi[$i]} ${f_remote[$i]}"
            printf '      %s\n' "$out"
            rc=1; continue
        fi
        local got_backup got_sha
        got_backup="$(printf '%s\n' "$out" | grep -m1 '^backup=' | cut -d= -f2-)"
        got_sha="$(printf '%s\n' "$out" | grep -m1 '^installed_sha256=' | cut -d= -f2-)"
        print_status "OK" "wrote ${f_remote[$i]} (sha256 ${got_sha:0:16}…)"
        if [ "$got_backup" != "-" ]; then
            printf '      backup: %s (sha256 %s)\n' "$got_backup" \
                "$(printf '%s\n' "$out" | grep -m1 '^backup_sha256=' | cut -d= -f2- | cut -c1-16)…"
        else
            printf '      backup: none — the file did not exist; undo is `sudo rm -f %s`\n' "${f_remote[$i]}"
        fi
        undo_target+=("${f_remote[$i]}"); undo_backup+=("$got_backup")

        if [ "${f_svc[$i]}" != "-" ]; then
            local seen=0 s
            for s in "${reload_svcs[@]:-}"; do [ "$s" = "${f_svc[$i]}" ] && seen=1; done
            [ "$seen" -eq 0 ] && reload_svcs+=("${f_svc[$i]}")
        fi
    done

    # -- Reload, with auto-rollback if the service refuses the new config ----
    local svc
    for svc in "${reload_svcs[@]:-}"; do
        [ -n "$svc" ] || continue
        local out
        if out="$(host_run "$dest" "$(_pf_reload_script "$svc")" 2>&1)"; then
            print_status "OK" "reloaded ${svc}"
        else
            print_status "FAIL" "RELOAD-FAILED ${svc} — rolling the conf.d writes back"
            printf '      %s\n' "$out"
            local j
            for ((j = 0; j < ${#undo_target[@]}; j++)); do
                host_run "$dest" "$(_pf_restore_script "${undo_target[$j]}" "${undo_backup[$j]}")" >/dev/null 2>&1 \
                    && print_status "OK" "restored ${undo_target[$j]}" \
                    || print_status "FAIL" "COULD NOT RESTORE ${undo_target[$j]} — restore by hand from ${undo_backup[$j]}"
            done
            host_run "$dest" "$(_pf_reload_script "$svc")" >/dev/null 2>&1 || true
            return 1
        fi
    done

    # -- Re-measure. THE POINT OF THE VERB ----------------------------------
    # A write that landed in a directory PHP does not scan looks exactly like a
    # write that worked. Success is a measurement, not an absence of errors.
    echo ""
    print_header "Post-apply verification — ${host}"
    local verified=0 failed=0
    for ((i = 0; i < ${#f_state[@]}; i++)); do
        case "${f_state[$i]}" in BELOW-FLOOR|FILE-DRIFT) ;; *) continue ;; esac
        local ver2 sname2 raw2 val2 sha2
        ver2="${f_sapi[$i]%%/*}"; sname2="${f_sapi[$i]##*/}"
        if ! raw2="$(_pf_probe "$dest" "$ver2" "$sname2" "${f_set[$i]}" "${f_remote[$i]}")"; then
            print_status "FAIL" "CANNOT-VERIFY ${f_sapi[$i]} — the host went unreadable AFTER the write"
            failed=$((failed + 1)); continue
        fi
        val2="$(_pf_field "$raw2" value)"
        sha2="$(_pf_field "$raw2" file_sha256)"
        if ! [[ "$val2" =~ ^[0-9]+$ ]]; then
            print_status "FAIL" "CANNOT-VERIFY ${f_sapi[$i]} ${f_set[$i]} — value unreadable after the write"
            failed=$((failed + 1)); continue
        fi
        if [ "$val2" -lt "${f_min[$i]}" ]; then
            print_status "FAIL" "DID-NOT-TAKE ${f_sapi[$i]} ${f_set[$i]}=${val2}, still below ${f_min[$i]}"
            printf '      the file was written but the SAPI does not see it. Undo: sudo rm -f %s\n' "${f_remote[$i]}"
            failed=$((failed + 1)); continue
        fi
        if [ "$sha2" != "${f_declsha[$i]}" ]; then
            print_status "FAIL" "CONTENT-MISMATCH ${f_sapi[$i]} — on-box sha256 differs from the declared ini after the write"
            failed=$((failed + 1)); continue
        fi
        print_status "OK" "${f_sapi[$i]} ${f_set[$i]}=${val2} (>= ${f_min[$i]}), file matches ${f_ini[$i]}"
        verified=$((verified + 1))
    done

    echo ""
    if [ "$failed" -gt 0 ] || [ "$rc" -ne 0 ]; then
        print_error "${failed} floor(s) NOT in force after apply — NOT reporting success"
        print_hint "Backups are under ${PF_BACKUP_DIR}/ on ${host} (paths printed above)."
        return 1
    fi
    print_success "${verified} floor(s) applied and RE-MEASURED in force on ${host}"
    print_hint "assert it independently with: pl server-state php-check ${host}"
    print_hint "record it with: pl rollback register"
    return 0
}

# _pf_report <7 array names> <host> — the per-host, per-SAPI plan.
_pf_report() {
    local -n _sapi="$1" _set="$2" _min="$3" _why="$4" _ini="$5" _rem="$6" _st="$7" _val="$8" _dif="$9"
    local host="${10}"
    local i
    for ((i = 0; i < ${#_st[@]}; i++)); do
        local badge
        case "${_st[$i]}" in
            IN-SYNC)            badge=OK ;;
            IN-FORCE-UNMANAGED) badge=WARN ;;
            *)                  badge=FAIL ;;
        esac
        print_status "$badge" "${_st[$i]}  ${_sapi[$i]} ${_set[$i]} = ${_val[$i]:--} (floor ${_min[$i]})"
        [ -n "${_rem[$i]}" ] && printf '      file  : %s:%s\n' "$host" "${_rem[$i]}"
        case "${_st[$i]}" in
            IN-FORCE-UNMANAGED)
                printf '      note  : satisfied today, but no declared_ini owns it — the next\n'
                printf '              package upgrade can remove it and nothing will restore it.\n' ;;
            FILE-DRIFT)
                printf '      note  : the floor holds, but NOT from the file this repo declares.\n' ;;
            SAPI-ABSENT)
                printf '      note  : /etc/php/%s/conf.d does not exist on this host.\n' "${_sapi[$i]}" ;;
        esac
        [ -n "${_why[$i]}" ] && printf '      why   : %s\n' "${_why[$i]}"
        if [ -n "${_dif[$i]}" ]; then
            printf '      diff  :\n'
            printf '%s\n' "${_dif[$i]}" | sed 's/^/        /'
        fi
    done
    # Explicit: the loop's last command may be a false `[ … ] &&` test, and this
    # library is sourced into scripts running `set -e`.
    return 0
}
