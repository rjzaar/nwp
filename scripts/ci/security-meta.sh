#!/usr/bin/env bash
#
# security-meta.sh — the meta-repo half of the old `security:scan` job, made
# reachable and made able to fail.
#
# WHY THIS FILE EXISTS
#   `security:scan` in .gitlab-ci.yml was gated on `rules: - exists: [composer.json]`.
#   There is NO composer.json at the root of nwp/nwp (verified 2026-07-26), so the
#   entire `security` stage has never run on this repository. And had it run:
#     * every check ended in `|| echo "WARNING: …"`,
#     * `secrets_found` / `suspicious_found` were assigned and never read,
#     * the job was `allow_failure: true`.
#   Three independent reasons it could not go red.
#
#   The composer/npm audit halves genuinely need a Drupal-site pipeline and stay
#   in `security:scan`. Everything below needs only the repo, so it runs
#   unconditionally here.
#
# CORPUS
#   `git ls-files` — tracked files only. sites/ and servers/ are gitignored and
#   full of third-party code; scanning them would produce a baseline nobody reads.
#
# BASELINE (shrink-only, same contract as .yq-first-baseline)
#   .security-meta-baseline holds `<check>:<path>` for pre-existing hits.
#   New hit not in the baseline          → exit 1.
#   Baseline entry that no longer hits   → exit 1 (delete the line).
#   Regenerate: scripts/ci/security-meta.sh --update-baseline
#
# EXIT
#   0 — clean against the baseline
#   1 — new finding, or stale baseline entry
#   2 — cannot verify (not a git repo / empty corpus)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE="${NWP_SECURITY_META_BASELINE:-$PROJECT_ROOT/.security-meta-baseline}"
UPDATE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --update-baseline) UPDATE=1 ;;
        --baseline=*) BASELINE="${1#*=}" ;;
        --root=*) PROJECT_ROOT="${1#*=}" ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

cd "$PROJECT_ROOT" || exit 2
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "ERROR: $PROJECT_ROOT is not a git work tree — cannot determine the corpus." >&2
    exit 2
}

mapfile -d '' -t tracked < <(git ls-files -z)
if [ "${#tracked[@]}" -eq 0 ]; then
    echo "ERROR: no tracked files — refusing to report success on an empty corpus." >&2
    exit 2
fi

hits_file="$(mktemp)"
trap 'rm -f "$hits_file"' EXIT
: > "$hits_file"

# ---------------------------------------------------------------- the checks
# Each check appends `<check>:<path>` lines. Paths (not line numbers) are the
# baseline key so the baseline survives edits to unrelated parts of a file.

_grep_files() {
    # _grep_files <check-name> <ere> <name-glob>...
    local check="$1" ere="$2"; shift 2
    local globs=("$@") f g subset=()
    for f in "${tracked[@]}"; do
        [ -f "$f" ] || continue
        for g in "${globs[@]}"; do
            # shellcheck disable=SC2053
            if [[ "$f" == $g || "$g" == '*' ]]; then subset+=("$f"); break; fi
        done
    done
    [ "${#subset[@]}" -eq 0 ] && return 0
    printf '%s\0' "${subset[@]}" \
        | LC_ALL=C xargs -0 -r grep -lIE "$ere" 2>/dev/null \
        | sed "s|^|${check}:|" >> "$hits_file"
    return 0
}

echo "=== Hardcoded credential shapes ==="
_grep_files "hardcoded-secret" \
    '(api_key|api_token|access_token|secret_key|private_key)[[:space:]]*=[[:space:]]*['"'"'"][^'"'"'"]{20,}' \
    '*.php' '*.sh' '*.js' '*.yml' '*.py'

echo "=== AWS access-key shape ==="
_grep_files "aws-key" 'AKIA[0-9A-Z]{16}' '*'

echo "=== Private-key material ==="
_grep_files "private-key-block" '-----BEGIN [A-Z ]*PRIVATE KEY-----' '*'

echo "=== Dynamic code execution ==="
_grep_files "dynamic-exec" \
    '(^|[^A-Za-z_>])(eval|base64_decode|passthru|shell_exec|proc_open)[[:space:]]*\(' \
    '*.php' '*.js'

echo "=== Obfuscation shapes ==="
_grep_files "obfuscation" '(chr\([0-9]+\)|\\x[0-9a-f]{2}){5,}' '*.php' '*.js'

echo "=== Group/world-writable tracked files ==="
for f in "${tracked[@]}"; do
    [ -f "$f" ] || continue
    perm=$(stat -c '%a' "$f" 2>/dev/null) || continue
    case "$perm" in
        *[2367]) echo "world-writable:${f}" >> "$hits_file" ;;
    esac
done

sort -u "$hits_file" -o "$hits_file"

# ------------------------------------------------------------------ baseline
if [ "$UPDATE" -eq 1 ]; then
    {
        echo "# .security-meta-baseline — pre-existing meta-repo security findings."
        echo "# SHRINK-ONLY. Key = <check>:<path>. Delete a line when the finding is"
        echo "# resolved; regenerate with: scripts/ci/security-meta.sh --update-baseline"
        cat "$hits_file"
    } > "$BASELINE"
    echo "Baseline written: $BASELINE ($(wc -l < "$hits_file") finding(s))"
    exit 0
fi

declare -A base=()
if [ -f "$BASELINE" ]; then
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        case "$k" in \#*) continue ;; esac
        base["$k"]=1
    done < "$BASELINE"
fi

new=0
while IFS= read -r k; do
    [ -z "$k" ] && continue
    if [ -z "${base[$k]+x}" ]; then
        new=$((new + 1))
        echo "NEW FINDING: $k"
    fi
done < "$hits_file"

stale=0
for k in "${!base[@]}"; do
    if ! grep -qxF "$k" "$hits_file"; then
        stale=$((stale + 1))
        echo "STALE BASELINE ENTRY: $k"
    fi
done

if [ "$new" -gt 0 ]; then
    echo ""
    echo "ERROR: $new new security finding(s). Fix them, or — if genuinely benign —"
    echo "       add the exact key to $BASELINE with a comment saying why."
fi
if [ "$stale" -gt 0 ]; then
    echo ""
    echo "ERROR: $stale baseline entr(y|ies) no longer match anything."
    echo "       The baseline is SHRINK-ONLY: delete the stale line(s)."
fi
if [ "$new" -gt 0 ] || [ "$stale" -gt 0 ]; then
    exit 1
fi

echo "OK — ${#tracked[@]} tracked file(s) scanned, $(wc -l < "$hits_file") baselined finding(s), none new."
exit 0
