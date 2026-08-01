#!/usr/bin/env bats
# `pl moodle course restore` — guarded bulk course import from .mbz backups
# (scripts/commands/moodle.sh cmd_course_restore).
#
# The load-bearing guards, each observed RED against the pre-fix tree (the verb
# did not exist; the operation was hand scp + ssh restore_backup.php):
#
#   1. name guard      — only backup-moodle2-course-*.mbz, no traversal shapes,
#                        no symlinks, no shell-hostile names (names are embedded
#                        in remote command lines).
#   2. PII fail-close  — moodle_backup.xml parsed LOCALLY before any byte
#                        ships; users=1 or a MISSING users setting refuses the
#                        whole run unless anonymize=1.
#   3. dry-run default — a plain invocation executes NOTHING remote (no ssh, no
#                        scp; asserted via PATH stubs + trace).
#   4. category map    — shortname-prefix → category name; an unmapped
#                        shortname is a refusal, never a silent default.
#   5. idempotency     — shortnames already on the target are skipped via a
#                        staged read-only query; a second run plans 0 restores.
#
# NO network, NO real ssh: ssh/scp are PATH stubs writing to a trace file; the
# stub "box" answers sha256sum from a fake home so the verified-push contract
# is exercised for real.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  MOODLE="${REPO_ROOT}/scripts/commands/moodle.sh"
  MAKE_MBZ="${REPO_ROOT}/tests/fixtures/mbz/make-mbz.sh"
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  export NWP_SSH_NO_MULTIPLEX=1
  mkdir -p "${PROJECT_ROOT}/sites/ssd/dev"

  # Fixture Moodle site with a live tier (TEST-NET-3 IP; nothing ever connects
  # — the ssh/scp on PATH are stubs in every test that reaches them).
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

  # The four-rail category map (the real use case).
  MAP="${TEST_TMP}/rails.map"
  cat > "$MAP" <<'EOF'
# shortname-prefix = category
b = Your Yes
c = Prayer & Recollection
d = Ascesis
e = Sacraments
EOF

  # Clean mbz set: one course per rail.
  MBZ="${TEST_TMP}/mbz"
  mkdir -p "$MBZ"
  bash "$MAKE_MBZ" "${MBZ}/backup-moodle2-course-10-b1-20260711-1749-nu.mbz" B1 0
  bash "$MAKE_MBZ" "${MBZ}/backup-moodle2-course-16-c1-20260711-1749-nu.mbz" C1 0
  bash "$MAKE_MBZ" "${MBZ}/backup-moodle2-course-21-d1-20260711-1749-nu.mbz" D1 0
  bash "$MAKE_MBZ" "${MBZ}/backup-moodle2-course-27-e1-20260711-1749-nu.mbz" E1 0

  # --- ssh/scp stubs + fake box -------------------------------------------
  STUB="${TEST_TMP}/stub"
  export CR_TRACE="${TEST_TMP}/trace.txt"
  export CR_FAKEHOME="${TEST_TMP}/fakehome"
  export CR_EXISTING="${TEST_TMP}/existing-shortnames.txt"
  mkdir -p "$STUB" "$CR_FAKEHOME"
  : > "$CR_TRACE"
  : > "$CR_EXISTING"

  cat > "${STUB}/ssh" <<'SSH'
#!/bin/bash
# Drain stdin like real ssh does — this is what catches a runner that forgets
# </dev/null inside a read loop (the ssd rehearsal bug: only 1 of 3 categories
# resolved because ssh/ddev-exec ate the loop's remaining stdin).
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
printf 'SSH %s\n' "$cmd" >> "$CR_TRACE"
case "$cmd" in
  *sha256sum*)
    n="$(printf '%s' "$cmd" | grep -o '~/[A-Za-z0-9._-]*' | head -1)"; n="${n#\~/}"
    sha256sum "$CR_FAKEHOME/$n" 2>/dev/null | awk '{print $1}' ;;
  *--list-shortnames*)    cat "$CR_EXISTING" ;;
  *--ensure-category=*)   echo "CATID 42" ;;
  *restore_backup.php*)   echo "RESTORE-DONE" ;;
  *--enable-self-enrol*)  echo "ENROL-OK stub" ;;
  *--assert-enterable*)
    if [ -n "${CR_ENTER_FAIL:-}" ]; then echo "ENTER-FAIL stub:no-self-enrol"; exit 1; fi
    echo "ENTER-OK stub" ;;
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
printf 'SCP %s -> %s\n' "${args[0]}" "${args[1]}" >> "$CR_TRACE"
cp "${args[0]}" "$CR_FAKEHOME/${args[1]#*:}"
SCP
  chmod +x "${STUB}/ssh" "${STUB}/scp"
}

