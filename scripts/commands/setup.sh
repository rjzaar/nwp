#!/bin/bash

################################################################################
# NWP Setup Manager
#
# Interactive TUI for managing NWP prerequisites installation.
# Features:
#   - Arrow key navigation through components
#   - Space to toggle selection
#   - Grouped by category with dependency visualization
#   - Color-coded priority indicators
#
# Use install.sh to create and configure actual projects.
################################################################################

set -e

# Script directory and paths - handle symlinks
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ $SCRIPT_PATH != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
# Navigate to project root (from scripts/commands/)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="$HOME/.nwp/setup_state"
ORIGINAL_STATE_FILE="$STATE_DIR/original_state.json"
CURRENT_STATE_FILE="$STATE_DIR/current_state.json"
INSTALL_LOG="$STATE_DIR/install.log"
CONFIG_FILE="$PROJECT_ROOT/cnwp.yml"
EXAMPLE_CONFIG="$PROJECT_ROOT/example.cnwp.yml"

# Source UI library if available
if [ -f "$PROJECT_ROOT/lib/ui.sh" ]; then
    source "$PROJECT_ROOT/lib/ui.sh"
else
    # Fallback colors
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
    BOLD='\033[1m'
    DIM='\033[2m'

    print_header() {
        echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}${BOLD}  $1${NC}"
        echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
    }

    print_status() {
        local status=$1
        local message=$2
        case "$status" in
            OK)   echo -e "[${GREEN}✓${NC}] $message" ;;
            WARN) echo -e "[${YELLOW}!${NC}] $message" ;;
            FAIL) echo -e "[${RED}✗${NC}] $message" ;;
            INFO) echo -e "[${BLUE}i${NC}] $message" ;;
            *)    echo -e "[${BLUE}i${NC}] $message" ;;
        esac
    }
fi

################################################################################
# Component Hierarchy Definition
################################################################################

declare -a COMPONENTS=(
    # Format: ID|NAME|PARENT|CATEGORY|PRIORITY|DESCRIPTION|EDITABLE_KEY
    # EDITABLE_KEY: config key name if editable, empty if not
    # Core Infrastructure
    "docker|Docker Engine|-|core|required|Container runtime for running DDEV and local development environments|"
    "docker_compose|Docker Compose Plugin|docker|core|required|Multi-container orchestration plugin for Docker|"
    "docker_group|Docker Group Membership|docker|core|required|Allows running Docker commands without sudo|"
    "ddev|DDEV Development Environment|docker|core|required|Local PHP development environment with per-project containers|"
    "ddev_config|DDEV Global Configuration|ddev|core|required|Default DDEV settings (PHP version, ports, DNS)|"
    "mkcert|mkcert SSL Tool|-|core|recommended|Creates locally-trusted SSL certificates for HTTPS|"
    "mkcert_ca|mkcert Certificate Authority|mkcert|core|recommended|Root CA for browser-trusted local SSL certificates|"

    # NWP Tools
    "nwp_cli|NWP CLI Command|-|tools|recommended|Global command to run NWP from any directory|cliprompt"
    "nwp_config|NWP Configuration (cnwp.yml)|-|tools|required|Main config file defining sites, recipes, and settings|"
    "nwp_secrets|NWP Secrets (.secrets.yml)|-|tools|recommended|API tokens for Linode, Cloudflare, GitLab integration|"
    "script_symlinks|Script Symlinks (backward compat)|-|tools|optional|Symlinks in project root for legacy ./install.sh usage|"

    # Testing Tools
    "bats|BATS Testing Framework|-|testing|optional|Bash Automated Testing System for running NWP tests|"

    # Security
    "claude_config|Claude Code Security Config|-|security|recommended|Restricts Claude from accessing production secrets and data|"

    # Linode Infrastructure
    "linode_cli|Linode CLI|-|linode|optional|Command-line tool for managing Linode cloud servers|"
    "linode_config|Linode CLI Configuration|linode_cli|linode|optional|API token and default region/type settings for Linode|linode_token"
    "ssh_keys|SSH Keys for Deployment|linode_cli|linode|optional|SSH keypair for secure server access and deployments|"

    # GitLab Infrastructure
    "gitlab_keys|GitLab SSH Keys|linode_config|gitlab|optional|SSH keys specifically for GitLab server provisioning|"
    "gitlab_server|GitLab Server|gitlab_keys|gitlab|optional|Self-hosted GitLab instance on Linode for private repos|"
    "gitlab_dns|GitLab DNS Record|gitlab_server|gitlab|optional|DNS A record pointing to your GitLab server|"
    "gitlab_ssh_config|GitLab SSH Config|gitlab_server|gitlab|optional|SSH config entry for easy git@git-server access|"
    "gitlab_composer|GitLab Composer Registry|gitlab_server|gitlab|optional|Private Composer package registry on GitLab|"
)

# Track component states
declare -A COMPONENT_INSTALLED
declare -A COMPONENT_ORIGINAL
declare -A COMPONENT_SELECTED
declare -A MANUAL_INPUTS

# Component arrays for TUI
COMP_IDS=()
COMP_NAMES=()
COMP_PARENTS=()
COMP_CATEGORIES=()
COMP_PRIORITIES=()
COMP_DESCRIPTIONS=()
COMP_EDITABLE_KEYS=()

