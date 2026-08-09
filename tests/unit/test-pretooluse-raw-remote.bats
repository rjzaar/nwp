#!/usr/bin/env bats
#
# F4 — the act-time raw-remote-idiom interceptor (ops#319, knowledge-honesty
# Tranche 0). Spec of record: ~/central/nwc-internal/meta-2026-08-09/
# meta-pass2.md §2.4 + meta-pass3.md §3 (the empirical proof that PreToolUse
# hooks fire and BLOCK under --dangerously-skip-permissions on harness
# 2.1.225) + meta-pass4.md residue R7.
#
# WHAT THIS FILE HAS TO PROVE, and why each part is here:
#
#  1. THE FORBIDDEN IDIOMS ARE BLOCKED — with the estate's own incident
#     specimens: the raw ssh+drush one-liner, the 2026-07-28 ops#149
#     scp + `ssh … sudo cp` deploy, the raw `ssh … admin/cli/…` Moodle
#     invocation, and the NWC-LIVE-DEPLOY-RUNBOOK alias trick
#     (`D="sudo -u www-data … drush"; ssh … "$D …"`) that doc-truth's
#     shape (b) exists for. A gate that a shell variable defeats is a
#     vacuous gate.
#
#  2. BENIGN LOOKALIKES PASS — the head-token guard (meta-pass2 §2.4): a
#     grep/echo/heredoc that merely MENTIONS ssh+drush is prose, not an act.
#     The matcher applies only to segments whose executable (head-token)
#     position is ssh/scp/sudo. And `pl`/`./pl` is the SANCTIONED path —
#     pl verbs ssh internally, but the hook only ever sees the top-level
#     Bash command, so a pl invocation must NEVER be blocked.
#
#  3. READ-ONLY RECON PASSES — CLAUDE.md's one standing exception
#     (`ssh host 'tail …'`, `free -h`) matches no mutation pattern; the
#     exception is preserved without a carve-out in the hook.
#
#  4. THE OVERRIDE IS LEDGERED, NEVER SILENT — NWP_RAW_REMOTE_OK=<reason>
#     lets a command through AND appends reason+mode+command to the
#     0600 override ledger. An override that leaves no trace is not an
#     override, it's a hole — so an unwritable ledger REFUSES the override,
#     and an empty reason is no override at all.
#
#  5. FAIL-CLOSED — a malformed envelope is a deny (exit 2), never a quiet
#     allow. "A check may not substitute a literal for a measurement it
#     failed to take."
#
#  6. THE R7 PIN — `--selftest` proves the hook's own pattern source still
#     loads and still classifies the canonical specimens. This suite runs in
#     CI on every MR, so a silently-broken hook (regex file moved, source
#     line dropped) goes red HERE rather than silently disarming at
#     act-time. (The harness-side half of R7 — hooks firing in bypass mode
#     at all — is a property of the Claude Code harness, observed empirically
#     in meta-pass3 §3; permission_mode="bypassPermissions" is pinned in the
#     fixtures below so the envelope contract is at least exercised.)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HOOK="$REPO_ROOT/scripts/hooks/pretooluse-raw-remote.sh"
    LEDGER="$BATS_TEST_TMPDIR/raw-remote-overrides.log"
}

