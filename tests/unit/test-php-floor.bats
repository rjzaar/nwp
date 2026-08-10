#!/usr/bin/env bats
#
# tests/unit/test-php-floor.bats — `pl host apply <host> --kind=php`.
#
# THE DEFECT THIS GUARDS
# ----------------------
# The 2026-07-26 Moodle outage was a `max_input_vars` ceiling. The remedy was
# applied to PHP 8.3 while Moodle runs on 8.2, so it was never in force, and a
# grep for "max_input_vars" found 5000 and reported the matter closed.
# `pl server-state php-check` (item 7) made that RED. Nothing could make it
# GREEN: `pl host apply --execute` was disabled wholesale (CP-I6), so the
# declared `90-nwp-moodle.ini` carried a "NOT YET APPLIED" header for six days
# and then reached the live box by `scp` + `sudo cp` — no backup, no sha256, no
# post-write measurement, no rollback row.
#
# Every case below was RED on origin/main before this branch, for the plainest
# possible reason: `pl host apply … --execute` printed
# "not enabled in this release" and returned 1.
#
# HOW THE REMOTE SIDE IS TESTED
# -----------------------------
# With a FAKE BOX, not a mock of our own parser. The `ssh` stub on PATH
# interprets the real remote scripts this code emits against a directory tree
# under $BOX, and simulates PHP's conf.d scan the way PHP actually does it
# (alphabetical, last assignment wins). So these cases exercise the real argv
# construction, the real base64 transport and the real parse path; there is no
# production-code test hook that can go stale. The one thing the stub can be
# told to lie about is whether the setting TAKES — which is precisely the
# failure the verb exists to catch.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export REPO_ROOT
  PL="${REPO_ROOT}/pl"; export PL
  TMP="${BATS_TEST_TMPDIR}"; export TMP
  export STUBBIN="${TMP}/stubbin"; mkdir -p "$STUBBIN"
  export BOX="${TMP}/box"
  export SERVERS="${TMP}/servers"
  mkdir -p "$BOX" "$SERVERS/h1/php/conf.d" "$SERVERS/h1/system"

  cat > "${TMP}/manifest.yml" <<'EOF'
roles:
  ci-host:
    - stubhost
ssh_targets:
  stubhost:
    dest: tester@203.0.113.9
EOF
  export NWP_INSTANCE_MANIFEST="${TMP}/manifest.yml"
  export NWP_SERVERS_DIR="$SERVERS"

  _fake_box_ssh
  _declared_ini 5000
}

# The declared remedy, as it exists in the repo.
_declared_ini() {
  cat > "${SERVERS}/h1/php/conf.d/90-nwp-moodle.ini" <<EOF
; declared by nwp — do not edit on the box
max_input_vars = ${1}
EOF
}

# A two-SAPI inventory, the real shape of servers/{live,nwpcode}/system/.
_inventory() {
  local sapi_fpm="${1:-8.2/fpm}" sapi_cli="${2:-8.2/cli}" ini="${3:-php/conf.d/90-nwp-moodle.ini}"
  cat > "${SERVERS}/h1/system/inventory.yml" <<EOF
host: h1
ssh_role: ci-host
ssh_user: tester
php_floors:
  - sapi: "${sapi_fpm}"
    setting: max_input_vars
    min: 5000
    declared_ini: ${ini}
    why: "Moodle course edit forms; ss.conf -> php8.2-fpm.sock"
  - sapi: "${sapi_cli}"
    setting: max_input_vars
    min: 5000
    declared_ini: ${ini}
    why: "Moodle cron + admin/cli/upgrade.php"
artifacts: []
EOF
}

# Give the fake box a PHP version with both SAPIs present.
_box_php() {
  local v="${1:-8.2}"
  mkdir -p "${BOX}/etc/php/${v}/fpm/conf.d" "${BOX}/etc/php/${v}/cli/conf.d"
}

