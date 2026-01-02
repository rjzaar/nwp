#!/bin/bash
#
# verify.sh - NWP Feature Verification Tracking
#
# This script manages the verification status of NWP features.
# It tracks which features have been manually verified by a human,
# and automatically invalidates verification when code changes.
#
# Usage:
#   ./verify.sh              # Show verification status
#   ./verify.sh status       # Show verification status (default)
#   ./verify.sh check        # Check for invalidated verifications
#   ./verify.sh details <id> # Show what changed and verification checklist
#   ./verify.sh verify       # Interactive verification mode
#   ./verify.sh verify <id>  # Mark a specific feature as verified
#   ./verify.sh unverify <id> # Mark a specific feature as unverified
#   ./verify.sh list         # List all feature IDs
#   ./verify.sh summary      # Show summary statistics
#   ./verify.sh reset        # Reset all verifications

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFICATION_FILE="${SCRIPT_DIR}/.verification.yml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Checkbox characters
CHECK_ON="[✓]"
CHECK_OFF="[ ]"
CHECK_INVALID="[!]"

# Calculate SHA256 hash for a list of files
calculate_hash() {
    local files="$1"
    local combined_hash=""

    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            local filepath="${SCRIPT_DIR}/${file}"
            if [[ -f "$filepath" ]]; then
                combined_hash+=$(sha256sum "$filepath" 2>/dev/null | cut -d' ' -f1)
            fi
        fi
    done <<< "$files"

    if [[ -n "$combined_hash" ]]; then
        echo -n "$combined_hash" | sha256sum | cut -d' ' -f1
    else
        echo ""
    fi
}

