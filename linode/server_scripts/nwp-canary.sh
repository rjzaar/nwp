#!/bin/bash

################################################################################
# nwp-canary.sh - Canary Release Management for NWP Sites
################################################################################
#
# Implements canary release strategy for gradual rollout of new versions:
#   - Deploy to subset of infrastructure (single server or percentage)
#   - Monitor for errors and performance degradation
#   - Auto-promote to full deployment if healthy
#   - Auto-rollback if issues detected
#
# Canary releases minimize risk by exposing changes to a small percentage
# of traffic/servers first, validating stability before full rollout.
#
# Usage:
#   ./nwp-canary.sh [COMMAND] [OPTIONS]
#
# Commands:
#   deploy              Deploy canary version
#   promote             Promote canary to full production
#   rollback            Rollback canary deployment
#   status              Show canary status
#
# Options:
#   --webroot DIR        Web root parent directory (default: /var/www)
#   --domain DOMAIN      Domain name for health checks
#   --percent N          Traffic percentage for canary (default: 10)
#   --duration N         Monitoring duration in seconds (default: 300)
#   --check-interval N   Health check interval in seconds (default: 30)
#   --error-threshold N  Max error count before rollback (default: 3)
#   --perf-threshold N   Max performance degradation % (default: 20)
#   --auto-promote       Auto-promote if all checks pass
#   --auto-rollback      Auto-rollback on failure (default: prompt)
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
# Exit Codes:
#   0 - Success
#   1 - Canary failed (rolled back)
#   2 - Invalid arguments or configuration error
#
# Examples:
#   # Deploy canary with 10% traffic for 5 minutes
#   ./nwp-canary.sh deploy --percent 10 --duration 300
#
#   # Deploy with auto-promotion after successful monitoring
#   ./nwp-canary.sh deploy --duration 600 --auto-promote
#
#   # Check canary status
#   ./nwp-canary.sh status
#
#   # Manually promote canary to production
#   ./nwp-canary.sh promote
#
#   # Rollback canary
#   ./nwp-canary.sh rollback
#
################################################################################

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Default configuration
WEBROOT_PARENT="/var/www"
DOMAIN=""
CANARY_PERCENT=10
DURATION=300
CHECK_INTERVAL=30
ERROR_THRESHOLD=3
PERF_THRESHOLD=20
AUTO_PROMOTE=false
AUTO_ROLLBACK=false
VERBOSE=false

# Directories
PROD_DIR="$WEBROOT_PARENT/prod"
CANARY_DIR="$WEBROOT_PARENT/canary"
LOG_DIR="/var/log/nwp"
STATE_FILE="$LOG_DIR/canary-state.json"
BASELINE_DIR="$LOG_DIR/baselines"

# Monitoring state
ERROR_COUNT=0
HEALTH_CHECKS=0
HEALTH_FAILURES=0

# Helper functions
print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} ${BOLD}$1${NC}"
}

# State management functions
save_canary_state() {
    local status=$1
    local message=$2

    mkdir -p "$LOG_DIR"

    cat > "$STATE_FILE" <<EOF
{
  "status": "$status",
  "message": "$message",
  "percent": $CANARY_PERCENT,
  "started_at": "$(date -Iseconds)",
  "domain": "$DOMAIN",
  "health_checks": $HEALTH_CHECKS,
  "health_failures": $HEALTH_FAILURES,
  "error_count": $ERROR_COUNT
}
EOF
}

load_canary_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo '{"status": "none", "message": "No active canary deployment"}'
    fi
}

clear_canary_state() {
    rm -f "$STATE_FILE"
}

