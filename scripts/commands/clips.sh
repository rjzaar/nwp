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
#   pl clips finish [--json]
#   pl clips sources
#
#   pl clips calibrate packet --rater=<id> [--rater=<id> ...] [--out=DIR]
#                             [--exclusions=FILE]
#   pl clips calibrate score  <answers.json> [<answers.json> ...] [--boot=N]
#   pl clips calibrate status
#
# ── `calibrate` — THE PANEL INSTRUMENT (P79, ops#348) ─────────────────────────
#
# The operator ruled that the calibration set is "really for the media guild to
# do". That is not a relabelling: with one assessor the four P78 4.4 gates
# measure operator-vs-machine, and with N members they also measure
# HUMAN-vs-HUMAN — the one quantity no machine measurement can supply, because
# every judging instance was the same model and a bias they share is invisible
# by construction (P78 5.2.7).
#
#   packet   builds ONE blinded packet per rater. Each rater gets their own
#            presentation seed, so order effects are not correlated across the
#            panel, and anti-self-review exclusions are applied at BUILD time —
#            an item a rater must not judge is not in their packet at all.
#            REFUSES to write member-facing excerpts inside this repository,
#            which is publicly mirrored (ADR-0039 / P78 6).
#
#   score    takes N answers files, joins each through its own packet, and runs
#            the generalised gates. Gate 0 (panel coherence) is evaluated FIRST
#            and DOMINATES: a panel that did not agree with itself has not
#            measured the machine, so it may not discard the labels — even when
#            Gates 1, 2 and 4 all say DISCARD.
#
# It degrades to N = 1 without changing the artefact format: same answers file,
# one per rater. At N = 1 Gates 0, 1b and 3b report NOT ARMED and the run is the
# instrument P78 already committed. Arming follows a declared fact — how many
# answers files exist — never a flag.
#
# `repair` is DRY RUN by default and repairs only what needs no judgement:
# it completes a truncated summary from the same learning point's own
# `standard.text`, and stamps unfilled slots, unplayable windows and measured
# linkage verdicts. It never chooses a replacement window or a replacement
# video — that is a judgement, and this verb does not make judgements.
#
# ── `finish` — WHAT IS STILL OWED ON THE CLIP PROGRAMME ───────────────────────
#
# The completion process. It answers one question for an operator sitting down
# cold with no memory of the session that produced any of this: WHAT IS OWED,
# IN WHAT ORDER, AND WHAT IS THE COMMAND.
#
# **It measures; it does not assert.** There is deliberately no checklist in
# this file. A hand-written checklist is stale the day after it is written and
# cannot say so — which is exactly why the estate split OPERATING-MODEL.md into
# hand-written doctrine plus a generated state block. Every line `finish` prints
# is read from a live artefact, a live repo or a live API at run time, and every
# line carries the command that produced it so the reader can re-take the
# reading rather than trust this one.
#
# Where it cannot look, it says CANNOT VERIFY and exits 2. An unreachable
# measurement host must never render as "nothing outstanding".
#
#   exit 0   nothing owed
#   exit 1   work is owed (the normal state)
#   exit 2   CANNOT VERIFY — a source could not be read. DOMINATES exit 1.
#
# The calibration set is printed FIRST, and the reason is printed with it:
# everything the machines established about this corpus is RELIABILITY, and all
# sixteen judging instances were one model, so a bias they share is invisible by
# construction. Only the operator's own judgements speak to VALIDITY.
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

# ── `finish` sources ──────────────────────────────────────────────────────────
# All overridable, which is also how the bats suite points `finish` at fixtures
# where the shortlist sha mismatches, the host is unreachable and the answers
# are absent — the three red states it must be able to report.
FINISH_HELPER="$PROJECT_ROOT/scripts/lib/clip-finish-shortlist.py"
CLIP_CAL_DIR="${NWP_CLIPS_CAL_DIR:-$HOME/dir/courses_v3/reports}"
CLIP_SCORER_DIR="${NWP_CLIPS_SCORER_DIR:-$HOME/dir/courses_v3/silver-labels-2026-08-11}"
CLIP_DIR_REPO="${NWP_CLIPS_DIR_REPO:-$HOME/dir}"
CLIP_DIR_BRANCH="${NWP_CLIPS_DIR_BRANCH:-clip-integrity-ops352}"
# The clip pool lives on the AI host. Its real name is NOT written here: this
# repo is publicly mirrored (ADR-0039 / ops#326), so the host is named by the
# same generic alias `pl ai-host` already uses, and resolved from the operator's
# ssh config. Reusing that one declared fact rather than adding a rival is the
# point — a host named in two places is a host that drifts.
# `local` runs the measurement here instead of over ssh (fixtures, and a host
# that has been retired). Anything else is an ssh destination.
CLIP_POOL_HOST="${NWP_CLIPS_POOL_HOST:-${NWP_AI_HOST_SSH:-${NWP_MINI_SSH_HOST:-ai-host}}}"
CLIP_POOL_SHORTLIST="${NWP_CLIPS_POOL_SHORTLIST:-\$HOME/clip-pool/shortlist}"
CLIP_POOL_WORK="${NWP_CLIPS_POOL_WORK:-\$HOME/clip-pool/work-d234}"
CLIP_SSH_TIMEOUT="${NWP_CLIPS_SSH_TIMEOUT:-10}"
# The ops issues this programme is blocked on. Their STATE is fetched live; only
# the numbers are recorded here, because a number is an address and a state is a
# measurement.
CLIP_OPS_DECISION="${NWP_CLIPS_OPS_DECISION:-338}"
CLIP_OPS_BLOCKERS="${NWP_CLIPS_OPS_BLOCKERS:-351 353}"
CLIP_OPS_PROJECT="${NWP_OPS_PROJECT_ID:-21}"
# The three files whose SIGPIPE-prone pipelines were left for operator review.
CLIP_SIGPIPE_FILES="${NWP_CLIPS_SIGPIPE_FILES:-scripts/commands/secrets.sh scripts/commands/live.sh scripts/commands/live2prod.sh}"

