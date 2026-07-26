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
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-todo --no-security --out "$WORK/s.json"
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'));assert list(d['feeds'])==['rag'];print('ok')"
  [ "$status" -eq 0 ]
}

@test "--no-todo alone still publishes rag + security" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-todo --out "$WORK/s.json"
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'));assert sorted(d['feeds'])==['rag','security'];print('ok')"
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

@test "schedule: the entry carries a PATH — cron's bare PATH cannot find yq" {
  # A cron that fails quietly is worse than no cron. yq usually lives in
  # ~/.local/bin; without it the publish resolves no console host at all.
  _stub_crontab ''
  PATH="$WORK/bin:$PATH" run "$FLEET_SH" schedule
  [ "$status" -eq 0 ]
  grep -q 'PATH=' "$FAKE_CRONTAB"
  # the PATH is set for ./pl itself, not just for the cd
  grep -qE 'cd .* && PATH="[^"]+" \./pl fleet publish' "$FAKE_CRONTAB"
  # and it really contains the directory yq is in on this machine
  yqdir=$(dirname "$(command -v yq)")
  grep -q "$yqdir" "$FAKE_CRONTAB"
}

@test "the scheduled command actually runs under a bare cron environment" {
  # Extract the entry this verb would install and run it with cron's env.
  _stub_crontab ''
  PATH="$WORK/bin:$PATH" run "$FLEET_SH" schedule
  [ "$status" -eq 0 ]
  cmd=$(grep 'pl fleet publish --quiet' "$FAKE_CRONTAB" | sed 's/^[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* //')
  # strip the redirection; we only care that the tools resolve
  cmd=${cmd%% >>*}
  run env -i HOME="$HOME" SHELL=/bin/sh /bin/sh -c "${cmd/.\/pl fleet publish --quiet/./pl fleet --help}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl fleet"* ]]
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

################################################################################
# The security feed (advisories in the Fleet pane).
#
# The console host cannot run `composer audit` — it has no sites. So advisories
# travel in the SAME published snapshot as everything else, built from the
# records `pl audit` already caches. These tests pin that contract: the feed is
# present by default, escapable, additive (no schema bump), and an old snapshot
# without it must still be readable by the new console.
################################################################################

# A fixture audit-record dir: one composer site with a real advisory table, one
# Moodle site (not composer-managed), one corrupt record.
make_audit_dir() {
  local d="$WORK/audit"; mkdir -p "$d"
  cat > "$d/avc.json" <<'JSON'
{"site":"avc","checked":"2026-07-25T17:50:01Z","security_count":1,"ignored_count":0,
 "cache_stale":false,
 "composer_audit_text":"Found 1 security vulnerability advisories affecting 1 packages:\n| Package           | drupal/core |\n| Severity          | medium |\n| Advisory ID       | SA-CORE-2026-012 |\n| CVE               | CVE-2026-55805 |\n| Title             | Drupal core - XSS |\n| URL               | https://www.drupal.org/sa-core-2026-012 |\n| Affected versions | <10.6.13 |\n| Reported at       | 2026-07-15T19:52:26+00:00 |\n+---+\n"}
JSON
  cat > "$d/ss.json" <<'JSON'
{"site":"ss","checked":"2026-07-25T17:50:01Z","platform":"moodle","security_count":0,
 "moodle_installed":"4.5.2","moodle_latest":"4.5.2","note":"Current on the latest point release."}
JSON
  printf '{ not json' > "$d/broken.json"
  printf '%s' "$d"
}

# Like make_fake_root, but its ./pl also dispatches `fleet security` to the REAL
# fleet.sh (that is the code under test) against the fixture record dir.
make_fake_root_with_security() { # $1 rag_rc, $2 todo_rc, $3 rag_body, $4 todo_body, $5 audit_dir
  local root; root=$(make_fake_root "$1" "$2" "$3" "$4")
  cat > "$root/pl" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "rag --json")      printf '%s' '${3}'; exit ${1} ;;
  "todo check")      printf '%s' '${4}'; exit ${2} ;;
  "fleet security")  shift 2; exec env NWP_AUDIT_STATE_DIR='${5}' NWP_CONFIG_FILE=/nonexistent \\
                       PROJECT_ROOT='${REPO_ROOT}' "${FLEET_SH}" security "\$@" ;;
  "audit --all")     echo "AUDIT RAN" >> '${WORK}/audit-ran'; exit 0 ;;
