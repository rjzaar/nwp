#!/bin/bash
set -euo pipefail

################################################################################
# NWP Mass Times Scraper Command
#
# Automated Catholic mass times scraping for mt.nwpcode.org (F16).
# Code-first extraction using regex, CSS selectors, and PDF parsing.
# LLM used only as a Tier 3 fallback.
#
# Usage: pl mass-times [OPTIONS]
#
# Options:
#   --discover              Run parish discovery
#   --build [parish]        Build/rebuild extraction template for a parish
#   --extract               Run extraction cycle
#   --status                Show system status
#   --report                Generate summary report
#   --check                 Dry run (no writes)
#   --setup                 Run initial setup (install deps, configure cron)
#   --setup-check           Check setup status
#   --setup-uninstall       Remove cron jobs
#   --deploy                Deploy to server
#   --deploy-conf           Generate conf only (no deploy)
#   --help, -h              Show this help
#
# Examples:
#   pl mass-times --status           # Check system status
#   pl mass-times --setup            # Initial setup
#   pl mass-times --discover         # Discover parishes
#   pl mass-times --extract          # Run extraction cycle
#   pl mass-times --build sacred-heart  # Build template for a parish
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
MT_DIR="$PROJECT_ROOT/mt"

# Source required libraries
source "$PROJECT_ROOT/lib/ui.sh"

# Check if setup/deploy subcommand
case "${1:-}" in
    --setup)
        shift
        exec "$MT_DIR/setup-mass-times.sh" "$@"
        ;;
    --setup-check)
        shift
        exec "$MT_DIR/setup-mass-times.sh" --check "$@"
        ;;
    --setup-uninstall)
        shift
        exec "$MT_DIR/setup-mass-times.sh" --uninstall "$@"
        ;;
    --deploy)
        shift
        exec "$MT_DIR/deploy-mass-times.sh" "$@"
        ;;
    --deploy-conf)
        shift
        exec "$MT_DIR/deploy-mass-times.sh" --conf-only "$@"
        ;;
esac

# Use the wrapper if it exists (has correct Python path)
if [[ -x "$MT_DIR/run-mass-times.sh" ]]; then
    exec "$MT_DIR/run-mass-times.sh" "$@"
fi

# Fallback to direct execution
exec "$MT_DIR/mass-times.sh" "$@"
