#!/usr/bin/env bats
# ops#328 tranche 5 — `pl demo walkthrough <site>` and the PROD-PHASE guard.
#
# The walkthrough verb answers one question for the console: "what can the
# operator jump into on this demo pair, and does each of those targets still
# resolve?" It is the data behind the Visuals ▸ walkthrough subtab.
#
# What is pinned here, and why each one is a gate rather than a hope:
#
#   * A TARGET NOBODY MEASURED IS `unknown`, NEVER `verified`. A link that
#     looks live and 404s is worse than no link (ops#292/#281). The verb ships
#     `verify.state: "unknown"` until a `--verify` run has actually measured,
#     and the counts say so.
#   * ABSENCE IS NOT MEASURABLE OVER HTTP ON THESE STACKS. Measured live
#     2026-08-11: nwd answers an unknown path with a 55 KB THEMED 404 and ssd
#     answers /auth/oauth2/login.php (a file that exists) with a Moodle-rendered
#     404. So the provider is verified through the ROUTER (`drush route`), and
#     a consumer 404 that carries an application body is `ambiguous`, never
#     `missing`. This is the swallowed-verdict class in its natural habitat.
#   * A ROUTE THAT MOVED IS `drifted`, not `verified` — same name, different
#     path, and the link would land on nothing.
#   * FAIL CLOSED: no catalogue, unreadable catalogue, unreadable roster, no
#     curl, unreadable router → exit 2 CANNOT VERIFY with a reason. Never an
#     empty-but-healthy target list.
#   * THE PROD-PHASE GUARD (CLAUDE.md, ops#33/#214). Minting a login link or
#     probing a site is refused when the site's CANONICAL PHASE is prod —
#     keyed off the phase, never off a site name. Inert today (no site is
#     prod), so it is proven here against a fixture that IS.
#
# The guard cases are the ones that must be seen RED: before this tranche,
# `pl demo testers <site> login` would happily mint a one-time login link on a
# site declared `canonical: prod`.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/sites/demo1" "${PROJECT_ROOT}/sites/cons1"
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  source "${REPO_ROOT}/lib/demo.sh"
  DEMO_CMD="${REPO_ROOT}/scripts/commands/demo.sh"
  export NWP_DEMO_REGISTRY_HOME_FILE="${TEST_TMP}/registry-home.yml"
  printf 'registry_home: %s\n' "$(hostname -s)" > "$NWP_DEMO_REGISTRY_HOME_FILE"
  # The catalogue the verb reads. Tests that want the SHIPPED one unset this.
  export NWP_WALKTHROUGH_CATALOG="${TEST_TMP}/targets.yml"
  catalog_fixture
  pair_fixture
  # Default: an ordinary dev-phase site, so the prod guard is not in play.
  phase_fixture demo1 dev
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset PROJECT_ROOT NWP_DEMO_REGISTRY_HOME_FILE NWP_WALKTHROUGH_CATALOG NWP_YML NWP_PAIR_CONTRACT_DIR
}

# --- fixtures ----------------------------------------------------------------

# The global nwp.yml canonical_get_phase() reads. `phase_fixture <site> <phase>`
phase_fixture() {
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  cat > "$NWP_YML" <<YML
sites:
  demo1:
    canonical: ${2}
    live:
      domain: demo1.example.invalid
  cons1:
    canonical: dev
    live:
      domain: cons1.example.invalid
YML
}

# The pair contract that binds demo1 (provider) to cons1 (consumer). The verb
# resolves the consumer from here, never by guessing.
pair_fixture() {
  export NWP_PAIR_CONTRACT_DIR="${TEST_TMP}/pairs"
  mkdir -p "$NWP_PAIR_CONTRACT_DIR"
  cat > "${NWP_PAIR_CONTRACT_DIR}/cons1.pair-contract.yml" <<'YML'
pair: cons1-demo1
provider: demo1
consumer: cons1
demo:
  enabled: true
YML
}

catalog_fixture() {
  cat > "${NWP_WALKTHROUGH_CATALOG}" <<'YML'
version: 1
provider:
  sections:
    - key: entry
      label: Entry points
      targets:
        - key: stream
          label: Stream
          path: /stream
          route: social_core.homepage
        - key: about
          label: About
          path: /about
          kind: alias
    - key: queues
      label: Queues
      targets:
        - key: feedback
          label: Feedback triage
          path: /admin/nwc/feedback
          route: nwc_feedback.overview
          admin_only: true
  group_targets:
    - key: about
      label: Group about
      path: /group/{gid}/about
      route: view.group_information.page_group_about
    - key: dash
      label: Guild dashboard
      path: /group/{gid}/guild-dashboard
      route: nwc_guild.dashboard
consumer:
  sections:
    - key: entry
      label: Entry points
      targets:
        - key: home
          label: Site home
          path: /
        - key: courses
          label: All courses
          path: /course/index.php
YML
}

