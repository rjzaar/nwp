#!/bin/bash
################################################################################
# lib/session.sh — the session-handover substrate: the baton, and the DERIVED
# session brief.
#
# WHY THIS FILE EXISTS
# --------------------
# On 2026-08-02 an orchestrating session fed its sub-agents four premises out of
# memory, and every single one was wrong:
#
#   * an MR described as "merged" that was still open;
#   * a branch described as "on main" that was not;
#   * a root cause that was not the root cause;
#   * "the video is missing" when the video was present.
#
# All four were caught, but only because each sub-agent independently went and
# looked. That is luck, not a system. Prose carried between sessions goes stale
# silently: nothing about a sentence in a handover document changes when the
# world underneath it changes.
#
# GENERATED STATE CANNOT GO STALE THAT WAY. So the contract of this file is:
#
#   A session brief is DERIVED from live state. Prose is allowed only for
#   judgement that cannot be derived, it is quarantined into one section, and
#   every prose line is stamped UNVERIFIED.
#
# and its corollary, which matters just as much:
#
#   A section that could not be read says so. `MR-BLIND` is not "no open MRs";
#   `TRUNCATED` is not "that is all the issues". A brief that quietly reports
#   an empty list for a query it was not allowed to run is exactly the failure
#   mode it exists to prevent.
#
# WHAT IS IN HERE
#   Baton    — the machine-checkable relay contract (STATUS on line 1), with a
#              dropped-baton timeout, so a session that dies is DETECTABLE.
#   Sections — one function per derived section of the brief. Each returns JSON
#              carrying its own provenance (source + when + whether it is blind).
#
# The verb that composes these is `pl session` (scripts/commands/session.sh).
################################################################################

if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
fi
: "${YQ:=$(command -v yq || true)}"

# ─────────────────────────────────────────────────────────────────────────────
# THE BATON
#
# Line 1 of the baton file is `STATUS: <state>` and nothing else. That is the
# whole machine-readable contract; everything below line 1 is for humans and for
# the next session's PROSE section.
#
# States:
#   IN-PROGRESS  a session holds the baton and is still working
#   READY        a session finished cleanly; its handover below is complete
#   ABANDONED    a session stopped without finishing; contents may be partial
#
# and two states that are DERIVED rather than written, because a dead session
# cannot write anything:
#
#   ABANDONED(missing)   the file is not there. The baton is created BEFORE the
#                        work starts, so its absence is not "nothing happened",
#                        it is "something went wrong".
#   ABANDONED(timeout)   still IN-PROGRESS after the timeout. This is the case
#                        the whole design turns on: a session that dies mid-flight
#                        leaves IN-PROGRESS behind forever, and a supervisor that
#                        trusts the written status waits all night for a handover
#                        that will never come.
#
# Fail closed: an unreadable or malformed line 1 grades ABANDONED, never READY.
# The expensive error is starting from a partial handover believing it is whole.
# ─────────────────────────────────────────────────────────────────────────────

: "${NWP_BATON_FILE:=$HOME/central/OVERNIGHT-BATON.md}"
: "${NWP_BATON_TIMEOUT_MIN:=90}"

session_baton_path() { printf '%s' "$NWP_BATON_FILE"; }

# The status literally written on line 1. Empty if unreadable/malformed.
session_baton_written_status() {
  local f; f=$(session_baton_path)
  [ -r "$f" ] || return 0
  head -1 "$f" 2>/dev/null | sed -n 's/^STATUS:[[:space:]]*\([A-Za-z-]\{1,\}\)[[:space:]]*$/\1/p'
}

# Age in whole minutes of the freshest liveness signal we have.
#
# NOT just mtime. A long-running session can go an hour without touching the
# baton and still be perfectly alive, and if mtime were the only signal the
# supervisor would shoot it. So a live session stamps `HEARTBEAT: <iso8601>`
# (via `pl session heartbeat`) and the age is measured from whichever of the two
# is more recent. A session that stops heartbeating is a session that stopped.
session_baton_age_min() {
  local f now newest hb hb_epoch mt
  f=$(session_baton_path)
  [ -r "$f" ] || { printf '%s' ""; return 0; }
  now=$(date -u +%s)
  mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  newest="$mt"
  hb=$(grep -m1 '^HEARTBEAT:' "$f" 2>/dev/null | sed 's/^HEARTBEAT:[[:space:]]*//')
  if [ -n "$hb" ]; then
    hb_epoch=$(date -u -d "$hb" +%s 2>/dev/null || echo 0)
    [ "$hb_epoch" -gt "$newest" ] 2>/dev/null && newest="$hb_epoch"
  fi
  printf '%s' "$(( (now - newest) / 60 ))"
}

