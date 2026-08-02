#!/usr/bin/env bats
# `pl moodle privacy` — is a plugin VISIBLE to Moodle's privacy API on the
# target? (scripts/commands/moodle.sh cmd_privacy + scripts/moodle/privacy-registry.php,
# nwp/ops#259)
#
# WHY THESE ASSERTIONS AND NOT OTHERS
# -----------------------------------
# The bug this verb exists for is a check that could not fail. `pl moodle plugin
# drift` compared each site's copies to EACH OTHER, so local_feedback missing
# provider.php on live ssd, live ssc and live rgs simultaneously read as "every
# compared copy agrees". Every test below was observed RED before the verb
# existed (there was no `privacy` subcommand at all — `pl moodle privacy`
# answered "Unknown moodle subcommand").
#
#   p1  a gap is exit 1, and says which component            (the finding itself)
#   p2  clean is exit 0                                      (can return positive)
#   p3  a run that could not complete is exit 3, NOT 0       (blind != clean)
#   p4  the helper is sha256-verified before it is run       (no blind staging)
#   p5  the /tmp stage is removed on the failing path too    (no litter on live)
#   p6  tier discipline: live only, --tier required
#   p7  NOT-INSTALLED is a failure, not a silent skip
#   p8  the helper writes nothing — no --apply, no confirm, no deploy gate
#
# NO network, NO real ssh: ssh/scp are PATH stubs writing to a trace file.
#
# NO `command -v php || skip` GUARDS (removed 2026-08-03, MR !317)
#   p10/p11 used to skip when php was absent. bats scores a skip as `ok`, so on
#   a php-less machine the helper's own argument validation — the traversal
#   refusal in p10 — reported green having run nothing (H3 in
#   scripts/ci/lint-test-honesty.sh). The guard was also dead where it claimed
#   to help: test:unit sets NWP_BATS_REQUIRED_TOOLS="bats git php yq" and
#   scripts/ci/run-bats.sh exits 2 before running a case if php is missing, so
#   a php-less runner is already a red pipeline. "php: command not found" here
#   is the intended report; install php-cli, do not re-add the guard.

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

  STUB="${TEST_TMP}/stub"
  export PR_TRACE="${TEST_TMP}/trace.txt"
  export PR_FAKEHOME="${TEST_TMP}/fakehome"
  mkdir -p "$STUB" "$PR_FAKEHOME"
  : > "$PR_TRACE"

  cat > "${STUB}/ssh" <<'SSH'
#!/bin/bash
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
printf 'SSH %s\n' "$cmd" >> "$PR_TRACE"
case "$cmd" in
  *sha256sum*privacy-registry.php*)
    n="privacy-registry.php"
    sha256sum "$PR_FAKEHOME/$n" 2>/dev/null | cut -d' ' -f1 ;;
  *mkdir*nwp-privacy*) : ;;
  *rm*-rf*nwp-privacy*) : ;;
  *privacy-registry.php*)
    case "${PR_MODE:-gap}" in
      gap)
        echo "PRIVACY local_feedback NO-PROVIDER versiondisk=2026051704 versiondb=2026051704 metadata=- interfaces=- missing=-"
        echo "PRIVACY-SUMMARY checked=1 compliant=0 null=0 noprovider=1 incomplete=0 cannotverify=0"
        exit 1 ;;
      clean)
        echo "PRIVACY local_feedback COMPLIANT versiondisk=2026080101 versiondb=2026080101 metadata=2 interfaces=metadata\\provider,plugin\\provider missing=-"
        echo "PRIVACY-SUMMARY checked=1 compliant=1 null=0 noprovider=0 incomplete=0 cannotverify=0"
        exit 0 ;;
      notinstalled)
        echo "PRIVACY local_feedback NOT-INSTALLED versiondisk=- versiondb=- metadata=- interfaces=- missing=-"
        echo "PRIVACY-SUMMARY checked=0 compliant=0 null=0 noprovider=0 incomplete=0 cannotverify=0"
        exit 1 ;;
      blind)
        echo "PHP Fatal error: something exploded before Moodle booted"
        exit 255 ;;
    esac ;;
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
printf 'SCP %s -> %s\n' "${args[0]}" "${args[1]}" >> "$PR_TRACE"
cp "${args[0]}" "$PR_FAKEHOME/${args[1]#*:}"
SCP
  chmod +x "${STUB}/ssh" "${STUB}/scp"
}

