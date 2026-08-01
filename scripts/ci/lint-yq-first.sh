#!/usr/bin/env bash
#
# lint-yq-first.sh — yq-first enforcement (ADR-0015 / F36 A-C2) that can see
# more than one line at a time.
#
# WHY THIS FILE EXISTS
#   The `lint:yq-first` CI job used to be a single line-wise grep:
#       grep -RHnE 'awk[^|]*(\.yml|nwp\.yml)' pl scripts/commands/ lib/
#   That is wrong in BOTH directions, proven on a probe tree 2026-07-26:
#     * FALSE NEGATIVE — nobody writes a non-trivial awk YAML parser on one
#       line. Every real offender in this repo is a multi-line `awk '…' "$FILE"`
#       block, and the filename lands on the *closing* line, so the regex never
#       sees `awk` and the `.yml` together. Five such parsers live in
#       scripts/commands/verify.sh (one of them computes .badges.json) and more
#       in lib/yaml-write.sh; the old gate reported "OK — no AWK YAML parsers".
#     * FALSE POSITIVE — a *comment* mentioning "awk" and "nwp.yml" reddens the
#       gate, which trains people to work around it.
#
# WHAT THIS DOES INSTEAD
#   Scans each file as a whole:
#     1. skips full-line comments and here-document bodies,
#     2. finds `awk` invocations whose program is single-quoted, tracking the
#        quote across lines until it closes,
#     3. inspects the arguments that follow the closing quote (and, for
#        single-line invocations, the rest of that line),
#     4. flags the invocation when an argument is a YAML file — either a literal
#        `*.yml` / `*.yaml`, or a shell variable that is assigned a `*.yml` /
#        `*.yaml` path AND IS IN SCOPE AT THE INVOCATION (this is how the
#        verify.sh parsers hide: `' "$VERIFICATION_FILE"`).
#
#   Non-YAML awk (du output, port parsing, printf formatting, `awk "BEGIN{…}"`
#   arithmetic) is untouched, as ADR-0015 intends.
#
# ---------------------------------------------------------------------------
# VARIABLE SCOPING — the ops#196 correctness fix (2026-08-02)
# ---------------------------------------------------------------------------
#   Until ops#196, step 4's variable learning was FILE-SCOPED: any `VAR=` on any
#   line that also contained `.yml` made `$VAR` mean "a YAML path" for the WHOLE
#   file. Measured consequence in scripts/commands/moodle.sh:
#
#       _moodle_core_patches_decl() {
#           local base="$1" config_file="$2" f
#           f="${cache}/core-patches/${base}.yml"      # ← teaches "f is YAML"
#       }
#       …400 lines later, a different function…
#           for f in "$dir"/*.mbz; do
#               sum="$(awk '{print $1}' "$f.sha256")"  # ← reported as a YAML parser
#
#   `f` there is an .mbz backup and the awk is splitting `sha256sum` output. The
#   gate blocked it anyway, and the tempting "fix" — add a baseline row — would
#   have permanently blessed a whole class of non-violations.
#
#   The learning is now scoped THE WAY BASH ACTUALLY SCOPES:
#     * a variable named in a `local` / `declare` / `typeset` statement inside
#       function F is F-scoped; a `.yml` assignment to it taints F only;
#     * every other assignment (top level, or inside a function with no `local`)
#       is a GLOBAL and taints the whole file — which is what keeps the real
#       verify.sh / yaml-write.sh offenders caught, since they read top-level
#       constants like `VERIFICATION_FILE`.
#   So the moodle.sh `f` (declared `local`) no longer leaks out of its function,
#   and `CFG_FILE="…/.verification.yml"` at file scope still reaches every
#   function that reads it.
#
#   KNOWN, DELIBERATE GAP: an awk YAML parser that receives its file as a
#   POSITIONAL parameter (`awk '…' "$1"`, called as `_helper "$config_file"`) is
#   not detected — resolving that needs call-graph analysis, not scope analysis.
#   One such parser exists today: lib/install-common.sh::get_recipe_list_value's
#   nested `_awk_recipe_list`. It is recorded here rather than papered over.
#
# ---------------------------------------------------------------------------
# FUNCTION ATTRIBUTION — the other half of the ops#196 fix
# ---------------------------------------------------------------------------
#   The baseline key is `<path>::<function>` so it survives line moves. The old
#   tracker only ever *entered* functions: it set the current function on any
#   line that looked like a definition — including an INDENTED, nested one — and
#   never left. Everything after `    _awk_recipe_list() { … }` in
#   lib/install-common.sh was therefore attributed to `_awk_recipe_list` until
#   the next definition appeared, so baseline rows could name a function that
#   does not contain the offending awk at all.
#
#   The tracker now keeps a STACK keyed by indentation: a definition at indent I
#   pushes, a `}` at indent ≤ I pops, and a sibling definition at indent ≤ I pops
#   first. Lines inside a multi-line single-quoted awk program and inside a
#   here-document are excluded from brace tracking, because `}` in an awk program
#   body or in a heredoc is not a shell block close.
#
# BASELINE (shrink-only)
#   Pre-existing offenders are recorded in .yq-first-baseline, keyed by
#   `path::function` — stable across line moves. The gate:
#     * fails on any hit NOT in the baseline   (no new AWK YAML parsers), and
#     * fails on any baseline entry NOT hit    (the baseline may only shrink;
#       when you convert a parser to yq you must delete its baseline line).
#   Regenerate deliberately with:  scripts/ci/lint-yq-first.sh --update-baseline
#   Inspect what it would contain with: scripts/ci/lint-yq-first.sh --list
#
# EXIT
#   0 — no un-baselined AWK YAML parsers, baseline is exact
#   1 — new offender, or a stale baseline entry
#   2 — empty corpus / bad usage (cannot verify)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE="${NWP_YQ_FIRST_BASELINE:-$PROJECT_ROOT/.yq-first-baseline}"

