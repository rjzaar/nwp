#!/usr/bin/env bash
#
# pl forge — the sanctioned way to work on the forge box (the `gitlab-host`
# role),
# across both of its planes (ops#331, ADR-0038).
#
# WHY THIS EXISTS. The forge box had exactly one credential — an unrestricted
# key in ~gitlab/.ssh/authorized_keys, where `gitlab` carries
# `(ALL) NOPASSWD: ALL` — so *every* interaction with it, down to reading how
# much RAM is free, authenticated as root-on-box. ADR-0038 splits that into
# named, scoped identities; this verb is what makes the split real, because a
# scheme that only exists in an authorized_keys file is a scheme the next
# session routes around with a raw `ssh`.
#
# THE TWO PLANES
#   BOX plane      Linux. Read-only words go over the JAILED probe key
#                  (nwp-forge-probe → /usr/local/bin/forge-probe-restricted);
#                  writes go over the named full-control key (nwp-forge-ops).
#   APPLICATION    GitLab REST. Users, SSH keys, memberships, CI variables,
#   plane          deploy keys. Needs the forge-admin PAT, which the OPERATOR
#                  mints (ADR-0038 plane 2). Until it exists, every verb here
#                  that needs it REFUSES BY NAME — never a crash, never a silent
#                  skip, never a guess.
#
# INVARIANTS
#   * Read-only by default. Every write is dry-run-by-default + typed confirm.
#   * The token NEVER appears in argv or the environment of a child process —
#     0600 curl-config file, the `cmd_whose` pattern.
#   * Fail closed: cannot measure ⇒ exit 2 CANNOT VERIFY. Never exit 0, never a
#     substituted literal.
#   * No gitlab-rails / gitlab-rake, ever. This box OOM-killed itself for 5-8
#     minutes on 2026-07-25; application administration goes through the REST
#     API, which runs inside the already-resident puma.
#   * SSH is invoked with FULL identity isolation — see _forge_ssh.
#
# Exit codes: 0 ok · 1 failure/refused-write · 2 CANNOT VERIFY (incl. absent
#             credential) · 3 host unreachable
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NWP_DIR="${NWP_DIR:-$PROJECT_ROOT}"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true

FORGE_SERVER="${NWP_FORGE_SERVER:-nwpcode}"
FORGE_USER="${NWP_FORGE_USER:-gitlab}"
OPS_KEY="${NWP_FORGE_OPS_KEY:-$HOME/.ssh/nwp-forge-ops}"
PROBE_KEY="${NWP_FORGE_PROBE_KEY:-$HOME/.ssh/nwp-forge-probe}"
LEGACY_KEY="${NWP_FORGE_LEGACY_KEY:-$HOME/.ssh/gitlab_linode}"
ADMIN_TOKEN_FILE="${NWP_FORGE_ADMIN_TOKEN:-$HOME/.config/nwp/forge-admin.token}"
ADMIN_REGISTRY_ID="gitlab_forge_admin"
# Resolved from servers/<forge>/.nwp-server.yml, never hardcoded: a literal
# internal FQDN in a tracked file is both a leak (the gitleaks operator ruleset
# refuses it) and a lie waiting to happen if the forge ever moves.
_forge_api_host() {
    local d=""
    declare -F get_server_domain >/dev/null && d="$(get_server_domain "$FORGE_SERVER" 2>/dev/null)"
    [ -n "$d" ] && { printf 'git.%s' "$d"; return 0; }
    return 1
}
FORGE_API_HOST="${NWP_FORGE_API_HOST:-$(_forge_api_host || true)}"

# The words the box-plane wrapper accepts. Held here as well as on the box so a
# typo is refused locally with a useful message instead of costing a round trip
# — and so this file documents the jail it depends on.
PROBE_WORDS="status health services certs backups forge-version disk keys logs-nginx logs-gitlab logs-auth help"

################################################################################
# Resolution + transport
################################################################################

