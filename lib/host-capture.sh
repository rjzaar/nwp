#!/usr/bin/env bash
#
# lib/host-capture.sh — the engine behind `pl host`, `pl server health`,
# `pl server forge status`, `pl logs` and `pl loop --host`.
#
# WHY THIS EXISTS (fix-programme item 6, `pl-host`)
# ------------------------------------------------
# Before this file, no `pl` verb owned any host state:
#
#   * `pl server status` reported SSH reachability ONLY — no RAM, no disk, no
#     load. There was no working verb that answered "how much memory does this
#     box have left", which is exactly the preflight whose absence let a heavy
#     op OOM-kill the 3.8 GB gitlab-host box (the forge + 5 live sites) for
#     5-8 minutes on 2026-07-25.
#   * `lib/safe-ops.sh` — which CLAUDE.md instructed agents to `source` — had
#     ZERO callers and printed the names of root scripts that do not exist.
#     Dead code the standing orders point at reads as coverage.
#   * DR crons, nginx snippets, php.ini overrides, ufw rules and systemd units
#     existed only on boxes. `pl config export` could not rebuild a host.
#
# DESIGN RULES (all load-bearing — do not relax without a decision-log entry)
# --------------------------------------------------------------------------
#  1. READ-ONLY BY CONSTRUCTION. Capture, diff, health, logs and forge status
#     issue a FIXED set of commands. Nothing here interpolates operator input
#     into a remote shell. Only `host_apply` writes, and only with --execute.
#  2. FAIL CLOSED. A transport failure, a missing tool or a sudo refusal is
#     NEVER "no drift". It is CAPTURE-INCOMPLETE / UNREACHABLE with a non-zero
#     exit. Blindness must not be indistinguishable from health.
#  3. CHEAP. Every probe is O(ms) and allocation-free. NOTHING here may invoke
#     gitlab-rails, gitlab-rake, composer or a database dump — see rule 1's
#     motivating incident.
#  4. NO SECRET MATERIAL EVER LANDS IN THE REPO. Captured streams pass through
#     host_scrub_stream; authorized_keys is reduced to options+comments only.
#  5. NO HOSTNAME IS HARDCODED. Every destination comes from the tracked
#     servers/<name>/.nwp-server.yml or the operator's private instance
#     manifest (leakage gate).
#
# CAPTURE STREAM PROTOCOL v1
# --------------------------
# A remote probe writes a single stream. Multi-file captures separate members
# with a marker line:
#
#     ==NWPFILE== <relative/path>
#     <content ...>
#
# A stream with no marker is stored as one file: <kind>/<default file>.
# A probe that could not read something emits:
#
#     ==NWPINCOMPLETE== <what> <why>
#
# which makes capture and diff fail closed.

# Guard against double-source.
[ -n "${_NWP_HOST_CAPTURE_SOURCED:-}" ] && return 0
_NWP_HOST_CAPTURE_SOURCED=1

_HOST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$_HOST_LIB_DIR/.." && pwd)}"

# Where captured host state lives. Overridable for tests and for operators who
# keep servers/ outside the tool checkout.
#
# NWP_DIR IS HONOURED HERE TOO (ops#149). `NWP_DIR` is the documented root of
# the DECLARATIONS — lib/project-resolver.sh, lib/server-resolver.sh and
# scripts/commands/server.sh all read `${NWP_DIR:-$PROJECT_ROOT}` — while this
# file resolved the SSH ROUTE from PROJECT_ROOT alone. Setting NWP_DIR (which is
# what you do to run a checkout's code against the operator's inventory: a git
# worktree, a release candidate, CI) therefore half-worked: `pl server roots`
# found the site declarations and then could not resolve a destination for the
# very server they name, failing with ssh rc=255 — reported honestly as
# CANNOT-VERIFY, but for a reason that was ours, not the box's. Same precedence
# as everywhere else: explicit NWP_SERVERS_DIR wins, then NWP_DIR, then
# PROJECT_ROOT — so with neither set nothing changes.
HOST_SERVERS_DIR="${NWP_SERVERS_DIR:-${NWP_DIR:-$HOST_PROJECT_ROOT}/servers}"

# The private role -> hostname manifest (same file `pl host <role>` reads).
HOST_MANIFEST="${NWP_INSTANCE_MANIFEST:-$HOME/nwp-instances/instance-manifest.yml}"

HOST_SSH_OPTS=${HOST_SSH_OPTS:-"-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"}

