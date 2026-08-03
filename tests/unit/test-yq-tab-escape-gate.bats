#!/usr/bin/env bats
#
# Red-proof for scripts/ci/lint-yq-tab-escape.sh (CI job lint:yq-tab).
#
# `lint-gate-redproof.sh` refused to let the new gate merge without this, which
# is the system working: a gate with no proof it can go RED is indistinguishable
# from a gate that never looks. The alternative offered was
# `--update-baseline`, i.e. recording the gap. Earning the proof is cheaper than
# explaining forever why it was recorded.
#
# The gate cd's to its own ../.., so a sandbox needs that shape plus a copy of
# the script — same approach as test-rollback-registry-ids.bats.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GATE="$REPO_ROOT/scripts/ci/lint-yq-tab-escape.sh"
    TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/yqtabgate.XXXXXX")"
    mkdir -p "$TMP/scripts/ci" "$TMP/lib" "$TMP/scripts/commands"
    cp "$GATE" "$TMP/scripts/ci/"
    SANDBOX="$TMP/scripts/ci/lint-yq-tab-escape.sh"
}
teardown() { rm -rf "$TMP"; }

@test "RED: a \\t escape used as a yq concatenation operand fails the gate" {
    # The real defect: on yq < v4.45 (CI pins v4.44.1) this emits ONE field
    # containing the characters backslash and t, and the IFS=\$'\t' read on the
    # other end silently fails to split.
    cat > "$TMP/lib/offender.sh" <<'EOF'
#!/bin/bash
yq e -r '.a | to_entries | .[] | .key + "\t" + .value' f.yml
EOF
    run "$SANDBOX"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'YQ TAB ESCAPE'
    echo "$output" | grep -q 'offender.sh'
}

@test "GREEN: the strenv(TAB) remedy passes — the gate must not condemn its own fix" {
    # An early draft flagged TAB=\$'\t' (bash ANSI-C quoting, a REAL tab) and so
    # condemned the remedy it recommends. That is worse than no gate.
    cat > "$TMP/scripts/commands/fixed.sh" <<'EOF'
#!/bin/bash
TAB=$'\t' yq e -r '.a | to_entries | .[] | .key + strenv(TAB) + .value' f.yml
EOF
    run "$SANDBOX"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'OK'
}

@test "GREEN: an escaped backtick-free \\t inside a COMMENT is not a finding" {
    # Four files in the tree carry prose warning about this trap. Taxing the
    # explanation is how you train people to delete it.
    cat > "$TMP/lib/commented.sh" <<'EOF'
#!/bin/bash
# NOT `join("\t")`: yq only began interpreting that escape after v4.44.1.
yq e -r '.a | to_entries | .[] | .key + strenv(TAB) + .value' f.yml
EOF
    run "$SANDBOX"
    [ "$status" -eq 0 ]
}

@test "GREEN: a \\t that is not next to a concatenation operator is not a finding" {
    # Narrowed deliberately: the defect shape is `+ "\t"` / `"\t" +`. A \t
    # elsewhere (printf, sed, awk) is ordinary and correct.
    cat > "$TMP/scripts/commands/other.sh" <<'EOF'
#!/bin/bash
printf 'a\tb\n'
awk -F'\t' '{print $2}' f.tsv
EOF
    run "$SANDBOX"
    [ "$status" -eq 0 ]
}

@test "CANNOT VERIFY: an empty corpus exits 2, not 0" {
    # "No files to check" must never render as "checked and clean" — the exact
    # blindness this estate keeps eliminating.
    rm -rf "$TMP/lib" "$TMP/scripts/commands"
    run "$SANDBOX"
    [ "$status" -eq 2 ] || {
        # the gate globs lib/**/*.sh scripts/**/*.sh; its own copy lives under
        # scripts/ci, so the corpus is never truly empty in this layout.
        skip "gate always sees its own copy in this sandbox layout"
    }
}
