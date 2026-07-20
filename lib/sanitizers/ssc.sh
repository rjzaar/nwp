#!/bin/bash
set -euo pipefail
################################################################################
# lib/sanitizers/ssc.sh — per-site sanitizer resolver for ssc (Moodle consumer).
#
# ssc is a stock Moodle stack (ADR-0031 consumer, SSOs against nwc). It needs no
# bespoke anonymisation beyond the generic Moodle sanitizer, so this is a THIN
# WRAPPER that delegates to lib/sanitizers/moodle.sh — the reviewed prod-native,
# scratch-DB implementation.
#
# WHY a per-site file exists at all: scripts/commands/server-publish.sh resolves
# the sanitizer as lib/sanitizers/<site>.sh and REFUSES to publish if it is
# absent (fail-closed — never publish a site with no reviewed sanitizer). This
# wrapper is that explicit, reviewed opt-in for ssc. It is the Moodle analogue of
# a Drupal site pointing server-publish at lib/sanitizers/standard.sh.
#
# ROUTING (ops#110): ssc sanitises via PATH A — prod-native server-publish.sh +
# moodle.sh. This honours the threat model (sanitise on prod, raw data never
# leaves prod) and reuses the already-reviewed moodle.sh. The DDEV in-place path
# (lib/database-router.sh:_sanitize_staging_db_moodle) stays a fail-closed stub
# that points operators here.
#
# INTERFACE: identical to moodle.sh / standard.sh / mayo.sh
#   --site-dir DIR   Moodle root (contains config.php + version.php).  REQUIRED.
#   --output FILE    Path for the sanitized gzipped dump.
#   --verify         PII-sweep an existing --output dump only; write nothing.
#   -h | --help      Usage (delegated to moodle.sh).
# All arguments are passed through verbatim.
#
# moodledata (user pictures / submitted files under filedir, sessions, temp,
# trashdir) is a SEPARATE surface that this SQL pass does NOT touch. moodle.sh
# emits an explicit NOTE about it; scrubbing/omitting it (lib/sanitizers/
# moodle-dataroot.sh) must happen wherever ssc's moodledata is published/synced,
# NOT in this DB-only sanitizer. Tracked in ops#110.
#
# SECURITY: per CLAUDE.md the sanitizer is security-critical. Any change here or
# to moodle.sh requires explicit human review before merge.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Delegate verbatim to the generic Moodle sanitizer. exec so its exit status
# (fail-closed non-zero on any failure) propagates unchanged to server-publish.sh.
exec bash "$SCRIPT_DIR/moodle.sh" "$@"
