#!/usr/bin/env bats
#
# tests/unit/test-host.bats — fix-programme item 6 (`pl-host`).
#
# THE DEFECT THIS GUARDS: no `pl` verb owned any host state. `pl server status`
# reported SSH reachability only — no RAM, no disk, no load — which is exactly
# the guard whose absence let a heavy op OOM-kill the 3.8 GB git box for 5-8 min
# on 2026-07-25. `lib/safe-ops.sh`, which CLAUDE.md instructs agents to source,
# had ZERO callers and printed the names of root scripts that do not exist, so
# dead code the standing orders pointed at read as coverage. And `.gitignore`
# blanket-ignored `servers/*`, so captured host state could only ever be
# versioned by someone remembering `git add -f`.
#
# Every test below was RED on origin/main before item 6. See the MR description
# for the captured failure output — a test never seen failing is not evidence.
#
# All remote interaction is stubbed with a fake `ssh` earlier in PATH, so these
# tests exercise the real argument construction and the real parse path; there
# is no production-code test hook to go stale.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export REPO_ROOT
  PL="${REPO_ROOT}/pl"
  export PL
  TMP="${BATS_TEST_TMPDIR}"
  export STUBBIN="${TMP}/stubbin"
  mkdir -p "$STUBBIN"
}

# Write an `ssh` stub that echoes a canned payload for any remote command and
# records the argv it was called with. $1 = payload file, $2 = exit code.
_stub_ssh() {
  local payload="$1" rc="${2:-0}"
  cat > "${STUBBIN}/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TMP}/ssh.argv"
cat "${payload}"
exit ${rc}
EOF
  chmod +x "${STUBBIN}/ssh"
}

# A fixture instance-manifest binding a role to a stub host.
_fixture_manifest() {
  cat > "${TMP}/manifest.yml" <<'EOF'
roles:
  ci-host:
    - stubhost
  gitlab-host:
    - stubforge
ssh_targets:
  stubhost:
    dest: tester@203.0.113.9
  stubforge:
    dest: tester@203.0.113.10
EOF
  export NWP_INSTANCE_MANIFEST="${TMP}/manifest.yml"
}

################################################################################
# (a) pl host capture / diff — drift must be detectable, and blindness must
#     NOT read as clean.
################################################################################

@test "lib/host-capture.sh exists (the capture engine is code, not a runbook)" {
  [ -f "${REPO_ROOT}/lib/host-capture.sh" ]
}

@test "pl host capture is a real subcommand and lists its kinds" {
  run "$PL" host capture --help
  [ "$status" -eq 0 ]
  for kind in cron systemd nginx php ssh firewall; do
    [[ "$output" == *"$kind"* ]]
  done
}

@test "pl host <role> still resolves a role to a hostname (no regression)" {
  _fixture_manifest
  run "$PL" host ci-host
  [ "$status" -eq 0 ]
  [[ "$output" == *"stubhost"* ]]
}

@test "pl host diff exits NON-ZERO when a captured file drifted from the host" {
  _fixture_manifest
  local tree="${TMP}/servers/stubhost/system/cron"
  mkdir -p "$tree"
  # Committed capture says the cron runs at 01:30 ...
  printf '30 1 * * * root /usr/local/bin/nwp-box-backup.sh\n' > "${tree}/crontab.root"
  # ... the host says something else.
  printf '45 2 * * * root /usr/local/bin/nwp-box-backup.sh\n' > "${TMP}/live-cron"
  _stub_ssh "${TMP}/live-cron" 0

  PATH="${STUBBIN}:$PATH" NWP_SERVERS_DIR="${TMP}/servers" \
    run "$PL" host diff ci-host --kind=cron
  [ "$status" -ne 0 ]
  [[ "$output" == *"DRIFT"* ]]
}

