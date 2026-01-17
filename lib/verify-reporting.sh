#!/bin/bash
################################################################################
# NWP Verification Reporting Library
#
# Part of P51: AI-Powered Deep Verification (Phase 6)
#
# This library provides comprehensive reporting for AI verification runs.
# It generates scenario completion reports, exports findings to JSON,
# creates AI coverage badges, and produces summary statistics.
#
# Key Functions:
#   - report_generate() - Generate full verification report
#   - report_export_findings() - Export findings to JSON
#   - report_create_badge() - Generate AI coverage badge
#   - report_summary() - Display summary statistics
#
# Source this file: source "$PROJECT_ROOT/lib/verify-reporting.sh"
#
# Reference:
#   - P51: AI-Powered Deep Verification
#   - docs/proposals/P51-ai-powered-verification.md
################################################################################

# Determine paths
REPORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$REPORT_LIB_DIR/.." && pwd)}"

# Make PROJECT_ROOT available if not set
PROJECT_ROOT="${PROJECT_ROOT:-$REPORT_PROJECT_ROOT}"

# Configuration
REPORT_OUTPUT_DIR="${REPORT_OUTPUT_DIR:-$REPORT_PROJECT_ROOT/.logs/verification}"
REPORT_BADGES_DIR="${REPORT_BADGES_DIR:-$REPORT_PROJECT_ROOT/.verification-badges}"
REPORT_JSON_FILE="${REPORT_JSON_FILE:-$REPORT_OUTPUT_DIR/ai-verification-findings.json}"
REPORT_HTML_FILE="${REPORT_HTML_FILE:-$REPORT_OUTPUT_DIR/ai-verification-report.html}"
REPORT_MD_FILE="${REPORT_MD_FILE:-$REPORT_OUTPUT_DIR/ai-verification-report.md}"

# Source dependencies
for dep in verify-checkpoint.sh verify-cross-validate.sh verify-behat.sh verify-autofix.sh; do
    if [[ -f "$REPORT_PROJECT_ROOT/lib/$dep" ]]; then
        source "$REPORT_PROJECT_ROOT/lib/$dep"
    fi
done

################################################################################
# SECTION 1: Initialization
################################################################################

#######################################
# Initialize reporting system
#######################################
report_init() {
    mkdir -p "$REPORT_OUTPUT_DIR"
    mkdir -p "$REPORT_BADGES_DIR"
}

################################################################################
# SECTION 2: Data Collection
################################################################################

#######################################
# Collect all verification data
# Outputs: JSON with all verification data
#######################################
report_collect_data() {
    local timestamp
    timestamp=$(date -Iseconds)

    # Get checkpoint data
    local checkpoint_data='{}'
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        checkpoint_data=$(yq -o=json '.' "$CHECKPOINT_FILE" 2>/dev/null || echo '{}')
    fi

    # Get cross-validation findings
    local crossval_data='{}'
    if [[ -f "$CROSSVAL_FINDINGS_FILE" ]]; then
        crossval_data=$(cat "$CROSSVAL_FINDINGS_FILE" 2>/dev/null || echo '{}')
    fi

    # Get Behat findings
    local behat_data='{}'
    if [[ -f "$BEHAT_FINDINGS_FILE" ]]; then
        behat_data=$(cat "$BEHAT_FINDINGS_FILE" 2>/dev/null || echo '{}')
    fi

    # Get auto-fix findings
    local autofix_data='{}'
    if [[ -f "$AUTOFIX_FINDINGS_FILE" ]]; then
        autofix_data=$(cat "$AUTOFIX_FINDINGS_FILE" 2>/dev/null || echo '{}')
    fi

    # Combine all data
    jq -n \
        --arg ts "$timestamp" \
        --argjson checkpoint "$checkpoint_data" \
        --argjson crossval "$crossval_data" \
        --argjson behat "$behat_data" \
        --argjson autofix "$autofix_data" \
        '{
            generated_at: $ts,
            checkpoint: $checkpoint,
            cross_validation: $crossval,
            behat: $behat,
            auto_fix: $autofix
        }'
}

################################################################################
# SECTION 3: Report Generation
################################################################################

