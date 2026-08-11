#!/usr/bin/env bash
#
# lint-gate-redproof.sh — A CHECK THAT HAS NEVER BEEN PROVEN TO FAIL IS NOT A
# CHECK. This is the meta-gate that says so about every other gate.
#
# ============================================================================
# WHY THIS FILE EXISTS
# ============================================================================
# In a single night (2026-08-01/02) six independent checks in this estate were
# found unable to do their job. Every one of them was green, or was believed
# green, for its whole life:
#
#   1. `boundary:classify` returned INTERNAL + exit 0 on a corrupt or empty
#      contract — fail-OPEN while claiming to block.                  (!308)
#   2. `verify_restic` checked the MACHINE before it checked the ARGUMENT, so
#      `--restic-provenance=trustme` was ACCEPTED on any host without restic —
#      a supply-chain flag typo passing validation.                   (!316)
#   3. Seven `! pl install '<payload>'` verification checks passed against a
#      tree with NO input validation at all, because `pl install` exited 1 for
#      an unrelated reason ("Recipe not found") and `!` turned that green.
#                                                                     (!297)
#   4. `check_security_updates` shelled a drush subcommand REMOVED from drush,
#      swallowed the error with `|| echo "[]"`, and read a pre-v2 webroot
#      layout — it could never emit a finding.                        (!306)
#   5. `lib/sanitize.sh:266`'s PII email detector was `grep -qE … | grep -qvE`,
#      unsatisfiable by construction: -q prints nothing, so the second grep saw
#      empty stdin and always exited 1.                     (fixed 2026-08-02)
#   6. `pl moodle-smoke` for ssc probes the literal placeholder
#      `https://nwc.<example-prod-domain>` — it can never pass.     (ops#210)
#
# The common shape is not a bug in any one check. It is that NOBODY EVER SAW
# THE CHECK GO RED. A gate is a hypothesis until a known-bad input has been fed
# to it and the red observed. This script turns that sentence into CI.
#
# ============================================================================
# WHAT IT ASSERTS, IN TWO LAYERS
# ============================================================================
#
# LAYER 1 — CAN IT GO RED AT ALL? (structural, read off .gitlab-ci.yml)
#   A job is CANNOT-FAIL when the pipeline cannot be reddened by it no matter
#   what the code does:
#     * `allow_failure: true`                       — advisory by declaration
#     * every substantive script line ends `|| true` / `|| echo …`
#     * the script is nothing but `echo` (a placeholder wearing a gate's name)
#   These are the strongest findings this tool produces, because they need no
#   heuristics: the YAML says it outright. Two live examples on main today are
#   `security:scan` (every arm is `… || echo "ADVISORY: …"`) and
#   `e2e:fresh-install` (`./tests/e2e/test-fresh-install.sh || true`).
#
# LAYER 2 — HAS IT BEEN PROVEN RED? (evidence, read off tests/**.bats)
#   For each gate implementation under scripts/ci/, look for a `@test` block
#   that (a) names that script and (b) asserts a NON-ZERO exit from it
#   (`[ "$status" -ne 0 ]`, `-eq 1`, `-eq 2`, `-gt 0`, `assert_failure`, …).
#   A suite that only ever asserts `-eq 0` has proven the gate can say yes. It
#   has proven nothing about the gate's ability to say no, which is the only
#   thing a gate is for.
#
# ============================================================================
# WHAT IT DELIBERATELY DOES NOT ASSERT
# ============================================================================
#   * Not that the red proof is a GOOD one. `[ "$status" -ne 0 ]` counts here,
#     even though lint-test-honesty.sh separately argues it is weak evidence.
#     One gate per concern; this one only asks "was red ever observed".
#   * Not that INLINE jobs (script written straight into the YAML) are proven.
#     Attributing a bats case to an inline shell fragment needs guesswork, and
#     a meta-honesty tool that guesses is self-refuting. Inline jobs are
#     reported as NO-RED-PROOF with the reason INLINE, which is the truth: the
#     tool cannot see a proof, so it does not claim one exists.
#   * Not anything about `pl` verbs that are not wired to a CI job. That is a
#     larger corpus and a later piece of work.
#
# ============================================================================
# BASELINE (shrink-only, same contract as .yq-first-baseline)
# ============================================================================
#   `.gate-redproof-baseline` records `<verdict>\t<key>` for every gate that is
#   NOT yet PROVEN-RED. The gate fails when:
#     * a gate is unproven and is NOT in the baseline   (a new blind gate), or
#     * a baseline row no longer matches reality        (it improved, or it got
#       worse, or the gate was renamed/removed) — either way the row is stale
#       and must be edited in the same MR.
#   PROVEN-RED is never written to the baseline, so the file can only shrink.
#
#   THIS SCRIPT IS IN ITS OWN CORPUS. It lives in scripts/ci/, so it is scanned
#   like every other gate and must carry its own red proof
#   (tests/unit/test-gate-redproof.bats). A meta-honesty check exempt from its
#   own rule would be the seventh entry on the list above.
#
# ============================================================================
# DETERMINISM (ops#343)
# ============================================================================
#   The verdict is a pure function of (.gitlab-ci.yml, scripts/ci/, tests/**).
#   It must not depend on timing, and once it did: see the long comment on
#   has_red_proof. Two rules keep it that way, and both have bats red-proofs:
#     * NO EARLY-EXIT PIPELINE decides a verdict. `… | grep -q` under
#       `set -o pipefail` returns 141 when the writer is still writing, which
#       is a coin flip, not a measurement. The evidence index is an in-memory
#       associative array.
#     * THE CORPUS SIZE IS REPORTED ON EVERY RUN, and a corpus below
#       NWP_GATE_MIN_PROOFS (default 1), or a test root that is not there at
#       all, is exit 2 — not a page of NO-RED-PROOF rows that look like
#       findings but are really the scanner describing itself.
#
# EXIT
#   0 — every gate is PROVEN-RED or is an exact, current baseline row
#   1 — a new unproven gate, or a stale baseline row
#   2 — CANNOT VERIFY (no yq, unreadable .gitlab-ci.yml, empty corpus,
#       a missing test root, or an evidence corpus below the floor)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CI_FILE="${NWP_GATE_CI_FILE:-$PROJECT_ROOT/.gitlab-ci.yml}"
CI_DIR="${NWP_GATE_CI_DIR:-$PROJECT_ROOT/scripts/ci}"
TEST_ROOTS_RAW="${NWP_GATE_TEST_ROOTS:-tests}"
BASELINE="${NWP_GATE_REDPROOF_BASELINE:-$PROJECT_ROOT/.gate-redproof-baseline}"
# Smallest evidence corpus this tool will render a verdict over (ops#343). One
# real proof is the floor: a scan that finds NONE has either lost the corpus or
# is looking in the wrong place, and in both cases every gate reads
# NO-RED-PROOF — a swallowed measurement wearing the costume of a finding.
# Overridable so the tool's own fixtures, which are deliberately corpus-free
# where they exercise verdict logic rather than corpus integrity, can set 0.
MIN_PROOFS="${NWP_GATE_MIN_PROOFS:-1}"

