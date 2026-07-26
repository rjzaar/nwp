#!/bin/bash
#
# pl server-state — capture load-bearing host state into version control, and
#                   prove the captured copy still matches the running one.
#
# WHY THIS EXISTS
#
# The estate's most load-bearing configuration lived only on the boxes. Audited
# 2026-07-26 against the live fleet:
#
#   * The entire DR chain was ONE root cron one-liner on the ci-host, written
#     by a `dr-pull-setup.sh` that exists in no repo. Its restic retention
#     (`--keep-monthly 12` of raw prod) was an inline flag nobody could grep —
#     while the GDPR retention work is about precisely that number.
#   * `deny-files-secrets.conf` was committed calling itself "the HTTP-serving
#     layer of a 3-part defence", while on the box no vhost included it.
#   * max_input_vars=5000 was set on PHP 8.3; Moodle runs on 8.2, still at the
#     default 1000 — the exact ceiling that caused the 2026-07-26 outage.
#   * nwc-cron.timer (drives live Drupal cron) was unversioned.
#
# The counterexample already paid for is `nwp-daily-audit`: a load-bearing
# script that existed only on the ci-host, silently diverged from its repo
# namesake, and reported "no change" for 31 nights over a stopped container.
#
# THE RULE: if it is load-bearing it belongs in version control, and a `pl`
# verb must be able to make the claim "captured == running" go RED.
#
# THREE SEPARATE VERDICTS, NEVER CONFLATED
#
#   OK          live matches the captured copy
#   DRIFT       live differs — someone changed the box without capturing
#   UNREACHABLE the host could not be read
#
# UNREACHABLE is an ERROR, not a pass. "I could not check" reported as "clean"
# is the single failure mode this project keeps rediscovering.
#
# CAPTURE IS READ-ONLY. This command never writes to a host. Applying declared
# state back to a box is a separate, gated concern (`pl host apply`, item 6) so
# that a capture run can never mutate production.
#
# SECRETS. Artifacts of kind `ssh-policy` are redacted at capture time: the
# forced-command OPTIONS and the comment are kept, the key material never
# enters the repo. `pl server-state check` re-asserts that invariant over the
# captured tree, so a future careless capture cannot quietly turn this command
# into an exfiltration path.
#
# Usage:
#   pl server-state list                     inventories that exist
#   pl server-state capture <host> [--artifact=ID]
#   pl server-state diff    <host> [--artifact=ID]
#   pl server-state check   [<host>|--all]   repo-side invariants (CI-safe)
#   pl server-state php-check <host>         declared per-SAPI setting floors
#
# Env:
#   NWP_SERVER_STATE_ROOT   repo root to read/write servers/ under (tests)
#   NWP_SERVER_STATE_FETCH  fetch shim: <script> <host> <artifact-id> (tests)
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"

ROOT="${NWP_SERVER_STATE_ROOT:-$PROJECT_ROOT}"
YQ="$(command -v yq || true)"

_inv() { printf '%s/servers/%s/system/inventory.yml' "$ROOT" "$1"; }
_dir() { printf '%s/servers/%s/system' "$ROOT" "$1"; }

_require_inv() {
    local f; f="$(_inv "$1")"
    [ -n "$YQ" ] || { print_error "yq is required (go-yq / mikefarah)"; exit 1; }
    [ -f "$f" ] || { print_error "no inventory for host '$1': ${f#$ROOT/}"; exit 1; }
}

