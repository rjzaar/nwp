#!/bin/bash

################################################################################
# NWP Coders Management TUI
#
# Interactive terminal interface for managing NWP coders with:
# - Auto-listing of all coders on startup
# - Onboarding status columns (GitLab, DNS, Server, Site)
# - Arrow key navigation
# - Bulk actions (delete, promote)
# - Auto-sync from GitLab
# - Detailed stats view
#
# Usage:
#   ./coders.sh              - Launch TUI
#   ./coders.sh list         - List all coders (non-interactive)
#   ./coders.sh sync         - Sync from GitLab (non-interactive)
#
# TUI Controls:
#   Up/Down    - Navigate coders
#   Space      - Select/deselect for bulk actions
#   Enter      - View detailed stats
#   M          - Modify selected coder
#   P          - Promote selected/marked coders
#   D          - Delete selected/marked coders
#   A          - Add new coder
#   S          - Sync from GitLab
#   /          - Filter/search
#   Q          - Quit
#
################################################################################

# Note: Don't use set -e in interactive TUIs - it causes crashes on edge cases

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/yaml-write.sh"
source "$PROJECT_ROOT/lib/git.sh"

# Configuration
CONFIG_FILE="${PROJECT_ROOT}/cnwp.yml"
CODER_SETUP="${SCRIPT_DIR}/coder-setup.sh"

# TUI State
declare -a CODERS=()
declare -a CODER_DATA=()
declare -a CODER_STATUS=()  # Onboarding status: GL|GRP|NS|DNS|SRV|SITE
declare -a SELECTED=()
CURRENT_INDEX=0
FILTER=""
LAST_SYNC=""
TERMINAL_HEIGHT=0
TERMINAL_WIDTH=0
LIST_START=0
STATUS_CHECKED=false

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[0;37m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly REVERSE='\033[7m'
readonly NC='\033[0m'

################################################################################
# Terminal Helpers
################################################################################

# Get terminal size
get_terminal_size() {
    TERMINAL_HEIGHT=$(tput lines)
    TERMINAL_WIDTH=$(tput cols)
}

# Move cursor
cursor_to() {
    printf '\033[%d;%dH' "$1" "$2"
}

# Clear line
clear_line() {
    printf '\033[2K'
}

# Hide cursor
hide_cursor() {
    printf '\033[?25l'
}

# Show cursor
show_cursor() {
    printf '\033[?25h'
}

# Save screen
save_screen() {
    printf '\033[?1049h'
}

# Restore screen
restore_screen() {
    printf '\033[?1049l'
}

# Read single key (including arrow keys)
read_key() {
    local key
    IFS= read -rsn1 key

    # Check for escape sequence (arrow keys)
    if [[ "$key" == $'\033' ]]; then
        read -rsn2 -t 0.1 key
        case "$key" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            '[5') read -rsn1; echo "PGUP" ;;
            '[6') read -rsn1; echo "PGDN" ;;
            *) echo "ESC" ;;
        esac
    else
        case "$key" in
            '') echo "ENTER" ;;
            ' ') echo "SPACE" ;;
            $'\177') echo "BACKSPACE" ;;
            *) echo "$key" ;;
        esac
    fi
}

################################################################################
# Onboarding Status Check Functions
################################################################################

# Check if GitLab user exists
check_gitlab_user() {
    local name="$1"
    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    [[ -z "$gitlab_url" || -z "$token" ]] && echo "?" && return

    local user_id=$(curl -s --max-time 5 -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/users?username=${name}" 2>/dev/null | jq -r '.[0].id // empty')

    [[ -n "$user_id" ]] && echo "Y" || echo "N"
}

# Check if user is in GitLab group
check_gitlab_group() {
    local name="$1"
    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    [[ -z "$gitlab_url" || -z "$token" ]] && echo "?" && return

    local user_id=$(curl -s --max-time 5 -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/users?username=${name}" 2>/dev/null | jq -r '.[0].id // empty')

    [[ -z "$user_id" ]] && echo "N" && return

    # Check if in nwp group
    local group_id=$(curl -s --max-time 5 -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/groups?search=nwp" 2>/dev/null | jq -r '.[0].id // empty')

    [[ -z "$group_id" ]] && echo "?" && return

    local member=$(curl -s --max-time 5 -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/groups/${group_id}/members/${user_id}" 2>/dev/null | jq -r '.id // empty')

    [[ -n "$member" ]] && echo "Y" || echo "N"
}

# Get base domain (works with or without yq)
get_base_domain_for_check() {
    if command -v yq &>/dev/null; then
        get_base_domain_for_check
    else
        local result=$(awk '
            /^settings:/ { in_section = 1; next }
            in_section && /^[a-zA-Z]/ && !/^  / { in_section = 0 }
            in_section && /^  url:/ {
                sub(/^  url: */, "")
                sub(/#.*/, "")
                gsub(/["'"'"']/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                if (length($0) > 0) print
                exit
            }
        ' "$CONFIG_FILE" 2>/dev/null)
        echo "${result:-nwpcode.org}"
    fi
}

# Get coder field from config (works with or without yq)
get_coder_field() {
    local name="$1"
    local field="$2"

    if command -v yq &>/dev/null; then
        yq -r ".other_coders.coders.${name}.${field} // empty" "$CONFIG_FILE" 2>/dev/null
    else
        awk -v coder="$name" -v field="$field" '
            /^other_coders:/ { in_other = 1; next }
            in_other && /^  coders:/ { in_coders = 1; next }
            in_coders && $0 ~ "^    " coder ":" { in_coder = 1; next }
            in_coder && /^    [a-zA-Z]/ && !/^      / { in_coder = 0 }
            in_coder && $0 ~ "^      " field ":" {
                sub(/^      [a-zA-Z_]+: */, "")
                gsub(/["'"'"']/, "")
                print
                exit
            }
        ' "$CONFIG_FILE" 2>/dev/null
    fi
}

# Check NS delegation
check_ns_delegation() {
    local name="$1"
    local base_domain=$(get_base_domain_for_check)
    local subdomain="${name}.${base_domain}"

    local ns=$(dig NS "$subdomain" +short +time=2 +tries=1 2>/dev/null | head -1)

    [[ -n "$ns" ]] && echo "Y" || echo "N"
}

# Check DNS A records
check_dns_records() {
    local name="$1"
    local base_domain=$(get_base_domain_for_check)
    local subdomain="${name}.${base_domain}"

    local ip=$(dig A "$subdomain" +short +time=2 +tries=1 2>/dev/null | head -1)

    [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "Y" || echo "N"
}

# Check server exists (from config or Linode)
check_server() {
    local name="$1"

    # First check config for server_ip
    local server_ip=$(get_coder_field "$name" "server_ip")

    if [[ -n "$server_ip" && "$server_ip" != "null" ]]; then
        echo "Y"
        return
    fi

    # Check if linode_label exists
    local linode_label=$(get_coder_field "$name" "linode_label")

    [[ -n "$linode_label" && "$linode_label" != "null" ]] && echo "Y" || echo "N"
}

# Check site is accessible
check_site() {
    local name="$1"
    local base_domain=$(get_base_domain_for_check)
    local subdomain="${name}.${base_domain}"

    # Try to reach the site
    local status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${subdomain}" 2>/dev/null)

    [[ "$status" =~ ^(200|301|302|303)$ ]] && echo "Y" || echo "N"
}

# Determine if step is required based on role
# Returns: Y=required, N=not required
step_required() {
    local step="$1"  # GL, GRP, NS, DNS, SRV, SITE
    local role="$2"  # steward, core, contributor, newcomer

    case "$step" in
        GL|GRP)
            # All coders need GitLab access
            echo "Y"
            ;;
        NS|DNS)
            # Core+ need their own subdomain
            case "$role" in
                steward|core) echo "Y" ;;
                *) echo "N" ;;
            esac
            ;;
        SRV|SITE)
            # Only core+ need their own server/site
            case "$role" in
                steward|core) echo "Y" ;;
                *) echo "N" ;;
            esac
            ;;
        *)
            echo "Y"
            ;;
    esac
}

