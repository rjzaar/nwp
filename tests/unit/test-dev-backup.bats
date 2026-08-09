#!/usr/bin/env bats
################################################################################
# test-dev-backup.bats — the met→laptop pull route + three-host presence
# (ops#330).
#
# Two claims are load-bearing and each is asserted by ERROR TEXT, never by
# blind negation (CLAUDE.md standing order):
#
#   1. The inbound laptop key is SINGLE-PURPOSE READ-ONLY. Its authorized_keys
#      line forces `rrsync -ro <export>`; these tests drive the REAL
#      /usr/bin/rrsync exactly as sshd would (SSH_ORIGINAL_COMMAND) and prove
#      it refuses a shell, refuses writes, refuses `..` escapes — and that the
#      probe CAN go green (an in-scope pull succeeds byte-exact).
#
#   2. A backup that silently stops is the failure mode that matters. The met
#      puller must fail LOUDLY (non-zero + named error) when the source is
#      unreachable and no fresh pushed staging exists, when the restic repo is
#      absent, and when the post-run verification finds a snapshot that is too
#      small or too old. Each failure mode is observed RED here.
#
# All host-touching pieces are NWP_*-overridable (an untestable host-specific
# script is a check nobody has seen fail).
################################################################################

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
EXPORT_SH="$REPO_ROOT/scripts/dev-backup-export.sh"
PULL_SH="$REPO_ROOT/scripts/met-dr-pull.sh"
INSTALL_SH="$REPO_ROOT/scripts/install-dev-backup.sh"

setup() {
    TDIR="$(mktemp -d)"
    export TDIR
}

teardown() {
    rm -rf "$TDIR"
}

# --- helpers ----------------------------------------------------------------

# A fake ssh transport that runs the real rrsync the way sshd's forced
# command would: the client's rsync server-invocation arrives in
# SSH_ORIGINAL_COMMAND. Lets us test the whole restricted pull path with no
# sshd. $1 = restricted dir.
make_fake_ssh() {
    local scope="$1"
    cat > "$TDIR/fake-ssh" <<EOF
#!/bin/bash
shift
export SSH_ORIGINAL_COMMAND="\$*"
exec /usr/bin/rrsync -ro "$scope"
EOF
    chmod +x "$TDIR/fake-ssh"
}

# Fixture tree shaped like the curated laptop set.
make_fixture() {
    mkdir -p "$TDIR/nwp/private" "$TDIR/nwp/servers/x" "$TDIR/nwp/classes" \
             "$TDIR/nwp/sites/alpha/backups" "$TDIR/nwp/sites/beta/dev" \
             "$TDIR/nwp/keys" "$TDIR/central/docs"
    echo "registry" > "$TDIR/nwp/private/secrets-registry.yml"
    echo "srv"      > "$TDIR/nwp/servers/x/conf"
    echo "class"    > "$TDIR/nwp/classes/a.md"
    echo "dump"     > "$TDIR/nwp/sites/alpha/backups/a.sql.gz"
    echo "central"  > "$TDIR/central/docs/op.md"
    echo "infra-secrets" > "$TDIR/nwp/.secrets.yml"
    # deny-tier files that must NEVER enter the export
    echo "DENY" > "$TDIR/nwp/.secrets.data.yml"
    echo "DENY" > "$TDIR/nwp/keys/prod_deploy"
    # junk that must be excluded
    mkdir -p "$TDIR/central/__pycache__"
    echo "junk" > "$TDIR/central/__pycache__/x.pyc"
}

export_env() {
    export NWP_DEV_EXPORT_DIR="$TDIR/export"
    export NWP_DEV_NWP_ROOT="$TDIR/nwp"
    export NWP_DEV_CENTRAL="$TDIR/central"
    export NWP_DEV_SKIP_MINI=1
    export NWP_DEV_SKIP_PUSH_MINI=1
}

# Stub restic: logs argv, answers snapshots/stats with configurable JSON.
make_restic_stub() {
    mkdir -p "$TDIR/bin"
    cat > "$TDIR/bin/restic" <<'EOF'
#!/bin/bash
echo "restic $*" >> "$STUB_LOG"
for a in "$@"; do case "$a" in
  snapshots) cat "$STUB_SNAPSHOTS_JSON"; exit 0 ;;
  stats)     cat "$STUB_STATS_JSON"; exit 0 ;;
esac; done
exit 0
EOF
    chmod +x "$TDIR/bin/restic"
    export STUB_LOG="$TDIR/restic.log"
    export STUB_SNAPSHOTS_JSON="$TDIR/snapshots.json"
    export STUB_STATS_JSON="$TDIR/stats.json"
    # healthy defaults: a snapshot from 'now', plausibly sized
    printf '[{"time":"%s","id":"abcdef1234567890","short_id":"abcdef12"}]\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$STUB_SNAPSHOTS_JSON"
    echo '{"total_size":900000000,"total_file_count":5000}' > "$STUB_STATS_JSON"
}

