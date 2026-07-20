#!/bin/bash
set -euo pipefail
################################################################################
# lib/sanitizers/ssc.sh — per-site sanitizer resolver for ssc (Moodle consumer).
#
# ssc is a stock Moodle stack (ADR-0031 consumer, SSOs against nwc). It needs no
# bespoke anonymisation beyond the generic Moodle pipeline, so this is a THIN
# WRAPPER that delegates to lib/sanitizers/moodle-full.sh — the reviewed atomic
# orchestrator that composes the DB sanitiser (moodle.sh, scratch-DB) with the
# moodledata omit-and-placeholder scrub (moodle-dataroot.sh) + the independent
# PII gate, and emits a single bundle {db.sql.gz, dataroot-manifest} (ADR-0032
# Flow A). server-publish.sh detects the Moodle bundle and gates the inner dump.
#
# WHY a per-site file exists at all: scripts/commands/server-publish.sh resolves
# the sanitizer as lib/sanitizers/<site>.sh and REFUSES to publish if it is
# absent (fail-closed — never publish a site with no reviewed sanitizer). This
# wrapper is that explicit, reviewed opt-in for ssc. It is the Moodle analogue of
# a Drupal site pointing server-publish at lib/sanitizers/standard.sh.
#
# ROUTING (ops#110/#111): ssc sanitises via PATH A — prod-native server-publish.sh
# + moodle-full.sh. This honours the threat model (sanitise on prod, raw data
# never leaves prod) and reuses the already-reviewed sub-scrubbers. The DDEV
# in-place path (lib/database-router.sh:_sanitize_staging_db_moodle) stays a
# fail-closed stub that points operators here.
#
# INTERFACE: identical to moodle-full.sh / standard.sh / mayo.sh
#   --site-dir DIR   Moodle root (contains config.php + version.php).  REQUIRED.
#   --output FILE    Path for the sanitized bundle (.tar.gz {db.sql.gz, manifest}).
#   --dataroot DIR   Live moodledata (READ-ONLY). Default: resolved from config.php.
#   --verify         Re-verify an existing --output bundle only; write nothing.
#   -h | --help      Usage (delegated to moodle-full.sh).
# All arguments are passed through verbatim.
#
# moodledata is handled by moodle-full.sh via the omit-and-placeholder scrub
# (moodle-dataroot.sh): the bundle carries an EMPTY dataroot manifest, not files.
# The dev/stg loader rebuilds the empty scaffold locally + prunes orphaned
# mdl_files rows (`moosh file-dbcheck`). See ADR-0032.
#
# SECURITY: per CLAUDE.md the sanitizer chain is security-critical. Any change
# here or to moodle-full.sh / moodle.sh / moodle-dataroot.sh requires explicit
# human review before merge.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Delegate verbatim to the full Moodle orchestrator. exec so its exit status
# (fail-closed non-zero on any failure) propagates unchanged to server-publish.sh.
exec bash "$SCRIPT_DIR/moodle-full.sh" "$@"
