#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/console.sh — NWP Console lifecycle (pl console)
#
# The mesh-only, passkey-only web console (scripts/console/) deployed to the
# operator's console host — never only-on-a-box (the nwp-daily-audit lesson).
# See scripts/console/README.md.
#
# Operator-specific values (host alias, FQDN, tailnet IP, headscale URL) live
# in the gitignored nwp.yml under settings.console — NOT in this script
# (P61 leakage gate). See example.nwp.yml for the schema.
#
#   pl console deploy [--host <ssh-host>] [--no-restart] [--dry-run|-n]
#                     [--force-overwrite] [-y]             divergence guard, then
#                                                          fate manifest, then
#                                                          rsync + venv + unit + health
#   pl console status [--host <ssh-host>]                  systemd + /health over mesh
#   pl console user add <name> --role viewer|operator|owner
#   pl console user addkey <name> [--no-open] [--no-wait] [--timeout <secs>]
#                                                          scripted passkey enrolment ceremony;
#                                                          +1 passkey, keeps the existing ones
#   pl console user reset <name>                           break-glass re-enrol
#   pl console user keys <name>                            list passkeys (handle + what it is)
#   pl console user rmkey <name> <handle>                  revoke ONE passkey (never the last)
#   pl console user list | role <name> <role> | rm <name>
#   pl console enroll [--expiry 1h] [--runbook]            mint a Headscale pre-auth key
#                                                          on settings.console.headscale_host
#   pl console dns                                         upsert console A record (Linode API)
#   pl console cert                                        LE cert via DNS-01 (issued HERE,
#                                                          only cert+key pushed to host)
#   pl console logs [--host <ssh-host>]                    tail the console log
#
# Security notes:
#   * deploy NEVER copies tokens. The GitLab pane token (walled ops_note_token
#     pattern) is provisioned manually — see README "token" section.
#   * the Linode DNS token stays on THIS machine (.secrets.yml, infra tier);
#     the console host only ever receives the issued certificate + key.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/console-deploy.sh"   # target-divergence guard for deploy
source "$REPO_ROOT/lib/impact.sh"           # ops#47 impact contract (fate manifest)

# Resolve operator config: env override > nwp.yml chain > public placeholder.
_console_cfg_file() {
    # Explicit override wins outright (set-but-missing => unconfigured, no chain).
    if [ -n "${NWP_CONSOLE_CONFIG:-}" ]; then
        [ -f "$NWP_CONSOLE_CONFIG" ] && printf '%s' "$NWP_CONSOLE_CONFIG"
        return 0
    fi
    local f
    for f in "$REPO_ROOT/nwp.yml" "$HOME/nwp-instances/_global/nwp.yml" "$HOME/nwp/nwp.yml"; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 0
}

_console_cfg() { # $1 key under settings.console, $2 default
    local f v=""
    f=$(_console_cfg_file)
    if [ -n "$f" ] && command -v yq >/dev/null 2>&1; then
        v=$(yq e ".settings.console.$1 // \"\"" "$f" 2>/dev/null | grep -v '^null$' || true)
    fi
    printf '%s' "${v:-$2}"
}

CONSOLE_HOST="${NWP_CONSOLE_HOST:-$(_console_cfg host console-host)}"   # ssh alias
CONSOLE_FQDN="${NWP_CONSOLE_FQDN:-$(_console_cfg fqdn console.example.com)}"
CONSOLE_TAILNET_IP="${NWP_CONSOLE_TAILNET_IP:-$(_console_cfg tailnet_ip 100.64.0.2)}"
CONSOLE_PORT="${NWP_CONSOLE_PORT:-$(_console_cfg port 8600)}"
HEADSCALE_URL="${NWP_CONSOLE_HEADSCALE_URL:-$(_console_cfg headscale_url "https://<headscale-host>")}"
# The control plane is its own box. It was assumed to be the console host until
# 2026-08-01, when the printed runbook sent the operator to ssh a box with no
# headscale on it: the console deliberately runs where no prod keys live, which
# is exactly NOT where a public control endpoint runs.
HEADSCALE_HOST="${NWP_CONSOLE_HEADSCALE_HOST:-$(_console_cfg headscale_host "")}"
HEADSCALE_USER="${NWP_CONSOLE_HEADSCALE_USER:-$(_console_cfg headscale_user "")}"
CONSOLE_SRC="$REPO_ROOT/scripts/console"
SECRETS_FILE="${NWP_SECRETS_FILE:-$REPO_ROOT/.secrets.yml}"
LINODE_DOMAIN_NAME="${CONSOLE_FQDN#*.}"   # apex derived from the console FQDN

_require_configured() {
    if [ "$CONSOLE_FQDN" = "console.example.com" ]; then
        print_error "settings.console is not configured in nwp.yml (see example.nwp.yml)."
        print_hint "Needed keys: settings.console.{host,fqdn,tailnet_ip,port,headscale_url}"
        return 1
    fi
}

