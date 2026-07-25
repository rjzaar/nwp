#!/usr/bin/env bats
# ops#133 Phase 2 — paired golden/reset for the demo tier.
#
# Pure-logic + static tests only: no ddev/drush/mysql is ever invoked (a real
# paired reset wipes two sites). The contract resolution, the OPT-IN gate, the
# cut manifest and the refusals are exercised directly; the ORDERING guarantees
# (refuse-before-destroy, provider-first, harvest-before-wipe) are asserted
# statically against the command script.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/pairs" \
           "${PROJECT_ROOT}/sites/prov" "${PROJECT_ROOT}/sites/cons"
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  source "${REPO_ROOT}/lib/demo.sh"
  source "${REPO_ROOT}/lib/demo-pair.sh"
  DEMO_CMD="${REPO_ROOT}/scripts/commands/demo.sh"
  DEMO_LIB="${REPO_ROOT}/lib/demo-pair.sh"

  # A minimal demo-enabled contract.
  cat > "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" <<'YML'
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
demo:
  enabled: true
  paired_golden: true
  paired_reset: true
  feedback_path: /feedback/submit
endpoints:
  dev:
    issuer: "https://prov-dev.ddev.site"
oidc:
  issuer_name: "prov (F26)"
  user_field_mappings:
    sub: idnumber
    email: email
    given_name: firstname
    family_name: lastname
YML
  # A pair contract that has NOT opted in (stands in for ssc↔nwc).
  cat > "${PROJECT_ROOT}/pairs/real.pair-contract.yml" <<'YML'
pair: real-realprov
contract_version: 1
provider: realprov
consumer: real
endpoints:
  dev:
    issuer: "https://realprov-dev.ddev.site"
YML
  cat > "${PROJECT_ROOT}/sites/prov/.nwp.yml" <<'YML'
project:
  name: prov
  type: drupal
YML
  cat > "${PROJECT_ROOT}/sites/cons/.nwp.yml" <<'YML'
project:
  name: cons
  type: moodle
moodle:
  dataroot_host: sites/cons_moodledata
YML
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset PROJECT_ROOT
}

# Build a fake golden dir with a valid manifest for <site> in <dir>.
_fake_golden() {
  local dir="$1" site="$2" seed="${3:-x}"
  mkdir -p "$dir"
  printf '%s' "db-$seed"    > "$dir/golden.db.sql.gz"
  printf '%s' "files-$seed" > "$dir/golden.files.tar.gz"
  ( cd "$dir" && sha256sum golden.db.sql.gz    > golden.db.sql.gz.sha256 )
  ( cd "$dir" && sha256sum golden.files.tar.gz > golden.files.tar.gz.sha256 )
  demo_manifest_write "$dir" "$site" golden.db.sql.gz golden.files.tar.gz
}

# --- contract resolution + the OPT-IN gate -----------------------------------

@test "demo_pair_contract_for finds the contract from EITHER side" {
  run demo_pair_contract_for prov
  [ "$status" -eq 0 ]
  [[ "$output" == *"cons.pair-contract.yml" ]]
  run demo_pair_contract_for cons
  [ "$status" -eq 0 ]
  [[ "$output" == *"cons.pair-contract.yml" ]]
}

@test "OPT-IN: a pair WITHOUT demo.enabled is invisible to the demo tier" {
  # This is the guard that keeps the real ssc<->nwc pair out of a nightly wipe.
  run demo_pair_contract_for real
  [ "$status" -ne 0 ]
  run demo_pair_contract_for realprov
  [ "$status" -ne 0 ]
}

@test "demo_pair_contract_for fails closed for an unpaired site" {
  run demo_pair_contract_for nosuchsite
  [ "$status" -ne 0 ]
}

@test "partner + role resolve from either end" {
  c="$(demo_pair_contract_for prov)"
  [ "$(demo_pair_partner prov "$c")" = "cons" ]
  [ "$(demo_pair_partner cons "$c")" = "prov" ]
  [ "$(demo_pair_role prov "$c")" = "provider" ]
  [ "$(demo_pair_role cons "$c")" = "consumer" ]
  run demo_pair_role stranger "$c"
  [ "$status" -ne 0 ]
}

@test "issuer is read per tier and FAILS CLOSED when the tier is absent" {
  c="$(demo_pair_contract_for cons)"
  [ "$(demo_pair_issuer "$c" dev)" = "https://prov-dev.ddev.site" ]
  run demo_pair_issuer "$c" live
  [ "$status" -ne 0 ]
}

