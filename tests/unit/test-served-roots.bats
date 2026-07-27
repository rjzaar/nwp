#!/usr/bin/env bats
#
# tests/unit/test-served-roots.bats — `pl server roots` (nwp/ops#149).
#
# THE DEFECT THIS GUARDS
# ----------------------
# rgs.nwpcode.org ran the pre-ops#90 mod_depthcontent — raw `<details>`
# re-insert, i.e. stored XSS — for ELEVEN DAYS after the fix had reached every
# copy on a HAND-MAINTAINED list. rgs was declared in the global nwp.yml, but
# it had no sites/rgs/.nwp.yml, so every `pl moodle` verb refused it by name:
#
#     $ pl moodle gate-status rgs
#     ERROR: No site config at sites/rgs/.nwp.yml
#
# The site was therefore invisible to every gate *even when named*. Nothing in
# the tool could answer the only question that mattered — "what is this box
# actually serving, and is all of it under a gate?" — because the corpus of
# every check was a list a human maintained by hand.
#
# The property under test is CORPUS HONESTY: an incomplete enumeration must
# never be reportable as a clean one. Every assertion below therefore comes in
# a pair — a positive case that must go red, and a negative control that must
# go green — so that a guard which is simply always-red cannot pass this file.
#
# All remote interaction is stubbed via --probe-cmd, exercising the real parse
# and the real reconciliation path; the declaration side is a fixture NWP_DIR
# tree, so these tests do NOT depend on the operator's nwp.yml (in particular
# they do not depend on sites/rgs/.nwp.yml existing).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export REPO_ROOT
  PL="${REPO_ROOT}/pl"
  export PL
  TMP="${BATS_TEST_TMPDIR}"
  export STUBBIN="${TMP}/stubbin"
  mkdir -p "$STUBBIN"
}

# ---------------------------------------------------------------------------
# A stub probe. `pl server roots --probe-cmd=<cmd>` runs `<cmd> <script>`; the
# stub ignores the script and prints a canned capture, exactly as the health
# and forge probe stubs in test-host.bats do.
# ---------------------------------------------------------------------------
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

# A capture in which every served root is declared and every declaration gated.
_capture_clean() {
  cat > "${TMP}/cap-clean" <<'EOF'
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
dirlist=/var/www
D alpha
D beta
EOF
  printf '%s\n' "${TMP}/cap-clean"
}

# The ops#149 shape: a third vhost serving a root nothing declares.
_capture_undeclared() {
  cat > "${TMP}/cap-undeclared" <<'EOF'
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
file=/etc/nginx/conf.d/ghost.conf
L server {
L server_name ghost.example.org;
L root /var/www/ghost;
L }
dirlist=/var/www
D alpha
D beta
D ghost
EOF
  printf '%s\n' "${TMP}/cap-undeclared"
}

# ---------------------------------------------------------------------------
# Declaration fixtures. $1 = "gated" | "ungated".
#
# "gated"   — both live sites have a global nwp.yml entry AND a per-site
#             sites/<name>/.nwp.yml, so every `pl` gate can see them.
# "ungated" — beta is declared live in nwp.yml but has NO sites/beta/.nwp.yml.
#             THIS IS THE rgs SHAPE.
# ---------------------------------------------------------------------------
_fixture_decl() {
  local mode="${1:-gated}"
  local fix="${TMP}/decl"
  rm -rf "$fix"
  mkdir -p "$fix/servers/testbox" "$fix/sites/alpha"

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

  if [ "$mode" = "gated" ]; then
    mkdir -p "$fix/sites/beta"
    cat > "$fix/sites/beta/.nwp.yml" <<'EOF'
schema_version: 2
live:
  enabled: true
  server: testbox
  domain: beta.example.org
  remote_path: /var/www/beta
EOF
  fi

  export NWP_DIR="$fix"
  printf '%s\n' "$fix"
}

################################################################################
# (0) the verb exists and is discoverable
################################################################################

@test "pl server roots is a real subcommand and is listed in help" {
  run "$PL" server help
  [ "$status" -eq 0 ]
  [[ "$output" == *"roots"* ]]
}

@test "lib/served-roots.sh exists (the reconciler is code, not a runbook)" {
  [ -f "${REPO_ROOT}/lib/served-roots.sh" ]
}

################################################################################
# (1) THE ops#149 CLASS — a served root nothing declares must go RED.
################################################################################

@test "UNDECLARED-ROOT: a served root with no declaration EXITS NON-ZERO" {
  _fixture_decl gated
  _stub_probe "$(_capture_undeclared)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNDECLARED-ROOT"* ]]
  [[ "$output" == *"/var/www/ghost"* ]]
}

