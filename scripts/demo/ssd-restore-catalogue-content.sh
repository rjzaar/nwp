#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/ssd-restore-catalogue-content.sh — restore the canonical quiz
# items (and audio fallback clips) to the imported catalogue courses.
#
#   scripts/demo/ssd-restore-catalogue-content.sh [--site=ssd] [--tier=dev]
#                                                 [--check] [--payload=FILE]
#
# See ssd-restore-catalogue-content.php for the defect this repairs (the
# pre-e9c596f build_json.py stripped quiz_items out of every learning point, so
# the 2026-07-11 mbz — and everything restored from it — never had them).
#
# THREE PHASES, so that the bytes written are bytes a validator approved:
#   1. --dump        read-only on the target; pull every row's content_json.
#   2. --merge-local on THIS machine; apply the merge, then hand every merged
#                    document to the ONE schema validator we have —
#                    ssd-seed-courses.php --validate-file= — and record a
#                    sha256 per row. Any SCHEMA-FAIL aborts before any write.
#   3. --apply       on the target; re-run the same merge and write only rows
#                    whose result hashes to the validated value.
#
# Stages the .php into the Moodle root, runs it, removes it again — the same
# gated idiom as ssd-seed-courses.sh (ops#146: live allowed, prod refused).
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/demo-pair.sh"

SITE="ssd"; TIER="dev"; CHECK="false"
PAYLOAD="$REPO_ROOT/servers/live/demo/ssd-catalogue-content.json"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*)    SITE="${1#--site=}"; shift ;;
        --tier=*)    TIER="${1#--tier=}"; shift ;;
        --payload=*) PAYLOAD="${1#--payload=}"; shift ;;
        --check)     CHECK="true"; shift ;;
        *) print_error "Unknown option '$1'"; exit 1 ;;
    esac
done

# Same tier posture as the seeder: this writes only catalogue CONTENT into a
# demo site. prod stays refused — a prod Moodle holds real learners' records.
case "$TIER" in dev|stg|live) ;; *) print_error "REFUSED: tier '$TIER' — dev|stg|live only."; exit 1 ;; esac

[[ -f "$PAYLOAD" ]] || { print_error "REFUSED: payload not found: $PAYLOAD"; exit 1; }

if [[ "$TIER" != "live" ]]; then
    MOODLE_ROOT="$(resolve_project "$SITE" "$TIER")" || { print_error "Cannot resolve $SITE ($TIER)"; exit 1; }
    [[ -f "$MOODLE_ROOT/version.php" ]] || { print_error "REFUSED: $MOODLE_ROOT is not a Moodle root"; exit 1; }
    [[ -d "$MOODLE_ROOT/mod/depthcontent" ]] || {
        print_error "REFUSED: mod_depthcontent not installed — run scripts/demo/ssd-rebuild.sh first."
        exit 1
    }
fi

CONTRACT="$(demo_pair_contract_for "$SITE")" || { print_error "REFUSED: no demo-enabled pair contract names '$SITE'."; exit 1; }
CLI_PHP="${CLI_PHP:-$(demo_pair_get "$CONTRACT" '.oidc.cli_php_version' '8.3')}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SRC="$SCRIPT_DIR/ssd-restore-catalogue-content.php"

# ── Phase 1: read-only dump from the target ────────────────────────────────
print_status "INFO" "phase 1/3: reading current content_json from $SITE ($TIER)"
set +e
demo_moodle_php_run "$SITE" "$TIER" "$SRC" "$CLI_PHP" -- --dump > "$WORK/dump.raw" 2>"$WORK/dump.err"
rc=$?
set -e
(( rc == 0 )) || { print_error "dump failed (rc=$rc)"; cat "$WORK/dump.err" >&2; exit "$rc"; }
sed -n '/^NWPDUMP-BEGIN$/,/^NWPDUMP-END$/p' "$WORK/dump.raw" | sed '1d;$d' > "$WORK/dump.json"
[[ -s "$WORK/dump.json" ]] || { print_error "dump produced nothing (no NWPDUMP sentinel)"; exit 1; }

# ── Phase 2: merge here, then validate with the ONE schema validator ───────
print_status "INFO" "phase 2/3: merging and validating against the depthcontent reader schema"
php "$SRC" --merge-local="$WORK/dump.json" --payload="$PAYLOAD" \
    --out-dir="$WORK/merged" --manifest="$WORK/manifest.json" || {
    print_error "local merge failed"; exit 1; }

VALIDATOR="$SCRIPT_DIR/ssd-seed-courses.php"
[[ -f "$VALIDATOR" ]] || { print_error "REFUSED: schema validator not found: $VALIDATOR"; exit 1; }
nfiles=0; nbad=0
shopt -s nullglob
for f in "$WORK"/merged/row-*.json; do
    nfiles=$(( nfiles + 1 ))
    if ! out="$(php "$VALIDATOR" --validate-file="$f" 2>&1)"; then
        nbad=$(( nbad + 1 ))
        print_error "SCHEMA-FAIL $(basename "$f"): $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    fi
done
shopt -u nullglob
if (( nbad > 0 )); then
    print_error "REFUSED: $nbad/$nfiles merged documents fail the depthcontent reader schema — nothing written."
    exit 1
fi
if (( nfiles == 0 )); then
    print_status "OK" "$SITE catalogue content already current — nothing to restore"
    exit 0
fi
print_status "OK" "phase 2/3: $nfiles merged documents validated clean"

# ── Phase 3: splice payload + manifest into the script and apply ───────────
# Single-quoted heredocs: no interpolation, no escaping, and the terminators
# cannot occur in JSON. The generated file is the repo file plus data.
splice() {
    local var="$1" marker="$2" datafile="$3" infile="$4" outfile="$5"
    {
        sed "/${marker}/,\$d" "$infile"
        echo "\$${var} = <<<'NWPJSONDATA'"
        cat "$datafile"
        echo
        echo "NWPJSONDATA;"
        sed -n "/${marker}/,\$p" "$infile" | tail -n +2
    } > "$outfile"
}
splice PAYLOAD_INLINE  '__NWP_PAYLOAD_HEREDOC__'  "$PAYLOAD"           "$SRC"            "$WORK/s1.php"
splice MANIFEST_INLINE '__NWP_MANIFEST_HEREDOC__' "$WORK/manifest.json" "$WORK/s1.php"   "$WORK/staged.php"
php -l "$WORK/staged.php" >/dev/null || { print_error "spliced script does not parse"; exit 1; }

PASS=""; [[ "$CHECK" == "true" ]] && PASS="--check"
print_status "INFO" "phase 3/3: applying to $SITE ($TIER)${PASS:+ [check-only]}"
set +e
demo_moodle_php_run "$SITE" "$TIER" "$WORK/staged.php" "$CLI_PHP" -- $PASS
rc=$?
set -e

if [[ "$CHECK" == "true" ]]; then
    (( rc == 0 )) && print_status "OK" "$SITE catalogue content restore is clean to apply" \
                  || print_status "FAIL" "$SITE catalogue content restore would not apply cleanly"
    exit "$rc"
fi
(( rc == 0 )) || { print_error "Restore failed (rc=$rc)"; exit "$rc"; }
print_status "OK" "$SITE catalogue quiz/audio content restored"