teardown() { rm -rf "${TEST_TMP}"; }

# Run the verb with stubs on PATH (used by every test; dry-run tests then
# assert the stubs were NEVER called).
cr() {
  env PATH="${STUB}:${PATH}" AUTO_CONFIRM=true bash "$MOODLE" course restore "$@"
}

# ── guard 1: filename / traversal ────────────────────────────────────────────

@test "r1: a matching name containing '..' refuses the WHOLE run (traversal shape)" {
  bash "$MAKE_MBZ" "${MBZ}/backup-moodle2-course-..evil.mbz" X1 0
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"traversal"* ]]
}

@test "r2: non-matching filenames are never candidates; a dir with none refuses" {
  local d="${TEST_TMP}/other"; mkdir -p "$d"
  echo x > "${d}/evil.php"
  echo x > "${d}/course.mbz"
  run cr ssd --tier=live --from="$d" --category-map="$MAP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"No backup-moodle2-course-"* ]]
}

@test "r3: a symlinked mbz is not accepted as a candidate" {
  local d="${TEST_TMP}/links"; mkdir -p "$d"
  ln -s "${MBZ}/backup-moodle2-course-10-b1-20260711-1749-nu.mbz" \
        "${d}/backup-moodle2-course-10-b1-20260711-1749-nu.mbz"
  run cr ssd --tier=live --from="$d" --category-map="$MAP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"No backup-moodle2-course-"* ]]
}

# ── guard 2: PII fail-close ──────────────────────────────────────────────────

@test "r4: an mbz with users=1 refuses the run (PII fail-close)" {
  bash "$MAKE_MBZ" "${MBZ}/backup-moodle2-course-99-x1-20260711-1749.mbz" X1 1
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"user data"* ]]
  [[ "$output" == *"users=1"* ]]
}

@test "r5: an mbz with NO users setting refuses (unprovable is not shippable)" {
  bash "$MAKE_MBZ" "${MBZ}/backup-moodle2-course-98-y1-20260711-1749.mbz" Y1 missing
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no root-level 'users' setting"* ]]
}

@test "r6: anonymize=1 lifts the users guard (anonymised backups are shippable)" {
  local d="${TEST_TMP}/anon"; mkdir -p "$d"
  bash "$MAKE_MBZ" "${d}/backup-moodle2-course-97-b9-20260711-1749-an.mbz" B9 anon
  run cr ssd --tier=live --from="$d" --category-map="$MAP" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"B9"* ]]
  [[ "$output" == *"[dry-run]"* ]]
}

# ── guard 3: dry-run default, executes nothing ───────────────────────────────

@test "r7: dry-run is the DEFAULT and makes zero ssh/scp calls (stub trace empty)" {
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"4 restore(s) planned"* ]]
  # The stubs log every invocation; a dry run must have logged NONE.
  [ ! -s "$CR_TRACE" ]
}

# ── guard 4: category map ────────────────────────────────────────────────────

@test "r8: the four-rail map is parsed and applied per shortname prefix" {
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Your Yes"* ]]
  [[ "$output" == *"Prayer & Recollection"* ]]
  [[ "$output" == *"Ascesis"* ]]
  [[ "$output" == *"Sacraments"* ]]
}

@test "r9: a shortname no prefix matches is a REFUSAL, not a silent default" {
  bash "$MAKE_MBZ" "${MBZ}/backup-moodle2-course-96-z1-20260711-1749-nu.mbz" Z9 0
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"matches no prefix"* ]]
}

@test "r10: --category and --category-map are mutually exclusive; neither is a refusal" {
  run cr ssd --tier=live --from="$MBZ" --category=X --category-map="$MAP" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
  run cr ssd --tier=live --from="$MBZ" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--category"* ]]
}

# ── guard 5: idempotency + apply plumbing (stubbed box) ──────────────────────

