#!/usr/bin/env bats
################################################################################
# tests/unit/test-moodle-mail.bats — the declared mail identity and, above all,
# the REFUSAL.
#
# The four cases that matter are the four real faults found on live on
# 2026-08-01, each frozen here as a test that must stay red-if-broken:
#
#   admin@consumer.estatemail.net  a subdomain with no MX       -> REFUSE (b3)
#   noreply@consumer1.ddev.site    a dev domain on a live site  -> REFUSE (b1)
#   noreply@demo.ddev.site         the same leak on the demo    -> REFUSE (b2)
#   <unaliased>@estatemail.net     an estate address nobody
#                                  aliased = a silent black hole -> REFUSE (b6)
#
# Domains here are FIXTURES: the estate's real apex is deliberately not spelled
# out in a tracked file (the repo's gitleaks ruleset enforces that).
#
# Pure-logic only: no ddev, no ssh, no mysql, and no DNS — the resolver is
# injected through MOODLE_MAIL_MX_CMD so the whole gate runs offline.
################################################################################

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  TEST_TMP="$(mktemp -d)"
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/servers/nwpcode/email" "${PROJECT_ROOT}/sites/ss"

  # The estate's promise + the tracked baseline of the box's alias map.
  cat > "${PROJECT_ROOT}/servers/nwpcode/email/referenced-addresses.txt" <<'EOF'
# comment line
support@estatemail.net      # support address
ss@estatemail.net           # site from-address
demo-support@estatemail.net # demo tier
promised-but-unaliased@estatemail.net  # declared, never aliased
EOF
  cat > "${PROJECT_ROOT}/servers/nwpcode/email/postfix-virtual" <<'EOF'
# --- live map below (verbatim) ---
support@estatemail.net    forward-target@elsewhere.net
ss@estatemail.net    forward-target@elsewhere.net
demo-support@estatemail.net    forward-target@elsewhere.net
EOF

  # Injected resolver, mirroring the real zone's shape: the APEX has an MX,
  # its SUBDOMAINS have neither MX nor A, and aonly.net has an A only.
  cat > "${TEST_TMP}/mx" <<'EOF'
#!/bin/bash
case "$1:$2" in
  MX:estatemail.net)      echo "10 git.estatemail.net." ;;
  MX:otherco.net)      echo "5 mail.otherco.net." ;;
  A:aonly.net)         echo "203.0.113.9" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${TEST_TMP}/mx"
  export MOODLE_MAIL_MX_CMD="${TEST_TMP}/mx"

  source "${REPO_ROOT}/lib/moodle-mail.sh"
}

teardown() { rm -rf "${TEST_TMP}"; }

# --- a: syntax ---------------------------------------------------------------

@test "a1: a well-formed address passes the syntax check" {
  run moodle_mail_syntax_ok "support@estatemail.net"
  [ "$status" -eq 0 ]
}

@test "a2: junk is refused by the syntax check" {
  for bad in "" "nodomain" "@estatemail.net" "two@@estatemail.net" "a b@estatemail.net" "x@nodot"; do
    run moodle_mail_syntax_ok "$bad"
    [ "$status" -ne 0 ] || { echo "accepted junk: '$bad'"; return 1; }
  done
}

# --- b: THE REFUSALS (the four real faults) ----------------------------------

@test "b1: REFUSES noreply@consumer1.ddev.site — the dev-domain leak found on live real site" {
  run moodle_mail_validate "noreply@consumer1.ddev.site" "$PROJECT_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == REFUSE* ]]
  [[ "$output" == *"development/reserved domain"* ]]
}

@test "b2: REFUSES noreply@demo.ddev.site — the same leak on live demo site" {
  run moodle_mail_validate "noreply@demo.ddev.site" "$PROJECT_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"development/reserved domain"* ]]
}

@test "b3: REFUSES admin@consumer.estatemail.net — no MX, undeliverable by construction" {
  run moodle_mail_validate "admin@consumer.estatemail.net" "$PROJECT_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no MX and no A record"* ]]
}

@test "b4: REFUSES admin@demo.estatemail.net — the demo twin of the same fault" {
  run moodle_mail_validate "admin@demo.estatemail.net" "$PROJECT_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no MX and no A record"* ]]
}

@test "b5: every other dev/reserved suffix is refused too" {
  for bad in a@x.local a@x.test a@x.invalid a@x.example a@x.internal a@example.com; do
    run moodle_mail_validate "$bad" "$PROJECT_ROOT"
    [ "$status" -eq 1 ] || { echo "accepted dev domain: $bad"; return 1; }
  done
}

@test "b6: REFUSES an estate address that is declared but NOT aliased (black hole)" {
  run moodle_mail_validate "promised-but-unaliased@estatemail.net" "$PROJECT_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no alias in"* ]]
}

@test "b7: REFUSES an estate address nobody declared at all" {
  run moodle_mail_validate "invented@estatemail.net" "$PROJECT_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not declared in"* ]]
}