# ---------------------------------------------------------------------------
# Fetch one artifact's LIVE content to stdout. Exit non-zero => unreachable.
#
# The indirection exists so the whole command is testable with no network and
# no ssh: the suite points NWP_SERVER_STATE_FETCH at a stub. Without it, every
# case would need the real fleet and would degrade to "skip" in CI — which is
# the same vacuity this command was written to cure.
# ---------------------------------------------------------------------------
_fetch() {
    local host="$1" id="$2"

    if [ -n "${NWP_SERVER_STATE_FETCH:-}" ]; then
        "$NWP_SERVER_STATE_FETCH" "$host" "$id" || return 1
        return 0
    fi

    local inv; inv="$(_inv "$host")"
    local kind remote role user target
    kind=$(id="$id"   "$YQ" e '.artifacts[] | select(.id == strenv(id)) | .kind   // "file"' "$inv")
    remote=$(id="$id" "$YQ" e '.artifacts[] | select(.id == strenv(id)) | .remote // ""'     "$inv")
    role=$("$YQ" e '.ssh_role // ""' "$inv")
    user=$("$YQ" e '.ssh_user // ""' "$inv")

    [ -n "$role" ] || { print_error "inventory declares no ssh_role for '$host'" >&2; return 1; }
    # Role -> hostname via the one resolver, so no hostname is ever written
    # into this repo (leakage gate).
    target="$("$PROJECT_ROOT/scripts/commands/host.sh" "$role" 2>/dev/null | head -1)" || return 1
    [ -n "$target" ] || return 1
    [ -n "$user" ] && target="${user}@${target}"

    # Home-relative remotes are written as `~/path`. The account name differs
    # per host (and naming it in the inventory would put an operator home path
    # into the repo, which the leakage gate correctly rejects), so the remote
    # shell has to do the expanding. `printf %q` would quote the tilde into a
    # literal — the resulting UNREACHABLE is honest but useless — so the quoted
    # part is the tail only and "$HOME" is left for the remote shell.
    local rpath
    case "$remote" in
        '~/'*) rpath="\"\$HOME\"/$(printf '%q' "${remote#\~/}")" ;;
        *)     rpath="$(printf '%q' "$remote")" ;;
    esac

    local rcmd
    case "$kind" in
        cmd)    rcmd="$remote" ;;
        *)      rcmd="sudo -n cat ${rpath} 2>/dev/null || cat ${rpath}" ;;
    esac

    # Read-only by construction, bounded, and never interactive.
    #
    # -n is load-bearing, not cosmetic. Without it ssh inherits and drains the
    # caller's stdin, which is the `while read id` stream feeding the capture
    # loop: the first artifact would succeed and the remaining eight would
    # vanish with no error at all. Observed exactly once, on the first real run
    # (1 of 9 captured, exit 0) — a capture that silently captures almost
    # nothing is precisely the failure this command exists to prevent.
    timeout 30 ssh -n -o ConnectTimeout=8 -o BatchMode=yes ${NWP_SERVER_STATE_SSH_OPTS:-} \
        "$target" "$rcmd" || return 1
}

# ---------------------------------------------------------------------------
# Redact per kind. Called on EVERY capture, so the repo can only ever hold the
# redacted form.
#
# ssh-policy: keep the forced-command options and the comment — that is the
# security-relevant content (a key with `command=`+`restrict` is jailed; a bare
# key is a shell). Drop the key blob itself.
# ---------------------------------------------------------------------------
#
# Applied to EVERY artifact regardless of kind: strip routable IPv4 literals.
#
# The DR cron is the motivating case — it carries `gitlab@<public-ip>` and is
# otherwise the single most important thing to version. The literal address
# carries no review value (the structure, the retention flags and the key path
# are what matter), and the leakage gate rightly rejects the operator's public
# IP. Private, CGNAT/tailnet and loopback ranges are KEPT, because the topology
# they describe is the reviewable part and none of it is sensitive.
_ip_is_private() {
    local o1 o2
    IFS=. read -r o1 o2 _ _ <<< "$1"
    case "$o1" in 10|127|0) return 0 ;; esac
    [ "$o1" = 192 ] && [ "$o2" = 168 ] && return 0
    [ "$o1" = 169 ] && [ "$o2" = 254 ] && return 0
    [ "$o1" = 172 ] && [ "$o2" -ge 16 ] 2>/dev/null && [ "$o2" -le 31 ] && return 0
    [ "$o1" = 100 ] && [ "$o2" -ge 64 ] 2>/dev/null && [ "$o2" -le 127 ] && return 0
    return 1
}

_redact_public_ip() {
    local content ip
    content="$(cat)"
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        _ip_is_private "$ip" && continue
        content="${content//"$ip"/<public-ip-redacted>}"
    done < <(printf '%s\n' "$content" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | sort -u)
    printf '%s\n' "$content"
}

# ---------------------------------------------------------------------------
# IDENTITY REDACTION.
#
# Capturing host state verbatim necessarily captures the operator's identity:
# hostnames, the apex domain, home directories. The first real capture put six
# leakage-gate findings into the tree (`internal-bare-hostname`,
# `live-domain-apex`, `live-internal-domain`, `operator-home-path` ×2) — the
# gate was doing its job, and "add servers/ to the allowlist" would have
# re-blinded exactly the tree this item exists to add.
#
# So the identifiers are substituted for their ROLE placeholders instead, using
# the same private instance manifest `pl host` reads. Consequences:
#
#   * No hostname, domain or home path is hardcoded in this file. Writing the
#     apex literally here would itself trip `live-domain-apex`, since that rule
#     covers .sh files.
#   * The vocabulary follows the manifest. Bind a new role and captures start
#     using it; there is no second list to forget to update.
#   * Substitution is deterministic and applied to BOTH sides in `diff`, so
#     drift detection is unaffected.
#
# FIDELITY TRADE-OFF, stated plainly: a redacted capture is a faithful RECORD,
# not a byte-restorable backup. That is the right side of the trade for this
# repo — the restore path for host state is declared state applied by verb, and
# the live host remains the authority for its own literal text. `diff` still
# proves the captured record is true.
# ---------------------------------------------------------------------------
_IDENTITY_MAP_CACHE=""

