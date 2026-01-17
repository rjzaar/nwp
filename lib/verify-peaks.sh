#!/bin/bash
################################################################################
# NWP Peak Badge System Library
#
# Part of P51: AI-Powered Deep Verification (Phase 7)
#
# This library tracks peak (best) verification coverage metrics over time.
# It maintains historical records of coverage highs, generates extended badges
# showing both current and peak values, and provides trend analysis.
#
# Key Features:
#   - Peak detection and recording
#   - Extended badges (current + peak)
#   - Peak history tracking
#   - Trend analysis
#
# Source this file: source "$PROJECT_ROOT/lib/verify-peaks.sh"
#
# Reference:
#   - P51: AI-Powered Deep Verification
#   - docs/proposals/P51-ai-powered-verification.md
################################################################################

# Determine paths
PEAKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PEAKS_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$PEAKS_LIB_DIR/.." && pwd)}"

# Make PROJECT_ROOT available if not set
PROJECT_ROOT="${PROJECT_ROOT:-$PEAKS_PROJECT_ROOT}"

# Configuration
PEAKS_FILE="${PEAKS_FILE:-$PEAKS_PROJECT_ROOT/.verification-peaks.yml}"
PEAKS_BADGES_DIR="${PEAKS_BADGES_DIR:-$PEAKS_PROJECT_ROOT/.verification-badges}"
PEAKS_HISTORY_MAX="${PEAKS_HISTORY_MAX:-10}"

################################################################################
# SECTION 1: Initialization
################################################################################

#######################################
# Initialize peaks system
#######################################
peaks_init() {
    mkdir -p "$PEAKS_BADGES_DIR"

    if [[ ! -f "$PEAKS_FILE" ]]; then
        peaks_create_file
    fi
}

#######################################
# Create initial peaks file
#######################################
peaks_create_file() {
    local timestamp
    timestamp=$(date -Iseconds)

    cat > "$PEAKS_FILE" << EOF
# NWP Verification Peaks
# Tracks best verification coverage achieved over time
# DO NOT EDIT MANUALLY - managed by P51 verify-peaks.sh

peaks:
  machine_coverage:
    current: 0
    peak: 0
    peak_achieved_at: null
    peak_run_id: null

  ai_coverage:
    current: 0
    peak: 0
    peak_achieved_at: null
    peak_run_id: null

  scenarios_passed:
    current: 0
    peak: 0
    peak_achieved_at: null
    peak_run_id: null

  items_verified:
    current: 0
    peak: 0
    peak_achieved_at: null
    peak_run_id: null

  average_confidence:
    current: 0
    peak: 0
    peak_achieved_at: null
    peak_run_id: null

history:
  # Last $PEAKS_HISTORY_MAX changes tracked
  changes: []

metadata:
  created_at: "$timestamp"
  last_updated: "$timestamp"
  total_runs_tracked: 0
EOF
}

#######################################
# Check if yq is available
#######################################
peaks_check_yq() {
    if ! command -v yq &>/dev/null; then
        echo "ERROR: yq is required for peaks management." >&2
        return 1
    fi
    return 0
}

################################################################################
# SECTION 2: Peak Detection and Recording
################################################################################

