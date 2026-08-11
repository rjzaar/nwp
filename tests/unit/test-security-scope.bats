#!/usr/bin/env bats
# `pl security update` must be able to update EXACTLY the packages that carry an
# advisory — and must refuse to guess when it could not read the advisories.
#
# WHY (2026-08-11). The only update path was:
#
#     ddev composer update "drupal/*" "guzzlehttp/*" --with-dependencies
#
# Two problems, and the second is the dangerous one:
#
#   1. SCOPE. That moves every Drupal package on the site, vulnerable or not, to
#      clear (on mayo) 6 packages. On a site imported from a live server that is
#      a far larger blast radius than the finding justifies, and it is the
#      "blanket update" the operator's standing instruction rules out.
#
#   2. COVERAGE THAT LOOKS LIKE SCOPE. The two globs are a HARDCODED GUESS at
#      where advisories live. mayo's real advisory set included
#      webonyx/graphql-php — neither drupal/* nor guzzlehttp/* — so the command
#      would have run, exited 0, and left an advisory it never had any way to
#      reach. The comment above it even records this being patched once before,
#      by adding guzzlehttp/* after Guzzle advisories were missed. A list that
#      has to be extended every time reality surprises it is not a scope, it is
#      a memory of past surprises.
#
# CONTRACT: the package list is DERIVED from `composer audit --format=json`, so
# it cannot miss an ecosystem nobody thought of. And if that measurement cannot
# be read, the command exits 2 CANNOT VERIFY — it must never degrade to "no
# packages found, nothing to do", which is the swallowed-verdict shape: an empty
# list is indistinguishable from success while leaving every advisory in place.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  load_lib() { source "$ROOT/lib/security-scope.sh"; }
}

@test "derives the package list from real composer audit JSON (incl. non-drupal, non-guzzle)" {
  load_lib
  run security_advisory_packages < <(cat <<'JSON'
{"advisories":{
  "drupal/core":[{"advisoryId":"a"},{"advisoryId":"b"}],
  "guzzlehttp/guzzle":[{"advisoryId":"c"}],
  "webonyx/graphql-php":[{"advisoryId":"d"}],
  "drupal/paragraphs":[{"advisoryId":"e"}]}}
JSON
)
  [ "$status" -eq 0 ]
  echo "$output"
  # THE regression this locks: the package the old globs could never reach.
  [[ "$output" == *"webonyx/graphql-php"* ]]
  [[ "$output" == *"drupal/core"* ]]
  [[ "$output" == *"guzzlehttp/guzzle"* ]]
  [ "$(echo "$output" | wc -l)" -eq 4 ]
}

@test "the old hardcoded globs would have MISSED webonyx/graphql-php — proof the guess was a guess" {
  # Not a test of our code; a test of the claim in the header, so the next
  # reader does not have to take it on trust.
  run bash -c 'case "webonyx/graphql-php" in drupal/*|guzzlehttp/*) echo REACHED ;; *) echo MISSED ;; esac'
  [ "$output" = "MISSED" ]
}

@test "no advisories: empty list, exit 0 — but only from a document we could read" {
  load_lib
  run security_advisory_packages <<< '{"advisories":{}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "FAIL-CLOSED: unparseable audit output exits 2 CANNOT VERIFY, not 0/empty" {
  load_lib
  run security_advisory_packages <<< 'this is not json at all'
  echo "status=$status output=$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "FAIL-CLOSED: the REAL ddev failure text exits 2, not 'nothing to update'" {
  # This is verbatim the shape ddev emits when composer exits 3 on findings and
  # the wrapper reports failure — the exact input that would have turned a site
  # full of advisories into a silent no-op.
  load_lib
  run security_advisory_packages <<'EOF'
Failed to run composer audit --locked: exit status 3
Found 15 security vulnerability advisories affecting 6 packages:
EOF
  echo "status=$status output=$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "FAIL-CLOSED: valid JSON with no 'advisories' key at all exits 2, not 0" {
  # A schema change upstream must surface as "I no longer understand this",
  # never as "clean". Note {} is valid JSON — parseability is not enough.
  load_lib
  run security_advisory_packages <<< '{}'
  echo "status=$status output=$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "FAIL-CLOSED: empty input exits 2" {
  load_lib
  run security_advisory_packages <<< ''
  [ "$status" -eq 2 ]
}

