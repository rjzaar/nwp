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

@test "demo.sh refuses --tier=prod outright (a demo tier never resets prod)" {
  run bash "$DEMO_CMD" status demo1 --tier=prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "demo.sh refuses an unknown tier" {
  run bash "$DEMO_CMD" status demo1 --tier=staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown tier"* ]]
}

@test "demo.sh accepts --tier=live (Phase 2 no longer fail-closed on the tier)" {
  run bash "$DEMO_CMD" status demo1 --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSED"* ]]
  [[ "$output" == *"live"* ]]
}

# --- tier-scoped golden dir ---------------------------------------------------

@test "the live golden lives in its own dir — a local image can never be restored over live" {
  [ "$(demo_golden_dir demo1)"      = "${PROJECT_ROOT}/sites/demo1/demo-golden" ]
  [ "$(demo_golden_dir demo1 dev)"  = "${PROJECT_ROOT}/sites/demo1/demo-golden" ]
  [ "$(demo_golden_dir demo1 stg)"  = "${PROJECT_ROOT}/sites/demo1/demo-golden" ]
  [ "$(demo_golden_dir demo1 live)" = "${PROJECT_ROOT}/sites/demo1/demo-golden-live" ]
  [ "$(demo_golden_dir demo1 live)" != "$(demo_golden_dir demo1 dev)" ]
}

@test "live status reads the live golden dir, not the local one" {
  mkdir -p "$(demo_golden_dir demo1 live)"
  # a manifest in the LOCAL dir must not be reported by --tier=live
  mkdir -p "$(demo_golden_dir demo1 dev)"
  echo '{"site":"demo1","captured_utc":"2026-01-01T00:00:00Z"}' > "$(demo_golden_dir demo1 dev)/golden.manifest.json"
  run bash "$DEMO_CMD" status demo1 --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"No golden image captured yet"* ]]
  [[ "$output" == *"--tier=live"* ]]
}

# --- live reset: fail-closed ordering (static) --------------------------------

@test "live reset verifies the golden BEFORE it touches the remote host" {
  verify=$(grep -n 'demo_golden_verify "\$gdir" "\$site"' "$DEMO_CMD" | sed -n 2p | cut -d: -f1)
  drop=$(grep -n 'drush sql:drop' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$verify" ] && [ -n "$drop" ]
  [ "$verify" -lt "$drop" ]
}

@test "live reset requires remote demo_mode BEFORE the drop (the anti-wipe guard)" {
  guard=$(grep -n 'demo_live_require_demo_mode "\$site"' "$DEMO_CMD" | sed -n 2p | cut -d: -f1)
  drop=$(grep -n 'drush sql:drop' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$guard" ] && [ -n "$drop" ]
  [ "$guard" -lt "$drop" ]
}

@test "live reset re-verifies the UPLOADED golden on the remote before the drop" {
  push=$(grep -n 'demo_push_verified "\$site" "\$gdir/\$GOLDEN_FILES"' "$DEMO_CMD" | head -1 | cut -d: -f1)
  drop=$(grep -n 'drush sql:drop' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$push" ] && [ -n "$drop" ]
  [ "$push" -lt "$drop" ]
  # and the push itself compares a remote-computed sha against the local sidecar
  grep -q 'sha256 MISMATCH after push' "$DEMO_CMD"
}

@test "live reset harvests errors BEFORE the wipe" {
  harvest=$(grep -n 'demo_harvest "\$site" live demo_harvest_collect_live' "$DEMO_CMD" | head -1 | cut -d: -f1)
  drop=$(grep -n 'drush sql:drop' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$harvest" ] && [ -n "$drop" ]
  [ "$harvest" -lt "$drop" ]
}

@test "live restore drops the DB first so orphan tables cannot survive" {
  grep -q 'drush sql:drop -y' "$DEMO_CMD"
}

@test "demo_live_ctx refuses a site with no live server configured" {
  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  cat > "${PROJECT_ROOT}/sites/demo1/.nwp.yml" <<'YML'
schema_version: 2
project:
  name: demo1
YML
  run bash "$DEMO_CMD" golden demo1 --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"No live server configured"* ]]
}

@test "demo_live_ctx refuses when live.enabled is false" {
  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  cat > "${PROJECT_ROOT}/sites/demo1/.nwp.yml" <<'YML'
schema_version: 2
project:
  name: demo1
live:
  enabled: false
  server_ip: 203.0.113.9
YML
  run bash "$DEMO_CMD" golden demo1 --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"Live deployment disabled"* ]]
}

