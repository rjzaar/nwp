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
#   nwp-server backup --site-dir DIR [opts]      per-SITE scope (DB + files)
#   nwp-server backup --host [opts]              BOX scope (the whole host)
#
# TWO SCOPES, ONE VERB. `--site-dir` is the right unit for a pre-deploy snapshot
# and the WRONG unit for disaster recovery: restore every site snapshot onto a
# bare Ubuntu box and you have a pile of files that serves nothing. `--host` adds
# the box itself — /etc (nginx, letsencrypt, postfix, cron, sshd, ufw, php),
# /usr/local, /root, /opt, every webroot and moodledata under /var/www, every
# non-system database, and a generated manifest (package selections, enabled
# units, per-user crontabs, `nginx -T`, replayable MySQL grants). Same repo
# family, same custodian-pull contract, same encryption — a different unit.
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
#
# BOX SCOPE (--host) options:
#   --scope LIST        comma list of config,db,web (default: all three)
#   --extra-path P      add a path to the box scope (repeatable). NOT included by
#                       default: /home — on the live box that is ~10 GB of
#                       transient `pl` snapshot droppings already superseded by
#                       this very backup.
#   --web-root PATH     web tree root for the `web` scope (default /var/www)
#   --min-free-mb N     refuse when the repo filesystem would be left with less
#                       than N MB after a worst-case (zero-dedup) first snapshot
#                       (default 2048). Filling / on a live box is an outage.
#   --force-disk        take the backup anyway. Never the default: an aborted
#                       backup is recoverable, a full root filesystem is not.
#
# RESTIC PROVENANCE (both scopes):
#   --restic-provenance minisign|apt|none
#       minisign  verify the binary against --restic-pub (the ADR-0025 default
#                 for a signed ver-kit restic).
#       apt       the binary belongs to an installed dpkg package whose shipped
#                 checksums still match on disk. This is a REAL provenance claim
#                 (Ubuntu archive signing + dpkg integrity), not a bypass — it is
#                 what you have on a host that installed restic from the distro.
#       none      no provenance. Must be asked for explicitly and says so loudly.
#   --skip-restic-verify is retained as an alias for --restic-provenance none.
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
# BOX-scope helpers (--host). Hard-sourced: without it --host cannot run, and a
# --host run that silently degrades to "no databases found" is the exact
# silent-partial failure this whole file is written against.
source "$PROJECT_ROOT/lib/server-backup-host.sh"

SITE_DIR="" REPO="" PASS_FILE="/etc/nwp-server/restic.pass"
# NWP_RESTIC_BIN: name the binary explicitly instead of taking whatever is first
# on PATH. Two uses, one of them a real one: pointing a run at a specific restic
# (e.g. a signed one out of the ver-kit rather than the distro's), and putting a
# machine that HAS restic into the shoes of one that does not
# (NWP_RESTIC_BIN=/nonexistent/restic). The second is why the provenance tests
# can pin runner behaviour from a laptop — see tests/unit/test-server-backup-host.bats.
RESTIC="${NWP_RESTIC_BIN:-$(command -v restic || echo restic)}" RESTIC_PUB=""
DRUSH="" FILES_SUB="web/sites/default/files" KEEP_LAST=3 TAG=""
DB_ONLY=n FILES_ONLY=n SKIP_RESTIC_VERIFY=n EXECUTE=n
# ops#127: sanitised long-term DR tier. --sanitize runs the site sanitiser
# (--preserve-admin: keep the real admin, scrub every other user) → external
# lib/pii-gate.sh (fail-closed) → snapshots the SANITISED DB to a DISTINCT
# `<site>-sanitized` repo. It carries no member PII, so ver keeps it long-term
# (tiered), while the RAW repo is capped at 30d (--keep-within). DB-only for now:
# sanitised FILES (moodledata/uploads) are ops#84 — never mix raw files in here.
SANITIZE=n SANITIZER=""
# BOX scope (--host): the disaster-recovery unit. See lib/server-backup-host.sh
# for why per-site snapshots alone cannot rebuild a host.
HOST_SCOPE=n SCOPE="config,db,web" WEB_ROOT="/var/www"
EXTRA_PATHS=() MIN_FREE_MB=2048 FORCE_DISK=n
# Provenance of the restic binary. Empty = infer (minisign when --restic-pub is
# given, else fail-closed on a live run, as before).
RESTIC_PROVENANCE=""

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
    --host)       HOST_SCOPE=y ;;
    --scope=*)    SCOPE="${1#*=}" ;;
    --scope)      SCOPE="$2"; shift ;;
    --extra-path=*) EXTRA_PATHS+=("${1#*=}") ;;
    --extra-path) EXTRA_PATHS+=("$2"); shift ;;
    --web-root=*) WEB_ROOT="${1#*=}" ;;
    --web-root)   WEB_ROOT="$2"; shift ;;
    --min-free-mb=*) MIN_FREE_MB="${1#*=}" ;;
    --min-free-mb)   MIN_FREE_MB="$2"; shift ;;
    --force-disk) FORCE_DISK=y ;;
    --restic-provenance=*) RESTIC_PROVENANCE="${1#*=}" ;;
    --restic-provenance)   RESTIC_PROVENANCE="$2"; shift ;;
    --skip-restic-verify) SKIP_RESTIC_VERIFY=y; RESTIC_PROVENANCE=none ;;
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