_identity_map() {
    # "literal<TAB>placeholder" lines, LONGEST LITERAL FIRST so that a host
    # like `git.<apex>` is replaced before the bare apex would swallow its tail
    # and leave a half-substituted `git.<prod-base>`.
    [ -n "$_IDENTITY_MAP_CACHE" ] && { printf '%s' "$_IDENTITY_MAP_CACHE"; return 0; }

    local manifest="${NWP_INSTANCE_MANIFEST:-$HOME/nwp-instances/instance-manifest.yml}"
    [ -f "$manifest" ] && [ -n "$YQ" ] || return 0

    local raw
    raw="$(
        # role -> host bindings, emitted host-first. A host may carry several
        # roles; the first binding wins, deterministically, because the map is
        # de-duplicated on the literal below.
        "$YQ" e '.roles // {} | to_entries | .[] | .key as $r | (.value // []) | .[] | . + "\t<" + $r + ">"' "$manifest" 2>/dev/null
        "$YQ" e '.domains.prod-base // "" | select(. != "") | . + "\t<prod-base>"' "$manifest" 2>/dev/null
        "$YQ" e '.domains.ddev-base // "" | select(. != "") | . + "\t<ddev-base>"' "$manifest" 2>/dev/null
    )"

    _IDENTITY_MAP_CACHE="$(
        printf '%s\n' "$raw" \
          | grep -vE '^[[:space:]]*$' \
          | awk -F'\t' '!seen[$1]++ { print length($1) "\t" $0 }' \
          | sort -rn -k1,1 | cut -f2-
    )"
    printf '%s' "$_IDENTITY_MAP_CACHE"
}

_redact_identity() {
    local content lit ph
    content="$(cat)"

    while IFS=$'\t' read -r lit ph; do
        [ -n "$lit" ] || continue
        content="${content//"$lit"/$ph}"
    done <<< "$(_identity_map)"

    # Operator home directories, generically. Deliberately NOT read from the
    # manifest: the account name differs per host (the forge box runs as a
    # different user than the workstation), so a manifest-driven list would
    # miss exactly the ones that appear in captured server state.
    printf '%s\n' "$content" | sed -E 's#/home/[a-z_][a-z0-9_-]*#/home/<operator>#g'
}

_redact() {
    case "$1" in
        ssh-policy)
            # NB: the delimiter must not be '@' — the key-type alternation
            # itself contains '@openssh.com', which silently truncated the
            # expression and made the whole capture fail.
            #
            # Second pass drops the domain from any user@fqdn key comment. Key
            # comments routinely carry the live apex ("gitlab@<apex>"), which
            # the leakage gate rightly rejects. The rule is generic — anything
            # with a dotted TLD — so no hostname is hardcoded here; bare role
            # comments like "nwp-dr-pull@met" keep their meaning.
            sed -E 's#(^|[[:space:]])((sk-)?(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp[0-9]+)(@openssh\.com)?)[[:space:]]+[A-Za-z0-9+/]+=*#\1\2 <key-redacted>#g' \
              | sed -E 's#@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}#@<fqdn-redacted>#g' \
              | _redact_public_ip | _redact_identity
            ;;
        *) _redact_public_ip | _redact_identity ;;
    esac
}