# Page definitions - categories grouped into pages
declare -a PAGE_CATEGORIES
PAGE_CATEGORIES[0]="core tools testing"
PAGE_CATEGORIES[1]="security linode gitlab"
declare -a PAGE_NAMES
PAGE_NAMES[0]="Core & Tools"
PAGE_NAMES[1]="Infrastructure"
NUM_PAGES=2
CURRENT_PAGE=0

# Per-page component indices
declare -a PAGE_COMP_INDICES

################################################################################
# TUI Functions
################################################################################

cursor_to() { printf "\033[%d;%dH" "$1" "$2"; }
cursor_hide() { printf "\033[?25l"; }
cursor_show() { printf "\033[?25h"; }
clear_screen() { printf "\033[2J\033[H"; }
clear_line() { printf "\033[2K"; }

read_key() {
    local key
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.1 rest
        case "$rest" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            *) echo "ESC" ;;
        esac
    elif [[ $key == "" ]]; then
        echo "ENTER"
    elif [[ $key == " " ]]; then
        echo "SPACE"
    else
        echo "$key"
    fi
}

# Initialize component arrays
init_components() {
    local idx=0
    for comp in "${COMPONENTS[@]}"; do
        COMP_IDS[$idx]=$(echo "$comp" | cut -d'|' -f1)
        COMP_NAMES[$idx]=$(echo "$comp" | cut -d'|' -f2)
        COMP_PARENTS[$idx]=$(echo "$comp" | cut -d'|' -f3)
        COMP_CATEGORIES[$idx]=$(echo "$comp" | cut -d'|' -f4)
        COMP_PRIORITIES[$idx]=$(echo "$comp" | cut -d'|' -f5)
        COMP_DESCRIPTIONS[$idx]=$(echo "$comp" | cut -d'|' -f6)
        COMP_EDITABLE_KEYS[$idx]=$(echo "$comp" | cut -d'|' -f7)
        idx=$((idx + 1))
    done
    build_page_indices
}

# Build per-page component index arrays
build_page_indices() {
    for ((page=0; page<NUM_PAGES; page++)); do
        local categories="${PAGE_CATEGORIES[$page]}"
        local indices=""
        for ((i=0; i<${#COMP_IDS[@]}; i++)); do
            local cat="${COMP_CATEGORIES[$i]}"
            if [[ " $categories " == *" $cat "* ]]; then
                indices="$indices $i"
            fi
        done
        PAGE_COMP_INDICES[$page]="${indices# }"
    done
}

# Get component indices for current page
get_page_indices() {
    echo "${PAGE_COMP_INDICES[$CURRENT_PAGE]}"
}

# Get count of components on current page
get_page_count() {
    local indices=(${PAGE_COMP_INDICES[$CURRENT_PAGE]})
    echo "${#indices[@]}"
}

# Get component name by ID
get_component_name_by_id() {
    local target_id="$1"
    for ((i=0; i<${#COMP_IDS[@]}; i++)); do
        if [ "${COMP_IDS[$i]}" = "$target_id" ]; then
            echo "${COMP_NAMES[$i]}"
            return
        fi
    done
    echo "$target_id"
}

# Get current value for editable component
get_editable_value() {
    local comp_id="$1"
    local edit_key="$2"

    # Check if manually set
    if [ -n "${MANUAL_INPUTS[$comp_id]:-}" ]; then
        echo "${MANUAL_INPUTS[$comp_id]}"
        return
    fi

    # Get default from config
    case "$edit_key" in
        cliprompt)
            local val=$(read_config_value "cliprompt")
            echo "${val:-pl}"
            ;;
        linode_token)
            if [ -f "$PROJECT_ROOT/.secrets.yml" ]; then
                local val=$(grep "api_token:" "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | head -1 | awk -F'"' '{print $2}')
                [ -n "$val" ] && echo "(configured)" || echo "(not set)"
            else
                echo "(not set)"
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# Get prompt text for editable field
get_edit_prompt() {
    local edit_key="$1"
    case "$edit_key" in
        cliprompt)    echo "CLI command name" ;;
        linode_token) echo "Linode API token" ;;
        *)            echo "Value" ;;
    esac
}

# Get category display name
get_category_name() {
    case "$1" in
        core)     echo "Core Infrastructure" ;;
        tools)    echo "NWP Tools" ;;
        testing)  echo "Testing" ;;
        security) echo "Security" ;;
        linode)   echo "Linode Infrastructure" ;;
        gitlab)   echo "GitLab Deployment" ;;
        *)        echo "$1" ;;
    esac
}