_err() { printf 'ERROR: %s\n' "$*" >&2; }

usage() {
    sed -n '3,119p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

################################################################################
# pl clips finish
################################################################################

# Worst-of accumulator. 2 (CANNOT VERIFY) dominates 1 (owed), which dominates 0,
# so a run that could not look is never readable as a clean one.
F_RC=0
_f_rc() { case "$1" in 2) F_RC=2 ;; 1) [ "$F_RC" -eq 0 ] && F_RC=1 ;; esac; }

_f_c() { # colour by status word, degrading to plain when common.sh is absent
    case "$1" in
        OWED)          printf '%s' "${YELLOW:-}" ;;
        "CANNOT VERIFY") printf '%s' "${RED:-}" ;;
        DONE)          printf '%s' "${GREEN:-}" ;;
    esac
}

_f_head() { # $1=n $2=title $3=status
    printf '\n%s%s%s  %s%s%s\n' "${BOLD:-}" "  $1  $2" "${NC:-}" \
        "$(_f_c "$3")" "[$3]" "${NC:-}"
    case "$3" in
        OWED) _f_rc 1 ;;
        "CANNOT VERIFY") _f_rc 2 ;;
    esac
}
_f_say()  { printf '     %s\n' "$*"; }
_f_read() { printf '     %sread: %s%s\n' "${DIM:-}" "$*" "${NC:-}"; }
_f_next() { printf '     %snext: %s%s\n' "${BOLD:-}" "$*" "${NC:-}"; }
_f_cv()   { printf '     %sCANNOT VERIFY: %s%s\n' "${RED:-}" "$*" "${NC:-}"; }

# ── 1. the calibration set ───────────────────────────────────────────────────
_f_calibration() {
    local set_md="$CLIP_CAL_DIR/CALIBRATION-SET.md"
    local tmpl="$CLIP_CAL_DIR/answers-template.json"
    local ans="${NWP_CLIPS_ANSWERS:-$CLIP_CAL_DIR/answers.json}"
    local scorer="$CLIP_SCORER_DIR/score_calibration.py"

    if [ ! -f "$set_md" ]; then
        _f_head 1 "CALIBRATION SET — the only thing that can speak to VALIDITY" "CANNOT VERIFY"
        _f_cv "the calibration set is not on this machine: $set_md"
        return
    fi

    local total=0 graded=0
    if [ -f "$tmpl" ]; then
        total=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$tmpl" 2>/dev/null || echo 0)
    fi
    if [ -f "$ans" ]; then
        graded=$(python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(-1); raise SystemExit
print(sum(1 for v in d.values() if v is not None))' "$ans" 2>/dev/null || echo -1)
    fi

    if [ "$total" -eq 0 ]; then
        _f_head 1 "CALIBRATION SET — the only thing that can speak to VALIDITY" "CANNOT VERIFY"
        _f_cv "cannot count the items: $tmpl is missing or unreadable"
        _f_read "$set_md"
        return
    fi

    if [ ! -f "$ans" ] || [ "$graded" -le 0 ]; then
        _f_head 1 "CALIBRATION SET — the only thing that can speak to VALIDITY" "OWED"
        _f_say "WHY THIS IS FIRST: every figure the machines produced about this corpus"
        _f_say "measures RELIABILITY (0.81 set agreement, weighted kappa 0.915). All sixteen"
        _f_say "judges were one model, so a bias they SHARE is invisible by construction."
        _f_say "Only your own judgements speak to VALIDITY. Nothing downstream is safe to"
        _f_say "believe until this is graded."
        if [ "$graded" -lt 0 ]; then
            _f_cv "$ans exists but is not readable json"
            _f_rc 2
        else
            _f_say "0 of $total judgements graded — not started. 60–90 minutes, four gates"
            _f_say "with thresholds committed in advance (P78 §4.4); the test CAN fail."
        fi
        _f_read "$set_md"
        _f_next "cp $tmpl $ans   # then grade, then:"
        _f_next "python3 $scorer $ans"
        return
    fi

    if [ "$graded" -lt "$total" ]; then
        _f_head 1 "CALIBRATION SET — the only thing that can speak to VALIDITY" "OWED"
        _f_say "$graded of $total judgements graded — in progress, not scoreable yet."
        _f_read "$ans"
        _f_next "python3 $scorer $ans"
        return
    fi

    # graded in full — score it, and report the scorer's own verdict
    if [ ! -f "$scorer" ]; then
        _f_head 1 "CALIBRATION SET — the only thing that can speak to VALIDITY" "CANNOT VERIFY"
        _f_cv "all $total graded, but the scorer is missing: $scorer"
        return
    fi
    local res rc
    res=$(python3 "$scorer" "$ans" 2>&1); rc=$?
    local overall
    overall=$(printf '%s' "$res" | python3 -c '
import json,sys
try: print(json.loads(sys.stdin.read()).get("OVERALL","(no OVERALL field)"))
except Exception: print("(scorer emitted no json)")' 2>/dev/null)
    case "$rc" in
        0) _f_head 1 "CALIBRATION SET — SCORED" "DONE" ;;
        2) _f_head 1 "CALIBRATION SET — SCORED" "CANNOT VERIFY" ;;
        *) _f_head 1 "CALIBRATION SET — SCORED" "OWED" ;;
    esac
    _f_say "all $total graded · scorer exit $rc"
    _f_say "$overall"
    printf '%s' "$res" | python3 -c '
