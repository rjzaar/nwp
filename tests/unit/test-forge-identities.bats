#!/usr/bin/env bats
#
# tests/unit/test-forge-identities.bats — the forge-box identity scheme
# (ops#331, ADR-0038).
#
# THE DEFECT THIS GUARDS. Until ops#331 the forge box had exactly ONE login
# credential: a single unrestricted key in ~gitlab/.ssh/authorized_keys, titled
# "NWP Backup Key" on GitLab, which was in fact the dev workstation's
# ~/.ssh/gitlab_linode — and `gitlab` on that box carries
# `(ALL) NOPASSWD: ALL`. One key, one name that described neither its holder nor
# its power, and no lesser credential for the ninety percent of work that only
# reads. ADR-0038 splits that into a named full-control identity and a jailed
# read-only probe. THIS FILE IS THE PROOF THAT THE JAIL IS A JAIL.
#
# WHY THE JAIL TESTS RUN THE WRAPPER LOCALLY, NOT OVER SSH. A test that needs
# the private key and the live box would skip in CI, and bats scores a skip as
# `ok` — a jail whose test cannot fail is the ops#214 class this repo exists to
# stamp out. The wrapper is a program; its refusal logic is decided entirely by
# $SSH_ORIGINAL_COMMAND, which the test sets directly. So every refusal below is
# exercised for real, on every host, with no network and no credential.
#   The over-the-wire half — that sshd actually applies the forced command to
# that key — is proven live by `pl forge doctor --live` and was run against the
# real box before this landed; the counts are in the MR description. The two
# halves answer different questions and neither substitutes for the other.
#
# RED PROOF. Every test in this file was RED before the wrapper existed: the
# file `servers/nwpcode/forge/forge-probe-restricted` was absent, so each
# `run bash "$WRAPPER"` returned 127. Quoted in the MR description.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export REPO_ROOT
  WRAPPER="${REPO_ROOT}/servers/nwpcode/forge/forge-probe-restricted"
  INSTALLER="${REPO_ROOT}/servers/nwpcode/forge/install-forge-identities.sh"
  export WRAPPER INSTALLER
  # The wrapper logs to /var/log/nwp-forge on the box; here it must degrade
  # silently rather than fail, which is what log()'s fail-soft return covers.
}

# Run the wrapper exactly as sshd would: the client's string in
# $SSH_ORIGINAL_COMMAND, nothing on argv.
_as_client() {
  SSH_ORIGINAL_COMMAND="$1" SSH_CLIENT="203.0.113.9 5000 22" run bash "$WRAPPER"
}

################################################################################
# [G1] the allowlist — refusals
################################################################################

@test "forge-probe: a shell command is REFUSED and never executed" {
  _as_client 'id'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  # The decisive assertion: `id` did not run. Asserting only on the exit code
  # would be the blind-negation shape — exit 2 could mean anything.
  [[ "$output" != *"uid="* ]]
}

@test "forge-probe: sudo is REFUSED" {
  _as_client 'sudo -n id'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" != *"uid=0"* ]]
}

@test "forge-probe: an unknown action word is REFUSED and names the allowlist" {
  _as_client 'restart-gitlab'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"logs-nginx"* ]]   # the refusal tells the caller what IS allowed
}

