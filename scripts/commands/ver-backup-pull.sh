#!/bin/bash
set -euo pipefail
################################################################################
# ver backup pull — drain prod's restic snapshots into ver's durable repo (NWP-ADR-0025).
#
# `ver` is the offline, hardware-keyed custodian. During its scheduled online
# session it reaches a prod host over the dedicated WireGuard tunnel and PULLS new
# snapshots with `restic copy` into its OWN full-access repo, then applies long-term
# retention (`forget`/`prune`) and integrity verification (`check`). Prod never holds
# a credential that can delete this repo — only `ver` prunes.
#
# This is the durable, immutable, off-box tier of the DR backup (the raw data is
# acceptable here: `ver` is in the prod-trust tier). Keep ver's repo password sealed
# at rest (e.g. Solo 2 via age-plugin-fido2-hmac) and escrowed independently.
#
# Usage:
#   ver backup pull --from FROM_REPO --to TO_REPO [opts]
#
#   --from REPO            source repo (prod), e.g. sftp:prod-over-tunnel:/var/backups/nwp-server/<site>
#   --to REPO             ver's durable repo, e.g. /srv/ver-backups/<site>
#   --from-pass-file PATH  password file for the source repo, 0600
#   --to-pass-file PATH    password file for ver's repo, 0600
#   --restic BIN           restic binary (default: first `restic` in PATH)
#   --restic-pub PATH      minisign pubkey to verify the restic binary (fail-closed in --execute)
#   --keep-daily N         (default 7)
#   --keep-weekly N        (default 8)
#   --keep-monthly N       (default 12)
#   --keep-within DUR      erasure ceiling (e.g. 30d): keep every snapshot within
#                          DUR, remove ALL older ones (overrides daily/weekly/
#                          monthly). Use for user-data/PII repos to honour the
#                          30-day erasure promise (ops#127/#124). Default: unset.
#   --kind raw|sanitized   declare the source's data class. `raw` (unsanitised,
#                          PII, NWP-ADR-0025) REQUIRES an erasure ceiling: this
#                          command FAILS CLOSED unless --keep-within is also set,
#                          so a RAW source can never silently fall through to the
#                          tiered daily/weekly/monthly (~1yr) policy. `sanitized`
#                          has no PII and may use the tiered policy. Default: unset
#                          (legacy: honours --keep-within if given, else tiered).
#   --check-subset PCT     `restic check --read-data-subset` after drain (default 5%)
#   --skip-restic-verify   (debug) skip the minisign check on the restic binary
#   --dry-run (default) | --execute
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/minisign.sh" 2>/dev/null || true

FROM="" TO="" FROM_PASS="" TO_PASS=""
RESTIC="$(command -v restic || echo restic)" RESTIC_PUB=""
KEEP_DAILY=7 KEEP_WEEKLY=8 KEEP_MONTHLY=12 CHECK_SUBSET="5%"
# ops#127: erasure-window ceiling. When set (e.g. "30d"), forget uses
# `--keep-within <DUR>` — restic keeps every snapshot within the window and
# removes ALL older ones, so RAW (unsanitised, NWP-ADR-0025) user data cannot
# survive past the window. Required for user-data (PII) sites to honour the
# 30-day erasure promise (ops#124/#123). Empty = legacy daily/weekly/monthly.
KEEP_WITHIN=""
# ops#127 wiring: data class of this source. When "raw", an erasure ceiling
# (--keep-within) is MANDATORY — preflight fails closed without one.
KIND=""
SKIP_RESTIC_VERIFY=n EXECUTE=n

die(){ print_error "$*"; exit 1; }
show_help(){ sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; }

# tolerate an optional leading "pull" subcommand (so `ver backup pull …` works)
[ "${1:-}" = "pull" ] && shift

while [ $# -gt 0 ]; do
  case "$1" in
    --from=*) FROM="${1#*=}" ;;            --from) FROM="$2"; shift ;;
    --to=*)   TO="${1#*=}" ;;              --to)   TO="$2"; shift ;;
    --from-pass-file=*) FROM_PASS="${1#*=}" ;; --from-pass-file) FROM_PASS="$2"; shift ;;
    --to-pass-file=*)   TO_PASS="${1#*=}" ;;   --to-pass-file)   TO_PASS="$2"; shift ;;
    --restic=*) RESTIC="${1#*=}" ;;        --restic) RESTIC="$2"; shift ;;
    --restic-pub=*) RESTIC_PUB="${1#*=}" ;; --restic-pub) RESTIC_PUB="$2"; shift ;;
    --keep-daily=*) KEEP_DAILY="${1#*=}" ;; --keep-daily) KEEP_DAILY="$2"; shift ;;
    --keep-weekly=*) KEEP_WEEKLY="${1#*=}" ;; --keep-weekly) KEEP_WEEKLY="$2"; shift ;;
    --keep-monthly=*) KEEP_MONTHLY="${1#*=}" ;; --keep-monthly) KEEP_MONTHLY="$2"; shift ;;
    --keep-within=*) KEEP_WITHIN="${1#*=}" ;; --keep-within) KEEP_WITHIN="$2"; shift ;;
    --kind=*) KIND="${1#*=}" ;;             --kind) KIND="$2"; shift ;;
    --check-subset=*) CHECK_SUBSET="${1#*=}" ;; --check-subset) CHECK_SUBSET="$2"; shift ;;
    --skip-restic-verify) SKIP_RESTIC_VERIFY=y ;;
    --execute|-y) EXECUTE=y ;;             --dry-run) EXECUTE=n ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