# Build a PreToolUse envelope the way the harness does (meta-pass3 §3:
# tool_name + tool_input.command + permission_mode) and feed it to the hook.
# $1 = command, $2 = permission_mode (default: the agent-loop's bypass mode),
# $3… = extra env VAR=val pairs for the hook process.
run_hook() {
    local cmd="$1" pm="${2:-bypassPermissions}"
    shift; [ $# -gt 0 ] && shift
    jq -n --arg cmd "$cmd" --arg pm "$pm" \
        '{tool_name:"Bash", tool_input:{command:$cmd}, permission_mode:$pm}' \
      | env NWP_RAW_REMOTE_LEDGER="$LEDGER" "$@" "$HOOK"
}

# ---------------------------------------------------------------- blocked ---

@test "F4 blocks the raw ssh+drush one-liner and teaches pl drush" {
    run run_hook "ssh gitlab@97.107.137.88 'sudo -u www-data php /var/www/nwc/vendor/bin/drush cr'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"pl drush"* ]]
    [[ "$output" == *"NWP_RAW_REMOTE_OK"* ]]   # the deny teaches the override too
}

@test "F4 blocks raw ssh admin/cli and teaches pl moodle cli" {
    run run_hook "ssh gitlab@ss.nwpcode.org 'sudo -u www-data php /var/www/ss/admin/cli/purge_caches.php'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"pl moodle cli"* ]]
}

@test "F4 blocks the ops#149 scp + ssh sudo-cp deploy idiom" {
    run run_hook "scp /tmp/depthcontent.tar.gz gitlab@host:/tmp/ && ssh gitlab@host 'sudo cp -r /tmp/depthcontent /var/www/ss/mod/'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"pl moodle plugin deploy"* ]]
}

@test "F4 blocks local sudo -u www-data drush (shape b, direct)" {
    run run_hook "sudo -u www-data /var/www/nwc/vendor/bin/drush updatedb -y"
    [ "$status" -eq 2 ]
    [[ "$output" == *"pl drush"* ]]
}

@test "F4 blocks the alias trick — a shell variable must not defeat the gate" {
    run run_hook 'D="sudo -u www-data /var/www/nwc/vendor/bin/drush --root=/var/www/nwc/web"; ssh gitlab@host "$D updatedb -y"'
    [ "$status" -eq 2 ]
}

@test "F4 blocks the forbidden segment inside a benign compound" {
    run run_hook "cd /tmp && ssh host drush cr"
    [ "$status" -eq 2 ]
}

# ------------------------------------------------------ benign lookalikes ---

@test "grep that mentions ssh+drush is prose, not an act — passes" {
    run run_hook 'grep -rn "ssh.*drush" docs/ scripts/'
    [ "$status" -eq 0 ]
}

@test "heredoc body containing the forbidden idiom passes" {
    run run_hook $'cat > /tmp/runbook.md <<EOF\nssh host drush cr\nssh host sudo cp /tmp/x /var/www/x\nsudo -u www-data php admin/cli/upgrade.php\nEOF'
    [ "$status" -eq 0 ]
}

@test "echo quoting the idiom passes (quoted semicolon does not split)" {
    run run_hook 'echo "never do: ssh host drush cr; ssh host sudo cp a b"'
    [ "$status" -eq 0 ]
}

@test "./pl is the sanctioned path and is NEVER blocked" {
    run run_hook "./pl drush nwc --tier=live --execute -- cr"
    [ "$status" -eq 0 ]
    run run_hook "pl moodle cli ss --tier=live --execute -- admin/cli/purge_caches.php"
    [ "$status" -eq 0 ]
}

@test "read-only recon (CLAUDE.md's standing exception) passes" {
    run run_hook "ssh host 'tail -n 200 /var/log/nginx/error.log'"
    [ "$status" -eq 0 ]
    run run_hook "ssh host 'free -h; uptime'"
    [ "$status" -eq 0 ]
}

@test "non-Bash tools are ignored" {
    run bash -c "jq -n '{tool_name:\"Read\", tool_input:{file_path:\"/etc/passwd\"}, permission_mode:\"bypassPermissions\"}' | env NWP_RAW_REMOTE_LEDGER='$LEDGER' '$HOOK'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- override ---

@test "override via hook env allows AND ledgers reason+mode+command, 0600" {
    run run_hook "ssh host drush cr" bypassPermissions NWP_RAW_REMOTE_OK="ops#319 fixture: verb broken, fixing next"
    [ "$status" -eq 0 ]
    [ -f "$LEDGER" ]
    grep -q "ops#319 fixture: verb broken, fixing next" "$LEDGER"
    grep -q "ssh host drush cr" "$LEDGER"
    grep -q "bypassPermissions" "$LEDGER"
    [ "$(stat -c %a "$LEDGER")" = "600" ]
}

@test "override via command-string prefix allows AND ledgers" {
    run run_hook "NWP_RAW_REMOTE_OK='prefix-form reason' ssh host drush cr"
    [ "$status" -eq 0 ]
    grep -q "prefix-form reason" "$LEDGER"
}

@test "an EMPTY override reason is no override" {
    run run_hook "ssh host drush cr" bypassPermissions NWP_RAW_REMOTE_OK=""
    [ "$status" -eq 2 ]
}

@test "benign command with override env set is NOT ledgered (no spam)" {
    run run_hook "ls -la" bypassPermissions NWP_RAW_REMOTE_OK="exported in session"
    [ "$status" -eq 0 ]
    [ ! -s "$LEDGER" ]
}

@test "an unledgerable override is REFUSED — no trace, no pass" {
    run bash -c "jq -n '{tool_name:\"Bash\", tool_input:{command:\"ssh host drush cr\"}, permission_mode:\"default\"}' | env NWP_RAW_REMOTE_LEDGER=/dev/null/nope NWP_RAW_REMOTE_OK=why '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"ledger"* ]]
}

# -------------------------------------------------------------- fail-closed ---

@test "a malformed envelope is a deny, never a quiet allow" {
    run bash -c "echo 'not json at all' | env NWP_RAW_REMOTE_LEDGER='$LEDGER' '$HOOK'"
    [ "$status" -eq 2 ]
}

# ------------------------------------------------------------------ R7 pin ---

@test "--selftest proves the pattern source loads and classifies (R7 pin)" {
    run "$HOOK" --selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"selftest"* ]]
    [[ "$output" == *"OK"* ]]
}

@test "one source of truth: doc-truth and the hook read the SAME pattern file" {
    grep -q 'raw-remote-patterns.sh' "$REPO_ROOT/scripts/commands/doc-truth.sh"
    grep -q 'raw-remote-patterns.sh' "$HOOK"
    # and the regex is not forked back inline into doc-truth
    ! grep -qE "grep -nE 'ssh\[" "$REPO_ROOT/scripts/commands/doc-truth.sh"
}
