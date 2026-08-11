#!/usr/bin/env bash
#
# lint-pipefail-sigpipe.sh — the ops#343 defect class, fleet-wide (ops#351).
#
# ============================================================================
# THE BUG, MEASURED
# ============================================================================
#   scripts/ci/lint-gate-redproof.sh once answered "has this gate ever been
#   proven red?" with:
#
#       has_red_proof() { cut -f1 "$proofs_file" | grep -qxF "$1"; }
#
#   Under `set -o pipefail` that is a COIN FLIP, not a lookup. `grep -q` exits
#   the instant it matches; if `cut` still has bytes to write, the kernel kills
#   it with SIGPIPE and it exits **141**; `pipefail` then promotes 141 to the
#   pipeline's status, so the function answers "NO" about a gate whose proof it
#   had just found. Measured on the workstation before MR !434: **7 of 400**
#   identical calls returned 141 on the small corpus; **20 of 20** once the
#   corpus passed the 64 KiB pipe buffer. Two pipelines ran the same commit
#   minutes apart and disagreed; one job contradicted itself inside a single
#   process.
#
#   That was ONE instance. `… | grep -q`, `… | head`, `… | read` under pipefail
#   appear ~250 times across `pl`, `scripts/` and `lib/`.
#
# ============================================================================
# WHY MOST OF THOSE 250 ARE NOT BUGS — and why that distinction IS this lint
# ============================================================================
#   The race needs THREE things at once:
#
#     1. `set -o pipefail` in effect — own, or INHERITED by being sourced into
#        a shell that set it (`pl` is `set -euo pipefail`, and 109 of 117
#        lib/*.sh never set it themselves; they run under pl's), AND
#     2. an early-exiting READER at the tail of the pipeline (`grep -q`,
#        `grep -m`, `grep -l`, `head`, `read`, `sed …q`, `awk …exit`), AND
#     3. the pipeline's exit status ACTUALLY CONSUMED.
#
#   (3) is the whole job. `foo | grep -q x` as a bare statement whose status
#   nobody reads is harmless: 141 is discarded exactly as 1 would be. The same
#   text inside an `if`, after a `&&`, as the last statement of a function, or
#   bare under `set -e`, is a live defect. A hand audit will not tell those
#   apart at this scale — so this tool does, and only the consumed ones are
#   findings.
#
#   Reported classes (see --list):
#     COND     `if` / `elif` / `while` / `until` / `!` / `&&` / `||` /
#              `return`-of — the status picks a branch.        LIVE DEFECT
#     TAIL     last statement of a function body — the status BECOMES the
#              function's return value, which the caller then tests. This is
#              the exact ops#343 shape.                        LIVE DEFECT
#     ERREXIT  bare statement, or a non-`local` assignment, inside a region
#              with `set -e` — 141 aborts the script.          LIVE DEFECT
#     BENIGN   captured value with the status dropped (`local x=$(…|head -1)`),
#              or a bare statement with no errexit.            NOT A FINDING
#
# ============================================================================
# DIRECTION — which of these can fail OPEN
# ============================================================================
#   The race can only turn exit 0 ("the reader matched") into 141 ("looks like
#   it did not"). It is therefore ALWAYS a false NO-MATCH, never a false match.
#   What that means downstream depends entirely on polarity:
#
#     POSITIVE   `if x | grep -q P; then …`      a real match is missed, so
#                `x | grep -q P && …`            the guarded body is SKIPPED.
#                                                If that body is a refusal, a
#                                                die, a warning or a skip, the
#                                                check FAILS OPEN — the
#                                                "swallowed verdict" class.
#     NEGATED    `if ! x | grep -q P; then …`    the body RUNS when it should
#                `x | grep -q P || …`            not: a false RED. Noisy and
#                                                expensive, but fails closed.
#
#   ops#343 was NEGATED-equivalent and could only manufacture false reds. The
#   POSITIVE sites are the ones that matter most, and `--rank` prints them
#   first. Polarity is mechanical; whether the guarded body is a refusal is a
#   judgement, so --rank shows the consequent text for a human to read.
#
# ============================================================================
# BASELINE (shrink-only)
# ============================================================================
#   Pre-existing consumed sites are recorded in .pipefail-sigpipe-baseline,
#   keyed by `<path>::<function>::<class>::<normalised pipeline text>` — stable
#   across line moves, granular enough that fixing ONE of several sites in a
#   function shrinks the baseline by exactly one row. The gate:
#     * fails on any consumed site NOT in the baseline (no new ones), and
#     * fails on any baseline row NOT hit (shrink-only: fixing a site means
#       deleting its row).
#   Adding a row is a RECORDED DECISION — say in the commit message why that
#   site goes in blind.
#
#   Regenerate:  scripts/ci/lint-pipefail-sigpipe.sh --update-baseline
#   Inspect:     scripts/ci/lint-pipefail-sigpipe.sh --list
#   Everything, including BENIGN:  … --list-all
#   Fail-open first, with context: … --rank
#   Sensitive paths only:          … --sensitive
#
# ============================================================================
# SENSITIVE PATHS ARE LISTED, NEVER AUTO-FIXED
# ============================================================================
#   CLAUDE.md names `lib/auth*`, `lib/*secret*`, `scripts/commands/live*.sh`,
#   `**/settings.php`, `.gitlab-ci.yml`, `composer.json`, `keys/**` and
#   `CLAUDE.md` as requiring human eyes. Between them `secrets.sh` and
#   `live.sh` hold a large share of these findings. A silent mechanical sweep
#   through secret-handling and deployment code is precisely the change this
#   estate wants a human to look at, so findings there are TAGGED and reported
#   under `--sensitive` for the operator to decide. The lint still counts them;
#   it just does not pretend the fix is mechanical.
#
# ============================================================================
# THE FIX, WHEN YOU MAKE ONE
# ============================================================================
#   Do not add `|| true` — that discards the real verdict too. Remove the pipe:
#     cut -f1 "$f" | grep -qxF "$x"     ->  grep -qxF "$x" < <(cut -f1 "$f")
#                                       ->  or an in-memory associative array
#     grep X "$f" | grep -q Y           ->  grep X "$f" | { grep -q Y; }   NO
#                                       ->  awk '/X/ && /Y/ {found=1; exit}
#                                              END {exit !found}' "$f"
#     cmd | head -1                     ->  read -r first < <(cmd)   (status is
#                                           read's, and cmd's SIGPIPE is not in
#                                           the pipeline's PIPESTATUS at all)
#   Process substitution moves the writer OUT of the pipeline, so its 141 is
#   never a candidate for pipefail's verdict. That is the shape MR !434 used.
#
# EXIT
#   0 — no un-baselined consumed sites, baseline exact
#   1 — a new consumed site, or a stale baseline row
#   2 — CANNOT VERIFY (empty corpus, unreadable root, bad usage)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE="${NWP_PIPEFAIL_SIGPIPE_BASELINE:-$PROJECT_ROOT/.pipefail-sigpipe-baseline}"

