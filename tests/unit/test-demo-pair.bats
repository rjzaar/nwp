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
  export REPO_ROOT TEST_TMP
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

@test "ops#170: paired capture REFUSES --tier=live when a half has no live HOST" {
  # The Phase-2 refusal ("not implemented … the consumer half has no live host
  # yet") is replaced by the thing it was standing in for: an actual check that
  # both halves have a live host. With no live: block in either .nwp.yml, this
  # still refuses — and now says which half and why.
  run bash "$DEMO_CMD" golden prov --with-pair --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"no live host configured"* || "$output" == *"no instance at tier"* ]]
}

@test "ops#170: the 'not implemented at live' refusals are GONE from both paired verbs" {
  # The refusal TEXT survives in the header comment that explains what it was
  # and why replacing it is not the same as deleting a guard. What must not
  # survive is an executable refusal, so only non-comment lines are searched.
  code=$(grep -vE '^[[:space:]]*#' "$DEMO_CMD")
  ! printf '%s\n' "$code" | grep -q 'paired capture on --tier=live is not implemented'
  ! printf '%s\n' "$code" | grep -q 'paired reset on --tier=live is not implemented'
}

@test "ops#170: BOTH paired verbs refuse --tier=prod even when called directly" {
  # demo_check_tier only guards main(); a library caller must hit the same wall.
  run bash -c '
    set -uo pipefail
    source "$REPO_ROOT/scripts/commands/demo.sh"
    set +e
    cmd_golden_paired prov prod false 2>&1
    echo "GOLDEN_RC=$?"
    cmd_reset_paired prov prod "" true false false 2>&1
    echo "RESET_RC=$?"
  '
  [[ "$output" == *"REFUSED: --tier=prod"* ]]
  [[ "$output" == *"GOLDEN_RC=1"* ]]
  [[ "$output" == *"RESET_RC=1"* ]]
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

@test "paired reset restores PROVIDER FIRST (NWP-ADR-0031 D5)" {
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

@test "naming EITHER half from the CLI runs the paired reset (auto-upgrade at dev/stg)" {
  body=$(awk '/^main\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'running the PAIRED reset'
}

@test "--no-pair is a loud, logged override, not a silent single-site reset" {
  # The guard moved OUT of cmd_reset into its own function (ops#170) so that it
  # runs above the dev/live tier split instead of below it — same rules, one
  # place, and now reachable at --tier=live.
  body=$(awk '/^demo_reset_pair_guard\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'reset-unpaired-override'
  printf '%s\n' "$body" | grep -q 'keeps SSO locks against accounts this wipe destroys'
  # and the refusal backstop still exists for direct/library callers
  printf '%s\n' "$body" | grep -q 'reset-refused'
}

@test "ops#170: the paired-half guard runs BEFORE the live dispatch, not after it" {
  # It used to sit below `if demo_is_live … cmd_reset_live … return`, which made
  # it dead code at the one tier where wiping half a coupled pair is worst.
  body=$(awk '/^cmd_reset\(\)/,/^}/' "$DEMO_CMD")
  g=$(printf '%s\n' "$body" | grep -n 'demo_reset_pair_guard' | head -1 | cut -d: -f1)
  l=$(printf '%s\n' "$body" | grep -n 'cmd_reset_live'        | head -1 | cut -d: -f1)
  [ -n "$g" ] && [ -n "$l" ] && [ "$g" -lt "$l" ]
}

@test "ops#170: the pair guard asks demo_instance_exists, not demo_project_dir" {
  # At live there is no .ddev directory for either half, so the old question
  # ("is there a local DDEV project") answered NO and the pair vanished.
  body=$(awk '/^demo_reset_pair_guard\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'demo_instance_exists'
  ! printf '%s\n' "$body" | grep -q 'demo_project_dir'
  awk '/^main\(\)/,0' "$DEMO_CMD" | grep -q 'demo_instance_exists "\$_partner" "\$tier"'
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

# --- ops#146: the tier gate narrowed. What must still hold. -------------------
#
# The issuer provisioner used to refuse EVERY tier but dev, and a single test
# ("refuses any tier but dev") stood for the whole safety story. ops#146
# implemented the live half, so that test's literal claim is now false — but the
# thing it was really protecting is not, and these tests pin it down properly.
#
# The old blanket refusal was doing three jobs at once:
#   (1) prod/stg must never be reachable from this workstation   — STILL TRUE;
#   (2) the REAL, student-bearing nwc<->ssc pair must never be an
#       argument to a demo script                                — STILL TRUE,
#       and now enforced by the contract gate rather than by tier accident;
#   (3) "there is no live implementation yet"                    — no longer true.
#
# Note also that the old test invoked `--tier=live` with the DEFAULT --site
# (nwd), which is demo-enabled. Under the bats fixture PROJECT_ROOT that is
# inert, but run from a real checkout on a host with ssh to the box it performs
# an actual live provisioning run. Nothing below invokes the live TRANSPORT: every
# live-tier case here is refused before a socket is opened.

@test "the issuer provisioner refuses prod and stg outright" {
  for t in prod stg; do
    run bash "${REPO_ROOT}/scripts/demo/nwd-issuer-provision.sh" --site=prov "--tier=$t"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does dev and live only"* ]]
  done
}

@test "NEGATIVE CONTROL: the tier gate admits dev and live (it does not refuse everything)" {
  # Without this, a provisioner that refused EVERY tier would satisfy the test
  # above. dev and live must get PAST guard 1 and fail later, for another
  # reason — here, the fixture contract has no live issuer and no redirect.
  for t in dev live; do
    run bash "${REPO_ROOT}/scripts/demo/nwd-issuer-provision.sh" --site=prov "--tier=$t"
    [[ "$output" != *"does dev and live only"* ]]
  done
}

@test "the live tier is bounded by the demo-enabled contract, not by the tier gate" {
  # THE replacement invariant. 'realprov' stands in for nwc: a pair contract
  # that never opted into the demo tier. Widening guard 1 to admit live must not
  # make the real, student-bearing pair reachable from a demo script.
  run bash "${REPO_ROOT}/scripts/demo/nwd-issuer-provision.sh" --site=realprov --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo-enabled pair contract"* ]]
}

@test "the contract gate is evaluated BEFORE any transport is established" {
  # A future edit that connects first and checks afterwards would leak an ssh
  # login to a non-demo host even though the run is ultimately refused.
  s="${REPO_ROOT}/scripts/demo/nwd-issuer-provision.sh"
  guard=$(grep -n 'demo_pair_contract_for' "$s" | head -1 | cut -d: -f1)
  ssh_line=$(grep -nE '^\s*(rexec\(\)|.*ssh \$RSSH_OPTS)' "$s" | head -1 | cut -d: -f1)
  [ -n "$guard" ] && [ -n "$ssh_line" ]
  [ "$guard" -lt "$ssh_line" ]
}

@test "the issuer provisioner never touches Moodle's cURL SSRF blocklist on any tier" {
  ! grep -q 'curlsecurityblockedhosts' "${REPO_ROOT}/scripts/demo/nwd-issuer-provision.sh"
}

@test "the issuer JWKS probe verifies TLS on live and only skips it on dev" {
  s="${REPO_ROOT}/scripts/demo/nwd-issuer-provision.sh"
  # no unconditional insecure probe may survive
  ! grep -qE "curl [^|]*-sk" "$s"
  # and -k must be gated on dev
  grep -q 'TIER" == "dev" \]\] && CURL_TLS=(-k)' "$s"
}

@test "the live keypair probe is privileged FOR THE WHOLE COMPOUND (or it re-mints the signing key every run)" {
  # The live key dir is 0700 www-data; an unprivileged 'test -r' there always
  # answers "absent", so the caller regenerates — silently invalidating every
  # id_token already signed.
  #
  # Asserting that the word "sudo" appears is NOT enough, and that weaker
  # assertion is exactly what let the first version of this fix ship broken.
  # `rexec "sudo $1"` with a compound probe sends
  #     sudo test -r …/private.key && test -r …/public.key
  # and the REMOTE SHELL binds `&&` outside sudo: only the first test is
  # privileged. The second still runs as the ssh user, still cannot read inside
  # 0700, so the probe still says "absent" and the key still rotates every run.
  # Confirmed on the live host: the prefix form returned 1, `sudo sh -c` returns 0.
  #
  # So execute the real definition and assert BOTH halves reach sudo.
  s="${REPO_ROOT}/scripts/demo/nwd-issuer-provision.sh"
  grep -q 'rprobe "test -r \$KEY_DIR/private.key' "$s"

  # the live branch's rprobe, verbatim — not a paraphrase of it
  awk '/^if \[\[ "\$TIER" == "live" \]\]; then/,/^else$/' "$s" \
      | grep -E '^[[:space:]]*rprobe\(\)' > "${TEST_TMP}/rprobe.sh"
  [ -s "${TEST_TMP}/rprobe.sh" ]

  mkdir -p "${TEST_TMP}/fakebin"
  cat > "${TEST_TMP}/fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SUDO_LOG"
exit 0
EOF
  chmod +x "${TEST_TMP}/fakebin/sudo"

  # rexec stands in for ssh: it hands the string to a shell, as the remote does.
  : > "${TEST_TMP}/sudo.log"
  SUDO_LOG="${TEST_TMP}/sudo.log" PATH="${TEST_TMP}/fakebin:${PATH}" \
    bash -c '
      rexec() { bash -c "$1"; }
      # shellcheck disable=SC1090
      source "$1"
      rprobe "test -r /K/private.key && test -r /K/public.key"
    ' _ "${TEST_TMP}/rprobe.sh" || true

  run cat "${TEST_TMP}/sudo.log"
  [[ "$output" == *"private.key"* ]]
  [[ "$output" == *"public.key"* ]]   # RED if `&&` escaped sudo
}

# --- ops#146: the SSRF relaxation is reachable ONLY on dev --------------------
#
# This is the invariant the old "dev-only" test was standing in for. It lives on
# the CONSUMER script (ssd-oidc-wire.sh), whose apply_dev_prereqs() blanks
# $CFG->curlsecurityblockedhosts — disabling Moodle's SSRF protection for EVERY
# server-side fetch the site makes, not just the OIDC ones. That must never
# follow to a real host. Asserted twice, structurally and at runtime, mirroring
# the two independent checks the code itself carries.

# Run apply_dev_prereqs() in isolation against a scratch Moodle root at a chosen
# tier. Echoes the function's output; leaves the scratch config.php for
# inspection so we can see whether the relaxation was actually written.
_run_apply_dev_prereqs() {
  local tier="$1" root="$2"
  mkdir -p "$root/.ddev"
  cat > "$root/config.php" <<'PHP'
<?php
$CFG = new stdClass();
require_once(__DIR__ . '/lib/setup.php');
PHP
  awk '/^apply_dev_prereqs\(\)/,/^}/' \
      "${REPO_ROOT}/scripts/demo/ssd-oidc-wire.sh" > "${TEST_TMP}/apply_dev_prereqs.sh"
  TIER="$tier" MOODLE_ROOT="$root" FN="${TEST_TMP}/apply_dev_prereqs.sh" bash -c '
    print_error() { echo "ERROR: $*"; }
    print_info()  { echo "INFO: $*"; }
    print_status(){ echo "OK: $*"; }
    ddev()        { echo "STUB ddev $*"; }   # a test never restarts anything
    SITE="cons"; PROVIDER="prov"; ISSUER="https://prov-dev.ddev.site"
    source "$FN"
    apply_dev_prereqs
  '
}

@test "apply_dev_prereqs REFUSES off dev and writes no SSRF relaxation" {
  root="${TEST_TMP}/moodle-live"
  run _run_apply_dev_prereqs live "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"INTERNAL REFUSAL"* ]]
  # the load-bearing half: nothing was relaxed
  ! grep -q 'curlsecurityblockedhosts' "$root/config.php"
  [ ! -f "$root/.ddev/docker-compose.prov-sso.yaml" ]
}

@test "NEGATIVE CONTROL: apply_dev_prereqs DOES relax on dev (the guard is tier-specific, not a blanket refusal)" {
  # Without this, deleting the function body — or making it refuse every tier —
  # would satisfy the test above. On dev the relaxation must actually land, and
  # the refusal must NOT fire.
  root="${TEST_TMP}/moodle-dev"
  run _run_apply_dev_prereqs dev "$root"
  [[ "$output" != *"INTERNAL REFUSAL"* ]]
  grep -q 'curlsecurityblockedhosts' "$root/config.php"
}

@test "apply_dev_prereqs has exactly one call site and it is inside a dev branch" {
  # The runtime self-assert can be deleted by a future edit; the call site is the
  # second, independent check. Exactly one caller, guarded by an explicit dev test.
  s="${REPO_ROOT}/scripts/demo/ssd-oidc-wire.sh"
  n=$(grep -cE '^[[:space:]]*apply_dev_prereqs( |$|\|)' "$s")
  [ "$n" -eq 1 ]
  grep -B2 -E '^[[:space:]]*apply_dev_prereqs( |$|\|)' "$s" | grep -q 'TIER" == "dev"'
}

@test "the consumer wiring refuses prod and stg outright" {
  for t in prod stg; do
    run bash "${REPO_ROOT}/scripts/demo/ssd-oidc-wire.sh" --site=cons "--tier=$t"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does dev and live only"* ]]
  done
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

@test "the OIDC wiring script refuses a contract without oidc.issuer_name (no codename fallback)" {
  # issuer_name is MEMBER-FACING (the SSO login-button label). The old silent
  # fallback "<provider> (F26)" once put an internal codename on the live login
  # page; a missing key must abort with instructions, never guess.
  c="$(demo_pair_contract_for cons)"
  sed -i '/^  issuer_name:/d' "$c"
  run bash "${REPO_ROOT}/scripts/demo/ssd-oidc-wire.sh" --site=cons --tier=dev --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"oidc.issuer_name is not set"* ]]
  [[ "$output" != *"(F26)"* ]]
}

@test "NEGATIVE CONTROL: with issuer_name present the issuer-name refusal does not fire" {
  # Without this, an unconditional refusal would satisfy the test above.
  run bash "${REPO_ROOT}/scripts/demo/ssd-oidc-wire.sh" --site=cons --tier=dev --check
  [[ "$output" != *"oidc.issuer_name is not set"* ]]
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

################################################################################
# THE AUDITED CONFIRMATION ROUTE (MR !162 review, note 2218)
#
# `main` asserts that every destructive demo path goes through ONE route:
# render a fate manifest (lib/impact.sh), THEN impact_confirm. The first cut of
# cmd_reset_paired hand-rolled a `read -r reply` instead — so the verb that
# destroys TWO sites, one of them the SSO identity provider, was LESS guarded
# than the one that destroys one. The file-level impact-contract gate could not
# see it, because demo.sh already adopts the lib over in cmd_reset.
#
# These tests are BEHAVIOURAL: they run cmd_reset_paired against a stubbed
# world and assert on the ORDER of the real impact_render / impact_confirm /
# destructive-step events, not on the source text. The static greps below them
# are a second, cheaper net for the specific pattern that regressed.
################################################################################

# Run cmd_reset_paired under a stub world and echo a TRACE, one event per line:
#   RENDER · CONFIRM tier=<t> subject=<s> rc=<n> · DESTROY <site> · DRYRUN
# $1 = auto_yes ("true" approves, "false" reaches the real prompt which
#      fail-closes with no TTY), $2 = dry_run.
_paired_trace() {
  local auto_yes="$1" dry_run="$2"
  local run="${TEST_TMP}/run.sh"

  cat > "$run" <<'RUN'
set -uo pipefail
source "$REPO_ROOT/scripts/commands/demo.sh"
set +e   # demo.sh carries `set -e` into whoever sources it; we need the rc

# --- world stubs: everything that would touch a real site -------------------
demo_project_dir() { case "$1" in prov) echo "$TEST_TMP/proj-prov" ;;
                                  *)    echo "$TEST_TMP/proj-cons" ;; esac; }
demo_measure_local_kind() { DEMO_M_DB=12.0; DEMO_M_FILES=3.4M; DEMO_M_ACCTS=2; }
demo_harvest_collect()        { :; }
demo_harvest_collect_moodle() { :; }
demo_files_restore()      { echo "DESTROY files:$2" >> "$TRACE"; }
demo_drush()              { :; }
demo_sync_codes_to_site() { :; }
demo_cache_rebuild()      { :; }
demo_consumer_checks()    { :; }
demo_moodledata_dir()     { echo "$PROJECT_ROOT/sites/cons_moodledata"; }

# --- spies: the REAL impact.sh functions, wrapped so the order is visible ---
eval "_real_impact_render() $(declare -f impact_render | tail -n +2)"
impact_render()  { echo "RENDER" >> "$TRACE"; _real_impact_render "$@" >/dev/null; }
eval "_real_impact_confirm() $(declare -f impact_confirm | tail -n +2)"
impact_confirm() {
  local rc=0; _real_impact_confirm "$@" >/dev/null 2>&1 || rc=$?
  echo "CONFIRM tier=$1 subject=$2 rc=$rc" >> "$TRACE"
  return "$rc"
}
_real_print_status="$(declare -f print_status)"
print_status() { [[ "${2:-}" == *"[dry-run]"* ]] && echo "DRYRUN" >> "$TRACE"; return 0; }

cmd_reset_paired prov dev "" "$AUTO_YES" true "$DRY_RUN" >/dev/null 2>&1
echo "EXIT $?" >> "$TRACE"
RUN

  TRACE="${TEST_TMP}/trace"; : > "$TRACE"
  PATH="${TEST_TMP}/bin:$PATH" TRACE="$TRACE" REPO_ROOT="$REPO_ROOT" \
    TEST_TMP="$TEST_TMP" PROJECT_ROOT="$PROJECT_ROOT" \
    AUTO_YES="$auto_yes" DRY_RUN="$dry_run" \
    bash "$run" </dev/null >/dev/null 2>&1 || true
  cat "$TRACE"
}

# The whole stub world both halves need: two ddev-shaped project dirs, a
# moodledata dir, and two goldens bound into ONE cut.
_paired_fixture() {
  export DEMO_GOLDEN_ROOT="${TEST_TMP}/golden"
  mkdir -p "${TEST_TMP}/bin" "${TEST_TMP}/proj-prov/.ddev" \
           "${TEST_TMP}/proj-cons/.ddev" "${PROJECT_ROOT}/sites/cons_moodledata" \
           "${TEST_TMP}/proj-prov/web/sites/default/files"
  printf 'docroot: web\n' > "${TEST_TMP}/proj-prov/.ddev/config.yaml"
  printf 'docroot: ""\n'  > "${TEST_TMP}/proj-cons/.ddev/config.yaml"
  # A `ddev` that destroys nothing and reports that it was asked to.
  cat > "${TEST_TMP}/bin/ddev" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "import-db" ]; then echo "DESTROY ${PWD##*/}" >> "$TRACE"; fi
exit 0
STUB
  chmod +x "${TEST_TMP}/bin/ddev"
  _fake_golden "$(demo_golden_dir prov dev)" prov s1
  _fake_golden "$(demo_golden_dir cons dev)" cons s1
  demo_pair_cut_write "$(demo_pair_cut_file "$(demo_golden_dir prov dev)")" \
    cons-prov "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" dev cut-test \
    prov "$(demo_golden_dir prov dev)" cons "$(demo_golden_dir cons dev)"
}

@test "GUARD: the paired wipe cannot be reached without a rendered manifest AND a confirmation" {
  _paired_fixture
  trace="$(_paired_trace true false)"
  # The destructive step IS reached — this is the negative control: the guard
  # cannot be satisfied by a function that simply refuses everything.
  [[ "$trace" == *"DESTROY"* ]]
  # …and it is reached ONLY after the manifest and the confirmation.
  render=$(printf '%s\n' "$trace"  | grep -n '^RENDER'  | head -1 | cut -d: -f1)
  confirm=$(printf '%s\n' "$trace" | grep -n '^CONFIRM' | head -1 | cut -d: -f1)
  destroy=$(printf '%s\n' "$trace" | grep -n '^DESTROY' | head -1 | cut -d: -f1)
  [ -n "$render" ] && [ -n "$confirm" ] && [ -n "$destroy" ]
  [ "$render"  -lt "$confirm" ]
  [ "$confirm" -lt "$destroy" ]
}

@test "GUARD: a REFUSED confirmation destroys nothing (fail-closed, no TTY, no -y)" {
  _paired_fixture
  trace="$(_paired_trace false false)"
  # the report still lands — -y skips the PROMPT, never the REPORT
  [[ "$trace" == *"RENDER"* ]]
  [[ "$trace" == *"rc=1"* ]]
  ! [[ "$trace" == *"DESTROY"* ]]
  [[ "$trace" == *"EXIT 1"* ]]
}

@test "GUARD: --with-pair --dry-run reports and stops — it does NOT wipe two sites" {
  _paired_fixture
  trace="$(_paired_trace false true)"
  [[ "$trace" == *"RENDER"* ]]
  [[ "$trace" == *"DRYRUN"* ]]
  ! [[ "$trace" == *"CONFIRM"* ]]
  ! [[ "$trace" == *"DESTROY"* ]]
  [[ "$trace" == *"EXIT 0"* ]]
}

@test "the paired confirmation names BOTH sites, at the standard tier" {
  _paired_fixture
  trace="$(_paired_trace true false)"
  line="$(printf '%s\n' "$trace" | grep '^CONFIRM' | head -1)"
  [[ "$line" == *"tier=standard"* ]]
  [[ "$line" == *"prov"* ]]
  [[ "$line" == *"cons"* ]]
}

@test "the paired manifest names BOTH halves and the SSO coupling" {
  _paired_fixture
  mkdir -p "${TEST_TMP}/bin"
  # Render for real and read the report itself, not a trace of it.
  run bash -c '
    set -uo pipefail
    source "$REPO_ROOT/scripts/commands/demo.sh"
    demo_project_dir() { case "$1" in prov) echo "$TEST_TMP/proj-prov";; *) echo "$TEST_TMP/proj-cons";; esac; }
    demo_measure_local_kind() { DEMO_M_DB=12.0; DEMO_M_FILES=3.4M; DEMO_M_ACCTS=2; }
    demo_moodledata_dir() { echo "$PROJECT_ROOT/sites/cons_moodledata"; }
    cmd_reset_paired prov dev "" false true true 2>&1
  '
  [[ "$output" == *"prov dev DB"* ]]
  [[ "$output" == *"cons dev DB"* ]]
  [[ "$output" == *"SSO IDENTITY PROVIDER"* ]]
  [[ "$output" == *"PAIRED WIPE"* ]]
}

@test "STATIC: the hand-rolled y/N prompt never comes back to the paired path" {
  body=$(awk '/^cmd_reset_paired\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'impact_render'
  printf '%s\n' "$body" | grep -q 'impact_confirm standard "ERASE BOTH'
  # the pattern main's test-demo.bats bans, asserted inside THIS body too
  ! printf '%s\n' "$body" | grep -q 'read -r reply'
  ! printf '%s\n' "$body" | grep -q 'This will ERASE'
  # ordering, in the body: render -> confirm -> wipe
  r=$(printf '%s\n' "$body" | grep -n 'impact_render'           | head -1 | cut -d: -f1)
  c=$(printf '%s\n' "$body" | grep -n 'impact_confirm standard' | head -1 | cut -d: -f1)
  i=$(printf '%s\n' "$body" | grep -n 'ddev import-db'          | head -1 | cut -d: -f1)
  [ "$r" -lt "$c" ] && [ "$c" -lt "$i" ]
}

@test "STATIC: dry_run is arg 6 on BOTH reset verbs and every call site passes it" {
  # the regression was a 5-arg call to a 6-arg function: --dry-run vanished
  grep -q 'local dry_run="\${6:-false}"' "$DEMO_CMD"
  awk '/^cmd_reset\(\)/,/^}/' "$DEMO_CMD" | grep -q 'dry_run="\${6:-false}"'
  # no 5-argument cmd_reset_paired call survives anywhere
  ! grep -qE 'cmd_reset_paired ("[^"]*" ){4}"[^"]*"$' "$DEMO_CMD"
  awk '/^main\(\)/,0' "$DEMO_CMD" | grep -q 'cmd_reset_paired "\$site" "\$tier" "\$if_idle" "\$auto_yes" "\$skip_seed" "\$dry_run"'
}

@test "REGRESSION: cmd_reset resolves its docroot — no 'droot: unbound variable'" {
  # The rebase dropped droot="$(demo_docroot …)" but kept its only consumer, so
  # under `set -u` EVERY dev/stg single-site reset died at the manifest step.
  # --dry-run, so this exercises the whole path up to (not through) the wipe.
  _paired_fixture
  run bash -c '
    set -euo pipefail
    source "$REPO_ROOT/scripts/commands/demo.sh"
    demo_is_live()       { return 1; }
    demo_project_dir()   { echo "$TEST_TMP/proj-prov"; }
    demo_kind_of()       { echo drupal; }
    demo_pair_resolve()  { return 1; }
    demo_measure_local() { :; }
    cmd_reset prov dev "" true true true   # --dry-run: stops at the report
  '
  [[ "$output" != *"unbound variable"* ]]
  [ "$status" -eq 0 ]
}

################################################################################
# nwp/ops#170 — PAIRED CAPTURE AND RESET AT --tier=live
#
# The refusals these replace were NOT-BUILT markers ("the consumer half has no
# live host yet"), not safety judgements. So the tests below are about the
# guards that had to be built to make the live path safe, and each one is
# written so that DELETING the guard turns it red:
#
#   * one cut, tier-bound          — a dev cut cannot authorise a live restore
#   * one writer + the box's lock  — a workstation run cannot race the nightly
#   * pre-flight BOTH, then destroy — an unreachable half destroys nothing
#   * stage BOTH, then destroy     — a failed transfer destroys nothing
#   * provider-first, and the split state is RECORDED and REPAIRABLE
#   * the live context is per-SITE — both halves live on ONE box
################################################################################

# Give the fixture pair two live hosts. Deliberately real config rather than a
# stub, because demo_instance_exists reads exactly this.
_live_fixture_config() {
  cat > "${PROJECT_ROOT}/sites/prov/.nwp.yml" <<'YML'
project:
  name: prov
  type: drupal
live:
  enabled: true
  domain: prov.example.test
  server_ip: 203.0.113.10
  remote_path: /var/www/prov
YML
  cat > "${PROJECT_ROOT}/sites/cons/.nwp.yml" <<'YML'
project:
  name: cons
  type: moodle
moodle:
  dataroot_host: sites/cons_moodledata
live:
  enabled: true
  domain: cons.example.test
  server_ip: 203.0.113.10
  remote_path: /var/www/cons
YML
}

# Two LIVE goldens bound into one live cut.
_live_goldens() {
  _fake_golden "$(demo_golden_dir prov live)" prov L1
  _fake_golden "$(demo_golden_dir cons live)" cons L1
  demo_pair_cut_write "$(demo_pair_cut_file "$(demo_golden_dir prov live)")" \
    cons-prov "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" live cut-live-1 \
    prov "$(demo_golden_dir prov live)" cons "$(demo_golden_dir cons live)"
}

# Run the PAIRED LIVE reset against a stubbed box and echo a TRACE, one event
# per line. Env knobs: LOCK_MODE=held|busy, STAGE_RC, PROV_RC, CONS_RC,
# PREFLIGHT_FAIL=<site>, AUTO_YES, DRY_RUN.
_live_trace() {
  local run="${TEST_TMP}/livrun.sh"
  cat > "$run" <<'RUN'
set -uo pipefail
source "$REPO_ROOT/scripts/commands/demo.sh"
set +e

# --- the box, stubbed --------------------------------------------------------
demo_live_ctx() {
  local s="$1"
  DEMO_LIVE_SITE="$s"; DEMO_LIVE_IP="203.0.113.10"; DEMO_LIVE_USER="gitlab"
  DEMO_LIVE_PATH="/var/www/$s"; DEMO_LIVE_DOMAIN="${s}.example.test"
  DEMO_LIVE_WEBROOT="web"; DEMO_LIVE_SUDO="sudo"; DEMO_LIVE_DRUSHSUDO="sudo -u www-data"
  echo "CTX $s" >> "$TRACE"
  return 0
}
demo_rssh() {
  local site="$1"; shift
  local cmd="$*"
  case "$cmd" in
    *nohup*)                                     # the lock ACQUIRE
      echo "LOCK-ACQUIRE $site" >> "$TRACE"
      [ "${LOCK_MODE:-held}" = "busy" ] && { echo "BUSY /var/lock/prov-demo-reset.lock"; return 0; }
      echo "HOLDER 4242"; return 0 ;;
    *"echo FREE"*)                               # the read-only probe
      echo "LOCK-PROBE $site" >> "$TRACE"; echo FREE; return 0 ;;
    kill*)
      echo "LOCK-RELEASE $site" >> "$TRACE"; return 0 ;;
    *"rm -f"*) echo "CLEANUP $site" >> "$TRACE"; return 0 ;;
  esac
  echo "RSSH $site $cmd" >> "$TRACE"; return 0
}
demo_live_require_demo_mode() {
  echo "DEMOMODE $1" >> "$TRACE"
  [ "${PREFLIGHT_FAIL:-}" = "$1" ] && return 1
  return 0
}
demo_live_newest_session()      { echo 1; }
demo_measure_live()             { DEMO_M_DB=10; DEMO_M_FILES=2M; DEMO_M_ACCTS=1; }
demo_live_manifest_files_path() { echo "/var/www/$1-data"; }
demo_live_files_parent()        { echo "/var/www/${DEMO_LIVE_SITE}/web/sites/default"; }
demo_push_verified() {
  echo "STAGE $1 $3" >> "$TRACE"
  return "${STAGE_RC:-0}"
}
cmd_reset_live() {
  echo "RESTORE $1 cut=$6 db=$7 files=$8 idle=[$2] yes=$3" >> "$TRACE"
  case "$1" in
    prov) return "${PROV_RC:-0}" ;;
    *)    return "${CONS_RC:-0}" ;;
  esac
}
demo_consumer_checks() { echo "CONSUMER-CHECKS $1 $2" >> "$TRACE"; return 0; }

