#!/usr/bin/env bash
#
# pl forge — the sanctioned way to work on the forge box (the `gitlab-host`
# role),
# across both of its planes (ops#331, NWP-ADR-0038).
#
# WHY THIS EXISTS. The forge box had exactly one credential — an unrestricted
# key in ~gitlab/.ssh/authorized_keys, where `gitlab` carries
# `(ALL) NOPASSWD: ALL` — so *every* interaction with it, down to reading how
# much RAM is free, authenticated as root-on-box. NWP-ADR-0038 splits that into
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
#                  mints (NWP-ADR-0038 plane 2). Until it exists, every verb here
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
# Where a key snapshot lands. SSH PUBLIC keys are not secrets, but a machine→
# identity map is, so it goes under private/ (its own repo) rather than the
# engine tree, and the directory is 0700.
KEY_BACKUP_DIR="${NWP_FORGE_KEY_BACKUP_DIR:-$NWP_DIR/private/forge-key-backups}"
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
    print_hint "OPERATOR step (NWP-ADR-0038 plane 2), then re-run:"
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

# Every WRITE on this plane goes through here first. Two separate facts, and
# the second is the one that matters for a rehome: an SSH key deletion is only
# safe because the API can put the key back, and a token that cannot administer
# users is not that safety net. Refusing on "present" alone would be the
# swallowed-verdict shape — a credential that exists is not a credential that
# works.
_require_admin() {
    _admin_token_present || { _refuse_no_admin; return 2; }
    if ! _is_admin; then
        print_error "CANNOT VERIFY: the forge credential is present but not an instance admin"
        echo "  looked in:   ${ADMIN_TOKEN_FILE}"
        echo "  registry id: ${ADMIN_REGISTRY_ID}"
        echo "  probe:       GET /application/settings (admin-only) did not return 200"
        echo "  why it blocks a write: the API is the SAFETY NET for every key move — a key"
        echo "               deleted from a user can always be restored through it. A token"
        echo "               that cannot administer users is not that net, so the move would"
        echo "               be one-way. Refusing while it is still reversible."
        echo
        print_hint "pl forge whoami   ·   pl secrets steps ${ADMIN_REGISTRY_ID}"
        return 2
    fi
    return 0
}

_need_tool() { # tool  why
    command -v "$1" >/dev/null 2>&1 && return 0
    print_error "CANNOT VERIFY: '${1}' is not installed — ${2}"
    return 2
}

################################################################################
# Application plane — users, SSH keys, memberships (the ops#331 migration)
################################################################################

# → "<id>\t<username>"; 0 found · 1 no such user (a measured absence) ·
#   2 could not ask. The three outcomes are kept apart deliberately: "the API
#   said no such user" and "I could not reach the API" must never collapse into
#   one refusal, because only the first is safe to act on.
_resolve_user() { # user-or-id
    local who="$1" r code body n
    if [[ "$who" =~ ^[0-9]+$ ]]; then
        r="$(_api GET "/users/${who}")" || return 2
        code="$(_api_code "$r")"; body="$(_api_body "$r")"
        [ "$code" = "404" ] && return 1
        [ "$code" = "200" ] || { print_error "CANNOT VERIFY: GET /users/${who} returned HTTP ${code}" >&2; return 2; }
        printf '%s\t%s\n' "$(jq -r '.id' <<<"$body")" "$(jq -r '.username' <<<"$body")"
        return 0
    fi
    r="$(_api GET "/users?username=${who}")" || return 2
    code="$(_api_code "$r")"; body="$(_api_body "$r")"
    [ "$code" = "200" ] || { print_error "CANNOT VERIFY: GET /users?username=${who} returned HTTP ${code}" >&2; return 2; }
    n="$(jq -r 'length' <<<"$body" 2>/dev/null)" || return 2
    [ "$n" = "0" ] && return 1
    printf '%s\t%s\n' "$(jq -r '.[0].id' <<<"$body")" "$(jq -r '.[0].username' <<<"$body")"
    return 0
}

_keys_body() { # uid → the raw JSON array
    local r code; r="$(_api GET "/users/${1}/keys")" || return 2
    code="$(_api_code "$r")"
    [ "$code" = "200" ] || { print_error "CANNOT VERIFY: GET /users/${1}/keys returned HTTP ${code}" >&2; return 2; }
    _api_body "$r"
}

# A numeric selector that is NOT among a user's keys may still be a real key —
# a DEPLOY key. `GET /keys/:id` returns those too, and its `user` field names
# the account that CREATED it, not an owner. That cost real time on 2026-08-11:
# key 5 looked like a fourth key on root that `GET /users/1/keys` was hiding,
# and the natural conclusion — "the listing under-reports, root has a key we
# cannot see" — was wrong. It is a read-only deploy key on two projects, and
# the DELETE that follows from the wrong conclusion 404s. Name it instead.
_explain_if_deploy_key() { # key-id → prints an explanation, rc 0 if it IS one
    local kid="$1" r code body projs
    case "$kid" in ''|*[!0-9]*) return 1 ;; esac
    r="$(_api GET "/deploy_keys")" || return 1
    code="$(_api_code "$r")"; [ "$code" = "200" ] || return 1
    body="$(_api_body "$r")"
    printf '%s' "$body" | jq -e --arg id "$kid" 'any(.[]; .id == ($id|tonumber))' >/dev/null 2>&1 || return 1
    print_warning "key ${kid} is a DEPLOY KEY, not a user key — it cannot be rehomed to a user."
    echo "  Deploy keys belong to PROJECTS, not people: 'GET /keys/${kid}' reports a"
    echo "  \`user\` field, but that is whoever CREATED it. This is why it is absent"
    echo "  from every user's key list and why deleting it from a user 404s."
    projs="$(printf '%s' "$body" | jq -r --arg id "$kid" '.[] | select(.id == ($id|tonumber)) | "    " + .title + "  can_push=" + (.can_push|tostring)')"
    [ -n "$projs" ] && echo "$projs"
    print_hint "manage it as a deploy key (pl forge deploy-key), or leave it — a read-only"
    print_hint "deploy key scoped to a project is ALREADY least privilege."
    return 0
}