# Environment for met-dr-pull.sh pointed entirely at the fixture.
pull_env() {
    export NWP_DR_BASE="$TDIR/dr"
    export NWP_DR_RESTIC="$TDIR/bin/restic"
    export NWP_DR_PW_FILE="$TDIR/pw"
    export NWP_DR_DEV_KEY="$TDIR/key"
    export NWP_DR_LIVE_KEY="$TDIR/key"
    export NWP_DR_DEV_SRC="unreachable.invalid:"
    export NWP_DR_LIVE_SRC="unreachable.invalid:"
    export NWP_DR_NO_NOTIFY=1
    export NWP_DR_MIN_FILES_DEV=10
    export NWP_DR_MIN_BYTES_DEV=1000
    mkdir -p "$TDIR/dr/repo" "$TDIR/dr/staging-dev" "$TDIR/dr/staging-live"
    echo "cfg" > "$TDIR/dr/repo/config"     # restic repo marker
    echo "pw"  > "$TDIR/pw"; chmod 600 "$TDIR/pw"
    echo "key" > "$TDIR/key"; chmod 600 "$TDIR/key"
}

# ============================================================================
# 0. the scripts exist and parse
# ============================================================================

@test "dev-backup scripts exist and pass bash -n" {
    [ -f "$EXPORT_SH" ]
    [ -f "$PULL_SH" ]
    [ -f "$INSTALL_SH" ]
    bash -n "$EXPORT_SH"
    bash -n "$PULL_SH"
    bash -n "$INSTALL_SH"
}

# ============================================================================
# 1. the restricted key: rrsync -ro, driven as sshd would
# ============================================================================

@test "rrsync scope: a shell command is refused, by name" {
    mkdir -p "$TDIR/scope"
    SSH_ORIGINAL_COMMAND='bash -i' run /usr/bin/rrsync -ro "$TDIR/scope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SSH_ORIGINAL_COMMAND does not run rsync"* ]]
}

@test "rrsync scope: writing through the read-only key is refused, by name" {
    mkdir -p "$TDIR/scope"
    make_fake_ssh "$TDIR/scope"
    echo "payload" > "$TDIR/payload"
    run rsync -a -e "$TDIR/fake-ssh" "$TDIR/payload" dummy:
    [[ "$output" == *"sending to read-only server is not allowed"* ]]
    [ ! -e "$TDIR/scope/payload" ]
}

@test "rrsync scope: '..' path escape is refused, by name, and delivers nothing" {
    mkdir -p "$TDIR/scope" "$TDIR/out"
    echo "TOPSECRET" > "$TDIR/outside.txt"
    make_fake_ssh "$TDIR/scope"
    run rsync -a -e "$TDIR/fake-ssh" dummy:../outside.txt "$TDIR/out/"
    [ "$status" -ne 0 ]
    [[ "$output" == *"do not use .. in arg"* ]]
    [ ! -e "$TDIR/out/outside.txt" ]
}

@test "rrsync scope: positive control — an in-scope pull succeeds byte-exact" {
    mkdir -p "$TDIR/scope/sub" "$TDIR/out"
    echo "in-scope-data" > "$TDIR/scope/sub/file.txt"
    make_fake_ssh "$TDIR/scope"
    run rsync -a -e "$TDIR/fake-ssh" dummy: "$TDIR/out/"
    [ "$status" -eq 0 ]
    diff "$TDIR/scope/sub/file.txt" "$TDIR/out/sub/file.txt"
}

@test "installer emits the fully-hardened authorized_keys line" {
    echo "ssh-ed25519 AAAATESTKEYBLOB nwp-dev-pull@met" > "$TDIR/k.pub"
    run bash "$INSTALL_SH" --authorized-line "$TDIR/k.pub"
    [ "$status" -eq 0 ]
    [[ "$output" == *'command="rrsync -ro '* ]]
    [[ "$output" == *"no-agent-forwarding"* ]]
    [[ "$output" == *"no-port-forwarding"* ]]
    [[ "$output" == *"no-pty"* ]]
    [[ "$output" == *"no-user-rc"* ]]
    [[ "$output" == *"no-X11-forwarding"* ]]
    [[ "$output" == *"ssh-ed25519 AAAATESTKEYBLOB nwp-dev-pull@met"* ]]
}

# ============================================================================
# 2. the laptop export (hardlink farm)
# ============================================================================

@test "export builds the curated hardlink farm (same inode, junk excluded)" {
    make_fixture; export_env
    run bash "$EXPORT_SH"
    [ "$status" -eq 0 ]
    [ -f "$TDIR/export/nwp-private/secrets-registry.yml" ]
    [ -f "$TDIR/export/nwp-servers/x/conf" ]
    [ -f "$TDIR/export/nwp-classes/a.md" ]
    [ -f "$TDIR/export/secrets.yml" ]
    [ -f "$TDIR/export/sites-backups/alpha/a.sql.gz" ]
    [ -f "$TDIR/export/central/docs/op.md" ]
    # hardlink, not a copy: identical inode with the source
    [ "$(stat -c %i "$TDIR/export/central/docs/op.md")" = "$(stat -c %i "$TDIR/central/docs/op.md")" ]
    # junk excluded
    [ ! -e "$TDIR/export/central/__pycache__" ]
    # a site without backups/ is skipped, not fatal
    [ ! -e "$TDIR/export/sites-backups/beta" ]
}

