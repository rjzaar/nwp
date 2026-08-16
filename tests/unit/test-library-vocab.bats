#!/usr/bin/env bats
# `pl library` — the site vocabulary must contain SITES, and only sites.
#
# WHY THIS FILE EXISTS
# --------------------
# On 2026-08-16 `pl library build` was run against the real tree for the first
# time and REFUSED:
#
#   - docs/overview/saint-school.md: marked public but names site(s) ['hidden']
#     that are not in the manifest's `public_sites` allowlist
#
# The doc names no such site. Line 68 reads "54 courses visible, 1 hidden, with
# no ...". `hidden` entered the site vocabulary because `_site_vocab` unioned in
# every directory name under sites/, and sites/ also holds `hidden`, `latest`,
# `vendor`, `verify-test` and `<site>_moodledata` — leftovers, not sites. The
# library had never been published on either host, and this was why.
#
# WHY THESE ASSERT THE VOCABULARY AND NOT THE BUILD'S EXIT STATUS
# ---------------------------------------------------------------
# The first cut of this file asserted `pl library build` exits 0. That passed
# here and FAILED in CI, and the failure was correct: without a gitleaks binary
# every doc's identity verdict is `unknown`, and unknown never publishes — so
# the build refuses on ANY host that has no gitleaks, for a reason that has
# nothing to do with this fix. That is a host-blind check, the fourth shape
# CLAUDE.md names, and it would have gone quietly green on every developer
# machine while asserting nothing in CI.
#
# So cases 1-4 exercise `_site_vocab` directly: no scanner, no host dependency,
# and they assert the POSITIVE fact (which names are in the vocabulary) rather
# than the absence of one error string. Case 5 keeps the end-to-end build, and
# asserts BOTH host branches explicitly rather than skipping either.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  LIB_CMD="${REPO_ROOT}/scripts/commands/library.sh"
  TEST_TMP=$(mktemp -d)
  FIX="${TEST_TMP}/tree"
  OUT="${TEST_TMP}/out"
  mkdir -p "${FIX}/docs/overview" "${FIX}/docs/guides"

  # A real site (declares itself with .nwp.yml) and the non-sites that actually
  # sit in sites/ on the workstation today.
  mkdir -p "${FIX}/sites/ss"
  printf 'project:\n  name: ss\n' > "${FIX}/sites/ss/.nwp.yml"
  local junk
  for junk in hidden latest vendor verify-test ss_moodledata; do
    mkdir -p "${FIX}/sites/${junk}"
  done

  # One public doc that uses "hidden" and "latest" as ENGLISH, and names exactly
  # one real, allowlisted site. Identity-clean: no operator name, no domain.
  cat > "${FIX}/docs/overview/README.md" <<'MD'
# Overview

The courses live on ss. Of the 54 courses, 53 are visible and 1 is hidden
while it is drafted; readers always see the latest published revision.
MD

  cat > "${FIX}/docs/library-manifest.yml" <<'YML'
schema: nwp.library-manifest
schema_version: 1

public_sites: [ss]

docs:

  - path: docs/overview/README.md
    title: Overview
    audience: public
    summary: What this is.
    sites: [ss]
YML

  # Keep the vocabulary derivation inside the fixture: no real nwp.yml, no real
  # fleet snapshot. NWP_CONSOLE_CONFIG points at a file that does not exist, so
  # _console_cfg_file yields nothing rather than falling back to ~/nwp/nwp.yml.
  export PROJECT_ROOT="${FIX}"
  export NWP_CONSOLE_CONFIG="${TEST_TMP}/no-such-nwp.yml"
  export TEST_TMP FIX OUT REPO_ROOT LIB_CMD
}

teardown() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "${TEST_TMP}"
}