import json,sys
try: r=json.loads(sys.stdin.read())
except Exception: sys.exit(0)
for k in ("gate1_screening_kappa","gate2_weighted_kappa",
          "gate3_directional_bias","gate4_controls"):
    v=r.get(k)
    if isinstance(v,dict): print("     %-26s %s"%(k.split("_")[0],v.get("verdict")))
' 2>/dev/null
    _f_read "$ans"
    _f_next "python3 $scorer $ans"
}

# ── 2. the shortlist and its unapplied remediation ───────────────────────────
_f_shortlist() {
    local title="SHORTLIST — 251 learning points, and a NAMED QUALITY BLOCKER"
    if [ ! -f "$FINISH_HELPER" ]; then
        _f_head 2 "$title" "CANNOT VERIFY"
        _f_cv "measurement helper missing: $FINISH_HELPER"
        return
    fi
    local raw rc
    if [ "$CLIP_POOL_HOST" = "local" ]; then
        raw=$(python3 "$FINISH_HELPER" "$CLIP_POOL_SHORTLIST" "$CLIP_POOL_WORK" 2>&1); rc=$?
    else
        raw=$(ssh -o BatchMode=yes -o ConnectTimeout="$CLIP_SSH_TIMEOUT" \
                  "$CLIP_POOL_HOST" python3 - "$CLIP_POOL_SHORTLIST" "$CLIP_POOL_WORK" \
                  < "$FINISH_HELPER" 2>&1); rc=$?
    fi
    if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
        _f_head 2 "$title" "CANNOT VERIFY"
        _f_cv "could not reach the measurement host '$CLIP_POOL_HOST' (ssh rc $rc)."
        _f_cv "an unreachable host is NOT 'nothing outstanding'."
        [ -n "$raw" ] && _f_say "$(printf '%s' "$raw" | head -2)"
        _f_next "pl server status $CLIP_POOL_HOST"
        return
    fi

    local kv
    kv=$(printf '%s' "$raw" | python3 -c '
import json,sys
def q(v): return "" if v is None else str(v)
try: r=json.loads(sys.stdin.read())
except Exception as e:
    print("PARSE_FAIL=1"); raise SystemExit
if not r.get("ok"):
    print("PARSE_FAIL=2")
    print("CV=%s"%json.dumps("; ".join(r.get("cannot_verify") or ["unspecified"]), ensure_ascii=False))
    raise SystemExit
d4=r.get("d4") or {}; d2=r.get("d2") or {}; d3=r.get("d3") or {}
ds=r.get("deep_signal") or {}
for k,v in [("LPS",r.get("lps")),("ROWS",r.get("rows")),
            ("SHA_MATCH",r.get("sha_match")),("SHA_A",(r.get("sha_actual") or "")[:12]),
            ("SHA_R",(r.get("sha_recorded") or "")[:12]),
            ("UNCAV",r.get("quote_outstanding_uncaveated")),
            ("CAV",r.get("quote_repaired_caveated")),
            ("NLFRAG",r.get("quote_not_located_fragments")),
            ("NOAUDIT",r.get("rows_without_quote_audit")),
            ("OVAPP",r.get("overlays_applied")),("D3APP",r.get("d3_ceiling_applied")),
            ("D2APP",r.get("d2_reasons_applied")),
            ("OVER420",r.get("rows_over_ceiling_420s")),
            ("NQP",r.get("rows_needing_quote_pass")),
            ("UNDER",r.get("lps_under_target")),
            ("D2LPS",d2.get("lps_examined")),("D2UNEX",d2.get("unexplained_drops")),
            ("D2UNEXLP",d2.get("unexplained_lps")),
            ("D3SWAP",d3.get("swapped")),("D3DROP",d3.get("dropped")),
            ("D4JUDGED",d4.get("judged")),("CONTESTED",d4.get("contested")),
            ("UNFORCED",d4.get("unforced")),("UNJUDGED",d4.get("contested_unjudged")),
            ("STRICT",d4.get("strict_survival_pct")),
            ("DEEPPOP",d4.get("population_deep_rows")),
            ("SAMPN",ds.get("sample_n")),("SAMPSURV",ds.get("sample_survived")),
            ("SAMPSEED",ds.get("sample_seed")),("DEEPROWS",ds.get("deep_rows")),
            ("DEEPREM",ds.get("remainder"))]:
    print("%s=%s"%(k,json.dumps(q(v),ensure_ascii=False)))
ci=d4.get("strict_ci95") or []
print("CI=%s"%json.dumps("%s-%s"%(ci[0],ci[1]) if len(ci)==2 else "", ensure_ascii=False))
v=d2.get("verdicts") or {}
print("D2V=%s"%json.dumps(", ".join("%s %d"%(k,v[k]) for k in sorted(v)), ensure_ascii=False))
print("CV=%s"%json.dumps("; ".join(r.get("cannot_verify") or []), ensure_ascii=False))
')
    eval "$kv" 2>/dev/null
    if [ "${PARSE_FAIL:-}" = "1" ]; then
        _f_head 2 "$title" "CANNOT VERIFY"
        _f_cv "the measurement host returned something that is not json"
        return
    fi
    if [ "${PARSE_FAIL:-}" = "2" ]; then
        _f_head 2 "$title" "CANNOT VERIFY"
        _f_cv "${CV:-unspecified}"
        return
    fi

    local status=OWED
    [ -n "${CV:-}" ] && status="CANNOT VERIFY"
    _f_head 2 "$title" "$status"

    _f_say "artefact: $LPS learning points, $ROWS candidate rows, $UNDER under target 16"
    if [ "$SHA_MATCH" = "True" ]; then
        _f_say "sha256 MATCHES the digest recorded beside it ($SHA_A…)"
    else
        _f_say "sha256 MISMATCH — recorded $SHA_R… actual $SHA_A…; the artefact has"
        _f_say "moved since its digest was written, so re-stamp it before quoting it"
        _f_rc 1
    fi

    printf '\n'
    _f_say "${BOLD:-}a) TOP OUTSTANDING ITEM — the contested deep third${NC:-}"
    _f_say "   ${CONTESTED:-?} of ${DEEPPOP:-?} deep rows are CONTESTED (a corroborated in-window"
    _f_say "   moment was passed over); ${UNFORCED:-?} are UNFORCED and displaced nothing."
    _f_say "   ${D4JUDGED:-0} were judged. STRICT SURVIVAL ${STRICT:-?}% (95% CI ${CI:-?}%)."
    _f_say "   ${RED:-}${UNJUDGED:-?} CONTESTED DEEP ROWS REMAIN UNJUDGED — nobody has looked at them.${NC:-}"
    _f_say "   This is a SAMPLE, not a census. The census was cut DELIBERATELY to protect"
    _f_say "   the operator's usage budget; it is named here so silence is not read as"
    _f_say "   coverage. Extrapolating the point estimate, roughly half the contested"
    _f_say "   rows would be better replaced by the moment they displaced — the recurring"
    _f_say "   shape is a book promotion, station ID or presenter chatter displacing a"
    _f_say "   moment that states the learning point outright."
    _f_next "ssh $CLIP_POOL_HOST 'python3 ~/clip-pool/work-d234/d4sample.py \\"
    _f_next "     ~/clip-pool/shortlist/SHORTLIST-16.jsonl 40'   # next deterministic batch"

    printf '\n'
    _f_say "${BOLD:-}b) THE REMEDIATION OVERLAYS ARE NOT APPLIED${NC:-}"
    if [ "$OVAPP" = "True" ]; then
        _f_say "   applied: ceiling ✓  shortfall reasons ✓ (measured in the base artefact)"
    else
        _f_say "   measured in the BASE artefact, not assumed: over-ceiling rows ${OVER420},"
        _f_say "   NEEDS-QUOTE-PASS markers ${NQP}, shortfall-audit blocks present: ${D2APP}."
        _f_say "   ceiling overlay applied: ${D3APP} · reasons overlay applied: ${D2APP}"
        _f_say "   Apply order matters — d3 (ceiling) then d2fix then d2 (reasons), because"
        _f_say "   the reason audits are computed against the post-swap selection."
        _f_say "   ${YELLOW:-}The quote-repair agent owns SHORTLIST-16.jsonl; settle that first.${NC:-}"
        _f_rc 1
    fi
    _f_next "ssh $CLIP_POOL_HOST 'cd ~/clip-pool/work-d234 && \\"
    _f_next "     python3 apply_overlay.py ~/clip-pool/shortlist/SHORTLIST-16.jsonl _stage1.jsonl d3_overlay.json && \\"
    _f_next "     python3 d2fix.py _stage1.jsonl && \\"
    _f_next "     python3 apply_overlay.py _stage1.jsonl SHORTLIST-16.remediated.jsonl d2_overlay.json'"

    printf '\n'
    _f_say "${BOLD:-}c) shortfall reasons — 15 of ${D2LPS:-?} did not survive measurement${NC:-}"
    _f_say "   verdicts: ${D2V:-?}"
    _f_say "   ${D2UNEX:-?} in-window drops across ${D2UNEXLP:-?} learning points are now UNEXPLAINED."
    _f_say "   Two of the false reasons had dropped the pool's top-ranked 3/3-agreement"
    _f_say "   moment while blaming moments that were never dropped."

    printf '\n'
    _f_say "${BOLD:-}d) the 420 s ceiling — one rule, no exceptions${NC:-}"
    _f_say "   ${D3SWAP:-?} swapped, ${D3DROP:-?} dropped, never padded (in the overlay, pending apply)."
    _f_say "   ${YELLOW:-}CARRY-OVER: the ${D3SWAP:-?} swapped-in rows have NOT been through the quote"
    _f_say "   checker${NC:-} — they are flagged NEEDS-QUOTE-PASS and that flag is owed work."

    printf '\n'
    _f_say "${BOLD:-}e) fabricated quotes — ${CAV:-?} rows marked, ${UNCAV:-?} outstanding${NC:-}"
    _f_say "   ${NLFRAG:-?} quoted fragments could not be located in the clip they describe."
    if [ "${NOAUDIT:-0}" != "0" ]; then
        _f_say "   ${RED:-}${NOAUDIT} rows carry no audit block, so that count is a FLOOR.${NC:-}"
    fi

    printf '\n'
    _f_say "in-artefact justification signal, censused AND sampled: ${DEEPROWS:-?} deep rows,"
    _f_say "   ${DEEPREM:-?} carry neither a declared shortfall reason nor 2-source corroboration."
    _f_say "   Sampled ${SAMPN:-?} of ${DEEPROWS:-?} (seed ${SAMPSEED:-?}): ${SAMPSURV:-?} survived. SAMPLED, NOT CENSUSED."
    _f_read "$CLIP_POOL_HOST:${CLIP_POOL_SHORTLIST/\$HOME/\~} · $CLIP_POOL_HOST:${CLIP_POOL_WORK/\$HOME/\~}"
    [ -n "${CV:-}" ] && _f_cv "$CV"
    return 0
}

# ── 3. the unmerged catalogue repair ─────────────────────────────────────────
_f_dir_branch() {
    local t="CATALOGUE REPAIR — merged nowhere, blocked on an operator decision"
    if [ ! -d "$CLIP_DIR_REPO/.git" ]; then
        _f_head 3 "$t" "CANNOT VERIFY"
        _f_cv "not a git repo: $CLIP_DIR_REPO"
        return
    fi
    local sha
    sha=$(git -C "$CLIP_DIR_REPO" rev-parse --short --verify "$CLIP_DIR_BRANCH" 2>/dev/null)
    if [ -z "$sha" ]; then
        _f_head 3 "$t" "CANNOT VERIFY"
        _f_cv "branch $CLIP_DIR_BRANCH does not exist in $CLIP_DIR_REPO"
        return
    fi
    if git -C "$CLIP_DIR_REPO" merge-base --is-ancestor "$CLIP_DIR_BRANCH" main 2>/dev/null; then
        _f_head 3 "$t" "DONE"
        _f_say "$CLIP_DIR_BRANCH ($sha) is already in main"
        _f_read "git -C $CLIP_DIR_REPO merge-base --is-ancestor $CLIP_DIR_BRANCH main"
        return
    fi
    local files
    files=$(git -C "$CLIP_DIR_REPO" diff --name-only main..."$CLIP_DIR_BRANCH" 2>/dev/null | wc -l)
    _f_head 3 "$t" "OWED"
    _f_say "$CLIP_DIR_BRANCH ($sha) is NOT an ancestor of main — $files files changed."
    _f_say "Produced entirely by 'pl clips repair'; nothing in it was hand-edited and"
    _f_say "nothing in it is a judgement about WHICH clip is right."
    _f_say "BLOCKED ON ops#$CLIP_OPS_DECISION — where the dir code should live. That is YOUR call;"
    _f_say "new code must not accrete in $CLIP_DIR_REPO while it is undecided."
    _f_read "git -C $CLIP_DIR_REPO log -1 $CLIP_DIR_BRANCH"
    _f_next "git -C $CLIP_DIR_REPO checkout main && git -C $CLIP_DIR_REPO merge $CLIP_DIR_BRANCH"
}

# ── 4. decisions awaiting the operator ───────────────────────────────────────
_f_decisions() {
    local t="DECISIONS AWAITING YOU"
    local out n
    out=$("$PROJECT_ROOT/pl" decisions --json 2>/dev/null)
    if [ -z "$out" ]; then
        _f_head 4 "$t" "CANNOT VERIFY"
        _f_cv "pl decisions --json returned nothing (no token, or the forge is unreachable)"
        _f_next "pl decisions"
        return
    fi
    # `outside_queue` is the decision::wanted tier. It carries its OWN honesty
    # flags — `readable` and `partial` — and they are load-bearing: a fetch that
    # stopped early still reports a count, and printing that count as if it were
    # the total is the swallowed-verdict failure. Absent flags read as NOT
    # readable, which is the fail-closed direction.
    n=$(printf '%s' "$out" | python3 -c '
import json,sys
try: r=json.loads(sys.stdin.read())
except Exception: print("?"); raise SystemExit
q=r.get("outside_queue")
if not isinstance(q,dict): print("?"); raise SystemExit
if not q.get("readable"): print("BLIND"); raise SystemExit
c=q.get("count")
if c is None: print("?"); raise SystemExit
print("PARTIAL %d"%c if q.get("partial") else c)' 2>/dev/null)
    case "$n" in
        "?"|"")
            _f_head 4 "$t" "CANNOT VERIFY"
            _f_cv "could not read a decision::wanted count out of pl decisions --json"
            _f_next "pl decisions"; return ;;
        BLIND)
            _f_head 4 "$t" "CANNOT VERIFY"
            _f_cv "pl decisions could not read the decision::wanted tier at all"
            _f_next "pl decisions"; return ;;
        "PARTIAL "*)
            _f_head 4 "$t" "CANNOT VERIFY"
            _f_cv "the decision::wanted fetch was PARTIAL — ${n#PARTIAL } is a floor, not the total"
            _f_next "pl decisions"; return ;;
    esac
    if [ "$n" -eq 0 ] 2>/dev/null; then
        _f_head 4 "$t" "DONE"
        _f_say "no issue carries decision::wanted"
    else
        _f_head 4 "$t" "OWED"
        _f_say "$n open issues carry decision::wanted — counted now, not recorded here."
        _f_say "ops#$CLIP_OPS_DECISION is the one this programme is actually blocked on."
    fi
    _f_read "pl decisions --json  (.outside_queue.count, honouring .readable/.partial)"
    _f_next "pl decisions"
}