# A DDEV project + stub `ddev drush` answering the roster read the verb uses.
site_fixture() {
  mkdir -p "${PROJECT_ROOT}/sites/demo1/.ddev" "${TEST_TMP}/bin"
  printf 'docroot: web\n' > "${PROJECT_ROOT}/sites/demo1/.ddev/config.yaml"
  printf 'true\n' > "${TEST_TMP}/demo_mode"
  printf '0\n' > "${TEST_TMP}/drush_rc"
  cat > "${TEST_TMP}/tester_json" <<'JSON'
{"ok":true,"counts":{"fenced_active":2},
 "accounts":[
   {"uid":33,"name":"nwcdemo_walkthrough","mail":"nwcdemo_walkthrough@demo.invalid",
    "active":true,"roles":["verified","administrator"],
    "guilds":[{"group_id":10,"type":"guild","label":"Media Guild","seed_key":"media","roles":["guild-admin"]},
              {"group_id":3,"type":"flexible_group","label":"Writers IG","seed_key":"writers-ig","roles":["flexible_group-member"]}],
    "sojourner_level":0},
   {"uid":2,"name":"demo_writer","mail":"demo_writer@demo.invalid","active":true,
    "roles":["verified"],"guilds":[],"sojourner_level":0}],
 "guild_catalog":{"guilds":[{"seed_key":"media","label":"Media Guild","group_id":10,"type":"guild"}]}}
JSON
  cat > "${TEST_TMP}/bin/ddev" <<STUB
#!/bin/bash
T="${TEST_TMP}"
[ "\$1" = "drush" ] || exit 1
shift
case "\$1" in
  cget) cat "\$T/demo_mode" 2>/dev/null || true; exit 0 ;;
  route) cat "\$T/route_json" 2>/dev/null || echo '{}'; exit "\$(cat "\$T/route_rc" 2>/dev/null || echo 0)" ;;
  nwc:tester-list)
    echo "\$@" >> "\$T/drush_calls"
    if [ -e "\$T/not_defined" ]; then
      echo "  Command \"\$1\" is not defined." >&2; exit 1
    fi
    cat "\$T/tester_json"; exit "\$(cat "\$T/drush_rc")" ;;
esac
exit 1
STUB
  chmod +x "${TEST_TMP}/bin/ddev"
  export PATH="${TEST_TMP}/bin:$PATH"
  cat > "${TEST_TMP}/route_json" <<'JSON'
{"social_core.homepage":"/stream",
 "nwc_feedback.overview":"/admin/nwc/feedback",
 "view.group_information.page_group_about":"/group/{group}/about",
 "nwc_guild.dashboard":"/group/{group}/guild-dashboard"}
JSON
  printf '0\n' > "${TEST_TMP}/route_rc"
}

# A stub curl whose verdict per URL is steered by $TEST_TMP/http_map
# (lines "<substring> <code> <bodylen>"). Anything unmatched is 200/1000.
curl_fixture() {
  mkdir -p "${TEST_TMP}/bin"
  : > "${TEST_TMP}/http_map"
  cat > "${TEST_TMP}/bin/curl" <<'STUB'
#!/bin/bash
url=""
for a in "$@"; do case "$a" in https://*|http://*) url="$a";; esac; done
code=200; len=1000
while read -r pat c l; do
  [ -n "$pat" ] || continue
  case "$url" in *"$pat"*) code="$c"; len="$l";; esac
done < "$TEST_TMP_FOR_CURL/http_map"
body=""
if [ "$len" -gt 0 ]; then
  body="<title>stub page</title>"
  while [ "${#body}" -lt "$len" ]; do body="${body}x"; done
fi
printf '%s\n__NWPHTTP__%s\n' "$body" "$code"
STUB
  chmod +x "${TEST_TMP}/bin/curl"
  export TEST_TMP_FOR_CURL="${TEST_TMP}"
  export PATH="${TEST_TMP}/bin:$PATH"
}

# --- 1. dispatch + shape -----------------------------------------------------

@test "walkthrough is a real subcommand" {
  site_fixture
  run bash "$DEMO_CMD" walkthrough demo1 --json
  refute_output_contains "Unknown subcommand"
}

@test "walkthrough --json emits targets with per-side counts" {
  site_fixture
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true' >/dev/null
  echo "$output" | jq -e '.targets | length > 0' >/dev/null
  echo "$output" | jq -e '.counts.total == (.targets | length)' >/dev/null
  echo "$output" | jq -e '[.targets[].side] | unique | sort == ["consumer","provider"]' >/dev/null
}