# Provenance of the restic binary via the DISTRIBUTION: the file must belong to
# an installed dpkg package and still match the checksums that package shipped.
# That is a genuine supply-chain claim — the Ubuntu archive signed the package,
# apt verified that signature at install time, and this re-checks that nothing
# rewrote the binary since. It is strictly stronger than the --skip-restic-verify
# it replaces on a distro-installed host, and it is checkable, which is the
# property the estate's registry demands of every claimed capability.
#
# Returns 0 = provenance established (prints how), 1 = it is NOT established.
verify_restic_apt(){
  local bin="$1" pkg=""
  command -v dpkg-query >/dev/null 2>&1 || { print_error "no dpkg on this host — 'apt' provenance is not available"; return 1; }
  pkg="$(dpkg-query -S "$(readlink -f "$bin")" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -n "$pkg" ] || pkg="$(dpkg-query -S "$bin" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -n "$pkg" ] || { print_error "$bin belongs to no installed package — cannot establish apt provenance"; return 1; }
  local ver; ver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"

  # Re-verify the shipped checksums. dpkg records md5sums; md5 is worthless
  # against a forger but perfectly good against the thing we are actually
  # testing here — did anything overwrite this file after apt installed it.
  # The signature that establishes ORIGIN was checked by apt at install time.
  local sums="/var/lib/dpkg/info/${pkg}.md5sums"
  [ -f "$sums" ] || sums="/var/lib/dpkg/info/${pkg}:$(dpkg --print-architecture 2>/dev/null).md5sums"
  if [ ! -f "$sums" ]; then
    print_error "no dpkg md5sums manifest for $pkg — cannot re-verify the binary on disk"; return 1
  fi
  local want got rel; rel="$(readlink -f "$bin")"; rel="${rel#/}"
  want="$(awk -v p="$rel" '$2==p {print $1; exit}' "$sums")"
  [ -n "$want" ] || { print_error "$rel is not listed in $pkg's md5sums — cannot verify"; return 1; }
  got="$(md5sum "/$rel" 2>/dev/null | awk '{print $1}')"
  if [ "$want" != "$got" ]; then
    print_error "restic binary does NOT match the checksum $pkg shipped — the file was modified after install"; return 1
  fi
  print_status "OK" "restic provenance: dpkg package ${pkg} ${ver} (on-disk checksum matches what apt installed)"
  return 0
}

# Verify the restic binary against our pinned minisign key (supply chain), fail-closed.
#
# ORDER MATTERS HERE, and it is the whole content of a bug this shipped with.
# The presence check used to come first, so on any host WITHOUT restic the
# function returned 0 before it had looked at --restic-provenance at all:
#   * a typo'd mode (`--restic-provenance=trustme`) was silently ACCEPTED, and
#   * `--restic-provenance=none` never said the supply chain was unproven.
# Whether an argument is valid, and what posture the operator asked for, are
# properties of the COMMAND. Letting an unrelated property of the machine decide
# them is fail-open on a security-relevant flag. Both now happen unconditionally,
# before anything is looked up on disk.
verify_restic(){
  # 1 · Is the mode itself legal? Environment-independent, always.
  case "${RESTIC_PROVENANCE:-}" in
    ''|minisign|apt|none) : ;;
    *) die "--restic-provenance must be minisign, apt or none (got: $RESTIC_PROVENANCE)" ;;
  esac
  # 2 · Say the posture out loud. `none` is a decision to run unverified and it
  #     is stated whether or not the binary happens to be installed here.
  if [ "$RESTIC_PROVENANCE" = none ] || [ "$SKIP_RESTIC_VERIFY" = y ]; then
    print_warning "restic binary is UNVERIFIED (--restic-provenance none) — the snapshot's supply chain is unproven"
    # Still fall through to the presence check: "unverified" and "absent" are
    # different problems and a live run needs to hear about both.
  fi
  # 3 · Now the machine.
  if ! command -v "$RESTIC" >/dev/null 2>&1; then
    [ "$EXECUTE" = y ] && die "restic not found: $RESTIC"
    print_warning "[dry-run] restic not found ($RESTIC) — required for a live run"; return 0
  fi
  if [ "$RESTIC_PROVENANCE" = none ] || [ "$SKIP_RESTIC_VERIFY" = y ]; then
    return 0
  fi
  if [ "$RESTIC_PROVENANCE" = apt ]; then
    if verify_restic_apt "$(command -v "$RESTIC")"; then return 0; fi
    [ "$EXECUTE" = y ] && die "apt provenance for restic could not be established — refusing (fail-closed)"
    print_warning "[dry-run] apt provenance not established; a live run would refuse"
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