# The API does NOT return a fingerprint on this endpoint, so it is COMPUTED
# from the blob — the same way ops#331's key→machine mapping had to be. A
# fingerprint that cannot be computed is never silently blanked: the row
# carries UNCOMPUTABLE and every match against it fails.
_key_fingerprint() { # blob
    local f fp
    f="$(mktemp)"; printf '%s\n' "$1" > "$f"
    fp="$(ssh-keygen -lf "$f" 2>/dev/null | awk '{print $2}')"
    rm -f "$f"
    [ -n "$fp" ] || { printf 'UNCOMPUTABLE'; return 1; }
    printf '%s' "$fp"
}

_body_tsv() { # keys-json → id \t fingerprint \t title \t blob
    local id title blob fp
    while IFS=$'\t' read -r id title blob; do
        [ -n "$id" ] || continue
        fp="$(_key_fingerprint "$blob")" || true
        printf '%s\t%s\t%s\t%s\n' "$id" "$fp" "$title" "$blob"
    done < <(jq -r '.[] | [(.id|tostring), .title, .key] | @tsv' <<<"$1")
}

# A selector is a numeric KEY ID or a fingerprint (full, or a prefix, with or
# without the SHA256: header). A prefix that matches more than one key is
# AMBIGUOUS and is refused — picking the first would be the estate's worst
# available failure mode on this verb.
_match_keys() { # selector  tsv
    local sel="$1" tsv="$2"
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
        awk -F'\t' -v s="$sel" '$1==s' <<<"$tsv"
    else
        awk -F'\t' -v s="$sel" '$2!="UNCOMPUTABLE" && (index($2,s)==1 || index(substr($2,8),s)==1)' <<<"$tsv"
    fi
}

_print_key_rows() { # tsv
    local id fp title blob
    printf '    %-5s %-52s %s\n' ID FINGERPRINT TITLE
    while IFS=$'\t' read -r id fp title blob; do
        [ -n "$id" ] || continue
        printf '    %-5s %-52s %s\n' "$id" "$fp" "$title"
    done <<<"$1"
}

_user_has_fp() { # uid  fingerprint → 0 present · 1 absent · 2 cannot verify
    local body; body="$(_keys_body "$1")" || return 2
    local tsv; tsv="$(_body_tsv "$body")"
    awk -F'\t' -v f="$2" '$2==f{found=1} END{exit found?0:1}' <<<"$tsv"
}

# Writes go through these two so that EVERY caller — rehome, restore, rollback
# — sends the same request and reads the same verdict.
FORGE_LAST_CODE=""; FORGE_LAST_BODY=""
_add_key() { # uid  title  blob
    local bf rc r
    bf="$(mktemp)"; chmod 600 "$bf"
    jq -n --arg t "$2" --arg k "$3" '{title:$t, key:$k}' > "$bf"
    r="$(_api POST "/users/${1}/keys" -H 'Content-Type: application/json' --data-binary "@${bf}")"; rc=$?
    rm -f "$bf"
    FORGE_LAST_CODE="$(_api_code "$r")"; FORGE_LAST_BODY="$(_api_body "$r")"
    [ $rc -eq 0 ] || return 2
    case "$FORGE_LAST_CODE" in 200|201) return 0 ;; esac
    return 1
}
_del_key() { # uid  keyid
    local r rc
    r="$(_api DELETE "/users/${1}/keys/${2}")"; rc=$?
    FORGE_LAST_CODE="$(_api_code "$r")"; FORGE_LAST_BODY="$(_api_body "$r")"
    [ $rc -eq 0 ] || return 2
    case "$FORGE_LAST_CODE" in 200|204) return 0 ;; esac
    return 1
}

