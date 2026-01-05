#!/bin/bash

################################################################################
# nwp-perf-baseline.sh - Performance Baseline Tracking for NWP Deployments
################################################################################
#
# Captures and stores performance baselines after deployments to track
# performance trends and detect regressions.
#
# Tracks key performance metrics:
#   - Page load time (total request time)
#   - Time to First Byte (TTFB)
#   - Database query time
#   - Response sizes
#   - Cache hit rates
#
# Baselines are stored in /var/log/nwp/baselines/ for historical comparison.
# Alerts if new deployment shows >20% regression from previous baseline.
#
# Usage:
#   ./nwp-perf-baseline.sh [COMMAND] [OPTIONS]
#
# Commands:
#   capture             Capture current performance baseline
#   compare             Compare current performance to baseline
#   list                List stored baselines
#   show                Show specific baseline
#
# Options:
#   --site-dir DIR       Site directory (default: /var/www/prod)
#   --domain DOMAIN      Domain to test (required for capture)
#   --baseline NAME      Baseline name (default: timestamp)
#   --set-latest         Mark this baseline as latest
#   --threshold N        Regression threshold percentage (default: 20)
#   --samples N          Number of samples to average (default: 5)
#   --output FORMAT      Output format: text|json (default: text)
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
# Exit Codes:
#   0 - Success (or performance within threshold)
#   1 - Performance regression detected
#   2 - Invalid arguments or configuration error
#
# Examples:
#   # Capture baseline after deployment
#   ./nwp-perf-baseline.sh capture --domain example.com --set-latest
#
#   # Compare current performance to baseline
#   ./nwp-perf-baseline.sh compare --domain example.com --threshold 20
#
#   # List all baselines
#   ./nwp-perf-baseline.sh list
#
#   # Show specific baseline
#   ./nwp-perf-baseline.sh show --baseline 20260105_120000
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
SITE_DIR="/var/www/prod"
DOMAIN=""
BASELINE_NAME=""
SET_LATEST=false
THRESHOLD=20
SAMPLES=5
OUTPUT_FORMAT="text"
VERBOSE=false

# Directories
LOG_DIR="/var/log/nwp"
BASELINE_DIR="$LOG_DIR/baselines"

# Performance metrics
declare -A METRICS

# Helper functions
print_header() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}${BOLD}  $1${NC}"
        echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
    fi
}

print_info() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo -e "${BLUE}INFO:${NC} $1"
    fi
}

print_success() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo -e "${GREEN}✓${NC} $1"
    fi
}

print_warning() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo -e "${YELLOW}!${NC} $1"
    fi
}

print_error() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo -e "${RED}ERROR:${NC} $1"
    fi
}

# Ensure baseline directory exists
mkdir -p "$BASELINE_DIR"

# Measure page performance using curl
measure_http_performance() {
    local url=$1
    local sample_num=$2

    if [ "$VERBOSE" = true ]; then
        print_info "Sample $sample_num: Measuring $url"
    fi

    # Use curl with timing information
    local curl_format='
{
  "time_namelookup": %{time_namelookup},
  "time_connect": %{time_connect},
  "time_appconnect": %{time_appconnect},
  "time_pretransfer": %{time_pretransfer},
  "time_redirect": %{time_redirect},
  "time_starttransfer": %{time_starttransfer},
  "time_total": %{time_total},
  "size_download": %{size_download},
  "size_header": %{size_header},
  "speed_download": %{speed_download},
  "http_code": %{http_code}
}
'

    local result=$(curl -o /dev/null -s -w "$curl_format" "$url" 2>/dev/null || echo '{}')

    echo "$result"
}

# Measure database performance
measure_database_performance() {
    local site_dir=$1

    if [ ! -f "$site_dir/vendor/bin/drush" ]; then
        echo '{"query_time": 0, "error": "drush not found"}'
        return
    fi

    cd "$site_dir"

    # Simple query time measurement
    local start=$(date +%s%N)
    sudo -u www-data ./vendor/bin/drush sqlq "SELECT 1;" > /dev/null 2>&1 || true
    local end=$(date +%s%N)

    local query_time=$(( (end - start) / 1000000 ))  # Convert to milliseconds

    echo "{\"query_time\": $query_time}"
}

