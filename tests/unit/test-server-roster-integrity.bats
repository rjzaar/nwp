#!/usr/bin/env bats
# Fleet-roster integrity for the `--all` verbs.
#
# Regression guard for the box-split bug (2026-07-31): `pl server status --all`
# and `pl server health --all` each loop over server names fed on stdin
# (`while read ... <<< "$servers"`), and each calls ssh inside that loop.
# ssh with stdin left open SLURPS the remaining loop input, so everything after
# the FIRST server silently vanished — a two-box fleet reported as one box, at
# exit 0. A truncated roster that reads as a complete one is the worst possible
# failure for a preflight command, so both the root cause (host_run / ssh -n)
# and the symptom (roster completeness) are pinned here.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  SERVER_SH="${REPO_ROOT}/scripts/commands/server.sh"
  TEST_ROOT="$(mktemp -d)"
  mkdir -p "${TEST_ROOT}/servers" "${TEST_ROOT}/bin"

  # A key file that merely has to EXIST for _status_one to attempt a probe.
  touch "${TEST_ROOT}/fake_key"

  # Three servers so a truncation at any point is visible.
  for n in alpha bravo charlie; do
    mkdir -p "${TEST_ROOT}/servers/${n}"
    cat > "${TEST_ROOT}/servers/${n}/.nwp-server.yml" <<EOF
schema_version: 1
server:
  name: ${n}
  ip: 10.0.0.1
  ssh_user: gitlab
  ssh_key: ${TEST_ROOT}/fake_key
EOF
  done

  # A stub ssh faithful to the one behaviour under test: real ssh drains stdin
  # unless -n is given (which redirects its stdin from /dev/null). So the stub
  # drains only when -n is absent — with the fix in place there is nothing left
  # to drain and the caller's loop input survives.
  cat > "${TEST_ROOT}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-n" ] && exit 0; done
cat >/dev/null 2>&1 || true
exit 0
EOF
  chmod +x "${TEST_ROOT}/bin/ssh"

  export NWP_DIR="${TEST_ROOT}"
  export PATH="${TEST_ROOT}/bin:${PATH}"
}

teardown() { rm -rf "${TEST_ROOT}"; unset NWP_DIR; }

@test "status --all reports EVERY server, not just the first (ssh must not eat the loop's stdin)" {
  run bash "$SERVER_SH" status --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"*   ]]
  [[ "$output" == *"bravo"*   ]]
  [[ "$output" == *"charlie"* ]]
}

@test "status --all keeps going past an incomplete record, and still fails at the end" {
  # `alpha` sorts first, so a broken record here is exactly the case that used
  # to swallow the rest of the fleet. The roster must stay complete AND the
  # command must report failure rather than a clean-looking exit 0.
  cat > "${TEST_ROOT}/servers/alpha/.nwp-server.yml" <<EOF
schema_version: 1
server:
  name: alpha
EOF
  run bash "$SERVER_SH" status --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"alpha"*   ]]
  [[ "$output" == *"bravo"*   ]]
  [[ "$output" == *"charlie"* ]]
}

@test "health --all reports EVERY server too" {
  run bash "$SERVER_SH" health --all --probe-cmd="bash -c"
  [[ "$output" == *"alpha"*   ]]
  [[ "$output" == *"bravo"*   ]]
  [[ "$output" == *"charlie"* ]]
}

@test "host_run does not consume the caller's stdin" {
  # The root cause, isolated. host_run takes its script as an ARGUMENT, so it
  # has no business reading stdin; if it does, every host-looping verb truncates.
  run bash -c "
    source '${REPO_ROOT}/lib/host-capture.sh'
    printf 'one\ntwo\nthree\n' | {
      read -r first
      host_run LOCAL 'true' >/dev/null 2>&1
      # If host_run ate stdin these reads come back empty.
      read -r second
      read -r third
      echo \"\$first \$second \$third\"
    }
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"one two three"* ]]
}