# The snapshot. Everything a rehome could destroy is in here BEFORE anything is
# destroyed, in a form `pl forge keys restore` can put back without a human
# reading JSON.
_write_backup() { # uid  username  outfile  keys-json
    local uid="$1" uname="$2" out="$3" body="$4"
    local dir; dir="$(dirname "$out")"
    mkdir -p "$dir" 2>/dev/null || { print_error "CANNOT VERIFY: cannot create ${dir}"; return 2; }
    chmod 700 "$dir" 2>/dev/null || true
    local fps="{}" id fp title blob
    while IFS=$'\t' read -r id fp title blob; do
        [ -n "$id" ] || continue
        fps="$(jq --arg k "$id" --arg v "$fp" '. + {($k):$v}' <<<"$fps")"
    done < <(_body_tsv "$body")
    jq --argjson fp "$fps" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg host "${FORGE_API_HOST:-unknown}" \
       --argjson uid "$uid" --arg uname "$uname" \
       '{schema:"nwp.forge.key-backup/1", taken_at:$ts, api_host:$host,
         user:{id:$uid, username:$uname},
         keys:[ .[] | {id, title, key, created_at, fingerprint_sha256:($fp[(.id|tostring)] // null)} ]}' \
       <<<"$body" > "$out" || { print_error "CANNOT VERIFY: could not write ${out}"; return 2; }
    chmod 600 "$out" 2>/dev/null || true
    return 0
}

# Printed on every rehome, dry-run and execute alike. An operator watching a
# step whose middle is "this key authenticates to nothing" is entitled to know
# what is NOT at stake — and it was measured, not assumed (2026-08-11).
_print_not_at_risk() {
    echo
    print_info "NOT AT RISK — shell access to the forge box"
    echo "    ~/.ssh/gitlab_linode authenticates to gitlab@<forge> through that box's own"
    echo "    ~gitlab/.ssh/authorized_keys, which is a DIFFERENT plane from a GitLab user's"
    echo "    SSH keys. Removing a key from a GitLab USER cannot remove box administration,"
    echo "    and this verb never touches authorized_keys. If everything below fails, the"
    echo "    box is still reachable and the API can still restore the key."
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

# ops#331 rehomes met's key to a `met` service user — and there is no `met`
# user. This is the verb that makes step 2 of the migration possible without an
# operator browser session. No password is ever generated, printed or sent:
# `reset_password` makes GitLab mail a set-password link, so there is no
# credential here for this process to leak.
cmd_user_create() { # <username> --name=… --email=… [--admin] [--execute] [--yes]
    local uname="" name="" email="" admin=0 execute=0 yes=0 a
    for a in "$@"; do
        case "$a" in
            --name=*)  name="${a#--name=}" ;;
            --email=*) email="${a#--email=}" ;;
            --admin)   admin=1 ;;
            --execute) execute=1 ;;
            --yes)     yes=1 ;;
            -*) print_error "Unknown option: $a"; return 2 ;;
            *)  [ -z "$uname" ] && uname="$a" || { print_error "unexpected argument: $a"; return 2; } ;;
        esac
    done
    [ -n "$uname" ] || { print_error "usage: pl forge user create <username> --name='…' --email='…' [--admin] [--execute]"; return 2; }
    _need_tool jq "the API speaks JSON" || return 2
    _require_admin || return 2
    if [ -z "$name" ] || [ -z "$email" ]; then
        print_error "REFUSED: --name and --email are both required — this verb does not invent an identity"
        print_hint "pl forge user create ${uname} --name='${uname} (service account)' --email='${uname}@…' --execute"
        return 2
    fi
    local u rc; u="$(_resolve_user "$uname")"; rc=$?
    [ $rc -eq 2 ] && return 2
    if [ $rc -eq 0 ]; then
        print_error "REFUSED: user '${uname}' already exists (id $(cut -f1 <<<"$u")) — nothing was changed"
        return 1
    fi
    print_header "create forge user '${uname}'"
    printf '  name    %s\n  email   %s\n  admin   %s\n  password  none is set or sent — GitLab mails a set-password link\n' \
        "$name" "$email" "$( [ "$admin" -eq 1 ] && echo YES || echo no )"
    if [ "$admin" -eq 1 ]; then
        print_warning "an ADMIN user is being requested — NWP-ADR-0038 scopes admin to ONE bot (${ADMIN_REGISTRY_ID})."
    fi
    if [ "$execute" -eq 0 ]; then print_info "DRY RUN — nothing sent. Re-run with --execute."; return 0; fi
    if [ "$yes" -eq 0 ]; then
        local typed; printf 'Type the username (%s) to confirm creation: ' "$uname"; read -r typed
        [ "$typed" = "$uname" ] || { echo "Confirmation did not match — nothing was created."; return 1; }
    fi
    local bf r code body
    bf="$(mktemp)"; chmod 600 "$bf"
    jq -n --arg u "$uname" --arg n "$name" --arg e "$email" --argjson ad "$admin" \
       '{username:$u, name:$n, email:$e, admin:($ad==1), reset_password:true, skip_confirmation:true}' > "$bf"
    r="$(_api POST /users -H 'Content-Type: application/json' --data-binary "@${bf}")"; rc=$?
    rm -f "$bf"
    [ $rc -eq 0 ] || { print_error "CANNOT VERIFY: the request to create ${uname} did not complete"; return 2; }
    code="$(_api_code "$r")"; body="$(_api_body "$r")"
    case "$code" in 200|201) ;; *) print_error "create FAILED (HTTP ${code}) — ${body}"; return 1 ;; esac
    # Verify by re-reading, not by trusting the 201.
    u="$(_resolve_user "$uname")" || { print_error "VERIFY FAILED: the API reported ${code} but ${uname} is not resolvable"; return 1; }
    print_success "created and VERIFIED: ${uname} (id $(cut -f1 <<<"$u"))"
    print_hint "give it access:  pl forge members add <group|project> ${uname} --level=reporter --execute"
    return 0
}

cmd_users() {
    case "${1:-list}" in
        list) _read_only_api "users" "/users?per_page=50&without_project_bots=true" ;;
        show) [ -n "${2:-}" ] || { print_error "usage: pl forge users show <username>"; return 2; }
              _read_only_api "user ${2}" "/users?username=${2}" ;;
        create) shift; cmd_user_create "$@" ;;
        *) print_error "usage: pl forge user list|show <username>|create <username> --name=… --email=…"; return 2 ;;
    esac
}

_default_backup_path() { # username
    printf '%s/%s-%s.json' "$KEY_BACKUP_DIR" "$1" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# Shared front door for every keys verb that names a user: resolve, or refuse
# in a way that says which of the three things went wrong.
# NOTE the >&2 on every message: this helper is called inside $( ), so anything
# it writes to stdout is CAPTURED as the resolved user instead of reaching the
# operator. The first draft printed the "create it first" hint to stdout and it
# vanished — the refusal was correct and invisible, which on this verb is the
# same as being wrong.
_keys_user_or_refuse() { # user  → prints "id\tusername"
    local who="$1" u rc
    u="$(_resolve_user "$who")"; rc=$?
    if [ $rc -eq 1 ]; then
        print_error "REFUSED: no such user '${who}' on the forge — nothing has been touched"
        print_hint "create it first:  pl forge user create ${who} --name='…' --email='…' --execute" >&2
        return 1
    fi
    [ $rc -eq 0 ] || return 2
    printf '%s' "$u"
}

cmd_keys_backup() { # [user] [--out=FILE]
    local who="root" out="" a
    for a in "$@"; do
        case "$a" in
            --out=*) out="${a#--out=}" ;;
            -*) print_error "Unknown option: $a"; return 2 ;;
            *)  who="$a" ;;
        esac
    done
    _need_tool jq "the backup is JSON" || return 2
    _need_tool ssh-keygen "fingerprints are computed from the key blob" || return 2
    _require_admin || return 2
    local u rc; u="$(_keys_user_or_refuse "$who")"; rc=$?; [ $rc -eq 0 ] || return $rc
    local uid uname; IFS=$'\t' read -r uid uname <<<"$u"
    local body; body="$(_keys_body "$uid")" || return 2
    [ -n "$out" ] || out="$(_default_backup_path "$uname")"
    _write_backup "$uid" "$uname" "$out" "$body" || return 2
    print_success "backed up $(jq -r '.keys|length' "$out") key(s) of ${uname} (id ${uid})"
    echo "  file: ${out}"
    print_hint "restore any of them with:  pl forge keys restore ${out} --key-id=<id> --execute"
    return 0
}

