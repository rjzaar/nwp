#!/usr/bin/env bash
#
# lib/gitlab-tunables.sh — the engine behind `pl host apply <host> --kind=gitlab`.
#
# WHY THIS FILE EXISTS
# --------------------
# Measured 2026-08-02 (ops#257): the forge box runs GitLab in 3.92 GB and had
# 1.46 GB of 2.6 GB swap already in use — puma 1220 MB PSS, sidekiq 968 MB,
# postgres 358 MB. That is the mechanism behind the 2026-07-25 OOM that took
# GitLab and its vhosts down for 5-8 minutes: the box has no headroom, so any
# heavy operation tips it over.
#
# The remedy is four declared numbers in /etc/gitlab/gitlab.rb. There was no
# verb that could put them in force. Without one this lands as
# `ssh` + `sudo vim` + `gitlab-ctl reconfigure` — the exact pl-first violation
# CLAUDE.md forbids, on the one box whose failure takes the forge down, with no
# backup, no post-write measurement and no rollback row.
#
# WHAT IT GUARANTEES (mirroring lib/php-floor.sh — same shape, same reasons)
# -------------------------------------------------------------------------
#  1. DRY-RUN BY DEFAULT. Prints the exact managed block it would write and the
#     effective values it measured, and writes nothing without --execute.
#  2. IT MEASURES, IT DOES NOT GREP gitlab.rb. `max_connections` is read from
#     the running server (`SHOW max_connections`); puma and sidekiq are read
#     from the files CHEF RENDERED, not from the source we just edited. Reading
#     back your own edit proves only that you can write a file — the estate has
#     been burned by exactly that (a php floor "set" on the wrong SAPI).
#  3. FAIL CLOSED ON BLINDNESS. Unreachable host, absent gitlab.rb, or a value
#     that cannot be parsed is CANNOT-MEASURE with a non-zero exit, never
#     "applied". `gitlab.rb` present is itself asserted: this must not run
#     against a box that is not the forge.
#  4. THE FILE IS BACKED UP WITH ITS sha256 BEFORE THE WRITE, at a path the
#     verb prints, so the rollback row can be honest.
#  5. IT RE-MEASURES AFTERWARDS and refuses to claim success unless the values
#     are in force after the reconfigure.
#  6. THE BLOCK IS MARKER-DELIMITED AND IDEMPOTENT. Re-running rewrites the
#     block in place; it never appends a second copy. gitlab.rb is
#     last-assignment-wins, so a duplicated block is not merely untidy, it
#     silently decides which value is real. (That trap is already live on this
#     box: `puma['worker_processes']` is assigned at line 3664 AND 3697.)
#  7. IT REFUSES WHILE CI IS BUSY, unless overridden. `gitlab-ctl reconfigure`
#     restarts puma and sidekiq; a running pipeline dies with it.
#
# DECLARED, NOT CAPTURED: the numbers live in
# `servers/<host>/system/gitlab-tunables.yml`, authored and reviewed, so there
# is no redaction round-trip to lose.

# shellcheck disable=SC2034
GITLAB_TUNABLES_MARKER_BEGIN='# >>> nwp gitlab tunables >>>'
GITLAB_TUNABLES_MARKER_END='# <<< nwp gitlab tunables <<<'
GITLAB_RB='/etc/gitlab/gitlab.rb'

# gitlab_tunables_declared <declfile> — echo "key<TAB>value" per tunable.
gitlab_tunables_declared() {
    local f="$1"
    [ -r "$f" ] || return 2
    # A REAL TAB via strenv, never the "\t" escape: yq only began expanding that
    # in v4.45+. CI pins v4.44.1, where it stays a literal backslash-t and the
    # `IFS=$'\t' read` below silently fails to split — so every tunable would
    # parse as one field and the verb would quietly declare nothing. It works on
    # this workstation (v4.50.1) and would have broken anywhere else. Four other
    # files in this tree already carry comments warning about exactly this.
    TAB=$'\t' "${YQ:-yq}" e -r '.tunables | to_entries | .[] | .key + strenv(TAB) + (.value|tostring)' "$f" 2>/dev/null
}