# Load onboarding status for a coder (returns: GL|GRP|NS|DNS|SRV|SITE)
# Values: Y=yes, N=no, ?=unknown, -=not required
load_coder_status() {
    local name="$1"
    local role="$2"

    local gl grp ns dns srv site

    # Check each step, respecting role requirements
    if [[ $(step_required "GL" "$role") == "Y" ]]; then
        gl=$(check_gitlab_user "$name")
    else
        gl="-"
    fi

    if [[ $(step_required "GRP" "$role") == "Y" ]]; then
        grp=$(check_gitlab_group "$name")
    else
        grp="-"
    fi

    if [[ $(step_required "NS" "$role") == "Y" ]]; then
        ns=$(check_ns_delegation "$name")
    else
        ns="-"
    fi

    if [[ $(step_required "DNS" "$role") == "Y" ]]; then
        dns=$(check_dns_records "$name")
    else
        dns="-"
    fi

    if [[ $(step_required "SRV" "$role") == "Y" ]]; then
        srv=$(check_server "$name")
    else
        srv="-"
    fi

    if [[ $(step_required "SITE" "$role") == "Y" ]]; then
        site=$(check_site "$name")
    else
        site="-"
    fi

    echo "${gl}|${grp}|${ns}|${dns}|${srv}|${site}"
}

################################################################################
# Data Functions
################################################################################