@test "r11: apply restores each course once, with the resolved categoryid" {
  echo "SHORTNAME B1" > "$CR_EXISTING"   # B1 already on the target
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"*"B1"* ]]
  [[ "$output" == *"3 of 4 course(s) to restore"* ]]
  [ "$(grep -c 'restore_backup.php' "$CR_TRACE")" -eq 3 ]
  grep -q -- '--categoryid=42' "$CR_TRACE"
  # verified push really happened (scp + remote sha check) before any restore
  grep -q '^SCP ' "$CR_TRACE"
  grep -q 'sha256sum' "$CR_TRACE"
  # post-pass ran
  grep -q -- '--assert-enterable' "$CR_TRACE"
  # and WITHOUT the opt-in flag, no enrolment write happens
  ! grep -q -- '--enable-self-enrol' "$CR_TRACE"
}

@test "r12: IDEMPOTENT — a second run against a fully-populated target plans 0 restores" {
  printf 'SHORTNAME B1\nSHORTNAME C1\nSHORTNAME D1\nSHORTNAME E1\n' > "$CR_EXISTING"
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 restores to perform"* ]]
  ! grep -q 'restore_backup.php' "$CR_TRACE"
}

# ── --enable-self-enrol (explicit opt-in; ssd rehearsal finding) ─────────────

@test "r14: flag ABSENT — a failing enterability post-pass fails the verb loudly" {
  # This is the rehearsal outcome pinned as a test: restore_backup.php brings
  # courses up without enabled self-enrol; without the opt-in flag the verb
  # must exit non-zero and say why, never quietly ship a locked demo.
  export CR_ENTER_FAIL=1
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENTER-FAIL"* ]]
  [[ "$output" == *"enterability assertion FAILED"* ]]
  ! grep -q -- '--enable-self-enrol' "$CR_TRACE"
}

@test "r15: flag PRESENT — the enable step runs on exactly the courses THIS run restored" {
  echo "SHORTNAME B1" > "$CR_EXISTING"   # B1 pre-exists: must NOT be retrofitted
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --apply --enable-self-enrol
  [ "$status" -eq 0 ]
  local line
  line="$(grep -- '--enable-self-enrol' "$CR_TRACE")"
  [ -n "$line" ]
  [[ "$line" == *"C1"* ]]
  [[ "$line" == *"D1"* ]]
  [[ "$line" == *"E1"* ]]
  [[ "$line" != *"B1"* ]]
  # enable runs BEFORE the post-pass assertion
  [ "$(grep -n -- '--enable-self-enrol' "$CR_TRACE" | cut -d: -f1)" \
    -lt "$(grep -n -- '--assert-enterable' "$CR_TRACE" | cut -d: -f1)" ]
}

@test "r16: flag + dry-run — prints WOULD-enable, still executes nothing" {
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --dry-run --enable-self-enrol
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD enable"* ]]
  [[ "$output" == *"[dry-run]"* ]]
  [ ! -s "$CR_TRACE" ]
}

@test "r17: flag + fully-populated target — 0 restores means 0 enrol writes (no retrofit)" {
  printf 'SHORTNAME B1\nSHORTNAME C1\nSHORTNAME D1\nSHORTNAME E1\n' > "$CR_EXISTING"
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --apply --enable-self-enrol
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 restores to perform"* ]]
  ! grep -q -- '--enable-self-enrol' "$CR_TRACE"
}

@test "r13: an unreadable shortname enumeration refuses to restore blind" {
  # Make the list-shortnames leg fail: replace the ssh stub with one that
  # errors on that command only.
  cat > "${STUB}/ssh" <<'SSH'
#!/bin/bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in -o|-i) shift 2 ;; -*) shift ;; *) args+=("$1"); shift ;; esac
done
cmd="${args[*]:1}"
printf 'SSH %s\n' "$cmd" >> "$CR_TRACE"
case "$cmd" in
  *sha256sum*)
    n="$(printf '%s' "$cmd" | grep -o '~/[A-Za-z0-9._-]*' | head -1)"; n="${n#\~/}"
    sha256sum "$CR_FAKEHOME/$n" 2>/dev/null | awk '{print $1}' ;;
  *--list-shortnames*) exit 255 ;;
  *) : ;;
esac
exit 0
SSH
  chmod +x "${STUB}/ssh"
  run cr ssd --tier=live --from="$MBZ" --category-map="$MAP" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to restore blind"* ]]
  ! grep -q 'restore_backup.php' "$CR_TRACE"
}