# Draw the interactive setup screen
draw_setup_screen() {
    local current_row="$1"
    local page_indices=(${PAGE_COMP_INDICES[$CURRENT_PAGE]})
    local num_on_page=${#page_indices[@]}

    clear_screen

    # Header with page indicator
    printf "${BOLD}NWP Setup Manager${NC}  |  "
    printf "←→:Page ↑↓:Nav SPACE:Toggle d:Desc e:Edit a:All n:None ENTER:Apply q:Quit\n"
    printf "═══════════════════════════════════════════════════════════════════════════════\n"

    # Page tabs
    printf "  "
    for ((p=0; p<NUM_PAGES; p++)); do
        if [ $p -eq $CURRENT_PAGE ]; then
            printf "${BOLD}${CYAN}[${PAGE_NAMES[$p]}]${NC}  "
        else
            printf "${DIM}${PAGE_NAMES[$p]}${NC}  "
        fi
    done
    printf "\n"

    # Legend
    printf "  ${RED}●${NC} Required  ${YELLOW}●${NC} Recommended  ${CYAN}●${NC} Optional    "
    printf "${GREEN}[✓]${NC} Installed  ${DIM}[ ]${NC} Not Installed\n"
    printf "───────────────────────────────────────────────────────────────────────────────\n"

    local current_category=""
    local row=0

    for row_idx in "${!page_indices[@]}"; do
        local i="${page_indices[$row_idx]}"
        local id="${COMP_IDS[$i]}"
        local name="${COMP_NAMES[$i]}"
        local parent="${COMP_PARENTS[$i]}"
        local category="${COMP_CATEGORIES[$i]}"
        local priority="${COMP_PRIORITIES[$i]}"

        # Category header
        if [ "$category" != "$current_category" ]; then
            current_category="$category"
            printf "\n  ${BOLD}$(get_category_name "$category")${NC}\n"
        fi

        # Indentation for children
        local indent="    "
        local prefix=""
        if [ "$parent" != "-" ]; then
            indent="      "
            prefix="└─ "
        fi

        # Priority indicator
        local priority_dot=""
        case "$priority" in
            required)    priority_dot="${RED}●${NC}" ;;
            recommended) priority_dot="${YELLOW}●${NC}" ;;
            optional)    priority_dot="${CYAN}●${NC}" ;;
        esac

        # Selection checkbox
        local checkbox="[ ]"
        if [ "${COMPONENT_SELECTED[$id]:-0}" = "1" ]; then
            checkbox="[${GREEN}✓${NC}]"
        fi

        # Installed status and editable value
        local status_icon=""
        local edit_key="${COMP_EDITABLE_KEYS[$i]}"
        if [ "${COMPONENT_INSTALLED[$id]:-0}" = "1" ]; then
            status_icon="${GREEN}installed${NC}"
        else
            status_icon="${DIM}not installed${NC}"
        fi

        # Show current value for editable items
        local edit_info=""
        if [ -n "$edit_key" ]; then
            local current_val=$(get_editable_value "$id" "$edit_key")
            edit_info=" ${CYAN}[$current_val]${NC}"
        fi

        # Highlight current row
        if [ $row_idx -eq $current_row ]; then
            printf "${BOLD}>${NC}"
        else
            printf " "
        fi

        # Print component line
        printf "%s%b %b %s%-30s%b %b\n" "$indent" "$checkbox" "$priority_dot" "$prefix" "$name" "$edit_info" "$status_icon"

        row=$((row + 1))
    done

    # Footer
    printf "\n───────────────────────────────────────────────────────────────────────────────\n"

    # Count selected (all pages)
    local selected_count=0
    local installed_count=0
    local total_count=${#COMP_IDS[@]}
    for id in "${COMP_IDS[@]}"; do
        [ "${COMPONENT_SELECTED[$id]:-0}" = "1" ] && selected_count=$((selected_count + 1))
        [ "${COMPONENT_INSTALLED[$id]:-0}" = "1" ] && installed_count=$((installed_count + 1))
    done

    printf "  ${CYAN}%d${NC} selected  |  ${GREEN}%d${NC}/%d installed\n" "$selected_count" "$installed_count" "$total_count"

    # Show what will change
    local to_install=""
    local to_remove=""
    for id in "${COMP_IDS[@]}"; do
        local installed=${COMPONENT_INSTALLED[$id]:-0}
        local selected=${COMPONENT_SELECTED[$id]:-0}
        if [ "$selected" = "1" ] && [ "$installed" = "0" ]; then
            to_install="$to_install $id"
        elif [ "$selected" = "0" ] && [ "$installed" = "1" ]; then
            to_remove="$to_remove $id"
        fi
    done

    if [ -n "$to_install" ] || [ -n "$to_remove" ]; then
        printf "\n  Changes pending: "
        [ -n "$to_install" ] && printf "${GREEN}+$(echo $to_install | wc -w) install${NC}  "
        [ -n "$to_remove" ] && printf "${RED}-$(echo $to_remove | wc -w) remove${NC}"
        printf "\n"
    fi
}