# Load coders from config
load_coders() {
    CODERS=()
    CODER_DATA=()
    CODER_STATUS=()
    SELECTED=()
    STATUS_CHECKED=false

    local coders_list
    if command -v yq &>/dev/null; then
        coders_list=$(yq -r '.other_coders.coders | keys[]' "$CONFIG_FILE" 2>/dev/null || echo "")
    else
        coders_list=$(awk '
            /^other_coders:/ { in_other = 1; next }
            in_other && /^[a-zA-Z]/ && !/^  / { in_other = 0 }
            in_other && /^  coders:/ { in_coders = 1; next }
            in_coders && /^  [a-zA-Z]/ && !/^    / { in_coders = 0 }
            in_coders && /^    [a-zA-Z][a-zA-Z0-9_-]*:/ {
                sub(/^    /, "")
                sub(/:.*/, "")
                print
            }
        ' "$CONFIG_FILE" 2>/dev/null)
    fi

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        CODERS+=("$name")
        SELECTED+=(0)

        # Load coder data
        local role status added commits mrs reviews
        if command -v yq &>/dev/null; then
            role=$(yq -r ".other_coders.coders.$name.role // \"contributor\"" "$CONFIG_FILE" 2>/dev/null)
            status=$(yq -r ".other_coders.coders.$name.status // \"active\"" "$CONFIG_FILE" 2>/dev/null)
            added=$(yq -r ".other_coders.coders.$name.added // \"\"" "$CONFIG_FILE" 2>/dev/null)
            commits=$(yq -r ".other_coders.coders.$name.commits // 0" "$CONFIG_FILE" 2>/dev/null)
            mrs=$(yq -r ".other_coders.coders.$name.merge_requests // 0" "$CONFIG_FILE" 2>/dev/null)
            reviews=$(yq -r ".other_coders.coders.$name.reviews // 0" "$CONFIG_FILE" 2>/dev/null)
        else
            role="contributor"
            status="active"
            added=""
            commits=0
            mrs=0
            reviews=0
        fi

        CODER_DATA+=("$role|$status|${added:0:10}|$commits|$mrs|$reviews")
        # Initialize status as unknown (will be checked later)
        CODER_STATUS+=("?|?|?|?|?|?")
    done <<< "$coders_list"
}

# Check onboarding status for all coders (run after initial load)
check_all_status() {
    for i in "${!CODERS[@]}"; do
        local name="${CODERS[$i]}"
        local data="${CODER_DATA[$i]:-contributor|active||0|0|0}"
        local role=$(echo "$data" | cut -d'|' -f1)

        # Update status row in TUI
        get_terminal_size
        local status_row=$((TERMINAL_HEIGHT - 1))
        cursor_to "$status_row" 1
        clear_line
        printf " ${DIM}Checking: %s...${NC}" "$name"

        CODER_STATUS[$i]=$(load_coder_status "$name" "$role")
        draw_coder_row "$i" $((5 + i - LIST_START)) 2>/dev/null || true
    done

    STATUS_CHECKED=true

    # Clear status message
    get_terminal_size
    local status_row=$((TERMINAL_HEIGHT - 1))
    cursor_to "$status_row" 1
    clear_line
}

# Sync from GitLab
sync_from_gitlab() {
    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [[ -z "$gitlab_url" || -z "$token" ]]; then
        return 1
    fi

    for i in "${!CODERS[@]}"; do
        local name="${CODERS[$i]}"

        # Get user info from GitLab
        local user_info=$(curl -s -H "PRIVATE-TOKEN: $token" \
            "https://${gitlab_url}/api/v4/users?username=${name}" 2>/dev/null)

        local user_id=$(echo "$user_info" | jq -r '.[0].id // empty' 2>/dev/null)

        if [[ -n "$user_id" ]]; then
            # Get events
            local events=$(curl -s -H "PRIVATE-TOKEN: $token" \
                "https://${gitlab_url}/api/v4/users/${user_id}/events?per_page=100" 2>/dev/null)

            local commits=$(echo "$events" | jq '[.[] | select(.action_name=="pushed to" or .action_name=="pushed new")] | length' 2>/dev/null || echo "0")
            local mrs=$(echo "$events" | jq '[.[] | select(.target_type=="MergeRequest" and .action_name=="opened")] | length' 2>/dev/null || echo "0")
            local reviews=$(echo "$events" | jq '[.[] | select(.target_type=="MergeRequest" and (.action_name=="approved" or .action_name=="commented on"))] | length' 2>/dev/null || echo "0")

            # Update config
            if command -v yq &>/dev/null; then
                yq -i ".other_coders.coders.$name.commits = $commits" "$CONFIG_FILE" 2>/dev/null
                yq -i ".other_coders.coders.$name.merge_requests = $mrs" "$CONFIG_FILE" 2>/dev/null
                yq -i ".other_coders.coders.$name.reviews = $reviews" "$CONFIG_FILE" 2>/dev/null
                yq -i ".other_coders.coders.$name.last_sync = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$CONFIG_FILE" 2>/dev/null
            fi

            # Update local data
            local old_data="${CODER_DATA[$i]}"
            local role=$(echo "$old_data" | cut -d'|' -f1)
            local status=$(echo "$old_data" | cut -d'|' -f2)
            local added=$(echo "$old_data" | cut -d'|' -f3)
            CODER_DATA[$i]="$role|$status|$added|$commits|$mrs|$reviews"
        fi
    done

    LAST_SYNC=$(date +"%H:%M:%S")
}

# Get role display
role_display() {
    case "$1" in
        steward)     echo "Steward" ;;
        core)        echo "Core" ;;
        contributor) echo "Contrib" ;;
        newcomer)    echo "New" ;;
        *)           echo "$1" ;;
    esac
}

# Role to level
role_level() {
    case "$1" in
        steward)     echo 50 ;;
        core)        echo 40 ;;
        contributor) echo 30 ;;
        *)           echo 0 ;;
    esac
}

# Status color
status_color() {
    case "$1" in
        active)    echo "${GREEN}" ;;
        inactive)  echo "${YELLOW}" ;;
        suspended) echo "${RED}" ;;
        *)         echo "${WHITE}" ;;
    esac
}

# Role color
role_color() {
    case "$1" in
        steward)     echo "${MAGENTA}" ;;
        core)        echo "${CYAN}" ;;
        contributor) echo "${GREEN}" ;;
        newcomer)    echo "${DIM}" ;;
        *)           echo "${WHITE}" ;;
    esac
}

################################################################################
# Drawing Functions
################################################################################

draw_header() {
    cursor_to 1 1
    clear_line
    printf "${BOLD}${REVERSE} NWP CODER MANAGEMENT ${NC}"
    printf "  ${DIM}%d coders${NC}" "${#CODERS[@]}"

    if [[ -n "$LAST_SYNC" ]]; then
        printf "  ${DIM}Synced: %s${NC}" "$LAST_SYNC"
    fi

    # Show selected count
    local selected_count=0
    for s in "${SELECTED[@]}"; do
        ((s)) && ((selected_count++))
    done
    if ((selected_count > 0)); then
        printf "  ${YELLOW}[%d selected]${NC}" "$selected_count"
    fi

    printf "\n"
}

draw_column_headers() {
    cursor_to 3 1
    clear_line
    printf "${BOLD}${DIM}"
    printf "   %-12s %-8s " "NAME" "ROLE"
    # Onboarding status columns
    printf "%3s %3s %3s %3s %3s %4s  " "GL" "GRP" "NS" "DNS" "SRV" "SITE"
    printf "%6s %4s" "COMMIT" "MRs"
    printf "${NC}\n"

    cursor_to 4 1
    clear_line
    printf "${DIM}"
    printf "   %-12s %-8s " "────────────" "────────"
    printf "%3s %3s %3s %3s %3s %4s  " "──" "───" "──" "───" "───" "────"
    printf "%6s %4s" "──────" "────"
    printf "${NC}\n"
}