@test "every catalogue path is site-relative — no host is ever baked in" {
  site_fixture
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.targets[].path | startswith("/")] | all' >/dev/null
  echo "$output" | jq -e '[.targets[].path | test("^https?://") | not] | all' >/dev/null
}

@test "group targets are expanded with REAL group ids read from the site" {
  site_fixture
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.targets[] | select(.path == "/group/10/guild-dashboard")] | length == 1' >/dev/null
  echo "$output" | jq -e '[.targets[].path | test("\\{gid\\}")] | any | not' >/dev/null
}

@test "the group source is NAMED, so a partial catalogue cannot pass as complete" {
  site_fixture
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.groups.source | test("catalog|roster")' >/dev/null
  echo "$output" | jq -e '.groups.count >= 1' >/dev/null
}

# --- 2. the two zeros --------------------------------------------------------

@test "an unmeasured target is unknown, NEVER verified" {
  site_fixture
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.targets[].verify.state] | unique == ["unknown"]' >/dev/null
  echo "$output" | jq -e '.counts.verified == 0' >/dev/null
  echo "$output" | jq -e '.verification.state == "never"' >/dev/null
}

@test "a missing catalogue is exit 2 CANNOT VERIFY, not an empty list" {
  site_fixture
  export NWP_WALKTHROUGH_CATALOG="${TEST_TMP}/does-not-exist.yml"
  # stdout is the machine document, stderr the human diagnostic — separated
  # here so the assertion is on the DOCUMENT, not on the two mixed together.
  run --separate-stderr bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false' >/dev/null
  echo "$output" | grep -qi "CANNOT VERIFY"
  echo "$stderr" | grep -qi "catalogue not found"
}

@test "an unreadable roster is exit 2 CANNOT VERIFY, not zero groups" {
  site_fixture
  printf '1\n' > "${TEST_TMP}/drush_rc"
  printf 'not json\n' > "${TEST_TMP}/tester_json"
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi "CANNOT VERIFY"
}

@test "an undeployed nwc:tester-list is a NAMED not_deployed, not error soup" {
  site_fixture
  touch "${TEST_TMP}/not_defined"
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.not_deployed == true' >/dev/null
}

# --- 3. verification ---------------------------------------------------------

@test "--verify marks a present route verified and a moved route DRIFTED" {
  site_fixture
  curl_fixture
  cat > "${TEST_TMP}/route_json" <<'JSON'
{"social_core.homepage":"/stream",
 "nwc_feedback.overview":"/admin/nwc/feedback-MOVED",
 "view.group_information.page_group_about":"/group/{group}/about",
 "nwc_guild.dashboard":"/group/{group}/guild-dashboard"}
JSON
  run bash "$DEMO_CMD" walkthrough demo1 --verify --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.targets[] | select(.route == "social_core.homepage")][0].verify.state == "verified"' >/dev/null
  echo "$output" | jq -e '[.targets[] | select(.route == "nwc_feedback.overview")][0].verify.state == "drifted"' >/dev/null
}

@test "--verify marks a route the router does not know as MISSING" {
  site_fixture
  curl_fixture
  printf '{"social_core.homepage":"/stream"}\n' > "${TEST_TMP}/route_json"
  run bash "$DEMO_CMD" walkthrough demo1 --verify --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.targets[] | select(.route == "nwc_guild.dashboard")][0].verify.state == "missing"' >/dev/null
  echo "$output" | jq -e '.counts.missing >= 1' >/dev/null
}

@test "a consumer 404 WITH an application body is ambiguous, never missing" {
  site_fixture
  curl_fixture
  printf '/course/index.php 404 900\n' > "${TEST_TMP}/http_map"
  run bash "$DEMO_CMD" walkthrough demo1 --verify --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.targets[] | select(.path == "/course/index.php")][0].verify.state == "ambiguous"' >/dev/null
}

@test "a consumer BARE 404 (no application body) is missing" {
  site_fixture
  curl_fixture
  printf '/course/index.php 404 0\n' > "${TEST_TMP}/http_map"
  run bash "$DEMO_CMD" walkthrough demo1 --verify --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.targets[] | select(.path == "/course/index.php")][0].verify.state == "missing"' >/dev/null
}

@test "--verify with no curl on the host is exit 2, never a clean sweep" {
  site_fixture
  mkdir -p "${TEST_TMP}/nocurl"
  cat > "${TEST_TMP}/nocurl/curl" <<'STUB'
#!/bin/bash
exit 127
STUB
  chmod +x "${TEST_TMP}/nocurl/curl"
  run env NWP_WALKTHROUGH_NO_CURL=1 bash "$DEMO_CMD" walkthrough demo1 --verify --json
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi "CANNOT VERIFY"
}