# --- spies on the REAL impact functions --------------------------------------
eval "_real_impact_render() $(declare -f impact_render | tail -n +2)"
impact_render()  { echo "RENDER" >> "$TRACE"; _real_impact_render "$@" >/dev/null; }
eval "_real_impact_confirm() $(declare -f impact_confirm | tail -n +2)"
impact_confirm() {
  local rc=0; _real_impact_confirm "$@" >/dev/null 2>&1 || rc=$?
  echo "CONFIRM tier=$1 subject=$2 rc=$rc" >> "$TRACE"
  return "$rc"
}
print_status() { [[ "${2:-}" == *"[dry-run]"* ]] && echo "DRYRUN" >> "$TRACE"; return 0; }

cmd_reset_paired prov live "" "$AUTO_YES" false "$DRY_RUN" >/dev/null 2>&1
echo "EXIT $?" >> "$TRACE"
RUN
  TRACE="${TEST_TMP}/livetrace"; : > "$TRACE"
  TRACE="$TRACE" REPO_ROOT="$REPO_ROOT" TEST_TMP="$TEST_TMP" PROJECT_ROOT="$PROJECT_ROOT" \
    AUTO_YES="${AUTO_YES:-true}" DRY_RUN="${DRY_RUN:-false}" \
    LOCK_MODE="${LOCK_MODE:-held}" STAGE_RC="${STAGE_RC:-0}" \
    PROV_RC="${PROV_RC:-0}" CONS_RC="${CONS_RC:-0}" PREFLIGHT_FAIL="${PREFLIGHT_FAIL:-}" \
    bash "$run" </dev/null >/dev/null 2>&1 || true
  cat "$TRACE"
}