#######################################
# Update current values and check for new peaks
# Arguments:
#   $1 - Machine coverage percentage
#   $2 - AI coverage percentage
#   $3 - Scenarios passed count
#   $4 - Items verified count
#   $5 - Average confidence percentage
#   $6 - Run ID (optional)
# Returns: Number of new peaks detected
#######################################
peaks_update() {
    local machine_coverage="${1:-0}"
    local ai_coverage="${2:-0}"
    local scenarios_passed="${3:-0}"
    local items_verified="${4:-0}"
    local avg_confidence="${5:-0}"
    local run_id="${6:-unknown}"

    peaks_init

    local timestamp
    timestamp=$(date -Iseconds)
    local new_peaks=0
    local changes=()

    # Update current values
    yq -i "
        .peaks.machine_coverage.current = $machine_coverage |
        .peaks.ai_coverage.current = $ai_coverage |
        .peaks.scenarios_passed.current = $scenarios_passed |
        .peaks.items_verified.current = $items_verified |
        .peaks.average_confidence.current = $avg_confidence |
        .metadata.last_updated = \"$timestamp\" |
        .metadata.total_runs_tracked += 1
    " "$PEAKS_FILE"

    # Check each metric for new peak
    # Machine coverage
    local old_peak
    old_peak=$(yq '.peaks.machine_coverage.peak' "$PEAKS_FILE")
    if [[ $machine_coverage -gt $old_peak ]]; then
        yq -i "
            .peaks.machine_coverage.peak = $machine_coverage |
            .peaks.machine_coverage.peak_achieved_at = \"$timestamp\" |
            .peaks.machine_coverage.peak_run_id = \"$run_id\"
        " "$PEAKS_FILE"
        ((new_peaks++))
        changes+=("machine_coverage: $old_peak -> $machine_coverage")
        echo "  New peak: Machine coverage $old_peak% -> $machine_coverage%"
    fi

    # AI coverage
    old_peak=$(yq '.peaks.ai_coverage.peak' "$PEAKS_FILE")
    if [[ $ai_coverage -gt $old_peak ]]; then
        yq -i "
            .peaks.ai_coverage.peak = $ai_coverage |
            .peaks.ai_coverage.peak_achieved_at = \"$timestamp\" |
            .peaks.ai_coverage.peak_run_id = \"$run_id\"
        " "$PEAKS_FILE"
        ((new_peaks++))
        changes+=("ai_coverage: $old_peak -> $ai_coverage")
        echo "  New peak: AI coverage $old_peak% -> $ai_coverage%"
    fi

    # Scenarios passed
    old_peak=$(yq '.peaks.scenarios_passed.peak' "$PEAKS_FILE")
    if [[ $scenarios_passed -gt $old_peak ]]; then
        yq -i "
            .peaks.scenarios_passed.peak = $scenarios_passed |
            .peaks.scenarios_passed.peak_achieved_at = \"$timestamp\" |
            .peaks.scenarios_passed.peak_run_id = \"$run_id\"
        " "$PEAKS_FILE"
        ((new_peaks++))
        changes+=("scenarios_passed: $old_peak -> $scenarios_passed")
        echo "  New peak: Scenarios passed $old_peak -> $scenarios_passed"
    fi

    # Items verified
    old_peak=$(yq '.peaks.items_verified.peak' "$PEAKS_FILE")
    if [[ $items_verified -gt $old_peak ]]; then
        yq -i "
            .peaks.items_verified.peak = $items_verified |
            .peaks.items_verified.peak_achieved_at = \"$timestamp\" |
            .peaks.items_verified.peak_run_id = \"$run_id\"
        " "$PEAKS_FILE"
        ((new_peaks++))
        changes+=("items_verified: $old_peak -> $items_verified")
        echo "  New peak: Items verified $old_peak -> $items_verified"
    fi

    # Average confidence
    old_peak=$(yq '.peaks.average_confidence.peak' "$PEAKS_FILE")
    if [[ $avg_confidence -gt $old_peak ]]; then
        yq -i "
            .peaks.average_confidence.peak = $avg_confidence |
            .peaks.average_confidence.peak_achieved_at = \"$timestamp\" |
            .peaks.average_confidence.peak_run_id = \"$run_id\"
        " "$PEAKS_FILE"
        ((new_peaks++))
        changes+=("average_confidence: $old_peak -> $avg_confidence")
        echo "  New peak: Average confidence $old_peak% -> $avg_confidence%"
    fi

    # Record in history if there were changes
    if [[ ${#changes[@]} -gt 0 ]]; then
        local change_str
        change_str=$(printf '%s; ' "${changes[@]}")
        yq -i "
            .history.changes = [{
                \"timestamp\": \"$timestamp\",
                \"run_id\": \"$run_id\",
                \"changes\": \"${change_str%;*}\"
            }] + .history.changes |
            .history.changes |= .[0:$PEAKS_HISTORY_MAX]
        " "$PEAKS_FILE"
    fi

    return $new_peaks
}

#######################################
# Update peaks from checkpoint data
# Arguments:
#   $1 - Path to checkpoint file (optional)
#######################################
peaks_update_from_checkpoint() {
    local checkpoint_file="${1:-$PEAKS_PROJECT_ROOT/.verification-checkpoint.yml}"

    if [[ ! -f "$checkpoint_file" ]]; then
        echo "No checkpoint file found"
        return 1
    fi

    # Extract values from checkpoint
    local run_id ai_coverage scenarios_passed items_verified avg_confidence

    run_id=$(yq -r '.checkpoint.run_id // "unknown"' "$checkpoint_file")
    scenarios_passed=$(yq '.checkpoint.completed_scenarios | length // 0' "$checkpoint_file")
    items_verified=$(yq '.checkpoint.progress.items.verified // 0' "$checkpoint_file")
    ai_coverage=$((items_verified * 100 / 471))

    # Calculate average confidence (handle empty scenarios gracefully)
    avg_confidence=0
    local conf_values
    conf_values=$(yq -r '.checkpoint.completed_scenarios[].confidence' "$checkpoint_file" 2>/dev/null)
    if [[ -n "$conf_values" ]]; then
        local sum=0 count=0
        for conf in $conf_values; do
            sum=$((sum + conf))
            count=$((count + 1))
        done
        [[ $count -gt 0 ]] && avg_confidence=$((sum / count))
    fi

    # Get machine coverage from verification system if available
    local machine_coverage=0
    if [[ -f "$PEAKS_PROJECT_ROOT/.verification-results.yml" ]]; then
        machine_coverage=$(yq '.results.coverage_percentage // 0' "$PEAKS_PROJECT_ROOT/.verification-results.yml" 2>/dev/null || echo "0")
    fi

    echo "Updating peaks from checkpoint: $run_id"
    peaks_update "$machine_coverage" "$ai_coverage" "$scenarios_passed" "$items_verified" "$avg_confidence" "$run_id"
}

################################################################################
# SECTION 3: Peak Queries
################################################################################

#######################################
# Get current values
# Outputs: JSON with current values
#######################################
peaks_get_current() {
    if [[ ! -f "$PEAKS_FILE" ]]; then
        echo '{"machine_coverage": 0, "ai_coverage": 0, "scenarios_passed": 0}'
        return
    fi

    yq -o=json '{
        machine_coverage: .peaks.machine_coverage.current,
        ai_coverage: .peaks.ai_coverage.current,
        scenarios_passed: .peaks.scenarios_passed.current,
        items_verified: .peaks.items_verified.current,
        average_confidence: .peaks.average_confidence.current
    }' "$PEAKS_FILE"
}

#######################################
# Get peak values
# Outputs: JSON with peak values
#######################################
peaks_get_peaks() {
    if [[ ! -f "$PEAKS_FILE" ]]; then
        echo '{"machine_coverage": 0, "ai_coverage": 0, "scenarios_passed": 0}'
        return
    fi

    yq -o=json '{
        machine_coverage: .peaks.machine_coverage.peak,
        ai_coverage: .peaks.ai_coverage.peak,
        scenarios_passed: .peaks.scenarios_passed.peak,
        items_verified: .peaks.items_verified.peak,
        average_confidence: .peaks.average_confidence.peak
    }' "$PEAKS_FILE"
}

#######################################
# Get peak details for a specific metric
# Arguments:
#   $1 - Metric name (machine_coverage, ai_coverage, etc.)
# Outputs: JSON with peak details
#######################################
peaks_get_metric() {
    local metric="$1"

    if [[ ! -f "$PEAKS_FILE" ]]; then
        echo '{"current": 0, "peak": 0}'
        return
    fi

    yq -o=json ".peaks.$metric" "$PEAKS_FILE"
}

#######################################
# Get history of peak changes
# Outputs: List of historical changes
#######################################
peaks_get_history() {
    if [[ ! -f "$PEAKS_FILE" ]]; then
        echo '[]'
        return
    fi

    yq -o=json '.history.changes' "$PEAKS_FILE"
}

################################################################################
# SECTION 4: Extended Badge Generation
################################################################################

#######################################
# Generate extended badge showing current + peak
# Arguments:
#   $1 - Metric type (machine|ai)
#######################################
peaks_generate_extended_badge() {
    local metric_type="${1:-ai}"

    peaks_init

    local current peak color_current color_peak
    local label badge_file

    case "$metric_type" in
        machine)
            current=$(yq '.peaks.machine_coverage.current' "$PEAKS_FILE")
            peak=$(yq '.peaks.machine_coverage.peak' "$PEAKS_FILE")
            label="Machine"
            badge_file="$PEAKS_BADGES_DIR/machine-extended.svg"
            ;;
        ai)
            current=$(yq '.peaks.ai_coverage.current' "$PEAKS_FILE")
            peak=$(yq '.peaks.ai_coverage.peak' "$PEAKS_FILE")
            label="AI Coverage"
            badge_file="$PEAKS_BADGES_DIR/ai-extended.svg"
            ;;
        *)
            echo "Unknown metric type: $metric_type"
            return 1
            ;;
    esac

    # Determine colors
    if [[ $current -ge 90 ]]; then
        color_current="#28a745"
    elif [[ $current -ge 70 ]]; then
        color_current="#ffc107"
    elif [[ $current -ge 50 ]]; then
        color_current="#fd7e14"
    else
        color_current="#dc3545"
    fi

    color_peak="#6c757d"  # Gray for peak

    # Generate SVG
    cat > "$badge_file" << EOF
