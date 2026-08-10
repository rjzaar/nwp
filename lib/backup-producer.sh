#!/usr/bin/env bash
################################################################################
# lib/backup-producer.sh — install and MEASURE the nightly box backup producer.
#
# The engine behind `pl host apply <host> --kind=backup [--execute]` and the
# `backup` capture kind (nwp/ops#332).
#
# WHY THIS IS A VERB AND NOT A README STEP. The producer's own header used to
# say "Install (operator, once): sudo cp … && echo '30 1 …' | sudo tee …", i.e.
# it prescribed the exact `scp`-and-`sudo cp` idiom the pl-first standing order
# forbids and `lint:doc-truth`'s raw-remote-cli check fails runbooks for. The
# consequence was measurable: the two boxes had drifted to a script the repo
# could not diff, and the only reason anyone knew what was installed was that
# somebody had left a copy in /tmp. A leg that can only be deployed by hand is a
# leg that gets deployed by hand at 2 a.m. and never recorded.
#
# WHY IT IS SAFE TO AUTOMATE — the same four-part test `pl host apply --kind=php`
# had to pass (see scripts/commands/host.sh):
#   * DECLARED, not captured. servers/<h>/backup/nwp-box-backup.conf is authored
#     and reviewed; there is no redaction round-trip to lose.
#   * ADDITIVE and single-purpose. One script, one conf, one cron line.
#   * MEASURABLE afterwards. --execute RUNS the producer once and reads back the
#     verdict artefact it wrote. "Applied" is a reading, never an assumption.
#   * The un-automated version has a proven cost — nwp/ops#332 is that cost.
#
# ONE PRODUCER, MANY HOSTS. The per-host difference is the DECLARATION, never
# the code; that is the whole point of ops#332. So the script comes from a
# single canonical path and only the .conf is per-host, and a host with no
# declared conf is REFUSED rather than given a guessed one.
################################################################################

# Guard against double-sourcing.
[ -n "${NWP_BACKUP_PRODUCER_SH:-}" ] && return 0
NWP_BACKUP_PRODUCER_SH=1

BP_REMOTE_SCRIPT="${NWP_BP_REMOTE_SCRIPT:-/usr/local/sbin/nwp-box-backup.sh}"
BP_REMOTE_CONF="${NWP_BP_REMOTE_CONF:-/etc/nwp-box-backup.conf}"
BP_REMOTE_CRON="${NWP_BP_REMOTE_CRON:-/etc/cron.d/nwp-box-backup}"
BP_REMOTE_OUT="${NWP_BP_REMOTE_OUT:-/var/backups/nwp-pull}"
BP_CRON_LINE="${NWP_BP_CRON_LINE:-30 1 * * * root ${BP_REMOTE_SCRIPT}}"
# The heredoc sentinel used to carry file content over the wire. Content that
# contains this line is REFUSED rather than silently truncated.
BP_EOF="NWPBOXBACKUPEOF"

_bp_root() { printf '%s' "${NWP_BP_PROJECT_ROOT:-${PROJECT_ROOT:-${NWP_DIR:-$PWD}}}"; }

# The ONE canonical producer. Per-host difference is the conf, never the code.
backup_producer_source() { printf '%s/servers/nwpcode/backup/nwp-box-backup.sh' "$(_bp_root)"; }
backup_producer_conf()   { printf '%s/servers/%s/backup/nwp-box-backup.conf' "$(_bp_root)" "$1"; }

_bp_say()  { if declare -F print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '  %s\n' "$*"; fi; }
_bp_ok()   { if declare -F print_success >/dev/null 2>&1; then print_success "$*"; else printf '  OK: %s\n' "$*"; fi; }
_bp_warn() { if declare -F print_warning >/dev/null 2>&1; then print_warning "$*"; else printf '  WARN: %s\n' "$*"; fi; }
_bp_err()  { if declare -F print_error   >/dev/null 2>&1; then print_error   "$*"; else printf '  ERROR: %s\n' "$*" >&2; fi; }

