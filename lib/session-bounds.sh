#!/bin/bash
################################################################################
# lib/session-bounds.sh — the bounds on an UNATTENDED session.
#
# WHAT AN UNATTENDED SESSION MAY DO
#   read anything · fix · push · open merge requests
#
# WHAT IT MAY NOT DO WITHOUT A HUMAN
#   1. merge anything touching a CLAUDE.md-listed sensitive path
#   2. write to a live site outside the demo tier
#
# and two bounds on the run itself rather than its blast radius:
#   3. repeat-failure stop — fail the same way twice and STOP, do not loop
#   4. token ceiling — a run has a budget and stops when it is spent
#
# HOW THESE ARE ENFORCED, AND WHY IT MATTERS WHERE
# ------------------------------------------------
# Bound 1 is enforced IN THE FORGE, not in a prompt and not in a document.
# On 2026-08-02 a hold recorded in prose was overridden within minutes by the
# very session that recorded it — its own sweeper read the queue, not the note.
# A rule an agent must remember is not a rule; it is a wish. GitLab's Draft flag
# is a rule: a Draft MR cannot be merged, by the server, whatever any agent
# believes. (!314 proved this survives a bot re-arming auto-merge, A/B.)
#
# Bound 2 refuses locally, before the write leaves the machine, because there is
# no forge in that path to appeal to.
#
# Bounds 3 and 4 are ledger-and-count: dull, and the reason a wedged loop costs
# one failure instead of a night.
#
# ONE SOURCE OF TRUTH FOR "SENSITIVE"
# -----------------------------------
# The pattern is NOT restated here. It is extracted from the live gate in
# scripts/agent-loop/agent-loop.sh (SENSITIVE_PATH_RE, hoisted to a single line
# precisely so it can be extracted and tested). A second copy would drift, and
# the copy that drifts is always the one doing the enforcing. If the extraction
# fails, this library REFUSES EVERYTHING — a gate that cannot read its own rules
# has no business saying yes.
################################################################################

if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
fi
: "${YQ:=$(command -v yq || true)}"

: "${NWP_SESSION_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/nwp/session}"

# ─────────────────────────────────────────────────────────────────────────────
# BOUND 1 — sensitive paths
# ─────────────────────────────────────────────────────────────────────────────

# The agent-loop's live PUSH gate pattern. Non-zero if it cannot be read.
session_loop_sensitive_re() {
  local src="${NWP_SENSITIVE_SRC:-$PROJECT_ROOT/scripts/agent-loop/agent-loop.sh}"
  # Post-!314 there may be a proper lib. Prefer it; it is the same pattern with
  # a nicer front door.
  if [ -r "$PROJECT_ROOT/lib/sensitive-paths.sh" ]; then
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/sensitive-paths.sh" 2>/dev/null || true
    if [ -n "${SENSITIVE_PATH_RE:-}" ]; then printf '%s' "$SENSITIVE_PATH_RE"; return 0; fi
  fi
  [ -r "$src" ] || return 1
  local assign; assign="$(grep -m1 '^SENSITIVE_PATH_RE=' "$src" || true)"
  [ -n "$assign" ] || return 1
  # eval of exactly one assignment line, matching the idiom the existing gate
  # test uses, so this exercises the real regex including its quoting.
  local SENSITIVE_PATH_RE=""
  eval "$assign" || return 1
  [ -n "$SENSITIVE_PATH_RE" ] || return 1
  printf '%s' "$SENSITIVE_PATH_RE"
}