_forge_host() {
    local ip=""
    declare -F get_server_ip >/dev/null && ip="$(get_server_ip "$FORGE_SERVER" 2>/dev/null)"
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    print_error "CANNOT VERIFY: cannot resolve '${FORGE_SERVER}' from servers/${FORGE_SERVER}/.nwp-server.yml" >&2
    print_hint "in a git worktree? the identity file is gitignored — see ops#331's fix to \`pl issue work\`" >&2
    return 2
}

# ⚠️ THE ISOLATION FLAGS ARE LOAD-BEARING.
# ~/.ssh/config supplies `IdentityFile ~/.ssh/gitlab_linode` for this host, and
# `IdentitiesOnly=yes` does NOT exclude config-supplied identity files — only
# extra AGENT keys. So `ssh -o IdentitiesOnly=yes -i <probe key> gitlab@<box> id`
# authenticated as gitlab_linode and printed a root-capable `uid=…` line while
# the probe key was not installed anywhere at all (measured 2026-08-10). Without
# -F /dev/null every jail check in this file would be a fake green, and
# `pl forge doctor` would report an identity that does not exist as working.
_forge_ssh() { # keyfile  [remote words…]
    local key="$1"; shift
    local host; host="$(_forge_host)" || return 2
    ssh -F /dev/null \
        -o IdentitiesOnly=yes -o IdentityAgent=none \
        -o BatchMode=yes -o ConnectTimeout=20 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
        -i "$key" "${FORGE_USER}@${host}" "$@"
}

_need_key() { # keyfile  name
    [ -r "$1" ] && return 0
    print_error "CANNOT VERIFY: the ${2} key is absent (${1})"
    print_hint "generate + install:  bash servers/${FORGE_SERVER}/forge/install-forge-identities.sh --execute"
    return 2
}

# Run one allowlisted read-only word over the JAILED key.
_probe() { # word
    local word="$1"
    case " $PROBE_WORDS " in
        *" $word "*) ;;
        *) print_error "not a probe word: ${word}"; print_hint "allowed: ${PROBE_WORDS}"; return 2 ;;
    esac
    _need_key "$PROBE_KEY" "read-only probe" || return 2
    _forge_ssh "$PROBE_KEY" "$word"
}

################################################################################
# Application plane — credential handling (0600 curl-config; never in argv)
################################################################################

_admin_token_present() { [ -s "$ADMIN_TOKEN_FILE" ]; }

# The named refusal. This is the state the verb lives in until the operator
# mints the PAT, so it has to be genuinely useful: what is missing, where it is
# looked for, and the exact next command.
_refuse_no_admin() {
    print_error "CANNOT VERIFY: no forge-admin credential — this verb needs the GitLab application plane"
    echo "  looked in:   ${ADMIN_TOKEN_FILE}"
    echo "  registry id: ${ADMIN_REGISTRY_ID}"
    echo "  why:         SSH to this box is jailed to git verbs (\`ssh git@… id\` → 'Disallowed"
    echo "               command'), so user/key/membership/CI-variable work has no SSH path at"
    echo "               all — it is REST-only, and REST needs an admin token."
    echo
    print_hint "OPERATOR step (ADR-0038 plane 2), then re-run:"
    echo "    pl secrets steps ${ADMIN_REGISTRY_ID}"
    return 2
}

# curl against the forge with the token supplied via a 0600 config file, so it
# never appears in argv (visible in `ps`) nor in any error message.
# NOTE: _api is always called inside $( ), so it must print NOTHING but the
# response. It therefore returns 2 for "no credential" and leaves the REFUSAL to
# the caller — an earlier draft called _refuse_no_admin here and the message was
# captured as a response body, so the operator saw one bare ERROR line and none
# of the instructions. Callers gate with _admin_token_present FIRST.
_api() { # method  path  [curl args…]
    local method="$1" path="$2"; shift 2
    _admin_token_present || return 2
    [ -n "$FORGE_API_HOST" ] || return 2
    local cfg; cfg="$(mktemp)"; chmod 600 "$cfg"
    # `header` in a curl config file: the value is read from the file, never
    # passed on the command line.
    { printf 'header = "PRIVATE-TOKEN: %s"\n' "$(head -1 "$ADMIN_TOKEN_FILE")"
      printf 'silent\nshow-error\n'; } > "$cfg"
    local out rc
    out="$(curl -K "$cfg" -X "$method" -w '\n%{http_code}' \
           "https://${FORGE_API_HOST}/api/v4${path}" "$@" 2>&1)"; rc=$?
    shred -u "$cfg" 2>/dev/null || rm -f "$cfg"
    printf '%s' "$out"
    return $rc
}