_line_of() { printf '%s\n' "$1" | grep -n "^$2" | head -1 | cut -d: -f1; }

@test "ops#170 GREEN: the paired LIVE reset now RUNS — both halves, one cut, one confirmation" {
  _live_fixture_config; _live_goldens
  trace="$(_live_trace)"
  # It gets all the way to the destructive step (the negative control: a guard
  # that refuses everything would also produce no RESTORE lines).
  [[ "$trace" == *"RESTORE prov cut=cut-live-1"* ]]
  [[ "$trace" == *"RESTORE cons cut=cut-live-1"* ]]
  [[ "$trace" == *"EXIT 0"* ]]
  # exactly ONE report and ONE confirmation cover both halves
  [ "$(printf '%s\n' "$trace" | grep -c '^RENDER')"  -eq 1 ]
  [ "$(printf '%s\n' "$trace" | grep -c '^CONFIRM')" -eq 1 ]
}

@test "ops#170: the live confirmation is the TYPED tier and names the pair" {
  _live_fixture_config; _live_goldens
  trace="$(_live_trace)"
  line="$(printf '%s\n' "$trace" | grep '^CONFIRM' | head -1)"
  [[ "$line" == *"tier=typed"* ]]
  [[ "$line" == *"cons-prov"* ]]
}