@test "UNDECLARED-ROOT names the server_name that reaches it" {
  _fixture_decl gated
  _stub_probe "$(_capture_undeclared)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [[ "$output" == *"ghost.example.org"* ]]
}

################################################################################
# (2) NEGATIVE CONTROL — a fully declared, fully gated fleet must EXIT 0.
#
#     Without this, a guard that is unconditionally red would pass (1).
################################################################################

@test "NEGATIVE CONTROL: fully declared + fully gated fleet EXITS ZERO" {
  _fixture_decl gated
  _stub_probe "$(_capture_clean)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNDECLARED-ROOT"* ]]
  [[ "$output" != *"UNGATED-DECLARATION"* ]]
}

@test "NEGATIVE CONTROL: a declared ANCESTOR covers a served subdirectory root" {
  # avc really is declared as /var/www/avc and really is served from
  # /var/www/avc/html. String equality would emit a false UNDECLARED-ROOT and
  # train the operator to ignore this gate — the way the hand-maintained list
  # got ignored. alpha below is the same shape.
  _fixture_decl gated
  _stub_probe "$(_capture_clean)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"/var/www/alpha/web"*"UNDECLARED"* ]]
}

################################################################################
# (3) THE rgs SHAPE — declared in the inventory, invisible to every gate.
################################################################################

@test "UNGATED-DECLARATION: nwp.yml entry with no sites/<n>/.nwp.yml EXITS NON-ZERO" {
  _fixture_decl ungated
  _stub_probe "$(_capture_clean)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNGATED-DECLARATION"* ]]
  [[ "$output" == *"beta"* ]]
}

@test "UNGATED-DECLARATION says WHICH file is missing, so the fix is obvious" {
  _fixture_decl ungated
  _stub_probe "$(_capture_clean)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [[ "$output" == *"sites/beta/.nwp.yml"* ]]
}

@test "an UNGATED declaration is red EVEN WHEN its root is properly served" {
  # This is precisely why rgs went unnoticed: the site was up, reachable and
  # serving traffic. Being served is not being gated.
  _fixture_decl ungated
  _stub_probe "$(_capture_clean)"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 1 ]
  [[ "$output" != *"UNDECLARED-ROOT"* ]]
}

################################################################################
# (4) BLINDNESS — the single most important property.
#
#     The incident happened because a check's corpus was silently incomplete.
#     Zero roots, a dead transport or an unreadable config must be
#     CANNOT-VERIFY (rc=3), NEVER a clean 0.
################################################################################

@test "BLINDNESS: ssh/transport failure is CANNOT-VERIFY (rc=3), not clean" {
  _fixture_decl gated
  : > "${TMP}/empty"
  _stub_probe "${TMP}/empty" 255
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "BLINDNESS: ZERO served roots is CANNOT-VERIFY, never 'nothing undeclared'" {
  _fixture_decl gated
  cat > "${TMP}/cap-empty" <<'EOF'
NWPROOTS v1
master=yes
config=/etc/nginx/nginx.conf
readmode=plain
EOF
  _stub_probe "${TMP}/cap-empty"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "BLINDNESS: an UNREADABLE vhost file poisons the whole run (rc=3)" {
  # A corpus you could not fully read is a corpus you must not grade. Note the
  # capture below DOES contain a valid, fully declared root: a naive
  # implementation would reconcile the readable part and report success.
  _fixture_decl gated
  cat > "${TMP}/cap-partial" <<'EOF'
NWPROOTS v1
master=yes
config=/etc/nginx/nginx.conf
readmode=plain
file=/etc/nginx/conf.d/alpha.conf
L server {
L server_name alpha.example.org;
L root /var/www/alpha/web;
L }
unreadable=/etc/nginx/conf.d/secret.conf
dirlist=/var/www
D alpha
EOF
  _stub_probe "${TMP}/cap-partial"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"secret.conf"* ]]
}

@test "BLINDNESS: no running nginx master means we cannot know what is served" {
  _fixture_decl gated
  cat > "${TMP}/cap-nomaster" <<'EOF'
NWPROOTS v1
master=no
config=
readmode=plain
EOF
  _stub_probe "${TMP}/cap-nomaster"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "BLINDNESS: a garbage capture without the version banner is CANNOT-VERIFY" {
  _fixture_decl gated
  printf 'bash: nginx: command not found\n' > "${TMP}/cap-garbage"
  _stub_probe "${TMP}/cap-garbage"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 3 ]
}

################################################################################
# (5) RETIREMENT — legitimate, so it must be WARN, not RED. But an unserved
#     tree still on disk carrying vulnerable code earns its own WARN line.
################################################################################