run(){ if [ "$EXECUTE" = y ]; then "$@"; else printf '   [dry-run] %s\n' "$*"; fi; }

verify_restic(){
  if ! command -v "$RESTIC" >/dev/null 2>&1; then
    [ "$EXECUTE" = y ] && die "restic not found: $RESTIC"
    print_warning "[dry-run] restic not found ($RESTIC) — required for a live run"; return 0
  fi
  if [ "$SKIP_RESTIC_VERIFY" = y ]; then print_warning "skipping restic minisign verification"; return 0; fi
  if [ -z "$RESTIC_PUB" ]; then
    [ "$EXECUTE" = y ] && die "refusing to run an unverified restic — pass --restic-pub (or --skip-restic-verify)"
    print_warning "[dry-run] no --restic-pub; live run would require it"; return 0
  fi
  local bin; bin="$(command -v "$RESTIC")"
  if type minisign_verify >/dev/null 2>&1 && minisign_verify "$bin" "$RESTIC_PUB" >/dev/null 2>&1; then
    print_status "OK" "restic binary minisign-verified"
  else
    die "restic binary failed minisign verification against $RESTIC_PUB"
  fi
}

main(){
  [ -n "$FROM" ] || { show_help; die "--from <source-repo> is required"; }
  [ -n "$TO" ]   || die "--to <ver-repo> is required"

  print_header "ver backup pull"
  [ "$EXECUTE" = y ] || print_warning "DRY-RUN (default) — re-run with --execute to drain."

  # ── Preflight ──────────────────────────────────────────────────────────────
  print_header "Preflight"
  local label pf flag
  for label in FROM_PASS TO_PASS; do
    pf="${!label}"
    [ "$label" = FROM_PASS ] && flag="--from-pass-file" || flag="--to-pass-file"
    if [ -z "$pf" ]; then
      [ "$EXECUTE" = y ] && die "$flag is required for a live run"
      print_warning "[dry-run] $flag not set (required for live run)"
    elif [ ! -r "$pf" ]; then
      [ "$EXECUTE" = y ] && die "password file not readable: $pf"
      print_warning "[dry-run] password file $pf not present"
    fi
  done
  # ── Data-class / erasure-ceiling gate (ops#127, fail-closed) ────────────────
  # A RAW source carries unsanitised user data (PII). It MUST NOT fall through to
  # the tiered daily/weekly/monthly policy (~1yr retention) — that would defeat
  # the 2-tier split and outlive the 30-day erasure promise. Refuse, always
  # (dry-run included), unless a --keep-within ceiling is present.
  case "$KIND" in
    ''|raw|sanitized) : ;;
    *) die "--kind must be raw or sanitized (got: $KIND)" ;;
  esac
  if [ "$KIND" = raw ] && [ -z "$KEEP_WITHIN" ]; then
    die "refusing to drain a RAW (unsanitised/PII) source without an erasure ceiling — pass --keep-within DUR (e.g. 30d)"
  fi
  verify_restic
  print_info "from: $FROM"
  print_info "to:   $TO"
  print_info "kind: ${KIND:-unset}$([ -n "$KEEP_WITHIN" ] && echo " · ceiling: $KEEP_WITHIN")"

  # restic copy needs both passwords. The destination repo is the primary -r/--password-file;
  # the source is --from-repo/--from-password-file.
  local CP=("$RESTIC" -r "$TO" --password-file "${TO_PASS:-/dev/null}"
            --from-repo "$FROM" --from-password-file "${FROM_PASS:-/dev/null}")
  local TOREPO=("$RESTIC" -r "$TO" --password-file "${TO_PASS:-/dev/null}")

  # ── Ensure ver's repo exists ───────────────────────────────────────────────
  print_header "Step 1 · Ensure ver repo"
  if [ "$EXECUTE" = y ] && ! "${TOREPO[@]}" cat config >/dev/null 2>&1; then
    run "${TOREPO[@]}" init
  else
    print_info "$([ "$EXECUTE" = y ] && echo 'repo exists' || echo '[dry-run] would init ver repo if absent')"
  fi

  # ── Drain: copy new snapshots prod → ver ───────────────────────────────────
  print_header "Step 2 · Copy snapshots (prod → ver)"
  run "${CP[@]}" copy

  # ── Retention (ver is the ONLY pruner) ─────────────────────────────────────
  # ops#127: with --keep-within, enforce a hard erasure ceiling (nothing older
  # than the window survives) instead of the tiered daily/weekly/monthly policy.
  if [ -n "$KEEP_WITHIN" ]; then
    print_header "Step 3 · Retention (erasure ceiling: keep-within $KEEP_WITHIN)"
    run "${TOREPO[@]}" forget --keep-within "$KEEP_WITHIN" --prune
  else
    print_header "Step 3 · Retention (d:$KEEP_DAILY w:$KEEP_WEEKLY m:$KEEP_MONTHLY)"
    run "${TOREPO[@]}" forget --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune
  fi

  # ── Integrity verification (the "0" in 3-2-1-1-0) ──────────────────────────
  print_header "Step 4 · Verify (check --read-data-subset=$CHECK_SUBSET)"
  run "${TOREPO[@]}" check --read-data-subset="$CHECK_SUBSET"

  echo
  if [ "$EXECUTE" = y ]; then
    print_success "drain complete → $TO"
    print_hint "monthly: run a FULL restore drill into a sandbox to satisfy the 0 in 3-2-1-1-0"
  else
    print_success "dry-run complete — no changes made. Add --execute to drain."
  fi
}

main "$@"
