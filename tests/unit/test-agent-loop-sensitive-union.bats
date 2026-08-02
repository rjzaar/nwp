#!/usr/bin/env bats
#
# The agent-loop's pre-push gate must block the UNION of two lists:
#
#   SENSITIVE_PATH_RE   operational — repo machinery an autonomous agent must
#                       not weaken (CI, the loop, gitleaks, keys, deploy verbs)
#   CLAUDE.md           policy — the paths requiring two-person approval
#
# Neither contains the other, which is the whole point of this suite. Measured
# 2026-08-02: CLAUDE.md carried three paths the regex missed (including
# CLAUDE.md itself, so an agent could rewrite its own standing orders unchecked)
# while the regex carried eleven the policy never declared. "Just use the single
# source of truth" would have deleted those eleven.
#
# These tests exercise the LIVE definitions extracted from the shipped files,
# never a copy — a copied pattern proves only that the copy is self-consistent.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    LOOP="$REPO_ROOT/scripts/agent-loop/agent-loop.sh"
    export NWP_ROOT="$REPO_ROOT"

    # Extract the live operational pattern (hoisted to one line for exactly this).
    RE="$(grep -oP "(?<=^SENSITIVE_PATH_RE=').*(?='\$)" "$LOOP")"
    [ -n "$RE" ] || return 1

    # Load the live policy half and the live composition function.
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/sensitive-paths.sh"
    SENSITIVE_PATH_RE="$RE"
    eval "$(awk '/^sensitive_path_re_effective\(\) \{/,/^\}/' "$LOOP")"
    _SENSITIVE_PATHS_LIB="$REPO_ROOT/lib/sensitive-paths.sh"
}

blocks() { echo "$1" | grep -qE "$(sensitive_path_re_effective)"; }

# --- the three CLAUDE.md paths the operational regex missed -------------------

@test "CLAUDE.md itself is blocked — an agent may not rewrite its own orders" {
    blocks 'CLAUDE.md'
    # and prove this is the union doing the work, not the old regex
    run bash -c "echo CLAUDE.md | grep -qE '$RE'"
    [ "$status" -ne 0 ]
}

@test "**/settings.php is blocked (was missed by the operational regex)" {
    blocks 'web/sites/default/settings.php'
    run bash -c "echo web/sites/default/settings.php | grep -qE '$RE'"
    [ "$status" -ne 0 ]
}

@test "composer.json is blocked (was missed by the operational regex)" {
    blocks 'composer.json'
    run bash -c "echo composer.json | grep -qE '$RE'"
    [ "$status" -ne 0 ]
}

# --- the operational half must NOT be lost to the policy half -----------------

@test "the eleven operational paths still block — the union subtracts nothing" {
    for f in scripts/ci/lint-bash.sh \
             scripts/agent-loop/agent-loop.sh \
             nwp.yml \
             .gitleaks.toml \
             lib/loop-parts.sh \
             lib/sanitizers/x.sh \
             contracts/validate.py \
             deploy.pem \
             .github/workflows/x.yml \
             scripts/commands/stg2live.sh \
             scripts/console/app/main.py; do
        blocks "$f" || { echo "REGRESSION: $f no longer blocked"; return 1; }
    done
}

@test "an ordinary file is still allowed — the gate did not become block-everything" {
    # Compute the pattern in THIS shell. Calling it inside `bash -c` leaves the
    # function undefined there, so $(...) expands to empty and `grep -qE ""`
    # matches every line — the assertion would fail for a reason unrelated to
    # the gate. (It did, on the first run.)
    local re
    re="$(sensitive_path_re_effective)"
    [ -n "$re" ]
    ! echo 'docs/guides/miniterm.md' | grep -qE "$re"
    ! echo 'lib/rag-render.py'       | grep -qE "$re"
    ! echo 'README.md'               | grep -qE "$re"
}

# --- fail-closed --------------------------------------------------------------

@test "FAIL-CLOSED: a missing policy library returns 2, it does not fall back" {
    _SENSITIVE_PATHS_LIB="$BATS_TMPDIR/definitely-absent-$$.sh"
    run sensitive_path_re_effective
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "FAIL-CLOSED: an unparseable CLAUDE.md returns 2 rather than an empty policy" {
    export NWP_CLAUDE_MD="$BATS_TMPDIR/empty-$$.md"
    printf '# nothing here\n' > "$NWP_CLAUDE_MD"
    run sensitive_path_re_effective
    [ "$status" -eq 2 ]
}

# --- the anti-drift assertion -------------------------------------------------

@test "ANTI-DRIFT: every glob CLAUDE.md declares is blocked by the effective gate" {
    # This is the test that stops the original defect returning. Adding a path
    # to CLAUDE.md's list arms the gate on the next run; if some future change
    # breaks that derivation, this goes red naming the path that lost cover.
    local re missed=""
    re="$(sensitive_path_re_effective)"
    while IFS= read -r glob; do
        [ -n "$glob" ] || continue
        # a representative concrete path for each glob form
        local sample="${glob//\*\*\//web/sites/default/}"
        sample="${sample//\*/x}"
        echo "$sample" | grep -qE "$re" || missed="$missed $glob"
    done <<< "$(nwp_sensitive_globs)"
    [ -z "$missed" ] || { echo "CLAUDE.md globs with no cover:$missed"; return 1; }
}
