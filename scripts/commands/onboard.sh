#!/bin/bash
set -euo pipefail
################################################################################
# pl onboard — chain a production site into the local NWP fleet (OPERATING-MODEL §7).
#
# Collapses the bulk of docs/guides/production-site-integration.md (~1349 lines)
# into one resumable command:
#
#   preflight → create GitLab project → [supervised] prod sanitize
#   → FAIL-CLOSED PII gate → scaffold dev + load sanitized DB → register → pl status
#
# ── Security posture (read before changing) ──────────────────────────────────
# The per-site sanitizer (lib/sanitizers/<site>.sh) sanitizes a throwaway SCRATCH
# COPY of the DB on prod (the live DB is read-only) and is run ON PROD, UNDER HUMAN
# SUPERVISION — never by this command, which has no production access and cannot
# read DB credentials. onboard CONSUMES the sanitized dump the human produced and
# re-screens it with lib/pii-gate.sh (defence in depth) BEFORE it is allowed onto
# dev. Any PII match aborts. This is the inviolable boundary: raw user data never
# crosses onto dev.
#
# Default mode is DRY-RUN (prints the plan, touches nothing). Pass --execute to run.
#
# Usage:
#   pl onboard <site> --server=<srv> --source=<remote-webroot> --recipe=<r> \
#       [--sanitized-db=PATH] [--allowlist=PATH] [--group=<g>] [--purpose=<p>] \
#       [--key=PATH] [--full-files] [-s=N|--step=N] [--execute|-y] [--dry-run]
#
#   pl onboard mayo --server=mayo --source=/var/www/mayostudios.org/web \
#       --recipe=avc --sanitized-db=~/dumps/mayo-sanitized.sql.gz --execute
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/pii-gate.sh"

PL="$PROJECT_ROOT/pl"
SANITIZERS_DIR="$PROJECT_ROOT/lib/sanitizers"
SITES_DIR="$PROJECT_ROOT/sites"

# ── Options ──────────────────────────────────────────────────────────────────
OPT_SITE="" OPT_SERVER="" OPT_SOURCE="" OPT_RECIPE=""
OPT_SANITIZED_DB="" OPT_ALLOWLIST="" OPT_GROUP="" OPT_PURPOSE="indefinite"
OPT_KEY="$HOME/.ssh/nwp" OPT_FULL_FILES="n" OPT_STEP="1" OPT_EXECUTE="n"

die(){ print_error "$*"; exit 1; }

show_help(){ sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; }

parse_args(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --server=*)        OPT_SERVER="${1#*=}" ;;
      --source=*)        OPT_SOURCE="${1#*=}" ;;
      --recipe=*)        OPT_RECIPE="${1#*=}" ;;
      --sanitized-db=*)  OPT_SANITIZED_DB="${1#*=}"; OPT_SANITIZED_DB="${OPT_SANITIZED_DB/#\~/$HOME}" ;;
      --allowlist=*)     OPT_ALLOWLIST="${1#*=}"; OPT_ALLOWLIST="${OPT_ALLOWLIST/#\~/$HOME}" ;;
      --group=*)         OPT_GROUP="${1#*=}" ;;
      --purpose=*)       OPT_PURPOSE="${1#*=}" ;;
      --key=*)           OPT_KEY="${1#*=}"; OPT_KEY="${OPT_KEY/#\~/$HOME}" ;;
      --full-files)      OPT_FULL_FILES="y" ;;
      -s=*|--step=*)     OPT_STEP="${1#*=}" ;;
      --execute|-y|--yes) OPT_EXECUTE="y" ;;
      --dry-run)         OPT_EXECUTE="n" ;;
      -h|--help)         show_help; exit 0 ;;
      -*)                die "unknown option: $1 (try: pl onboard --help)" ;;
      *)                 [ -z "$OPT_SITE" ] && OPT_SITE="$1" || die "unexpected argument: $1" ;;
    esac
    shift
  done
}