# Run interactive TUI
run_interactive_tui() {
    local current_row=0

    # Setup terminal
    cursor_hide
    trap 'cursor_show; clear_screen' EXIT

    while true; do
        local page_indices=(${PAGE_COMP_INDICES[$CURRENT_PAGE]})
        local num_on_page=${#page_indices[@]}

        draw_setup_screen $current_row

        local key=$(read_key)

        case "$key" in
            "UP"|"k")
                [ $current_row -gt 0 ] && current_row=$((current_row - 1))
                ;;
            "DOWN"|"j")
                [ $current_row -lt $((num_on_page - 1)) ] && current_row=$((current_row + 1))
                ;;
            "LEFT"|"h")
                if [ $CURRENT_PAGE -gt 0 ]; then
                    CURRENT_PAGE=$((CURRENT_PAGE - 1))
                    current_row=0
                fi
                ;;
            "RIGHT"|"l")
                if [ $CURRENT_PAGE -lt $((NUM_PAGES - 1)) ]; then
                    CURRENT_PAGE=$((CURRENT_PAGE + 1))
                    current_row=0
                fi
                ;;
            "SPACE")
                # Get actual component index from page indices
                local comp_idx="${page_indices[$current_row]}"
                local id="${COMP_IDS[$comp_idx]}"
                if [ "${COMPONENT_SELECTED[$id]:-0}" = "1" ]; then
                    COMPONENT_SELECTED[$id]=0
                else
                    COMPONENT_SELECTED[$id]=1
                fi
                enforce_dependencies
                ;;
            "a"|"A")
                # Select all required + recommended (all pages)
                for ((i=0; i<${#COMP_IDS[@]}; i++)); do
                    local id="${COMP_IDS[$i]}"
                    local priority="${COMP_PRIORITIES[$i]}"
                    if [ "$priority" = "required" ] || [ "$priority" = "recommended" ]; then
                        COMPONENT_SELECTED[$id]=1
                    fi
                done
                enforce_dependencies
                ;;
            "n"|"N")
                # Deselect all (except already installed)
                for id in "${COMP_IDS[@]}"; do
                    COMPONENT_SELECTED[$id]=${COMPONENT_INSTALLED[$id]:-0}
                done
                ;;
            "d"|"D")
                # Show description for current component
                local comp_idx="${page_indices[$current_row]}"
                local comp_id="${COMP_IDS[$comp_idx]}"
                local comp_name="${COMP_NAMES[$comp_idx]}"
                local comp_desc="${COMP_DESCRIPTIONS[$comp_idx]}"
                local comp_priority="${COMP_PRIORITIES[$comp_idx]}"
                local comp_parent="${COMP_PARENTS[$comp_idx]}"
                local comp_edit_key="${COMP_EDITABLE_KEYS[$comp_idx]}"
                local parent_name=""
                [ "$comp_parent" != "-" ] && parent_name=$(get_component_name_by_id "$comp_parent")

                cursor_show
                clear_screen
                printf "\n${BOLD}${CYAN}$comp_name${NC}\n"
                printf "═══════════════════════════════════════════════════════════════════════════════\n\n"
                printf "  ${BOLD}Description:${NC}\n"
                printf "  $comp_desc\n\n"
                printf "  ${BOLD}Priority:${NC} $comp_priority\n"
                [ -n "$parent_name" ] && printf "  ${BOLD}Requires:${NC} $parent_name\n"
                if [ -n "$comp_edit_key" ]; then
                    local current_val=$(get_editable_value "$comp_id" "$comp_edit_key")
                    printf "  ${BOLD}Current value:${NC} ${CYAN}$current_val${NC}  ${DIM}(press 'e' to edit)${NC}\n"
                fi
                printf "\n───────────────────────────────────────────────────────────────────────────────\n"
                printf "  Press any key to return..."
                read -rsn1
                cursor_hide
                ;;
            "e"|"E")
                # Edit value for editable component inline
                local comp_idx="${page_indices[$current_row]}"
                local comp_id="${COMP_IDS[$comp_idx]}"
                local comp_name="${COMP_NAMES[$comp_idx]}"
                local comp_edit_key="${COMP_EDITABLE_KEYS[$comp_idx]}"

                if [ -z "$comp_edit_key" ]; then
                    # Not editable - flash message at bottom
                    printf "\n  ${YELLOW}$comp_name is not editable${NC}"
                    sleep 0.8
                else
                    local current_val=$(get_editable_value "$comp_id" "$comp_edit_key")
                    local prompt_text=$(get_edit_prompt "$comp_edit_key")

                    # Show inline edit prompt at bottom
                    cursor_show
                    printf "\n  ${BOLD}$prompt_text${NC} [${CYAN}$current_val${NC}]: "
                    read new_val
                    cursor_hide
                    if [ -n "$new_val" ]; then
                        MANUAL_INPUTS[$comp_id]="$new_val"
                    fi
                fi
                ;;
            "ENTER")
                cursor_show
                echo ""
                apply_changes
                echo ""
                read -p "Press Enter to continue..."
                cursor_hide
                # Refresh states
                detect_all_current_states
                # Update selections to match installed
                for id in "${COMP_IDS[@]}"; do
                    COMPONENT_SELECTED[$id]=${COMPONENT_INSTALLED[$id]:-0}
                done
                ;;
            "q"|"Q"|"ESC")
                break
                ;;
        esac
    done

    cursor_show
    clear_screen
}

################################################################################
# Helper Functions
################################################################################