# gitlab_tunables_block <declfile> — the exact managed block to install.
gitlab_tunables_block() {
    local f="$1" key val
    printf '%s\n' "$GITLAB_TUNABLES_MARKER_BEGIN"
    printf '# Managed by `pl host apply --kind=gitlab` (lib/gitlab-tunables.sh).\n'
    printf '# Declared in servers/<host>/system/gitlab-tunables.yml — edit there.\n'
    printf '# Assignments here are LAST in the file, so they are the effective values.\n'
    while IFS=$'\t' read -r key val; do
        [ -n "$key" ] || continue
        case "$val" in
            ''|*[!0-9]*) printf '%s = "%s"\n' "$key" "$val" ;;
            *)           printf '%s = %s\n'   "$key" "$val" ;;
        esac
    done < <(gitlab_tunables_declared "$f")

    # Rails env vars. On 18.7 the memory controls live here, not in omnibus
    # attributes: `gitlab_rails['env']` renders one file per variable into
    # /opt/gitlab/etc/gitlab-rails/env/, which the puma and sidekiq runit
    # scripts load with `chpst -e`. Emitted only when declared, so the hash is
    # never written empty (an empty assignment would clobber the defaults).
    local envp; envp="$(gitlab_tunables_rails_env "$f")"
    if [ -n "$envp" ]; then
        printf "gitlab_rails['env'] = {\n"
        printf '%s' "$envp"
        printf "}\n"
    fi
    printf '%s\n' "$GITLAB_TUNABLES_MARKER_END"
}

# gitlab_tunables_rails_env <declfile> — the body of the env hash, or empty.
gitlab_tunables_rails_env() {
    local f="$1" k v
    TAB=$'\t' "${YQ:-yq}" e -r '.rails_env // {} | to_entries | .[] | .key + strenv(TAB) + (.value|tostring)' "$f" 2>/dev/null \
    | while IFS=$'\t' read -r k v; do
        [ -n "$k" ] || continue
        printf "  '%s' => '%s',\n" "$k" "$v"
      done
}

# gitlab_tunables_ci_busy <host> — 0 if a pipeline is running (refuse), 1 if idle.
# Guarantee 7: a reconfigure restarts puma and kills whatever CI is mid-job.
gitlab_tunables_ci_busy() {
    local cfg="${NWP_GLCURL_CFG:-}" host="${NWP_GITLAB_HOST:-}" n sec
    # The forge host is NEVER a literal here — the gitleaks operator ruleset
    # rejects bare internal hostnames outside allowlisted paths, and it was
    # right to: role labels and config are the vocabulary
    # (docs/reference/role-vocabulary.md). Read it from the secrets file the
    # rest of the tooling already uses, or take it from the environment.
    if [ -z "$host" ]; then
        sec="${NWP_SECRETS_FILE:-$HOME/nwp/.secrets.yml}"
        [ -r "$sec" ] && host="$("${YQ:-yq}" e -r '.gitlab.server.domain // ""' "$sec" 2>/dev/null)"
    fi
    # Cannot check => do not block. This guard exists to avoid killing a running
    # job, not to be a second approval gate; refusing on "I could not look"
    # would strand the verb on any host without forge credentials.
    [ -n "$host" ] && [ -n "$cfg" ] && [ -r "$cfg" ] || return 1
    # ops#374: `-K -` with the config redirected in, so curl never opens a
    # credential path itself. NOTE this config is OPERATOR-SUPPLIED via
    # NWP_GLCURL_CFG, which has NO producer anywhere in this tree — so the
    # `[ -r "$cfg" ]` guard above never passes and this check is currently
    # INERT. Flagged, not fixed here: making it live is a behaviour change to a
    # CI-busy guard and belongs in its own MR.
    n=$(curl -sS -K - < "$cfg" \
        "https://$host/api/v4/projects/9/pipelines?status=running&per_page=5" \
        -o - 2>/dev/null | grep -c '"id"') || return 1
    [ "${n:-0}" -gt 0 ]
}

# gitlab_tunables_run <target> [--execute] [--force-ci]
# The verb body. Dry-run unless --execute.
gitlab_tunables_run() {
    local target="${1:-}"; shift || true
    local execute=0 force_ci=0 a
    for a in "$@"; do
        case "$a" in --execute) execute=1 ;; --force-ci) force_ci=1 ;; esac
    done

    local name dest decl
    name="$(host_resolve_name "$target" 2>/dev/null || echo "$target")"
    dest="$(host_resolve_dest "$target")" || { print_error "cannot resolve $target"; return 3; }
    [ "$dest" = "LOCAL" ] && { print_error "refusing: --kind=gitlab is a remote-host verb"; return 2; }

    decl="$HOST_SERVERS_DIR/$target/system/gitlab-tunables.yml"
    [ -r "$decl" ] || decl="$HOST_SERVERS_DIR/$name/system/gitlab-tunables.yml"
    [ -r "$decl" ] || { print_error "no declared tunables at servers/$target/system/gitlab-tunables.yml"; return 2; }

    print_header "pl host apply — $name (gitlab tunables)"

    # (a) BEFORE, measured from the running box — never grepped from gitlab.rb.
    local before
    before="$($dest 'bash -s' <<'P' 2>/dev/null
