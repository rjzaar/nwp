#!/bin/bash
set -uo pipefail
################################################################################
# pl session — session handover: the baton in, the brief out, the supervisor
#              that joins one session to the next.
#
# WHY THIS IS A `pl` VERB AND NOT A SCRIPT BESIDE THE TOOLING
# -----------------------------------------------------------
# The standing order says everything goes through `pl`, and the reason applies
# here with unusual force. This machinery decides what an unattended agent
# believes about the estate and what it is allowed to do to it. A loose script
# is not in `pl commands`, is not in the bats suite, is not in CI, and is not
# discoverable by the next session — which is precisely the population this
# thing exists to serve. Everything below is testable because it is a verb.
#
# WHY `session` AND NOT `loop` OR `handover`
#   `pl loop` is the agent-loop: issue → worktree → fix → MR. Different actor,
#   different lifecycle. This verb is about the SESSION as a unit — its brief,
#   its baton, its bounds, its supervisor. It sits beside `pl issue work`, which
#   starts one; `pl session` is what makes ending one, and starting the next,
#   into something other than an act of memory.
#
# SUBCOMMANDS
#   brief        generate the session brief from LIVE state (the point of it all)
#   baton        status | write | heartbeat | ready | abandon
#   end          write the handover + flip the baton (called by the SessionEnd hook)
#   guard        mr <iid> | live <site> [tier] | budget <transcript>
#   supervisor   install | status | run | uninstall  (systemd user timer, `ai-host`)
#
# EXIT
#   0 ok · 1 usage/failure · 2 CANNOT VERIFY (blind) · 3 HELD / refused by a bound
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh" 2>/dev/null || true
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true
source "$PROJECT_ROOT/lib/session.sh"
source "$PROJECT_ROOT/lib/session-bounds.sh"

: "${NWP_SESSION_PROJECT_ID:=9}"          # nwp/nwp — where the MRs are

show_help() {
    cat <<EOF
${BOLD:-}pl session${NC:-} — hand one session to the next without trusting memory

${BOLD:-}USAGE:${NC:-}
    pl session brief [--format=md|json] [--recompute] [--prose=FILE]
    pl session baton status|write|heartbeat|ready|abandon
    pl session end [--status=READY|ABANDONED] [--summary=FILE]
    pl session guard mr <iid> [--dry-run] | live <site> [tier] | budget <transcript>
    pl session supervisor install|status|run|uninstall

${BOLD:-}THE CONTRACT${NC:-}
    A brief is DERIVED. Every figure carries the command that produced it and
    the moment it was read. Prose appears in exactly one section, stamped
    UNVERIFIED, because a sentence does not change when the world does.

    A section that could not be read says BLIND. Blind is never rendered as
    empty: "no open MRs" and "I was not allowed to look" are opposite facts.

${BOLD:-}BOUNDS ON AN UNATTENDED RUN${NC:-}
    read anything · fix · push · open MRs        — allowed
    merge a sensitive path                       — HELD in the forge (Draft)
    live write outside the demo tier             — REFUSED locally
    same failure twice                           — STOP, do not loop
    token ceiling reached                        — STOP
    operator unreachable (Gotify)                — DO NOT LAUNCH

${BOLD:-}EXIT:${NC:-} 0 ok · 1 failure · 2 cannot verify · 3 held/refused
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# brief
# ─────────────────────────────────────────────────────────────────────────────

cmd_brief() {
  local format=md recompute=0 prose_file="" a
  for a in "$@"; do
    case "$a" in
      --format=*)   format="${a#--format=}" ;;
      --recompute)  recompute=1 ;;
      --prose=*)    prose_file="${a#--prose=}" ;;
      -h|--help)    show_help; return 0 ;;
      *) print_error "unknown flag: $a"; return 1 ;;
    esac
  done

  local g i m r gl h
  g=$(session_section_git "$PROJECT_ROOT")
  i=$(session_section_issues)
  m=$(session_section_mrs "$NWP_SESSION_PROJECT_ID" "$recompute")
  r=$(session_section_rag)
  gl=$(session_section_goldens)
  h=$(session_section_holds "$NWP_SESSION_PROJECT_ID")

  if [ "$format" = "json" ]; then
    printf '{"generated":"%s","host":"%s","baton":{"path":"%s","effective_status":"%s","age_min":"%s"},"sections":[%s,%s,%s,%s,%s,%s]}\n' \
      "$(_sess_now)" "$(hostname -s 2>/dev/null)" "$(session_baton_path)" \
      "$(session_baton_effective_status)" "$(session_baton_age_min)" \
      "$g" "$i" "$m" "$r" "$gl" "$h"
    return 0
  fi

  _blind()  { printf '%s' "$1" | "$YQ" e -p=json '.provenance.blind // ""' - 2>/dev/null; }
  _src()    { printf '%s' "$1" | "$YQ" e -p=json '.provenance.source // ""' - 2>/dev/null; }
  _at()     { printf '%s' "$1" | "$YQ" e -p=json '.provenance.at // ""' - 2>/dev/null; }
  _f()      { printf '%s' "$1" | "$YQ" e -p=json ".$2 // \"\"" - 2>/dev/null; }
  # Render one section header, and make blindness impossible to skim past.
  _hdr() {
    local sec="$1" name="$2" b; b=$(_blind "$sec")
    printf '\n### %s\n' "$name"
    printf '_derived from `%s` at %s_\n' "$(_src "$sec")" "$(_at "$sec")"
    [ -n "$b" ] && printf '\n> ⚠️ **BLIND — %s**\n> This section is UNKNOWN, not empty.\n' "$b"
    return 0
  }

  local baton_status; baton_status=$(session_baton_effective_status)

  cat <<EOF