@test "ops#170: PROVIDER FIRST on live (NWP-ADR-0031 D5)" {
  _live_fixture_config; _live_goldens
  trace="$(_live_trace)"
  p=$(_line_of "$trace" "RESTORE prov"); c=$(_line_of "$trace" "RESTORE cons")
  [ -n "$p" ] && [ -n "$c" ] && [ "$p" -lt "$c" ]
}

@test "ops#170: NOTHING is destroyed before the lock, the report and the confirmation" {
  _live_fixture_config; _live_goldens
  trace="$(_live_trace)"
  lock=$(_line_of "$trace" "LOCK-ACQUIRE")
  render=$(_line_of "$trace" "RENDER")
  confirm=$(_line_of "$trace" "CONFIRM")
  restore=$(_line_of "$trace" "RESTORE prov")
  [ -n "$lock" ] && [ -n "$render" ] && [ -n "$confirm" ] && [ -n "$restore" ]
  [ "$lock" -lt "$render" ]
  [ "$render" -lt "$confirm" ]
  [ "$confirm" -lt "$restore" ]
}

@test "ops#170: BOTH halves are staged on the box BEFORE either is destroyed" {
  # The likeliest way a two-host restore splits a pair is a transfer failure
  # halfway through. Staging both first moves that entirely in front of the wipe.
  _live_fixture_config; _live_goldens
  trace="$(_live_trace)"
  sp=$(_line_of "$trace" "STAGE prov"); sc=$(_line_of "$trace" "STAGE cons")
  r=$(_line_of "$trace" "RESTORE prov")
  [ -n "$sp" ] && [ -n "$sc" ] && [ -n "$r" ]
  [ "$sp" -lt "$r" ] && [ "$sc" -lt "$r" ]
}