# ── 5. rotation debt and tier violations ─────────────────────────────────────
_f_debt() {
    local t="ROTATION DEBT — these fail a prod bring-up CLOSED"
    local out n rc
    out=$("$PROJECT_ROOT/pl" secrets debt --json 2>/dev/null); rc=$?
    n=$(printf '%s' "$out" | python3 -c '
import json,sys
try: r=json.loads(sys.stdin.read())
except Exception: print("?"); raise SystemExit
if isinstance(r,list): print(sum(1 for e in r if not e.get("rotated")))
else: print(r.get("open","?"))' 2>/dev/null)
    local tier
    tier=$("$PROJECT_ROOT/pl" secrets lint 2>&1 | grep -c '^ERROR: TIER:' || true)

    if [ "$n" = "?" ] || [ -z "$n" ]; then
        _f_head 5 "$t" "CANNOT VERIFY"
        _f_cv "pl secrets debt --json could not be read (rc $rc)"
        _f_next "pl secrets debt"
        return
    fi
    if [ "$n" -eq 0 ] 2>/dev/null && [ "$tier" -eq 0 ] 2>/dev/null; then
        _f_head 5 "$t" "DONE"
        _f_say "no open rotation debt, no tier violations"
    else
        _f_head 5 "$t" "OWED"
        _f_say "$n open rotation debt records. They REFUSE pl canonical set <site> prod and"
        _f_say "every prod write through the ADR-0028 gate while they stand."
        _f_say "$tier TIER violations — an admin/backup-decryption credential in the"
        _f_say "AI-readable tier. Moving one is an OPERATOR action; the AI is deny-ruled"
        _f_say "from the destination file and cannot do it for you."
    fi
    _f_read "pl secrets debt --json · pl secrets lint"
    _f_next "pl secrets debt      # then: pl secrets rotate <id>"
    _f_next "pl secrets migrate-tier <dotted.key>   # operator-only"
}

# ── 6. named blockers, and the verb gap this programme exposed ───────────────
_f_blockers() {
    local t="BLOCKERS AND FOLLOW-UPS"
    local lines="" any_cv=0
    local iid state title
    for iid in $CLIP_OPS_BLOCKERS; do
        local body
        body=$(_f_issue "$iid")
        if [ -z "$body" ]; then any_cv=1; lines="$lines
     ops#$iid  (state CANNOT VERIFY — the forge could not be read)"; continue; fi
        state=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("state","?"))' 2>/dev/null)
        title=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("title","?")[:70])' 2>/dev/null)
        [ -z "$state" ] && { any_cv=1; state="CANNOT VERIFY"; }
        lines="$lines
     ops#$iid  [$state]  $title"
    done

    # SIGPIPE-prone pipelines, counted here rather than remembered. The predicate
    # is printed with the count, because a count without its predicate is folklore.
    local sig=0 f
    for f in $CLIP_SIGPIPE_FILES; do
        if [ -f "$PROJECT_ROOT/$f" ]; then
            sig=$(( sig + $(grep -cE '^[[:space:]]*(if|elif|while)[[:space:]].*\|[[:space:]]*(grep[[:space:]]+-[a-zA-Z]*q|head[[:space:]]+-)' "$PROJECT_ROOT/$f" || true) ))
        else
            any_cv=1
        fi
    done

    if [ "$any_cv" -eq 1 ]; then _f_head 6 "$t" "CANNOT VERIFY"; else _f_head 6 "$t" "OWED"; fi
    printf '%s\n' "${lines# }"
    _f_say ""
    _f_say "$sig SIGPIPE-prone pipelines on sensitive paths, left for your review on ops#351."
    _f_say "predicate: a pipeline in an if/elif/while whose consumer short-circuits"
    _f_say "(grep -q / head -n) — with set -o pipefail the producer takes SIGPIPE, the"
    _f_say "pipeline reports 141, and the guard silently does not fire."
    _f_say "files: $CLIP_SIGPIPE_FILES"
    _f_say ""
    _f_say "${YELLOW:-}VERB GAP, recorded as a bug report and not a licence:${NC:-} no pl verb covers"
    _f_say "clip-pool remediation, so that work followed the ad-hoc ~/clip-pool/work-*/"
    _f_say "script pattern. Under the standing order that is a gap to close, not a"
    _f_say "precedent — 'pl clips remediate' is the verb that should exist."
    _f_read "pl issue show <n> · grep over $CLIP_SIGPIPE_FILES"
    _f_next "pl issue show 351"
}

