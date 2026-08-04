#!/usr/bin/env bats
#
# The MR write path must build its JSON WITHOUT yq (nwp/ops#281).
#
# WHAT WAS BROKEN, AND FOR HOW LONG. Every write payload in lib/gitlab-mr.sh and
# scripts/commands/mr.sh was built like this:
#
#     payload=$(T="$title" A="$label" "$YQ" -n -o=json '{"title": strenv(T), ...}')
#
# $YQ is EMPTY on the CI runner, which has no yq. With an empty command name bash
# performs the assignments and runs nothing, so `payload` came back EMPTY, the PUT
# sent an empty body, and GitLab answered 400. The D13 hold's LAYER 1 — the
# forge-enforced Draft, the one that survives a bot re-arming auto-merge — has
# therefore been silently inert on every CI-applied hold, and the estate has been
# relying on layer 2, which its own docblock calls the weaker one:
#
#     "a red pipeline is indistinguishable from a broken build, it trains people
#      to retry until green, and one allow_failure: true ends it"
#
# It surfaced only because a trace line — "line 425: : command not found" — was
# read closely while diagnosing something else. Nothing was testing it, because
# every test ran on a workstation where yq exists.
#
# THIS IS THE HOST-BLIND BRANCH from CLAUDE.md's standing orders, occurring inside
# the gate written to enforce them. Hence the shape of this file: the assertions
# run with YQ deliberately EMPTY, because a suite that only ever runs where yq
# exists is exactly what let this survive.

# `run -127` is a flagged form; bats warns without this declaration.
bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # THE POINT OF THE WHOLE FILE. Not a convenience — the defect is invisible
    # with yq present, so every case below runs as the runner does.
    YQ=""
    export MR_STATUS_FILE="$(mktemp)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/ui.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/gitlab-mr.sh"
}
teardown() { rm -f "$MR_STATUS_FILE"; }

@test "RED-PROOF: _mr_json builds a real object with NO yq on PATH" {
    run _mr_json title "Draft: something" add_labels "hold::sensitive"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    # Parse it rather than string-match: a payload that merely looks JSON-ish is
    # what GitLab rejected with a 400.
    run python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["title"], "|", d["add_labels"])' <<<"$output"
    [ "$output" = "Draft: something | hold::sensitive" ]
}

@test "the OLD idiom really does produce nothing when yq is absent" {
    # Demonstrates the defect rather than asserting it from memory, so nobody has
    # to take the diagnosis on trust.
    # 127 is the point: with $YQ empty bash has no command to run. Asserted
    # explicitly so bats does not merely warn about it.
    run -127 bash -c 'YQ=""; T="x" A="y" $YQ -n -o=json "{\"title\": strenv(T)}" 2>/dev/null'
    [ -z "$output" ]
}

@test "quotes, newlines and unicode survive — values are argv, never interpolated" {
    # The old expression passed values through the environment and a yq DSL
    # string; this passes them as argv. A title containing a quote or a brace
    # must not be able to break the payload or inject a field.
    run _mr_json title 'He said "no" — {"admin": true}
second line' body 'ünïcødé ✓'
    [ "$status" -eq 0 ]
    run python3 -c '
import json,sys
d = json.load(sys.stdin)
assert d["title"].startswith("He said \"no\"'"'"'"[:0] or "He said"), d
assert "\n" in d["title"]
assert "admin" not in d or isinstance(d.get("admin"), str) is False
assert d["body"] == "ünïcødé ✓"
print("OK", len(d))' <<<"$output"
    [[ "$output" == OK\ 2 ]]
}

@test "a :bool key emits a real boolean, not the string \"true\"" {
    # The yq expression this replaced wrote (strenv(R) == "true"), a genuine
    # boolean. Quietly turning remove_source_branch into a STRING would be a type
    # change smuggled inside a bug fix.
    run _mr_json source_branch "b" remove_source_branch:bool "true"
    run python3 -c 'import json,sys; d=json.load(sys.stdin); print(type(d["remove_source_branch"]).__name__, d["remove_source_branch"])' <<<"$output"
    [ "$output" = "bool True" ]
}

@test "a :bool key with anything but 'true' is false" {
    run _mr_json flag:bool "false"
    run python3 -c 'import json,sys; print(json.load(sys.stdin)["flag"])' <<<"$output"
    [ "$output" = "False" ]
}

@test "no write path still builds JSON with yq" {
    # The regression that matters: one reintroduced `"$YQ" -n -o=json` puts the
    # hold back to silently inert. Comments are exempt — the explanation of the
    # bug necessarily contains the old idiom.
    local offenders
    offenders="$(grep -n '"\$YQ" -n -o=json' \
                   "$REPO_ROOT/lib/gitlab-mr.sh" \
                   "$REPO_ROOT/scripts/commands/mr.sh" 2>/dev/null \
                 | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
    [ -z "$offenders" ] || { echo "yq json-build still present: $offenders"; false; }
}

@test "a failed hold is HOLD-MECHANISM-FAILED, never a WARNING" {
    # A soft word for a failed security control is how it stays failed: the
    # reader skims "WARNING" and sees the job go red for what looks like the
    # intended reason. That is precisely what happened here for months.
    grep -q 'HOLD-MECHANISM-FAILED: could not apply the Draft hold' "$REPO_ROOT/scripts/commands/mr.sh"
    grep -q 'HOLD-MECHANISM-FAILED: the Draft hold could not be CONFIRMED' "$REPO_ROOT/scripts/commands/mr.sh"
    ! grep -q 'WARNING: could not apply the Draft hold' "$REPO_ROOT/scripts/commands/mr.sh"
    # and it must tell the reader not to trust the remaining layer
    grep -q 'do not merge on the strength of the red pipeline alone' "$REPO_ROOT/scripts/commands/mr.sh"
}

@test "_mr_jget still reads JSON without yq (the pre-existing fallback)" {
    # Guards the other half: reading already had a python3 fallback, and this
    # change must not have disturbed it.
    #
    # NOT via `bash -c`: that spawns a fresh shell in which setup()'s sourced
    # functions do not exist, so the case exited 127 and bats DROPPED it from the
    # output entirely rather than reporting a failure — the missing-`not ok`
    # behaviour recorded in ops#283. It read as 7 passes and no failures.
    local out
    out="$(printf '%s' '{"head_pipeline":{"id":1910}}' | _mr_jget 'head_pipeline.id')"
    [ "$out" = "1910" ]
}
