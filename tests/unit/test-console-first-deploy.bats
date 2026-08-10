#!/usr/bin/env bats
# `pl console deploy` — the FIRST deploy onto a virgin host must not self-report
# as broken.
#
# Same class as ops#331's `pl secrets` defects: a verb written for the steady
# state meets a thing that does not exist yet and calls it a failure. Here the
# verb already KNOWS which state it is in — step 3/5 checks for the TLS cert and
# warns "the service will fail to start until the cert exists" — and then step
# 5/5 runs the health probe anyway and exits 1 with "health check failed — try:
# pl console status / pl console logs". So deploy #1 on a host that has not had
# `pl console cert` run yet ends RED every time, with every step having
# succeeded, and sends the operator to debug a service behaving exactly as
# designed. The verb's own help prescribes dns -> cert -> deploy; nothing
# branched on it.
#
# NOT YET SERVING and BROKEN need different actions, so they get different
# verdicts. The two negative controls below are the load-bearing half: a real
# failure, with a cert present, must still be RED.
#
# No network: ssh / rsync / curl are stubbed on PATH, as in
# test-console-deploy-guard.bats, and act on a local directory playing the part
# of the target host.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CONSOLE_SH="$REPO_ROOT/scripts/commands/console.sh"

  WORK="$BATS_TEST_TMPDIR/w"
  export FAKE_REMOTE_HOME="$WORK/remote-home"
  BIN="$WORK/bin"
  mkdir -p "$FAKE_REMOTE_HOME" "$BIN"

  cat > "$BIN/ssh" <<'EOS'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-i|-p|-F) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift            # the host
mkdir -p "$FAKE_REMOTE_HOME"
cd "$FAKE_REMOTE_HOME" || exit 1
case "$*" in
  *"python3 -m venv"*) mkdir -p "$FAKE_REMOTE_HOME/nwp-console/venv"; echo "(stub) venv + pip"; exit 0 ;;
  *systemctl*)         echo "(stub) systemctl"; exit 0 ;;
esac
HOME="$FAKE_REMOTE_HOME" exec bash -c "$*"
EOS

  cat > "$BIN/rsync" <<'EOS'
#!/bin/bash
args=()
for a in "$@"; do
  case "$a" in
    *:*) [[ "$a" == /* || "$a" == ./* ]] && args+=("$a") || args+=("$FAKE_REMOTE_HOME/${a#*:}") ;;
    *) args+=("$a") ;;
  esac
done
exec /usr/bin/rsync "${args[@]}"
EOS

  # The health probe answers only if $WORK/healthy exists — so "the service is
  # up" is a fixture switch, independent of whether a cert is present. That is
  # what lets the third case below assert a genuine failure is still RED.
  cat > "$BIN/curl" <<'EOS'
#!/bin/bash
[ -f "$HEALTHY_FLAG" ] || exit 7
echo '{"ok":true,"app":"nwp-console"}'
EOS
  chmod +x "$BIN/ssh" "$BIN/rsync" "$BIN/curl"
  export PATH="$BIN:$PATH"
  export HEALTHY_FLAG="$WORK/healthy"

  cat > "$WORK/nwp.yml" <<'EOY'
settings:
  console:
    host: fake-console-host
    fqdn: console.test.invalid
    tailnet_ip: 127.0.0.1
    port: 8600
    headscale_url: https://hs.test.invalid
EOY
  export NWP_CONSOLE_CONFIG="$WORK/nwp.yml"
  export NO_COLOR=1
}

give_cert() { mkdir -p "$FAKE_REMOTE_HOME/.config/nwp-console/tls"
              printf 'PLACEHOLDER-CERT\n' > "$FAKE_REMOTE_HOME/.config/nwp-console/tls/fullchain.pem"; }
give_health() { : > "$HEALTHY_FLAG"; }

@test "first deploy, no cert yet: NOT YET SERVING — deployed, not broken" {
  # Virgin host: no cert, and therefore no service answering. Everything the
  # deploy itself does succeeded.
  run bash "$CONSOLE_SH" deploy --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT YET SERVING"* ]]
  [[ "$output" != *"health check failed"* ]]
  # and it must name the rest of the bring-up, not send them to the debugger
  [[ "$output" == *"pl console cert"* ]]
}

@test "NEGATIVE CONTROL: cert present and service up — still reports healthy, exit 0" {
  give_cert; give_health
  run bash "$CONSOLE_SH" deploy --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
  [[ "$output" != *"NOT YET SERVING"* ]]
}

@test "NEGATIVE CONTROL: cert present but service DOWN is still a RED health check" {
  # This is the case the fix must not swallow. A console that has been fully
  # brought up and is not answering is broken, and must stay exit 1.
  give_cert
  run bash "$CONSOLE_SH" deploy --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"health check failed"* ]]
  [[ "$output" != *"NOT YET SERVING"* ]]
}

@test "logs: before the first deploy, say NOT DEPLOYED YET rather than a raw tail error" {
  run bash "$CONSOLE_SH" logs
  [[ "$output" != *"No such file or directory"* ]]
  [[ "$output" == *"NOT DEPLOYED YET"* ]]
}

@test "NEGATIVE CONTROL: logs still tails a log that exists" {
  mkdir -p "$FAKE_REMOTE_HOME/nwp-console"
  printf 'PLACEHOLDER log line\n' > "$FAKE_REMOTE_HOME/nwp-console/console.log"
  run bash "$CONSOLE_SH" logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLACEHOLDER log line"* ]]
  [[ "$output" != *"NOT DEPLOYED YET"* ]]
}
