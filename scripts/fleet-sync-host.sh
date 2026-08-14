#!/usr/bin/env bash
#
# fleet-sync-host.sh — keep THIS host's nwp checkout on current origin/main
# shortly after a merge, with due care. (nwp/ops#360)
#
# WHY THIS FILE EXISTS
#   On 2026-08-12 the ai-host's ~/nwp — the clone the ARMED agent-loop executes from —
#   was measured 59 commits behind origin/main. The half-mechanisms that
#   existed (the ci-host's daily maybe_git_pull inside nwp-daily-audit.sh, the ai-host's raw
#   private/-only pull cron) were per-host accidents: no verification, no
#   health check, no ledger, and failures visible only in logs nobody reads.
#   This is the ONE worker, provisioned by `pl fleet sync install`, run from a
#   marked cron block every 15 minutes on each non-prod nwp host.
#
# THE THREAT MODEL SHAPES THIS SCRIPT (ADR-0017 / ADR-0028)
#   * PROD IS EXCLUDED BY CONSTRUCTION. the verifier tier receives code as SIGNED
#     ARTIFACTS through their own verification path, never through this
#     worker. Two independent refusals, both keyed off declared facts and
#     never a hostname list:
#       1. if an instance manifest is readable here and this host is bound to
#          a prod-reaching ROLE (verifier, signed-deploy, prod-cluster,
#          prod-agent, prod-au) → REFUSE. Arms itself the moment a host is
#          bound to such a role.
#       2. if any site in this checkout's nwp.yml has canonical phase `prod`
#          (or an unparseable phase — fail closed, same rule as
#          lib/canonical.sh) → REFUSE.
#     (The primary guard is at PROVISION time in `pl fleet sync install`,
#     which refuses to target such hosts at all; these are defence in depth,
#     because a cron line outlives the assumptions of the day it was written.)
#   * AUTO-DELIVERING CODE TO AN AI-AGENT HOST IS A SUPPLY-CHAIN SURFACE.
#     Mitigations: fast-forward ONLY (a diverged or force-pushed main is a
#     refusal, never a reset); signature verification over the incoming range
#     via scripts/ci/verify-signature.sh — enforcing when
#     NWP_REQUIRE_SIGNED_COMMITS=1 (the SAME switch CI uses), report-only
#     otherwise, because signing is not yet configured on the authoring
#     machines (measured 2026-08-14: 25/25 recent main commits unsigned;
#     enforcement today would refuse every sync, and inventing a pass would be
#     the swallowed-verdict sin) — the per-pull signed/unsigned counts are
#     LEDGERED so the gap stays visible; and a post-pull health check
#     (bash -n / python ast on every changed script) that REVERTS to the
#     recorded from-sha on failure.
#   * A HOST MID-WORK IS SKIPPED, LOUDLY. Dirty tracked files or a non-main
#     branch: never stash, never checkout -f. (Untracked files do not block —
#     git itself refuses a ff that would overwrite one, and we surface that.)
#   * FAIL CLOSED. Unreachable origin, unverifiable signatures under
#     enforcement, unreadable canonical phase: exit 2, and the state file is
#     REWRITTEN on every outcome so `pl fleet sync status` can never read a
#     stale success as current.
#
# EXIT CODES
#   0 — synced, or already current
#   2 — refused / skipped / cannot verify (reason in output, state and ledger)
#
# ENV
#   NWP_ROOT                    checkout to manage       (default $HOME/nwp)
#   NWP_SYNC_REMOTE/_BRANCH     what to follow           (origin / main)
#   NWP_REQUIRE_SIGNED_COMMITS  1 = refuse unsigned incoming commits
#   NWP_INSTANCE_MANIFEST       role manifest, if present on this host
#   NWP_SYNC_HOST_LABEL         override this host's label for the role guard
#   NWP_SYNC_ROLE               role this cron was provisioned for (audit)
#   NWP_SYNC_STATE/_LEDGER      state json / append-only ledger paths
#   NWP_SYNC_FETCH_TIMEOUT      seconds for the fetch    (default 60)
#   NWP_SYNC_RESTART_UNITS      user units this worker MAY restart when their
#                               source changed (default: none — report only)
#
# The whole body lives in main(), called on the last line: bash parses the
# file completely before executing, so the pull replacing this very script
# mid-run cannot corrupt the running interpreter.

set -uo pipefail