# Health check function
run_health_check() {
    local target_dir=$1
    local check_type=$2  # "quick" or "full"

    HEALTH_CHECKS=$((HEALTH_CHECKS + 1))

    HEALTHCHECK_SCRIPT="$(dirname "$0")/nwp-healthcheck.sh"

    if [ ! -f "$HEALTHCHECK_SCRIPT" ]; then
        print_warning "Health check script not found, skipping"
        return 0
    fi

    local quick_flag=""
    if [ "$check_type" = "quick" ]; then
        quick_flag="--quick"
    fi

    if [ "$VERBOSE" = true ]; then
        "$HEALTHCHECK_SCRIPT" --domain "$DOMAIN" $quick_flag "$target_dir"
    else
        "$HEALTHCHECK_SCRIPT" --domain "$DOMAIN" $quick_flag --json "$target_dir" > /dev/null 2>&1
    fi

    local result=$?

    if [ $result -ne 0 ]; then
        HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    return 0
}

# Performance check function
check_performance() {
    local target_dir=$1

    PERF_SCRIPT="$(dirname "$0")/nwp-perf-baseline.sh"

    if [ ! -f "$PERF_SCRIPT" ]; then
        print_warning "Performance baseline script not found, skipping"
        return 0
    fi

    print_info "Checking performance against baseline..."

    # Get current performance metrics
    local current_ttfb=$(curl -o /dev/null -s -w '%{time_starttransfer}\n' "http://$DOMAIN" | awk '{print int($1 * 1000)}')

    # Get baseline if it exists
    if [ -f "$BASELINE_DIR/latest.json" ]; then
        local baseline_ttfb=$(grep -oP '"ttfb":\s*\K[0-9]+' "$BASELINE_DIR/latest.json" || echo "0")

        if [ "$baseline_ttfb" -gt 0 ]; then
            local degradation=$(awk "BEGIN {print int((($current_ttfb - $baseline_ttfb) / $baseline_ttfb) * 100)}")

            if [ "$degradation" -gt "$PERF_THRESHOLD" ]; then
                print_error "Performance degradation detected: ${degradation}% slower than baseline"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                return 1
            else
                print_success "Performance acceptable (${degradation}% change from baseline)"
            fi
        fi
    else
        print_warning "No performance baseline found, skipping comparison"
    fi

    return 0
}

# Canary deployment functions
deploy_canary() {
    print_header "Canary Deployment"

    # Verify directories
    if [ ! -d "$PROD_DIR" ]; then
        print_error "Production directory not found: $PROD_DIR"
        exit 2
    fi

    if [ ! -d "$CANARY_DIR" ]; then
        print_error "Canary directory not found: $CANARY_DIR"
        print_info "Prepare canary code at: $CANARY_DIR"
        exit 2
    fi

    print_info "Starting canary deployment with ${CANARY_PERCENT}% traffic"
    print_info "Monitoring duration: ${DURATION}s"
    print_info "Check interval: ${CHECK_INTERVAL}s"
    echo ""

    # Initial health check on canary
    print_step "Validating Canary Environment"

    if ! run_health_check "$CANARY_DIR" "full"; then
        print_error "Canary environment failed initial health check"
        exit 1
    fi

    print_success "Canary environment is healthy"

    # Enable canary routing (placeholder - implement based on your infrastructure)
    print_step "Enabling Canary Routing"
    enable_canary_routing

    # Save state
    save_canary_state "active" "Canary deployment active at ${CANARY_PERCENT}%"

    # Monitor canary
    print_step "Monitoring Canary Deployment"
    monitor_canary

    local monitoring_result=$?

    if [ $monitoring_result -eq 0 ]; then
        print_success "Canary monitoring complete - no issues detected"

        if [ "$AUTO_PROMOTE" = true ]; then
            print_info "Auto-promoting canary to production..."
            promote_canary
        else
            print_info "Canary is healthy and ready for promotion"
            print_info "Run: $0 promote"
        fi
    else
        print_error "Canary monitoring detected issues"

        if [ "$AUTO_ROLLBACK" = true ]; then
            print_warning "Auto-rolling back canary..."
            rollback_canary
            exit 1
        else
            print_warning "Manual intervention required"
            print_info "Run: $0 rollback"
            exit 1
        fi
    fi
}

