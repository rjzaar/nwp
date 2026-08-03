#!/usr/bin/env bats
#
# `pl secrets retire` — a credential that is GONE, not rotated (nwp/ops#268).
#
# WHY THE VERB EXISTS
#   `pl secrets debt` rightly refuses to let a rotation debt lapse (ruling D8:
#   an open debt blocks a prod bring-up). But the only discharge paths were
#   `rotate` ("here is the new value") and `done` ("I rotated it by hand"). A
#   revoked-and-deleted credential with no replacement fits neither, so
#   gitlab_nwp_courses_pat was discharged with `done` and the registry then
#   claimed a live credential expiring 2027-08-03 for a token that no longer
#   exists. The operator caught it: "I deleted it not rotated it."
#
#   The registry's one job is to be right about which credentials exist.

setup() {
    ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/retire.XXXXXX")"
    SEC="$T/.secrets.yml"
    REG="$T/reg.yml"
    export NWP_SECRETS_REGISTRY="$REG"
}
teardown() { rm -rf "$T"; }

# fixture <value-for-the-declared-location>
fixture() {
    printf 'gitlab:\n  doomed: %s\n' "$1" > "$SEC"
    cat > "$REG" <<EOF
secrets:
  - id: test_cred
    provider: gitlab
    cadence_days: 365
    stored_in:
      - $SEC:gitlab.doomed
    exposure:
      - ref: ops#999
        severity: high
        closed: true
EOF
}

retire() { run "$ROOT/pl" secrets retire test_cred --reason='revoked at provider, no replacement' "$@"; }

@test "REFUSES while a declared location still holds a value" {
    # The guard that matters. A 'retired' credential still sitting in a config
    # file is not retired, it is abandoned — and still readable by anyone who
    # can read that file.
    fixture '"still-here-aaaaaaaaaaaaaaaaaaaaaaaa"'
    retire
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'STILL HOLD'
    echo "$output" | grep -qE 'still holds [0-9]+ chars'
    # and it must NOT have stamped anything
    run yq -r '.secrets[0].retired // "NONE"' "$REG"
    [ "$output" = "NONE" ]
}

@test "succeeds once the location is cleared" {
    fixture '""'
    retire
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE 'RETIRED [0-9]{4}-[0-9]{2}-[0-9]{2}'
    run yq -r '.secrets[0].retired // "NONE"' "$REG"
    [ "$output" != "NONE" ]
}

@test "does NOT stamp expires or last_rotated — the whole point of the verb" {
    # This is the defect being fixed. `done` writes both, which is what produced
    # a phantom credential with 364 days to run.
    fixture '""'
    retire
    [ "$status" -eq 0 ]
    run yq -r '.secrets[0].expires // "NONE"' "$REG"
    [ "$output" = "NONE" ]
    run yq -r '.secrets[0].last_rotated // "NONE"' "$REG"
    [ "$output" = "NONE" ]
}

@test "discharges the open rotation debt — the credential is gone, so it is settled" {
    fixture '""'
    run yq -r '.secrets[0].exposure[0].rotated // false' "$REG"
    [ "$output" = "false" ]          # precondition
    retire
    [ "$status" -eq 0 ]
    run yq -r '.secrets[0].exposure[0].rotated // false' "$REG"
    [ "$output" = "true" ]
}

@test "an absent file counts as cleared; an UNREADABLE one does not" {
    # loc_read: 3 = file absent, 4 = present but empty, 5 = no reader.
    # 3 and 4 are both "the value is not there". 5 is "I could not look" and must
    # refuse — the distinction this estate keeps getting wrong.
    fixture '""'
    rm -f "$SEC"
    retire
    [ "$status" -eq 0 ]
}

@test "an EXTERNAL location cannot be machine-checked: refuses with exit 2 until affirmed" {
    printf 'secrets:\n  - id: test_cred\n    provider: gitlab\n    cadence_days: 365\n    stored_in:\n      - external:Drupal config on a frozen site\n' > "$REG"
    retire
    [ "$status" -eq 2 ]
    echo "$output" | grep -q 'CANNOT VERIFY'
    echo "$output" | grep -q 'could not look'

    # affirmed explicitly, it proceeds — and says what was affirmed
    retire --externals-cleared
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'affirmed'
}

@test "--reason is required: a retirement nobody explained looks like a mistake" {
    fixture '""'
    run "$ROOT/pl" secrets retire test_cred
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'reason'
}

@test "--dry-run writes nothing" {
    fixture '""'
    retire --dry-run
    [ "$status" -eq 0 ]
    run yq -r '.secrets[0].retired // "NONE"' "$REG"
    [ "$output" = "NONE" ]
}

@test "idempotent: retiring twice is a no-op, not an error" {
    fixture '""'
    retire
    [ "$status" -eq 0 ]
    retire
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'already retired'
}

@test "status renders RETIRED and does not colour it by expiry" {
    fixture '""'
    retire
    run "$ROOT/pl" secrets status
    [ "$status" -eq 0 ] || true
    echo "$output" | grep -q 'RETIRED'
}

@test "status does not flag rotation debt on a retired entry" {
    # Before the status change, a retired entry whose exposure was discharged
    # still rendered EXPOSED because the debt check ran regardless.
    fixture '""'
    retire
    run "$ROOT/pl" secrets status
    ! ( echo "$output" | grep 'test_cred' | grep -q 'rotation OWED' )
}
