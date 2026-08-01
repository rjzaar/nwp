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

# GIVE THE FIXTURE A WORKING DELIVERY PATH (nwp/ops#173).
#
# Every code verb now refuses on a host that cannot deliver to the named tier,
# so a test about invite RENDERING has to be run on a host that can. This builds
# a real one — a .ddev dir plus a stub `ddev` that answers drush state:get and
# state:set — rather than switching the guard off with the env escape. The
# difference matters: this way the rendering tests keep exercising the actual
# probe (demo_project_dir → `ddev drush state:get`), so if the probe ever stops
# working these fail too instead of quietly passing around it.
demo_enable_delivery() {
  mkdir -p "${PROJECT_ROOT}/sites/demo1/.ddev" "${TEST_TMP}/bin"
  printf 'docroot: web\n' > "${PROJECT_ROOT}/sites/demo1/.ddev/config.yaml"
  cat > "${TEST_TMP}/bin/ddev" <<'STUB'
#!/bin/bash
# Stand-in for the DDEV project. Answers only what the code path uses.
[ "$1" = "drush" ] || exit 1
shift
while [ $# -gt 0 ]; do
  case "$1" in
    state:get) echo '{"version":1,"codes":[]}'; exit 0 ;;
    state:set) exit 0 ;;
  esac
  shift
done
exit 1
STUB
  chmod +x "${TEST_TMP}/bin/ddev"
  export PATH="${TEST_TMP}/bin:$PATH"
}

# The invite subcommand end-to-end.
# --tier is REQUIRED for invite (demo_require_explicit_tier) AND this host must
# be able to reach it (demo_require_delivery); these cases are about the draft
# and the registry, so they name the local tier and stand up a local path to it.
# Both refusals are covered further down.
run_invite() {
  demo_enable_delivery
  run bash "$DEMO_CMD" invite demo1 --tier=dev "$@"
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
  # Scoped to the cmd_reset BODY. `grep … | head -1` over the whole file was
  # wrong the moment a second reset verb appeared above this one: it compared
  # cmd_reset's harvest against cmd_reset_paired's import and reported a
  # correctly-ordered function as broken. The paired body has its own
  # equivalent in test-demo-pair.bats ("harvests BOTH halves BEFORE the first
  # import-db"), so scoping loses no coverage.
  body=$(awk '/^cmd_reset\(\)/,/^}/' "$DEMO_CMD")
  harvest_line=$(printf '%s\n' "$body" | grep -n 'demo_harvest "\$site"' | head -1 | cut -d: -f1)
  import_line=$(printf '%s\n' "$body" | grep -n 'ddev import-db' | head -1 | cut -d: -f1)
  [ -n "$harvest_line" ] && [ -n "$import_line" ]
  [ "$harvest_line" -lt "$import_line" ]
  # and the call is belt-and-braces guarded against set -e
  grep -q 'demo_harvest "\$site" "\$tier" demo_harvest_collect "\$proj" || true' "$DEMO_CMD"
}

