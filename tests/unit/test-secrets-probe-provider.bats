#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-secrets-probe-provider.bats
# an HTTP probe on an unrecognised provider was SILENTLY NOT RUN
# =============================================================================
# CLAUDE.md: "A declared scope must carry a `probe:` … because a capability the
# registry never checks is folklore." `pl secrets lint` enforces the presence of
# the block. Nothing enforced that the block is EXECUTED.
#
# `_probe_scopes()` ran its ssh probes first, then reached:
#
#     case "$prov" in
#       gitlab) hdr="PRIVATE-TOKEN:" ;;
#       github|linode) hdr="Authorization: Bearer" ;;
#       *) printf '%s' "$out"; return 0 ;;      # <-- every other provider
#     esac
#
# So an entry with `provider: nwp-internal`, `smtp`, `moodle`, `drupal`,
# `webhook` or `anthropic` could declare any number of HTTP probes — including
# NEGATIVE ones, which are the only way to record a LIMIT — and every one of
# them was skipped without a word. The audit then printed a clean row. That is
# the ops#214 class exactly: a check that has never been proven capable of
# failing, and here one that could not fail even in principle.
#
# It is not hypothetical. `avc_ss_feedback_cross_site` is `provider:
# nwp-internal`, and ops#336 adds `nwc_cross_site_bearer` on the same provider:
# a shared bearer guarding three UNAUTHENTICATED write endpoints, whose whole
# reason for having a probe is to prove it still authenticates and that a WRONG
# token still does not.
#
# Fixed by: (a) an explicit `header:` on a probe, so any provider can state how
# its credential is presented; (b) `PROBE-UNSUPPORTED` reported — and counted as
# a problem — when a probe cannot be run, instead of silence. Fail-closed:
# "I could not check this capability" must never render as "this capability is
# as recorded".

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SECRETS_SH="$REPO_ROOT/scripts/commands/secrets.sh"
    export REG="$BATS_TEST_TMPDIR/registry.yml"

    # A minimal harness: the real _probe_scopes, with the network stubbed so
    # each probe's "response" is whatever the fixture says it should be.
    HARNESS="$BATS_TEST_TMPDIR/h.sh"
    {
        echo "YQ=yq"
        echo "REGISTRY=\"\$REG\""
        cat <<'STUB'
expand_placeholders(){ printf '%s' "$1"; }
# The stub answers with the code embedded in the URL, so a fixture can say
# "this endpoint returns 401" without a network.
_audit_code(){
  case "$1" in
    *"/gives-200"*) echo 200 ;;
    *"/gives-401"*) echo 401 ;;
    *)              echo 500 ;;
  esac
}
# Records what the transport was actually handed, so a test can prove the
# credential really was presented rather than a literal {TOKEN}.
_audit_status_body(){
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/last-url"
  case "$1" in
    *"/gives-200"*) printf '200\n%s' "$STUB_BODY" ;;
    *"/gives-401"*) printf '401\n%s' "$STUB_BODY" ;;
    *)              printf '500\n%s' "$STUB_BODY" ;;
  esac
}
STUB
        sed -n '/^_probe_scopes(){/,/^}/p' "$SECRETS_SH"
    } > "$HARNESS"
}

scopes() { STUB_BODY="${STUB_BODY:-}" bash -c "source '$HARNESS'; _probe_scopes 0 '$1' TOKENVALUE"; }

# --------------------------------------------------------------------------
# THE RED. A probe that must fail, on a provider the runner does not know.
# --------------------------------------------------------------------------

@test "an HTTP probe on a non-gitlab provider is actually RUN (was skipped in silence)" {
    cat > "$REG" <<'YML'
secrets:
  - id: shared_bearer
    provider: nwp-internal
    probe:
      - {name: "must-authenticate", url: "https://demo.example.org/gives-401", expect: 200, header: "X-Cross-Site-Token:"}
YML
    run scopes nwp-internal
    # The endpoint answers 401 and the registry claims 200. That is SCOPE-DRIFT.
    # Before the fix this returned an empty string: a clean bill of health for a
    # capability nobody looked at.
    [[ "$output" == *"SCOPE-DRIFT(must-authenticate want=200 got=401)"* ]]
}

@test "a NEGATIVE probe on a non-gitlab provider goes red when the limit widens" {
    cat > "$REG" <<'YML'
secrets:
  - id: shared_bearer
    provider: nwp-internal
    probe:
      - {name: "NEGATIVE-wrong-token-rejected", url: "https://demo.example.org/gives-200", expect: 401, header: "X-Cross-Site-Token:"}
YML
    run scopes nwp-internal
    [[ "$output" == *"SCOPE-DRIFT(NEGATIVE-wrong-token-rejected want=401 got=200)"* ]]
}

