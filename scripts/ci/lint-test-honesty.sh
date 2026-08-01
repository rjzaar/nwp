#!/usr/bin/env bash
#
# lint-test-honesty.sh — the four ways a test in this repo has been observed to
# assert nothing while reporting success.
#
# ============================================================================
# WHY THIS FILE EXISTS
# ============================================================================
# lint-gate-redproof.sh asks "has this gate ever been seen RED?". This one asks
# the next question down: "when it went red, did anyone check WHY?" Both come
# out of the 2026-08-01/02 sweep, and each rule below is a shape that was found
# live in this tree, not a shape imagined from a style guide.
#
#   H1 BLIND-NEGATION   `! pl install '<payload>' 2>/dev/null`
#       Seven verification checks claimed to prove `pl install` REJECTS shell
#       metacharacters in a site name. The tree had no such validation at all.
#       They passed because `pl install` exited 1 for a completely unrelated
#       reason ("Recipe not found") and `!` turned that into a green tick. The
#       `2>/dev/null` is what makes it unfixable in place: the evidence that
#       would have distinguished the two failures was being discarded by the
#       check itself.                                                    (!297)
#
#   H2 SWALLOWED-VERDICT  `updates=$(… drush pm:security … || echo "[]")`
#       `check_security_updates` shelled a drush subcommand that had been
#       REMOVED from drush. Every invocation errored; `|| echo "[]"` turned the
#       error into "zero security updates"; the check then reported clean. It
#       could not emit a finding in any universe.                        (!306)
#
#   H3 SKIP             `command -v ddev || skip "ddev not installed"`
#       bats reports a skip as `ok`. A runner missing a tool converts real
#       assertions into green ticks with nothing anywhere turning red. The DR
#       work proved a zero-skip unit suite is achievable, so the number of
#       skips in the tree is a debt with a floor of zero, not a fact of life.
#
#   H4 HOST-BLIND       `command -v restic || return 0`
#       `verify_restic` checked the MACHINE before it checked the ARGUMENT, so
#       on any host without restic the supply-chain flag
#       `--restic-provenance=trustme` was ACCEPTED. A host-dependent branch
#       with no environment knob cannot be tested from the other side, so the
#       side that matters is the side nobody ever runs.                  (!316)
#
# ============================================================================
# CONVENTIONS
# ============================================================================
# Follows .yq-first-baseline exactly: a shrink-only baseline keyed on something
# stable across line moves, `--update-baseline` to regenerate deliberately,
# `--list` to inspect, exit 2 on a corpus it cannot read. Growing a baseline is
# a recorded decision (say why in the commit message), never a fix.
#
# EXIT
#   0 — no un-baselined finding, and the baseline is exact
#   1 — a new finding, or a stale/loosened baseline row
#   2 — CANNOT VERIFY (missing corpus, no yq)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# NWP_HONESTY_ROOT lets the acceptance suite point every rule at a synthetic
# tree. Without it the rules resolved their relative roots against the REAL
# repo no matter what the fixture said, so the "does it stay green on a clean
# tree?" cases were silently re-testing main — a test that cannot see its own
# fixture is the disease this file is about.
PROJECT_ROOT="${NWP_HONESTY_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

BASELINE="${NWP_TEST_HONESTY_BASELINE:-$PROJECT_ROOT/.test-honesty-baseline}"
VERIFICATION_FILE="${NWP_HONESTY_VERIFICATION_FILE:-$PROJECT_ROOT/.verification.yml}"
CI_DIR="${NWP_HONESTY_CI_DIR:-$PROJECT_ROOT/scripts/ci}"
CODE_ROOTS_RAW="${NWP_HONESTY_CODE_ROOTS:-lib scripts/commands}"
SUITE_ROOTS_RAW="${NWP_HONESTY_SUITE_ROOTS:-tests/unit tests/integration}"

MODE=check
RULES="H1 H2 H3 H4"
while [ $# -gt 0 ]; do
    case "$1" in
        --list)            MODE=list ;;
        --update-baseline) MODE=update ;;
        --baseline=*)      BASELINE="${1#*=}" ;;
        --rules=*)         RULES="${1#*=}"; RULES="${RULES//,/ }" ;;
        --root=*)          PROJECT_ROOT="${1#*=}"
                           VERIFICATION_FILE="${NWP_HONESTY_VERIFICATION_FILE:-$PROJECT_ROOT/.verification.yml}"
                           CI_DIR="${NWP_HONESTY_CI_DIR:-$PROJECT_ROOT/scripts/ci}" ;;
        --help|-h)
            sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  echo "unexpected argument: $1" >&2; exit 2 ;;
    esac
    shift
done