draw_coder_row() {
    local index=$1
    local row=$2

    # Bounds check
    ((index < 0 || index >= ${#CODERS[@]})) && return

    local name="${CODERS[$index]}"
    local data="${CODER_DATA[$index]:-contributor|active||0|0|0}"
    local onboard_status="${CODER_STATUS[$index]:-?|?|?|?|?|?}"

    local role=$(echo "$data" | cut -d'|' -f1)
    local status=$(echo "$data" | cut -d'|' -f2)
    local added=$(echo "$data" | cut -d'|' -f3)
    local commits=$(echo "$data" | cut -d'|' -f4)
    local mrs=$(echo "$data" | cut -d'|' -f5)
    local reviews=$(echo "$data" | cut -d'|' -f6)

    # Parse onboarding status
    local gl=$(echo "$onboard_status" | cut -d'|' -f1)
    local grp=$(echo "$onboard_status" | cut -d'|' -f2)
    local ns=$(echo "$onboard_status" | cut -d'|' -f3)
    local dns=$(echo "$onboard_status" | cut -d'|' -f4)
    local srv=$(echo "$onboard_status" | cut -d'|' -f5)
    local site=$(echo "$onboard_status" | cut -d'|' -f6)

    cursor_to "$row" 1
    clear_line

    # Selection marker
    local is_selected=${SELECTED[$index]:-0}
    if ((is_selected)); then
        printf "${YELLOW}*${NC} "
    else
        printf "  "
    fi

    # Highlight current row
    if ((index == CURRENT_INDEX)); then
        printf "${REVERSE}"
    fi

    # Checkbox for selection
    if ((is_selected)); then
        printf "${YELLOW}[x]${NC}"
    else
        printf "[ ]"
    fi

    # Name (truncated to 11 chars)
    printf " %-11s" "${name:0:11}"

    # Role with color
    local rc=$(role_color "$role")
    printf " ${rc}%-7s${NC}" "$(role_display "$role")"

    # Onboarding status columns with colors
    print_status_cell "$gl"
    print_status_cell "$grp"
    print_status_cell "$ns"
    print_status_cell "$dns"
    print_status_cell "$srv"
    print_status_cell "$site" 4

    # Stats
    printf " %6s" "$commits"
    printf " %4s" "$mrs"

    if ((index == CURRENT_INDEX)); then
        printf "${NC}"
    fi
}

# Print a status cell with appropriate color
# Y=green ✓, N=red ✗, ?=yellow ?, -=dim -
# Note: '-' must come before '?' since '?' is a glob pattern matching any char
print_status_cell() {
    local val="$1"
    local width="${2:-3}"

    case "$val" in
        Y) printf " ${GREEN}%*s${NC}" "$width" "✓" ;;
        N) printf " ${RED}%*s${NC}" "$width" "✗" ;;
        -) printf " ${DIM}%*s${NC}" "$width" "-" ;;
        '?') printf " ${YELLOW}%*s${NC}" "$width" "?" ;;
        *) printf " %*s" "$width" "$val" ;;
    esac
}