# The vocabulary, as the verb itself computes it. stdout only; the HINT line
# naming dropped entries goes to stderr and is asserted separately.
_vocab() {
  bash -c "source '${LIB_CMD}' help >/dev/null 2>&1; _site_vocab '' '${FIX}' 2>/dev/null"
}
_vocab_stderr() {
  bash -c "source '${LIB_CMD}' help >/dev/null 2>&1; _site_vocab '' '${FIX}' 2>&1 >/dev/null"
}
# Does this host have a usable gitleaks? Asked exactly the way library.sh asks.
_has_gitleaks() {
  bash -c "source '${REPO_ROOT}/tests/helpers/pubrel-docs-check.sh' >/dev/null 2>&1
           b=\$(pubrel_gitleaks_bin 2>/dev/null || true); [ -n \"\$b\" ] && [ -x \"\$b\" ]"
}

@test "a leftover directory under sites/ is not in the site vocabulary" {
  run _vocab
  [ "$status" -eq 0 ]
  # The whole bug: `hidden` was a vocabulary entry, so an English word read as
  # a site name and refused every build.
  [[ ",${output}," != *",hidden,"* ]]
  [[ ",${output}," != *",latest,"* ]]
  [[ ",${output}," != *",vendor,"* ]]
  [[ ",${output}," != *",verify-test,"* ]]
  [[ ",${output}," != *",ss_moodledata,"* ]]
}

@test "the real site IS in the vocabulary — the narrowing did not go blind" {
  run _vocab
  [ "$status" -eq 0 ]
  [[ ",${output}," == *",ss,"* ]]
}

@test "every non-site it drops is named on stderr, not dropped silently" {
  run _vocab_stderr
  [[ "$output" == *"excluded from the site vocabulary"* ]]
  [[ "$output" == *"hidden"* ]]
  [[ "$output" == *"ss_moodledata"* ]]
}

@test "a non-site the FLEET SNAPSHOT calls a site is dropped; an unknown name is KEPT" {
  # Filtering only the sites/*/ glob is not enough: `pl rag` grades sites/hidden
  # and sites/verify-test, so the published snapshot re-injects both names.
  mkdir -p "${FIX}/private/fleet"
  cat > "${FIX}/private/fleet/fleet-state.json" <<'JSON'
{"feeds": {"rag": {"data": {"sites": [
  {"site": "ss"}, {"site": "hidden"}, {"site": "verify-test"}, {"site": "ssc1"}
]}}}}
JSON
  run _vocab
  [ "$status" -eq 0 ]
  [[ ",${output}," != *",hidden,"* ]]
  [[ ",${output}," != *",verify-test,"* ]]
  # ssc1 has no directory here, so this tree cannot disprove it: it must SURVIVE.
  # Absence of evidence may not narrow the scan.
  [[ ",${output}," == *",ssc1,"* ]]
}

@test "a site declared only in nwp.yml (no local .nwp.yml) is KEPT" {
  # `mg` is real on the workstation and has no sites/mg/.nwp.yml. Without this
  # clause a real site would be dropped from the scan — the blindness the whole
  # check exists to prevent.
  mkdir -p "${FIX}/sites/mg"
  printf 'sites:\n  ss: {}\n  mg: {}\n' > "${TEST_TMP}/nwp.yml"
  export NWP_CONSOLE_CONFIG="${TEST_TMP}/nwp.yml"
  run _vocab
  [ "$status" -eq 0 ]
  [[ ",${output}," != *",hidden,"* ]]

  # The nwp.yml source is read with yq. Branch on it explicitly rather than
  # leave a second host-blind assertion: with yq the declaration is read and
  # `mg` survives; without it the verb genuinely cannot read nwp.yml, so `mg`
  # is dropped and this test says so out loud instead of going quietly green.
  if command -v yq >/dev/null 2>&1; then
    [[ ",${output}," == *",mg,"* ]]
  else
    [[ ",${output}," != *",mg,"* ]]
  fi
}

@test "the end-to-end build no longer refuses over the word 'hidden' (both host branches)" {
  run bash "$LIB_CMD" build --root "$FIX" \
       --manifest "${FIX}/docs/library-manifest.yml" --out "$OUT" 2>&1

  # Asserted on EVERY host: whatever else happens, no build may be refused for
  # naming a site called `hidden`.
  [[ "$output" != *"['hidden']"* ]]

  if _has_gitleaks; then
    # Scanner present: the docs certify clean and the bundle is written.
    [ "$status" -eq 0 ]
    [ -f "${OUT}/library.json" ]
    [ -f "${OUT}/library-public.json" ]
  else
    # No scanner: every verdict is `unknown`, and unknown never publishes. The
    # build MUST still refuse — asserted, not skipped, so the fail-closed path
    # is exercised rather than assumed.
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSED"* ]]
    [ ! -f "${OUT}/library.json" ]
  fi
}

@test "an empty vocabulary still refuses the build" {
  rm -rf "${FIX}/sites"
  run bash "$LIB_CMD" build --root "$FIX" \
       --manifest "${FIX}/docs/library-manifest.yml" --out "$OUT" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* || "$output" == *"vocabulary"* ]]
}
