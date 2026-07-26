#!/usr/bin/env bats
# Item 2 (oversight-honesty): `pl audit`'s Moodle leg must be capable of going RED.
#
# Defect this locks down: `_moodle_field` used `sed 's/.*=//'`, which is greedy and
# takes the LAST `=` on the line. Moodle's real version.php reads:
#
#   $version  = 2024042212.01;   // 20240422      = branching date YYYYMMDD - do not modify!
#
# so both the installed and the upstream version parsed to the literal string
# `branchingdateYYYYMMDD-donotmodify!`. `awk 'a+0 < b+0'` then compared 0 < 0 and
# `behind` was ALWAYS 0. Live private/update-awareness/{ss,ssd}.json carry that
# string with security_count: 0 — a Moodle-CVE signal that could never fire.
#
# These tests must be able to go red on the real defect: (1) a genuinely behind
# Moodle must report behind=1; (2) an unparseable $version must set stale, never
# report a confident clean.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/audit-moodle"
  mkdir -p "$TMP/bin" "$TMP/state"
  PATH="$TMP/bin:$PATH"
}

# Write a Moodle-shaped version.php with the real trailing comment.
_fixture_version_php() {
  local dir="$1" version="$2" release="$3" branch="$4"
  mkdir -p "$dir"
  cat > "$dir/version.php" <<EOF
<?php
defined('MOODLE_INTERNAL') || die();

\$version  = $version;              // 20240422      = branching date YYYYMMDD - do not modify!
                                    // RR            = release increments - 00 in DEV branches.
                                    // .XX           = incremental changes.
\$release  = '$release';    // Human-friendly version name
\$branch   = '$branch';                      // This version's branch.
\$maturity = MATURITY_STABLE;            // This version's maturity level.
EOF
}

# Stub curl so moodle_audit_site sees a pinned upstream version.php.
_stub_curl_latest() {
  local version="$1" release="$2"
  cat > "$TMP/bin/curl" <<EOF
#!/bin/bash
cat <<'PHP'
<?php
\$version  = $version;              // 20240422      = branching date YYYYMMDD - do not modify!
\$release  = '$release';    // Human-friendly version name
\$branch   = '404';                      // This version's branch.
PHP
EOF
  chmod +x "$TMP/bin/curl"
}

_run_moodle_audit() {
  local site="$1"
  # shellcheck disable=SC1090
  STATE_DIR="$TMP/state" \
  bash -c '
    source "'"$ROOT"'/scripts/commands/audit.sh" >/dev/null 2>&1
    set +e +u
    STATE_DIR="'"$TMP"'/state"
    _site_dir() { printf "%s" "'"$TMP"'/sites/$1"; }
    moodle_audit_site "'"$site"'"
  '
}

@test "_moodle_field takes the FIRST '=' — the trailing branching-date comment must not win" {
  _fixture_version_php "$TMP/sites/oldss/dev" "2016052300.00" "3.1 (Build: 20160523)" "31"
  run bash -c '
    source "'"$ROOT"'/scripts/commands/audit.sh" >/dev/null 2>&1
    _moodle_field "'"$TMP"'/sites/oldss/dev/version.php" version
  '
  [ "$status" -eq 0 ]
  [ "$output" = "2016052300.00" ]
}

@test "a Moodle 3.1 audited against 4.4 STABLE reports behind=1 (security_count 1)" {
  _fixture_version_php "$TMP/sites/oldss/dev" "2016052300.00" "3.1 (Build: 20160523)" "404"
  _stub_curl_latest "2024042212.01" "4.4.12+ (Build: 20251212)"

  run _run_moodle_audit oldss
  [ "$status" -eq 0 ]
  # TSV: site<TAB>status<TAB>secfield<TAB>sec_count<TAB>stamp<TAB>path
  echo "audit line: $output"
  [[ "$output" == *"INSECURE"* ]]

  run python3 -c "import json;d=json.load(open('$TMP/state/oldss.json'));print(d['security_count'],d['moodle_installed_version'],d['moodle_latest_version'])"
  [ "$status" -eq 0 ]
  echo "record: $output"
  [[ "$output" == "1 2016052300.00 2024042212.01" ]]
}

@test "a current Moodle against the same upstream reports clean" {
  _fixture_version_php "$TMP/sites/curss/dev" "2024042212.01" "4.4.12+ (Build: 20251212)" "404"
  _stub_curl_latest "2024042212.01" "4.4.12+ (Build: 20251212)"

  run _run_moodle_audit curss
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  run python3 -c "import json;print(json.load(open('$TMP/state/curss.json'))['security_count'])"
  [ "$output" = "0" ]
}

@test "a non-numeric \$version must set cache_stale — never a confident security_count 0" {
  mkdir -p "$TMP/sites/weird/dev"
  cat > "$TMP/sites/weird/dev/version.php" <<'EOF'
<?php
defined('MOODLE_INTERNAL') || die();
$version  = MOODLE_VERSION_CONSTANT;     // patched by a distributor
$release  = 'custom';
$branch   = '404';
EOF
  _stub_curl_latest "2024042212.01" "4.4.12+ (Build: 20251212)"

  run _run_moodle_audit weird
  [ "$status" -eq 0 ]
  echo "audit line: $output"

  run python3 -c "import json;d=json.load(open('$TMP/state/weird.json'));print(d['cache_stale'])"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "an unreachable upstream (curl fails) must set cache_stale, not clean" {
  _fixture_version_php "$TMP/sites/offline/dev" "2016052300.00" "3.1 (Build: 20160523)" "404"
  cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
exit 7
EOF
  chmod +x "$TMP/bin/curl"

  run _run_moodle_audit offline
  [ "$status" -eq 0 ]
  run python3 -c "import json;print(json.load(open('$TMP/state/offline.json'))['cache_stale'])"
  [ "$output" = "True" ]
}