# Session brief — $(_sess_now)

Host \`$(hostname -s 2>/dev/null)\` · repo \`$PROJECT_ROOT\`

**Everything below the PROSE heading is DERIVED.** It was read out of the estate
at the timestamps shown, not carried from a previous session. If a figure here
disagrees with something you remember, the figure is right.

## Baton

| field | value |
|---|---|
| file | \`$(session_baton_path)\` |
| written status | \`$(session_baton_written_status)\` |
| **effective status** | **\`$baton_status\`** |
| minutes since last heartbeat | $(session_baton_age_min) |
| dropped-baton timeout | ${NWP_BATON_TIMEOUT_MIN} min |
EOF

  case "$baton_status" in
    ABANDONED*)
      cat <<'EOF'

> 🔁 **RE-DERIVE MODE.** The previous session did not hand over cleanly, so the
> PROSE section below is partial at best. Treat every prose line as a lead to
> check, never as a fact to build on.
EOF
      ;;
  esac

  _hdr "$g" "Git"
  printf '\n| field | value |\n|---|---|\n'
  printf '| branch | `%s` |\n| HEAD | `%s` |\n| origin/main | `%s` |\n| behind origin/main | %s |\n| ahead of origin/main | %s |\n' \
    "$(_f "$g" branch)" "$(_f "$g" head)" "$(_f "$g" origin_main)" \
    "$(_f "$g" behind_origin_main)" "$(_f "$g" ahead_of_origin_main)"

  _hdr "$i" "Issue queue"
  local trunc; trunc=$(_f "$i" truncation_warning)
  [ -n "$trunc" ] && printf '\n> ⚠️ **TRUNCATED** — %s\n' "$trunc"
  printf '\n```\n%b\n```\n' "$(_f "$i" text)"

  _hdr "$m" "Open merge requests (project $NWP_SESSION_PROJECT_ID)"
  printf '\nopen: **%s**' "$(_f "$m" open_count)"
  [ "$recompute" = "0" ] && printf '  ·  _merge status NOT recomputed; `cannot_be_merged?` is a claim, not a finding (ops#213)_'
  printf '\n\n```\n%b\n```\n' "$(_f "$m" rows)"

  _hdr "$r" "Fleet RAG"
  printf '\n| RED | AMBER | GREEN | UNSCANNED | generated | age |\n|---|---|---|---|---|---|\n'
  printf '| %s | %s | %s | %s | %s | %s min |\n' \
    "$(_f "$r" RED)" "$(_f "$r" AMBER)" "$(_f "$r" GREEN)" "$(_f "$r" UNSCANNED)" \
    "$(_f "$r" generated)" "$(_f "$r" age_min)"

  _hdr "$gl" "Staged demo goldens"
  printf '\n```\n%b\n```\n' "$(_f "$gl" rows)"
  printf '\n%s superseded copies exist under `demo-golden-live.*` and are NOT live.\n' "$(_f "$gl" archived_copies)"
  printf '\n> Do **not** recapture a golden listed above without a reason recorded first.\n'

  _hdr "$h" "Holds the forge enforces"
  printf '\nDraft (= unmergeable) MRs: **%s**\n' "$(_f "$h" draft_count)"
  printf '\n```\n%b\n```\n' "$(_f "$h" rows)"
  printf '\n> A hold written in a document is not a hold. Only what is listed here binds.\n'

  # ---- bounds --------------------------------------------------------------
  printf '\n### Bounds in force\n\n| bound | setting | state |\n|---|---|---|\n'
  printf '| sensitive-path merges | `SENSITIVE_PATH_RE` from `scripts/agent-loop/agent-loop.sh` | %s |\n' \
    "$(session_sensitive_re >/dev/null 2>&1 && echo 'readable → enforced' || echo '**UNREADABLE → gate refuses everything**')"
  printf '| live writes | demo tier only: `%s` | enforced locally |\n' "$NWP_SESSION_DEMO_SITES"
  printf '| repeat failure | stop at %s identical signatures | %s recorded |\n' \
    "$NWP_SESSION_MAX_REPEATS" "$( [ -r "$(_sess_ledger)" ] && wc -l < "$(_sess_ledger)" | tr -d ' ' || echo 0 )"
  printf '| token ceiling | %s tokens · %s turns | per run |\n' "$NWP_SESSION_TOKEN_CEILING" "$NWP_SESSION_MAX_TURNS"
  printf '| operator reachable | `pl notify health` | %s |\n' \
    "$(session_notify_healthy && echo 'yes' || echo '**NO — supervisor will refuse to launch**')"

  # ---- prose ---------------------------------------------------------------
  cat <<'EOF'

---

## PROSE — judgement that cannot be derived

Everything above this line was read from the estate. Everything below it is a
previous session's opinion, and opinions go stale silently. Nothing here is a
premise; each line is a lead to verify.
EOF
  if [ -n "$prose_file" ] && [ -r "$prose_file" ]; then
    printf '\n_(carried from `%s`, UNVERIFIED)_\n\n' "$prose_file"
    sed 's/^/> /' "$prose_file"
  else
    local baton; baton=$(session_baton_path)
    if [ -r "$baton" ]; then
      printf '\n_(carried from the baton `%s`, UNVERIFIED)_\n\n' "$baton"
      tail -n +3 "$baton" | sed 's/^/> /'
    else
      printf '\n_(no prose available — the baton is missing. Nothing is carried; derive everything.)_\n'
    fi
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# baton
# ─────────────────────────────────────────────────────────────────────────────

cmd_baton() {
  local sub="${1:-status}"; shift || true
  case "$sub" in
    status)
      local eff; eff=$(session_baton_effective_status)
      printf 'file:      %s\n' "$(session_baton_path)"
      printf 'written:   %s\n' "$(session_baton_written_status)"
      printf 'effective: %s\n' "$eff"
      printf 'age_min:   %s (timeout %s)\n' "$(session_baton_age_min)" "$NWP_BATON_TIMEOUT_MIN"
      case "$eff" in
        READY) return 0 ;;
        IN-PROGRESS) return 0 ;;
        *) return 2 ;;      # every ABANDONED shape is "cannot rely on this"
      esac ;;
    write)     session_baton_write "${1:-IN-PROGRESS}" ;;
    heartbeat) session_baton_heartbeat ;;
    ready)     session_baton_set_status READY ;;
    abandon)   session_baton_set_status ABANDONED ;;
    *) print_error "pl session baton: unknown subcommand '$sub'"; return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# end — the SessionEnd half of the contract
#
# The failure this closes: a session that ends without flipping the baton leaves
# the next one waiting on IN-PROGRESS forever. Remembering to flip it is not a
# plan; the hook does it whether the session meant to or not.
#
# What the handover MUST record, because these are the four things the next
# session cannot reconstruct on its own:
#   status · what was IN FLIGHT · what is HELD and why · what is UNVERIFIED
# ─────────────────────────────────────────────────────────────────────────────

cmd_end() {
  local status=READY summary_file="" a
  for a in "$@"; do
    case "$a" in
      --status=*)  status="${a#--status=}" ;;
      --summary=*) summary_file="${a#--summary=}" ;;
      -h|--help)   show_help; return 0 ;;
    esac
  done

  local now; now=$(_sess_now)
  local held; held=$(session_section_holds "$NWP_SESSION_PROJECT_ID")
  local held_n; held_n=$(printf '%s' "$held" | "$YQ" e -p=json '.draft_count // "0"' - 2>/dev/null)
  local held_blind; held_blind=$(printf '%s' "$held" | "$YQ" e -p=json '.provenance.blind // ""' - 2>/dev/null)
  local git_s; git_s=$(session_section_git "$PROJECT_ROOT")

  {
    printf '\n# Baton — written automatically by `pl session end` at %s\n\n' "$now"
    printf 'Host `%s` · repo `%s` · branch `%s` @ `%s`\n' \
      "$(hostname -s 2>/dev/null)" "$PROJECT_ROOT" \
      "$(printf '%s' "$git_s" | "$YQ" e -p=json '.branch // ""' -)" \
      "$(printf '%s' "$git_s" | "$YQ" e -p=json '.head // ""' -)"

    printf '\n## Status\n\n`%s`' "$status"
    if [ "$status" = "ABANDONED" ]; then
      printf ' — this session stopped WITHOUT finishing. Everything below is partial.\n'
    else
      printf ' — this session finished cleanly.\n'
    fi

    printf '\n## In flight when this session ended\n\n'
    printf 'Branch `%s` is %s commit(s) ahead of and %s behind `origin/main`.\n' \
      "$(printf '%s' "$git_s" | "$YQ" e -p=json '.branch // ""' -)" \
      "$(printf '%s' "$git_s" | "$YQ" e -p=json '.ahead_of_origin_main // "?"' -)" \
      "$(printf '%s' "$git_s" | "$YQ" e -p=json '.behind_origin_main // "?"' -)"

    printf '\n## HELD, and why\n\n'
    if [ -n "$held_blind" ]; then
      printf '⚠️ **UNKNOWN** — %s\n\nDo not read this as "nothing is held".\n' "$held_blind"
    else
      printf '%s MR(s) are Draft in the forge and cannot be merged until a human clears them.\n' "$held_n"
      printf '\n```\n%b\n```\n' "$(printf '%s' "$held" | "$YQ" e -p=json '.rows // ""' -)"
    fi

    printf '\n## UNVERIFIED\n\n'
    printf 'Claims this session did **not** check against ground truth. Verify before use.\n\n'
    if [ -n "$summary_file" ] && [ -r "$summary_file" ]; then
      sed 's/^/- /' "$summary_file"
    else
      printf -- '- (none recorded — the session ended without writing a summary, which is itself a reason to re-derive)\n'
    fi
    printf '\n---\n\n_Regenerate live state instead of trusting this file: `pl session brief`._\n'
  } | session_baton_write "$status"

  print_success "baton flipped to $status: $(session_baton_path)"
  session_notify "ended" "session ended $status on $(hostname -s) — baton flipped" 4 || \
    print_warning "could not notify the operator (pl notify)"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# guard
# ─────────────────────────────────────────────────────────────────────────────

cmd_guard() {
  local what="${1:-}"; shift || true
  case "$what" in
    mr)
      local iid="${1:-}"; shift || true
      [ -n "$iid" ] || { print_error "usage: pl session guard mr <iid> [--dry-run]"; return 1; }
      local apply=1; [ "${1:-}" = "--dry-run" ] && apply=0
      local rc=0
      session_guard_mr_sensitive "$NWP_SESSION_PROJECT_ID" "$iid" "$apply" || rc=$?
      case "$rc" in
        0) print_success "!$iid touches no sensitive path — an unattended merge is within bounds"; return 0 ;;
        1) print_error "!$iid is HELD for a human"; return 3 ;;
        *) print_error "!$iid could not be checked — HELD (a gate that cannot see refuses)"; return 2 ;;
      esac ;;
    live)
      local site="${1:-}" tier="${2:-live}"
      [ -n "$site" ] || { print_error "usage: pl session guard live <site> [tier]"; return 1; }
      if session_guard_live "$site" "$tier"; then
        print_success "$site@$tier is inside the unattended live bound"; return 0
      fi
      return 3 ;;
    budget)
      local t="${1:-}"
      [ -n "$t" ] || { print_error "usage: pl session guard budget <transcript.jsonl>"; return 1; }
      local used; used=$(session_tokens_used "$t")
      printf 'tokens used: %s / ceiling %s\n' "$used" "$NWP_SESSION_TOKEN_CEILING"
      if session_budget_exceeded "$t"; then print_error "BUDGET EXCEEDED — stop the run"; return 3; fi
      print_success "within budget"; return 0 ;;
    repeat)
      local sig="${1:-}"
      [ -n "$sig" ] || { print_error "usage: pl session guard repeat <signature>"; return 1; }
      printf 'signature "%s": %s occurrence(s), stop at %s\n' \
        "$sig" "$(session_failure_count "$sig")" "$NWP_SESSION_MAX_REPEATS"
      if session_repeat_stop "$sig"; then print_error "REPEAT-FAILURE STOP"; return 3; fi
      print_success "not a repeat"; return 0 ;;
    *) print_error "pl session guard: expected mr|live|budget|repeat"; return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# supervisor
# ─────────────────────────────────────────────────────────────────────────────

SUP_UNIT_DIR="${NWP_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
# Units are PER-HOST, so resolve the directory from the host we are installing
# on rather than hardcoding one. Two reasons, both real: a literal hostname in
# code violates the role-label rule (docs/reference/role-vocabulary.md), and a
# hardcoded path silently installs the wrong host's units if the supervisor ever
# runs anywhere else. `pl session supervisor install` on the `ai-host` resolves
# to that host's own servers/<host>/system/ tree.
SUP_SRC="$PROJECT_ROOT/servers/${NWP_SESSION_UNIT_HOST:-$(hostname -s)}/system"

cmd_supervisor() {
  local sub="${1:-status}"; shift || true
  case "$sub" in
    install)
      mkdir -p "$SUP_UNIT_DIR"
      # The repo stores these as `systemd-<name>` under servers/<host>/system/,
      # matching the existing convention (servers/live/system/systemd-nwc-cron.*)
      # and the servers/ gitignore allowlist. systemd needs the bare unit name,
      # so the prefix is dropped on the way in. Named explicitly rather than
      # globbed: a glob that matches nothing installs nothing and succeeds.
      install -m 0644 "$SUP_SRC/systemd-nwp-session-supervisor.service" \
              "$SUP_UNIT_DIR/nwp-session-supervisor.service" || return 1
      install -m 0644 "$SUP_SRC/systemd-nwp-session-supervisor.timer" \
              "$SUP_UNIT_DIR/nwp-session-supervisor.timer" || return 1
      systemctl --user daemon-reload || return 1
      systemctl --user enable --now nwp-session-supervisor.timer || return 1
      print_success "supervisor timer installed and started"
      print_info "linger must be on for it to survive logout: loginctl enable-linger \$USER"
      ;;
    uninstall)
      systemctl --user disable --now nwp-session-supervisor.timer 2>/dev/null || true
      rm -f "$SUP_UNIT_DIR/nwp-session-supervisor.timer" "$SUP_UNIT_DIR/nwp-session-supervisor.service"
      systemctl --user daemon-reload || true
      print_success "supervisor removed" ;;
    status)
      systemctl --user status nwp-session-supervisor.timer --no-pager 2>&1 | head -12 || true
      printf '\n'; cmd_baton status ;;
    run) cmd_supervisor_run "$@" ;;
    *) print_error "pl session supervisor: expected install|status|run|uninstall"; return 1 ;;
  esac
}

# The tick the timer fires. Everything it does is a bound being checked BEFORE
# anything is launched — the order is the design.
cmd_supervisor_run() {
  local dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
  # NWP_PL indirection so the supervisor is testable without a live estate. The
  # default is the real verb; a test can substitute a stub and still exercise
  # the ORDER of the checks, which is the part that carries the safety.
  local PL="${NWP_PL:-$PROJECT_ROOT/pl}"
  local tmux_sess="${NWP_SESSION_TMUX:-nwp-auto}"
  local eff; eff=$(session_baton_effective_status)
  local mode=fresh

  # ── 0. never two of us ────────────────────────────────────────────────────
  # `tmux has-session` also returns non-zero when tmux is ABSENT, which would
  # read as "no session running, go ahead" and launch into nothing. Separate the
  # two: no tmux is a CANNOT-VERIFY, not a green light.
  if ! command -v tmux >/dev/null 2>&1; then
    print_error "supervisor: no tmux on this host — cannot start or supervise a durable session"
    return 2
  fi
  if tmux has-session -t "$tmux_sess" 2>/dev/null; then
    print_info "supervisor: '$tmux_sess' is already running — nothing to do"
    return 0
  fi

  # ── 1. is the baton asking for a session at all? ──────────────────────────
  case "$eff" in
    READY) mode=fresh ;;
    ABANDONED*)
      # The dropped baton. Start, but in RE-DERIVE mode: the previous session's
      # prose is partial by definition and must not be treated as a premise.
      mode=re-derive ;;
    IN-PROGRESS)
      print_info "supervisor: baton IN-PROGRESS, ${NWP_BATON_TIMEOUT_MIN}min timeout not reached — waiting"
      return 0 ;;
    *) print_error "supervisor: unrecognised baton state '$eff'"; return 2 ;;
  esac

  # ── 2. repeat-failure stop, BEFORE spending anything ──────────────────────
  local sig="supervisor:launch:$mode"
  if session_repeat_stop "$sig"; then
    print_error "supervisor: STOPPING — '$sig' has failed $(session_failure_count "$sig") times"
    session_notify "stopped-repeat-failure" \
      "supervisor STOPPED: '$sig' failed $(session_failure_count "$sig")x. Not looping. Clear with: pl session guard repeat --clear" 8 || true
    return 3
  fi

  # ── 3. can we even tell the operator what happens next? ───────────────────
  if ! session_notify_healthy; then
    if [ "${NWP_SESSION_ALLOW_NO_NOTIFY:-0}" != "1" ]; then
      print_error "supervisor: REFUSING to launch — this host cannot reach the operator (pl notify health failed)."
      print_error "            An unattended session nobody can be told about is unbounded in time."
      print_error "            Fix the Gotify path, or set NWP_SESSION_ALLOW_NO_NOTIFY=1 deliberately."
      session_failure_record "$sig" "notify-unhealthy"
      return 3
    fi
    print_warning "supervisor: notification path is DEAD and NWP_SESSION_ALLOW_NO_NOTIFY=1 — launching blind"
  fi

  # ── 4. brief first. A session starts from generated state or not at all. ──
  local brief_dir="${NWP_SESSION_BRIEF_DIR:-$HOME/.local/state/nwp/session/briefs}"
  mkdir -p "$brief_dir"
  local brief="$brief_dir/brief-$(date -u +%Y%m%dT%H%M%SZ).md"
  if ! "$PL" session brief --recompute > "$brief" 2>/dev/null; then
    session_failure_record "$sig" "brief-generation-failed"
    session_notify "stuck" "supervisor could not generate a session brief — not launching" 7 || true
    return 2
  fi

  if [ "$dry" = "1" ]; then
    print_success "supervisor --dry-run: would launch mode=$mode with $brief"
    return 0
  fi

  # ── 5. launch, bounded ────────────────────────────────────────────────────
  session_baton_write IN-PROGRESS <<EOF

# Baton — held by the unattended supervisor session started $(_sess_now)

mode: **$mode**$( [ "$mode" = "re-derive" ] && printf ' — the previous baton was dropped; re-derive everything' )
brief: \`$brief\`
tmux:  \`$tmux_sess\` on $(hostname -s 2>/dev/null)

If this line is still here and the heartbeat above is more than
${NWP_BATON_TIMEOUT_MIN} minutes old, this session is gone: treat as ABANDONED.
EOF

  local prompt="$brief_dir/prompt-$(date -u +%Y%m%dT%H%M%SZ).txt"
  {
    printf 'You are an unattended NWP session started by the supervisor on %s.\n\n' "$(hostname -s 2>/dev/null)"
    [ "$mode" = "re-derive" ] && printf 'MODE: RE-DERIVE. The previous session dropped its baton. Its handover prose is PARTIAL. Verify every claim against ground truth before acting on it.\n\n'
    printf 'Your brief is GENERATED state at %s. Read it first and prefer it over anything you remember.\n\n' "$brief"
    printf 'BOUNDS (enforced, not advisory):\n'
    printf '  * you may read anything, fix, push, and open MRs;\n'
    printf '  * you may NOT merge anything touching a sensitive path — run `pl session guard mr <iid>`; it will Draft the MR in the forge;\n'
    printf '  * you may NOT write to a live site outside the demo tier (%s) — `pl session guard live <site> live`;\n' "$NWP_SESSION_DEMO_SITES"
    printf '  * you may NOT write to prod at all. prod belongs to ver.\n\n'
    printf 'Heartbeat the baton at least every 30 minutes: `pl session heartbeat`.\n'
    printf 'When you finish, `pl session end` writes the handover and flips the baton.\n'
  } > "$prompt"

  tmux new-session -d -s "$tmux_sess" -c "$PROJECT_ROOT" \
    "${NWP_CLAUDE_CMD:-claude} -p --max-turns ${NWP_SESSION_MAX_TURNS} \"\$(cat '$prompt')\" ; '$PL' session end --status=READY" \
    || { session_failure_record "$sig" "tmux-launch-failed"
         session_notify "stuck" "supervisor could not start tmux session '$tmux_sess'" 7 || true
         return 1; }

  session_failure_clear "$sig"
  print_success "supervisor: launched '$tmux_sess' (mode=$mode)"
  session_notify "started" "unattended session '$tmux_sess' started on $(hostname -s), mode=$mode, brief=$brief" 4 || true
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    brief)      cmd_brief "$@" ;;
    baton)      cmd_baton "$@" ;;
    heartbeat)  session_baton_heartbeat ;;
    end)        cmd_end "$@" ;;
    guard)      cmd_guard "$@" ;;
    supervisor) cmd_supervisor "$@" ;;
    ""|-h|--help|help) show_help ;;
    *) print_error "pl session: unknown subcommand '$cmd'"; show_help; return 1 ;;
  esac
}

# Only run when executed, so bats can source this file and test its functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