# --- schedule: the cron line carries the tier ---------------------------------

@test "schedule writes a tier-explicit nightly line" {
  grep -q 'pl demo nightly \${site} --tier=\${tier}' "$DEMO_CMD"
}

# --- harvest-post -------------------------------------------------------------

@test "harvest-post on an empty spool is a no-op, not an error" {
  run bash "$DEMO_CMD" harvest-post demo1
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to post"* ]]
}

@test "harvest-post --dry-run lists digests and posts nothing" {
  demo_harvest demo1 live echo "PHP Fatal error: kaboom"
  run bash "$DEMO_CMD" harvest-post demo1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would post"* ]]
  [[ "$output" == *"demo-tester,auto-harvest"* ]]
  # spool untouched, nothing moved to posted/
  [ -n "$(ls "$(demo_harvest_dir demo1)"/harvest-*.md)" ]
  [ ! -d "$(demo_harvest_dir demo1)/posted" ]
}

@test "harvest-post only moves a digest to posted/ after GitLab confirms (retry-safe)" {
  # static: the mv is inside the iid-confirmed branch, never before the POST
  mv_line=$(grep -n 'mv "\$f" "\$hdir/posted/' "$DEMO_CMD" | head -1 | cut -d: -f1)
  iid_line=$(grep -n 'iid="\$(printf' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$mv_line" ] && [ -n "$iid_line" ]
  [ "$iid_line" -lt "$mv_line" ]
  grep -q 'left in the spool for retry' "$DEMO_CMD"
}

@test "harvest-post uses the least-privilege ops_note_token path, never a raw PAT" {
  grep -q 'lib/gitlab-issues.sh' "$DEMO_CMD"
  # no token ever reaches argv/stdout from this command
  ! grep -q 'PRIVATE-TOKEN' "$DEMO_CMD"
  ! grep -q 'api_token' "$DEMO_CMD"
}

@test "status surfaces an unposted harvest backlog" {
  demo_harvest demo1 live echo "PHP Fatal error: kaboom"
  run bash "$DEMO_CMD" status demo1
  [ "$status" -eq 0 ]
  [[ "$output" == *"harvest digest(s) in the spool"* ]]
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

# --- live post-restore smoke --------------------------------------------------

@test "live smoke retries before declaring the site broken (cold-cache tolerance)" {
  # a single sample would report a healthy site as broken on a small host
  grep -q 'for attempt in 1 2 3 4 5; do' "$DEMO_CMD"
  grep -q 'still \${code} after 5 attempts' "$DEMO_CMD"
}

@test "a live reset that restores data but fails its smoke check returns FAILURE" {
  # the nightly wrapper must not treat a degraded site as success
  grep -q 'reset-ok-degraded' "$DEMO_CMD"
  block=$(sed -n '/if \[\[ "\$degraded" == "true" \]\]/,/^    fi$/p' "$DEMO_CMD")
  [[ "$block" == *"return 1"* ]]
}

@test "live smoke checks /demo/join too — testers must be able to join" {
  grep -q '/demo/join' "$DEMO_CMD"
  grep -q 'testers cannot join' "$DEMO_CMD"
}

@test "the live deploy gate is actually sourced, not silently skipped" {
  grep -q 'source "\$REPO_ROOT/lib/deploy-gate.sh"' "$DEMO_CMD"
  gate=$(grep -n 'deploy_gate_require "\$site" "live"' "$DEMO_CMD" | head -1 | cut -d: -f1)
  drop=$(grep -n 'drush sql:drop' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$gate" ] && [ "$gate" -lt "$drop" ]
}

# --- schedule: real crontab round-trip against a stub `crontab` ---------------

@test "schedule installs, is idempotent, removes cleanly, and preserves neighbours" {
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/crontab" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then cat "$STUB_CRON" 2>/dev/null; exit 0; fi
cat > "$STUB_CRON"
STUB
  chmod +x "${TEST_TMP}/bin/crontab"
  export STUB_CRON="${TEST_TMP}/current.cron"
  printf '# unrelated\n30 2 * * * /home/rob/bin/nwp-daily-audit\n' > "$STUB_CRON"

  PATH="${TEST_TMP}/bin:$PATH" run bash "$DEMO_CMD" schedule demo1 --tier=live
  [ "$status" -eq 0 ]
  grep -q '^CRON_TZ=Australia/Melbourne$' "$STUB_CRON"
  grep -q 'pl demo nightly demo1 --tier=live' "$STUB_CRON"
  grep -q 'nwp-daily-audit' "$STUB_CRON"          # neighbour survived

  # re-install must not duplicate the block
  PATH="${TEST_TMP}/bin:$PATH" bash "$DEMO_CMD" schedule demo1 --tier=live >/dev/null 2>&1
  [ "$(grep -c 'pl demo nightly demo1' "$STUB_CRON")" -eq 1 ]
  [ "$(grep -c '^CRON_TZ=' "$STUB_CRON")" -eq 1 ]

  # removal takes the whole block and leaves the neighbour
  PATH="${TEST_TMP}/bin:$PATH" bash "$DEMO_CMD" schedule demo1 --tier=live --remove >/dev/null 2>&1
  ! grep -q 'pl demo nightly demo1' "$STUB_CRON"
  ! grep -q '^CRON_TZ=' "$STUB_CRON"
  grep -q 'nwp-daily-audit' "$STUB_CRON"
}

@test "a dev-tier schedule does not silently become a live one" {
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/crontab" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then cat "$STUB_CRON" 2>/dev/null; exit 0; fi
cat > "$STUB_CRON"
STUB
  chmod +x "${TEST_TMP}/bin/crontab"
  export STUB_CRON="${TEST_TMP}/current.cron"; : > "$STUB_CRON"
  PATH="${TEST_TMP}/bin:$PATH" bash "$DEMO_CMD" schedule demo1 >/dev/null 2>&1
  grep -q 'pl demo nightly demo1 --tier=dev' "$STUB_CRON"
  ! grep -q -- '--tier=live' "$STUB_CRON"
}

# --- Option A: restricted forced-command key (ops#133) ------------------------
#
# The wrapper is versioned at servers/nwpcode/demo/nwd-demo-reset-restricted and
# installed on the box as /usr/local/bin/nwd-demo-reset-restricted. Its
# client-input handling is the security boundary, so it is tested by RUNNING it
# with $SSH_ORIGINAL_COMMAND set. These tests never reach the destructive path:
# on a machine with no /var/www/nwd the wrapper dies at its precheck, which is
# itself the assertion that an allowed word got past the allowlist.

wrapper() { echo "${REPO_ROOT}/servers/nwpcode/demo/nwd-demo-reset-restricted"; }

@test "restricted wrapper is bash -n clean, and so are its installers" {
  run bash -n "$(wrapper)"
  [ "$status" -eq 0 ]
  run bash -n "${REPO_ROOT}/servers/nwpcode/demo/install-box.sh"
  [ "$status" -eq 0 ]
  run bash -n "${REPO_ROOT}/servers/nwpcode/demo/install-on-met.sh"
  [ "$status" -eq 0 ]
}

@test "restricted wrapper REFUSES every command outside the allowlist (exit 2)" {
  local c
  for c in 'id' 'cat /etc/passwd' 'bash' 'sudo id' 'sudo su -' 'rm -rf /var/www/avc' \
           'reset; id' 'reset && id' '$(id)' '`id`' 'dry-run; cat /etc/shadow' \
           'RESET' 'Nightly' ' reset' 'reset ' 'scp -t /tmp/pwn'; do
    SSH_ORIGINAL_COMMAND="$c" run bash "$(wrapper)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    # the refused string must never have been executed
    [[ "$output" != *"uid="* ]]
    [[ "$output" != *"root:x:0:0"* ]]
  done
}

@test "a refused command is LOGGED verbatim, not executed" {
  SSH_ORIGINAL_COMMAND='cat /etc/shadow' run bash "$(wrapper)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"rejected-command"* ]]
  [[ "$output" == *"requested=cat /etc/shadow"* ]]
  [[ "$output" != *"root:"* ]]
}

@test "log fields cannot be forged with newlines or pipes in the client command" {
  SSH_ORIGINAL_COMMAND=$'id\n2026-01-01T00:00:00Z|reset-ok|forged' run bash "$(wrapper)"
  [ "$status" -eq 2 ]
  # The newline is stripped and the | separators are rewritten to /, so the
  # injected text collapses into the requested= field of ONE log line and can
  # never be parsed as a second event.
  [ "$(printf '%s\n' "$output" | grep -c '|rejected-command|')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '|reset-ok|')" -eq 0 ]
  [[ "$output" == *"requested=id2026-01-01T00:00:00Z/reset-ok/forged"* ]]
}

@test "allowed action words get PAST the allowlist (exit != 2) and hit the guards" {
  local c
  for c in '' 'nightly' 'reset' 'dry-run'; do
    SSH_ORIGINAL_COMMAND="$c" run bash "$(wrapper)"
    [ "$status" -ne 2 ]
    [[ "$output" != *"REFUSED"* ]]
    # no /var/www/nwd on a test machine → fail-closed at the precheck
    [[ "$output" == *"precheck-failed"* ]] || [[ "$output" == *"golden"* ]]
  done
}

@test "status is read-only and always succeeds" {
  SSH_ORIGINAL_COMMAND='status' run bash "$(wrapper)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"site:        nwd"* ]]
}

@test "the wrapper is hard-wired to nwd and cannot be pointed at another site" {
  # No code path takes a site name from the client; the constants are literal.
  grep -q '^SITE="nwd"' "$(wrapper)"
  grep -q '^SITE_ROOT="/var/www/nwd"' "$(wrapper)"
  ! grep -qE 'SITE=.*\$(1|\{1|SSH_ORIGINAL)' "$(wrapper)"
}

@test "the wrapper never evals or shells out to client input" {
  ! grep -qE '\beval\b' "$(wrapper)"
  ! grep -qE '(sh|bash) +-c +.*SSH_ORIGINAL_COMMAND' "$(wrapper)"
  # Every use of the client-supplied string must be one of exactly three safe
  # shapes: the assignment, the `case` scrutinee, or a scrub()'d log argument.
  # Anything else (a command position, a redirect, an array expansion) fails.
  local line
  while IFS= read -r line; do
    [[ "$line" == *"RAW_CMD=\"\${SSH_ORIGINAL_COMMAND"* ]] && continue
    [[ "$line" == *"# "* ]] && continue
    [[ "$line" == *'case "$RAW_CMD" in'* ]] && continue
    [[ "$line" == *'scrub "$RAW_CMD"'* ]] && continue
    echo "unsafe use of RAW_CMD: $line"
    false
  done < <(grep 'RAW_CMD' "$(wrapper)")
}

@test "the wrapper refuses a non-demo site before anything destructive (static)" {
  local demo_line wipe_line
  demo_line=$(grep -n 'require_demo_mode || die' "$(wrapper)" | head -1 | cut -d: -f1)
  wipe_line=$(grep -n 'sql:drop' "$(wrapper)" | head -1 | cut -d: -f1)
  [ -n "$demo_line" ] && [ -n "$wipe_line" ]
  [ "$demo_line" -lt "$wipe_line" ]
}

@test "the wrapper verifies the golden before anything destructive (static)" {
  local verify_line wipe_line
  verify_line=$(grep -n 'golden_verify || die' "$(wrapper)" | head -1 | cut -d: -f1)
  wipe_line=$(grep -n 'sql:drop' "$(wrapper)" | head -1 | cut -d: -f1)
  [ "$verify_line" -lt "$wipe_line" ]
}

@test "the wrapper harvests errors before the wipe (static)" {
  local harvest_line wipe_line
  harvest_line=$(grep -n '^harvest || true' "$(wrapper)" | head -1 | cut -d: -f1)
  wipe_line=$(grep -n 'sql:drop' "$(wrapper)" | head -1 | cut -d: -f1)
  [ "$harvest_line" -lt "$wipe_line" ]
}

@test "authorized_keys restrictions installed are the full hardened set" {
  local ib="${REPO_ROOT}/servers/nwpcode/demo/install-box.sh"
  grep -q 'command="/usr/local/bin/nwd-demo-reset-restricted"' "$ib"
  local o
  for o in no-agent-forwarding no-port-forwarding no-pty no-user-rc no-X11-forwarding; do
    grep -q "$o" "$ib"
  done
}

@test "schedule --via-key writes a repo-free cron line pinned to the restricted key" {
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/crontab" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then cat "$STUB_CRON" 2>/dev/null; exit 0; fi
cat > "$STUB_CRON"
STUB
  chmod +x "${TEST_TMP}/bin/crontab"
  export STUB_CRON="${TEST_TMP}/current.cron"
  printf '# unrelated\n30 2 * * * $HOME/bin/nwp-daily-audit\n' > "$STUB_CRON"
  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  cat > "${PROJECT_ROOT}/sites/demo1/.nwp.yml" <<'YML'
schema_version: 2
project:
  name: demo1
live:
  enabled: true
  domain: demo1.example.com
  server_ip: 203.0.113.9
YML

  PATH="${TEST_TMP}/bin:$PATH" run bash "$DEMO_CMD" schedule demo1 --tier=live --via-key
  [ "$status" -eq 0 ]
  grep -q '^CRON_TZ=Australia/Melbourne$' "$STUB_CRON"
  grep -q 'demo1_demo_reset' "$STUB_CRON"
  # host + user come from the site config, never a hardcoded hostname
  grep -q '203.0.113.9' "$STUB_CRON"
  # the load-bearing ssh options (without them the ADMIN key wins)
  grep -q 'IdentitiesOnly=yes' "$STUB_CRON"
  grep -q 'IdentityAgent=none' "$STUB_CRON"
  # cron itself does the retrying: the wrapper is idempotent
  grep -q '^0,30 1-3 \* \* \*' "$STUB_CRON"
  # no repo path and no local pl invocation on the scheduler
  ! grep -q 'pl demo nightly demo1' "$STUB_CRON"
  grep -q 'nwp-daily-audit' "$STUB_CRON"          # neighbour survived
}

@test "schedule --remove clears the --via-key block too" {
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/crontab" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then cat "$STUB_CRON" 2>/dev/null; exit 0; fi
cat > "$STUB_CRON"
STUB
  chmod +x "${TEST_TMP}/bin/crontab"
  export STUB_CRON="${TEST_TMP}/current.cron"
  printf '# unrelated\n30 2 * * * $HOME/bin/nwp-daily-audit\n' > "$STUB_CRON"
  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  cat > "${PROJECT_ROOT}/sites/demo1/.nwp.yml" <<'YML'
schema_version: 2
project:
  name: demo1
live:
  enabled: true
  domain: demo1.example.com
  server_ip: 203.0.113.9
YML

  PATH="${TEST_TMP}/bin:$PATH" bash "$DEMO_CMD" schedule demo1 --tier=live --via-key >/dev/null 2>&1
  PATH="${TEST_TMP}/bin:$PATH" bash "$DEMO_CMD" schedule demo1 --remove >/dev/null 2>&1
  ! grep -q 'demo1_demo_reset' "$STUB_CRON"
  ! grep -q '^CRON_TZ=' "$STUB_CRON"
  grep -q 'nwp-daily-audit' "$STUB_CRON"
}

################################################################################
# ops#47 impact contract — reset WIPES a site (live tier included) unattended,
# so it must print a COMPUTED fate manifest first. -y skips the prompt, never
# the report. The builder is exercised for real (demo.sh is sourceable);
# the wiring around the destructive steps is pinned statically.
################################################################################

# A verifiable golden image for <site>/<tier>, so the manifest has real
# sha256/capture-time provenance to report.
_fixture_golden() {   # $1 site  $2 tier
  local gdir; gdir="$(demo_golden_dir "$1" "$2")"
  mkdir -p "$gdir"
  printf 'db\n'    > "$gdir/golden.db.sql.gz"
  printf 'files\n' > "$gdir/golden.files.tar.gz"
  ( cd "$gdir" && sha256sum golden.db.sql.gz    > golden.db.sql.gz.sha256 \
               && sha256sum golden.files.tar.gz > golden.files.tar.gz.sha256 )
  demo_manifest_write "$gdir" "$1" golden.db.sql.gz golden.files.tar.gz
  printf '%s' "$gdir"
}

@test "the fate manifest is COMPUTED: measured sizes + golden sha/age, nothing assumed" {
  gdir="$(_fixture_golden demo1 live)"
  run bash -c "source '$DEMO_CMD'
               DEMO_M_DB=63.8 DEMO_M_FILES=4.5G DEMO_M_ACCTS=7
               demo_reset_manifest demo1 live '$gdir' https://demo.example.org"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WILL BE PERMANENTLY DELETED"* ]]
  [[ "$output" == *"WILL BE OVERWRITTEN"* ]]
  [[ "$output" == *"63.8M"* ]]                       # measured DB, not guessed
  [[ "$output" == *"4.5G"* ]]                        # measured uploads
  [[ "$output" == *"7 account(s) created since"* ]]  # tester work at stake
  [[ "$output" == *"sha256 $(head -c 12 "$gdir/golden.db.sql.gz.sha256")"* ]]
  [[ "$output" == *"0m old"* ]]                      # replacement provenance
  [[ "$output" == *"LIVE TIER"* ]]
  [[ "$output" == *"NOT AFFECTED"* ]]
  [[ "$output" == *"Invite-code registry"* ]]        # what survives the wipe
}

@test "a failed probe is REPORTED, never papered over with a guess" {
  gdir="$(_fixture_golden demo1 dev)"
  run bash -c "source '$DEMO_CMD'
               DEMO_M_DB='' DEMO_M_FILES='' DEMO_M_ACCTS=''
               demo_reset_manifest demo1 dev '$gdir' /srv/demo1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not measure the current database size"* ]]
  [[ "$output" == *"could not measure the current uploads directory"* ]]
  [[ "$output" != *"LIVE TIER"* ]]
}

@test "an unattended (-y/cron) wipe still leaves the manifest in the log" {
  gdir="$(_fixture_golden demo1 live)"
  bash -c "source '$DEMO_CMD'
           DEMO_M_DB=12.0 DEMO_M_FILES=800M DEMO_M_ACCTS=3
           demo_reset_manifest demo1 live '$gdir' https://demo.example.org false" >/dev/null
  # …and a rehearsal is marked as one, so the audit trail cannot be misread
  bash -c "source '$DEMO_CMD'
           demo_reset_manifest demo1 live '$gdir' https://demo.example.org true" >/dev/null
  run cat "$(demo_log_file demo1)"
  [[ "$output" == *"reset-manifest"* ]]
  [[ "$output" == *"tier=live"* ]]
  [[ "$output" == *"dry_run=false"* ]]
  [[ "$output" == *"dry_run=true"* ]]
  [[ "$output" == *"db_now=12.0"* ]]
  [[ "$output" == *"new_accounts=3"* ]]
  [[ "$output" == *"golden_sha="* ]]
}

@test "reset renders the manifest BEFORE the wipe, on both tiers (static)" {
  # local tier: manifest → ddev import-db
  m_local=$(grep -n 'demo_reset_manifest "\$site" "\$tier"' "$DEMO_CMD" | head -1 | cut -d: -f1)
  import=$(grep -n 'ddev import-db' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$m_local" ] && [ "$m_local" -lt "$import" ]
  # live tier: manifest → sql:drop
  m_live=$(grep -n 'demo_reset_manifest "\$site" live' "$DEMO_CMD" | head -1 | cut -d: -f1)
  drop=$(grep -n 'drush sql:drop' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$m_live" ] && [ "$m_live" -lt "$drop" ]
}

@test "a LIVE wipe confirms at the TYPED tier; dev/stg at standard" {
  grep -q 'impact_confirm typed "\${DEMO_LIVE_DOMAIN:-\$site}"' "$DEMO_CMD"
  grep -q 'impact_confirm standard "ERASE' "$DEMO_CMD"
  # the hand-rolled y/N prompts are gone — one confirmation path, not three
  ! grep -q 'This will ERASE' "$DEMO_CMD"
}

@test "the manifest is rendered ahead of the Solo deploy gate (see it, then touch)" {
  m_live=$(grep -n 'demo_reset_manifest "\$site" live' "$DEMO_CMD" | head -1 | cut -d: -f1)
  gate=$(grep -n 'deploy_gate_require "\$site" "live"' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$m_live" ] && [ -n "$gate" ]
  [ "$m_live" -lt "$gate" ]
}

@test "reset --dry-run stops after the report, before the gate and the wipe" {
  grep -q 'dry-run\] nothing was touched' "$DEMO_CMD"
  dry=$(grep -n 'dry-run\] nothing was touched' "$DEMO_CMD" | head -1 | cut -d: -f1)
  import=$(grep -n 'ddev import-db' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ "$dry" -lt "$import" ]
  run bash "$DEMO_CMD" --help
  [[ "$output" == *"--dry-run"* ]]
}

@test "the nightly path passes -y but never suppresses the report" {
  awk '/^cmd_nightly\(\)/,/^}/' "$DEMO_CMD" | grep -q 'cmd_reset "\$site" "\$tier" "30m" "true" "false" "false"'
}