<svg xmlns="http://www.w3.org/2000/svg" width="180" height="20">
  <linearGradient id="b" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <mask id="a">
    <rect width="180" height="20" rx="3" fill="#fff"/>
  </mask>
  <g mask="url(#a)">
    <path fill="#555" d="M0 0h75v20H0z"/>
    <path fill="$color_current" d="M75 0h50v20H75z"/>
    <path fill="$color_peak" d="M125 0h55v20H125z"/>
    <path fill="url(#b)" d="M0 0h180v20H0z"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="DejaVu Sans,Verdana,Geneva,sans-serif" font-size="11">
    <text x="37.5" y="15" fill="#010101" fill-opacity=".3">$label</text>
    <text x="37.5" y="14">$label</text>
    <text x="100" y="15" fill="#010101" fill-opacity=".3">${current}%</text>
    <text x="100" y="14">${current}%</text>
    <text x="152" y="15" fill="#010101" fill-opacity=".3">▲${peak}%</text>
    <text x="152" y="14">▲${peak}%</text>
  </g>
</svg>
EOF

    echo "Extended badge: $badge_file"
}

#######################################
# Generate all extended badges
#######################################
peaks_generate_all_badges() {
    echo "Generating extended badges..."
    peaks_generate_extended_badge "machine"
    peaks_generate_extended_badge "ai"
    echo "Done."
}

