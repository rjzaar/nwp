#!/bin/bash
set -euo pipefail

################################################################################
# pl clip — clip-review corpus operations (nwp/ops#358)
#
# Today this verb owns ONE job: getting the 609 contested clip pairs from the
# host that built them onto the site that reviews them, without anybody
# reaching for scp.
#
# WHY THIS IS A VERB AND NOT A SHELL LINE
# ---------------------------------------
# The artefact is built on one host and reviewed on a site elsewhere, so the
# bytes cross a machine boundary. Everything that makes that crossing trusted —
# verifying the sha256 sidecar, asserting the row count, refusing a partial
# store, dry-run by default — is a guarantee that a hand-rolled
# `scp … && drush …` silently drops. `sync_review_slots.py` was exactly that
# shape: a python script on one laptop, no verb, no verification, and the
# corpus consequently lived in full on a single workstation (ops#328).
#
# THE TWO CHECKS, AND WHY BOTH
# ----------------------------
#   sha256    catches a file truncated or corrupted IN TRANSIT.
#   row count catches a file truncated and then RE-HASHED — a partial export, a
#             run that died at row 400, a sidecar regenerated over the partial
#             file. The hash is perfect and the artefact is still missing 209
#             pairs. This is the shape that actually happens; ops#357 is the
#             same defect one layer up.
#
# Both run HERE, in bash, before anything is copied anywhere, and BOTH run
# again inside the site via Pairs\PairImport. Defence in depth on purpose: the
# local check gives a fast, readable refusal, and the in-site check is the one
# that cannot be bypassed by a different caller.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
# impact_rm_scratch: the tree's single audited primitive for removing a
# throwaway directory this process created. Used instead of a bare recursive
# delete so a future edit that passes the wrong variable gets a refusal —
# and so this file does not read as manifest-class destruction to the
# impact-contract gate (its only deletions are its own mktemp staging dirs).
source "$PROJECT_ROOT/lib/impact.sh"

# The artefact of record: 609 contested pairs, sha256 from its sidecar.
# Declared here so "609" is stated once on this side of the boundary.
CLIP_PAIRS_EXPECTED_ROWS="${CLIP_PAIRS_EXPECTED_ROWS:-609}"
# The build host is NOT hard-coded. This repo is publicly mirrored, so an
# internal host name may not appear in it (the gitleaks ruleset enforces that,
# and refused this file when it did). Set NWP_CLIP_PAIRS_HOST, or pass --from.
CLIP_PAIRS_DEFAULT_HOST="${NWP_CLIP_PAIRS_HOST:-}"
CLIP_PAIRS_DEFAULT_PATH="${CLIP_PAIRS_DEFAULT_PATH:-clip-pool/shortlist/contested-pairs.jsonl}"

show_help() {
    cat << EOF
${BOLD}pl clip${NC} — clip-review corpus operations

${BOLD}USAGE:${NC}
    pl clip pairs import <site> [options]   Import the contested-pairs artefact
    pl clip pairs verify [options]          Verify the artefact, import nothing
    pl clip pairs progress <site>           How many of the 609 are resolved

${BOLD}WHAT "IMPORT" DOES:${NC}
    1. fetches contested-pairs.jsonl + its .sha256 sidecar from the build host
    2. verifies the sha256 — a mismatch REFUSES, nothing is copied onward
    3. asserts the row count (default ${CLIP_PAIRS_EXPECTED_ROWS}) — a truncated file whose
       sidecar was regenerated passes the hash and fails HERE
    4. hands the verified file to the site, which re-validates it and stores
       all rows or none

${BOLD}OPTIONS:${NC}
    --from=<host>       Build host (or set NWP_CLIP_PAIRS_HOST)
    --remote-path=<p>   Path on that host (default: ~/${CLIP_PAIRS_DEFAULT_PATH})
    --file=<path>       Use a LOCAL artefact instead of fetching
    --expected-rows=<n> Row count to assert (default: ${CLIP_PAIRS_EXPECTED_ROWS})
    --tier=<t>          Site tier: dev (default) | stg | live
    --apply             Actually store. Without it this is a DRY RUN.
    -h, --help          This help

${BOLD}EXAMPLES:${NC}
    pl clip pairs verify --from=<build-host> # is the artefact whole?
    pl clip pairs import nwc                 # dry run against the dev site
    pl clip pairs import nwc --apply         # store all 609
    pl clip pairs progress nwc               # N of 609 resolved

${BOLD}WHY DRY-RUN IS THE DEFAULT:${NC}
    Importing rewrites the pair corpus an author is working through. A dry run
    proves the bytes are good and the site is reachable without touching it.
EOF
}

# ── Fetch ─────────────────────────────────────────────────────────────────────