# ---------------------------------------------------------------------------
# The fake box. Interprets the remote scripts the code actually sends.
# ---------------------------------------------------------------------------
_fake_box_ssh() {
  cat > "${STUBBIN}/ssh" <<'STUB'
#!/usr/bin/env bash
# args: <ssh opts…> <dest> <remote-script>
script="${@: -1}"
printf '%s\n' "$script" >> "${TMP}/ssh.scripts"

_g() { sed -nE "s/^.*${1}='([^']*)'.*$/\1/p" <<< "$script" | head -1; }

# --- health probe --------------------------------------------------------
if [[ "$script" == *"NWPHEALTH"* ]]; then
  [ -f "${BOX}/unhealthy" ] && exit 1
  printf 'NWPHEALTH v1\nmem_total_mb=3915\nmem_avail_mb=2287\nswap_total_mb=2543\nswap_free_mb=2434\ndisk_avail_mb=46109\ndisk_pct=42\nload1=0.10\nnproc=2\n'
  exit 0
fi

# --- probe ---------------------------------------------------------------
if [[ "$script" == *"NWPPHPFLOOR v1"* ]]; then
  [ -f "${BOX}/unreachable" ] && exit 255
  V="$(_g V)"; S="$(_g S)"; T="$(_g T)"
  CD="${BOX}/etc/php/${V}/${S}/conf.d"
  printf 'NWPPHPFLOOR v1\n'
  printf 'confdir=/etc/php/%s/%s/conf.d\n' "$V" "$S"
  if [ -d "$CD" ]; then printf 'confdir_exists=yes\n'; else printf 'confdir_exists=no\n'; fi
  F="${BOX}${T}"
  if [ -f "$F" ]; then
    printf 'file_exists=yes\nfile_sha256=%s\n' "$(sha256sum "$F" | awk '{print $1}')"
  else
    printf 'file_exists=no\nfile_sha256=-\n'
  fi
  # Simulate PHP: no binary, or a forced reading, or an honest conf.d scan.
  if [ ! -d "$CD" ] || [ -f "${BOX}/nophp" ]; then
    printf 'binary=-\nvalue=-\n'
  elif [ -f "${BOX}/force-value" ]; then
    printf 'binary=/usr/bin/php%s\nvalue=%s\n' "$V" "$(cat "${BOX}/force-value")"
  else
    val=1000
    for f in $(ls "$CD" 2>/dev/null | sort); do
      n="$(sed -nE 's/^[[:space:]]*max_input_vars[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "${CD}/${f}" | tail -1)"
      [ -n "$n" ] && val="$n"
    done
    printf 'binary=/usr/bin/php%s\nvalue=%s\n' "$V" "$val"
  fi
  if [ "$S" = fpm ]; then printf 'service=php%s-fpm\nservice_exists=yes\n' "$V"
  else printf 'service=-\nservice_exists=-\n'; fi
  printf '==NWPPHPFLOOR-FILE==\n'
  [ -f "$F" ] && cat "$F"
  exit 0
fi

# --- write ---------------------------------------------------------------
if [[ "$script" == *"installed_sha256"* ]]; then
  T="$(_g T)"; BK="$(_g BK)"
  b64="$(sed -nE "s/^printf '%s' '([A-Za-z0-9+\/=]*)'.*$/\1/p" <<< "$script" | head -1)"
  F="${BOX}${T}"
  [ -d "$(dirname "$F")" ] || { printf 'ERR confdir-missing\n'; exit 5; }
  if [ -f "$F" ]; then
    mkdir -p "${BOX}$(dirname "$BK")"; cp -a "$F" "${BOX}${BK}"
    printf 'backup=%s\nbackup_sha256=%s\n' "$BK" "$(sha256sum "${BOX}${BK}" | awk '{print $1}')"
  else
    printf 'backup=-\nbackup_sha256=-\n'
  fi
  printf '%s' "$b64" | base64 -d > "$F" || { printf 'ERR decode-failed\n'; exit 7; }
  printf 'installed=%s\ninstalled_sha256=%s\n' "$T" "$(sha256sum "$F" | awk '{print $1}')"
  exit 0
fi

# --- reload --------------------------------------------------------------
if [[ "$script" == *"systemctl reload"* ]]; then
  svc="$(sed -nE "s/^.*systemctl reload '([^']*)'.*$/\1/p" <<< "$script" | head -1)"
  if [ -f "${BOX}/reload-fails" ]; then printf 'ERR reload-failed %s\n' "$svc"; exit 3; fi
  printf 'reloaded=%s\n' "$svc"; echo "$svc" >> "${TMP}/reloads"
  exit 0
fi

# --- restore -------------------------------------------------------------
if [[ "$script" == *"restored="* ]]; then
  T="$(_g T)"; BK="$(_g BK)"
  if [ "$BK" != "-" ] && [ -f "${BOX}${BK}" ]; then
    cp -a "${BOX}${BK}" "${BOX}${T}"; printf 'restored=%s\n' "$T"
  else
    rm -f "${BOX}${T}"; printf 'removed=%s\n' "$T"
  fi
  exit 0
fi