# Capture performance baseline
capture_baseline() {
    print_header "Capturing Performance Baseline"

    if [ -z "$DOMAIN" ]; then
        print_error "Domain required for baseline capture"
        echo "Use: --domain example.com"
        exit 2
    fi

    # Generate baseline name if not specified
    if [ -z "$BASELINE_NAME" ]; then
        BASELINE_NAME=$(date +%Y%m%d_%H%M%S)
    fi

    local baseline_file="$BASELINE_DIR/${BASELINE_NAME}.json"

    print_info "Capturing baseline: $BASELINE_NAME"
    print_info "Domain: $DOMAIN"
    print_info "Samples: $SAMPLES"
    echo ""

    # Test URLs
    local urls=(
        "https://$DOMAIN/"
        "https://$DOMAIN/user/login"
    )

    # Add additional test pages if they exist
    if curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN/node/1" 2>/dev/null | grep -q "200"; then
        urls+=("https://$DOMAIN/node/1")
    fi

    # Initialize metrics arrays
    declare -a ttfb_samples=()
    declare -a total_time_samples=()
    declare -a download_size_samples=()

    # Collect samples
    print_info "Collecting performance samples..."

    for ((i=1; i<=SAMPLES; i++)); do
        echo -n "  Sample $i/$SAMPLES: "

        for url in "${urls[@]}"; do
            local metrics=$(measure_http_performance "$url" "$i")

            # Extract metrics
            local ttfb=$(echo "$metrics" | grep -oP '"time_starttransfer":\s*\K[0-9.]+' || echo "0")
            local total=$(echo "$metrics" | grep -oP '"time_total":\s*\K[0-9.]+' || echo "0")
            local size=$(echo "$metrics" | grep -oP '"size_download":\s*\K[0-9.]+' || echo "0")

            # Convert to milliseconds
            ttfb=$(awk "BEGIN {print int($ttfb * 1000)}")
            total=$(awk "BEGIN {print int($total * 1000)}")

            ttfb_samples+=("$ttfb")
            total_time_samples+=("$total")
            download_size_samples+=("$size")
        done

        echo -e "${GREEN}✓${NC}"

        # Small delay between samples
        sleep 1
    done

    # Calculate averages
    local sum_ttfb=0
    local sum_total=0
    local sum_size=0

    for val in "${ttfb_samples[@]}"; do
        sum_ttfb=$((sum_ttfb + val))
    done

    for val in "${total_time_samples[@]}"; do
        sum_total=$((sum_total + val))
    done

    for val in "${download_size_samples[@]}"; do
        sum_size=$((sum_size + val))
    done

    local count=${#ttfb_samples[@]}
    local avg_ttfb=$((sum_ttfb / count))
    local avg_total=$((sum_total / count))
    local avg_size=$((sum_size / count))

    # Measure database performance
    print_info "Measuring database performance..."
    local db_metrics=$(measure_database_performance "$SITE_DIR")
    local db_query_time=$(echo "$db_metrics" | grep -oP '"query_time":\s*\K[0-9]+' || echo "0")

    # Calculate min/max/stddev for TTFB
    local min_ttfb=${ttfb_samples[0]}
    local max_ttfb=${ttfb_samples[0]}

    for val in "${ttfb_samples[@]}"; do
        if [ "$val" -lt "$min_ttfb" ]; then
            min_ttfb=$val
        fi
        if [ "$val" -gt "$max_ttfb" ]; then
            max_ttfb=$val
        fi
    done

    # Store baseline
    cat > "$baseline_file" <<EOF
{
  "name": "$BASELINE_NAME",
  "timestamp": "$(date -Iseconds)",
  "domain": "$DOMAIN",
  "site_dir": "$SITE_DIR",
  "samples": $SAMPLES,
  "metrics": {
    "ttfb": $avg_ttfb,
    "ttfb_min": $min_ttfb,
    "ttfb_max": $max_ttfb,
    "total_time": $avg_total,
    "download_size": $avg_size,
    "db_query_time": $db_query_time
  },
  "raw_samples": {
    "ttfb": [$(IFS=,; echo "${ttfb_samples[*]}")],
    "total_time": [$(IFS=,; echo "${total_time_samples[*]}")],
    "download_size": [$(IFS=,; echo "${download_size_samples[*]}")]
  }
}
EOF

    # Set as latest if requested
    if [ "$SET_LATEST" = true ]; then
        ln -sf "${BASELINE_NAME}.json" "$BASELINE_DIR/latest.json"
        print_info "Set as latest baseline"
    fi

    print_success "Baseline captured: $baseline_file"
    echo ""

    # Display results
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        print_header "Performance Baseline Results"
        echo "Baseline: $BASELINE_NAME"
        echo "Timestamp: $(date -Iseconds)"
        echo ""
        echo "Metrics (averaged over $SAMPLES samples):"
        echo "  Time to First Byte (TTFB): ${avg_ttfb}ms"
        echo "    Min: ${min_ttfb}ms, Max: ${max_ttfb}ms"
        echo "  Total Request Time: ${avg_total}ms"
        echo "  Download Size: ${avg_size} bytes"
        echo "  Database Query Time: ${db_query_time}ms"
        echo ""
    else
        cat "$baseline_file"
    fi
}

# Compare current performance to baseline
compare_performance() {
    print_header "Performance Comparison"

    if [ -z "$DOMAIN" ]; then
        print_error "Domain required for performance comparison"
        exit 2
    fi

    # Find baseline to compare against
    local baseline_file="$BASELINE_DIR/latest.json"

    if [ -n "$BASELINE_NAME" ]; then
        baseline_file="$BASELINE_DIR/${BASELINE_NAME}.json"
    fi

    if [ ! -f "$baseline_file" ]; then
        print_error "Baseline not found: $baseline_file"
        exit 2
    fi

    print_info "Comparing against baseline: $(basename "$baseline_file" .json)"
    echo ""

    # Load baseline metrics
    local baseline_ttfb=$(grep -oP '"ttfb":\s*\K[0-9]+' "$baseline_file" || echo "0")
    local baseline_total=$(grep -oP '"total_time":\s*\K[0-9]+' "$baseline_file" || echo "0")
    local baseline_db=$(grep -oP '"db_query_time":\s*\K[0-9]+' "$baseline_file" || echo "0")

    # Measure current performance
    print_info "Measuring current performance..."

    local current_metrics=$(measure_http_performance "https://$DOMAIN/" "1")
    local current_ttfb=$(echo "$current_metrics" | grep -oP '"time_starttransfer":\s*\K[0-9.]+' || echo "0")
    local current_total=$(echo "$current_metrics" | grep -oP '"time_total":\s*\K[0-9.]+' || echo "0")

    # Convert to milliseconds
    current_ttfb=$(awk "BEGIN {print int($current_ttfb * 1000)}")
    current_total=$(awk "BEGIN {print int($current_total * 1000)}")

    # Measure current database performance
    local current_db_metrics=$(measure_database_performance "$SITE_DIR")
    local current_db=$(echo "$current_db_metrics" | grep -oP '"query_time":\s*\K[0-9]+' || echo "0")

    # Calculate differences
    local ttfb_diff=0
    local total_diff=0
    local db_diff=0
    local has_regression=false

    if [ "$baseline_ttfb" -gt 0 ]; then
        ttfb_diff=$(awk "BEGIN {print int((($current_ttfb - $baseline_ttfb) / $baseline_ttfb) * 100)}")
    fi

    if [ "$baseline_total" -gt 0 ]; then
        total_diff=$(awk "BEGIN {print int((($current_total - $baseline_total) / $baseline_total) * 100)}")
    fi

    if [ "$baseline_db" -gt 0 ]; then
        db_diff=$(awk "BEGIN {print int((($current_db - $baseline_db) / $baseline_db) * 100)}")
    fi

    # Display comparison
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo "Metric                    Baseline    Current     Change"
        echo "────────────────────────────────────────────────────────"

        # TTFB
        printf "Time to First Byte        %6dms   %6dms   " "$baseline_ttfb" "$current_ttfb"
        if [ "$ttfb_diff" -gt "$THRESHOLD" ]; then
            echo -e "${RED}+${ttfb_diff}% ↑ REGRESSION${NC}"
            has_regression=true
        elif [ "$ttfb_diff" -lt "-$THRESHOLD" ]; then
            echo -e "${GREEN}${ttfb_diff}% ↓ IMPROVED${NC}"
        else
            echo -e "${ttfb_diff}%"
        fi

        # Total Time
        printf "Total Request Time        %6dms   %6dms   " "$baseline_total" "$current_total"
        if [ "$total_diff" -gt "$THRESHOLD" ]; then
            echo -e "${RED}+${total_diff}% ↑ REGRESSION${NC}"
            has_regression=true
        elif [ "$total_diff" -lt "-$THRESHOLD" ]; then
            echo -e "${GREEN}${total_diff}% ↓ IMPROVED${NC}"
        else
            echo -e "${total_diff}%"
        fi

        # Database Query Time
        printf "Database Query Time       %6dms   %6dms   " "$baseline_db" "$current_db"
        if [ "$db_diff" -gt "$THRESHOLD" ]; then
            echo -e "${RED}+${db_diff}% ↑ REGRESSION${NC}"
            has_regression=true
        elif [ "$db_diff" -lt "-$THRESHOLD" ]; then
            echo -e "${GREEN}${db_diff}% ↓ IMPROVED${NC}"
        else
            echo -e "${db_diff}%"
        fi

        echo ""

        if [ "$has_regression" = true ]; then
            print_error "Performance regression detected (threshold: ${THRESHOLD}%)"
            exit 1
        else
            print_success "Performance within acceptable range"
        fi
    else
        # JSON output
        cat <<EOF
{
  "baseline": {
    "ttfb": $baseline_ttfb,
    "total_time": $baseline_total,
    "db_query_time": $baseline_db
  },
  "current": {
    "ttfb": $current_ttfb,
    "total_time": $current_total,
    "db_query_time": $current_db
  },
  "change_percent": {
    "ttfb": $ttfb_diff,
    "total_time": $total_diff,
    "db_query_time": $db_diff
  },
  "threshold": $THRESHOLD,
  "regression_detected": $has_regression
}
EOF
        if [ "$has_regression" = true ]; then
            exit 1
        fi
    fi
}

# List all baselines
list_baselines() {
    print_header "Stored Performance Baselines"

    if [ ! -d "$BASELINE_DIR" ] || [ -z "$(ls -A "$BASELINE_DIR" 2>/dev/null)" ]; then
        print_info "No baselines found in $BASELINE_DIR"
        exit 0
    fi

    echo "Name                      Timestamp                    TTFB      Total"
    echo "────────────────────────────────────────────────────────────────────────"

    for file in "$BASELINE_DIR"/*.json; do
        if [ -f "$file" ] && [ "$(basename "$file")" != "latest.json" ]; then
            local name=$(basename "$file" .json)
            local timestamp=$(grep -oP '"timestamp":\s*"\K[^"]+' "$file" || echo "N/A")
            local ttfb=$(grep -oP '"ttfb":\s*\K[0-9]+' "$file" || echo "0")
            local total=$(grep -oP '"total_time":\s*\K[0-9]+' "$file" || echo "0")

            printf "%-25s %-28s %6dms  %6dms" "$name" "$timestamp" "$ttfb" "$total"

            # Check if this is the latest
            if [ -L "$BASELINE_DIR/latest.json" ]; then
                local latest=$(readlink "$BASELINE_DIR/latest.json")
                if [ "$(basename "$file")" = "$latest" ]; then
                    echo -e "  ${GREEN}[LATEST]${NC}"
                else
                    echo ""
                fi
            else
                echo ""
            fi
        fi
    done
}

# Show specific baseline
show_baseline() {
    if [ -z "$BASELINE_NAME" ]; then
        print_error "Baseline name required"
        echo "Use: --baseline NAME"
        exit 2
    fi

    local baseline_file="$BASELINE_DIR/${BASELINE_NAME}.json"

    if [ ! -f "$baseline_file" ]; then
        print_error "Baseline not found: $baseline_file"
        exit 2
    fi

    if [ "$OUTPUT_FORMAT" = "json" ]; then
        cat "$baseline_file"
    else
        print_header "Performance Baseline: $BASELINE_NAME"
        cat "$baseline_file" | python3 -m json.tool 2>/dev/null || cat "$baseline_file"
    fi
}

# Parse arguments
COMMAND="${1:-}"
shift || true

while [[ $# -gt 0 ]]; do
    case $1 in
        --site-dir)
            SITE_DIR="$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --baseline)
            BASELINE_NAME="$2"
            shift 2
            ;;
        --set-latest)
            SET_LATEST=true
            shift
            ;;
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        --samples)
            SAMPLES="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FORMAT="$2"
            shift 2
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

# Execute command
case "$COMMAND" in
    capture)
        capture_baseline
        ;;
    compare)
        compare_performance
        ;;
    list)
        list_baselines
        ;;
    show)
        show_baseline
        ;;
    "")
        print_error "No command specified"
        echo ""
        echo "Usage: $0 {capture|compare|list|show} [OPTIONS]"
        echo "Run '$0 --help' for more information"
        exit 2
        ;;
    *)
        print_error "Unknown command: $COMMAND"
        exit 2
        ;;
esac

exit 0