@test "reset ordering: golden verification precedes the wipe (static)" {
  # Scoped to the cmd_reset body — see the note above. The paired body's own
  # verify-before-wipe assertion is in test-demo-pair.bats.
  body=$(awk '/^cmd_reset\(\)/,/^}/' "$DEMO_CMD")
  verify_line=$(printf '%s\n' "$body" | grep -n 'demo_golden_verify "\$gdir" "\$site"' | head -1 | cut -d: -f1)
  import_line=$(printf '%s\n' "$body" | grep -n 'ddev import-db' | head -1 | cut -d: -f1)
  [ -n "$verify_line" ] && [ -n "$import_line" ]
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

@test "live smoke checks the tester's NEXT step, per site kind" {
  # The post-restore smoke must probe the route the tester actually uses next.
  # On the Drupal provider that is the join form. On the Moodle half /demo/join
  # does not exist, so probing it would report every healthy Moodle reset as a
  # failure — the check must follow the kind.
  grep -q '/demo/join' "$DEMO_CMD"
  grep -q '/login/index.php' "$DEMO_CMD"
  grep -q 'testers cannot proceed' "$DEMO_CMD"
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
# The wrapper is versioned at servers/live/demo/nwd-demo-reset-restricted and
# installed on the box as /usr/local/bin/nwd-demo-reset-restricted. Its
# client-input handling is the security boundary, so it is tested by RUNNING it
# with $SSH_ORIGINAL_COMMAND set. These tests never reach the destructive path:
# on a machine with no /var/www/nwd the wrapper dies at its precheck, which is
# itself the assertion that an allowed word got past the allowlist.

wrapper() { echo "${REPO_ROOT}/servers/live/demo/nwd-demo-reset-restricted"; }

@test "restricted wrapper is bash -n clean, and so are its installers" {
  run bash -n "$(wrapper)"
  [ "$status" -eq 0 ]
  run bash -n "${REPO_ROOT}/servers/live/demo/install-box.sh"
  [ "$status" -eq 0 ]
  run bash -n "${REPO_ROOT}/servers/live/demo/install-on-met.sh"
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

@test "authorized_keys restrictions installed are the full hardened set — for BOTH halves" {
  # ops#170 made the wrapper name a variable so the Moodle half could have its
  # own forced command. A grep for the old nwd literal would now pass on a file
  # that templated the string WRONG for ssd, so this asserts by EVALUATION: pull
  # the two lines that build the forced command out of the shipped installer and
  # run them for each site.
  local ib="${REPO_ROOT}/servers/live/demo/install-box.sh"
  local site rendered
  for site in nwd ssd; do
    rendered="$(
      DEMO_SITE="$site" bash -c '
        eval "$(grep -E "^WRAPPER_NAME=|^WRAPPER_DST=|^RESTRICTIONS=" "$1")"
        printf "%s" "$RESTRICTIONS"
      ' _ "$ib"
    )"
    [[ "$rendered" == "command=\"/usr/local/bin/${site}-demo-reset-restricted\","* ]]
    local o
    for o in no-agent-forwarding no-port-forwarding no-pty no-user-rc no-X11-forwarding; do
      [[ "$rendered" == *"$o"* ]]
    done
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

@test "schedule --via-key offsets the CONSUMER half of a demo pair by 15 minutes" {
  # Both halves live on the same box now. Same-minute firing means two
  # simultaneous drop-and-reload cycles on a small host, and it maximises the
  # window in which one half is at its golden and the other is not — the window
  # in which an SSO idnumber points at an account the provider no longer has.
  # The offset is DERIVED from the pair contract, never a flag, because a
  # collision-avoidance measure an operator must remember to pass is one they
  # will forget.
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/crontab" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then cat "$STUB_CRON" 2>/dev/null; exit 0; fi
cat > "$STUB_CRON"
STUB
  chmod +x "${TEST_TMP}/bin/crontab"
  export STUB_CRON="${TEST_TMP}/current.cron"
  : > "$STUB_CRON"

  mkdir -p "${PROJECT_ROOT}/sites/prov1" "${PROJECT_ROOT}/sites/cons1" "${PROJECT_ROOT}/pairs"
  for s in prov1 cons1; do
    cat > "${PROJECT_ROOT}/sites/${s}/.nwp.yml" <<YML
schema_version: 2
project:
  name: ${s}
live:
  enabled: true
  domain: ${s}.example.com
  server_ip: 203.0.113.9
YML
  done
  cat > "${PROJECT_ROOT}/pairs/cons1.pair-contract.yml" <<'YML'
pair: cons1-prov1
provider: prov1
consumer: cons1
demo:
  enabled: true
  paired_golden: true
  paired_reset: true
YML

  # the PROVIDER keeps the base cadence
  PATH="${TEST_TMP}/bin:$PATH" run bash "$DEMO_CMD" schedule prov1 --tier=live --via-key
  [ "$status" -eq 0 ]
  grep -q '^0,30 1-3 \* \* \*' "$STUB_CRON"

  # the CONSUMER is offset — same window, same cadence, never the same minute
  : > "$STUB_CRON"
  PATH="${TEST_TMP}/bin:$PATH" run bash "$DEMO_CMD" schedule cons1 --tier=live --via-key
  [ "$status" -eq 0 ]
  grep -q '^15,45 1-3 \* \* \*' "$STUB_CRON"
  ! grep -q '^0,30 1-3 \* \* \*' "$STUB_CRON"
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

@test "reset renders the manifest BEFORE the wipe, on EVERY reset verb (static)" {
  # One assertion per destructive body, so a new reset verb that skips the
  # manifest is caught HERE and cannot hide behind another body's line numbers.
  # cmd_reset_paired's first cut did exactly that (MR !162 note 2218).
  local_body=$(awk '/^cmd_reset\(\)/,/^}/' "$DEMO_CMD")
  m_local=$(printf '%s\n' "$local_body" | grep -n 'demo_reset_manifest "\$site" "\$tier"' | head -1 | cut -d: -f1)
  i_local=$(printf '%s\n' "$local_body" | grep -n 'ddev import-db' | head -1 | cut -d: -f1)
  [ -n "$m_local" ] && [ -n "$i_local" ] && [ "$m_local" -lt "$i_local" ]

  live_body=$(awk '/^cmd_reset_live\(\)/,/^}/' "$DEMO_CMD")
  m_live=$(printf '%s\n' "$live_body" | grep -n 'demo_reset_manifest "\$site" live' | head -1 | cut -d: -f1)
  d_live=$(printf '%s\n' "$live_body" | grep -n 'drush sql:drop' | head -1 | cut -d: -f1)
  [ -n "$m_live" ] && [ -n "$d_live" ] && [ "$m_live" -lt "$d_live" ]

  pair_body=$(awk '/^cmd_reset_paired\(\)/,/^}/' "$DEMO_CMD")
  m_pair=$(printf '%s\n' "$pair_body" | grep -n 'impact_render' | head -1 | cut -d: -f1)
  i_pair=$(printf '%s\n' "$pair_body" | grep -n 'ddev import-db' | head -1 | cut -d: -f1)
  [ -n "$m_pair" ] && [ -n "$i_pair" ] && [ "$m_pair" -lt "$i_pair" ]

  # EVERY body that wipes must build a manifest: no destructive verb is exempt.
  for fn in cmd_reset cmd_reset_live cmd_reset_paired; do
    b=$(awk "/^${fn}\\(\\)/,/^}/" "$DEMO_CMD")
    if ! printf '%s\n' "$b" | grep -qE 'demo_reset_manifest|impact_render'; then
      echo "FAIL: ${fn} destroys without building a fate manifest" >&2; return 1
    fi
  done
}

@test "a LIVE wipe confirms at the TYPED tier; dev/stg at standard" {
  grep -q 'impact_confirm typed "\${DEMO_LIVE_DOMAIN:-\$site}"' "$DEMO_CMD"
  grep -q 'impact_confirm standard "ERASE' "$DEMO_CMD"
  # the hand-rolled y/N prompts are gone — one confirmation path, not three
  ! grep -q 'This will ERASE' "$DEMO_CMD"
  # …and no destructive body may prompt on its own instead of via
  # impact_confirm. Checked on CODE lines only (same rule as lib/impact.sh's
  # own gate): a comment that NAMES the banned pattern is documentation, not a
  # violation — the note explaining why cmd_reset_paired must not hand-roll a
  # prompt would otherwise fail the very test it exists to explain.
  for fn in cmd_reset cmd_reset_live cmd_reset_paired; do
    b=$(awk "/^${fn}\\(\\)/,/^}/" "$DEMO_CMD" | grep -vE '^[[:space:]]*#')
    if ! printf '%s\n' "$b" | grep -q 'impact_confirm'; then
      echo "FAIL: ${fn} destroys without calling impact_confirm" >&2; return 1
    fi
    if printf '%s\n' "$b" | grep -qE 'read -r reply|This will ERASE'; then
      echo "FAIL: ${fn} hand-rolls its own prompt instead of impact_confirm" >&2; return 1
    fi
  done
}

@test "the manifest is rendered ahead of the Solo deploy gate (see it, then touch)" {
  m_live=$(grep -n 'demo_reset_manifest "\$site" live' "$DEMO_CMD" | head -1 | cut -d: -f1)
  gate=$(grep -n 'deploy_gate_require "\$site" "live"' "$DEMO_CMD" | head -1 | cut -d: -f1)
  [ -n "$m_live" ] && [ -n "$gate" ]
  [ "$m_live" -lt "$gate" ]
}

@test "reset --dry-run stops after the report, before the gate and the wipe" {
  grep -q 'dry-run\] nothing was touched' "$DEMO_CMD"
  # Per destructive body: a verb that accepts --dry-run and wipes anyway is the
  # worst possible outcome of this flag. cmd_reset_paired shipped exactly that
  # in its first cut — it took no dry_run argument at all and the dispatch
  # silently dropped the operator's --dry-run.
  for pair in "cmd_reset:ddev import-db" "cmd_reset_paired:ddev import-db" \
              "cmd_reset_live:drush sql:drop"; do
    fn="${pair%%:*}"; wipe="${pair#*:}"
    b=$(awk "/^${fn}\\(\\)/,/^}/" "$DEMO_CMD")
    d=$(printf '%s\n' "$b" | grep -n 'dry-run\] nothing was touched' | head -1 | cut -d: -f1)
    i=$(printf '%s\n' "$b" | grep -Fn "$wipe" | head -1 | cut -d: -f1)
    if [ -z "$d" ] || [ -z "$i" ] || [ "$d" -ge "$i" ]; then
      echo "FAIL: ${fn} wipes with no --dry-run stop before it (dry=${d:-none} wipe=${i:-none})" >&2
      return 1
    fi
  done
  run bash "$DEMO_CMD" --help
  [[ "$output" == *"--dry-run"* ]]
}

@test "the nightly path passes -y but never suppresses the report" {
  awk '/^cmd_nightly\(\)/,/^}/' "$DEMO_CMD" | grep -q 'cmd_reset "\$site" "\$tier" "30m" "true" "false" "false"'
}

# --- config parity gate (ops#145) ---------------------------------------------
#
# nwd was rebuilt on 2026-07-25 by a profile reinstall. Drupal reads a module's
# config/install once, at install time, and ConfigInstaller silently skips any
# item whose dependencies are unmet at that instant — under site:install/recipe
# (config syncing on for the whole run) that was 99 items, including the /apply
# webform the homepage links to. `pl demo golden` then froze the incomplete site
# into the image the nightly restores. These lock the gate that stops a repeat.

@test "parity verdict PASSES a site whose own modules' config is fully installed" {
  run bash -c "source '$DEMO_CMD'
               demo_parity_verdict demo1 live 'TOTAL_CUSTOM 0
TOTAL_VENDOR 53'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Config parity"* ]]
  # core/contrib defaults are reported but explicitly NOT gating
  [[ "$output" == *"53 core/contrib default(s) absent"* ]]
  [[ "$output" == *"not gating"* ]]
}

@test "parity verdict FAILS on missing custom config and names each item + module" {
  run bash -c "source '$DEMO_CMD'
               demo_parity_verdict demo1 live 'MISSING custom webform.webform.apply nwc_registration
MISSING custom nwc_help.topic.getting_started nwc_help
TOTAL_CUSTOM 2
TOTAL_VENDOR 53'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Config parity FAILED: 2 config item(s)"* ]]
  [[ "$output" == *"webform.webform.apply"* ]]      # the actual ops#133 casualty
  [[ "$output" == *"nwc_registration"* ]]           # attributed to its module
  [[ "$output" == *"nwc:config-heal"* ]]            # remedy is offered
}

@test "parity verdict is FAIL-CLOSED: an incomplete probe is never a pass" {
  # No TOTAL_CUSTOM line at all (probe died, ssh truncated, drush bootstrap failed).
  run bash -c "source '$DEMO_CMD'
               demo_parity_verdict demo1 live 'PHP Fatal error: something'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not complete"* ]]
  [[ "$output" == *"never captured as a golden"* ]]

  # Empty output must also fail, not silently pass.
  run bash -c "source '$DEMO_CMD' ; demo_parity_verdict demo1 live ''"
  [ "$status" -ne 0 ]

  # A non-numeric total must fail rather than being coerced to 0.
  run bash -c "source '$DEMO_CMD' ; demo_parity_verdict demo1 live 'TOTAL_CUSTOM unknown'"
  [ "$status" -ne 0 ]
}

@test "a parity failure is recorded in the demo log (auditable, like every guard)" {
  bash -c "source '$DEMO_CMD'
           demo_parity_verdict demo1 live 'MISSING custom node.type.codoc nwc_collab
TOTAL_CUSTOM 1
TOTAL_VENDOR 53'" >/dev/null 2>&1 || true
  run cat "$(demo_log_file demo1)"
  [[ "$output" == *"parity-failed"* ]]
  [[ "$output" == *"custom=1"* ]]
}

@test "golden capture runs the parity gate BEFORE dumping anything (both tiers)" {
  # Ordering is the whole point: a failure must cost nothing and must leave the
  # previous golden in place. Assert INSIDE each capture function, so the
  # helper definitions earlier in the file cannot satisfy this by accident.
  run bash -c "sed -n '/^cmd_golden() {/,/^}/p' '$DEMO_CMD' \
               | grep -n 'demo_parity_check_local\|ddev export-db'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"demo_parity_check_local"* ]]
  [[ "${lines[1]}" == *"export-db"* ]]

  # ops#168 moved the Drupal dump string into demo_drupal_dump_cmd (so the
  # log-table exclusions are unit-assertable), so this now matches the BUILDER
  # CALLS rather than the drush string. Same guarantee, and stronger: BOTH
  # kinds' dumps must come after the gate, not just the Drupal one.
  run bash -c "sed -n '/^cmd_golden_live() {/,/^}/p' '$DEMO_CMD' \
               | grep -n 'demo_parity_check_live\|demo_moodle_dump_cmd\|demo_drupal_dump_cmd'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"demo_parity_check_live"* ]]
  [[ "${lines[1]}" == *"demo_moodle_dump_cmd"* ]]
  [[ "${lines[2]}" == *"demo_drupal_dump_cmd"* ]]
}

@test "the parity override is opt-in, off by default, and logged" {
  run bash -c "grep -c 'allow_gaps=\"false\"' '$DEMO_CMD'"
  [ "$output" -ge 1 ]                                   # default is refuse
  run grep -q 'parity-overridden' "$DEMO_CMD"
  [ "$status" -eq 0 ]                                   # override leaves a trace
  run bash "$DEMO_CMD" --help
  [[ "$output" == *"--allow-config-gaps"* ]]
}

@test "the parity probe ships, parses, and reports both scopes fail-closed" {
  probe="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )/lib/probes/config-parity.php"
  [ -f "$probe" ]
  if command -v php >/dev/null 2>&1; then
    run php -l "$probe"
    [ "$status" -eq 0 ]
  fi
  # The two totals the bash side parses must both be emitted.
  run grep -c 'TOTAL_CUSTOM\|TOTAL_VENDOR' "$probe"
  [ "$output" -ge 2 ]
  # Scope must be decided by a custom/ path segment, not by guessing at names.
  run grep -q "custom/" "$probe"
  [ "$status" -eq 0 ]
}

# --- G: a code-issuing verb must NAME its tier ---------------------------------
#
# `pl demo invite nwd` — the exact command every guide printed — issued three
# fresh codes and then pushed the hashes into the LOCAL nwd-dev DDEV project,
# because main() defaults tier to "dev". nwd LIVE received nothing, and the
# operator saw a success. Corroborated on the real registry: 19 codes issued,
# 19 revoked, not one of them ever reachable from the live site.
#
# The fix is NOT to flip the default to live — that is the same bug pointing at
# a real host. Anything that writes or syncs codes must say which tier it means.

@test "invite REFUSES when no tier was named, and burns no code doing it" {
  run bash "$DEMO_CMD" invite demo1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--tier=live"* ]]        # both options are named…
  [[ "$output" == *"--tier=dev"* ]]
  # …and the refusal is BEFORE any state change: no registry, no draft dir.
  [ ! -e "$(demo_codes_file demo1)" ]
  [ ! -e "${PROJECT_ROOT}/sites/demo1/demo-invites" ]
}

@test "the guides never print a code-issuing command that would now be refused" {
  # The bug reached the operator through the docs: three guides printed
  # `pl demo invite nwd` verbatim. A guide that prints a command the CLI
  # refuses is worse than no guide, so pin it.
  docs="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )/docs/guides"
  for f in howto-invite-codes.md howto-demo-tier.md art9-golive-runbook.md; do
    [ -f "${docs}/${f}" ]
    # every `pl demo invite <site> …` line must carry a --tier (prose that
    # names the command without a site argument is not an instruction)
    run bash -c "grep -nE 'pl demo invite [a-z0-9]+' '${docs}/${f}' | grep -v -- '--tier='"
    [ "$status" -ne 0 ]
    # …and so must every mutating `pl demo codes …` line (list is exempt)
    run bash -c "grep -nE 'pl demo codes [a-z0-9]+ (issue|revoke|rotate|sync)' '${docs}/${f}' | grep -v -- '--tier='"
    [ "$status" -ne 0 ]
  done
}

@test "codes issue REFUSES when no tier was named, and never allocates an id" {
  run bash "$DEMO_CMD" codes demo1 issue tester-member
  [ "$status" -ne 0 ]
  [[ "$output" == *"--tier"* ]]
  [ ! -e "$(demo_codes_file demo1)" ]
  # a refused command that had already printed a plaintext code would be worse
  # than the bug it is guarding against. (Written as an explicit status check:
  # `! cmd` is exempt from set -e, so a bare negation asserts nothing in bats.)
  if [[ "$output" =~ [A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5} ]]; then
    echo "a refused 'codes issue' printed something that looks like a code" >&2
    return 1
  fi
}

@test "codes revoke|rotate|sync REFUSE when no tier was named" {
  # revoking at the wrong tier is the dangerous direction: the code stays live.
  for action in revoke rotate sync; do
    run bash "$DEMO_CMD" codes demo1 "$action" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"--tier"* ]]
  done
}

# NEGATIVE CONTROL — the guard must not be "refuse everything". Read-only and
# non-code verbs still work with no --tier, and an explicit dev still works.
@test "the tier guard is targeted: read-only verbs and an explicit tier still pass" {
  demo_enable_delivery
  run bash "$DEMO_CMD" status demo1
  [ "$status" -eq 0 ]
  run bash "$DEMO_CMD" codes demo1 list
  [ "$status" -eq 0 ]
  run bash "$DEMO_CMD" invite demo1 --tier=dev
  [ "$status" -eq 0 ]
  jq -e '.codes | length == 3' "$(demo_codes_file demo1)"
  run bash "$DEMO_CMD" codes demo1 issue tester-member --tier=dev
  [ "$status" -eq 0 ]
  jq -e '.codes | length == 4' "$(demo_codes_file demo1)"
}

# --- H: ops#173 — a host that cannot DELIVER must not MINT --------------------
#
# Naming the tier (guard G above) was necessary and not sufficient. The console
# host named --tier=live correctly every single time and still could not reach
# the box: `ssh gitlab@<box>` → Host key verification failed. It minted five
# codes, rendered a warm invitation naming them, printed OK, and delivered
# nothing. The operator mailed those codes to real testers and the live site —
# holding zero codes, because the nightly had restored an empty staged payload
# over the top — rejected every one.

@test "ops#173 invite REFUSES on a host with no delivery path, and mints nothing" {
  # A live site this host cannot reach: live.enabled, a domain, no server_ip.
  cat > "${PROJECT_ROOT}/sites/demo1/.nwp.yml" <<'EOF'
live:
  enabled: true
  domain: demo1.example.org
EOF
  run bash "$DEMO_CMD" invite demo1 --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"cannot deliver"* ]]
  # The refusal explains the model and names the way out, because the operator
  # in front of it is the one who cannot see the problem.
  [[ "$output" == *"ONE writable home"* ]]
  [[ "$output" == *"install-box.sh"* ]]
  # And it happens BEFORE anything is minted: no registry, no draft, no code
  # printed. A refusal that had already burned an id — or shown a plaintext the
  # operator might act on — would be worse than the bug.
  [ ! -e "$(demo_codes_file demo1)" ]
  [ ! -e "${PROJECT_ROOT}/sites/demo1/demo-invites" ]
  if [[ "$output" =~ [A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5} ]]; then
    echo "a refused invite printed something that looks like a code" >&2
    return 1
  fi
}