show_help() {
    cat <<EOF
${BOLD}pl console${NC} — NWP Console (mesh-only web console on ${CONSOLE_HOST})

${BOLD}USAGE:${NC}
    pl console deploy [--host <ssh-host>] [--no-restart] [--dry-run] [--force-overwrite] [-y]
    pl console status [--host <ssh-host>]
    pl console user add <name> --role viewer|operator|owner [--project <pid> --project-role <r>]
    pl console user addkey <name> [--no-open] [--no-wait] [--timeout <secs>]
                                       (scripted passkey enrolment: health -> token -> browser ->
                                        watch the host until the credential lands. Existing
                                        passkeys are KEPT. --no-open when enrolling on a phone.)
    pl console user reset <name>       (break-glass: shell-only, revokes passkeys)
    pl console user keys <name>        (list passkeys: handle, what each one IS, when)
    pl console user rmkey <name> <handle>
                                       (revoke ONE passkey; refuses the last — that is reset's job)
    pl console user list | show <name> | role <name> <role> | rm <name>
    pl console project list
    pl console project add|set <pid> [--name N] [--sites a b c] [--demo-sites a]
                                     [--issue-label L] [--ci-projects p]
    pl console project rm <pid>
    pl console project assign|unassign <user> <pid> [--role viewer|operator|maintainer]
    pl console project export [FILE]   (project->sites map -> private/project-map.json, 0600)
    pl console enroll                  (Headscale pre-auth key runbook for a new device)
    pl console dns                     (upsert ${CONSOLE_FQDN} A -> ${CONSOLE_TAILNET_IP})
    pl console cert                    (issue/renew the LE cert, DNS-01, push to host)
    pl console logs [--host <ssh-host>]

${BOLD}DEPLOY SAFETY (two gates, in this order):${NC}
    1. DIVERGENCE GUARD — "is it safe to proceed at all?" deploy uses
       'rsync --delete', so it first compares the target's tree with what is
       about to be shipped and REFUSES if the target holds anything this deploy
       does not explain — files that exist only there, or files edited there
       more recently than ours. --force-overwrite proceeds anyway, taking a
       timestamped tar.gz backup on the target FIRST.
    2. FATE MANIFEST — "what exactly will change?" the deploy then prints what
       is deleted / overwritten / added on the host, computed by
       rsync --dry-run itself, and confirms at a strength matching the damage.
       -y skips only the prompt, never the report.

    --dry-run runs BOTH gates and writes nothing.

First run: dns -> cert -> deploy -> user add <you> --role owner -> open the
printed one-time enrolment link on the device that holds your passkey.
URL: https://${CONSOLE_FQDN}:${CONSOLE_PORT}/  (resolves everywhere, reachable on-mesh only)
EOF
}

_ssh() { ssh -o ConnectTimeout=10 "$CONSOLE_HOST" "$@"; }

# 0600 curl-config pattern (never a token in argv) — mirrors lib/gitlab-issues.sh.
_linode_curl() { # $1 method, $2 path, [$3 json payload]
    local method="$1" path="$2" payload="${3:-}"
    local yq_bin; yq_bin=$(command -v yq) || { print_error "yq required"; return 1; }
    local token; token=$("$yq_bin" e '.linode.api_token // ""' "$SECRETS_FILE" | grep -v '^null$')
    [ -n "$token" ] || { print_error "no linode.api_token in $SECRETS_FILE"; return 1; }
    local cfg; cfg=$(mktemp); chmod 600 "$cfg"
    printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$token" > "$cfg"
    local rc=0
    if [ -n "$payload" ]; then
        curl -sS -K "$cfg" -X "$method" "https://api.linode.com/v4${path}" -d "$payload" || rc=$?
    else
        curl -sS -K "$cfg" -X "$method" "https://api.linode.com/v4${path}" || rc=$?
    fi
    rm -f "$cfg"
    return $rc
}

cmd_dns() {
    print_info "Upserting ${CONSOLE_FQDN} A -> ${CONSOLE_TAILNET_IP} (Linode DNS)"
    local sub="${CONSOLE_FQDN%.${LINODE_DOMAIN_NAME}}"
    local domain_id
    domain_id=$(_linode_curl GET "/domains" | jq -r ".data[] | select(.domain==\"$LINODE_DOMAIN_NAME\") | .id")
    [ -n "$domain_id" ] || { print_error "domain $LINODE_DOMAIN_NAME not found in Linode DNS"; return 1; }
    local rec_id
    rec_id=$(_linode_curl GET "/domains/$domain_id/records?page_size=500" \
        | jq -r ".data[] | select(.type==\"A\" and .name==\"$sub\") | .id" | head -1)
    local payload
    payload=$(jq -nc --arg n "$sub" --arg t "$CONSOLE_TAILNET_IP" '{type:"A",name:$n,target:$t,ttl_sec:300}')
    if [ -n "$rec_id" ]; then
        _linode_curl PUT "/domains/$domain_id/records/$rec_id" "$payload" | jq -r '"updated record id \(.id): \(.name) -> \(.target)"'
    else
        _linode_curl POST "/domains/$domain_id/records" "$payload" | jq -r '"created record id \(.id): \(.name) -> \(.target)"'
    fi
    print_success "DNS upsert done (TTL 300; propagation may take a few minutes)"
}

cmd_cert() {
    print_info "Issuing/renewing Let's Encrypt cert for ${CONSOLE_FQDN} (DNS-01, local certbot venv)"
    local certdir="$HOME/.config/nwp-console-certs"
    local venv="$certdir/venv"
    mkdir -p "$certdir"; chmod 700 "$certdir"
    [ -x "$venv/bin/certbot" ] || {
        python3 -m venv "$venv"
        "$venv/bin/pip" install -q --upgrade pip certbot certbot-dns-linode
    }
    local yq_bin; yq_bin=$(command -v yq) || { print_error "yq required"; return 1; }
    local token; token=$("$yq_bin" e '.linode.api_token // ""' "$SECRETS_FILE" | grep -v '^null$')
    [ -n "$token" ] || { print_error "no linode.api_token in $SECRETS_FILE"; return 1; }
    local creds="$certdir/linode.ini"
    ( umask 077; printf 'dns_linode_key = %s\ndns_linode_version = 4\n' "$token" > "$creds" )
    "$venv/bin/certbot" certonly --non-interactive --agree-tos \
        --email "admin@${LINODE_DOMAIN_NAME}" \
        --authenticator dns-linode --dns-linode-credentials "$creds" \
        --dns-linode-propagation-seconds 120 \
        -d "$CONSOLE_FQDN" \
        --config-dir "$certdir/config" --work-dir "$certdir/work" --logs-dir "$certdir/logs"
    local live="$certdir/config/live/$CONSOLE_FQDN"
    [ -f "$live/fullchain.pem" ] || { print_error "certbot did not produce $live/fullchain.pem"; return 1; }
    print_info "Pushing cert + key to ${CONSOLE_HOST}:~/.config/nwp-console/tls/"
    _ssh 'umask 077 && mkdir -p ~/.config/nwp-console/tls'
    # -L: dereference certbot's symlinks
    scp -q -o ConnectTimeout=10 "$(readlink -f "$live/fullchain.pem")" "$CONSOLE_HOST":.config/nwp-console/tls/fullchain.pem
    scp -q -o ConnectTimeout=10 "$(readlink -f "$live/privkey.pem")"   "$CONSOLE_HOST":.config/nwp-console/tls/privkey.pem
    _ssh 'chmod 600 ~/.config/nwp-console/tls/*.pem'
    _ssh 'systemctl --user try-restart nwp-console 2>/dev/null || true'
    print_success "cert deployed (valid ~90 days — re-run 'pl console cert' before expiry)"
}

_write_default_env() {
    # GitLab host for the issues/CI panes (never the token — that's manual).
    local gitlab_host=""
    if command -v yq >/dev/null 2>&1 && [ -f "$SECRETS_FILE" ]; then
        gitlab_host=$(yq e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$' || true)
    fi
    _ssh 'umask 077 && mkdir -p ~/.config/nwp-console && [ -f ~/.config/nwp-console/env ] || cat > ~/.config/nwp-console/env' <<EOF
# NWP Console runtime config (created by pl console deploy; edit + restart)
${CONSOLE_ENV_PATH_BLOCK}
NWP_CONSOLE_BIND=${CONSOLE_TAILNET_IP}
NWP_CONSOLE_PORT=${CONSOLE_PORT}
NWP_CONSOLE_RP_ID=${CONSOLE_FQDN}
NWP_CONSOLE_ORIGIN=https://${CONSOLE_FQDN}:${CONSOLE_PORT}
NWP_CONSOLE_TLS_CERT=%h/.config/nwp-console/tls/fullchain.pem
NWP_CONSOLE_TLS_KEY=%h/.config/nwp-console/tls/privkey.pem
NWP_CONSOLE_ROOT=%h/nwp
NWP_CONSOLE_GITLAB_HOST=${gitlab_host}
NWP_CONSOLE_DEMO_SITES=nwd
NWP_CONSOLE_CI_PROJECTS=nwp/nwp
# OPS_PROJECT is the ONE tracker the Issues pane may WRITE to. ISSUE_PROJECTS is
# every tracker it READS — tester feedback is synced into nwp/nwc by
# \`drush nwc-feedback:sync-to-gitlab\`, not into nwp/ops, so a console that
# reads only the ops board cannot show the operator their testers' reports.
# The walled ops_note_token 404s on nwp/nwc; give that tracker its own 0600
# token at ~/.config/nwp-console/gitlab.nwc.token (see README).
NWP_CONSOLE_OPS_PROJECT=nwp/ops
NWP_CONSOLE_ISSUE_PROJECTS=nwp/ops,nwp/nwc
# Quokka (local-LLM chat tab) — loopback ollama on this host only.
NWP_CONSOLE_QUOKKA_URL=http://127.0.0.1:11434
NWP_CONSOLE_QUOKKA_MODEL=llama3.3:70b
# Quokka voice — speech in/out, both ON THIS HOST (never a cloud speech API).
# Both are optional: with neither installed the mic button simply never renders.
#   speech in : faster-whisper via NWP_CONSOLE_STT_PYTHON (see README)
#   speech out: piper; without it the browser's own offline voice is used
NWP_CONSOLE_STT_BACKEND=auto
NWP_CONSOLE_STT_MODEL=base
NWP_CONSOLE_STT_PYTHON=/usr/bin/python3
NWP_CONSOLE_STT_MAX_SECONDS=60
NWP_CONSOLE_TTS_BACKEND=auto
NWP_CONSOLE_TTS_PIPER=%h/piper/venv/bin/piper
NWP_CONSOLE_TTS_VOICE=%h/piper/voices/en_US-lessac-medium.onnx
# Fleet state is PUBLISHED here by \`pl fleet publish\` (this host has no sites).
# Past FLEET_MAX_AGE seconds the panes mark the snapshot STALE instead of
# presenting it as current. Keep the publisher's cron well inside this window.
NWP_CONSOLE_FLEET_STATE=%h/.local/share/nwp-console/fleet-state.json
NWP_CONSOLE_FLEET_MAX_AGE=7200
EOF
    # systemd EnvironmentFile doesn't expand %h — replace with the real home dir.
    _ssh 'sed -i "s|%h|$HOME|g" ~/.config/nwp-console/env'
    _ensure_env_path
}

################################################################################
# PATH in the console's env file — LOAD-BEARING, and it was missing (ops#173.4)
#
# The console shells out to `pl`, and several pl helpers guard on
# `command -v yq`. On the console host yq is installed at ~/.local/bin/yq, which
# systemd does NOT put on a user service's PATH: the unit gets the bare
# /usr/local/bin:/usr/bin:/bin default, the guards fell through, and every
# invitation the operator sent from the console rendered with <YOUR-SITE-URL>,
# <COMMUNITY-SITE> and <COURSES-SITE> where the links belonged. It failed
# silently by construction — those placeholders exist precisely so the draft
# always renders rather than erroring.
#
# The block above only writes the env file when it does not already exist ("edit
# + restart" is the operator's file, not ours to clobber), so a host deployed
# before this fix would never get the line. Hence this second, idempotent step:
# it runs on EVERY deploy, adds the PATH only when absent, and never touches
# anything else in the file. Fixing the host by hand — which is how this was
# unblocked on 2026-08-01 — is exactly the kind of repair that silently regresses
# the next time the host is rebuilt.
################################################################################
CONSOLE_ENV_PATH_BLOCK='# PATH — LOAD-BEARING. The console shells out to `pl`, and several pl helpers
# guard on `command -v yq`. yq lives in ~/.local/bin, which systemd does NOT
# put on a user service PATH. Without this the guards fall through silently and
# `pl demo invite` renders the invitation with <YOUR-SITE-URL> placeholders.
PATH=%h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

_ensure_env_path() {
    _ssh 'f=$HOME/.config/nwp-console/env
          [ -f "$f" ] || exit 0
          grep -qE "^PATH=" "$f" && exit 0
          umask 077
          {
            printf "\n%s\n" "# PATH - LOAD-BEARING (nwp/ops#173). pl helpers guard on the presence of yq,"
            printf "%s\n"   "# which lives in ~/.local/bin - not on a systemd user service default PATH."
            printf "PATH=%s/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n" "$HOME"
          } >> "$f"
          echo "added PATH to $f"' || {
        print_warning "could not ensure PATH in ~/.config/nwp-console/env on ${CONSOLE_HOST}"
        print_hint    "without it, pl helpers that guard on 'command -v yq' fall through silently (ops#173)"
        return 0
    }
}

# -- gate 1: divergence guard (the 2026-07-25 near miss) ---------------------
# `rsync --delete` is a loaded gun pointed at whatever is on the target. Before
# firing, diff the target against what we are about to deploy and REFUSE when
# the target holds work this change does not explain. See lib/console-deploy.sh.
_deploy_classify() { # $1 outdir -> writes $1/classification; echoes rc
    local out="$1" rc=0
    console_manifest_local "$CONSOLE_SRC" > "$out/local.mf" || return 2
    if ! _ssh "cd nwp-console/src 2>/dev/null && { $CONSOLE_MANIFEST_CMD ; }" > "$out/target.mf" 2>/dev/null; then
        : > "$out/target.mf"      # no target tree yet => first deploy, nothing to lose
    fi
    console_deploy_classify "$out/local.mf" "$out/target.mf" > "$out/classification" || rc=$?
    printf '%s' "$rc"
}

_deploy_backup_target() {
    local stamp; stamp=$(date -u +%Y%m%d-%H%M%S)
    local dest="nwp-console/backups/src-${stamp}.tar.gz"
    print_info "Backing up the target's current tree first -> ~/${dest}"
    if ! _ssh "mkdir -p ~/nwp-console/backups && tar czf ~/${dest} -C ~/nwp-console src"; then
        print_error "backup FAILED — refusing to overwrite an unbacked-up target"
        return 1
    fi
    local size; size=$(_ssh "wc -c < ~/${dest}" 2>/dev/null | tr -d ' ' || true)
    if [ -z "$size" ] || [ "$size" -lt 100 ] 2>/dev/null; then
        print_error "backup looks empty (${size:-none} bytes) — refusing to proceed"
        return 1
    fi
    print_success "backup taken: ~/${dest} (${size} bytes) — restore with: tar xzf ~/${dest} -C ~/nwp-console"
    return 0
}

################################################################################
# gate 2: deploy fate manifest (nwp/ops#47 impact contract — lib/impact.sh)
#
# `pl console deploy` rsyncs with --delete, so it can destroy work that exists
# ONLY on the console host. That is not hypothetical: on 2026-07-25 the host
# was carrying an unpushed local edit and a plain deploy would have taken it
# with no record. The contract's answer is not "be careful next time" — it is
# to COMPUTE what the transfer will do and say it out loud before doing it.
#
# The plan comes from rsync itself: the same command, same flags, same
# excludes, with --dry-run --itemize-changes. A separately-written predictor
# could drift from the real transfer; this one cannot. Fail-closed — if the
# plan can't be computed (host down, ssh refused) the deploy REFUSES rather
# than shipping blind.
################################################################################

# The transfer, defined ONCE so the dry run and the real run cannot diverge.
# .nwp-deployed.json is WRITTEN ON THE TARGET after each rsync (see
# _console_write_marker) and exists in no checkout, so it must be excluded
# here AND in CONSOLE_MANIFEST_CMD (lib/console-deploy.sh) or --delete
# would remove it / the divergence gate would flag it as 'D' every time.
_console_rsync() {  # extra args (e.g. --dry-run) passed through
    rsync -az --delete \
        --exclude '__pycache__' --exclude '*.pyc' --exclude '.pytest_cache' \
        --exclude '.nwp-deployed.json' \
        "$@" "$CONSOLE_SRC/" "$CONSOLE_HOST":nwp-console/src/
}

# Record WHICH commit was just deployed, on the target, beside the app
# (ops#329). Before this marker existed the deployed console version was
# recorded NOWHERE — on 2026-08-09 the console sat stale after a merge and no
# probe could say so. The console's overview reads this file and compares it
# with GitLab main; an ABSENT marker renders "NOT RECORDED", never "in sync".
# Best-effort: a marker failure must not fail a deploy that already shipped.
_console_write_marker() {
    local sha branch dirty="false"
    sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
    branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    [ -n "$(git -C "$REPO_ROOT" status --porcelain -uno -- scripts/console 2>/dev/null)" ] && dirty="true"
    if [ -z "$sha" ]; then
        print_warning "could not resolve HEAD — deploy marker not written (overview will say NOT RECORDED)"
        return 0
    fi
    printf '{"sha":"%s","branch":"%s","dirty":%s,"deployed_at":"%s","by":"%s"}\n' \
        "$sha" "$branch" "$dirty" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(whoami)@$(hostname)" \
        | _ssh 'cat > ~/nwp-console/src/.nwp-deployed.json && chmod 600 ~/nwp-console/src/.nwp-deployed.json' \
        || print_warning "deploy marker write failed — overview will say NOT RECORDED"
}

# Compact "a, b, c … and N more" for a fate line.
_console_names() {  # $1 limit, $2.. names
    local limit="$1"; shift
    local n=$# out=""
    local i=0 f
    for f in "$@"; do
        i=$((i + 1))
        [ "$i" -gt "$limit" ] && break
        out="${out}${out:+, }${f}"
    done
    [ "$n" -gt "$limit" ] && out="${out} … and $((n - limit)) more"
    printf '%s' "$out"
}

# Build + render the manifest for the pending deploy. Sets CONSOLE_FATE to
# delete|overwrite|none so the caller can pick a confirmation strength.
CONSOLE_FATE="none"
_console_deploy_manifest() {
    local plan err mark path line
    plan=$(mktemp); err=$(mktemp)
    if ! _console_rsync --dry-run --itemize-changes >"$plan" 2>"$err"; then
        print_error "Could not compute the deploy plan (rsync --dry-run failed) — REFUSING to deploy blind."
        sed 's/^/    /' "$err" >&2
        rm -f "$plan" "$err"
        return 1
    fi

    local -a dels=() news=() upds=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read -r mark path <<<"$line"
        [ -n "$path" ] || continue
        case "$mark" in
            \*deleting)      dels+=("$path") ;;
            [\<\>]f*+++++++++) news+=("$path") ;;
            [\<\>]f*)          upds+=("$path") ;;
        esac
    done < "$plan"
    rm -f "$plan" "$err"

    impact_reset
    CONSOLE_FATE="none"

    if [ ${#dels[@]} -gt 0 ]; then
        CONSOLE_FATE="delete"
        impact_delete "Remote files" \
            "${#dels[@]} file(s) that exist ONLY on ${CONSOLE_HOST}:nwp-console/src/ — rsync --delete removes them: $(_console_names 8 "${dels[@]}")"
        impact_warn "anything edited or added directly on ${CONSOLE_HOST} under nwp-console/src/ is destroyed by this deploy — if you have been debugging on the host, copy it off FIRST"
    fi
    if [ ${#upds[@]} -gt 0 ]; then
        [ "$CONSOLE_FATE" = "none" ] && CONSOLE_FATE="overwrite"
        impact_overwrite "Remote files" \
            "${#upds[@]} file(s) on ${CONSOLE_HOST} replaced by this checkout ($CONSOLE_SRC): $(_console_names 8 "${upds[@]}")"
    fi
    if [ ${#news[@]} -gt 0 ]; then
        impact_keep "${#news[@]} new file(s) added (nothing of theirs is displaced): $(_console_names 5 "${news[@]}")"
    fi
    if [ ${#dels[@]} -eq 0 ] && [ ${#upds[@]} -eq 0 ] && [ ${#news[@]} -eq 0 ]; then
        impact_keep "Source tree already identical on ${CONSOLE_HOST} — the rsync is a no-op"
    fi

    impact_keep "~/.config/nwp-console/env — runtime config incl. the GitLab pane token; outside the rsync target and never overwritten once it exists"
    impact_keep "~/.config/nwp-console/tls/{fullchain,privkey}.pem and the passkey/user store — deploy never touches them"
    impact_keep "~/nwp-console/venv — updated in place (pip install), never deleted"
    impact_render
}

################################################################################
# cmd_deploy — the two gates, composed.
#
# They answer different questions and BOTH have to be asked, in this order:
#
#   gate 1  divergence guard   "is it safe to proceed AT ALL?"
#           Compares the target's real tree against ours (sha256 + mtime).
#           Work that exists only on the host, or is newer there, is work this
#           deploy cannot explain — REFUSE, unless --force-overwrite, which
#           takes a verified timestamped backup on the target first.
#
#   gate 2  fate manifest      "what EXACTLY will change?"
#           rsync's own --dry-run --itemize-changes, rendered through
#           lib/impact.sh, confirmed at a strength matching the damage.
#
# Gate 1 can say "stop" without gate 2 ever running (nothing to describe if we
# are not going). Gate 2 never runs after a write. -y skips gate 2's PROMPT,
# never its REPORT. --dry-run runs both gates and writes nothing.
################################################################################
cmd_deploy() {
    local restart=true dry_run=false force=false auto_yes=false
    while [ $# -gt 0 ]; do
        case "${1:-}" in
            --no-restart)      restart=false ;;
            --dry-run|-n)      dry_run=true ;;
            --force-overwrite) force=true ;;
            --yes|-y)          auto_yes=true ;;
            "")                : ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
        shift
    done
    # -y answers gate 2's prompt up front; --force-overwrite may also answer it
    # later, but only once the target backup has actually been taken.
    local prompt_answered="$auto_yes"
    print_info "Deploying NWP Console -> ${CONSOLE_HOST}"

    # --- gate 1: divergence guard -------------------------------------------
    print_info "0/5 checking the target for local changes"
    local wk; wk=$(mktemp -d); chmod 700 "$wk"
    # shellcheck disable=SC2064
    trap "rm -rf '$wk'" RETURN
    local crc; crc=$(_deploy_classify "$wk")
    if [ "$crc" = "2" ]; then
        print_error "could not build the deploy manifests — refusing to deploy blind"
        return 1
    fi
    console_deploy_summary "$wk/classification"

    if console_deploy_has_divergence "$wk/classification"; then
        if [ "$force" != true ]; then
            print_error "REFUSING to deploy: ${CONSOLE_HOST} has changes this deploy does not explain."
            print_error "Files marked D exist ONLY on the target and 'rsync --delete' would DESTROY them."
            print_error "Files marked ! are NEWER on the target and would be overwritten."
            print_hint "Look first:      pl console deploy --dry-run"
            print_hint "Rescue the work: ssh ${CONSOLE_HOST} 'cd ~/nwp-console/src && git status' (or scp it back)"
            print_hint "Proceed anyway:  pl console deploy --force-overwrite   (takes a timestamped backup first)"
            return 1
        fi
        print_warning "--force-overwrite: proceeding over target-local changes"
        if [ "$dry_run" != true ]; then
            _deploy_backup_target || return 1
            # --force-overwrite is an explicit, typed-out authorisation for
            # exactly the destruction gate 1 just itemised, and the verified
            # backup above means this is no longer the last copy. So it stands
            # in for gate 2's PROMPT — never for gate 2's REPORT, which is
            # still rendered below (contract rule, ops#47).
            prompt_answered=true
        fi
    fi

    # --- gate 2: fate manifest ----------------------------------------------
    # Computed + printed before ANYTHING is written — including the mkdir, so
    # --dry-run really does leave the host untouched.
    _console_deploy_manifest || return 1

    if [ "$dry_run" = true ]; then
        print_info "--dry-run: nothing was written to ${CONSOLE_HOST} (no rsync, no venv, no restart)"
        print_info "The report above is what a real deploy would do."
        return 0
    fi

    case "$CONSOLE_FATE" in
        # Files only the host has: --delete is their last copy. Typed tier.
        delete)    impact_confirm typed "$CONSOLE_HOST" "$prompt_answered" \
                       || { print_info "Deploy cancelled."; return 1; } ;;
        overwrite) impact_confirm standard "overwrite those files on ${CONSOLE_HOST}" "$prompt_answered" \
                       || { print_info "Deploy cancelled."; return 1; } ;;
        *)         : ;;   # nothing destructive — report printed, no prompt
    esac

    print_info "1/5 rsync source"
    _ssh 'mkdir -p ~/nwp-console/src'
    _console_rsync
    _console_write_marker

    print_info "2/5 venv + deps"
    _ssh 'python3 -m venv ~/nwp-console/venv 2>/dev/null || true;
          ~/nwp-console/venv/bin/pip install -q --upgrade pip;
          ~/nwp-console/venv/bin/pip install -q -r ~/nwp-console/src/requirements.txt'

    print_info "3/5 config + unit"
    _write_default_env
    _ssh 'mkdir -p ~/.config/systemd/user && cp ~/nwp-console/src/nwp-console.service ~/.config/systemd/user/ && systemctl --user daemon-reload'

    if ! _ssh 'test -f ~/.config/nwp-console/tls/fullchain.pem'; then
        print_warning "No TLS cert on ${CONSOLE_HOST} — run 'pl console dns' then 'pl console cert' first."
        print_warning "The service will fail to start until the cert exists (WebAuthn requires HTTPS)."
    fi

    print_info "4/5 enable + restart"
    _ssh 'systemctl --user enable nwp-console >/dev/null 2>&1 || true'
    if [ "$restart" = true ]; then
        _ssh 'systemctl --user restart nwp-console'
        sleep 2
    fi

    print_info "5/5 health check over the mesh"
    if curl -fsS --max-time 8 --resolve "${CONSOLE_FQDN}:${CONSOLE_PORT}:${CONSOLE_TAILNET_IP}" \
            "https://${CONSOLE_FQDN}:${CONSOLE_PORT}/health" | grep -q '"ok"'; then
        print_success "healthy: https://${CONSOLE_FQDN}:${CONSOLE_PORT}/ (mesh-only)"
    else
        print_error "health check failed — try: pl console status / pl console logs"
        return 1
    fi
}