_api_code() { printf '%s' "$1" | tail -1; }
_api_body() { printf '%s' "$1" | sed '$d'; }

# Is the credential in play actually an instance admin? Probed against an
# ADMIN-ONLY endpoint. `GET /users` is NOT admin-only — every authenticated user
# may call it — which is why `pl secrets capabilities` printed "admin: yes" for
# ten tokens including four that 404 on everything else (ops#331, ops#214).
_is_admin() {
    local r; r="$(_api GET /application/settings)" || return 2
    [ "$(_api_code "$r")" = "200" ]
}

################################################################################
# Verbs — box plane
################################################################################

cmd_health()  { _probe health; }
cmd_status()  { _probe status; }
cmd_services(){ _probe services; }
cmd_certs()   { _probe certs; }
cmd_backups() { _probe backups; }
cmd_disk()    { _probe disk; }
cmd_authorized_keys(){ _probe keys; }
cmd_version() { _probe forge-version; }

cmd_logs() {
    local src=""
    for a in "$@"; do
        case "$a" in
            --source=*) src="${a#--source=}" ;;
            *) print_error "Unknown option: $a"; return 2 ;;
        esac
    done
    case "$src" in
        nginx|gitlab|auth) ;;
        "") print_error "usage: pl forge logs --source=nginx|gitlab|auth"; return 2 ;;
        *)  print_error "unknown log source '${src}' — the set is FIXED: nginx|gitlab|auth"
            print_hint "the tail length is fixed at 200 on the box: a caller cannot choose it"
            return 2 ;;
    esac
    _probe "logs-${src}"
}

cmd_run() {
    local word="${1:-}"
    [ -n "$word" ] || { print_error "usage: pl forge run <word>"; print_hint "words: ${PROBE_WORDS}"; return 2; }
    _probe "$word"
}

################################################################################
# doctor — which identities exist, which WORK, which are absent
################################################################################