@test "ops#173 every code-WRITING verb is guarded, not just invite" {
  cat > "${PROJECT_ROOT}/sites/demo1/.nwp.yml" <<'EOF'
live:
  enabled: true
  domain: demo1.example.org
EOF
  # revoke is the sharpest: revoking where you cannot deliver leaves the code
  # live on the site while the local registry says it is gone.
  for action in issue revoke rotate sync; do
    run bash "$DEMO_CMD" codes demo1 "$action" tester-member --tier=live
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot deliver"* ]]
  done
  [ ! -e "$(demo_codes_file demo1)" ]
}

@test "ops#173 the guard is a real probe of the real path, not a host allowlist" {
  # NEGATIVE CONTROL. The same command that refuses above must SUCCEED the
  # moment a genuine delivery path exists — otherwise "refuse everything" would
  # pass every assertion in this section.
  demo_enable_delivery
  run bash "$DEMO_CMD" invite demo1 --tier=dev
  [ "$status" -eq 0 ]
  [[ "$output" != *"cannot deliver"* ]]
  jq -e '.codes | length == 3' "$(demo_codes_file demo1)"
}

@test "ops#173 the live delivery probe runs the real transport (ssh + remote drush)" {
  # A cheaper proxy — a ping, a config lookup — that succeeds where the real
  # write path fails would reproduce the bug with extra steps. Pin the probe to
  # the same two calls the sync itself makes.
  fn="$(sed -n '/^demo_codes_delivery_probe() {/,/^}/p' "$DEMO_CMD")"
  [ -n "$fn" ]
  [[ "$fn" == *"demo_live_ctx"* ]]
  [[ "$fn" == *"demo_rdrush"* ]]
  [[ "$fn" == *"nwc_demo_access.codes"* ]]
  # …and inside cmd_invite it is consulted BEFORE a code can exist.
  body="$(sed -n '/^cmd_invite() {/,/^}/p' "$DEMO_CMD")"
  [ -n "$body" ]
  guard=$(printf '%s\n' "$body" | grep -n 'demo_require_delivery' | head -1 | cut -d: -f1)
  mint=$(printf '%s\n'  "$body" | grep -n 'demo_generate_code'    | head -1 | cut -d: -f1)
  [ -n "$guard" ] && [ -n "$mint" ]
  [ "$guard" -lt "$mint" ]
}