printf 'UNHANDLED REMOTE SCRIPT\n' >&2
exit 99
STUB
  chmod +x "${STUBBIN}/ssh"
}

_apply() { PATH="${STUBBIN}:$PATH" run "$PL" host apply h1 --kind=php "$@"; }

# Count the write scripts the code sent (0 == nothing was written).
# NB `grep -c` prints 0 AND exits 1 on no-match, so a naive `|| echo 0` emits
# "0\n0" and every comparison becomes a syntax error that reads like a failure.
_writes() {
  [ -f "${TMP}/ssh.scripts" ] || { echo 0; return 0; }
  grep -c 'installed_sha256' "${TMP}/ssh.scripts" || true
}

################################################################################
# 1. DRY RUN IS THE DEFAULT AND IT WRITES NOTHING.
################################################################################

@test "dry-run reports the below-floor SAPI and sends NO write to the host" {
  _inventory; _box_php 8.2
  _apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"BELOW-FLOOR"* ]]
  [[ "$output" == *"8.2/fpm"* ]]
  [[ "$output" == *"8.2/cli"* ]]
  [[ "$output" == *"DRY RUN"* ]]
  [ "$(_writes)" -eq 0 ]
  [ ! -f "${BOX}/etc/php/8.2/fpm/conf.d/90-nwp-moodle.ini" ]
}

@test "dry-run prints the exact per-SAPI diff between the box and the declared ini" {
  _inventory; _box_php 8.2
  # The box carries a DIFFERENT file that happens to satisfy the floor — the
  # 2026-08-01 hand-placed-by-scp shape.
  printf '; placed by hand\nmax_input_vars = 5000\n' \
    > "${BOX}/etc/php/8.2/fpm/conf.d/90-nwp-moodle.ini"
  printf '; placed by hand\nmax_input_vars = 5000\n' \
    > "${BOX}/etc/php/8.2/cli/conf.d/90-nwp-moodle.ini"
  _apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"FILE-DRIFT"* ]]
  [[ "$output" == *"/etc/php/8.2/fpm/conf.d/90-nwp-moodle.ini"* ]]
  [[ "$output" == *"-; placed by hand"* ]]
  [[ "$output" == *"+; declared by nwp"* ]]
  [ "$(_writes)" -eq 0 ]
}

################################################################################
# 2. --execute: write, back up, reload once, RE-MEASURE.
################################################################################

@test "--execute installs the floor on BOTH 8.2 SAPIs and re-measures it in force" {
  _inventory; _box_php 8.2
  _apply --execute -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"Post-apply verification"* ]]
  [[ "$output" == *"8.2/fpm max_input_vars=5000"* ]]
  [[ "$output" == *"8.2/cli max_input_vars=5000"* ]]
  grep -q 'max_input_vars = 5000' "${BOX}/etc/php/8.2/fpm/conf.d/90-nwp-moodle.ini"
  grep -q 'max_input_vars = 5000' "${BOX}/etc/php/8.2/cli/conf.d/90-nwp-moodle.ini"
  # fpm reloaded ONCE; the cli SAPI has no service to reload.
  [ "$(grep -c 'php8.2-fpm' "${TMP}/reloads")" -eq 1 ]
}

@test "--execute replaces a hand-placed file and BACKS IT UP with a sha256" {
  _inventory; _box_php 8.2
  printf '; placed by hand\nmax_input_vars = 5000\n' \
    > "${BOX}/etc/php/8.2/fpm/conf.d/90-nwp-moodle.ini"
  _apply --execute -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup: /var/backups/nwp-php-floor/"* ]]
  [[ "$output" == *"sha256"* ]]
  # The replaced bytes really are preserved on the box.
  local bak
  bak="$(find "${BOX}/var/backups/nwp-php-floor" -name '*.bak' | head -1)"
  [ -n "$bak" ]
  grep -q 'placed by hand' "$bak"
}

################################################################################
# 3. IDEMPOTENCE. This is what "bring the hand-placed file under management"
#    has to mean: a second run must recognise its own work and do nothing.
################################################################################

@test "apply is IDEMPOTENT — a second run reports in-sync and writes nothing" {
  _inventory; _box_php 8.2
  _apply --execute -y
  [ "$status" -eq 0 ]
  local first; first="$(_writes)"
  [ "$first" -eq 2 ]

  _apply --execute -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"IN-SYNC"* ]]
  [[ "$output" == *"nothing to apply"* ]]
  # No SECOND round of writes, and no second reload.
  [ "$(_writes)" -eq "$first" ]
  [ "$(grep -c 'php8.2-fpm' "${TMP}/reloads")" -eq 1 ]
}