#######################################
# Generate complete verification report
# Arguments:
#   $1 - Output format (json|md|html|all)
# Returns: Path to generated report
#######################################
report_generate() {
    local format="${1:-all}"

    report_init

    echo ""
    echo "Generating AI Verification Report..."
    echo "═══════════════════════════════════════════════════════════════"

    # Collect all data
    local data
    data=$(report_collect_data)

    case "$format" in
        json)
            report_generate_json "$data"
            ;;
        md)
            report_generate_markdown "$data"
            ;;
        html)
            report_generate_html "$data"
            ;;
        all)
            report_generate_json "$data"
            report_generate_markdown "$data"
            report_generate_html "$data"
            ;;
    esac

    # Generate badge
    report_create_badge "$data"

    echo ""
    echo "Reports generated:"
    [[ -f "$REPORT_JSON_FILE" ]] && echo "  JSON: $REPORT_JSON_FILE"
    [[ -f "$REPORT_MD_FILE" ]] && echo "  Markdown: $REPORT_MD_FILE"
    [[ -f "$REPORT_HTML_FILE" ]] && echo "  HTML: $REPORT_HTML_FILE"
    echo ""
}

#######################################
# Generate JSON report
# Arguments:
#   $1 - Collected data JSON
#######################################
report_generate_json() {
    local data="$1"

    echo "  Generating JSON report..."

    # Add summary statistics
    local scenarios_completed scenarios_total items_verified items_total
    scenarios_completed=$(echo "$data" | jq '.checkpoint.checkpoint.completed_scenarios | length // 0' 2>/dev/null || echo "0")
    scenarios_total=17
    items_verified=$(echo "$data" | jq '.checkpoint.checkpoint.progress.items.verified // 0' 2>/dev/null || echo "0")
    items_total=471

    # Calculate percentages
    local scenario_pct item_pct
    scenario_pct=$((scenarios_completed * 100 / scenarios_total))
    item_pct=$((items_verified * 100 / items_total))

    # Add summary to data
    echo "$data" | jq \
        --argjson s_comp "$scenarios_completed" \
        --argjson s_total "$scenarios_total" \
        --argjson s_pct "$scenario_pct" \
        --argjson i_ver "$items_verified" \
        --argjson i_total "$items_total" \
        --argjson i_pct "$item_pct" \
        '. + {
            summary: {
                scenarios: {
                    completed: $s_comp,
                    total: $s_total,
                    percentage: $s_pct
                },
                items: {
                    verified: $i_ver,
                    total: $i_total,
                    percentage: $i_pct
                },
                ai_coverage: $i_pct
            }
        }' > "$REPORT_JSON_FILE"

    echo "  JSON report: $REPORT_JSON_FILE"
}

#######################################
# Generate Markdown report
# Arguments:
#   $1 - Collected data JSON
#######################################
report_generate_markdown() {
    local data="$1"

    echo "  Generating Markdown report..."

    local run_id status scenarios_completed scenarios_failed
    local items_verified items_total ai_coverage
    local duration crossval_issues behat_failures fixes_applied

    run_id=$(echo "$data" | jq -r '.checkpoint.checkpoint.run_id // "unknown"')
    status=$(echo "$data" | jq -r '.checkpoint.checkpoint.status // "unknown"')
    scenarios_completed=$(echo "$data" | jq '.checkpoint.checkpoint.completed_scenarios | length // 0')
    scenarios_failed=$(echo "$data" | jq '.checkpoint.checkpoint.failed_scenarios | length // 0')
    items_verified=$(echo "$data" | jq '.checkpoint.checkpoint.progress.items.verified // 0')
    items_total=471
    ai_coverage=$((items_verified * 100 / items_total))
    duration=$(echo "$data" | jq '.checkpoint.checkpoint.metrics.total_duration_seconds // 0')
    crossval_issues=$(echo "$data" | jq '.cross_validation.findings | length // 0')
    behat_failures=$(echo "$data" | jq '.behat.failures | length // 0')
    fixes_applied=$(echo "$data" | jq '.auto_fix.summary.fixed // 0')

    # Format duration
    local duration_fmt
    if [[ $duration -gt 3600 ]]; then
        duration_fmt="$((duration / 3600))h $((duration % 3600 / 60))m"
    elif [[ $duration -gt 60 ]]; then
        duration_fmt="$((duration / 60))m $((duration % 60))s"
    else
        duration_fmt="${duration}s"
    fi

    cat > "$REPORT_MD_FILE" << EOF
# AI Verification Report

**Run ID:** $run_id
**Status:** $status
**Generated:** $(date -Iseconds)

## Summary

| Metric | Value |
|--------|-------|
| Scenarios Completed | $scenarios_completed / 17 |
| Scenarios Failed | $scenarios_failed |
| Items Verified | $items_verified / $items_total |
| AI Coverage | $ai_coverage% |
| Duration | $duration_fmt |

## Coverage Badge

![AI Coverage](../.verification-badges/ai-coverage.svg)

## Cross-Validation Results

**Issues Found:** $crossval_issues

EOF

    # Add cross-validation findings
    if [[ $crossval_issues -gt 0 ]]; then
        echo "### Cross-Validation Issues" >> "$REPORT_MD_FILE"
        echo "" >> "$REPORT_MD_FILE"
        echo "$data" | jq -r '.cross_validation.findings[] | "- **\(.command).\(.field)**: Expected \(.expected), got \(.actual)"' >> "$REPORT_MD_FILE" 2>/dev/null
        echo "" >> "$REPORT_MD_FILE"
    fi

    # Add Behat results
    cat >> "$REPORT_MD_FILE" << EOF

## Behat Test Results

**Failures:** $behat_failures

EOF

    # Add auto-fix summary
    cat >> "$REPORT_MD_FILE" << EOF

## Auto-Fix Summary

**Fixes Applied:** $fixes_applied

EOF

    # Add scenario details
    cat >> "$REPORT_MD_FILE" << EOF

## Scenario Results

| Scenario | Status | Duration | Items | Confidence |
|----------|--------|----------|-------|------------|
EOF

    echo "$data" | jq -r '.checkpoint.checkpoint.completed_scenarios[] | "| \(.id) | \(.status) | \(.duration_seconds)s | \(.items_verified) | \(.confidence)% |"' >> "$REPORT_MD_FILE" 2>/dev/null

    if [[ $scenarios_failed -gt 0 ]]; then
        echo "" >> "$REPORT_MD_FILE"
        echo "### Failed Scenarios" >> "$REPORT_MD_FILE"
        echo "" >> "$REPORT_MD_FILE"
        echo "$data" | jq -r '.checkpoint.checkpoint.failed_scenarios[] | "- **\(.id)**: \(.status)"' >> "$REPORT_MD_FILE" 2>/dev/null
    fi

    cat >> "$REPORT_MD_FILE" << EOF

---

*Generated by P51 AI-Powered Deep Verification*
EOF

    echo "  Markdown report: $REPORT_MD_FILE"
}