# Headroom thresholds. Deliberately generous defaults: the estate's smallest
# box is 3.8 GB and already runs GitLab + 5 live sites.
HOST_MIN_MEM_MB="${NWP_HEALTH_MIN_MEM_MB:-512}"
HOST_MIN_DISK_MB="${NWP_HEALTH_MIN_DISK_MB:-2048}"
HOST_MAX_LOAD_PER_CORE="${NWP_HEALTH_MAX_LOAD_PER_CORE:-200}"   # percent (2.00 x cores)
HOST_MIN_SWAP_FREE_PCT="${NWP_HEALTH_MIN_SWAP_FREE_PCT:-25}"

_host_yq() { command -v yq >/dev/null 2>&1 && yq "$@"; }

_host_say()  { printf '%s\n' "$*"; }
_host_warn() { printf '%s\n' "$*" >&2; }

################################################################################
# SECTION 1 — target resolution (role | server name | hostname -> ssh dest)
################################################################################

# host_resolve_name <target>
# The directory name captured state is filed under. A configured server keeps
# its own name; a role resolves through the manifest to its bound hostname.
host_resolve_name() {
    local target="$1"
    [ -n "$target" ] || return 1

    if [ -f "$HOST_SERVERS_DIR/$target/.nwp-server.yml" ]; then
        printf '%s\n' "$target"
        return 0
    fi

    local hostname=""
    if [ -f "$HOST_MANIFEST" ] && command -v yq >/dev/null 2>&1; then
        hostname="$(role="$(_host_canon_role "$target")" yq e \
            '.roles[strenv(role)] // [] | .[0] // ""' "$HOST_MANIFEST" 2>/dev/null)"
    fi
    if [ -n "$hostname" ] && [ "$hostname" != "null" ]; then
        printf '%s\n' "$hostname"
        return 0
    fi

    # Bare hostname / ssh alias.
    printf '%s\n' "$target"
}

# Short alias -> canonical role label. Mirrors scripts/commands/host.sh so the
# two agree; kept small deliberately (the canonical list is
# docs/reference/role-vocabulary.md).
_host_canon_role() {
    case "$1" in
        auth) echo authoring ;;  cih) echo ci-host ;;   bh)  echo build-host ;;
        aih)  echo ai-host ;;    lmh) echo llm-host ;;  va)  echo voice-agent ;;
        tw)   echo transcription-worker ;;              tg)  echo transcription-gpu ;;
        ms)   echo mirror-store ;; rag) echo rag-backend ;; ver) echo verifier ;;
        gh)   echo gitlab-host ;; prod) echo prod-cluster ;; pa) echo prod-agent ;;
        *)    echo "$1" ;;
    esac
}

# host_resolve_dest <target>
# Prints the ssh command prefix to reach the target, e.g.
#   ssh -o BatchMode=yes ... -i /path/key gitlab@203.0.113.9
# Prints LOCAL when the target is this machine. Returns 1 if unresolvable.
host_resolve_dest() {
    local target="$1"
    [ -n "$target" ] || return 1

    # (1) A configured server record wins — it carries key + user + ip.
    if [ -f "$HOST_SERVERS_DIR/$target/.nwp-server.yml" ]; then
        if declare -F get_server_ssh_command >/dev/null 2>&1; then
            local cmd
            if cmd="$(get_server_ssh_command "$target" 2>/dev/null)" && [ -n "$cmd" ]; then
                printf 'ssh %s %s\n' "$HOST_SSH_OPTS" "${cmd#ssh }"
                return 0
            fi
        fi
    fi

    local hostname
    hostname="$(host_resolve_name "$target")"

    # (2) This machine?
    if [ "$hostname" = "localhost" ] || [ "$hostname" = "$(hostname -s 2>/dev/null)" ] \
       || [ "$hostname" = "$(hostname 2>/dev/null)" ]; then
        printf 'LOCAL\n'
        return 0
    fi

    # (3) An explicit ssh target in the private manifest. THIS is what makes the
    #     estate reachable off the home LAN: the operator records each host's
    #     tailnet destination ONCE, in the private manifest, instead of every
    #     script hardcoding a LAN alias that times out the moment you travel
    #     (the `${MET:-<alias>}` pattern in demo/install-on-met.sh).
    local dest="" identity=""
    if [ -f "$HOST_MANIFEST" ] && command -v yq >/dev/null 2>&1; then
        dest="$(h="$hostname" yq e '.ssh_targets[strenv(h)].dest // ""' "$HOST_MANIFEST" 2>/dev/null)"
        identity="$(h="$hostname" yq e '.ssh_targets[strenv(h)].identity // ""' "$HOST_MANIFEST" 2>/dev/null)"
    fi
    [ "$dest" = "null" ] && dest=""
    [ "$identity" = "null" ] && identity=""
    [ -n "$dest" ] || dest="$hostname"     # (4) fall back to an ssh_config alias

    if [ -n "$identity" ]; then
        printf 'ssh %s -o IdentitiesOnly=yes -i %s %s\n' "$HOST_SSH_OPTS" "${identity/#\~/$HOME}" "$dest"
    else
        printf 'ssh %s %s\n' "$HOST_SSH_OPTS" "$dest"
    fi
}