# Bring the artefact and its sidecar to a local staging dir.
#
# Uses scp INSIDE the verb, which is the point of having a verb: the copy is
# wrapped in the verification the standing order exists to preserve, rather
# than being the whole of what the operator types.
_clip_pairs_fetch() {
    local host="$1" remote_path="$2" dest_dir="$3"

    if [ -z "$host" ]; then
        print_status "FAIL" "No build host. Pass --from=<host> or set NWP_CLIP_PAIRS_HOST."
        return 2
    fi
    print_status "INFO" "Fetching ${host}:~/${remote_path}"
    if ! scp -q "${host}:${remote_path}" "${dest_dir}/contested-pairs.jsonl" 2>/dev/null; then
        print_status "FAIL" "Could not fetch the artefact from ${host}:${remote_path}"
        return 2
    fi
    if ! scp -q "${host}:${remote_path}.sha256" "${dest_dir}/contested-pairs.jsonl.sha256" 2>/dev/null; then
        # Fail closed. A sidecar we could not fetch is not a sidecar we may
        # skip: the whole reason to check is that the bytes crossed a machine.
        print_status "FAIL" "No .sha256 sidecar at ${host}:${remote_path}.sha256 — refusing to import unverified bytes."
        return 2
    fi
    return 0
}

# ── Verify ────────────────────────────────────────────────────────────────────

# Verify a local artefact: sha256 against its sidecar, then the row count.
#
# Returns 0 verified · 1 REFUSED · 2 cannot verify (missing file/tool).
_clip_pairs_verify() {
    local file="$1" expected_rows="$2"
    local sidecar="${file}.sha256"

    if [ ! -r "$file" ]; then
        print_status "FAIL" "Not a readable file: $file"
        return 2
    fi
    if [ ! -r "$sidecar" ]; then
        print_status "FAIL" "No sidecar at $sidecar — refusing to import unverified bytes."
        return 2
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        # An absent tool is CANNOT VERIFY, never a pass.
        print_status "FAIL" "sha256sum is not available; cannot verify the artefact."
        return 2
    fi

    local declared actual
    declared="$(awk '{print tolower($1); exit}' "$sidecar")"
    actual="$(sha256sum "$file" | awk '{print $1}')"

    if [ -z "$declared" ]; then
        print_status "FAIL" "The sidecar $sidecar declares no hash."
        return 2
    fi
    if [ "$declared" != "$actual" ]; then
        print_status "FAIL" "sha256 MISMATCH — this is not the artefact the sidecar describes."
        echo "    expected: $declared"
        echo "    actual:   $actual"
        echo "    Nothing imported."
        return 1
    fi
    print_status "OK" "sha256 verified: $actual"

    # A file truncated MID-LINE keeps its line count — the last line is simply
    # shorter — so the count check below would pass it. The signature of that
    # truncation is a missing final newline, and it is cheap to test for.
    # Found by tests/unit/test-clip-pairs-import.bats, which caught this verb
    # accepting a mid-line truncation on its first run.
    if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
        print_status "FAIL" "The artefact does not end with a newline — it is TRUNCATED MID-LINE."
        echo "    The row count cannot see this: the final line is still counted, just incomplete."
        echo "    Nothing imported."
        return 1
    fi

    # The count. Deliberately separate from the hash: a file truncated and then
    # re-hashed has a perfect sidecar and the wrong number of pairs.
    local rows
    rows="$(grep -c '[^[:space:]]' "$file" || true)"
    if [ "$rows" != "$expected_rows" ]; then
        print_status "FAIL" "Row count MISMATCH — expected ${expected_rows}, found ${rows}."
        echo "    A hash can be regenerated over a truncated file; the count is what catches that."
        echo "    Nothing imported."
        return 1
    fi
    print_status "OK" "row count verified: ${rows} pairs"
    return 0
}

# ── Site plumbing ─────────────────────────────────────────────────────────────

# Run drush for a site/tier, returning its exit status.
_clip_drush() {
    local site="$1" tier="$2"; shift 2
    local site_path
    site_path="$(_clip_site_path "$site" "$tier")" || return 2
    (cd "$site_path" && ddev drush "$@")
}

_clip_site_path() {
    local site="$1" tier="$2"
    local path="${PROJECT_ROOT}/sites/${site}/${tier}"
    if [ ! -d "$path" ]; then
        print_status "FAIL" "No such site/tier: sites/${site}/${tier}" >&2
        return 2
    fi
    echo "$path"
}

# ── Subcommands ───────────────────────────────────────────────────────────────

cmd_pairs_verify() {
    local file="" host="$CLIP_PAIRS_DEFAULT_HOST" remote_path="$CLIP_PAIRS_DEFAULT_PATH"
    local expected_rows="$CLIP_PAIRS_EXPECTED_ROWS"

    while [ $# -gt 0 ]; do
        case "$1" in
            --file=*)          file="${1#*=}" ;;
            --from=*)          host="${1#*=}" ;;
            --remote-path=*)   remote_path="${1#*=}" ;;
            --expected-rows=*) expected_rows="${1#*=}" ;;
            -h|--help)         show_help; return 0 ;;
            *) print_status "FAIL" "Unknown option: $1"; return 2 ;;
        esac
        shift
    done

    local staging="" rc=0
    if [ -z "$file" ]; then
        staging="$(mktemp -d)"
        # shellcheck disable=SC2064
        trap "impact_rm_scratch '$staging' >/dev/null || true" RETURN
        _clip_pairs_fetch "$host" "$remote_path" "$staging" || return $?
        file="${staging}/contested-pairs.jsonl"
    fi

    _clip_pairs_verify "$file" "$expected_rows" || rc=$?
    if [ "$rc" -eq 0 ]; then
        print_status "OK" "Artefact is whole: ${expected_rows} contested pairs."
    fi
    return "$rc"
}

