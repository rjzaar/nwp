#!/usr/bin/env bats
# P74 Phase 1 + item 7 — the boundary manifest-honesty test.
#
# The pair contract's `boundary:` block declares, per surface, a set of PRIVATE
# provider_symbols and the paths they may live in. The check fails if such a
# symbol is referenced (in NON-COMMENT production code, outside `tests/` dirs)
# from a file OUTSIDE that surface's declared paths — i.e. a boundary symbol
# grew a new cross-module tentacle the manifest doesn't know about.
#
# WHAT ITEM 7 CHANGED, AND WHY
#
# 1. VACUITY. The previous version of this file carried the sentence "In nwp CI
#    `sites/*` is gitignored so the nwc profile is absent and the check is
#    trivially clean" — and then asserted clean anyway. Ten of the eleven
#    provider symbols live in that absent profile, so CI was asserting a
#    security contract it could not see. Measured 2026-07-26: the identical
#    check reported 0 violations in CI and 11 on a workstation. `pl impact
#    --honesty` now distinguishes VERIFIED CLEAN (exit 0) from CANNOT VERIFY
#    (exit 2), and the corpus is asserted separately from the verdict.
#
# 2. NOISE. Those 11 "violations" were investigated and ALL 11 WERE FALSE
#    POSITIVES — every one was `sites/nwc/stg`, the byte-identical environment
#    twin of the declared `sites/nwc/dev` tree, pulled in because the scan root
#    was truncated to two path components (`sites/nwc`). Fixed in
#    boundary_scan_root_depth. A detector wrong 11 times out of 11 is how the
#    12th, real, finding gets ignored.
#
# 3. PORTABILITY. The cases below run against a SYNTHETIC fixture tree, so the
#    detector's behaviour is proven identically on a workstation and on a CI
#    runner with no sites/ at all. Cases that depend on the real profile being
#    checked out would silently degrade to "skip", which is the same disease.

setup() {
    REAL_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    FIX="${BATS_TEST_TMPDIR}/fixroot"
    mkdir -p "$FIX/pairs"
}