# host_run <ssh-prefix> <remote-script>
# Runs a FIXED remote script. Returns the transport/remote exit code.
host_run() {
    local prefix="$1"; shift
    local script="$1"
    if [ "$prefix" = "LOCAL" ]; then
        bash -c "$script"
        return $?
    fi
    # shellcheck disable=SC2086  # prefix is a command built by host_resolve_dest
    $prefix "$script"
}

################################################################################
# SECTION 2 — scrubbing. Rule 4: no secret material lands in the repo.
################################################################################

# host_scrub_authorized_keys  (stdin -> stdout)
# Keeps the forced-command options, the key TYPE and the comment; replaces the
# key blob with a stable fingerprint. This is what makes it safe to version the
# authorized_keys POLICY — the thing standing between a leaked pull key and an
# account with (ALL) NOPASSWD: ALL — without versioning the keys themselves.
host_scrub_authorized_keys() {
    awk '
      /^[[:space:]]*(#|$)/ { print; next }
      {
        line = $0
        # Find the key type token, then redact the blob that follows it.
        if (match(line, /(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-[a-z0-9-]+@openssh\.com)[[:space:]]+[A-Za-z0-9+\/=]+/)) {
          pre  = substr(line, 1, RSTART - 1)
          tok  = substr(line, RSTART, RLENGTH)
          post = substr(line, RSTART + RLENGTH)
          split(tok, a, /[[:space:]]+/)
          printf "%s%s <KEY-REDACTED len=%d>%s\n", pre, a[1], length(a[2]), post
          next
        }
        print line
      }'
}

# host_scrub_stream (stdin -> stdout)
# Belt-and-braces redaction applied to EVERY captured stream. Capture pulls
# /etc files; one careless kind must not push a credential into git.
host_scrub_stream() {
    sed -E \
        -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----).*/\1 <REDACTED>/' \
        -e 's/glpat-[A-Za-z0-9_-]{16,}/<REDACTED-GITLAB-PAT>/g' \
        -e 's/gl[a-z]{2,}-[A-Za-z0-9_-]{20,}/<REDACTED-GITLAB-TOKEN>/g' \
        -e 's/AKIA[0-9A-Z]{16}/<REDACTED-AWS-KEY>/g' \
        -e 's/(password|passwd|secret|api[_-]?key|token)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2<REDACTED>/Ig'
}

################################################################################
# SECTION 3 — the capture kinds. Each is a fixed, cheap, read-only probe.
################################################################################

# The order here is the order --all captures in.
HOST_CAPTURE_KINDS=(cron systemd nginx php ssh firewall headscale)

host_kind_default_file() {
    case "$1" in
        cron)      echo "crontab.root" ;;
        systemd)   echo "units.list" ;;
        nginx)     echo "nginx.txt" ;;
        php)       echo "php.txt" ;;
        ssh)       echo "authorized_keys.policy" ;;
        firewall)  echo "ufw.rules" ;;
        headscale) echo "headscale.policy.json" ;;
        *)         return 1 ;;
    esac
}

host_kind_is_known() {
    local k
    for k in "${HOST_CAPTURE_KINDS[@]}"; do [ "$k" = "$1" ] && return 0; done
    return 1
}

# host_kind_probe <kind> -> the remote script (stdout)
# Every branch is a literal. Nothing from argv reaches the remote shell.
host_kind_probe() {
    case "$1" in
    cron) cat <<'PROBE'