MODE=check
while [ $# -gt 0 ]; do
    case "$1" in
        --inventory)       MODE=inventory ;;
        --list)            MODE=list ;;
        --update-baseline) MODE=update ;;
        --baseline=*)      BASELINE="${1#*=}" ;;
        --ci-file=*)       CI_FILE="${1#*=}" ;;
        --ci-dir=*)        CI_DIR="${1#*=}" ;;
        --test-roots=*)    TEST_ROOTS_RAW="${1#*=}" ;;
        --help|-h)
            sed -n '2,107p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  echo "unexpected argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# --------------------------------------------------------------- fail closed
command -v yq >/dev/null 2>&1 || {
    echo "lint:gate-redproof: CANNOT VERIFY — yq unavailable." >&2
    echo "  Run scripts/ci/ensure-yq.sh first. An unreadable pipeline" >&2
    echo "  definition is never graded as 'all gates fine'." >&2
    exit 2
}
[ -r "$CI_FILE" ] || {
    echo "lint:gate-redproof: CANNOT VERIFY — cannot read $CI_FILE" >&2
    exit 2
}
if ! yq -e 'type == "!!map"' "$CI_FILE" >/dev/null 2>&1; then
    echo "lint:gate-redproof: CANNOT VERIFY — $CI_FILE is not a YAML mapping." >&2
    exit 2
