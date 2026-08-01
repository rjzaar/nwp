#!/usr/bin/env bats
# scripts/demo/ssd-seed-courses.php — schema contract with mod_depthcontent's reader.
#
# WHY THIS EXISTS: in 2026-08 all 3 ssd demo courses rendered EMPTY and then
# FATAL for testers. The seeder wrote content_json in a shape the module never
# reads: depths as bare strings (view.php:352-366 reads $ddata['summary'/'text']
# from an object — a bare string renders no section, blank page) and quiz
# options as bare strings (view.php:533 reads $opt['correct'] unguarded — a
# PHP 8 TypeError, fatal page). And because the seeder skipped every existing
# row, the broken rows were baked into the golden image; --check passed them.
#
# The seeder now carries a validator derived from the reader code plus two
# standalone modes that run WITHOUT Moodle:
#   --validate-file=<json>   validate one content_json (exit 0/1)
#   --schema-selftest        every catalogue entry the builder emits must
#                            pass the validator (the idempotency property)
#
# Fixtures (tests/fixtures/depthcontent/):
#   content-old-broken-shape.json  exactly what the pre-fix seeder wrote for
#                                  demo_prayer — MUST fail
#   content-prod-b1-lp01.json      extracted from a real production course
#                                  backup (sites/ss/backups/course-mbz-2026-07-11/
#                                  backup-moodle2-course-10-b1-*.mbz,
#                                  activities/depthcontent_79 content_json;
#                                  prose truncated, structure/keys/types
#                                  unchanged) — MUST pass

setup() {
  PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  SEEDER="$PROJECT_ROOT/scripts/demo/ssd-seed-courses.php"
  WRAPPER="$PROJECT_ROOT/scripts/demo/ssd-seed-courses.sh"
  FIXTURES="$PROJECT_ROOT/tests/fixtures/depthcontent"
}

# Fail closed when php is missing (same rationale as test-auth-logic.bats:
# a skip reports `ok`, and that is how schema tests silently vanish on an
# under-provisioned runner). NWP_ALLOW_MISSING_PHP=1 downgrades to a skip.
require_php() {
  if command -v php >/dev/null 2>&1; then return 0; fi
  if [ "${NWP_ALLOW_MISSING_PHP:-0}" = "1" ]; then
    skip "php-cli absent and NWP_ALLOW_MISSING_PHP=1 was set deliberately"
  fi
  echo "php-cli is NOT installed on this runner; this test FAILS rather than reporting 'ok'." >&2
  return 1
}

@test "ssd-seed-courses.php: php -l clean" {
  require_php
  run php -l "$SEEDER"
  [ "$status" -eq 0 ]
}

@test "ssd-seed-courses.sh: bash -n clean" {
  run bash -n "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "validator FAILS the old broken shape (bare-string depths + options)" {
  require_php
  run php "$SEEDER" --validate-file="$FIXTURES/content-old-broken-shape.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SCHEMA-FAIL"* ]]
  # Both defects must be named: the blank-page one and the fatal one.
  [[ "$output" == *"depths.standard: bare string"* ]]
  [[ "$output" == *"options[0]: bare string"* ]]
  [[ "$output" == *"TypeError"* ]]
}

@test "validator PASSES a real prod-mbz content_json" {
  require_php
  run php "$SEEDER" --validate-file="$FIXTURES/content-prod-b1-lp01.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCHEMA-OK"* ]]
}

@test "validator flags a structured option that lacks the 'correct' key" {
  require_php
  tmp="$(mktemp)"
  cat > "$tmp" <<'JSON'
{"depths":{"standard":{"text":"body"}},
 "quiz_items":[{"id":"q1","type":"multichoice","question":"Q?",
   "options":[{"text":"A"},{"text":"B","correct":true}]}],
 "practice":null}
JSON
  run php "$SEEDER" --validate-file="$tmp"
  rm -f "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"options[0].correct: missing"* ]]
}

@test "validator flags a quiz with no correct option at all" {
  require_php
  tmp="$(mktemp)"
  cat > "$tmp" <<'JSON'
{"depths":{"standard":{"text":"body"}},
 "quiz_items":[{"id":"q1","type":"multichoice","question":"Q?",
   "options":[{"text":"A","correct":false},{"text":"B","correct":false}]}],
 "practice":null}
JSON
  run php "$SEEDER" --validate-file="$tmp"
  rm -f "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no option marked correct"* ]]
}

@test "validator flags empty depths (the blank-page state)" {
  require_php
  tmp="$(mktemp)"
  printf '{"depths":{},"quiz_items":[],"practice":null}' > "$tmp"
  run php "$SEEDER" --validate-file="$tmp"
  rm -f "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"depths: missing or empty"* ]]
}

@test "schema-selftest: every built catalogue entry passes the validator (all 3 courses, all 6 depth levels)" {
  require_php
  run php "$SEEDER" --schema-selftest
  [ "$status" -eq 0 ]
  [[ "$output" != *"SELFTEST-FAIL"* ]]
  # All three demo courses, each carrying all six depth levels
  # (short|standard|longer|detailed|advanced|scholar per lib.php:65-73).
  ok_count="$(grep -c 'SELFTEST-OK' <<< "$output")"
  [ "$ok_count" -eq 3 ]
  depth6_count="$(grep -c 'depths=6' <<< "$output")"
  [ "$depth6_count" -eq 3 ]
}

@test "builder is deterministic: two runs byte-identical (a correct row is untouched on reseed)" {
  require_php
  a="$(php "$SEEDER" --schema-selftest)"
  b="$(php "$SEEDER" --schema-selftest)"
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

@test "seeder sets completion the way the 55 prod courses do (enablecompletion=1, cm tracking automatic+view)" {
  # Static pin for the DB-level fix a unit test cannot execute: the course is
  # created/repaired with enablecompletion=1 and the module tracked with
  # COMPLETION_TRACKING_AUTOMATIC + completionview=1, matching prod mbz
  # course.xml/module.xml. Without these, tester progress can never move.
  grep -q "'enablecompletion' => 1" "$SEEDER"
  grep -q "'completion' => COMPLETION_TRACKING_AUTOMATIC" "$SEEDER"
  grep -q "'completionview' => 1" "$SEEDER"
  grep -q "set_field('course', 'enablecompletion', 1" "$SEEDER"
}

@test "--check validates schema (would have caught the 2026-08 broken golden)" {
  # The old --check only tested record_exists and passed schema-broken rows.
  grep -q 'ssd_seed_validate_content_json((string) $dc->content_json)' "$SEEDER"
  grep -q 'bad-schema' "$SEEDER"
}

@test "seed loop self-repairs an invalid existing row instead of skipping it" {
  # The old loop was `if (!$dc) { insert } // else nothing` — a broken row
  # could never be reseeded out of the golden. Pin the repair branch.
  grep -q 'update_record' "$SEEDER"
  grep -q 'repaired activity content_json' "$SEEDER"
}