draw_coder_list() {
    get_terminal_size

    local list_height=$((TERMINAL_HEIGHT - 10))
    local visible_count=${#CODERS[@]}

    # Adjust scroll position
    if ((CURRENT_INDEX < LIST_START)); then
        LIST_START=$CURRENT_INDEX
    elif ((CURRENT_INDEX >= LIST_START + list_height)); then
        LIST_START=$((CURRENT_INDEX - list_height + 1))
    fi

    local row=5
    for ((i = LIST_START; i < ${#CODERS[@]} && i < LIST_START + list_height; i++)); do
        draw_coder_row "$i" "$row"
        ((row++))
    done

    # Clear remaining rows
    while ((row < 5 + list_height)); do
        cursor_to "$row" 1
        clear_line
        ((row++))
    done
}

draw_footer() {
    get_terminal_size
    local footer_row=$((TERMINAL_HEIGHT - 4))

    # Separator
    cursor_to "$footer_row" 1
    clear_line
    printf "${DIM}%s${NC}" "$(printf '─%.0s' $(seq 1 $TERMINAL_WIDTH))"

    # Selected coder info
    ((footer_row++))
    cursor_to "$footer_row" 1
    clear_line

    if ((${#CODERS[@]} > 0)); then
        local name="${CODERS[$CURRENT_INDEX]}"
        local data="${CODER_DATA[$CURRENT_INDEX]}"
        local role=$(echo "$data" | cut -d'|' -f1)
        local commits=$(echo "$data" | cut -d'|' -f4)
        local mrs=$(echo "$data" | cut -d'|' -f5)

        printf " ${BOLD}%s${NC}" "$name"
        printf " - $(role_color "$role")%s${NC}" "$(role_display "$role")"
        printf " | ${DIM}%s commits, %s MRs${NC}" "$commits" "$mrs"

        # Show subdomain
        local base_domain=$(get_base_domain_for_check)
        printf " | ${DIM}%s.%s${NC}" "$name" "$base_domain"
    fi

    # Help line
    ((footer_row++))
    cursor_to "$footer_row" 1
    clear_line
    printf " ${DIM}↑↓${NC} Nav  "
    printf "${DIM}Space${NC} Sel  "
    printf "${DIM}Enter${NC} Details  "
    printf "${DIM}M${NC}od  "
    printf "${DIM}P${NC}rom  "
    printf "${DIM}D${NC}el  "
    printf "${DIM}A${NC}dd  "
    printf "${DIM}S${NC}ync  "
    printf "${DIM}C${NC}heck  "
    printf "${DIM}H${NC}elp  "
    printf "${DIM}O${NC}pen doc  "
    printf "${DIM}Q${NC}uit"

    # Status line
    ((footer_row++))
    cursor_to "$footer_row" 1
    clear_line
}

draw_screen() {
    draw_header
    draw_column_headers
    draw_coder_list
    draw_footer
}

################################################################################
# Action Functions
################################################################################

# Show detailed stats
show_details() {
    if ((${#CODERS[@]} == 0)); then
        return
    fi

    local name="${CODERS[$CURRENT_INDEX]}"
    local data="${CODER_DATA[$CURRENT_INDEX]}"

    local role=$(echo "$data" | cut -d'|' -f1)
    local status=$(echo "$data" | cut -d'|' -f2)
    local added=$(echo "$data" | cut -d'|' -f3)
    local commits=$(echo "$data" | cut -d'|' -f4)
    local mrs=$(echo "$data" | cut -d'|' -f5)
    local reviews=$(echo "$data" | cut -d'|' -f6)

    clear
    cursor_to 1 1

    printf "${BOLD}${REVERSE} CODER DETAILS: %s ${NC}\n\n" "$name"

    printf "${BOLD}Identity${NC}\n"
    printf "  Name:       %s\n" "$name"
    printf "  Role:       $(role_color "$role")%s${NC} (level %s)\n" "$(role_display "$role")" "$(role_level "$role")"
    printf "  Status:     $(status_color "$status")%s${NC}\n" "$status"
    printf "  Registered: %s\n" "${added:-Unknown}"

    local base_domain=$(get_base_domain_for_check)
    printf "  Subdomain:  %s.%s\n" "$name" "$base_domain"
    printf "\n"

    printf "${BOLD}Contributions${NC}\n"

    # Visual bars
    local max=40
    local c_bar=$(printf '%*s' $((commits < max ? commits : max)) '' | tr ' ' '█')
    local m_bar=$(printf '%*s' $((mrs < max ? mrs : max)) '' | tr ' ' '█')
    local r_bar=$(printf '%*s' $((reviews < max ? reviews : max)) '' | tr ' ' '█')

    printf "  Commits:        %4s  ${GREEN}%s${NC}\n" "$commits" "$c_bar"
    printf "  Merge Requests: %4s  ${CYAN}%s${NC}\n" "$mrs" "$m_bar"
    printf "  Reviews:        %4s  ${MAGENTA}%s${NC}\n" "$reviews" "$r_bar"
    printf "\n"

    printf "${BOLD}Promotion Path${NC}\n"
    case "$role" in
        newcomer)
            printf "  ${DIM}Current:${NC} Newcomer\n"
            printf "  ${YELLOW}Next:${NC}    Contributor (requires 5+ merged PRs, 1+ month)\n"
            ;;
        contributor)
            printf "  ${DIM}Current:${NC} Contributor\n"
            printf "  ${YELLOW}Next:${NC}    Core Developer (requires 50+ MRs, 6+ months, vouched)\n"
            ;;
        core)
            printf "  ${DIM}Current:${NC} Core Developer\n"
            printf "  ${YELLOW}Next:${NC}    Steward (requires nomination + governance vote)\n"
            ;;
        steward)
            printf "  ${GREEN}Highest level achieved${NC}\n"
            ;;
    esac
    printf "\n"

    printf "${BOLD}Actions${NC}\n"
    printf "  [P] Promote    [M] Modify    [D] Delete    [V] Verify DNS\n"
    printf "\n"
    printf "${DIM}Press any key to return...${NC}"

    read_key >/dev/null
}

# Modify coder
modify_coder() {
    if ((${#CODERS[@]} == 0)); then
        return
    fi

    local name="${CODERS[$CURRENT_INDEX]}"
    local data="${CODER_DATA[$CURRENT_INDEX]}"
    local role=$(echo "$data" | cut -d'|' -f1)
    local status=$(echo "$data" | cut -d'|' -f2)

    clear
    cursor_to 1 1
    show_cursor

    printf "${BOLD}${REVERSE} MODIFY CODER: %s ${NC}\n\n" "$name"

    printf "Current: role=%s, status=%s\n\n" "$role" "$status"

    printf "What to modify?\n"
    printf "  [1] Role\n"
    printf "  [2] Status\n"
    printf "  [3] Notes\n"
    printf "  [C] Cancel\n\n"

    read -p "Choice: " choice

    case "${choice,,}" in
        1)
            printf "\nAvailable roles:\n"
            printf "  [1] newcomer\n"
            printf "  [2] contributor\n"
            printf "  [3] core\n"
            printf "  [4] steward\n"
            read -p "New role [1-4]: " rc
            local new_role
            case "$rc" in
                1) new_role="newcomer" ;;
                2) new_role="contributor" ;;
                3) new_role="core" ;;
                4) new_role="steward" ;;
                *) hide_cursor; return ;;
            esac
            yq -i ".other_coders.coders.$name.role = \"$new_role\"" "$CONFIG_FILE" 2>/dev/null
            ;;
        2)
            printf "\nAvailable statuses: active, inactive, suspended\n"
            read -p "New status: " new_status
            yq -i ".other_coders.coders.$name.status = \"$new_status\"" "$CONFIG_FILE" 2>/dev/null
            ;;
        3)
            read -p "New notes: " new_notes
            yq -i ".other_coders.coders.$name.notes = \"$new_notes\"" "$CONFIG_FILE" 2>/dev/null
            ;;
    esac

    load_coders
    hide_cursor
}

# Add new coder
add_coder() {
    clear
    show_cursor
    cursor_to 1 1

    printf "${BOLD}${REVERSE} ADD NEW CODER ${NC}\n\n"

    read -p "Coder name: " name
    if [[ -z "$name" ]]; then
        hide_cursor
        return
    fi

    read -p "Email address: " email
    read -p "Full name [$name]: " fullname
    [[ -z "$fullname" ]] && fullname="$name"

    printf "\nCreating coder...\n"

    if "$CODER_SETUP" add "$name" --email "$email" --fullname "$fullname" 2>&1; then
        yq -i ".other_coders.coders.$name.role = \"contributor\"" "$CONFIG_FILE" 2>/dev/null
        printf "\n${GREEN}Coder added successfully${NC}\n"
    else
        printf "\n${RED}Failed to add coder${NC}\n"
    fi

    printf "\nPress any key to continue..."
    read -rsn1

    load_coders
    hide_cursor
}

# Promote selected coders
promote_coders() {
    local to_promote=()

    # Get selected or current
    local selected_count=0
    for i in "${!SELECTED[@]}"; do
        if ((SELECTED[i])); then
            to_promote+=("${CODERS[$i]}")
            ((selected_count++))
        fi
    done

    if ((selected_count == 0)); then
        to_promote+=("${CODERS[$CURRENT_INDEX]}")
    fi

    clear
    show_cursor
    cursor_to 1 1

    printf "${BOLD}${REVERSE} PROMOTE CODERS ${NC}\n\n"

    printf "Coders to promote:\n"
    for name in "${to_promote[@]}"; do
        printf "  - %s\n" "$name"
    done
    printf "\n"

    printf "Promote to:\n"
    printf "  [1] contributor\n"
    printf "  [2] core\n"
    printf "  [3] steward\n"
    printf "  [C] Cancel\n\n"

    read -p "Choice: " choice

    local new_role
    case "${choice,,}" in
        1) new_role="contributor" ;;
        2) new_role="core" ;;
        3) new_role="steward" ;;
        *) hide_cursor; return ;;
    esac

    local new_level
    case "$new_role" in
        contributor) new_level=30 ;;
        core) new_level=40 ;;
        steward) new_level=50 ;;
    esac

    printf "\nPromoting to %s (level %s)...\n" "$new_role" "$new_level"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    for name in "${to_promote[@]}"; do
        printf "  %s... " "$name"

        # Update config
        yq -i ".other_coders.coders.$name.role = \"$new_role\"" "$CONFIG_FILE" 2>/dev/null

        # Update GitLab if possible
        if [[ -n "$gitlab_url" && -n "$token" ]]; then
            local user_id=$(curl -s -H "PRIVATE-TOKEN: $token" \
                "https://${gitlab_url}/api/v4/users?username=${name}" 2>/dev/null | jq -r '.[0].id // empty')

            if [[ -n "$user_id" ]]; then
                local group_id=$(curl -s -H "PRIVATE-TOKEN: $token" \
                    "https://${gitlab_url}/api/v4/groups?search=nwp" 2>/dev/null | jq -r '.[0].id // empty')

                if [[ -n "$group_id" ]]; then
                    curl -s -X PUT -H "PRIVATE-TOKEN: $token" \
                        "https://${gitlab_url}/api/v4/groups/${group_id}/members/${user_id}" \
                        -d "access_level=$new_level" >/dev/null 2>&1
                fi
            fi
        fi

        printf "${GREEN}done${NC}\n"

        # Log
        mkdir -p "${PROJECT_ROOT}/logs"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | PROMOTE | $name | -> $new_role | by $(whoami)" >> "${PROJECT_ROOT}/logs/promotions.log"
    done

    printf "\n${GREEN}Promotion complete${NC}\n"
    printf "\nPress any key to continue..."
    read -rsn1

    # Clear selection
    for i in "${!SELECTED[@]}"; do
        SELECTED[$i]=0
    done

    load_coders
    hide_cursor
}