fi

################################################################################
# EVIDENCE — which scripts/ci scripts have been observed RED by a bats case
################################################################################
# Emits `<script-basename>\t<test-file>` for every @test block that both NAMES a
# gate script and asserts a non-zero exit from it.
#
# ATTRIBUTION RULES — the part that decides whether this tool tells the truth
#   * BLOCK-SCOPED by default. A file that red-tests gate A and green-tests
#     gate B must not lend A's proof to B. (Case: "a red proof in one @test
#     block does not lend itself to another gate".)
#   * HELPER-AWARE. Real suites do not put the path in the block; they write
#     `_run_gate` or `_load`. A helper defined at column 0 lends its script
#     references to the blocks that CALL IT, and only those. Without this,
#     tests/unit/test-gate-redproof.bats — which drives this very script
#     through `_run_gate` — reported the meta-gate as unproven while proving
#     it fourteen times over.
#   * setup()/setup_file()/teardown() are FILE-WIDE, because bats runs them
#     around every case in the file. A script named there is a script the
#     whole file is about; that is not leakage, it is what the fixture means.
#   * Two resolution passes, so `_run_gate` → `_load` → path also resolves.
#
# CORPUS_BATS is set as a side effect: the number of .bats files actually
# scanned. It is REPORTED on every run (ops#343). A verdict computed over an
# evidence corpus of unknown size is not diagnosable — four pipelines had to be
# cross-referenced by hand before anyone could even ask "did the scan see the
# same files both times?".
CORPUS_BATS=0
collect_red_proofs() {
    local roots=("$@")
    local bats_files=()
    local r f
    for r in "${roots[@]}"; do
        # A MISSING TEST ROOT IS NOT AN EMPTY ONE (ops#343). `|| continue` here
        # meant a root that failed to materialise — an unlinked private/ overlay,
        # a worktree that shadows a directory, a checkout that did not complete —
        # silently shrank the evidence corpus, and every gate proved only by the
        # vanished files reported NO-RED-PROOF as if that were a finding. Same
        # shape as `lint:site-names` reading a deny-list that is not linked into
        # worktrees. Fail closed: say which root, and grade it CANNOT VERIFY.
        if [ ! -d "$r" ]; then
            echo "lint:gate-redproof: CANNOT VERIFY — test root not readable: $r" >&2
            echo "  The evidence corpus is scanned from this path; a missing one" >&2
            echo "  is an unmeasured corpus, never an empty one." >&2
            return 2
        fi
        while IFS= read -r -d '' f; do bats_files+=("$f"); done < <(
            find "$r" -type f -name '*.bats' -print0 2>/dev/null
        )
    done
    CORPUS_BATS=${#bats_files[@]}
    [ ${#bats_files[@]} -eq 0 ] && return 0

    # One awk invocation per file: helper definitions are file-local, and
    # resolving them needs the whole file in memory before any block is judged.
    for f in "${bats_files[@]}"; do
        awk '
        { L[NR] = $0 }
        function scripts_in(line,   s, out) {
            out = ""
            s = line
            while (match(s, /[A-Za-z0-9_.-]+\.sh/)) {
                out = out substr(s, RSTART, RLENGTH) " "
                s = substr(s, RSTART + RLENGTH)
            }
            return out
        }
        function is_red(line) {
            if (line ~ /\$status["]?[ \t]*-(ne|gt)[ \t]*["]?0/)  return 1
            if (line ~ /\$status["]?[ \t]*-eq[ \t]*["]?[1-9]/)   return 1
            if (line ~ /\$status["]?[ \t]*!=[ \t]*["]?0/)        return 1
            if (line ~ /(^|[ \t;&|])assert_failure([ \t]|$|\))/) return 1
            return 0
        }
        END {
            # ---- pass 1: helper functions at column 0, outside @test blocks --
            fn = ""; depth = 0; inblock = 0
            for (i = 1; i <= NR; i++) {
                l = L[i]
                sub(/[ \t]*#.*$/, "", l)
                if (l ~ /^@test/) { inblock = 1; continue }
                if (inblock) { if (l ~ /^\}[ \t]*$/) inblock = 0; continue }
                if (l ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\{?/) {
                    fn = l; sub(/[ \t]*\(\).*$/, "", fn); depth = 1
                    hbody[fn] = ""
                    continue
                }
                if (fn != "") {
                    if (l ~ /^\}[ \t]*$/) { fn = ""; continue }
                    hbody[fn] = hbody[fn] " " scripts_in(l)
                }
            }
            # transitive: a helper that calls a helper
            for (pass = 0; pass < 2; pass++)
                for (h in hbody)
                    for (g in hbody)
                        if (g != h && hbody[h] ~ ("(^|[ \t;&|(])" g "([ \t;&|)]|$)"))
                            hbody[h] = hbody[h] " " hbody[g]

            # setup/teardown apply to every case in the file
            always = ""
            split("setup setup_file teardown teardown_file", sf, " ")
            for (k = 1; k <= 4; k++) if (sf[k] in hbody) always = always " " hbody[sf[k]]

            # ---- pass 2: judge each block ----
            inblock = 0; red = 0; body = ""
            for (i = 1; i <= NR + 1; i++) {
                l = (i <= NR) ? L[i] : "}"
                sub(/[ \t]*#.*$/, "", l)
                if (l ~ /^@test/) { emit(body, red); inblock = 1; red = 0; body = ""; continue }
                if (!inblock) continue
                if (l ~ /^\}[ \t]*$/) { emit(body, red); inblock = 0; red = 0; body = ""; continue }
                body = body " " l
                if (is_red(l)) red = 1
            }
        }
        function emit(body, red,   n, i, tok, seen, out) {
            if (body == "" || !red) return
            out = scripts_in(body) " " always
            for (h in hbody)
                if (body ~ ("(^|[ \t;&|(])" h "([ \t;&|)]|$)")) out = out " " hbody[h]
            n = split(out, tok, /[ \t]+/)
            delete seen
            for (i = 1; i <= n; i++)
                if (tok[i] != "" && !(tok[i] in seen)) {
                    seen[tok[i]] = 1
                    print tok[i] "\t" FILENAME
                }
        }
        ' "$f"
    done | sort -u
}

IFS=' ' read -r -a TEST_ROOTS <<< "$TEST_ROOTS_RAW"
cd "$PROJECT_ROOT" || exit 2
proofs_file="$(mktemp)"
gates_file="$(mktemp)"
trap 'rm -f "$proofs_file" "$gates_file"' EXIT
collect_red_proofs "${TEST_ROOTS[@]}" > "$proofs_file" || exit 2

# ---------------------------------------------------------------- ops#343
# THE EVIDENCE INDEX IS BUILT ONCE, IN MEMORY, AND READ WITHOUT A PIPE.
#
# This function used to be:
#
#     has_red_proof() { cut -f1 "$proofs_file" | grep -qxF "$1"; }
#
# and under this script's `set -o pipefail` that is a COIN FLIP, not a lookup.
# `grep -q` exits the instant it matches. If `cut` has not finished writing by
# then — and with a 90 KB corpus against a 64 KiB pipe buffer it usually has
# not — `cut` is killed by SIGPIPE and exits 141. `pipefail` then makes 141 the
# pipeline's status, so the function answers "NO, this gate has never been
# proven red" about a gate whose proof it just found. The earlier a script
# sorts, the likelier the flip, because grep leaves sooner.
#
# The damage was exactly what you would expect of a random answer inside a
# meta-gate: on 2026-08-11 pipelines 2224 and 2225 ran the SAME commit
# 46082c87 minutes apart and disagreed, and job 18973 contradicted ITSELF —
# `impl:scripts/ci/run-bats.sh` PROVEN-RED and `job:test:integration` PROVEN-RED
# via run-bats.sh, while `job:test:unit` reported "no bats case asserts a
# non-zero exit from run-bats.sh", all in one process, milliseconds apart.
# Measured on the workstation before the fix: 7 of 400 identical calls for
# `lint-bash.sh` returned 141; with a 90 KB corpus, 20 of 20.
#
# Direction of the error: this race can only turn PROVEN-RED into
# NO-RED-PROOF, so it manufactures FALSE REDS, never a false green. That is
# still the bad outcome it looks like — a gate that cries wolf is on its way to
# being a gate nobody believes, and three of these were answered with a retry.
#
# An associative array has no pipe, no subprocess and no ordering, so the
# answer cannot depend on timing. It is also ~110 fewer forks per run.
declare -A RED_PROVEN=()
while IFS=$'\t' read -r _b _f; do
    [ -n "$_b" ] && RED_PROVEN["$_b"]=1
done < "$proofs_file"
CORPUS_PROOFS=$(wc -l < "$proofs_file" | tr -d ' ')

has_red_proof() {   # basename -> 0 if some block proved it red
    [ -n "${RED_PROVEN[$1]+x}" ]
}
proof_sites() {     # basename -> the test files that proved it
    grep -E "^$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')	" "$proofs_file" \
        | cut -f2 | sed 's#.*/##' | sort -u | paste -sd, -
}

# ALWAYS SAY HOW BIG THE EVIDENCE WAS (ops#343). Printed to stderr so `--list`
# stays machine-readable on stdout. Two numbers in the job log turn "why did
# this gate disagree with itself?" from a four-pipeline cross-reference into a
# one-line comparison.
echo "lint:gate-redproof: evidence corpus — $CORPUS_BATS bats file(s) under ${TEST_ROOTS[*]}, $CORPUS_PROOFS red-proof row(s)." >&2
if [ "$CORPUS_PROOFS" -lt "$MIN_PROOFS" ]; then
    echo "lint:gate-redproof: CANNOT VERIFY — evidence corpus too small:" >&2
    echo "  $CORPUS_PROOFS red-proof row(s) from $CORPUS_BATS bats file(s), floor is $MIN_PROOFS." >&2
    echo "  Every gate would read NO-RED-PROOF, which would be a report about" >&2
    echo "  the scanner, not about the gates. Refusing to render a verdict." >&2
    exit 2
fi

################################################################################
# LAYER 1 — read the pipeline definition
################################################################################
# A "substantive" script line is one that could carry a verdict: not blank, not
# a comment, not a pure `echo`, not a variable assignment.
job_is_cannot_fail() {
    local job="$1"
    local allow
    allow="$(yq -r ".\"$job\".allow_failure // false" "$CI_FILE" 2>/dev/null)"
    if [ "$allow" = "true" ]; then
        echo "allow_failure:true"
        return 0
    fi

    local body substantive=0 swallowed=0 line bare
    body="$(yq -r ".\"$job\".script[]?" "$CI_FILE" 2>/dev/null)"
    while IFS= read -r line; do
        [ -z "${line//[[:space:]]/}" ] && continue
        bare="${line#"${line%%[![:space:]]*}"}"
        # Strip `VAR=value ` command PREFIXES. Treating them as assignments was
        # this script's own first false positive: `test:console`'s only script
        # line is `PYTEST=.venv/bin/pytest ./scripts/ci/test-console.sh`, and
        # skipping it made a real, blocking gate read as an echo-only
        # placeholder. A meta-honesty tool gets exactly one chance to be the
        # kind of thing it exists to catch.
        while [[ "$bare" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
            bare="${bare#"${BASH_REMATCH[0]}"}"
        done
        case "$bare" in
            '#'*) continue ;;
            echo\ *|echo) continue ;;
            '') continue ;;
        esac
        # A standalone assignment (nothing follows it) carries no verdict.
        [[ "$bare" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*$ ]] && continue
        substantive=$((substantive + 1))
        # `cmd || true` and `cmd || echo …` discard the verdict.
        if printf '%s' "$line" | grep -qE '\|\|[[:space:]]*(true|:|echo([[:space:]]|$))'; then
            swallowed=$((swallowed + 1))
        fi
    done <<< "$body"

    if [ "$substantive" -eq 0 ]; then
        echo "echo-only"
        return 0
    fi
    if [ "$swallowed" -eq "$substantive" ]; then
        echo "all-${substantive}-verdicts-swallowed"
        return 0
    fi
    return 1
}