@test "pl host diff exits ZERO when the capture matches the host" {
  _fixture_manifest
  local tree="${TMP}/servers/stubhost/system/cron"
  mkdir -p "$tree"
  printf '30 1 * * * root /usr/local/bin/nwp-box-backup.sh\n' > "${tree}/crontab.root"
  cp "${tree}/crontab.root" "${TMP}/live-cron"
  _stub_ssh "${TMP}/live-cron" 0

  PATH="${STUBBIN}:$PATH" NWP_SERVERS_DIR="${TMP}/servers" \
    run "$PL" host diff ci-host --kind=cron
  [ "$status" -eq 0 ]
}

@test "VACUOUS-PASS GUARD: pl host diff fails CLOSED when the host is unreachable" {
  # An unreachable host must NOT read as "no drift". This is the shape of the
  # bug that let a nightly sweep report OK for 15 nights over a dead transport.
  _fixture_manifest
  mkdir -p "${TMP}/servers/stubhost/system/cron"
  : > "${TMP}/servers/stubhost/system/cron/crontab.root"
  : > "${TMP}/empty"
  _stub_ssh "${TMP}/empty" 255      # ssh transport failure

  PATH="${STUBBIN}:$PATH" NWP_SERVERS_DIR="${TMP}/servers" \
    run "$PL" host diff ci-host --kind=cron
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNREACHABLE"* || "$output" == *"CAPTURE-INCOMPLETE"* ]]
}

@test "pl host apply is DRY-RUN by default and writes nothing without --execute" {
  _fixture_manifest
  mkdir -p "${TMP}/servers/stubhost/system/cron"
  printf '30 1 * * * root /bin/true\n' > "${TMP}/servers/stubhost/system/cron/crontab.root"
  printf '45 2 * * * root /bin/true\n' > "${TMP}/live-cron"
  _stub_ssh "${TMP}/live-cron" 0

  PATH="${STUBBIN}:$PATH" NWP_SERVERS_DIR="${TMP}/servers" \
    run "$PL" host apply ci-host --kind=cron
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* || "$output" == *"dry-run"* ]]
  # No WRITE command was ever sent to the host. (`crontab -l` is a read and is
  # expected in the argv — the probe uses it; the assertion is on writers.)
  run grep -cE 'tee /etc|crontab /|> /etc/|install -m' "${TMP}/ssh.argv"
  [ "$output" = "0" ]
}

@test "pl host capture renders a REAL fate manifest before replacing a capture" {
  # Replacing a captured tree is a destructive local write. The manifest must
  # name the actual files at stake — a contract satisfied by the mere presence
  # of the words is the presence-grep failure this programme keeps finding.
  _fixture_manifest
  local tree="${TMP}/servers/stubhost/system/cron"
  mkdir -p "$tree"
  printf 'old\n'  > "${tree}/crontab.root"
  printf 'stale\n' > "${tree}/gone-from-host.txt"
  printf 'new\n'  > "${TMP}/live-cron"
  _stub_ssh "${TMP}/live-cron" 0

  PATH="${STUBBIN}:$PATH" NWP_SERVERS_DIR="${TMP}/servers" \
    run "$PL" host capture ci-host --kind=cron --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"WILL BE OVERWRITTEN"* ]]
  [[ "$output" == *"crontab.root"* ]]
  # A file the host no longer has is a DELETE, and must be named as one.
  [[ "$output" == *"WILL BE PERMANENTLY DELETED"* ]]
  [[ "$output" == *"gone-from-host.txt"* ]]
  # And the capture actually happened.
  run cat "${tree}/crontab.root"
  [ "$output" = "new" ]
}

@test "pl host capture ABORTS without --yes when there is no terminal to confirm on" {
  # impact_confirm fails closed with no TTY and no -y. A capture must not
  # silently overwrite a previous one from a cron.
  _fixture_manifest
  local tree="${TMP}/servers/stubhost/system/cron"
  mkdir -p "$tree"
  printf 'old\n' > "${tree}/crontab.root"
  printf 'new\n' > "${TMP}/live-cron"
  _stub_ssh "${TMP}/live-cron" 0

  PATH="${STUBBIN}:$PATH" NWP_SERVERS_DIR="${TMP}/servers" \
    run "$PL" host capture ci-host --kind=cron < /dev/null
  [ "$status" -ne 0 ]
  run cat "${tree}/crontab.root"
  [ "$output" = "old" ]        # untouched
}