# --- D2: the live config-parity probe is staged unpredictably ------------------
#
# demo_parity_check_live used to scp the probe to /tmp/nwp-config-parity-$$.php
# and then open it up to all readers — a name any local user can guess (the pid
# space is ~32k and /tmp is world-writable) on a file that drush then EXECUTES
# as the site user. Whoever wins that race chooses the PHP that runs as
# www-data.

@test "the parity probe is never staged at a PID-predictable, world-readable /tmp path" {
  # `run` + an explicit status check, NOT `! grep`: bash exempts `! cmd` from
  # set -e, so a bare negation in a bats test is an assertion that can never
  # fail. (Both of these did exactly nothing until this was rewritten.)
  run grep -nE 'nwp-config-parity-\$\$' "$DEMO_CMD"
  [ "$status" -ne 0 ]
  run grep -n 'chmod a+r' "$DEMO_CMD"
  [ "$status" -ne 0 ]
  fn="$(sed -n '/^demo_parity_check_live() {/,/^}/p' "$DEMO_CMD")"
  [ -n "$fn" ]
  [[ "$fn" == *"mktemp -d"* ]]     # the far side picks the name, exclusively
  [[ "$fn" != *"chmod"* ]]         # nothing is opened up after the fact
  [[ "$fn" == *"rm -rf"* ]]        # and it is always torn down
}

@test "demo_parity_check_live stages a readable probe in a private dir and removes it" {
  # A local simulation of the remote: demo_rssh runs the same shell commands
  # here, and a fake drush reports the mode + contents of what it was handed.
  # This exercises the real staging code, not a grep of it.
  probe="${TEST_TMP}/probe.php"
  printf '%s\n' '<?php echo "TOTAL_CUSTOM 0\n";' > "$probe"
  mkdir -p "${TEST_TMP}/siteroot/vendor/bin"
  cat > "${TEST_TMP}/siteroot/vendor/bin/drush" <<'EOF'
#!/bin/bash
# $1 = php:script, $2 = staged probe path
echo "STAGED_PATH $2"
echo "STAGED_MODE $(stat -c %a "$2")"
echo "STAGED_DIRMODE $(stat -c %a "$(dirname "$2")")"
cat "$2"
EOF
  chmod +x "${TEST_TMP}/siteroot/vendor/bin/drush"

  cat > "${TEST_TMP}/harness.sh" <<'EOF'
source "$DEMO_CMD"                      # BASH_SOURCE != $0 → no dispatch
demo_rssh() { shift; bash -c "$*"; }    # "remote" == here
demo_parity_verdict() { printf '%s\n' "$3"; return 0; }
DEMO_PARITY_PROBE="$PROBE"
DEMO_LIVE_PATH="$SITEROOT"
DEMO_LIVE_DRUSHSUDO=""
demo_parity_check_live demo1
EOF
  DEMO_CMD="$DEMO_CMD" PROBE="$probe" SITEROOT="${TEST_TMP}/siteroot" \
    run bash "${TEST_TMP}/harness.sh"
  [ "$status" -eq 0 ]

  staged="$(printf  '%s\n' "$output" | awk '/^STAGED_PATH /{print $2}')"
  mode="$(printf    '%s\n' "$output" | awk '/^STAGED_MODE /{print $2}')"
  dirmode="$(printf '%s\n' "$output" | awk '/^STAGED_DIRMODE /{print $2}')"

  # unguessable: the name came from mktemp, not from $$
  [[ "$staged" != *"$$"* ]]
  [[ "$staged" =~ ^/tmp/nwp-config-parity-[A-Za-z0-9]{6,}/ ]]
  # Nobody but the drush identity can read OR write it: staging under the same
  # user that executes the probe removes the need to widen anything at all.
  [ "$dirmode" = "700" ]
  [ "$mode" = "600" ]
  # the probe really arrived intact — a truncated probe fails CLOSED elsewhere,
  # so a silently empty file would read as a misleading parity FAILURE
  [[ "$output" == *"TOTAL_CUSTOM 0"* ]]
  # NEGATIVE CONTROL: passing by never staging anything is not an option — the
  # dir demonstrably existed, and it is demonstrably gone again afterwards.
  [ ! -e "$(dirname "$staged")" ]
}

@test "invite email: courses URL resolves the paired demo consumer's login" {
  # Regression for the 2026-07 invite bug: the email must name the courses
  # site (paired Moodle) login, resolved generically from the pair contract.
  run bash -c '
    source "'"$PWD"'/lib/common.sh" 2>/dev/null
    source "'"$PWD"'/lib/demo.sh" 2>/dev/null
    # fake a repo with a demo pair + global domains
    r="$(mktemp -d)"; mkdir -p "$r/pairs" "$r/sites/nwd" "$r/sites/ssd"
    cat > "$r/pairs/ssd.pair-contract.yml" <<YML
provider: nwd
consumer: ssd
demo: { enabled: true }
YML
    cat > "$r/nwp.yml" <<YML
sites:
  nwd: { live: { domain: nwd.example.test } }
  ssd: { live: { domain: ssd.example.test } }
YML
    export PROJECT_ROOT="$r"
    echo "COURSES=$(demo_invite_courses_url nwd)"
    echo "JOIN=$(demo_invite_join_url nwd)"
    rm -rf "$r"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"COURSES=https://ssd.example.test/login/index.php"* ]]
  [[ "$output" == *"JOIN=https://nwd.example.test/demo/join"* ]]
}

# --- demo-pilot audit 2026-07-31: live code-sync safety (A4-B3/M2/m2) ----------

@test "live code sync pins drush --input-format=string on BOTH paths (CodeRegistry fails closed on a non-string)" {
  # A drush default of --input-format=auto would parse the JSON payload into an
  # array; CodeRegistry::liveCodes() then rejects every invite code. Load-bearing.
  run grep -c 'state:set --input-format=string nwc_demo_access.codes' "$DEMO_CMD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "invite branches on the code-sync result and warns loudly on failure (not silent success)" {
  # Regression: cmd_invite used to swallow the sync rc with `|| true` and still
  # print OK, so an operator could hand out a code that reached no site. It now
  # branches on the rc and refuses to imply the code is usable when sync failed.
  grep -qF 'if demo_sync_codes_to_site "$site" "$tier"; then' "$DEMO_CMD"
  grep -q 'recipients would be REJECTED' "$DEMO_CMD"
}