job_impls() {       # the scripts/ci/*.sh a job actually runs (script + before_script)
    yq -r ".\"$1\".script[]? , .\"$1\".before_script[]?" "$CI_FILE" 2>/dev/null \
        | grep -oE 'scripts/ci/[A-Za-z0-9_.-]+\.sh' | sort -u
}

################################################################################
# BUILD THE INVENTORY
################################################################################
# One row per gate:  <verdict>\t<key>\t<detail>
#   key = `job:<name>` for a CI job, `impl:scripts/ci/<f>.sh` for a gate script.
{
    # ---- CI jobs ----
    while IFS= read -r job; do
        [ -z "$job" ] && continue
        case "$job" in .*|stages|variables|default|cache|workflow|include) continue ;; esac
        yq -e ".\"$job\" | type == \"!!map\"" "$CI_FILE" >/dev/null 2>&1 || continue
        yq -e ".\"$job\" | has(\"script\")"   "$CI_FILE" >/dev/null 2>&1 || continue

        if reason="$(job_is_cannot_fail "$job")"; then
            printf 'CANNOT-FAIL\tjob:%s\t%s\n' "$job" "$reason"
            continue
        fi

        impls="$(job_impls "$job")"
        if [ -z "$impls" ]; then
            printf 'NO-RED-PROOF\tjob:%s\t%s\n' "$job" "INLINE — script written into the YAML; no file to red-test"
            continue
        fi
        # A job is proven when at least one of the scripts it runs is proven.
        # ensure-*.sh bootstraps are excluded: proving the yq installer goes red
        # says nothing about the gate that later uses yq.
        proven=""; unproven=""
        while IFS= read -r impl; do
            [ -z "$impl" ] && continue
            case "${impl##*/}" in ensure-*.sh) continue ;; esac
            if has_red_proof "${impl##*/}"; then proven="$proven ${impl##*/}"
            else unproven="$unproven ${impl##*/}"; fi
        done <<< "$impls"
        if [ -n "$proven" ]; then
            printf 'PROVEN-RED\tjob:%s\tvia%s (%s)\n' "$job" "$proven" "$(proof_sites "$(echo $proven | awk '{print $1}')")"
        elif [ -n "$unproven" ]; then
            printf 'NO-RED-PROOF\tjob:%s\tno bats case asserts a non-zero exit from%s\n' "$job" "$unproven"
        else
            printf 'NO-RED-PROOF\tjob:%s\t%s\n' "$job" "runs only ensure-* bootstraps; the gate itself is inline"
        fi
    done < <(yq -r 'keys | .[]' "$CI_FILE" 2>/dev/null)

    # ---- gate implementations ----
    while IFS= read -r -d '' f; do
        b="${f##*/}"
        case "$b" in ensure-*.sh) continue ;; esac
        if has_red_proof "$b"; then
            printf 'PROVEN-RED\timpl:scripts/ci/%s\t%s\n' "$b" "$(proof_sites "$b")"
        else
            printf 'NO-RED-PROOF\timpl:scripts/ci/%s\t%s\n' "$b" "no bats case asserts a non-zero exit from it"
        fi
    done < <(find "$CI_DIR" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null | sort -z)
} | sort -t"$(printf '\t')" -k2,2 > "$gates_file"

