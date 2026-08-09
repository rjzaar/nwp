#!/usr/bin/env bats
#
# pl fleet estate / pl fleet checkout — the estate-overview feeds (nwp/ops#329).
#
# WHAT THIS FILE PROVES:
#
#  1. Both verbs emit PARSEABLE JSON with the contract keys the console's
#     parsers (scripts/console/app/parsers.py parse_estate/parse_checkout)
#     depend on. A key rename here silently blanks a console slot, which is
#     exactly the unreadable-renders-as-clean failure ops#329 exists to stop.
#
#  2. The refusal contract (ops#225): an unrecognised argument REFUSES with
#     exit 2 rather than running a different command than the one written.
#
#  3. checkout is honest about currency: the behind-count travels WITH the age
#     of the fetch it was measured against (fetched_age_seconds present in the
#     document — null allowed, absent not).
#
# RED-THEN-GREEN: run against the pre-ops#329 tree, `pl fleet estate --json`
# printed the fleet help text (no such subcommand) and this file failed on
# every test; quoted in the MR.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "fleet estate --json emits the contract keys" {
    run "$PROJECT_ROOT/pl" fleet estate --json
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read().strip().splitlines()[-1])
assert d["ok"] is True, d
for key in ("generated_at", "host", "repos", "deploys", "harvest",
            "secrets_debt", "backups"):
    assert key in d, f"missing key: {key}"
assert isinstance(d["repos"], list) and d["repos"], "repos empty"
r = d["repos"][0]
assert r["name"] == "nwp"
for key in ("present", "branch", "head", "ahead", "behind", "fetched", "dirty"):
    assert key in r, f"repo row missing: {key}"
'
}

@test "fleet checkout --json emits the contract keys incl fetch age" {
    run "$PROJECT_ROOT/pl" fleet checkout --json
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read().strip().splitlines()[-1])
assert d["ok"] is True, d
for key in ("root", "branch", "head", "head_short", "head_time",
            "ahead", "behind", "fetched_age_seconds", "dirty", "loop_paused"):
    assert key in d, f"missing key: {key}"
'
}

@test "fleet estate refuses an unrecognised argument (exit 2)" {
    run "$PROJECT_ROOT/pl" fleet estate --frobnicate
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
}

@test "fleet checkout refuses an unrecognised argument (exit 2)" {
    run "$PROJECT_ROOT/pl" fleet checkout --frobnicate
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
}