@test "invite warns a live code won't survive the nightly box reset until re-staged (A4-B3)" {
  grep -q 'nightly reset restores the box' "$DEMO_CMD"
  grep -q 'install-box.sh --stage-codes' "$DEMO_CMD"
}

################################################################################
# nwp/ops#168 — the golden must not bake in LOG-TABLE ROWS.
#
# A golden is a reference image restored onto the live demo site every night, so
# any row inside it is immortal: it cannot age out, because the table that would
# age it out is replaced from the image at 01:00. The 2026-08-01 pair proved the
# cost. nwd's golden held 36 `watchdog` rows — 16 of them from ddev, with
# `/var/www/html/html/…` backtraces, plus the operator's personal email twice
# and a real public client IP nine times. ssd's held 4,521
# `mdl_logstore_standard_log` rows across 299 distinct public visitor IPs, 27 %
# of the entire dump. The observable damage was the monitoring channel: the
# nightly digest re-reported the identical two Error rows, with the identical
# timestamps, every night for ever.
#
# These assert the generated dump COMMAND, because that is the only place the
# guarantee lives before a capture runs — the alternative is unpacking a golden
# after the fact, which is how ops#168 had to be found in the first place.
################################################################################

@test "ops#168 Drupal: the live dump excludes the DATA of watchdog/sessions/flood" {
  run bash -c "source '$DEMO_CMD'
               demo_drupal_dump_cmd /var/www/nwd/html 'sudo -u www-data' '~/g.db.sql.gz'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--structure-tables-list=watchdog,sessions,flood"* ]]
  # still a gzipped drush dump landing where the caller asked
  [[ "$output" == *"drush sql:dump --gzip"* ]]
  [[ "$output" == *"> ~/g.db.sql.gz"* ]]
  [[ "$output" == "cd /var/www/nwd/html && sudo -u www-data "* ]]
}

@test "ops#168 Drupal: it is STRUCTURE-only, never an omission" {
  # --structure-tables-list keeps the CREATE TABLE and drops only the rows.
  # Omitting the table itself would break a site that logs on the next request,
  # so the two are not interchangeable and the wrong flag must not appear.
  run bash -c "source '$DEMO_CMD'
               demo_drupal_dump_cmd /var/www/nwd/html 'sudo -u www-data' '~/g.db.sql.gz'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--skip-tables-list"* ]]
  [[ "$output" != *"--skip-tables-key"* ]]
}

@test "ops#168 Drupal: the live capture USES the builder (no second, drifting command)" {
  # The exclusion is worthless if cmd_golden_live still hand-rolls its own drush
  # line. There must be exactly ONE `drush sql:dump` in the command script, and
  # it must be the builder's.
  grep -qF 'demo_rssh "$site" "$(demo_drupal_dump_cmd "${DEMO_LIVE_PATH}" "${DEMO_LIVE_DRUSHSUDO}" "~/${rdb}")"' "$DEMO_CMD"
  # exactly one place invokes drush's dumper (message strings don't count)
  run grep -c 'vendor/bin/drush sql:dump' "$DEMO_CMD"
  [ "$output" -eq 1 ]
}

@test "ops#168 Moodle: the dump is TWO passes — data minus the log tables, then their structure" {
  run bash -c "source '${REPO_ROOT}/lib/demo-live-moodle.sh'
               demo_moodle_dump_cmd ssdmoodle '~/g.db.sql.gz'"
  [ "$status" -eq 0 ]
  # pass 1: data, with the log tables ignored
  [[ "$output" == *"--ignore-table=ssdmoodle.mdl_logstore_standard_log"* ]]
  [[ "$output" == *"--ignore-table=ssdmoodle.mdl_task_log"* ]]
  [[ "$output" == *"--ignore-table=ssdmoodle.mdl_sessions"* ]]
  # pass 2: their SCHEMA comes back, or the restore leaves Moodle without them
  [[ "$output" == *"--no-data ssdmoodle mdl_logstore_standard_log mdl_task_log mdl_sessions"* ]]
  # ONE gzip, ONE artifact — the sha256 sidecar and the `gunzip -c` restore are
  # unchanged by this, and must stay that way
  [[ "$output" == *"| gzip > ~/g.db.sql.gz"* ]]
  [ "$(grep -c 'gzip >' <<<"$output")" -eq 1 ]
}

@test "ops#168 Moodle: mdl_sessions is excluded too — it was the WORSE offender, and it was missed" {
  # Measured on the ssd golden captured immediately AFTER the first ops#168 fix
  # landed: logstore was gone, and the artifact still carried 3,940
  # `mdl_sessions` rows holding 306 distinct public visitor IPs. Moodle writes a
  # session row for every ANONYMOUS request — the same fact that forces [G4] of
  # the box wrapper to count `userid <> 0`. Excluding the log tables alone moved
  # the visitor IPs from one table to another; it did not remove them.
  run bash -c "source '${REPO_ROOT}/lib/demo-live-moodle.sh'
               demo_moodle_dump_cmd ssdmoodle '~/g.db.sql.gz'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--ignore-table=ssdmoodle.mdl_sessions"* ]]
  [[ "$output" == *"--no-data"*"mdl_sessions"* ]]
}