# Smallest corpus this tool will render a verdict over. A scan that finds NO
# shell files has lost its corpus, and every "OK — none new" it printed would be
# a report about the scanner, not about the tree (ops#343's lesson).
MIN_FILES="${NWP_PIPEFAIL_MIN_FILES:-1}"

MODE=check
ROOTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --update-baseline) MODE=update ;;
        --list)            MODE=list ;;
        --list-all)        MODE=listall ;;
        --rank)            MODE=rank ;;
        --sensitive)       MODE=sensitive ;;
        --baseline=*)      BASELINE="${1#*=}" ;;
        --help|-h)
            sed -n '2,140p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  ROOTS+=("$1") ;;
    esac
    shift
done

[ ${#ROOTS[@]} -eq 0 ] && ROOTS=(pl scripts lib)

cd "$PROJECT_ROOT" || exit 2

################################################################################
# CORPUS
################################################################################
files=()
for r in "${ROOTS[@]}"; do
    # A MISSING ROOT IS NOT AN EMPTY ONE. `|| continue` here would let a root
    # that failed to materialise (an unlinked overlay, an incomplete checkout)
    # silently shrink the corpus and still print OK. Fail closed and name it.
    if [ ! -e "$r" ]; then
        echo "lint:pipefail-sigpipe: CANNOT VERIFY — root not readable: $r" >&2
        exit 2
    fi
    if [ -f "$r" ]; then
        files+=("$r")
    else
        while IFS= read -r -d '' f; do files+=("$f"); done < <(
            find "$r" \( -path '*/node_modules/*' -o -path '*/vendor/*' \
                      -o -path '*/.git/*' \) -prune -o \
                 -type f \( -name '*.sh' -o -name '*.bash' \) -print0
        )
    fi
done

if [ ${#files[@]} -lt "$MIN_FILES" ]; then
    echo "lint:pipefail-sigpipe: CANNOT VERIFY — ${#files[@]} shell file(s) under: ${ROOTS[*]}" >&2
    echo "  Refusing to report success over an empty corpus." >&2
    exit 2
fi

################################################################################
# LAYER 1 — who runs under pipefail / errexit?
#
# A file's own `set -o pipefail` is the easy case. The hard — and far more
# common — case is INHERITANCE: `pl` is `set -euo pipefail` and sources
# lib/*.sh; 109 of 117 lib files never set either option themselves, yet every
# line in them executes under both. Ignoring inheritance would have declared
# almost all of lib/ out of scope, which is exactly backwards: lib/ is where
# the shared helpers whose return value everybody tests live.
#
# The source graph is resolved by BASENAME. `source "${SCRIPT_DIR}/lib/ui.sh"`
# and `source "$LIB_DIR/ui.sh"` and `. "$(dirname "$0")/../../lib/ui.sh"` all
# name ui.sh, and a basename collision inside this repo would be a bug of its
# own. Propagated to a fixpoint, because a file sourced by a file sourced by pl
# is just as much under pipefail.
################################################################################
declare -A OWN_PF=() OWN_EE=() HAS_PF=() HAS_EE=() PATH_OF=()
declare -A SOURCES=()   # sourcer -> space-separated basenames it sources

for f in "${files[@]}"; do
    b="${f##*/}"
    PATH_OF["$b"]="$f"
    # `set -o pipefail`, `set -euo pipefail`, `set -eo pipefail`. The first
    # spelling of this check demanded `-o` as its own word and therefore missed
    # `set -euo pipefail` — which is what `pl` itself and 187 other files use.
    # It reported ONE file under pipefail out of 322 and would have certified a
    # clean tree over a corpus it never looked at: the exact shape of a check
    # that has never been proven to fail. Caught by running it, not by reading it.
    if grep -qE '^[[:space:]]*set[[:space:]]+[^#]*pipefail' "$f"; then
        OWN_PF["$f"]=1
    fi
    # `set -e`, `set -eu`, `set -euo pipefail`, `set -o errexit` — but NOT `set +e`.
    if grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e[a-zA-Z]*([[:space:]]|$)|^[[:space:]]*set[[:space:]]+-o[[:space:]]+errexit' "$f"; then
        OWN_EE["$f"]=1
    fi
    srcs=$(grep -oE '^[[:space:]]*(source|\.)[[:space:]]+"?[^"]*/[A-Za-z0-9_.-]+\.sh' "$f" 2>/dev/null \
           | sed 's#.*/##' | sort -u | tr '\n' ' ')
    SOURCES["$f"]="$srcs"
done

for f in "${files[@]}"; do
    [ -n "${OWN_PF[$f]+x}" ] && HAS_PF["$f"]=own
    [ -n "${OWN_EE[$f]+x}" ] && HAS_EE["$f"]=own
done

for _iter in 1 2 3 4 5 6 7 8; do
    changed=0
    for f in "${files[@]}"; do
        for b in ${SOURCES[$f]}; do
            t="${PATH_OF[$b]:-}"
            [ -n "$t" ] || continue
            if [ -n "${HAS_PF[$f]+x}" ] && [ -z "${HAS_PF[$t]+x}" ]; then
                HAS_PF["$t"]=inherited; changed=1
            fi
            if [ -n "${HAS_EE[$f]+x}" ] && [ -z "${HAS_EE[$t]+x}" ]; then
                HAS_EE["$t"]=inherited; changed=1
            fi
        done
    done
    [ "$changed" -eq 0 ] && break
done

################################################################################
# LAYER 2 — the scanner
#
# Emits TSV: path \t line \t function \t class \t polarity \t writer-risk \t
#            normalised-pipeline \t consequent
################################################################################
scan_file() {
    local file="$1" pf="$2" ee="$3"
    awk -v PF="$pf" -v EE="$ee" -v FPATH="$file" '
    { line[NR] = $0 }
    END { main() }

    function main(   i) {
        pass1()
        for (i = 1; i <= NR; i++) if (code[i] != "") judge(i)
    }

    # ---------------------------------------------------------------- pass 1
    # Per-line context: heredoc bodies and full-line comments are not code;
    # a shell function stack keyed by indentation gives each line its enclosing
    # function; line continuations are joined so a pipeline broken across lines
    # is judged as one statement.
    function pass1(   i, raw, l, hd, hdtab, t, m, ind, f, sp, j, joined, k) {
        hd = ""; hdtab = 0; sp = 0
        for (i = 1; i <= NR; i++) {
            raw = line[i]
            if (hd != "") {
                t = raw
                if (hdtab) sub(/^[ \t]+/, "", t)
                if (t == hd) hd = ""
                fnof[i] = (sp > 0 ? fname[sp] : "(toplevel)")
                continue
            }
            l = raw
            if (l ~ /^[ \t]*#/ || l ~ /^[ \t]*$/) {
                fnof[i] = (sp > 0 ? fname[sp] : "(toplevel)")
                continue
            }

            ind = indent_of(raw)

            # close of a shell block pops any function opened at indent >= ind
            if (l ~ /^[ \t]*\}[ \t]*(;.*)?$/ || l ~ /^[ \t]*\}[ \t]*[<>&|].*$/) {
                while (sp > 0 && find[sp] >= ind) sp--
                fnof[i] = (sp > 0 ? fname[sp] : "(toplevel)")
                closer[i] = ind
                continue
            }

            # Function definition. The trailing `(#.*)?` is load-bearing: the
            # first spelling demanded end-of-line after the brace, so
            # `_secret() {  # $1 = yq path` was not recognised as a definition
            # at all — and its body then read as (toplevel), which downgraded a
            # real TAIL site in scripts/commands/notify.sh to BENIGN. A
            # classifier that silently reclassifies findings as non-findings is
            # the worst direction for this tool to be wrong in.
            if (l ~ /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)[ \t]*\{?[ \t]*(#.*)?$/) {
                f = l
                sub(/^[ \t]*/, "", f); sub(/^function[ \t]+/, "", f)
                sub(/[ \t]*\(\).*$/, "", f)
                while (sp > 0 && find[sp] >= ind) sp--
                sp++; fname[sp] = f; find[sp] = ind
                fnof[i] = f
                continue
            }

            fnof[i] = (sp > 0 ? fname[sp] : "(toplevel)")

            # JOIN CONTINUATIONS. A pipeline written as
            #     foo \
            #       | grep -q bar
            # or
            #     foo |
            #       grep -q bar
            # is one statement; scanning line-wise would see neither the writer
            # nor the reader beside each other and miss it entirely. Both
            # spellings are used in this tree.
            joined = strip_cont(raw)
            j = i
            while (j < NR && continues(line[j])) {
                j++
                k = line[j]
                sub(/^[ \t]*/, " ", k)
                joined = joined strip_cont(k)
                consumed_by[j] = i
            }
            code[i] = joined
            span_end[i] = j
            i = j       # do not re-judge the continuation lines
        }

        # heredoc openers have to be seen even on code lines; second sweep,
        # cheap and independent of the stack above.
        hd = ""; hdtab = 0
        for (i = 1; i <= NR; i++) {
            raw = line[i]
            if (hd != "") {
                t = raw
                if (hdtab) sub(/^[ \t]+/, "", t)
                if (t == hd) hd = ""
                code[i] = ""            # heredoc body is never code
                continue
            }
            t = raw
            gsub(/<<</, "  ", t)
            if (match(t, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
                m = substr(t, RSTART, RLENGTH)
                hdtab = (m ~ /^<<-/)
                sub(/^<<-?[ \t]*/, "", m)
                gsub(/[\047"]/, "", m)
                hd = m
            }
        }
    }

    function indent_of(s) { if (match(s, /^[ \t]*/)) return RLENGTH; return 0 }
    function strip_cont(s) { sub(/[ \t]*\\[ \t]*$/, " ", s); return s }
    function continues(s) {
        if (s ~ /\\[ \t]*$/) return 1               # backslash continuation
        if (s ~ /\|[ \t]*$/ && s !~ /\|\|[ \t]*$/) return 1   # trailing pipe
        if (s ~ /\|\|[ \t]*$/) return 1             # trailing ||
        if (s ~ /&&[ \t]*$/) return 1               # trailing &&
        return 0
    }

    # -------------------------------------------------------------- readers
    # Commands that STOP READING before their input ends. Anything else in tail
    # position drains the pipe, so the writer never sees EPIPE.
    function is_early_reader(seg) {
        gsub(/^[ \t]+|[ \t]+$/, "", seg)
        if (seg ~ /^grep([ \t]|$)/ || seg ~ /^(e|f)grep([ \t]|$)/ ||
            seg ~ /^(LC_ALL=[^ \t]+[ \t]+)?grep([ \t]|$)/) {
            # -q / --quiet / --silent exit on first match; -l lists and exits;
            # -m N stops after N matches. -c and plain grep read everything.
            if (seg ~ /(^|[ \t])-[a-zA-Z]*q/) return "grep -q"
            if (seg ~ /(^|[ \t])--quiet/ || seg ~ /(^|[ \t])--silent/) return "grep --quiet"
            if (seg ~ /(^|[ \t])-[a-zA-Z]*l([ \t]|$)/) return "grep -l"
            if (seg ~ /(^|[ \t])-m[ \t]*[0-9]/) return "grep -m"
            return ""
        }
        if (seg ~ /^head([ \t]|$)/) return "head"
        if (seg ~ /^read([ \t]|$)/) return "read"
        if (seg ~ /^(IFS=[^ \t]*[ \t]+)?read([ \t]|$)/) return "read"
        # sed with an explicit q/Q command stops early
        if (seg ~ /^sed([ \t]|$)/ && seg ~ /[;{ \047\042\057]q([ \t;}\047\042]|$)/) return "sed q"
        if (seg ~ /^sed([ \t]|$)/ && seg ~ /^sed[ \t]+[\047\042]?[0-9]+q/) return "sed Nq"
        # awk that exits early
        if (seg ~ /^awk([ \t]|$)/ && seg ~ /[;{ ]exit[ \t;}]/) return "awk exit"
        if (seg ~ /^(first|take)([ \t]|$)/) return ""
        return ""
    }

    # ------------------------------------------------------------ TOP-LEVEL MAP
    # ONE state machine, used by every splitter below. It exists because the
    # first version tracked quotes with two flags and got `bad="$(grep … "$f" …
    # | head -5 || true)"` wrong: the `"` opening the assignment was closed by
    # the `"` that really opened `"$f"`, so the pipes inside the substitution
    # leaked out and lib/sanitizers/files-secrets.sh — the security-critical
    # sanitiser — was reported with the wrong class AND a nonsense consequent
    # (`true)"`). Nested quoting inside `$( )` needs a STACK, not flags, and an
    # operator report is only worth reading if the rows in it are right.
    #
    # Fills, for each character i of s:
    #   top[i]  = 1  when i is at shell top level — outside every quote,
    #                substitution, backtick, subshell, brace and bracket. This
    #                is what "a top-level `|`" means.
    #   subd[i] = how many command substitutions / backticks enclose i. An
    #                OUTERMOST `$( … )` is one that opens at subd 0 — note that
    #                is NOT the same as top level, because `x="$(…)"` opens
    #                inside a double quote and is still the one we must judge.
    function mark_top(s, top, subd,   i, c, c2, sp, st, n, nsub) {
        sp = 0; nsub = 0
        n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            c2 = substr(s, i + 1, 1)
            st = (sp > 0 ? stack[sp] : "")
            top[i] = 0; subd[i] = nsub

            if (st == "sq") {                       # nothing expands in a single-quoted run
                if (c == "\047") sp--
                continue
            }
            if (st == "dq") {                       # "" still expands $( ) and ``
                if (c == "\\") { i++; top[i] = 0; subd[i] = nsub; continue }
                if (c == "$" && c2 == "(") { sp++; stack[sp] = "sub"; nsub++
                                             i++; top[i] = 0; subd[i] = nsub; continue }
                if (c == "`") { sp++; stack[sp] = "bq"; nsub++; continue }
                if (c == "\042") sp--
                continue
            }
            # unquoted, or inside a substitution/subshell/brace/bracket
            if (c == "\\") { top[i] = (sp == 0); i++; top[i] = 0; subd[i] = nsub; continue }
            top[i] = (sp == 0)
            if (c == "\047") { sp++; stack[sp] = "sq"; continue }
            if (c == "\042") { sp++; stack[sp] = "dq"; continue }
            if (c == "$" && c2 == "(") { sp++; stack[sp] = "sub"; nsub++
                                         i++; top[i] = 0; subd[i] = nsub; continue }
            if (c == "`") {
                if (st == "bq") { sp--; nsub-- } else { sp++; stack[sp] = "bq"; nsub++ }
                continue
            }
            if (c == "(") { sp++; stack[sp] = "par"; continue }
            if (c == ")") { if (st == "sub") { sp--; nsub-- } else if (st == "par") sp--; continue }
            if (c == "{") { sp++; stack[sp] = "brc"; continue }
            if (c == "}") { if (st == "brc") sp--; continue }
            if (c == "[") { sp++; stack[sp] = "brk"; continue }
            if (c == "]") { if (st == "brk") sp--; continue }
        }
        return n
    }

    # Split a statement into pipeline segments on TOP-LEVEL `|` (never `||`).
    function split_pipe(s, out,   i, c, n, seg, top, subd, len) {
        len = mark_top(s, top, subd)
        n = 0; seg = ""
        for (i = 1; i <= len; i++) {
            c = substr(s, i, 1)
            if (c == "|" && top[i]) {
                if (substr(s, i + 1, 1) == "|") { seg = seg "||"; i++; continue }
                if (i > 1 && substr(s, i - 1, 1) == "|") continue
                out[++n] = seg; seg = ""
                continue
            }
            seg = seg c
        }
        out[++n] = seg
        return n
    }

    # ------------------------------------------------------------- the judge
    function judge(i,   s, parts, np, tail, reader, k, prefix, cls, pol, risk,
                        norm, conseq, j, stmt, nstmt, p, after) {
        s = code[i]
        if (s ~ /^[ \t]*#/) return
        # A `|` that is really `||` only, or no pipe at all: nothing to do.
        if (s !~ /\|/) return

        # A statement may hold several `;`-separated commands. Judge each.
        nstmt = split_stmts(s, stmt)
        for (p = 1; p <= nstmt; p++) {
            np = split_pipe(stmt[p], parts)
            if (np < 2) continue
            tail = parts[np]
            reader = is_early_reader(strip_lead(tail))
            if (reader == "") continue

            # The writer side. `echo`/`printf` of a short literal completes
            # before the reader can leave, so those are ranked LOW — but they
            # are still reported, because `echo "$big"` past 64 KiB races just
            # the same and there is no way to know the size from here.
            risk = writer_risk(np, parts[1])

            prefix = ""
            for (j = 1; j < np; j++) prefix = prefix parts[j]
            after = after_reader(tail)

            cls = classify(i, prefix, after)
            if (cls == "") continue
            pol = polarity(prefix, after)
            norm = normalise(stmt[p])
            conseq = consequent(i, after)

            printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                   FPATH, i, fnof[i], cls, pol, risk, reader, norm, conseq
        }

        # COMMAND SUBSTITUTIONS ARE A SECOND POPULATION, and they are where the
        # BENIGN majority actually lives. `split_pipe` treats `$(` as opaque —
        # it must, or every `foo "$(a | b)"` would look like a pipeline — so
        # `ver=$(cmd | head -1)` was invisible to the first pass. Left there,
        # this tool would have reported 255 of 256 sites as consumed, which is
        # the opposite of the claim it exists to make.
        scan_substitutions(i, s)
    }

    # Judge the inside of each top-level `$( … )`. The status of a substitution
    # reaches the shell ONLY when the substitution is the whole right-hand side
    # of an assignment (or the whole command). `foo "$(cmd | head -1)"` throws
    # it away: the status of `foo` wins.
    function scan_substitutions(i, s,   n, subs, ctxs, k, parts, np, tail,
                                        reader, risk, cls, norm) {
        n = collect_substs(s, subs, ctxs)
        for (k = 1; k <= n; k++) {
            np = split_pipe(subs[k], parts)
            if (np < 2) continue
            tail = parts[np]
            reader = is_early_reader(strip_lead(tail))
            if (reader == "") continue
            risk = writer_risk(np, parts[1])
            cls = ctxs[k]
            norm = normalise(subs[k])
            printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                   FPATH, i, fnof[i], cls, "POSITIVE", risk, reader, "$(" norm ")", ""
        }
    }

    # Returns the top-level `$( … )` bodies, and for each the class its context
    # earns it:
    #   BENIGN   `local x=$(…)`  — `local` returns its own status, 0, which is
    #                              exactly why `local x=$(false)` never trips
    #                              errexit; the substitution verdict is lost.
    #   BENIGN   `foo "$(…)"`    — the status of the enclosing command wins.
    #   COND     `if x=$(…)`     — the assignment status is the condition.
    #   ERREXIT  `x=$(…)` under `set -e` — 141 aborts the script.
    # Find `$( … )` bodies. `mark_top` already knows exactly where a
    # substitution opens (it pushes "sub" there), so this walks the same
    # characters and pairs each opener with its closer by depth.
    function collect_substs(s, subs, ctxs,   i, j, c, top, subd, len, start, dep, n,
                                             pre, body, post) {
        len = mark_top(s, top, subd)
        n = 0
        for (i = 1; i < len; i++) {
            if (substr(s, i, 1) != "$" || substr(s, i + 1, 1) != "(") continue
            if (substr(s, i + 2, 1) == "(") continue        # $(( arithmetic ))
            # OUTERMOST substitutions only. subd[i] is the enclosing-substitution
            # count BEFORE this one opens, so 0 means outermost. A nested `$( )`
            # is reached when the outer body is scanned in its own right; taking
            # both would double-count the very sites this tool exists to count
            # honestly. Deliberately NOT `top[i]`: `x="$(…)"` opens inside a
            # double quote and is exactly the case that matters.
            if (subd[i] != 0) continue
            start = i + 2
            dep = 1
            for (j = start; j <= len; j++) {
                c = substr(s, j, 1)
                if (c == "(") dep++
                else if (c == ")") { dep--; if (dep == 0) break }
            }
            body = substr(s, start, j - start)
            pre  = substr(s, 1, i - 1)
            post = substr(s, j + 1)
            n++
            subs[n] = body
            ctxs[n] = subst_ctx(pre, body, post)
            i = j
        }
        return n
    }

    function subst_ctx(pre, body, post,   p, q) {
        # `x=$(… | head -1 || true)` — neutralised INSIDE the substitution.
        if (after_reader(last_pipe_seg(body)) ~ /^\|\|[ \t]*(true|:)[ \t]*$/) return "BENIGN"
        # `x="$(… | head -1)" || true` — neutralised OUTSIDE it. This spelling
        # is used in lib/demo.sh and lib/moodle-deploy.sh and would otherwise
        # have been reported as an errexit abort that cannot happen.
        q = strip_lead(post)
        sub(/^[\042\047]/, "", q)
        q = strip_lead(q)
        if (q ~ /^\|\|[ \t]*(true|:)([ \t]|$)/) return "BENIGN"
        if (q ~ /^(&&|\|\|)/) return "COND"

        p = strip_lead(pre)
        # A trailing `VAR=` / `VAR="` immediately before the `$(` is what makes
        # the substitution the WHOLE right-hand side, and therefore the thing
        # whose status the shell sees. `foo "$(a | head -1)"` is not that: the
        # status of `foo` wins and the race is invisible.
        if (p !~ /[A-Za-z_][A-Za-z0-9_]*\+?=[\042\047]?[ \t]*$/) return "BENIGN"
        if (p ~ /(^|[ \t;(&|])(if|elif|while|until)[ \t]/) return "COND"
        if (p ~ /(^|[ \t;(&|])(local|declare|typeset|readonly|export)[ \t]/) return "BENIGN"
        if (EE == "1") return "ERREXIT"
        return "BENIGN"
    }

    function last_pipe_seg(b,   parts, np) {
        np = split_pipe(b, parts)
        return parts[np]
    }

    # Everything in the tail segment that follows the reader command itself —
    # i.e. the `&& …` / `|| …` / `; then` that reads the verdict.
    function after_reader(t,   s, i, c, top, subd, len) {
        s = strip_lead(t)
        len = mark_top(s, top, subd)
        # step past the reader command word and its arguments up to the first
        # top-level `&&` or `||`.
        for (i = 1; i <= len; i++) {
            if (!top[i]) continue
            c = substr(s, i, 1)
            if (c == "&" && substr(s, i + 1, 1) == "&") return substr(s, i)
            if (c == "|" && substr(s, i + 1, 1) == "|") return substr(s, i)
        }
        return ""
    }

    # `!` and `[[ … ]]` do not mix: `[[ ! -f x ]] && cmd | grep -q y` is a
    # POSITIVE site, not a negated one. Blank out bracket tests before looking
    # for the negation that applies to the PIPELINE.
    function debracket(s) {
        gsub(/\[\[[^]]*\]\]/, " BR ", s)
        gsub(/\[[^]]*\]/, " BR ", s)
        return s
    }

    # How likely is the WRITER to still be writing when the reader leaves?
    #
    #   LOW   a single `echo`/`printf` stage. The data is already in the shell,
    #         and anything under the 64 KiB pipe buffer is written before the
    #         reader can possibly have matched. Still reported — `printf "%s"
    #         "$big"` past 64 KiB races exactly the same and the size is not
    #         knowable from here — but it is not where to start reading.
    #   HIGH  anything that streams: a file, a command, a remote, a find.
    #
    # The leading keyword MUST be stripped first. Without that,
    # `if printf ... | grep -qF ...` scored HIGH because parts[1] begins "if",
    # which put small in-shell string tests at the top of the operator report
    # alongside `dig` and `ssh`. A ranking that mis-sorts is worse than none:
    # it spends the reviewer attention it was supposed to save.
    function writer_risk(np, first,   w) {
        if (np != 2) return "HIGH"
        w = strip_lead(first)
        sub(/^(if|elif|while|until|then|do)[ \t]+/, "", w)
        sub(/^![ \t]*/, "", w)
        sub(/^(&&|\|\|)[ \t]*/, "", w)
        w = strip_lead(w)
        if (w ~ /^(echo|printf)([ \t]|$)/) return "LOW"
        return "HIGH"
    }

    function strip_lead(s) { gsub(/^[ \t]*/, "", s); return s }

    # Split on top-level `;` and `&&`/`||` boundaries so that
    # `foo && bar | grep -q x` judges `bar | grep -q x` with its `&&` context
    # preserved in the prefix.
    function split_stmts(s, out,   i, c, n, seg, top, subd, len) {
        len = mark_top(s, top, subd)
        n = 0; seg = ""
        for (i = 1; i <= len; i++) {
            c = substr(s, i, 1)
            if (c == ";" && top[i]) { out[++n] = seg; seg = ""; continue }
            seg = seg c
        }
        out[++n] = seg
        return n
    }

    # ---- is the status consumed? -------------------------------------------
    #
    # Four ways a pipeline verdict is read, and one way it is thrown away. The
    # discipline here is to claim consumption only where bash actually reads the
    # status, because over-claiming turns this lint into noise that gets
    # baselined wholesale and under-claiming lets a real coin flip through.
    #
    # NOTE what is deliberately NOT consumption: `foo && bar | grep -q x` as a
    # bare statement with no errexit. The `&&` is BEFORE the pipeline; nothing
    # reads the compound. An earlier draft called that COND and inflated the
    # finding count by ~40%.
    function classify(i, prefix, after,   b) {
        b = debracket(strip_lead(prefix))

        # COND-1 — a condition keyword introduces the pipeline.
        if (b ~ /(^|[ \t;(&|])(if|elif|while|until)([ \t]|$)/)  return "COND"
        # COND-2 — `!` negates the pipeline (bracket tests already blanked).
        if (b ~ /(^|[ \t;(&|])![ \t]/)                          return "COND"
        # NEUTRALISED — `cmd | grep -q X || true` (or `|| :`) pins the status to
        # 0 whatever happened, so nothing downstream can read the race. Checked
        # BEFORE the tail/errexit tests, because a trailing `|| true` also stops
        # the statement being a meaningful function return value and stops
        # errexit seeing anything. This is not an endorsement of `|| true` — it
        # throws the REAL verdict away too — it is just not THIS defect.
        if (after ~ /^\|\|[ \t]*(true|:)[ \t]*$/)                return "BENIGN"

        # COND-3 — something after the reader depends on the verdict:
        #          `cmd | grep -q X && act`   /   `cmd | grep -q X || die`
        if (after ~ /^(&&|\|\|)/)                               return "COND"

        # A CAPTURE throws the status away. `local x=$(…)` returns the status of
        # `local` itself (0), which is exactly why `local x=$(false)` never trips
        # errexit; a plain `x=$(…)` does carry it, but only errexit reads it.
        if (b ~ /^(local|declare|typeset|readonly|export)[ \t]/) return "BENIGN"
        if (b ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) {
            if (EE == "1") return "ERREXIT"
            return "BENIGN"
        }

        # TAIL — the last statement of a function body. Its status BECOMES the
        # return value, which every `if helper …` caller then tests. This is the
        # exact ops#343 shape, and it is invisible at the call site: that is why
        # has_red_proof survived unnoticed for months.
        if (fnof[i] != "(toplevel)" && is_tail(i)) return "TAIL"

        # A bare statement under `set -e`: 141 aborts the script outright.
        if (EE == "1") return "ERREXIT"
        return "BENIGN"
    }

    # The next thing after this statement closes the enclosing function.
    function is_tail(i,   j, end) {
        end = (span_end[i] ? span_end[i] : i)
        for (j = end + 1; j <= NR; j++) {
            if (line[j] ~ /^[ \t]*$/ || line[j] ~ /^[ \t]*#/) continue
            return (j in closer) ? 1 : 0
        }
        return 0
    }

    # ---- which way does a false NO-MATCH push? -----------------------------
    #
    # The race can ONLY turn "matched" into "did not match" — never the other
    # way. So the question is always: what does this code do when it believes
    # there was no match?
    #   POSITIVE  the guarded body is SKIPPED  -> a refusal that never fires,
    #                                             i.e. it can FAIL OPEN
    #   NEGATED   the guarded body RUNS        -> a false RED (the ops#343
    #                                             direction; noisy, not unsafe)
    function polarity(prefix, after,   b) {
        b = debracket(strip_lead(prefix))
        # `if ! cmd | grep -q X`, `[[ -n $x ]] && ! cmd | grep -q X`
        if (b ~ /(^|[ \t;(&|])![ \t]/)          return "NEGATED"
        # `cmd | grep -q X || die` — the die runs on a lost match.
        if (after ~ /^\|\|/)                    return "NEGATED"
        # `until cmd | grep -q X; do` loops while the status is non-zero.
        if (b ~ /(^|[ \t;(&|])until([ \t]|$)/)  return "NEGATED"
        return "POSITIVE"
    }

    # What runs when the (possibly wrong) answer is believed — the text a human
    # needs in order to say whether this one fails OPEN. Polarity is mechanical;
    # "is skipping this dangerous?" is not, so print the body and let a person
    # read it.
    function consequent(i, after,   j, t, end) {
        end = (span_end[i] ? span_end[i] : i)
        if (after ~ /^(&&|\|\|)/) {
            t = after
            sub(/^(&&|\|\|)[ \t]*/, "", t)
            if (t != "") return trim(t)
        }
        t = code[i]
        if (t ~ /[ \t;]then[ \t]*$/) {
            for (j = end + 1; j <= NR; j++) {
                if (line[j] ~ /^[ \t]*$/ || line[j] ~ /^[ \t]*#/) continue
                return trim(line[j])
            }
        }
        return ""
    }

    function normalise(s) {
        gsub(/[ \t]+/, " ", s)
        gsub(/^ | $/, "", s)
        return substr(s, 1, 160)
    }
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return substr(s, 1, 90) }
    ' "$file"
}

################################################################################
# RUN
################################################################################
hits="$(mktemp)"; keys="$(mktemp)"
trap 'rm -f "$hits" "$keys"' EXIT
: > "$hits"

scanned=0
for f in "${files[@]}"; do
    pf="${HAS_PF[$f]+1}"; pf="${pf:-0}"
    ee="${HAS_EE[$f]+1}"; ee="${ee:-0}"
    # No pipefail anywhere in this file's execution context: the writer's 141
    # can never become the pipeline's verdict, so there is nothing to find.
    [ "$pf" = "1" ] || continue
    scanned=$((scanned + 1))
    scan_file "$f" "$pf" "$ee" >> "$hits"
done

# --------------------------------------------------------------- sensitivity
is_sensitive() {
    case "$1" in
        lib/auth*|lib/*secret*|scripts/commands/live*.sh|scripts/commands/secrets.sh) return 0 ;;
        */settings.php|.gitlab-ci.yml|composer.json|keys/*|CLAUDE.md) return 0 ;;
    esac
    return 1
}

# Findings = consumed sites only. BENIGN rows are recorded by the scanner so
# that --list-all can show the ratio, but they are NOT findings and never enter
# the baseline: a status nobody reads cannot decide anything.
consumed_rows="$(mktemp)"; benign_rows="$(mktemp)"
trap 'rm -f "$hits" "$keys" "$consumed_rows" "$benign_rows"' EXIT
awk -F'\t' '$4 != "BENIGN"' "$hits" > "$consumed_rows"
awk -F'\t' '$4 == "BENIGN"' "$hits" > "$benign_rows"

# key = path::function::class::normalised-pipeline
awk -F'\t' '{ printf "%s::%s::%s::%s\n", $1, $3, $4, $8 }' "$consumed_rows" \
    | sort -u > "$keys"

n_all=$(wc -l < "$hits" | tr -d ' ')
n_consumed=$(wc -l < "$consumed_rows" | tr -d ' ')
n_benign=$(wc -l < "$benign_rows" | tr -d ' ')
n_keys=$(wc -l < "$keys" | tr -d ' ')

case "$MODE" in
list)
    sort -t$'\t' -k1,1 -k2,2n "$consumed_rows" \
      | awk -F'\t' '{ printf "%-8s %-8s %-4s %s:%s  %s()  [%s]\n      %s\n", $4, $5, $6, $1, $2, $3, $7, $8 }'
    printf '\nTOTAL %s consumed site(s); %s benign; %s early-exit pipelines seen under pipefail across %s file(s)\n' \
        "$n_consumed" "$n_benign" "$n_all" "$scanned"
    exit 0 ;;
listall)
    sort -t$'\t' -k4,4 -k1,1 -k2,2n "$hits" \
      | awk -F'\t' '{ printf "%-8s %-8s %-4s %s:%s  %s()  [%s]\n      %s\n", $4, $5, $6, $1, $2, $3, $7, $8 }'
    printf '\nTOTAL %s early-exit pipeline(s) under pipefail: %s CONSUMED, %s BENIGN, across %s file(s)\n' \
        "$n_all" "$n_consumed" "$n_benign" "$scanned"
    exit 0 ;;
rank)
    # FAIL-OPEN FIRST. A POSITIVE-polarity consumed site loses a real match, so
    # whatever the match was meant to trigger does not happen. When that is a
    # refusal, the check silently passes — the "swallowed verdict" class this
    # estate already has a live incident behind. NEGATED sites can only cry
    # wolf. Sorted so the expensive ones are read first, with the consequent
    # inline because only a human can say whether skipping it is dangerous.
    echo "=============================================================================="
    echo " RANK 1 — POSITIVE polarity: a lost match SKIPS the consequent. Can FAIL OPEN."
    echo "=============================================================================="
    awk -F'\t' '$5 == "POSITIVE"' "$consumed_rows" | sort -t$'\t' -k6,6 -k1,1 -k2,2n \
      | awk -F'\t' '{ s=""; if ($1 ~ /secret|live|auth/) s=" [SENSITIVE]";
            printf "%-8s %-4s %s:%s%s\n      %s\n      => skipped when it races: %s\n",
                   $4, $6, $1, $2, s, $8, ($9=="" ? "(then-branch)" : $9) }'
    echo ""
    echo "=============================================================================="
    echo " RANK 2 — NEGATED polarity: a lost match RUNS the consequent. False RED only."
    echo "=============================================================================="
    awk -F'\t' '$5 == "NEGATED"' "$consumed_rows" | sort -t$'\t' -k6,6 -k1,1 -k2,2n \
      | awk -F'\t' '{ printf "%-8s %-4s %s:%s\n      %s\n", $4, $6, $1, $2, $8 }'
    printf '\n%s POSITIVE (fail-open candidates), %s NEGATED (false-red only)\n' \
        "$(awk -F'\t' '$5=="POSITIVE"' "$consumed_rows" | wc -l | tr -d ' ')" \
        "$(awk -F'\t' '$5=="NEGATED"'  "$consumed_rows" | wc -l | tr -d ' ')"
    exit 0 ;;
sensitive)
    echo "Consumed sites on SENSITIVE paths — for OPERATOR review, not mechanical fix."
    echo "(CLAUDE.md: lib/auth*, lib/*secret*, scripts/commands/live*.sh, settings.php,"
    echo " .gitlab-ci.yml, composer.json, keys/**, CLAUDE.md)"
    echo ""
    n=0
    while IFS=$'\t' read -r p ln fn cls pol risk rd norm conseq; do
        is_sensitive "$p" || continue
        n=$((n + 1))
        printf '%-8s %-8s %-4s %s:%s  (%s)\n      %s\n' "$cls" "$pol" "$risk" "$p" "$ln" "$fn" "$norm"
        [ -n "$conseq" ] && printf '      => %s\n' "$conseq"
    done < <(sort -t$'\t' -k1,1 -k2,2n "$consumed_rows")
    printf '\n%s consumed site(s) on sensitive paths.\n' "$n"
    exit 0 ;;
update)
    sticky=""
    [ -f "$BASELINE" ] && sticky="$(grep '^#=' "$BASELINE" || true)"
    {
        echo "# .pipefail-sigpipe-baseline — status-consuming early-exit pipelines"
        echo "# under 'set -o pipefail' (ops#351; the class ops#343 / MR !434 proved)."
        echo "#"
        echo "# Key = <path>::<function>::<class>::<normalised pipeline>."
        echo "# SHRINK-ONLY: rows are DELETED when a site is fixed, never added by"
        echo "# hand. Adding one is a RECORDED DECISION — say in the commit message"
        echo "# why that site goes in blind."
        echo "# Regenerate: scripts/ci/lint-pipefail-sigpipe.sh --update-baseline"
        echo "# Inspect:    scripts/ci/lint-pipefail-sigpipe.sh --list | --rank | --sensitive"
        [ -n "$sticky" ] && printf '%s\n' "$sticky"
        cat "$keys"
    } > "$BASELINE"
    echo "Baseline written: $BASELINE ($n_keys row(s))"
    exit 0 ;;
esac

################################################################################
# CHECK
################################################################################
declare -A baseline=()
if [ -f "$BASELINE" ]; then
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        case "$k" in \#*) continue ;; esac
        baseline["$k"]=1
    done < "$BASELINE"
fi

new=0
while IFS= read -r k; do
    [ -z "$k" ] && continue
    if [ -z "${baseline[$k]+x}" ]; then
        new=$((new + 1))
        echo "NEW SIGPIPE-RACE SITE: $k"
    fi
done < "$keys"

stale=0
for k in "${!baseline[@]}"; do
    # Deliberately NOT `cut … | grep -q` — this lint would flag itself, and it
    # would be right to. `grep -F -x -q -f` reads the whole key file with no
    # pipe at all, so no writer can be killed mid-verdict.
    if ! grep -qxF -- "$k" "$keys"; then
        stale=$((stale + 1))
        echo "STALE BASELINE ROW: $k"
    fi
done

if [ "$new" -gt 0 ]; then
    echo ""
    echo "ERROR: $new new status-consuming early-exit pipeline(s) under pipefail."
    echo "       Under 'set -o pipefail' the writer's SIGPIPE (141) becomes the"
    echo "       pipeline's verdict, so the branch is decided by timing (ops#351)."
    echo "       Fix: move the writer out of the pipeline —"
    echo "         cmd | grep -q P      ->  grep -q P < <(cmd)"
    echo "         cmd | head -1        ->  read -r x < <(cmd)"
    echo "       Do NOT add '|| true': that discards the real verdict as well."
fi
if [ "$stale" -gt 0 ]; then
    echo ""
    echo "ERROR: $stale baseline row(s) match no code. The baseline is SHRINK-ONLY;"
    echo "       delete the stale row(s) from $BASELINE"
    echo "       (or run: scripts/ci/lint-pipefail-sigpipe.sh --update-baseline)."
fi
if [ "$new" -gt 0 ] || [ "$stale" -gt 0 ]; then
    exit 1
fi

echo "OK — $scanned file(s) under pipefail; $n_all early-exit pipeline(s), $n_consumed status-consuming ($n_keys baselined), $n_benign benign."
exit 0
