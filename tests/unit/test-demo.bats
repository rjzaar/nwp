#!/usr/bin/env bats
# ops#133 Phase 1 — daily-reset demo tier: lib/demo.sh + scripts/commands/demo.sh.
#
# Pure-logic + static tests only: no ddev/drush is ever invoked (a real reset
# is destructive and needs a live site). The idle/floor/codes/manifest logic
# is exercised directly; the reset ORDERING guarantees (harvest before wipe,
# exit-3 on active) are asserted statically against the command script.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  source "${REPO_ROOT}/lib/demo.sh"
  DEMO_CMD="${REPO_ROOT}/scripts/commands/demo.sh"
  PL="${REPO_ROOT}/pl"
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset PROJECT_ROOT
}

# --- dispatch -----------------------------------------------------------------

@test "pl dispatches 'demo' to demo.sh (help renders)" {
  run "$PL" demo --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"daily-reset demo tier"* ]]
  [[ "$output" == *"golden <site>"* ]]
}

@test "demo.sh refuses an unknown subcommand" {
  run bash "$DEMO_CMD" no-such-verb demo1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown subcommand"* ]]
}

@test "demo.sh refuses --tier=live in Phase 1 (fail-closed)" {
  run bash "$DEMO_CMD" status demo1 --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
}

# --- durations / idle guard ---------------------------------------------------

@test "demo_parse_duration handles s/m/h/d" {
  [ "$(demo_parse_duration 90s)" -eq 90 ]
  [ "$(demo_parse_duration 30m)" -eq 1800 ]
  [ "$(demo_parse_duration 2h)"  -eq 7200 ]
  [ "$(demo_parse_duration 14d)" -eq 1209600 ]
}

@test "demo_parse_duration fails closed on garbage" {
  run demo_parse_duration "30 minutes"
  [ "$status" -ne 0 ]
  run demo_parse_duration ""
  [ "$status" -ne 0 ]
  run demo_parse_duration "-5m"
  [ "$status" -ne 0 ]
}

@test "demo_idle_ok: idle beyond the window → ok to reset" {
  # newest activity 31 min ago, window 30 min
  demo_idle_ok "$(( 100000 - 1860 ))" 1800 100000
}

@test "demo_idle_ok: activity within the window → NOT ok" {
  run demo_idle_ok "$(( 100000 - 60 ))" 1800 100000
  [ "$status" -ne 0 ]
}

@test "demo_idle_ok fails closed on a garbled sessions result" {
  # a failed sqlq (empty / error text) must read as ACTIVE, never as idle
  run demo_idle_ok "" 1800 100000
  [ "$status" -ne 0 ]
  run demo_idle_ok "error: no such table" 1800 100000
  [ "$status" -ne 0 ]
}

@test "reset maps 'active' to the distinct retryable exit code 3" {
  [ "$DEMO_EXIT_ACTIVE" -eq 3 ]
  # the active path in cmd_reset must return DEMO_EXIT_ACTIVE, not 1
  grep -q 'return "\$DEMO_EXIT_ACTIVE"' "$DEMO_CMD"
}

# --- 04:00 floor --------------------------------------------------------------

@test "demo_past_floor: before/at/after the 04:00 floor" {
  run demo_past_floor "03:59" "04:00"; [ "$status" -ne 0 ]
  demo_past_floor "04:00" "04:00"
  demo_past_floor "04:30" "04:00"
}

@test "demo_past_floor fails closed on a malformed clock reading" {
  run demo_past_floor "4am" "04:00"
  [ "$status" -ne 0 ]
}

# --- golden manifest + sha256 -------------------------------------------------

make_golden() {
  GDIR="$(demo_golden_dir demo1)"
  mkdir -p "$GDIR"
  echo "fake-db-dump" > "$GDIR/golden.db.sql.gz"
  echo "fake-files-tar" > "$GDIR/golden.files.tar.gz"
  ( cd "$GDIR" && sha256sum golden.db.sql.gz > golden.db.sql.gz.sha256 \
               && sha256sum golden.files.tar.gz > golden.files.tar.gz.sha256 )
}

