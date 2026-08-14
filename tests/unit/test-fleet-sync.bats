#!/usr/bin/env bats
#
# pl fleet sync + scripts/fleet-sync-host.sh — automated engine-code
# propagation to nwp hosts (nwp/ops#360).
#
# WHAT THIS FILE PROVES (every refusal observed RED, per the standing order):
#
#  1. A host bound to a PROD-reaching role in the instance manifest is REFUSED
#     — by the worker at run time AND by `pl fleet sync install` at provision
#     time. Keyed off ROLES (verifier/signed-deploy/prod-cluster/prod-agent/
#     prod-au), never a hostname list, so the guard arms itself the moment a
#     host is bound to such a role. Inert today (no prod exists), correct
#     forever — and proven able to fire against a fixture, which is the
#     estate's standard for inert guards (ops#214).
#  2. A checkout serving a site whose canonical phase is `prod` (or an
#     unparseable phase) is REFUSED — fail closed, same vocabulary as
#     lib/canonical.sh.
#  3. Dirty tree / non-main branch / diverged history: SKIPPED or REFUSED
#     loudly; the tree is NEVER stashed, checkout-forced or reset.
#  4. Signature policy: with NWP_REQUIRE_SIGNED_COMMITS=1 an unsigned incoming
#     range is REFUSED (measured 2026-08-14: 25/25 recent main commits are
#     unsigned, so the default is the same report-only honesty as
#     scripts/ci/verify-signature.sh — counts ledgered, sync proceeds).
#  5. An unreachable origin is CANNOT VERIFY (exit 2), never "up to date".
#  6. A post-pull health failure (bash -n on a changed script) REVERTS to the
#     recorded from-sha.
#  7. The positive paths work — a clean fast-forward syncs, records state and
#     ledger — so the refusal tests above are proven non-vacuous.
#
# RED-THEN-GREEN: this file was run against the tree BEFORE the feature
# existed (worker script absent, `pl fleet sync` an unknown subcommand); the
# failure counts are quoted in the MR.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WORKER="$PROJECT_ROOT/scripts/fleet-sync-host.sh"
    FLEET="$PROJECT_ROOT/scripts/commands/fleet.sh"
    T="$(mktemp -d)"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid
    export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
    export NWP_SYNC_HOST_LABEL=testhost
    # point at a manifest that does not exist: the worker's role guard is
    # defence in depth and must not block hosts that have no manifest (the ai-host
    # and met do not); each test that needs one writes its own fixture.
    export NWP_INSTANCE_MANIFEST="$T/no-such-manifest.yml"
    unset NWP_REQUIRE_SIGNED_COMMITS NWP_SYNC_ROLE
}

teardown() { rm -rf "$T"; }

# --- fixtures ---------------------------------------------------------------

# A bare "forge" repo + a seed clone to author commits in + a "host" clone
# that plays the remote nwp checkout the worker manages.
mk_estate() {
    git init -q --bare "$T/origin.git"
    git init -q -b main "$T/seed"
    ( cd "$T/seed" \
      && printf '#!/bin/bash\necho ok\n' > ok.sh \
      && git add ok.sh && git commit -qm 'seed' \
      && git remote add origin "$T/origin.git" \
      && git push -q origin main )
    git clone -q "$T/origin.git" "$T/host" 2>/dev/null
    git -C "$T/host" checkout -q main
    export NWP_ROOT="$T/host"
}

# Author one more (unsigned) commit on the forge's main. $1 = filename,
# $2 = content (defaults to a valid shell script).
advance_origin() {
    ( cd "$T/seed" \
      && printf '%s' "${2:-#!/bin/bash
echo v2
}" > "${1:-ok.sh}" \
      && git add "${1:-ok.sh}" && git commit -qm "advance: ${1:-ok.sh}" \
      && git push -q origin main )
}

write_manifest() { # $1 = yaml roles body
    printf 'roles:\n%s\n' "$1" > "$T/manifest.yml"
    export NWP_INSTANCE_MANIFEST="$T/manifest.yml"
}

# --- 1. prod exclusion, worker (run time) ------------------------------------

@test "ops#360: worker REFUSES a host bound to a prod role in the manifest" {
    mk_estate
    advance_origin
    write_manifest '  prod-cluster: [testhost]'
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"prod-cluster"* ]]
    # and it must not have moved the checkout
    [ "$(git -C "$T/host" rev-parse HEAD)" != "$(git -C "$T/origin.git" rev-parse main)" ]
}