# Delete selected coders
delete_coders() {
    local to_delete=()

    # Get selected or current
    local selected_count=0
    for i in "${!SELECTED[@]}"; do
        if ((SELECTED[i])); then
            to_delete+=("${CODERS[$i]}")
            ((selected_count++))
        fi
    done

    if ((selected_count == 0)); then
        to_delete+=("${CODERS[$CURRENT_INDEX]}")
    fi

    clear
    show_cursor
    cursor_to 1 1

    printf "${BOLD}${RED}${REVERSE} DELETE CODERS ${NC}\n\n"

    printf "${RED}WARNING: This will remove the following coders:${NC}\n"
    for name in "${to_delete[@]}"; do
        printf "  - %s\n" "$name"
    done
    printf "\n"

    printf "Options:\n"
    printf "  [1] Delete with GitLab access revocation\n"
    printf "  [2] Delete but keep GitLab access\n"
    printf "  [3] Delete and archive contributions\n"
    printf "  [C] Cancel\n\n"

    read -p "Choice: " choice

    local args=""
    case "${choice,,}" in
        1) args="" ;;
        2) args="--keep-gitlab" ;;
        3) args="--archive" ;;
        *) hide_cursor; return ;;
    esac

    read -p "Type 'DELETE' to confirm: " confirm
    if [[ "$confirm" != "DELETE" ]]; then
        printf "\nCancelled\n"
        sleep 1
        hide_cursor
        return
    fi

    printf "\nDeleting...\n"

    for name in "${to_delete[@]}"; do
        printf "  %s... " "$name"
        if echo "y" | "$CODER_SETUP" remove "$name" $args >/dev/null 2>&1; then
            printf "${GREEN}done${NC}\n"
        else
            printf "${RED}failed${NC}\n"
        fi
    done

    printf "\n${GREEN}Deletion complete${NC}\n"
    printf "\nPress any key to continue..."
    read -rsn1

    load_coders
    CURRENT_INDEX=0
    hide_cursor
}