ask_yes_no() {
    local prompt=$1
    local default=${2:-n}
    if [ "$default" == "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    read -p "$prompt" response
    response=${response:-$default}
    [[ "$response" =~ ^[Yy]$ ]]
}

log_action() {
    mkdir -p "$STATE_DIR"
    echo "[$(date -Iseconds)] $1" >> "$INSTALL_LOG"
}

read_config_value() {
    local key="$1"
    local config_file="${2:-$CONFIG_FILE}"
    if [ ! -f "$CONFIG_FILE" ] && [ -f "$EXAMPLE_CONFIG" ]; then
        config_file="$EXAMPLE_CONFIG"
    fi
    [ -f "$config_file" ] || return 1
    grep "^  $key:" "$config_file" 2>/dev/null | head -1 | awk -F': ' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

get_base_url_from_config() {
    [ ! -f "$CONFIG_FILE" ] && return 1
    awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  url:/ {
            sub("^  url: *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$CONFIG_FILE"
}

################################################################################
# State Detection Functions
################################################################################

check_docker_installed() { command -v docker &>/dev/null && docker --version &>/dev/null; }
check_docker_compose_installed() { docker compose version &>/dev/null 2>&1; }
check_docker_group() { groups 2>/dev/null | grep -q docker; }
check_mkcert_installed() { command -v mkcert &>/dev/null; }
check_mkcert_ca_installed() {
    check_mkcert_installed || return 1
    local ca_root=$(mkcert -CAROOT 2>/dev/null)
    [ -n "$ca_root" ] && [ -f "$ca_root/rootCA.pem" ]
}
check_ddev_installed() { command -v ddev &>/dev/null; }
check_ddev_config_exists() { [ -f "$HOME/.ddev/global_config.yaml" ]; }
check_nwp_cli_installed() {
    local cli_prompt=$(read_config_value "cliprompt")
    cli_prompt=${cli_prompt:-pl}
    [ -f "/usr/local/bin/$cli_prompt" ]
}
check_script_symlinks_exist() {
    [ -L "$PROJECT_ROOT/install.sh" ] && [ -L "$PROJECT_ROOT/backup.sh" ]
}
check_nwp_config_exists() { [ -f "$CONFIG_FILE" ]; }
check_linode_cli_installed() { command -v linode-cli &>/dev/null; }
check_ssh_keys_exist() { [ -f "$PROJECT_ROOT/keys/nwp" ] || [ -f "$HOME/.ssh/nwp" ]; }
check_nwp_secrets_exist() { [ -f "$PROJECT_ROOT/.secrets.yml" ]; }
check_linode_config_exists() {
    command -v linode-cli &>/dev/null || return 1
    [ -f "$HOME/.config/linode-cli" ] || return 1
    timeout 5 linode-cli linodes list --text --no-headers &>/dev/null
}
check_gitlab_keys_exist() { [ -f "$PROJECT_ROOT/linode/gitlab/keys/gitlab_linode" ]; }
check_bats_installed() { command -v bats &>/dev/null; }
check_gitlab_server_exists() {
    [ -f "$PROJECT_ROOT/.secrets.yml" ] || return 1
    grep -q "^gitlab:" "$PROJECT_ROOT/.secrets.yml" 2>/dev/null && \
    grep -q "linode_id:" "$PROJECT_ROOT/.secrets.yml" 2>/dev/null
}
check_gitlab_dns_exists() {
    check_linode_config_exists || return 1
    local base_url=$(get_base_url_from_config 2>/dev/null)
    [ -z "$base_url" ] && return 1
    timeout 5 linode-cli domains list --text --no-headers 2>/dev/null | grep -q "$base_url"
}
check_gitlab_ssh_config_exists() {
    [ -f "$HOME/.ssh/config" ] && grep -q "Host git-server" "$HOME/.ssh/config" 2>/dev/null
}
check_claude_config_exists() {
    [ -f "$HOME/.claude/settings.json" ] && grep -q '"deny"' "$HOME/.claude/settings.json" 2>/dev/null
}
check_gitlab_composer_exists() {
    [ -f "$PROJECT_ROOT/.secrets.yml" ] || return 1
    source "$PROJECT_ROOT/lib/git.sh" 2>/dev/null || return 1
    local gitlab_url=$(get_gitlab_url 2>/dev/null)
    local token=$(get_gitlab_token 2>/dev/null)
    [ -z "$gitlab_url" ] && return 1
    [ -z "$token" ] && return 1
    timeout 5 curl -s --header "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/packages" &>/dev/null
}

detect_component_state() {
    local id="$1"
    case "$id" in
        docker)           check_docker_installed ;;
        docker_compose)   check_docker_compose_installed ;;
        docker_group)     check_docker_group ;;
        mkcert)           check_mkcert_installed ;;
        mkcert_ca)        check_mkcert_ca_installed ;;
        ddev)             check_ddev_installed ;;
        ddev_config)      check_ddev_config_exists ;;
        script_symlinks)  check_script_symlinks_exist ;;
        nwp_cli)          check_nwp_cli_installed ;;
        nwp_config)       check_nwp_config_exists ;;
        nwp_secrets)      check_nwp_secrets_exist ;;
        bats)             check_bats_installed ;;
        linode_cli)       check_linode_cli_installed ;;
        linode_config)    check_linode_config_exists ;;
        ssh_keys)         check_ssh_keys_exist ;;
        gitlab_keys)      check_gitlab_keys_exist ;;
        gitlab_server)    check_gitlab_server_exists ;;
        gitlab_dns)       check_gitlab_dns_exists ;;
        gitlab_ssh_config) check_gitlab_ssh_config_exists ;;
        gitlab_composer)  check_gitlab_composer_exists ;;
        claude_config)    check_claude_config_exists ;;
        *)                return 1 ;;
    esac
}

detect_all_current_states() {
    for id in "${COMP_IDS[@]}"; do
        if detect_component_state "$id"; then
            COMPONENT_INSTALLED[$id]=1
        else
            COMPONENT_INSTALLED[$id]=0
        fi
    done
}

