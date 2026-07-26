#!/usr/bin/env bats
# Item 7 — a rollback point whose artifact is not in version control is not a
# rollback point.
#
# `pl rollback register` already refuses an artifact it cannot RESOLVE (item 2
# added that). Resolution only proves a file is sitting on this laptop right
# now. CP17 in the consolidation-arc registry was registered against a tarball
# that existed on disk and was, at the time, untracked -- so the ledger's own
# integrity check was green while the artifact was one `git clean` away from
# gone. The laptop is the machine we are least entitled to assume survives:
# it travels, and the fleet backup crons back up the box and the site DBs, not
# un-pushed local files.
#
# So the bar is TRACKEDNESS, not existence. These cases pin that.

setup() {
    REAL_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    PL="${REAL_ROOT}/pl"
    FIX="${BATS_TEST_TMPDIR}/fix"
    mkdir -p "$FIX/docs"

    git init -q "$FIX"
    git -C "$FIX" config user.email t@t.t
    git -C "$FIX" config user.name t

    export NWP_ROLLBACK_REGISTRY="${FIX}/docs/rollback-registry.md"
    cat > "$NWP_ROLLBACK_REGISTRY" <<'MD'
# Rollback registry (fixture)

| CP | Date | What | Artifact(s) + sha | Verified | Restore |
|----|------|------|-------------------|----------|---------|
MD
    git -C "$FIX" add -A
    git -C "$FIX" -c commit.gpgsign=false commit -qm init
}

# NOTE ON PATHS. Artifacts are named RELATIVE TO THE REGISTRY DIRECTORY, which
# is how _registry_resolve already finds them and how the real rows are
# written. Naming them "docs/snap/..." instead would fail to resolve at all and
# the case would go red for the wrong reason -- a green-looking red.
# Measured on origin/main before the fix, with a resolvable path:
#   $ pl rollback register --cp=CP99 --artifact=snap/thing.tar.gz ...
#   INFO: Wrote integrity sidecar: thing.tar.gz.sha256
#   [OK] Registered CP99
#   rc=0            <-- untracked artifact accepted, row written
@test "register REFUSES an artifact that exists on disk but is untracked" {
    mkdir -p "${FIX}/docs/snap"
    echo body > "${FIX}/docs/snap/thing.tar.gz"   # never git-added

    run "$PL" rollback register --cp=CP99 --what="fixture" \
        --artifact=snap/thing.tar.gz --restore="tar -xzf thing.tar.gz"
    [ "$status" -ne 0 ]
    [[ "$output" == *UNTRACKED* ]]
    # and it must not have written a row it then cannot honour
    ! grep -q 'CP99' "$NWP_ROLLBACK_REGISTRY"
}

@test "register ACCEPTS the same artifact once it is committed" {
    mkdir -p "${FIX}/docs/snap"
    echo body > "${FIX}/docs/snap/thing.tar.gz"
    git -C "$FIX" add -A
    git -C "$FIX" -c commit.gpgsign=false commit -qm snap

    run "$PL" rollback register --cp=CP98 --what="fixture" \
        --artifact=snap/thing.tar.gz --restore="tar -xzf thing.tar.gz"
    [ "$status" -eq 0 ]
    grep -q 'CP98' "$NWP_ROLLBACK_REGISTRY"
}

@test "register still accepts an artifact-free row (not every CP has a file)" {
    run "$PL" rollback register --cp=CP97 --what="config-only change" \
        --restore="git revert abc123"
    [ "$status" -eq 0 ]
    grep -q 'CP97' "$NWP_ROLLBACK_REGISTRY"
}

@test "an explicitly off-host artifact is allowed (it cannot be tracked here)" {
    # box:/etc/... paths are legitimately outside this repo; the registry check
    # already demands they carry a recorded sha instead.
    run "$PL" rollback register --cp=CP96 --what="box nginx conf" \
        --off-host --artifact="box:/etc/nginx/conf.d/ss.conf" \
        --sha=deadbeefcafe1234 --restore="scp back from CP96 note"
    [ "$status" -eq 0 ]
    grep -q 'CP96' "$NWP_ROLLBACK_REGISTRY"
}