@test "ops#170: a staging failure destroys NOTHING and cleans up after itself" {
  _live_fixture_config; _live_goldens
  STAGE_RC=1 trace="$(STAGE_RC=1 _live_trace)"
  ! [[ "$trace" == *"RESTORE"* ]]
  [[ "$trace" == *"CLEANUP"* ]]
  [[ "$trace" == *"EXIT 1"* ]]
}

@test "ops#170: a BUSY box pair lock REFUSES — the workstation never races the nightly" {
  _live_fixture_config; _live_goldens
  trace="$(LOCK_MODE=busy _live_trace)"
  ! [[ "$trace" == *"RESTORE"* ]]
  ! [[ "$trace" == *"RENDER"* ]]
  [[ "$trace" == *"EXIT 1"* ]]
}

@test "ops#170: an unreachable/unpostured half is caught in PRE-FLIGHT — the other half is untouched" {
  _live_fixture_config; _live_goldens
  trace="$(PREFLIGHT_FAIL=cons _live_trace)"
  # the provider was checked first and is fine, but nothing is destroyed
  [[ "$trace" == *"DEMOMODE prov"* ]]
  [[ "$trace" == *"DEMOMODE cons"* ]]
  ! [[ "$trace" == *"RESTORE"* ]]
  ! [[ "$trace" == *"CONFIRM"* ]]
  [[ "$trace" == *"EXIT 1"* ]]
}