@test "ops#168: the two halves agree about what a golden may contain (parity is the guard)" {
  # The Drupal half has excluded `sessions` since its first commit; the Moodle
  # half did not, and that DISAGREEMENT is how mdl_sessions was missed. Pin the
  # correspondence so the next table added to one side is visibly owed on the
  # other.
  local drupal moodle
  drupal="$(grep -oE '^DEMO_DRUPAL_NODATA_TABLES="[^"]*"' "${REPO_ROOT}/scripts/commands/demo.sh")"
  [[ "$drupal" == *"sessions"* ]]
  moodle="$(grep -oE '^DEMO_MOODLE_NODATA_TABLES="[^"]*"' "${REPO_ROOT}/lib/demo-live-moodle.sh")"
  [[ "$moodle" == *"mdl_sessions"* ]]
  # and each side keeps its own log table
  [[ "$drupal" == *"watchdog"* ]]
  [[ "$moodle" == *"mdl_logstore_standard_log"* ]]
}

@test "ops#168 Moodle: a plain --ignore-table alone would be a BUG, so the structure pass is mandatory" {
  # demo_moodle_droptables_cmd drops the WHOLE schema before importing. If the
  # dump omitted the CREATE TABLE along with the rows, the restored site would
  # simply not have those tables and Moodle fatals on the first log write. This
  # pins both halves of that reasoning together so neither can be edited alone.
  grep -q 'DROP TABLE IF EXISTS' "${REPO_ROOT}/lib/demo-live-moodle.sh"
  run bash -c "source '${REPO_ROOT}/lib/demo-live-moodle.sh'
               demo_moodle_dump_cmd ssdmoodle '~/g.db.sql.gz'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-data"* ]]
  # the passes are chained with && : a failed data pass must not be followed by
  # a structure pass that makes a truncated artifact look complete
  [[ "$output" == *"&& sudo mysqldump"* ]]
}

@test "ops#168 Moodle: the generated command is valid shell (a two-pass group is easy to mis-quote)" {
  run bash -c "source '${REPO_ROOT}/lib/demo-live-moodle.sh'
               cmd=\"\$(demo_moodle_dump_cmd ssdmoodle '~/g.db.sql.gz')\"
               bash -n <<< \"\$cmd\""
  [ "$status" -eq 0 ]
}

@test "ops#168 Moodle: the excluded set is overridable but defaults to both log tables" {
  run bash -c "source '${REPO_ROOT}/lib/demo-live-moodle.sh'
               DEMO_MOODLE_NODATA_TABLES='mdl_foo' demo_moodle_dump_cmd d '~/o'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--ignore-table=d.mdl_foo"* ]]
  [[ "$output" == *"--no-data d mdl_foo"* ]]
  [[ "$output" != *"mdl_logstore"* ]]
}

@test "ops#168 Moodle: --routines/--events survive (a dump that loses them restores an incomplete site)" {
  run bash -c "source '${REPO_ROOT}/lib/demo-live-moodle.sh'
               demo_moodle_dump_cmd ssdmoodle '~/g.db.sql.gz'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--single-transaction --quick --routines --events"* ]]
}

################################################################################
# nwp/ops#171 — the scheduler must be schedulable.
#
# `--via-key` exists so the scheduler needs no repo checkout, no admin key and
# no root on the box. It then resolved the box's address out of
# sites/<site>/.nwp.yml — which met does not have — so the one verb that
# installs the repo-free cron was the one thing that could not run on the
# repo-free host. Both nightly blocks (nwd and ssd) had to be generated on the
# workstation and installed by hand, and re-running the verb on the workstation
# would have rewritten the WORKSTATION's crontab instead.
################################################################################

# A crontab stub that RECORDS being handed anything, so "wrote nothing" is
# observable rather than assumed.
_stub_crontab() {
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/crontab" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then cat "$STUB_CRON" 2>/dev/null; exit 0; fi
touch "${STUB_CRON}.written"
cat > "$STUB_CRON"
STUB
  chmod +x "${TEST_TMP}/bin/crontab"
  export STUB_CRON="${TEST_TMP}/current.cron"
  rm -f "${STUB_CRON}.written"
}

_site_with_live() {   # $1 site  $2 server_ip
  mkdir -p "${PROJECT_ROOT}/sites/$1"
  cat > "${PROJECT_ROOT}/sites/$1/.nwp.yml" <<YML
schema_version: 2
project:
  name: $1
live:
  enabled: true
  domain: $1.example.com
  server_ip: $2
YML
}

@test "ops#171 --host overrides the site config (and is not second-guessed by it)" {
  _stub_crontab
  : > "$STUB_CRON"
  _site_with_live demo1 203.0.113.9      # config says .9 …

  PATH="${TEST_TMP}/bin:$PATH" run bash "$DEMO_CMD" schedule demo1 --tier=live --via-key --host 198.51.100.7
  [ "$status" -eq 0 ]
  grep -q '198.51.100.7' "$STUB_CRON"    # … the flag says .7, and the flag wins
  ! grep -q '203.0.113.9' "$STUB_CRON"
  grep -q 'demo1_demo_reset' "$STUB_CRON"
}

@test "ops#171 --via-key works with NO site config at all — that is the whole point of it" {
  # The met case verbatim: a checkout with no sites/ directory. Before ops#171
  # this printed "No live.server_ip / live.domain" and installed nothing.
  _stub_crontab
  : > "$STUB_CRON"
  rm -rf "${PROJECT_ROOT}/sites/demo1"

  PATH="${TEST_TMP}/bin:$PATH" run bash "$DEMO_CMD" schedule demo1 --tier=live --via-key --host gitlab@198.51.100.7
  [ "$status" -eq 0 ]
  grep -q 'gitlab@198.51.100.7' "$STUB_CRON"
  grep -q 'IdentitiesOnly=yes' "$STUB_CRON"
  grep -q 'IdentityAgent=none' "$STUB_CRON"
  grep -q -- '-F /dev/null' "$STUB_CRON"   # MR !262's anti-hijack fix, still there
}

@test "ops#171 NWP_DEMO_BOX_HOST is the env form of --host" {
  _stub_crontab
  : > "$STUB_CRON"
  rm -rf "${PROJECT_ROOT}/sites/demo1"

  PATH="${TEST_TMP}/bin:$PATH" NWP_DEMO_BOX_HOST=gitlab@198.51.100.7 \
    run bash "$DEMO_CMD" schedule demo1 --tier=live --via-key
  [ "$status" -eq 0 ]
  grep -q 'gitlab@198.51.100.7' "$STUB_CRON"
}

@test "ops#171 --host beats NWP_DEMO_BOX_HOST (the explicit flag is the last word)" {
  _stub_crontab
  : > "$STUB_CRON"
  rm -rf "${PROJECT_ROOT}/sites/demo1"

  PATH="${TEST_TMP}/bin:$PATH" NWP_DEMO_BOX_HOST=gitlab@10.0.0.1 \
    run bash "$DEMO_CMD" schedule demo1 --tier=live --via-key --host gitlab@198.51.100.7
  [ "$status" -eq 0 ]
  grep -q 'gitlab@198.51.100.7' "$STUB_CRON"
  ! grep -q '10.0.0.1' "$STUB_CRON"
}

@test "ops#171 --print-only writes NO crontab — not even reading one" {
  _stub_crontab
  printf '# unrelated\n30 2 * * * $HOME/bin/nwp-daily-audit\n' > "$STUB_CRON"
  _site_with_live demo1 203.0.113.9

  PATH="${TEST_TMP}/bin:$PATH" run bash "$DEMO_CMD" schedule demo1 --tier=live --via-key --print-only
  [ "$status" -eq 0 ]
  [ ! -e "${STUB_CRON}.written" ]           # crontab was never handed anything
  grep -q 'nwp-daily-audit' "$STUB_CRON"    # and the real one is untouched
  ! grep -q 'demo1_demo_reset' "$STUB_CRON"
  # no logs/ dir either: this machine is not the one that will run the job
  [ ! -d "${PROJECT_ROOT}/logs" ]
}

@test "ops#171 --print-only emits the block on STDOUT, byte-identical to what install writes" {
  # Why this matters: the operator pastes this into met's crontab. A SECOND
  # rendering could drift from the tested one — which is exactly how a block
  # missing `-F /dev/null` nearly went live on 2026-08-01.
  _stub_crontab
  : > "$STUB_CRON"
  _site_with_live demo1 203.0.113.9

  PATH="${TEST_TMP}/bin:$PATH" \
    bash "$DEMO_CMD" schedule demo1 --tier=live --via-key --print-only \
    2>/dev/null > "${TEST_TMP}/printed"

  PATH="${TEST_TMP}/bin:$PATH" \
    bash "$DEMO_CMD" schedule demo1 --tier=live --via-key >/dev/null 2>&1
  [ -e "${STUB_CRON}.written" ]

  # the installed crontab's last 3 lines ARE the block (marker, CRON_TZ, job)
  tail -3 "$STUB_CRON" > "${TEST_TMP}/installed"
  run diff -u "${TEST_TMP}/installed" "${TEST_TMP}/printed"
  [ "$status" -eq 0 ]
  [ -s "${TEST_TMP}/printed" ]
  grep -q 'NWP Demo Reset - demo1' "${TEST_TMP}/printed"
}

@test "ops#171 --print-only keeps stdout crontab-clean (diagnostics go to stderr)" {
  _stub_crontab
  : > "$STUB_CRON"
  _site_with_live demo1 203.0.113.9

  PATH="${TEST_TMP}/bin:$PATH" \
    bash "$DEMO_CMD" schedule demo1 --tier=live --via-key --print-only \
    2>/dev/null > "${TEST_TMP}/printed"
  # exactly 3 lines: a marker comment, CRON_TZ, one job. Nothing else may ride
  # along, or `--print-only >> crontab` installs prose as a cron line.
  [ "$(wc -l < "${TEST_TMP}/printed")" -eq 3 ]
  ! grep -q 'nothing was written' "${TEST_TMP}/printed"

  PATH="${TEST_TMP}/bin:$PATH" \
    bash "$DEMO_CMD" schedule demo1 --tier=live --via-key --print-only \
    2>"${TEST_TMP}/err" >/dev/null
  grep -q 'nothing was written to any crontab' "${TEST_TMP}/err"
}

@test "ops#171 --print-only carries the pair offset too (it is derived, not re-typed)" {
  _stub_crontab
  : > "$STUB_CRON"
  mkdir -p "${PROJECT_ROOT}/pairs"
  _site_with_live prov1 203.0.113.9
  _site_with_live cons1 203.0.113.9
  cat > "${PROJECT_ROOT}/pairs/cons1.pair-contract.yml" <<'YML'
pair: cons1-prov1
provider: prov1
consumer: cons1
demo:
  enabled: true
  paired_golden: true
  paired_reset: true
YML

  PATH="${TEST_TMP}/bin:$PATH" run bash "$DEMO_CMD" schedule cons1 --tier=live --via-key --print-only --host 198.51.100.7
  [ "$status" -eq 0 ]
  [[ "$output" == *"15,45 1-3 * * *"* ]]
  [ ! -e "${STUB_CRON}.written" ]
}

@test "ops#171 --print-only --remove is REFUSED (emit and delete are not one request)" {
  _stub_crontab
  printf '# unrelated\n30 2 * * * $HOME/bin/nwp-daily-audit\n' > "$STUB_CRON"

  PATH="${TEST_TMP}/bin:$PATH" run bash "$DEMO_CMD" schedule demo1 --print-only --remove
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  [ ! -e "${STUB_CRON}.written" ]
}

@test "ops#171 without --host and without site config, the refusal NAMES the way out" {
  _stub_crontab
  : > "$STUB_CRON"
  rm -rf "${PROJECT_ROOT}/sites/demo1"

  PATH="${TEST_TMP}/bin:$PATH" run bash "$DEMO_CMD" schedule demo1 --tier=live --via-key
  [ "$status" -ne 0 ]
  [[ "$output" == *"No live.server_ip"* ]]
  [[ "$output" == *"--host"* ]]
  [[ "$output" == *"NWP_DEMO_BOX_HOST"* ]]
  [ ! -e "${STUB_CRON}.written" ]
}

@test "ops#171 a bare --host says so instead of dying silently under set -e" {
  run bash "$DEMO_CMD" schedule demo1 --tier=live --via-key --host
  [ "$status" -eq 2 ]
  [[ "$output" == *"--host requires a value"* ]]
}

@test "ops#171 the help documents both new flags (an undocumented escape hatch is hand-work again)" {
  run bash "$DEMO_CMD" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--print-only"* ]]
  [[ "$output" == *"NWP_DEMO_BOX_HOST"* ]]
}

################################################################################
# nwp/ops#173 — THE THREE NUMBERS THAT MUST AGREE.
#
# A code only works if it is in all three places at once: the registry (what the
# operator believes they handed out), the site's state (what a tester's code is
# checked against today) and the box's staged payload (what the 01:00 reset
# restores over the top, so what works tomorrow). On 2026-08-01 they were 3, 25
# and 0 — across two hosts holding disjoint registries — and every one of them
# was one command away the whole time. Nothing compared them.
################################################################################

@test "ops#173 drift: three agreeing numbers are OK; any disagreement is DRIFT" {
  run demo_drift_state 25 25 25
  [ "$status" -eq 0 ]
  [[ "$output" == ok\|* ]]
  # the actual 2026-08-01 shape: registry 3, site 25, box staged 0
  run demo_drift_state 3 25 0
  [[ "$output" == drift\|* ]]
  [[ "$output" == *"registry=3"* ]]
  [[ "$output" == *"site=25"* ]]
  [[ "$output" == *"staged=0"* ]]
  # the one that matters most is the quiet one: today's site is right and the
  # box will erase it at 01:00.
  run demo_drift_state 25 25 0
  [[ "$output" == drift\|* ]]
}

@test "ops#173 drift: 'could not read' is NEVER 'zero'" {
  # This distinction is the whole issue. An empty staged payload means every
  # invite code is about to be cleared; an unreadable one means we do not know.
  # They lead to opposite actions, so they must never render the same.
  run demo_drift_state 25 25 ""
  [[ "$output" == unknown\|* ]]
  [[ "$output" == *"staged=?"* ]]
  run demo_drift_state 25 25 0
  [[ "$output" == drift\|* ]]
  # and a proven disagreement outranks a missing reading — we already know
  # something is wrong, so say so rather than shrugging.
  run demo_drift_state 3 25 ""
  [[ "$output" == drift\|* ]]
}

@test "ops#173 drift: 'not applicable' is a third thing again (dev has no box)" {
  run demo_drift_state 4 4 -
  [[ "$output" == ok\|* ]]
  [[ "$output" != *"staged"* ]]     # not reported at all, not reported as zero
}

@test "ops#173 payload counting: empty is 0, absent is unknown" {
  run demo_payload_count '{"version":1,"codes":[]}'
  [ "$output" = "0" ]
  run demo_payload_count '{"version":1,"codes":[{"bundle":"tester-member","hash":"x","expires":1}]}'
  [ "$output" = "1" ]
  run demo_payload_count ''
  [ "$output" = "" ]
  run demo_payload_count 'not json at all'
  [ "$output" = "" ]
}

@test "ops#173 registry counting honours revoked + expired (that is what 'active' means)" {
  cfile="$(demo_codes_file demo1)"
  now=$(date +%s)
  demo_code_add "$cfile" c1 tester-member "$(printf a | sha256sum | awk '{print $1}')" "$((now + 600))"
  demo_code_add "$cfile" c2 tester-member "$(printf b | sha256sum | awk '{print $1}')" "$((now + 600))"
  demo_code_add "$cfile" c3 tester-member "$(printf c | sha256sum | awk '{print $1}')" "$((now - 600))"
  demo_code_revoke "$cfile" c2
  run demo_codes_active_count "$cfile"
  [ "$output" = "1" ]
  # a registry that does not exist really does hold no codes
  run demo_codes_active_count "${TEST_TMP}/nope.json"
  [ "$output" = "0" ]
}

@test "ops#173 a record nobody has ever written is a FINDING, not a pass" {
  # The console host held a code registry it had never once compared against
  # the site, for the whole pilot. Silence there is what let ops#173 run.
  run demo_drift_report "${TEST_TMP}/absent.json"
  [[ "$output" == missing\|* ]]

  rec="${TEST_TMP}/rec.json"
  demo_drift_record demo1 live 25 25 25 testhost > "$rec"
  jq -e '.registry_active == 25 and .site_live == 25 and .staged_payload == 25' "$rec"
  jq -e '.verdict == "ok"' "$rec"
  run demo_drift_report "$rec"
  [[ "$output" == ok\|* ]]
  [[ "$output" == *"tier=live"* ]]

  # …and it ages out: yesterday's agreement is not today's evidence.
  now=$(date +%s)
  run demo_drift_report "$rec" 3600 "$((now + 7200))"
  [[ "$output" == stale\|* ]]
}

@test "ops#173 the record keeps unknown as null and n/a as a string (not 0)" {
  rec="${TEST_TMP}/rec2.json"
  demo_drift_record demo1 dev 4 "" - testhost > "$rec"
  jq -e '.registry_active == 4' "$rec"
  jq -e '.site_live == null' "$rec"
  jq -e '.staged_payload == "n/a"' "$rec"
  jq -e '.verdict == "unknown"' "$rec"
}

@test "ops#173 'pl demo codes <site> drift' reports all three and records them" {
  demo_enable_delivery                 # dev path answers; no box at this tier
  run bash "$DEMO_CMD" codes demo1 drift --tier=dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"registry-active"* ]]
  [[ "$output" == *"site-live"* ]]
  [[ "$output" == *"staged-payload"* ]]
  [ -s "$(demo_drift_file demo1)" ]
  jq -e '.site == "demo1" and .tier == "dev"' "$(demo_drift_file demo1)"
}