# Get a YAML value using simple parsing
get_yaml_value() {
    local feature="$1"
    local field="$2"

    awk -v feature="$feature" -v field="$field" '
    BEGIN { in_feature = 0; indent = 0 }
    /^  [a-z0-9_]+:/ {
        gsub(/^  /, "")
        gsub(/:.*/, "")
        if ($0 == feature) {
            in_feature = 1
            indent = 4
        } else if (in_feature) {
            in_feature = 0
        }
    }
    in_feature && $0 ~ "^    " field ":" {
        gsub(/^    [a-z_]+: */, "")
        gsub(/^"/, "")
        gsub(/"$/, "")
        print
        exit
    }
    ' "$VERIFICATION_FILE"
}

# Get files list for a feature
get_feature_files() {
    local feature="$1"

    awk -v feature="$feature" '
    BEGIN { in_feature = 0; in_files = 0 }
    /^  [a-z0-9_]+:/ {
        gsub(/^  /, "")
        gsub(/:.*/, "")
        if ($0 == feature) {
            in_feature = 1
        } else if (in_feature) {
            in_feature = 0
            in_files = 0
        }
    }
    in_feature && /^    files:/ {
        in_files = 1
        next
    }
    in_feature && in_files && /^      - / {
        gsub(/^      - /, "")
        print
    }
    in_feature && in_files && /^    [a-z]/ {
        in_files = 0
    }
    ' "$VERIFICATION_FILE"
}

# Get checklist items for a feature
get_feature_checklist() {
    local feature="$1"

    awk -v feature="$feature" '
    BEGIN { in_feature = 0; in_checklist = 0 }
    /^  [a-z0-9_]+:/ {
        gsub(/^  /, "")
        gsub(/:.*/, "")
        if ($0 == feature) {
            in_feature = 1
        } else if (in_feature) {
            in_feature = 0
            in_checklist = 0
        }
    }
    in_feature && /^    checklist:/ {
        in_checklist = 1
        next
    }
    in_feature && in_checklist && /^      - / {
        gsub(/^      - "?/, "")
        gsub(/"$/, "")
        print
    }
    in_feature && in_checklist && /^    [a-z]/ {
        in_checklist = 0
    }
    ' "$VERIFICATION_FILE"
}

# Get list of files that changed since last verification
get_changed_files() {
    local feature="$1"
    local stored_hash=$(get_yaml_value "$feature" "file_hash")
    local changed_files=()

    if [[ -z "$stored_hash" || "$stored_hash" == "null" ]]; then
        # No stored hash, return all files as "unknown"
        get_feature_files "$feature"
        return
    fi

    # We need to track individual file hashes to detect which changed
    # For now, just return all files if the combined hash changed
    local files=$(get_feature_files "$feature")
    echo "$files"
}

# Show git diff for a file if available
show_file_diff() {
    local file="$1"
    local filepath="${SCRIPT_DIR}/${file}"

    if [[ ! -f "$filepath" ]]; then
        echo -e "    ${RED}File not found${NC}"
        return
    fi

    # Check if file is tracked by git
    if git -C "$SCRIPT_DIR" ls-files --error-unmatch "$file" &>/dev/null; then
        # Show recent changes (last commit that modified this file)
        local last_commit=$(git -C "$SCRIPT_DIR" log -1 --format="%h %s" -- "$file" 2>/dev/null)
        if [[ -n "$last_commit" ]]; then
            echo -e "    ${DIM}Last commit: ${last_commit}${NC}"
        fi

        # Show summary of changes if file has uncommitted changes
        if ! git -C "$SCRIPT_DIR" diff --quiet -- "$file" 2>/dev/null; then
            echo -e "    ${YELLOW}Has uncommitted changes${NC}"
            local stats=$(git -C "$SCRIPT_DIR" diff --stat -- "$file" 2>/dev/null | tail -1)
            if [[ -n "$stats" ]]; then
                echo -e "    ${DIM}${stats}${NC}"
            fi
        fi
    fi
}

# Get all feature IDs
get_feature_ids() {
    awk '
    /^  [a-z0-9_]+:$/ {
        gsub(/^  /, "")
        gsub(/:$/, "")
        print
    }
    ' "$VERIFICATION_FILE" | grep -v "^version$"
}

# Update YAML value
update_yaml_value() {
    local feature="$1"
    local field="$2"
    local value="$3"

    # Create a temporary file
    local tmpfile=$(mktemp)

    awk -v feature="$feature" -v field="$field" -v value="$value" '
    BEGIN { in_feature = 0 }
    /^  [a-z0-9_]+:/ {
        test = $0
        gsub(/^  /, "", test)
        gsub(/:.*/, "", test)
        if (test == feature) {
            in_feature = 1
        } else {
            in_feature = 0
        }
    }
    in_feature && $0 ~ "^    " field ":" {
        print "    " field ": " value
        next
    }
    { print }
    ' "$VERIFICATION_FILE" > "$tmpfile"

    mv "$tmpfile" "$VERIFICATION_FILE"
}

# Check if a feature's files have changed since verification
check_feature_changed() {
    local feature="$1"
    local stored_hash=$(get_yaml_value "$feature" "file_hash")

    if [[ -z "$stored_hash" || "$stored_hash" == "null" ]]; then
        return 1  # No hash stored, can't determine
    fi

    local files=$(get_feature_files "$feature")
    local current_hash=$(calculate_hash "$files")

    if [[ "$current_hash" != "$stored_hash" ]]; then
        return 0  # Changed
    fi
    return 1  # Not changed
}

# Display status for all features
show_status() {
    echo -e "${BOLD}${WHITE}NWP Feature Verification Status${NC}"
    echo -e "${DIM}════════════════════════════════════════════════════════════════${NC}"
    echo ""

    local verified_count=0
    local unverified_count=0
    local invalid_count=0
    local current_section=""

    while IFS= read -r feature; do
        local name=$(get_yaml_value "$feature" "name")
        local desc=$(get_yaml_value "$feature" "description")
        local verified=$(get_yaml_value "$feature" "verified")
        local verified_by=$(get_yaml_value "$feature" "verified_by")
        local verified_at=$(get_yaml_value "$feature" "verified_at")

        # Detect section from comments (simplified - use feature prefix)
        local section=""
        case "$feature" in
            setup|install|status|modify|backup|restore|sync|copy|delete|make|migration|import)
                section="CORE SCRIPTS"
                ;;
            live|dev2stg|stg2prod|prod2stg|stg2live|live2stg|live2prod|produce)
                section="DEPLOYMENT"
                ;;
            podcast|schedule|security|setup_ssh|uninstall)
                section="INFRASTRUCTURE"
                ;;
            pl_cli|test_nwp)
                section="CLI & TESTING"
                ;;
            lib_*)
                section="LIBRARIES"
                ;;
            moodle)
                section="MOODLE"
                ;;
            gitlab_*)
                section="GITLAB"
                ;;
            linode_*)
                section="LINODE"
                ;;
            config_*)
                section="CONFIGURATION"
                ;;
            tests_*)
                section="TESTS"
                ;;
        esac

        # Print section header if changed
        if [[ "$section" != "$current_section" ]]; then
            if [[ -n "$current_section" ]]; then
                echo ""
            fi
            echo -e "${CYAN}${BOLD}${section}${NC}"
            echo -e "${DIM}────────────────────────────────────────────────────${NC}"
            current_section="$section"
        fi

        # Determine checkbox state
        local checkbox
        local status_color
        local status_info=""

        if [[ "$verified" == "true" ]]; then
            # Check if files have changed
            if check_feature_changed "$feature"; then
                checkbox="${YELLOW}${CHECK_INVALID}${NC}"
                status_color="${YELLOW}"
                status_info=" ${DIM}(modified since verification)${NC}"
                ((++invalid_count))
            else
                checkbox="${GREEN}${CHECK_ON}${NC}"
                status_color="${GREEN}"
                if [[ -n "$verified_by" && "$verified_by" != "null" ]]; then
                    status_info=" ${DIM}by ${verified_by}${NC}"
                fi
                ((++verified_count))
            fi
        else
            checkbox="${RED}${CHECK_OFF}${NC}"
            status_color="${RED}"
            ((++unverified_count))
        fi

        # Print feature line
        printf "  %b %-45s %b\n" "$checkbox" "${name}" "$status_info"
        printf "    %b%-20s%b %b%s%b\n" "${DIM}" "$feature" "${NC}" "${DIM}" "$desc" "${NC}"

    done <<< "$(get_feature_ids)"

    echo ""
    echo -e "${DIM}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}Summary:${NC}"
    echo -e "  ${GREEN}✓ Verified:${NC}   $verified_count"
    echo -e "  ${RED}○ Unverified:${NC} $unverified_count"
    echo -e "  ${YELLOW}! Modified:${NC}   $invalid_count"
    echo ""
    echo -e "${DIM}Use './verify.sh verify <id>' to mark a feature as verified${NC}"
    echo -e "${DIM}Use './verify.sh list' to see all feature IDs${NC}"
}