enable_canary_routing() {
    print_info "Configuring canary routing for ${CANARY_PERCENT}% traffic..."

    # This is a placeholder implementation
    # In production, you would configure:
    # 1. Nginx split_clients directive
    # 2. Load balancer weighted pools
    # 3. Service mesh traffic splitting (Istio, Linkerd)
    # 4. DNS-based routing

    # Example Nginx configuration that would be generated:
    # split_clients "${remote_addr}${http_user_agent}" $backend {
    #   10%     canary;
    #   *       production;
    # }

    # For now, create a marker file
    echo "$CANARY_PERCENT" > "$WEBROOT_PARENT/.canary_routing"

    print_success "Canary routing enabled (${CANARY_PERCENT}% traffic)"
    print_warning "Note: Actual traffic splitting requires Nginx/LB configuration"
}

disable_canary_routing() {
    print_info "Disabling canary routing..."

    rm -f "$WEBROOT_PARENT/.canary_routing"

    print_success "Canary routing disabled"
}

monitor_canary() {
    local total_checks=$((DURATION / CHECK_INTERVAL))

    print_info "Running $total_checks health checks over ${DURATION}s..."
    echo ""

    for ((i=1; i<=total_checks; i++)); do
        local elapsed=$((i * CHECK_INTERVAL))
        local remaining=$((DURATION - elapsed))

        echo -ne "${CYAN}[${i}/${total_checks}]${NC} Check at ${elapsed}s (${remaining}s remaining): "

        # Run health check on production (which includes canary traffic)
        if run_health_check "$PROD_DIR" "quick"; then
            echo -e "${GREEN}HEALTHY${NC}"

            # Also check performance
            if check_performance "$PROD_DIR"; then
                # Performance is good
                :
            else
                echo -e "  ${YELLOW}Performance degradation detected${NC}"
            fi
        else
            echo -e "${RED}UNHEALTHY${NC}"

            # Check if we've exceeded error threshold
            if [ $ERROR_COUNT -ge $ERROR_THRESHOLD ]; then
                print_error "Error threshold exceeded ($ERROR_COUNT >= $ERROR_THRESHOLD)"
                return 1
            fi
        fi

        # Update state
        save_canary_state "monitoring" "Health checks: $HEALTH_CHECKS, Failures: $HEALTH_FAILURES"

        # Sleep until next check (unless it's the last one)
        if [ $i -lt $total_checks ]; then
            sleep $CHECK_INTERVAL
        fi
    done

    echo ""

    # Evaluate overall health
    local failure_rate=$((HEALTH_FAILURES * 100 / HEALTH_CHECKS))

    print_info "Monitoring Summary:"
    echo "  Total Checks: $HEALTH_CHECKS"
    echo "  Failures: $HEALTH_FAILURES"
    echo "  Failure Rate: ${failure_rate}%"
    echo "  Errors: $ERROR_COUNT"
    echo ""

    if [ $ERROR_COUNT -ge $ERROR_THRESHOLD ]; then
        print_error "Too many errors during canary monitoring"
        return 1
    fi

    if [ $failure_rate -gt 10 ]; then
        print_error "Failure rate too high (${failure_rate}% > 10%)"
        return 1
    fi

    return 0
}

