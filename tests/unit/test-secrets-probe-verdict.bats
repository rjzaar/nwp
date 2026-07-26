#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-secrets-probe-verdict.bats
# "could not ask" is not "revoked"
# =============================================================================
# `_audit_body` returned the response body and threw the HTTP status away, and
# `_probe_value` then concluded "no username in the body ⇒ DEAD". So EVERY
# non-200 — a 429 rate-limit, a 502, a 12-second timeout, a captive portal —
# rendered as `DEAD` / `REVOKED/INVALID`.
#
# Measured 2026-07-26 against the live estate: a direct probe of
# `gitlab_bot_ci_audit` returns HTTP 200 with `username: project_11_bot_…` and
# `expires_at: 2027-06-27`, matching the registry exactly — a healthy project
# access token. It had nonetheless been reported DEAD, because any transient
# non-200 was indistinguishable from a rejection.
#
# Note the host does not have to be down for this to bite: cmd_audit's
# reachability pre-check only fires when `/api/v4/metadata` itself returns 000,
# so a per-token 429/5xx/timeout sails past it and lands as "REVOKED/INVALID".
#
# This is the same failure as `--honesty` printing "clean" over a corpus it
# could not see, inverted: the tool asserting a DEFINITE NEGATIVE on no
# evidence. It matters because this audit runs daily from cron.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SECRETS_SH="$REPO_ROOT/scripts/commands/secrets.sh"

    # Load only the probe helpers, with the network stubbed.
    HARNESS="$BATS_TEST_TMPDIR/h.sh"
    {
        sed -n '/^_audit_verdict(){/,/^}/p' "$SECRETS_SH"
        sed -n '/^_probe_value(){/,/^}/p' "$SECRETS_SH"
        cat <<'STUB'
YQ=yq
_audit_status_body(){ printf '%s\n%s' "$STUB_CODE" "$STUB_BODY"; }
_audit_code(){ echo "$STUB_CODE"; }
verdict(){ _probe_value "$1" git.example.org FAKE | cut -f1; }
note_of(){ _probe_value "$1" git.example.org FAKE | cut -f3; }
STUB
    } > "$HARNESS"

    GOOD_BODY='{"id":8,"username":"project_11_bot_abc","is_admin":false}'
}

probe() { STUB_CODE="$1" STUB_BODY="${2:-}" bash -c "source '$HARNESS'; verdict gitlab"; }
probe_note() { STUB_CODE="$1" STUB_BODY="${2:-}" bash -c "source '$HARNESS'; note_of gitlab"; }

# --------------------------------------------------------------------------
# The regression: transient failures must not be reported as revocation.
# --------------------------------------------------------------------------

@test "HTTP 429 (rate-limited) is UNKNOWN, not DEAD" {
    run probe 429 '{"message":"429 Too Many Requests"}'
    [ "$output" = "UNKNOWN" ]
}

@test "HTTP 000 (no answer at all) is UNKNOWN, not DEAD" {
    run probe 000 ''
    [ "$output" = "UNKNOWN" ]
    run probe_note 000 ''
    [[ "$output" == *"no verdict (HTTP 000)"* ]]
}

@test "HTTP 5xx is UNKNOWN, not DEAD" {
    run probe 502 '<html>bad gateway</html>'
    [ "$output" = "UNKNOWN" ]
    run probe 500 ''
    [ "$output" = "UNKNOWN" ]
}

# /personal_access_tokens/self is a PERSONAL-token endpoint; a PROJECT access
# token 404s there. That says nothing about whether the token works.
@test "HTTP 404 is UNKNOWN, not DEAD" {
    run probe 404 '{"message":"404 Not Found"}'
    [ "$output" = "UNKNOWN" ]
}

# --------------------------------------------------------------------------
# ...but a real rejection must still be DEAD. A gate that never says DEAD is
# as useless as one that always does.
# --------------------------------------------------------------------------

@test "HTTP 401 (provider actively rejected the token) IS DEAD" {
    run probe 401 '{"message":"401 Unauthorized"}'
    [ "$output" = "DEAD" ]
}

@test "HTTP 403 IS DEAD" {
    run probe 403 '{"message":"403 Forbidden"}'
    [ "$output" = "DEAD" ]
}

@test "a healthy token still reads OK (the shape the live token returns)" {
    run probe 200 "$GOOD_BODY"
    [ "$output" = "OK" ]
}

# 200 with a body we cannot parse is still not evidence of revocation.
@test "HTTP 200 with an unparseable body is UNKNOWN, not DEAD and not OK" {
    run probe 200 'not json at all'
    [ "$output" = "UNKNOWN" ]
}

# --------------------------------------------------------------------------
# The encoding trap that this fix itself fell into first time round.
# --------------------------------------------------------------------------
# The first cut packed "<code>\t<body>" into one string and folded the body's
# newlines with `tr '\n' '\x01'`. In single quotes that is the literal string
# \x01, and GNU tr has no \xNN escape, so it translated the SET {\,x,0,1} to
# newline — every 0, 1 and x in the JSON became a line break and a HEALTHY
# token probed as "unparseable body". The body must survive verbatim.
@test "a body full of 0s, 1s and xs survives the probe intact" {
    run probe 200 '{"id":1010,"username":"x0x1x0","is_admin":false}'
    [ "$output" = "OK" ]
}

@test "_audit_status_body puts the code first and leaves the body verbatim" {
    run bash -c "
        source /dev/stdin <<<\"\$(sed -n '/^_audit_status_body(){/,/^}/p' '$SECRETS_SH')\"
        curl(){ printf '%s\n200' '{\"a\":\"x0x1\",\"b\":10}'; }
        out=\"\$(_audit_status_body http://x H v)\"
        printf '%s|%s' \"\${out%%\$'\n'*}\" \"\${out#*\$'\n'}\"
    "
    [ "$output" = '200|{"a":"x0x1","b":10}' ]
}

# A multi-line body must survive: "everything after the first newline" is the
# whole point of putting the status first.
@test "_audit_status_body preserves a body that itself contains newlines" {
    run bash -c "
        source /dev/stdin <<<\"\$(sed -n '/^_audit_status_body(){/,/^}/p' '$SECRETS_SH')\"
        curl(){ printf 'line1\nline2\nline3\n200'; }
        out=\"\$(_audit_status_body http://x H v)\"
        printf '%s|%s' \"\${out%%\$'\n'*}\" \"\$(printf '%s' \"\${out#*\$'\n'}\" | tr '\n' ',')\"
    "
    [ "$output" = '200|line1,line2,line3' ]
}

@test "the verdict mapping is total — every status yields exactly one verdict" {
    for code in 200 201 301 400 401 403 404 429 500 502 503 000; do
        v="$(bash -c "source '$HARNESS'; _audit_verdict $code")"
        [[ "$v" == "OK" || "$v" == "DEAD" || "$v" == "UNKNOWN" ]] || {
            echo "status $code produced '$v'"; return 1; }
    done
}

@test "secrets.sh is syntactically valid" {
    run bash -n "$SECRETS_SH"
    [ "$status" -eq 0 ]
}