################################################################################
# SECTION 5: Trend Analysis
################################################################################

#######################################
# Get trend information
# Outputs: JSON with trend data
#######################################
peaks_get_trend() {
    if [[ ! -f "$PEAKS_FILE" ]]; then
        echo '{"trend": "unknown", "changes_count": 0}'
        return
    fi

    local current_ai peak_ai changes_count total_runs

    current_ai=$(yq '.peaks.ai_coverage.current' "$PEAKS_FILE")
    peak_ai=$(yq '.peaks.ai_coverage.peak' "$PEAKS_FILE")
    changes_count=$(yq '.history.changes | length' "$PEAKS_FILE")
    total_runs=$(yq '.metadata.total_runs_tracked' "$PEAKS_FILE")

    local trend
    if [[ $current_ai -eq $peak_ai && $current_ai -gt 0 ]]; then
        trend="at_peak"
    elif [[ $current_ai -ge $((peak_ai * 95 / 100)) ]]; then
        trend="near_peak"
    elif [[ $current_ai -ge $((peak_ai * 80 / 100)) ]]; then
        trend="good"
    else
        trend="below_normal"
    fi

    cat << EOF
{
    "trend": "$trend",
    "current_vs_peak_percentage": $((current_ai * 100 / (peak_ai > 0 ? peak_ai : 1))),
    "changes_count": $changes_count,
    "total_runs_tracked": $total_runs
}
EOF
}

################################################################################
# SECTION 6: Display Functions
################################################################################