_artifact_ids() {
    local inv; inv="$(_inv "$1")"
    "$YQ" e '.artifacts // [] | .[] | .id' "$inv" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
cmd_capture() {
    local host="${1:-}"; shift || true
    [ -n "$host" ] || { print_error "usage: pl server-state capture <host>"; exit 1; }
    _require_inv "$host"

    local only=""
    local a; for a in "$@"; do case "$a" in --artifact=*) only="${a#*=}" ;; esac; done

    local dir; dir="$(_dir "$host")"; mkdir -p "$dir"
    print_header "Capture: $host"

    # Read the id list into an array FIRST. Iterating a process substitution
    # while the loop body shells out to ssh let ssh drain the id stream (see
    # the -n note in _fetch); an array cannot be consumed by a child.
    local ids=(); mapfile -t ids < <(_artifact_ids "$host")

    local id kind rc=0 n=0
    for id in "${ids[@]}"; do
        [ -n "$id" ] || continue
        [ -n "$only" ] && [ "$id" != "$only" ] && continue
        kind=$(id="$id" "$YQ" e '.artifacts[] | select(.id == strenv(id)) | .kind // "file"' "$(_inv "$host")")

        local tmp="${dir}/.${id}.tmp"
        if ! _fetch "$host" "$id" > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            print_status "FAIL" "UNREACHABLE ${id}"
            rc=1; continue
        fi
        _redact "$kind" < "$tmp" > "${dir}/${id}"
        rm -f "$tmp"
        n=$((n + 1))
        print_status "OK" "captured ${id}"
    done

    echo ""
    print_info "Captured ${n} of ${#ids[@]} declared artifact(s) into servers/${host}/system/"
    print_info "NOT YET SAFE: commit them. Untracked capture is worse than none —"
    print_info "the tree then LOOKS captured. Verify with: pl server-state check ${host}"
    return $rc
}

# ---------------------------------------------------------------------------
cmd_diff() {
    local host="${1:-}"; shift || true
    [ -n "$host" ] || { print_error "usage: pl server-state diff <host>"; exit 1; }
    _require_inv "$host"

    local only=""
    local a; for a in "$@"; do case "$a" in --artifact=*) only="${a#*=}" ;; esac; done

    local dir; dir="$(_dir "$host")"
    print_header "Drift: $host"

    # Array, not a process substitution — see the note in cmd_capture.
    local ids=(); mapfile -t ids < <(_artifact_ids "$host")

    local id kind rc=0 drift=0 unreach=0 ok=0 examined=0
    for id in "${ids[@]}"; do
        [ -n "$id" ] || continue
        [ -n "$only" ] && [ "$id" != "$only" ] && continue
        examined=$((examined + 1))
        kind=$(id="$id" "$YQ" e '.artifacts[] | select(.id == strenv(id)) | .kind // "file"' "$(_inv "$host")")

        local captured="${dir}/${id}"
        if [ ! -f "$captured" ]; then
            print_status "FAIL" "MISSING ${id} — declared but never captured"
            rc=1; continue
        fi

        local live; live="$(mktemp)"
        if ! _fetch "$host" "$id" 2>/dev/null | _redact "$kind" > "$live"; then
            rm -f "$live"
            # "Cannot verify" is NOT "clean".
            print_status "FAIL" "UNREACHABLE ${id} — cannot confirm the captured copy is still true"
            unreach=$((unreach + 1)); rc=1; continue
        fi

        if diff -q "$captured" "$live" >/dev/null 2>&1; then
            ok=$((ok + 1))
            print_status "OK" "${id}"
        else
            drift=$((drift + 1)); rc=1
            print_status "FAIL" "DRIFT ${id} — live differs from the captured copy"
            diff -u "$captured" "$live" 2>/dev/null | sed -n '3,20p' | sed 's/^/      /' || true
        fi
        rm -f "$live"
    done

    echo ""
    # Denominator is what was EXAMINED, not what was declared: under
    # --artifact= the two differ, and reporting "0 of 9" for a single-artifact
    # run overstates the coverage of the answer.
    printf "  %s of %s examined in sync, %s drifted, %s unreachable" "$ok" "$examined" "$drift" "$unreach"
    [ "$examined" -lt "${#ids[@]}" ] && printf " (%s of %s declared)" "$examined" "${#ids[@]}"
    printf "\n"
    [ "$rc" -eq 0 ] || print_info "Re-capture with: pl server-state capture ${host} (then COMMIT)"
    return $rc
}