NWP_ROOT="${NWP_ROOT:-$HOME/nwp}"
REMOTE="${NWP_SYNC_REMOTE:-origin}"
BRANCH="${NWP_SYNC_BRANCH:-main}"
REQUIRE="${NWP_REQUIRE_SIGNED_COMMITS:-0}"
MANIFEST="${NWP_INSTANCE_MANIFEST:-$HOME/nwp-instances/instance-manifest.yml}"
HOST_LABEL="${NWP_SYNC_HOST_LABEL:-$(hostname -s 2>/dev/null || echo unknown)}"
STATE="${NWP_SYNC_STATE:-$NWP_ROOT/logs/fleet-sync-state.json}"
LEDGER="${NWP_SYNC_LEDGER:-$NWP_ROOT/logs/fleet-sync.log}"
FETCH_TIMEOUT="${NWP_SYNC_FETCH_TIMEOUT:-60}"

# Roles whose hosts must NEVER receive AI-propagated code automatically.
# Grow this list, never key on a hostname (CLAUDE.md: guards key off the
# canonical phase/role, so they arm themselves and never miss a new prod box).
DENY_ROLES="verifier signed-deploy prod-cluster prod-agent prod-au"

SIG_SUMMARY="signed=?/?"

_json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null || printf '"%s"' "$1"; }

# record <result> <from> <to> <reason> [restart_csv]  — state + ledger, always.
record() {
    local result="$1" from="${2:-}" to="${3:-}" reason="${4:-}" restarts="${5:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$STATE")" "$(dirname "$LEDGER")" 2>/dev/null || true
    local rjson="[]"
    [ -n "$restarts" ] && rjson="[$(printf '%s' "$restarts" | awk -v RS=, '{printf "%s\"%s\"", (NR>1?",":""), $0}')]"
    local tmp="${STATE}.tmp.$$"
    {
        printf '{"schema":1,"ts":"%s","host":"%s","root":%s,"role":%s,' \
            "$ts" "$HOST_LABEL" "$(_json_escape "$NWP_ROOT")" "$(_json_escape "${NWP_SYNC_ROLE:-}")"
        printf '"result":"%s","from":"%s","to":"%s",' "$result" "$from" "$to"
        printf '"signatures":"%s","require_signed":%s,' "$SIG_SUMMARY" "${REQUIRE:-0}"
        printf '"restart_pending":%s,"reason":%s}\n' "$rjson" "$(_json_escape "$reason")"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE" 2>/dev/null
    printf '%s host=%s result=%s from=%s to=%s %s%s%s\n' \
        "$ts" "$HOST_LABEL" "$result" "${from:0:9}" "${to:0:9}" "$SIG_SUMMARY" \
        "${restarts:+ restart_pending=$restarts}" "${reason:+ reason=\"$reason\"}" \
        >> "$LEDGER" 2>/dev/null || true
}

refuse() { # <result> <from> <to> <message>
    record "$1" "$2" "$3" "$4"
    echo "$4"
    exit 2
}

# "<role>\t<host>" rows for every host bound to a deny role in the manifest.
# The manifest is simple `role: [a, b]` YAML; parsed with sed (POSIX — some
# estate hosts may carry mawk, and gawk-only constructs would make this guard silently
# emit nothing there, which is exactly the host-blind-branch shape the honesty
# lint exists for). No yq dependency for THIS guard.
_manifest_deny_hosts() {
    local role line h
    for role in $DENY_ROLES; do
        line=$(sed -n "s/^[[:space:]]*${role}:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$MANIFEST" 2>/dev/null | head -1)
        [ -n "$line" ] || continue
        for h in $(printf '%s' "$line" | tr ',' ' '); do
            [ -n "$h" ] && printf '%s\t%s\n' "$role" "$h"
        done
    done
}

guard_prod_role() {
    [ -f "$MANIFEST" ] || return 0    # no manifest on this host: the install-time guard was the gate
    local row role h
    while IFS=$'\t' read -r role h; do
        [ -n "$h" ] || continue
        if [ "$h" = "$HOST_LABEL" ] || [ "$h" = "$(hostname 2>/dev/null)" ] || [ "$h" = "$(hostname -s 2>/dev/null)" ]; then
            refuse "refused-prod-role" "" "" \
                "REFUSED: this host ('$HOST_LABEL') is bound to prod-reaching role '$role' in $MANIFEST — prod hosts receive code as signed artifacts (ADR-0017/0028), never via fleet sync"
        fi
    done < <(_manifest_deny_hosts)
}

