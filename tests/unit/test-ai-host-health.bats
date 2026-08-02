#!/usr/bin/env bats
#
# test-ai-host-health.bats — `pl ai-host llm health` must describe the host it
# could not reach, and must not die while doing it.
#
# WHY THIS EXISTS
#   Both checks used `x=$(ai_host_ssh … || echo LITERAL)`. That idiom does not
#   REPLACE the output on failure, it APPENDS to it — and both commands print
#   their answer AND exit non-zero when the answer is bad:
#
#       systemctl --user is-active  →  prints "inactive", exits 3
#       curl -w '%{http_code}'      →  prints "000",      exits 7
#
#   so the two commonest real failures produced a TWO-LINE detail, which
#   emit_json interpolated into python source. Measured 2026-08-03 against the
#   pre-fix file with the same stub used below:
#
#       File "<stdin>", line 7
#         "systemd": {"status": "fail", "detail": "inactive
#       SyntaxError: unterminated string literal
#
#   i.e. `pl ai-host llm health --json` crashed on exactly the runs it exists to
#   report, and the human output said "unreachable" about a host that had
#   answered. Flagged as H2-SWALLOWED-VERDICT by scripts/ci/lint-test-honesty.sh.
#
#   No skips: everything here is bash + python3 and a stub `ssh` on PATH.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CMD="$PROJECT_ROOT/scripts/commands/ai-host.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
}

# Install a stub `ssh` that answers each probe from a case-supplied script.
_stub_ssh() {
  printf '#!/usr/bin/env bash\nlast="${@: -1}"\n%s\nexit 0\n' "$1" > "$BIN/ssh"
  chmod +x "$BIN/ssh"
}

_health() {
  run env PATH="$BIN:$PATH" NWP_AI_HOST_SSH=stubhost \
      bash "$CMD" llm health --quick "$@"
}

# json.tool exits non-zero on anything that is not valid JSON, so this is the
# assertion the pre-fix emitter could not survive.
_assert_valid_json() {
  printf '%s' "$1" | python3 -m json.tool >/dev/null
}

_detail() {
  printf '%s' "$1" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["checks"][sys.argv[1]]["detail"])' "$2"
}

@test "a STOPPED unit is reported as 'inactive' and the JSON still parses" {
  _stub_ssh 'case "$last" in *systemctl*) echo inactive; exit 3 ;; *curl*) echo 000; exit 7 ;; esac'
  _health --json
  [ "$status" -eq 1 ]                      # unhealthy, and it says so
  _assert_valid_json "$output"
  [ "$(_detail "$output" systemd)" = "inactive" ]
  [ "$(_detail "$output" daemon)" = "HTTP 000 on 127.0.0.1:11434/api/tags" ]
}

@test "an UNREACHABLE host is a different verdict from a stopped unit" {
  # Three states, never two: 'could not look' must not read as a measurement.
  _stub_ssh 'echo "ssh: Could not resolve hostname stubhost" >&2; exit 255'
  _health --json
  [ "$status" -eq 1 ]
  _assert_valid_json "$output"
  d="$(_detail "$output" systemd)"
  case "$d" in
    *unreachable*rc=255*"Could not resolve hostname"*) : ;;
    *) printf 'systemd detail did not name the transport failure: %s\n' "$d" >&2; return 1 ;;
  esac
  # …and it is NOT one of the systemd state words, which is what made the old
  # detail indistinguishable from a real answer.
  [ "$d" != "inactive" ]
  [ "$d" != "unreachable" ]
}

@test "a HEALTHY host still reports ok — the fix did not make the check inert" {
  # The green half of the mutation test: a check that can only go red is as
  # useless as one that can only go green.
  _stub_ssh 'case "$last" in
      *systemctl*) echo active; exit 0 ;;
      *curl*) echo 200; exit 0 ;;
      *"ss -tlnH"*) echo 127.0.0.1:11434; exit 0 ;;
      *"ollama list"*) printf "llama3.1:8b\nqwen2.5-coder:14b\n"; exit 0 ;;
    esac'
  _health --json
  [ "$status" -eq 0 ]
  _assert_valid_json "$output"
  [ "$(_detail "$output" systemd)" = "active" ]
  [ "$(_detail "$output" daemon)" = "HTTP 200 on 127.0.0.1:11434/api/tags" ]
  [ "$(_detail "$output" bind)" = "127.0.0.1:11434" ]
}

@test "remote text carrying quotes and newlines cannot break the JSON emitter" {
  # The detail is REMOTE output. Pasting it into python source made the
  # emitter injectable by anything the far end printed.
  _stub_ssh 'printf "he said \"boom\"\nsecond line\n" >&2; exit 255'
  _health --json
  [ "$status" -eq 1 ]
  _assert_valid_json "$output"
  d="$(_detail "$output" systemd)"
  case "$d" in *'"boom"'*'second line'*) : ;;
    *) printf 'detail lost the remote text: %s\n' "$d" >&2; return 1 ;; esac
  # one line, because a detail is a table column
  [ "$(printf '%s' "$d" | wc -l)" -eq 0 ]
}

@test "the human (non-JSON) output names the stopped unit, not 'unreachable'" {
  _stub_ssh 'case "$last" in *systemctl*) echo inactive; exit 3 ;; *curl*) echo 000; exit 7 ;; esac'
  _health
  [ "$status" -eq 1 ]
  [[ "$output" == *"inactive"* ]]
  # The host ANSWERED. Saying "unreachable" anywhere here is the old bug: the
  # literal was appended to the real answer rather than replacing it.
  [[ "$output" != *"unreachable"* ]]
}
