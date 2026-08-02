#!/usr/bin/env bats
# `pl moodle content sync` — repair depth content in place on a site that
# already has the courses (scripts/commands/moodle.sh cmd_content_sync,
# nwp/ops#220).
#
# The load-bearing guards, each observed RED against the pre-fix tree (the verb
# did not exist at all; the only way to do this was a hand `ssh` + `mysql`
# UPDATE, which is exactly what the standing order forbids):
#
#   1. local validation — every *.json must parse and carry a non-empty string
#                         top-level `id`; ONE bad file refuses the WHOLE run.
#                         A partially-understood content payload must never be
#                         partially applied.
#   2. duplicate ids    — the same pointid in two files is a refusal, never
#                         last-wins.
#   3. dry-run default  — a plain invocation executes NOTHING remote (asserted
#                         via PATH stubs + a trace file).
#   4. verified push    — the payload is scp'd and its sha256 re-checked ON the
#                         target before anything runs.
#   5. plan before write— the read-only --plan runs on the target first, and a
#                         missing PLAN-SUMMARY refuses rather than writing blind.
#   6. rollback ledger  — --apply passes --backup=… and the prior values are
#                         pulled back to sites/<site>/backups/.
#
# NO network, NO real ssh: ssh/scp are PATH stubs writing to a trace file; the
# stub "box" answers sha256sum from a fake home so the verified-push contract is
# exercised for real.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  MOODLE="${REPO_ROOT}/scripts/commands/moodle.sh"
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  export NWP_SSH_NO_MULTIPLEX=1
  mkdir -p "${PROJECT_ROOT}/sites/ssd/dev"

  cat > "${PROJECT_ROOT}/sites/ssd/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: ssd
  type: moodle
live:
  enabled: true
  domain: ssd.example.org
  server_ip: 203.0.113.11
  ssh_user: gitlab
  remote_path: /var/www/ssd
moodle:
  cli_php_version: "8.2"
EOF

  # A clean learning-point set, in the shape the canonical catalogue builds.
  LP="${TEST_TMP}/json"
  mkdir -p "$LP"
  cat > "${LP}/A1.01.json" <<'EOF'
{"id":"A1.01","title":"Every baptised person is called to holiness","session":1,
 "depths":{"standard":{"text":"body","video":{"youtube_id":"JOJNDEeKDKc","start":"3:50","end":"5:30"}}},
 "quiz_items":[{"id":"A1.01.q1","type":"truefalse","correct_answer":false}]}
EOF
  cat > "${LP}/A1.02.json" <<'EOF'
{"id":"A1.02","title":"The lie that holiness is for others","session":1,
 "depths":{"standard":{"text":"body"}},"quiz_items":[]}
EOF

  # --- ssh/scp stubs + fake box -------------------------------------------
  STUB="${TEST_TMP}/stub"
  export CS_TRACE="${TEST_TMP}/trace.txt"
  export CS_FAKEHOME="${TEST_TMP}/fakehome"
  mkdir -p "$STUB" "$CS_FAKEHOME"
  : > "$CS_TRACE"

  cat > "${STUB}/ssh" <<'SSH'
#!/bin/bash
# Drain stdin like real ssh does.
cat >/dev/null
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-i) shift 2 ;;
    -*)    shift ;;
    *)     args+=("$1"); shift ;;
  esac
done
cmd="${args[*]:1}"
printf 'SSH %s\n' "$cmd" >> "$CS_TRACE"
case "$cmd" in
  *sha256sum*)
    n="$(printf '%s' "$cmd" | grep -o '~/[A-Za-z0-9._-]*' | head -1)"; n="${n#\~/}"
    sha256sum "$CS_FAKEHOME/$n" 2>/dev/null | cut -d' ' -f1 ;;
  *--plan*)
    if [ -n "${CS_NO_SUMMARY:-}" ]; then echo "POINT A1.01 PRESENT DIFFER 10 20"; exit 0; fi
    echo "POINT A1.01 PRESENT DIFFER 10 20"
    echo "POINT A1.02 ABSENT - 0 20"
    echo "PLAN-SUMMARY payload=2 present=1 absent=1 differ=1 same=0" ;;
  *--apply*)
    echo "UPDATED A1.01"
    echo "ABSENT A1.02"
    echo "APPLY-SUMMARY payload=2 changed=1 unchanged=0 absent=1 courses=1" ;;
  *cat*rollback.ndjson*)
    echo '{"pointid":"A1.01","content_json":{"id":"A1.01","depths":{}}}' ;;
  *) : ;;
esac
exit 0
SSH
  cat > "${STUB}/scp" <<'SCP'
#!/bin/bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-i) shift 2 ;;
    -*)    shift ;;
    *)     args+=("$1"); shift ;;
  esac
done
printf 'SCP %s -> %s\n' "${args[0]}" "${args[1]}" >> "$CS_TRACE"
cp "${args[0]}" "$CS_FAKEHOME/${args[1]#*:}"
SCP
  chmod +x "${STUB}/ssh" "${STUB}/scp"
}

teardown() { rm -rf "${TEST_TMP}"; }

cs() {
  env PATH="${STUB}:${PATH}" AUTO_CONFIRM=true bash "$MOODLE" content sync "$@"
}

# ── argument surface ─────────────────────────────────────────────────────────

@test "c1: --tier is required and stg is refused (no sync path at stg)" {
  run cs ssd --from="$LP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--tier is required"* ]]
  run cs ssd --tier=stg --from="$LP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be live or dev"* ]]
}