@test "captured host state is scrubbed — private key material never lands in the repo" {
  source "${REPO_ROOT}/lib/host-capture.sh"
  run bash -c 'source "'"${REPO_ROOT}"'/lib/host-capture.sh"; printf "%s\n" \
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexampleexampleexampleexample tester@dev" \
    | host_scrub_authorized_keys'
  [ "$status" -eq 0 ]
  # The key blob itself must be gone; the options/comment survive.
  [[ "$output" != *"AAAAC3NzaC1lZDI1NTE5"* ]]
  [[ "$output" == *"ssh-ed25519"* ]]
}

################################################################################
# (b) pl server health — the OOM guard that did not exist on 2026-07-25.
################################################################################

@test "pl server health is a real subcommand" {
  run "$PL" server help
  [ "$status" -eq 0 ]
  [[ "$output" == *"health"* ]]
}

@test "pl server health EXITS NON-ZERO on a host with no memory headroom" {
  cat > "${TMP}/health-bad" <<'EOF'
NWPHEALTH v1
mem_total_mb=3800
mem_avail_mb=200
swap_total_mb=0
swap_free_mb=0
disk_avail_mb=40000
disk_pct=42
load1=0.30
nproc=2
EOF
  _stub_ssh "${TMP}/health-bad" 0
  PATH="${STUBBIN}:$PATH" run "$PL" server health --probe-cmd="ssh stub" --raw
  [ "$status" -ne 0 ]
  [[ "$output" == *"200"* ]]
}

@test "pl server health EXITS ZERO on a host with headroom" {
  cat > "${TMP}/health-ok" <<'EOF'
NWPHEALTH v1
mem_total_mb=32000
mem_avail_mb=20000
swap_total_mb=2048
swap_free_mb=2048
disk_avail_mb=400000
disk_pct=18
load1=0.40
nproc=8
EOF
  _stub_ssh "${TMP}/health-ok" 0
  PATH="${STUBBIN}:$PATH" run "$PL" server health --probe-cmd="ssh stub" --raw
  [ "$status" -eq 0 ]
}

@test "a guarded verb REFUSES to run heavy work below the headroom threshold" {
  cat > "${TMP}/health-bad" <<'EOF'
NWPHEALTH v1
mem_total_mb=3800
mem_avail_mb=150
swap_total_mb=0
swap_free_mb=0
disk_avail_mb=40000
disk_pct=42
load1=6.00
nproc=2
EOF
  _stub_ssh "${TMP}/health-bad" 0
  run bash -c 'PATH="'"${STUBBIN}"':$PATH"; source "'"${REPO_ROOT}"'/lib/host-capture.sh"; \
      host_health_require "ssh stub" 512 "heavy import"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"refus"* || "$output" == *"REFUS"* || "$output" == *"headroom"* ]]
}

@test "VACUOUS-PASS GUARD: health probe failure is NOT treated as healthy" {
  : > "${TMP}/empty"
  _stub_ssh "${TMP}/empty" 255
  PATH="${STUBBIN}:$PATH" run "$PL" server health --probe-cmd="ssh stub" --raw
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNKNOWN"* || "$output" == *"UNREACHABLE"* ]]
}

@test "the health probe is CHEAP — it never invokes gitlab-rails or a heavy op" {
  # The 3.8 GB forge box was OOM-killed by exactly this class of mistake.
  # Comment lines are stripped: the doc-comments name these commands only to
  # warn against them (same convention as test-nginx-versioning.bats).
  #
  # The forbidden thing is INVOKING `gitlab-rails`/`gitlab-rake`, not naming a
  # PATH that contains the string. A bare substring match called
  # `/var/opt/gitlab/gitlab-rails/etc/puma.rb` — a 4 KB config file read, the
  # cheapest possible measurement — a heavy op, and the tempting repair for a
  # false positive on a guard is to delete the guard. So the pattern requires
  # the token to stand as a COMMAND WORD: not preceded by `/` (a path
  # component) and followed by whitespace (its arguments).
  run bash -c "grep -vE '^[[:space:]]*#' '${REPO_ROOT}/lib/host-capture.sh' \
               | grep -nE '(^|[^/[:alnum:]_-])(gitlab-rails|gitlab-rake)[[:space:]]|composer install|drush sql'"
  [ "$status" -ne 0 ]
}