cmd_status() {
    print_info "systemd on ${CONSOLE_HOST}:"
    _ssh 'systemctl --user --no-pager -n 5 status nwp-console' || true
    print_info "health over the mesh:"
    curl -fsS --max-time 8 --resolve "${CONSOLE_FQDN}:${CONSOLE_PORT}:${CONSOLE_TAILNET_IP}" \
        "https://${CONSOLE_FQDN}:${CONSOLE_PORT}/health" && echo || print_error "unreachable"
    print_info "users:"
    _ssh 'cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-list' || true
}

_name_ok() { # local hygiene guard; authoritative validation is in app/store.py
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || { print_error "invalid username: $1"; return 1; }
}

_pid_ok() { # ditto for project ids — these end up in a remote shell command
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || { print_error "invalid project id: $1"; return 1; }
}

_site_ok() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { print_error "invalid site name: $1"; return 1; }
}

# Every token below is regex-checked before it reaches the remote shell, so the
# quoting here is a second line of defence and not the only one. The store on
# the console host re-validates all of it regardless — the authority for what a
# project may contain lives there, never here.
cmd_project() {
    local sub="${1:-}"; shift || true
    local remote="cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage"
    # Gate AFTER the per-branch argument validation below, for the ops#144
    # reason: a bad project id or site name must be rejected on any machine,
    # configured or not, otherwise the guards are dead code on every CI runner.
    _pssh() { _require_configured || return 1; _ssh "$@"; }
    case "$sub" in
        list|"")
            _pssh "$remote project-list"
            ;;
        add|set)
            local pid="${1:-}"; shift || true
            [ -n "$pid" ] || { print_error "usage: pl console project $sub <pid> [--name N] [--sites a b] [--demo-sites a] [--issue-label L] [--ci-projects p]"; return 1; }
            _pid_ok "$pid" || return 1
            local cmd="$remote project-$sub '$pid'" s
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name) cmd+=" --name '${2//\'/}'"; shift 2 ;;
                    --description) cmd+=" --description '${2//\'/}'"; shift 2 ;;
                    --issue-label) cmd+=" --issue-label '${2//\'/}'"; shift 2 ;;
                    --sites|--demo-sites|--ci-projects)
                        local flag="$1"; shift
                        cmd+=" $flag"
                        while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
                            if [ "$flag" = "--ci-projects" ]; then
                                [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] || { print_error "invalid CI project: $1"; return 1; }
                            else
                                _site_ok "$1" || return 1
                            fi
                            cmd+=" '$1'"; shift
                        done
                        ;;
                    *) print_error "unknown flag: $1"; return 1 ;;
                esac
            done
            _pssh "$cmd"
            ;;
        rm)
            [ -n "${1:-}" ] || { print_error "usage: pl console project rm <pid>"; return 1; }
            _pid_ok "$1" || return 1
            print_warning "Deleting a project revokes every membership in it."
            _pssh "$remote project-rm '$1'"
            ;;
        assign)
            local u="${1:-}" pid="${2:-}"; shift 2 2>/dev/null || true
            local role="viewer"
            while [ $# -gt 0 ]; do case "$1" in --role) role="${2:-}"; shift 2 ;; --role=*) role="${1#--role=}"; shift ;; *) shift ;; esac; done
            [ -n "$u" ] && [ -n "$pid" ] || { print_error "usage: pl console project assign <user> <pid> [--role viewer|operator|maintainer]"; return 1; }
            _name_ok "$u" || return 1; _pid_ok "$pid" || return 1
            [[ "$role" =~ ^(viewer|operator|maintainer)$ ]] || { print_error "role must be viewer|operator|maintainer"; return 1; }
            _pssh "$remote project-assign '$u' '$pid' --role '$role'"
            ;;
        unassign)
            local u="${1:-}" pid="${2:-}"
            [ -n "$u" ] && [ -n "$pid" ] || { print_error "usage: pl console project unassign <user> <pid>"; return 1; }
            _name_ok "$u" || return 1; _pid_ok "$pid" || return 1
            _pssh "$remote project-unassign '$u' '$pid'"
            ;;
        export)
            # The console host AUTHORS the project->sites map; the workstation
            # only ever receives a copy. 0600 and gitignored: it names every
            # site of every tenant, which is the fact the boundary protects.
            local out="${1:-$REPO_ROOT/private/project-map.json}"
            mkdir -p "$(dirname "$out")"
            local tmp; tmp="$(mktemp)"; chmod 600 "$tmp"
            if _pssh "$remote project-export" > "$tmp"; then
                mv "$tmp" "$out"; chmod 600 "$out"
                print_success "project map -> $out (0600, gitignored)"
            else
                rm -f "$tmp"; print_error "export failed"; return 1
            fi
            ;;
        *) print_error "unknown: pl console project $sub"; return 1 ;;
    esac
}

