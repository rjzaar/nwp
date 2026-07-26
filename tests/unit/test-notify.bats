#!/usr/bin/env bats
# Item 2 (oversight-honesty): `pl notify` — one notification path, and one that
# can tell you it is broken.
#
# Defect this locks down: every producer curled Gotify with its own inline token
# (scripts/secrets-daily-audit.sh, scripts/console/app/config.py), each with
# `|| true` on the end, and there was NO way to ask "can this machine actually
# notify me?". The security detector had never fired against a real server, and
# the notification system could not notify you that it could not notify you.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  NOTIFY="$ROOT/scripts/commands/notify.sh"
  TMP="$BATS_TEST_TMPDIR/notify"
  mkdir -p "$TMP"
}

@test "scripts/commands/notify.sh exists and is executable (so 'pl notify' dispatches)" {
  [ -f "$NOTIFY" ]
  [ -x "$NOTIFY" ]
}

@test "notify.sh has valid bash syntax" {
  run bash -n "$NOTIFY"
  [ "$status" -eq 0 ]
}

@test "pl notify --help exits 0" {
  run "$NOTIFY" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"notify"* ]]
}

@test "pl notify health against a dead endpoint EXITS NON-ZERO" {
  # 127.0.0.1:1 — nothing listens there, ever.
  run env NWP_NOTIFY_URL="http://127.0.0.1:1" NWP_NOTIFY_TOKEN="fake" "$NOTIFY" health
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unreachable"* ]] || [[ "$output" == *"FAIL"* ]]
}

@test "pl notify send against a dead endpoint EXITS NON-ZERO (never '|| true')" {
  run env NWP_NOTIFY_URL="http://127.0.0.1:1" NWP_NOTIFY_TOKEN="fake" "$NOTIFY" send ops "hello"
  echo "$output"
  [ "$status" -ne 0 ]
}

@test "pl notify health with no token configured EXITS NON-ZERO and says so" {
  run env NWP_NOTIFY_URL="http://127.0.0.1:1" NWP_NOTIFY_TOKEN="" NWP_SECRETS_FILE="$TMP/absent.yml" "$NOTIFY" health
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"token"* ]]
}

@test "the token is never written to argv, stdout or the log" {
  # 0600 curl-config pattern: the secret must not appear in the process table or
  # in any output. We assert on output; argv is covered by the code review of
  # the curl invocation (grep below).
  run env NWP_NOTIFY_URL="http://127.0.0.1:1" NWP_NOTIFY_TOKEN="SUPERSECRETVALUE" "$NOTIFY" send ops "hello"
  echo "$output"
  [[ "$output" != *"SUPERSECRETVALUE"* ]]
}

@test "notify.sh passes the token via a curl config file, not the URL or -H on argv" {
  # `curl "...?token=$t"` puts the secret in /proc/<pid>/cmdline for any local
  # user to read — which is how the previous inline callers did it.
  run grep -nE 'token=\$|PRIVATE-TOKEN: \$|X-Gotify-Key: \$' "$NOTIFY"
  [ "$status" -ne 0 ]
  # curl reads the secret from a 0600 config file (-K), so it never hits argv.
  grep -qE '^\s*-K "\$cfg"|--config' "$NOTIFY"
  grep -q 'chmod 600 "\$cfg"' "$NOTIFY"
}

@test "pl notify send succeeds against a stub server and reports the message id" {
  # A real receipt assertion: the server must accept AND return a stored id.
  python3 - "$TMP" <<'PY' &
import http.server, json, sys, os
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length') or 0))
        body = json.dumps({"id": 4242, "appid": 1}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(sys.argv[1], "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
  local pid=$!
  local tries=0
  while [ ! -s "$TMP/port" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries+1)); done
  local port; port=$(cat "$TMP/port")

  run env NWP_NOTIFY_URL="http://127.0.0.1:$port" NWP_NOTIFY_TOKEN="tok" "$NOTIFY" send ops "hello"
  kill "$pid" 2>/dev/null || true
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"4242"* ]]
}

@test "pl notify health is wired into pl todo as a check" {
  grep -q 'check_notify_health' "$ROOT/lib/todo-checks.sh"
  grep -q 'check_notify_health' "$ROOT/lib/todo-checks.sh"
}

@test "scripts/secrets-daily-audit.sh routes through pl notify, not its own inline curl" {
  run grep -nE 'curl .*gotify|message\?token=' "$ROOT/scripts/secrets-daily-audit.sh"
  [ "$status" -ne 0 ]
  grep -q 'notify.sh\|pl notify' "$ROOT/scripts/secrets-daily-audit.sh"
}
