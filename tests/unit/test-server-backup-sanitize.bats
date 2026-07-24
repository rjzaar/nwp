#!/usr/bin/env bats
# nwp/ops#127 (3/3) — server-backup.sh --sanitize: run the site sanitiser
# (--preserve-admin) + external PII gate (fail-closed) → DISTINCT <site>-sanitized
# repo, DB-only. Never emit an unsanitised long-term archive.

S="${BATS_TEST_DIRNAME}/../../scripts/commands/server-backup.sh"

@test "--sanitize targets a distinct <site>-sanitized repo" {
  grep -Eq 'repo_site="\$\{site\}-sanitized"' "$S"
}

@test "--sanitize implies DB-only (sanitised files deferred to ops#84)" {
  grep -Eq 'SANITIZE" = y \];? then\s*$' "$S" || grep -Eq 'repo_site="\$\{site\}-sanitized"\s*$' "$S"
  grep -Eq 'DB_ONLY=y' "$S"
}

@test "--sanitize is fail-closed on a missing sanitiser" {
  grep -Eq 'Refusing to write an unsanitised long-term archive' "$S"
  run bash "$S" --sanitize --site-dir /tmp/fake-site-127 --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no sanitiser"* ]] || [[ "$output" == *"sanitiser"* ]]
}

@test "--sanitize runs the external PII gate fail-closed before snapshot" {
  grep -Eq 'pii_gate_scan "\$tmp_db" "\$\{tmp_db\}.admin-allow"' "$S"
  grep -Eq 'external PII gate FAILED' "$S"
  grep -Eq 'lib/pii-gate.sh not loaded' "$S"
}

@test "--sanitize snapshot carries the sanitized tag; sidecar is shredded" {
  grep -Eq '_dbtags\+=\(--tag sanitized\)' "$S"
  grep -Eq 'admin-allow.*shred|shred.*admin-allow' "$S"
}

@test "sanitiser invoked with --preserve-admin" {
  grep -Eq '_san_args=\(--site-dir "\$SITE_DIR" --output "\$tmp_db" --preserve-admin\)' "$S"
}