# --- c: the passes -----------------------------------------------------------

@test "c1: the chosen real-site addresses pass" {
  for good in support@estatemail.net ss@estatemail.net; do
    run moodle_mail_validate "$good" "$PROJECT_ROOT"
    [ "$status" -eq 0 ] || { echo "rejected: $good -> $output"; return 1; }
    [[ "$output" == OK:* ]]
  done
}

@test "c2: the chosen demo-tier address passes" {
  run moodle_mail_validate "demo-support@estatemail.net" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
}

@test "c3: a third-party domain with an MX passes without an alias requirement" {
  run moodle_mail_validate "someone@otherco.net" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
}

@test "c4: an A record with no MX is deliverable (RFC 5321 implicit MX)" {
  run moodle_mail_validate "someone@aonly.net" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
}

# --- d: CANNOT-VERIFY is never a pass ----------------------------------------

@test "d1: with no resolver on PATH the verdict is CANNOT-VERIFY (exit 2), not OK" {
  # A realistic degraded host: coreutils present, dig absent. The gate must
  # report that it could not look, never that the address is fine.
  mkdir -p "${TEST_TMP}/nodig"
  local t
  for t in tr grep sed awk cat wc; do
    ln -sf "$(command -v "$t")" "${TEST_TMP}/nodig/$t"
  done
  export MOODLE_MAIL_MX_CMD=""
  PATH="${TEST_TMP}/nodig" run moodle_mail_validate "x@otherco.net" "$PROJECT_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == CANNOT-VERIFY* ]]
  [[ "$output" == *"no resolver"* ]]
}

@test "d2: a manifest with no baseline is CANNOT-VERIFY, not a pass" {
  rm -f "${PROJECT_ROOT}/servers/nwpcode/email/postfix-virtual"
  run moodle_mail_validate "support@estatemail.net" "$PROJECT_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == CANNOT-VERIFY* ]]
}

# --- e: verdict --------------------------------------------------------------

@test "e1: verdict OK / DRIFT / UNSET" {
  run moodle_mail_verdict "a@b.org" "a@b.org"; [ "$status" -eq 0 ]; [ "$output" = "OK" ]
  run moodle_mail_verdict "a@b.org" "c@d.org"; [ "$status" -eq 1 ]; [ "$output" = "DRIFT" ]
  run moodle_mail_verdict "a@b.org" "";        [ "$status" -eq 1 ]; [ "$output" = "DRIFT" ]
  run moodle_mail_verdict ""        "c@d.org"; [ "$status" -eq 0 ]; [ "$output" = "UNSET" ]
}

@test "e2: the governed field set is exactly the three mail-identity settings" {
  [ "${#MOODLE_MAIL_FIELDS[@]}" -eq 3 ]
  printf '%s\n' "${MOODLE_MAIL_FIELDS[@]}" | grep -q '^support_email|supportemail$'
  printf '%s\n' "${MOODLE_MAIL_FIELDS[@]}" | grep -q '^support_name|supportname$'
  printf '%s\n' "${MOODLE_MAIL_FIELDS[@]}" | grep -q '^noreply_address|noreplyaddress$'
}

@test "e3: only the two address fields go through the deliverability gate" {
  run moodle_mail_field_is_address supportemail;    [ "$status" -eq 0 ]
  run moodle_mail_field_is_address noreplyaddress;  [ "$status" -eq 0 ]
  run moodle_mail_field_is_address supportname;     [ "$status" -ne 0 ]
}

# --- f: the verb refuses before it writes ------------------------------------

@test "f1: cmd_mail refuses a site with no mail: block rather than inventing one" {
  cat > "${PROJECT_ROOT}/sites/ss/.nwp.yml" <<'EOF'
schema_version: 2
project: { name: ss, type: moodle }
live: { enabled: true, domain: ss.estatemail.net, server_ip: 203.0.113.11, remote_path: /var/www/ssc }
EOF
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" mail ss --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"No mail: block declared"* ]]
}

@test "f2: cmd_mail REFUSES a declared address that cannot receive mail, before any ssh" {
  # The pre-repair live values, declared. The gate must stop at the declaration
  # and never reach the (unroutable TEST-NET-3) server.
  cat > "${PROJECT_ROOT}/sites/ss/.nwp.yml" <<'EOF'
schema_version: 2
project: { name: ss, type: moodle }
live: { enabled: true, domain: ss.estatemail.net, server_ip: 203.0.113.11, remote_path: /var/www/ssc }
mail:
  support_email: admin@consumer.estatemail.net
  noreply_address: noreply@consumer1.ddev.site
EOF
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" mail ss --tier=live --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"cannot receive mail"* ]]
  # It must have refused on the DECLARATION, not after trying to reach live.
  [[ "$output" != *"Target:"* ]]
}

@test "f3: --tier is mandatory and must be live" {
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" mail ss
  [ "$status" -ne 0 ]; [[ "$output" == *"--tier is required"* ]]
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" mail ss --tier=dev
  [ "$status" -ne 0 ]; [[ "$output" == *"--tier must be live"* ]]
}