total="$(wc -l < "$gates_file" | tr -d ' ')"
if [ "$total" -eq 0 ]; then
    echo "lint:gate-redproof: CANNOT VERIFY — zero gates found." >&2
    echo "  Refusing to report success on an empty corpus." >&2
    exit 2
fi

################################################################################
# OUTPUT MODES
################################################################################
if [ "$MODE" = "inventory" ] || [ "$MODE" = "list" ]; then
    if [ "$MODE" = "list" ]; then cat "$gates_file"; exit 0; fi
    echo "GATE RED-PROOF INVENTORY  ($total gates)"
    echo "A check that has never been proven to fail is not a check."
    echo ""
    for v in CANNOT-FAIL NO-RED-PROOF PROVEN-RED; do
        n="$(grep -c "^$v	" "$gates_file")"
        echo "── $v ($n)"
        grep "^$v	" "$gates_file" | while IFS=$'\t' read -r _v k d; do
            printf '   %-42s %s\n' "$k" "$d"
        done
        echo ""
    done
    exit 0
fi

# ------------------------------------------------------------------ baseline
unproven_file="$(mktemp)"
trap 'rm -f "$proofs_file" "$gates_file" "$unproven_file"' EXIT
grep -v "^PROVEN-RED	" "$gates_file" | cut -f1,2 | sort > "$unproven_file"