@test "c2: --from is required and must be a directory" {
  run cs ssd --tier=live --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--from=DIR is required"* ]]
  run cs ssd --tier=live --from="${TEST_TMP}/nope" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]]
}

# ── guard 1: local validation, one bad file refuses the whole run ────────────

@test "c3: a directory with no *.json refuses" {
  local d="${TEST_TMP}/empty"; mkdir -p "$d"; echo x > "${d}/README.md"
  run cs ssd --tier=live --from="$d" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"No *.json learning-point files"* ]]
}

@test "c4: a single unparseable file refuses the WHOLE run, and names it" {
  echo '{not json' > "${LP}/BROKEN.json"
  run cs ssd --tier=live --from="$LP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"BROKEN.json"* ]]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "c5: a file with no top-level string 'id' refuses (nothing to match on)" {
  echo '{"title":"orphan","depths":{}}' > "${LP}/A1.03.json"
  run cs ssd --tier=live --from="$LP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"A1.03.json"* ]]
  [[ "$output" == *"pointid"* ]]
}

@test "c6: an 'id' with a path shape refuses" {
  echo '{"id":"../etc/passwd","depths":{}}' > "${LP}/A1.04.json"
  run cs ssd --tier=live --from="$LP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"path shape"* ]]
}

# ── guard 2: duplicate pointids are never last-wins ──────────────────────────

@test "c7: the same pointid in two files refuses" {
  cp "${LP}/A1.01.json" "${LP}/A1.01-copy.json"
  run cs ssd --tier=live --from="$LP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"more than one file"* ]]
}

# ── guard 3: dry-run is the default and touches nothing remote ───────────────

@test "c8: a plain invocation is a dry-run and makes NO remote call" {
  run cs ssd --tier=live --from="$LP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"2 learning point(s) validated"* ]]
  [ ! -s "$CS_TRACE" ]
}

@test "c9: dry-run states the containment contract (update-only, never creates)" {
  run cs ssd --tier=live --from="$LP" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXISTING depthcontent rows matched by pointid"* ]]
  [[ "$output" == *"never created"* ]]
}

# ── guard 4/5/6: apply path — verified push, plan first, rollback pulled ─────

@test "c10: --apply pushes the payload sha256-verified before running anything" {
  run cs ssd --tier=live --from="$LP" --apply
  [ "$status" -eq 0 ]
  grep -q 'SCP .* -> gitlab@203.0.113.11:content-sync-apply.php' "$CS_TRACE"
  grep -q 'SCP .* -> gitlab@203.0.113.11:content-sync-payload.ndjson' "$CS_TRACE"
  grep -q 'sha256sum ~/content-sync-payload.ndjson' "$CS_TRACE"
}

@test "c11: --apply runs the READ-ONLY plan before the write, in that order" {
  run cs ssd --tier=live --from="$LP" --apply
  [ "$status" -eq 0 ]
  local planline applyline
  planline="$(grep -n -- '--plan' "$CS_TRACE" | head -1 | cut -d: -f1)"
  applyline="$(grep -n -- '--apply' "$CS_TRACE" | head -1 | cut -d: -f1)"
  [ -n "$planline" ]
  [ -n "$applyline" ]
  [ "$planline" -lt "$applyline" ]
}

@test "c12: a plan with no PLAN-SUMMARY refuses rather than writing blind" {
  CS_NO_SUMMARY=1 run env PATH="${STUB}:${PATH}" AUTO_CONFIRM=true CS_NO_SUMMARY=1 \
    bash "$MOODLE" content sync ssd --tier=live --from="$LP" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"No PLAN-SUMMARY"* ]]
  ! grep -q -- '--apply' "$CS_TRACE"
}

@test "c13: --apply always passes --backup= (no unrecorded overwrite)" {
  run cs ssd --tier=live --from="$LP" --apply
  [ "$status" -eq 0 ]
  grep -q -- '--backup=/tmp/nwp-content-sync-[0-9]*-[0-9]*/rollback.ndjson' "$CS_TRACE"
}

@test "c14: the rollback ledger is pulled back into sites/<site>/backups/" {
  run cs ssd --tier=live --from="$LP" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollback ledger:"* ]]
  local n
  n="$(find "${PROJECT_ROOT}/sites/ssd/backups" -name 'content-sync-live-*.ndjson' | wc -l)"
  [ "$n" -eq 1 ]
}

@test "c15: the reported absences are surfaced, not swallowed" {
  run cs ssd --tier=live --from="$LP" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"ABSENT A1.02"* ]]
  [[ "$output" == *"APPLY-SUMMARY"* ]]
}

@test "c16: the remote stage is cleaned up afterwards" {
  run cs ssd --tier=live --from="$LP" --apply
  [ "$status" -eq 0 ]
  grep -q 'rm -rf /tmp/nwp-content-sync-' "$CS_TRACE"
}

# ── the staged helper's own contract ─────────────────────────────────────────

@test "c17: the helper refuses --apply without --backup=" {
  run php "${REPO_ROOT}/scripts/moodle/content-sync-apply.php" --apply /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--backup"* ]]
}

@test "c18: the helper is syntactically valid PHP" {
  run php -l "${REPO_ROOT}/scripts/moodle/content-sync-apply.php"
  [ "$status" -eq 0 ]
}

@test "c19: the helper never contains a DELETE or INSERT against depthcontent" {
  run grep -nE "delete_records|insert_record" "${REPO_ROOT}/scripts/moodle/content-sync-apply.php"
  [ "$status" -ne 0 ]
}