cmd_doctor() {
    local live=0 a
    for a in "$@"; do [ "$a" = "--live" ] && live=1; done
    local host; host="$(_forge_host)" || return 2
    print_header "pl forge doctor — ${FORGE_USER}@${host}"

    local issues=0
    _row() { printf '  %-22s %-10s %s\n' "$1" "$2" "$3"; }
    _row IDENTITY STATE DETAIL

    # --- box plane ---------------------------------------------------------
    local k
    for k in "ops:${OPS_KEY}" "probe:${PROBE_KEY}" "legacy:${LEGACY_KEY}"; do
        local name="${k%%:*}" file="${k#*:}"
        if [ -r "$file" ]; then _row "nwp-forge-${name}" present "$file"
        else _row "nwp-forge-${name}" ABSENT "$file"; [ "$name" = legacy ] || issues=$((issues+1)); fi
    done

    # --- application plane -------------------------------------------------
    if _admin_token_present; then
        if _is_admin; then _row "forge-admin PAT" "ADMIN" "$ADMIN_TOKEN_FILE"
        else _row "forge-admin PAT" "NOT-ADMIN" "present but /application/settings is not 200 — wrong token?"; issues=$((issues+1)); fi
    else
        _row "forge-admin PAT" "not minted" "$ADMIN_TOKEN_FILE (OPERATOR: pl secrets steps ${ADMIN_REGISTRY_ID})"
    fi

    [ "$live" -eq 1 ] || {
        echo
        print_hint "add --live to prove the jail over the wire (refusals + in-scope reads)"
        [ "$issues" -eq 0 ] && return 0 || return 2
    }

    # --- live proof --------------------------------------------------------
    echo
    print_header "live jail proof (over the wire)"
    _need_key "$PROBE_KEY" "read-only probe" || return 2
    local pass=0 fail=0 out rc

    # REFUSALS. Each asserts the ERROR TEXT and the ABSENCE of the effect, not
    # merely a non-zero exit — "it exited non-zero" is the blind-negation shape
    # that let seven security checks go green over a tree with no validation.
    local c
    for c in 'id' 'sudo -n id' 'status; id' 'cat ../../etc/shadow' 'logs-nginx 500000' 'gitlab-rails runner 1'; do
        out="$(_forge_ssh "$PROBE_KEY" "$c" 2>&1)"; rc=$?
        if [ "$rc" -eq 2 ] && grep -q 'REFUSED' <<<"$out" && ! grep -q 'uid=' <<<"$out"; then
            pass=$((pass+1)); printf '  %-34s REFUSED (rc=2, nothing executed)\n' "$c"
        else
            fail=$((fail+1)); printf '  %-34s ${RED}UNEXPECTED${NC} rc=%s\n' "$c" "$rc"
        fi
    done
    # No shell at all.
    out="$(_forge_ssh "$PROBE_KEY" 2>&1)"; rc=$?
    if grep -q 'forge-probe (READ-ONLY)' <<<"$out" && ! grep -q 'uid=' <<<"$out"; then
        pass=$((pass+1)); printf '  %-34s no shell — resolves to `status`\n' '(empty command)'
    else fail=$((fail+1)); printf '  %-34s UNEXPECTED\n' '(empty command)'; fi

    # IN-SCOPE reads must WORK — a jail that blocks the legitimate work is also
    # broken, just less loudly.
    local w
    for w in health services disk keys; do
        out="$(_forge_ssh "$PROBE_KEY" "$w" 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf '  %-34s ok\n' "$w"
        else fail=$((fail+1)); printf '  %-34s rc=%s (2 = CANNOT VERIFY, a real gap)\n' "$w" "$rc"; fi
    done

    # Full control on the ops key.
    if [ -r "$OPS_KEY" ]; then
        out="$(_forge_ssh "$OPS_KEY" 'id && sudo -n id' 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ] && grep -q 'uid=0' <<<"$out"; then
            pass=$((pass+1)); printf '  %-34s shell + sudo (as designed)\n' 'nwp-forge-ops'
        else fail=$((fail+1)); printf '  %-34s UNEXPECTED rc=%s\n' 'nwp-forge-ops' "$rc"; fi
    fi

    echo
    printf '  live: %s pass, %s fail\n' "$pass" "$fail"
    [ "$fail" -eq 0 ] && [ "$issues" -eq 0 ] && return 0
    return 2
}

cmd_whoami() {
    if ! _admin_token_present; then
        print_warning "application plane: no credential (${ADMIN_TOKEN_FILE})"
        echo "  box plane: $( [ -r "$OPS_KEY" ] && echo 'nwp-forge-ops present' || echo 'nwp-forge-ops ABSENT' )" \
             "· $( [ -r "$PROBE_KEY" ] && echo 'nwp-forge-probe present' || echo 'nwp-forge-probe ABSENT' )"
        return 2
    fi
    local r; r="$(_api GET /user)" || return 2
    [ "$(_api_code "$r")" = "200" ] || { print_error "CANNOT VERIFY: /user returned $(_api_code "$r")"; return 2; }
    local body; body="$(_api_body "$r")"
    printf '  username   %s\n' "$(sed -n 's/.*"username":"\([^"]*\)".*/\1/p' <<<"$body" | head -1)"
    printf '  id         %s\n' "$(sed -n 's/.*"id":\([0-9]*\).*/\1/p' <<<"$body" | head -1)"
    # is_admin in the /user body is NOT authoritative for non-admin tokens; the
    # discriminating check is the admin-only endpoint.
    if _is_admin; then printf '  admin      YES (GET /application/settings = 200)\n'
    else               printf '  admin      no  (GET /application/settings != 200)\n'; fi
}

################################################################################
# Verbs — application plane. Present, and refusing by name until the PAT exists.
################################################################################

_read_only_api() { # description  path
    _admin_token_present || { _refuse_no_admin; return 2; }
    local r; r="$(_api GET "$2")" || return 2
    local code; code="$(_api_code "$r")"
    [ "$code" = "200" ] || { print_error "CANNOT VERIFY: ${1} returned HTTP ${code}"; return 2; }
    _api_body "$r"
}

cmd_users() {
    case "${1:-list}" in
        list) _read_only_api "users" "/users?per_page=50&without_project_bots=true" ;;
        show) [ -n "${2:-}" ] || { print_error "usage: pl forge users show <username>"; return 2; }
              _read_only_api "user ${2}" "/users?username=${2}" ;;
        *) print_error "usage: pl forge users list|show <username>"; return 2 ;;
    esac
}