if [ "$MODE" = "update" ]; then
    sticky=""
    [ -f "$BASELINE" ] && sticky="$(grep '^#=' "$BASELINE" 2>/dev/null)"
    {
        echo "# .gate-redproof-baseline — gates that have NEVER been observed RED."
        echo "#"
        echo "# Format: <verdict>\\t<key>.  Verdicts:"
        echo "#   CANNOT-FAIL   the pipeline definition makes a red verdict impossible"
        echo "#                 (allow_failure:true, every verdict '|| true'/'|| echo',"
        echo "#                 or an echo-only placeholder). Worst class: the job name"
        echo "#                 asserts coverage the job cannot deliver."
        echo "#   NO-RED-PROOF  it could go red, but no bats case has ever made it."
        echo "#"
        echo "# SHRINK-ONLY. Rows are DELETED when a gate earns a red proof; PROVEN-RED"
        echo "# is never written here. Adding a row is a recorded decision, not a fix —"
        echo "# say in the commit message why the gate is going in blind."
        echo "# Regenerate: scripts/ci/lint-gate-redproof.sh --update-baseline"
        echo "# Inspect:    scripts/ci/lint-gate-redproof.sh --inventory"
        [ -n "$sticky" ] && printf '%s\n' "$sticky"
        cat "$unproven_file"
    } > "$BASELINE"
    echo "Baseline written: $BASELINE ($(wc -l < "$unproven_file" | tr -d ' ') unproven gate(s) of $total)"
    exit 0