# Argument validation runs BEFORE _require_configured (see main()): bad input is
# rejected on its own merits, on any machine, configured or not. Ordering it the
# other way round made the guards below dead code everywhere nwp.yml is absent —
# e.g. every CI runner — so they were never actually exercised.
# ---------------------------------------------------------------------------
# Passkey enrolment ceremony — pl console user addkey <name>
#
# Two steps of a WebAuthn enrolment cannot be scripted: a browser has to run
# the ceremony, and a finger has to touch the key. EVERYTHING around them can,
# and was previously a hand-copied runbook: check the mesh is up, check a key
# is even plugged in, issue the token, open the tab, and then WATCH the store
# until the credential lands.
#
# That last step is the one worth having. Without it "did that work?" is
# answered by a second command nobody runs, so an abandoned ceremony and a
# completed one look identical. Here the command does not return 0 until the
# passkey count on the host actually went up.
#
# It does NOT prove WHICH authenticator answered — the store holds only the
# credential id, public key and sign count, so a platform passkey saved on
# this laptop counts the same as a touch on the hardware key. Recording the
# AAGUID/transports at enrol time would fix that; today the browser prompt is
# the only place that distinction is made.
# ---------------------------------------------------------------------------
_console_health() {
    curl -fsS --max-time 8 --resolve "${CONSOLE_FQDN}:${CONSOLE_PORT}:${CONSOLE_TAILNET_IP}" \
        "https://${CONSOLE_FQDN}:${CONSOLE_PORT}/health" 2>/dev/null | grep -q '"ok"'
}