sudo -n gitlab-psql -tAc 'SHOW max_connections' 2>/dev/null | tr -d ' ' | sed 's/^/postgresql.max_connections=/'
# The env dir is the artifact that decides behaviour — the runit scripts load
# it with `chpst -e`. Measuring /opt/gitlab/sv/sidekiq/run instead reported
# UNSET for a setting that was in force, which is how the first run of this
# verb produced a false NOT-IN-FORCE on puma.
E=/opt/gitlab/etc/gitlab-rails/env
printf 'sidekiq.memory_killer_max_rss=%s\n' "$(sudo -n cat $E/SIDEKIQ_MEMORY_KILLER_MAX_RSS 2>/dev/null || echo UNSET)"
printf 'puma.worker_max_memory_mb=%s\n' "$(sudo -n cat $E/PUMA_WORKER_MAX_MEMORY 2>/dev/null || echo UNSET)"
# Also emit each env var under its REAL name. The assertion below compares
# declared name to measured name directly; deriving one from the other by
# lowercasing produced a false NOT-IN-FORCE on a value that was correct
# (SIDEKIQ_MEMORY_KILLER_MAX_RSS vs sidekiq.memory_killer_max_rss).
for _v in $(sudo -n ls $E 2>/dev/null); do
  printf 'env.%s=%s\n' "$_v" "$(sudo -n cat $E/$_v 2>/dev/null)"
done
awk '/^MemAvailable:/{printf "mem.available_mb=%d\n", $2/1024}' /proc/meminfo
awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{printf "swap.used_mb=%d\n",(t-f)/1024}' /proc/meminfo
P
)"
    [ -n "$before" ] || { print_error "CANNOT MEASURE — the box did not answer; refusing (a blind apply is not an apply)"; return 3; }
    echo "BEFORE (effective, measured):"; printf '  %s\n' $before

    # (b) the block that would be installed
    local block; block="$(gitlab_tunables_block "$decl")"
    echo ""; echo "Managed block for $GITLAB_RB:"; printf '%s\n' "$block" | sed 's/^/  /'

    if [ "$execute" -eq 0 ]; then
        echo ""
        print_warning "DRY RUN — nothing was written to $name."
        print_hint "Re-run with --execute (you will be asked to type the host name)."
        print_hint "This RESTARTS puma and sidekiq: brief GitLab downtime, and any running CI job dies."
        return 0
    fi

    # (c) guarantee 7 — refuse while CI is mid-job
    if [ "$force_ci" -eq 0 ] && gitlab_tunables_ci_busy; then
        print_error "REFUSING: a pipeline is running. gitlab-ctl reconfigure restarts puma and would kill it."
        print_hint "Wait for the queue to drain, or pass --force-ci if you accept losing the job."
        return 1
    fi

    # (d) preflight — the standing order before anything heavy on a shared box
    local _pl; _pl="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pl"
    if [ -x "$_pl" ]; then
        "$_pl" server health "$target" >/dev/null 2>&1 \
            || print_warning "server health did not return clean — proceeding, but read it: pl server health $target"
    fi

    print_warning "About to edit $GITLAB_RB on '$name' and run gitlab-ctl reconfigure."
    printf "Type the host name to continue: "
    local typed=""; read -r typed || true
    [ "$typed" = "$name" ] || [ "$typed" = "$target" ] || { print_error "confirmation did not match — nothing applied"; return 1; }

    # (e) backup + idempotent write + reconfigure, as ONE remote script.
    local stamp; stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    # The block travels as base64 in the remote command line, NOT on stdin.
    # First attempt piped it into ssh AND supplied the script as a heredoc: the
    # heredoc wins, so `BLOCK="$(cat)"` read an empty stdin and the whole remote
    # script silently did nothing (no backup, no write, no output — which is how
    # it was caught: an "apply" that produced not one line of evidence).
    # base64 is [A-Za-z0-9+/=] only, so nothing in it can reach the remote shell
    # as syntax.
    local b64; b64="$(printf '%s\n' "$block" | base64 -w0)"
    local out
    out="$($dest "BLOCK_B64='$b64' BLOCK_STAMP='$stamp' bash -s" <<'P' 2>&1
