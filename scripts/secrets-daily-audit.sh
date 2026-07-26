#!/bin/bash
################################################################################
# secrets-daily-audit.sh — daily LIVE token audit + drift-sync + alert.
#
# The "checking daily for any token expiry / validity, integrated & managed"
# piece. Complements the pl-todo check_token_liveness (same engine, cached) with
# an explicit daily run that ALSO fixes recorded-expiry drift automatically.
#
# What it does:
#   1. pl secrets audit --sync  → live-probe every token; write live expiry back
#      into the registry (so `pl secrets status` never drifts from reality)
#   2. On any DEAD or soon-expiring token → alert (below) + exit non-zero
#   3. Host unreachable (audit exit 2) → no-op, no false alarm
#
# Install on the ci-host (met), alongside the existing daily audit:
#   crontab -e →  30 6 * * *  "$HOME"/nwp/scripts/secrets-daily-audit.sh >> "$HOME"/nwp-secrets-audit.log 2>&1
#
# Alert channels are all best-effort / fail-soft; the exit code + log line are
# the guaranteed signal (cron mails non-zero exits; pl todo also surfaces it).
################################################################################
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEC="$ROOT/scripts/commands/secrets.sh"
WARN="${SECRETS_WARN_DAYS:-21}"
STAMP="$(date -Is 2>/dev/null || date)"
ALERT_FILE="$ROOT/private/.token-audit-alert"

[ -f "$SEC" ] || { echo "$STAMP token-audit: $SEC not found"; exit 3; }

out=$(bash "$SEC" audit --sync --quiet --days "$WARN" 2>/dev/null); rc=$?

BLIND_FILE="$ROOT/private/.token-audit-blind"
BLIND_MAX="${SECRETS_BLIND_MAX_DAYS:-3}"

if [ "$rc" = "2" ]; then
  # BLINDNESS IS A STATE, NOT A PASS. "skipped (no alarm)" + exit 0 is the exact
  # shape of the sweeps that ran dead for weeks while their logs said OK: the one
  # condition under which the check cannot work is the one condition it reports
  # as fine. Count consecutive blind days and escalate — a fleet nobody has been
  # able to audit for BLIND_MAX days is a finding, not a quiet skip.
  blind=$(( $( [ -f "$BLIND_FILE" ] && head -1 "$BLIND_FILE" 2>/dev/null | tr -dc '0-9' || echo 0 ) + 0 ))
  blind=$(( blind + 1 ))
  printf '%s\n%s\n' "$blind" "$STAMP" > "$BLIND_FILE"
  if [ "$blind" -ge "$BLIND_MAX" ]; then
    echo "$STAMP token-audit: AUDIT-BLIND for $blind consecutive run(s) — the fleet has NOT been audited"
    exit 4
  fi
  echo "$STAMP token-audit: AUDIT-BLIND (run $blind of $BLIND_MAX before escalation) — provider unreachable"
  exit 0
fi
rm -f "$BLIND_FILE" 2>/dev/null || true

if [ -n "$out" ]; then
  {
    echo "NWP token audit — action needed ($STAMP):"
    echo "$out" | while IFS=$'\t' read -r id live exp note; do
      [ -n "$id" ] && printf '  %-26s %-6s %-12s %s\n' "$id" "$live" "$exp" "$note"
    done
    echo "Reissue any of them with:  pl secrets steps <id>  →  create it  →  pl secrets rotate <id>"
  } | tee "$ALERT_FILE"

  # --- push notification, through the ONE notification path -------------------
  #
  # This used to be an inline curl that put the token in the URL (and therefore
  # in /proc/<pid>/cmdline) and ended in `|| true`, so a failed alert about dead
  # credentials was itself silent. `pl notify` fails loudly and keeps the token
  # off argv; we still do not abort the audit on a delivery failure, but we DO
  # say so on stderr so the cron mail / log carries it.
  if [ -x "$ROOT/scripts/commands/notify.sh" ]; then
    if ! "$ROOT/scripts/commands/notify.sh" send secrets \
           "$(printf '%s' "$out" | head -8)" \
           --priority 7 --title "NWP token audit" >/dev/null; then
      echo "$STAMP token-audit: WARNING — could not deliver the alert notification (run: pl notify health)" >&2
    fi
  else
    echo "$STAMP token-audit: WARNING — pl notify is unavailable; alert not pushed" >&2
  fi
  exit 1
fi

rm -f "$ALERT_FILE" 2>/dev/null || true
echo "$STAMP token-audit: all live tokens valid, no drift, none expiring within ${WARN}d"
exit 0
