#!/usr/bin/env bats
#
# tests/unit/test-dns-list.bats — `pl dns list`, the DNS enumerator.
#
# THE DEFECT THIS GUARDS
# ----------------------
# There was no way to enumerate DNS in this estate. DNS was a side effect of
# `pl live` and of hand-run NS-delegation primitives, and nothing ever asked the
# provider what the zone contained. "~50 junk DNS records" therefore survived
# TWO handovers unactioned, and the worse half was never even counted: 22 lame
# NS delegations, one of which was silently NXDOMAIN-ing an A record that read
# as perfectly healthy everywhere else.
#
# Two properties are under test, and every assertion below comes in a PAIR — a
# positive case that must go red and a negative control that must go green — so
# that a guard which is simply always-red cannot pass this file:
#
#   1. CLASSIFICATION HONESTY. A shadowed record and a mispointed declaration
#      are found; blindness (no token, no answer, an error status, an empty or
#      partial read) is rc=3 and NEVER rc=0; and UNDECLARED on its own is NOT a
#      failure and never produces a removal instruction. Undeclared must never
#      come to mean prunable — that mistake, made by `pl server prune`'s first
#      cut, proposed deleting two live databases and a serving site's cert.
#
#   2. THE TOKEN NEVER REACHES ARGV. `ps -ef` on a shared box shows every
#      argument of every running process. The credential must travel only
#      inside a 0600 curl config, as lib/gitlab-issues.sh already does it.
#
# Everything runs offline: curl is shadowed by a stub on PATH, and the
# declaration side is a fixture NWP_DIR, so nothing here depends on the
# operator's nwp.yml, sites/ tree or real .secrets.yml.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DNS="${REPO_ROOT}/scripts/commands/dns.sh"
  TMP="${BATS_TEST_TMPDIR}"

  export STUBBIN="${TMP}/bin"; mkdir -p "$STUBBIN"
  export ARGV_LOG="${TMP}/curl-argv.log"
  export CFG_COPY="${TMP}/curl-cfg.copy"
  export CFG_MODE="${TMP}/curl-cfg.mode"
  export FAKE_CODE=200
  export FAKE_TRANSPORT_FAIL=0
  : > "$ARGV_LOG"

  # ── The curl stub ────────────────────────────────────────────────────────
  # It records its OWN argv (that is the thing under test), copies the -K
  # config and its permission bits, then answers from the fixtures.
  cat > "${STUBBIN}/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
cfg=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[$i]}" = "-K" ] && cfg="${args[$((i+1))]}"
done
if [ -n "$cfg" ] && [ -f "$cfg" ]; then
  cp "$cfg" "$CFG_COPY"
  stat -c '%a' "$cfg" > "$CFG_MODE"
fi
if [ "${FAKE_TRANSPORT_FAIL:-0}" = "1" ]; then exit 7; fi
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg" | head -1)
case "$url" in
  */v4/domains\?*|*/v4/domains)  body=$(cat "$FIXTURE_DOMAINS") ;;
  */records*)                    body=$(cat "$FIXTURE_RECORDS") ;;
  *)                             body='{"errors":[{"reason":"unexpected url"}]}' ;;
esac
printf '%s' "$body"
if grep -q '^write-out' "$cfg"; then printf '\nNWPHTTP:%s' "${FAKE_CODE:-200}"; fi
exit 0
STUB
  chmod +x "${STUBBIN}/curl"

  # ── The fixture inventory (NWP_DIR) ──────────────────────────────────────
  export FIX="${TMP}/fixture"
  mkdir -p "$FIX/sites/alpha" "$FIX/sites/ghost" "$FIX/servers/box"
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
  # A site declared to `box` with a STALE cached server_ip — the shape the box
  # split left behind. The symbolic reference must win, or three correctly
  # pointed live sites read as mispointed.
  cat > "$FIX/sites/ghost/.nwp.yml" <<'EOF'
live:
  server: box
  server_ip: 198.51.100.9
  domain: ghost.example.org
EOF
  cat > "$FIX/servers/box/.nwp-server.yml" <<'EOF'
schema_version: 1
server:
  name: box
  ip: 203.0.113.10
  domain: example.org
EOF

  # A secrets file holding a recognisable token value.
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
  export FIXTURE_RECORDS="${TMP}/records.json"
  _records_clean
}

# ---------------------------------------------------------------------------
# Fixture zones. `_records_clean` is the negative control for every finding:
# same shape, nothing wrong with it.
# ---------------------------------------------------------------------------
_records_clean() {
  cat > "$FIXTURE_RECORDS" <<'EOF'
{"data":[
 {"id":1,"type":"A","name":"alpha","target":"203.0.113.10","ttl_sec":300},
 {"id":2,"type":"A","name":"ghost","target":"203.0.113.10","ttl_sec":300},
 {"id":3,"type":"A","name":"bats-test-junk","target":"203.0.113.10","ttl_sec":300},
 {"id":4,"type":"MX","name":"","target":"mail.example.org","ttl_sec":300}
],"page":1,"pages":1,"results":4}
EOF
}