@test "feature switches default OFF when the key is missing" {
  c="$(demo_pair_contract_for cons)"
  demo_pair_golden_enabled "$c"
  demo_pair_reset_enabled "$c"
  # Strip the switches: both must now refuse.
  sed -i 's/  paired_golden: true//; s/  paired_reset: true//' "$c"
  run demo_pair_golden_enabled "$c"
  [ "$status" -ne 0 ]
  run demo_pair_reset_enabled "$c"
  [ "$status" -ne 0 ]
}

# --- site kind ---------------------------------------------------------------

@test "demo_site_kind reads project.type and fails closed on anything else" {
  [ "$(demo_site_kind prov)" = "drupal" ]
  [ "$(demo_site_kind cons)" = "moodle" ]
  mkdir -p "${PROJECT_ROOT}/sites/weird"
  printf 'project:\n  type: wordpress\n' > "${PROJECT_ROOT}/sites/weird/.nwp.yml"
  run demo_site_kind weird
  [ "$status" -ne 0 ]
  run demo_site_kind absent
  [ "$status" -ne 0 ]
}

# --- the cut manifest --------------------------------------------------------

@test "cut write+verify: two goldens captured together are ONE cut" {
  pdir="${PROJECT_ROOT}/sites/prov/demo-golden"
  cdir="${PROJECT_ROOT}/sites/cons/demo-golden"
  _fake_golden "$pdir" prov p1
  _fake_golden "$cdir" cons c1
  cut="$(demo_pair_cut_file "$pdir")"
  run demo_pair_cut_write "$cut" cons-prov "$(demo_pair_contract_for cons)" dev cut1 \
      prov "$pdir" cons "$cdir"
  [ "$status" -eq 0 ]
  run demo_pair_cut_verify "$cut" prov "$pdir" cons "$cdir"
  [ "$status" -eq 0 ]
  [ "$(demo_pair_cut_id_of "$cut")" = "cut1" ]
}

@test "cut verify REFUSES when one half was re-captured alone (the real hazard)" {
  pdir="${PROJECT_ROOT}/sites/prov/demo-golden"
  cdir="${PROJECT_ROOT}/sites/cons/demo-golden"
  _fake_golden "$pdir" prov p1
  _fake_golden "$cdir" cons c1
  cut="$(demo_pair_cut_file "$pdir")"
  demo_pair_cut_write "$cut" cons-prov contract dev cut1 prov "$pdir" cons "$cdir"
  # Re-capture ONLY the consumer — exactly what a well-meaning operator does.
  _fake_golden "$cdir" cons c2
  run demo_pair_cut_verify "$cut" prov "$pdir" cons "$cdir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PAIR CUT BROKEN"* ]]
  [[ "$output" == *"cons"* ]]
}

@test "cut verify REFUSES a cut written for a different pair" {
  pdir="${PROJECT_ROOT}/sites/prov/demo-golden"
  cdir="${PROJECT_ROOT}/sites/cons/demo-golden"
  _fake_golden "$pdir" prov p1
  _fake_golden "$cdir" cons c1
  cut="$(demo_pair_cut_file "$pdir")"
  demo_pair_cut_write "$cut" cons-prov contract dev cut1 prov "$pdir" cons "$cdir"
  run demo_pair_cut_verify "$cut" otherprov "$pdir" cons "$cdir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not"* ]]
}

@test "cut verify REFUSES when there is no cut at all" {
  pdir="${PROJECT_ROOT}/sites/prov/demo-golden"
  cdir="${PROJECT_ROOT}/sites/cons/demo-golden"
  _fake_golden "$pdir" prov p1
  _fake_golden "$cdir" cons c1
  run demo_pair_cut_verify "$(demo_pair_cut_file "$pdir")" prov "$pdir" cons "$cdir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No pair cut manifest"* ]]
}