@test "ops#170: --dry-run on the live pair reports and stops, and takes no box lock" {
  _live_fixture_config; _live_goldens
  trace="$(DRY_RUN=true AUTO_YES=false _live_trace)"
  [[ "$trace" == *"RENDER"* ]]
  [[ "$trace" == *"DRYRUN"* ]]
  [[ "$trace" == *"LOCK-PROBE"* ]]        # it LOOKS…
  ! [[ "$trace" == *"LOCK-ACQUIRE"* ]]    # …but takes nothing
  ! [[ "$trace" == *"CONFIRM"* ]]
  ! [[ "$trace" == *"RESTORE"* ]]
  [[ "$trace" == *"EXIT 0"* ]]
}

@test "ops#170: a refused confirmation destroys nothing (no TTY, no -y)" {
  _live_fixture_config; _live_goldens
  trace="$(AUTO_YES=false _live_trace)"
  [[ "$trace" == *"RENDER"* ]]
  [[ "$trace" == *"rc=1"* ]]
  ! [[ "$trace" == *"RESTORE"* ]]
  [[ "$trace" == *"EXIT 1"* ]]
}

@test "ops#170 HALF-FAILURE: provider fails ⇒ consumer NEVER touched, no split recorded" {
  _live_fixture_config; _live_goldens
  trace="$(PROV_RC=1 _live_trace)"
  [[ "$trace" == *"RESTORE prov"* ]]
  ! [[ "$trace" == *"RESTORE cons"* ]]
  [[ "$trace" == *"EXIT 1"* ]]
  # the pair was not split BY US, so no breadcrumb
  [ ! -f "$(demo_pair_inconsistent_file prov)" ]
  grep -q 'reason=provider-restore' "${PROJECT_ROOT}/sites/prov/demo-reset.log"
  ! grep -q 'reset-ok' "${PROJECT_ROOT}/sites/prov/demo-reset.log"
}

@test "ops#170 HALF-FAILURE: consumer fails AFTER the provider ⇒ split RECORDED, logged, repairable, non-zero" {
  _live_fixture_config; _live_goldens
  trace="$(CONS_RC=1 _live_trace)"
  [[ "$trace" == *"RESTORE prov"* ]]
  [[ "$trace" == *"RESTORE cons"* ]]
  [[ "$trace" == *"EXIT 1"* ]]
  f="$(demo_pair_inconsistent_file prov)"
  [ -s "$f" ]
  [ "$(jq -r .failed_half "$f")" = "consumer" ]
  [ "$(jq -r .cut_id "$f")" = "cut-live-1" ]
  [[ "$(jq -r .repair "$f")" == *"--with-pair --tier=live"* ]]
  grep -q 'pair-inconsistent' "${PROJECT_ROOT}/sites/prov/demo-reset.log"
  grep -q 'pair-inconsistent' "${PROJECT_ROOT}/sites/cons/demo-reset.log"
  # and it did NOT claim success
  ! grep -q 'reset-ok ' "${PROJECT_ROOT}/sites/prov/demo-reset.log"
}

@test "ops#170 HALF-FAILURE: a successful paired run CLEARS a previous split" {
  _live_fixture_config; _live_goldens
  demo_pair_mark_inconsistent prov cons old-cut consumer "earlier failure"
  [ -s "$(demo_pair_inconsistent_file prov)" ]
  trace="$(_live_trace)"
  [[ "$trace" == *"EXIT 0"* ]]
  [ ! -f "$(demo_pair_inconsistent_file prov)" ]
}

@test "ops#170 DEGRADED: a half that restores but smokes red does NOT strand the other half" {
  # Stopping here would trade a cosmetic failure for a data-consistency one.
  _live_fixture_config; _live_goldens
  trace="$(PROV_RC=4 _live_trace)"
  [[ "$trace" == *"RESTORE cons"* ]]      # the pair is still brought to one cut
  [[ "$trace" == *"EXIT 1"* ]]            # …and the run still reports FAILED
  [ ! -f "$(demo_pair_inconsistent_file prov)" ]
}

@test "ops#170: every log line of a paired live run is tagged with the cut" {
  _live_fixture_config; _live_goldens
  trace="$(_live_trace)"
  grep -q 'pair=1 cut=cut-live-1' "${PROJECT_ROOT}/sites/prov/demo-reset.log"
  grep -q 'pair=1 cut=cut-live-1' "${PROJECT_ROOT}/sites/cons/demo-reset.log"
  # including the per-site manifest line, which knows nothing about the pair
  grep -q 'reset-manifest .*pair=1 cut=cut-live-1' "${PROJECT_ROOT}/sites/cons/demo-reset.log"
}

@test "ops#170: pl demo status reports a split pair until it is repaired" {
  _live_fixture_config; _live_goldens
  demo_pair_mark_inconsistent prov cons cut-live-1 consumer "cmd_reset_live rc=1"
  run bash "$DEMO_CMD" status prov --tier=live
  [[ "$output" == *"PAIR INCONSISTENT"* ]]
  [[ "$output" == *"--with-pair --tier=live"* ]]
  demo_pair_clear_inconsistent prov
  run bash "$DEMO_CMD" status prov --tier=live
  ! [[ "$output" == *"PAIR INCONSISTENT"* ]]
}

# --- the cut is bound to its TIER --------------------------------------------

@test "ops#170: a DEV cut cannot authorise a LIVE restore" {
  _fake_golden "$(demo_golden_dir prov dev)" prov s1
  _fake_golden "$(demo_golden_dir cons dev)" cons s1
  cut="$(demo_pair_cut_file "$(demo_golden_dir prov dev)")"
  demo_pair_cut_write "$cut" cons-prov "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" \
    dev cut-dev-1 prov "$(demo_golden_dir prov dev)" cons "$(demo_golden_dir cons dev)"
  # verifies as a dev cut…
  run demo_pair_cut_verify "$cut" prov "$(demo_golden_dir prov dev)" cons "$(demo_golden_dir cons dev)" dev
  [ "$status" -eq 0 ]
  # …and REFUSES when a live restore asks
  run demo_pair_cut_verify "$cut" prov "$(demo_golden_dir prov dev)" cons "$(demo_golden_dir cons dev)" live
  [ "$status" -ne 0 ]
  [[ "$output" == *"tier"* ]]
}