teardown() { rm -rf "${TEST_TMP}"; }

priv() { env PATH="${STUB}:${PATH}" bash "$MOODLE" privacy "$@"; }

# ── the finding ──────────────────────────────────────────────────────────────

@test "p1: a component with no provider is exit 1 and is named" {
  PR_MODE=gap run priv ssd --tier=live --component=local_feedback
  [ "$status" -eq 1 ]
  [[ "$output" == *"local_feedback NO-PROVIDER"* ]]
  [[ "$output" == *"PRIVACY GAP"* ]]
}

@test "p2: a compliant component is exit 0 — the probe can return positive" {
  PR_MODE=clean run priv ssd --tier=live --component=local_feedback
  [ "$status" -eq 0 ]
  [[ "$output" == *"local_feedback COMPLIANT"* ]]
}

@test "p3: a run that did not complete is exit 3 CANNOT-VERIFY, never a pass" {
  PR_MODE=blind run priv ssd --tier=live --component=local_feedback
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"has NOT looked"* ]]
}

@test "p7: an asserted component that is not installed FAILS (no silent skip)" {
  PR_MODE=notinstalled run priv ssd --tier=live --component=local_feedback
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT-INSTALLED"* ]]
}

# ── staging discipline ───────────────────────────────────────────────────────

@test "p4: the helper is sha256-verified on the target before it is run" {
  PR_MODE=clean run priv ssd --tier=live --component=local_feedback
  [ "$status" -eq 0 ]
  grep -q 'SCP .*privacy-registry.php' "$PR_TRACE"
  grep -q 'SSH sha256sum ~/privacy-registry.php' "$PR_TRACE"
}

@test "p5: the /tmp stage is cleaned up on the FAILING path too" {
  PR_MODE=gap run priv ssd --tier=live --component=local_feedback
  [ "$status" -eq 1 ]
  grep -q 'rm -rf /tmp/nwp-privacy' "$PR_TRACE"
}

@test "p8: it writes nothing — no maintenance mode, no upgrade, no rsync" {
  PR_MODE=clean run priv ssd --tier=live --component=local_feedback
  [ "$status" -eq 0 ]
  ! grep -q 'maintenance' "$PR_TRACE"
  ! grep -q 'upgrade.php' "$PR_TRACE"
  ! grep -q 'rsync' "$PR_TRACE"
}

# ── argument surface ─────────────────────────────────────────────────────────

@test "p6: --tier is required and only live is supported" {
  run priv ssd --component=local_feedback
  [ "$status" -ne 0 ]
  [[ "$output" == *"--tier is required"* ]]
  run priv ssd --tier=stg --component=local_feedback
  [ "$status" -ne 0 ]
  [[ "$output" == *"only live"* ]]
}

@test "p9: the subcommand is wired into the dispatcher" {
  run bash "$MOODLE" privacy --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl moodle privacy"* ]]
}

# ── the helper's own argument validation (runs before Moodle is loaded) ───────

@test "p10: the helper refuses a non-frankenstyle --component without a Moodle" {
  run php "${REPO_ROOT}/scripts/moodle/privacy-registry.php" --component='../../etc/passwd'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Bad --component"* ]]
}

@test "p11: the helper is syntactically valid PHP" {
  run php -l "${REPO_ROOT}/scripts/moodle/privacy-registry.php"
  [ "$status" -eq 0 ]
}

# ── the verb bug this session also fixed ─────────────────────────────────────

@test "p12: plugin deploy accepts --override-pair, the flag its own refusal advertises" {
  run bash -c "grep -n -- '--override-pair)' '$MOODLE'"
  [ "$status" -eq 0 ]
  # and the guard is called with the parsed value, not the bare env var
  run bash -c "grep -n 'pair_guard \"\$BASE\" \"\$tier\" \"moodle-deploy\" \"true\" \"\$override_pair\"' '$MOODLE'"
  [ "$status" -eq 0 ]
}
