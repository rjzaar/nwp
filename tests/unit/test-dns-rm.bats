#!/usr/bin/env bats
#
# tests/unit/test-dns-rm.bats — `pl dns rm`, the guarded DNS removal path.
#
# THE DEFECT THIS GUARDS
# ----------------------
# `pl dns list` (test-dns-list.bats) is deliberately read-only, so the only way
# to remove a proven-dead record was hand-rolled curl against the provider API —
# the exact idiom the standing order forbids. 54 fixture records therefore
# outlived two handovers and a full written audit. `rm` is the apply path, and
# THESE tests are about the ways it must refuse to apply:
#
#   1. DRY-RUN IS THE DEFAULT. Without --execute, no DELETE ever leaves the
#      process — and the dry run still prints the verbatim recreation rows.
#   2. ALL-OR-NOTHING. One refused ID (declared record, NS delegation, zone
#      policy, unknown ID) aborts the ENTIRE set before any DELETE is sent.
#      A partially applied delete list is drift with a receipt.
#   3. THE LEDGER ROW PRECEDES THE DELETE. A deletion that cannot be recreated
#      verbatim is not allowed to happen.
#   4. THE TOKEN NEVER REACHES ARGV (the property test-dns-list.bats 1a-1d
#      guards, re-asserted on the write path where it matters more).
#
# As in test-dns-list.bats, every positive assertion has a negative control so
# an always-refusing implementation cannot pass.
#
# Everything runs offline: curl is shadowed by a stub on PATH that records the
# HTTP method of every request, and the declaration side is a fixture NWP_DIR.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DNS="${REPO_ROOT}/scripts/commands/dns.sh"
  TMP="${BATS_TEST_TMPDIR}"

  export STUBBIN="${TMP}/bin"; mkdir -p "$STUBBIN"
  export ARGV_LOG="${TMP}/curl-argv.log"
  export METHOD_LOG="${TMP}/curl-methods.log"
  export CFG_COPY="${TMP}/curl-cfg.copy"
  export FAKE_DELETE_CODE=200
  : > "$ARGV_LOG"
  : > "$METHOD_LOG"

  # ── The curl stub ────────────────────────────────────────────────────────
  # Records its own argv and, for every request, "<METHOD> <url>" — the DELETE
  # log is what dry-run and all-or-nothing are proven against.
  cat > "${STUBBIN}/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
cfg=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[$i]}" = "-K" ] && cfg="${args[$((i+1))]}"
done
[ -n "$cfg" ] && [ -f "$cfg" ] && cp "$cfg" "$CFG_COPY"
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg" | head -1)
method=$(sed -n 's/^request = "\(.*\)"$/\1/p' "$cfg" | head -1)
printf '%s %s\n' "${method:-GET}" "$url" >> "$METHOD_LOG"
if [ "${method:-GET}" = "DELETE" ]; then
  body='{}'
  code="${FAKE_DELETE_CODE:-200}"
else
  case "$url" in
    */v4/domains\?*|*/v4/domains)  body=$(cat "$FIXTURE_DOMAINS") ;;
    */records*)                    body=$(cat "$FIXTURE_RECORDS") ;;
    *)                             body='{"errors":[{"reason":"unexpected url"}]}' ;;
  esac
  code=200
fi
printf '%s' "$body"
if grep -q '^write-out' "$cfg"; then printf '\nNWPHTTP:%s' "$code"; fi
exit 0
STUB
  chmod +x "${STUBBIN}/curl"

  # ── The fixture inventory (NWP_DIR) ──────────────────────────────────────
  export FIX="${TMP}/fixture"
  mkdir -p "$FIX/sites/alpha" "$FIX/servers/box"
  cat > "$FIX/nwp.yml" <<'EOF'
sites:
  alpha:
    live:
      enabled: true
      domain: alpha.example.org
      server: box
EOF
  cat > "$FIX/sites/alpha/.nwp.yml" <<'EOF'
live:
  server: box
  domain: alpha.example.org
EOF
  cat > "$FIX/servers/box/.nwp-server.yml" <<'EOF'
schema_version: 1
server:
  name: box
  ip: 203.0.113.10
  domain: example.org
EOF

  export TOKEN_VALUE="fixture-token-not-a-real-credential"
  export NWP_SECRETS_FILE="${TMP}/secrets/.secrets.yml"
  mkdir -p "${TMP}/secrets"
  cat > "$NWP_SECRETS_FILE" <<EOF
linode:
  api_token: ${TOKEN_VALUE}
EOF

  export FIXTURE_DOMAINS="${TMP}/domains.json"
  cat > "$FIXTURE_DOMAINS" <<'EOF'
{"data":[{"id":4242,"domain":"example.org"}],"page":1,"pages":1,"results":1}
EOF

  # The zone: one declared A (1), two dead fixtures (3, 6), one NS delegation
  # (5), one MX (4). Only 3 and 6 are legitimately removable.
  export FIXTURE_RECORDS="${TMP}/records.json"
  cat > "$FIXTURE_RECORDS" <<'EOF'
{"data":[
 {"id":1,"type":"A","name":"alpha","target":"203.0.113.10","ttl_sec":300},
 {"id":3,"type":"A","name":"bats-test-junk","target":"203.0.113.10","ttl_sec":300},
 {"id":6,"type":"A","name":"verify-junk","target":"203.0.113.10","ttl_sec":600},
 {"id":5,"type":"NS","name":"coder","target":"ns1.linode.com","ttl_sec":300},
 {"id":4,"type":"MX","name":"","target":"mail.example.org","ttl_sec":300}
],"page":1,"pages":1,"results":5}
EOF
}