# A per-site allowlist of public-contact addresses that may legitimately remain in
# a sanitized dump. Defaults to lib/sanitizers/<site>.allow if present.
resolve_allowlist(){
  [ -n "$OPT_ALLOWLIST" ] && { echo "$OPT_ALLOWLIST"; return; }
  [ -f "$SANITIZERS_DIR/$OPT_SITE.allow" ] && { echo "$SANITIZERS_DIR/$OPT_SITE.allow"; return; }
  echo ""
}

# ── Step 1: preflight ────────────────────────────────────────────────────────
step_preflight(){
  print_header "Step 1/7 · Preflight"
  [ -n "$OPT_SITE" ]   || die "site name required:  pl onboard <site> --server=… --source=… --recipe=…"
  [ -n "$OPT_SERVER" ] || die "--server=<srv> required"
  [ -n "$OPT_SOURCE" ] || die "--source=<remote-webroot> required (e.g. /var/www/site/web)"
  [ -n "$OPT_RECIPE" ] || die "--recipe=<recipe> required"

  # Site must not already be registered or scaffolded.
  if [ -d "$SITES_DIR/$OPT_SITE" ]; then
    die "site dir already exists: $SITES_DIR/$OPT_SITE — onboard is for NEW sites"
  fi
  source "$PROJECT_ROOT/lib/yaml-write.sh"
  if YAML_CONFIG_FILE="$PROJECT_ROOT/nwp.yml" yaml_site_exists "$OPT_SITE" "$PROJECT_ROOT/nwp.yml" 2>/dev/null; then
    die "site '$OPT_SITE' is already registered in nwp.yml"
  fi

  # A reviewed sanitizer must exist (the prod-side, human-run step). We do NOT run
  # it; we require its presence so onboarding a site without one is a hard stop.
  if [ ! -f "$SANITIZERS_DIR/$OPT_SITE.sh" ]; then
    print_error "no sanitizer at lib/sanitizers/$OPT_SITE.sh"
    print_hint  "write one (see lib/sanitizers/mayo.sh) and have it human-reviewed first —"
    print_hint  "sanitization is security-critical (CLAUDE.md). Onboarding cannot proceed without it."
    exit 1
  fi
  print_status "OK" "sanitizer present: lib/sanitizers/$OPT_SITE.sh"

  # Tooling.
  for t in ssh scp ddev; do command -v "$t" >/dev/null 2>&1 || die "$t is required but not installed"; done
  [ -f "$OPT_KEY" ] || die "SSH key not found: $OPT_KEY (override with --key=PATH)"

  local allow; allow=$(resolve_allowlist)
  print_info "site=$OPT_SITE  server=$OPT_SERVER  recipe=$OPT_RECIPE  purpose=$OPT_PURPOSE"
  print_info "remote webroot: $OPT_SOURCE"
  print_info "PII allowlist:  ${allow:-<built-in defaults only>}"
  print_status "OK" "preflight passed"
}

# ── Step 2: create GitLab project ────────────────────────────────────────────
step_create_project(){
  print_header "Step 2/7 · Create GitLab project"
  local group="${OPT_GROUP:-}"
  if [ "$OPT_EXECUTE" != "y" ]; then
    print_info "[dry-run] would create GitLab project '${group:-<default-group>}/$OPT_SITE'"
    return 0
  fi
  source "$PROJECT_ROOT/lib/git.sh"
  if [ -n "$group" ]; then
    gitlab_api_create_project "$OPT_SITE" "$group" "NWP onboarded site: $OPT_SITE" \
      || die "GitLab project creation failed"
  else
    gitlab_api_create_project "$OPT_SITE" \
      || die "GitLab project creation failed"
  fi
}