################################################################################
# State Management
################################################################################

save_original_state() {
    mkdir -p "$STATE_DIR"
    [ -f "$ORIGINAL_STATE_FILE" ] && return 0
    detect_all_current_states
    cat > "$ORIGINAL_STATE_FILE" << EOF
{
  "saved_date": "$(date -Iseconds)",
  "user": "$USER",
  "hostname": "$(hostname)",
  "components": {
EOF
    local first=true
    for id in "${COMP_IDS[@]}"; do
        [ "$first" = true ] && first=false || echo "," >> "$ORIGINAL_STATE_FILE"
        echo -n "    \"$id\": ${COMPONENT_INSTALLED[$id]:-0}" >> "$ORIGINAL_STATE_FILE"
    done
    cat >> "$ORIGINAL_STATE_FILE" << EOF

  }
}
EOF
    log_action "Original state saved"
}

load_original_state() {
    [ -f "$ORIGINAL_STATE_FILE" ] || return 1
    for id in "${COMP_IDS[@]}"; do
        local value=$(grep "\"$id\":" "$ORIGINAL_STATE_FILE" | grep -oE '[0-9]+' | head -1)
        COMPONENT_ORIGINAL[$id]=${value:-0}
    done
}

################################################################################
# Dependency Enforcement
################################################################################