@test "golden manifest is written with both artifact sha256s and verifies" {
  make_golden
  demo_manifest_write "$GDIR" demo1 golden.db.sql.gz golden.files.tar.gz
  [ -s "$GDIR/golden.manifest.json" ]
  jq -e '.type == "demo-golden" and .site == "demo1"' "$GDIR/golden.manifest.json"
  jq -e '.db_sha256 | test("^[0-9a-f]{64}$")' "$GDIR/golden.manifest.json"
  demo_golden_verify "$GDIR" demo1
}

@test "manifest write refuses when a sidecar is missing (fail-closed)" {
  make_golden
  rm "$GDIR/golden.files.tar.gz.sha256"
  run demo_manifest_write "$GDIR" demo1 golden.db.sql.gz golden.files.tar.gz
  [ "$status" -ne 0 ]
}

@test "golden verify refuses a corrupted artifact" {
  make_golden
  demo_manifest_write "$GDIR" demo1 golden.db.sql.gz golden.files.tar.gz
  echo "tampered" >> "$GDIR/golden.db.sql.gz"
  run demo_golden_verify "$GDIR" demo1
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISMATCH"* ]]
}

@test "golden verify refuses a manifest captured for a DIFFERENT site" {
  make_golden
  demo_manifest_write "$GDIR" demo1 golden.db.sql.gz golden.files.tar.gz
  run demo_golden_verify "$GDIR" some-other-site
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing"* ]]
}

@test "golden verify refuses when no golden exists at all" {
  run demo_golden_verify "$(demo_golden_dir demo1)" demo1
  [ "$status" -ne 0 ]
}

# --- invite codes: hashed at rest ---------------------------------------------

@test "issued codes are stored hashed, never plaintext" {
  CFILE="$(demo_codes_file demo1)"
  code="$(demo_generate_code)"
  hash="$(demo_hash_code "$code")"
  demo_code_add "$CFILE" c1 tester-member "$hash" "$(( $(date +%s) + 3600 ))"
  # the plaintext must not appear anywhere in the registry
  ! grep -qF "$code" "$CFILE"
  grep -qF "$hash" "$CFILE"
  jq -e '.codes[0].hash | test("^[0-9a-f]{64}$")' "$CFILE"
}

@test "registry refuses to store a value that is not a sha256 hash" {
  CFILE="$(demo_codes_file demo1)"
  run demo_code_add "$CFILE" c1 tester-member "MY-PLAINTEXT-CODE" "$(( $(date +%s) + 3600 ))"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing"* ]]
}

@test "registry refuses an unknown bundle (sitemanager is not a bundle)" {
  CFILE="$(demo_codes_file demo1)"
  h="$(demo_hash_code x)"
  run demo_code_add "$CFILE" c1 tester-sitemanager "$h" "$(( $(date +%s) + 3600 ))"
  [ "$status" -ne 0 ]
  run demo_code_add "$CFILE" c2 sitemanager "$h" "$(( $(date +%s) + 3600 ))"
  [ "$status" -ne 0 ]
}

@test "code generation is high-entropy and hash is deterministic sha256" {
  c1="$(demo_generate_code)"; c2="$(demo_generate_code)"
  [ "${#c1}" -eq 23 ]           # 20 chars + 3 dashes
  [ "$c1" != "$c2" ]
  [ "$(demo_hash_code abc)" = "$(printf '%s' abc | sha256sum | awk '{print $1}')" ]
}

@test "revoke keeps the row but excludes it from the site payload" {
  CFILE="$(demo_codes_file demo1)"
  now=$(date +%s)
  demo_code_add "$CFILE" c1 tester-member "$(demo_hash_code a)" "$(( now + 3600 ))"
  demo_code_add "$CFILE" c2 tester-guild-leader "$(demo_hash_code b)" "$(( now + 3600 ))"
  demo_code_revoke "$CFILE" c1
  jq -e '.codes | length == 2' "$CFILE"                       # audit row kept
  payload="$(demo_codes_payload "$CFILE")"
  echo "$payload" | jq -e '.codes | length == 1'
  echo "$payload" | jq -e '.codes[0].bundle == "tester-guild-leader"'
}