################################################################################
# BOX SCOPE — `nwp-server backup --host`
#
# The disaster-recovery unit. Everything a bare Ubuntu box needs to become THIS
# box again: config, generated state, every database, every webroot. Written to
# a DISTINCT repo (<host>-system) so the erasure ceiling that governs per-site
# RAW user data (ops#127, --keep-within) can be applied independently of the
# host-config tier, which carries no member PII of its own.
################################################################################
host_scope_has(){ case ",$SCOPE," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

main_host(){
  local host; host="$(sbh_hostname)"
  local repo_site="${host}-system"
  [ -n "$REPO" ] || REPO="/var/backups/nwp-server/$repo_site"
  [ -n "$TAG" ]  || TAG="${host}/system"
  # When the caller named the repo (the `pl server backup` driver does, so the
  # archive is filed under the NWP server name rather than this clone's inherited
  # `hostname -s`), the staging directory follows it. Otherwise a repo called
  # live-system stages into a directory called git-system and the two names in
  # the snapshot listing disagree about which box this is.
  repo_site="$(basename "$REPO")"

  local s
  for s in ${SCOPE//,/ }; do
    case "$s" in config|db|web) : ;; *) die "--scope items must be config, db or web (got: $s)" ;; esac
  done

  print_header "nwp-server backup --host · $host"
  [ "$EXECUTE" = y ] || print_warning "DRY-RUN (default) — re-run with --execute to perform the backup."

  # ── Preflight ──────────────────────────────────────────────────────────────
  print_header "Preflight"
  # Resolve the config paths that actually exist. A path that is missing is
  # REPORTED, never silently dropped: "it wasn't in the backup" must be a thing
  # the operator was told at backup time, not discovered at restore time.
  local -a paths=() missing=()
  if host_scope_has config; then
    local p
    for p in $SBH_DEFAULT_PATHS; do
      if [ -e "$p" ]; then paths+=("$p"); else missing+=("$p"); fi
    done
  fi
  if host_scope_has web; then
    if [ -d "$WEB_ROOT" ]; then paths+=("$WEB_ROOT"); else missing+=("$WEB_ROOT"); fi
  fi
  local ep
  for ep in ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}; do
    if [ -e "$ep" ]; then paths+=("$ep"); else die "--extra-path does not exist: $ep"; fi
  done
  # SBH_DEFAULT_PATHS already contains /var/www; drop the duplicate when both the
  # config and web scopes are on (restic would dedup it, but the plan should not
  # claim to back the same tree up twice).
  local -a uniq=(); local q keep
  for p in ${paths[@]+"${paths[@]}"}; do
    keep=y; for q in ${uniq[@]+"${uniq[@]}"}; do [ "$q" = "$p" ] && keep=n; done
    [ "$keep" = y ] && uniq+=("$p")
  done
  paths=(${uniq[@]+"${uniq[@]}"})

  if [ "${#paths[@]}" -eq 0 ] && ! host_scope_has db; then
    die "nothing to back up: --scope '$SCOPE' resolved to no paths and no databases"
  fi

  # Password file (same contract as the per-site scope).
  if [ ! -r "$PASS_FILE" ]; then
    [ "$EXECUTE" = y ] && die "restic password file not readable: $PASS_FILE"
    print_warning "[dry-run] restic password file $PASS_FILE not present (required for live run)"
  else
    local perm; perm="$(stat -c '%a' "$PASS_FILE" 2>/dev/null || echo '?')"
    [ "$perm" = 600 ] || print_warning "restic password file $PASS_FILE is $perm; expected 600"
  fi
  verify_restic

  # ── Disk projection (the guard that keeps a backup from becoming an outage) ─
  # restic dedups and compresses, so the FIRST snapshot is the worst case and
  # every later one is far smaller. Budget for the worst case anyway: a
  # half-written repo is recoverable, a full root filesystem on a live box is a
  # site-down incident, and this box has 46 GB free and 15 sites on it.
  local src_mb=0 free_mb after_mb
  if [ "${#paths[@]}" -gt 0 ]; then
    src_mb="$(sbh_size_mb "${paths[@]}")" || print_warning "could not measure source size — treating the projection as UNKNOWN"
  fi
  free_mb="$(sbh_free_mb "$REPO")"
  [ -n "$free_mb" ] || free_mb=0
  after_mb=$(( free_mb - src_mb ))
  print_info "repo:       $REPO"
  print_info "tag:        $TAG"
  print_info "scope:      $SCOPE"
  print_info "paths:      ${paths[*]:-<none>}"
  [ "${#missing[@]}" -gt 0 ] && print_warning "NOT in this backup (path absent): ${missing[*]}"
  # A statement about the SCOPE, not about this machine. It used to be gated on
  # `[ -d /home ]`, which made the plan's contents depend on the host rather than
  # on what was asked for — and made the test that pinned it pass here and fail
  # on a runner with no /home.
  if ! printf '%s\n' ${paths[@]+"${paths[@]}"} | grep -qx /home; then
    print_info "note:       /home is not in the default scope — add --extra-path=/home if it holds anything you would need back"
  fi
  print_info "sources:    ${src_mb} MB (worst case, before restic dedup/compression)"
  print_info "free:       ${free_mb} MB on the repo filesystem → ${after_mb} MB worst-case remaining"
  if [ "$after_mb" -lt "$MIN_FREE_MB" ]; then
    if [ "$FORCE_DISK" = y ]; then
      print_warning "projected free space ${after_mb} MB < ${MIN_FREE_MB} MB — proceeding because --force-disk was given"
    else
      die "refusing: a worst-case first snapshot would leave ${after_mb} MB free (< ${MIN_FREE_MB} MB). Prune the repo, pick a smaller --scope, or pass --force-disk if you have measured the real delta."
    fi
  fi

  # ── Ensure repo exists ─────────────────────────────────────────────────────
  local RC=("$RESTIC" -r "$REPO" --password-file "$PASS_FILE")
  print_header "Step 1 · Ensure restic repo"
  if [ "$EXECUTE" = y ] && ! "${RC[@]}" cat config >/dev/null 2>&1; then
    mkdir -p "$(dirname "$REPO")"
    run "${RC[@]}" init
  else
    print_info "$([ "$EXECUTE" = y ] && echo 'repo exists' || echo '[dry-run] would init repo if absent')"
  fi

  # ── Generated host state (manifest) ────────────────────────────────────────
  # A FIXED staging path, not mktemp -d. Two reasons, both learned the hard way
  # from the first real run: a random /tmp/tmp.XXXX path makes every snapshot's
  # tree a different tree, so restic re-stores the manifest and all 16 database
  # dumps in full every night instead of deduplicating against yesterday's; and
  # a restore has to discover the path before it can `--include` anything. /tmp
  # is also the wrong filesystem for ~130 MB of dumps on a box with a tmpfs.
  local staging="/var/backups/nwp-server/.staging/${repo_site}"
  local wrote_staging=n
  if host_scope_has config; then
    print_header "Step 2 · Host state manifest"
    if [ "$EXECUTE" = y ]; then
      # 0700 on BOTH levels. This directory holds unencrypted database dumps
      # for the seconds between mysqldump and restic; on a box with 15 sites and
      # several service accounts, world-listable is not good enough.
      install -d -m 700 "$(dirname "${staging:?}")" "$staging"
      # Clear yesterday's staged copy without a recursive rm: this file ships in
      # the prod artifact, and `rm -rf $VAR` on a prod host is a shape the impact
      # contract is right to refuse even when the variable is provably safe.
      find "$staging" -mindepth 1 -delete 2>/dev/null || true
      wrote_staging=y
      sbh_write_manifest "$staging/manifest" || die "could not write the host state manifest"
      if [ -f "$staging/manifest/UNREADABLE.txt" ]; then
        print_warning "some host state could not be read (recorded in the snapshot as manifest/UNREADABLE.txt):"
        sed 's/^/     /' "$staging/manifest/UNREADABLE.txt"
      fi
      print_status "OK" "manifest: $(find "$staging/manifest" -type f | wc -l | tr -d ' ') files"
    else
      print_info "[dry-run] would write: dpkg selections, apt manual/hold, enabled units, df/mounts/ip, nginx -T, per-user crontabs, replayable MySQL grants"
    fi
  fi

  # ── Databases ──────────────────────────────────────────────────────────────
  if host_scope_has db; then
    print_header "Step 3 · Databases (raw, one dump per schema)"
    if [ "$EXECUTE" = y ]; then
      install -d -m 700 "$(dirname "${staging:?}")" "$staging"; wrote_staging=y
      find "$staging/db" -mindepth 1 -delete 2>/dev/null || true
      sbh_dump_databases "$staging/db" || die "database dump failed — refusing to record a partial DR snapshot (fail-closed)"
      print_status "OK" "databases: $(find "$staging/db" -name '*.sql.gz' | wc -l | tr -d ' ') dumped and gzip-verified"
    else
      local dbs; dbs="$(sbh_list_databases 2>/dev/null || true)"
      if [ -n "$dbs" ]; then
        print_info "[dry-run] would dump $(printf '%s\n' "$dbs" | wc -l | tr -d ' ') schema(s): $(printf '%s ' $dbs)"
      else
        print_warning "[dry-run] could not enumerate databases from here (needs the DB socket; a live run on the host will)"
      fi
    fi
  fi

  # ── Snapshot ───────────────────────────────────────────────────────────────
  print_header "Step 4 · Snapshot"
  if host_scope_has config || host_scope_has db; then
    run "${RC[@]}" backup --tag "$TAG" --tag state "$staging"
  fi
  if [ "${#paths[@]}" -gt 0 ]; then
    # One snapshot for the whole path set: a restore wants them as a unit, and a
    # single snapshot means `restic restore latest` is unambiguous.
    run "${RC[@]}" backup --tag "$TAG" --tag box "${paths[@]}"
  fi

  # ── Local staging retention ────────────────────────────────────────────────
  print_header "Step 5 · Local staging retention (keep-last $KEEP_LAST)"
  run "${RC[@]}" forget --tag "$TAG" --keep-last "$KEEP_LAST" --prune

  # ── Shred the staged raw dumps ─────────────────────────────────────────────
  # The staged copy holds RAW database dumps in the clear. It has been committed
  # to the encrypted repo; leaving a plaintext duplicate on the box afterwards
  # would put every site's member data in a directory that is not the archive.
  if [ "$wrote_staging" = y ] && [ "$EXECUTE" = y ]; then
    find "$staging" -type f -exec shred -u {} + 2>/dev/null || true
    find "$staging" -mindepth 1 -delete 2>/dev/null || true
    rmdir "$staging" 2>/dev/null || true
  fi

  echo
  if [ "$EXECUTE" = y ]; then
    print_success "box-level backup complete → $REPO"
    print_hint "verify:  pl server backup <name> --verify"
    print_hint "restore-test:  pl server backup <name> --restore-test"
    print_hint "pull from ver:  ver backup pull --from sftp:<this-host-over-tunnel>:$REPO --to <ver-repo>"
    print_warning "This repo is ON THE BOX IT BACKS UP. Until a pull tier drains it, it does NOT survive loss of the host."
  else
    print_success "dry-run complete — no changes made. Add --execute to run."
  fi
}

