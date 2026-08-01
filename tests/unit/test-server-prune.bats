#!/usr/bin/env bats
# lib/server-prune.sh — the last step of a box migration.
#
# Prune deletes the only copy of production that is not a backup, so the tests
# that matter here are the REFUSALS. Every case below pins something that went
# wrong while building the verb against the real 2026-07-31 nwpcode -> live
# split, and each was silent:
#
#  * `hs.<live-domain>` — the headscale control server for the whole fleet — was
#    put on the certbot delete list, because the keep-list was built only from
#    SITES and headscale is declared as INFRASTRUCTURE (it deliberately has no
#    sites/<n>/.nwp.yml). "Not a site" read as "prunable".
#  * The infrastructure lookup used the wrong yq path and returned nothing.
#    An empty keep-list is indistinguishable from "nothing declared", so the
#    bug could only ever be seen by checking a name that SHOULD be kept.
#  * Loops ending in `[[ -n "$x" ]] && cmd` take the test's exit status, so a
#    false final iteration failed the loop and, under `set -e`, killed the
#    whole command after printing only its header — no manifest, no error.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT NWP_DIR="$TEST_ROOT" YQ="${YQ:-yq}"
  mkdir -p "$TEST_ROOT/servers/box" "$TEST_ROOT/sites/moved" "$TEST_ROOT/sites/stays"

  cat > "$TEST_ROOT/servers/box/.nwp-server.yml" <<'YML'
server:
  name: box
  domain: box.example.org
infrastructure_roots:
  - path: /var/www/hs/html
    service: headscale
    domain: hs.example.org
YML
  cat > "$TEST_ROOT/sites/moved/.nwp.yml" <<'YML'
live:
  server: newbox
  domain: moved.example.org
  remote_path: /var/www/moved
YML
  cat > "$TEST_ROOT/sites/stays/.nwp.yml" <<'YML'
live:
  server: box
  domain: stays.example.org
  remote_path: /var/www/stays
YML

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/server-prune.sh"
}

teardown() { rm -rf "${TEST_ROOT}"; }

# A stub ssh prefix: runs the command locally instead of on a box.
stub_prefix() { echo "bash -c"; }

# --- [P1] proof of life elsewhere -------------------------------------------

@test "[P1] a site declared to ANOTHER server is prunable" {
  get_site_server() { echo "newbox"; }
  run prune_site_is_elsewhere moved box
  [ "$status" -eq 0 ]
}

@test "[P1] a site still declared to THIS server is never prunable" {
  get_site_server() { echo "box"; }
  run prune_site_is_elsewhere stays box
  [ "$status" -ne 0 ]
}

@test "[P1] a site with NO declared server is kept — unknown must not mean delete" {
  get_site_server() { return 1; }
  run prune_site_is_elsewhere mystery box
  [ "$status" -ne 0 ]
}

# --- the site-field readers -------------------------------------------------

@test "site fields are read from the SITE ROOT declaration, not a checkout" {
  run get_site_remote_path moved
  [ "$status" -eq 0 ]
  [ "$output" = "/var/www/moved" ]
  run get_site_domain moved
  [ "$output" = "moved.example.org" ]
}