cmd_keys_verify() { # <user> <selector>
    local who="${1:-}" sel="${2:-}"
    [ -n "$who" ] && [ -n "$sel" ] || { print_error "usage: pl forge keys verify <user> <fingerprint|key-id>"; return 2; }
    _need_tool jq "the API speaks JSON" || return 2
    _need_tool ssh-keygen "fingerprints are computed from the key blob" || return 2
    _require_admin || return 2
    local u rc; u="$(_keys_user_or_refuse "$who")"; rc=$?; [ $rc -eq 0 ] || return $rc
    local uid uname; IFS=$'\t' read -r uid uname <<<"$u"
    local body tsv hits n
    body="$(_keys_body "$uid")" || return 2
    tsv="$(_body_tsv "$body")"
    hits="$(_match_keys "$sel" "$tsv")"
    n="$(printf '%s' "$hits" | grep -c . || true)"
    if [ "$n" = "0" ]; then
        print_error "NOT on ${uname} (id ${uid}): no key matching '${sel}'"
        [ -n "$tsv" ] && { echo "  what ${uname} does hold:"; _print_key_rows "$tsv"; }
        return 1
    fi
    print_success "PRESENT on ${uname} (id ${uid}) — ${n} matching key(s)"
    _print_key_rows "$hits"
    return 0
}

cmd_keys_add() { # <user> --key-file=F [--title=T] [--execute] [--yes]
    local who="" kf="" title="" execute=0 yes=0 a
    for a in "$@"; do
        case "$a" in
            --key-file=*) kf="${a#--key-file=}" ;;
            --title=*)    title="${a#--title=}" ;;
            --execute)    execute=1 ;;
            --yes)        yes=1 ;;
            -*) print_error "Unknown option: $a"; return 2 ;;
            *)  [ -z "$who" ] && who="$a" || { print_error "unexpected argument: $a"; return 2; } ;;
        esac
    done
    [ -n "$who" ] && [ -n "$kf" ] || { print_error "usage: pl forge keys add <user> --key-file=<pubkey> [--title=…] [--execute]"; return 2; }
    [ -r "$kf" ] || { print_error "CANNOT VERIFY: cannot read ${kf}"; return 2; }
    _need_tool jq "the API speaks JSON" || return 2
    _need_tool ssh-keygen "fingerprints are computed from the key blob" || return 2
    _require_admin || return 2
    local u rc; u="$(_keys_user_or_refuse "$who")"; rc=$?; [ $rc -eq 0 ] || return $rc
    local uid uname; IFS=$'\t' read -r uid uname <<<"$u"
    local blob fp; blob="$(head -1 "$kf")"
    fp="$(_key_fingerprint "$blob")" || { print_error "CANNOT VERIFY: ${kf} is not a public key ssh-keygen can read"; return 2; }
    [ -n "$title" ] || title="$(awk '{print $3}' <<<"$blob")"
    [ -n "$title" ] || title="added by pl forge"
    printf '  add %s\n  to  %s (id %s) as "%s"\n' "$fp" "$uname" "$uid" "$title"
    if [ "$execute" -eq 0 ]; then print_info "DRY RUN — nothing sent. Re-run with --execute."; return 0; fi
    if [ "$yes" -eq 0 ]; then
        local typed; printf 'Type the username (%s) to confirm: ' "$uname"; read -r typed
        [ "$typed" = "$uname" ] || { echo "Confirmation did not match — nothing was changed."; return 1; }
    fi
    if _add_key "$uid" "$title" "$blob" && _user_has_fp "$uid" "$fp"; then
        print_success "added and VERIFIED on ${uname}"; return 0
    fi
    print_error "add FAILED (HTTP ${FORGE_LAST_CODE}) — ${FORGE_LAST_BODY}"
    return 1
}

cmd_keys_delete() { # <user> <selector> [--execute] [--yes] [--no-backup]
    local who="" sel="" execute=0 yes=0 a
    for a in "$@"; do
        case "$a" in
            --execute) execute=1 ;;
            --yes)     yes=1 ;;
            -*) print_error "Unknown option: $a"; return 2 ;;
            *)  if   [ -z "$who" ]; then who="$a"
                elif [ -z "$sel" ]; then sel="$a"
                else print_error "unexpected argument: $a"; return 2; fi ;;
        esac
    done
    [ -n "$who" ] && [ -n "$sel" ] || { print_error "usage: pl forge keys delete <user> <fingerprint|key-id> [--execute]"; return 2; }
    _need_tool jq "the API speaks JSON" || return 2
    _need_tool ssh-keygen "fingerprints are computed from the key blob" || return 2
    _require_admin || return 2
    local u rc; u="$(_keys_user_or_refuse "$who")"; rc=$?; [ $rc -eq 0 ] || return $rc
    local uid uname; IFS=$'\t' read -r uid uname <<<"$u"
    local body tsv hits n
    body="$(_keys_body "$uid")" || return 2
    tsv="$(_body_tsv "$body")"
    hits="$(_match_keys "$sel" "$tsv")"
    n="$(printf '%s' "$hits" | grep -c . || true)"
    [ "$n" = "0" ] && { print_error "REFUSED: no key on ${uname} matches '${sel}'"; _print_key_rows "$tsv"; return 1; }
    [ "$n" -gt 1 ] && { print_error "AMBIGUOUS: '${sel}' matches ${n} keys on ${uname} — refusing to pick one"; _print_key_rows "$hits"; return 2; }
    local kid fp title blob; IFS=$'\t' read -r kid fp title blob <<<"$hits"
    printf '  delete key %s "%s"\n  from       %s (id %s)\n  %s\n' "$kid" "$title" "$uname" "$uid" "$fp"
    if [ "$execute" -eq 0 ]; then print_info "DRY RUN — nothing sent. Re-run with --execute."; return 0; fi
    local bk; bk="$(_default_backup_path "$uname")"
    _write_backup "$uid" "$uname" "$bk" "$body" || return 2
    echo "  backup: ${bk}"
    if [ "$yes" -eq 0 ]; then
        local typed; printf 'Type the username (%s) to confirm deletion: ' "$uname"; read -r typed
        [ "$typed" = "$uname" ] || { echo "Confirmation did not match — nothing was changed."; return 1; }
    fi
    if _del_key "$uid" "$kid"; then
        print_success "deleted — restore with:  pl forge keys restore ${bk} --key-id=${kid} --execute"
        return 0
    fi
    print_error "delete FAILED (HTTP ${FORGE_LAST_CODE}) — nothing was changed"
    return 1
}