@test "ops#360: worker refuses verifier-role hosts too (the verifier host is never a target)" {
    mk_estate
    write_manifest '  verifier: [otherbox, testhost]'
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"verifier"* ]]
}

@test "ops#360: a manifest that binds testhost only to safe roles is NOT refused" {
    mk_estate
    write_manifest '  ai-host: [testhost]
  prod-cluster: [someprodbox]'
    run bash "$WORKER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CURRENT"* ]]
}

# --- 2. canonical phase = prod, worker (run time) ----------------------------

@test "ops#360: worker REFUSES when a local site's canonical phase is prod" {
    mk_estate
    advance_origin
    printf 'sites:\n  foo:\n    canonical: prod\n' > "$T/host/nwp.yml"
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"canonical"* ]]
    [ "$(git -C "$T/host" rev-parse HEAD)" != "$(git -C "$T/origin.git" rev-parse main)" ]
}

@test "ops#360: an unparseable canonical phase FAILS CLOSED (refused, not defaulted)" {
    mk_estate
    printf 'sites:\n  foo:\n    canonical: banana\n' > "$T/host/nwp.yml"
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
}

@test "ops#360: canonical dev/live sites do not block the sync" {
    mk_estate
    printf 'sites:\n  foo:\n    canonical: live\n  bar:\n    canonical: dev\n' > "$T/host/nwp.yml"
    run bash "$WORKER"
    [ "$status" -eq 0 ]
}

# --- 3. dirty tree / branch / divergence -------------------------------------

@test "ops#360: dirty tracked file = loud SKIP, file untouched, no pull" {
    mk_estate
    advance_origin
    echo "local work in progress" >> "$T/host/ok.sh"
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SKIPPED"* ]]
    [[ "$output" == *"dirty"* ]]
    grep -q "local work in progress" "$T/host/ok.sh"
    [ "$(git -C "$T/host" rev-parse HEAD)" != "$(git -C "$T/origin.git" rev-parse main)" ]
}

@test "ops#360: non-main branch = loud SKIP, never a checkout" {
    mk_estate
    git -C "$T/host" checkout -qb somebody-elses-work
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SKIPPED"* ]]
    [ "$(git -C "$T/host" rev-parse --abbrev-ref HEAD)" = "somebody-elses-work" ]
}

@test "ops#360: diverged history = REFUSED, local commit preserved, no reset" {
    mk_estate
    ( cd "$T/host" && echo divergent > local.txt && git add local.txt \
      && git commit -qm 'local divergent commit' )
    advance_origin
    local_head="$(git -C "$T/host" rev-parse HEAD)"
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"diverged"* ]]
    [ "$(git -C "$T/host" rev-parse HEAD)" = "$local_head" ]
}

# --- 4. signature policy -----------------------------------------------------

@test "ops#360: NWP_REQUIRE_SIGNED_COMMITS=1 REFUSES an unsigned incoming range" {
    mk_estate
    mkdir -p "$T/host/scripts/ci"
    cp "$PROJECT_ROOT/scripts/ci/verify-signature.sh" "$T/host/scripts/ci/"
    advance_origin
    export NWP_REQUIRE_SIGNED_COMMITS=1
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"unsigned"* ]]
    [ "$(git -C "$T/host" rev-parse HEAD)" != "$(git -C "$T/origin.git" rev-parse main)" ]
}

@test "ops#360: enforcement with NO verifier script on the host fails closed" {
    mk_estate
    advance_origin
    export NWP_REQUIRE_SIGNED_COMMITS=1
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "ops#360: default (report-only) syncs and LEDGERS the signature counts" {
    mk_estate
    mkdir -p "$T/host/scripts/ci"
    cp "$PROJECT_ROOT/scripts/ci/verify-signature.sh" "$T/host/scripts/ci/"
    advance_origin
    run bash "$WORKER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SYNCED"* ]]
    grep -q "signed=0/1" "$T/host/logs/fleet-sync.log"
}

# --- 5. unreachable origin ---------------------------------------------------

@test "ops#360: unreachable origin is CANNOT VERIFY (exit 2), never up-to-date" {
    mk_estate
    rm -rf "$T/origin.git"
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    [[ "$output" != *"CURRENT"* ]]
}

