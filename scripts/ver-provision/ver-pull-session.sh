#!/bin/bash
set -euo pipefail
################################################################################
# ver-pull-session.sh — one supervised ONLINE SESSION on `ver`: bring up the 1:1
# tunnel, unseal the keystore (token touch), drain prod's restic snapshots via
# ver-backup-pull.sh, verify, then lock and go dark again (ADR-0025; ops#25).
#
# `ver` is offline by default. This script is the ONLY sanctioned way it goes
# online for backups, and it cleans up after itself fail-safe: the unsealed
# passwords are shredded and the tunnel torn down on ANY exit path (trap).
#
# Self-contained: runs on `ver` with no nwp checkout. Uses:
#   - ver-backup-pull.sh from the deployed nwp-server artifact
#     (NWP_SERVER_ROOT or --artifact; the artifact's scripts/commands/ dir)
#   - ver-seal-keystore.sh (installed alongside this script)
#
# Config: /etc/nwp-server/pull-sources.conf — one source per line:
#   name|from_repo|to_repo
#   e.g.  site1|sftp:backup@<prod-tunnel-ip>:/var/backups/nwp-server/site1|/srv/ver-backups/site1
# Keystore entries expected per source: `<name>.from` (prod staging repo password)
# and one shared `ver-repo` (ver's durable repo password).
#
# Usage:
#   ver-pull-session.sh [--source NAME]... [--wg IFACE] [--artifact DIR]
#                       [--dry-run (default) | --execute]
#
#   --wg IFACE      wg-quick config to bring up/down around the session
#                   (e.g. `verprod` for /etc/wireguard/verprod.conf); omit if
#                   the tunnel is managed manually
#   --source NAME   limit to one or more named sources (default: all)
#   --artifact DIR  nwp-server artifact root (default: $NWP_SERVER_ROOT, else
#                   /opt/nwp-server)
################################################################################

# NWP_VER_* overrides exist for sandboxed testing only — never set them on a real ver.
ETC="${NWP_VER_ETC:-/etc/nwp-server}"
CONF="$ETC/pull-sources.conf"
RUN="${NWP_VER_RUN:-/run/nwp-server}"
SELF_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SEAL="$SELF_DIR/ver-seal-keystore.sh"
ARTIFACT="${NWP_SERVER_ROOT:-/opt/nwp-server}"
WG_IFACE=""
EXECUTE=n
ONLY=()

c_ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
c_warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
c_err(){  printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
c_head(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die(){ c_err "$*"; exit 1; }
usage(){ sed -n '3,/^####*$/{/^####*$/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --wg=*) WG_IFACE="${1#*=}" ;;      --wg) WG_IFACE="$2"; shift ;;
    --source=*) ONLY+=("${1#*=}") ;;   --source) ONLY+=("$2"); shift ;;
    --artifact=*) ARTIFACT="${1#*=}" ;; --artifact) ARTIFACT="$2"; shift ;;
    --execute|-y) EXECUTE=y ;;         --dry-run) EXECUTE=n ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

PULL="$ARTIFACT/scripts/commands/ver-backup-pull.sh"
[ -x "$PULL" ] || die "ver-backup-pull.sh not found/executable at $PULL — deploy the nwp-server artifact or pass --artifact DIR"
[ -x "$SEAL" ] || die "ver-seal-keystore.sh not found alongside this script ($SEAL)"
[ -f "$CONF" ] || die "no pull-sources config: $CONF (see the header of this script for the format)"
RESTIC_PUB="$ETC/nwp-minisign.pub"
[ -f "$RESTIC_PUB" ] || die "pinned minisign pubkey missing: $RESTIC_PUB (run ver-provision.sh install)"

WG_UP=n
cleanup(){
  c_head "Session cleanup (always runs)"
  "$SEAL" lock || true
  if [ "$WG_UP" = y ]; then
    wg-quick down "$WG_IFACE" >/dev/null 2>&1 && c_ok "tunnel $WG_IFACE down" || c_warn "tunnel $WG_IFACE teardown reported an error — check manually"
  fi
}
trap cleanup EXIT

wants(){ # is this source selected?
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local s; for s in "${ONLY[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

c_head "ver pull session $([ "$EXECUTE" = y ] && echo '(EXECUTE)' || echo '(dry-run — add --execute)')"

if [ -n "$WG_IFACE" ]; then
  wg-quick up "$WG_IFACE" || die "could not bring up tunnel $WG_IFACE"
  WG_UP=y
  c_ok "tunnel $WG_IFACE up"
fi

# Unseal ver's own repo password once (one touch), per-source passwords as needed.
c_head "Unseal keystore"
"$SEAL" unseal ver-repo --out "$RUN/ver-repo"

FAILED=0 DONE=0
while IFS='|' read -r name from to; do
  case "$name" in ''|\#*) continue ;; esac
  wants "$name" || continue
  c_head "Source: $name"
  "$SEAL" unseal "$name.from" --out "$RUN/$name.from"
  if "$PULL" \
      --from "$from" --to "$to" \
      --from-pass-file "$RUN/$name.from" --to-pass-file "$RUN/ver-repo" \
      --restic-pub "$RESTIC_PUB" \
      $([ "$EXECUTE" = y ] && echo --execute); then
    DONE=$((DONE+1))
  else
    c_err "$name: pull FAILED"
    FAILED=$((FAILED+1))
  fi
  "$SEAL" lock "$name.from"
done < "$CONF"

echo
[ "$FAILED" = 0 ] || die "session finished with $FAILED failed source(s), $DONE ok"
c_ok "session complete: $DONE source(s) drained$([ "$EXECUTE" = y ] || echo ' (dry-run)')"
c_warn "monthly: run a FULL restore drill into a sandbox (the 0 in 3-2-1-1-0)"
