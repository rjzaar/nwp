#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cross-repo coverage gate for auth_nwc's guild→cohort reconciliation.
#
# WHY THIS EXISTS
#
# The stranded branch `nwp/nwp:ops-93` (1 commit, 9e78092, 2026-07-18, never an
# MR) carried the guild→cohort sync for the Moodle auth_nwc plugin. Its
# PRODUCTION half now lives — newer and byte-identical for the pure class — in
# the canonical plugin repo `nwp/ss-moodle-plugins` at `auth/nwc/`. So the
# branch looks safely deletable.
#
# It is not safe to delete on that evidence alone. "The production code
# survived" is a different claim from "the TEST coverage survived", and the
# branch's only unique artefact is a 79-line pure-logic unit test
# (`tests/guild_cohort_map_logic_test.php`). Deleting the branch because the
# class exists elsewhere would silently drop the only thing that proves the
# class is right.
#
# This script is the gate. It answers ONE question:
#
#     May refs/heads/ops-93 be deleted from nwp/nwp?
#
# and it answers "no" unless the canonical repo carries BOTH halves — the code
# AND a guild-cohort logic test that is registered, runnable, green, and
# NON-VACUOUS (proven by mutating the class under it and requiring a failure).
#
# NOT WIRED INTO CI, DELIBERATELY. It reads a second private repository over
# SSH. The nwp/nwp CI runner holds no credential for `nwp/ss-moodle-plugins`,
# so wiring this into a pipeline would produce a job that can only ever fail or
# be skipped — the exact "gate that cannot fail" shape this arc is removing.
# Run it by hand (or from an agent session with the operator's SSH key) before
# deleting the branch, and paste the output into the deletion record.
#
# Usage:
#   tests/tools/verify-crossrepo-guild-cohort-coverage.sh [--repo=URL] [--ref=REF]
#
# Exit: 0 = GREEN, canonical coverage complete, ops-93 may be deleted.
#       1 = RED,   do NOT delete; port the missing test into the canonical repo.
#       2 = CANNOT VERIFY (no php / no git / repo unreachable). Never 0.
# ---------------------------------------------------------------------------
set -u

REPO="git@git.nwpcode.org:nwp/ss-moodle-plugins.git"
REF="main"
for arg in "$@"; do
    case "$arg" in
        --repo=*) REPO="${arg#*=}" ;;
        --ref=*)  REF="${arg#*=}" ;;
        --local=*) LOCAL_TREE="${arg#*=}" ;;
        -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

red=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  RED  %s\n' "$*"; red=1; }
cant() { printf '  CANNOT-VERIFY  %s\n' "$*" >&2; exit 2; }

command -v git >/dev/null 2>&1 || cant "git is not installed"
command -v php >/dev/null 2>&1 || cant "php CLI is not installed — the logic test cannot be executed, and 'I did not run it' is not 'it passed'"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "${LOCAL_TREE:-}" ]; then
    # Escape hatch used by this script's own self-test: point at an already
    # checked-out tree instead of cloning.
    TREE="$LOCAL_TREE"
    say "Canonical tree (local override): $TREE"
else
    TREE="$TMP/canonical"
    git clone --quiet --depth 1 --branch "$REF" "$REPO" "$TREE" 2>"$TMP/clone.err" \
        || cant "cannot clone ${REPO}@${REF}: $(tr '\n' ' ' <"$TMP/clone.err")"
    say "Canonical: ${REPO}@${REF} ($(git -C "$TREE" rev-parse --short HEAD))"
fi

say ""
say "A. production half — the code the branch was written to add"
[ -f "$TREE/auth/nwc/classes/guild_cohort_map.php" ] \
    && ok "auth/nwc/classes/guild_cohort_map.php exists" \
    || bad "auth/nwc/classes/guild_cohort_map.php is MISSING"
grep -q 'guild_cohort_map::decide' "$TREE/auth/nwc/auth.php" 2>/dev/null \
    && ok "auth/nwc/auth.php calls guild_cohort_map::decide" \
    || bad "auth/nwc/auth.php does NOT call guild_cohort_map::decide"

say ""
say "B. test half — the branch's only unique artefact (79 lines)"
TESTFILE=""
for cand in "$TREE"/auth/nwc/tests/*guild*cohort*.php "$TREE"/auth/nwc/tests/*guild*.php; do
    [ -f "$cand" ] && { TESTFILE="$cand"; break; }
done
if [ -z "$TESTFILE" ]; then
    bad "no guild-cohort logic test under auth/nwc/tests/ — the branch's tests/guild_cohort_map_logic_test.php has NO canonical equivalent"
    bad "correct action is to PORT THE TEST into ${REPO}, not to delete ops-93"
else
    ok "test present: ${TESTFILE#$TREE/}"

    rel="${TESTFILE#$TREE/}"
    if grep -qF "$rel" "$TREE/tests/run-standalone.sh" 2>/dev/null; then
        ok "registered in tests/run-standalone.sh (it will actually be run)"
    else
        bad "NOT registered in tests/run-standalone.sh — present but run by nothing"
    fi

    if ( cd "$TREE" && php "$rel" >"$TMP/run.out" 2>&1 ); then
        ok "test passes against the canonical class ($(grep -oE '[0-9]+ passed' "$TMP/run.out" | tail -1))"
    else
        bad "test FAILS against the canonical class:"; sed 's/^/       /' "$TMP/run.out"
    fi

    # ---- negative control -------------------------------------------------
    # A gate that only checks "the file exists and exits 0" is satisfied by a
    # test that asserts nothing. Mutate the class the test is supposed to be
    # guarding; if the test still passes, it proves nothing and the coverage
    # claim is false.
    say ""
    say "C. negative control — the test must FAIL on a broken class"
    for mutant in prefix noleave; do
        cp -r "$TREE" "$TMP/mut-$mutant"
        case "$mutant" in
            prefix)
                sed -i "s/const MANAGED_PREFIX = 'nwcguild:';/const MANAGED_PREFIX = 'mutant:';/" \
                    "$TMP/mut-$mutant/auth/nwc/classes/guild_cohort_map.php" ;;
            noleave)
                sed -i 's/^                \$leave\[\] = \$uuid;/                \/\/ mutated away/' \
                    "$TMP/mut-$mutant/auth/nwc/classes/guild_cohort_map.php" ;;
        esac
        if ! diff -q "$TREE/auth/nwc/classes/guild_cohort_map.php" \
                     "$TMP/mut-$mutant/auth/nwc/classes/guild_cohort_map.php" >/dev/null; then
            if ( cd "$TMP/mut-$mutant" && php "$rel" >/dev/null 2>&1 ); then
                bad "mutant '$mutant' still PASSES — the test is vacuous"
            else
                ok "mutant '$mutant' is caught"
            fi
        else
            bad "mutant '$mutant' could not be applied (class shape changed) — non-vacuity UNPROVEN"
        fi
    done
fi

say ""
if [ "$red" -eq 0 ]; then
    say "GREEN — canonical repo carries both halves. nwp/nwp:ops-93 may be deleted."
    exit 0
fi
say "RED — do NOT delete nwp/nwp:ops-93."
exit 1
