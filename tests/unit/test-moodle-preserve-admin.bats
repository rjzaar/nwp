#!/usr/bin/env bats
# nwp/ops#127 (2/3) — moodle.sh --preserve-admin (DR): keep the real `siteadmins`
# untouched, scrub everyone else, allowlist ONLY the preserved admin emails.
# Moodle admins = the siteadmins set (NOT literally uid 1).

S="${BATS_TEST_DIRNAME}/../../lib/sanitizers/moodle.sh"
FIX="${BATS_TEST_DIRNAME}/../fixtures"

@test "default scrub floor is id > 1; --preserve-admin excludes siteadmins" {
  grep -Eq 'USER_SCRUB_WHERE="id > 1"' "$S"
  grep -Eq 'USER_SCRUB_WHERE="id > 1 AND id NOT IN \(\$\{_sa\}\)"' "$S"
}

@test "siteadmins list is validated (digits+commas only) before use in IN()" {
  grep -Eq '_sa" =~ \^\[0-9\]\+\(,\[0-9\]\+\)\*\$' "$S"
}

@test "preserve-admin skips the dev-admin restore (real admins kept)" {
  grep -Eq 'skipping dev-admin restore' "$S"
}

@test "verify: admin-only dump PASSES with --preserve-admin + matching admin mails" {
  run bash "$S" --verify --output "$FIX/moodle-dr-admin-only.sql.gz" --preserve-admin --admin-mail 'admin1@school.io,admin2@school.io'
  [ "$status" -eq 0 ]
}

@test "verify: admin-only dump FAILS without --preserve-admin (admin emails flagged)" {
  run bash "$S" --verify --output "$FIX/moodle-dr-admin-only.sql.gz"
  [ "$status" -ne 0 ]
}

@test "verify: a leaked MEMBER email still FAILS with --preserve-admin (no over-allowlist)" {
  run bash "$S" --verify --output "$FIX/moodle-dr-with-member.sql.gz" --preserve-admin --admin-mail 'admin1@school.io,admin2@school.io'
  [ "$status" -ne 0 ]
}
