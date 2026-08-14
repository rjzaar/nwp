#!/usr/bin/env bats
#
# ops#351 — `pl console register` parsed the control plane's reply through
# pipelines whose exit status it then consumed, under `set -euo pipefail`
# (console.sh line 2). Three sites:
#
#   printf '%s' "$out" | grep -qi 'not found' && print_hint "…"     (×2, COND)
#   given=$(printf '%s' "$out" | sed -n 's/^Node \(.*\) registered$/\1/p' | head -1)
#                                                                   (ERREXIT)
#
# In each, the early-exiting reader (`grep -q`, `head -1`) leaves the moment it
# has what it needs; the writer is then killed by SIGPIPE and exits 141; and
# `pipefail` promotes 141 to the pipeline's verdict. The `&&` then does not
# fire, or — worse — the bare assignment fails and `set -e` aborts the verb
# immediately AFTER the device has already been admitted to the mesh.
#
# `$out` is REMOTE OUTPUT: it is whatever this headscale version chose to
# print, not something this repo controls. At today's sizes (one line on
# success, a line plus a usage blurb on failure) none of the three can fire —
# which is exactly the "will not fire today" statement about a size nobody
# controls that the ops#351 operator note flags. These fixtures make the writer
# outrun the 64 KiB pipe buffer so the failure is CERTAIN and the proof is not
# itself a flake.
#
# All three assert CORRECTNESS (the right name, the right hint), never merely
# that repeated runs agree: five identical wrong answers are perfectly stable.

setup() {
    CONSOLE_SH="$BATS_TEST_DIRNAME/../../scripts/commands/console.sh"
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    PATH="$STUB_BIN:$PATH"
    export PATH
    export NWP_CONSOLE_HEADSCALE_HOST=stub-control-plane
    export NWP_CONSOLE_HEADSCALE_USER=nwp
    export NWP_CONSOLE_CONFIG=/nonexistent
}

# A stub control plane. $1 = exit code for `nodes register`, stdin = the body
# it prints for that call.
mk_control_plane() {
    local rc="$1"
    cat > "$STUB_BIN/register-body"
    cat > "$STUB_BIN/ssh" <<EOF
#!/bin/bash
cmd="\${!#}"
case "\$cmd" in
    *"users list"*)     printf '[{"id":"1","name":"nwp"}]\n'; exit 0 ;;
    *"nodes register"*) cat "$STUB_BIN/register-body"; exit $rc ;;
    *"nodes list"*)     printf '[{"id":"7","given_name":"phone","name":"phone"}]\n'; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$STUB_BIN/ssh"
}

@test "register reports the node name when the control plane replies at length (ops#351)" {
    # 3000 further 'Node … registered' lines ≈ 210 KiB against a 64 KiB pipe:
    # `head -1` takes the first and leaves, and `sed` is killed mid-write.
    {
        printf 'Node phone registered\n'
        seq 1 3000 | while read -r i; do
            printf 'Node pad-to-cross-the-64KiB-pipe-buffer-%04d registered\n' "$i"
        done
    } | mk_control_plane 0

    run "$CONSOLE_SH" register EXAMPLE-node-key-NOT-REAL-0000
    [ "$status" -eq 0 ]
    [[ "$output" == *"registered as 'phone'"* ]]
}

@test "register still prints the expired-key hint when the error is verbose (ops#351)" {
    # headscale prints the error and then its usage. 'not found' is on the
    # first line, so `grep -qi` leaves at once and `printf` is killed with
    # ~150 KiB still to write — and the hint that names the real cause never
    # prints.
    {
        printf 'Error: node not found\n'
        seq 1 3000 | while read -r i; do
            printf '  --flag-%04d string   usage padding the control plane emitted\n' "$i"
        done
    } | mk_control_plane 1

    run "$CONSOLE_SH" register EXAMPLE-node-key-NOT-REAL-0000
    [ "$status" -ne 0 ]
    [[ "$output" == *"headscale caches a pending registration"* ]]
    [[ "$output" == *"reload it there for a fresh key and retry"* ]]
}

# The negative: a failure that is NOT a missing pending registration must not
# grow the hint. A "fix" that printed the hint unconditionally would pass the
# test above.
@test "register does not offer the expired-key hint for an unrelated failure (ops#351)" {
    printf 'Error: permission denied\n' | mk_control_plane 1

    run "$CONSOLE_SH" register EXAMPLE-node-key-NOT-REAL-0000
    [ "$status" -ne 0 ]
    [[ "$output" != *"headscale caches a pending registration"* ]]
}

# The negative for the name parse: a reply that names no node must leave
# `given` empty rather than inventing one.
@test "register claims no name when the control plane names no node (ops#351)" {
    printf 'nothing that matches the registered-node line\n' | mk_control_plane 0

    run "$CONSOLE_SH" register EXAMPLE-node-key-NOT-REAL-0000
    [ "$status" -eq 0 ]
    [[ "$output" != *"registered as '"* ]]
}