cmd_keys_restore() { # <backup.json> [--user=U] [--key-id=N|--all] [--execute] [--yes]
    local file="" who="" kid="" all=0 execute=0 yes=0 a
    for a in "$@"; do
        case "$a" in
            --user=*)   who="${a#--user=}" ;;
            --key-id=*) kid="${a#--key-id=}" ;;
            --all)      all=1 ;;
            --execute)  execute=1 ;;
            --yes)      yes=1 ;;
            -*) print_error "Unknown option: $a"; return 2 ;;
            *)  [ -z "$file" ] && file="$a" || { print_error "unexpected argument: $a"; return 2; } ;;
        esac
    done
    [ -n "$file" ] || { print_error "usage: pl forge keys restore <backup.json> [--key-id=N|--all] [--execute]"; return 2; }
    [ -r "$file" ] || { print_error "CANNOT VERIFY: cannot read ${file}"; return 2; }
    [ -n "$kid" ] || [ "$all" -eq 1 ] || { print_error "usage: name what to restore — --key-id=<id> or --all"; return 2; }
    _need_tool jq "the backup is JSON" || return 2
    _need_tool ssh-keygen "fingerprints are computed from the key blob" || return 2
    jq -e '.schema=="nwp.forge.key-backup/1"' "$file" >/dev/null 2>&1 || {
        print_error "CANNOT VERIFY: ${file} is not an nwp.forge.key-backup/1 snapshot"; return 2; }
    _require_admin || return 2
    [ -n "$who" ] || who="$(jq -r '.user.username' "$file")"
    local u rc; u="$(_keys_user_or_refuse "$who")"; rc=$?; [ $rc -eq 0 ] || return $rc
    local uid uname; IFS=$'\t' read -r uid uname <<<"$u"

    local rows
    if [ "$all" -eq 1 ]; then rows="$(jq -r '.keys[] | [(.id|tostring), .title, .key] | @tsv' "$file")"
    else rows="$(jq -r --arg i "$kid" '.keys[] | select((.id|tostring)==$i) | [(.id|tostring), .title, .key] | @tsv' "$file")"; fi
    [ -n "$rows" ] || { print_error "REFUSED: ${file} holds no key with id ${kid}"; return 1; }

    print_header "restore key(s) from ${file} → ${uname} (id ${uid})"
    local id title blob fp done_n=0 skip_n=0 fail_n=0
    while IFS=$'\t' read -r id title blob; do
        [ -n "$id" ] || continue
        fp="$(_key_fingerprint "$blob")" || { print_error "  key ${id}: unreadable blob — skipped"; fail_n=$((fail_n+1)); continue; }
        if _user_has_fp "$uid" "$fp"; then
            printf '  %-5s %s  ALREADY PRESENT\n' "$id" "$fp"; skip_n=$((skip_n+1)); continue
        fi
        printf '  %-5s %s  "%s"\n' "$id" "$fp" "$title"
        [ "$execute" -eq 0 ] && continue
        if _add_key "$uid" "$title" "$blob" && _user_has_fp "$uid" "$fp"; then
            print_success "  restored and VERIFIED on ${uname}"; done_n=$((done_n+1))
        else
            print_error "  FAILED (HTTP ${FORGE_LAST_CODE}) — ${FORGE_LAST_BODY}"; fail_n=$((fail_n+1))
        fi
    done <<<"$rows"

    if [ "$execute" -eq 0 ]; then
        print_info "DRY RUN — nothing sent. Re-run with --execute."
        return 0
    fi
    printf '\n  %s restored, %s already present, %s failed\n' "$done_n" "$skip_n" "$fail_n"
    [ "$fail_n" -eq 0 ] || return 1
    return 0
}

################################################################################
# rehome — the ops#331 migration, as ONE verb
#
# WHY IT IS ONE VERB AND NOT "delete then add".
# GitLab enforces SSH-key uniqueness INSTANCE-WIDE. Measured 2026-08-11:
# POSTing root's key blob to another user answers
#   {"message":{"fingerprint_sha256":["has already been taken"]}}
# so the safe order — add to the new home, confirm it works, then remove from
# the old — IS NOT AVAILABLE on this API. The move is necessarily
# DELETE-then-ADD, and between those two calls the key authenticates to no
# account at all. That window is the whole risk, so it belongs inside one verb
# that owns it, rather than in a session's shell where the recovery step is
# whatever the operator can remember at the time.
#
# HOW THE WINDOW IS MINIMISED
#   * Everything that can fail early is done early: tool checks, the ADMIN
#     probe, both user resolutions, both key lists, the fingerprint match, the
#     backup file, the typed confirm. By the time the DELETE is sent, the only
#     remaining unknowns are the two HTTP calls themselves.
#   * The window is literally two adjacent statements — no prompt, no file I/O,
#     no resolution between them (tests/unit/test-forge-keys-rehome.bats 2b
#     asserts the two requests are adjacent in the request log).
#   * A signal inside the window (Ctrl-C, SIGTERM) is trapped and rolls back.
#   * If the process is killed outright (SIGKILL, power loss) the backup file
#     written before the DELETE is the recovery, and its path is printed BEFORE
#     the window opens, not only afterwards.
################################################################################

_REHOME_IN_WINDOW=0
_rehome_panic() {
    [ "$_REHOME_IN_WINDOW" -eq 1 ] || exit 130
    echo
    print_warning "INTERRUPTED INSIDE THE WINDOW — attempting rollback before exiting"
    if _add_key "$_RH_SRC_ID" "$_RH_TITLE" "$_RH_BLOB" && _user_has_fp "$_RH_SRC_ID" "$_RH_FP"; then
        print_success "ROLLED BACK — the key is back on ${_RH_SRC_NAME} (verified)"
        exit 1
    fi
    print_error "ROLLBACK FAILED — the key authenticates to NO account right now"
    echo "  backup:  ${_RH_BACKUP}"
    echo "  repair:  pl forge keys restore ${_RH_BACKUP} --key-id=${_RH_KEY_ID} --execute"
    exit 1
}