#######################################
# Display peaks summary
#######################################
peaks_display_summary() {
    if [[ ! -f "$PEAKS_FILE" ]]; then
        echo "No peaks data found. Run a verification first."
        return
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    VERIFICATION PEAKS"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    printf "  %-20s %10s %10s %s\n" "METRIC" "CURRENT" "PEAK" "STATUS"
    printf "  %-20s %10s %10s %s\n" "────────────────────" "─────────" "─────────" "──────────────"

    local metrics=("machine_coverage" "ai_coverage" "scenarios_passed" "items_verified" "average_confidence")
    local labels=("Machine Coverage" "AI Coverage" "Scenarios Passed" "Items Verified" "Avg Confidence")

    for i in "${!metrics[@]}"; do
        local metric="${metrics[$i]}"
        local label="${labels[$i]}"
        local current peak status status_icon

        current=$(yq ".peaks.$metric.current" "$PEAKS_FILE")
        peak=$(yq ".peaks.$metric.peak" "$PEAKS_FILE")

        if [[ $current -eq $peak && $current -gt 0 ]]; then
            status="AT PEAK"
            status_icon="★"
        elif [[ $current -ge $((peak * 95 / 100)) ]]; then
            status="Near peak"
            status_icon="▲"
        else
            status=""
            status_icon=" "
        fi

        local suffix=""
        [[ "$metric" =~ coverage|confidence ]] && suffix="%"

        printf "  %-20s %9s%s %9s%s %s %s\n" "$label" "$current" "$suffix" "$peak" "$suffix" "$status_icon" "$status"
    done

    echo ""

    # Show recent history
    local history_count
    history_count=$(yq '.history.changes | length' "$PEAKS_FILE")

    if [[ $history_count -gt 0 ]]; then
        echo "  Recent Peak Changes:"
        yq -r '.history.changes[:5][] | "    \(.timestamp | split("T")[0]) - \(.changes)"' "$PEAKS_FILE" 2>/dev/null
        echo ""
    fi

    local total_runs
    total_runs=$(yq '.metadata.total_runs_tracked' "$PEAKS_FILE")
    echo "  Total runs tracked: $total_runs"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
}

#######################################
# Print peaks help
#######################################
peaks_help() {
    cat << 'EOF'
NWP Peak Badge System (P51 Phase 7)

Peak Management:
  peaks_update M AI S I C [RUN_ID]      Update with new values
  peaks_update_from_checkpoint [FILE]  Update from checkpoint

Queries:
  peaks_get_current                    Get current values (JSON)
  peaks_get_peaks                      Get peak values (JSON)
  peaks_get_metric METRIC              Get specific metric details
  peaks_get_history                    Get change history
  peaks_get_trend                      Get trend analysis

Badge Generation:
  peaks_generate_extended_badge TYPE   Generate extended badge (machine|ai)
  peaks_generate_all_badges            Generate all extended badges

Display:
  peaks_display_summary                Show peaks summary

Examples:
  # Update peaks from verification run
  peaks_update 88 75 15 350 92 "ai-verify-20260117-143000"

  # Update from checkpoint
  peaks_update_from_checkpoint

  # Generate extended badges
  peaks_generate_all_badges

  # View peaks
  peaks_display_summary
EOF
}

#######################################
# CLI entry point
#######################################
peaks_main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        init)
            peaks_init
            echo "Peaks system initialized"
            ;;
        update)
            peaks_update "$@"
            ;;
        update-checkpoint)
            peaks_update_from_checkpoint "$@"
            ;;
        current)
            peaks_get_current
            ;;
        peaks)
            peaks_get_peaks
            ;;
        metric)
            peaks_get_metric "$@"
            ;;
        history)
            peaks_get_history
            ;;
        trend)
            peaks_get_trend
            ;;
        badge)
            peaks_generate_extended_badge "$@"
            ;;
        badges)
            peaks_generate_all_badges
            ;;
        summary|show)
            peaks_display_summary
            ;;
        help|--help|-h)
            peaks_help
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run 'peaks_main help' for usage"
            return 1
            ;;
    esac
}

# Export functions
export -f peaks_init peaks_create_file peaks_check_yq
export -f peaks_update peaks_update_from_checkpoint
export -f peaks_get_current peaks_get_peaks peaks_get_metric peaks_get_history peaks_get_trend
export -f peaks_generate_extended_badge peaks_generate_all_badges
export -f peaks_display_summary peaks_help peaks_main
