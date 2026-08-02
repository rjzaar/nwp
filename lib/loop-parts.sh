#!/usr/bin/env bash
# lib/loop-parts.sh — per-part enable/disable state for the self-healing loop.
#
# WHY (deep-audit finding C0): the loop was armed on more than one host with only
# a single `.loop-paused` sentinel as a brake. That sentinel is a *whole-loop*
# stop, and historically the only "pause" some parts honoured was a check the
# agent prompt was asked to respect — best-effort, not enforced. This library is
# the WRAPPER-ENFORCED replacement: the cron/entrypoint wrappers (agent-loop.sh,
# rag-sync.sh, gitlab-webhook-receiver.py) consult it BEFORE invoking any agent
# logic, so a disabled part is provably skipped by the wrapper, not merely asked
# not to run.
#
# STATE FILE (host-local, outside the repo):
#   ${NWP_LOOP_STATE:-$HOME/.config/nwp-loop/parts.state}
#   One `part=enabled|disabled` per line. `#` comments and blanks ignored.
# Host-local on purpose: each host has its own arming state (so "armed on two
# hosts" is now two independent, visible switches), and a branch switch in the
# shared ~/nwp worktree can never flip it.
#
# DEFAULT (documented, in-repo): every part defaults to ENABLED. An unknown or
# missing state value therefore leaves a part in its documented default rather
# than silently off — but a part is only ever *run* when a wrapper has
# affirmatively checked it, so "missing state" can never mean "ran something the
# operator disabled".
#
# TWO KILL SWITCHES, KEYED OFF A DECLARED CAPABILITY (ops#230)
# ------------------------------------------------------------
# There used to be ONE switch. `.loop-paused` / `all=disabled` meant "stop the
# loop", and every part honoured it — including `rag-sync`, which does not write
# anything to the estate: it reads fleet state and files nwp/ops issues. So the
# switch whose purpose is "don't let agents change things" also meant "stop
# looking at whether anything is wrong".
#
# That cost 8 nights in July 2026 (2026-07-18 → 07-25), was written up in this
# very file as a comment, was given an opt-in flag (NWP_LOOP_SPLIT_GATES=1)
# that defaulted to OFF — and then recurred and ran to 16 nights (ops#230). A
# comment is not an enforcement mechanism and an opt-in default-off flag is not
# a fix.
#
# So the distinction is now STRUCTURAL. Every part declares a CAPABILITY:
#
#   write    it can change the estate (open MRs, push, deploy, accept hooks)
#   observe  it only reads state and reports  (rag-sync)
#
# and there are two independent kills, which cannot be conflated because they
# are different names in different places:
#
#   WRITE kill      `.loop-paused`      /  parts.state `all=disabled`
#                   stops every `write` part. Does NOT stop `observe` parts.
#   OVERSIGHT kill  `.oversight-paused` /  parts.state `oversight=disabled`
#                   stops every `observe` part. Deliberately harder to reach:
#                   there is no legacy muscle-memory path to it.
#
# A part with an UNDECLARED capability is treated as `write` (fail-safe: the
# global kill still stops it), and tests/unit/test-oversight-freshness.bats
# fails if any part in LOOP_PARTS has no declared capability.
#
# Per-part switches are unchanged and still win: `pl loop disable rag-sync`
# (and the legacy `.rag-sync-paused` sentinel) stop rag-sync on its own.
#
# ESCAPE HATCH: NWP_LOOP_UNIFIED_GATES=1 restores the pre-ops#230 behaviour
# (one kill for everything). It exists so this change is revertible without a
# deploy; it logs loudly wherever it is honoured, and nothing in the tree sets
# it.
#
# This file is dependency-free (no common.sh / ui.sh) so the minimal cron
# wrappers can source it without side effects.

# The canonical, in-repo list of togglable parts and their one-line meaning.
# Order is the dashboard display order.
LOOP_PARTS=(
  "fix-loop"       # agent-loop.sh: autonomous poll of agent-eligible issues -> fix -> MR
  "respawn-drain"  # agent-loop.sh: power-user instant re-spawn (drains .agent-respawn markers)
  "rag-sync"       # rag-sync.sh: stage 1, turn live RAG state into nwp/ops issues
  "webhook"        # gitlab-webhook-receiver.py: accept hooks, write markers, fire the loop
)