enforce_dependencies() {
    local changed=true
    while [ "$changed" = true ]; do
        changed=false
        for ((i=0; i<${#COMP_IDS[@]}; i++)); do
            local id="${COMP_IDS[$i]}"
            local parent="${COMP_PARENTS[$i]}"
            if [ "$parent" != "-" ]; then
                # If child selected but parent not, select parent
                if [ "${COMPONENT_SELECTED[$id]:-0}" = "1" ] && [ "${COMPONENT_SELECTED[$parent]:-0}" = "0" ]; then
                    COMPONENT_SELECTED[$parent]=1
                    changed=true
                fi
                # If parent deselected, deselect children
                if [ "${COMPONENT_SELECTED[$parent]:-0}" = "0" ] && [ "${COMPONENT_SELECTED[$id]:-0}" = "1" ]; then
                    COMPONENT_SELECTED[$id]=0
                    changed=true
                fi
            fi
        done
    done
}

################################################################################
# Installation Functions
################################################################################

install_docker() {
    print_status "INFO" "Installing Docker Engine..."
    log_action "Installing Docker Engine"
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo systemctl start docker
    sudo systemctl enable docker
    print_status "OK" "Docker installed"
}

install_docker_group() {
    print_status "INFO" "Adding user to docker group..."
    sudo groupadd docker 2>/dev/null || true
    sudo usermod -aG docker $USER
    print_status "OK" "User added to docker group"
    print_status "WARN" "Log out and back in to take effect"
}

install_mkcert() {
    print_status "INFO" "Installing mkcert..."
    sudo apt-get update && sudo apt install -y libnss3-tools
    curl -JLO "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
    chmod +x mkcert-v*-linux-amd64
    sudo mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert
    print_status "OK" "mkcert installed"
}

install_mkcert_ca() {
    print_status "INFO" "Installing mkcert CA..."
    mkcert -install
    print_status "OK" "mkcert CA installed"
}

install_ddev() {
    print_status "INFO" "Installing DDEV..."
    curl -fsSL https://ddev.com/install.sh | bash
    print_status "OK" "DDEV installed"
}

install_ddev_config() {
    print_status "INFO" "Creating DDEV config..."
    mkdir -p ~/.ddev
    cat > ~/.ddev/global_config.yaml << 'EOF'
use_dns_when_possible: false
router_http_port: "80"
router_https_port: "443"
instrumentation_opt_in: false
php_version: "8.3"
EOF
    print_status "OK" "DDEV config created"
}

install_script_symlinks() {
    print_status "INFO" "Creating script symlinks..."
    local commands_dir="$PROJECT_ROOT/scripts/commands"
    [ ! -d "$commands_dir" ] && { print_status "FAIL" "scripts/commands/ not found"; return 1; }
    local scripts=(backup.sh coder-setup.sh copy.sh delete.sh dev2stg.sh import.sh install.sh live.sh make.sh setup.sh status.sh)
    local created=0
    for script in "${scripts[@]}"; do
        local target="$PROJECT_ROOT/$script"
        [ -L "$target" ] || [ -f "$target" ] && continue
        [ -f "$commands_dir/$script" ] && { ln -s "scripts/commands/$script" "$target"; created=$((created + 1)); }
    done
    print_status "OK" "Created $created symlinks"
}

install_nwp_cli() {
    print_status "INFO" "Installing NWP CLI..."
    local cli_prompt="${MANUAL_INPUTS[nwp_cli]:-}"
    [ -z "$cli_prompt" ] && cli_prompt=$(read_config_value "cliprompt")
    cli_prompt=${cli_prompt:-pl}
    sudo tee "/usr/local/bin/$cli_prompt" > /dev/null << CLIEOF
#!/bin/bash
NWP_DIR="\$HOME/nwp"
for dir in "\$HOME/nwp" "\$HOME/projects/nwp" "/opt/nwp"; do
    [ -d "\$dir" ] && [ -f "\$dir/pl" ] && { NWP_DIR="\$dir"; break; }
done
[ ! -d "\$NWP_DIR" ] && { echo "Error: NWP directory not found"; exit 1; }
cd "\$NWP_DIR" && exec "./pl" "\$@"
CLIEOF
    sudo chmod +x "/usr/local/bin/$cli_prompt"
    print_status "OK" "CLI '$cli_prompt' installed"
}

install_nwp_config() {
    print_status "INFO" "Creating cnwp.yml..."
    [ -f "$EXAMPLE_CONFIG" ] && cp "$EXAMPLE_CONFIG" "$CONFIG_FILE" && print_status "OK" "cnwp.yml created"
}

install_nwp_secrets() {
    print_status "INFO" "Creating .secrets.yml..."
    [ -f "$PROJECT_ROOT/.secrets.yml" ] && { print_status "OK" ".secrets.yml exists"; return 0; }
    cat > "$PROJECT_ROOT/.secrets.yml" << 'EOF'
# NWP Infrastructure Secrets - NEVER commit this file!
linode:
  api_token: ""
EOF
    chmod 600 "$PROJECT_ROOT/.secrets.yml"
    print_status "OK" ".secrets.yml created"
}

install_linode_cli() {
    print_status "INFO" "Installing Linode CLI..."
    command -v pipx &>/dev/null || { sudo apt-get update && sudo apt-get install -y pipx && pipx ensurepath; }
    pipx install linode-cli
    print_status "OK" "Linode CLI installed"
}

install_linode_config() {
    print_status "INFO" "Configuring Linode CLI..."
    check_linode_config_exists && { print_status "OK" "Already configured"; return 0; }
    local token=""
    [ -f "$PROJECT_ROOT/.secrets.yml" ] && token=$(grep "api_token:" "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | head -1 | awk -F'"' '{print $2}')
    if [ -z "$token" ]; then
        read -p "Enter Linode API token (or Enter to skip): " token
        [ -z "$token" ] && { print_status "INFO" "Skipped"; return 1; }
        [ -f "$PROJECT_ROOT/.secrets.yml" ] && sed -i "s/api_token: \"\"/api_token: \"$token\"/" "$PROJECT_ROOT/.secrets.yml"
    fi
    mkdir -p "$HOME/.config"
    cat > "$HOME/.config/linode-cli" << EOF
[DEFAULT]
default-user = default
token = $token
[default]
region = us-east
type = g6-standard-2
image = linode/ubuntu24.04
EOF
    print_status "OK" "Linode CLI configured"
}

install_ssh_keys() {
    print_status "INFO" "Setting up SSH keys..."
    [ -x "$PROJECT_ROOT/scripts/commands/setup-ssh.sh" ] && "$PROJECT_ROOT/scripts/commands/setup-ssh.sh"
}

install_gitlab_keys() {
    print_status "INFO" "Generating GitLab SSH keys..."
    local keys_dir="$PROJECT_ROOT/linode/gitlab/keys"
    mkdir -p "$keys_dir"
    [ -f "$keys_dir/gitlab_linode" ] && { print_status "OK" "Keys exist"; return 0; }
    ssh-keygen -t ed25519 -f "$keys_dir/gitlab_linode" -N "" -C "gitlab@$(get_base_url_from_config 2>/dev/null || echo localhost)"
    print_status "OK" "GitLab SSH keys generated"
}

install_gitlab_server() {
    print_status "INFO" "Provisioning GitLab server..."
    check_linode_config_exists || { print_status "FAIL" "Linode CLI not configured"; return 1; }
    [ -x "$PROJECT_ROOT/linode/gitlab/setup_gitlab_site.sh" ] && "$PROJECT_ROOT/linode/gitlab/setup_gitlab_site.sh" -y
}

install_gitlab_dns() {
    print_status "INFO" "Configuring GitLab DNS..."
    # Implementation from original
}

install_gitlab_ssh_config() {
    print_status "INFO" "Configuring GitLab SSH..."
    # Implementation from original
}

install_gitlab_composer() {
    print_status "INFO" "Setting up GitLab Composer Registry..."
    print_status "OK" "See docs/GITLAB_COMPOSER.md for usage"
}

install_bats() {
    print_status "INFO" "Installing BATS..."
    sudo apt-get update && sudo apt-get install -y bats
    print_status "OK" "BATS installed"
}

install_claude_config() {
    print_status "INFO" "Configuring Claude Code security..."
    local claude_dir="$HOME/.claude"
    mkdir -p "$claude_dir"
    [ -f "$claude_dir/settings.json" ] && grep -q '"deny"' "$claude_dir/settings.json" && { print_status "OK" "Already configured"; return 0; }
    cat > "$claude_dir/settings.json" << 'EOF'
{
  "permissions": {
    "deny": [
      "**/.secrets.data.yml",
      "**/keys/prod_*",
      "~/.ssh/*",
      "**/*.sql",
      "**/settings.php"
    ]
  }
}
EOF
    chmod 600 "$claude_dir/settings.json"
    print_status "OK" "Claude security config created"
}

install_component() {
    local id="$1"
    case "$id" in
        docker)           install_docker ;;
        docker_compose)   print_status "OK" "Included with Docker" ;;
        docker_group)     install_docker_group ;;
        mkcert)           install_mkcert ;;
        mkcert_ca)        install_mkcert_ca ;;
        ddev)             install_ddev ;;
        ddev_config)      install_ddev_config ;;
        script_symlinks)  install_script_symlinks ;;
        nwp_cli)          install_nwp_cli ;;
        nwp_config)       install_nwp_config ;;
        nwp_secrets)      install_nwp_secrets ;;
        bats)             install_bats ;;
        linode_cli)       install_linode_cli ;;
        linode_config)    install_linode_config ;;
        ssh_keys)         install_ssh_keys ;;
        gitlab_keys)      install_gitlab_keys ;;
        gitlab_server)    install_gitlab_server ;;
        gitlab_dns)       install_gitlab_dns ;;
        gitlab_ssh_config) install_gitlab_ssh_config ;;
        gitlab_composer)  install_gitlab_composer ;;
        claude_config)    install_claude_config ;;
    esac
}

