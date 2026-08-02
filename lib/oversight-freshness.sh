#!/usr/bin/env bash
# lib/oversight-freshness.sh — "has the oversight itself stopped?" (ops#230)
#
# THE FAILURE THIS EXISTS TO MAKE IMPOSSIBLE
# ------------------------------------------
# On 2026-08-02 it was discovered that `rag-sync` — the stage that turns the
# live fleet RAG grade into tracked nwp/ops issues — had produced nothing since
# 2026-07-17. Sixteen nights. Two independent causes, either of which alone was
# enough: a WRITE kill (`.loop-paused`) that also stopped the READ-ONLY half,
# and, later, an empty crontab.
#
# For all sixteen nights every component reported success. The cron wrapper
# exited 0 ("skipping" is a successful exit). `pl rag` printed a perfectly
# accurate table. `pl todo` said nothing. Two days into the blackout
# guzzlehttp/guzzle advisories landed, three sites flipped AMBER→RED, and not
# one of the five open `rag-auto` issues moved.
#
# An oversight system that has stopped must not look identical to an estate with
# nothing wrong. That is the whole of this file: one probe, one set of states,
# one grade — consumed by `pl todo` (check_rag_sync_freshness), `pl rag` (the
# self-liveness banner, which now makes a stale sync RED and exit 3) and
# `pl loop` (the dashboard). Before this, those three each had their OWN inline
# `grep 'rag-sync done'`, and check_rag_sync_freshness existed TWICE with two
# different bodies (ops#204) — four implementations of one question, none of
# which noticed the answer had been "no" since July.
#
# STATES (oversight_probe sets OVERSIGHT_STATE / OVERSIGHT_GRADE / …):
#
#   LIVE          a run completed inside the warn window.                GREEN
#   AGING         last completed run >= warn days ago.                   AMBER
#   STALE         last completed run >= alert days ago.                  RED
#   NEVER         a log exists but no run has ever completed.            RED
#   NOSCHEDULE    the part is enabled and nothing will ever wake it
#                 (no cron entry on the host that owns oversight).       RED
#   SILENCED      the read-only half is being stopped by the WRITE kill
#                 — the exact ops#230 shape. Only reachable now via
#                 NWP_LOOP_UNIFIED_GATES=1 or an old wrapper elsewhere.  RED
#   OFF           an operator deliberately disabled oversight (its own
#                 switch or the oversight kill). Switched off, not
#                 broken — but never silent.                             AMBER
#   DELEGATED     oversight is declared to live on another host; this
#                 host cannot vouch for it.                              AMBER
#   UNKNOWN       we could not tell (no log and no way to look).         AMBER
#
# Dependency-free on purpose (no ui.sh / common.sh): `pl todo` sources it
# inside a 45 s budget and the cron wrappers must be able to as well.

# Path helpers ---------------------------------------------------------------
_of_root() { echo "${NWP_ROOT:-$HOME/nwp}"; }

# Numeric setting with a default; callers may pre-set these from nwp.yml.
_of_int() {
  local v="$1" d="$2"
  case "$v" in ''|*[!0-9]*) echo "$d" ;; *) echo "$v" ;; esac
}

# Is a rag-sync cron entry installed on THIS machine?
#   0 = yes, 1 = no, 2 = cannot tell (no crontab binary)
# NWP_OVERSIGHT_CRON=present|absent|unknown overrides the probe. It exists so
# tests can state the schedule as a fixture instead of depending on whatever the
# machine running the suite happens to have in its crontab.
oversight_cron_present() {
  case "${NWP_OVERSIGHT_CRON:-}" in
    present) return 0 ;;
    absent)  return 1 ;;
    unknown) return 2 ;;
  esac
  command -v crontab >/dev/null 2>&1 || return 2
  crontab -l 2>/dev/null | grep -qE '^[[:space:]]*[0-9*].*rag-sync\.sh' && return 0
  return 1
}

# Which host is declared to own the oversight schedule ("" = this one).
# Set with settings.loop.oversight_host in nwp.yml, or NWP_OVERSIGHT_HOST.
oversight_declared_host() {
  if [ -n "${NWP_OVERSIGHT_HOST:-}" ]; then echo "$NWP_OVERSIGHT_HOST"; return 0; fi
  local cfg; cfg="$(_of_root)/nwp.yml"
  if [ -f "$cfg" ] && command -v yq >/dev/null 2>&1; then
    local v; v="$(yq e '.settings.loop.oversight_host // ""' "$cfg" 2>/dev/null)"
    [ "$v" = "null" ] && v=""
    echo "$v"; return 0
  fi
  echo ""
}

