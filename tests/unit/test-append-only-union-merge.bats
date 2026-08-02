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