_passkey_count() { # $1 name -> integer on stdout, empty if the user is unknown
    _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-show '$1' 2>/dev/null" \
        2>/dev/null | awk '/^passkeys:/ {print $2; exit}'
}

_enrol_wait() { # $1 name, $2 baseline count, $3 timeout seconds
    # ONE ssh holding a remote poll loop — not N ssh handshakes on a timer.
    local name="$1" base="$2" rounds=$(( ${3:-300} / 3 ))
    _ssh "cd ~/nwp-console/src && i=0; while [ \$i -lt $rounds ]; do
            c=\$(~/nwp-console/venv/bin/python -m app.manage user-show '$name' 2>/dev/null \
                 | awk '/^passkeys:/{print \$2; exit}');
            if [ -n \"\$c\" ] && [ \"\$c\" -gt $base ] 2>/dev/null; then echo \"ENROLLED \$c\"; exit 0; fi;
            i=\$((i+1)); sleep 3; done; echo TIMEOUT; exit 1"
}

cmd_addkey() {
    local name="${1:-}"; shift || true
    local do_open=1 do_wait=1 timeout=300 qr=0
    while [ $# -gt 0 ]; do case "$1" in
        --no-open)   do_open=0; shift ;;
        --no-wait)   do_wait=0; shift ;;
        --qr)        qr=1; do_open=0; shift ;;   # phone enrolment: never open it here
        --timeout)   timeout="${2:-}"; shift 2 ;;
        --timeout=*) timeout="${1#--timeout=}"; shift ;;
        *) print_error "unknown flag: $1 (want --no-open | --qr | --no-wait | --timeout <secs>)"; return 1 ;;
    esac; done
    [ -n "$name" ] || { print_error "usage: pl console user addkey <name> [--no-open|--qr] [--no-wait] [--timeout <secs>]"; return 1; }
    _name_ok "$name" || return 1
    [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -ge 30 ] || { print_error "--timeout must be seconds, >= 30"; return 1; }
    _require_configured || return 1

    print_info "1/4 console reachable over the mesh"
    _console_health || {
        print_error "console unreachable at https://${CONSOLE_FQDN}:${CONSOLE_PORT}/ — is the VPN app connected?"
        print_hint "diagnose with: pl console status"
        return 1
    }
    print_success "healthy: https://${CONSOLE_FQDN}:${CONSOLE_PORT}/"

    # Informational only — the key may be on the phone you are about to use.
    if command -v fido2-token >/dev/null 2>&1; then
        local keys; keys=$(fido2-token -L 2>/dev/null || true)
        if [ -n "$keys" ]; then
            print_info "FIDO2 device(s) on THIS machine:"; printf '    %s\n' "$keys"
        else
            print_hint "no FIDO2 device on this machine — plug the key in, or enrol on another device with --no-open"
        fi
    fi

    print_info "2/4 issuing a one-time enrolment token (existing passkeys are KEPT)"
    local before; before=$(_passkey_count "$name")
    [ -n "$before" ] || { print_error "no such console user: $name"; print_hint "pl console user list"; return 1; }
    local out link
    out=$(_ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-addkey '$name'") || return 1
    link=$(printf '%s\n' "$out" | grep -o "https://[^[:space:]]*enroll?token=[A-Za-z0-9_-]*" | head -1)
    [ -n "$link" ] || { printf '%s\n' "$out"; print_error "could not parse an enrolment link out of that"; return 1; }
    echo
    echo "    $link"
    echo
    print_hint "single use, 48 h, stored hashed on the host — it cannot be re-shown"

    # Enrolling a PHONE means getting a 43-char token onto it. Typing it is the
    # step people give up on, so offer the camera instead.
    if [ "$qr" = 1 ]; then
        if command -v qrencode >/dev/null 2>&1; then
            print_info "3/4 scan this with the phone's camera (it is already on the mesh, yes?)"
            qrencode -t ANSIUTF8 -m 2 "$link"
        else
            print_error "qrencode not installed — install it with: sudo apt install qrencode"
            print_hint "or send yourself the link above; it stays valid for 48 h"
        fi
    elif [ "$do_open" = 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then
        print_info "3/4 opening it in your browser"
        # The token sits in xdg-open's argv for the moment it runs. Accepted
        # rather than worked around: it is single-use, 48 h, mesh-only, and is
        # already printed on this terminal — unlike the API tokens the 0600
        # curl-config pattern exists for.
        xdg-open "$link" >/dev/null 2>&1 &
    else
        print_info "3/4 open that link on the device holding the key (it must be on the mesh)"
    fi
    # Which answer is RIGHT at the browser's "where do you want to save this?"
    # prompt depends entirely on what you are enrolling, so say the one that
    # matches the mode rather than a generic line that is wrong half the time.
    if [ "$qr" = 1 ] || [ "$do_open" = 0 ]; then
        print_hint "on that device, save it as a passkey ON the device (face/fingerprint) — that is the"
        print_hint "right answer for a phone; 'security key' would ask you for a USB key it cannot reach."
    else
        print_hint "when the browser asks WHERE to save it, choose the SECURITY KEY — 'this device' makes a"
        print_hint "platform passkey on this laptop instead of using the hardware key. Then touch the key."
    fi
    print_hint "A key that is already enrolled is refused by the browser (excludeCredentials)."

    if [ "$do_wait" = 0 ]; then
        print_hint "not waiting (--no-wait). Confirm with: pl console user show $name"
        return 0
    fi

    print_info "4/4 waiting for the credential to land on the host (up to ${timeout}s)"
    print_hint "Ctrl-C is safe — it stops watching, it does not revoke anything, and the link stays valid"
    local res
    if res=$(_enrol_wait "$name" "$before" "$timeout"); then
        print_success "enrolled — '$name' now has $(printf '%s' "$res" | awk '{print $2}') passkey(s), none revoked"
        print_hint "verify any time: pl console user show $name"
    else
        print_error "timed out — '$name' is still on $before passkey(s). Nothing was revoked."
        print_hint "the link above is still valid; re-open it, or re-run: pl console user addkey $name"
        return 1
    fi
}

cmd_user() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        add)
            local name="${1:-}"; shift || true
            local role="viewer" project="" prole="viewer"
            while [ $# -gt 0 ]; do case "$1" in
                --role) role="${2:-}"; shift 2 ;;
                --role=*) role="${1#--role=}"; shift ;;
                --project) project="${2:-}"; shift 2 ;;
                --project=*) project="${1#--project=}"; shift ;;
                --project-role) prole="${2:-}"; shift 2 ;;
                --project-role=*) prole="${1#--project-role=}"; shift ;;
                *) shift ;;
            esac; done
            [ -n "$name" ] || { print_error "usage: pl console user add <name> --role viewer|operator|owner [--project <pid>]"; return 1; }
            _name_ok "$name" || return 1
            [[ "$role" =~ ^(viewer|operator|owner)$ ]] || { print_error "role must be viewer|operator|owner"; return 1; }
            local extra=""
            if [ -n "$project" ]; then
                _pid_ok "$project" || return 1
                [[ "$prole" =~ ^(viewer|operator|maintainer)$ ]] || { print_error "--project-role must be viewer|operator|maintainer"; return 1; }
                extra=" --project '$project' --project-role '$prole'"
            fi
            _require_configured || return 1
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-add '$name' --role '$role'$extra"
            print_hint "Their device must be on the mesh first — see: pl console enroll"
            if [ -z "$project" ]; then
                # Say it out loud rather than let someone create an account that
                # silently sees nothing: with projects configured, no membership
                # means the /no-project page and an empty console, forever.
                print_hint "No --project given. If any project exists, this account sees NOTHING until:"
                print_hint "  pl console project assign $name <pid> --role viewer"
            fi
            ;;
        keys)
            [ -n "${1:-}" ] || { print_error "usage: pl console user keys <name>"; return 1; }
            _name_ok "$1" || return 1
            _require_configured || return 1
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-keys '$1'"
            ;;
        rmkey)
            # Revoke ONE passkey. The store refuses the last one — that is a
            # lockout, and `reset` is the verb that means it (it hands back an
            # enrolment link in the same breath).
            [ -n "${2:-}" ] || { print_error "usage: pl console user rmkey <name> <handle>   (handles: pl console user keys <name>)"; return 1; }
            _name_ok "$1" || return 1
            [[ "$2" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || { print_error "invalid handle: $2"; return 1; }
            _require_configured || return 1
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-rmkey '$1' '$2'"
            ;;
        show)
            [ -n "${1:-}" ] || { print_error "usage: pl console user show <name>"; return 1; }
            _name_ok "$1" || return 1
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-show '$1'"
            ;;
        addkey)
            # Second passkey (hardware key beside a phone, or a new device).
            # Deliberately NOT reset: revoking the credential you are holding
            # to add another one is the wrong trade for the everyday case.
            cmd_addkey "$@"
            ;;
        reset)
            [ -n "${1:-}" ] || { print_error "usage: pl console user reset <name>"; return 1; }
            _name_ok "$1" || return 1
            _require_configured || return 1
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-reset '$1'"
            ;;
        role)
            [ -n "${2:-}" ] || { print_error "usage: pl console user role <name> <role>"; return 1; }
            _name_ok "$1" || return 1
            [[ "$2" =~ ^(viewer|operator|owner)$ ]] || { print_error "role must be viewer|operator|owner"; return 1; }
            _require_configured || return 1
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-role '$1' '$2'"
            ;;
        rm)
            [ -n "${1:-}" ] || { print_error "usage: pl console user rm <name>"; return 1; }
            _name_ok "$1" || return 1
            _require_configured || return 1
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-rm '$1'"
            ;;
        list|"")
            _require_configured || return 1
            _ssh 'cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-list'
            ;;
        *) print_error "unknown: pl console user $sub"; return 1 ;;
    esac
}