# Show detailed information about a feature including changes and checklist
show_details() {
    local feature="$1"

    # Check if feature exists
    if ! get_feature_ids | grep -q "^${feature}$"; then
        echo -e "${RED}Error:${NC} Feature '$feature' not found"
        echo "Use './verify.sh list' to see all feature IDs"
        return 1
    fi

    local name=$(get_yaml_value "$feature" "name")
    local desc=$(get_yaml_value "$feature" "description")
    local verified=$(get_yaml_value "$feature" "verified")
    local verified_by=$(get_yaml_value "$feature" "verified_by")
    local verified_at=$(get_yaml_value "$feature" "verified_at")
    local notes=$(get_yaml_value "$feature" "notes")

    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${WHITE}  $name${NC}"
    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${DIM}$desc${NC}"
    echo ""

    # Status
    echo -e "${BOLD}Status:${NC}"
    if [[ "$verified" == "true" ]]; then
        if check_feature_changed "$feature"; then
            echo -e "  ${YELLOW}${CHECK_INVALID}${NC} ${YELLOW}MODIFIED${NC} - verification invalidated"
            if [[ -n "$verified_by" && "$verified_by" != "null" ]]; then
                echo -e "  ${DIM}Previously verified by ${verified_by} at ${verified_at}${NC}"
            fi
        else
            echo -e "  ${GREEN}${CHECK_ON}${NC} ${GREEN}VERIFIED${NC}"
            if [[ -n "$verified_by" && "$verified_by" != "null" ]]; then
                echo -e "  ${DIM}Verified by ${verified_by} at ${verified_at}${NC}"
            fi
        fi
    else
        echo -e "  ${RED}${CHECK_OFF}${NC} ${RED}UNVERIFIED${NC}"
        if [[ -n "$notes" && "$notes" != "null" ]]; then
            echo -e "  ${DIM}Note: $notes${NC}"
        fi
    fi
    echo ""

    # Files that changed
    echo -e "${BOLD}Files:${NC}"
    local files=$(get_feature_files "$feature")
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            local filepath="${SCRIPT_DIR}/${file}"
            if [[ -f "$filepath" ]]; then
                echo -e "  ${CYAN}•${NC} $file"
                show_file_diff "$file"
            else
                echo -e "  ${RED}•${NC} $file ${DIM}(missing)${NC}"
            fi
        fi
    done <<< "$files"
    echo ""

    # Verification checklist
    echo -e "${BOLD}Verification Checklist:${NC}"
    local checklist=$(get_feature_checklist "$feature")
    if [[ -z "$checklist" ]]; then
        echo -e "  ${DIM}No specific checklist defined for this feature.${NC}"
        echo -e "  ${DIM}General verification steps:${NC}"
        echo -e "    ${WHITE}□${NC} Review the code changes"
        echo -e "    ${WHITE}□${NC} Test the feature manually"
        echo -e "    ${WHITE}□${NC} Check for edge cases"
        echo -e "    ${WHITE}□${NC} Verify error handling"
    else
        while IFS= read -r item; do
            if [[ -n "$item" ]]; then
                echo -e "  ${WHITE}□${NC} $item"
            fi
        done <<< "$checklist"
    fi
    echo ""

    # Recent git history for these files
    echo -e "${BOLD}Recent Changes (git log):${NC}"
    local all_files=""
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            all_files+=" $file"
        fi
    done <<< "$files"

    if [[ -n "$all_files" ]]; then
        local git_log=$(git -C "$SCRIPT_DIR" log --oneline -5 -- $all_files 2>/dev/null)
        if [[ -n "$git_log" ]]; then
            echo "$git_log" | while IFS= read -r line; do
                echo -e "  ${DIM}$line${NC}"
            done
        else
            echo -e "  ${DIM}No recent commits found${NC}"
        fi
    fi
    echo ""

    # Action hint
    if [[ "$verified" != "true" ]] || check_feature_changed "$feature"; then
        echo -e "${YELLOW}To verify this feature after checking:${NC}"
        echo -e "  ./verify.sh verify $feature"
    fi
}