# The status a SUPERVISOR should act on. This is the one callers want.
# Prints one of: READY | IN-PROGRESS | ABANDONED | ABANDONED(missing) |
#                ABANDONED(timeout) | ABANDONED(malformed)
session_baton_effective_status() {
  local f written age
  f=$(session_baton_path)
  [ -e "$f" ] || { printf 'ABANDONED(missing)'; return 0; }
  [ -r "$f" ] || { printf 'ABANDONED(missing)'; return 0; }
  written=$(session_baton_written_status)
  case "$written" in
    READY)      printf 'READY'; return 0 ;;
    ABANDONED)  printf 'ABANDONED'; return 0 ;;
    IN-PROGRESS) : ;;
    *)          printf 'ABANDONED(malformed)'; return 0 ;;
  esac
  age=$(session_baton_age_min)
  if [ -n "$age" ] && [ "$age" -ge "$NWP_BATON_TIMEOUT_MIN" ] 2>/dev/null; then
    printf 'ABANDONED(timeout)'
  else
    printf 'IN-PROGRESS'
  fi
}

# True when the next session must re-derive everything rather than trust the
# handover text. Every ABANDONED shape qualifies — including the clean written
# one, because "I stopped early" means the prose below is partial by definition.
session_baton_requires_rederive() {
  case "$(session_baton_effective_status)" in
    ABANDONED*) return 0 ;;
    *) return 1 ;;
  esac
}

# Write the baton atomically with STATUS on line 1. Body arrives on stdin.
# Atomic because a supervisor polling every minute WILL eventually read a
# half-written file, and a truncated read of line 1 grades ABANDONED — i.e. a
# non-atomic write can spuriously shoot a healthy session.
session_baton_write() { # $1=STATUS  (body on stdin)
  local status="$1" f tmp
  case "$status" in
    IN-PROGRESS|READY|ABANDONED) : ;;
    *) echo "session_baton_write: refusing unknown status '$status'" >&2; return 1 ;;
  esac
  f=$(session_baton_path)
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$f.tmp.$$"
  {
    printf 'STATUS: %s\n' "$status"
    printf 'HEARTBEAT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f"
}

# Refresh only the heartbeat, leaving status and body untouched.
session_baton_heartbeat() {
  local f tmp now
  f=$(session_baton_path)
  [ -w "$f" ] || return 1
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp="$f.tmp.$$"
  if grep -q '^HEARTBEAT:' "$f"; then
    sed "0,/^HEARTBEAT:.*/s//HEARTBEAT: $now/" "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    { head -1 "$f"; printf 'HEARTBEAT: %s\n' "$now"; tail -n +2 "$f"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$f"
}

# Flip status in place without rewriting the body. Used by the SessionEnd hook
# when a session ends having already written its handover.
session_baton_set_status() { # $1=STATUS
  local status="$1" f tmp
  case "$status" in
    IN-PROGRESS|READY|ABANDONED) : ;;
    *) echo "session_baton_set_status: refusing unknown status '$status'" >&2; return 1 ;;
  esac
  f=$(session_baton_path)
  [ -f "$f" ] || return 1
  tmp="$f.tmp.$$"
  { printf 'STATUS: %s\n' "$status"; tail -n +2 "$f"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f"
}

# ─────────────────────────────────────────────────────────────────────────────
# DERIVED SECTIONS
#
# Every section emits a JSON object with a `provenance` block:
#   source  — the command or file the numbers came from
#   at      — when it was read (UTC)
#   blind   — non-empty when the section COULD NOT be read. A blind section is
#             never rendered as an empty result.
# ─────────────────────────────────────────────────────────────────────────────