@test "package names are shell-safe: anything odd is refused rather than passed to composer" {
  # The list is interpolated into a composer command line. A name that is not a
  # plain vendor/package must not reach it.
  load_lib
  run security_advisory_packages <<< '{"advisories":{"evil; rm -rf /":[{"advisoryId":"x"}]}}'
  echo "status=$status output=$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing"* ]] || [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "pl security update accepts --advisories-only (the flag exists at all)" {
  run "$ROOT/pl" security update --advisories-only --help
  echo "$output"
  # getopt prints this to stderr and exits nonzero for an unknown long option.
  [[ "$output" != *"unrecognized option"* ]]
  [[ "$output" != *"unrecognised option"* ]]
}

@test "pl security --help documents the scoped mode" {
  run "$ROOT/pl" security --help
  [[ "$output" == *"--advisories-only"* ]]
}

################################################################################
# Root pinners — naming the advisory package is not enough to move it
################################################################################
# THE DEFECT (mayo, 2026-08-11): `composer update drupal/core --with-dependencies`
# printed "Nothing to modify in lock file" and EXITED 0. The advisory count stayed
# at 15. drupal/core is pinned to an exact version by drupal/core-recommended, a
# ROOT requirement, which composer will not touch unless it is named. A scoped
# update that cannot move the thing it scoped to is worse than no scoped update:
# it succeeds, silently, forever.

@test "root pinners: finds the metapackage that pins the advisory package" {
  load_lib
  cat > "$BATS_TEST_TMPDIR/composer.json" <<'JSON'
{"require":{"drupal/core-recommended":"^10.5","drupal/core-composer-scaffold":"^10.5","php":">=8.1"}}
JSON
  run security_root_pinners "$BATS_TEST_TMPDIR" <<'WHY'
drupal/address                    2.0.4        requires  drupal/core (^9.5 || ^10 || ^11)
drupal/core-recommended           10.6.12      requires  drupal/core (10.6.12)
drupal/admin_toolbar              3.6.2        requires  drupal/core (^9.5 || ^10 || ^11)
WHY
  echo "status=$status output=$output"
  [ "$status" -eq 0 ]
  [ "$output" = "drupal/core-recommended" ]
}

@test "root pinners: a requirer that is NOT a root requirement is not added" {
  # Otherwise a scoped update quietly grows to the whole dependency graph —
  # drupal/core has ~200 requirers on a real site.
  load_lib
  echo '{"require":{"drupal/core-recommended":"^10.5"}}' > "$BATS_TEST_TMPDIR/composer.json"
  run security_root_pinners "$BATS_TEST_TMPDIR" <<'WHY'
drupal/address     2.0.4   requires  drupal/core (^9.5)
drupal/admin_toolbar 3.6.2 requires  drupal/core (^9.5)
WHY
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "root pinners FAIL-CLOSED: unreadable composer.json exits 2, not 'no pinners'" {
  load_lib
  run security_root_pinners "$BATS_TEST_TMPDIR/nonexistent-dir"
  echo "status=$status output=$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "root pinners FAIL-CLOSED: a composer.json with no require block exits 2" {
  load_lib
  echo '{"name":"x/y"}' > "$BATS_TEST_TMPDIR/composer.json"
  run security_root_pinners "$BATS_TEST_TMPDIR" <<< ''
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "the scoped update passes -W, without which a pinned package cannot move" {
  # Guards the exact regression: --with-dependencies leaves root requirements
  # locked, so the resolved pinners would be named and still ignored.
  run grep -n 'ddev composer update "${pkg_args\[@\]}" -W' "$ROOT/scripts/commands/security.sh"
  [ "$status" -eq 0 ]
  run grep -c 'ddev composer update "${pkg_args\[@\]}" --with-dependencies' "$ROOT/scripts/commands/security.sh"
  [ "$output" = "0" ]
}

@test "root pinners: ONLY exact pins count — a flexible root requirement is not a blocker" {
  # The first cut of this rule added any root requirement that required the
  # advisory package. On mayo that grew a 6-package scoped update to 17 and
  # dragged in drupal/webform 6.2.10 => 6.3.0 to fix a Guzzle advisory — the
  # blanket update coming back in through the pinner resolver.
  load_lib
  cat > "$BATS_TEST_TMPDIR/composer.json" <<'JSON'
{"require":{"drupal/core-recommended":"^10.5","drupal/webform":"^6.2","nwp/avc":"^0.3"}}
JSON
  run security_root_pinners "$BATS_TEST_TMPDIR" <<'WHY'
drupal/core-recommended  10.6.12 requires  drupal/core (10.6.12)
drupal/webform           6.2.10  requires  drupal/core (^10.2 || ^11)
nwp/avc                  0.3.1   requires  drupal/core (^10)
WHY
  echo "status=$status output=$output"
  [ "$status" -eq 0 ]
  # Exact pin blocks; the two range constraints already admit the fix.
  [ "$output" = "drupal/core-recommended" ]
}

@test "root pinners: an exact pre-release pin (3.0.0-beta4) is still an exact pin" {
  load_lib
  echo '{"require":{"nwp/avc":"^0.3"}}' > "$BATS_TEST_TMPDIR/composer.json"
  run security_root_pinners "$BATS_TEST_TMPDIR" <<'WHY'
nwp/avc 0.3.1 requires drupal/ginvite (3.0.0-beta4)
WHY
  [ "$status" -eq 0 ]
  [ "$output" = "nwp/avc" ]
}