# CAPABILITY DECLARATION — the load-bearing table. Adding a part without adding
# a row here makes it `write` (safe) and reddens the unit test (visible).
loop_part_capability() {
  case "$1" in
    fix-loop)      echo write ;;
    respawn-drain) echo write ;;
    webhook)       echo write ;;
    rag-sync)      echo observe ;;
    *)             echo write ;;   # fail-safe for an undeclared part
  esac
}

loop_part_desc() {
  case "$1" in
    fix-loop)      echo "autonomous issue -> MR fix loop (agent-loop.sh poll)";;
    respawn-drain) echo "power-user instant re-spawn (agent-loop.sh marker drain)";;
    rag-sync)      echo "RAG state -> nwp/ops issues (rag-sync.sh, stage 1)";;
    webhook)       echo "GitLab webhook receiver (markers + loop kick)";;
    all)           echo "WRITE kill-switch (every part that can change the estate)";;
    oversight)     echo "OVERSIGHT kill-switch (every read-only part; separate on purpose)";;
    *)             echo "unknown part";;
  esac
}

# Path to the host-local state file.
loop_parts_state_file() {
  echo "${NWP_LOOP_STATE:-$HOME/.config/nwp-loop/parts.state}"
}

# Root of the runtime tree (for the legacy sentinels).
_loop_nwp_root() {
  echo "${NWP_ROOT:-$HOME/nwp}"
}

# True (0) if PART is a known togglable part name.
loop_part_is_known() {
  local p want="$1"
  [ "$want" = "all" ] && return 0
  [ "$want" = "oversight" ] && return 0
  for p in "${LOOP_PARTS[@]}"; do
    [ "$p" = "$want" ] && return 0
  done
  return 1
}

# Print the raw stored value for a part ("enabled" / "disabled" / empty).
# Last matching line wins, so a set never has to rewrite in place.
loop_part_raw() {
  local part="$1" file val=""
  file="$(loop_parts_state_file)"
  [ -f "$file" ] || return 0
  # Read simple `part=value` lines; ignore comments/blanks.
  while IFS='=' read -r k v; do
    k="${k%%[[:space:]]*}"; k="${k#"${k%%[![:space:]]*}"}"
    [ -z "$k" ] && continue
    case "$k" in \#*) continue;; esac
    v="${v%%[[:space:]]*}"
    if [ "$k" = "$part" ]; then val="$v"; fi
  done < "$file"
  echo "$val"
}

# True (0) if the WRITE kill is set: `.loop-paused` OR state `all=disabled`.
# This is the switch operators reach for; it stops parts that change things.
loop_write_killed() {
  local root; root="$(_loop_nwp_root)"
  [ -f "$root/.loop-paused" ] && return 0
  [ "$(loop_part_raw all)" = "disabled" ] && return 0
  return 1
}

# Why the write kill is set, in words, or empty when it is not set.
loop_write_kill_reason() {
  local root; root="$(_loop_nwp_root)"
  [ -f "$root/.loop-paused" ] && { echo ".loop-paused"; return 0; }
  [ "$(loop_part_raw all)" = "disabled" ] && { echo "parts.state all=disabled"; return 0; }
  echo ""
}

# True (0) if the OVERSIGHT kill is set: `.oversight-paused` OR state
# `oversight=disabled`. Separate file, separate key, no legacy alias — you
# cannot arrive here by muscle memory, only by meaning it.
loop_oversight_killed() {
  local root; root="$(_loop_nwp_root)"
  [ -f "$root/.oversight-paused" ] && return 0
  [ "$(loop_part_raw oversight)" = "disabled" ] && return 0
  return 1
}

loop_oversight_kill_reason() {
  local root; root="$(_loop_nwp_root)"
  [ -f "$root/.oversight-paused" ] && { echo ".oversight-paused"; return 0; }
  [ "$(loop_part_raw oversight)" = "disabled" ] && { echo "parts.state oversight=disabled"; return 0; }
  echo ""
}

# BACK-COMPAT: loop_global_killed() is what several callers still ask. It keeps
# its old meaning — "the switch the operator flipped" — which is the WRITE kill.
# New code should say which kill it means.
loop_global_killed() { loop_write_killed; }

# True (0) if the legacy unified-gate escape hatch is armed.
loop_gates_unified() { [ "${NWP_LOOP_UNIFIED_GATES:-0}" = "1" ]; }