_sess_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Escape an arbitrary multi-line blob into one JSON string value.
_sess_jstr() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'NF{printf "%s\\n",$0}'; }

# ── forge plumbing, shared by the mrs/holds sections ────────────────────────
# Hoisted to file scope on purpose: these were briefly nested inside
# session_section_mrs, which made session_section_holds work only if the mrs
# section happened to have run first. A helper that exists depending on call
# order is a blind section waiting to happen.
#
# TOKEN CHOICE. MR reads need project reach that gitlab.ops_note_token has not
# got (Reporter on nwp/ops 21 only — measured 404 on nwp/nwp 9). So prefer an
# explicit gitlab.mr_token, then gitlab.api_token. The token is written only
# into a 0600 curl config: never argv, never ps, never a log.
_sess_secrets_file() { printf '%s' "${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}"; }

_sess_mr_token() {
  "$YQ" e '.gitlab.mr_token // .gitlab.api_token // ""' "$(_sess_secrets_file)" 2>/dev/null | grep -v '^null$'
}

_sess_mr_host() {
  local h="${NWP_GITLAB_HOST:-}"
  [ -n "$h" ] || h=$("$YQ" e '.gitlab.server.domain // ""' "$(_sess_secrets_file)" 2>/dev/null | grep -v '^null$')
  printf '%s' "$h"
}

_sess_mr_get() { # $1 = api path
  local host token cfg rc
  host=$(_sess_mr_host); token=$(_sess_mr_token)
  [ -n "$host" ] && [ -n "$token" ] || return 2
  cfg=$(mktemp); chmod 600 "$cfg"
  { printf 'silent\nconnect-timeout = 8\nmax-time = 25\n'
    printf 'header = "PRIVATE-TOKEN: %s"\nurl = "https://%s/api/v4%s"\n' "$token" "$host" "$1"
  } > "$cfg"
  token=""
  curl -K "$cfg" 2>/dev/null; rc=$?
  rm -f "$cfg"; return $rc
}

_sess_mr_put() { # $1 = api path
  local host token cfg rc
  host=$(_sess_mr_host); token=$(_sess_mr_token)
  [ -n "$host" ] && [ -n "$token" ] || return 2
  cfg=$(mktemp); chmod 600 "$cfg"
  { printf 'silent\nconnect-timeout = 8\nmax-time = 25\nrequest = "PUT"\n'
    printf 'header = "PRIVATE-TOKEN: %s"\nurl = "https://%s/api/v4%s"\n' "$token" "$host" "$1"
  } > "$cfg"
  token=""
  curl -K "$cfg" >/dev/null 2>&1; rc=$?
  rm -f "$cfg"; return $rc
}

# ---- git -------------------------------------------------------------------
# The cheapest premise to get wrong ("that branch is on main") and the cheapest
# to check. Reports the drift of the working checkout explicitly, because a
# session reading a checkout 85 commits behind will describe a world that no
# longer exists.
session_section_git() {
  local repo="${1:-$PROJECT_ROOT}" head_sha main_sha behind ahead branch blind=""
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    blind="not a git repository: $repo"
  else
    git -C "$repo" fetch origin --quiet 2>/dev/null || blind="git fetch failed — remote state may be stale"
    branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
    head_sha=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
    main_sha=$(git -C "$repo" rev-parse --short origin/main 2>/dev/null)
    behind=$(git -C "$repo" rev-list --count HEAD..origin/main 2>/dev/null || echo "")
    ahead=$(git -C "$repo" rev-list --count origin/main..HEAD 2>/dev/null || echo "")
  fi
  cat <<EOF
{"section":"git","provenance":{"source":"git -C $repo rev-parse/rev-list origin/main","at":"$(_sess_now)","blind":"$blind"},
 "repo":"$repo","branch":"${branch:-}","head":"${head_sha:-}","origin_main":"${main_sha:-}",
 "behind_origin_main":"${behind:-}","ahead_of_origin_main":"${ahead:-}"}
EOF
}