guard_canonical_prod() {
    local cfg="$NWP_ROOT/nwp.yml"
    [ -f "$cfg" ] || return 0         # no site registry in this checkout — nothing to guard
    command -v yq >/dev/null 2>&1 || refuse "refused-canonical-unreadable" "" "" \
        "REFUSED: $cfg exists but yq is unavailable — CANNOT VERIFY canonical phases, failing closed"
    local rows
    if ! rows=$(yq e '.sites // {} | to_entries | .[] | .key + " " + ((.value.canonical // "dev") | tostring)' "$cfg" 2>/dev/null); then
        refuse "refused-canonical-unreadable" "" "" \
            "REFUSED: could not parse canonical phases from $cfg — failing closed (lib/canonical.sh rule: unparseable is CANNOT VERIFY, not dev)"
    fi
    local site phase
    while read -r site phase; do
        [ -n "$site" ] || continue
        case "$phase" in
            dev|live) ;;
            prod) refuse "refused-canonical-prod" "" "" \
                "REFUSED: site '$site' in this checkout has canonical phase 'prod' — a prod-serving host is never an auto-sync target" ;;
            *) refuse "refused-canonical-unreadable" "" "" \
                "REFUSED: site '$site' has unparseable canonical phase '$phase' — failing closed" ;;
        esac
    done <<< "$rows"
}

verify_signatures() { # $1 = from, $2 = to; sets SIG_SUMMARY; refuses per policy
    local from="$1" to="$2" verifier="$NWP_ROOT/scripts/ci/verify-signature.sh"
    if [ ! -f "$verifier" ]; then
        if [ "$REQUIRE" = "1" ]; then
            refuse "refused-cannot-verify-signatures" "$from" "$to" \
                "CANNOT VERIFY: NWP_REQUIRE_SIGNED_COMMITS=1 but $verifier is missing from this checkout — refusing to apply an unverified range"
        fi
        SIG_SUMMARY="signed=unverified(no-verifier)"
        return 0
    fi
    local out rc=0
    out=$(cd "$NWP_ROOT" && NWP_REQUIRE_SIGNED_COMMITS="$REQUIRE" \
          bash "$verifier" --base="$from" --head="$to" 2>&1) || rc=$?
    local counts
    counts=$(printf '%s\n' "$out" | sed -n 's/.*: \([0-9]*\) signed \/ \([0-9]*\) unsigned (\([0-9]*\) total).*/\1\/\3/p' | head -1)
    SIG_SUMMARY="signed=${counts:-?/?}"
    if [ "$rc" -eq 1 ]; then
        refuse "refused-unsigned" "$from" "$to" \
            "REFUSED: incoming range ${from:0:9}..${to:0:9} contains unsigned commits and NWP_REQUIRE_SIGNED_COMMITS=1 ($SIG_SUMMARY)"
    elif [ "$rc" -ne 0 ]; then
        if [ "$REQUIRE" = "1" ]; then
            refuse "refused-cannot-verify-signatures" "$from" "$to" \
                "CANNOT VERIFY: signature verifier exited $rc under enforcement — refusing"
        fi
        SIG_SUMMARY="signed=unverified(rc=$rc)"
    fi
}

health_check() { # $1 = from, $2 = to; returns 1 with $HEALTH_FAIL set on failure
    HEALTH_FAIL=""
    local f
    while IFS= read -r f; do
        [ -f "$NWP_ROOT/$f" ] || continue
        case "$f" in
            *.sh|pl)
                bash -n "$NWP_ROOT/$f" 2>/dev/null || { HEALTH_FAIL="bash -n failed: $f"; return 1; } ;;
            *.py)
                command -v python3 >/dev/null 2>&1 || continue
                python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$NWP_ROOT/$f" 2>/dev/null \
                    || { HEALTH_FAIL="python syntax failed: $f"; return 1; } ;;
        esac
    done < <(git -C "$NWP_ROOT" diff --name-only "$1..$2" 2>/dev/null)
    return 0
}