cmd_keys() {
    case "${1:-list}" in
        list) local u="${2:-}"
              if [ -n "$u" ]; then _read_only_api "keys of ${u}" "/users/${u}/keys"
              else _read_only_api "own keys" "/user/keys"; fi ;;
        add|delete)
            _admin_token_present || { _refuse_no_admin; return 2; }
            print_error "not yet implemented: \`pl forge keys ${1}\` is the ops#331 rehoming step"
            print_hint "it lands with the credential (ADR-0038 §Migration step 3), red-then-green, with a typed confirm"
            return 2 ;;
        *) print_error "usage: pl forge keys list [<user>] | add | delete"; return 2 ;;
    esac
}

cmd_members() {
    case "${1:-list}" in
        list) [ -n "${2:-}" ] || { print_error "usage: pl forge members list <project>"; return 2; }
              _read_only_api "members" "/projects/${2//\//%2F}/members/all?per_page=50" ;;
        add)  _admin_token_present || { _refuse_no_admin; return 2; }
              print_error "not yet implemented: write verbs land with the credential (ADR-0038 §Migration)"; return 2 ;;
        *) print_error "usage: pl forge members list <project> | add"; return 2 ;;
    esac
}

cmd_ci_var() {
    case "${1:-list}" in
        list) [ -n "${2:-}" ] || { print_error "usage: pl forge ci-var list <project>"; return 2; }
              _read_only_api "ci variables" "/projects/${2//\//%2F}/variables" ;;
        set)  _admin_token_present || { _refuse_no_admin; return 2; }
              # ADR-0038 makes this a NAMED prohibition rather than a habit: the
              # nwc-project pipeline has an unactivated sign:minisign job whose
              # variables would put the minisign SECRET KEY and its PASSWORD on
              # met — an AI host — collapsing the one property that keeps forge
              # control away from prod.
              if [ "${3:-}" = "MINISIGN_SECRET_KEY" ] || [ "${3:-}" = "MINISIGN_PASSWORD" ]; then
                  print_error "REFUSED: ${3} must never be set as a CI variable (ADR-0038 §minisign)"
                  echo "  Setting it would place the artifact-signing secret on an AI-run runner and"
                  echo "  break 'trust flows through signatures, not machines' — the property that"
                  echo "  makes forge control safe to grant at all."
                  return 1
              fi
              print_error "not yet implemented: write verbs land with the credential (ADR-0038 §Migration)"; return 2 ;;
        *) print_error "usage: pl forge ci-var list <project> | set <project> <KEY> <value>"; return 2 ;;
    esac
}

cmd_deploy_key() {
    case "${1:-list}" in
        list) [ -n "${2:-}" ] || { print_error "usage: pl forge deploy-key list <project>"; return 2; }
              _read_only_api "deploy keys" "/projects/${2//\//%2F}/deploy_keys" ;;
        add)  _admin_token_present || { _refuse_no_admin; return 2; }
              print_error "not yet implemented: write verbs land with the credential (ADR-0038 §Migration)"; return 2 ;;
        *) print_error "usage: pl forge deploy-key list <project> | add"; return 2 ;;
    esac
}