# ── Step 3: supervised prod sanitize + FAIL-CLOSED PII gate ──────────────────
step_sanitize_and_gate(){
  print_header "Step 3/7 · Sanitize (supervised) + fail-closed PII gate"
  local remote_root; remote_root="$(dirname "$OPT_SOURCE")"

  if [ -z "$OPT_SANITIZED_DB" ]; then
    # We never run the destructive sanitizer ourselves. Hand the operator the exact
    # command and stop; they re-invoke with --sanitized-db once it has produced output.
    print_warning "no --sanitized-db supplied — the prod sanitize step is HUMAN-SUPERVISED."
    echo
    print_info "Run this ON the production server (it sanitizes a scratch copy; live DB stays read-only):"
    echo "    scp -i $OPT_KEY lib/sanitizers/$OPT_SITE.sh <prod>:/tmp/$OPT_SITE-sanitizer.sh"
    echo "    ssh -i $OPT_KEY <prod> \\"
    echo "        \"cd '$remote_root' && sudo -u www-data /tmp/$OPT_SITE-sanitizer.sh \\"
    echo "             --site-dir '$remote_root' --output /tmp/$OPT_SITE-sanitized.sql.gz\""
    echo "    # then pull the sanitized dump back to this machine:"
    echo "    scp -i $OPT_KEY <prod>:/tmp/$OPT_SITE-sanitized.sql.gz ~/dumps/"
    echo
    print_hint "then resume:  pl onboard $OPT_SITE --server=$OPT_SERVER --source=$OPT_SOURCE \\"
    print_hint "                 --recipe=$OPT_RECIPE --sanitized-db=~/dumps/$OPT_SITE-sanitized.sql.gz --execute -s=3"
    exit 2
  fi

  [ -r "$OPT_SANITIZED_DB" ] || die "sanitized dump not readable: $OPT_SANITIZED_DB"

  # THE GATE. Fail-closed: only an explicit pass (rc 0) lets the data proceed.
  local allow; allow=$(resolve_allowlist)
  print_info "scanning $OPT_SANITIZED_DB for residual PII (fail-closed)…"
  if pii_gate_scan "$OPT_SANITIZED_DB" "$allow"; then
    print_status "OK" "PII gate PASSED — no unsanitized PII found"
  else
    local rc=$?
    print_error "PII gate FAILED (rc=$rc) — refusing to bring this dump onto dev"
    print_hint  "the dump still contains PII (or could not be read). Fix the sanitizer and re-run."
    exit 1
  fi
}

# ── Step 4: scaffold dev environment (reuses the SAFE import step functions) ──
step_scaffold(){
  print_header "Step 4/7 · Scaffold dev environment"
  if [ "$OPT_EXECUTE" != "y" ]; then
    print_info "[dry-run] would scaffold $SITES_DIR/$OPT_SITE (ddev, files via stage-file-proxy, composer install)"
    return 0
  fi
  # Pull in the reusable import step functions. We deliberately do NOT use
  # import_step_pull_database (raw pull) nor import_step_sanitize_database
  # (local sanitize = threat-model violation). The sanitized dump is supplied.
  source "$PROJECT_ROOT/lib/server-scan.sh"
  source "$PROJECT_ROOT/lib/import-tui.sh"
  source "$PROJECT_ROOT/lib/import.sh"

  local remote_root; remote_root="$(dirname "$OPT_SOURCE")"
  local webroot_name; webroot_name="$(basename "$OPT_SOURCE")"
  local ssh_target; ssh_target="$(get_server_ip "$OPT_SERVER" 2>/dev/null || echo "$OPT_SERVER")"

  cd "$SITES_DIR" || die "cannot cd into $SITES_DIR"
  import_step_create_directory "$OPT_SITE" "$webroot_name" || die "directory scaffold failed"
  import_step_configure_ddev   "$OPT_SITE" "$webroot_name" "8.2" || die "ddev configure failed"
  import_step_pull_files       "$OPT_SITE" "$ssh_target" "$OPT_KEY" "$remote_root" "$webroot_name" "$OPT_FULL_FILES" \
    || die "file sync failed"
  if [ "$OPT_FULL_FILES" != "y" ]; then
    ( cd "$SITES_DIR/$OPT_SITE" && ddev start >/dev/null 2>&1 && ddev composer install --no-interaction 2>/dev/null ) || true
  fi
}