@test "cut write REFUSES to bind a golden with no sha256 (unbindable cut)" {
  pdir="${PROJECT_ROOT}/sites/prov/demo-golden"
  cdir="${PROJECT_ROOT}/sites/cons/demo-golden"
  _fake_golden "$pdir" prov p1
  mkdir -p "$cdir"                     # consumer has NO manifest
  run demo_pair_cut_write "$(demo_pair_cut_file "$pdir")" cons-prov c dev cut1 \
      prov "$pdir" cons "$cdir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "cut ids are unique and sortable" {
  a="$(demo_pair_cut_id)"; b="$(demo_pair_cut_id)"
  [ "$a" != "$b" ]
  [[ "$a" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
}

# --- harvest co-location -----------------------------------------------------

@test "demo_harvest_as spools the CONSUMER's digest into the PROVIDER's dir" {
  run demo_harvest_as prov cons dev printf 'moodle boom\n'
  [ "$status" -eq 0 ]
  spool="$(ls "${PROJECT_ROOT}/sites/prov/demo-harvest/"*.md)"
  [ -f "$spool" ]
  grep -q 'cons (dev)' "$spool"
  grep -q 'demo-tester,auto-harvest' "$spool"
  grep -q 'moodle boom' "$spool"
  # Nothing was written into the consumer's own spool.
  [ ! -d "${PROJECT_ROOT}/sites/cons/demo-harvest" ]
}

@test "demo_harvest_as never clobbers a same-second sibling digest" {
  demo_harvest_as prov prov dev printf 'a\n'
  demo_harvest_as prov cons dev printf 'b\n'
  n="$(ls "${PROJECT_ROOT}/sites/prov/demo-harvest/" | wc -l)"
  [ "$n" -eq 2 ]
}

@test "demo_harvest_as keeps the fail-OPEN contract (always exit 0)" {
  run demo_harvest_as prov cons dev false
  [ "$status" -eq 0 ]
  run demo_harvest_as prov cons dev
  [ "$status" -eq 0 ]
  grep -q 'harvest-failed' "${PROJECT_ROOT}/sites/prov/demo-reset.log"
}

@test "demo_harvest (legacy 2-arg form) still spools to its own site" {
  run demo_harvest prov dev printf 'drupal boom\n'
  [ "$status" -eq 0 ]
  grep -q 'drupal boom' "${PROJECT_ROOT}/sites/prov/demo-harvest/"*.md
}

# --- command-level refusals --------------------------------------------------

@test "--with-pair REFUSES when the site is not in a demo-enabled pair" {
  run bash "$DEMO_CMD" golden real --with-pair
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in a demo-enabled pair"* ]]
}

@test "--with-pair REFUSES when the partner has no instance at this tier" {
  # No .ddev anywhere under sites/ ⇒ demo_project_dir fails for the partner.
  run bash "$DEMO_CMD" golden prov --with-pair
  [ "$status" -ne 0 ]
  [[ "$output" == *"no instance at tier"* ]]
}

@test "paired capture REFUSES --tier=live (not implemented in Phase 2)" {
  run bash "$DEMO_CMD" golden prov --with-pair --tier=live
  [ "$status" -ne 0 ]
}

# --- static ORDERING guarantees ----------------------------------------------

@test "paired reset verifies BOTH goldens and the cut BEFORE any import-db" {
  verify_line=$(grep -n 'demo_pair_cut_verify "$cut"' "$DEMO_CMD" | head -1 | cut -d: -f1)
  import_line=$(awk '/^cmd_reset_paired\(\)/,0' "$DEMO_CMD" | grep -n 'ddev import-db' | head -1 | cut -d: -f1)
  start=$(grep -n '^cmd_reset_paired()' "$DEMO_CMD" | cut -d: -f1)
  [ -n "$verify_line" ] && [ -n "$import_line" ]
  [ "$verify_line" -lt $(( start + import_line )) ]
}

@test "paired reset harvests BOTH halves BEFORE the first import-db" {
  body=$(awk '/^cmd_reset_paired\(\)/,/^}/' "$DEMO_CMD")
  h=$(printf '%s\n' "$body" | grep -n 'demo_harvest_as' | head -1 | cut -d: -f1)
  i=$(printf '%s\n' "$body" | grep -n 'ddev import-db' | head -1 | cut -d: -f1)
  [ -n "$h" ] && [ -n "$i" ] && [ "$h" -lt "$i" ]
}

@test "paired reset restores PROVIDER FIRST (ADR-0031 D5)" {
  body=$(awk '/^cmd_reset_paired\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'for half in provider consumer'
  # and never the reverse
  ! printf '%s\n' "$body" | grep -q 'for half in consumer provider'
}

@test "paired reset RETURNS NON-ZERO when post-restore checks fail" {
  body=$(awk '/^cmd_reset_paired\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'reset-degraded'
  printf '%s\n' "$body" | grep -A3 'verify_ok" != "true"' | grep -q 'return 1'
}

@test "idle guard consults BOTH halves and exits 3 on either" {
  body=$(awk '/^cmd_reset_paired\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'for half in provider consumer'
  printf '%s\n' "$body" | grep -q 'return "\$DEMO_EXIT_ACTIVE"'
}

@test "naming EITHER half from the CLI runs the paired reset (auto-upgrade)" {
  body=$(awk '/^main\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'running the PAIRED reset'
}

@test "--no-pair is a loud, logged override, not a silent single-site reset" {
  body=$(awk '/^cmd_reset\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'reset-unpaired-override'
  printf '%s\n' "$body" | grep -q 'keeps SSO locks against accounts this wipe destroys'
  # and the refusal backstop still exists for direct/library callers
  printf '%s\n' "$body" | grep -q 'reset-refused'
}

@test "Moodle files restore CLEARS CONTENTS, never rm -rf the bind-mount dir" {
  body=$(awk '/^demo_files_restore\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'find "\$dr" -mindepth 1'
  # the rm -rf branch must be the Drupal one only
  ! printf '%s\n' "$body" | grep -q 'rm -rf "\$dr"'
}

@test "moodledata resolution fails closed when the dir is absent" {
  body=$(awk '/^demo_moodledata_dir\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'Moodle dataroot not found'
}

# --- build-script guards ------------------------------------------------------

@test "ssd rebuild refuses a live/prod tier" {
  run bash "${REPO_ROOT}/scripts/demo/ssd-rebuild.sh" --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "the issuer provisioner refuses any tier but dev" {
  run bash "${REPO_ROOT}/scripts/demo/nwd-issuer-provision.sh" --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev-only"* ]]
}

@test "the issuer provisioner refuses a site with no demo-enabled contract" {
  run bash "${REPO_ROOT}/scripts/demo/nwd-issuer-provision.sh" --site=realprov --tier=dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo-enabled pair contract"* ]]
}

@test "the OIDC wiring script refuses a mapping set without sub->idnumber" {
  # Removing the UID-lock mapping must be refused, not silently applied:
  # without it auth_nwc DENIES every login.
  c="$(demo_pair_contract_for cons)"
  sed -i 's/^    sub: idnumber$//' "$c"
  run bash "${REPO_ROOT}/scripts/demo/ssd-oidc-wire.sh" --site=cons --tier=dev --check
  [ "$status" -ne 0 ]
}

@test "the decoy sweep names auth_nwc_oauth2 and is fail-loud" {
  grep -q 'DECOY_PLUGIN="auth_nwc_oauth2"' "${REPO_ROOT}/scripts/demo/ssd-rebuild.sh"
  grep -q 'REFUSED: auth_nwc_oauth2 traces present' "${REPO_ROOT}/scripts/demo/ssd-rebuild.sh"
}

@test "the demo posture applies noindex=2, mail-kill and the demo marker" {
  php="${REPO_ROOT}/scripts/demo/ssd-demo-posture.php"
  grep -q "'allowindexing'            => '2'" "$php"
  grep -q "'noemailever'              => '1'" "$php"
  grep -q "'nwp_demo_mode'            => '1'" "$php"
  grep -q "registerauth" "$php"
}

@test "the posture banner refuses to render with no provider URL (dead link)" {
  grep -q "DEMO_PROVIDER_URL not set" "${REPO_ROOT}/scripts/demo/ssd-demo-posture.php"
}

@test "no secret is ever passed on a container argv" {
  # Both auth-surface scripts must stage the secret through a file.
  grep -q 'SECRET_TMP_CONTAINER' "${REPO_ROOT}/scripts/demo/nwd-issuer-provision.sh"
  grep -q 'OIDC_CLIENT_SECRET_FILE' "${REPO_ROOT}/scripts/demo/ssd-oidc-wire.sh"
  ! grep -qE 'ddev exec .*OIDC_CLIENT_SECRET=' "${REPO_ROOT}/scripts/demo/ssd-oidc-wire.sh"
}

@test "all Phase-2 shell scripts are syntactically valid" {
  for f in "${REPO_ROOT}"/scripts/demo/*.sh "${REPO_ROOT}/lib/demo-pair.sh" \
           "${REPO_ROOT}/tests/e2e/demo-pair/run.sh"; do
    run bash -n "$f"
    [ "$status" -eq 0 ]
  done
}

@test "the ssd pair contract declares the demo tier and a JWKS smoke probe" {
  c="${REPO_ROOT}/pairs/ssd.pair-contract.yml"
  grep -q 'enabled: true' "$c"
  grep -q 'paired_reset: true' "$c"
  grep -q '/.well-known/jwks.json' "$c"
  # The discovery probe could never pass against a simple_oauth issuer.
  ! grep -q 'name: oidc_discovery' "$c"
  # and the decoy must not be named as the consumer plugin
  grep -qE '^  consumer_plugin: auth_nwc([[:space:]]|#|$)' "$c"
}
