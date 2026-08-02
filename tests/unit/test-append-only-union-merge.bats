#!/usr/bin/env bats
#
# The append-only arc ledgers (rollback-registry.md, decision-log.md) carry
# `merge=union` in .gitattributes so that two agents appending different rows
# is not a conflict. See the rationale block in .gitattributes.
#
# These tests build a throwaway repo and perform real merges, because the thing
# under test is git's behaviour under an attribute — asserting that the line
# exists in .gitattributes would only prove someone typed it. The union
# attribute is worth having only if a concurrent append MERGES and a duplicate
# checkpoint id still FAILS; both are proven here.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/union-merge.XXXXXX")"
    cd "$TMP" || return 1
    git init -q -b main .
    git config user.email t@example.invalid
    git config user.name  t
    # The estate mandates signed commits, and the runner may enforce that
    # globally. A fixture repo has no key, so every `git commit` here would
    # fail and ALL cases in this file would go red for a reason unrelated to
    # merge behaviour — which is exactly what happened in CI while the suite
    # passed locally. Disable signing for the throwaway repo only.
    git config commit.gpgsign false
    git config tag.gpgsign false
    mkdir -p docs/reports/arc-test
    cp "$REPO_ROOT/.gitattributes" .gitattributes
    # The gate pins itself to its own repo root (cd to BASH_SOURCE/../..), which
    # is correct for CI but means invoking the real copy would silently grade
    # the real registry instead of this fixture — it passed for that reason on
    # the first run. Copy it in so it grades the fixture it is pointed at.
    mkdir -p scripts/ci
    cp "$REPO_ROOT/scripts/ci/lint-rollback-registry-ids.sh" scripts/ci/
    LEDGER=docs/reports/arc-test/rollback-registry.md
    printf '| ID | What | Restore |\n|----|------|--------|\n| CP1 | base | run x |\n' > "$LEDGER"
    git add -A
    git commit -qm base
}

teardown() { cd / || true; rm -rf "$TMP"; }

# Two agents, two branches, each appending its own row to the same table end.
append_on_branch() { # branch, row
    git checkout -q -b "$1" main
    printf '%s\n' "$2" >> "$LEDGER"
    git commit -qam "append $1"
}

@test "concurrent appends to the rollback registry merge without conflict" {
    append_on_branch agent-a '| CP2 | agent A did a thing | run a |'
    append_on_branch agent-b '| CP3 | agent B did a thing | run b |'

    git checkout -q main
    git merge -q --no-edit agent-a
    run git merge --no-edit agent-b
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -qi conflict
}

@test "BOTH agents' rows survive the union merge — neither side is dropped" {
    append_on_branch agent-a '| CP2 | agent A did a thing | run a |'
    append_on_branch agent-b '| CP3 | agent B did a thing | run b |'

    git checkout -q main
    git merge -q --no-edit agent-a
    git merge -q --no-edit agent-b

    # The whole point of union on a ledger: losing a row loses a restore path.
    grep -q 'CP2 | agent A' "$LEDGER"
    grep -q 'CP3 | agent B' "$LEDGER"
    grep -q 'CP1 | base'    "$LEDGER"
    [ "$(grep -c '^| CP' "$LEDGER")" -eq 3 ]
}

@test "RED-PROOF: without the attribute the same merge conflicts" {
    # Proves the attribute is what does the work, not some incidental property
    # of the fixture. If this test ever passes cleanly, the other two prove
    # nothing.
    rm .gitattributes
    git commit -qam 'drop attributes'
    append_on_branch agent-a '| CP2 | agent A did a thing | run a |'
    append_on_branch agent-b '| CP3 | agent B did a thing | run b |'

    git checkout -q main
    git merge -q --no-edit agent-a
    run git merge --no-edit agent-b
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi conflict
}

@test "union merge does NOT hide a duplicate checkpoint id — the gate still fails it" {
    # The one genuinely dangerous case. Union will happily keep two rows that
    # claim the same id, and one id offering two different restore commands is
    # worse than a missing row (lint-rollback-registry-ids.sh's own words).
    # That gate is the reason `merge=union` is defensible here, so it is tested
    # together with the attribute rather than trusted separately.
    append_on_branch agent-a '| CP2 | agent A did a thing | run a |'
    append_on_branch agent-b '| CP2 | agent B did a DIFFERENT thing | run b |'

    git checkout -q main
    git merge -q --no-edit agent-a
    run git merge --no-edit agent-b
    [ "$status" -eq 0 ]           # merges silently — this is the hazard

    run ./scripts/ci/lint-rollback-registry-ids.sh
    [ "$status" -ne 0 ]           # …and the gate is what catches it
    echo "$output" | grep -q 'CP2'
}

@test "the decision log carries the same attribute" {
    LEDGER=docs/reports/arc-test/decision-log.md
    printf '| D1 | base |\n' > "$LEDGER"
    git add -A && git commit -qm 'decision log'
    append_on_branch dl-a '| D2 | agent A decided |'
    append_on_branch dl-b '| D3 | agent B decided |'

    git checkout -q main
    git merge -q --no-edit dl-a
    run git merge --no-edit dl-b
    [ "$status" -eq 0 ]
    grep -q 'D2' "$LEDGER"
    grep -q 'D3' "$LEDGER"
}

@test "an amended row is NOT duplicated by a plain merge" {
    # The merge path handles the amendment correctly — git compares endpoints,
    # so only the final version lands. Pinned so the limitation below is
    # attributed to the right mechanism (rebase) rather than to union itself.
    git checkout -q -b amend-side main
    printf '%s\n' '| CP2 | thing | MR TBD |' >> "$LEDGER"
    git commit -qam 'add row'
    sed -i 's/MR TBD/MR !317/' "$LEDGER"
    git commit -qam 'amend row'

    git checkout -q main
    printf '%s\n' '| CP3 | other agent | run b |' >> "$LEDGER"
    git commit -qam 'concurrent append'
    git merge -q --no-edit amend-side

    [ "$(grep -c '^| CP2 ' "$LEDGER")" -eq 1 ]
    grep -q 'MR !317' "$LEDGER"
}

@test "KNOWN LIMIT: REBASE replays the amendment and the row survives twice" {
    # The path that actually bites: GitLab's rebase button, and draining the
    # queue by hand, replay each commit in turn — so the "add" lands and the
    # "amend" then arrives as a change to a line union has already kept.
    # Asserting this via merge would report no problem (see the test above) and
    # would prove nothing.
    git checkout -q main
    printf '%s\n' '| CP3 | other agent | run b |' >> "$LEDGER"
    git commit -qam 'concurrent append'

    git checkout -q -b amend-side main~1 2>/dev/null || git checkout -q -b amend-side main
    printf '%s\n' '| CP2 | thing | MR TBD |' >> "$LEDGER"
    git commit -qam 'add row'
    sed -i 's/MR TBD/MR !317/' "$LEDGER"
    git commit -qam 'amend row'

    run git rebase main
    [ "$status" -eq 0 ]
    [ "$(grep -c '^| CP2 ' "$LEDGER")" -eq 2 ]   # the limitation, made visible

    # …and it is NOT silent: the gate refuses the duplicated id.
    run ./scripts/ci/lint-rollback-registry-ids.sh
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'CP2'
}