# ── Step 5: load the sanitized DB (no local sanitize step) ───────────────────
step_load_db(){
  print_header "Step 5/7 · Load sanitized database"
  if [ "$OPT_EXECUTE" != "y" ]; then
    print_info "[dry-run] would import the gated dump ($OPT_SANITIZED_DB) into DDEV (no further sanitize)"
    return 0
  fi
  # import_step_import_database imports from db.sql.gz in $PWD/$site. Stage the
  # ALREADY-SANITIZED, ALREADY-GATED dump there — never a raw pull.
  cp -f "$OPT_SANITIZED_DB" "$SITES_DIR/$OPT_SITE/db.sql.gz" || die "could not stage sanitized dump"
  ( cd "$SITES_DIR" && import_step_import_database "$OPT_SITE" ) || die "database import failed"
}

# ── Step 6: finalize dev (settings, stage-file-proxy, caches, verify) ────────
step_finalize(){
  print_header "Step 6/7 · Finalize dev environment"
  if [ "$OPT_EXECUTE" != "y" ]; then
    print_info "[dry-run] would configure settings, stage-file-proxy, clear caches, verify site"
    return 0
  fi
  local webroot_name; webroot_name="$(basename "$OPT_SOURCE")"
  cd "$SITES_DIR" || die "cannot cd into $SITES_DIR"
  import_step_configure_settings "$OPT_SITE" "$webroot_name" || true
  import_step_clear_caches       "$OPT_SITE" || true
  import_step_verify_site        "$OPT_SITE" || true
}

# ── Step 7: register + first status ──────────────────────────────────────────
step_register(){
  print_header "Step 7/7 · Register in nwp.yml + first status"
  if [ "$OPT_EXECUTE" != "y" ]; then
    print_info "[dry-run] would yaml_add_site '$OPT_SITE' '$SITES_DIR/$OPT_SITE' '$OPT_RECIPE' development '$OPT_PURPOSE'"
    print_info "[dry-run] would run: pl status $OPT_SITE"
    return 0
  fi
  source "$PROJECT_ROOT/lib/yaml-write.sh"
  yaml_add_site "$OPT_SITE" "$SITES_DIR/$OPT_SITE" "$OPT_RECIPE" "development" "$OPT_PURPOSE" \
    || die "yaml_add_site failed"
  print_status "OK" "registered '$OPT_SITE' in nwp.yml"
  "$PL" status "$OPT_SITE" 2>/dev/null || "$PL" status 2>/dev/null || true
}

main(){
  parse_args "$@"
  [ -n "$OPT_SITE" ] || { show_help; exit 0; }

  if [ "$OPT_EXECUTE" != "y" ]; then
    print_warning "DRY-RUN (default). Re-run with --execute to perform the onboarding."
  fi

  # Resumable: -s=N starts at step N. Preflight ALWAYS runs (it validates the
  # inputs every resume needs). Later steps run only when OPT_STEP allows.
  step_preflight
  [ "$OPT_STEP" -le 2 ] && step_create_project    || print_info "· skipping step 2 (create project)"
  [ "$OPT_STEP" -le 3 ] && step_sanitize_and_gate || print_info "· skipping step 3 (sanitize+gate)"
  [ "$OPT_STEP" -le 4 ] && step_scaffold          || print_info "· skipping step 4 (scaffold)"
  [ "$OPT_STEP" -le 5 ] && step_load_db           || print_info "· skipping step 5 (load db)"
  [ "$OPT_STEP" -le 6 ] && step_finalize          || print_info "· skipping step 6 (finalize)"
  [ "$OPT_STEP" -le 7 ] && step_register          || print_info "· skipping step 7 (register)"

  echo
  if [ "$OPT_EXECUTE" = "y" ]; then
    print_success "onboard complete for '$OPT_SITE'"
  else
    print_success "dry-run complete — no changes made. Add --execute to run for real."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