# The paths CLAUDE.md ITSELF declares sensitive, compiled from the document.
#
# WHY THIS EXISTS — a measured gap, not a hypothetical one. On 2026-08-02 the
# live SENSITIVE_PATH_RE was checked against CLAUDE.md's own "Sensitive File
# Paths" list and three entries were NOT covered:
#
#     CLAUDE.md          (the AI standing orders themselves)
#     composer.json      (dependency definitions — supply chain)
#     **/settings.php    (Drupal credentials)
#
# An agent could therefore have merged a change to its own standing orders
# unattended. The two lists had drifted, and the drift was invisible because
# nothing compared them.
#
# The fix is deliberately NOT a second hand-written pattern — that is the same
# mistake one layer up. The supplement is COMPILED FROM THE DOCUMENT that
# declares the policy, so adding a bullet to CLAUDE.md widens the enforced gate
# with no code change, and deleting one narrows it visibly in a diff.
session_claude_md_re() {
  local f="${NWP_CLAUDE_MD:-$PROJECT_ROOT/CLAUDE.md}"
  [ -r "$f" ] || return 1
  local globs g out=""
  # The bullet list under "### Sensitive File Paths", up to the next heading.
  globs=$(awk '
      /^#+[[:space:]]+Sensitive File Paths/ { inlist=1; next }
      inlist && /^#+[[:space:]]/            { exit }
      inlist                                { print }
    ' "$f" | sed -n 's/^-[[:space:]]*`\([^`]*\)`.*/\1/p')
  [ -n "$globs" ] || return 1
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    local re="$g"
    # Escape regex metacharacters that are literal in a glob, THEN expand the
    # glob operators. Order matters: escaping after expansion would neuter the
    # very metacharacters we just introduced.
    re=${re//\\/\\\\}
    re=${re//./\\.}
    re=${re//+/\\+}
    re=${re//\{/\\\{}
    re=${re//\}/\\\}}
    re=${re//\(/\\\(}
    re=${re//\)/\\\)}
    # `**/` = any number of leading directories; `**` = anything;
    # `*` = anything within one path segment.
    re=${re//\*\*\//__ANYDIR__}
    re=${re//\*\*/__ANY__}
    re=${re//\*/[^\/]*}
    re=${re//__ANYDIR__/(.*\/)?}
    re=${re//__ANY__/.*}
    # Anchor. A rule that matches mid-path would fire on `docs/keys-guide.md`.
    case "$re" in
      '(.*/)?'*) : ;;              # already allows any prefix
      *) re="(^|/)$re" ;;
    esac
    case "$g" in
      *'**') : ;;                  # a trailing ** is open-ended by definition
      *) re="$re\$" ;;
    esac
    out="${out:+$out|}$re"
  done <<< "$globs"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# The union the merge bound actually enforces: the loop's push gate OR the
# standing orders' own list. Non-zero (and prints nothing) if EITHER source is
# unreadable — callers MUST treat that as "refuse", never as "no rules". Half a
# rule set is not a rule set.
session_sensitive_re() {
  local a b
  a=$(session_loop_sensitive_re) || return 1
  b=$(session_claude_md_re) || return 1
  printf '(%s)|(%s)' "$a" "$b"
}

# session_sensitive_hits — read newline-separated paths on stdin, print the ones
# that are sensitive.
# Exit: 0 = at least one hit (i.e. REQUIRES A HUMAN)
#       1 = no hits (clear)
#       2 = CANNOT VERIFY — the rules could not be read. Callers must treat 2
#           exactly like 0. A gate that cannot see refuses.
session_sensitive_hits() {
  local re; re=$(session_sensitive_re) || {
    echo "SENSITIVE-GATE-BLIND: could not read SENSITIVE_PATH_RE — refusing" >&2
    return 2
  }
  local hits; hits=$(grep -E "$re" || true)
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; return 0; fi
  return 1
}

# session_guard_mr_sensitive <project_id> <iid>
# Decide whether an MR may be merged unattended, and — when it may not — make
# the forge say no rather than hoping the next agent remembers.
# Exit: 0 clear to merge unattended · 1 HELD (sensitive) · 2 cannot verify → HELD
session_guard_mr_sensitive() {
  local project_id="$1" iid="$2" apply="${3:-1}"
  local changes paths hits rc

  changes=$(_sess_mr_get "/projects/$project_id/merge_requests/$iid/changes?access_raw_diffs=false" 2>/dev/null) || changes=""
  if [ -z "$changes" ] || printf '%s' "$changes" | grep -q '"message"'; then
    echo "GUARD-BLIND: cannot read changes for !$iid on project $project_id — HOLDING" >&2
    [ "$apply" = "1" ] && session_hold_mr "$project_id" "$iid" "guard could not read the diff"
    return 2
  fi
  paths=$(printf '%s' "$changes" | "$YQ" e -p=json '.changes[].new_path' - 2>/dev/null)
  paths="$paths
$(printf '%s' "$changes" | "$YQ" e -p=json '.changes[].old_path' - 2>/dev/null)"

  set +e
  hits=$(printf '%s\n' "$paths" | sort -u | grep -v '^$' | session_sensitive_hits)
  rc=$?
  set -e
  case "$rc" in
    0)
      echo "HELD — !$iid touches sensitive paths (human merge required):" >&2
      printf '%s\n' "$hits" | sed 's/^/    /' >&2
      [ "$apply" = "1" ] && session_hold_mr "$project_id" "$iid" "touches sensitive paths: $(printf '%s' "$hits" | tr '\n' ' ')"
      return 1 ;;
    2)
      [ "$apply" = "1" ] && session_hold_mr "$project_id" "$iid" "sensitive-path rules unreadable"
      return 2 ;;
    *) return 0 ;;
  esac
}

# session_hold_mr <project_id> <iid> <reason>
# Put a hold on an MR that the FORGE enforces.
#
# Delegation, deliberately: if `pl mr hold` is present (!314, branch
# feat/mr-hold-gate — unmerged as of 2026-08-02) we call it, because it also
# posts the structured release note and carries its own tests. If it is not, we
# do the same thing the only way that actually binds — set Draft via the API.
# Two implementations of a hold would be one too many; a hold that waits for an
# unmerged branch to land would be none at all.
session_hold_mr() {
  local project_id="$1" iid="$2" reason="${3:-unattended-session bound}"
  if [ -x "$PROJECT_ROOT/scripts/commands/mr.sh" ]; then
    "$PROJECT_ROOT/pl" mr hold "$iid" --reason "$reason" && return 0
    echo "session_hold_mr: pl mr hold failed; falling back to the Draft PUT" >&2
  fi
  local title new
  title=$(_sess_mr_get "/projects/$project_id/merge_requests/$iid" 2>/dev/null | "$YQ" e -p=json '.title // ""' -)
  [ -n "$title" ] || { echo "session_hold_mr: cannot read !$iid — HOLD NOT APPLIED" >&2; return 1; }
  case "$title" in
    Draft:*|WIP:*) return 0 ;;   # already held
  esac
  new="Draft: $title"
  _sess_mr_api_put_json "/projects/$project_id/merge_requests/$iid" \
    "{\"title\":$(_sess_json_quote "$new")}" || {
      echo "session_hold_mr: Draft PUT failed for !$iid — HOLD NOT APPLIED" >&2; return 1; }
  _sess_mr_api_post_json "/projects/$project_id/merge_requests/$iid/notes" \
    "{\"body\":$(_sess_json_quote "🔒 **HELD for a human.** An unattended session opened or updated this MR and the sensitive-path bound fired.

Reason: $reason

The hold is the GitLab **Draft** flag, which the forge enforces — a prose hold is not a hold (2026-08-02: one was overridden by its own author's sweeper inside minutes). Remove the \`Draft:\` prefix to release, after a human has read the diff.")}" >/dev/null || true
  return 0
}

# Quote an arbitrary blob as a JSON string, newlines and all. Kept dependency-
# free (no jq on every host) and deliberately literal: escape the backslash
# FIRST, or every subsequent escape gets double-escaped.
_sess_json_quote() {
  printf '%s' "${1:-}" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g' \
    | awk 'BEGIN{printf "\""} {if(NR>1) printf "\\n"; printf "%s",$0} END{printf "\""}'
}

_sess_mr_api_put_json()  { _sess_mr_api_send PUT  "$1" "$2"; }
_sess_mr_api_post_json() { _sess_mr_api_send POST "$1" "$2"; }
_sess_mr_api_send() { # $1=METHOD $2=path $3=json
  local method="$1" path="$2" payload="$3" host token body rc
  host=$(_sess_mr_host); token=$(_sess_mr_token)
  [ -n "$host" ] && [ -n "$token" ] || return 2
  # ops#374: config on stdin — a credential must never become a file (see lib/http.sh).
  # The body stays a file (curl `data = "@…"` needs one); it holds no credential.
  body=$(mktemp); chmod 600 "$body"
  printf '%s' "$payload" > "$body"
  { printf 'silent\nconnect-timeout = 8\nmax-time = 25\n'
    printf 'request = "%s"\n' "$method"
    printf 'header = "PRIVATE-TOKEN: %s"\nheader = "Content-Type: application/json"\n' "$token"
    printf 'data = "@%s"\nurl = "https://%s/api/v4%s"\n' "$body" "$host" "$path"
  } | curl -K - >/dev/null 2>&1; rc=$?
  token=""
  rm -f "$body"; return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# BOUND 2 — live writes are demo-tier only
#
# LIVE IS NOT PROD: nwd/ssd/nwc/ss hold no real user data, and ordinary care is
# the right posture there. That is exactly why the bound is worth drawing
# precisely rather than banning "live" wholesale — an unattended session that
# cannot touch the demo tier cannot do the work it exists to do.
#
# Fail closed on an unknown site: a site nobody listed is a site nobody
# considered.
# ─────────────────────────────────────────────────────────────────────────────

: "${NWP_SESSION_DEMO_SITES:=nwd ssd}"

# session_guard_live <site> [tier]
# Exit: 0 permitted unattended · 1 REFUSED (needs a human)
session_guard_live() {
  local site="$1" tier="${2:-live}" s
  case "$tier" in
    dev|stg) return 0 ;;                       # never leaves the workstation
    live) : ;;
    prod|*)
      echo "REFUSED: '$tier' writes are not available to an unattended session at all." >&2
      echo "         prod belongs to ver alone — no AI-accessible machine writes to prod (CLAUDE.md, permanent)." >&2
      return 1 ;;
  esac
  for s in $NWP_SESSION_DEMO_SITES; do
    [ "$s" = "$site" ] && return 0
  done
  echo "REFUSED: '$site' is not in the demo tier, so a live write to it needs a human." >&2
  echo "         demo tier = ${NWP_SESSION_DEMO_SITES}. Widen it deliberately (NWP_SESSION_DEMO_SITES), not in passing." >&2
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# BOUND 3 — repeat-failure stop
#
# A loop that retries a deterministic failure is not resilience, it is a way to
# spend a night and a budget discovering the same thing repeatedly. Two
# identical signatures and the supervisor stops and says so.
#
# The signature is the caller's job to make stable (e.g. "brief:mr-blind",
# "run:exit-2"). A signature that embeds a timestamp never repeats, which is
# how this class of guard usually dies quietly.
# ─────────────────────────────────────────────────────────────────────────────

: "${NWP_SESSION_MAX_REPEATS:=2}"

_sess_ledger() { printf '%s/failures.tsv' "$NWP_SESSION_STATE_DIR"; }

session_failure_record() { # $1=signature [$2=detail]
  local sig="$1" detail="${2:-}"
  mkdir -p "$NWP_SESSION_STATE_DIR"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sig" "$detail" >> "$(_sess_ledger)"
}

session_failure_count() { # $1=signature
  local f; f=$(_sess_ledger)
  [ -r "$f" ] || { printf '0'; return 0; }
  awk -F'\t' -v s="$1" '$2==s{n++} END{print n+0}' "$f"
}

# session_repeat_stop <signature>
# Exit: 0 = STOP (this failure has already happened enough times)
#       1 = keep going
session_repeat_stop() {
  local n; n=$(session_failure_count "$1")
  [ "$n" -ge "$NWP_SESSION_MAX_REPEATS" ]
}

session_failure_clear() { # $1=signature (a success clears its own signature)
  local f tmp; f=$(_sess_ledger)
  [ -r "$f" ] || return 0
  tmp="$f.tmp.$$"
  awk -F'\t' -v s="$1" '$2!=s' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

# ─────────────────────────────────────────────────────────────────────────────
# BOUND 4 — token ceiling
#
# Two layers, because each catches what the other misses:
#   * `claude -p --max-turns N` is a hard structural bound the model cannot talk
#     its way past, but turns are a poor proxy for spend;
#   * the transcript tally is the real number, and is what stops a run that is
#     burning tokens inside a few enormous turns.
# ─────────────────────────────────────────────────────────────────────────────

: "${NWP_SESSION_TOKEN_CEILING:=2000000}"
: "${NWP_SESSION_MAX_TURNS:=200}"

# session_tokens_used <transcript.jsonl>
# Sum every usage record in a Claude Code transcript. Cache reads are counted:
# they are cheaper, not free, and a ceiling that ignores them is not a ceiling.
session_tokens_used() {
  local t="$1"
  [ -r "$t" ] || { printf '0'; return 0; }
  awk '
    {
      n=0
      while (match($0, /"(input_tokens|output_tokens|cache_creation_input_tokens|cache_read_input_tokens)":[ ]*[0-9]+/)) {
        f=substr($0, RSTART, RLENGTH); sub(/^.*:[ ]*/, "", f); n+=f
        $0 = substr($0, RSTART+RLENGTH)
      }
      total+=n
    }
    END { printf "%d", total+0 }
  ' "$t"
}

# session_budget_exceeded <transcript.jsonl> [ceiling]
# Exit: 0 = over budget (STOP) · 1 = within budget
session_budget_exceeded() {
  local t="$1" ceiling="${2:-$NWP_SESSION_TOKEN_CEILING}" used
  used=$(session_tokens_used "$t")
  [ "$used" -ge "$ceiling" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# NOTIFICATION — and the refusal that makes it load-bearing
#
# `pl notify` is the estate's single Gotify path (self-hosted; no SaaS). The
# interesting part is not sending, it is this:
#
#   An unattended session that cannot reach the operator is unbounded in the one
#   dimension that matters — time. It can be stuck, or looping, or finished
#   hours ago, and nobody learns which. So the supervisor PREFLIGHTS the
#   notification path and REFUSES TO LAUNCH if it is dead.
#
# This is the same doctrine as "a blind audit is not a clean audit", applied to
# the thing that would have told you the audit was blind.
#
# Escape hatch, deliberately explicit and deliberately ugly:
# NWP_SESSION_ALLOW_NO_NOTIFY=1.
# ─────────────────────────────────────────────────────────────────────────────

session_notify() { # $1=event $2=message [$3=priority]
  local event="$1" msg="$2" prio="${3:-5}"
  local pl="${NWP_PL:-$PROJECT_ROOT/pl}"
  [ -x "$pl" ] || return 1
  "$pl" notify send "${NWP_SESSION_NOTIFY_APP:-ops}" "[session:$event] $msg" \
      --priority "$prio" --title "NWP session $event" >/dev/null 2>&1
}

# Exit: 0 = the operator is reachable · 1 = NOT reachable (do not launch)
session_notify_healthy() {
  local pl="${NWP_PL:-$PROJECT_ROOT/pl}"
  [ -x "$pl" ] || return 1
  "$pl" notify health "${NWP_SESSION_NOTIFY_APP:-ops}" >/dev/null 2>&1
}
