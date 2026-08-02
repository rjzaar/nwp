#!/usr/bin/env bash
################################################################################
# SessionEnd hook — flip the baton when a session ends, whether or not it meant
# to.
#
# WHY A HOOK AND NOT A HABIT
#   A session that ends without flipping the baton leaves the next one polling
#   IN-PROGRESS until the 90-minute timeout. Remembering is not a mechanism.
#   `SessionEnd` fires on real termination (/exit, Ctrl-D, /clear, logout) — and
#   notably NOT when someone types "exit" as a prompt, which is why `Stop` (once
#   per turn) is the wrong event here.
#
# WHY IT IS THIN
#   All the logic is in `pl session end`, which is a verb, which means it is in
#   the bats suite and in CI. This file is an adapter: read the hook's JSON,
#   call the verb. It deliberately holds no policy of its own. Adapters that
#   grow policy are how the estate ends up with two answers to one question.
#
# EXIT REASON → BATON STATUS
#   The hook payload's exit_reason distinguishes a clean end from a crash. A
#   session that dies grades ABANDONED, so the next reader is told to re-derive
#   rather than trusting a half-written handover. Unknown reason → ABANDONED:
#   the cheap error is re-checking, the expensive one is trusting.
#
# INSTALL: see docs/guides/session-handover-runbook.md (settings.json snippet).
# It composes with ~/claudemax/issue-hooks/issue-summary-on-end.sh; Claude Code
# runs every matching hook, so the issue summary still posts.
################################################################################
set -uo pipefail

# Never let a hook failure take the session's exit down with it.
trap 'exit 0' ERR

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

reason=$(printf '%s' "$input" | jq -r '.exit_reason // .reason // ""')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""')

case "$reason" in
  clear|logout|exit|prompt_input_exit|"") status=READY ;;
  *)                                      status=ABANDONED ;;
esac

PL="${NWP_PL:-$HOME/nwp/pl}"
[ -x "$PL" ] || exit 0

# The transcript is the only honest source for "what did this session actually
# do" — but it is a conversation, not a summary, and this hook must not block on
# summarising one. Pass it as the UNVERIFIED evidence pointer and let the human
# or the next session read it.
summary=$(mktemp)
{
  printf 'exit_reason: %s\n' "${reason:-unknown}"
  [ -n "$transcript" ] && printf 'transcript: %s\n' "$transcript"
  printf 'This handover was written by the SessionEnd hook, not by the session itself,\n'
  printf 'so it records no intent — only the state at the moment the session stopped.\n'
} > "$summary"

"$PL" session end --status="$status" --summary="$summary" >/dev/null 2>&1
rm -f "$summary"
exit 0