@test "RED-PROOF: that CHEAP assertion still catches a real gitlab-rails invocation" {
  # A check never proven to fail is not a check. Same pattern, over a file that
  # really does invoke the forbidden command.
  cat > "${TMP}/heavy.sh" <<'EOF'
#!/bin/bash
# this comment mentions gitlab-rails and must NOT trip the check
pr=/var/opt/gitlab/gitlab-rails/etc/puma.rb      # a path must NOT trip it either
sudo -n gitlab-rails runner 'puts User.count'    # THIS must trip it
EOF
  run bash -c "grep -vE '^[[:space:]]*#' '${TMP}/heavy.sh' \
               | grep -nE '(^|[^/[:alnum:]_-])(gitlab-rails|gitlab-rake)[[:space:]]|composer install|drush sql'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"runner"* ]]
  [[ "$output" != *"puma.rb"* ]]     # the path alone is not a finding
}

################################################################################
# (c) pl loop --host — the dashboard must name the machine it interrogated.
################################################################################

@test "pl loop --host reports the REMOTE sentinel and NAMES the host" {
  _fixture_manifest
  cat > "${TMP}/loop-remote" <<'EOF'
NWPLOOP v1
root=/home/tester/nwp
kill=present
kill_mtime=1753400000
rag_pause=absent
log_mtime=1753400000
cron=present
EOF
  _stub_ssh "${TMP}/loop-remote" 0
  PATH="${STUBBIN}:$PATH" run "$PL" loop --host ci-host
  [ "$status" -eq 0 ]
  [[ "$output" == *"stubhost"* ]]       # names the machine it asked
  [[ "$output" == *"PAUSED"* || "$output" == *"paused"* ]]
}

@test "pl loop enable REFUSES to write when the target is not this machine" {
  _fixture_manifest
  run "$PL" loop --host ci-host enable all
  [ "$status" -ne 0 ]
  [[ "$output" == *"stubhost"* ]]
}

################################################################################
# (d) servers/ must be versionable — .gitignore:149 `servers/*` made captured
#     host state invisible unless someone remembered `git add -f`.
################################################################################

@test "no path under servers/*/{nginx,demo,linode,backup,email,system} is git-ignored" {
  cd "$REPO_ROOT"
  local bad=()
  for sub in nginx demo linode backup email system; do
    for probe in "servers/nwpcode/${sub}/PROBE.conf" "servers/nwpcode/${sub}/nested/PROBE.sh"; do
      if git check-ignore -q "$probe" 2>/dev/null; then bad+=("$probe"); fi
    done
  done
  printf 'ignored: %s\n' "${bad[@]:-none}"
  [ "${#bad[@]}" -eq 0 ]
}

@test "the server IDENTITY file and secrets stay ignored (allowlist must not over-open)" {
  cd "$REPO_ROOT"
  git check-ignore -q "servers/nwpcode/.nwp-server.yml"
  git check-ignore -q "servers/nwpcode/.secrets.yml"
  git check-ignore -q "servers/nwpcode/system/ssh/id_ed25519"
}

@test "pl doctor reports drift when servers/ has uncommitted captured state" {
  source "${REPO_ROOT}/lib/host-capture.sh"
  run host_check_servers_tracked "$REPO_ROOT"
  # Must be a real function that can answer; not a stub that always says yes.
  [ "$status" -eq 0 ] || [[ "$output" == *"servers/"* ]]
}