_enroll_steps() { # $1 optional pre-auth key
    local key="${1:-}"
    cat <<EOF

${BOLD}On the device (phone or laptop), once:${NC}

 1. Install the Tailscale app.
 2. Set the CUSTOM CONTROL SERVER to:
      ${HEADSCALE_URL}
    (Android/iOS: menu -> Settings -> Accounts -> "Use an alternate server".)
 3. Sign in with the pre-auth key$([ -n "$key" ] && printf ' above' || printf '').
 4. Verify: https://${CONSOLE_FQDN}:${CONSOLE_PORT}/health -> {"ok":true}

Then give that device a passkey:
    pl console user addkey <name> --no-open      # open the printed link ON the device
New person rather than a new device of yours:
    pl console user add <name> --role viewer     # then addkey for their device
EOF
}

cmd_enroll() {
    # Was a printed runbook that named the CONSOLE host as the headscale host.
    # It was wrong, and a runbook nobody can execute is worse than no runbook —
    # so this now mints the key itself, from the configured control-plane host.
    local expiry="1h" runbook=0
    while [ $# -gt 0 ]; do case "$1" in
        --expiry)   expiry="${2:-1h}"; shift 2 ;;
        --expiry=*) expiry="${1#--expiry=}"; shift ;;
        --runbook)  runbook=1; shift ;;
        *) print_error "unknown flag: $1 (want --expiry <dur> | --runbook)"; return 1 ;;
    esac; done
    [[ "$expiry" =~ ^[0-9]+[mhd]$ ]] || { print_error "--expiry wants a duration like 1h, 30m, 7d"; return 1; }

    if [ "$runbook" = 1 ] || [ -z "$HEADSCALE_HOST" ] || [ -z "$HEADSCALE_USER" ]; then
        if [ "$runbook" != 1 ]; then
            print_error "settings.console.{headscale_host,headscale_user} not set in nwp.yml — cannot mint a key"
            print_hint "headscale runs on the box holding the PUBLIC control endpoint, not necessarily ${CONSOLE_HOST}"
            print_hint "find it with: headscale users list   (on that box)"
        fi
        print_info "Create the pre-auth key yourself on the headscale host:"
        # headscale >= 0.26 takes a NUMERIC id here and rejects a name outright
        # ("strconv.ParseUint"). The mint path resolves that for the operator;
        # the manual path has to tell them, or the runbook fails the same way
        # the old one did.
        echo "    sudo headscale users list                 # note the numeric id"
        echo "    sudo headscale preauthkeys create --user <numeric-user-id> --expiration ${expiry}"
        _enroll_steps
        [ "$runbook" = 1 ] && return 0 || return 1
    fi

    # headscale >= 0.26 takes a numeric user ID on --user and rejects the name
    # outright ("strconv.ParseUint"). The config names a HUMAN user, so resolve
    # it here rather than making the operator store an integer that changes if
    # the user is ever recreated.
    local uid="$HEADSCALE_USER"
    if ! [[ "$uid" =~ ^[0-9]+$ ]]; then
        uid=$(ssh -o ConnectTimeout=10 "$HEADSCALE_HOST" \
                "sudo -n headscale users list -o json 2>/dev/null" \
              | python3 -c "import json,sys;u='$HEADSCALE_USER';print(next((str(x['id']) for x in json.load(sys.stdin) if x.get('name')==u),''))" 2>/dev/null) || true
        [ -n "$uid" ] || {
            print_error "headscale user '${HEADSCALE_USER}' not found on ${HEADSCALE_HOST}"
            print_hint "list them with: ssh ${HEADSCALE_HOST} 'sudo -n headscale users list'"
            return 1
        }
    fi

    print_info "minting a ${expiry} pre-auth key on ${HEADSCALE_HOST} (headscale user '${HEADSCALE_USER}' = id ${uid})"
    local key
    key=$(ssh -o ConnectTimeout=10 "$HEADSCALE_HOST" \
            "sudo -n headscale preauthkeys create --user '$uid' --expiration '$expiry' 2>/dev/null" \
          | tr -d '\r' | grep -oE '(hskey-auth-)?[A-Za-z0-9_-]{40,}' | tail -1) || true
    if [ -z "$key" ]; then
        print_error "no key came back from ${HEADSCALE_HOST}"
        print_hint "check: ssh ${HEADSCALE_HOST} 'sudo -n headscale users list'  (passwordless sudo? right user?)"
        return 1
    fi
    echo
    echo "    $key"
    echo
    print_hint "single device, expires in ${expiry} — mint another any time with: pl console enroll"
    _enroll_steps "$key"
    print_hint "Second dev, not your own device? Also add a headscale ACL pinning their node to"
    print_hint "${CONSOLE_TAILNET_IP}:${CONSOLE_PORT} only — console port, not ssh, not the whole mesh."
}