# ---- issues ----------------------------------------------------------------
# TRUNCATION HONESTY. `pl issue ls` on main pages at per_page=100 in one call and
# nwp/ops is AT that cap, so the list silently stops. !320 (branch
# fix/issue-ls-truncation) fixes it and adds --pending/--project=all; it is NOT
# merged as of this writing. So: detect the fix rather than assume either way,
# and when it is absent say TRUNCATED out loud instead of presenting a short
# list as a complete one.
session_section_issues() {
  local pl="${NWP_PL:-$PROJECT_ROOT/pl}" out rc=0 count blind="" truncated="" has_pending=""
  if [ ! -x "$pl" ]; then
    blind="no executable pl at $pl"
  else
    if "$pl" issue ls --help 2>&1 | grep -q -- '--pending'; then has_pending=1; fi
    if [ -n "$has_pending" ]; then
      out=$("$pl" issue ls --pending --project=all 2>&1) || rc=$?
    else
      out=$("$pl" issue ls 2>&1) || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      blind="pl issue ls exited $rc — the queue could not be read (this is NOT an empty queue)"
    else
      count=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*(#|ops#|nwc#)?[0-9]+' || true)
      if [ -z "$has_pending" ]; then
        truncated="pl issue ls here reads ONE page of 100 and nwp/ops is at that cap: the list below may be SHORT. !320 (fix/issue-ls-truncation) paginates and adds --pending/--project=all; it is not merged in this checkout."
      fi
    fi
  fi
  local body; body=$(_sess_jstr "${out:-}")
  cat <<EOF
{"section":"issues","provenance":{"source":"pl issue ls${has_pending:+ --pending --project=all}","at":"$(_sess_now)","blind":"$blind"},
 "paginating_verb_present":"${has_pending:-0}","truncation_warning":"$truncated","row_estimate":"${count:-}","text":"$body"}
EOF
}

# ---- merge requests --------------------------------------------------------
# THE STALE-CONFLICT TRAP (ops#213). This forge reports `cannot_be_merged` for
# branches that in fact merge cleanly — confirmed by local test-merge. Two
# consequences a brief MUST encode rather than paper over:
#
#   * `checking` / `unchecked` means "ask again", NOT "failure". Poll it.
#   * `cannot_be_merged` is UNVERIFIED until the forge recomputes. `PUT
#     /merge_requests/:iid/rebase` forces that recompute — but it is a WRITE, so
#     it happens only under --recompute. Unrecomputed, the status is rendered
#     `cannot_be_merged?` with the reason attached. A question mark is the
#     honest rendering of a number you have not earned.
#
# TOKEN REACH. gitlab.ops_note_token is Reporter on nwp/ops (21) ONLY — measured:
# `404 Project Not Found` on nwp/nwp (9). On a host that holds only that token
# this section is BLIND, and blind is reported as blind. An
# empty MR list from a token that cannot see the project is the single most
# dangerous thing this brief could print.
session_section_mrs() {
  local project_id="${1:-9}" recompute="${2:-0}"
  local json rows blind="" n=0 out=""

  json=$(_sess_mr_get "/projects/$project_id/merge_requests?state=opened&per_page=100") || json=""
  if [ -z "$json" ]; then
    blind="MR-BLIND: no response from the forge for project $project_id"
  elif printf '%s' "$json" | grep -q '"message"[[:space:]]*:[[:space:]]*"40[34]'; then
    blind="MR-BLIND: this host's token cannot read project $project_id (gitlab.ops_note_token is scoped to nwp/ops only). This is NOT 'no open MRs'."
  else
    rows=$(printf '%s' "$json" | "$YQ" e -p=json -o=json -I=0 '.[] | {"iid":.iid,"title":.title,"draft":.draft,"ms":.merge_status,"dms":.detailed_merge_status,"branch":.source_branch,"labels":(.labels|join(","))}' - 2>/dev/null)
    n=$(printf '%s\n' "$rows" | grep -c . || true)

    # Retry the ones the forge has not finished thinking about, then optionally
    # force a recompute on the conflict-claimers.
    local line iid ms attempt fresh
    out=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      iid=$(printf '%s' "$line" | "$YQ" e -p=json '.iid' - 2>/dev/null)
      ms=$(printf '%s' "$line" | "$YQ" e -p=json '.ms' - 2>/dev/null)
      attempt=0
      while { [ "$ms" = "checking" ] || [ "$ms" = "unchecked" ]; } && [ "$attempt" -lt 3 ]; do
        sleep 2; attempt=$((attempt+1))
        fresh=$(_sess_mr_get "/projects/$project_id/merge_requests/$iid") || fresh=""
        [ -n "$fresh" ] && ms=$(printf '%s' "$fresh" | "$YQ" e -p=json '.merge_status // ""' - 2>/dev/null)
      done
      if [ "$ms" = "cannot_be_merged" ]; then
        if [ "$recompute" = "1" ]; then
          _sess_mr_put "/projects/$project_id/merge_requests/$iid/rebase" || true
          sleep 4
          fresh=$(_sess_mr_get "/projects/$project_id/merge_requests/$iid") || fresh=""
          [ -n "$fresh" ] && ms=$(printf '%s' "$fresh" | "$YQ" e -p=json '.merge_status // ""' - 2>/dev/null)
          ms="$ms(recomputed)"
        else
          # ops#213: unverified until recomputed. Say so in the value itself.
          ms="cannot_be_merged?(STALE-SUSPECT: this forge reports stale conflicts; re-run with --recompute to force PUT /rebase)"
        fi
      fi
      out="$out$(printf '%s' "$line" | "$YQ" e -p=json -o=json -I=0 ".ms = \"$ms\"" - 2>/dev/null)
"
    done <<< "$rows"
  fi
  local body; body=$(_sess_jstr "${out:-}")
  cat <<EOF
{"section":"mrs","provenance":{"source":"GET /projects/$project_id/merge_requests?state=opened (recompute=$recompute)","at":"$(_sess_now)","blind":"$blind"},
 "project_id":"$project_id","open_count":"${n:-0}","rows":"$body"}
EOF
}