cmd_keys_rehome() { # <selector> --to=<user> [--from=<user>] [--title=…] [--execute] [--yes]
    local sel="" to="" from="root" title="" execute=0 yes=0 a
    for a in "$@"; do
        case "$a" in
            --to=*)    to="${a#--to=}" ;;
            --from=*)  from="${a#--from=}" ;;
            --title=*) title="${a#--title=}" ;;
            --execute) execute=1 ;;
            --yes)     yes=1 ;;
            -*) print_error "Unknown option: $a"; return 2 ;;
            *)  [ -z "$sel" ] && sel="$a" || { print_error "unexpected argument: $a"; return 2; } ;;
        esac
    done
    [ -n "$sel" ] && [ -n "$to" ] || {
        print_error "usage: pl forge keys rehome <fingerprint|key-id> --to=<user> [--from=<user>] [--title=…] [--execute]"
        print_hint "the source defaults to 'root' — the account ops#331 is about"
        return 2; }

    _need_tool jq "the API speaks JSON" || return 2
    _need_tool ssh-keygen "the fingerprint is computed from the key blob, not returned by the API" || return 2
    _require_admin || return 2

    # ---- resolution, both ends, BEFORE anything is touched --------------
    local u rc src_id src_name dst_id dst_name
    u="$(_keys_user_or_refuse "$from")"; rc=$?; [ $rc -eq 0 ] || return $rc
    IFS=$'\t' read -r src_id src_name <<<"$u"
    u="$(_keys_user_or_refuse "$to")";  rc=$?; [ $rc -eq 0 ] || return $rc
    IFS=$'\t' read -r dst_id dst_name <<<"$u"
    [ "$src_id" != "$dst_id" ] || { print_error "REFUSED: source and target are the same user (${src_name})"; return 2; }

    local src_body dst_body src_tsv dst_tsv
    src_body="$(_keys_body "$src_id")" || return 2
    dst_body="$(_keys_body "$dst_id")" || return 2
    src_tsv="$(_body_tsv "$src_body")"
    dst_tsv="$(_body_tsv "$dst_body")"

    local hits n dhits dn
    hits="$(_match_keys "$sel" "$src_tsv")"; n="$(printf '%s' "$hits" | grep -c . || true)"
    dhits="$(_match_keys "$sel" "$dst_tsv")"; dn="$(printf '%s' "$dhits" | grep -c . || true)"

    if [ "$n" = "0" ] && [ "$dn" != "0" ]; then
        print_success "nothing to do: '${sel}' is already on ${dst_name} (id ${dst_id})"
        _print_key_rows "$dhits"
        print_hint "confirm independently:  pl forge keys verify ${dst_name} ${sel}"
        return 0
    fi
    if [ "$n" = "0" ] && _explain_if_deploy_key "$sel"; then
        print_error "REFUSED: '${sel}' is not a user key — nothing has been touched"
        return 1
    fi
    if [ "$n" = "0" ]; then
        print_error "REFUSED: no key on ${src_name} matches '${sel}' — nothing has been touched"
        echo "  what ${src_name} (id ${src_id}) holds:"
        _print_key_rows "$src_tsv"
        return 1
    fi
    if [ "$n" -gt 1 ]; then
        print_error "AMBIGUOUS: '${sel}' matches ${n} keys on ${src_name} — refusing to pick one"
        _print_key_rows "$hits"
        print_hint "name a full fingerprint or the numeric key id"
        return 2
    fi

    local key_id fp orig_title blob new_title
    IFS=$'\t' read -r key_id fp orig_title blob <<<"$hits"
    new_title="${title:-$orig_title}"

    # ---- the impact manifest -------------------------------------------
    print_header "rehome ONE SSH key: ${src_name} → ${dst_name}"
    printf '  key id      %s\n' "$key_id"
    printf '  title       "%s"%s\n' "$orig_title" "$( [ "$new_title" = "$orig_title" ] || printf '  → "%s"' "$new_title" )"
    printf '  fingerprint %s\n' "$fp"
    printf '  FROM        %s (id %s) — loses this key\n' "$src_name" "$src_id"
    printf '  TO          %s (id %s) — gains it\n' "$dst_name" "$dst_id"
    echo
    print_warning "THE WINDOW: GitLab enforces key uniqueness instance-wide, so this is DELETE"
    echo "    then ADD — there is no add-first order. Between the two calls this key"
    echo "    authenticates to NO GitLab account. Any failure inside the window rolls back"
    echo "    to ${src_name} and re-reads the key list to prove it."
    _print_not_at_risk

    if [ "$execute" -eq 0 ]; then
        echo
        print_info "DRY RUN — nothing sent, no backup written. Re-run with --execute."
        printf '  backup would be written to: %s\n' "$(_default_backup_path "$src_name")"
        return 0
    fi

    # ---- typed confirm --------------------------------------------------
    if [ "$yes" -eq 0 ]; then
        local typed
        printf '\nType the transition (%s->%s) to proceed: ' "$src_name" "$dst_name"
        read -r typed
        if [ "$typed" != "${src_name}->${dst_name}" ]; then
            echo "Confirmation did not match — NOTHING was changed."
            return 1
        fi
    fi

    # ---- the backup, BEFORE the window ---------------------------------
    local backup; backup="$(_default_backup_path "$src_name")"
    _write_backup "$src_id" "$src_name" "$backup" "$src_body" || {
        print_error "REFUSED: could not write the snapshot — a rehome without a restorable backup is not allowed"
        return 2; }
    grep -qF "$blob" "$backup" || {
        print_error "REFUSED: the snapshot at ${backup} does not contain the key blob — refusing to proceed"
        return 2; }
    print_success "snapshot written: ${backup}"
    printf '  if this process dies mid-move, THIS is the repair:\n    pl forge keys restore %s --key-id=%s --execute\n' "$backup" "$key_id"

    _RH_SRC_ID="$src_id"; _RH_SRC_NAME="$src_name"; _RH_TITLE="$orig_title"
    _RH_BLOB="$blob"; _RH_FP="$fp"; _RH_BACKUP="$backup"; _RH_KEY_ID="$key_id"

    # ======================= THE WINDOW OPENS ===========================
    _REHOME_IN_WINDOW=1
    trap _rehome_panic INT TERM HUP
    local fail_reason=""
    if ! _del_key "$src_id" "$key_id"; then
        _REHOME_IN_WINDOW=0; trap - INT TERM HUP
        print_error "DELETE failed (HTTP ${FORGE_LAST_CODE}) — nothing was changed; the key is still on ${src_name}"
        echo "  ${FORGE_LAST_BODY}"
        return 1
    fi
    if _add_key "$dst_id" "$new_title" "$blob"; then
        if _user_has_fp "$dst_id" "$fp"; then
            _REHOME_IN_WINDOW=0; trap - INT TERM HUP
            # ==================== THE WINDOW CLOSES =====================
            print_success "VERIFIED — the key is now on ${dst_name} (id ${dst_id}) and gone from ${src_name}"
            echo "  re-read of /users/${dst_id}/keys matched ${fp}"
            echo "  snapshot kept: ${backup}"
            print_hint "confirm independently:  pl forge keys verify ${dst_name} ${fp}"
            return 0
        fi
        fail_reason="VERIFY FAILED: the ADD returned HTTP ${FORGE_LAST_CODE} but ${fp} is NOT in ${dst_name}'s key list"
    else
        fail_reason="ADD FAILED (HTTP ${FORGE_LAST_CODE}): ${FORGE_LAST_BODY}"
    fi

    # ---- rollback -------------------------------------------------------
    print_error "$fail_reason"
    print_warning "ROLLING BACK: re-adding the key to ${src_name}…"
    if _add_key "$src_id" "$orig_title" "$blob" && _user_has_fp "$src_id" "$fp"; then
        _REHOME_IN_WINDOW=0; trap - INT TERM HUP
        print_success "ROLLED BACK — the key is back on ${src_name} (id ${src_id}), verified by re-reading its key list"
        echo "  the estate is exactly as it was before this command ran."
        echo "  snapshot kept: ${backup}"
        return 1
    fi
    _REHOME_IN_WINDOW=0; trap - INT TERM HUP
    echo
    print_error "ROLLBACK FAILED — the key authenticates to NO account right now"
    echo "  It was removed from ${src_name} and could not be placed on ${dst_name} OR put back."
    echo "  fingerprint: ${fp}"
    echo "  last API code: ${FORGE_LAST_CODE}"
    echo "  snapshot:    ${backup}"
    echo
    print_warning "REPAIR IT WITH THIS, EXACTLY:"
    echo "    pl forge keys restore ${backup} --key-id=${key_id} --execute"
    echo "  then confirm:"
    echo "    pl forge keys verify ${src_name} ${fp}"
    _print_not_at_risk
    return 1
}