@test "expired codes are excluded from the site payload" {
  CFILE="$(demo_codes_file demo1)"
  demo_code_add "$CFILE" c1 tester-member "$(demo_hash_code a)" "$(( $(date +%s) - 10 ))"
  demo_codes_payload "$CFILE" | jq -e '.codes | length == 0'
}

@test "code ids are monotonic and never reused" {
  CFILE="$(demo_codes_file demo1)"
  [ "$(demo_next_code_id "$CFILE")" = "c1" ]
  demo_code_add "$CFILE" c1 tester-member "$(demo_hash_code a)" "$(( $(date +%s) + 10 ))"
  demo_code_add "$CFILE" c7 tester-member "$(demo_hash_code b)" "$(( $(date +%s) + 10 ))"
  [ "$(demo_next_code_id "$CFILE")" = "c8" ]
}

# --- invite: copy-ready email with per-level codes ----------------------------

# The invite subcommand end-to-end (minus the site sync, which is non-fatal
# and fails cleanly here — no ddev in the fixture).
run_invite() {
  run bash "$DEMO_CMD" invite demo1 "$@"
}

@test "invite writes a 0600 draft under sites/<site>/demo-invites/" {
  run_invite
  [ "$status" -eq 0 ]
  draft=$(ls "${PROJECT_ROOT}/sites/demo1/demo-invites"/invite-*.md)
  [ -s "$draft" ]
  [ "$(stat -c %a "$draft")" = "600" ]
}

@test "invite registers ONE hashed code per default bundle (no plaintext at rest)" {
  run_invite
  [ "$status" -eq 0 ]
  CFILE="$(demo_codes_file demo1)"
  jq -e '.codes | length == 3' "$CFILE"
  jq -e '[.codes[].bundle] | sort ==
         ["tester-content-manager","tester-guild-leader","tester-member"]' "$CFILE"
  jq -e 'all(.codes[]; .hash | test("^[0-9a-f]{64}$"))' "$CFILE"
  # no plaintext code (XXXXX-XXXXX-XXXXX-XXXXX) may appear in the registry
  ! grep -qE '[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}' "$CFILE"
}

@test "invite --all covers all five bundles; --bundles narrows; unknown refuses" {
  run_invite --all
  [ "$status" -eq 0 ]
  jq -e '.codes | length == 5' "$(demo_codes_file demo1)"
  run_invite --bundles tester-member
  [ "$status" -eq 0 ]
  jq -e '.codes | length == 6' "$(demo_codes_file demo1)"
  run_invite --bundles tester-member,not-a-bundle
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown bundle"* ]]
}

@test "draft email: each code exactly once, join URL, nightly-erase promise" {
  # give the fixture site a live domain so the real join URL is rendered
  cat > "${PROJECT_ROOT}/sites/demo1/.nwp.yml" <<'EOF'
live:
  enabled: true
  domain: demo1.example.org
EOF
  run_invite
  [ "$status" -eq 0 ]
  draft=$(ls "${PROJECT_ROOT}/sites/demo1/demo-invites"/invite-*.md)
  # every registered hash corresponds to exactly one plaintext occurrence:
  # 3 bundles → exactly 3 distinct code strings, each appearing once
  codes=$(grep -oE '[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}' "$draft" | sort)
  [ "$(echo "$codes" | wc -l)" -eq 3 ]
  [ "$(echo "$codes" | uniq | wc -l)" -eq 3 ]
  # each plaintext hashes to a registered hash (right codes, not random text)
  while IFS= read -r c; do
    h="$(demo_hash_code "$c")"
    jq -e --arg h "$h" '.codes[] | select(.hash == $h)' "$(demo_codes_file demo1)"
  done <<< "$codes"
  grep -qF "https://demo1.example.org/demo/join" "$draft"
  grep -q "ERASED EVERY" "$draft"
  grep -q "1am Melbourne" "$draft"
  grep -q "Report a problem" "$draft"
}

