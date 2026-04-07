#!/bin/bash
# vrt.sh - Visual Regression Testing
# Part of NWP (Narrow Way Project)
#
# Usage: pl vrt <subcommand> <sitename> [options]
# Subcommands: baseline, compare, report, accept

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

VRT_DIR="${PROJECT_ROOT}/.vrt"

show_help() {
    cat << 'EOF'
Usage: pl vrt <subcommand> <sitename> [options]

Visual Regression Testing - detect unintended visual changes in your sites.

Subcommands:
  baseline <site>   Capture baseline screenshots
  compare <site>    Compare current state against baseline
  report <site>     Show comparison report
  accept <site>     Accept current state as new baseline

Options:
  -h, --help        Show this help
  --viewport WxH    Override viewport size (default: 1920x1080)
  --mobile          Also capture mobile viewport (375x812)
  --threshold N     Pixel difference threshold as percentage (default: 0.1)
  --pages URL,...   Override pages to capture (comma-separated)

Examples:
  pl vrt baseline mysite              # Capture baseline screenshots
  pl vrt compare mysite               # Compare against baseline
  pl vrt compare mysite --threshold 1 # Allow 1% difference
  pl vrt accept mysite                # Accept current as new baseline
  pl vrt report mysite                # View last comparison report

Requirements:
  - DDEV running for the target site
  - Google Chrome or Chromium (for headless screenshots)
  - ImageMagick (for image comparison)
EOF
}

# Check required tools
check_vrt_dependencies() {
    local missing=0

    if ! command -v google-chrome &>/dev/null && ! command -v chromium-browser &>/dev/null && ! command -v chromium &>/dev/null; then
        print_warning "Chrome/Chromium not found - needed for screenshots"
        print_hint "Install: sudo apt install chromium-browser"
        ((missing++))
    fi

    if ! command -v compare &>/dev/null; then
        print_warning "ImageMagick 'compare' not found - needed for diff"
        print_hint "Install: sudo apt install imagemagick"
        ((missing++))
    fi

    return $missing
}

# Get Chrome binary path
get_chrome_binary() {
    for bin in google-chrome chromium-browser chromium; do
        if command -v "$bin" &>/dev/null; then
            echo "$bin"
            return
        fi
    done
    echo ""
}

