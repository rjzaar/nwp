#!/usr/bin/env bats
# Demo-golden identity hygiene (lib/golden-hygiene.sh + check_demo_golden_hygiene).
#
# Defect this locks down: the ssd golden carried a Moodle SITE-ADMINISTRATOR row
# with a real person's given name, family name and personal mailbox, from the
# 2026-05-19 install until 2026-08-01. A golden is restored over the LIVE demo
# site every night and copied into every backup of the demo box, so the row was
# immortal — and every oversight surface graded the site green throughout,
# because nothing ever looked inside a golden.
#
# Contract now:
#   - a mailbox in a golden must be on an RFC-reserved sentinel domain or on a
#     domain nwp.yml declares for this estate; anything else is a FINDING
#   - the finding is SEC/high, which is what `pl rag` grades RED
#   - personal NAMES come from an untracked denylist; with no denylist the name
#     half of the check is UNKNOWN, never CLEAR
#   - findings report the matched name token MASKED — a leak report must not
#     re-publish the identifier it found
#
# NOTE FOR FUTURE EDITORS: every address below is deliberately fictional
# (person@gmail.com, someone@partner.example). Never put a real personal
# identifier in this file to "make the test realistic" — that is the exact
# failure this guards, and .gitleaks.toml will block it anyway.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$TMP/sites/demosite/demo-golden-live" "$TMP/private" "$TMP/lib"
  cp "$ROOT/lib/golden-hygiene.sh" "$TMP/lib/"
  cp "$ROOT/lib/todo-checks.sh"    "$TMP/lib/"

  # A minimal nwp.yml declaring one estate domain.
  cat > "$TMP/nwp.yml" <<'YAML'
sites:
  demosite:
    live:
      enabled: true
      domain: demosite.estate-under-test.org
      mail_domain: estate-under-test.org
YAML

  GOLDEN="$TMP/sites/demosite/demo-golden-live"
}

# Build a fake golden DB dump with the given body.
_golden() { printf '%s\n' "$1" | gzip -c > "$GOLDEN/golden.db.sql.gz"; }

_source_lib() { . "$TMP/lib/golden-hygiene.sh"; }

_declared() { _source_lib; golden_hygiene_declared_domains "$TMP/nwp.yml"; }

# Run the todo check against the fixture tree only.
_run_check() {
  bash -c '
    TODO_CHECKS_PROJECT_ROOT="$1"; export TODO_CHECKS_PROJECT_ROOT
    TODO_CONFIG_FILE="$2"; export TODO_CONFIG_FILE
    TODO_CACHE_DIR="$1/cache"; export TODO_CACHE_DIR
    . "$1/lib/todo-checks.sh"
    todo_clear_items
    check_demo_golden_hygiene
    todo_output_items
  ' _ "$TMP" "$TMP/nwp.yml"
}

################################################################################
# Rule 1 — mailbox domains
################################################################################

@test "estate-declared domains are read from nwp.yml, not hardcoded" {
  run _declared
  [ "$status" -eq 0 ]
  [[ "$output" == *"estate-under-test.org"* ]]
  [[ "$output" == *"demosite.estate-under-test.org"* ]]
}

@test "a golden with only sentinel + estate addresses is clean" {
  _golden "INSERT INTO users VALUES ('user1@demo.invalid'),('admin@example.com'),('noreply@demosite.estate-under-test.org');"
  _source_lib
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.db.sql.gz" "$(_declared)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a consumer mailbox in a golden is a foreign domain" {
  _golden "INSERT INTO users VALUES ('person@gmail.com');"
  _source_lib
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.db.sql.gz" "$(_declared)"
  [[ "$output" == *"gmail.com"* ]]
}

@test "any third-party mailbox is a foreign domain, not just consumer webmail" {
  _golden "INSERT INTO settings VALUES ('approver','someone@partner.example.net');"
  _source_lib
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.db.sql.gz" "$(_declared)"
  [[ "$output" == *"partner.example.net"* ]]
}