# Check for invalidated verifications and update them
check_invalidations() {
    echo -e "${BOLD}Checking for modified files...${NC}"
    echo ""

    local invalidated=0
    local invalidated_features=()

    while IFS= read -r feature; do
        local verified=$(get_yaml_value "$feature" "verified")
        local name=$(get_yaml_value "$feature" "name")

        if [[ "$verified" == "true" ]]; then
            if check_feature_changed "$feature"; then
                echo -e "${YELLOW}!${NC} ${name}"

                # Show which files changed
                local files=$(get_feature_files "$feature")
                while IFS= read -r file; do
                    if [[ -n "$file" ]]; then
                        local last_commit=$(git -C "$SCRIPT_DIR" log -1 --format="%h %s" -- "$file" 2>/dev/null)
                        echo -e "    ${DIM}${file}: ${last_commit}${NC}"
                    fi
                done <<< "$files"

                # Mark as unverified
                update_yaml_value "$feature" "verified" "false"
                update_yaml_value "$feature" "verified_by" "null"
                update_yaml_value "$feature" "verified_at" "null"
                update_yaml_value "$feature" "notes" "\"Auto-invalidated: files changed\""
                invalidated_features+=("$feature")
                ((++invalidated))
                echo ""
            fi
        fi
    done <<< "$(get_feature_ids)"

    if [[ $invalidated -eq 0 ]]; then
        echo -e "${GREEN}✓${NC} All verifications are still valid"
    else
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}!${NC} $invalidated verification(s) invalidated due to file changes"
        echo ""
        echo -e "${BOLD}To see what needs to be re-verified:${NC}"
        for feat in "${invalidated_features[@]}"; do
            echo -e "  ./verify.sh details $feat"
        done
    fi
}