@test "ops#170: a live capture whose SECOND half fails leaves no usable cut" {
  # The realistic partial capture: provider re-captured, consumer failed. The
  # OLD cut must stop verifying rather than silently binding a stale half.
  _live_goldens
  pdir="$(demo_golden_dir prov live)"; cdir="$(demo_golden_dir cons live)"
  cut="$(demo_pair_cut_file "$pdir")"
  run demo_pair_cut_verify "$cut" prov "$pdir" cons "$cdir" live
  [ "$status" -eq 0 ]
  _fake_golden "$pdir" prov L2          # provider re-captured alone
  run demo_pair_cut_verify "$cut" prov "$pdir" cons "$cdir" live
  [ "$status" -ne 0 ]
  [[ "$output" == *"PAIR CUT BROKEN"* ]]
}

# --- the live context is per-SITE (both halves are on ONE box) ---------------

@test "ops#170 REGRESSION: resolving the second half does not inherit the first half's host" {
  # Before this, demo_live_ctx memoised for the life of the PROCESS. nwd and ssd
  # are on the same box, so the second half would have been dumped from — and
  # restored onto — the FIRST half's path and database, sha-verified all the way.
  _live_fixture_config
  run bash -c '
    set -uo pipefail
    source "$REPO_ROOT/scripts/commands/demo.sh"
    set +e
    get_ssh_user() { echo gitlab; }
    demo_rssh() { return 0; }
    demo_live_ctx prov >/dev/null 2>&1
    echo "FIRST=$DEMO_LIVE_PATH:$DEMO_LIVE_DOMAIN"
    demo_live_ctx cons >/dev/null 2>&1
    echo "SECOND=$DEMO_LIVE_PATH:$DEMO_LIVE_DOMAIN"
  '
  [[ "$output" == *"FIRST=/var/www/prov:prov.example.test"* ]]
  [[ "$output" == *"SECOND=/var/www/cons:cons.example.test"* ]]
}

@test "ops#170: every remote helper asserts the context belongs to the site it was handed" {
  for fn in demo_rssh demo_push_verified demo_pull_verified; do
    body=$(awk "/^${fn}\(\)/,/^}/" "$DEMO_CMD")
    printf '%s\n' "$body" | grep -q 'DEMO_LIVE_SITE" == "\$site"'
  done
  # and the memo itself is keyed, not a bare "have I resolved anything"
  awk '/^demo_live_ctx\(\)/,/^}/' "$DEMO_CMD" | grep -q 'DEMO_LIVE_SITE" == "\$site"'
}

@test "ops#170: the paired live path resets the context between the halves" {
  body=$(awk '/^_cmd_reset_paired_live_body\(\)/,/^}/' "$DEMO_CMD")
  [ "$(printf '%s\n' "$body" | grep -c 'demo_live_ctx_reset')" -ge 4 ]
  body=$(awk '/^cmd_golden_paired\(\)/,/^}/' "$DEMO_CMD")
  [ "$(printf '%s\n' "$body" | grep -c 'demo_live_ctx_reset')" -ge 2 ]
}

# --- the box lock, as a string ------------------------------------------------

@test "ops#170: the derived box lock paths are the ones the SHIPPED wrappers use" {
  # Read off the target, not from memory: if either wrapper renames its lock,
  # this goes red instead of the pair silently losing its serialisation.
  nwd_lock=$(grep -E '^LOCK_FILE=' "${REPO_ROOT}/servers/live/demo/nwd-demo-reset-restricted" | head -1 | cut -d'"' -f2)
  ssd_lock=$(grep -E '^LOCK_FILE=' "${REPO_ROOT}/servers/live/demo/ssd-demo-reset-restricted" | head -1 | cut -d'"' -f2)
  [ "$(demo_pair_box_lock_file nwd)" = "$nwd_lock" ]
  [ "$(demo_pair_box_lock_file ssd)" = "$ssd_lock" ]
  # and the ssd wrapper's advisory PAIR lock is the nwd one
  pair_lock=$(grep -E '^PAIR_LOCK_FILE=' "${REPO_ROOT}/servers/live/demo/ssd-demo-reset-restricted" | head -1 | cut -d'"' -f2)
  [ "$(demo_pair_box_lock_file nwd)" = "$pair_lock" ]
}

@test "ops#170: the box lock command is non-blocking, TTL-bounded, and PROVES it holds the locks" {
  cmd="$(demo_pair_box_lock_cmd /var/lock/a.lock /var/lock/b.lock 900)"
  [[ "$cmd" == *"flock -n"* ]]
  ! [[ "$cmd" == *"flock -w"* ]]
  [[ "$cmd" == *"sleep \"\$3\""* ]]     # the holder self-releases
  [[ "$cmd" == *900* ]]
  [[ "$cmd" == *"BUSY"* ]]
  [[ "$cmd" == *"NOTHELD"* ]]           # the positive control
  [[ "$cmd" == *"HOLDER"* ]]
  # ONE process holds BOTH fds, so ONE kill releases both
  [[ "$cmd" == *'exec 8>'* ]] && [[ "$cmd" == *'exec 9>'* ]]
  [[ "$(demo_pair_box_unlock_cmd 1234)" == "kill 1234"* ]]
}

@test "ops#170: the box lock command actually works when run (locks, then blocks a second taker)" {
  # Positive control for the control: prove the emitted shell does what the
  # refusal path assumes it does, on this machine, before believing any BUSY.
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  a="${TEST_TMP}/a.lock"; b="${TEST_TMP}/b.lock"
  out="$(sh -c "$(demo_pair_box_lock_cmd "$a" "$b" 5)" || true)"
  [[ "$out" == HOLDER* ]]
  pid="${out#HOLDER }"
  # a second attempt must now be refused
  out2="$(sh -c "$(demo_pair_box_lock_cmd "$a" "$b" 5)" || true)"
  [[ "$out2" == BUSY* ]]
  sh -c "$(demo_pair_box_unlock_cmd "$pid")"
  sleep 0.3
  out3="$(sh -c "$(demo_pair_box_lock_probe_cmd "$a" "$b")")"
  [ "$out3" = "FREE" ]
  pkill -f "sleep 5" 2>/dev/null || true
}