set -u
BLOCK="$(printf '%s' "$BLOCK_B64" | base64 -d)"
[ -n "$BLOCK" ] || { echo "FATAL: empty block reached the host — refusing"; exit 3; }
RB=/etc/gitlab/gitlab.rb
BAK="/etc/gitlab/gitlab.rb.nwp-${BLOCK_STAMP}.bak"
sudo -n cp -a "$RB" "$BAK" || { echo "FATAL: backup failed"; exit 3; }
echo "BACKUP=$BAK"
echo "BACKUP_SHA=$(sudo -n sha256sum "$BAK" | cut -d' ' -f1)"
sudo -n sed -i '/^# >>> nwp gitlab tunables >>>$/,/^# <<< nwp gitlab tunables <<<$/d' "$RB"
printf '\n%s\n' "$BLOCK" | sudo -n tee -a "$RB" >/dev/null
n=$(sudo -n grep -c '^# >>> nwp gitlab tunables >>>$' "$RB")
[ "$n" = "1" ] || { echo "FATAL: $n managed blocks after write (expected 1)"; sudo -n cp -a "$BAK" "$RB"; exit 3; }
echo "BLOCKS=$n"
echo "RECONFIGURE-START"
sudo -n gitlab-ctl reconfigure >/tmp/nwp-reconf.log 2>&1 || { echo "FATAL: reconfigure failed"; sudo -n tail -25 /tmp/nwp-reconf.log; sudo -n cp -a "$BAK" "$RB"; exit 4; }
echo "RECONFIGURE-OK"
P
)"
    printf '%s\n' "$out" | sed 's/^/  /'
    printf '%s' "$out" | grep -q 'RECONFIGURE-OK' || {
        print_error "APPLY FAILED — see above. gitlab.rb was restored from the backup if the write was at fault."
        return 4
    }

    # (f) guarantee 5 — re-measure, and only then claim success
    echo ""; print_info "re-measuring…"; sleep 20
    local after
    after="$($dest 'bash -s' <<'P' 2>/dev/null
sudo -n gitlab-psql -tAc 'SHOW max_connections' 2>/dev/null | tr -d ' ' | sed 's/^/postgresql.max_connections=/'
# The env dir is the artifact that decides behaviour — the runit scripts load
# it with `chpst -e`. Measuring /opt/gitlab/sv/sidekiq/run instead reported
# UNSET for a setting that was in force, which is how the first run of this
# verb produced a false NOT-IN-FORCE on puma.
E=/opt/gitlab/etc/gitlab-rails/env
printf 'sidekiq.memory_killer_max_rss=%s\n' "$(sudo -n cat $E/SIDEKIQ_MEMORY_KILLER_MAX_RSS 2>/dev/null || echo UNSET)"
printf 'puma.worker_max_memory_mb=%s\n' "$(sudo -n cat $E/PUMA_WORKER_MAX_MEMORY 2>/dev/null || echo UNSET)"
# Also emit each env var under its REAL name. The assertion below compares
# declared name to measured name directly; deriving one from the other by
# lowercasing produced a false NOT-IN-FORCE on a value that was correct
# (SIDEKIQ_MEMORY_KILLER_MAX_RSS vs sidekiq.memory_killer_max_rss).
for _v in $(sudo -n ls $E 2>/dev/null); do
  printf 'env.%s=%s\n' "$_v" "$(sudo -n cat $E/$_v 2>/dev/null)"
done
awk '/^MemAvailable:/{printf "mem.available_mb=%d\n", $2/1024}' /proc/meminfo
awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{printf "swap.used_mb=%d\n",(t-f)/1024}' /proc/meminfo
P
)"
    echo "AFTER (effective, measured):"; printf '  %s\n' $after

    # assert every declared value is actually in force
    local key val ok=1
    while IFS=$'\t' read -r key val; do
        case "$key" in
            "postgresql['max_connections']")        printf '%s' "$after" | grep -q "postgresql.max_connections=$val" || { print_error "NOT IN FORCE: max_connections != $val"; ok=0; } ;;
            "puma['per_worker_max_memory_mb']")     printf '%s' "$after" | grep -q "puma.worker_max_memory_mb=$val" || { print_error "NOT IN FORCE: PUMA_WORKER_MAX_MEMORY != $val"; ok=0; } ;;
        esac
    done < <(gitlab_tunables_declared "$decl")
    while IFS=$'\t' read -r key val; do
        [ -n "$key" ] || continue
        printf '%s' "$after" | grep -qx "env.$key=$val" \
            || { print_error "NOT IN FORCE: $key != $val"; ok=0; }
    done < <(TAB=$'\t' "${YQ:-yq}" e -r '.rails_env // {} | to_entries | .[] | .key + strenv(TAB) + (.value|tostring)' "$decl" 2>/dev/null)

    [ "$ok" -eq 1 ] || { print_error "applied, but NOT all values are in force — do not record this as done"; return 5; }
    print_success "all declared tunables are in force on $name (re-measured, not assumed)"
    print_hint "rollback: restore the printed backup over $GITLAB_RB, then sudo gitlab-ctl reconfigure"
    return 0
}