fi

declare -A base=()
if [ -f "$BASELINE" ]; then
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        case "$row" in \#*) continue ;; esac
        base["$row"]=1
    done < "$BASELINE"
fi

new=0
while IFS= read -r row; do
    [ -z "$row" ] && continue
    if [ -z "${base[$row]+x}" ]; then
        new=$((new + 1))
        v="${row%%	*}"; k="${row#*	}"
        detail="$(grep -F "	$k	" "$gates_file" | cut -f3 | head -1)"
        echo "UNPROVEN GATE (not in baseline): [$v] $k"
        echo "    $detail"
    fi
done < "$unproven_file"

stale=0
for row in "${!base[@]}"; do
    if ! grep -qxF "$row" "$unproven_file"; then
        stale=$((stale + 1))
        k="${row#*	}"
        if grep -q "^PROVEN-RED	$k	" "$gates_file"; then
            echo "STALE BASELINE ROW (gate is now PROVEN-RED — delete it): $row"
        elif grep -q "	$k	" "$gates_file"; then
            echo "STALE BASELINE ROW (verdict changed — re-record it): $row"
            echo "    now: $(grep -F "	$k	" "$gates_file" | cut -f1,3 | head -1)"
        else
            echo "STALE BASELINE ROW (gate no longer exists — delete it): $row"
        fi
    fi
done

cannot="$(grep -c "^CANNOT-FAIL	" "$gates_file")"
noproof="$(grep -c "^NO-RED-PROOF	" "$gates_file")"
proven="$(grep -c "^PROVEN-RED	" "$gates_file")"

if [ "$new" -gt 0 ]; then
    echo ""
    echo "ERROR: $new gate(s) with no proof they can go RED, and no baseline row."
    echo "       Write a test that feeds the gate a KNOWN-BAD input and asserts a"
    echo "       non-zero exit (see tests/unit/test-ci-lint-commands.bats), or"
    echo "       record the gap deliberately:"
    echo "         scripts/ci/lint-gate-redproof.sh --update-baseline"
fi
if [ "$stale" -gt 0 ]; then
    echo ""
    echo "ERROR: $stale baseline row(s) no longer describe the tree."
    echo "       The baseline is SHRINK-ONLY — edit $BASELINE in this MR."
fi
if [ "$new" -gt 0 ] || [ "$stale" -gt 0 ]; then
    exit 1
fi

echo "OK — $total gate(s): $proven PROVEN-RED, $noproof NO-RED-PROOF, $cannot CANNOT-FAIL."
echo "     $((noproof + cannot)) recorded in $(basename "$BASELINE") (shrink-only);"
echo "     see 'pl verify gates' for the full inventory."
exit 0