_run_dns() {
  PATH="${STUBBIN}:${PATH}" NWP_DIR="$FIX" run "$DNS" "$@"
}

_deletes_sent() { grep -c '^DELETE ' "$METHOD_LOG" || true; }

# ===========================================================================
# 1. Dry-run is the default
# ===========================================================================

@test "1a without --execute no DELETE request is ever sent" {
  _run_dns rm example.org 3 6
  [ "$status" -eq 0 ]
  [ "$(_deletes_sent)" = "0" ]
  [[ "$output" == *"DRY RUN"* ]]
}

@test "1b the dry run prints the verbatim recreation row for every record" {
  _run_dns rm example.org 3 6
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats-test-junk"* ]]
  [[ "$output" == *"verify-junk"* ]]
  [[ "$output" == *"203.0.113.10"* ]]
  [[ "$output" == *"600"* ]]   # the TTL, not a default
}

@test "1c negative control: --execute --yes DOES send the DELETEs" {
  _run_dns rm example.org 3 6 --execute --yes
  [ "$status" -eq 0 ]
  [ "$(_deletes_sent)" = "2" ]
  grep -q 'DELETE .*/v4/domains/4242/records/3' "$METHOD_LOG"
  grep -q 'DELETE .*/v4/domains/4242/records/6' "$METHOD_LOG"
}

# ===========================================================================
# 2. All-or-nothing refusals
# ===========================================================================

@test "2a a DECLARED record is refused and NOTHING in the set is deleted" {
  _run_dns rm example.org 1 3 --execute --yes
  [ "$status" -eq 1 ]
  [ "$(_deletes_sent)" = "0" ]
  [[ "$output" == *"DECLARED"* ]]
  [[ "$output" == *"NOTHING was deleted"* ]]
}

@test "2b an NS delegation is refused — offboarding is not pruning" {
  _run_dns rm example.org 5 3 --execute --yes
  [ "$status" -eq 1 ]
  [ "$(_deletes_sent)" = "0" ]
  [[ "$output" == *"offboarding"* ]]
}

@test "2c zone policy (MX) is refused" {
  _run_dns rm example.org 4 --execute --yes
  [ "$status" -eq 1 ]
  [ "$(_deletes_sent)" = "0" ]
  [[ "$output" == *"zone policy"* ]]
}

@test "2d an ID not in the zone is refused, not skipped" {
  _run_dns rm example.org 999 3 --execute --yes
  [ "$status" -eq 1 ]
  [ "$(_deletes_sent)" = "0" ]
  [[ "$output" == *"not in zone"* ]]
}

@test "2e a record named by NAME instead of ID is a usage error" {
  _run_dns rm example.org bats-test-junk
  [ "$status" -eq 2 ]
  [ "$(_deletes_sent)" = "0" ]
}

@test "2f a zone the token cannot see is CANNOT-VERIFY (3), not empty (0)" {
  _run_dns rm other.example 3
  [ "$status" -eq 3 ]
  [ "$(_deletes_sent)" = "0" ]
}

# ===========================================================================
# 3. The rollback ledger
# ===========================================================================

@test "3a every deletion appends a verbatim recreation row to the ledger" {
  _run_dns rm example.org 3 6 --execute --yes
  [ "$status" -eq 0 ]
  local ledger="$FIX/private/dns-rollback.log"
  [ -f "$ledger" ]
  grep -qP '\texample.org\t4242\t3\tA\tbats-test-junk\t203.0.113.10\t300$' "$ledger"
  grep -qP '\texample.org\t4242\t6\tA\tverify-junk\t203.0.113.10\t600$' "$ledger"
}

@test "3b the ledger row is written even when the DELETE fails, and rc is 1" {
  FAKE_DELETE_CODE=500 _run_dns rm example.org 3 --execute --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT deleted"* ]] || [[ "$output" == *"failed"* ]]
  grep -qP '\t3\tA\tbats-test-junk\t' "$FIX/private/dns-rollback.log"
}

@test "3c a dry run writes NO ledger row" {
  _run_dns rm example.org 3
  [ "$status" -eq 0 ]
  [ ! -f "$FIX/private/dns-rollback.log" ]
}

# ===========================================================================
# 4. Confirmation and the token
# ===========================================================================

@test "4a --execute without --yes requires the domain typed back" {
  PATH="${STUBBIN}:${PATH}" NWP_DIR="$FIX" run bash -c \
    "printf 'wrong-domain\n' | '$DNS' rm example.org 3 --execute"
  [ "$status" -eq 1 ]
  [ "$(_deletes_sent)" = "0" ]
  [[ "$output" == *"NOTHING was deleted"* ]]
}

@test "4b negative control: the correctly typed domain proceeds" {
  PATH="${STUBBIN}:${PATH}" NWP_DIR="$FIX" run bash -c \
    "printf 'example.org\n' | '$DNS' rm example.org 3 --execute"
  [ "$status" -eq 0 ]
  [ "$(_deletes_sent)" = "1" ]
}

@test "4c the API token never appears in curl's argv on the write path" {
  _run_dns rm example.org 3 --execute --yes
  [ "$status" -eq 0 ]
  run grep -c "$TOKEN_VALUE" "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "4d the token IS sent — inside the curl config, not by being omitted" {
  _run_dns rm example.org 3 --execute --yes
  grep -q "Authorization: Bearer ${TOKEN_VALUE}" "$CFG_COPY"
}

@test "4e the token is never printed in the command's own output" {
  _run_dns rm example.org 3 --execute --yes
  [[ "$output" != *"$TOKEN_VALUE"* ]]
}