cmd_keys() {
    case "${1:-list}" in
        list) local u="${2:-}"
              if [ -n "$u" ]; then _read_only_api "keys of ${u}" "/users/${u}/keys"
              else _read_only_api "own keys" "/user/keys"; fi ;;
        backup)  shift; cmd_keys_backup "$@" ;;
        verify)  shift; cmd_keys_verify "$@" ;;
        rehome)  shift; cmd_keys_rehome "$@" ;;
        restore) shift; cmd_keys_restore "$@" ;;
        add)     shift; cmd_keys_add "$@" ;;
        delete)  shift; cmd_keys_delete "$@" ;;
        *) print_error "usage: pl forge keys list|backup|verify|rehome|restore|add|delete"; return 2 ;;
    esac
}

# A path is a project or a group, and guessing wrong writes a membership to the
# wrong object. Ask, in that order, and refuse if neither answers.
_resolve_namespace() { # path → "projects|groups\t<encoded>"
    local enc="${1//\//%2F}" r code
    r="$(_api GET "/projects/${enc}")" || return 2
    code="$(_api_code "$r")"
    [ "$code" = "200" ] && { printf 'projects\t%s\n' "$enc"; return 0; }
    r="$(_api GET "/groups/${enc}")" || return 2
    code="$(_api_code "$r")"
    [ "$code" = "200" ] && { printf 'groups\t%s\n' "$enc"; return 0; }
    return 1
}

_access_level() { # word → number, or refuse
    case "$1" in
        reporter)   printf 20 ;;
        developer)  printf 30 ;;
        maintainer) printf 40 ;;
        *) return 1 ;;
    esac
}

cmd_members_add() { # <project|group> <user> --level=… [--execute] [--yes]
    local where="" who="" level="" execute=0 yes=0 a
    for a in "$@"; do
        case "$a" in
            --level=*) level="${a#--level=}" ;;
            --execute) execute=1 ;;
            --yes)     yes=1 ;;
            -*) print_error "Unknown option: $a"; return 2 ;;
            *)  if   [ -z "$where" ]; then where="$a"
                elif [ -z "$who" ];   then who="$a"
                else print_error "unexpected argument: $a"; return 2; fi ;;
        esac
    done
    [ -n "$where" ] && [ -n "$who" ] || { print_error "usage: pl forge members add <project|group> <user> --level=reporter|developer|maintainer [--execute]"; return 2; }
    _need_tool jq "the API speaks JSON" || return 2
    _require_admin || return 2
    local lvl
    if ! lvl="$(_access_level "$level")"; then
        print_error "REFUSED: --level must be one of reporter | developer | maintainer (got '${level:-none}')"
        echo "  guest is below anything ops#331 needs; owner and admin are NOT grantable here —"
        echo "  NWP-ADR-0038 keeps instance-level privilege to the one declared bot."
        return 2
    fi
    local ns rc; ns="$(_resolve_namespace "$where")"; rc=$?
    [ $rc -eq 2 ] && return 2
    if [ $rc -eq 1 ]; then
        print_error "CANNOT VERIFY: '${where}' is neither a project nor a group this credential can see"
        print_hint "check the full path, e.g. nwp/nwp (project) or nwp (group)"
        return 2
    fi
    local kind enc; IFS=$'\t' read -r kind enc <<<"$ns"
    local u; u="$(_keys_user_or_refuse "$who")"; rc=$?; [ $rc -eq 0 ] || return $rc
    local uid uname; IFS=$'\t' read -r uid uname <<<"$u"

    print_header "add ${uname} (id ${uid}) to ${kind%s} ${where} as ${level}"
    printf '  access_level %s (%s)\n' "$lvl" "$level"
    if [ "$execute" -eq 0 ]; then print_info "DRY RUN — nothing sent. Re-run with --execute."; return 0; fi
    if [ "$yes" -eq 0 ]; then
        local typed; printf 'Type the username (%s) to confirm: ' "$uname"; read -r typed
        [ "$typed" = "$uname" ] || { echo "Confirmation did not match — nothing was changed."; return 1; }
    fi
    local bf r code body
    bf="$(mktemp)"; chmod 600 "$bf"
    jq -n --argjson u "$uid" --argjson l "$lvl" '{user_id:$u, access_level:$l}' > "$bf"
    r="$(_api POST "/${kind}/${enc}/members" -H 'Content-Type: application/json' --data-binary "@${bf}")"; rc=$?
    rm -f "$bf"
    [ $rc -eq 0 ] || { print_error "CANNOT VERIFY: the membership request did not complete"; return 2; }
    code="$(_api_code "$r")"; body="$(_api_body "$r")"
    case "$code" in 200|201) print_success "added ${uname} to ${where} as ${level}"; return 0 ;; esac
    print_error "add FAILED (HTTP ${code}) — ${body}"
    return 1
}

