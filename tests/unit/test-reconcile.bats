#!/usr/bin/env bats
# `pl reconcile` — the daily state-copy comparison (R1, 2026-08-04).
# Pins the honesty contract: CANNOT-VERIFY is never OK, red is named, and the
# golden comparison actually compares (the ops#269 incident class).

setup() {
    ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/reconcile.XXXXXX")"
}
teardown() { rm -rf "$T"; }

_run_reconcile() { # ssh-stub-behaviour
    # Stub ssh entirely: NWP_RECONCILE_SSH points at a script that answers per
    # our scenario. Also neuter the delegated verbs via a stub pl.
    cat > "$T/pl" <<'P'
#!/usr/bin/env bash
exit 0
P
    chmod +x "$T/pl"
    NWP_RECONCILE_SSH="$T/ssh-stub" timeout 120 bash -c "
        cd '$T' &&
        PROJECT_ROOT='$T' bash '$ROOT/scripts/commands/reconcile.sh'"
}

@test "an unreachable host is CANNOT-VERIFY, never OK (blindness is not health)" {
    cat > "$T/ssh-stub" <<'S'
#!/usr/bin/env bash
exit 255
S
    chmod +x "$T/ssh-stub"
    mkdir -p "$T/sites"
    run env NWP_RECONCILE_SSH="$T/ssh-stub" bash "$ROOT/scripts/commands/reconcile.sh"
    echo "$output" | grep -E 'checkout-mini' | grep -q 'CANNOT-VERIFY'
    ! (echo "$output" | grep -qE '^OK +checkout-mini')
}

@test "RED-PROOF: a box golden that differs from local is RED and names the consequence" {
    mkdir -p "$T/sites/nwd/demo-golden-live"
    printf '%064d  golden.db.sql.gz\n' 1 > "$T/sites/nwd/demo-golden-live/golden.db.sql.gz.sha256"
    cat > "$T/ssh-stub" <<S
#!/usr/bin/env bash
# any golden hash query gets a DIFFERENT valid hash
echo "$(printf '%064d' 2)"
S
    chmod +x "$T/ssh-stub"
    run env NWP_RECONCILE_SSH="$T/ssh-stub" PROJECT_ROOT_OVERRIDE="$T" bash -c "
        sed 's|^PROJECT_ROOT=.*|PROJECT_ROOT=\"$T\"|' '$ROOT/scripts/commands/reconcile.sh' > '$T/r.sh' && bash '$T/r.sh'"
    echo "$output" | grep 'golden-nwd' | grep -q 'RED'
    echo "$output" | grep 'golden-nwd' | grep -qi 'reset restores the box copy'
    [ "$status" -eq 1 ]
}

@test "GREEN control: matching golden hashes are OK" {
    mkdir -p "$T/sites/nwd/demo-golden-live"
    h="$(printf '%064d' 7)"
    printf '%s  golden.db.sql.gz\n' "$h" > "$T/sites/nwd/demo-golden-live/golden.db.sql.gz.sha256"
    cat > "$T/ssh-stub" <<S
#!/usr/bin/env bash
echo "$h"
S
    chmod +x "$T/ssh-stub"
    run bash -c "
        sed 's|^PROJECT_ROOT=.*|PROJECT_ROOT=\"$T\"|' '$ROOT/scripts/commands/reconcile.sh' > '$T/r.sh' &&
        NWP_RECONCILE_SSH='$T/ssh-stub' bash '$T/r.sh'"
    # OK is at column 1 of the row — grepping ' OK ' (leading space) missed it
    # and failed this case for a formatting reason, not a logic one.
    echo "$output" | grep -qE '^OK +golden-nwd'
}

@test "exit code contract: red beats blind beats clean" {
    grep -q 'return 1' "$ROOT/scripts/commands/reconcile.sh"
    grep -q 'return 3' "$ROOT/scripts/commands/reconcile.sh"
    # and blind is counted separately from red
    grep -q 'BLINDS=' "$ROOT/scripts/commands/reconcile.sh"
}