# ---------------------------------------------------------------------------
# The same bar, applied to rows that are ALREADY in the ledger.
#
# `register` guards the front door, but every row written before the guard
# existed came in unchecked -- and the ledger is read at the worst possible
# moment, by someone who needs the artifact to still be there. So the checker
# has to re-assert trackedness over the whole file, not just trust that
# whatever wrote each row was careful.
#
# The specific hole: an artifact carrying a matching `.sha256` sidecar took the
# sidecar branch and was reported OK without any trackedness question being
# asked. A sidecar proves the bytes have not rotted. It says nothing about
# whether the bytes survive `git clean -xfd`, a reimaged laptop or a pruned
# worktree -- and both the artifact and its sidecar are equally untracked, so
# the check is comparing a file to its own untracked shadow.
#
# Measured on this branch BEFORE the fix (fixture: untracked tarball + matching
# sidecar):
#   [✓] CP90: snap/ghost.tar.gz
#   [✓] Registry consistent (1 rows)
#   rc=0
# ---------------------------------------------------------------------------
@test "registry check FAILS on a row whose artifact has a good sidecar but is untracked" {
    mkdir -p "${FIX}/docs/snap"
    echo body > "${FIX}/docs/snap/ghost.tar.gz"
    ( cd "${FIX}/docs/snap" && sha256sum ghost.tar.gz > ghost.tar.gz.sha256 )
    # neither the artifact nor its sidecar is git-added -- the CP17 shape

    printf '| CP90 | 2026-07-26 | fixture | `snap/ghost.tar.gz` | — | tar -xzf |\n' \
        >> "$NWP_ROLLBACK_REGISTRY"

    run "$PL" rollback registry check
    [ "$status" -ne 0 ]
    [[ "$output" == *UNTRACKED* ]]
}

@test "registry check PASSES on that same row once the artifact is committed" {
    mkdir -p "${FIX}/docs/snap"
    echo body > "${FIX}/docs/snap/ghost.tar.gz"
    ( cd "${FIX}/docs/snap" && sha256sum ghost.tar.gz > ghost.tar.gz.sha256 )
    git -C "$FIX" add -A
    git -C "$FIX" -c commit.gpgsign=false commit -qm snap

    printf '| CP90 | 2026-07-26 | fixture | `snap/ghost.tar.gz` | — | tar -xzf |\n' \
        >> "$NWP_ROLLBACK_REGISTRY"

    run "$PL" rollback registry check
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The remedy must not be worse than the defect.
#
# "Untracked" and "untrackable" are different problems. A site DB dump or files
# tarball is excluded by the repo's own ignore policy BECAUSE committing it is
# the P0 this estate already has: a 36 MB member-data .sql pushed to the forge,
# where no Art.17 erasure can reach it. A checker that responds to such a row
# with "commit it" would, if obeyed, manufacture that P0 again -- and it would
# be obeyed, because it is printed at the moment someone is under pressure.
#
# So a policy-ignored artifact must still FAIL (it really does exist in one
# travelling place), but with the second-copy remedy, and it must never utter
# the word "commit".
# ---------------------------------------------------------------------------
@test "registry check FAILS a policy-ignored data artifact WITHOUT telling anyone to commit it" {
    mkdir -p "${FIX}/docs/snap"
    echo 'INSERT INTO users' > "${FIX}/docs/snap/site.sql.gz"
    # NB anchoring: a pattern containing a slash is rooted at the repo top, so
    # `snap/*.sql.gz` would NOT match docs/snap/. Getting this wrong made the
    # case fail for the wrong reason on first run.
    echo 'docs/snap/*.sql.gz' > "${FIX}/.gitignore"
    git -C "$FIX" add .gitignore
    git -C "$FIX" -c commit.gpgsign=false commit -qm ignore

    printf '| CP91 | 2026-07-26 | fixture | `snap/site.sql.gz` | — | restore |\n' \
        >> "$NWP_ROLLBACK_REGISTRY"

    run "$PL" rollback registry check
    [ "$status" -ne 0 ]
    [[ "$output" == *LAPTOP-ONLY* ]]
    [[ "$output" == *"do NOT commit"* ]]
    # The dangerous advice must be absent, not merely outweighed.
    [[ "$output" != *"Commit it,"* ]]
}

# A sidecar mismatch must still be caught, and must not be masked by the new
# trackedness question -- otherwise the fix would trade one blind spot for
# another.
@test "registry check still FAILS a tracked artifact whose sidecar no longer matches" {
    mkdir -p "${FIX}/docs/snap"
    echo body > "${FIX}/docs/snap/ghost.tar.gz"
    ( cd "${FIX}/docs/snap" && sha256sum ghost.tar.gz > ghost.tar.gz.sha256 )
    echo tampered > "${FIX}/docs/snap/ghost.tar.gz"
    git -C "$FIX" add -A
    git -C "$FIX" -c commit.gpgsign=false commit -qm snap

    printf '| CP90 | 2026-07-26 | fixture | `snap/ghost.tar.gz` | — | tar -xzf |\n' \
        >> "$NWP_ROLLBACK_REGISTRY"

    run "$PL" rollback registry check
    [ "$status" -ne 0 ]
    [[ "$output" == *sha256* ]]
}