UPDATE_BASELINE=0
LIST_ONLY=0
ROOTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --update-baseline) UPDATE_BASELINE=1 ;;
        --list)            LIST_ONLY=1 ;;
        --baseline=*)      BASELINE="${1#*=}" ;;
        --help|-h)
            sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  ROOTS+=("$1") ;;
    esac
    shift
done

if [ ${#ROOTS[@]} -eq 0 ]; then
    ROOTS=(pl scripts/commands lib)
fi

cd "$PROJECT_ROOT" || exit 2

# ---------------------------------------------------------------- file corpus
files=()
for r in "${ROOTS[@]}"; do
    [ -e "$r" ] || continue
    if [ -f "$r" ]; then
        files+=("$r")
    else
        while IFS= read -r -d '' f; do files+=("$f"); done < <(
            find "$r" \( -path '*/node_modules/*' -o -path '*/vendor/*' \) -prune -o \
                 -type f \( -name '*.sh' -o -name '*.bash' \) -print0
        )
    fi
done

if [ ${#files[@]} -eq 0 ]; then
    echo "ERROR: lint-yq-first found no shell files under: ${ROOTS[*]}" >&2
    echo "       Refusing to report success on an empty corpus." >&2
    exit 2
fi

# --------------------------------------------------------------- the scanner
# Emits one line per offending awk invocation:  <path>::<function>\t<line>\t<args>
scan_file() {
    awk '
    { line[NR] = $0 }

    END {
        # =================================================================
        # PASS 1 — per-line context: heredoc body, awk-program body, and the
        # enclosing shell function (indentation-keyed stack). Also collects
        # the awk invocation CANDIDATES; their arguments are judged in pass 3,
        # once variable scoping is known.
        # =================================================================
        hd = ""; hdtab = 0          # active heredoc terminator
        inq = 0                     # inside a multi-line single-quoted program
        sp = 0                      # function stack pointer
        ncand = 0
        for (i = 1; i <= NR; i++) {
            raw = line[i]
            cur = (sp > 0 ? fname[sp] : "(toplevel)")

            # ---- here-document body: opaque text, never shell code ----
            if (hd != "") {
                inhd[i] = 1; fnof[i] = cur
                t = raw
                if (hdtab) sub(/^[ \t]+/, "", t)
                if (t == hd) hd = ""
                continue
            }

            l = strip_qesc(raw)

            # ---- inside a multi-line single-quoted awk program ----
            if (inq) {
                inawk[i] = 1; fnof[i] = cur
                q = countq(l)
                if (q % 2 == 1) {
                    inq = 0
                    # arguments follow the LAST quote on the closing line
                    cargs[ncand] = substr(l, lastq(l) + 1)
                }
                continue
            }

            fnof[i] = cur

            # ---- full-line comment: no code, no heredoc, no braces ----
            if (l ~ /^[ \t]*#/) continue

            ind = indent_of(raw)

            # ---- close of a shell block: pop any function at indent >= ind ----
            if (l ~ /^[ \t]*\}[ \t]*(;.*)?$/ || l ~ /^[ \t]*\}[ \t]*[<>&|].*$/) {
                while (sp > 0 && find[sp] >= ind) sp--
                fnof[i] = (sp > 0 ? fname[sp] : "(toplevel)")
                continue
            }

            # ---- function definition: a sibling/outer def pops first ----
            if (l ~ /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)[ \t]*\{?[ \t]*$/) {
                f = l
                sub(/^[ \t]*/, "", f); sub(/^function[ \t]+/, "", f)
                sub(/[ \t]*\(\).*$/, "", f)
                while (sp > 0 && find[sp] >= ind) sp--
                sp++; fname[sp] = f; find[sp] = ind
                fnof[i] = f
                continue
            }

            # ---- awk invocation? ----
            if (l ~ /(^|[ \t;(&|=$"`])awk[ \t]/) {
                p = index(l, "awk")
                rest = substr(l, p)
                q = countq(rest)
                if (q > 0) {
                    ncand++
                    cstart[ncand] = i
                    cfn[ncand] = fnof[i]
                    if (q % 2 == 1) {       # program opens here, closes later
                        inq = 1
                        cargs[ncand] = ""   # filled on the closing line
                        continue
                    }
                    # Balanced on this line: a single-line invocation. The
                    # arguments are what follows the LAST quote — the same rule
                    # as the multi-line case. Taking the whole `awk …` text
                    # instead (the pre-ops#196 behaviour) made `-v v="$value"`
                    # program parameters look like file arguments, which is how
                    # lib/ci-stats.sh::ci_stats_check — pure BEGIN{} arithmetic
                    # with no file at all — got reported as a YAML parser.
                    cargs[ncand] = substr(rest, lastq(rest) + 1)
                }
            }

            # ---- here-document opener (herestrings <<< are not heredocs) ----
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

        # =================================================================
        # PASS 2a — which names are `local` to which function.
        # =================================================================
        for (i = 1; i <= NR; i++) {
            if (inhd[i] || inawk[i]) continue
            l = line[i]
            if (l ~ /^[ \t]*#/) continue
            if (l !~ /(^|[ \t;(&|])(local|declare|typeset)[ \t]/) continue
            s = l
            while (match(s, /(^|[ \t;(&|])(local|declare|typeset)[ \t]+/)) {
                s = substr(s, RSTART + RLENGTH)
                # names run until the next `;`, `)` or end of statement
                d = s
                if (match(d, /[;)]/)) d = substr(d, 1, RSTART - 1)
                n = split(d, tok, /[ \t]+/)
                for (j = 1; j <= n; j++) {
                    v = tok[j]
                    if (v ~ /^-/) continue                 # -a, -A, -r, -i …
                    sub(/=.*$/, "", v)
                    if (v ~ /^[A-Za-z_][A-Za-z0-9_]*$/) localof[fnof[i] SUBSEP v] = 1
                }
            }
        }

        # =================================================================
        # PASS 2b — which same-file functions PRODUCE a YAML path. Used by
        # rule R3 below: `f="$(_resolve_infra_secrets_file)"` carries a YAML
        # path even though the assignment line never says ".yml".
        # =================================================================
        for (i = 1; i <= NR; i++) {
            if (inhd[i] || inawk[i]) continue
            l = line[i]
            if (l ~ /^[ \t]*#/) continue
            if (l ~ /\.(yml|yaml)([^A-Za-z0-9_]|$)/ && fnof[i] != "(toplevel)")
                producer[fnof[i]] = 1
        }

        # =================================================================
        # PASS 2c — reachability: which variables can hold a *.yml/*.yaml
        # path AT A GIVEN POINT. Scope follows bash: a name declared `local`
        # in function F taints F only (key F); every other assignment is a
        # shell global (key ""). Four ways a name becomes tainted:
        #   R1 literal   x=".../foo.yml"
        #   R2 var flow  x="${1:-$YAML_CONFIG_FILE}"     (source already tainted)
        #   R3 producer  x="$(_resolve_infra_secrets_file)"
        #   R4 for-loop  for x in "$DIR"/*.yml; do
        # Iterated to a fixpoint because R2 depends on earlier taints and the
        # assignment order in a file is not the dependency order.
        # =================================================================
        for (iter = 0; iter < 12; iter++) {
            changed = 0
            for (i = 1; i <= NR; i++) {
                if (inhd[i] || inawk[i]) continue
                l = line[i]
                if (l ~ /^[ \t]*#/) continue
                fn = fnof[i]

                # R4 — for-loop variable
                if (match(l, /(^|[ \t;])for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]/)) {
                    hdr = substr(l, RSTART, RLENGTH)
                    lst = substr(l, RSTART + RLENGTH)
                    sub(/;[ \t]*do.*$/, "", lst)
                    v = hdr
                    sub(/^[ \t;]*for[ \t]+/, "", v); sub(/[ \t]+in[ \t]*$/, "", v)
                    if (yamlish(lst, fn)) changed += taint(fn, v)
                }

                # R1/R2/R3 — assignments
                s = l
                while (match(s, /(^|[ \t;(&|])(local[ \t]+|export[ \t]+|readonly[ \t]+|declare[ \t]+-[a-zA-Z]+[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
                    v = substr(s, RSTART, RLENGTH)
                    s = substr(s, RSTART + RLENGTH)
                    sub(/^[ \t;(&|]/, "", v)
                    sub(/^(local|export|readonly)[ \t]+/, "", v)
                    sub(/^declare[ \t]+-[a-zA-Z]+[ \t]+/, "", v)
                    sub(/=$/, "", v)
                    # RHS runs to the next ` name=` on the line, or to EOL
                    rhs = s
                    if (match(rhs, /[ \t][A-Za-z_][A-Za-z0-9_]*=/))
                        rhs = substr(rhs, 1, RSTART - 1)
                    if (yamlish(rhs, fn)) changed += taint(fn, v)
                }
            }
            if (changed == 0) break
        }

        # =================================================================
        # PASS 3 — judge each candidate awk invocation.
        # =================================================================
        for (c = 1; c <= ncand; c++) check(cfn[c], cstart[c], cargs[c])
    }

    function indent_of(s,   n) {
        if (match(s, /^[ \t]*/)) return RLENGTH
        return 0
    }

    # Does this text carry a YAML path, as seen from inside function `fn`?
    function yamlish(t, fn,   a, v) {
        if (t ~ /\.(yml|yaml)([^A-Za-z0-9_]|$)/) return 1          # R1
        a = t
        while (match(a, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {        # R2
            v = substr(a, RSTART, RLENGTH); gsub(/[${}]/, "", v)
            if ((fn SUBSEP v) in yamlvar || ("" SUBSEP v) in yamlvar) return 1
            a = substr(a, RSTART + RLENGTH)
        }
        a = t
        while (match(a, /\$\([ \t]*[A-Za-z_][A-Za-z0-9_:.-]*/)) {   # R3
            v = substr(a, RSTART, RLENGTH); sub(/^\$\([ \t]*/, "", v)
            if (v in producer) return 1
            a = substr(a, RSTART + RLENGTH)
        }
        return 0
    }

    # Taint `v` in the narrowest scope bash would give it. Returns 1 if new.
    function taint(fn, v,   k) {
        k = (localof[fn SUBSEP v] ? fn : "") SUBSEP v
        if (k in yamlvar) return 0
        yamlvar[k] = 1
        return 1
    }

    # Bash escapes a single quote inside a single-quoted string as \047"\047"\047
    # (close, double-quoted quote, reopen). That is 3 single quotes, which flips
    # the parity the wrong way and produced a false positive in stg2live.sh.
    # Strip the whole 5-char idiom before counting.
    function strip_qesc(s) {
        gsub(/\047"\047"\047/, "", s)
        return s
    }
    function countq(s,   n, j, t) {
        t = strip_qesc(s); n = 0
        for (j = 1; j <= length(t); j++) if (substr(t, j, 1) == "\047") n++
        return n
    }
    function lastq(s,   j, t) {
        t = strip_qesc(s)
        for (j = length(t); j >= 1; j--) if (substr(t, j, 1) == "\047") return j
        return 0
    }
    function check(f, ln, args,   a, v) {
        a = args
        if (a ~ /\.(yml|yaml)([^A-Za-z0-9_]|$)/) { emit(f, ln, a); return }
        while (match(a, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
            v = substr(a, RSTART, RLENGTH)
            gsub(/[${}]/, "", v)
            # in scope here? function-local taint, or a shell global
            if ((f SUBSEP v) in yamlvar || ("" SUBSEP v) in yamlvar) {
                emit(f, ln, args); return
            }
            a = substr(a, RSTART + RLENGTH)
        }
    }
    function emit(f, ln, a) {
        gsub(/^[ \t]+|[ \t]+$/, "", a)
        printf "%s::%s\t%d\t%s\n", FILENAME, f, ln, a
    }
    ' "$1"
}

hits_file="$(mktemp)"
trap 'rm -f "$hits_file" "$hits_file.keys"' EXIT
: > "$hits_file"
for f in "${files[@]}"; do
    scan_file "$f" >> "$hits_file"
done

cut -f1 "$hits_file" | sort -u > "$hits_file.keys"

# ------------------------------------------------------------------ inspect
if [ "$LIST_ONLY" -eq 1 ]; then
    sort "$hits_file"
    exit 0
fi

# ------------------------------------------------------------------ baseline
if [ "$UPDATE_BASELINE" -eq 1 ]; then
    # Sticky provenance MUST be captured before the redirect below truncates
    # the file it would be read from.
    sticky=""
    [ -f "$BASELINE" ] && sticky="$(grep '^#=' "$BASELINE" || true)"
    {
        echo "# .yq-first-baseline — pre-existing AWK YAML parsers (ADR-0015)."
        echo "# SHRINK-ONLY: entries may be DELETED (when converted to yq) but never added"
        echo "# by hand. Regenerate with: scripts/ci/lint-yq-first.sh --update-baseline"
        echo "# Key = <path>::<enclosing shell function>."
        # Sticky provenance: lines beginning '#=' survive regeneration, so the
        # reason a baseline once moved is not lost the next time it is rebuilt.
        [ -n "$sticky" ] && printf '%s\n' "$sticky"
        cat "$hits_file.keys"
    } > "$BASELINE"
    echo "Baseline written: $BASELINE ($(wc -l < "$hits_file.keys") entr(y|ies))"
    exit 0
fi

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
        echo "NEW AWK YAML PARSER: $k"
        grep -F "$(printf '%s\t' "$k")" "$hits_file" | while IFS=$'\t' read -r _key ln args; do
            echo "    line $ln: $args"
        done
    fi
done < "$hits_file.keys"

stale=0
for k in "${!baseline[@]}"; do
    if ! grep -qxF "$k" "$hits_file.keys"; then
        stale=$((stale + 1))
        echo "STALE BASELINE ENTRY: $k"
    fi
done

if [ "$new" -gt 0 ]; then
    echo ""
    echo "ERROR: $new AWK YAML parser(s) introduced. Use yq instead (ADR-0015)."
    echo "       See lib/ci-stats.sh and pl get_site_field for the yq pattern."
fi
if [ "$stale" -gt 0 ]; then
    echo ""
    echo "ERROR: $stale baseline entr(y|ies) no longer match any code."
    echo "       The baseline is SHRINK-ONLY — delete the stale line(s) from"
    echo "       $BASELINE (or run: scripts/ci/lint-yq-first.sh --update-baseline)."
fi
if [ "$new" -gt 0 ] || [ "$stale" -gt 0 ]; then
    exit 1
fi

echo "OK — scanned ${#files[@]} file(s); $(wc -l < "$hits_file.keys" | tr -d ' ') known AWK YAML parser(s), none new."
exit 0