@test "export NEVER contains deny-tier files (.secrets.data.yml, keys/)" {
    make_fixture; export_env
    run bash "$EXPORT_SH"
    [ "$status" -eq 0 ]
    run find "$TDIR/export" \( -name '.secrets.data.yml' -o -name 'prod_*' -o -name 'keys' \)
    [ -z "$output" ]
}

@test "export fails closed (exit 2, named) when a curated path is missing" {
    make_fixture; export_env
    rm -rf "$TDIR/nwp/private"
    run bash "$EXPORT_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT EXPORT"* ]]
    [[ "$output" == *"private"* ]]
}

@test "export --push to a local dest lands the set, writes the freshness marker, sha-verifies" {
    make_fixture; export_env
    export NWP_DEV_PUSH_DEST="$TDIR/staging"
    mkdir -p "$TDIR/staging"
    run bash "$EXPORT_SH" --push
    [ "$status" -eq 0 ]
    [ -f "$TDIR/staging/secrets.yml" ]
    [ -f "$TDIR/staging/.pushed-at" ]
    [[ "$output" == *"sha256 verified"* ]]
}

# ============================================================================
# 3. the met puller: every failure mode is loud
# ============================================================================

@test "met-dr-pull: missing transport key → exit 2 CANNOT" {
    make_restic_stub; pull_env
    rm -f "$TDIR/key"
    run bash "$PULL_SH" dev
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT"* ]]
}

@test "met-dr-pull: absent restic repo → exit 2, refuses to invent one" {
    make_restic_stub; pull_env
    rm -rf "$TDIR/dr/repo"
    run bash "$PULL_SH" dev
    [ "$status" -eq 2 ]
    [[ "$output" == *"repo"* ]]
    [[ "$output" == *"CANNOT"* ]]
}

@test "met-dr-pull: pull fails, no fresh pushed staging → loud failure, nothing snapshotted" {
    make_restic_stub; pull_env
    run bash "$PULL_SH" dev
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT backed up"* ]]
    ! grep -q "restic backup" "$STUB_LOG" 2>/dev/null
}

@test "met-dr-pull: pull fails but a FRESH pushed staging exists → push-fallback proceeds" {
    make_restic_stub; pull_env
    echo "data" > "$TDIR/dr/staging-dev/f"
    touch "$TDIR/dr/staging-dev/.pushed-at"
    run bash "$PULL_SH" dev
    [ "$status" -eq 0 ]
    [[ "$output" == *"push-fallback"* ]]
    grep -q "restic .*backup" "$STUB_LOG"
    grep -q "dev-pull" "$STUB_LOG"
}

@test "met-dr-pull: STALE pushed staging is not a backup → loud failure" {
    make_restic_stub; pull_env
    echo "data" > "$TDIR/dr/staging-dev/f"
    touch -d '2 days ago' "$TDIR/dr/staging-dev/.pushed-at"
    run bash "$PULL_SH" dev
    [ "$status" -eq 1 ]
    [[ "$output" == *"STALE"* ]]
}

@test "met-dr-pull verify: an implausibly small snapshot goes RED, by name" {
    make_restic_stub; pull_env
    echo "data" > "$TDIR/dr/staging-dev/f"
    touch "$TDIR/dr/staging-dev/.pushed-at"
    echo '{"total_size":12,"total_file_count":1}' > "$STUB_STATS_JSON"
    run bash "$PULL_SH" dev
    [ "$status" -eq 1 ]
    [[ "$output" == *"SANITY"* ]]
}

@test "met-dr-pull verify: a stale latest snapshot goes RED, by name" {
    make_restic_stub; pull_env
    echo "data" > "$TDIR/dr/staging-dev/f"
    touch "$TDIR/dr/staging-dev/.pushed-at"
    printf '[{"time":"2026-01-01T00:00:00Z","id":"abcdef1234567890","short_id":"abcdef12"}]\n' \
        > "$STUB_SNAPSHOTS_JSON"
    run bash "$PULL_SH" dev
    [ "$status" -eq 1 ]
    [[ "$output" == *"SANITY"* ]]
}

@test "met-dr-pull live: pull failure is loud and has NO fallback" {
    make_restic_stub; pull_env
    run bash "$PULL_SH" live
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT backed up"* ]]
}

@test "met-dr-pull live: a good pull snapshots with the live-pull tag" {
    make_restic_stub; pull_env
    # local rsync source stands in for the box (rsync accepts local paths)
    mkdir -p "$TDIR/livebox"; echo "db" > "$TDIR/livebox/site.sql.gz"
    export NWP_DR_LIVE_SRC="$TDIR/livebox/"
    export NWP_DR_MIN_FILES_LIVE=1 NWP_DR_MIN_BYTES_LIVE=1
    run bash "$PULL_SH" live
    [ "$status" -eq 0 ]
    grep -q -- "--tag live-pull" "$STUB_LOG"
    [ -f "$TDIR/dr/staging-live/site.sql.gz" ]
}
