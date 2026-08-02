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

@test "a package version string is not a mailbox — no TLD is all-digits" {
  # Warm Drupal cache tables are full of CDN library refs shaped like an
  # address. Before this, a recapture of nwd reported three "foreign mail
  # domains" (v17.0.19, v2.0.7, v2.3.0) on every single scan — and a guard
  # that cries wolf nightly is a guard that gets switched off.
  _golden "INSERT INTO cache_default VALUES ('intl-tel-input@v17.0.19','signature_pad@v2.3.0','progress-tracker@v2.0.7','mathjax@2.7.9');"
  _source_lib
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.db.sql.gz" "$(_declared)"
  [ -z "$output" ]
}

@test "the version-string exemption does not blind the check to a real domain" {
  _golden "INSERT INTO c VALUES ('intl-tel-input@v17.0.19','person@gmail.com');"
  _source_lib
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.db.sql.gz" "$(_declared)"
  [[ "$output" == *"gmail.com"* ]]
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
# Rule 3 — orphaned consent, the fingerprint of the WRONG remedy
#
# nwp/ops#200: an identity scrub found the operator's mailbox in an OLD
# data_policy revision and DELETED the revision. The published text was already
# clean, so nothing user-facing changed — but a user_consent row cited that
# revision, and a consent record whose referent no longer exists cannot show
# what the person agreed to. Operator ruling: redact as a revision, never
# delete. Rule 3 makes the deletion visible instead of silent.
################################################################################

# A data_policy fixture. $1 = space-separated vids that still EXIST,
# $2 = space-separated vids that consent rows CITE.
_policy_golden() {
  { echo 'INSERT INTO `data_policy_revision` VALUES'
    local first=1 v
    for v in $1; do
      [ $first -eq 1 ] && first=0 || echo ','
      printf "(%s,%s,'en',0,1784943141,'v1 initial — operator-drafted; pre-counsel',1)" "$v" "$v"
    done
    echo ';'
    echo 'INSERT INTO `user_consent__data_policy_revision_id` VALUES'
    first=1; local i=0
    for v in $2; do
      i=$((i+1))
      [ $first -eq 1 ] && first=0 || echo ','
      printf "('user_consent',0,%s,%s,'en',0,%s)" "$i" "$i" "$v"
    done
    echo ';'
  } | gzip -c > "$GOLDEN/golden.db.sql.gz"
}

@test "a consent row citing a deleted revision is reported as an orphan" {
  _policy_golden "1 3 4 5 6 7" "5 5 5 1 2 3 4 5 1 6 3 4 7"   # vid 2 deleted
  _source_lib
  run golden_hygiene_orphaned_consents "$GOLDEN/golden.db.sql.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "2 1" ]      # revision 2 missing, cited by 1 consent row
}

@test "orphan counting reports how many consent rows each deleted revision cost" {
  _policy_golden "1 3" "1 2 2 2 3 3"
  _source_lib
  run golden_hygiene_orphaned_consents "$GOLDEN/golden.db.sql.gz"
  [ "$output" = "2 3" ]
}

@test "a golden with every cited revision present is clean" {
  _policy_golden "1 2 3 4 5 6 7" "5 5 5 1 2 3 4 5 1 6 3 4 7"
  _source_lib
  run golden_hygiene_orphaned_consents "$GOLDEN/golden.db.sql.gz"
  [ -z "$output" ]
}

@test "restoring the deleted revision — redacted, at its own vid — clears the finding" {
  # The whole point of the ops#200 ruling: the repair is to put the revision
  # BACK (redacted), not to renumber it or to repoint the consent record.
  _policy_golden "1 3 4 5 6 7" "1 2 3"
  _source_lib
  run golden_hygiene_orphaned_consents "$GOLDEN/golden.db.sql.gz"
  [ "$output" = "2 1" ]
  _policy_golden "1 2 3 4 5 6 7" "1 2 3"
  run golden_hygiene_orphaned_consents "$GOLDEN/golden.db.sql.gz"
  [ -z "$output" ]
}

@test "a golden with no data_policy at all is silent, not all-orphaned" {
  # Every Moodle golden looks like this. Failing loud here would put a
  # permanent false RED on half the fleet and get the check disabled.
  _golden "INSERT INTO mdl_user VALUES (3,'Given','Family');"
  _source_lib
  run golden_hygiene_orphaned_consents "$GOLDEN/golden.db.sql.gz"
  [ -z "$output" ]
}

@test "consent rows but no revision table is silent too — cannot conclude deletion" {
  { echo 'INSERT INTO `user_consent__data_policy_revision_id` VALUES'
    echo "('user_consent',0,1,1,'en',0,4);"
  } | gzip -c > "$GOLDEN/golden.db.sql.gz"
  _source_lib
  run golden_hygiene_orphaned_consents "$GOLDEN/golden.db.sql.gz"
  [ -z "$output" ]
}

@test "an orphan surfaces as SEC/high — pl rag must grade this RED" {
  printf '# none\n' > "$TMP/private/golden-identity-denylist.txt"
  _policy_golden "1 3" "1 2 3"
  run _run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *'"category":"SEC"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"-orphan"* ]]
}

@test "the orphan finding says the remedy is redact-not-delete, and that recapture will not fix it" {
  printf '# none\n' > "$TMP/private/golden-identity-denylist.txt"
  _policy_golden "1 3" "1 2 3"
  run _run_check
  [[ "$output" == *"REDACT, NEVER DELETE"* ]]
  [[ "$output" == *"ops#200"* ]]
  [[ "$output" == *"ORIGINAL vid"* ]]
}

@test "the PII findings carry the remedy too — the guard must say what to do, not just what is wrong" {
  # A guard that reports "there is a personal mailbox in your golden" and stops
  # is what produced the deletion in the first place.
  _golden "INSERT INTO users VALUES ('person@gmail.com');"
  run _run_check
  [[ "$output" == *"REDACT, NEVER DELETE"* ]]
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
# RULE 3 — the demo SEED FENCE must hold INSIDE the golden (ops#213)
#
# Defect this locks down: on 2026-08-01 an account (uid 19, demo_applicant) was
# created on live nwd with an `@nwd.example` address. `.example` is RFC 2606
# reserved, so RULE 1 above passes it — it is not a privacy leak. But
# NwcPrivacyDemoCommands::guardAgainstRealMembers() fences the demo tier on the
# NARROWER `@demo.invalid`, and treats any uid>1 off that domain as "a real
# member", refusing to seed. The nightly recapture baked the account into the
# golden, and servers/live/demo/nwd-demo-reset-restricted runs
# `drush nwc:seed-demo` fail-CLOSED — so the next restore would have aborted the
# whole reset, then retried hourly to the 04:00 floor and failed every time.
#
# A golden that cannot be reset FROM is a booby-trapped golden. Nothing looked.
# This is the looking: the property is asserted BEFORE a golden is accepted.
################################################################################

# Build a fake golden carrying a real-shaped users_field_data INSERT.
# Args: one "uid|name|mail" triple per argument.
_users_golden() {
  local body='INSERT INTO `users_field_data` VALUES' first=1 row uid name mail
  for row in "$@"; do
    IFS='|' read -r uid name mail <<< "$row"
    [ "$first" -eq 1 ] && first=0 || body+=','
    body+=$'\n'"($uid,'en','en',NULL,'$name','\$2y\$10\$abc','$mail','UTC',1,1753000000,1753000000,0,0,'$mail',1)"
  done
  printf '%s;\n' "$body" | gzip -c > "$GOLDEN/golden.db.sql.gz"
}

@test "fence: a golden whose accounts are all on @demo.invalid is clean" {
  _users_golden "1|admin|admin@example.com" \
                "12|nwcdemo_consenting|nwcdemo_consenting@demo.invalid" \
                "17|Sebastian-1572|user1572@demo.invalid"
  _source_lib
  run golden_demo_fence_violations "$GOLDEN/golden.db.sql.gz"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fence: an account above uid 1 off @demo.invalid is a violation" {
  _users_golden "1|admin|admin@example.com" \
                "19|demo_applicant|applicant@nwd.example"
  _source_lib
  run golden_demo_fence_violations "$GOLDEN/golden.db.sql.gz"
  [[ "$output" == *"uid=19"* ]]
  [[ "$output" == *"nwd.example"* ]]
}

@test "fence: THE ops#213 CASE — .example passes RULE 1 but still breaks the seeder" {
  _users_golden "19|demo_applicant|applicant@nwd.example"
  _source_lib
  # RULE 1 is silent: .example is an RFC 2606 sentinel, so this is NOT a leak…
  run golden_hygiene_foreign_mail_domains "$GOLDEN/golden.db.sql.gz" "$(_declared)"
  [ -z "$output" ]
  # …and yet the reset would die. That gap is the whole point of RULE 3.
  run golden_demo_fence_violations "$GOLDEN/golden.db.sql.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uid=19"* ]]
}

