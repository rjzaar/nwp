#!/usr/bin/env bash
#
# lint-bash.sh — bash syntax gate that can actually fail.
#
# WHY THIS FILE EXISTS
#   The `lint:bash` CI job used to be:
#       find scripts/commands lib -name "*.sh" -type f -exec bash -n {} \;
#   `find -exec … \;` reports the exit status of *find*, not of the commands it
#   ran, so a file with a syntax error printed the error and the job exited 0.
#   Proven 2026-07-26 on a probe tree: the error text appeared in the log and
#   `EXIT=0`. A gate that cannot go red is decoration.
#
#   Keeping the command in a script (rather than inline YAML) also means the
#   acceptance test in tests/unit/test-ci-lint-commands.bats runs *the same
#   code CI runs*, not a copy of it that can drift.
#
# USAGE
#   scripts/ci/lint-bash.sh [ROOT ...]
#     ROOT defaults to: pl scripts lib tests
#
# EXIT
#   0 — every checked file parses
#   1 — at least one file failed `bash -n` (each failure printed)
#   2 — nothing was checked (empty corpus ⇒ "cannot verify", never a silent pass)

set -uo pipefail

roots=("$@")
if [ ${#roots[@]} -eq 0 ]; then
    roots=(pl scripts lib tests)
fi

# Only consider roots that exist — a missing optional root is not a failure,
# but an entirely empty corpus is (see exit 2 below).
existing=()
for r in "${roots[@]}"; do
    [ -e "$r" ] && existing+=("$r")
done

files=()
if [ ${#existing[@]} -gt 0 ]; then
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(
        find "${existing[@]}" \
            \( -path '*/node_modules/*' -o -path '*/vendor/*' -o -path '*/.git/*' \) -prune -o \
            \( -type f \( -name '*.sh' -o -name '*.bash' -o -name 'pl' \) \) -print0
    )
fi

if [ ${#files[@]} -eq 0 ]; then
    echo "ERROR: lint-bash found no shell files under: ${roots[*]}" >&2
    echo "       Refusing to report success on an empty corpus." >&2
    exit 2
fi

failed=0
checked=0
for f in "${files[@]}"; do
    checked=$((checked + 1))
    if ! bash -n "$f" 2>&1; then
        echo "SYNTAX ERROR: $f" >&2
        failed=$((failed + 1))
    fi
done

if [ "$failed" -gt 0 ]; then
    echo ""
    echo "FAIL: $failed of $checked shell file(s) have syntax errors." >&2
    exit 1
fi

echo "OK — $checked shell file(s) parse cleanly."
exit 0