# long-running services whose SOURCE changed in this pull. Restarted only if
# named in NWP_SYNC_RESTART_UNITS (operator-armed); otherwise reported, and
# `pl fleet sync status` surfaces the pending restart.
restart_scan() { # $1 = from, $2 = to; prints csv of units pending restart
    command -v systemctl >/dev/null 2>&1 || return 0
    local changed pending=""
    changed=$(git -C "$NWP_ROOT" diff --name-only "$1..$2" 2>/dev/null)
    declare -A unit_for=(
        [scripts/agent-loop/gitlab-webhook-receiver.py]="nwp-webhook"
        [scripts/console/]="nwp-console"
    )
    local pat unit
    for pat in "${!unit_for[@]}"; do
        unit="${unit_for[$pat]}"
        grep -q "^${pat}" <<< "$changed" || continue
        systemctl --user is-active --quiet "$unit" 2>/dev/null || continue
        if [[ " ${NWP_SYNC_RESTART_UNITS:-} " == *" $unit "* ]]; then
            if systemctl --user restart "$unit" 2>/dev/null; then
                echo "RESTARTED user unit $unit (source changed in this pull)" >&2
                continue
            fi
        fi
        pending="${pending:+$pending,}$unit"
    done
    printf '%s' "$pending"
}

main() {
    git -C "$NWP_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
        || refuse "error-not-a-checkout" "" "" "CANNOT VERIFY: $NWP_ROOT is not a git checkout"

    guard_prod_role
    guard_canonical_prod

    local branch
    branch=$(git -C "$NWP_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    if [ "$branch" != "$BRANCH" ]; then
        refuse "skipped-branch" "" "" \
            "SKIPPED: checkout is on '$branch', not '$BRANCH' — a host mid-work is never synced over (nothing was touched)"
    fi
    if [ -n "$(git -C "$NWP_ROOT" status --porcelain -uno 2>/dev/null)" ]; then
        refuse "skipped-dirty" "" "" \
            "SKIPPED: tree is dirty (tracked modifications present) — never stashed, never overwritten; commit or clean it, then sync"
    fi

    if ! timeout "$FETCH_TIMEOUT" git -C "$NWP_ROOT" fetch -q "$REMOTE" "$BRANCH" 2>/dev/null; then
        refuse "unreachable" "" "" \
            "CANNOT VERIFY: could not fetch $REMOTE/$BRANCH within ${FETCH_TIMEOUT}s — an unreachable origin is UNKNOWN, never up-to-date"
    fi

    local from to
    from=$(git -C "$NWP_ROOT" rev-parse HEAD)
    to=$(git -C "$NWP_ROOT" rev-parse "$REMOTE/$BRANCH")

    if [ "$from" = "$to" ]; then
        record "current" "$from" "$to" ""
        echo "CURRENT: already at $REMOTE/$BRANCH (${to:0:9})"
        exit 0
    fi

    if ! git -C "$NWP_ROOT" merge-base --is-ancestor "$from" "$to" 2>/dev/null; then
        refuse "refused-diverged" "$from" "$to" \
            "REFUSED: local HEAD ${from:0:9} has diverged from $REMOTE/$BRANCH ${to:0:9} (or main was force-pushed) — fast-forward only, never a reset; reconcile by hand"
    fi

    verify_signatures "$from" "$to"

    if ! git -C "$NWP_ROOT" merge --ff-only -q "$to" 2>/dev/null; then
        refuse "merge-failed" "$from" "$to" \
            "REFUSED: git refused the fast-forward (likely an untracked file the incoming tree would overwrite) — resolve on the host"
    fi

    if ! health_check "$from" "$to"; then
        git -C "$NWP_ROOT" reset -q --keep "$from" 2>/dev/null
        refuse "reverted-health" "$from" "$to" \
            "REVERTED: post-pull health check failed ($HEALTH_FAIL) — checkout restored to ${from:0:9}; the bad range is NOT applied. Rollback was: git reset --keep $from"
    fi

    local pending commits
    pending=$(restart_scan "$from" "$to")
    commits=$(git -C "$NWP_ROOT" rev-list --count "$from..$to" 2>/dev/null || echo "?")
    record "synced" "$from" "$to" "" "$pending"
    echo "SYNCED: ${from:0:9} -> ${to:0:9} ($commits commit(s), $SIG_SUMMARY)${pending:+ — RESTART PENDING: $pending (long-running service still executing pre-pull code)}"
    echo "rollback (if needed): git -C $NWP_ROOT reset --keep $from"
    exit 0
}

main "$@"