################################################################################
# (e) two overlapping repos over one path — servers/<h>/.git with no remote is
#     a guaranteed divergent second copy of load-bearing scripts.
################################################################################

@test "host_check_server_repos FLAGS an inner repo with no remote" {
  local root="${TMP}/root"
  mkdir -p "${root}/servers/lonely"
  git -C "${root}/servers/lonely" init -q
  git -C "${root}/servers/lonely" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
  source "${REPO_ROOT}/lib/host-capture.sh"
  run host_check_server_repos "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lonely"* ]]
  [[ "$output" == *"remote"* ]]
}

@test "host_check_server_repos FLAGS an inner repo with unpushed commits" {
  local root="${TMP}/root2" bare="${TMP}/bare.git"
  mkdir -p "${root}/servers/drifty"
  git init -q --bare "$bare"
  git -C "${root}/servers/drifty" init -q
  git -C "${root}/servers/drifty" remote add origin "$bare"
  git -C "${root}/servers/drifty" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unpushed
  source "${REPO_ROOT}/lib/host-capture.sh"
  run host_check_server_repos "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"drifty"* ]]
}

@test "host_check_server_repos PASSES a clean inner repo (test can go green too)" {
  local root="${TMP}/root3" bare="${TMP}/bare3.git"
  mkdir -p "${root}/servers/tidy"
  git init -q --bare "$bare"
  git -C "${root}/servers/tidy" init -q
  git -C "${root}/servers/tidy" remote add origin "$bare"
  git -C "${root}/servers/tidy" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
  git -C "${root}/servers/tidy" push -q origin HEAD:refs/heads/main
  git -C "${root}/servers/tidy" branch -q --set-upstream-to=origin/main 2>/dev/null || true
  source "${REPO_ROOT}/lib/host-capture.sh"
  run host_check_server_repos "$root"
  [ "$status" -eq 0 ]
}

################################################################################
# pl logs — read-only by construction. Every incident used to start with an
# unsanctioned ssh into the box you are least supposed to poke.
################################################################################

@test "pl logs exists and only offers a FIXED source set" {
  run "$PL" logs --help
  [ "$status" -eq 0 ]
  for src in nginx php-fpm auth systemd; do
    [[ "$output" == *"$src"* ]]
  done
}

@test "pl logs REFUSES an unknown source rather than passing it to the shell" {
  _fixture_manifest
  run "$PL" logs ci-host --source='nginx; rm -rf /tmp/pwned'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown source"* || "$output" == *"Unknown source"* ]]
}

@test "pl logs is resource-bounded — --tail is clamped, never unbounded" {
  _fixture_manifest
  : > "${TMP}/empty"
  _stub_ssh "${TMP}/empty" 0
  PATH="${STUBBIN}:$PATH" run "$PL" logs ci-host --source=nginx --tail=999999
  [ "$status" -eq 0 ]
  run grep -qE 'tail -n (5000|[0-9]{1,4})\b' "${TMP}/ssh.argv"
  [ "$status" -eq 0 ]
}

################################################################################
# pl logs --source=mail (ops#271) — "did the confirmation email actually leave?"
# had NO verb at all, so it was answered by raw ssh. The answer mattered: zero
# mail had ever been sent from nwd@/ssd@/nwc@/ss@, i.e. the /apply email leg was
# wired and had never once run. Silence from a mail log must therefore never be
# allowed to read as "no mail was sent" — that is the exact shape of the recon
# gotcha: `sudo -n wc -l < /var/log/mail.log` expands the redirect in the CALLING
# shell, so it reports "Permission denied" while looking like a count of zero.
################################################################################

@test "pl logs offers a mail source (outbound mail must be readable via a verb)" {
  run "$PL" logs --sources
  [ "$status" -eq 0 ]
  [[ "$output" == *"mail"* ]]
  run "$PL" logs --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"mail"* ]]
}

