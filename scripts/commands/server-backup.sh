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
# sanitized-publish flow (ADR-0026); raw data never reaches the dev/AI tier.
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
#   --drush PATH        drush (default: <site-dir>/vendor/bin/drush) — Drupal only
#   --files SUBPATH     Drupal PUBLIC files dir relative to site-dir
#                       (default web/sites/default/files). Drupal private files are
#                       auto-detected. IGNORED for Moodle (which backs up moodledata).
#
# Stack-aware (ADR-0032 Flow B): a Moodle site (version.php) is backed up as
# moodledata + a mysqldump-via-config.php DB dump; a Drupal site as public+private
# files + a drush sql-dump. Raw data → ver only (ADR-0025); never the dev/AI tier.
#   --keep-last N       local staging retention (default 3)
#   --tag TAG           restic tag (default: <host>/<site>)
#   --db-only | --files-only
#   --sanitize          ops#127: produce a SANITISED long-term DR snapshot instead
#                       of a raw one — runs the site sanitiser (--preserve-admin:
#                       keep the real admin, scrub all other users) + the external
#                       PII gate (fail-closed), into a DISTINCT `<site>-sanitized`
#                       repo. Implies --db-only (sanitised files = ops#84).
#   --sanitizer PATH    sanitiser to use (default: lib/sanitizers/<site>.sh)
#   --skip-restic-verify   (debug) skip the minisign check on the restic binary
#   --dry-run (default) | --execute
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/minisign.sh" 2>/dev/null || true
source "$PROJECT_ROOT/lib/server-backup-resolve.sh"
source "$PROJECT_ROOT/lib/pii-gate.sh" 2>/dev/null || true  # ops#127: --sanitize gate
# files_secrets_verify — pre-snapshot fail-LOUD leftover-secret warning (never an
# abort; DR must not be blocked by a leftover credential). lib/sanitizers/ ships
# in the nwp-server artifact (build/nwp-server.include), so this is present on
# the prod host; guarded anyway so a partial install degrades to no-check.
source "$PROJECT_ROOT/lib/sanitizers/files-secrets.sh" 2>/dev/null || true