#######################################
# Generate HTML report
# Arguments:
#   $1 - Collected data JSON
#######################################
report_generate_html() {
    local data="$1"

    echo "  Generating HTML report..."

    local run_id status scenarios_completed scenarios_failed
    local items_verified items_total ai_coverage duration

    run_id=$(echo "$data" | jq -r '.checkpoint.checkpoint.run_id // "unknown"')
    status=$(echo "$data" | jq -r '.checkpoint.checkpoint.status // "unknown"')
    scenarios_completed=$(echo "$data" | jq '.checkpoint.checkpoint.completed_scenarios | length // 0')
    scenarios_failed=$(echo "$data" | jq '.checkpoint.checkpoint.failed_scenarios | length // 0')
    items_verified=$(echo "$data" | jq '.checkpoint.checkpoint.progress.items.verified // 0')
    items_total=471
    ai_coverage=$((items_verified * 100 / items_total))
    duration=$(echo "$data" | jq '.checkpoint.checkpoint.metrics.total_duration_seconds // 0')

    local status_color
    case "$status" in
        completed) status_color="#28a745" ;;
        completed_with_failures) status_color="#ffc107" ;;
        in_progress) status_color="#17a2b8" ;;
        *) status_color="#dc3545" ;;
    esac

    cat > "$REPORT_HTML_FILE" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AI Verification Report - $run_id</title>
    <style>
        :root {
            --primary: #2c3e50;
            --success: #28a745;
            --warning: #ffc107;
            --danger: #dc3545;
            --info: #17a2b8;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            line-height: 1.6;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background: #f5f5f5;
        }
        .header {
            background: var(--primary);
            color: white;
            padding: 30px;
            border-radius: 8px;
            margin-bottom: 20px;
        }
        .header h1 { margin: 0; }
        .header .meta { opacity: 0.8; margin-top: 10px; }
        .status-badge {
            display: inline-block;
            padding: 5px 15px;
            border-radius: 20px;
            background: $status_color;
            color: white;
            font-weight: bold;
        }
        .card {
            background: white;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .card h2 { margin-top: 0; color: var(--primary); }
        .metrics {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
        }
        .metric {
            text-align: center;
            padding: 20px;
            background: #f8f9fa;
            border-radius: 8px;
        }
        .metric .value {
            font-size: 2.5em;
            font-weight: bold;
            color: var(--primary);
        }
        .metric .label { color: #666; }
        .progress-bar {
            height: 30px;
            background: #e9ecef;
            border-radius: 15px;
            overflow: hidden;
        }
        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, var(--success), #20c997);
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
            font-weight: bold;
        }
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th { background: #f8f9fa; }
        .passed { color: var(--success); }
        .failed { color: var(--danger); }
        footer {
            text-align: center;
            padding: 20px;
            color: #666;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>AI Verification Report</h1>
        <div class="meta">
            <span>Run ID: $run_id</span> |
            <span class="status-badge">$status</span> |
            <span>$(date)</span>
        </div>
    </div>

    <div class="card">
        <h2>Summary</h2>
        <div class="metrics">
            <div class="metric">
                <div class="value">$scenarios_completed/17</div>
                <div class="label">Scenarios</div>
            </div>
            <div class="metric">
                <div class="value">$items_verified</div>
                <div class="label">Items Verified</div>
            </div>
            <div class="metric">
                <div class="value">$ai_coverage%</div>
                <div class="label">AI Coverage</div>
            </div>
            <div class="metric">
                <div class="value">${duration}s</div>
                <div class="label">Duration</div>
            </div>
        </div>
    </div>

    <div class="card">
        <h2>AI Coverage</h2>
        <div class="progress-bar">
            <div class="progress-fill" style="width: ${ai_coverage}%">${ai_coverage}%</div>
        </div>
    </div>

    <div class="card">
        <h2>Scenario Results</h2>
        <table>
            <thead>
                <tr>
                    <th>Scenario</th>
                    <th>Status</th>
                    <th>Duration</th>
                    <th>Items</th>
                    <th>Confidence</th>
                </tr>
            </thead>
            <tbody>
EOF

    # Add scenario rows
    echo "$data" | jq -r '.checkpoint.checkpoint.completed_scenarios[] | "<tr><td>\(.id)</td><td class=\"passed\">\(.status)</td><td>\(.duration_seconds)s</td><td>\(.items_verified)</td><td>\(.confidence)%</td></tr>"' >> "$REPORT_HTML_FILE" 2>/dev/null

    echo "$data" | jq -r '.checkpoint.checkpoint.failed_scenarios[] | "<tr><td>\(.id)</td><td class=\"failed\">\(.status)</td><td>-</td><td>-</td><td>-</td></tr>"' >> "$REPORT_HTML_FILE" 2>/dev/null

    cat >> "$REPORT_HTML_FILE" << EOF
            </tbody>
        </table>
    </div>

    <footer>
        Generated by P51 AI-Powered Deep Verification
    </footer>
</body>
</html>
EOF

    echo "  HTML report: $REPORT_HTML_FILE"
}

################################################################################
# SECTION 4: Badge Generation
################################################################################

#######################################
# Create AI coverage badge
# Arguments:
#   $1 - Data JSON (optional, will collect if not provided)
#######################################
report_create_badge() {
    local data="${1:-$(report_collect_data)}"

    echo "  Generating AI coverage badge..."

    local items_verified ai_coverage
    items_verified=$(echo "$data" | jq '.checkpoint.checkpoint.progress.items.verified // 0' 2>/dev/null || echo "0")
    ai_coverage=$((items_verified * 100 / 471))

    # Determine color based on coverage
    local color
    if [[ $ai_coverage -ge 90 ]]; then
        color="#28a745"  # Green
    elif [[ $ai_coverage -ge 70 ]]; then
        color="#ffc107"  # Yellow
    elif [[ $ai_coverage -ge 50 ]]; then
        color="#fd7e14"  # Orange
    else
        color="#dc3545"  # Red
    fi

    # Generate SVG badge
    local badge_file="$REPORT_BADGES_DIR/ai-coverage.svg"

    cat > "$badge_file" << EOF
<svg xmlns="http://www.w3.org/2000/svg" width="130" height="20">
  <linearGradient id="b" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <mask id="a">
    <rect width="130" height="20" rx="3" fill="#fff"/>
  </mask>
  <g mask="url(#a)">
    <path fill="#555" d="M0 0h75v20H0z"/>
    <path fill="$color" d="M75 0h55v20H75z"/>
    <path fill="url(#b)" d="M0 0h130v20H0z"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="DejaVu Sans,Verdana,Geneva,sans-serif" font-size="11">
    <text x="37.5" y="15" fill="#010101" fill-opacity=".3">AI Coverage</text>
    <text x="37.5" y="14">AI Coverage</text>
    <text x="102" y="15" fill="#010101" fill-opacity=".3">${ai_coverage}%</text>
    <text x="102" y="14">${ai_coverage}%</text>
  </g>
</svg>
EOF

    echo "  Badge: $badge_file"
}

#######################################
# Update all verification badges
#######################################
report_update_badges() {
    report_init

    echo "Updating verification badges..."

    # Generate AI coverage badge
    report_create_badge

    # Also update machine coverage badge if verify-runner is available
    if type -t verify_generate_badge &>/dev/null; then
        verify_generate_badge
    fi

    echo "Badges updated in $REPORT_BADGES_DIR"
}

################################################################################
# SECTION 5: Export Functions
################################################################################

#######################################
# Export findings to JSON
# Arguments:
#   $1 - Output file (optional)
# Returns: Path to exported file
#######################################
report_export_findings() {
    local output_file="${1:-$REPORT_JSON_FILE}"

    report_init

    local data
    data=$(report_collect_data)

    echo "$data" > "$output_file"

    echo "Findings exported to: $output_file"
    echo "$output_file"
}

#######################################
# Get summary statistics
# Outputs: JSON with summary stats
#######################################
report_get_summary() {
    local data
    data=$(report_collect_data)

    local scenarios_completed scenarios_failed items_verified ai_coverage
    scenarios_completed=$(echo "$data" | jq '.checkpoint.checkpoint.completed_scenarios | length // 0')
    scenarios_failed=$(echo "$data" | jq '.checkpoint.checkpoint.failed_scenarios | length // 0')
    items_verified=$(echo "$data" | jq '.checkpoint.checkpoint.progress.items.verified // 0')
    ai_coverage=$((items_verified * 100 / 471))

    cat << EOF
{
    "scenarios_completed": $scenarios_completed,
    "scenarios_failed": $scenarios_failed,
    "scenarios_total": 17,
    "items_verified": $items_verified,
    "items_total": 471,
    "ai_coverage_percentage": $ai_coverage
}
EOF
}

################################################################################
# SECTION 6: Display Functions
################################################################################

#######################################
# Display summary to console
#######################################
report_display_summary() {
    local data
    data=$(report_collect_data)

    local run_id status scenarios_completed scenarios_failed
    local items_verified items_total ai_coverage duration

    run_id=$(echo "$data" | jq -r '.checkpoint.checkpoint.run_id // "unknown"')
    status=$(echo "$data" | jq -r '.checkpoint.checkpoint.status // "unknown"')
    scenarios_completed=$(echo "$data" | jq '.checkpoint.checkpoint.completed_scenarios | length // 0')
    scenarios_failed=$(echo "$data" | jq '.checkpoint.checkpoint.failed_scenarios | length // 0')
    items_verified=$(echo "$data" | jq '.checkpoint.checkpoint.progress.items.verified // 0')
    items_total=471
    ai_coverage=$((items_verified * 100 / items_total))
    duration=$(echo "$data" | jq '.checkpoint.checkpoint.metrics.total_duration_seconds // 0')

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "              AI VERIFICATION REPORT SUMMARY"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Run ID:              $run_id"
    echo "  Status:              $status"
    echo ""
    echo "  Scenarios Completed: $scenarios_completed / 17"
    [[ $scenarios_failed -gt 0 ]] && echo "  Scenarios Failed:    $scenarios_failed"
    echo ""
    echo "  Items Verified:      $items_verified / $items_total"
    echo ""

    # Progress bar
    local bar_width=40
    local filled=$((ai_coverage * bar_width / 100))
    local empty=$((bar_width - filled))
    printf "  AI Coverage:         ["
    printf "%0.s█" $(seq 1 $filled 2>/dev/null)
    printf "%0.s░" $(seq 1 $empty 2>/dev/null)
    printf "] %d%%\n" "$ai_coverage"

    echo ""
    echo "  Duration:            ${duration}s"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
}

#######################################
# Print reporting help
#######################################
report_help() {
    cat << 'EOF'
NWP Verification Reporting Library (P51 Phase 6)

Report Generation:
  report_generate [FORMAT]             Generate report (json|md|html|all)
  report_generate_json DATA            Generate JSON report
  report_generate_markdown DATA        Generate Markdown report
  report_generate_html DATA            Generate HTML report

Badge Generation:
  report_create_badge [DATA]           Create AI coverage badge
  report_update_badges                 Update all verification badges

Export:
  report_export_findings [FILE]        Export findings to JSON
  report_get_summary                   Get summary statistics

Display:
  report_display_summary               Show summary to console

Data Collection:
  report_collect_data                  Collect all verification data

Examples:
  # Generate all reports
  report_generate all

  # Export findings
  report_export_findings findings.json

  # Update badges
  report_update_badges
EOF
}

# Export functions
export -f report_init report_collect_data
export -f report_generate report_generate_json report_generate_markdown report_generate_html
export -f report_create_badge report_update_badges
export -f report_export_findings report_get_summary
export -f report_display_summary report_help