# ---------------------------------------------------------------------------
# Repo-side invariants. No network, so this is the CI-safe half.
#
# The headline assertion is TRACKEDNESS. Root .gitignore carries a blanket
# `servers/*`, so a captured file is ignored by default and `git status` stays
# clean while the tree looks captured. Presence-on-disk is therefore not
# evidence of anything.
# ---------------------------------------------------------------------------
cmd_check() {
    local hosts=() a
    for a in "$@"; do case "$a" in --all) ;; -*) ;; *) hosts+=("$a") ;; esac; done

    if [ "${#hosts[@]}" -eq 0 ]; then
        local f
        for f in "$ROOT"/servers/*/system/inventory.yml; do
            [ -e "$f" ] || continue
            f="${f%/system/inventory.yml}"; hosts+=("$(basename "$f")")
        done
    fi
    [ "${#hosts[@]}" -gt 0 ] || { print_error "no host inventories found under servers/*/system/"; exit 1; }

    [ -n "$YQ" ] || { print_error "yq is required (go-yq / mikefarah)"; exit 1; }

    local problems=0 host id
    for host in "${hosts[@]}"; do
        print_header "Check: $host"
        local inv; inv="$(_inv "$host")"
        [ -f "$inv" ] || { print_status "FAIL" "no inventory: servers/${host}/system/inventory.yml"; problems=$((problems+1)); continue; }

        local dir; dir="$(_dir "$host")"

        # The inventory itself must be tracked, or the declaration is as
        # ephemeral as the thing it declares.
        _assert_tracked "$inv" "inventory" || problems=$((problems+1))

        while IFS= read -r id; do
            [ -n "$id" ] || continue
            local f="${dir}/${id}"
            if [ ! -f "$f" ]; then
                print_status "FAIL" "MISSING ${id} — declared in the inventory, never captured"
                problems=$((problems+1)); continue
            fi
            _assert_tracked "$f" "$id" || { problems=$((problems+1)); continue; }

            # Redaction invariant: no key material may sit in the captured tree.
            if grep -qE '(^|[[:space:]])(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp[0-9]+)[[:space:]]+[A-Za-z0-9+/]{32,}' "$f"; then
                print_status "FAIL" "KEY-MATERIAL ${id} — captured file contains an un-redacted public key"
                problems=$((problems+1)); continue
            fi

            # THE nwp-daily-audit LESSON, generalised.
            #
            # met runs ~/bin/nwp-daily-audit (257 lines); the repo ships
            # scripts/nwp-daily-audit.sh (331 lines). They share no header —
            # two different programs with the same job, one of which reported
            # "no change" for 31 nights over a stopped container. Nothing
            # detected it, because nothing was comparing them.
            #
            # So: an artifact may declare a repo counterpart. If the two differ
            # and no `counterpart_divergence:` justification is recorded, that
            # is an error. Divergence is allowed — it is often temporary and
            # legitimate — but it must be DECLARED, in the file, where review
            # can see it. Silent divergence is the failure mode.
            local cp_path cp_why
            cp_path=$(id="$id" "$YQ" e '.artifacts[] | select(.id == strenv(id)) | .repo_counterpart // ""' "$inv")
            if [ -n "$cp_path" ]; then
                cp_why=$(id="$id" "$YQ" e '.artifacts[] | select(.id == strenv(id)) | .counterpart_divergence // ""' "$inv")
                local cp_abs="${ROOT}/${cp_path}"
                if [ ! -f "$cp_abs" ]; then
                    print_status "FAIL" "COUNTERPART-MISSING ${id} — declares ${cp_path}, which does not exist"
                    problems=$((problems+1)); continue
                fi
                if ! diff -q "$f" "$cp_abs" >/dev/null 2>&1; then
                    if [ -z "$cp_why" ]; then
                        print_status "FAIL" "COUNTERPART-DRIFT ${id} — differs from ${cp_path} with no declared reason"
                        problems=$((problems+1)); continue
                    fi
                    print_status "WARN" "DECLARED-DIVERGENCE ${id} vs ${cp_path}"
                    printf "      %s\n" "$cp_why"
                    continue
                fi
            fi
            print_status "OK" "$id"
        done < <(_artifact_ids "$host")
    done

    echo ""
    if [ "$problems" -gt 0 ]; then
        print_error "${problems} problem(s)"
        print_info "UNTRACKED is the common one: root .gitignore has a blanket 'servers/*',"
        print_info "so a captured file is invisible until it is negated AND committed."
        return 1
    fi
    print_status "OK" "every declared artifact is captured, tracked and redacted"
    return 0
}

_assert_tracked() {
    local f="$1" label="$2" repo rel
    repo="$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$repo" ]; then
        print_status "FAIL" "UNTRACKED ${label} — not inside a git repository"
        return 1
    fi
    rel="$(realpath --relative-to="$repo" "$f" 2>/dev/null || printf '%s' "$f")"
    if ! git -C "$repo" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
        print_status "FAIL" "UNTRACKED ${label} — on disk but not in version control"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Declared per-SAPI setting floors.