# Build a remote script that writes <local-file> to <remote-path> with <mode>.
# A quoted heredoc, so the remote shell expands NOTHING in the payload — and the
# payload is written verbatim, so a reviewer of this MR sees exactly the bytes
# that reach the box (which base64 would have hidden).
_bp_put_script() { # <local-file> <remote-path> <mode>
    local src="$1" dst="$2" mode="$3"
    if grep -qxF "$BP_EOF" "$src"; then
        _bp_err "refusing to transfer ${src}: it contains the heredoc sentinel ${BP_EOF}"
        return 1
    fi
    printf 'set -eu\numask 022\ntmp="$(mktemp)"\n'
    printf "cat > \"\$tmp\" <<'%s'\n" "$BP_EOF"
    cat "$src"
    printf '%s\n' "$BP_EOF"
    # install(1) is atomic-ish and sets owner+mode in one step; a half-written
    # root cron script is worse than an old one.
    printf 'if [ -f %s ]; then sudo -n cp -a %s %s.bak-$(date -u +%%Y%%m%%dT%%H%%M%%SZ); fi\n' "$dst" "$dst" "$dst"
    printf 'sudo -n install -m %s -o root -g root "$tmp" %s\n' "$mode" "$dst"
    printf 'rm -f "$tmp"\n'
    printf 'printf "installed %%s\\n" %s\n' "$dst"
}

# The managed cron entry, written as a whole file so a re-install rewrites
# rather than duplicating (the same shape `pl host schedule` uses).
_bp_cron_script() {
    printf 'set -eu\n'
    printf "cat > /tmp/nwp-box-backup.cron <<'%s'\n" "$BP_EOF"
    printf '# managed by `pl host apply <host> --kind=backup` — do not edit on the box\n'
    printf 'SHELL=/bin/bash\n'
    printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    printf '%s\n' "$BP_CRON_LINE"
    printf '%s\n' "$BP_EOF"
    printf 'sudo -n install -m 0644 -o root -g root /tmp/nwp-box-backup.cron %s\n' "$BP_REMOTE_CRON"
    printf 'rm -f /tmp/nwp-box-backup.cron\n'
    printf 'printf "cron ok\\n"\n'
}

# Read the box's current state for the backup leg. Read-only; safe any time.
_bp_probe_script() {
    cat <<PROBE
set -u
printf 'NWPBACKUPSTATE v1\n'
if [ -r ${BP_REMOTE_SCRIPT} ]; then
  printf 'script_sha=%s\n' "\$(sha256sum ${BP_REMOTE_SCRIPT} 2>/dev/null | awk '{print \$1}')"
else
  printf 'script_sha=absent\n'
fi
if [ -r ${BP_REMOTE_CONF} ]; then
  printf 'conf_sha=%s\n' "\$(sha256sum ${BP_REMOTE_CONF} 2>/dev/null | awk '{print \$1}')"
  printf 'conf_db=%s\n'  "\$(sed -n 's/^[[:space:]]*SITE_DB_LEG[[:space:]]*=[[:space:]]*\([A-Za-z-]*\).*/\1/p' ${BP_REMOTE_CONF} | head -1)"
  printf 'conf_gitlab=%s\n' "\$(sed -n 's/^[[:space:]]*GITLAB_LEG[[:space:]]*=[[:space:]]*\([A-Za-z-]*\).*/\1/p' ${BP_REMOTE_CONF} | head -1)"
else
  printf 'conf_sha=absent\n'
fi
if [ -r ${BP_REMOTE_CRON} ]; then
  printf 'cron=%s\n' "\$(grep -v '^[[:space:]]*#' ${BP_REMOTE_CRON} | grep -c . )"
else
  printf 'cron=absent\n'
fi
if sudo -n cat ${BP_REMOTE_OUT}/backup-verdict.json 2>/dev/null | head -40; then :; else
  printf 'verdict=absent\n'
fi
PROBE
}

# backup_producer_state <ssh-prefix>  -> the raw probe block on stdout
# Returns 3 when the host could not be read. NEVER "no drift".
backup_producer_state() {
    local prefix="$1" out rc
    out="$(host_run "$prefix" "$(_bp_probe_script)" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [[ "$out" != *"NWPBACKUPSTATE"* ]]; then
        _bp_err "UNREACHABLE: could not read the backup state on this host (rc=${rc}) — this is NOT 'in sync'"
        return 3
    fi
    printf '%s\n' "$out"
}