# Build a fixture PROJECT_ROOT with one declared surface, then source the libs
# against it. Callers add files before invoking the check.
_fixture_contract() {
    cat > "$FIX/pairs/px.pair-contract.yml" <<'YML'
pair_id: px
boundary:
  probe_surface:
    provider_paths:
      - sites/px/dev/modules/alpha/**
    consumer_paths:
      - moodle/local/px/**
    provider_symbols:
      - ProbeOnlySymbol
YML
}

_load_libs() {
    export PROJECT_ROOT="$FIX"
    export NWP_PAIR_CONTRACT_DIR="$FIX/pairs"
    source "${REAL_ROOT}/lib/impact.sh"
    source "${REAL_ROOT}/lib/boundary.sh"
    CONTRACT="$FIX/pairs/px.pair-contract.yml"
}

# ---------------------------------------------------------------------------
# Contract shape (real contract)
# ---------------------------------------------------------------------------

@test "every declared surface has at least one provider_symbol and one path" {
    export PROJECT_ROOT="$REAL_ROOT"
    export NWP_PAIR_CONTRACT_DIR="${REAL_ROOT}/pairs"
    source "${REAL_ROOT}/lib/impact.sh"
    source "${REAL_ROOT}/lib/boundary.sh"
    local c="${REAL_ROOT}/pairs/ssd.pair-contract.yml"   # ops#326: the shipped sample pair
    local surface n=0
    while IFS= read -r surface; do
        [ -n "$surface" ] || continue
        n=$((n + 1))
        [ -n "$(boundary_symbols "$surface" "$c")" ] || {
            echo "surface '$surface' has no provider_symbols"; return 1; }
        [ -n "$(boundary_paths "$surface" "$c")" ] || {
            echo "surface '$surface' has no paths"; return 1; }
    done < <(boundary_surfaces "$c")
    # The loop above is vacuously true over zero surfaces — assert the corpus.
    [ "$n" -ge 5 ]
}

# ---------------------------------------------------------------------------
# THE ITEM-7 CASE: an absent corpus must report CANNOT VERIFY, never clean
# ---------------------------------------------------------------------------

@test "CANNOT VERIFY: a surface whose provider tree is absent is not 'clean'" {
    # RED before item 7: boundary_honesty_violations returned empty and the
    # suite asserted clean — exactly the CI condition, where sites/* is
    # gitignored and the nwc profile does not exist.
    _fixture_contract
    _load_libs
    run boundary_honesty_check "$CONTRACT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNVERIFIABLE"* ]]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    [[ "$output" != *"VERIFIED CLEAN"* ]]
}

@test "CANNOT VERIFY: a contract declaring no surfaces at all fails closed" {
    printf 'pair_id: px\nboundary: {}\n' > "$FIX/pairs/px.pair-contract.yml"
    _load_libs
    run boundary_honesty_check "$CONTRACT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "VERIFIED CLEAN is reachable, and says so distinctly" {
    _fixture_contract
    mkdir -p "$FIX/sites/px/dev/modules/alpha"
    cat > "$FIX/sites/px/dev/modules/alpha/alpha.php" <<'PHP'
<?php
class ProbeOnlySymbol {}
PHP
    _load_libs
    run boundary_honesty_check "$CONTRACT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERIFIED CLEAN"* ]]
}

# ---------------------------------------------------------------------------
# The detector still detects — proven on the fixture, not on the real profile
# ---------------------------------------------------------------------------

@test "DETECTOR: a sibling module in the SAME checkout referencing the symbol is a VIOLATION" {
    # This is the edge the check exists for, and it is the one the scan-root
    # fix must not blind: same environment checkout, different module.
    _fixture_contract
    mkdir -p "$FIX/sites/px/dev/modules/alpha" "$FIX/sites/px/dev/modules/beta"
    printf '<?php\nclass ProbeOnlySymbol {}\n' > "$FIX/sites/px/dev/modules/alpha/alpha.php"
    printf '<?php\n$x = new ProbeOnlySymbol();\n'  > "$FIX/sites/px/dev/modules/beta/beta.php"
    _load_libs
    run boundary_honesty_check "$CONTRACT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION"* ]]
    [[ "$output" == *"beta.php"* ]]
}

@test "DETECTOR: the stg ENVIRONMENT TWIN of a declared dev path is NOT a violation" {
    # All 11 findings on the real tree in 2026-07 were this shape: the F23
    # sites/<site>/stg twin of sites/<site>/dev. A copy of the code is not a
    # new coupling. Red before the boundary_scan_root_depth fix.
    _fixture_contract
    mkdir -p "$FIX/sites/px/dev/modules/alpha" "$FIX/sites/px/stg/modules/alpha"
    printf '<?php\nclass ProbeOnlySymbol {}\n' > "$FIX/sites/px/dev/modules/alpha/alpha.php"
    cp "$FIX/sites/px/dev/modules/alpha/alpha.php" "$FIX/sites/px/stg/modules/alpha/alpha.php"
    _load_libs
    run boundary_honesty_check "$CONTRACT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"stg"* ]]
    [[ "$output" == *"VERIFIED CLEAN"* ]]
}

@test "DETECTOR: an unrelated site checkout carrying a clone is NOT a violation" {
    _fixture_contract
    mkdir -p "$FIX/sites/px/dev/modules/alpha" "$FIX/sites/other/dev/modules/alpha"
    printf '<?php\nclass ProbeOnlySymbol {}\n' > "$FIX/sites/px/dev/modules/alpha/alpha.php"
    cp "$FIX/sites/px/dev/modules/alpha/alpha.php" "$FIX/sites/other/dev/modules/alpha/alpha.php"
    _load_libs
    run boundary_honesty_check "$CONTRACT"
    [ "$status" -eq 0 ]
}

@test "DETECTOR: a COMMENT-only reference outside declared paths is NOT a violation" {
    _fixture_contract
    mkdir -p "$FIX/sites/px/dev/modules/alpha" "$FIX/sites/px/dev/modules/beta"
    printf '<?php\nclass ProbeOnlySymbol {}\n' > "$FIX/sites/px/dev/modules/alpha/alpha.php"
    printf '<?php\n// mentions ProbeOnlySymbol in a comment only.\n' > "$FIX/sites/px/dev/modules/beta/beta.php"
    _load_libs
    run boundary_honesty_check "$CONTRACT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERIFIED CLEAN"* ]]
}

# ---------------------------------------------------------------------------
# The real tree, reported honestly whichever machine this runs on
# ---------------------------------------------------------------------------

@test "the real contract reports a VERDICT, and never 'clean' over an unseen corpus" {
    export PROJECT_ROOT="$REAL_ROOT"
    export NWP_PAIR_CONTRACT_DIR="${REAL_ROOT}/pairs"
    source "${REAL_ROOT}/lib/impact.sh"
    source "${REAL_ROOT}/lib/boundary.sh"
    run boundary_honesty_check "${REAL_ROOT}/pairs/ssd.pair-contract.yml"
    case "$status" in
        0) [[ "$output" == *"VERIFIED CLEAN"* ]] ;;
        1) [[ "$output" == *"VIOLATIONS"*     ]] ;;
        2) [[ "$output" == *"CANNOT VERIFY"* || "$output" == *"CANNOT-VERIFY"* ]] ;;
        *) echo "unexpected status $status"; return 1 ;;
    esac
    # Whatever the machine, "clean" must never be claimed without a corpus.
    if [[ "$output" == *"VERIFIED CLEAN"* ]]; then
        [[ "$output" != *"UNVERIFIABLE"* ]]
    fi
}
