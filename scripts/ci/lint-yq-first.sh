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
#     1. skips full-line comments,
#     2. finds `awk` invocations whose program is single-quoted, tracking the
#        quote across lines until it closes,
#     3. inspects the arguments that follow the closing quote (and, for
#        single-line invocations, the rest of that line),
#     4. flags the invocation when an argument is a YAML file — either a literal
#        `*.yml` / `*.yaml`, or a shell variable that is assigned a `*.yml` /
#        `*.yaml` path elsewhere in the same file (this is how the verify.sh
#        parsers hide: `' "$VERIFICATION_FILE"`).
#
#   Non-YAML awk (du output, port parsing, printf formatting, `awk "BEGIN{…}"`
#   arithmetic) is untouched, as ADR-0015 intends.
#
# BASELINE (shrink-only)
#   Pre-existing offenders are recorded in .yq-first-baseline, keyed by
#   `path::function` — stable across line moves. The gate:
#     * fails on any hit NOT in the baseline   (no new AWK YAML parsers), and
#     * fails on any baseline entry NOT hit    (the baseline may only shrink;
#       when you convert a parser to yq you must delete its baseline line).
#   Regenerate deliberately with:  scripts/ci/lint-yq-first.sh --update-baseline
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
ROOTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --update-baseline) UPDATE_BASELINE=1 ;;
        --baseline=*)      BASELINE="${1#*=}" ;;
        --help|-h)
            sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
    # ---- pass 1: remember every variable assigned a *.yml / *.yaml path ----
    { line[NR] = $0 }
    /\.(yml|yaml)/ {
        s = $0
        while (match(s, /(^|[ \t;(&|])(local[ \t]+|export[ \t]+|declare[ \t]+-[a-zA-Z]+[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
            v = substr(s, RSTART, RLENGTH)
            sub(/^[ \t;(&|]/, "", v)
            sub(/^(local|export)[ \t]+/, "", v)
            sub(/^declare[ \t]+-[a-zA-Z]+[ \t]+/, "", v)
            sub(/=$/, "", v)
            yamlvar[v] = 1
            s = substr(s, RSTART + RLENGTH)
        }
    }
    END {
        fn = "(toplevel)"
        inblock = 0
        for (i = 1; i <= NR; i++) {
            l = strip_qesc(line[i])

            # track the enclosing shell function for a line-number-independent key
            if (l ~ /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)[ \t]*\{?[ \t]*$/) {
                f = l
                sub(/^[ \t]*/, "", f); sub(/^function[ \t]+/, "", f)
                sub(/[ \t]*\(\).*$/, "", f)
                fn = f
            }

            if (inblock) {
                q = countq(l)
                if (q % 2 == 1) {
                    inblock = 0
                    # arguments follow the LAST quote on the closing line
                    p = lastq(l)
                    args = substr(l, p + 1)
                    check(startfn, startline, args)
                }
                continue
            }

            # skip full-line comments
            if (l ~ /^[ \t]*#/) continue
            if (l !~ /(^|[ \t;(&|=$"`])awk[ \t]/) continue

            # everything from the awk token onward
            p = index(l, "awk")
            rest = substr(l, p)
            q = countq(rest)
            if (q == 0) continue          # no single-quoted program: awk "…" or awk -f
            if (q % 2 == 1) {             # program opens here, closes on a later line
                inblock = 1
                startline = i
                startfn = fn
                continue
            }
            # balanced on this line: single-line awk, args are whatever follows
            check(fn, i, rest)
        }
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
        # strip a trailing shell comment
        a = args
        if (a ~ /\.(yml|yaml)([^A-Za-z0-9_]|$)/) { emit(f, ln, a); return }
        while (match(a, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
            v = substr(a, RSTART, RLENGTH)
            gsub(/[${}]/, "", v)
            if (v in yamlvar) { emit(f, ln, args); return }
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

# ------------------------------------------------------------------ baseline
if [ "$UPDATE_BASELINE" -eq 1 ]; then
    {
        echo "# .yq-first-baseline — pre-existing AWK YAML parsers (ADR-0015)."
        echo "# SHRINK-ONLY: entries may be DELETED (when converted to yq) but never added"
        echo "# by hand. Regenerate with: scripts/ci/lint-yq-first.sh --update-baseline"
        echo "# Key = <path>::<enclosing shell function>."
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