@test "a satisfied probe on a non-gitlab provider reports nothing" {
    cat > "$REG" <<'YML'
secrets:
  - id: shared_bearer
    provider: nwp-internal
    probe:
      - {name: "must-authenticate", url: "https://demo.example.org/gives-200", expect: 200, header: "X-Cross-Site-Token:"}
YML
    run scopes nwp-internal
    [ "$output" = "" ]
}

# --------------------------------------------------------------------------
# FAIL CLOSED. When a probe genuinely cannot be run, SAY SO.
# --------------------------------------------------------------------------

@test "a probe with no runnable header on an unknown provider reports PROBE-UNSUPPORTED, not silence" {
    cat > "$REG" <<'YML'
secrets:
  - id: mystery
    provider: some-provider-with-no-known-auth-header
    probe:
      - {name: "reaches-thing", url: "https://demo.example.org/gives-200", expect: 200}
YML
    run scopes some-provider-with-no-known-auth-header
    [[ "$output" == *"PROBE-UNSUPPORTED(reaches-thing"* ]]
    # And it must NOT be reported as a satisfied probe.
    [[ "$output" != "" ]]
}

@test "a known provider still uses its own header without declaring one" {
    cat > "$REG" <<'YML'
secrets:
  - id: a_gitlab_token
    provider: gitlab
    probe:
      - {name: "alive", url: "https://git.example.org/gives-401", expect: 200}
YML
    run scopes gitlab
    [[ "$output" == *"SCOPE-DRIFT(alive want=200 got=401)"* ]]
}

@test "ssh probes are unaffected by the header change" {
    cat > "$REG" <<'YML'
secrets:
  - id: a_key
    provider: local
    probe:
      - {name: "reaches-box", ssh: "nobody@127.0.0.1", key: "/nonexistent/key", expect_rc: 0}
YML
    run scopes local
    # A probe key that is not on this host cannot answer the question, and the
    # existing code already says PROBE-BLIND rather than reporting a negative.
    [[ "$output" == *"PROBE-BLIND(reaches-box key-absent)"* ]]
}

# --------------------------------------------------------------------------
# A credential presented in the URL. Moodle's web-service API takes `wstoken=`,
# not a header — and the two ssd_nwd_completion_ws probes have been sitting in
# the real registry with a LITERAL `wstoken={TOKEN}`, never substituted and
# (because of the provider gate above) never run either.
# --------------------------------------------------------------------------

@test "{TOKEN} in the url is a valid credential presentation, and is substituted" {
    cat > "$REG" <<'YML'
secrets:
  - id: a_moodle_ws_token
    provider: moodle
    probe:
      - {name: "siteinfo", url: "https://ssd.example.org/gives-200?wstoken={TOKEN}", expect: 200, expect_body_contains: "sitename"}
YML
    STUB_BODY='{"sitename":"SSD"}' run scopes moodle
    [ "$output" = "" ]
    run cat "$BATS_TEST_TMPDIR/last-url"
    [[ "$output" == *"wstoken=TOKENVALUE"* ]]
    [[ "$output" != *"{TOKEN}"* ]]
}

@test "expect_body_contains is CHECKED — a 200 whose body refuses is not a pass" {
    cat > "$REG" <<'YML'
secrets:
  - id: a_moodle_ws_token
    provider: moodle
    probe:
      - {name: "NEGATIVE-not-a-write-token", url: "https://ssd.example.org/gives-200?wstoken={TOKEN}", expect: 200, expect_body_contains: "accessexception"}
YML
    # The token CAN write: Moodle answers 200 with a real result, no exception.
    # Status alone would read as a pass; the body is the whole verdict.
    STUB_BODY='{"warnings":[]}' run scopes moodle
    [[ "$output" == *"SCOPE-DRIFT(NEGATIVE-not-a-write-token body lacks 'accessexception')"* ]]
}

@test "expect_body_contains is satisfied when the refusal really is there" {
    cat > "$REG" <<'YML'
secrets:
  - id: a_moodle_ws_token
    provider: moodle
    probe:
      - {name: "NEGATIVE-not-a-write-token", url: "https://ssd.example.org/gives-200?wstoken={TOKEN}", expect: 200, expect_body_contains: "accessexception"}
YML
    STUB_BODY='{"exception":"webservice_access_exception","errorcode":"accessexception"}' run scopes moodle
    [ "$output" = "" ]
}
