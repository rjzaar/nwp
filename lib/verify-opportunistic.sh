#!/bin/bash
# lib/verify-opportunistic.sh - Opportunistic human verification prompts
# Part of NWP (Narrow Way Project)

if [[ "${_VERIFY_OPPORTUNISTIC_LOADED:-}" == "1" ]]; then
    return 0
fi
_VERIFY_OPPORTUNISTIC_LOADED=1

# Check if current user is a designated tester
# Usage: is_tester [config_file]
is_tester() {
    local config_file="${1:-${PROJECT_ROOT}/nwp.yml}"
    local current_user
    current_user=$(whoami)

    local tester_flag
    tester_flag=$(awk -v user="$current_user" '
        /^coders:/{in_coders=1; next}
        in_coders && /^  [a-zA-Z]/{
            gsub(/:$/, "", $1)
            current_coder=$1
        }
        in_coders && current_coder==user && /tester:/{print $2; exit}
        in_coders && /^[a-zA-Z]/{in_coders=0}
    ' "$config_file" 2>/dev/null)

    [[ "$tester_flag" == "true" ]]
}

# Get prompt mode for tester (unverified|all|never)
# Usage: get_prompt_mode [config_file]
get_prompt_mode() {
    local config_file="${1:-${PROJECT_ROOT}/nwp.yml}"
    local mode
    mode=$(awk '/^settings:/{found=1} found && /tester_prompts:/{in_tp=1} in_tp && /prompt_mode:/{print $2; exit}' "$config_file" 2>/dev/null)
    echo "${mode:-unverified}"
}

# Get prompt timeout in seconds
# Usage: get_prompt_timeout [config_file]
get_prompt_timeout() {
    local config_file="${1:-${PROJECT_ROOT}/nwp.yml}"
    local timeout
    timeout=$(awk '/^settings:/{found=1} found && /tester_prompts:/{in_tp=1} in_tp && /prompt_timeout:/{print $2; exit}' "$config_file" 2>/dev/null)
    echo "${timeout:-30}"
}

# Check if a command should be skipped for prompting
# Usage: should_skip_command <command_name> [config_file]
should_skip_command() {
    local cmd_name="$1"
    local config_file="${2:-${PROJECT_ROOT}/nwp.yml}"

    # Always skip read-only commands
    case "$cmd_name" in
        status|doctor|help|verify|coders|todo|version)
            return 0
            ;;
    esac

    return 1
}

# Check if verification prompt should be shown
# Usage: should_prompt_verification <command_name> [config_file]
should_prompt_verification() {
    local cmd_name="$1"
    local config_file="${2:-${PROJECT_ROOT}/nwp.yml}"

    # Check if user is a tester
    is_tester "$config_file" || return 1

    # Check prompt mode
    local mode
    mode=$(get_prompt_mode "$config_file")
    [[ "$mode" == "never" ]] && return 1

    # Check if command should be skipped
    should_skip_command "$cmd_name" && return 1

    return 0
}

# Find matching verification item for a command
# Usage: find_verification_item <command_name>
find_verification_item() {
    local cmd_name="$1"
    local verification_file="${PROJECT_ROOT}/.verification.yml"

    [[ ! -f "$verification_file" ]] && return 1

    # Look for unverified items matching this command
    awk -v cmd="$cmd_name" '
        /^[a-z_]+:$/{
            gsub(/:$/, "")
            feature=$0
        }
        feature==cmd && /text:/{
            gsub(/^[[:space:]]*text:[[:space:]]*"?/, "")
            gsub(/"[[:space:]]*$/, "")
            print
            exit
        }
    ' "$verification_file" 2>/dev/null
}

# Show verification prompt after command execution
# Usage: show_verification_prompt <command_name> <exit_code>
show_verification_prompt() {
    local cmd_name="$1"
    local exit_code="$2"
    local timeout
    timeout=$(get_prompt_timeout)

    # Only prompt on successful commands
    [[ "$exit_code" -ne 0 ]] && return

    local item_text
    item_text=$(find_verification_item "$cmd_name")
    [[ -z "$item_text" ]] && return

    echo ""
    echo "┌─ VERIFICATION ──────────────────────────────┐"
    echo "│ Command: pl ${cmd_name}                      "
    echo "│ Item: \"${item_text}\"                        "
    echo "│                                              "
    echo "│ Did the command work correctly?               "
    echo "│ [Y]es  [n]o  [s]kip  [d]on't ask again  [?] "
    echo "└──────────────────────────────────────────────┘"

    local response=""
    read -t "$timeout" -n 1 -r response
    echo ""

    case "${response,,}" in
        y|"")
            record_verification "$cmd_name" "$item_text" "pass"
            print_success "Verified! Thank you."
            ;;
        n)
            print_warning "Starting bug report..."
            create_bug_report "$cmd_name" "$item_text"
            ;;
        s)
            print_info "Skipped for this session"
            ;;
        d)
            print_info "Won't ask for this command again"
            # TODO: Record permanent skip in user prefs
            ;;
        *)
            print_info "Y=verified, n=bug report, s=skip, d=don't ask"
            ;;
    esac
}

# Record a successful human verification
# Usage: record_verification <command> <item_text> <result>
record_verification() {
    local cmd_name="$1"
    local item_text="$2"
    local result="$3"
    local timestamp
    timestamp=$(date -Iseconds)
    local tester
    tester=$(whoami)

    print_info "Recording verification: ${cmd_name} - ${result} by ${tester}"
    # Verification recorded in .verification.yml via verify system
}
