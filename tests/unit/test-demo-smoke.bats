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

# --- A10: the SSO button must say what the email says ---------------------------
# `pl demo smoke nwd` sat 9/9 green while the invite email named the button
# wrongly, because the old check only proved the page said "Log in using your
# account on" SOMEWHERE — it never read the text of the button the tester must
# actually click. These pin the equality check against the contract's name.

_btn_page() {
  printf '<html><body><h2 class="login-heading">Log in using your account on:</h2>
<a class="btn login-identityprovider-btn btn-block" href="/auth/oauth2/login.php?id=1">%s</a></body></html>' "$1"
}

@test "SSO button label: equals the contract name, surrounding whitespace collapsed" {
  # Moodle renders the label padded with spaces and newlines — the live button
  # carries "     Narrow Way Commons     ". Cosmetic whitespace is not drift.
  _with_fake_page "$(_btn_page '     Narrow Way
   Commons   ')"
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_button_label B http://x login-identityprovider-btn 'Narrow Way Commons'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Narrow Way Commons"* ]]
}

@test "SSO button label: a codename on the button FAILS even when the heading is right" {
  _with_fake_page "$(_btn_page 'nwd (F26)')"
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_button_label B http://x login-identityprovider-btn 'Narrow Way Commons'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nwd (F26)"* ]]
  [[ "$output" == *"Narrow Way Commons"* ]]
}

@test "SSO button label: a login page with NO identity-provider button FAILS" {
  # The issuer being disabled removes the button while the page still 200s.
  _with_fake_page '<html><body><h2>Log in using your account on:</h2> Username Password</body></html>'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_button_label B http://x login-identityprovider-btn 'Narrow Way Commons'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

# --- A12: redirects checked WITHOUT following them -------------------------------

# Fake curl that answers with a raw header block (what -D - produces).
_with_fake_redirect() {
  FAKE="$(mktemp -d)"
  {
    printf 'HTTP/2 %s \r\n' "$1"
    [ -n "${2:-}" ] && printf 'location: %s\r\n' "$2"
    printf 'content-type: text/html\r\n\r\n'
  } > "$FAKE/headers"
  cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
cat "$d/headers"
EOF
  chmod +x "$FAKE/curl"
  export PATH="$FAKE:$PATH"
}

@test "redirect check: 302 with Location ending /apply PASSES without following" {
  _with_fake_redirect 302 'https://x.example/apply'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_redirect R http://x/user/register 302 /apply"
  [ "$status" -eq 0 ]
}

@test "redirect check: a 200 that never redirects FAILS" {
  # /user/register serving an open registration form is exactly the regression
  # this exists to catch — the gated-signup promise silently un-gated.
  _with_fake_redirect 200 ''
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_redirect R http://x/user/register 302 /apply"
  [ "$status" -ne 0 ]
}

@test "redirect check: redirecting somewhere ELSE fails — a query-string /apply does not count" {
  # ?destination=/apply ENDS with /apply; the check must compare the path, not
  # the raw string, or a login bounce would impersonate the apply redirect.
  _with_fake_redirect 302 'https://x.example/user/login?destination=/apply'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_redirect R http://x/user/register 302 /apply"
  [ "$status" -ne 0 ]
}

# --- A14: the consumer's shortname must not be its public identity ---------------

@test "shortname leak: <title> 'Home | ssd' FAILS the machine-name rule" {
  # This is the defect the 9/9-green run missed: ssd's own front page titled
  # with the machine shortname while every promise-level check passed.
  _with_fake_page '<html><head><title>Home | ssd</title></head><body></body></html>'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_title_regex T http://x 'Saint School' '\bssd\b'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "shortname leak: a word merely CONTAINING the shortname is not a leak" {
  _with_fake_page '<html><head><title>Saint School ssdemo</title></head><body></body></html>'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_title_regex T http://x 'Saint School' '\bssd\b'"
  [ "$status" -eq 0 ]
}

@test "shortname leak: passing the forbid rule is not enough — the real name must be present" {
  _with_fake_page '<html><head><title>Home</title></head><body></body></html>'
  run bash -c "source '$LIB'; smoke_reset_counters; smoke_check_title_regex T http://x 'Saint School' '\bssd\b'"
  [ "$status" -ne 0 ]
}

# --- the consumer half smokes ITSELF ---------------------------------------------

@test "pl demo smoke <consumer> runs its own half's assertions, not a bounce to the provider" {
  # Delegating ssd's smoke wholesale to nwd is how a broken ssd surface hid
  # behind a green nwd run. The consumer path must exist by name, and the old
  # redirect-to-provider message must be gone.
  DEMO_CMD="${REPO_ROOT}/scripts/commands/demo.sh"
  grep -q 'smoke_consumer_half' "$DEMO_CMD"
  ! grep -q 'smoking the provider' "$DEMO_CMD"
}
