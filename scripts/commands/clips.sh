#!/bin/bash
set -uo pipefail
################################################################################
# pl clips — clip-catalogue referential integrity
#
# ── WHY THIS IS A VERB ────────────────────────────────────────────────────────
#
# The clip catalogue's 176 `video:` blocks are a promise to an author: "click
# here and you will hear this teaching." nwp/ops#349 established that all 176
# are machine output from a 2026-03-08 regex scrape, so there is no editorial
# authority in them to preserve — only a first pass with known breakage.
#
# Improving WHICH clip is chosen needs relevance judgement and a gold set that
# does not exist (ops#348). This verb deliberately answers only the questions
# that need neither: does the window EXIST, does it PLAY, is it HONESTLY
# LABELLED. Those three are provable today against local artefacts, so they are
# the highest-certainty value available in this programme.
#
# It is a verb rather than a script in ~/dir for two reasons. First, the
# standing order: everything on this estate goes through `pl`, and a check that
# only one session knows how to run is a check nobody runs again. Second,
# ops#338 (where the dir code should live) is an OPEN operator decision, so new
# code must not accrete in ~/dir while that is undecided.
#
# ── FAIL-CLOSED ───────────────────────────────────────────────────────────────
#
#   exit 0   clean
#   exit 1   defects found
#   exit 2   CANNOT VERIFY — a duration could not be read, a transcript is
#            missing, or a truncated summary has no recoverable source.
#
# exit 2 DOMINATES exit 1. A run that could not evaluate every block reports 2
# even when it also found real defects, because a partial verdict must never be
# readable as a complete one. Grade an exit 2 AMBER; never count it as a pass.
#
# ── SOURCES ───────────────────────────────────────────────────────────────────
#
# All four are local. Nothing in this verb touches the network — the corpus is
# derivative-cleared-pending and stays on this machine.
#
#   catalogue          the `video:` blocks under review
#   episode transcripts word-timed ASR of the PODCAST — measures episode length
#                      and supplies one side of the linkage evidence
#   video transcripts   word-timed ASR of the YOUTUBE videos — the other side
#   video index        per-video duration
#
# Override any of them with the NWP_CLIP_* environment variables below, which is
# also how the bats suite points the verb at a fixture catalogue.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#
#   pl clips verify [--verbose] [--json] [--only=CLASS,...] [--no-linkage]
#   pl clips repair [--apply] [--fix-derived] [--json] [--no-linkage]
#   pl clips sources
#
# `repair` is DRY RUN by default and repairs only what needs no judgement:
# it completes a truncated summary from the same learning point's own
# `standard.text`, and stamps unfilled slots, unplayable windows and measured
# linkage verdicts. It never chooses a replacement window or a replacement
# video — that is a judgement, and this verb does not make judgements.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
[ -f "$PROJECT_ROOT/lib/common.sh" ] && source "$PROJECT_ROOT/lib/common.sh"

HELPER="$PROJECT_ROOT/scripts/lib/clip-integrity.py"

# Defaults are the estate's real corpus locations, recorded here rather than in
# a session's shell history.
CLIP_CATALOG="${NWP_CLIP_CATALOG:-$HOME/dir/courses_v3/catalog}"
CLIP_TRANSCRIPTS="${NWP_CLIP_TRANSCRIPTS:-$HOME/dir/transcripts/whisper_merged}"
CLIP_VIDEO_TRANSCRIPTS="${NWP_CLIP_VIDEO_TRANSCRIPTS:-$HOME/sd/transcripts/whisper_large_fp16}"
CLIP_VIDEO_INDEX="${NWP_CLIP_VIDEO_INDEX:-$HOME/sd/data/videos.json}"

_err() { printf 'ERROR: %s\n' "$*" >&2; }

usage() {
    sed -n '3,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cmd_sources() {
    local rc=0 label path
    printf '%-20s %s\n' "SOURCE" "PATH"
    for pair in \
        "catalogue:$CLIP_CATALOG" \
        "episode-transcripts:$CLIP_TRANSCRIPTS" \
        "video-transcripts:$CLIP_VIDEO_TRANSCRIPTS" \
        "video-index:$CLIP_VIDEO_INDEX"; do
        label="${pair%%:*}"; path="${pair#*:}"
        if [ -e "$path" ]; then
            printf '%-20s %s\n' "$label" "$path"
        else
            printf '%-20s %s  [MISSING]\n' "$label" "$path"
            rc=2
        fi
    done
    [ "$rc" -ne 0 ] && printf '\nCANNOT VERIFY: a source above is missing.\n' >&2
    return "$rc"
}

run_helper() {
    local mode="$1"; shift
    if [ ! -f "$HELPER" ]; then
        _err "helper missing: $HELPER"
        return 2
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        _err "python3 is required"
        return 2
    fi
    python3 "$HELPER" "$mode" \
        --catalog "$CLIP_CATALOG" \
        --transcripts "$CLIP_TRANSCRIPTS" \
        --video-transcripts "$CLIP_VIDEO_TRANSCRIPTS" \
        --video-index "$CLIP_VIDEO_INDEX" \
        "$@"
}

main() {
    local sub="${1:-}"; shift || true
    local -a passthru=()
    local linkage="--linkage"

    for arg in "$@"; do
        case "$arg" in
            --no-linkage) linkage="" ;;
            --only=*)     passthru+=(--only "${arg#*=}") ;;
            --json|--verbose|--apply|--fix-derived) passthru+=("$arg") ;;
            --catalog=*)  CLIP_CATALOG="${arg#*=}" ;;
            -h|--help)    usage; return 0 ;;
            *)            _err "unknown option: $arg"; return 1 ;;
        esac
    done
    [ -n "$linkage" ] && passthru+=("$linkage")

    case "$sub" in
        verify)  run_helper verify "${passthru[@]}" ;;
        repair)  run_helper repair "${passthru[@]}" ;;
        sources) cmd_sources ;;
        ""|-h|--help|help) usage ;;
        *) _err "unknown subcommand: $sub"; usage; return 1 ;;
    esac
}

main "$@"