# Mark a feature as verified
verify_feature() {
    local feature="$1"
    local verifier="${2:-$(whoami)}"

    # Check if feature exists
    if ! get_feature_ids | grep -q "^${feature}$"; then
        echo -e "${RED}Error:${NC} Feature '$feature' not found"
        echo "Use './verify.sh list' to see all feature IDs"
        return 1
    fi

    local name=$(get_yaml_value "$feature" "name")
    local files=$(get_feature_files "$feature")
    local hash=$(calculate_hash "$files")
    local timestamp=$(date -Iseconds)

    update_yaml_value "$feature" "verified" "true"
    update_yaml_value "$feature" "verified_by" "\"$verifier\""
    update_yaml_value "$feature" "verified_at" "\"$timestamp\""
    update_yaml_value "$feature" "file_hash" "\"$hash\""
    update_yaml_value "$feature" "notes" "null"

    echo -e "${GREEN}✓${NC} Marked '$name' as verified by $verifier"
}

# Mark a feature as unverified
unverify_feature() {
    local feature="$1"

    # Check if feature exists
    if ! get_feature_ids | grep -q "^${feature}$"; then
        echo -e "${RED}Error:${NC} Feature '$feature' not found"
        echo "Use './verify.sh list' to see all feature IDs"
        return 1
    fi

    local name=$(get_yaml_value "$feature" "name")

    update_yaml_value "$feature" "verified" "false"
    update_yaml_value "$feature" "verified_by" "null"
    update_yaml_value "$feature" "verified_at" "null"
    update_yaml_value "$feature" "file_hash" "null"
    update_yaml_value "$feature" "notes" "null"

    echo -e "${RED}○${NC} Marked '$name' as unverified"
}

# List all feature IDs
list_features() {
    echo -e "${BOLD}Feature IDs:${NC}"
    echo ""

    while IFS= read -r feature; do
        local name=$(get_yaml_value "$feature" "name")
        local verified=$(get_yaml_value "$feature" "verified")

        local status
        if [[ "$verified" == "true" ]]; then
            if check_feature_changed "$feature"; then
                status="${YELLOW}!${NC}"
            else
                status="${GREEN}✓${NC}"
            fi
        else
            status="${RED}○${NC}"
        fi

        printf "  %b %-25s %b%b\n" "$status" "$feature" "${DIM}${name}" "${NC}"
    done <<< "$(get_feature_ids)"
}

# Show summary statistics
show_summary() {
    local verified=0
    local unverified=0
    local modified=0
    local total=0

    while IFS= read -r feature; do
        ((++total))
        local v=$(get_yaml_value "$feature" "verified")

        if [[ "$v" == "true" ]]; then
            if check_feature_changed "$feature"; then
                ((++modified))
            else
                ((++verified))
            fi
        else
            ((++unverified))
        fi
    done <<< "$(get_feature_ids)"

    local pct=0
    if [[ $total -gt 0 ]]; then
        pct=$((verified * 100 / total))
    fi

    echo -e "${BOLD}Verification Summary${NC}"
    echo -e "${DIM}═══════════════════════════════${NC}"
    echo ""
    echo -e "  Total features:  $total"
    echo -e "  ${GREEN}Verified:${NC}        $verified (${pct}%)"
    echo -e "  ${RED}Unverified:${NC}      $unverified"
    echo -e "  ${YELLOW}Modified:${NC}        $modified"
    echo ""

    # Progress bar
    local bar_width=40
    local filled=$((verified * bar_width / total))
    local empty=$((bar_width - filled))

    printf "  ["
    if [[ $filled -gt 0 ]]; then
        for ((i=0; i<filled; i++)); do printf "${GREEN}█${NC}"; done
    fi
    for ((i=0; i<empty; i++)); do printf "${DIM}░${NC}"; done
    printf "] %d%%\n" $pct
}