@test "dry-run after apply is clean and exits 0 without touching the host" {
  _inventory; _box_php 8.2
  _apply --execute -y
  [ "$status" -eq 0 ]
  local before; before="$(_writes)"
  _apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"IN-SYNC"* ]]
  [[ "$output" != *"DRY RUN"* ]]
  [ "$(_writes)" -eq "$before" ]
}

################################################################################
# 4. THE HEADLINE HONESTY CASE. A write that lands but does not take must NOT
#    be reported as success. Without this, the verb reproduces the original
#    2026-07-26 defect with better manners.
################################################################################

@test "post-apply verification CATCHES a floor that did not take, and fails" {
  _inventory; _box_php 8.2
  # The file writes fine; the SAPI keeps reporting the default (a conf.d PHP
  # does not scan, a stale opcache, a fpm that ignored the reload).
  echo 1000 > "${BOX}/force-value"
  _apply --execute -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"DID-NOT-TAKE"* ]]
  [[ "$output" == *"NOT in force after apply"* ]]
  [[ "$output" != *"applied and RE-MEASURED in force"* ]]
  # It still wrote the file — and it still tells you how to undo it.
  [[ "$output" == *"Undo: sudo rm -f /etc/php/8.2/fpm/conf.d/90-nwp-moodle.ini"* ]]
}

################################################################################
# 5. THE PHP-MINOR-UPGRADE REGRESSION, named in the declared ini's own header:
#    an upgrade moves /etc/php/8.2/… and the remedy silently stops existing.
#    Both the verb and the independent assertion must go RED on the same
#    inventory — that agreement is the point.
################################################################################

@test "conf.d moved by a PHP upgrade: apply REFUSES with SAPI-ABSENT (exit 4)" {
  _inventory              # declares 8.2/fpm + 8.2/cli
  _box_php 8.4            # the box now only has 8.4
  _apply
  [ "$status" -eq 4 ]
  [[ "$output" == *"SAPI-ABSENT"* ]]
  [[ "$output" == *"/etc/php/8.2/fpm/conf.d does not exist"* ]]
  [[ "$output" == *"update php_floors[].sapi"* ]]
  [ "$(_writes)" -eq 0 ]
}

@test "conf.d moved by a PHP upgrade: apply NEVER creates the missing conf.d dir" {
  _inventory; _box_php 8.4
  _apply --execute -y
  [ "$status" -eq 4 ]
  [ ! -d "${BOX}/etc/php/8.2" ]
}

@test "php-check goes RED on the SAME inventory when the SAPI is gone (the verbs agree)" {
  _inventory
  local fetch="${TMP}/fetch.sh"
  cat > "$fetch" <<'EOF'
#!/bin/bash
printf '8.4/fpm max_input_vars=1000\n8.4/cli max_input_vars=1000\n'
EOF
  chmod +x "$fetch"
  NWP_SERVER_STATE_ROOT="$SERVERS/.." NWP_SERVER_STATE_FETCH="$fetch" \
    run "$PL" server-state php-check h1
  [ "$status" -ne 0 ]
  [[ "$output" == *"BELOW-FLOOR"* ]]
  [[ "$output" == *"8.2/fpm"* ]]
}

@test "php-check goes GREEN on the SAME inventory once the declared floor is applied" {
  _inventory
  local fetch="${TMP}/fetch.sh"
  cat > "$fetch" <<'EOF'
#!/bin/bash
printf '8.2/fpm max_input_vars=5000\n8.2/cli max_input_vars=5000\n'
EOF
  chmod +x "$fetch"
  NWP_SERVER_STATE_ROOT="$SERVERS/.." NWP_SERVER_STATE_FETCH="$fetch" \
    run "$PL" server-state php-check h1
  [ "$status" -eq 0 ]
}

################################################################################
# 6. BLINDNESS IS NEVER "IN FORCE". Three separate shapes, three refusals.
################################################################################

@test "a value that cannot be measured is CANNOT-MEASURE (exit 3), never applied" {
  _inventory; _box_php 8.2
  touch "${BOX}/nophp"          # conf.d exists, no interpreter to ask
  _apply --execute -y
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-MEASURE"* ]]
  [[ "$output" == *"blindness is not 'in force'"* ]]
  [ "$(_writes)" -eq 0 ]
}

@test "an unreachable host is UNREACHABLE (exit 3), not 'nothing to apply'" {
  _inventory; _box_php 8.2
  touch "${BOX}/unreachable"
  _apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"UNREACHABLE"* ]]
  [[ "$output" != *"nothing to apply"* ]]
}