@test "pl logs --source=mail reads mail.log AND mail.err" {
  source "${REPO_ROOT}/lib/host-capture.sh"
  run host_log_source_cmd mail 200
  [ "$status" -eq 0 ]
  [[ "$output" == *"/var/log/mail.log"* ]]
  [[ "$output" == *"/var/log/mail.err"* ]]
}

@test "pl logs --source=mail never reads a log through a shell REDIRECT (ops#271 gotcha)" {
  source "${REPO_ROOT}/lib/host-capture.sh"
  run host_log_source_cmd mail 200
  [ "$status" -eq 0 ]
  # `sudo -n cmd < /var/log/mail.log` runs the redirect as the UNPRIVILEGED
  # caller: permission-denied that looks like an empty log. Paths are arguments.
  [[ "$output" != *"< /var/log/mail"* ]]
  [[ "$output" != *'<"$f"'* ]]
  [[ "$output" != *'< "$f"'* ]]
}

@test "pl logs --source=mail is clamped like every other source" {
  source "${REPO_ROOT}/lib/host-capture.sh"
  run host_log_source_cmd mail 999999
  [ "$status" -eq 0 ]
  [[ "$output" == *"5000"* ]]
  [[ "$output" != *"999999"* ]]
}

@test "an ABSENT mail log is reported, never rendered as 'no mail was sent'" {
  source "${REPO_ROOT}/lib/host-capture.sh"
  local script
  script="$(host_log_source_cmd mail 200)"
  # Point the generated script at an empty fixture dir: no mail log exists.
  mkdir -p "${TMP}/varlog"
  script="${script//\/var\/log\/mail/${TMP}/varlog/mail}"
  run bash -c "$script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NWPLOG-ABSENT"* ]]
}

@test "an UNREADABLE mail log is reported, never rendered as 'no mail was sent'" {
  # Root satisfies `[ -r ]` on any file, so as root this branch cannot fire.
  # That is CANNOT VERIFY, and it is REFUSED rather than skipped: bats scores a
  # skip as `ok`, which is the exact dishonesty H3 exists to stop. CI and dev
  # both run unprivileged, so this never fires here — and where it would, a red
  # "I could not check" beats a green "checked".
  if [ "$(id -u)" -eq 0 ]; then
    echo "REFUSING: run this suite unprivileged — as root the unreadable-log branch cannot be exercised" >&2
    return 1
  fi
  source "${REPO_ROOT}/lib/host-capture.sh"
  local script
  script="$(host_log_source_cmd mail 200)"
  mkdir -p "${TMP}/varlog"
  printf 'to=<x@example.org>, status=sent\n' > "${TMP}/varlog/mail.log"
  chmod 000 "${TMP}/varlog/mail.log"
  script="${script//\/var\/log\/mail/${TMP}/varlog/mail}"
  # `sudo` must not rescue it here: stub a sudo that always refuses.
  cat > "${STUBBIN}/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${STUBBIN}/sudo"
  PATH="${STUBBIN}:$PATH" run bash -c "$script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NWPLOG-UNREADABLE"* ]]
}

@test "a readable mail log is tailed, and a real 'status=sent' line survives" {
  source "${REPO_ROOT}/lib/host-capture.sh"
  local script
  script="$(host_log_source_cmd mail 200)"
  mkdir -p "${TMP}/varlog"
  printf 'postfix/smtp[1]: to=<x@gmail.com>, status=sent (250 2.0.0 OK)\n' > "${TMP}/varlog/mail.log"
  script="${script//\/var\/log\/mail/${TMP}/varlog/mail}"
  run bash -c "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=sent"* ]]
}

@test "pl logs does not report a mail read failure as 'no errors'" {
  _fixture_manifest
  : > "${TMP}/empty"
  _stub_ssh "${TMP}/empty" 4
  PATH="${STUBBIN}:$PATH" run "$PL" logs ci-host --source=mail
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT"* ]]
}

################################################################################
# pl schedule host / where — cron ownership must be answerable without ssh.
################################################################################

@test "pl schedule host exists (pl demo schedule already tells operators to run it)" {
  run "$PL" schedule --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"host"* ]]
}

