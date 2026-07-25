#!/usr/bin/env bats
# `pl fleet publish` — the snapshot the console consumes.
#
# The console host has no sites, so `pl rag` there returns an empty fleet. The
# machine that HAS the sites publishes a snapshot instead. These tests pin the
# snapshot contract (schema, provenance, per-feed honesty) with a stub `pl`,
# so nothing here touches a real site, a real host or the network.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  FLEET_SH="$REPO_ROOT/scripts/commands/fleet.sh"
  WORK="$BATS_TEST_TMPDIR/w"
  mkdir -p "$WORK"
  export NO_COLOR=1
  export NWP_CONSOLE_CONFIG=/nonexistent      # no operator config in tests
  unset NWP_CONSOLE_HOST || true
}

# A fake nwp root whose ./pl answers the two feeds. $1 = rag exit code.
make_fake_root() { # $1 rag_rc, $2 todo_rc, $3 rag_body, $4 todo_body
  local root="$WORK/root"; mkdir -p "$root"
  cat > "$root/pl" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "rag --json")   printf '%s' '${3}'; exit ${1} ;;
  "todo check")   printf '%s' '${4}'; exit ${2} ;;
  "--version "*|"--version") echo "NWP CLI (pl) version 9.9.9"; exit 0 ;;
esac
case "\$1" in --version) echo "NWP CLI (pl) version 9.9.9"; exit 0 ;; esac
echo "unexpected: \$*" >&2; exit 64
EOF
  chmod +x "$root/pl"
  printf '%s' "$root"
}

RAG_OK='{"summary":{"RED":2,"AMBER":0,"GREEN":1},"sites":[{"site":"avc","rag":"RED"},{"site":"nwc","rag":"RED"},{"site":"nwd","rag":"GREEN"}]}'
TODO_OK='{"summary":{"total":2},"items":[{"id":"BAK-avc","category":"BAK","title":"Backup is 14 days old","site":"avc"},{"id":"DSK-001","category":"DSK","title":"Disk usage critical"}]}'

@test "fleet.sh passes bash -n and is executable" {
  bash -n "$FLEET_SH"
  [ -x "$FLEET_SH" ]
}

@test "help exits 0 and explains why it exists" {
  run "$FLEET_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"publish"* ]]
  [[ "$output" == *"no sites"* ]]
}

@test "unknown subcommand fails" {
  run "$FLEET_SH" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown subcommand"* ]]
}

@test "pl dispatches fleet" {
  run "$REPO_ROOT/pl" fleet --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl fleet"* ]]
}

@test "snapshot has the schema, a UTC timestamp and the producing host" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  [ "$status" -eq 0 ]
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'))
assert d['schema']=='nwp.fleet-state', d['schema']
assert d['schema_version']==1
assert d['generated_at'].endswith('Z')
assert d['generated_by']['host']
assert d['generated_by']['pl_version']=='9.9.9', d['generated_by']
print('ok')"
  [ "$status" -eq 0 ]
}

@test "snapshot carries both feeds verbatim under .feeds.<name>.data" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'))
assert [s['site'] for s in d['feeds']['rag']['data']['sites']]==['avc','nwc','nwd']
assert d['feeds']['todo']['data']['items'][0]['id']=='BAK-avc'
assert d['summary']['RED']==2 and d['summary']['sites']==3
assert d['summary']['todo_items']==2 and d['summary']['backup_items']==1
print('ok')"
  [ "$status" -eq 0 ]
}

@test "pl rag exit 3 (a site is RED) is NOT treated as a failed feed" {
  # `pl rag` exits 3 when any site is red — that is the signal, not an error.
  root=$(make_fake_root 3 0 "$RAG_OK" "$TODO_OK")
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  [ "$status" -eq 0 ]
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'))
assert d['feeds']['rag']['ok'] is True, d['feeds']['rag']
assert d['feeds']['rag']['rc']==3
print('ok')"
  [ "$status" -eq 0 ]
}