# Sync action with status
do_sync() {
    get_terminal_size
    local status_row=$((TERMINAL_HEIGHT - 1))

    cursor_to "$status_row" 1
    clear_line
    printf " ${YELLOW}Syncing from GitLab...${NC}"

    if sync_from_gitlab; then
        cursor_to "$status_row" 1
        clear_line
        printf " ${GREEN}Sync complete${NC}"
    else
        cursor_to "$status_row" 1
        clear_line
        printf " ${RED}Sync failed (check GitLab credentials)${NC}"
    fi

    sleep 1
    draw_screen
}

################################################################################
# Help & Documentation
################################################################################

# Show help screen with status column explanations
show_help_screen() {
    clear
    cursor_to 1 1

    printf "${BOLD}${REVERSE} CODERS TUI HELP ${NC}\n\n"

    printf "${BOLD}Status Columns${NC}\n"
    printf "  ${GREEN}✓${NC}  Complete/OK\n"
    printf "  ${RED}✗${NC}  Missing/Failed\n"
    printf "  ${YELLOW}?${NC}  Unknown/Checking\n"
    printf "  ${DIM}-${NC}  Not required for role\n\n"

    printf "${BOLD}Role-based Requirements${NC}\n"
    printf "  ${DIM}Newcomer/Contributor:${NC} Only GL + GRP required\n"
    printf "  ${DIM}Core/Steward:${NC}         All steps required (GL, GRP, NS, DNS, SRV, SITE)\n\n"

    printf "${BOLD}Status Checks${NC}\n"
    printf "  ${CYAN}GL${NC}   GitLab user exists (via API)\n"
    printf "  ${CYAN}GRP${NC}  GitLab group membership (via API)\n"
    printf "  ${CYAN}NS${NC}   NS delegation configured (dig NS)\n"
    printf "  ${CYAN}DNS${NC}  A record resolves to IP (dig A)\n"
    printf "  ${CYAN}SRV${NC}  Server provisioned (config or Linode)\n"
    printf "  ${CYAN}SITE${NC} Site accessible via HTTPS\n\n"

    printf "${BOLD}Keyboard Shortcuts${NC}\n"
    printf "  ${DIM}↑/↓${NC}       Navigate coders\n"
    printf "  ${DIM}Space${NC}     Select/deselect for bulk actions\n"
    printf "  ${DIM}Enter${NC}     View detailed stats\n"
    printf "  ${DIM}M${NC}         Modify selected coder\n"
    printf "  ${DIM}P${NC}         Promote selected/marked coders\n"
    printf "  ${DIM}D${NC}         Delete selected/marked coders\n"
    printf "  ${DIM}A${NC}         Add new coder\n"
    printf "  ${DIM}S${NC}         Sync from GitLab (contribution stats)\n"
    printf "  ${DIM}C${NC}         Check onboarding status\n"
    printf "  ${DIM}V${NC}         Verify DNS/infrastructure\n"
    printf "  ${DIM}R${NC}         Reload data\n"
    printf "  ${DIM}H${NC}         Show this help\n"
    printf "  ${DIM}O${NC}         Open documentation\n"
    printf "  ${DIM}Q${NC}         Quit\n\n"

    printf "${DIM}Press any key to return...${NC}"
    read_key >/dev/null
}

# Open documentation in default viewer
open_documentation() {
    local doc_file="${PROJECT_ROOT}/docs/CODER_ONBOARDING.md"

    if [[ ! -f "$doc_file" ]]; then
        get_terminal_size
        local status_row=$((TERMINAL_HEIGHT - 1))
        cursor_to "$status_row" 1
        clear_line
        printf " ${RED}Documentation not found: %s${NC}" "$doc_file"
        sleep 2
        return
    fi

    # Restore terminal and open doc
    show_cursor
    restore_screen

    # Try different viewers
    if command -v xdg-open &>/dev/null; then
        xdg-open "$doc_file" 2>/dev/null &
    elif command -v open &>/dev/null; then
        open "$doc_file" 2>/dev/null &
    elif command -v less &>/dev/null; then
        less "$doc_file"
    elif command -v cat &>/dev/null; then
        cat "$doc_file" | more
    fi

    # Return to TUI
    save_screen
    hide_cursor
    draw_screen
}

################################################################################
# Main TUI Loop
################################################################################

