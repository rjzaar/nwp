#!/bin/bash
set -euo pipefail

################################################################################
# NWP Financial Market Monitor Command
#
# Monitors S&P500, VIX, and ASX200 for super fund switching signals.
# Sends email alerts when market conditions suggest switching between
# Australian Shares and Cash.
#
# Usage: pl fin-monitor [OPTIONS]
#
# Options:
#   --status                Show current market data and signal status
#   --set-cash              Record that you've switched to cash
#   --set-growth            Record that you've switched to growth
#   --test-email            Send a test email
#   --check                 Dry run (no emails sent)
#   --setup                 Run initial setup (install deps, configure cron)
#   --setup-check           Check setup status
#   --setup-uninstall       Remove cron jobs
#   --help, -h              Show this help
#
# Examples:
#   pl fin-monitor --status          # Check current market signals
#   pl fin-monitor --setup           # Initial setup
#   pl fin-monitor --set-cash        # Record switch to cash
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
FIN_DIR="$PROJECT_ROOT/fin"

# Source required libraries
source "$PROJECT_ROOT/lib/ui.sh"

# Check if setup subcommand
case "${1:-}" in
    --setup)
        shift
        exec "$FIN_DIR/setup-fin-monitor.sh" "$@"
        ;;
    --setup-check)
        shift
        exec "$FIN_DIR/setup-fin-monitor.sh" --check "$@"
        ;;
    --setup-uninstall)
        shift
        exec "$FIN_DIR/setup-fin-monitor.sh" --uninstall "$@"
        ;;
esac

# Use the wrapper if it exists (has correct Python path)
if [[ -x "$FIN_DIR/run-fin-monitor.sh" ]]; then
    exec "$FIN_DIR/run-fin-monitor.sh" "$@"
fi

# Fallback to direct execution
exec "$FIN_DIR/fin-monitor.sh" "$@"