# Get VRT pages for a site from nwp.yml
get_vrt_pages() {
    local site_name="$1"
    local config_file="${PROJECT_ROOT}/nwp.yml"

    # Try to read from nwp.yml vrt.pages configuration
    local pages
    pages=$(awk -v site="$site_name" '
        /^sites:/{in_sites=1; next}
        in_sites && /^  [a-zA-Z]/{
            gsub(/:$/, "", $1)
            current_site=$1
        }
        in_sites && current_site==site && /vrt:/{in_vrt=1; next}
        in_vrt && /pages:/{in_pages=1; next}
        in_pages && /- url:/{
            gsub(/^[[:space:]]*- url:[[:space:]]*/, "")
            print
        }
        in_pages && /^    [a-zA-Z]/ && !/- url:/{in_pages=0}
        in_vrt && /^    [a-zA-Z]/ && !/pages:/{in_vrt=0}
    ' "$config_file" 2>/dev/null)

    if [[ -z "$pages" ]]; then
        # Default pages if not configured
        echo "/"
        echo "/user/login"
    else
        echo "$pages"
    fi
}

# Capture a screenshot using headless Chrome
# Usage: capture_screenshot <url> <output_file> [viewport]
capture_screenshot() {
    local url="$1"
    local output_file="$2"
    local viewport="${3:-1920,1080}"

    local chrome
    chrome=$(get_chrome_binary)

    if [[ -z "$chrome" ]]; then
        print_error "Chrome/Chromium not available"
        return 1
    fi

    "$chrome" \
        --headless \
        --disable-gpu \
        --no-sandbox \
        --screenshot="$output_file" \
        --window-size="$viewport" \
        --hide-scrollbars \
        "$url" 2>/dev/null
}

# Capture baseline screenshots for a site
cmd_baseline() {
    local site_name="$1"
    local viewport="${VIEWPORT:-1920,1080}"

    validate_sitename "$site_name" || return 1
    check_vrt_dependencies || return 1

    local site_dir="${PROJECT_ROOT}/sites/${site_name}"
    local baseline_dir="${VRT_DIR}/${site_name}/baseline"
    mkdir -p "$baseline_dir"

    # Get site URL from DDEV
    local site_url
    site_url=$(cd "$site_dir" && ddev describe -j 2>/dev/null | awk -F'"' '/"primary_url"/{print $4}') || {
        print_error "Could not get site URL. Is DDEV running for ${site_name}?"
        return 1
    }

    print_info "Capturing baseline screenshots for ${site_name}..."

    local pages
    pages=$(get_vrt_pages "$site_name")
    local count=0

    while IFS= read -r page; do
        [[ -z "$page" ]] && continue
        local safe_name
        safe_name=$(echo "$page" | sed 's/[\/]/_/g; s/^_//')
        [[ -z "$safe_name" ]] && safe_name="homepage"

        local output_file="${baseline_dir}/${safe_name}.png"
        print_info "  Capturing ${page} → ${safe_name}.png"

        if capture_screenshot "${site_url}${page}" "$output_file" "$viewport"; then
            print_success "  Captured: ${safe_name}.png"
            ((count++))
        else
            print_warning "  Failed to capture: ${page}"
        fi
    done <<< "$pages"

    print_success "Baseline captured: ${count} screenshots in ${baseline_dir}"
}

# Compare current state against baseline
cmd_compare() {
    local site_name="$1"
    local threshold="${THRESHOLD:-0.1}"
    local viewport="${VIEWPORT:-1920,1080}"

    validate_sitename "$site_name" || return 1
    check_vrt_dependencies || return 1

    local baseline_dir="${VRT_DIR}/${site_name}/baseline"
    local current_dir="${VRT_DIR}/${site_name}/current"
    local diff_dir="${VRT_DIR}/${site_name}/diff"

    if [[ ! -d "$baseline_dir" ]]; then
        print_error "No baseline found. Run: pl vrt baseline ${site_name}"
        return 1
    fi

    mkdir -p "$current_dir" "$diff_dir"

    # Get site URL
    local site_dir="${PROJECT_ROOT}/sites/${site_name}"
    local site_url
    site_url=$(cd "$site_dir" && ddev describe -j 2>/dev/null | awk -F'"' '/"primary_url"/{print $4}') || {
        print_error "Could not get site URL"
        return 1
    }

    print_info "Comparing ${site_name} against baseline (threshold: ${threshold}%)..."

    local pages pass=0 fail=0 total=0
    pages=$(get_vrt_pages "$site_name")

    # Capture current screenshots
    while IFS= read -r page; do
        [[ -z "$page" ]] && continue
        local safe_name
        safe_name=$(echo "$page" | sed 's/[\/]/_/g; s/^_//')
        [[ -z "$safe_name" ]] && safe_name="homepage"

        local baseline_file="${baseline_dir}/${safe_name}.png"
        local current_file="${current_dir}/${safe_name}.png"
        local diff_file="${diff_dir}/${safe_name}-diff.png"

        [[ ! -f "$baseline_file" ]] && continue
        ((total++))

        # Capture current
        capture_screenshot "${site_url}${page}" "$current_file" "$viewport" || continue

        # Compare using ImageMagick
        local diff_metric
        diff_metric=$(compare -metric AE "$baseline_file" "$current_file" "$diff_file" 2>&1) || true

        # Get total pixels for percentage calculation
        local total_pixels
        total_pixels=$(identify -format '%[fx:w*h]' "$baseline_file" 2>/dev/null || echo "1")

        local diff_pct
        diff_pct=$(awk "BEGIN {printf \"%.4f\", ($diff_metric / $total_pixels) * 100}" 2>/dev/null)

        if awk "BEGIN {exit !($diff_pct <= $threshold)}" 2>/dev/null; then
            print_success "  PASS: ${safe_name} (${diff_pct}% different)"
            ((pass++))
        else
            print_error "  FAIL: ${safe_name} (${diff_pct}% different, threshold: ${threshold}%)"
            print_hint "  Diff image: ${diff_file}"
            ((fail++))
        fi
    done <<< "$pages"

    echo ""
    if [[ $fail -eq 0 ]]; then
        print_success "VRT passed: ${pass}/${total} pages within threshold"
    else
        print_error "VRT failed: ${fail}/${total} pages exceeded threshold"
        print_hint "Review diffs in: ${diff_dir}"
        print_hint "Accept changes: pl vrt accept ${site_name}"
        return 1
    fi
}

# Accept current screenshots as new baseline
cmd_accept() {
    local site_name="$1"

    local current_dir="${VRT_DIR}/${site_name}/current"
    local baseline_dir="${VRT_DIR}/${site_name}/baseline"

    if [[ ! -d "$current_dir" ]]; then
        print_error "No current screenshots to accept. Run: pl vrt compare ${site_name}"
        return 1
    fi

    rm -rf "$baseline_dir"
    mv "$current_dir" "$baseline_dir"
    rm -rf "${VRT_DIR}/${site_name}/diff"

    print_success "Current screenshots accepted as new baseline for ${site_name}"
}

# Show comparison report
cmd_report() {
    local site_name="$1"
    local diff_dir="${VRT_DIR}/${site_name}/diff"

    if [[ ! -d "$diff_dir" ]]; then
        print_info "No comparison results found. Run: pl vrt compare ${site_name}"
        return
    fi

    print_info "VRT Report for ${site_name}"
    echo ""

    for diff_file in "$diff_dir"/*-diff.png; do
        [[ ! -f "$diff_file" ]] && continue
        local name
        name=$(basename "$diff_file" -diff.png)
        echo "  ${name}: ${diff_file}"
    done
}

main() {
    # Parse global flags
    VIEWPORT="1920,1080"
    THRESHOLD="0.1"
    MOBILE=false

    local subcommand=""
    local site_name=""
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; return 0 ;;
            --viewport) VIEWPORT="$2"; shift 2 ;;
            --threshold) THRESHOLD="$2"; shift 2 ;;
            --mobile) MOBILE=true; shift ;;
            baseline|compare|report|accept)
                subcommand="$1"
                shift
                ;;
            *)
                if [[ -z "$site_name" ]]; then
                    site_name="$1"
                else
                    args+=("$1")
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$subcommand" ]]; then
        show_help
        return 1
    fi

    if [[ -z "$site_name" ]]; then
        print_error "Site name required"
        return 1
    fi

    case "$subcommand" in
        baseline) cmd_baseline "$site_name" ;;
        compare) cmd_compare "$site_name" ;;
        report) cmd_report "$site_name" ;;
        accept) cmd_accept "$site_name" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