@test "UNREACHABLE-DECLARATION warns but does NOT redden a clean fleet" {
  # /var/www/_retired_ss_20260724 and ss.archived-20260522 are real, legitimate
  # retirements. Making retirement red would make the gate noise.
  _fixture_decl gated
  cat > "${TMP}/cap-retired" <<'EOF'
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
dirlist=/var/www
D alpha
D beta
D _retired_ss_20260724
EOF
  _stub_probe "${TMP}/cap-retired"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE-TREE"* ]]
  [[ "$output" == *"_retired_ss_20260724"* ]]
}

@test "UNREACHABLE-DECLARATION: a declared site no vhost serves is reported" {
  _fixture_decl gated
  cat > "${TMP}/cap-noserve-beta" <<'EOF'
NWPROOTS v1
master=yes
config=/etc/nginx/nginx.conf
readmode=plain
file=/etc/nginx/conf.d/alpha.conf
L server {
L server_name alpha.example.org;
L root /var/www/alpha/web;
L }
dirlist=/var/www
D alpha
EOF
  _stub_probe "${TMP}/cap-noserve-beta"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNREACHABLE-DECLARATION"* ]]
  [[ "$output" == *"beta"* ]]
}

################################################################################
# (6) SHAPE — redirect-only and reverse-proxy vhosts are real on this estate.
################################################################################

@test "a redirect-only vhost contributes NO served root (no false UNDECLARED)" {
  # ssc.conf and ss2.conf are pure 301s with no docroot at all. Treating a
  # redirect as a docroot would invent findings.
  _fixture_decl gated
  cat > "${TMP}/cap-redirect" <<'EOF'
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
file=/etc/nginx/conf.d/gone.conf
L server {
L server_name gone.example.org;
L return 301 https://alpha.example.org$request_uri;
L }
dirlist=/var/www
D alpha
D beta
EOF
  _stub_probe "${TMP}/cap-redirect"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNDECLARED-ROOT"* ]]
}

@test "a location-level ACME root is classed apart from a site docroot" {
  # rgv.conf/hs.conf carry `root /var/www/html` INSIDE a
  # location ^~ /.well-known/acme-challenge/ block. That is an ACME stub, not
  # a site docroot, and must not be reported as an undeclared site.
  _fixture_decl gated
  cat > "${TMP}/cap-acme" <<'EOF'
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
file=/etc/nginx/conf.d/proxy.conf
L server {
L server_name proxy.example.org;
L location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
L location / { proxy_pass http://127.0.0.1:8071; }
L }
dirlist=/var/www
D alpha
D beta
EOF
  _stub_probe "${TMP}/cap-acme"
  run "$PL" server roots testbox --probe-cmd="$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOCATION-ROOT"* ]]
}

################################################################################
# (7) THE PROBE MUST STAY CHEAP — this box is 3.8 GB and runs GitLab + the
#     live fleet. A heavy op OOM-killed it for 5-8 minutes on 2026-07-25.
################################################################################

@test "the roots probe NEVER invokes gitlab-rails, gitlab-rake or a heavy op" {
  # NOT a grep over the whole lib: that passes vacuously if the file is absent,
  # which is the precise shape of the bug this whole MR exists to prevent. We
  # materialise the ACTUAL remote script and inspect that.
  [ -f "${REPO_ROOT}/lib/served-roots.sh" ]
  run bash -c "source '${REPO_ROOT}/lib/served-roots.sh'; served_roots_probe_script"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run bash -c "source '${REPO_ROOT}/lib/served-roots.sh'; served_roots_probe_script \
      | grep -vE '^[[:space:]]*#' \
      | grep -nE 'gitlab-rails|gitlab-rake|mysqldump|composer |nginx -s|nginx -t|systemctl (restart|reload|start)|gitlab-ctl'"
  [ "$status" -ne 0 ]
}

@test "the roots probe is READ-ONLY — it writes nothing on the box" {
  [ -f "${REPO_ROOT}/lib/served-roots.sh" ]
  run bash -c "source '${REPO_ROOT}/lib/served-roots.sh'; served_roots_probe_script"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # No output redirection to a real file, no tee, no mutation verbs. Discarding
  # stderr/stdout to /dev/null is permitted and is the ONLY redirect the probe
  # may use; anything else would be a write to the box.
  run bash -c "source '${REPO_ROOT}/lib/served-roots.sh'; served_roots_probe_script \
      | grep -vE '^[[:space:]]*#' \
      | sed -E 's#[0-9]*>[[:space:]]*/dev/null##g; s#2>&1##g' \
      | grep -nE '>|tee |rm |mkdir |cp |mv |chmod |chown |touch |truncate '"
  [ "$status" -ne 0 ]
}