SITE_DIR="" REPO="" PASS_FILE="/etc/nwp-server/restic.pass"
RESTIC="$(command -v restic || echo restic)" RESTIC_PUB=""
DRUSH="" FILES_SUB="web/sites/default/files" KEEP_LAST=3 TAG=""
DB_ONLY=n FILES_ONLY=n SKIP_RESTIC_VERIFY=n EXECUTE=n
# ops#127: sanitised long-term DR tier. --sanitize runs the site sanitiser
# (--preserve-admin: keep the real admin, scrub every other user) → external
# lib/pii-gate.sh (fail-closed) → snapshots the SANITISED DB to a DISTINCT
# `<site>-sanitized` repo. It carries no member PII, so ver keeps it long-term
# (tiered), while the RAW repo is capped at 30d (--keep-within). DB-only for now:
# sanitised FILES (moodledata/uploads) are ops#84 — never mix raw files in here.
SANITIZE=n SANITIZER=""

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
    --sanitize)   SANITIZE=y ;;
    --sanitizer=*) SANITIZER="${1#*=}" ;;
    --sanitizer)  SANITIZER="$2"; shift ;;
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
  local repo_site="$site"
  # ops#127: sanitised tier resolution — distinct repo, DB-only, fail-closed on a
  # missing sanitiser (never emit an unsanitised long-term archive).
  if [ "$SANITIZE" = y ]; then
    repo_site="${site}-sanitized"
    DB_ONLY=y
    [ -n "$SANITIZER" ] || SANITIZER="${PROJECT_ROOT:-.}/lib/sanitizers/${site}.sh"
    [ -f "$SANITIZER" ] || die "--sanitize: no sanitiser at '$SANITIZER' — pass --sanitizer PATH. Refusing to write an unsanitised long-term archive (fail-closed)."
  fi
  [ -n "$REPO" ]  || REPO="/var/backups/nwp-server/$repo_site"
  [ -n "$DRUSH" ] || DRUSH="$SITE_DIR/vendor/bin/drush"
  [ -n "$TAG" ]   || TAG="$(hostname -s 2>/dev/null || echo host)/$repo_site"

  # Stack-aware (ADR-0032 Flow B): Moodle backs up moodledata + mysqldump-via-
  # config.php; Drupal backs up public+private files + drush. --files overrides
  # the Drupal PUBLIC subpath and is ignored for Moodle (which uses moodledata).
  local stack; stack="$(sb_detect_stack "$SITE_DIR")"
  local -a files_paths=()
  while IFS= read -r _p; do [ -n "$_p" ] && files_paths+=("$_p"); done \
    < <(sb_backup_files_paths "$SITE_DIR" "$FILES_SUB")
  # Visibility guard: if a Drupal site's public files aren't at the default path
  # (e.g. an `html` docroot), don't silently omit them — tell the operator.
  if [ "$stack" = drupal ] && [ "$DB_ONLY" != y ] && [ ! -d "$SITE_DIR/$FILES_SUB" ]; then
    print_warning "Drupal public files not found at '$FILES_SUB' — pass --files <docroot>/sites/default/files (backing up only what was resolved)"
  fi

  print_header "nwp-server backup · $site"
  [ "$EXECUTE" = y ] || print_warning "DRY-RUN (default) — re-run with --execute to perform the backup."

  # ── Preflight ──────────────────────────────────────────────────────────────
  print_header "Preflight"
  [ -d "$SITE_DIR" ] || die "site dir not found: $SITE_DIR"
  if [ "$FILES_ONLY" != y ]; then
    if [ "$stack" = drupal ]; then
      [ -x "$DRUSH" ] || die "drush not found/executable: $DRUSH"
    else
      # Moodle DB dump needs php + mysqldump (no drush). Warn in dry-run; the
      # dump helper is fail-closed on a live run if either is missing.
      { command -v php >/dev/null 2>&1 && command -v mysqldump >/dev/null 2>&1; } \
        || { [ "$EXECUTE" = y ] && die "moodle DB backup needs php + mysqldump"; \
             print_warning "[dry-run] moodle DB backup needs php + mysqldump (missing here)"; }
    fi
  fi
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
  print_info "stack:   $stack"
  if [ "$FILES_ONLY" = y ]; then
    print_info "db:      skip"
  elif [ "$stack" = moodle ]; then
    print_info "db:      mysqldump via config.php (raw)"
  else
    print_info "db:      $DRUSH sql-dump (raw)"
  fi
  print_info "files:   $([ "$DB_ONLY" = y ] && echo skip || printf '%s ' "${files_paths[@]:-<none found>}")"

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
    print_header "Step 2 · Snapshot database ($([ "$SANITIZE" = y ] && echo 'SANITISED, preserve-admin' || echo raw))"
    tmp_db="$(mktemp -d)/db.sql.gz"
    if [ "$EXECUTE" = y ]; then
      if [ "$SANITIZE" = y ]; then
        # Reviewed site sanitiser (scratch-DB; raw data stays on this host) with
        # the real admin preserved, THEN the independent external PII gate. Both
        # fail-closed — an unsanitised or unverifiable dump is never snapshotted.
        local _san_args=(--site-dir "$SITE_DIR" --output "$tmp_db" --preserve-admin)
        [ "$stack" != moodle ] && _san_args+=(--drush "$DRUSH")
        "$SANITIZER" "${_san_args[@]}" || die "sanitiser failed — refusing to snapshot (fail-closed)"
        [ -s "$tmp_db" ] || die "sanitiser produced no dump — refusing (fail-closed)"
        type pii_gate_scan >/dev/null 2>&1 || die "lib/pii-gate.sh not loaded — cannot run the independent PII gate (fail-closed)"
        pii_gate_scan "$tmp_db" "${tmp_db}.admin-allow" \
          || die "external PII gate FAILED on the sanitised dump — refusing to snapshot (fail-closed)"
        print_status "OK" "sanitised + PII-gate clean (admin preserved, all other users scrubbed)"
      elif [ "$stack" = moodle ]; then
        sb_moodle_db_dump "$SITE_DIR" "$tmp_db" || die "moodle DB dump failed (mysqldump via config.php)"
      else
        ( cd "$SITE_DIR" && "$DRUSH" sql-dump --gzip --result-file="${tmp_db%.gz}" ) || die "drush sql-dump failed"
      fi
    elif [ "$SANITIZE" = y ]; then
      print_info "[dry-run] would: $SANITIZER --site-dir $SITE_DIR --output <tmp> --preserve-admin → pii_gate_scan → restic (repo: $REPO)"
    elif [ "$stack" = moodle ]; then
      print_info "[dry-run] would: sb_moodle_db_dump $SITE_DIR $tmp_db (mysqldump via config.php)"
    else
      print_info "[dry-run] would: cd $SITE_DIR && $DRUSH sql-dump --gzip --result-file=${tmp_db%.gz}"
    fi
    local _dbtags=(--tag "$TAG" --tag db)
    [ "$SANITIZE" = y ] && _dbtags+=(--tag sanitized)
    run "${RC[@]}" backup "${_dbtags[@]}" "$tmp_db"
  fi

  # ── Files → restic (dedup) ─────────────────────────────────────────────────
  if [ "$DB_ONLY" != y ]; then
    print_header "Step 3 · Snapshot files (dedup)"
    # Secret-exclude (defence in depth): a Drupal config-sync export written under
    # a site's PUBLIC files (…/files/sync/*.yml) — plus any auth.json / .env that
    # lands in the files tree — can carry LIVE credentials (a real incident: a
    # config-sync file held a glpat token + webhook_secret). Those creds are
    # recoverable from git/config, not user data, so the RAW DR snapshot bound for
    # `ver` must NOT carry them. Restic --exclude drops only the secret-bearing
    # files; user uploads are still backed up. Kept in step with the artifact-level
    # redactor lib/sanitizers/files-secrets.sh (same target-file vocabulary).
    #
    # KNOWN OVER-EXCLUSION (accepted trade-off): restic patterns here match by
    # BASENAME anywhere under the files tree, so a legitimate USER UPLOAD that
    # happens to be named `auth.json` or `.env` (or live under a `sync/`
    # directory as *.yml) is dropped from the DR snapshot too. We bias toward
    # never snapshotting a credential over perfectly-faithful uploads; the
    # fail-LOUD verify below surfaces the affected paths so an operator can see
    # what was skipped and rescue a false positive by renaming it.
    local -a secret_excludes=(
      --exclude 'sync/*.yml'  --exclude 'sync/*.yaml'
      --exclude 'auth.json'   --exclude '.env'  --exclude '.env.*'
    )
    print_info "files secret-exclude: sync/*.yml sync/*.yaml auth.json .env .env.*"
    if [ "${#files_paths[@]}" -gt 0 ]; then
      local fp fs_out
      for fp in "${files_paths[@]}"; do
        [ -d "$fp" ] || { [ "$EXECUTE" = y ] && die "files dir not found: $fp"; }
        # Pre-snapshot fail-LOUD warning (NOT an abort — DR must never be
        # blocked by a leftover secret; the excludes above already keep these
        # files OUT of the snapshot). The point is to get the live credential
        # rotated/removed at source, not to fail the backup.
        if [ -d "$fp" ] && type files_secrets_verify >/dev/null 2>&1; then
          if ! fs_out="$(files_secrets_verify "$fp" 2>&1)"; then
            print_warning "leftover live-secret(s) detected under $fp — NOT snapshotted (excluded above); rotate/remove at source:"
            [ -n "$fs_out" ] && printf '%s\n' "$fs_out" | sed 's/^/     /'
          fi
        fi
        run "${RC[@]}" backup --tag "$TAG" --tag files "${secret_excludes[@]}" "$fp"
      done
    else
      [ "$EXECUTE" = y ] && die "no files paths found to back up for $stack site: $SITE_DIR"
      print_warning "[dry-run] no files paths resolved (a live run would fail here)"
    fi
  fi

  # ── Local staging retention (prod prunes its OWN local repo only) ──────────
  print_header "Step 4 · Local staging retention (keep-last $KEEP_LAST)"
  run "${RC[@]}" forget --tag "$TAG" --keep-last "$KEEP_LAST" --prune

  # ── Shred the temp raw dump ────────────────────────────────────────────────
  if [ -n "$tmp_db" ] && [ "$EXECUTE" = y ]; then
    shred -u "$tmp_db" 2>/dev/null || rm -f "$tmp_db"
    [ -f "${tmp_db}.admin-allow" ] && { shred -u "${tmp_db}.admin-allow" 2>/dev/null || rm -f "${tmp_db}.admin-allow"; }
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
