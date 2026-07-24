#!/usr/bin/env bats
# nwp/ops#127 — ver-pull-session.sh wires the per-source data class from
# pull-sources.conf (name|from|to|kind) into ver-backup-pull's erasure ceiling:
#   raw       → --kind raw --keep-within 30d   (or raw:<DUR> for an override)
#   sanitized → --kind sanitized               (tiered daily/weekly/monthly)
# and FAILS CLOSED on any source that omits or mis-declares its data class, so a
# RAW (PII) source can never silently fall through to ~1yr retention.

SESSION="${BATS_TEST_DIRNAME}/../../scripts/ver-provision/ver-pull-session.sh"

setup() {
  T="$(mktemp -d)"
  ETC="$T/etc"; RUN="$T/run"; ART="$T/art"
  mkdir -p "$ETC" "$RUN" "$ART/scripts/commands"
  # pinned pubkey the session insists on (content irrelevant to the stub path)
  : > "$ETC/nwp-minisign.pub"

  # Copy the real session script into T so SELF_DIR resolves here — lets us drop
  # a stub keystore alongside it instead of invoking real crypto.
  cp "$SESSION" "$T/ver-pull-session.sh"
  cat > "$T/ver-seal-keystore.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$T/ver-seal-keystore.sh"

  # Stub ver-backup-pull that records the exact flags each source is drained with.
  CAP="$T/pull.calls"
  cat > "$ART/scripts/commands/ver-backup-pull.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$CAP"
exit 0
EOF
  chmod +x "$ART/scripts/commands/ver-backup-pull.sh"
}

teardown() { rm -rf "$T"; }

conf() { printf '%s\n' "$@" > "$ETC/pull-sources.conf"; }

run_check() { NWP_VER_ETC="$ETC" run bash "$T/ver-pull-session.sh" --check; }

run_session() {
  NWP_VER_ETC="$ETC" NWP_VER_RUN="$RUN" \
    run bash "$T/ver-pull-session.sh" --artifact "$ART"
}

# ── --check preflight ────────────────────────────────────────────────────────

@test "--check passes a conf where every source declares a valid data class" {
  conf '# a comment' \
       'site1|sftp:x|/srv/a|raw' \
       'site2|sftp:y|/srv/b|sanitized' \
       'site3|sftp:z|/srv/c|raw:14d'
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"all declare a valid data class"* ]]
}

@test "--check FAILS CLOSED on a legacy 3-field line (no data class)" {
  conf 'legacy|sftp:x|/srv/a' \
       'site2|sftp:y|/srv/b|sanitized'
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"legacy"* ]]
  [[ "$output" == *"fail-closed"* ]]
}

@test "--check FAILS CLOSED on a raw source with an empty ceiling (raw:)" {
  conf 'noceiling|sftp:x|/srv/a|raw:'
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"noceiling"* ]]
}

@test "--check FAILS CLOSED on an unknown data class" {
  conf 'weird|sftp:x|/srv/a|bogus'
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"weird"* ]]
}

@test "--check FAILS CLOSED on a missing from/to repo" {
  conf 'halfline|sftp:x||raw'
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing from/to"* ]]
}

# ── end-to-end wiring (stubbed keystore + ver-backup-pull) ───────────────────

@test "a RAW source is drained with --kind raw --keep-within 30d" {
  conf 'site1|sftp:x|/srv/a|raw'
  run_session
  [ "$status" -eq 0 ]
  grep -Fq -- '--kind raw --keep-within 30d' "$CAP"
}

@test "a raw:<DUR> source uses its own ceiling, not the 30d default" {
  conf 'site1|sftp:x|/srv/a|raw:14d'
  run_session
  [ "$status" -eq 0 ]
  grep -Fq -- '--kind raw --keep-within 14d' "$CAP"
}

@test "a SANITIZED source is drained with --kind sanitized and NO keep-within" {
  conf 'site2|sftp:y|/srv/b|sanitized'
  run_session
  [ "$status" -eq 0 ]
  grep -Fq -- '--kind sanitized' "$CAP"
  ! grep -Fq -- '--keep-within' "$CAP"
}

@test "a bad conf aborts the session before ANY source is drained" {
  conf 'good|sftp:x|/srv/a|raw' \
       'bad|sftp:y|/srv/b|oops'
  run_session
  [ "$status" -ne 0 ]
  # validate_conf runs before the drain loop → no pull was ever invoked
  [ ! -f "$CAP" ]
}

@test "help documents the data-class field and --check" {
  run bash "$SESSION" --help
  [[ "$output" == *"name|from_repo|to_repo|kind"* ]]
  [[ "$output" == *"--check"* ]]
}