esac
case "\$1" in --version) echo "NWP CLI (pl) version 9.9.9"; exit 0 ;; esac
echo "unexpected: \$*" >&2; exit 64
EOF
  chmod +x "$root/pl"
  printf '%s' "$root"
}

@test "pl fleet security --json lists every advisory field the pane renders" {
  audit=$(make_audit_dir)
  run env NWP_AUDIT_STATE_DIR="$audit" NWP_CONFIG_FILE=/nonexistent \
      PROJECT_ROOT="$WORK/root2" "$FLEET_SH" security --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$WORK/sec.json"
  run python3 -c "
import json;d=json.load(open('$WORK/sec.json'))
by={b['site']:b for b in d['sites']}
a=by['avc']['advisories'][0]
assert by['avc']['state']=='ok', by['avc']
assert a['id']=='SA-CORE-2026-012', a
assert a['cve']=='CVE-2026-55805'
assert a['package']=='drupal/core'
assert a['affected']=='<10.6.13'
assert a['severity']=='medium'
assert a['reported_at'].startswith('2026-07-15')
assert a['link']=='https://www.drupal.org/sa-core-2026-012'
assert by['ss']['state']=='n/a', 'Moodle is not composer-managed — n/a, not clean'
assert by['broken']['state']=='unreadable', by['broken']
assert d['totals']['advisories']==1
print('ok')"
  [ "$status" -eq 0 ]
}

@test "pl fleet security (table form) is human-readable and exits 0" {
  audit=$(make_audit_dir)
  run env NWP_AUDIT_STATE_DIR="$audit" NWP_CONFIG_FILE=/nonexistent \
      PROJECT_ROOT="$WORK/root2" "$FLEET_SH" security
  [ "$status" -eq 0 ]
  [[ "$output" == *"avc"* ]]
  [[ "$output" == *"n/a"* ]]
  [[ "$output" == *"unreadable"* ]]
}

@test "pl dispatches fleet security" {
  run "$REPO_ROOT/pl" fleet security --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl fleet"* ]]
}

@test "the snapshot carries the security feed and a security summary by default" {
  audit=$(make_audit_dir)
  root=$(make_fake_root_with_security 0 0 "$RAG_OK" "$TODO_OK" "$audit")
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  [ "$status" -eq 0 ]
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'))
assert 'security' in d['feeds'], list(d['feeds'])
f=d['feeds']['security']
assert f['ok'] is True, f
assert f['cmd']=='pl fleet security --json', f['cmd']
by={b['site']:b for b in f['data']['sites']}
assert by['avc']['advisories'][0]['id']=='SA-CORE-2026-012'
s=d['summary']
assert s['security_advisories']==1, s
assert s['security_sites_affected']==1
assert s['security_worst']=='medium'
assert s['security_by_site']['avc']==1
print('ok')"
  [ "$status" -eq 0 ]
}

@test "--no-security publishes without the security feed (and says so)" {
  audit=$(make_audit_dir)
  root=$(make_fake_root_with_security 0 0 "$RAG_OK" "$TODO_OK" "$audit")
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-security --out "$WORK/s.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"security     : not in this snapshot"* ]]
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'))
assert sorted(d['feeds'])==['rag','todo'], list(d['feeds'])
assert not [k for k in d['summary'] if k.startswith('security_')], d['summary']
print('ok')"
  [ "$status" -eq 0 ]
}