promote_canary() {
    print_header "Promoting Canary to Production"

    # Verify canary is active
    local state=$(load_canary_state | grep -oP '"status":\s*"\K[^"]+' || echo "none")

    if [ "$state" = "none" ]; then
        print_error "No active canary deployment found"
        exit 2
    fi

    # Disable canary routing first
    disable_canary_routing

    # Swap canary to production
    print_info "Swapping canary to production..."

    TEMP_DIR="$WEBROOT_PARENT/.promote_temp_$$"

    # Move current prod to temp
    sudo mv "$PROD_DIR" "$TEMP_DIR"

    # Move canary to prod
    sudo mv "$CANARY_DIR" "$PROD_DIR"

    # Move old prod to canary slot
    sudo mv "$TEMP_DIR" "$CANARY_DIR"

    print_success "Canary promoted to production"

    # Fix permissions
    print_info "Setting permissions..."
    sudo chown -R www-data:www-data "$PROD_DIR"
    sudo chown -R www-data:www-data "$CANARY_DIR"

    # Clear caches
    print_info "Clearing caches..."
    if [ -f "$PROD_DIR/vendor/bin/drush" ]; then
        cd "$PROD_DIR"
        sudo -u www-data ./vendor/bin/drush cr || print_warning "Cache clear failed"
    fi

    # Final health check
    print_info "Running final health check..."
    if run_health_check "$PROD_DIR" "full"; then
        print_success "Production is healthy after promotion"
    else
        print_warning "Production health check failed - manual verification recommended"
    fi

    # Log promotion
    echo "$(date -Iseconds) - CANARY PROMOTED: canary → prod (${CANARY_PERCENT}% for ${DURATION}s)" | sudo tee -a "$LOG_DIR/deployments.log" > /dev/null

    # Clear state
    clear_canary_state

    print_header "Canary Promotion Complete!"
    print_success "Canary successfully promoted to production"
}

rollback_canary() {
    print_header "Rolling Back Canary Deployment"

    # Disable canary routing
    disable_canary_routing

    # Log rollback
    echo "$(date -Iseconds) - CANARY ROLLBACK: Errors: $ERROR_COUNT, Failures: $HEALTH_FAILURES/$HEALTH_CHECKS" | sudo tee -a "$LOG_DIR/deployments.log" > /dev/null

    # Clear state
    clear_canary_state

    print_success "Canary deployment rolled back"
    print_info "Production remains on stable version"
}

show_status() {
    print_header "Canary Deployment Status"

    local state=$(load_canary_state)

    echo "$state" | python3 -m json.tool 2>/dev/null || echo "$state"

    echo ""

    # Check for routing file
    if [ -f "$WEBROOT_PARENT/.canary_routing" ]; then
        local percent=$(cat "$WEBROOT_PARENT/.canary_routing")
        print_info "Canary routing active: ${percent}% traffic"
    else
        print_info "No canary routing active"
    fi
}

# Parse arguments
COMMAND="${1:-}"
shift || true

while [[ $# -gt 0 ]]; do
    case $1 in
        --webroot)
            WEBROOT_PARENT="$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --percent)
            CANARY_PERCENT="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --check-interval)
            CHECK_INTERVAL="$2"
            shift 2
            ;;
        --error-threshold)
            ERROR_THRESHOLD="$2"
            shift 2
            ;;
        --perf-threshold)
            PERF_THRESHOLD="$2"
            shift 2
            ;;
        --auto-promote)
            AUTO_PROMOTE=true
            shift
            ;;
        --auto-rollback)
            AUTO_ROLLBACK=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 2
            ;;
    esac
done

# Detect domain if not specified
if [ -z "$DOMAIN" ]; then
    NGINX_CONF="/etc/nginx/sites-enabled/default"
    if [ -f "$NGINX_CONF" ]; then
        DOMAIN=$(grep -m 1 "server_name" "$NGINX_CONF" | awk '{print $2}' | sed 's/;//')
    fi

    if [ -z "$DOMAIN" ]; then
        DOMAIN="localhost"
    fi
fi

# Update directory paths after parsing
PROD_DIR="$WEBROOT_PARENT/prod"
CANARY_DIR="$WEBROOT_PARENT/canary"

# Execute command
case "$COMMAND" in
    deploy)
        deploy_canary
        ;;
    promote)
        promote_canary
        ;;
    rollback)
        rollback_canary
        ;;
    status)
        show_status
        ;;
    "")
        print_error "No command specified"
        echo ""
        echo "Usage: $0 {deploy|promote|rollback|status} [OPTIONS]"
        echo "Run '$0 --help' for more information"
        exit 2
        ;;
    *)
        print_error "Unknown command: $COMMAND"
        exit 2
        ;;
esac

exit 0