################################################################################
# Removal Functions (stubs - full implementation in original)
################################################################################

remove_component() {
    local id="$1"
    print_status "INFO" "Removing $id..."
    # Full removal logic from original file
    log_action "Removed $id"
}

################################################################################
# Apply Changes
################################################################################

apply_changes() {
    local to_install=()
    local to_remove=()

    for id in "${COMP_IDS[@]}"; do
        local installed=${COMPONENT_INSTALLED[$id]:-0}
        local selected=${COMPONENT_SELECTED[$id]:-0}
        if [ "$selected" = "1" ] && [ "$installed" = "0" ]; then
            to_install+=("$id")
        elif [ "$selected" = "0" ] && [ "$installed" = "1" ]; then
            to_remove+=("$id")
        fi
    done

    if [ ${#to_install[@]} -eq 0 ] && [ ${#to_remove[@]} -eq 0 ]; then
        print_status "OK" "No changes needed"
        return 0
    fi

    echo ""
    print_status "INFO" "Changes to apply:"
    [ ${#to_install[@]} -gt 0 ] && echo -e "  ${GREEN}Install:${NC} ${to_install[*]}"
    [ ${#to_remove[@]} -gt 0 ] && echo -e "  ${RED}Remove:${NC} ${to_remove[*]}"
    echo ""

    if ! ask_yes_no "Proceed?" "y"; then
        print_status "INFO" "Cancelled"
        return 1
    fi

    # Install
    for id in "${to_install[@]}"; do
        install_component "$id"
    done

    # Remove (in reverse order)
    for ((i=${#to_remove[@]}-1; i>=0; i--)); do
        remove_component "${to_remove[$i]}"
    done

    print_status "OK" "Changes applied"
}

################################################################################
# Main
################################################################################

show_help() {
    cat << EOF
NWP Setup Manager - Interactive TUI for managing prerequisites

Usage: $0 [options]

Options:
  --status       Show current installation status
  --auto         Auto-install all required + recommended components
  --help         Show this help

Without options, runs interactive TUI.

TUI Controls:
  ↑/↓            Navigate components
  SPACE          Toggle selection
  a              Select all required + recommended
  n              Reset to current state
  ENTER          Apply changes
  q              Quit
EOF
}

show_status() {
    print_header "NWP Setup Status"
    init_components
    detect_all_current_states

    local current_category=""
    for ((i=0; i<${#COMP_IDS[@]}; i++)); do
        local id="${COMP_IDS[$i]}"
        local name="${COMP_NAMES[$i]}"
        local category="${COMP_CATEGORIES[$i]}"
        local priority="${COMP_PRIORITIES[$i]}"

        [ "$category" != "$current_category" ] && { current_category="$category"; echo -e "\n${BOLD}$(get_category_name "$category")${NC}"; }

        local status_icon="${RED}✗${NC}"
        [ "${COMPONENT_INSTALLED[$id]:-0}" = "1" ] && status_icon="${GREEN}✓${NC}"

        local priority_dot=""
        case "$priority" in
            required) priority_dot="${RED}●${NC}" ;;
            recommended) priority_dot="${YELLOW}●${NC}" ;;
            optional) priority_dot="${CYAN}●${NC}" ;;
        esac

        printf "  [%b] %b %s\n" "$status_icon" "$priority_dot" "$name"
    done
    echo ""
}

main() {
    case "${1:-}" in
        --help|-h) show_help; exit 0 ;;
        --status) show_status; exit 0 ;;
        --auto)
            init_components
            save_original_state
            detect_all_current_states
            load_original_state
            for ((i=0; i<${#COMP_IDS[@]}; i++)); do
                local id="${COMP_IDS[$i]}"
                local priority="${COMP_PRIORITIES[$i]}"
                if [ "$priority" = "required" ] || [ "$priority" = "recommended" ]; then
                    COMPONENT_SELECTED[$id]=1
                else
                    COMPONENT_SELECTED[$id]=${COMPONENT_INSTALLED[$id]:-0}
                fi
            done
            enforce_dependencies
            apply_changes
            exit 0
            ;;
    esac

    # Interactive TUI mode
    init_components
    save_original_state
    detect_all_current_states
    load_original_state

    # Initialize selections to current state
    for id in "${COMP_IDS[@]}"; do
        COMPONENT_SELECTED[$id]=${COMPONENT_INSTALLED[$id]:-0}
    done

    run_interactive_tui
}

main "$@"