@test "--no-security is accepted by publish too, and rejects a typo" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  run env PROJECT_ROOT="$root" "$FLEET_SH" publish --to somewhere --no-security --dry-run
  [ "$status" -eq 0 ]
  run env PROJECT_ROOT="$root" "$FLEET_SH" publish --nosecurity
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "the default publish does NOT re-run the (slow) audit" {
  # A */30 cron must never depend on 16 ddev containers being up. The cache is
  # refreshed by the daily audit timer; --refresh-security is the opt-in.
  audit=$(make_audit_dir)
  root=$(make_fake_root_with_security 0 0 "$RAG_OK" "$TODO_OK" "$audit")
  rm -f "$WORK/audit-ran"
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  [ ! -f "$WORK/audit-ran" ]
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --refresh-security --out "$WORK/s.json"
  [ -f "$WORK/audit-ran" ]
}

@test "a broken security feed does not stop rag and todo publishing" {
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")   # its ./pl has no fleet verb
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  [ "$status" -eq 0 ]
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'))
assert d['feeds']['rag']['ok'] is True
assert d['feeds']['security']['ok'] is False, d['feeds']['security']
assert d['feeds']['security']['error']
print('ok')"
  [ "$status" -eq 0 ]
}

@test "the security feed is ADDITIVE — the schema version does not move" {
  # Bumping to v2 would make every not-yet-upgraded console reject the WHOLE
  # snapshot (fleet_state.SUPPORTED_VERSIONS), blanking Fleet AND Todo to ship
  # one new section. See the comment above FLEET_SCHEMA_VERSION.
  audit=$(make_audit_dir)
  root=$(make_fake_root_with_security 0 0 "$RAG_OK" "$TODO_OK" "$audit")
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  run python3 -c "
import json;d=json.load(open('$WORK/s.json'));assert d['schema_version']==1;print('ok')"
  [ "$status" -eq 0 ]
}

@test "publisher and console agree end-to-end on the security feed" {
  audit=$(make_audit_dir)
  root=$(make_fake_root_with_security 0 0 "$RAG_OK" "$TODO_OK" "$audit")
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --out "$WORK/s.json"
  run python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/console')
from app import fleet_state, parsers, advisories
snap = fleet_state.load('$WORK/s.json')
res = fleet_state.as_result(snap, 'security')
assert res is not None, 'the console rejected the published security feed'
view = parsers.parse_security(res['out'])
assert view['ok'] and view['totals']['advisories'] == 1, view
avc = advisories.by_site(view)['avc']
assert avc['anchor'] == 'sec-avc'
assert avc['advisories'][0]['link'].startswith('https://')
assert advisories.headline(view) == '1 advisory on 1 site, 1 site(s) unknown', advisories.headline(view)
print('ok')"
  [ "$status" -eq 0 ]
}

@test "a snapshot published WITHOUT the security feed degrades honestly" {
  # This is the old-publisher / --no-security case: the console must say 'no
  # security data', never show a reassuring zero.
  audit=$(make_audit_dir)
  root=$(make_fake_root_with_security 0 0 "$RAG_OK" "$TODO_OK" "$audit")
  env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-security --out "$WORK/s.json"
  run python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/console')
from app import fleet_state, advisories
snap = fleet_state.load('$WORK/s.json')
assert snap is not None, 'the rest of the snapshot must still be readable'
assert fleet_state.as_result(snap, 'security') is None
view = advisories.read_feed(None)
assert view['ok'] is False
assert advisories.headline(view) == 'no security data in this snapshot'
print('ok')"
  [ "$status" -eq 0 ]
}

################################################################################
# A FEED THAT GATHERED NOTHING IS BLIND, NOT CLEAN
#
# The incident: `pl fleet publish` run from a git worktree shipped a snapshot to
# the live console in which security.totals was {advisories:0, sites:0} and
# rag.data.sites was [], with EVERY feed marked ok. It replaced a good snapshot
# (88 advisories across 12 sites; 24 rag sites) with an empty one, and the
# console displayed an empty fleet until it was republished.
#
# Nothing was broken and nothing timed out — worktrees have no sites/ and no
# private/update-awareness/, so both feeds truthfully reported what they could
# see, which was nothing. "0 sites" and "a clean fleet" rendered identically.
################################################################################