cmd_logs() {
    _ssh 'tail -n 100 ~/nwp-console/console.log'
}

main() {
    local sub="${1:-}"; shift || true
    # global --host override
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --host)   CONSOLE_HOST="${2:-}"; shift 2 ;;
            --host=*) CONSOLE_HOST="${1#--host=}"; shift ;;
            *) args+=("$1"); shift ;;
        esac
    done
    # ${args[@]+"${args[@]}"} — NOT "${args[@]:-}". On an EMPTY array the latter
    # expands to one empty-string argument, which every parser below reads as a
    # flag it does not know.
    #
    # `enroll` had it worse still: it was dispatched with no arguments at all.
    # So --runbook (the offline path, for when the mesh is the broken thing)
    # silently took the NETWORK path, and --expiry never reached its validator —
    # `pl console enroll --expiry forever` did not refuse, it minted a live
    # pre-auth key on the production control plane with the default expiry.
    # Reproduced on the workstation 2026-08-01; eight unredeemed keys from that
    # and from the feature's own testing were expired by hand.
    #
    # CI never minted: the runner has no nwp.yml (gitignored), so HEADSCALE_HOST
    # is empty there and enroll takes the fallback branch. That is why the two
    # bats cases failed in CI with the FALLBACK text rather than by minting —
    # they were red for the real defect, by a different route.
    case "$sub" in
        -h|--help|"") show_help ;;
        deploy)  _require_configured && cmd_deploy ${args[@]+"${args[@]}"} ;;
        status)  _require_configured && cmd_status ;;
        user)    cmd_user ${args[@]+"${args[@]}"} ;;      # gates itself AFTER validating input
        project) cmd_project ${args[@]+"${args[@]}"} ;;   # ditto
        enroll)  cmd_enroll ${args[@]+"${args[@]}"} ;;
        dns)     _require_configured && cmd_dns ;;
        cert)    _require_configured && cmd_cert ;;
        logs)    _require_configured && cmd_logs ;;
        *) print_error "Unknown subcommand: $sub"; show_help; return 1 ;;
    esac
}

main "$@"