set -u
emit() { printf '==NWPFILE== %s\n' "$1"; }
inc()  { printf '==NWPINCOMPLETE== %s %s\n' "$1" "$2"; }
emit "crontab.root"; crontab -l 2>/dev/null || sudo -n crontab -l 2>/dev/null || inc crontab.root "not-readable"
emit "etc-crontab";  [ -r /etc/crontab ] && cat /etc/crontab || inc etc-crontab "not-readable"
for f in /etc/cron.d/*; do
  [ -f "$f" ] || continue
  emit "cron.d/$(basename "$f")"
  cat "$f" 2>/dev/null || inc "cron.d/$(basename "$f")" "not-readable"
done
PROBE
        ;;
    systemd) cat <<'PROBE'
set -u
printf '==NWPFILE== units.list\n'
systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null \
  || printf '==NWPINCOMPLETE== units.list no-systemctl\n'
printf '==NWPFILE== timers.list\n'
systemctl list-timers --all --no-pager --no-legend 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]{2,}/\t/g' \
  || printf '==NWPINCOMPLETE== timers.list no-systemctl\n'
PROBE
        ;;
    nginx) cat <<'PROBE'
set -u
for f in /etc/nginx/conf.d/*.conf /etc/nginx/snippets/*.conf; do
  [ -f "$f" ] || continue
  printf '==NWPFILE== %s\n' "${f#/etc/nginx/}"
  cat "$f" 2>/dev/null || printf '==NWPINCOMPLETE== %s not-readable\n' "${f#/etc/nginx/}"
done
# The certbot deploy hook belongs to the nginx picture: an installed hook that
# has diverged from the versioned one is a silent cert-expiry outage.
for f in /etc/letsencrypt/renewal-hooks/deploy/*; do
  [ -f "$f" ] || continue
  printf '==NWPFILE== renewal-hooks/deploy/%s\n' "$(basename "$f")"
  cat "$f" 2>/dev/null || printf '==NWPINCOMPLETE== renewal-hooks/deploy/%s not-readable\n' "$(basename "$f")"
done
PROBE
        ;;
    php) cat <<'PROBE'
set -u
for f in /etc/php/*/fpm/conf.d/*.ini /etc/php/*/cli/conf.d/*.ini; do
  [ -f "$f" ] || continue
  printf '==NWPFILE== %s\n' "${f#/etc/php/}"
  cat "$f" 2>/dev/null || printf '==NWPINCOMPLETE== %s not-readable\n' "${f#/etc/php/}"
done
printf '==NWPFILE== effective.txt\n'
for b in /usr/bin/php8.1 /usr/bin/php8.2 /usr/bin/php8.3 /usr/bin/php8.4; do
  [ -x "$b" ] || continue
  printf '%s max_input_vars=%s memory_limit=%s\n' "$(basename "$b")" \
    "$("$b" -r 'echo ini_get("max_input_vars");' 2>/dev/null)" \
    "$("$b" -r 'echo ini_get("memory_limit");' 2>/dev/null)"
done
PROBE
        ;;
    ssh) cat <<'PROBE'
set -u
printf '==NWPFILE== authorized_keys.policy\n'
if [ -r "$HOME/.ssh/authorized_keys" ]; then
  cat "$HOME/.ssh/authorized_keys"
else
  printf '==NWPINCOMPLETE== authorized_keys.policy not-readable\n'
fi
PROBE
        ;;
    firewall) cat <<'PROBE'
set -u
printf '==NWPFILE== ufw.rules\n'
sudo -n ufw status numbered 2>/dev/null || printf '==NWPINCOMPLETE== ufw.rules no-sudo-or-no-ufw\n'
PROBE
        ;;
    headscale) cat <<'PROBE'
set -u
printf '==NWPFILE== headscale.policy.json\n'
sudo -n headscale policy get 2>/dev/null || printf '==NWPINCOMPLETE== headscale.policy.json no-sudo-or-no-headscale\n'
PROBE
        ;;
    *) return 1 ;;
    esac
}

# _host_split_stream <kind> <destdir>   (stdin)
# Splits a v1 capture stream into files. Returns 2 if the stream declared any
# incompleteness — rule 2, fail closed.
_host_split_stream() {
    local kind="$1" dest="$2"
    local default_file; default_file="$(host_kind_default_file "$kind")"
    mkdir -p "$dest"
    awk -v dest="$dest" -v deffile="$default_file" '
      BEGIN { cur = ""; incomplete = 0 }
      /^==NWPINCOMPLETE== / { incomplete = 1; print "INCOMPLETE " $2 " " $3 > "/dev/stderr"; next }
      /^==NWPFILE== / {
        cur = dest "/" $2
        n = split($2, parts, "/")
        if (n > 1) { d = dest; for (i = 1; i < n; i++) { d = d "/" parts[i]; system("mkdir -p \"" d "\"") } }
        printf "" > cur
        next
      }
      {
        if (cur == "") { cur = dest "/" deffile; printf "" > cur }
        print >> cur
      }
      END { exit (incomplete ? 2 : 0) }
    '
}

# host_capture_kind <ssh-prefix> <kind> <destdir>
# Runs the probe, scrubs, splits. Returns 0 ok / 3 unreachable / 2 incomplete.
host_capture_kind() {
    local prefix="$1" kind="$2" dest="$3"
    local probe raw rc
    probe="$(host_kind_probe "$kind")" || { _host_warn "unknown kind: $kind"; return 4; }

    raw="$(host_run "$prefix" "$probe" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        _host_say "UNREACHABLE: ${kind} probe exited ${rc} — this is NOT 'no drift'"
        return 3
    fi

    local scrubbed
    if [ "$kind" = "ssh" ]; then
        scrubbed="$(printf '%s\n' "$raw" | host_scrub_authorized_keys | host_scrub_stream)"
    else
        scrubbed="$(printf '%s\n' "$raw" | host_scrub_stream)"
    fi

    if ! printf '%s\n' "$scrubbed" | _host_split_stream "$kind" "$dest" 2>/dev/null; then
        _host_say "CAPTURE-INCOMPLETE: ${kind} — the host could not read part of its own state"
        return 2
    fi
    return 0
}

################################################################################
# SECTION 4 — capture / diff / apply
################################################################################

host_system_dir() { printf '%s/%s/system\n' "$HOST_SERVERS_DIR" "$(host_resolve_name "$1")"; }

# host_capture <target> [kind ...]
#
# Replacing a captured tree is a DESTRUCTIVE local write, so it adopts
# lib/impact.sh: the fate manifest is rendered unconditionally and only the
# prompt is skippable. Auto-confirms when there is nothing to lose (no existing
# capture) or when the caller passed --yes; otherwise it asks.
host_capture() {
    local target="$1"; shift
    local auto="false" kinds=() a
    for a in "$@"; do
        case "$a" in
            -y|--yes) auto="true" ;;
            *)        kinds+=("$a") ;;
        esac
    done
    [ "${#kinds[@]}" -eq 0 ] && kinds=("${HOST_CAPTURE_KINDS[@]}")

    local prefix name sysdir rc=0
    prefix="$(host_resolve_dest "$target")" || { _host_warn "cannot resolve target: $target"; return 1; }
    name="$(host_resolve_name "$target")"
    sysdir="$HOST_SERVERS_DIR/$name/system"

    # shellcheck source=/dev/null
    [ -f "$HOST_PROJECT_ROOT/lib/impact.sh" ] && source "$HOST_PROJECT_ROOT/lib/impact.sh"

    local k
    for k in "${kinds[@]}"; do
        local tmp; tmp="$(mktemp -d)"
        if host_capture_kind "$prefix" "$k" "$tmp/$k"; then
            # FATE MANIFEST — what replacing this capture costs.
            if declare -F impact_reset >/dev/null 2>&1; then
                impact_reset
                local this_auto="$auto" f rel
                if [ -d "$sysdir/$k" ]; then
                    while IFS= read -r f; do
                        rel="${f#"$sysdir/$k"/}"
                        if [ -e "$tmp/$k/$rel" ]; then
                            impact_overwrite "Captured" "system/${k}/${rel}"
                        else
                            impact_delete "Captured" "system/${k}/${rel} (the host no longer has it)"
                        fi
                    done < <(find "$sysdir/$k" -type f | sort)
                    impact_keep "git history of servers/${name}/system/ — the previous capture is recoverable with git checkout"
                else
                    # Nothing on disk yet: no fate to weigh, so no prompt.
                    impact_keep "no previous capture of system/${k} — nothing can be lost"
                    this_auto="true"
                fi
                impact_render
                if ! impact_confirm standard "replace the captured ${name}/system/${k} tree" "$this_auto"; then
                    _host_say "aborted — ${name}/system/${k} left untouched"
                    rm -rf "$tmp"
                    rc=1
                    continue
                fi
            fi
            rm -rf "${sysdir:?}/$k"
            mkdir -p "$sysdir"
            cp -a "$tmp/$k" "$sysdir/$k"
            _host_say "captured ${name}/system/${k}"
        else
            rc=$?
            _host_say "capture FAILED for ${name}/system/${k} (rc=${rc}) — tree left untouched"
        fi
        rm -rf "$tmp"
    done

    {
        printf '# generated by `pl host capture` — do not edit by hand\n'
        printf 'host: %s\n' "$name"
        printf 'captured_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'kinds:\n'
        for k in "${kinds[@]}"; do printf '  - %s\n' "$k"; done
    } > "$sysdir/MANIFEST.yml" 2>/dev/null || true
    return $rc
}

# host_diff <target> [kind ...]
# 0 = in sync, 1 = drift, 2 = incomplete, 3 = unreachable.
# NOTHING here can report "clean" without having actually compared bytes.
host_diff() {
    local target="$1"; shift
    local kinds=("$@"); [ "${#kinds[@]}" -eq 0 ] && kinds=("${HOST_CAPTURE_KINDS[@]}")
    local prefix name sysdir worst=0
    prefix="$(host_resolve_dest "$target")" || { _host_warn "cannot resolve target: $target"; return 3; }
    name="$(host_resolve_name "$target")"
    sysdir="$HOST_SERVERS_DIR/$name/system"

    local k
    for k in "${kinds[@]}"; do
        local tmp rc; tmp="$(mktemp -d)"
        host_capture_kind "$prefix" "$k" "$tmp/$k"; rc=$?
        if [ "$rc" -ne 0 ]; then
            rm -rf "$tmp"
            [ "$rc" -gt "$worst" ] && worst=$rc
            continue
        fi
        if [ ! -d "$sysdir/$k" ]; then
            _host_say "DRIFT: ${name}/system/${k} has never been captured (host has state, repo has none)"
            [ "$worst" -lt 1 ] && worst=1
            rm -rf "$tmp"; continue
        fi
        if diff -ru "$sysdir/$k" "$tmp/$k" > "$tmp/d.txt" 2>&1; then
            _host_say "in sync: ${name}/system/${k}"
        else
            _host_say "DRIFT: ${name}/system/${k}"
            sed 's/^/    /' "$tmp/d.txt"
            [ "$worst" -lt 1 ] && worst=1
        fi
        rm -rf "$tmp"
    done
    return $worst
}

################################################################################
# SECTION 5 — health. The OOM guard that did not exist on 2026-07-25.
################################################################################

# Deliberately trivial: three reads from /proc and one df. Rule 3.
_host_health_probe_script() {
    cat <<'PROBE'
set -u
printf 'NWPHEALTH v1\n'
awk '/^MemTotal:/     {printf "mem_total_mb=%d\n",  $2/1024}
     /^MemAvailable:/ {printf "mem_avail_mb=%d\n",  $2/1024}
     /^SwapTotal:/    {printf "swap_total_mb=%d\n", $2/1024}
     /^SwapFree:/     {printf "swap_free_mb=%d\n",  $2/1024}' /proc/meminfo
df -Pm / | awk 'NR==2 {printf "disk_avail_mb=%d\ndisk_pct=%d\n", $4, $5+0}'
awk '{printf "load1=%s\n", $1}' /proc/loadavg
printf 'nproc=%s\n' "$(nproc 2>/dev/null || echo 1)"
PROBE
}

# host_health_probe <ssh-prefix>
# Emits the raw key=value block on stdout. Returns 3 when the host could not be
# probed — the caller MUST NOT read that as healthy.
host_health_probe() {
    local prefix="$1" out rc
    out="$(host_run "$prefix" "$(_host_health_probe_script)" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ] || [[ "$out" != *"NWPHEALTH"* ]]; then
        _host_say "UNKNOWN: health probe failed (rc=${rc}) — treating as UNREACHABLE, not healthy"
        return 3
    fi
    printf '%s\n' "$out"
    return 0
}

# host_health_eval <raw> [min_mem_mb]
# Prints a human summary. 0 = healthy, 1 = below threshold.
host_health_eval() {
    local raw="$1" min_mem="${2:-$HOST_MIN_MEM_MB}"
    local mem_total=0 mem_avail=0 swap_total=0 swap_free=0 disk_avail=0 disk_pct=0 load1=0 nproc=1
    local line key val
    while IFS= read -r line; do
        case "$line" in *=*) key="${line%%=*}"; val="${line#*=}" ;; *) continue ;; esac
        case "$key" in
            mem_total_mb) mem_total="$val" ;;   mem_avail_mb) mem_avail="$val" ;;
            swap_total_mb) swap_total="$val" ;; swap_free_mb) swap_free="$val" ;;
            disk_avail_mb) disk_avail="$val" ;;
            disk_pct)     disk_pct="$val" ;;    load1) load1="$val" ;;
            nproc)        nproc="$val" ;;
        esac
    done <<< "$raw"

    [ "${nproc:-0}" -gt 0 ] 2>/dev/null || nproc=1
    local load_pct
    load_pct=$(awk -v l="$load1" -v n="$nproc" 'BEGIN{ printf "%d", (n>0? l*100/n : 0) }')

    local bad=0 reasons=()
    if [ "$mem_avail" -lt "$min_mem" ] 2>/dev/null; then
        bad=1; reasons+=("memory headroom ${mem_avail} MB < ${min_mem} MB required")
    fi
    if [ "$disk_avail" -lt "$HOST_MIN_DISK_MB" ] 2>/dev/null; then
        bad=1; reasons+=("disk headroom ${disk_avail} MB < ${HOST_MIN_DISK_MB} MB required")
    fi
    if [ "$load_pct" -gt "$HOST_MAX_LOAD_PER_CORE" ] 2>/dev/null; then
        bad=1; reasons+=("load ${load1} over ${nproc} core(s) = ${load_pct}% > ${HOST_MAX_LOAD_PER_CORE}%")
    fi
    # SWAP PRESSURE. A box with free RAM above the floor but its swap already
    # 75% consumed is a box that is ALREADY thrashing — starting heavy work
    # there is how you get an OOM kill, not how you avoid one. Measured on the
    # real 3.9 GB forge box the day after it went down: 544 MB "available" but
    # only 625 of 2543 MB swap free. An absolute-RAM-only rule called that
    # HEALTHY, which would have been the same wrong answer as having no check.
    if [ "${swap_total:-0}" -gt 0 ] 2>/dev/null; then
        local swap_free_pct
        swap_free_pct=$(( swap_free * 100 / swap_total ))
        if [ "$swap_free_pct" -lt "$HOST_MIN_SWAP_FREE_PCT" ]; then
            bad=1; reasons+=("swap is ${swap_free_pct}% free (< ${HOST_MIN_SWAP_FREE_PCT}%) — the host is already under memory pressure")
        fi
    fi

    printf '  mem   %s MB available of %s MB\n' "$mem_avail" "$mem_total"
    printf '  swap  %s MB free\n' "$swap_free"
    printf '  disk  %s MB available on / (%s%% used)\n' "$disk_avail" "$disk_pct"
    printf '  load  %s over %s core(s)\n' "$load1" "$nproc"
    if [ "$bad" -eq 0 ]; then
        printf '  HEALTHY — has headroom for heavy work\n'
        return 0
    fi
    local r
    for r in "${reasons[@]}"; do printf '  NO HEADROOM: %s\n' "$r"; done
    return 1
}

# host_health_require <ssh-prefix> <min_mem_mb> <label>
# THE PREFLIGHT. Every verb that runs real work on a shared box calls this and
# refuses below the threshold. Blindness is also a refusal — an unprobeable box
# is not a box you should start a heavy op on.
host_health_require() {
    local prefix="$1" min_mem="${2:-$HOST_MIN_MEM_MB}" label="${3:-this operation}"
    local raw
    if ! raw="$(host_health_probe "$prefix")"; then
        printf 'REFUSING %s — could not read host headroom (UNKNOWN is not OK)\n' "$label" >&2
        return 3
    fi
    if ! host_health_eval "$raw" "$min_mem" >&2; then
        printf 'REFUSING %s — the host has no headroom (see above).\n' "$label" >&2
        printf 'Rerun when it recovers, or move the work to a bigger host.\n' >&2
        return 1
    fi
    return 0
}

################################################################################
# SECTION 6 — forge status. The forge holds the whole trust root and no check
# covered it. NOTHING here may run gitlab-rails on a 3.8 GB box.
################################################################################

_host_forge_probe_script() {
    cat <<'PROBE'
set -u
printf 'NWPFORGE v1\n'
pkg=""
for p in gitlab-ce gitlab-ee; do
  if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then pkg="$p"; break; fi
done
if [ -z "$pkg" ]; then printf 'pkg=none\n'; else
  printf 'pkg=%s\n' "$pkg"
  printf 'version=%s\n' "$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
  if apt-mark showhold 2>/dev/null | grep -qx "$pkg"; then printf 'held=yes\n'; else printf 'held=no\n'; fi
fi
for k in /etc/apt/keyrings/gitlab*.gpg /etc/apt/trusted.gpg.d/gitlab*.gpg; do
  [ -f "$k" ] || continue
  printf 'key_expiry=%s\n' "$(gpg --show-keys --with-colons "$k" 2>/dev/null | awk -F: '/^pub:/ {print $7; exit}')"
  break
done
printf 'upgradable=%s\n' "$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || echo 0)"
PROBE
}

host_forge_probe() {
    local prefix="$1" out rc
    out="$(host_run "$prefix" "$(_host_forge_probe_script)" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [[ "$out" != *"NWPFORGE"* ]]; then
        _host_say "UNKNOWN: forge probe failed (rc=${rc}) — not 'up to date'"
        return 3
    fi
    printf '%s\n' "$out"
}

################################################################################
# SECTION 7 — logs. Read-only by construction; a FIXED source set.
################################################################################

# host_log_source_cmd <source> <tail> [since]
# Returns 1 for an unknown source. Operator input NEVER reaches the remote
# shell: `source` is matched against a literal case, and tail/since are
# validated as integers/date-shaped before interpolation.
host_log_source_cmd() {
    local src="$1" tail="$2" since="${3:-}"
    [[ "$tail" =~ ^[0-9]+$ ]] || return 1
    [ "$tail" -gt 5000 ] && tail=5000
    [ "$tail" -lt 1 ] && tail=1
    local sincearg=""
    if [ -n "$since" ]; then
        [[ "$since" =~ ^[A-Za-z0-9:_.\ -]{1,32}$ ]] || return 1
        sincearg="--since=$since"
    fi
    case "$src" in
        nginx)    printf 'tail -n %s /var/log/nginx/error.log /var/log/nginx/access.log 2>/dev/null\n' "$tail" ;;
        php-fpm)  printf 'tail -n %s /var/log/php*-fpm.log 2>/dev/null\n' "$tail" ;;
        auth)     printf 'tail -n %s /var/log/auth.log 2>/dev/null\n' "$tail" ;;
        systemd)  printf 'journalctl --no-pager -n %s %s 2>/dev/null\n' "$tail" "$sincearg" ;;
        watchdog) printf 'tail -n %s /var/log/syslog 2>/dev/null\n' "$tail" ;;
        *)        return 1 ;;
    esac
}

HOST_LOG_SOURCES=(nginx php-fpm auth systemd watchdog)

################################################################################
# SECTION 8 — repo-hygiene checks (wired into `pl doctor` and `pl verify`).
################################################################################

# host_check_server_repos <root>
# Two overlapping git repos over one path guarantee a divergent second copy of
# load-bearing scripts. servers/nwpcode/ is a 2-commit repo with NO REMOTE whose
# tracked set is disjoint from the parent's — and it is the sole home of the
# fleet backup producer and the CVE-response upgrade script.
# 0 = clean, 1 = a nested server repo is unbacked.
host_check_server_repos() {
    local root="${1:-$HOST_PROJECT_ROOT}"
    local bad=0 d name
    [ -d "$root/servers" ] || return 0
    for d in "$root"/servers/*/; do
        [ -d "$d/.git" ] || continue
        name="$(basename "$d")"
        if [ -z "$(git -C "$d" remote 2>/dev/null)" ]; then
            _host_say "servers/${name}: nested git repo has NO remote — its history exists on exactly one disk"
            bad=1
            continue
        fi
        local unpushed
        unpushed="$(git -C "$d" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
        if [ "${unpushed:-0}" -gt 0 ]; then
            _host_say "servers/${name}: ${unpushed} unpushed commit(s) — not backed by any remote"
            bad=1
        fi
    done
    return $bad
}

# host_check_servers_tracked <root>
# Captured host state must be VERSIONED, not force-added by whoever remembers.
# 0 = every captured artifact is tracked/trackable, 1 = something is ignored or
# uncommitted.
host_check_servers_tracked() {
    local root="${1:-$HOST_PROJECT_ROOT}"
    local bad=0 sub probe
    [ -d "$root/servers" ] || return 0
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    for sub in nginx demo linode backup email system; do
        probe="servers/PROBE-HOST/${sub}/PROBE.conf"
        if git -C "$root" check-ignore -q "$probe" 2>/dev/null; then
            _host_say "servers/*/${sub}/** is git-ignored — captured host state cannot be versioned"
            bad=1
        fi
    done

    local dirty
    dirty="$(git -C "$root" status --porcelain -- servers/ 2>/dev/null | head -20)"
    if [ -n "$dirty" ]; then
        _host_say "servers/ has uncommitted captured state:"
        printf '%s\n' "$dirty" | sed 's/^/    /'
        bad=1
    fi
    return $bad
}