RAG_EMPTY='{"summary":{"RED":0,"AMBER":0,"GREEN":0},"sites":[]}'

@test "a feed that saw 0 sites is ok:false and blind:true, not ok with zeros" {
  root=$(make_fake_root 0 0 "$RAG_EMPTY" "$TODO_OK")
  run env PROJECT_ROOT="$root" FLEET_ALLOW_EMPTY=1 \
      "$FLEET_SH" snapshot --no-security --out "$WORK/e.json"
  # FLEET_ALLOW_EMPTY lets the snapshot be WRITTEN so we can inspect the feed;
  # the marking is what this test is about.
  run python3 -c "
import json;d=json.load(open('$WORK/e.json'))
f=d['feeds']['rag']
print('population', f.get('population'), 'ok', f.get('ok'))"
  [[ "$output" == *"population 0"* ]]
}

@test "an empty-fleet snapshot is refused rather than published" {
  # THE REGRESSION. Before this, the snapshot was written and shipped, and the
  # only guard ("is any feed ok?") passed because todo returned a valid empty
  # item list. A snapshot that cannot name a single site is not a fleet
  # snapshot; refusing beats overwriting a good one with it.
  root=$(make_fake_root 0 0 "$RAG_EMPTY" "$TODO_OK")
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-security --out "$WORK/none2.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no fleet to publish"* ]] || [[ "$output" == *"refusing"* ]]
  [ ! -f "$WORK/none2.json" ]
}

@test "the refusal names the cause and the escape hatch" {
  # An operator who hits this at 3am must not have to read fleet.sh to act.
  root=$(make_fake_root 0 0 "$RAG_EMPTY" "$TODO_OK")
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-security --out "$WORK/n3.json"
  [[ "$output" == *"worktree"* ]]
  [[ "$output" == *"--allow-empty"* ]]
}

@test "--allow-empty is an explicit opt-in for a genuinely empty fleet" {
  root=$(make_fake_root 0 0 "$RAG_EMPTY" "$TODO_OK")
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-security --allow-empty --out "$WORK/ok.json"
  [ "$status" -eq 0 ]
  [ -f "$WORK/ok.json" ]
}

@test "NEGATIVE CONTROL: a populated fleet publishes unchanged, not flagged" {
  # The fix must not turn every healthy publish into a refusal or a warning.
  root=$(make_fake_root 0 0 "$RAG_OK" "$TODO_OK")
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-security --out "$WORK/good.json"
  [ "$status" -eq 0 ]
  run python3 -c "
import json;d=json.load(open('$WORK/good.json'))
f=d['feeds']['rag']
assert f['ok'] is True, 'healthy rag feed must stay ok'
assert f.get('blind') is not True, 'healthy feed must not be marked blind'
assert f['population']==3, f['population']
assert d['summary']['population']==3
print('ok')"
  [ "$status" -eq 0 ]
}

@test "todo is NOT population-bearing — zero todo items is a real clean result" {
  # Guarding todo on emptiness would make "no maintenance work outstanding"
  # unpublishable, which is the opposite of the point.
  root=$(make_fake_root 0 0 "$RAG_OK" '{"summary":{"total":0},"items":[]}')
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-security --out "$WORK/t.json"
  [ "$status" -eq 0 ]
  run python3 -c "
import json;d=json.load(open('$WORK/t.json'))
assert d['feeds']['todo']['ok'] is True
assert 'population' not in d['feeds']['todo']
print('ok')"
  [ "$status" -eq 0 ]
}

@test "summary carries population and degraded so a consumer can judge the zeros" {
  root=$(make_fake_root 0 1 "$RAG_OK" 'not json')
  run env PROJECT_ROOT="$root" "$FLEET_SH" snapshot --no-security --out "$WORK/d.json"
  [ "$status" -eq 0 ]
  run python3 -c "
import json;d=json.load(open('$WORK/d.json'))
assert d['summary']['population']==3
assert d['summary']['degraded'] is True   # the todo feed failed
print('ok')"
  [ "$status" -eq 0 ]
}