tui_main() {
    # Setup
    save_screen
    hide_cursor
    clear

    # Trap for cleanup
    trap 'show_cursor; restore_screen; exit 0' EXIT INT TERM

    # Load data
    load_coders

    # Initial draw with ? placeholders
    draw_screen

    # Check onboarding status (updates display as it goes)
    check_all_status

    # Initial sync from GitLab for contribution stats
    sync_from_gitlab 2>/dev/null || true

    # Main loop
    while true; do
        draw_screen

        local key=$(read_key)

        case "$key" in
            UP)
                if ((CURRENT_INDEX > 0)); then
                    ((CURRENT_INDEX--))
                fi
                ;;
            DOWN)
                if ((CURRENT_INDEX < ${#CODERS[@]} - 1)); then
                    ((CURRENT_INDEX++))
                fi
                ;;
            PGUP)
                CURRENT_INDEX=$((CURRENT_INDEX - 10))
                ((CURRENT_INDEX < 0)) && CURRENT_INDEX=0
                ;;
            PGDN)
                if ((${#CODERS[@]} > 0)); then
                    CURRENT_INDEX=$((CURRENT_INDEX + 10))
                    local max_idx=$((${#CODERS[@]} - 1))
                    ((CURRENT_INDEX > max_idx)) && CURRENT_INDEX=$max_idx
                fi
                ;;
            SPACE)
                if ((${#CODERS[@]} > 0)) && ((CURRENT_INDEX >= 0)) && ((CURRENT_INDEX < ${#SELECTED[@]})); then
                    SELECTED[$CURRENT_INDEX]=$((1 - ${SELECTED[$CURRENT_INDEX]:-0}))
                    # Move down after selection
                    if ((CURRENT_INDEX < ${#CODERS[@]} - 1)); then
                        ((CURRENT_INDEX++)) || true
                    fi
                fi
                ;;
            ENTER)
                show_details
                ;;
            m|M)
                modify_coder
                ;;
            p|P)
                promote_coders
                ;;
            d|D)
                delete_coders
                ;;
            a|A)
                add_coder
                ;;
            s|S)
                do_sync
                ;;
            v|V)
                if ((${#CODERS[@]} > 0)); then
                    clear
                    show_cursor
                    "$CODER_SETUP" verify "${CODERS[$CURRENT_INDEX]}"
                    printf "\nPress any key to continue..."
                    read -rsn1
                    hide_cursor
                fi
                ;;
            r|R)
                load_coders
                draw_screen
                check_all_status
                ;;
            c|C)
                # Recheck onboarding status
                check_all_status
                ;;
            h|H|?)
                # Show help screen
                show_help_screen
                ;;
            o|O)
                # Open documentation
                open_documentation
                ;;
            q|Q|ESC)
                break
                ;;
        esac
    done
}

################################################################################
# Non-Interactive Commands
################################################################################

cmd_list() {
    load_coders

    echo "Checking onboarding status..."

    printf "%-12s %-8s  GL GRP  NS DNS SRV SITE  %6s %4s\n" "NAME" "ROLE" "COMMIT" "MRs"
    printf "%-12s %-8s  ── ───  ── ─── ─── ────  %6s %4s\n" "────────────" "────────" "──────" "────"

    for i in "${!CODERS[@]}"; do
        local name="${CODERS[$i]}"
        local data="${CODER_DATA[$i]}"
        local role=$(echo "$data" | cut -d'|' -f1)
        local commits=$(echo "$data" | cut -d'|' -f4)
        local mrs=$(echo "$data" | cut -d'|' -f5)

        # Check status for this coder
        local status_str=$(load_coder_status "$name" "$role")
        local gl=$(echo "$status_str" | cut -d'|' -f1)
        local grp=$(echo "$status_str" | cut -d'|' -f2)
        local ns=$(echo "$status_str" | cut -d'|' -f3)
        local dns=$(echo "$status_str" | cut -d'|' -f4)
        local srv=$(echo "$status_str" | cut -d'|' -f5)
        local site=$(echo "$status_str" | cut -d'|' -f6)

        # Convert to display chars
        gl=$(status_char "$gl")
        grp=$(status_char "$grp")
        ns=$(status_char "$ns")
        dns=$(status_char "$dns")
        srv=$(status_char "$srv")
        site=$(status_char "$site")

        printf "%-12s %-8s  %2s %3s  %2s %3s %3s %4s  %6s %4s\n" \
            "${name:0:12}" "$(role_display "$role")" "$gl" "$grp" "$ns" "$dns" "$srv" "$site" "$commits" "$mrs"
    done
}

# Convert status code to display character (non-colored for CLI)
# Note: '-' must come before '?' since '?' is a glob pattern matching any char
status_char() {
    case "$1" in
        Y) echo "✓" ;;
        N) echo "✗" ;;
        -) echo "-" ;;
        '?') echo "?" ;;
        *) echo "$1" ;;
    esac
}

cmd_sync() {
    load_coders
    printf "Syncing %d coders from GitLab...\n" "${#CODERS[@]}"

    if sync_from_gitlab; then
        printf "Sync complete\n"
    else
        printf "Sync failed\n"
        exit 1
    fi
}

################################################################################
# Main Entry Point
################################################################################

main() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file not found: $CONFIG_FILE"
        exit 1
    fi

    local command="${1:-}"

    case "$command" in
        list)
            cmd_list
            ;;
        sync)
            cmd_sync
            ;;
        -h|--help|help)
            cat << EOF
NWP Coders Management TUI

Usage: $(basename "$0") [command]

Commands:
  (none)    Launch interactive TUI
  list      List all coders (non-interactive)
  sync      Sync from GitLab (non-interactive)
  help      Show this help

TUI Controls:
  ↑/↓       Navigate coders
  Space     Select/deselect for bulk actions
  Enter     View detailed stats
  M         Modify selected coder
  P         Promote selected/marked coders
  D         Delete selected/marked coders
  A         Add new coder
  S         Sync from GitLab (contribution stats)
  C         Check onboarding status (GL, DNS, etc.)
  V         Verify DNS/infrastructure
  R         Reload data
  H         Show help screen
  O         Open documentation (CODER_ONBOARDING.md)
  Q         Quit

Status Columns:
  GL        GitLab user exists (via API)
  GRP       GitLab group membership (via API)
  NS        NS delegation configured (dig NS)
  DNS       A record resolves to IP (dig A)
  SRV       Server provisioned (config or Linode)
  SITE      Site accessible via HTTPS

Status Symbols:
  ✓         Complete/OK
  ✗         Missing/Failed
  ?         Unknown/Checking
  -         Not required for role

Role-based Requirements:
  Newcomer/Contributor: Only GL + GRP required
  Core/Steward:         All steps required

EOF
            ;;
        "")
            tui_main
            ;;
        *)
            echo "Unknown command: $command"
            echo "Run '$(basename "$0") help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