@test "a subdomain of a declared estate domain is allowed" {
  _golden "INSERT INTO settings VALUES ('mail','bounce.mx.estate-under-test.org');
INSERT INTO u VALUES ('noreply@bounce.mx.estate-under-test.org');"
  _source_lib
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.db.sql.gz" "$(_declared)"
  [ -z "$output" ]
}

@test "contrib placeholder fixtures are exempt as whole addresses, not as domains" {
  # Webform ships test@test.com / random@random.com in webform.settings on every
  # install. They are impersonal, so they must not cry wolf...
  _golden "INSERT INTO config VALUES ('webform.settings','test@test.com, random@random.com');"
  _source_lib
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.db.sql.gz" "$(_declared)"
  [ -z "$output" ]

  # ...but the DOMAIN is not exempt: a different mailbox there is still a finding.
  _golden "INSERT INTO users VALUES ('someone.real@test.com');"
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.db.sql.gz" "$(_declared)"
  [[ "$output" == *"test.com"* ]]
}

@test "the files tarball is scanned too, not just the DB dump" {
  mkdir -p "$TMP/stage"
  printf 'approver_email: person@gmail.com\n' > "$TMP/stage/settings.yml"
  tar -czf "$GOLDEN/golden.files.tar.gz" -C "$TMP/stage" .
  _source_lib
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.files.tar.gz" "$(_declared)"
  [[ "$output" == *"gmail.com"* ]]
}

################################################################################
# Rule 2 — personal names, from an untracked denylist, reported masked
################################################################################

@test "a denylisted name token in a golden is found, case-insensitively" {
  printf '# one token per line\nFamilyname\n' > "$TMP/private/golden-identity-denylist.txt"
  _golden "INSERT INTO mdl_user VALUES (3,'Given','FAMILYNAME');"
  _source_lib
  run golden_hygiene_denylisted_tokens "$GOLDEN/golden.db.sql.gz" "$TMP/private/golden-identity-denylist.txt"
  [ -n "$output" ]
}

@test "the finding masks the token it matched — a leak report must not leak" {
  printf 'Familyname\n' > "$TMP/private/golden-identity-denylist.txt"
  _golden "INSERT INTO mdl_user VALUES (3,'Given','Familyname');"
  _source_lib
  run golden_hygiene_denylisted_tokens "$GOLDEN/golden.db.sql.gz" "$TMP/private/golden-identity-denylist.txt"
  [[ "$output" != *"Familyname"* ]]
  [[ "$output" != *"amilyname"* ]]
  # first character + length only, case-folded
  [[ "$output" == "f"*"(10 chars)"* ]]
}

@test "a golden containing binary payloads is still scanned, not skipped as binary" {
  # A files tarball holds images and nested archives. Without grep --text, GNU
  # grep answers "Binary file matches" and -o prints NOTHING — the check would
  # have silently reported clean on exactly the artifacts most likely to be dirty.
  printf 'Familyname\n' > "$TMP/private/golden-identity-denylist.txt"
  mkdir -p "$TMP/bin"
  head -c 4096 /dev/urandom > "$TMP/bin/blob.dat"
  printf '\x00\x01\x02 Familyname \x00 person@gmail.com\n' > "$TMP/bin/mixed.dat"
  tar -czf "$GOLDEN/golden.files.tar.gz" -C "$TMP/bin" .
  _source_lib
  run golden_hygiene_denylisted_tokens "$GOLDEN/golden.files.tar.gz" "$TMP/private/golden-identity-denylist.txt"
  [ -n "$output" ]
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.files.tar.gz" "$(_declared)"
  [[ "$output" == *"gmail.com"* ]]
}

@test "comments and blank lines in the denylist are ignored" {
  printf '\n# Familyname\n\n' > "$TMP/private/golden-identity-denylist.txt"
  _golden "INSERT INTO mdl_user VALUES (3,'Given','Familyname');"
  _source_lib
  run golden_hygiene_denylisted_tokens "$GOLDEN/golden.db.sql.gz" "$TMP/private/golden-identity-denylist.txt"
  [ -z "$output" ]
}