_f_issue() { # $1=iid -> issue json, or empty when it could not be read
    (
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/lib/gitlab-issues.sh" >/dev/null 2>&1 || exit 0
        _token_present || exit 0
        _api_get "/projects/$CLIP_OPS_PROJECT/issues/$1" 2>/dev/null
    )
}

cmd_finish() {
    printf '%s══ pl clips finish — what is owed, in what order, and the command ══%s\n' \
        "${BOLD:-}" "${NC:-}"
    printf '%severy line below is MEASURED at run time; nothing here is a checklist%s\n' \
        "${DIM:-}" "${NC:-}"
    printf '%smeasured: %s%s\n' "${DIM:-}" "$(date -u '+%Y-%m-%d %H:%M UTC')" "${NC:-}"

    _f_calibration
    _f_shortlist
    _f_dir_branch
    _f_decisions
    _f_debt
    _f_blockers

    printf '\n'
    case "$F_RC" in
        0) printf '%sNOTHING OWED.%s\n' "${GREEN:-}" "${NC:-}" ;;
        1) printf '%sWORK IS OWED — the sections marked OWED, in the order printed.%s\n' "${YELLOW:-}" "${NC:-}" ;;
        2) printf '%sCANNOT VERIFY — at least one source could not be read. Grade this AMBER;%s\n' "${RED:-}" "${NC:-}"
           printf '%snever count it as a pass, and never read it as "nothing outstanding".%s\n' "${RED:-}" "${NC:-}" ;;
    esac
    return "$F_RC"
}

