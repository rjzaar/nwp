#!/usr/bin/env bash
#
# lint-credential-files.sh — a credential may never become a FILE.
#
# WHY THIS FILE EXISTS
#   Measured 2026-08-16 (ops#374): 56 files under /tmp — later 82 — each held a
#   LIVE `glpat-` token. All were 0600 and owner-only; the oldest was four days
#   old. They were curl config files written by the estate's own "0600 curl
#   config" pattern, which CLAUDE.md recommends precisely because it keeps the
#   token out of argv where `ps` can read it:
#
#       cfg=$(mktemp); chmod 600 "$cfg"
#       printf 'header = "PRIVATE-TOKEN: %s"\n' "$token" > "$cfg"
#       curl -K "$cfg" ...
#       rm -f "$cfg"                      # <-- not reached if we are killed
#
#   The `rm -f` is not a guarantee. 50 of the 56 landed on :00/:01/:30/:31 —
#   a half-hourly job cut off mid-call. `nwp_http_get` was the worst offender
#   because it SLEEPS between retries, holding the file open for seconds at a
#   time with a live credential in it.
#
#   A trap was the obvious fix and it is NOT sufficient: EXIT/INT/TERM handlers
#   do not run on SIGKILL, on an OOM kill, or when the machine loses power. The
#   fix that has no gap is to stop creating the file at all — curl reads its
#   config from STDIN with `-K -`, so there is nothing on disk to leak on any
#   path, including the paths no handler can reach.
#
# WHAT THIS ASSERTS, over tracked shell sources
#   R1  No `curl -K <path>` / `--config <path>`. The argument must be `-`.
#       A config file that is never read is not the pattern; a config file that
#       IS read is a credential at rest, however briefly.
#   R2  No line that writes a credential header into a file:
#           printf '... header = "PRIVATE-TOKEN: ...' ... > "$cfg"
#       covering PRIVATE-TOKEN, Authorization and Bearer.
#
# FAIL CLOSED
#   No readable corpus (no tracked shell files, or git unavailable) is exit 2
#   CANNOT VERIFY, never exit 0 — an unreadable corpus is not a clean one.
#
# EXEMPTIONS
#   This file, because it must quote the pattern it hunts for; and anything the
#   caller names in NWP_CREDFILE_LINT_EXEMPT (space-separated paths), which is
#   how the bats fixture drives the failing case. Exemptions are never silent:
#   each one is printed.
set -uo pipefail

# NWP_CREDFILE_LINT_ROOT points the scan at another repo. It exists so the gate
# can be PROVEN RED: tests/unit/test-credential-files.bats builds a throwaway git
# repo containing the exact pre-ops#374 pattern and asserts this script exits 1
# naming it. A lint that has only ever been seen green is a hypothesis, not a
# gate (CLAUDE.md standing order).
cd "${NWP_CREDFILE_LINT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/../..}" || exit 2

SELF="scripts/ci/lint-credential-files.sh"
EXEMPT="${NWP_CREDFILE_LINT_EXEMPT:-}"

# ── corpus ───────────────────────────────────────────────────────────────────
# Tracked shell sources only. Untracked scratch is not the repo's problem, and
# scanning it makes the gate flaky.
mapfile -t FILES < <(
    { git ls-files -- '*.sh' 'pl' 2>/dev/null || true; } | sort -u
)

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "lint:credential-files: CANNOT VERIFY — no tracked shell files readable (git missing or empty tree)"
    exit 2
fi

is_exempt() {
    local f="$1" e
    [ "$f" = "$SELF" ] && return 0
    # curl STAND-INS. tests/unit/helpers/{fake,slow}-curl.sh exist to be curl for
    # a test, so they must keep accepting `-K <file>` exactly as real curl does.
    # Exempting them is not a hole: they are test doubles, never a caller, and
    # they hold no credential of their own.
    case "$f" in tests/unit/helpers/*curl*.sh) return 0 ;; esac
    for e in $EXEMPT; do [ "$f" = "$e" ] && return 0; done
    return 1
}

fail=0
scanned=0

for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    if is_exempt "$f"; then
        echo "lint:credential-files: EXEMPT $f"
        continue
    fi
    scanned=$((scanned + 1))

    # R1 — curl must read its config from stdin, never from a path.
    # Matches `-K x` / `-K"x"` / `--config x` / `--config=x` where x is not `-`.
    #
    # Scoped to lines that actually invoke `curl`, and skipping comments: other
    # tools take a `--config` too (gitleaks does, on a continuation line), and a
    # gate that reddens on an unrelated flag gets switched off within a week.
    # The cost of that scoping is that a `-K "$cfg"` split onto a continuation
    # line of its own is not seen by R1 — R2 catches the write that fed it.
    while IFS=: read -r ln text; do
        [ -n "$ln" ] || continue
        echo "R1 $f:$ln: curl reads its config from a FILE — use \`-K -\` and feed the config on stdin"
        echo "      $(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
        fail=1
    done < <(grep -nE '(^|[^[:alnum:]_-])(-K|--config)([[:space:]]*=?[[:space:]]*)("?[^-[:space:]"][^[:space:]"]*"?)' "$f" 2>/dev/null \
             | grep -E '(^|:)[[:space:]]*[0-9]+:[^#]*\bcurl\b' || true)

    # R2 — a credential header must never be redirected into a file.
    while IFS=: read -r ln text; do
        [ -n "$ln" ] || continue
        echo "R2 $f:$ln: a credential header is written into a FILE — build the config and pipe it to \`curl -K -\`"
        echo "      $(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
        fail=1
    done < <(grep -nE 'header[[:space:]]*=[[:space:]]*.?(PRIVATE-TOKEN|Authorization|Bearer)' "$f" 2>/dev/null \
             | grep -E '>>?[[:space:]]*"?\$' || true)
done

echo "lint:credential-files: scanned $scanned tracked shell file(s)"

if [ "$fail" -ne 0 ]; then
    cat <<'EOF'

A credential must never become a file.

  WRONG                                     RIGHT
  cfg=$(mktemp); chmod 600 "$cfg"           { printf 'silent\n'
  printf 'header = "PRIVATE-TOKEN: %s"\n' \    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok"
    "$tok" > "$cfg"                           printf 'url = "%s"\n' "$url"
  curl -K "$cfg" ...                        } | curl -K - ...
  rm -f "$cfg"      # never runs if killed

A trap is NOT an acceptable substitute: SIGKILL, an OOM kill and power loss all
run no handler. ops#374 found 56 such files in /tmp holding a live glpat- token.
EOF
    exit 1
fi

echo "lint:credential-files: OK — no credential is written to, or read from, a file"
exit 0