@test "fence: uid 1 is ignored, exactly as guardAgainstRealMembers() ignores it" {
  # The seeder's query is ->condition('uid', 1, '>'). Root's address is
  # therefore irrelevant to whether a reset can proceed; flagging it would be a
  # false positive that trains the operator to ignore this check.
  _users_golden "0|| " "1|admin|admin@example.com" \
                "12|nwcdemo_consenting|nwcdemo_consenting@demo.invalid"
  _source_lib
  run golden_demo_fence_violations "$GOLDEN/golden.db.sql.gz"
  [ -z "$output" ]
}

@test "fence: the finding never republishes the mailbox — local-part is masked" {
  _users_golden "19|demo_applicant|applicant@nwd.example"
  _source_lib
  run golden_demo_fence_violations "$GOLDEN/golden.db.sql.gz"
  [ "$status" -eq 0 ]
  # The finding must be actionable…
  [[ "$output" == *"uid=19"* && "$output" == *"nwd.example"* ]]
  # …without republishing the address. Same discipline as RULE 1/2.
  [[ "$output" != *"applicant@"* ]]
}

@test "fence: a deliberate exemption can be declared, and is honoured" {
  _users_golden "19|demo_applicant|applicant@nwd.example"
  _source_lib
  run golden_demo_fence_violations "$GOLDEN/golden.db.sql.gz" "applicant@nwd.example"
  [ -z "$output" ]
}