################################################################################
# Wiring into pl todo / pl rag
################################################################################

@test "a foreign mailbox surfaces as SEC/high — which is what pl rag grades RED" {
  _golden "INSERT INTO users VALUES ('person@gmail.com');"
  run _run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *'"category":"SEC"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"demosite"* ]]
}

@test "a clean golden produces no finding" {
  printf '# none\n' > "$TMP/private/golden-identity-denylist.txt"
  _golden "INSERT INTO users VALUES ('user1@demo.invalid');"
  run _run_check
  [[ "$output" != *'"category":"SEC"'* ]]
}

@test "no denylist is UNKNOWN, not CLEAR — the name half did not run" {
  _golden "INSERT INTO users VALUES ('user1@demo.invalid');"
  run _run_check
  [[ "$output" == *'"category":"UNK"'* ]]
  [[ "$output" == *"golden_identity_names"* ]]
}

@test "the scan is memoised on content — and a recapture invalidates it" {
  printf 'Familyname\n' > "$TMP/private/golden-identity-denylist.txt"
  _source_lib
  _golden "INSERT INTO users VALUES ('person@gmail.com');"

  run golden_hygiene_scan "$GOLDEN/golden.db.sql.gz" "$(_declared)" \
      "$TMP/private/golden-identity-denylist.txt" "$TMP/cache"
  [[ "$output" == *"MAIL gmail.com"* ]]
  [ "$(find "$TMP/cache/golden-hygiene" -type f | wc -l)" -eq 1 ]

  # Same bytes → served from cache, same answer.
  run golden_hygiene_scan "$GOLDEN/golden.db.sql.gz" "$(_declared)" \
      "$TMP/private/golden-identity-denylist.txt" "$TMP/cache"
  [[ "$output" == *"MAIL gmail.com"* ]]
  [ "$(find "$TMP/cache/golden-hygiene" -type f | wc -l)" -eq 1 ]

  # Recaptured clean → different sha256 → rescanned, and the finding clears.
  # A cache that survived a recapture would report yesterday's golden forever.
  _golden "INSERT INTO users VALUES ('user1@demo.invalid');"
  run golden_hygiene_scan "$GOLDEN/golden.db.sql.gz" "$(_declared)" \
      "$TMP/private/golden-identity-denylist.txt" "$TMP/cache"
  [ -z "$output" ]

  # Editing the denylist is also part of the key.
  printf 'demo\n' > "$TMP/private/golden-identity-denylist.txt"
  run golden_hygiene_scan "$GOLDEN/golden.db.sql.gz" "$(_declared)" \
      "$TMP/private/golden-identity-denylist.txt" "$TMP/cache"
  [[ "$output" == "NAME d"*"(4 chars)"* ]]
}

@test "a host with no goldens at all is silent — this is a no-op on CI" {
  rm -f "$GOLDEN/golden.db.sql.gz" "$GOLDEN/golden.files.tar.gz"
  run _run_check
  [[ "$output" != *'"category":"SEC"'* ]]
  [[ "$output" != *'"category":"UNK"'* ]]
}

################################################################################
# The guard must not itself become the leak (P61 / .gitleaks.toml)
################################################################################

@test "no tracked file added by this guard names a person or an estate domain" {
  for f in "$ROOT/lib/golden-hygiene.sh" "$ROOT/tests/unit/test-golden-hygiene.bats"; do
    run grep -nEi '@(gmail|googlemail|hotmail|outlook|yahoo|icloud|proton(mail)?)\.(com|me)' "$f"
    # gmail.com may appear only inside this test's own fictional fixtures.
    if [ "$f" = "$ROOT/lib/golden-hygiene.sh" ]; then [ -z "$output" ]; fi
    run grep -nE '\b(nwpcode|mayostudios)\.org\b' "$f"
    [ -z "$output" ]
  done
}
