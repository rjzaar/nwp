#!/usr/bin/env bats
#
# tests/unit/test-served-roots-infra.bats — INFRASTRUCTURE roots (nwp/ops#149).
#
# WHY THIS EXISTS
# ---------------
# `pl server roots nwpcode` reported /var/www/hs/html as UNDECLARED-ROOT. It is
# an EMPTY certbot webroot in front of a vhost that reverse-proxies to the
# Headscale controller on 127.0.0.1:8085 — the mesh controller for the whole
# fleet (dev, mini, met, gitlab all online through it). It is load-bearing, and
# it is NOT a site: there is no sites/hs/.nwp.yml to write and writing one would
# be a lie.
#
# The tempting fix was an `ignore:` list of known-good paths in
# lib/served-roots.sh. That is the ops#149 failure mode reintroduced verbatim: a
# hand-maintained list, in code, that goes green by omission and that nothing
# re-checks against the box. So the root is DECLARED instead, in the server
# inventory every other `pl server` verb already reads:
#
#     infrastructure_roots:
#       - path: /var/www/hs/html
#         service: headscale
#
# Every test below defends the difference between a declaration and a mute:
# the green must be bought by the declaration (negative control), an entry must
# NAME AN OWNER, matching is exact so a declaration cannot swallow a subtree,
# and an unreadable config declares nothing rather than everything.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export REPO_ROOT
  PL="${REPO_ROOT}/pl"
  export PL
  TMP="${BATS_TEST_TMPDIR}"
  export STUBBIN="${TMP}/stubbin"
  mkdir -p "$STUBBIN"
}

# `pl server roots --probe-cmd=<cmd>` runs `<cmd> <script>`; the stub ignores
# the script and prints a canned capture, so the real parser and the real
# reconciler run while nothing touches a box.
_stub_probe() {
  local payload="$1" rc="${2:-0}"
  cat > "${STUBBIN}/fakeprobe" <<EOF
#!/usr/bin/env bash
cat "${payload}"
exit ${rc}
EOF
  chmod +x "${STUBBIN}/fakeprobe"
  PROBE="${STUBBIN}/fakeprobe"
  export PROBE
}

# Two ordinary declared+gated sites, plus a third vhost serving an ACME/proxy
# webroot rather than a site docroot.
_capture_infra() {
  cat > "${TMP}/cap-infra" <<'EOF'
NWPROOTS v1
master=yes
config=/etc/nginx/nginx.conf
readmode=plain
file=/etc/nginx/conf.d/alpha.conf
L server {
L server_name alpha.example.org;
L root /var/www/alpha/web;
L }
file=/etc/nginx/conf.d/beta.conf
L server {
L server_name beta.example.org;
L root /var/www/beta;
L }
file=/etc/nginx/conf.d/mesh.conf
L server {
L server_name mesh.example.org;
L root /var/www/mesh/html;
L proxy_pass http://127.0.0.1:8085;
L }
dirlist=/var/www
D alpha
D beta
D mesh
EOF
  printf '%s\n' "${TMP}/cap-infra"
}

# A fixture NWP_DIR in which alpha and beta are declared AND gated, so anything
# red in these tests is red because of the third root and nothing else.
_fixture_decl() {
  local fix="${TMP}/decl"
  rm -rf "$fix"
  mkdir -p "$fix/servers/testbox" "$fix/sites/alpha" "$fix/sites/beta"

  cat > "$fix/servers/testbox/.nwp-server.yml" <<'EOF'
schema_version: 1
server:
  ip: 203.0.113.7
  ssh_user: tester
  ssh_key: ~/.ssh/nonexistent
  domain: example.org
EOF

  cat > "$fix/nwp.yml" <<'EOF'
sites:
  alpha:
    live:
      enabled: true
      server: testbox
      domain: alpha.example.org
      remote_path: /var/www/alpha
  beta:
    live:
      enabled: true
      server: testbox
      domain: beta.example.org
      remote_path: /var/www/beta
EOF

  cat > "$fix/sites/alpha/.nwp.yml" <<'EOF'
schema_version: 2
live:
  enabled: true
  server: testbox
  domain: alpha.example.org
  remote_path: /var/www/alpha
EOF

  cat > "$fix/sites/beta/.nwp.yml" <<'EOF'
schema_version: 2
live:
  enabled: true
  server: testbox
  domain: beta.example.org
  remote_path: /var/www/beta
EOF

  export NWP_DIR="$fix"
}

# $1 = good | no-service | parent-path | unparseable
_fixture_infra() {
  local mode="${1:-good}"
  local cfg="${NWP_DIR}/servers/testbox/.nwp-server.yml"
  case "$mode" in
    good)
      cat >> "$cfg" <<'EOF'
infrastructure_roots:
  - path: /var/www/mesh/html
    service: headscale
    domain: mesh.example.org
EOF
      ;;
    no-service)
      cat >> "$cfg" <<'EOF'
infrastructure_roots:
  - path: /var/www/mesh/html
EOF
      ;;
    parent-path)
      cat >> "$cfg" <<'EOF'
