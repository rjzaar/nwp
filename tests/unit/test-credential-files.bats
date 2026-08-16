#!/usr/bin/env bats
#
# ops#374 — a credential may never become a file.
#
# Measured 2026-08-16: 56 files under /tmp (82 by the time the fix landed) each
# held a LIVE glpat- token, written by the estate's own 0600 curl-config pattern
# and orphaned when the writing process was killed before its `rm -f`.
#
# Two kinds of proof here, because either alone would be weak:
#
#   BEHAVIOURAL  kill a real API call mid-flight and assert nothing with the
#                token in it is left behind. These fail against the pre-fix tree
#                — that is the red proof, and it is why the fix is `curl -K -`
#                (config on stdin, no file) rather than a trap: a trap does not
#                run on SIGKILL.
#
#   STATIC       the lint, proven RED against a throwaway repo carrying the exact
#                pre-fix idiom, so a seventh writer cannot be added silently.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    FAKETOKEN='glpat-REDPROOFxxxxxxxxxxxx'
}

# Build a fake `curl` that hangs, so the call is guaranteed to be in flight when
# we kill it. This is the half-hourly job's situation exactly.
_stub_hanging_curl() {
    local bin="$WORK/bin"; mkdir -p "$bin"
    printf '#!/bin/bash\nsleep 30\n' > "$bin/curl"
    chmod +x "$bin/curl"
    printf '%s' "$bin"
}

# Run <snippet> in a subshell with an isolated TMPDIR, kill it mid-call with
# <signal>, then report how many files under that TMPDIR contain the token.
_leaked_after_kill() { # $1 = signal, $2 = bash snippet
    local sig="$1" snippet="$2" bin tmp pid
    bin="$(_stub_hanging_curl)"
    tmp="$WORK/tmp.$sig.$RANDOM"; mkdir -p "$tmp"
    (
        export TMPDIR="$tmp" PATH="$bin:$PATH"
        export NWP_MR_TOKEN="$FAKETOKEN" NWP_GITLAB_HOST='gitlab.invalid'
        cd "$REPO_ROOT" || exit 1
        bash -c "$snippet"
    ) >/dev/null 2>&1 &
    pid=$!
    sleep 2
    kill "-$sig" "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 0.3
    grep -rl "$FAKETOKEN" "$tmp" 2>/dev/null | wc -l
}

@test "ops#374: a SIGTERMed _mr_api leaves no credential on disk" {
    local n
    n="$(_leaked_after_kill TERM '
        source lib/gitlab-mr.sh
        _mr_api GET /projects/1
    ')"
    [ "$n" -eq 0 ]
}

# The one a trap could never have covered. Before the fix this leaked too; a
# SIGKILLed process runs no EXIT/INT/TERM handler, which is the whole reason the
# config had to stop being a file.
@test "ops#374: a SIGKILLed _mr_api leaves no credential on disk" {
    local n
    n="$(_leaked_after_kill KILL '
        source lib/gitlab-mr.sh
        _mr_api GET /projects/1
    ')"
    [ "$n" -eq 0 ]
}

# nwp_http_get holds the widest window in the tree: it SLEEPS between retries,
# so a killer is overwhelmingly likely to land while the config is live.
@test "ops#374: a SIGKILLed nwp_http_get leaves no credential on disk" {
    local n
    n="$(_leaked_after_kill KILL '
        source lib/http.sh
        nwp_http_get "https://gitlab.invalid/api/v4/user" \
            "header = \"PRIVATE-TOKEN: '"$FAKETOKEN"'\""
    ')"
    [ "$n" -eq 0 ]
}

@test "lint:credential-files passes over the tree" {
    run "$REPO_ROOT/scripts/ci/lint-credential-files.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no credential is written to, or read from, a file"* ]]
}

# THE RED PROOF FOR THE GATE ITSELF. Replays the pre-ops#374 idiom verbatim in a
# throwaway repo; if this ever goes green the gate has stopped gating.
@test "lint:credential-files FAILS on the pre-ops#374 idiom (proven red)" {
    local repo="$WORK/badrepo"
    mkdir -p "$repo/scripts/ci"
    cat > "$repo/leaky.sh" <<'BAD'
#!/bin/bash
api() {
  local cfg; cfg=$(mktemp); chmod 600 "$cfg"
  printf 'header = "PRIVATE-TOKEN: %s"\n' "$token" > "$cfg"
  curl -K "$cfg" "https://example.invalid/api/v4/user"
  rm -f "$cfg"
}
BAD
    git -C "$repo" init -q
    git -C "$repo" add -A
    git -C "$repo" -c user.email=t@t -c user.name=t commit -qm fixture

    NWP_CREDFILE_LINT_ROOT="$repo" run "$REPO_ROOT/scripts/ci/lint-credential-files.sh"
    [ "$status" -eq 1 ]
    # Both rules must name it: the write, and the read.
    [[ "$output" == *"R1 leaky.sh"* ]]
    [[ "$output" == *"R2 leaky.sh"* ]]
    [[ "$output" == *"A credential must never become a file."* ]]
}

# Fail-closed: an unreadable corpus is CANNOT VERIFY (exit 2), never a pass.
@test "lint:credential-files is fail-closed on an empty corpus" {
    local empty="$WORK/emptyrepo"
    mkdir -p "$empty"
    git -C "$empty" init -q
    NWP_CREDFILE_LINT_ROOT="$empty" run "$REPO_ROOT/scripts/ci/lint-credential-files.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}