main(){
  [ "$HOST_SCOPE" = y ] && { [ -z "$SITE_DIR" ] || die "--host and --site-dir are different scopes; pick one"; main_host; return $?; }
  [ -n "$SITE_DIR" ] || { show_help; die "--site-dir is required (or --host for the box scope)"; }
  local site; site="$(basename "$SITE_DIR")"
  local repo_site="$site"
  # ops#127: sanitised tier resolution — distinct repo, DB-only, fail-closed on a
  # missing sanitiser (never emit an unsanitised long-term archive).
  if [ "$SANITIZE" = y ]; then
    repo_site="${site}-sanitized"
    DB_ONLY=y
    # ops#326: per-instance sanitizers live in the private overlay
    # (private/sanitizers/), searched after the shipped lib/sanitizers/.
    if [ -z "$SANITIZER" ]; then
      SANITIZER="${PROJECT_ROOT:-.}/lib/sanitizers/${site}.sh"
      _san_ovl="${NWP_SANITIZER_OVERLAY_DIR:-${PROJECT_ROOT:-.}/private/sanitizers}/${site}.sh"
      if [ ! -f "$SANITIZER" ] && [ -f "$_san_ovl" ]; then SANITIZER="$_san_ovl"; fi
    fi
    [ -f "$SANITIZER" ] || die "--sanitize: no sanitiser at '$SANITIZER' (or the private/sanitizers overlay) — pass --sanitizer PATH. Refusing to write an unsanitised long-term archive (fail-closed)."
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