# THE authoritative check the wrappers call. Returns 0 (enabled/run it) or
# 1 (disabled/skip). Fail-safe precedence:
#   1. the kill that matches the part's CAPABILITY -> disabled
#        write   parts: the write kill (.loop-paused / all=disabled)
#        observe parts: the oversight kill (.oversight-paused / oversight=disabled)
#      (with NWP_LOOP_UNIFIED_GATES=1, either kill disables everything)
#   2. legacy per-part sentinel (.rag-sync-paused for rag-sync) -> disabled
#   3. explicit state value ("disabled"/"enabled")
#   4. documented default -> enabled
loop_part_enabled() {
  local part="$1" raw root cap
  root="$(_loop_nwp_root)"
  cap="$(loop_part_capability "$part")"

  if loop_gates_unified; then
    # Pre-ops#230 semantics, only when someone asks for them explicitly.
    if loop_write_killed || loop_oversight_killed; then return 1; fi
  elif [ "$cap" = "observe" ]; then
    loop_oversight_killed && return 1
  else
    loop_write_killed && return 1
  fi

  if [ "$part" = "rag-sync" ] && [ -f "$root/.rag-sync-paused" ]; then
    return 1
  fi

  raw="$(loop_part_raw "$part")"
  case "$raw" in
    disabled) return 1 ;;
    enabled)  return 0 ;;
    *)        return 0 ;;   # documented default: enabled
  esac
}

# Why a part is off, in words ("" when it is on). Used by the wrappers so a skip
# is never recorded without a reason — "switched off" and "broken" looked
# identical from outside for 16 nights.
loop_part_disabled_reason() {
  local part="$1" root cap
  root="$(_loop_nwp_root)"
  cap="$(loop_part_capability "$part")"
  loop_part_enabled "$part" && { echo ""; return 0; }

  if loop_gates_unified; then
    local w o
    w="$(loop_write_kill_reason)"; o="$(loop_oversight_kill_reason)"
    [ -n "$w" ] && { echo "NWP_LOOP_UNIFIED_GATES=1 + WRITE kill ($w)"; return 0; }
    [ -n "$o" ] && { echo "NWP_LOOP_UNIFIED_GATES=1 + OVERSIGHT kill ($o)"; return 0; }
  elif [ "$cap" = "observe" ]; then
    local o; o="$(loop_oversight_kill_reason)"
    [ -n "$o" ] && { echo "OVERSIGHT kill ($o)"; return 0; }
  else
    local w; w="$(loop_write_kill_reason)"
    [ -n "$w" ] && { echo "WRITE kill ($w)"; return 0; }
  fi

  [ "$part" = "rag-sync" ] && [ -f "$root/.rag-sync-paused" ] && { echo "own sentinel (.rag-sync-paused)"; return 0; }
  [ "$(loop_part_raw "$part")" = "disabled" ] && { echo "own switch (parts.state ${part}=disabled)"; return 0; }
  echo "unknown"
}

# Word form of a part's effective state, for dashboards/logs.
loop_part_state_word() {
  if loop_part_enabled "$1"; then echo "enabled"; else echo "disabled"; fi
}

# Persist a part's state. Usage: loop_part_set <part> <enabled|disabled>
# Writes atomically; creates the state dir on first use. Returns non-zero on a
# bad part/value so callers can surface a usage error.
loop_part_set() {
  local part="$1" val="$2" file dir tmp
  if ! loop_part_is_known "$part"; then
    echo "loop_part_set: unknown part '$part'" >&2
    return 2
  fi
  case "$val" in
    enabled|disabled) ;;
    *) echo "loop_part_set: value must be enabled|disabled (got '$val')" >&2; return 2 ;;
  esac
  file="$(loop_parts_state_file)"
  dir="$(dirname "$file")"
  mkdir -p "$dir" || { echo "loop_part_set: cannot create $dir" >&2; return 1; }

  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  {
    echo "# nwp-loop parts state — managed by \`pl loop enable|disable\`."
    echo "# Host-local; do not commit. See lib/loop-parts.sh."
    local p seen_part=0 cur
    # Preserve existing values, overwriting the target part.
    for p in all oversight "${LOOP_PARTS[@]}"; do
      cur="$(loop_part_raw "$p")"
      if [ "$p" = "$part" ]; then cur="$val"; seen_part=1; fi
      [ -n "$cur" ] && echo "${p}=${cur}"
    done
    [ "$seen_part" = "0" ] && echo "${part}=${val}"
  } > "$tmp"
  mv -f "$tmp" "$file"
}