@test "draft email: one deletable block per level with plain-language names" {
  run_invite --all
  draft=$(ls "${PROJECT_ROOT}/sites/demo1/demo-invites"/invite-*.md)
  for label in "MEMBER TESTER" "GUILD LEADER TESTER" "CONTENT MANAGER TESTER" \
               "COPYRIGHT REVIEWER TESTER" "SAFEGUARDING REVIEWER TESTER"; do
    grep -q "$label" "$draft"
  done
  # jargon must not leak into the email
  ! grep -qiE '\b(OIDC|bundles?|RAG)\b' "$draft"
}

@test "invite without live.domain falls back to a visible placeholder" {
  run_invite
  [ "$status" -eq 0 ]
  draft=$(ls "${PROJECT_ROOT}/sites/demo1/demo-invites"/invite-*.md)
  grep -qF "<YOUR-SITE-URL>/demo/join" "$draft"
  [[ "$output" == *"placeholder"* ]]
}

@test "invite --expiry is validated and reflected in the email" {
  run_invite --expiry 7d
  [ "$status" -eq 0 ]
  draft=$(ls "${PROJECT_ROOT}/sites/demo1/demo-invites"/invite-*.md)
  grep -q "expires in 7 days" "$draft"
  run_invite --expiry "next week"
  [ "$status" -ne 0 ]
}

@test "demo.sh and lib/demo.sh are bash -n clean" {
  bash -n "$DEMO_CMD"
  bash -n "${REPO_ROOT}/lib/demo.sh"
}

# --- pre-wipe error harvest (fail-open) ---------------------------------------

@test "harvest with findings writes a labelled spool digest" {
  demo_harvest demo1 dev echo "PHP Fatal error: something broke"
  spool=$(ls "$(demo_harvest_dir demo1)"/harvest-*.md)
  [ -s "$spool" ]
  grep -q "demo-tester,auto-harvest" "$spool"
  grep -q "something broke" "$spool"
  grep -q "harvest-ok" "$(demo_log_file demo1)"
}

@test "harvest with nothing to report spools nothing" {
  demo_harvest demo1 dev true
  [ ! -d "$(demo_harvest_dir demo1)" ] || [ -z "$(ls -A "$(demo_harvest_dir demo1)")" ]
  grep -q "harvest-empty" "$(demo_log_file demo1)"
}

@test "a FAILING harvest never blocks the reset (returns 0, logged)" {
  run demo_harvest demo1 dev false
  [ "$status" -eq 0 ]
  grep -q "harvest-failed" "$(demo_log_file demo1)"
}

@test "reset ordering: harvest runs BEFORE the DB restore (static)" {
  harvest_line=$(grep -n 'demo_harvest "\$site"' "$DEMO_CMD" | head -1 | cut -d: -f1)
  import_line=$(grep -n 'ddev import-db' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$harvest_line" ] && [ -n "$import_line" ]
  [ "$harvest_line" -lt "$import_line" ]
  # and the call is belt-and-braces guarded against set -e
  grep -q 'demo_harvest "\$site" "\$tier" demo_harvest_collect "\$proj" || true' "$DEMO_CMD"
}

@test "reset ordering: golden verification precedes the wipe (static)" {
  verify_line=$(grep -n 'demo_golden_verify "\$gdir" "\$site"' "$DEMO_CMD" | head -1 | cut -d: -f1)
  import_line=$(grep -n 'ddev import-db' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ "$verify_line" -lt "$import_line" ]
}

# --- logging ------------------------------------------------------------------

@test "demo_log appends timestamped events" {
  demo_log demo1 reset-ok "tier=dev took=42s"
  demo_log demo1 skip-active "tier=dev window=30m"
  lines=$(wc -l < "$(demo_log_file demo1)")
  [ "$lines" -eq 2 ]
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z reset-ok tier=dev' "$(demo_log_file demo1)"
}