@test "ops#173 drift is READ-ONLY — it needs no tier guard and writes to no site" {
  # It must be safe to run at any moment, including from a host that is about
  # to be told it may not write. So it is deliberately outside both guards.
  fn="$(sed -n '/^cmd_codes() {/,/^}/p' "$DEMO_CMD")"
  # both guards list exactly the four WRITING verbs…
  [ "$(printf '%s\n' "$fn" | grep -c 'issue|revoke|rotate|sync)')" -eq 2 ]
  # …and drift appears only as its own case arm, never inside a guard list
  [ "$(printf '%s\n' "$fn" | grep -cE '^ *drift\)')" -eq 1 ]
  run bash "$DEMO_CMD" codes demo1 drift          # …and needs no --tier
  [ "$status" -eq 0 ]
}

@test "ops#173 status surfaces the delivery state without probing anything" {
  # `pl demo status` runs often and must stay fast and read-only, so it reads
  # the record rather than opening two ssh connections to re-derive it.
  demo_codes_init "$(demo_codes_file demo1)"
  run bash "$DEMO_CMD" status demo1
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEVER checked"* ]]

  mkdir -p "$(demo_drift_dir)"
  demo_drift_record demo1 live 25 25 0 testhost > "$(demo_drift_file demo1)"
  run bash "$DEMO_CMD" status demo1
  [ "$status" -eq 0 ]
  [[ "$output" == *"CODE DRIFT"* ]]
  [[ "$output" == *"staged=0"* ]]
}