# ---- rag -------------------------------------------------------------------
# Read the LAST rag rollup rather than running one (a rollup is minutes of work
# and hits the estate). But a cached number presented without its age is exactly
# the stale premise this brief exists to kill, so the age is part of the value.
session_section_rag() {
  local f="${NWP_RAG_STATE:-$PROJECT_ROOT/private/rag/state.json}"
  local blind="" gen red amber green unscanned age_min gen_epoch
  if [ ! -r "$f" ]; then
    blind="no rag state at $f — grade the fleet UNKNOWN, not GREEN. Run: pl rag"
  else
    gen=$("$YQ" e -p=json '.generated // ""' "$f" 2>/dev/null)
    red=$("$YQ" e -p=json '.summary.RED // ""' "$f" 2>/dev/null)
    amber=$("$YQ" e -p=json '.summary.AMBER // ""' "$f" 2>/dev/null)
    green=$("$YQ" e -p=json '.summary.GREEN // ""' "$f" 2>/dev/null)
    unscanned=$("$YQ" e -p=json '.summary.UNSCANNED // ""' "$f" 2>/dev/null)
    # THE EMPTY-DATE TRAP. `date -u -d "" +%s` does not fail — it silently
    # returns MIDNIGHT TODAY, exit 0. Caught here in the wild on 2026-08-02:
    # a mid-write rollup with "generated": null rendered as a confident
    # "507 min old", which is precisely the shape of stale premise this brief
    # exists to abolish, manufactured by the brief itself. Guard the input; do
    # not trust `|| echo 0` to catch a command that does not fail.
    if [ -z "$gen" ] || [ "$gen" = "null" ]; then
      gen=""
      blind="the rag rollup at $f carries NO generated timestamp (mid-write, or a broken run). Its counts are of UNKNOWN age — re-run: pl rag"
    else
      gen_epoch=$(date -u -d "$gen" +%s 2>/dev/null || echo 0)
      if [ "$gen_epoch" -gt 0 ] 2>/dev/null; then
        age_min=$(( ( $(date -u +%s) - gen_epoch ) / 60 ))
      else
        blind="the rag rollup's generated timestamp ('$gen') did not parse — age UNKNOWN"
      fi
    fi
  fi
  cat <<EOF
{"section":"rag","provenance":{"source":"$f","at":"$(_sess_now)","blind":"$blind"},
 "generated":"${gen:-}","age_min":"${age_min:-}","RED":"${red:-}","AMBER":"${amber:-}","GREEN":"${green:-}","UNSCANNED":"${unscanned:-}"}
EOF
}