cmd_retire_legacy_key() {
    # The one step that can lock the estate out of the box. It verifies the
    # replacement BEFORE it removes anything, and it is typed-confirm only.
    print_header "retire ~/.ssh/gitlab_linode from the forge box"
    _need_key "$OPS_KEY" "full-control ops" || return 2
    print_info "1/3 proving nwp-forge-ops works before anything is removed…"
    local out rc; out="$(_forge_ssh "$OPS_KEY" 'id && sudo -n id' 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q 'uid=0' <<<"$out"; then
        print_error "REFUSING: nwp-forge-ops cannot get a root shell — removing the legacy key would lock you out"
        return 1
    fi
    print_success "nwp-forge-ops verified (shell + sudo)"
    print_warning "2/3 servers/${FORGE_SERVER}/.nwp-server.yml still names ssh_key: ~/.ssh/gitlab_linode"
    echo "      Switch that FIRST, run \`pl server health ${FORGE_SERVER}\`, and only then retire."
    print_error "3/3 NOT IMPLEMENTED — deliberately. This is ADR-0038 §Migration step 4 and it"
    echo "      lands as its own reviewed change, after the ops#331 GitLab-side rehoming."
    return 2
}

################################################################################
usage() {
    cat <<EOF
pl forge — work on the forge box (the 'gitlab-host' role) through named, scoped identities
           (ops#331, ADR-0038). Read-only by default.

BOX PLANE (jailed read-only key — nwp-forge-probe):
  pl forge status | health | services | certs | backups | disk | version
  pl forge authorized-keys                     who may log in to the BOX, and under what forced command
  pl forge logs --source=nginx|gitlab|auth     fixed set, tail fixed at 200 on the box
  pl forge run <word>                          one allowlisted probe word

DIAGNOSIS:
  pl forge doctor [--live]     which identities exist; --live proves the jail over the wire
  pl forge whoami              which credential is in play, and whether it is REALLY admin

APPLICATION PLANE (GitLab REST — needs the forge-admin PAT, ADR-0038 plane 2):
  pl forge users list|show <u>
  pl forge keys list [<user>] | add | delete
  pl forge members list <project> | add
  pl forge ci-var list <project> | set
  pl forge deploy-key list <project> | add

MIGRATION:
  pl forge retire-legacy-key   swap off ~/.ssh/gitlab_linode (verifies first; not yet armed)

Every application-plane verb REFUSES BY NAME while the credential is absent —
that is its state until the operator mints it:  pl secrets steps ${ADMIN_REGISTRY_ID}
EOF
}

case "${1:-}" in
    ""|-h|--help|help) usage ;;
    status)        shift; cmd_status "$@" ;;
    health)        shift; cmd_health "$@" ;;
    services)      shift; cmd_services "$@" ;;
    certs)         shift; cmd_certs "$@" ;;
    backups)       shift; cmd_backups "$@" ;;
    disk)          shift; cmd_disk "$@" ;;
    version)       shift; cmd_version "$@" ;;
    authorized-keys) shift; cmd_authorized_keys "$@" ;;
    logs)          shift; cmd_logs "$@" ;;
    run)           shift; cmd_run "$@" ;;
    doctor)        shift; cmd_doctor "$@" ;;
    whoami)        shift; cmd_whoami "$@" ;;
    users)         shift; cmd_users "$@" ;;
    keys)          shift; cmd_keys "$@" ;;
    members)       shift; cmd_members "$@" ;;
    ci-var)        shift; cmd_ci_var "$@" ;;
    deploy-key)    shift; cmd_deploy_key "$@" ;;
    retire-legacy-key) shift; cmd_retire_legacy_key "$@" ;;
    *) print_error "unknown subcommand: $1"; echo; usage; exit 2 ;;
esac