@test "fence: an exemption is exact — it does not blanket the whole domain" {
  _users_golden "19|demo_applicant|applicant@nwd.example" \
                "20|someone_else|other@nwd.example"
  _source_lib
  run golden_demo_fence_violations "$GOLDEN/golden.db.sql.gz" "applicant@nwd.example"
  [[ "$output" == *"uid=20"* ]]
  [[ "$output" != *"uid=19"* ]]
}

@test "fence: a golden with no users table at all is silent, not a false positive" {
  _golden "INSERT INTO config VALUES ('system.site','mail@demo.invalid');"
  _source_lib
  run golden_demo_fence_violations "$GOLDEN/golden.db.sql.gz"
  [ -z "$output" ]
}

@test "fence: a violation surfaces through the scan as a FENCE line" {
  _users_golden "19|demo_applicant|applicant@nwd.example"
  _source_lib
  run golden_hygiene_scan "$GOLDEN/golden.db.sql.gz" "$(_declared)" \
      "$TMP/private/none.txt" "$TMP/cache"
  [[ "$output" == *"FENCE uid=19"* ]]
}

@test "fence: adding a rule invalidates old cache entries (ruleset version)" {
  # A cache keyed only on CONTENT would serve a pre-RULE-3 verdict for an
  # unchanged golden forever — stale-NEGATIVE, the one direction the cache
  # contract forbids. The ruleset version must be part of the key.
  _users_golden "19|demo_applicant|applicant@nwd.example"
  _source_lib
  run golden_hygiene_scan "$GOLDEN/golden.db.sql.gz" "$(_declared)" \
      "$TMP/private/none.txt" "$TMP/cache"
  [[ "$output" == *"FENCE"* ]]

  local before after
  before="$(find "$TMP/cache/golden-hygiene" -type f | head -1)"
  GOLDEN_HYGIENE_RULESET_VERSION="$(( GOLDEN_HYGIENE_RULESET_VERSION + 1 ))"
  run golden_hygiene_scan "$GOLDEN/golden.db.sql.gz" "$(_declared)" \
      "$TMP/private/none.txt" "$TMP/cache"
  after="$(find "$TMP/cache/golden-hygiene" -type f | wc -l)"
  [ "$after" -eq 2 ]
  [ -n "$before" ]
}

@test "fence: a violation surfaces as SEC/high — pl rag grades that RED" {
  _users_golden "19|demo_applicant|applicant@nwd.example"
  run _run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *'"category":"SEC"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"seed-demo"* ]]
}

@test "fence: a clean golden raises no fence finding" {
  _users_golden "1|admin|admin@example.com" \
                "12|nwcdemo_consenting|nwcdemo_consenting@demo.invalid"
  run _run_check
  [[ "$output" != *"goldenfence"* ]]
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
