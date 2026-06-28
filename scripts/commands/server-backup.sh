#!/bin/bash
set -euo pipefail
################################################################################
# nwp-server backup — disaster-recovery backup of a prod site (ADR-0025).
#
# Produces a RAW (unsanitized) restic snapshot of the site DB + files into a repo
# LOCAL to this prod host. The offline custodian `ver` later PULLS these snapshots
# into its own durable, immutable repo (see ver-backup-pull.sh). This host holds NO
# credential that can delete `ver`'s copy — the "pull + immutable" anti-ransomware
# pattern. The local repo is short-window staging only.
#
# Threat model (ADR-0025): this is the DR flow — raw data, restic-encrypted, bound
# for `ver` ONLY (the prod-trust, offline, hardware-keyed custodian). It is NOT the
# sanitized-publish flow (ADR-0024); raw data never reaches the dev/AI tier.
#
# Usage:
#   nwp-server backup --site-dir DIR [opts]
#
#   --repo PATH         local restic repo (default: /var/backups/nwp-server/<site>)
#   --pass-file PATH    file holding the restic repo password, 0600
#                       (default: /etc/nwp-server/restic.pass)
#   --restic BIN        restic binary (default: first `restic` in PATH)
#   --restic-pub PATH   minisign public key to verify the restic binary before use
#                       (fail-closed in --execute unless --skip-restic-verify)
#   --drush PATH        drush (default: <site-dir>/vendor/bin/drush)
#   --files SUBPATH     files dir relative to site-dir (default web/sites/default/files)
#   --keep-last N       local staging retention (default 3)
#   --tag TAG           restic tag (default: <host>/<site>)
#   --db-only | --files-only
#   --skip-restic-verify   (debug) skip the minisign check on the restic binary
#   --dry-run (default) | --execute
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/minisign.sh" 2>/dev/null || true

SITE_DIR="" REPO="" PASS_FILE="/etc/nwp-server/restic.pass"
RESTIC="$(command -v restic || echo restic)" RESTIC_PUB=""
DRUSH="" FILES_SUB="web/sites/default/files" KEEP_LAST=3 TAG=""
DB_ONLY=n FILES_ONLY=n SKIP_RESTIC_VERIFY=n EXECUTE=n

die(){ print_error "$*"; exit 1; }
show_help(){ sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --site-dir=*) SITE_DIR="${1#*=}" ;;
    --site-dir)   SITE_DIR="$2"; shift ;;
    --repo=*)     REPO="${1#*=}" ;;
    --repo)       REPO="$2"; shift ;;
    --pass-file=*) PASS_FILE="${1#*=}" ;;
    --pass-file)  PASS_FILE="$2"; shift ;;
    --restic=*)   RESTIC="${1#*=}" ;;
    --restic)     RESTIC="$2"; shift ;;
    --restic-pub=*) RESTIC_PUB="${1#*=}" ;;
    --restic-pub) RESTIC_PUB="$2"; shift ;;
    --drush=*)    DRUSH="${1#*=}" ;;
    --drush)      DRUSH="$2"; shift ;;
    --files=*)    FILES_SUB="${1#*=}" ;;
    --files)      FILES_SUB="$2"; shift ;;
    --keep-last=*) KEEP_LAST="${1#*=}" ;;
    --keep-last)  KEEP_LAST="$2"; shift ;;
    --tag=*)      TAG="${1#*=}" ;;
    --tag)        TAG="$2"; shift ;;
    --db-only)    DB_ONLY=y ;;
    --files-only) FILES_ONLY=y ;;
    --skip-restic-verify) SKIP_RESTIC_VERIFY=y ;;
    --execute|-y) EXECUTE=y ;;
    --dry-run)    EXECUTE=n ;;
    -h|--help)    show_help; exit 0 ;;
    *)            die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

run(){ # echo + run, or just echo in dry-run
  if [ "$EXECUTE" = y ]; then "$@"; else printf '   [dry-run] %s\n' "$*"; fi
}

# Verify the restic binary against our pinned minisign key (supply chain), fail-closed.
verify_restic(){
  if ! command -v "$RESTIC" >/dev/null 2>&1; then
    [ "$EXECUTE" = y ] && die "restic not found: $RESTIC"
    print_warning "[dry-run] restic not found ($RESTIC) — required for a live run"; return 0
  fi
  if [ "$SKIP_RESTIC_VERIFY" = y ]; then
    print_warning "skipping restic minisign verification (--skip-restic-verify)"
    return 0
  fi
  if [ -z "$RESTIC_PUB" ]; then
    [ "$EXECUTE" = y ] && die "refusing to run an unverified restic binary — pass --restic-pub PATH (or --skip-restic-verify to override)"
    print_warning "[dry-run] no --restic-pub given; live run would require it"
    return 0
  fi
  local bin; bin="$(command -v "$RESTIC")"
  if type minisign_verify >/dev/null 2>&1 && minisign_verify "$bin" "$RESTIC_PUB" >/dev/null 2>&1; then
    print_status "OK" "restic binary minisign-verified"
  else
    die "restic binary failed minisign verification against $RESTIC_PUB (expected ${bin}.minisig)"
  fi
}