@test "--no-todo publishes the rag feed only" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-todo --out "$WORK/s.json"
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'));assert list(d['feeds'])==['rag'];print('ok')"
  [ "$status" -eq 0 ]
}

@test "one broken feed still publishes, marked ok:false with its error" {
  root=$(make_fake_root 0 1 "$RAG_OK" 'not json at all')
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  [ "$status" -eq 0 ]
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'))
assert d['feeds']['rag']['ok'] is True
assert d['feeds']['todo']['ok'] is False
assert d['feeds']['todo']['error']
print('ok')"
  [ "$status" -eq 0 ]
}

@test "a snapshot with NO usable feed is refused, not published" {
  # Publishing an all-empty snapshot would look fresh while saying nothing —
  # worse than having no snapshot at all.
  root=$(make_fake_root 1 1 'boom' 'boom')
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/none.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to publish"* ]]
  [ ! -f "$WORK/none.json" ]
}

@test "the snapshot file is written 0600" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  [ "$(stat -c %a "$WORK/s.json")" = "600" ]
}

@test "publish with no host configured fails closed with the fix in the message" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  run env PROJECT_ROOT="$root" "$FLEET_SH" publish
  [ "$status" -ne 0 ]
  [[ "$output" == *"no console host"* ]]
}

@test "--dry-run builds the snapshot and ships nothing" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  # An ssh on PATH here would be a bug; make sure calling it would fail loudly.
  mkdir -p "$WORK/bin"
  printf '#!/bin/bash\necho "ssh MUST NOT RUN" >&2; exit 99\n' > "$WORK/bin/ssh"
  chmod +x "$WORK/bin/ssh"
  run env PATH="$WORK/bin:$PATH" PROJECT_ROOT="$root" "$FLEET_SH" publish --to somewhere --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing shipped"* ]]
  [[ "$output" != *"MUST NOT RUN"* ]]
  [ -f "$root/private/fleet/fleet-state.json" ]
}

@test "publish refuses a destination that is not a boring absolute path" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  run env PROJECT_ROOT="$root" "$FLEET_SH" publish --to somewhere --dest '/tmp/x;rm -rf ~'
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing suspicious --dest"* ]]
}

@test "publish ships the snapshot and verifies what landed" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  mkdir -p "$WORK/bin" "$WORK/target"
  # Fake ssh: run the remote command locally with HOME=$WORK/target.
  cat > "$WORK/bin/ssh" <<'EOS'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
HOME="$FAKE_TARGET" exec bash -c "$*"
EOS
  chmod +x "$WORK/bin/ssh"
  run env PATH="$WORK/bin:$PATH" FAKE_TARGET="$WORK/target" PROJECT_ROOT="$root" \
      "$FLEET_SH" publish --to somewhere
  [ "$status" -eq 0 ]
  [[ "$output" == *"published"* ]]
  landed="$WORK/target/.local/share/nwp-console/fleet-state.json"
  [ -f "$landed" ]
  [ "$(stat -c %a "$landed")" = "600" ]
  run python3 -c "
import json;d=json.load(open('$landed'));assert d['summary']['RED']==2;print('ok')"
  [ "$status" -eq 0 ]
}

@test "publish is idempotent — a second run just replaces the file" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  mkdir -p "$WORK/bin" "$WORK/target"
  cat > "$WORK/bin/ssh" <<'EOS'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
HOME="$FAKE_TARGET" exec bash -c "$*"
EOS
  chmod +x "$WORK/bin/ssh"
  env PATH="$WORK/bin:$PATH" FAKE_TARGET="$WORK/target" PROJECT_ROOT="$root" "$FLEET_SH" publish --to somewhere
  run env PATH="$WORK/bin:$PATH" FAKE_TARGET="$WORK/target" PROJECT_ROOT="$root" "$FLEET_SH" publish --to somewhere
  [ "$status" -eq 0 ]
  [ "$(ls "$WORK/target/.local/share/nwp-console/" | wc -l)" = "1" ]   # no tmp litter
}