@test "ops#170: the local one-writer lock is fail-CLOSED" {
  body=$(awk '/^demo_pair_live_lock\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'flock -n 201'
  printf '%s\n' "$body" | grep -q 'already running'
  # an unopenable lock file refuses too — it never proceeds unlocked
  printf '%s\n' "$body" | grep -q 'Cannot open the pair lock'
}

# --- what must NOT have changed ----------------------------------------------

@test "ops#170: the live paired capture DELEGATES to cmd_golden — no second dump idiom" {
  # The structure-only exclusions (Drupal watchdog/sessions/flood; Moodle's
  # regenerable dataroot trees) live in the single-site live capture. A paired
  # path with its own mysqldump would quietly lose them.
  body=$(awk '/^cmd_golden_paired\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'cmd_golden "\$prov"'
  printf '%s\n' "$body" | grep -q 'cmd_golden "\$cons"'
  ! printf '%s\n' "$body" | grep -qE 'mysqldump|sql:dump|tar czf'
}

@test "ops#170: the REAL ssc<->nwc pair stays invisible at live too" {
  # The opt-in is the only thing between a production pair and a nightly wipe.
  run bash "$DEMO_CMD" reset realprov --with-pair --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in a demo-enabled pair"* ]]
  run bash "$DEMO_CMD" golden real --with-pair --tier=live
  [ "$status" -ne 0 ]
}

@test "ops#170: --tier=prod is still refused by the CLI at every paired verb" {
  for verb in golden reset nightly; do
    run bash "$DEMO_CMD" "$verb" prov --with-pair --tier=prod
    [ "$status" -ne 0 ]
    [[ "$output" == *"prod"* ]]
  done
}

################################################################################
# ops#170, operator decision 2026-08-02 — AT LIVE THE PAIRED PATH IS OPT-IN
#
# dev/stg auto-upgrade: naming either half runs the pair. Live does NOT, and the
# asymmetry is the point. The paired live path is destructive across two hosts
# and has never been exercised against the estate; making a never-run
# destructive path the new default of an existing live verb is precisely the
# move that the context-bleed bug found while writing it argues against.
#
# The pair does not stop being enforced, though: without --with-pair, a live
# reset of a coupled half REFUSES and names the flag. Refusing is a fine
# default. Silently doing a new thing is not.
################################################################################

@test "ops#170 OPT-IN: a bare live reset of a coupled half REFUSES and names --with-pair" {
  _live_fixture_config
  run bash "$DEMO_CMD" reset cons --tier=live --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"half of the demo pair"* ]]
  [[ "$output" == *"--with-pair --tier=live"* ]]
  # …and it did NOT quietly reset one host instead
  ! [[ "$output" == *"Golden image verified"* ]]
  grep -q 'reset-refused' "${PROJECT_ROOT}/sites/cons/demo-reset.log"
}

@test "ops#170 OPT-IN: the refusal also names the single-host escape and the capture step" {
  _live_fixture_config
  run bash "$DEMO_CMD" reset prov --tier=live --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"--no-pair --tier=live"* ]]
  [[ "$output" == *"golden prov --with-pair --tier=live"* ]]
}

@test "ops#170 OPT-IN: --with-pair at live DOES opt in (negative control — the gate is not a blanket refusal)" {
  # It must get PAST the unpaired-half refusal. It then fails for an honest
  # later reason (no golden / no cut / no reachable box), which is what we assert
  # — the point is that the pair gate is no longer what stops it.
  _live_fixture_config
  run bash "$DEMO_CMD" reset prov --with-pair --tier=live --force
  [ "$status" -ne 0 ]
  ! [[ "$output" == *"half of the demo pair"* ]]
  [[ "$output" == *"Paired demo reset"* || "$output" == *"pair lock"* || "$output" == *"golden"* ]]
}

@test "ops#170 OPT-IN: --no-pair at live is still the loud, logged single-host override" {
  _live_fixture_config
  run bash "$DEMO_CMD" reset cons --no-pair --tier=live --force
  [[ "$output" == *"--no-pair: resetting ONLY 'cons'"* ]]
  grep -q 'reset-unpaired-override' "${PROJECT_ROOT}/sites/cons/demo-reset.log"
}

@test "ops#170 OPT-IN is LIVE-ONLY: dev still auto-upgrades to the pair" {
  # The negative control for the inversion: it must not have disabled pairing
  # everywhere. dev has DDEV projects for both halves, so the pair applies.
  mkdir -p "${TEST_TMP}/proj-prov/.ddev" "${TEST_TMP}/proj-cons/.ddev"
  run bash -c '
    set -uo pipefail
    source "$REPO_ROOT/scripts/commands/demo.sh"
    set +e
    demo_project_dir() { case "$1" in prov) echo "$TEST_TMP/proj-prov";; *) echo "$TEST_TMP/proj-cons";; esac; }
    cmd_reset_paired() { echo "PAIRED-PATH tier=$2"; return 0; }
    cmd_reset()        { echo "SINGLE-PATH tier=$2"; return 0; }
    main reset cons --tier=dev --force
  '
  [[ "$output" == *"PAIRED-PATH tier=dev"* ]]
  ! [[ "$output" == *"SINGLE-PATH"* ]]
}

@test "ops#170 OPT-IN: at live, main() routes a bare reset to the SINGLE path (where the guard refuses)" {
  _live_fixture_config
  run bash -c '
    set -uo pipefail
    source "$REPO_ROOT/scripts/commands/demo.sh"
    set +e
    cmd_reset_paired() { echo "PAIRED-PATH tier=$2"; return 0; }
    cmd_reset()        { echo "SINGLE-PATH tier=$2 pairflag=[${7:-}]"; return 0; }
    main reset cons --tier=live --force
    main reset cons --tier=live --with-pair --force
  '
  [[ "$output" == *"SINGLE-PATH tier=live pairflag=[]"* ]]   # bare: single path, guard refuses inside
  [[ "$output" == *"PAIRED-PATH tier=live"* ]]               # --with-pair: opted in
}

@test "ops#170 OPT-IN: a bare live CAPTURE is unchanged (single-site, non-destructive)" {
  # The other half of not surprising anyone: `pl demo golden <site> --tier=live`
  # must keep doing exactly what it did, because capture destroys nothing and a
  # session may be mid-flight relying on it.
  _live_fixture_config
  run bash -c '
    set -uo pipefail
    source "$REPO_ROOT/scripts/commands/demo.sh"
    set +e
    cmd_golden_paired() { echo "PAIRED-CAPTURE"; return 0; }
    cmd_golden()        { echo "SINGLE-CAPTURE $1 tier=$2"; return 0; }
    main golden cons --tier=live
    main golden cons --tier=live --with-pair
  '
  [[ "$output" == *"SINGLE-CAPTURE cons tier=live"* ]]
  [[ "$output" == *"PAIRED-CAPTURE"* ]]
}

@test "ops#170 OPT-IN: the live opt-in is stated in main(), not inferred" {
  body=$(awk '/^main\(\)/,/^}/' "$DEMO_CMD")
  printf '%s\n' "$body" | grep -q 'demo_is_live "\$tier" && \[\[ "\$with_pair" != "yes" \]\]'
  printf '%s\n' "$body" | grep -q 'opt-IN only at live'
}

# ── pair_contract_for_any — the deliberate real-pair exception (ops#222) ──────
# One content-only tool may resolve the real pair under an explicit operator-
# approved flag. The demo gate must be UNCHANGED by its existence.

@test "ops#222: pair_contract_for_any resolves the NON-demo (real) contract" {
  run bash -c "source '$DEMO_LIB'; pair_contract_for_any real"
  [ "$status" -eq 0 ]
  [[ "$output" == *"real.pair-contract.yml"* ]]
}

@test "ops#222: the demo gate still refuses the real pair — for_any changes nothing" {
  run bash -c "source '$DEMO_LIB'; demo_pair_contract_for real"
  [ "$status" -ne 0 ]
}

@test "ops#222: pair_contract_for_any also finds demo contracts (superset, not a fork)" {
  run bash -c "source '$DEMO_LIB'; pair_contract_for_any cons"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cons.pair-contract.yml"* ]]
}

@test "ops#222: destructive paired verbs never call pair_contract_for_any" {
  # The function's contract: content-only callers only. golden/reset resolving
  # the real pair would put the student site one flag from a nightly wipe.
  ! grep -n "pair_contract_for_any" "${REPO_ROOT}/scripts/commands/demo.sh"
}
