#!/usr/bin/env bats
#
# test-library-status-blind.bats — `pl library status` must not exit 0 when it
# could not reach the console host.
#
# WHY THIS EXISTS (ops#383, measured 2026-08-15)
#   cmd_status ended with
#       ssh … || print_warning "  (unreachable)"
#   print_warning returns 0 and it was the last statement, so the verb
#   SUCCEEDED having measured nothing: "could not look" rendered as a clean
#   status. The estate rule (CLAUDE.md, `pl server health`, AUDIT-BLIND in
#   secrets.sh) is exit 2 CANNOT VERIFY, never exit 0.
#
#   The truthful exit (ops#361) is the verb itself: re-run `pl library status`
#   when the host answers and the verdict clears on its own terms.
#
# No skips: everything here is bash and a stub `ssh` on PATH.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CMD="$PROJECT_ROOT/scripts/commands/library.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$BIN" "$OUT"
}

_stub_ssh() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$BIN/ssh"
  chmod +x "$BIN/ssh"
}

_status() {
  run env PATH="$BIN:$PATH" NWP_CONSOLE_HOST=stubhost NWP_LIBRARY_OUT="$OUT" \
      bash "$CMD" status
}

@test "an unreachable console host is exit 2 CANNOT VERIFY, not exit 0" {
  _stub_ssh 'echo "ssh: Could not resolve hostname stubhost" >&2; exit 255'
  _status
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "a host that answers with published bundles is still exit 0" {
  # The green half of the mutation test: the fix must not make the verb
  # incapable of succeeding.
  _stub_ssh 'printf "  library.json  mtime: 2026-08-15T00:00:00Z  size: 1234  mode: 600\n"; exit 0'
  _status
  [ "$status" -eq 0 ]
  [[ "$output" != *"CANNOT VERIFY"* ]]
}

@test "a host that answers 'not published' is a MEASUREMENT — exit 0, no blindness claim" {
  # Genuine absence, honestly measured, is a status this verb may report
  # calmly. Only the unmeasured case is barred from exit 0.
  _stub_ssh 'printf "  library.json: not published\n  library-public.json: not published\n"; exit 0'
  _status
  [ "$status" -eq 0 ]
  [[ "$output" == *"not published"* ]]
  [[ "$output" != *"CANNOT VERIFY"* ]]
}