#
# known C, generalised. The 2026-07-26 Moodle outage was a max_input_vars
# ceiling; the remedy was applied to PHP 8.3 while Moodle runs on 8.2. A check
# that asked "is 5000 set anywhere on this box" would have passed throughout —
# so the floor is asserted against the SAPI the site actually uses, named
# explicitly in the inventory with a `why`.
# ---------------------------------------------------------------------------
cmd_php_check() {
    local host="${1:-}"
    [ -n "$host" ] || { print_error "usage: pl server-state php-check <host>"; exit 1; }
    _require_inv "$host"
    local inv; inv="$(_inv "$host")"

    local n; n=$("$YQ" e '.php_floors // [] | length' "$inv")
    [ "$n" -gt 0 ] || { print_info "no php_floors declared for ${host}"; return 0; }

    local map; map="$(mktemp)"
    if ! _fetch "$host" "php-map" > "$map" 2>/dev/null; then
        rm -f "$map"
        print_error "UNREACHABLE — could not read the PHP settings map from ${host}"
        return 1
    fi

    print_header "PHP floors: $host"
    local i rc=0
    for ((i = 0; i < n; i++)); do
        local sapi setting min why live
        sapi=$(i="$i"    "$YQ" e ".php_floors[strenv(i)|tonumber].sapi"       "$inv")
        setting=$(i="$i" "$YQ" e ".php_floors[strenv(i)|tonumber].setting"    "$inv")
        min=$(i="$i"     "$YQ" e ".php_floors[strenv(i)|tonumber].min"        "$inv")
        why=$(i="$i"     "$YQ" e ".php_floors[strenv(i)|tonumber].why // \"\"" "$inv")

        live=$(grep -E "^${sapi//\//\\/}[[:space:]]" "$map" | grep -oE "${setting}=[0-9]+" | head -1 | cut -d= -f2 || true)

        if [ -z "$live" ]; then
            # The SAPI a site depends on not appearing in the map is exactly the
            # 8.2-vs-8.3 shape: silence there must not read as satisfied.
            print_status "FAIL" "BELOW-FLOOR ${sapi} ${setting} — not set (PHP default), need >= ${min}"
            [ -n "$why" ] && printf "      %s\n" "$why"
            rc=1; continue
        fi
        if [ "$live" -lt "$min" ]; then
            print_status "FAIL" "BELOW-FLOOR ${sapi} ${setting}=${live}, need >= ${min}"
            [ -n "$why" ] && printf "      %s\n" "$why"
            rc=1; continue
        fi
        print_status "OK" "${sapi} ${setting}=${live} (>= ${min})"
    done
    rm -f "$map"
    return $rc
}

cmd_list() {
    print_header "Host inventories"
    local f host n
    local found=0
    for f in "$ROOT"/servers/*/system/inventory.yml; do
        [ -e "$f" ] || continue
        found=1
        host="$(basename "$(dirname "$(dirname "$f")")")"
        n=$("$YQ" e '.artifacts // [] | length' "$f" 2>/dev/null || echo '?')
        printf "  ${BOLD}%-14s${NC} %s artifact(s)\n" "$host" "$n"
    done
    [ "$found" = 1 ] || print_info "none yet — servers/<host>/system/inventory.yml"
}

show_help() {
    cat << EOF
${BOLD}pl server-state${NC} — capture host state into git, and prove it still matches

${BOLD}USAGE:${NC}
  pl server-state list
  pl server-state capture   <host> [--artifact=ID]   read-only; writes servers/<host>/system/
  pl server-state diff      <host> [--artifact=ID]   OK / DRIFT / UNREACHABLE (non-zero on either)
  pl server-state check     [<host>|--all]           repo-side: captured + TRACKED + redacted
  pl server-state php-check <host>                   declared per-SAPI setting floors

${BOLD}NOTES:${NC}
  capture never writes to a host. Applying declared state back is ${DIM}pl host apply${NC}.
  UNREACHABLE is an error, never a pass — "could not check" is not "clean".
  ssh-policy artifacts are redacted at capture: options kept, key material dropped.
EOF
}

main() {
    case "${1:-}" in
        ""|-h|--help) show_help ;;
        list)      shift; cmd_list "$@" ;;
        capture)   shift; cmd_capture "$@" ;;
        diff)      shift; cmd_diff "$@" ;;
        check)     shift; cmd_check "$@" ;;
        php-check) shift; cmd_php_check "$@" ;;
        *) print_error "Unknown subcommand: $1"; echo ""; show_help; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