@test "ops#173 a successful LIVE sync records what it saw, so nothing has to remember to look" {
  fn="$(sed -n '/^demo_sync_codes_to_site() {/,/^}/p' "$DEMO_CMD")"
  [[ "$fn" == *"demo_drift_record_save"* ]]
}

@test "ops#173 the staged-payload path matches what install-box.sh actually writes" {
  # The box path is asserted in two files; if they drift, the drift check reads
  # a file that does not exist and reports 'could not tell' for ever.
  run demo_box_codes_payload nwd
  [ "$output" = "/var/lib/nwp-demo/nwd/codes-payload.json" ]
  ib="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )/servers/live/demo/install-box.sh"
  grep -q 'STATE_DIR="/var/lib/nwp-demo/${DEMO_SITE}"' "$ib"
  grep -q "codes-payload.json" "$ib"
}

@test "ops#173.4 yq is found in ~/.local/bin, not just on PATH" {
  # On the console host yq lives in ~/.local/bin, which systemd does not put on
  # a user service's PATH. `command -v yq` therefore failed, live.domain never
  # resolved, and EVERY invitation went out with <YOUR-SITE-URL> placeholders —
  # silently, because the placeholder exists so the draft always renders.
  # yq is a declared required tool for this suite (NWP_BATS_REQUIRED_TOOLS), so
  # this is an assertion, not a skip — the CI skip budget is an equality
  # contract and a conditional skip here would move it.
  real_yq="$(command -v yq)"
  [ -n "$real_yq" ]
  home="${TEST_TMP}/fakehome"
  mkdir -p "${home}/.local/bin"
  ln -s "$real_yq" "${home}/.local/bin/yq"

  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  cat > "${PROJECT_ROOT}/sites/demo1/.nwp.yml" <<'EOF'
live:
  domain: demo1.example.org
EOF
  # PATH must be CONTROLLED, not inherited-by-convention: `/usr/bin:/bin` holds
  # a system yq on some runners (met-shell) and not on others (the console
  # host / this laptop), which made this test runner-dependent — it failed on
  # nwp!273's pipeline for exactly that reason. demo_invite_join_url needs only
  # bash builtins plus yq itself, so an EMPTY PATH dir isolates the lookup
  # completely: the only yq that can ever be found is the one in $HOME/.local/bin.
  # bash is invoked by absolute path because env(1) cannot resolve it otherwise.
  emptybin="${TEST_TMP}/emptybin"; mkdir -p "$emptybin"
  run env -i HOME="$home" PATH="$emptybin" PROJECT_ROOT="$PROJECT_ROOT" \
      /bin/bash -c 'source "'"$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"'/lib/demo.sh"; demo_invite_join_url demo1'
  [ "$status" -eq 0 ]
  [[ "$output" == "https://demo1.example.org/demo/join" ]]
  [[ "$output" != *"<YOUR-SITE-URL>"* ]]

  # NEGATIVE CONTROL: with no yq anywhere the placeholder still renders, because
  # a draft that fails to render is worse than one with a visible gap.
  run env -i HOME="${TEST_TMP}/emptyhome" PATH="$emptybin" PROJECT_ROOT="$PROJECT_ROOT" \
      /bin/bash -c 'source "'"$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"'/lib/demo.sh"; demo_invite_join_url demo1'
  [ "$status" -eq 0 ]
  [[ "$output" == "<YOUR-SITE-URL>/demo/join" ]]
}

################################################################################
# nwp/ops#173 item 3 — the drift check has to reach `pl rag`.
#
# The requirement was explicitly "wire it into the existing RAG machinery rather
# than inventing a parallel one". So the comparison is a `pl todo` check
# (check_demo_code_drift), which is the input `pl rag` already grades and
# `pl rag --sync-issues` already turns into a tracked nwp/ops issue. A bespoke
# demo-monitor script would have been a second thing nobody looks at, which is
# the failure mode this issue is about.
################################################################################

# Run check_demo_code_drift against a throwaway tree and print the items it made.
_run_dcd() {   # $1 = fixture root
  TODO_CHECKS_PROJECT_ROOT="$1" TODO_CONFIG_FILE="$1/nwp.yml" \
  bash -c '
    source "'"$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"'/lib/todo-checks.sh"
    todo_clear_items
    check_demo_code_drift
    todo_output_items
  '
}

_dcd_fixture() {  # $1 = root; creates a site with a registry
  mkdir -p "$1/sites/nwd" "$1/private/demo-codes" "$1/lib"
  cp "$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )/lib/demo.sh" "$1/lib/demo.sh"
  printf '{"version":1,"codes":[]}\n' > "$1/sites/nwd/demo-codes.json"
  printf 'sites: {}\n' > "$1/nwp.yml"
}

@test "ops#173 pl todo reports DRIFT for a demo site whose three numbers disagree" {
  root="${TEST_TMP}/dcd1"; _dcd_fixture "$root"
  PROJECT_ROOT="$root" demo_drift_record nwd live 25 25 0 h > "$root/private/demo-codes/nwd.json"
  run _run_dcd "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"category":"DCD"'* ]]
  [[ "$output" == *'"site":"nwd"'* ]]
  [[ "$output" == *"DISAGREE"* ]]
  # AMBER, not RED: rag-render reserves RED for SEC/TOK. This must show up as
  # "needs attention", which is what the issue asked for.
  [[ "$output" != *'"category":"SEC"'* ]]
  [[ "$output" != *'"category":"TOK"'* ]]
}

@test "ops#173 pl todo stays quiet when all three agree (the check is not a nag)" {
  root="${TEST_TMP}/dcd2"; _dcd_fixture "$root"
  PROJECT_ROOT="$root" demo_drift_record nwd live 25 25 25 h > "$root/private/demo-codes/nwd.json"
  run _run_dcd "$root"
  [ "$status" -eq 0 ]
  [[ "$output" != *"DCD"* ]]
}

@test "ops#173 pl todo reports a host that has NEVER looked, and one whose look is stale" {
  root="${TEST_TMP}/dcd3"; _dcd_fixture "$root"
  run _run_dcd "$root"                       # no record at all
  [[ "$output" == *"DCD-nwd-unchecked"* ]]
  [[ "$output" == *"NEVER checked"* ]]

  # a record from four days ago, with the default 48h window
  PROJECT_ROOT="$root" demo_drift_record nwd live 25 25 25 h \
    | python3 -c 'import json,sys,time; d=json.load(sys.stdin); d["checked_epoch"]=int(time.time())-4*86400; print(json.dumps(d))' \
    > "$root/private/demo-codes/nwd.json"
  run _run_dcd "$root"
  [[ "$output" == *"DCD-nwd-stale"* ]]
  [[ "$output" == *"unverified"* ]]
}

@test "ops#173 the check does nothing on a host that holds no demo registry" {
  root="${TEST_TMP}/dcd4"
  mkdir -p "$root/sites/other" "$root/lib"
  cp "$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )/lib/demo.sh" "$root/lib/demo.sh"
  printf 'sites: {}\n' > "$root/nwp.yml"
  run _run_dcd "$root"
  [ "$status" -eq 0 ]
  [[ "$output" != *"DCD"* ]]
}

@test "ops#173 check_demo_code_drift is actually WIRED into the todo run, not just defined" {
  # A check that exists and is never called is the same as no check. It has to
  # be in the registry `run_all_checks` iterates and exported like its peers.
  lib="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )/lib/todo-checks.sh"
  grep -q '"check_demo_code_drift:Demo invite-code drift"' "$lib"
  grep -q '^export -f check_demo_code_drift' "$lib"
  # and rag-render must grade it AMBER: DCD is deliberately not a security cat
  run grep -n 'SEC_CATS=' "$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )/lib/rag-render.py"
  [[ "$output" != *"DCD"* ]]
}

@test "ops#173 pl todo lists DCD in its category legend (an unexplained code is noise)" {
  run bash "$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )/scripts/commands/todo.sh" --help
  [[ "$output" == *"DCD"* ]]
}