main(){
  [ -n "$SITE_DIR" ] || { show_help; die "--site-dir is required"; }
  local site; site="$(basename "$SITE_DIR")"
  [ -n "$REPO" ]  || REPO="/var/backups/nwp-server/$site"
  [ -n "$DRUSH" ] || DRUSH="$SITE_DIR/vendor/bin/drush"
  [ -n "$TAG" ]   || TAG="$(hostname -s 2>/dev/null || echo host)/$site"
  local files_path="$SITE_DIR/$FILES_SUB"

  print_header "nwp-server backup · $site"
  [ "$EXECUTE" = y ] || print_warning "DRY-RUN (default) — re-run with --execute to perform the backup."

  # ── Preflight ──────────────────────────────────────────────────────────────
  print_header "Preflight"
  [ -d "$SITE_DIR" ] || die "site dir not found: $SITE_DIR"
  [ "$FILES_ONLY" = y ] || [ -x "$DRUSH" ] || die "drush not found/executable: $DRUSH"
  if [ ! -r "$PASS_FILE" ]; then
    [ "$EXECUTE" = y ] && die "restic password file not readable: $PASS_FILE"
    print_warning "[dry-run] restic password file $PASS_FILE not present (required for live run)"
  else
    local perm; perm="$(stat -c '%a' "$PASS_FILE" 2>/dev/null || echo '?')"
    [ "$perm" = 600 ] || print_warning "restic password file $PASS_FILE is $perm; expected 600"
  fi
  verify_restic
  local RC=("$RESTIC" -r "$REPO" --password-file "$PASS_FILE")
  print_info "repo:    $REPO"
  print_info "tag:     $TAG"
  print_info "db:      $([ "$FILES_ONLY" = y ] && echo skip || echo "$DRUSH sql-dump (raw)")"
  print_info "files:   $([ "$DB_ONLY" = y ] && echo skip || echo "$files_path")"

  # ── Ensure repo exists (init once) ─────────────────────────────────────────
  print_header "Step 1 · Ensure restic repo"
  if [ "$EXECUTE" = y ] && ! "${RC[@]}" cat config >/dev/null 2>&1; then
    run "${RC[@]}" init
  else
    print_info "$([ "$EXECUTE" = y ] && echo 'repo exists' || echo '[dry-run] would init repo if absent')"
  fi

  # ── DB dump (raw) → restic ─────────────────────────────────────────────────
  local tmp_db=""
  if [ "$FILES_ONLY" != y ]; then
    print_header "Step 2 · Snapshot database (raw)"
    tmp_db="$(mktemp -d)/db.sql.gz"
    if [ "$EXECUTE" = y ]; then
      ( cd "$SITE_DIR" && "$DRUSH" sql-dump --gzip --result-file="${tmp_db%.gz}" ) || die "drush sql-dump failed"
    else
      print_info "[dry-run] would: cd $SITE_DIR && $DRUSH sql-dump --gzip --result-file=${tmp_db%.gz}"
    fi
    run "${RC[@]}" backup --tag "$TAG" --tag db "$tmp_db"
  fi

  # ── Files → restic (dedup) ─────────────────────────────────────────────────
  if [ "$DB_ONLY" != y ]; then
    print_header "Step 3 · Snapshot files (dedup)"
    [ -d "$files_path" ] || { [ "$EXECUTE" = y ] && die "files dir not found: $files_path"; }
    run "${RC[@]}" backup --tag "$TAG" --tag files "$files_path"
  fi

  # ── Local staging retention (prod prunes its OWN local repo only) ──────────
  print_header "Step 4 · Local staging retention (keep-last $KEEP_LAST)"
  run "${RC[@]}" forget --tag "$TAG" --keep-last "$KEEP_LAST" --prune

  # ── Shred the temp raw dump ────────────────────────────────────────────────
  if [ -n "$tmp_db" ] && [ "$EXECUTE" = y ]; then
    shred -u "$tmp_db" 2>/dev/null || rm -f "$tmp_db"
    rmdir "$(dirname "$tmp_db")" 2>/dev/null || true
  fi

  echo
  if [ "$EXECUTE" = y ]; then
    print_success "backup complete → $REPO"
    print_hint "pull from ver:  ver backup pull --from sftp:<this-host-over-tunnel>:$REPO --to <ver-repo>"
  else
    print_success "dry-run complete — no changes made. Add --execute to run."
  fi
}

main "$@"