@test "forge-probe: command chaining onto a VALID word is REFUSED whole" {
  # The dangerous near-miss: a prefix that is a real action word. If the arm
  # were a glob or the string were ever re-split, this would run `id`.
  _as_client 'status; id'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" != *"uid="* ]]
  _as_client 'health && whoami'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "forge-probe: an ARGUMENT to a valid word is REFUSED (no client-chosen tail/path)" {
  # [G4]: the log tail is a constant. A caller must not be able to ask for
  # 500000 lines, and must not be able to name a file.
  _as_client 'logs-nginx 500000'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  _as_client 'logs-auth /etc/shadow'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "forge-probe: path escape is REFUSED" {
  _as_client 'cat ../../etc/shadow'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" != *"root:"* ]]
}

@test "forge-probe: scp/sftp/rsync subsystems are REFUSED" {
  # A forced command intercepts these too; prove it, because "I'll just scp the
  # file up" is the exact idiom the pl-first standing order exists to stop.
  local c
  for c in 'scp -t /tmp/x' 'rsync --server -vlogDtpre.iLsfxCIvu . /tmp/' 'internal-sftp'; do
    _as_client "$c"
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
  done
}

@test "forge-probe: gitlab-rails and gitlab-rake are unreachable (the OOM guard)" {
  # [G5] — 2026-07-25: a heavy op OOM-killed this 3.9 GB box for 5-8 minutes.
  _as_client 'gitlab-rails runner "puts 1"'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  _as_client 'gitlab-rake gitlab:backup:create'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  # …and no action word can reach them either. The assertion is on COMMAND
  # POSITION, not on the string: `/var/log/gitlab/gitlab-rails/production.log`
  # is a path this wrapper legitimately tails, and a test that banned the
  # substring would have to be silenced rather than fixed the first time
  # somebody read that log. So: every occurrence must be a comment, a path
  # component, or help text — anything else is the token starting a command.
  [ -s "$WRAPPER" ]
  local hits benign
  hits="$(grep -nE 'gitlab-(rails|rake)' "$WRAPPER" | wc -l)"
  [ "$hits" -gt 0 ]                                  # the guard has something to guard
  benign="$(grep -nE 'gitlab-(rails|rake)' "$WRAPPER" \
            | grep -cE '^[0-9]+: *#|/gitlab-(rails|rake)/|lines of gitlab-rails' || true)"
  [ "$hits" -eq "$benign" ]
}

################################################################################
# [G1]/[G2] structural — the properties that make the refusals trustworthy
################################################################################

@test "forge-probe: no eval, no sh -c, no client string in a command position" {
  # A single `eval "$SSH_ORIGINAL_COMMAND"` would undo every test above, so the
  # absence is asserted rather than assumed.
  [ -s "$WRAPPER" ]
  # Comment lines are excluded deliberately: the header PROMISES "No eval, no
  # `sh -c`", and a test that read its own documentation as a violation would
  # be a test that punishes writing the guarantee down.
  local bad_exec
  bad_exec="$(grep -nE '(^|[^[:alnum:]_])(eval|sh -c|bash -c)([^[:alnum:]_]|$)' "$WRAPPER" \
              | grep -vE '^[0-9]+: *#' || true)"
  [ -z "$bad_exec" ]
  # $RAW_CMD may be COMPARED and LOGGED, never expanded into a command. Every
  # legitimate use is inside `case "$RAW_CMD" in`, `scrub "$RAW_CMD"` or an
  # assignment; anything else is a finding.
  local bad; bad="$(grep -nE '\$(RAW_CMD|SSH_ORIGINAL_COMMAND)' "$WRAPPER" \
      | grep -vE 'case "|scrub "|RAW_CMD=' | grep -vE '^[0-9]+: *#' || true)"
  [ -z "$bad" ]
}

@test "forge-probe: every case arm is a literal — no glob, no regex" {
  # `status*)` or `*rails*)` would silently widen the allowlist.
  local arms
  arms="$(sed -n '/^resolve_action()/,/^}/p' "$WRAPPER" | grep -E '^\s+[^ ].*\)\s+echo' | grep -vE '^\s+\*\)')"
  [ -n "$arms" ]
  # the only permitted metacharacters are `|` (alternation between literals)
  # and the empty-string arm `""`.
  run bash -c "printf '%s\n' '$arms' | grep -E '[*?\[]'"
  [ "$status" -ne 0 ]
}

@test "forge-probe: bash -n clean and the allowlist matches the help text" {
  run bash -n "$WRAPPER"
  [ "$status" -eq 0 ]
  # A help text that drifts from the allowlist teaches callers a word that is
  # refused, or hides one that works.
  local w
  for w in status health services certs backups forge-version disk keys \
           logs-nginx logs-gitlab logs-auth; do
    run grep -q "  ${w} " "$WRAPPER"
    [ "$status" -eq 0 ]
  done
}

################################################################################
# in-scope actions actually work (the other half of a jail: it must let the
# legitimate work through)
################################################################################

@test "forge-probe: health reads real headroom figures and exits 0" {
  _as_client 'health'
  [ "$status" -eq 0 ]
  [[ "$output" == *"mem "* ]]
  [[ "$output" == *"MB available of"* ]]
  [[ "$output" == *"load "* ]]
  # a measurement, not a literal: the number must be a number
  run bash -c "printf '%s' '$output' | grep -qE 'mem +[0-9]+ MB available of [0-9]+ MB'"
  [ "$status" -eq 0 ]
}

@test "forge-probe: the empty command means status, not a login shell" {
  # [G3]. `ssh -i <key> gitlab@box` with no command sends "".
  _as_client ''
  [ "$status" -eq 0 ]
  [[ "$output" == *"forge-probe (READ-ONLY)"* ]]
  [[ "$output" != *"uid="* ]]
}

@test "forge-probe: disk and help work" {
  _as_client 'disk'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Filesystem"* ]]
  _as_client 'help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"READ-ONLY"* ]]
}

@test "forge-probe: an unmeasurable figure is CANNOT-VERIFY exit 2, never a clean 0" {
  # [G7]. Off the box there is no /etc/letsencrypt, so `certs` cannot measure.
  # The rule under test is the estate rule: fail closed, never substitute a
  # literal for a measurement you failed to take.
  # NOT skipped where letsencrypt happens to exist — a skip scores as `ok`
  # without running, so the case would silently stop testing on exactly the
  # hosts that matter. Point the wrapper at a directory that cannot exist and
  # the cannot-measure branch is exercised on EVERY host (CLAUDE.md H4).
  NWP_FORGE_LE_LIVE="${TEST_TMP}/no-such-letsencrypt" _as_client 'certs'
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

################################################################################
# the installer's safety property
################################################################################

@test "install-forge-identities: dry-run is the default and it is bash -n clean" {
  run bash -n "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -q 'execute=false' "$INSTALLER"
  [ "$status" -eq 0 ]
}

@test "install-forge-identities: it REFUSES if a pre-existing key would change" {
  # The workstation's own gitlab_linode entry lives in that file. An installer
  # that could drop it is an installer that can lock everyone out of the box.
  run grep -q 'REFUSING: pre-existing authorized_keys entries would change' "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -q 'cp -a authorized_keys authorized_keys.bak-' "$INSTALLER"
  [ "$status" -eq 0 ]
}

@test "install-forge-identities: the probe entry carries every restriction" {
  local r
  for r in 'command=' no-agent-forwarding no-port-forwarding no-pty no-user-rc no-X11-forwarding; do
    run grep -q -- "$r" "$INSTALLER"
    [ "$status" -eq 0 ]
  done
}

@test "install-forge-identities: it never generates or transmits a private key" {
  # A grep-for-ABSENCE passes vacuously against a missing file — that is the
  # blind-negation shape, and this very test was the one green line in the
  # 18/19 red run before the installer existed. Assert the subject is there
  # first, so "no match" can only mean "no match".
  [ -s "$INSTALLER" ]
  run grep -nE '^[^#]*ssh-keygen -t' "$INSTALLER"
  [ "$status" -ne 0 ]
  # …and the positive half: the only key files it opens are public halves.
  run grep -q 'awk .{print \$1" "\$2}. "\$pub"' "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -q '\${OPS_KEY}.pub' "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -q '\${PROBE_KEY}.pub' "$INSTALLER"
  [ "$status" -eq 0 ]
}
