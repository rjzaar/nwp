#!/usr/bin/env bats
# nwp/ops#127 — standard.sh --preserve-admin (DR sanitiser): keep uid 1 intact,
# scrub everyone else, and allowlist ONLY uid 1's retained email in pii_sweep.
# Functional tests via the --verify entrypoint (runs pii_sweep only).

S="${BATS_TEST_DIRNAME}/../../lib/sanitizers/standard.sh"
FIX="${BATS_TEST_DIRNAME}/../fixtures"

@test "default scrub floor is uid>0; --preserve-admin makes it uid>1" {
  grep -Eq 'USER_SCRUB_WHERE="uid>1"' "$S"
  grep -Eq 'USER_SCRUB_WHERE="uid>0"' "$S"
  grep -Eq 'PRESERVE_ADMIN.*= true.*USER_SCRUB_WHERE="uid>1"' "$S"
}

@test "captures uid 1 mail from the SCRATCH copy before scrubbing" {
  grep -Eq "PRESERVE_ADMIN_MAIL=.*SELECT mail FROM users_field_data WHERE uid=1" "$S"
}

@test "verify: admin-only dump PASSES with --preserve-admin + matching --admin-mail" {
  run bash "$S" --verify --output "$FIX/dr-admin-only.sql.gz" --preserve-admin --admin-mail 'admin@realdomain.io'
  [ "$status" -eq 0 ]
}

@test "verify: admin-only dump FAILS without --preserve-admin (admin email flagged)" {
  run bash "$S" --verify --output "$FIX/dr-admin-only.sql.gz"
  [ "$status" -ne 0 ]
}

@test "verify: a leaked MEMBER email still FAILS even with --preserve-admin (no over-allowlist)" {
  run bash "$S" --verify --output "$FIX/dr-with-member.sql.gz" --preserve-admin --admin-mail 'admin@realdomain.io'
  [ "$status" -ne 0 ]
}