@test "a missing site declaration fails rather than returning an empty keep entry" {
  run get_site_remote_path nosuchsite
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- [P2] the keep-list is fail-closed --------------------------------------

# A real renewal directory, so these assert on actual classification rather
# than on an empty listing (which passes every assertion vacuously).
mk_renewals() {
  export PRUNE_RENEWAL_DIR="$TEST_ROOT/renewal"
  mkdir -p "$PRUNE_RENEWAL_DIR"
  local n
  for n in "$@"; do touch "$PRUNE_RENEWAL_DIR/${n}.conf"; done
  # The stub prefix is `bash -c`, i.e. a FRESH shell — a `sudo` shell function
  # defined here would not survive into it, which is why the first cut of these
  # tests passed on empty output. Put a real shim on PATH instead.
  mkdir -p "$TEST_ROOT/bin"
  printf '#!/bin/sh\nexec "$@"\n' > "$TEST_ROOT/bin/sudo"
  chmod +x "$TEST_ROOT/bin/sudo"
  export PATH="$TEST_ROOT/bin:$PATH"
}

@test "[P2] REGRESSION: an infrastructure domain (headscale) is NOT a dead renewal" {
  # The bug that mattered: hs.example.org is declared as INFRASTRUCTURE, has no
  # site file, and must survive. Deleting its renewal takes the fleet's tailnet
  # control server off the air at the next expiry — weeks later, silently.
  mk_renewals hs.example.org stays.example.org moved.example.org
  run prune_dead_certbot_renewals "$(stub_prefix)" "stays.example.org hs.example.org"
  [ "$status" -eq 0 ]
  [[ "$output" != *"hs.example.org"* ]]
  [[ "$output" != *"stays.example.org"* ]]
  # ...and it must still find the genuinely dead one, or the test proves nothing.
  [[ "$output" == *"moved.example.org"* ]]
}

@test "[P2] the infrastructure path yields the TREE to keep, not the ACME leaf" {
  # /var/www/hs/html is the served webroot; the tree that must survive is
  # /var/www/hs. basename() would yield "html" and leave /var/www/hs to be
  # deleted — keeping the empty challenge dir and destroying the service.
  run prune_infra_tree /var/www/hs/html
  [ "$status" -eq 0 ]
  [ "$output" = "hs" ]
}

@test "[P2] an infrastructure path outside /var/www keeps nothing, and says so" {
  run prune_infra_tree /opt/something/else
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "[P2] a renewal for a name nobody claims IS reported as dead" {
  mk_renewals orphan.example.org stays.example.org
  run prune_dead_certbot_renewals "$(stub_prefix)" "stays.example.org"
  [ "$status" -eq 0 ]
  [[ "$output" == *"orphan.example.org"* ]]
  [[ "$output" != *"stays.example.org"* ]]
}

# --- the near-miss: "not on the keep-list" is NOT the same as "prunable" ----
#
# The first cut built the delete set by SUBTRACTING a keep-list from everything
# present on the box. Dry-run against the live sites box, that proposed to
# delete every Moodle's data directory, two live databases, and the certificate
# of a site that was serving fine. All three share one cause: undeclared read
# as prunable. The candidate set is now BUILT UP from sites that demonstrably
# moved, so anything unattributable is kept.

@test "REGRESSION: a Moodle's undeclared _moodledata is a COMPANION of its webroot" {
  # A Moodle declares remote_path: /var/www/ssc — the webroot. Its data lives
  # in /var/www/ssc_moodledata, which no file declares. Treating that as
  # orphaned deletes every course, upload and submission on the host, while the
  # webroot survives so the site 500s rather than obviously disappearing.
  run prune_companion_trees /var/www/ssc
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssc"* ]]
  [[ "$output" == *"ssc_moodledata"* ]]
}

@test "REGRESSION: a cert whose name still resolves HERE is never dead" {
  # rgv.<live-domain> serves from the live box (HTTP 401, basic-auth gated) and
  # has no sites/rgv/.nwp.yml at all. Declaration-only reasoning called its
  # renewal dead. DNS is the ground truth that overrides a missing declaration.
  run prune_cert_is_dead rgv.example.org "203.0.113.9" "203.0.113.9"
  [ "$status" -ne 0 ]
}

@test "a cert for a moved name that resolves ELSEWHERE is dead" {
  run prune_cert_is_dead moved.example.org "198.51.100.7" "203.0.113.9"
  [ "$status" -eq 0 ]
}

@test "a cert whose name does not resolve at all is KEPT, not guessed at" {
  run prune_cert_is_dead gone.example.org "" "203.0.113.9"
  [ "$status" -ne 0 ]
}

# --- [P1] proof of life, wired for real -------------------------------------
#
# The first cut DEFINED prune_site_is_elsewhere, tested it, and then never
# called it — the gate existed only in the header comment. "Declared elsewhere"
# was the whole test, which is not the same question as "is anything else
# actually serving it".

@test "[P1] REGRESSION: declared elsewhere but STILL RESOLVING HERE is kept" {
  # The real case: cccrdf is declared to the live server, but its A record was
  # never flipped and still points at the old box. On declarations alone this
  # authorised deleting the only copy of a site no new box serves.
  run prune_points_elsewhere cccrdf.example.org "203.0.113.9" "203.0.113.9"
  [ "$status" -ne 0 ]
}

@test "[P1] declared elsewhere AND resolving elsewhere is prunable" {
  run prune_points_elsewhere moved.example.org "198.51.100.7" "203.0.113.9"
  [ "$status" -eq 0 ]
}

@test "[P1] a domain that does not resolve at all is kept, not assumed moved" {
  run prune_points_elsewhere ghost.example.org "" "203.0.113.9"
  [ "$status" -ne 0 ]
}

@test "[P1] prune_cert_is_dead and the site check share ONE implementation" {
  # They ask the same question of DNS. Two copies would drift, and the drift
  # would be silent in exactly one direction: deleting more than intended.
  run prune_cert_is_dead x.example.org "198.51.100.7" "203.0.113.9"
  [ "$status" -eq 0 ]
  run prune_cert_is_dead x.example.org "203.0.113.9" "203.0.113.9"
  [ "$status" -ne 0 ]
}

# --- [P6] a backup must exist -----------------------------------------------

@test "[P6] no backup at all -> refusal, not a guess" {
  run prune_backup_age_hours "$(stub_prefix)" "$TEST_ROOT/definitely-absent"
  [ "$status" -ne 0 ]
}

@test "[P6] a present backup reports an age in hours" {
  mkdir -p "$TEST_ROOT/bk"; touch "$TEST_ROOT/bk/dump.sql.gz"
  mk_renewals   # reuse: puts the `sudo` shim on PATH for the stub subshell
  run prune_backup_age_hours "$(stub_prefix)" "$TEST_ROOT/bk"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# --- [P5] a database an app still names is never dropped --------------------

@test "[P5] an unreadable app config protects rather than exposes its database" {
  # prune_probe_live_dbnames output is only ever SUBTRACTED from the drop set,
  # so a config it cannot read must yield nothing and the caller must treat a
  # name it cannot confirm as still-in-use. Empty output, exit 0, no crash.
  run prune_probe_live_dbnames "$(stub_prefix)" "/nonexistent/path"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- loop-exit-status regression --------------------------------------------

@test "REGRESSION: probing several paths does not fail on a final empty result" {
  # A loop takes its last command's status. When the final path yielded no db
  # name, the function returned 1, the caller's pipeline failed under pipefail,
  # and `set -e` aborted the command with only a header printed.
  run prune_probe_live_dbnames "$(stub_prefix)" "/nope/one" "/nope/two"
  [ "$status" -eq 0 ]
}