cmd_members() {
    case "${1:-list}" in
        list) [ -n "${2:-}" ] || { print_error "usage: pl forge members list <project|group>"; return 2; }
              local ns rc; ns="$(_resolve_namespace "$2")"; rc=$?
              [ $rc -eq 2 ] && return 2
              [ $rc -eq 1 ] && { print_error "CANNOT VERIFY: '${2}' is neither a project nor a group this credential can see"; return 2; }
              local kind enc; IFS=$'\t' read -r kind enc <<<"$ns"
              _read_only_api "members" "/${kind}/${enc}/members/all?per_page=50" ;;
        add)  shift; cmd_members_add "$@" ;;
        *) print_error "usage: pl forge members list <project|group> | add <project|group> <user> --level=…"; return 2 ;;
    esac
}

cmd_ci_var() {
    case "${1:-list}" in
        list) [ -n "${2:-}" ] || { print_error "usage: pl forge ci-var list <project>"; return 2; }
              _read_only_api "ci variables" "/projects/${2//\//%2F}/variables" ;;
        set)  _admin_token_present || { _refuse_no_admin; return 2; }
              # NWP-ADR-0038 makes this a NAMED prohibition rather than a habit: the
              # nwc-project pipeline has an unactivated sign:minisign job whose
              # variables would put the minisign SECRET KEY and its PASSWORD on
              # met — an AI host — collapsing the one property that keeps forge
              # control away from prod.
              if [ "${3:-}" = "MINISIGN_SECRET_KEY" ] || [ "${3:-}" = "MINISIGN_PASSWORD" ]; then
                  print_error "REFUSED: ${3} must never be set as a CI variable (NWP-ADR-0038 §minisign)"
                  echo "  Setting it would place the artifact-signing secret on an AI-run runner and"
                  echo "  break 'trust flows through signatures, not machines' — the property that"
                  echo "  makes forge control safe to grant at all."
                  return 1
              fi
              print_error "not yet implemented: write verbs land with the credential (NWP-ADR-0038 §Migration)"; return 2 ;;
        *) print_error "usage: pl forge ci-var list <project> | set <project> <KEY> <value>"; return 2 ;;
    esac
}

cmd_deploy_key() {
    case "${1:-list}" in
        list) [ -n "${2:-}" ] || { print_error "usage: pl forge deploy-key list <project>"; return 2; }
              _read_only_api "deploy keys" "/projects/${2//\//%2F}/deploy_keys" ;;
        add)  _admin_token_present || { _refuse_no_admin; return 2; }
              print_error "not yet implemented: write verbs land with the credential (NWP-ADR-0038 §Migration)"; return 2 ;;
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
    print_error "3/3 NOT IMPLEMENTED — deliberately. This is NWP-ADR-0038 §Migration step 4 and it"
    echo "      lands as its own reviewed change, after the ops#331 GitLab-side rehoming."
    return 2
}

################################################################################
usage() {
    cat <<EOF
pl forge — work on the forge box (the 'gitlab-host' role) through named, scoped identities
           (ops#331, NWP-ADR-0038). Read-only by default.

BOX PLANE (jailed read-only key — nwp-forge-probe):
  pl forge status | health | services | certs | backups | disk | version
  pl forge authorized-keys                     who may log in to the BOX, and under what forced command
  pl forge logs --source=nginx|gitlab|auth     fixed set, tail fixed at 200 on the box
  pl forge run <word>                          one allowlisted probe word

DIAGNOSIS:
  pl forge doctor [--live]     which identities exist; --live proves the jail over the wire
  pl forge whoami              which credential is in play, and whether it is REALLY admin

APPLICATION PLANE (GitLab REST — needs the forge-admin PAT, NWP-ADR-0038 plane 2):
  pl forge users list|show <u>
  pl forge user create <username> --name='…' --email='…' [--admin] [--execute]
  pl forge keys list [<user>]
  pl forge keys backup [<user>] [--out=FILE]          snapshot every key, so restore is possible
  pl forge keys verify <user> <fingerprint|key-id>    0 = present · 1 = not there · 2 = could not ask
  pl forge keys rehome <fingerprint|key-id> --to=<user> [--from=root] [--title=…] [--execute]
                                                      THE ops#331 MIGRATION: backup → delete →
                                                      add → verify, rolling back on any failure
  pl forge keys restore <backup.json> --key-id=N|--all [--execute]
  pl forge keys add <user> --key-file=<pubkey> [--title=…] [--execute]
  pl forge keys delete <user> <fingerprint|key-id> [--execute]
  pl forge members list <project|group>
  pl forge members add <project|group> <user> --level=reporter|developer|maintainer [--execute]
  pl forge ci-var list <project> | set
  pl forge deploy-key list <project> | add

Every write is DRY-RUN BY DEFAULT and needs --execute plus a typed confirm
(--yes for automation). A rehome writes its snapshot BEFORE it deletes anything.

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
    users|user)    shift; cmd_users "$@" ;;
    keys)          shift; cmd_keys "$@" ;;
    members)       shift; cmd_members "$@" ;;
    ci-var)        shift; cmd_ci_var "$@" ;;
    deploy-key)    shift; cmd_deploy_key "$@" ;;
    retire-legacy-key) shift; cmd_retire_legacy_key "$@" ;;
    *) print_error "unknown subcommand: $1"; echo; usage; exit 2 ;;
esac