# --- g: the golden tail ------------------------------------------------------

@test "g1: the golden tail is idempotent SQL naming only mdl_config" {
  source "${REPO_ROOT}/scripts/commands/moodle.sh"
  run _moodle_mail_tail ssd "supportemail=demo-support@estatemail.net" "noreplyaddress=ssd@estatemail.net"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ON DUPLICATE KEY UPDATE"* ]]
  [[ "$output" == *"INSERT INTO mdl_config (name,value) VALUES ('supportemail','demo-support@estatemail.net')"* ]]
  [[ "$output" == *">>> nwp:mail-identity ssd"* ]]
  [[ "$output" == *"<<< nwp:mail-identity"* ]]
  # It must not touch anything else — in particular never the mail-kill.
  [[ "$output" != *"noemailever"* ]]
  [[ "$output" != *"DELETE"* ]]
  [[ "$output" != *"DROP"* ]]
}

@test "g2: re-syncing a golden twice leaves exactly one managed block" {
  source "${REPO_ROOT}/scripts/commands/moodle.sh"
  local dir="${PROJECT_ROOT}/sites/ssd/demo-golden-live"
  mkdir -p "$dir"
  printf 'INSERT INTO mdl_config VALUES (1,%s,%s);\n' "'supportemail'" "'old@estatemail.net'" \
    | gzip -c > "$dir/golden.db.sql.gz"
  printf '{"type":"demo-golden","site":"ssd","db_sha256":"x"}\n' > "$dir/golden.manifest.json"

  _moodle_mail_sync_golden ssd "$dir" "supportemail=demo-support@estatemail.net" >/dev/null
  _moodle_mail_sync_golden ssd "$dir" "supportemail=demo-support@estatemail.net" >/dev/null

  run bash -c "gunzip -c '$dir/golden.db.sql.gz' | grep -c '>>> nwp:mail-identity'"
  [ "$output" -eq 1 ]
  run bash -c "gunzip -c '$dir/golden.db.sql.gz' | grep -c 'demo-support@estatemail.net'"
  [ "$output" -eq 1 ]
  # The original payload survives untouched.
  run bash -c "gunzip -c '$dir/golden.db.sql.gz' | grep -c \"old@estatemail.net\""
  [ "$output" -eq 1 ]
}

@test "g2b: the golden block is READ BACK verbatim — the '--' marker is not eaten as an option" {
  # REGRESSION: the first cut compared the block with `grep -qF "$marker"`.
  # The markers start with `--`, so grep took them for end-of-options, errored,
  # and reported GOLDEN-DRIFT on a golden that was actually correct — i.e. the
  # check silently could not see its own output. awk reads them literally.
  source "${REPO_ROOT}/scripts/commands/moodle.sh"
  local dir="${PROJECT_ROOT}/sites/ssd/demo-golden-live"
  mkdir -p "$dir"
  printf 'SELECT 1;\n' | gzip -c > "$dir/golden.db.sql.gz"

  local want; want="$(_moodle_mail_tail ssd "supportemail=demo-support@estatemail.net" "noreplyaddress=ssd@estatemail.net")"
  _moodle_mail_sync_golden ssd "$dir" "supportemail=demo-support@estatemail.net" "noreplyaddress=ssd@estatemail.net" >/dev/null

  run _moodle_mail_golden_block "$dir/golden.db.sql.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  [[ "$output" != *"unrecognized option"* ]]
}

@test "g2c: a golden with no managed block reads back empty (that is the DRIFT signal)" {
  source "${REPO_ROOT}/scripts/commands/moodle.sh"
  local dir="${PROJECT_ROOT}/sites/ssd/demo-golden-live"
  mkdir -p "$dir"
  printf 'SELECT 1;\n' | gzip -c > "$dir/golden.db.sql.gz"
  run _moodle_mail_golden_block "$dir/golden.db.sql.gz"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "g3: sync rewrites the sha256 sidecar and the manifest so staging still verifies" {
  source "${REPO_ROOT}/scripts/commands/moodle.sh"
  local dir="${PROJECT_ROOT}/sites/ssd/demo-golden-live"
  mkdir -p "$dir"
  printf 'SELECT 1;\n' | gzip -c > "$dir/golden.db.sql.gz"
  printf '{"type":"demo-golden","site":"ssd","db_sha256":"stale"}\n' > "$dir/golden.manifest.json"

  _moodle_mail_sync_golden ssd "$dir" "supportemail=demo-support@estatemail.net" >/dev/null

  run bash -c "cd '$dir' && sha256sum -c golden.db.sql.gz.sha256"
  [ "$status" -eq 0 ]
  if command -v jq >/dev/null 2>&1; then
    run bash -c "jq -r .db_sha256 '$dir/golden.manifest.json'"
    [ "$output" != "stale" ]
    [ "${#output}" -eq 64 ]
  fi
}