infrastructure_roots:
  - path: /var/www/mesh
    service: headscale
EOF
      ;;
    unparseable)
      printf 'infrastructure_roots: [ {path: /var/www/mesh/html, service: headscale\n' >> "$cfg"
      ;;
  esac
}

################################################################################
# The feature
################################################################################

@test "INFRA-ROOT: a server-declared infrastructure root is not UNDECLARED" {
  _fixture_decl
  _fixture_infra good
  _stub_probe "$(_capture_infra)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNDECLARED-ROOT"* ]]
}

@test "INFRA-ROOT is REPORTED with the service that owns it — never silent" {
  _fixture_decl
  _fixture_infra good
  _stub_probe "$(_capture_infra)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [[ "$output" == *"INFRA-ROOT"* ]]
  [[ "$output" == *"/var/www/mesh/html"* ]]
  [[ "$output" == *"headscale"* ]]
  # Legible as "not a site", or a reader goes looking for its missing gate.
  [[ "$output" == *"not a site"* ]]
}

@test "the infrastructure count is shown beside the declaration count" {
  _fixture_decl
  _fixture_infra good
  _stub_probe "$(_capture_infra)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [[ "$output" == *"infrastructure"* ]]
}

################################################################################
# The guards that keep it a declaration rather than a mute
################################################################################

@test "NEGATIVE CONTROL: the same served root WITHOUT the declaration is red" {
  # Proves the green above is bought by the DECLARATION — not by the path
  # looking infrastructural, and not by the reconciler having gone soft.
  _fixture_decl
  _stub_probe "$(_capture_infra)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNDECLARED-ROOT"* ]]
  [[ "$output" == *"/var/www/mesh/html"* ]]
}

@test "an entry with no service: is ignored — silencing a root requires an owner" {
  # Otherwise the block degenerates into the ignore-list this design refuses:
  # a column of paths nobody ever had to justify.
  _fixture_decl
  _fixture_infra no-service
  _stub_probe "$(_capture_infra)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNDECLARED-ROOT"* ]]
}

@test "infrastructure matching is EXACT — a declared parent covers no child" {
  # Site declarations cover subtrees because a docroot legitimately sits under a
  # site root. An ACME stub owns no subtree, and letting one silence a branch of
  # /var/www is how a real docroot would vanish from the gate.
  _fixture_decl
  _fixture_infra parent-path
  _stub_probe "$(_capture_infra)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNDECLARED-ROOT"* ]]
  [[ "$output" == *"/var/www/mesh/html"* ]]
}

@test "FAIL CLOSED: an unparseable server config declares no infrastructure" {
  # Design rule 1 — blindness never becomes coverage.
  _fixture_decl
  _fixture_infra unparseable
  _stub_probe "$(_capture_infra)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNDECLARED-ROOT"* || "$output" == *"CANNOT-VERIFY"* ]]
}

################################################################################
# NWP_DIR must steer the SSH ROUTE as well as the declarations
################################################################################

@test "NWP_DIR selects the servers/ directory used to resolve the ssh route" {
  # `pl server roots` read site declarations from ${NWP_DIR:-PROJECT_ROOT} but
  # resolved the destination from PROJECT_ROOT/servers alone, so running a
  # worktree's code against the operator's inventory found every declaration and
  # then failed with ssh rc=255 — CANNOT-VERIFY for a reason of our own making.
  run bash -c "PROJECT_ROOT=/tmp/nwp-pr-xyz NWP_DIR=/tmp/nwp-nd-xyz \
      source '${REPO_ROOT}/lib/host-capture.sh'; printf '%s\n' \"\$HOST_SERVERS_DIR\""
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "/tmp/nwp-nd-xyz/servers" ]
}

@test "NEGATIVE CONTROL: with NWP_DIR unset the route still comes from PROJECT_ROOT" {
  run bash -c "unset NWP_DIR; PROJECT_ROOT=/tmp/nwp-pr-xyz \
      source '${REPO_ROOT}/lib/host-capture.sh'; printf '%s\n' \"\$HOST_SERVERS_DIR\""
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "/tmp/nwp-pr-xyz/servers" ]
}

@test "an explicit NWP_SERVERS_DIR still wins over both" {
  run bash -c "PROJECT_ROOT=/tmp/nwp-pr-xyz NWP_DIR=/tmp/nwp-nd-xyz \
      NWP_SERVERS_DIR=/tmp/nwp-explicit \
      source '${REPO_ROOT}/lib/host-capture.sh'; printf '%s\n' \"\$HOST_SERVERS_DIR\""
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "/tmp/nwp-explicit" ]
}

@test "no hardcoded path allowlist crept into the reconciler" {
  # The whole point: the only way to make a root green is to DECLARE it. A
  # literal /var/www/… path in the coverage logic would be the hand-maintained
  # list, in code.
  run grep -nE '^[^#]*(hs/html|/var/www/(hs|sso|rosaryforge|avctest|cccrdf))' \
      "${REPO_ROOT}/lib/served-roots.sh" "${REPO_ROOT}/scripts/commands/server.sh"
  [ "$status" -ne 0 ]
}