_bp_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

################################################################################
# backup_producer_run <target> [--execute] [--no-run] [-y]
#
# Exit: 0 in sync / applied+verified · 1 refused or the post-apply run FAILED
#       2 CANNOT VERIFY (no declaration, unreadable verdict) · 3 host unreachable
################################################################################
backup_producer_run() {
    local target="${1:-}"; shift || true
    local execute=0 do_run=1 auto=0 a
    for a in "$@"; do
        case "$a" in
            --execute) execute=1 ;;
            --no-run)  do_run=0 ;;
            -y|--yes)  auto=1 ;;
        esac
    done
    [ -n "$target" ] || { _bp_err "usage: pl host apply <host> --kind=backup [--execute]"; return 2; }

    local name prefix src conf
    name="$(host_resolve_name "$target")"
    prefix="$(host_resolve_dest "$target")" || { _bp_err "cannot resolve target: $target"; return 3; }
    src="$(backup_producer_source)"
    conf="$(backup_producer_conf "$name")"

    if declare -F print_header >/dev/null 2>&1; then
        print_header "pl host apply — ${name} --kind=backup"
    else
        printf '\n== pl host apply — %s --kind=backup\n' "$name"
    fi

    [ -r "$src" ] || { _bp_err "the canonical producer is missing: $src"; return 2; }

    # FAIL CLOSED on an undeclared host. Installing the producer without a
    # declaration would leave the box in exactly the state ops#332 is about:
    # unable to tell "no leg here" from "the leg is broken".
    if [ ! -r "$conf" ]; then
        _bp_err "REFUSING: ${name} has no DECLARED backup legs."
        _bp_say "Expected: ${conf#$(_bp_root)/}"
        _bp_say "A host must SAY which legs it owns before the producer is installed —"
        _bp_say "otherwise 'this host has no site databases' and 'the database server is"
        _bp_say "down' are the same observation, which is nwp/ops#332."
        _bp_say "Write the file (copy servers/nwpcode/backup/nwp-box-backup.conf) and re-run."
        return 2
    fi

    local declared_db declared_gitlab
    declared_db="$(sed -n 's/^[[:space:]]*SITE_DB_LEG[[:space:]]*=[[:space:]]*\([A-Za-z-]*\).*/\1/p' "$conf" | head -1)"
    declared_gitlab="$(sed -n 's/^[[:space:]]*GITLAB_LEG[[:space:]]*=[[:space:]]*\([A-Za-z-]*\).*/\1/p' "$conf" | head -1)"
    case "$declared_db" in required|none) ;; *)
        _bp_err "REFUSING: ${conf#$(_bp_root)/} declares SITE_DB_LEG='${declared_db}' (want: required|none)"; return 2 ;;
    esac
    case "$declared_gitlab" in required|none) ;; *)
        _bp_err "REFUSING: ${conf#$(_bp_root)/} declares GITLAB_LEG='${declared_gitlab}' (want: required|none)"; return 2 ;;
    esac
    _bp_say "declared legs: SITE_DB_LEG=${declared_db}  GITLAB_LEG=${declared_gitlab}"

    # --- what is actually on the box right now -----------------------------
    local state; state="$(backup_producer_state "$prefix")" || return 3
    local box_script box_conf box_cron want_script want_conf
    box_script="$(_bp_field "$state" script_sha)"
    box_conf="$(_bp_field "$state" conf_sha)"
    box_cron="$(_bp_field "$state" cron)"
    want_script="$(sha256sum "$src"  | awk '{print $1}')"
    want_conf="$(sha256sum "$conf" | awk '{print $1}')"

    local drift=0
    if [ "$box_script" = "$want_script" ]; then _bp_ok "producer script in sync (${want_script:0:12})"
    else drift=1; _bp_warn "producer script DRIFT: box=${box_script:0:12} repo=${want_script:0:12}"; fi
    if [ "$box_conf" = "$want_conf" ]; then _bp_ok "declaration in sync (${want_conf:0:12})"
    else drift=1; _bp_warn "declaration DRIFT: box=${box_conf:0:12} repo=${want_conf:0:12}"; fi
    if [ "$box_cron" = "absent" ] || [ "${box_cron:-0}" = "0" ]; then
        drift=1; _bp_warn "cron DRIFT: ${BP_REMOTE_CRON} is absent or empty"
    else _bp_ok "cron present (${BP_REMOTE_CRON})"; fi

    if [ "$drift" -eq 0 ] && [ "$do_run" -eq 0 ]; then
        _bp_ok "nothing to apply — ${name} already matches the repo"
        return 0
    fi

    if [ "$execute" -eq 0 ]; then
        printf '\n'
        _bp_warn "DRY RUN — nothing was written to ${name}."
        _bp_say "would install ${src#$(_bp_root)/}  ->  ${BP_REMOTE_SCRIPT} (0755 root:root)"
        _bp_say "would install ${conf#$(_bp_root)/}  ->  ${BP_REMOTE_CONF} (0644 root:root)"
        _bp_say "would ensure  ${BP_REMOTE_CRON}: ${BP_CRON_LINE}"
        _bp_say "then RUN the producer once and read back ${BP_REMOTE_OUT}/backup-verdict.json"
        _bp_say "re-run with --execute"
        return 0
    fi

    # --- --execute ---------------------------------------------------------
    if [ "$auto" -eq 0 ]; then
        printf 'Type the host name to install the backup producer on it: '
        local typed=""; read -r typed || true
        [ "$typed" = "$name" ] || { _bp_err "confirmation did not match — nothing applied"; return 1; }
    fi

    # The producer runs mysqldump over every site DB and may run gitlab-backup.
    # That is heavy, and this estate has OOM-killed a 3.8 GB box before.
    if declare -F host_health_require >/dev/null 2>&1; then
        host_health_require "$prefix" 384 "installing and running the backup producer on '${name}'" || return $?
    fi

    local put rc
    put="$(_bp_put_script "$src" "$BP_REMOTE_SCRIPT" 0755)" || return 1
    host_run "$prefix" "$put" || { _bp_err "could not install ${BP_REMOTE_SCRIPT} on ${name}"; return 1; }
    put="$(_bp_put_script "$conf" "$BP_REMOTE_CONF" 0644)" || return 1
    host_run "$prefix" "$put" || { _bp_err "could not install ${BP_REMOTE_CONF} on ${name}"; return 1; }
    host_run "$prefix" "$(_bp_cron_script)" \
        || { _bp_err "could not write ${BP_REMOTE_CRON} on ${name}"; return 1; }
    _bp_ok "installed producer + declaration + cron on ${name}"

    [ "$do_run" -eq 1 ] || { _bp_warn "--no-run: NOT measured. 'installed' is not 'working'."; return 0; }

    # --- MEASURE. This is what makes 'applied' a reading. ------------------
    _bp_say "running the producer once on ${name} …"
    local out
    out="$(host_run "$prefix" "sudo -n ${BP_REMOTE_SCRIPT}; printf 'PRODUCER_EXIT=%s\\n' \$?" 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/    /'
    local prod_exit; prod_exit="$(printf '%s\n' "$out" | sed -n 's/^PRODUCER_EXIT=//p' | tail -1)"
    if [ -z "$prod_exit" ]; then
        _bp_err "CANNOT VERIFY: the producer run on ${name} returned no exit code (transport rc=${rc})"
        return 2
    fi
    local verdict; verdict="$(host_run "$prefix" "sudo -n cat ${BP_REMOTE_OUT}/backup-verdict.json" 2>/dev/null)"
    if [ -z "$verdict" ]; then
        _bp_err "CANNOT VERIFY: no ${BP_REMOTE_OUT}/backup-verdict.json after the run"
        return 2
    fi
    printf '%s\n' "$verdict" | sed 's/^/    /'
    case "$prod_exit" in
        0) _bp_ok "${name}: producer exit 0 — every declared leg ran"; return 0 ;;
        2) _bp_err "${name}: producer exit 2 CANNOT VERIFY — see the verdict above"; return 2 ;;
        *) _bp_err "${name}: producer exit ${prod_exit} FAILED — see the verdict above"; return 1 ;;
    esac
}