cmd_pairs_import() {
    local site="" tier="dev" apply="false" file=""
    local host="$CLIP_PAIRS_DEFAULT_HOST" remote_path="$CLIP_PAIRS_DEFAULT_PATH"
    local expected_rows="$CLIP_PAIRS_EXPECTED_ROWS"

    while [ $# -gt 0 ]; do
        case "$1" in
            --file=*)          file="${1#*=}" ;;
            --from=*)          host="${1#*=}" ;;
            --remote-path=*)   remote_path="${1#*=}" ;;
            --expected-rows=*) expected_rows="${1#*=}" ;;
            --tier=*)          tier="${1#*=}" ;;
            --apply)           apply="true" ;;
            -h|--help)         show_help; return 0 ;;
            -*) print_status "FAIL" "Unknown option: $1"; return 2 ;;
            *)  site="$1" ;;
        esac
        shift
    done

    if [ -z "$site" ]; then
        print_status "FAIL" "Which site? e.g. pl clip pairs import nwc"
        return 2
    fi

    local staging=""
    if [ -z "$file" ]; then
        staging="$(mktemp -d)"
        # shellcheck disable=SC2064
        trap "impact_rm_scratch '$staging' >/dev/null || true" RETURN
        _clip_pairs_fetch "$host" "$remote_path" "$staging" || return $?
        file="${staging}/contested-pairs.jsonl"
    fi

    # Verify BEFORE resolving the site, and before the file goes anywhere near
    # it. Two reasons, both learned the hard way:
    #   * a bad artefact should refuse identically whether or not the site
    #     happens to exist — otherwise "No such site" masks "your file is
    #     corrupt", and the operator fixes the wrong thing;
    #   * a git worktree shadows sites/, so a guard that resolves the site
    #     first reports a site problem for every artefact, good or bad. That
    #     false-verdict shape is recorded in this estate already.
    local rc=0
    _clip_pairs_verify "$file" "$expected_rows" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    local site_path
    site_path="$(_clip_site_path "$site" "$tier")" || return 2

    # Stage the artefact where the site's container can read it. Kept beside
    # the site rather than in /tmp so a failed import leaves evidence.
    local drop_dir="${site_path}/.nwp-import"
    mkdir -p "$drop_dir"
    cp "$file" "${drop_dir}/contested-pairs.jsonl"
    cp "${file}.sha256" "${drop_dir}/contested-pairs.jsonl.sha256"

    if [ "$apply" != "true" ]; then
        print_status "INFO" "DRY RUN — verifying against the site, storing nothing."
        _clip_drush "$site" "$tier" nwc:pairs-import \
            "/var/www/html/.nwp-import/contested-pairs.jsonl" \
            --expected-rows="$expected_rows" --dry-run || return 1
        echo
        print_status "OK" "Dry run complete. Re-run with --apply to store ${expected_rows} pairs."
        return 0
    fi

    print_status "INFO" "Importing ${expected_rows} contested pairs into ${site}/${tier}…"
    if ! _clip_drush "$site" "$tier" nwc:pairs-import \
        "/var/www/html/.nwp-import/contested-pairs.jsonl" \
        --expected-rows="$expected_rows"; then
        print_status "FAIL" "The site refused or partially stored the artefact. Nothing is assumed."
        return 1
    fi
    print_status "OK" "Imported. Authors review at /admin/review/clips/pairs"
    return 0
}

cmd_pairs_progress() {
    local site="" tier="dev"
    while [ $# -gt 0 ]; do
        case "$1" in
            --tier=*)  tier="${1#*=}" ;;
            -h|--help) show_help; return 0 ;;
            -*) print_status "FAIL" "Unknown option: $1"; return 2 ;;
            *)  site="$1" ;;
        esac
        shift
    done
    if [ -z "$site" ]; then
        print_status "FAIL" "Which site? e.g. pl clip pairs progress nwc"
        return 2
    fi
    _clip_drush "$site" "$tier" nwc:pairs-progress
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

main() {
    local group="${1:-}" ; shift || true
    case "$group" in
        pairs)
            local sub="${1:-}" ; shift || true
            case "$sub" in
                import)   cmd_pairs_import "$@" ;;
                verify)   cmd_pairs_verify "$@" ;;
                progress) cmd_pairs_progress "$@" ;;
                ""|-h|--help) show_help ;;
                *) print_status "FAIL" "Unknown: pl clip pairs $sub"; show_help; return 2 ;;
            esac
            ;;
        ""|-h|--help) show_help ;;
        *) print_status "FAIL" "Unknown: pl clip $group"; show_help; return 2 ;;
    esac
}

main "$@"
