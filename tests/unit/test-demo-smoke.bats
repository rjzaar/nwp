#!/usr/bin/env bats
# lib/demo-smoke.sh — does the demo tier SERVE what the invite email PROMISES?
#
# The demo pilot's failure mode is a broken promise, not a stack trace: the
# email tells a tester to click a link and land as a Sojourner, and the page
# 200s while carrying the partner site's name, or the SSO button is gone, or a
# route quietly redirects somewhere else. An uptime check passes through all of
# that. These tests pin the properties that make the smoke verb able to fail.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  LIB="${REPO_ROOT}/lib/demo-smoke.sh"
}

# Build a fake curl on PATH so the checks can be driven without a network.
_with_fake_page() {
  FAKE="$(mktemp -d)"
  printf '%s' "$1" > "$FAKE/body"
  printf '%s' "${2:-200}" > "$FAKE/code"
  cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
cat "$d/body"
printf '\n__HTTP__%s' "$(cat "$d/code")"
EOF
  chmod +x "$FAKE/curl"
  export PATH="$FAKE:$PATH"
}

# Must end 0: bats treats a non-zero teardown as a test failure, and
# `[ -n "" ]` is non-zero for the tests that never build a fake page.
teardown() { [ -n "${FAKE:-}" ] && rm -rf "$FAKE"; return 0; }

@test "title check reads the FIRST <title>, not an SVG icon's" {
  # Open Social embeds <title> inside inline SVG icons. A greedy match walks
  # past the document title to the last one on the page, which is how this
  # first reported a page's title as "Close search window".
  _with_fake_page '<html><head><title>Narrow Way Commons</title></head><body><svg><title>Close search window</title></svg></body></html>'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_title T http://x 'Narrow Way Commons' 'Saint School'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Narrow Way Commons"* ]]
  [[ "$output" != *"Close search window"* ]]
}

@test "title check FAILS when the page is titled with the PARTNER's name" {
  # This is finding A1-2: nwd shipped with system.site.name set to the partner's
  # name, so every page title claimed to be the other site.
  _with_fake_page '<html><head><title>Saint School Demo</title></head><body>hi</body></html>'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_title T http://x 'Narrow Way Commons' 'Saint School'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"PARTNER"* ]]
}

@test "a mention of the partner in the BODY is not a failure" {
  # nwd legitimately links to Saint School — that is the point of a two-site
  # pilot and the invite email says so. Only the site's own IDENTITY is at issue.
  _with_fake_page '<html><head><title>Narrow Way Commons</title></head><body>Then head over to Saint School for courses.</body></html>'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_title T http://x 'Narrow Way Commons' 'Saint School'"
  [ "$status" -eq 0 ]
}

@test "a 200 page missing the promised text FAILS (not merely 'up')" {
  # The SSO button vanishing leaves the login page returning a perfectly healthy
  # 200 — invisible to uptime, fatal to the email's STEP 2.
  _with_fake_page '<html><body>Username Password</body></html>'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_contains SSO http://x 'Log in using your account on'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does NOT contain"* ]]
}

@test "content checks FAIL rather than pass when the page did not load" {
  _with_fake_page 'irrelevant' '500'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_contains X http://x 'anything'"
  [ "$status" -ne 0 ]
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_title X http://x 'a' 'b'"
  [ "$status" -ne 0 ]
}

@test "a page with no <title> at all FAILS" {
  _with_fake_page '<html><body>no head</body></html>'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_title T http://x 'Anything' ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no <title>"* ]]
}

@test "smoke_summary is non-zero when anything failed, and warnings never mask it" {
  run bash -c "source '$LIB'; smoke_reset_counters; SMOKE_PASS=5; SMOKE_FAIL=1; SMOKE_WARN=9; smoke_summary"
  [ "$status" -ne 0 ]
  run bash -c "source '$LIB'; smoke_reset_counters; SMOKE_PASS=5; SMOKE_FAIL=0; SMOKE_WARN=9; smoke_summary"
  [ "$status" -eq 0 ]
}

@test "every probe is a GET — the verb must be safe to point at live" {
  # This is what allows it to run against a production demo site and on a
  # schedule. A POST here would make it unrunnable where it matters most.
  run grep -nE '(-X[[:space:]]*(POST|PUT|DELETE)|--data|--request)' "$LIB"
  [ "$status" -ne 0 ]
}