# --- 6. post-pull health check ----------------------------------------------

@test "ops#360: a changed script that fails bash -n REVERTS to the from-sha" {
    mk_estate
    from="$(git -C "$T/host" rev-parse HEAD)"
    advance_origin bad.sh '#!/bin/bash
if [ broken syntax here ; then
'
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"REVERTED"* ]]
    [ "$(git -C "$T/host" rev-parse HEAD)" = "$from" ]
    [ ! -f "$T/host/bad.sh" ]
}

# --- 7. positive paths (the refusals above are not vacuous) ------------------

@test "ops#360: clean fast-forward SYNCS, records state file + ledger line" {
    mk_estate
    from="$(git -C "$T/host" rev-parse HEAD)"
    advance_origin
    to="$(git -C "$T/origin.git" rev-parse main)"
    run bash "$WORKER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SYNCED"* ]]
    [ "$(git -C "$T/host" rev-parse HEAD)" = "$to" ]
    python3 - "$T/host/logs/fleet-sync-state.json" "$from" "$to" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["result"] == "synced", d
assert d["from"] == sys.argv[2] and d["to"] == sys.argv[3], d
assert "restart_pending" in d and "ts" in d and "host" in d, d
PY
    grep -q "result=synced" "$T/host/logs/fleet-sync.log"
}

@test "ops#360: already current = exit 0, result recorded as current" {
    mk_estate
    run bash "$WORKER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CURRENT"* ]]
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["result"]=="current", d' \
        "$T/host/logs/fleet-sync-state.json"
}

@test "ops#360: every refusal still writes the state file (status never stale-green)" {
    mk_estate
    advance_origin
    echo dirt >> "$T/host/ok.sh"
    run bash "$WORKER"
    [ "$status" -eq 2 ]
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["result"]=="skipped-dirty", d' \
        "$T/host/logs/fleet-sync-state.json"
}

# --- 8. pl fleet sync install guard (provision time) -------------------------

@test "ops#360: install --host=prod-cluster is REFUSED outright" {
    write_manifest '  prod-cluster: [someprodbox]'
    run bash "$FLEET" sync install --host=prod-cluster --dry-run
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"prod"* ]]
}

@test "ops#360: install --host=verifier and --host=signed-deploy are REFUSED" {
    write_manifest '  verifier: [vbox]
  signed-deploy: [vbox]'
    run bash "$FLEET" sync install --host=verifier --dry-run
    [ "$status" -eq 2 ]
    run bash "$FLEET" sync install --host=signed-deploy --dry-run
    [ "$status" -eq 2 ]
}

@test "ops#360: install --host=authoring is REFUSED (sessions control the dev tree)" {
    write_manifest '  authoring: [carlo]'
    run bash "$FLEET" sync install --host=authoring --dry-run
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"session"* ]]
}

@test "ops#360: a target host that ALSO holds a prod role is REFUSED (arms itself)" {
    write_manifest '  ai-host: [boxa]
  prod-agent: [boxa]'
    run bash "$FLEET" sync install --host=ai-host --dry-run
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"prod-agent"* ]]
}

@test "ops#360: no readable manifest = CANNOT VERIFY (exit 2), not a pass" {
    export NWP_INSTANCE_MANIFEST="$T/absent.yml"
    run bash "$FLEET" sync install --host=ai-host --dry-run
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "ops#360: a clean target role passes the guard (dry-run prints the cron block)" {
    write_manifest '  ai-host: [cleanbox]'
    mkdir -p "$T/bin"
    cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
# fake ssh: answer the remote-root discovery probe for any target
echo "/home/fake/nwp"
EOF
    chmod +x "$T/bin/ssh"
    PATH="$T/bin:$PATH" run bash "$FLEET" sync install --host=ai-host --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"fleet-sync-host.sh"* ]]
    [[ "$output" == *"dry-run"* ]]
}

@test "ops#360: sync status with an unreachable host exits 2, never renders it current" {
    write_manifest '  ai-host: [definitely-unreachable-host-360]'
    NWP_FLEET_SYNC_ROLES="ai-host" run bash "$FLEET" sync status
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREACHABLE"* ]]
    [[ "$output" != *"CURRENT"* ]]
}