# alpha's A record with an NS delegation sitting on the same name: the
# delegation answers first and the A record is unreachable.
_records_shadowed() {
  cat > "$FIXTURE_RECORDS" <<'EOF'
{"data":[
 {"id":1,"type":"A","name":"alpha","target":"203.0.113.10","ttl_sec":300},
 {"id":2,"type":"A","name":"ghost","target":"203.0.113.10","ttl_sec":300},
 {"id":5,"type":"NS","name":"alpha","target":"ns1.linode.com","ttl_sec":300},
 {"id":4,"type":"MX","name":"","target":"mail.example.org","ttl_sec":300}
],"page":1,"pages":1,"results":4}
EOF
}

# alpha declared to `box` (203.0.113.10) but pointing at the other box.
_records_mispointed() {
  cat > "$FIXTURE_RECORDS" <<'EOF'
{"data":[
 {"id":1,"type":"A","name":"alpha","target":"198.51.100.9","ttl_sec":300},
 {"id":2,"type":"A","name":"ghost","target":"203.0.113.10","ttl_sec":300},
 {"id":4,"type":"MX","name":"","target":"mail.example.org","ttl_sec":300}
],"page":1,"pages":1,"results":3}
EOF
}

_run_dns() {
  PATH="${STUBBIN}:${PATH}" NWP_DIR="$FIX" run "$DNS" "$@"
}

# ===========================================================================
# 1. The token never reaches argv
# ===========================================================================

@test "1a the API token never appears in curl's argv" {
  _run_dns list example.org
  [ "$status" -eq 0 ]
  # The stub logged every argument of every call it received.
  run grep -c "$TOKEN_VALUE" "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "1b the token IS sent — inside the curl config, not by being omitted" {
  _run_dns list example.org
  # Negative control for 1a: a command that simply never authenticated would
  # also pass 1a. The credential must actually be in the config.
  grep -q "Authorization: Bearer ${TOKEN_VALUE}" "$CFG_COPY"
}

@test "1c the curl config carrying the token is mode 0600" {
  _run_dns list example.org
  [ "$(cat "$CFG_MODE")" = "600" ]
}

@test "1d the token is never printed in the command's own output" {
  _run_dns list example.org
  [[ "$output" != *"$TOKEN_VALUE"* ]]
}

# ===========================================================================
# 2. Classification
# ===========================================================================

@test "2a a declared site's record is DECLARED and names its declaration" {
  _run_dns list example.org
  [[ "$output" =~ alpha[[:space:]]+A[[:space:]]+203\.0\.113\.10.*DECLARED ]]
  [[ "$output" == *"sites/alpha/.nwp.yml"* ]]
}

@test "2b a record nothing declares is UNDECLARED" {
  _run_dns list example.org
  [[ "$output" =~ bats-test-junk[[:space:]]+A[[:space:]]+.*UNDECLARED ]]
}

@test "2c UNDECLARED alone is NOT a failure — it is a question, not a delete list" {
  _run_dns list example.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT A DELETE LIST"* ]]
}

@test "2d the verb never emits a removal instruction" {
  # A read-only enumerator that starts suggesting deletions is how an audit
  # becomes an incident. Nothing in the output may look like a command to run.
  _run_dns list example.org
  [[ "$output" != *"linode_delete"* ]]
  [[ "$output" != *"--delete"* ]]
  [[ "$output" != *"-X DELETE"* ]]
  [[ "$output" != *"api.linode.com"* ]]
  # ...while the warning that the column is NOT a delete list must still be there.
  [[ "$output" == *"NOT A DELETE LIST"* ]]
}

@test "2e an empty record name renders as the apex with its target intact" {
  # Regression guard: `IFS=\$'\t' read` collapses consecutive tabs, so an empty
  # name silently shifts every later column left and the apex MX reads as a
  # host called "mail.example.org" pointing at "300".
  _run_dns list example.org
  [[ "$output" =~ @[[:space:]]+MX[[:space:]]+mail\.example\.org ]]
}

@test "2f a stale cached server_ip does not manufacture a MISPOINTED" {
  # ghost declares `server: box` (203.0.113.10) AND a stale
  # `server_ip: 198.51.100.9`. The symbolic reference is authoritative.
  _run_dns list example.org
  [[ "$output" != *"MISPOINTED"* ]]
  [ "$status" -eq 0 ]
}

# ===========================================================================
# 3. The two red findings — each with its negative control
# ===========================================================================

@test "3a an NS record shadowing an A record on the same name is found, rc=1" {
  _records_shadowed
  _run_dns list example.org
  [ "$status" -eq 1 ]
  [[ "$output" == *"SHADOWED-BY-NS"* ]]
  [[ "$output" == *"alpha.example.org"* ]]
}

@test "3b control: the same zone without the delegation is clean, rc=0" {
  _records_clean
  _run_dns list example.org
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHADOWED-BY-NS"* ]]
}

