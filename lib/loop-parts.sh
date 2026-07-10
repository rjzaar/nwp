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
# GLOBAL KILL: `all=disabled` in the state file OR the legacy `.loop-paused`
# sentinel disables every part at once. `.rag-sync-paused` additionally disables
# just rag-sync. Both legacy sentinels stay honoured so existing runbooks and
# `touch ~/nwp/.loop-paused` muscle memory keep working.
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

loop_part_desc() {
  case "$1" in
    fix-loop)      echo "autonomous issue -> MR fix loop (agent-loop.sh poll)";;
    respawn-drain) echo "power-user instant re-spawn (agent-loop.sh marker drain)";;
    rag-sync)      echo "RAG state -> nwp/ops issues (rag-sync.sh, stage 1)";;
    webhook)       echo "GitLab webhook receiver (markers + loop kick)";;
    all)           echo "GLOBAL kill-switch (every part)";;
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

# True (0) if the whole loop is killed: state `all=disabled` OR `.loop-paused`.
loop_global_killed() {
  local root; root="$(_loop_nwp_root)"
  [ -f "$root/.loop-paused" ] && return 0
  [ "$(loop_part_raw all)" = "disabled" ] && return 0
  return 1
}

# THE authoritative check the wrappers call. Returns 0 (enabled/run it) or
# 1 (disabled/skip). Fail-safe precedence:
#   1. global kill      -> disabled
#   2. legacy per-part sentinel (.rag-sync-paused for rag-sync) -> disabled
#   3. explicit state value ("disabled"/"enabled")
#   4. documented default -> enabled
loop_part_enabled() {
  local part="$1" raw root
  root="$(_loop_nwp_root)"

  if loop_global_killed; then
    return 1
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
    for p in all "${LOOP_PARTS[@]}"; do
      cur="$(loop_part_raw "$p")"
      if [ "$p" = "$part" ]; then cur="$val"; seen_part=1; fi
      [ -n "$cur" ] && echo "${p}=${cur}"
    done
    [ "$seen_part" = "0" ] && echo "${part}=${val}"
  } > "$tmp"
  mv -f "$tmp" "$file"
}