# Interactive verification mode
interactive_verify() {
    echo -e "${BOLD}Interactive Verification Mode${NC}"
    echo -e "${DIM}Enter feature ID to verify, or 'q' to quit${NC}"
    echo ""

    list_features
    echo ""

    while true; do
        echo -n "Feature ID (or 'q'): "
        read -r input

        if [[ "$input" == "q" || "$input" == "quit" ]]; then
            break
        fi

        if [[ -n "$input" ]]; then
            echo -n "Your name (or Enter for $(whoami)): "
            read -r verifier
            verifier="${verifier:-$(whoami)}"

            verify_feature "$input" "$verifier" || true
            echo ""
        fi
    done
}

# Reset all verifications
reset_all() {
    echo -n "Are you sure you want to reset all verifications? [y/N] "
    read -r confirm

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        while IFS= read -r feature; do
            update_yaml_value "$feature" "verified" "false"
            update_yaml_value "$feature" "verified_by" "null"
            update_yaml_value "$feature" "verified_at" "null"
            update_yaml_value "$feature" "file_hash" "null"
            update_yaml_value "$feature" "notes" "null"
        done <<< "$(get_feature_ids)"

        echo -e "${GREEN}✓${NC} All verifications have been reset"
    else
        echo "Cancelled"
    fi
}

# Main
main() {
    local command="${1:-status}"

    if [[ ! -f "$VERIFICATION_FILE" ]]; then
        echo -e "${RED}Error:${NC} Verification file not found: $VERIFICATION_FILE"
        exit 1
    fi

    case "$command" in
        status)
            show_status
            ;;
        check)
            check_invalidations
            ;;
        details)
            if [[ -z "${2:-}" ]]; then
                echo "Usage: ./verify.sh details <feature_id>"
                echo ""
                echo "Shows what changed and what needs to be verified."
                exit 1
            fi
            show_details "$2"
            ;;
        verify)
            if [[ -n "${2:-}" ]]; then
                verify_feature "$2" "${3:-}"
            else
                interactive_verify
            fi
            ;;
        unverify)
            if [[ -z "${2:-}" ]]; then
                echo "Usage: ./verify.sh unverify <feature_id>"
                exit 1
            fi
            unverify_feature "$2"
            ;;
        list)
            list_features
            ;;
        summary)
            show_summary
            ;;
        reset)
            reset_all
            ;;
        help|--help|-h)
            echo "Usage: ./verify.sh [command] [args]"
            echo ""
            echo "Commands:"
            echo "  status        Show verification status (default)"
            echo "  check         Check for invalidated verifications"
            echo "  details <id>  Show what changed and verification checklist"
            echo "  verify        Interactive verification mode"
            echo "  verify <id>   Mark a specific feature as verified"
            echo "  unverify <id> Mark a specific feature as unverified"
            echo "  list          List all feature IDs"
            echo "  summary       Show summary statistics"
            echo "  reset         Reset all verifications"
            echo "  help          Show this help message"
            echo ""
            echo "When a verification is invalidated due to code changes:"
            echo "  1. Run './verify.sh details <id>' to see what changed"
            echo "  2. Review the verification checklist"
            echo "  3. Test the feature manually"
            echo "  4. Run './verify.sh verify <id>' to re-verify"
            ;;
        *)
            echo "Unknown command: $command"
            echo "Use './verify.sh help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