# ---- goldens ---------------------------------------------------------------
# Staged demo goldens, read off their manifests. A brief that names a golden
# timestamp from memory is how a session talks itself into recapturing one that
# is already staged and verified.
# THE SUPERSEDED-COPY TRAP. A first cut used `find -name golden.manifest.json`
# and returned NINE goldens for two sites, because every `demo-golden-live.pre-<x>`
# rollback copy answers to that name. A brief that lists five nwd goldens with
# five different timestamps has told the reader nothing except that it did not
# know which one was live — and the reader's next move is to recapture. So: the
# LIVE golden is the one in the canonically-named directory, and the archived
# copies are counted, not listed beside it.
session_section_goldens() {
  local sites_dir="${NWP_SITES_DIR:-$PROJECT_ROOT/sites}" rows="" m site cap dbsha blind="" archived=0
  if [ ! -d "$sites_dir" ]; then
    blind="no sites dir at $sites_dir"
  else
    for m in "$sites_dir"/*/demo-golden-live/golden.manifest.json; do
      [ -r "$m" ] || continue
      site=$("$YQ" e -p=json '.site // ""' "$m" 2>/dev/null)
      cap=$("$YQ" e -p=json '.captured_utc // ""' "$m" 2>/dev/null)
      dbsha=$("$YQ" e -p=json '.db_sha256 // ""' "$m" 2>/dev/null)
      rows="$rows{\\\"site\\\":\\\"$site\\\",\\\"captured_utc\\\":\\\"$cap\\\",\\\"db_sha256\\\":\\\"${dbsha:0:12}\\\",\\\"state\\\":\\\"LIVE\\\"}\\n"
    done
    archived=$(find "$sites_dir" -maxdepth 3 -path '*demo-golden-live.*' -name golden.manifest.json 2>/dev/null | grep -c . || true)
    [ -n "$rows" ] || blind="no golden manifest in any $sites_dir/*/demo-golden-live/ — the demo tier has NO staged golden, which is not the same as 'none needed'"
  fi
  cat <<EOF
{"section":"goldens","provenance":{"source":"$sites_dir/*/demo-golden-live/golden.manifest.json","at":"$(_sess_now)","blind":"$blind"},
 "archived_copies":"$archived","rows":"$rows"}
EOF
}

# ---- holds -----------------------------------------------------------------
# A hold that lives in a document is not a hold. On 2026-08-02 a hold recorded in
# prose was overridden by the recording session's OWN sweeper inside minutes.
# So this section reads holds only from places a machine enforces them:
#   * GitLab Draft status on an MR — a Draft cannot be merged, by the forge
#     (this is !314's mechanism, and it survived an A/B against a bot re-arming
#     auto-merge);
#   * a `hold::*` label on an issue, which the agent-loop's eligibility filter
#     reads.
# Prose holds are deliberately NOT collected here. If it is not in the forge, it
# is not a hold, and listing it beside real holds would give it a credibility it
# has not got.
session_section_holds() {
  local project_id="${1:-9}" blind="" drafts="" nd=0
  local json
  json=$(_sess_mr_get "/projects/$project_id/merge_requests?state=opened&per_page=100" 2>/dev/null) || json=""
  if [ -z "$json" ] || printf '%s' "$json" | grep -q '"message"[[:space:]]*:[[:space:]]*"40[34]'; then
    blind="HOLD-BLIND: cannot read project $project_id MRs, so forge-enforced holds are UNKNOWN"
  else
    drafts=$(printf '%s' "$json" | "$YQ" e -p=json -o=json -I=0 '.[] | select(.draft == true) | {"iid":.iid,"title":.title}' - 2>/dev/null)
    nd=$(printf '%s\n' "$drafts" | grep -c . || true)
  fi
  local body; body=$(_sess_jstr "${drafts:-}")
  cat <<EOF
{"section":"holds","provenance":{"source":"GET /projects/$project_id/merge_requests?state=opened → .draft==true (forge-enforced only; prose holds are NOT holds)","at":"$(_sess_now)","blind":"$blind"},
 "draft_count":"${nd:-0}","rows":"$body"}
EOF
}