@test "the published snapshot is exactly what the console consumer accepts" {
  # End-to-end contract check across the bash producer and the python consumer.
  root=$(make_fake_root 3 0 "$RAG_OK" "$TODO_OK")
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  run python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/console')
from app import fleet_state, parsers
snap = fleet_state.load('$WORK/s.json')
assert snap is not None, 'consumer rejected the published snapshot'
res = fleet_state.as_result(snap, 'rag')
rag = parsers.parse_rag(res['out'])
assert rag['ok'] and rag['counts']['RED'] == 2, rag
todo = parsers.parse_todo(fleet_state.as_result(snap, 'todo')['out'])
assert len(parsers.todo_backup_items(todo)) == 1, todo
print('ok')"
  [ "$status" -eq 0 ]
}

################################################################################
# `pl fleet schedule` rewrites the WHOLE crontab and drops every line mentioning
# `pl fleet publish` — including one a human wrote. ops#47 says compute that and
# say it out loud. `crontab` is stubbed against a file: the real one is never
# read or written by these tests.
################################################################################

_stub_crontab() {  # $1 = initial crontab contents
  mkdir -p "$WORK/bin"
  export FAKE_CRONTAB="$WORK/crontab.txt"
  printf '%s' "$1" > "$FAKE_CRONTAB"
  cat > "$WORK/bin/crontab" <<'EOS'
#!/bin/bash
case "${1:-}" in
  -l) cat "$FAKE_CRONTAB" ;;
  -)  cat > "$FAKE_CRONTAB" ;;
  *)  exit 2 ;;
esac
EOS
  chmod +x "$WORK/bin/crontab"
}

@test "schedule: a first install displaces nothing — report, no prompt, entry lands" {
  _stub_crontab '@daily /usr/bin/something-else
'
  PATH="$WORK/bin:$PATH" run "$FLEET_SH" schedule
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT AFFECTED"* ]]                 # the report is always printed
  [[ "$output" != *"WILL BE PERMANENTLY DELETED"* ]]  # nothing was displaced
  grep -q 'pl fleet publish --quiet' "$FAKE_CRONTAB"
  grep -q 'something-else' "$FAKE_CRONTAB"            # the operator's line survives
}

@test "schedule: displacing an existing line reports it and fails closed with no TTY" {
  _stub_crontab '@daily /usr/bin/something-else
*/5 * * * * cd /somewhere && ./pl fleet publish --quiet
'
  PATH="$WORK/bin:$PATH" run "$FLEET_SH" schedule
  [ "$status" -ne 0 ]
  [[ "$output" == *"WILL BE PERMANENTLY DELETED"* ]]
  [[ "$output" == *"No terminal available"* ]]
  # refused => the crontab is untouched
  grep -q '\*/5 \* \* \* \*' "$FAKE_CRONTAB"
}

@test "schedule: -y skips the PROMPT, never the REPORT" {
  _stub_crontab '@daily /usr/bin/something-else
*/5 * * * * cd /somewhere && ./pl fleet publish --quiet
'
  PATH="$WORK/bin:$PATH" run "$FLEET_SH" schedule -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"WILL BE PERMANENTLY DELETED"* ]]
  grep -q 'something-else' "$FAKE_CRONTAB"
  [ "$(grep -c 'pl fleet publish --quiet' "$FAKE_CRONTAB")" -eq 1 ]   # replaced, not doubled
  ! grep -q '\*/5 \* \* \* \*' "$FAKE_CRONTAB"                        # the old cadence is gone
}

@test "schedule --remove with nothing installed is a no-op that still reports" {
  _stub_crontab '@daily /usr/bin/something-else
'
  PATH="$WORK/bin:$PATH" run "$FLEET_SH" schedule --remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
  grep -q 'something-else' "$FAKE_CRONTAB"
}

@test "schedule rejects an unknown option instead of ignoring it" {
  _stub_crontab ''
  PATH="$WORK/bin:$PATH" run "$FLEET_SH" schedule --yolo
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}