@test "--verify records the measurement so a later read reports its age" {
  site_fixture
  curl_fixture
  run bash "$DEMO_CMD" walkthrough demo1 --verify --json
  [ "$status" -eq 0 ]
  [ -f "${PROJECT_ROOT}/private/demo-walkthrough/demo1.json" ]
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verification.state == "measured"' >/dev/null
  echo "$output" | jq -e '.verification.age_seconds >= 0' >/dev/null
}

# --- 4. the walkthrough account ---------------------------------------------

@test "the walkthrough account is reported present with its clearance" {
  site_fixture
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.account.present == true' >/dev/null
  echo "$output" | jq -e '.account.name == "nwcdemo_walkthrough"' >/dev/null
  echo "$output" | jq -e '.account.uid == 33' >/dev/null
  echo "$output" | jq -e '.account.guilds == 2' >/dev/null
  echo "$output" | jq -e '.account.admin == true' >/dev/null
}

@test "a roster without the walkthrough account says so, with the fix" {
  site_fixture
  cat > "${TEST_TMP}/tester_json" <<'JSON'
{"ok":true,"counts":{},"accounts":[{"uid":2,"name":"demo_writer","mail":"demo_writer@demo.invalid","active":true,"roles":[],"guilds":[],"sojourner_level":0}]}
JSON
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.account.present == false' >/dev/null
  echo "$output" | jq -e '.account.reason | test("seed-demo|nwc")' >/dev/null
}

# --- 5. THE PROD-PHASE GUARD (ops#33 / ops#214) ------------------------------

@test "RED: testers login REFUSES on a site whose canonical phase is prod" {
  site_fixture
  phase_fixture demo1 prod
  run bash "$DEMO_CMD" testers demo1 login nwcdemo_walkthrough --tier=live
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "canonical: prod"
}

@test "RED: testers set-guild REFUSES on a prod-phase site" {
  site_fixture
  phase_fixture demo1 prod
  run bash "$DEMO_CMD" testers demo1 set-guild nwcdemo_walkthrough media --tier=live
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "canonical: prod"
}

@test "RED: walkthrough --verify REFUSES on a prod-phase site" {
  site_fixture
  curl_fixture
  phase_fixture demo1 prod
  run bash "$DEMO_CMD" walkthrough demo1 --verify --json
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "canonical: prod"
}

@test "the guard is INERT at dev and live — it refuses a phase, not a name" {
  site_fixture
  phase_fixture demo1 live
  run bash "$DEMO_CMD" testers demo1 login nwcdemo_walkthrough --tier=live
  refute_output_contains "canonical: prod"
}

@test "an UNREADABLE canonical phase refuses too — fail closed, not open" {
  site_fixture
  export NWP_YML="${TEST_TMP}/no-such-nwp.yml"
  run bash "$DEMO_CMD" testers demo1 login nwcdemo_walkthrough --tier=live
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi "CANNOT VERIFY"
}

@test "a READ of the walkthrough is allowed at prod phase — only minting is not" {
  site_fixture
  phase_fixture demo1 prod
  run bash "$DEMO_CMD" walkthrough demo1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.phase == "prod"' >/dev/null
  echo "$output" | jq -e '.jump_in_allowed == false' >/dev/null
}

# --- 6. the SHIPPED catalogue ------------------------------------------------

@test "the shipped catalogue parses and declares both halves" {
  unset NWP_WALKTHROUGH_CATALOG
  run bash -c "source '${REPO_ROOT}/lib/demo.sh'; source '${REPO_ROOT}/lib/demo-walkthrough.sh'; demo_walkthrough_catalog_json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.provider.sections | length > 0' >/dev/null
  echo "$output" | jq -e '.consumer.sections | length > 0' >/dev/null
  echo "$output" | jq -e '.provider.group_targets | length > 0' >/dev/null
}

@test "no shipped catalogue entry names a host — the P61 leakage rule" {
  unset NWP_WALKTHROUGH_CATALOG
  run bash -c "source '${REPO_ROOT}/lib/demo.sh'; source '${REPO_ROOT}/lib/demo-walkthrough.sh'; demo_walkthrough_catalog_json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.. | strings | select(test("nwpcode\\.org|https?://"))] | length == 0' >/dev/null
}

@test "every shipped PROVIDER target declares a route or is marked an alias" {
  unset NWP_WALKTHROUGH_CATALOG
  run bash -c "source '${REPO_ROOT}/lib/demo.sh'; source '${REPO_ROOT}/lib/demo-walkthrough.sh'; demo_walkthrough_catalog_json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.provider.sections[].targets[], .provider.group_targets[]
                           | select((.route // "") == "" and (.kind // "") != "alias")] | length == 0' >/dev/null
}

# --- helpers -----------------------------------------------------------------

refute_output_contains() {
  if echo "$output" | grep -qF -- "$1"; then
    echo "expected output NOT to contain: $1"
    echo "--- got ---"
    echo "$output"
    return 1
  fi
}