cd "$PROJECT_ROOT" || exit 2
IFS=' ' read -r -a CODE_ROOTS  <<< "$CODE_ROOTS_RAW"
IFS=' ' read -r -a SUITE_ROOTS <<< "$SUITE_ROOTS_RAW"

wants() { case " $RULES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

findings="$(mktemp)"
trap 'rm -f "$findings" "$findings.b"' EXIT
: > "$findings"
corpus_seen=0

################################################################################
# H1 — BLIND NEGATION in the machine-verification corpus
################################################################################
# A `! <cmd>` check asserts only "this exited non-zero". That is a proof of
# rejection ONLY when the command has one way to fail. `pl install` has dozens.
#
# A negation is ACCEPTED here when either:
#   * the negated command is a simple predicate whose only failure is the thing
#     being asserted — grep / test / [ / [[ / cmp / diff / stat / ls, or
#   * the check discriminates on the OUTPUT: it pipes stdout+stderr into a
#     grep/match for the specific error expected.
# It is REPORTED when it is a bare negation of a real program, and doubly so
# when `2>/dev/null` throws away the only evidence that could tell the intended
# failure from an accidental one.
if wants H1; then
    if [ -r "$VERIFICATION_FILE" ]; then
        command -v yq >/dev/null 2>&1 || {
            echo "lint:test-honesty: CANNOT VERIFY — yq unavailable for $VERIFICATION_FILE" >&2
            exit 2
        }
        corpus_seen=1
        yq -r '.. | select(tag == "!!map") | select(has("cmd")) | .cmd' \
           "$VERIFICATION_FILE" 2>/dev/null \
        | awk '
            {
                c = $0
                sub(/^[ \t]*/, "", c)
                if (c !~ /^![ \t]*/) next
                body = c; sub(/^![ \t]*/, "", body)

                # head of the negated command
                head = body
                sub(/[ \t].*$/, "", head)
                sub(/^.*\//, "", head)
                if (head ~ /^(grep|egrep|fgrep|test|\[|\[\[|cmp|diff|stat|ls|find|jq|yq)$/) next

                # discriminates on output?
                if (body ~ /\|[ \t]*(grep|egrep|fgrep|jq|awk|test)/) next
                if (body ~ /2>&1/ && body ~ /grep/) next

                blind = (body ~ /2>\/dev\/null/) ? "stderr discarded" : "no error-text assertion"
                print "H1-BLIND-NEGATION\t" c "\t" blind
            }' >> "$findings"
    fi
fi

################################################################################
# H2 — a CHECK that swallows the failure it exists to detect
################################################################################
# Scope: functions whose NAME says they render a verdict (check_/verify_/audit_/
# assert_/scan_/detect_/probe_ … or …_check/_guard/_verify/_audit) in the code
# roots, plus every script in scripts/ci (all of which are verdicts by
# definition). Reported shape: a command substitution whose failure is replaced
# by a literal — `x=$(cmd … || echo "[]")`. That literal then flows into the
# verdict as if it were a measurement.
#
# DELIBERATE EXCLUSIONS
#   * `cond && echo A || echo B` — a ternary, not a swallow: no command fails.
#   * Everything outside a verdict-named function. `branch=$(git … || echo
#     unknown)` painting a status column is not this bug, and folding 300 such
#     lines in would bury the 42 that sit inside a check. Narrow and enforced
#     beats broad and baselined-into-silence.
if wants H2; then
    files=()
    for r in "${CODE_ROOTS[@]}"; do
        [ -d "$r" ] || continue
        while IFS= read -r -d '' f; do files+=("$f"); done < <(
            find "$r" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)
    done
    [ -d "$CI_DIR" ] && while IFS= read -r -d '' f; do files+=("$f"); done < <(
        find "$CI_DIR" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)

    if [ ${#files[@]} -gt 0 ]; then
        corpus_seen=1
        awk '
        FNR == 1 { fn = "(toplevel)"; isci = (FILENAME ~ /\/scripts\/ci\//) }
        /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)[ \t]*\{?[ \t]*$/ {
            f = $0; sub(/^[ \t]*/, "", f); sub(/^function[ \t]+/, "", f)
            sub(/[ \t]*\(\).*$/, "", f); fn = f; next
        }
        /^\}[ \t]*$/ { fn = "(toplevel)"; next }
        {
            if ($0 ~ /^[ \t]*#/) next
            verdictish = (fn ~ /^(check|verify|audit|assert|scan|detect|probe)_/ ||
                          fn ~ /_(check|guard|verify|audit)$/ || isci)
            if (!verdictish) next
            if ($0 !~ /=[ \t]*"?\$\(.*\|\|[ \t]*echo/) next
            if ($0 ~ /&&[ \t]*echo[^|]*\|\|[ \t]*echo/) next     # ternary
            print "H2-SWALLOWED-VERDICT\t" FILENAME "::" fn "\tfailure replaced by a literal"
        }' "${files[@]}" | sort -u >> "$findings"
    fi
fi

################################################################################
# H3 — skips, counted per file, shrink-only
################################################################################
# tests/.skip-budget caps how many cases may skip AT RUNTIME on the machine
# doing the running. That is the right check and it is already enforced. This
# one caps how many `skip` statements EXIST, which is the thing that decides
# whether a differently-provisioned machine can quietly stop testing. Runtime
# budget = today's runner; source count = every runner there will ever be.
if wants H3; then
    for r in "${SUITE_ROOTS[@]}"; do
        [ -d "$r" ] || continue
        corpus_seen=1
        while IFS= read -r -d '' f; do
            # `# honesty:fixture` excludes a line that WRITES a skip into a
            # synthetic tree (this file's own acceptance suite does that eight
            # times). Explicit and greppable beats obfuscating the word so the
            # counter cannot see it.
            n="$(grep -vF 'honesty:fixture' "$f" \
                 | grep -cE '(^|[|&;( ])skip( |$|"|'"'"')')"
            [ "${n:-0}" -gt 0 ] && printf 'H3-SKIP-STATEMENTS\t%s\t%s\n' "$f" "$n" >> "$findings"
        done < <(find "$r" -maxdepth 1 -type f -name '*.bats' -print0 2>/dev/null | sort -z)
    done
fi

################################################################################
# H4 — a host-dependent branch with no way to simulate the other host
################################################################################
# `command -v X` deciding a gate's behaviour is fine when the missing tool is
# FAIL-CLOSED (exit/return non-zero, "CANNOT VERIFY") — lint-conflict-markers.sh
# does exactly that with git. It is a hole when the tool's absence degrades to
# success or to a skip AND the file offers no `NWP_*` knob, because then the
# absent-tool path is the one nobody can exercise deliberately. That is the
# verify_restic shape: on a host without restic, an invalid provenance flag was
# accepted, and no test could pin it because there was no way to say "pretend
# restic is missing".
if wants H4; then
    if [ -d "$CI_DIR" ]; then
        corpus_seen=1
        while IFS= read -r -d '' f; do
            grep -qE 'NWP_[A-Z_]+' "$f" && continue   # has an override knob
            awk -v F="$f" '
            { L[NR] = $0 }
            END {
                for (i = 1; i <= NR; i++) {
                    line = L[i]
                    if (line ~ /^[ \t]*#/) continue
                    if (line !~ /command -v[ \t]+/) continue
                    t = line
                    sub(/^.*command -v[ \t]+/, "", t)
                    sub(/[ \t].*$/, "", t)
                    gsub(/["\047$(){}]/, "", t)
                    if (t == "") continue
                    # fail-closed within the branch? look at this line + 3 more
                    closed = 0
                    for (j = i; j <= i + 3 && j <= NR; j++)
                        if (L[j] ~ /(exit|return)[ \t]+[1-9]/ || L[j] ~ /CANNOT VERIFY/) closed = 1
                    if (closed) continue
                    print "H4-HOST-BLIND\t" F "::" t "\tno NWP_* override, absence does not fail closed"
                }
            }' "$f" >> "$findings"
        done < <(find "$CI_DIR" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null | sort -z)
    fi
fi

################################################################################
# VERDICT
################################################################################
if [ "$corpus_seen" -eq 0 ]; then
    echo "lint:test-honesty: CANNOT VERIFY — no corpus found for rules: $RULES" >&2
    echo "  Refusing to report success on an empty corpus." >&2
    exit 2
fi

# Keys must be REPO-RELATIVE. CI_DIR and the roots may arrive absolute (they do
# under --root and under the bats fixtures), and an absolute path in a committed
# baseline is a row that matches on exactly one machine — a baseline that goes
# stale the moment someone else checks the repo out is worse than none.
sed -i "s#\t${PROJECT_ROOT}/#\t#g; s#::${PROJECT_ROOT}/#::#g" "$findings"
sort -o "$findings" "$findings"

if [ "$MODE" = "list" ]; then cat "$findings"; exit 0; fi

# rows carried in the baseline: rule + key + (H3 only) count
cut -f1,2,3 "$findings" | awk -F'\t' '{ if ($1 == "H3-SKIP-STATEMENTS") print $1"\t"$2"\t"$3; else print $1"\t"$2 }' \
    | sort -u > "$findings.b"

if [ "$MODE" = "update" ]; then
    sticky=""
    [ -f "$BASELINE" ] && sticky="$(grep '^#=' "$BASELINE" 2>/dev/null)"
    {
        echo "# .test-honesty-baseline — tests and checks that currently assert less"
        echo "# than they appear to. Generated by scripts/ci/lint-test-honesty.sh."
        echo "#"
        echo "#   H1-BLIND-NEGATION    \`! <cmd>\` proving only 'exited non-zero', with"
        echo "#                        no assertion on WHY. Fix: assert the error text."
        echo "#   H2-SWALLOWED-VERDICT a verdict function replaces a command failure"
        echo "#                        with a literal (\`|| echo \"[]\"\`) and measures it."
        echo "#   H3-SKIP-STATEMENTS   per-file count of \`skip\` statements. bats scores"
        echo "#                        a skip as ok. SHRINK-ONLY: the count may go DOWN"
        echo "#                        (lower the number in the same MR) but never up."
        echo "#   H4-HOST-BLIND        a host-dependent branch with no NWP_* knob to"
        echo "#                        simulate the absent tool, that does not fail closed."
        echo "#"
        echo "# SHRINK-ONLY. Deleting a row is a fix. Adding one is a recorded decision:"
        echo "# say in the commit message why the check is going in blind."
        echo "# Regenerate: scripts/ci/lint-test-honesty.sh --update-baseline"
        echo "# Inspect:    scripts/ci/lint-test-honesty.sh --list"
        [ -n "$sticky" ] && printf '%s\n' "$sticky"
        cat "$findings.b"
    } > "$BASELINE"
    echo "Baseline written: $BASELINE ($(wc -l < "$findings.b" | tr -d ' ') row(s))"
    exit 0
fi

declare -A base=()
declare -A base_h3=()
if [ -f "$BASELINE" ]; then
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        case "$row" in \#*) continue ;; esac
        base["$row"]=1
        case "$row" in
            H3-SKIP-STATEMENTS*) k="${row%	*}"; base_h3["$k"]="${row##*	}" ;;
        esac
    done < "$BASELINE"
fi

new=0 stale=0 grown=0
while IFS= read -r row; do
    [ -z "$row" ] && continue
    case "$row" in
        H3-SKIP-STATEMENTS*)
            k="${row%	*}"; n="${row##*	}"
            b="${base_h3[$k]:-}"
            if [ -z "$b" ]; then
                new=$((new + 1)); echo "NEW skip-bearing suite: ${k#*	} ($n skip statement(s))"
            elif [ "$n" -gt "$b" ]; then
                grown=$((grown + 1)); echo "SKIPS GREW: ${k#*	}  $b -> $n (shrink-only)"
            elif [ "$n" -lt "$b" ]; then
                stale=$((stale + 1)); echo "SKIPS SHRANK (good) — lower the baseline: ${k#*	}  $b -> $n"
            fi
            ;;
        *)
            if [ -z "${base[$row]+x}" ]; then
                new=$((new + 1))
                detail="$(grep -F "$row	" "$findings" | cut -f3 | head -1)"
                echo "NEW ${row%%	*}: ${row#*	}"
                [ -n "$detail" ] && echo "    $detail"
            fi
            ;;
    esac
done < "$findings.b"

for row in "${!base[@]}"; do
    case "$row" in H3-SKIP-STATEMENTS*) continue ;; esac   # handled above
    if ! grep -qxF "$row" "$findings.b"; then
        stale=$((stale + 1))
        echo "STALE BASELINE ROW (fixed — delete it): $row"
    fi
done
for k in "${!base_h3[@]}"; do
    grep -q "^$(printf '%s' "$k" | sed 's/[.[\*^$/]/\\&/g')	" "$findings.b" && continue
    stale=$((stale + 1))
    echo "STALE BASELINE ROW (no skips left — delete it): $k"
done

if [ "$new" -gt 0 ]; then
    echo ""
    echo "ERROR: $new new test-honesty finding(s)."
    echo "  H1 — assert the ERROR TEXT, not just a non-zero exit:"
    echo "         pl install d 'bad name' 2>&1 | grep -q 'Invalid site name'"
    echo "  H2 — let the check FAIL when its measurement fails; do not substitute a literal."
    echo "  H3 — provision the tool on the runner, or make the case machine-independent."
    echo "  H4 — add an NWP_* knob so the absent-tool path can be exercised on purpose."
fi
if [ "$grown" -gt 0 ]; then
    echo ""
    echo "ERROR: $grown suite(s) gained skip statements. The baseline is SHRINK-ONLY."
fi
if [ "$stale" -gt 0 ]; then
    echo ""
    echo "ERROR: $stale baseline row(s) no longer match the tree — edit $BASELINE in this MR."
fi
[ "$new" -gt 0 ] || [ "$grown" -gt 0 ] || [ "$stale" -gt 0 ] && exit 1

total="$(wc -l < "$findings.b" | tr -d ' ')"
echo "OK — test-honesty rules [$RULES]: $total known finding(s), none new."
exit 0
