#!/bin/bash

################################################################################
# NWP Badges Library
#
# Generate GitLab badge URLs and README snippets
# Source this file: source "$SCRIPT_DIR/lib/badges.sh"
#
# Dependencies: lib/ui.sh, lib/common.sh
################################################################################

# Generate badge URLs for a project
# Usage: generate_badge_urls "project-name" "group" ["branch"]
generate_badge_urls() {
    local project_name="$1"
    local group="${2:-sites}"
    local branch="${3:-main}"
    local cnwp_file="${SCRIPT_DIR}/cnwp.yml"

    # Get GitLab URL from cnwp.yml
    local gitlab_domain=""
    if [ -f "$cnwp_file" ]; then
        local base_url=$(awk '
            /^settings:/ { in_settings = 1; next }
            in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
            in_settings && /^  url:/ {
                sub("^  url: *", "")
                gsub(/["'"'"']/, "")
                print
                exit
            }
        ' "$cnwp_file")

        if [ -n "$base_url" ]; then
            gitlab_domain="git.${base_url}"
        fi
    fi

    # Fallback to default
    if [ -z "$gitlab_domain" ]; then
        gitlab_domain="git.nwpcode.org"
    fi

    local base="https://${gitlab_domain}/${group}/${project_name}"

    echo "# Badge URLs for ${group}/${project_name}"
    echo ""
    echo "Pipeline: ${base}/badges/${branch}/pipeline.svg"
    echo "Coverage: ${base}/badges/${branch}/coverage.svg"
    echo "Release:  ${base}/-/badges/release.svg"
    echo ""
    echo "# Markdown"
    echo "[![Pipeline](${base}/badges/${branch}/pipeline.svg)](${base}/-/pipelines)"
    echo "[![Coverage](${base}/badges/${branch}/coverage.svg)](${base}/-/graphs/${branch}/charts)"
}

# Generate complete README badges section
# Usage: generate_readme_badges "project-name" "group" ["branch"]
generate_readme_badges() {
    local project_name="$1"
    local group="${2:-sites}"
    local branch="${3:-main}"

    local gitlab_domain=""
    local cnwp_file="${SCRIPT_DIR}/cnwp.yml"

    if [ -f "$cnwp_file" ]; then
        local base_url=$(awk '
            /^settings:/ { in_settings = 1; next }
            in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
            in_settings && /^  url:/ {
                sub("^  url: *", "")
                gsub(/["'"'"']/, "")
                print
                exit
            }
        ' "$cnwp_file")

        if [ -n "$base_url" ]; then
            gitlab_domain="git.${base_url}"
        fi
    fi

    if [ -z "$gitlab_domain" ]; then
        gitlab_domain="git.nwpcode.org"
    fi

    local base="https://${gitlab_domain}/${group}/${project_name}"

    cat << EOF
[![Pipeline Status](${base}/badges/${branch}/pipeline.svg)](${base}/-/pipelines)
[![Coverage](${base}/badges/${branch}/coverage.svg)](${base}/-/graphs/${branch}/charts)
EOF
}

# Add badges to existing README.md
# Usage: add_badges_to_readme "/path/to/README.md" "project-name" "group"
add_badges_to_readme() {
    local readme_path="$1"
    local project_name="$2"
    local group="${3:-sites}"

    if [ ! -f "$readme_path" ]; then
        print_error "README not found: $readme_path"
        return 1
    fi

    # Check if badges already exist
    if grep -q "badges/main/pipeline.svg" "$readme_path"; then
        print_info "Badges already present in README"
        return 0
    fi

    # Generate badge markdown
    local badges=$(generate_readme_badges "$project_name" "$group")

    # Insert after first heading
    local temp_file=$(mktemp)

    awk -v badges="$badges" '
        !inserted && /^#/ {
            print
            getline
            if (/^$/ || /^[^#]/) {
                print ""
                print badges
                print ""
            }
            inserted = 1
        }
        { print }
    ' "$readme_path" > "$temp_file"

    mv "$temp_file" "$readme_path"
    print_status "OK" "Added badges to README"
}

# Check if coverage meets threshold
# Usage: check_coverage_threshold "80" "/path/to/coverage.xml"
check_coverage_threshold() {
    local threshold="$1"
    local coverage_file="$2"

    if [ ! -f "$coverage_file" ]; then
        print_warning "Coverage file not found: $coverage_file"
        return 1
    fi

    # Extract coverage percentage from Clover XML
    local coverage=$(grep -oP 'line-rate="\K[0-9.]+' "$coverage_file" 2>/dev/null | head -1)

    if [ -z "$coverage" ]; then
        # Try cobertura format
        coverage=$(grep -oP '<coverage[^>]*line-rate="\K[0-9.]+' "$coverage_file" 2>/dev/null | head -1)
    fi

    if [ -z "$coverage" ]; then
        print_warning "Could not extract coverage percentage"
        return 1
    fi

    # Convert to percentage
    local coverage_pct=$(echo "$coverage * 100" | bc 2>/dev/null || echo "0")
    coverage_pct=${coverage_pct%.*}

    echo "Coverage: ${coverage_pct}%"

    if [ "$coverage_pct" -ge "$threshold" ]; then
        print_status "OK" "Coverage ${coverage_pct}% meets threshold ${threshold}%"
        return 0
    else
        print_error "Coverage ${coverage_pct}% below threshold ${threshold}%"
        return 1
    fi
}