@test "pl schedule where reports which HOST owns each schedule" {
  run "$PL" schedule where
  # ops#164: this is a LIVE probe and the exit code is part of the contract —
  # 0 = clean, 1 = a declared schedule sits on a stopped cron daemon,
  # 3 = a daemon state could not be read. All three are honest reports;
  # anything else is a real failure. (tests/unit/test-schedule-where.bats
  # pins each code against a stubbed estate.)
  [[ "$status" -eq 0 || "$status" -eq 1 || "$status" -eq 3 ]]
  [[ "$output" == *"HOST"* || "$output" == *"host"* ]]
}

################################################################################
# pl server forge status — the forge holds the whole trust root and no check
# covered it. It must never run a heavy op on the 3.8 GB box.
################################################################################

@test "pl server forge status exists and never shells gitlab-rails" {
  run "$PL" server help
  [ "$status" -eq 0 ]
  [[ "$output" == *"forge"* ]]
  # Comment lines stripped — they name the command only to forbid it.
  run bash -c "grep -vE '^[[:space:]]*#' '${REPO_ROOT}/scripts/commands/server.sh' \
               | grep -nE 'gitlab-rails|gitlab-rake'"
  [ "$status" -ne 0 ]
}

@test "pl server forge status parses a package version from a stubbed host" {
  cat > "${TMP}/forge" <<'EOF'
NWPFORGE v1
pkg=gitlab-ce
version=18.7.7-ce.0
held=yes
key_expiry=2027-05-01
upgradable=0
EOF
  _stub_ssh "${TMP}/forge" 0
  PATH="${STUBBIN}:$PATH" run "$PL" server forge status --probe-cmd="ssh stub" --raw
  [ "$status" -eq 0 ]
  [[ "$output" == *"18.7.7"* ]]
}

################################################################################
# Dead code the standing orders point at reads as coverage.
################################################################################

@test "CLAUDE.md must not instruct agents to source a lib file that has no callers" {
  cd "$REPO_ROOT"
  local bad=()
  # Every lib/*.sh named in CLAUDE.md must be referenced by real PRODUCTION code
  # (lib/, scripts/, pl). A file referenced only by its own tests is still dead
  # to an operator following the standing orders — and tests/ is excluded so
  # this very file cannot satisfy the check it is asserting.
  while read -r libfile; do
    [ -n "$libfile" ] || continue
    local base callers
    base="$(basename "$libfile")"
    callers=$(grep -rl -- "$base" --include='*.sh' lib scripts pl 2>/dev/null \
              | grep -cv "^lib/${base}$" || true)
    [ "$callers" -eq 0 ] && bad+=("$libfile")
  done < <(grep -oE 'lib/[a-z0-9-]+\.sh' CLAUDE.md | sort -u)
  printf 'CLAUDE.md points at dead code: %s\n' "${bad[@]:-none}"
  [ "${#bad[@]}" -eq 0 ]
}

@test "the dead-lib allowlist is SHRINK-ONLY (frozen at 6; never add to it)" {
  local allow="${REPO_ROOT}/tests/fixtures/dead-libs.allow"
  [ -f "$allow" ]
  local n
  n=$(grep -cvE '^\s*(#|$)' "$allow")
  [ "$n" -le 6 ]
}

@test "no lib/*.sh is dead code outside the frozen allowlist" {
  cd "$REPO_ROOT"
  local allow="${REPO_ROOT}/tests/fixtures/dead-libs.allow"
  local dead=()
  for f in lib/*.sh; do
    local base callers
    base="$(basename "$f")"
    callers=$(grep -rl -- "$base" --include='*.sh' lib scripts pl 2>/dev/null \
              | grep -cv "^lib/${base}$" || true)
    if [ "$callers" -eq 0 ] && ! grep -qxF "$f" "$allow" 2>/dev/null; then dead+=("$f"); fi
  done
  printf 'unallowlisted dead lib: %s\n' "${dead[@]:-none}"
  [ "${#dead[@]}" -eq 0 ]
}