_of_this_host() { hostname -s 2>/dev/null || hostname 2>/dev/null || echo localhost; }

################################################################################
# oversight_probe [warn_days] [alert_days]
#
# Sets, in the caller's shell:
#   OVERSIGHT_STATE   one of the states above
#   OVERSIGHT_GRADE   RED | AMBER | GREEN
#   OVERSIGHT_AGE     age in whole days of the last COMPLETED run, or ""
#   OVERSIGHT_LAST    timestamp of the last completed run, or ""
#   OVERSIGHT_DETAIL  one sentence, safe to print anywhere
#   OVERSIGHT_ACTION  the pl verb that fixes it
# Always returns 0 — a probe that exits non-zero gets `|| true`d into silence,
# which is the bug class this file is about.
################################################################################
oversight_probe() {
  local root log warn alert
  root="$(_of_root)"
  log="$root/logs/rag-sync.log"
  warn="$(_of_int "${1:-${NWP_RAG_SYNC_WARN_DAYS:-2}}" 2)"
  alert="$(_of_int "${2:-${NWP_RAG_SYNC_ALERT_DAYS:-7}}" 7)"

  OVERSIGHT_STATE=UNKNOWN; OVERSIGHT_GRADE=AMBER
  OVERSIGHT_AGE=""; OVERSIGHT_LAST=""; OVERSIGHT_DETAIL=""; OVERSIGHT_ACTION="pl loop"

  # Capability/kill state, when the parts library is available.
  local enabled=yes reason="" cap=observe unified=no
  if declare -F loop_part_enabled >/dev/null 2>&1; then
    cap="$(loop_part_capability rag-sync)"
    loop_gates_unified && unified=yes
    if ! loop_part_enabled rag-sync; then
      enabled=no
      reason="$(loop_part_disabled_reason rag-sync)"
    fi
  fi

  # 1. SILENCED — the read half stopped by a WRITE kill. This is ops#230 itself.
  if [ "$enabled" = no ] && case "$reason" in *"WRITE kill"*) true ;; *) false ;; esac; then
    OVERSIGHT_STATE=SILENCED; OVERSIGHT_GRADE=RED
    OVERSIGHT_DETAIL="the read-only oversight half is being stopped by the WRITE kill ($reason). A kill switch for 'don't let agents write' must not also mean 'stop looking' — that is ops#230, which ran 16 nights."
    OVERSIGHT_ACTION="unset NWP_LOOP_UNIFIED_GATES (gates are split by capability since ops#230)"
    return 0
  fi

  # 2. OFF — deliberately disabled. Recorded, never silent.
  if [ "$enabled" = no ]; then
    OVERSIGHT_STATE=OFF; OVERSIGHT_GRADE=AMBER
    OVERSIGHT_DETAIL="rag-sync is switched off by $reason — switched off, not broken. While it holds, the fleet's RAG grade does not reach nwp/ops."
    OVERSIGHT_ACTION="pl loop enable rag-sync"
    return 0
  fi

  # 3. Whose job is it? A host that was never given the schedule is not at fault
  #    — but it must say it cannot vouch for the one that was.
  local owner me; owner="$(oversight_declared_host)"; me="$(_of_this_host)"
  local delegated=no
  if [ -n "$owner" ] && [ "$owner" != "$me" ] && [ "$owner" != "localhost" ]; then
    delegated=yes
  fi

  # 4. NOSCHEDULE — enabled, owned here, and nothing will ever wake it.
  local cronrc=0; oversight_cron_present || cronrc=$?
  if [ "$delegated" = no ] && [ "$cronrc" = "1" ]; then
    OVERSIGHT_STATE=NOSCHEDULE; OVERSIGHT_GRADE=RED
    OVERSIGHT_DETAIL="rag-sync is enabled on $me but has NO cron entry — nothing will ever wake it. Lifting a pause does not restart a schedule that no longer exists."
    OVERSIGHT_ACTION="pl loop schedule install --execute"
    return 0
  fi

  # 5. Age the last COMPLETED run. "skipping" lines are not evidence; they are
  #    the failure mode, and they keep the log file's mtime looking fresh.
  if [ ! -f "$log" ]; then
    if [ "$delegated" = yes ]; then
      OVERSIGHT_STATE=DELEGATED; OVERSIGHT_GRADE=AMBER
      OVERSIGHT_DETAIL="oversight is declared to run on '$owner', not on $me; this host holds no rag-sync log and cannot vouch for it."
      OVERSIGHT_ACTION="pl loop --host $owner"
    else
      OVERSIGHT_STATE=UNKNOWN; OVERSIGHT_GRADE=AMBER
      OVERSIGHT_DETAIL="no rag-sync log at $log — cannot tell whether the RAG→issues writer has ever run on $me. Absence of a log is not evidence of health."
      OVERSIGHT_ACTION="pl loop schedule status"
    fi
    return 0
  fi

  local last; last="$(grep -E 'rag-sync done' "$log" 2>/dev/null | tail -1 | awk '{print $1}')"
  if [ -z "$last" ]; then
    local skips; skips="$(grep -cE 'skipping' "$log" 2>/dev/null || echo 0)"
    OVERSIGHT_STATE=NEVER; OVERSIGHT_GRADE=RED
    OVERSIGHT_DETAIL="rag-sync has NEVER completed a run on $me (${skips} 'skipping' line(s) in $log). A skipped run exits 0, so cron looks healthy while nothing reaches the tracker."
    OVERSIGHT_ACTION="pl loop schedule status"
    return 0
  fi
  OVERSIGHT_LAST="$last"

  local e n; e="$(date -d "$last" +%s 2>/dev/null || echo 0)"
  if [ "$e" = "0" ]; then
    OVERSIGHT_STATE=UNKNOWN; OVERSIGHT_GRADE=AMBER
    OVERSIGHT_DETAIL="could not parse a timestamp from the last rag-sync 'done' line ('$last') — the age of the oversight signal is unmeasured."
    OVERSIGHT_ACTION="pl loop schedule status"
    return 0
  fi
  n="$(date +%s)"
  OVERSIGHT_AGE=$(( (n - e) / 86400 ))

  local where=""; [ "$delegated" = yes ] && where=" (schedule is declared to live on '$owner')"
  if [ "$OVERSIGHT_AGE" -ge "$alert" ]; then
    OVERSIGHT_STATE=STALE; OVERSIGHT_GRADE=RED
    OVERSIGHT_DETAIL="rag-sync last COMPLETED ${OVERSIGHT_AGE}d ago ($last), past the ${alert}d alert threshold${where}. The fleet's RAG grade is not reaching nwp/ops: red sites file no issues and open issues are not corrected."
    OVERSIGHT_ACTION="pl loop schedule status"
  elif [ "$OVERSIGHT_AGE" -ge "$warn" ]; then
    OVERSIGHT_STATE=AGING; OVERSIGHT_GRADE=AMBER
    OVERSIGHT_DETAIL="rag-sync last completed ${OVERSIGHT_AGE}d ago ($last), past the ${warn}d warn threshold${where}."
    OVERSIGHT_ACTION="pl loop schedule status"
  else
    OVERSIGHT_STATE=LIVE; OVERSIGHT_GRADE=GREEN
    OVERSIGHT_DETAIL="rag-sync last completed ${OVERSIGHT_AGE}d ago ($last)."
    OVERSIGHT_ACTION="pl loop"
  fi
  # A delegated host can never assert GREEN about a schedule it does not own.
  if [ "$delegated" = yes ] && [ "$OVERSIGHT_GRADE" = GREEN ]; then
    OVERSIGHT_STATE=DELEGATED; OVERSIGHT_GRADE=AMBER
    OVERSIGHT_DETAIL="$OVERSIGHT_DETAIL This host does not own the schedule ('$owner' does) — read it there before trusting this."
    OVERSIGHT_ACTION="pl loop --host $owner"
  fi
  return 0
}

# One-line summary for logs and banners.
oversight_line() {
  oversight_probe "$@"
  printf '%s (%s) %s\n' "$OVERSIGHT_STATE" "$OVERSIGHT_GRADE" "$OVERSIGHT_DETAIL"
}