@test "3c a declared site pointing at the wrong server is MISPOINTED, rc=1" {
  _records_mispointed
  _run_dns list example.org
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISPOINTED"* ]]
  [[ "$output" == *"203.0.113.10"* ]]
}

@test "3d control: the same zone pointed correctly is clean, rc=0" {
  _records_clean
  _run_dns list example.org
  [ "$status" -eq 0 ]
  [[ "$output" != *"MISPOINTED"* ]]
}

@test "3e a declared site with no record at all is a WARN, not a failure" {
  cat > "$FIX/sites/absent/.nwp.yml" 2>/dev/null || mkdir -p "$FIX/sites/absent"
  cat > "$FIX/sites/absent/.nwp.yml" <<'EOF'
live:
  server: box
  domain: absent.example.org
EOF
  _run_dns list example.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"MISSING-RECORD"* ]]
  [[ "$output" == *"absent.example.org"* ]]
}

# ===========================================================================
# 4. Blindness is rc=3 — never rc=0
# ===========================================================================

@test "4a no token is CANNOT-VERIFY, not an empty zone" {
  export NWP_SECRETS_FILE="${TMP}/secrets/empty/.secrets.yml"
  mkdir -p "$(dirname "$NWP_SECRETS_FILE")"; printf 'linode: {}\n' > "$NWP_SECRETS_FILE"
  LINODE_API_TOKEN="" _run_dns list example.org
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "4b an HTTP error status is CANNOT-VERIFY" {
  FAKE_CODE=401 _run_dns list example.org
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "4c a dead transport is CANNOT-VERIFY, never a clean zone" {
  FAKE_TRANSPORT_FAIL=1 _run_dns list example.org
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "4d a zone that returns ZERO records is CANNOT-VERIFY, not 'nothing undeclared'" {
  printf '{"data":[],"page":1,"pages":1,"results":0}\n' > "$FIXTURE_RECORDS"
  _run_dns list example.org
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "4e a PARTIAL (multi-page) read is CANNOT-VERIFY, not a graded zone" {
  cat > "$FIXTURE_RECORDS" <<'EOF'
{"data":[{"id":1,"type":"A","name":"alpha","target":"203.0.113.10","ttl_sec":300}],
 "page":1,"pages":4,"results":900}
EOF
  _run_dns list example.org
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "4f a count mismatch between 'results' and the parsed rows is CANNOT-VERIFY" {
  cat > "$FIXTURE_RECORDS" <<'EOF'
{"data":[{"id":1,"type":"A","name":"alpha","target":"203.0.113.10","ttl_sec":300}],
 "page":1,"pages":1,"results":7}
EOF
  _run_dns list example.org
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "4g a zone the token cannot see is CANNOT-VERIFY, not 'not there'" {
  _run_dns list rosaryforge.org
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"not visible"* ]]
}

@test "4h control: the healthy path really does reach rc=0" {
  # Without this, every rc=3 assertion above would pass on a command that is
  # simply always broken.
  _run_dns list example.org
  [ "$status" -eq 0 ]
  [[ "$output" != *"CANNOT-VERIFY"* ]]
}

# ===========================================================================
# 5. --json
# ===========================================================================

@test "5a --json emits parseable JSON with the same classification" {
  _run_dns list example.org --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "${TMP}/out.json"
  run python3 -c "
import json,sys
d=json.load(open('${TMP}/out.json'))
z=d['zones'][0]
assert z['domain']=='example.org', z['domain']
assert z['total']==4, z['total']
byname={r['name']:r for r in z['records']}
assert byname['alpha']['status']=='DECLARED', byname['alpha']
assert byname['bats-test-junk']['status']=='UNDECLARED', byname['bats-test-junk']
assert byname['@']['target']=='mail.example.org', byname['@']
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "5b --json survives a target containing quotes and backslashes" {
  cat > "$FIXTURE_RECORDS" <<'EOF'
{"data":[
 {"id":1,"type":"A","name":"alpha","target":"203.0.113.10","ttl_sec":300},
 {"id":9,"type":"TXT","name":"weird","target":"a \"quoted\" \\ value","ttl_sec":300}
],"page":1,"pages":1,"results":2}
EOF
  _run_dns list example.org --json
  printf '%s' "$output" > "${TMP}/out2.json"
  run python3 -c "import json;json.load(open('${TMP}/out2.json'));print('ok')"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# 6. Usage
# ===========================================================================

@test "6a an unknown subcommand is a usage error (rc=2), not a silent success" {
  _run_dns frobnicate
  [ "$status" -eq 2 ]
}

@test "6b an unknown option is a usage error (rc=2)" {
  _run_dns list --wat
  [ "$status" -eq 2 ]
}

@test "6c help mentions that the command is read-only" {
  _run_dns help
  [ "$status" -eq 0 ]
  [[ "$output" == *"READ-ONLY"* ]]
}