@test "--execute REFUSES on a host with no measurable headroom (the OOM preflight)" {
  _inventory; _box_php 8.2
  touch "${BOX}/unhealthy"
  _apply --execute -y
  [ "$status" -eq 3 ]
  [[ "$output" == *"no measurable headroom"* || "$output" == *"REFUSING"* ]]
  [ "$(_writes)" -eq 0 ]
}

################################################################################
# 7. A FAILED RELOAD IS ROLLED BACK. A box left with a config its service
#    refused is worse than the ceiling we came to fix.
################################################################################

@test "a failed reload restores the previous conf.d file and fails loudly" {
  _inventory; _box_php 8.2
  printf '; placed by hand\nmax_input_vars = 5000\n' \
    > "${BOX}/etc/php/8.2/fpm/conf.d/90-nwp-moodle.ini"
  touch "${BOX}/reload-fails"
  _apply --execute -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"RELOAD-FAILED"* ]]
  [[ "$output" == *"restored"* ]]
  grep -q 'placed by hand' "${BOX}/etc/php/8.2/fpm/conf.d/90-nwp-moodle.ini"
}

################################################################################
# 8. THE DECLARATION IS THE ONLY THING INTERPOLATED INTO A REMOTE SHELL, so a
#    malformed one must refuse rather than build a command out of it.
################################################################################

@test "a malformed sapi is BAD-DECLARATION (exit 2) and reaches no remote shell" {
  _inventory '8.2/fpm; rm -rf /' '8.2/cli'
  _box_php 8.2
  _apply --execute -y
  [ "$status" -eq 2 ]
  [[ "$output" == *"BAD-DECLARATION"* ]]
  [ ! -f "${TMP}/ssh.scripts" ] || ! grep -q 'rm -rf /' "${TMP}/ssh.scripts"
}

@test "a declared_ini that is not in the repo is DECLARED-INI-MISSING (exit 2)" {
  _inventory '8.2/fpm' '8.2/cli' 'php/conf.d/does-not-exist.ini'
  _box_php 8.2
  _apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"DECLARED-INI-MISSING"* ]]
  [ "$(_writes)" -eq 0 ]
}

################################################################################
# 9. The estate's own declarations must be usable by the verb, not just by a
#    fixture. A declared_ini that names a file nobody committed is the failure
#    mode this whole item is about.
################################################################################

# _inventory_roots — every server tree this machine can see holding an
# inventory: the shipped fixture ALWAYS, plus the real servers/ captures WHEN
# PRESENT. The real inventories moved into the private per-server repos
# (ops#326 tranche 3), so a CI clone has none and this predicate would pass
# over zero declarations — which the non-vacuity guard below rightly refuses
# to score as a pass. Same shape as test-nginx-versioning's capture handling.
_inventory_roots() {
  printf '%s\n' "${REPO_ROOT}/tests/fixtures/server-inventory"
  local real="${NWP_SERVERS_DIR:-${REPO_ROOT}/servers}"
  [ -d "$real" ] && printf '%s\n' "$real"
  return 0
}

@test "every php_floors declared_ini actually exists beside its inventory" {
  local root inv host ini n i found=0
  while IFS= read -r root; do
  for inv in "$root"/*/system/inventory.yml; do
    [ -e "$inv" ] || continue
    host="$(dirname "$(dirname "$inv")")"
    n="$(yq e '.php_floors // [] | length' "$inv")"
    for ((i = 0; i < n; i++)); do
      ini="$(i="$i" yq e ".php_floors[strenv(i)|tonumber].declared_ini // \"\"" "$inv")"
      [ -n "$ini" ] || continue
      found=$((found + 1))
      [ -f "${host}/${ini}" ] \
        || { echo "${host}/${ini} declared but missing" >&2; return 1; }
    done
  done
  done < <(_inventory_roots)
  # Non-vacuity: a pass over zero declarations is not a pass. The shipped
  # fixture guarantees four on any checkout, so this can only trip if the
  # fixture itself is lost — which is the thing worth being told about.
  [ "$found" -ge 4 ]
}

@test "the shipped inventory fixture exists — the declared_ini check is never vacuous" {
  [ -f "${REPO_ROOT}/tests/fixtures/server-inventory/probehost/system/inventory.yml" ]
  run yq e '.php_floors | length' "${REPO_ROOT}/tests/fixtures/server-inventory/probehost/system/inventory.yml"
  [ "$output" -ge 4 ]
}