################################################################################
# pl clips calibrate — the panel instrument (P79)
################################################################################

CAL_SCORER="$PROJECT_ROOT/scripts/lib/clip-calibration-multi.py"
CAL_PACKET="$PROJECT_ROOT/scripts/lib/clip-calibration-packet.py"
# The calibration set and the packets live in ~/dir because they carry corpus
# excerpts (P78 6). Only the METHOD lives here.
CAL_SET="${NWP_CLIPS_CAL_SET:-$CLIP_SCORER_DIR/calibration_set.json}"
CAL_PANEL_DIR="${NWP_CLIPS_PANEL_DIR:-$CLIP_CAL_DIR/panel}"

cmd_calibrate() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        packet)
            [ -f "$CAL_PACKET" ] || { _err "builder missing: $CAL_PACKET"; return 2; }
            [ -f "$CAL_SET" ] || {
                _err "no calibration set at $CAL_SET"
                _err "CANNOT VERIFY: a packet cannot be built from a set that is not here."
                return 2; }
            local -a args=(--cal="$CAL_SET") ; local have_out=0
            for a in "$@"; do
                case "$a" in
                    --out=*) have_out=1; args+=("$a") ;;
                    *) args+=("$a") ;;
                esac
            done
            [ "$have_out" -eq 0 ] && args+=(--out="$CAL_PANEL_DIR")
            python3 "$CAL_PACKET" "${args[@]}"
            ;;
        score)
            [ -f "$CAL_SCORER" ] || { _err "scorer missing: $CAL_SCORER"; return 2; }
            [ -f "$CAL_SET" ] || {
                _err "no calibration set at $CAL_SET"
                _err "CANNOT VERIFY: refusing to score answers against a set that is not here."
                return 2; }
            local -a sargs=(--cal="$CAL_SET" --packet-dir="$CAL_PANEL_DIR")
            local n=0
            for a in "$@"; do
                case "$a" in
                    --*) sargs+=("$a") ;;
                    *)   sargs+=("$a"); n=$((n + 1)) ;;
                esac
            done
            if [ "$n" -eq 0 ]; then
                # No files named: take every answers file in the panel dir. A
                # panel is whoever handed in, and that is a DECLARED FACT read
                # off the directory, not a roster kept somewhere else.
                local f found=0
                for f in "$CAL_PANEL_DIR"/answers-*.json; do
                    [ -e "$f" ] || continue
                    sargs+=("$f"); found=$((found + 1))
                done
                if [ "$found" -eq 0 ]; then
                    _err "no answers files in $CAL_PANEL_DIR and none named"
                    _err "CANNOT VERIFY: an empty panel is not a passing panel."
                    return 2
                fi
                printf '%sscoring %d rater(s) found in %s%s\n' \
                    "${DIM:-}" "$found" "$CAL_PANEL_DIR" "${NC:-}" >&2
            fi
            python3 "$CAL_SCORER" "${sargs[@]}"
            ;;
        status)
            printf '%-24s %s\n' "calibration set" "$CAL_SET"
            printf '%-24s %s\n' "panel directory" "$CAL_PANEL_DIR"
            if [ ! -f "$CAL_SET" ]; then
                printf '\nCANNOT VERIFY: the calibration set is not on this machine.\n' >&2
                return 2
            fi
            local total
            total=$(python3 -c '
import json,sys
c=json.load(open(sys.argv[1]))
print(sum(len(l["items"]) for l in c))' "$CAL_SET" 2>/dev/null) || total=0
            printf '%-24s %s\n\n' "judgements per rater" "$total"
            printf '%-14s %-9s %-9s %s\n' "RATER" "GRADED" "OF" "PACKET"
            # Worst-of, same convention as `finish`: 2 (cannot look) dominates
            # 1 (owed), which dominates 0. A half-graded panel must never read
            # as a finished one just because the table rendered.
            local f rid graded pk any=0 rc=0
            for f in "$CAL_PANEL_DIR"/answers-*.json; do
                [ -e "$f" ] || continue
                any=1
                rid=$(basename "$f" .json); rid="${rid#answers-}"
                graded=$(python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(-1); raise SystemExit
print(sum(1 for v in d.values() if v is not None))' "$f" 2>/dev/null) || graded=-1
                pk="$CAL_PANEL_DIR/calibration-packet-$rid.json"
                if [ -f "$pk" ]; then pk="present"; else
                    pk="MISSING — this rater CANNOT be scored"; rc=2
                fi
                printf '%-14s %-9s %-9s %s\n' "$rid" "$graded" "$total" "$pk"
                if [ "$graded" -lt 0 ]; then rc=2
                elif [ "$graded" -lt "$total" ] && [ "$rc" -ne 2 ]; then rc=1; fi
            done
            if [ "$any" -eq 0 ]; then
                printf '(no rater has handed in)\n\n'
                printf 'CANNOT VERIFY: nobody has judged anything yet. An empty\n' >&2
                printf 'panel is not a passing panel.\n' >&2
                return 2
            fi
            case "$rc" in
                0) printf '\nall raters complete.\nnext: pl clips calibrate score\n' ;;
                1) printf '\nOWED: at least one rater has judgements outstanding.\n' ;;
                2) printf '\nCANNOT VERIFY: a rater above cannot be scored at all.\n' >&2 ;;
            esac
            return "$rc"
            ;;
        ""|-h|--help|help)
            usage; return 0 ;;
        *)  _err "unknown calibrate subcommand: $sub"; usage; return 1 ;;
    esac
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

    # `calibrate` takes its own flags (--rater=, --exclusions=, --boot=) and
    # positional answers files, so it is dispatched BEFORE the shared option
    # loop below, which would reject them as unknown.
    if [ "$sub" = "calibrate" ]; then
        cmd_calibrate "$@"
        return $?
    fi

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
        finish)  cmd_finish ;;
        sources) cmd_sources ;;
        ""|-h|--help|help) usage ;;
        *) _err "unknown subcommand: $sub"; usage; return 1 ;;
    esac
}

main "$@"
