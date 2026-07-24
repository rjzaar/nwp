#!/usr/bin/env bats
# lib/config-drift.sh — Vortex-style config-drift gate around `drush updatedb`
# (report P3 / nwp/ops#63).
#
# NO ssh, NO network, NO real drush. The gate is host-agnostic: it runs every
# command through an injected executor function. Here the executor is a local
# `bash -c`, and DRUSH points at a MOCK drush that:
#   * config:export --destination=DIR  -> copies $FAKE_ACTIVE/* into DIR
#   * updatedb ...                      -> exit $FAKE_UPDATEDB_RC, and if
#                                          $FAKE_DRIFT=1, mutates $FAKE_ACTIVE
#                                          (simulating an update hook rewriting
#                                          active config)
# so the two before/after exports differ exactly when a drift is simulated.

setup() {
  TEST_TMP="$(mktemp -d)"
  export FAKE_ACTIVE="${TEST_TMP}/active"
  mkdir -p "${FAKE_ACTIVE}"
  # A small, realistic active-config set.
  printf 'name: Example\nmail: a@b.c\n' > "${FAKE_ACTIVE}/system.site.yml"
  printf 'module:\n  node: 0\n'          > "${FAKE_ACTIVE}/core.extension.yml"

  # Mock drush.
  MOCK_DRUSH="${TEST_TMP}/drush"
  cat > "${MOCK_DRUSH}" <<'MOCK'
#!/usr/bin/env bash
# minimal drush mock for the config-drift gate
cmd="$1"; shift || true
case "$cmd" in
  config:export)
    dest=""
    for a in "$@"; do
      case "$a" in --destination=*) dest="${a#--destination=}" ;; esac
    done
    [ -n "$dest" ] || { echo "no destination" >&2; exit 1; }
    [ "${FAKE_EXPORT_FAIL:-0}" = "1" ] && { echo "export failed" >&2; exit 1; }
    mkdir -p "$dest"
    cp -a "${FAKE_ACTIVE}"/. "$dest"/ 2>/dev/null || true
    exit 0
    ;;
  updatedb)
    if [ "${FAKE_DRIFT:-0}" = "1" ]; then
      # an update hook rewrites active config
      printf 'css.preprocess: true\n' > "${FAKE_ACTIVE}/system.performance.yml"
    fi
    exit "${FAKE_UPDATEDB_RC:-0}"
    ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DRUSH}"

  # Local executor: run the shell string on "this host".
  _exec_local() { bash -c "$1"; }
  export -f _exec_local 2>/dev/null || true

  # The gate needs print_* helpers.
  source "${BATS_TEST_DIRNAME}/../../lib/ui.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/config-drift.sh"
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset FAKE_ACTIVE FAKE_DRIFT FAKE_UPDATEDB_RC FAKE_EXPORT_FAIL NWP_ALLOW_CONFIG_DRIFT NWP_CONFIG_DRIFT_GATE
}

# ── the gate: drift detection ────────────────────────────────────────────────

@test "no drift: updatedb leaves active config unchanged -> PASS (rc 0)" {
  run config_drift_guarded_updatedb _exec_local "${MOCK_DRUSH}" "updatedb -y" "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"did NOT change active config"* ]]
}

@test "drift: updatedb mutates active config -> FAIL-CLOSED (rc 2)" {
  export FAKE_DRIFT=1
  run config_drift_guarded_updatedb _exec_local "${MOCK_DRUSH}" "updatedb -y" "test"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CHANGED active config"* ]]
  [[ "$output" == *"fail-closed"* ]]
  # the diff names the newly-added config object
  [[ "$output" == *"system.performance.yml"* ]]
}

@test "drift + NWP_ALLOW_CONFIG_DRIFT=1 -> allowed (rc 0) with warning" {
  export FAKE_DRIFT=1 NWP_ALLOW_CONFIG_DRIFT=1
  run config_drift_guarded_updatedb _exec_local "${MOCK_DRUSH}" "updatedb -y" "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALLOWED"* ]]
}

@test "drift + allow passed as arg 5 -> allowed (rc 0)" {
  export FAKE_DRIFT=1
  run config_drift_guarded_updatedb _exec_local "${MOCK_DRUSH}" "updatedb -y" "test" "1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALLOWED"* ]]
}

# ── the gate: failure modes ──────────────────────────────────────────────────

@test "updatedb itself fails -> rc 1 (distinct from drift)" {
  export FAKE_UPDATEDB_RC=1
  run config_drift_guarded_updatedb _exec_local "${MOCK_DRUSH}" "updatedb -y" "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED"* ]]
}

@test "config:export unavailable -> rc 3 (cannot gate)" {
  export FAKE_EXPORT_FAIL=1
  run config_drift_guarded_updatedb _exec_local "${MOCK_DRUSH}" "updatedb -y" "test"
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot gate"* || "$output" == *"config:export"* ]]
}

@test "undefined executor -> rc 3" {
  run config_drift_guarded_updatedb _no_such_exec_fn "${MOCK_DRUSH}" "updatedb -y" "test"
  [ "$status" -eq 3 ]
}

# ── enablement: off by default, opt-in via env / site config ─────────────────

@test "config_drift_enabled: OFF by default (no env, no site config)" {
  run config_drift_enabled "somesite"
  [ "$status" -ne 0 ]
}

@test "config_drift_enabled: NWP_CONFIG_DRIFT_GATE=1 turns it ON" {
  export NWP_CONFIG_DRIFT_GATE=1
  run config_drift_enabled "somesite"
  [ "$status" -eq 0 ]
}

@test "config_drift_enabled: NWP_CONFIG_DRIFT_GATE=0 forces it OFF (override wins)" {
  export NWP_CONFIG_DRIFT_GATE=0
  # even if a site config would say true, the explicit env override wins
  get_site_config_value() { echo "true"; }
  run config_drift_enabled "somesite"
  [ "$status" -ne 0 ]
}

@test "config_drift_enabled: site .nwp.yml config.drift_gate: true turns it ON" {
  # stub the resolver helper the gate consults
  get_site_config_value() { echo "true"; }
  export -f get_site_config_value
  run config_drift_enabled "somesite"
  [ "$status" -eq 0 ]
}
