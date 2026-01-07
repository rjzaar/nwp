#!/bin/bash

################################################################################
# NWP Uninstaller
#
# This script reverses all changes made by setup.sh, restoring the system
# to its pre-NWP state based on the installation snapshot.
#
# CAUTION: This will remove Docker, DDEV, and related tools if they were
# installed by NWP setup. Make sure you have backups of any important data.
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HOME/.nwp/setup_state"
ORIGINAL_STATE_FILE="$STATE_DIR/original_state.json"
LEGACY_STATE_FILE="$STATE_DIR/pre_setup_state.json"
INSTALL_LOG="$STATE_DIR/install.log"
CONFIG_FILE="$SCRIPT_DIR/cnwp.yml"

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_status() {
    local status=$1
    local message=$2

    if [ "$status" == "OK" ]; then
        echo -e "[${GREEN}✓${NC}] $message"
    elif [ "$status" == "WARN" ]; then
        echo -e "[${YELLOW}!${NC}] $message"
    elif [ "$status" == "FAIL" ]; then
        echo -e "[${RED}✗${NC}] $message"
    else
        echo -e "[${BLUE}i${NC}] $message"
    fi
}

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

    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

################################################################################
# State Reading Functions
################################################################################

# Determine which state file to use (new format or legacy)
get_state_file() {
    if [ -f "$ORIGINAL_STATE_FILE" ]; then
        echo "$ORIGINAL_STATE_FILE"
    elif [ -f "$LEGACY_STATE_FILE" ]; then
        echo "$LEGACY_STATE_FILE"
    else
        echo ""
    fi
}

# Read state value - handles both new and legacy formats
read_state_value() {
    local key="$1"
    local state_file=$(get_state_file)

    if [ -z "$state_file" ]; then
        echo ""
        return 1
    fi

    # Check if it's the new format (with components section)
    if grep -q '"components"' "$state_file" 2>/dev/null; then
        # New format: look in components section
        local value=$(grep "\"$key\":" "$state_file" | grep -oE '[0-9]+' | head -1)
        if [ -n "$value" ] && [ "$value" -eq 1 ]; then
            echo "true"
        else
            echo "false"
        fi
    else
        # Legacy format: direct key lookup
        local value=$(grep "\"$key\"" "$state_file" | sed 's/.*": "\?\([^",]*\)"\?.*/\1/' | head -1)
        echo "$value"
    fi
}

# Map legacy keys to new component IDs
map_legacy_key() {
    local legacy_key="$1"

    case "$legacy_key" in
        had_docker)       echo "docker" ;;
        had_docker_compose) echo "docker_compose" ;;
        was_in_docker_group) echo "docker_group" ;;
        had_mkcert)       echo "mkcert" ;;
        had_mkcert_ca)    echo "mkcert_ca" ;;
        had_ddev)         echo "ddev" ;;
        had_ddev_config)  echo "ddev_config" ;;
        had_linode_cli)   echo "linode_cli" ;;
        installed_cli)    echo "nwp_cli" ;;
        *)                echo "" ;;
    esac
}

# Check if component was originally installed (before NWP)
was_originally_installed() {
    local component_id="$1"
    local state_file=$(get_state_file)

    if [ -z "$state_file" ]; then
        return 1
    fi

    # Check if new format
    if grep -q '"components"' "$state_file" 2>/dev/null; then
        local value=$(grep "\"$component_id\":" "$state_file" | grep -oE '[0-9]+' | head -1)
        [ "$value" -eq 1 ] 2>/dev/null
    else
        # Legacy format - map the key
        local legacy_key=""
        case "$component_id" in
            docker)         legacy_key="had_docker" ;;
            docker_compose) legacy_key="had_docker_compose" ;;
            docker_group)   legacy_key="was_in_docker_group" ;;
            mkcert)         legacy_key="had_mkcert" ;;
            mkcert_ca)      legacy_key="had_mkcert_ca" ;;
            ddev)           legacy_key="had_ddev" ;;
            ddev_config)    legacy_key="had_ddev_config" ;;
            linode_cli)     legacy_key="had_linode_cli" ;;
            *)              return 1 ;;
        esac

        local value=$(read_state_value "$legacy_key")
        [ "$value" == "true" ]
    fi
}

read_config_value() {
    local key="$1"
    local config_file="$CONFIG_FILE"

    [ -f "$config_file" ] || return 1
    grep "^  $key:" "$config_file" 2>/dev/null | head -1 | awk -F': ' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

################################################################################
# Uninstall Functions
################################################################################

remove_docker() {
    print_header "Removing Docker"

    if was_originally_installed "docker"; then
        print_status "INFO" "Docker was already installed before NWP setup"
        print_status "INFO" "Skipping Docker removal (keeping existing installation)"
        return 0
    fi

    if ask_yes_no "Remove Docker Engine and related packages?" "y"; then
        print_status "INFO" "Stopping Docker services..."
        sudo systemctl stop docker 2>/dev/null || true
        sudo systemctl disable docker 2>/dev/null || true

        print_status "INFO" "Removing Docker packages..."
        sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
        sudo apt-get autoremove -y 2>/dev/null || true

        print_status "INFO" "Removing Docker repository..."
        sudo rm -f /etc/apt/sources.list.d/docker.list
        sudo rm -f /etc/apt/keyrings/docker-archive-keyring.gpg

        print_status "OK" "Docker removed"
    else
        print_status "INFO" "Keeping Docker installed"
    fi
}

remove_docker_group() {
    print_header "Removing User from Docker Group"

    if was_originally_installed "docker_group"; then
        print_status "INFO" "User was already in docker group before NWP setup"
        print_status "INFO" "Skipping docker group removal"
        return 0
    fi

    if groups | grep -q docker; then
        if ask_yes_no "Remove $USER from docker group?" "y"; then
            sudo gpasswd -d $USER docker
            print_status "OK" "User removed from docker group"
            print_status "WARN" "You need to log out and log back in for this to take effect"
        fi
    else
        print_status "INFO" "User not in docker group"
    fi
}

remove_mkcert() {
    print_header "Removing mkcert"

    if was_originally_installed "mkcert"; then
        print_status "INFO" "mkcert was already installed before NWP setup"
        print_status "INFO" "Skipping mkcert removal"
        return 0
    fi

    if command -v mkcert &> /dev/null; then
        if ask_yes_no "Remove mkcert and its certificate authority?" "y"; then
            print_status "INFO" "Uninstalling mkcert CA..."
            mkcert -uninstall 2>/dev/null || true

            print_status "INFO" "Removing mkcert binary..."
            sudo rm -f /usr/local/bin/mkcert

            print_status "OK" "mkcert removed"
        fi
    else
        print_status "INFO" "mkcert not installed"
    fi
}

remove_ddev() {
    print_header "Removing DDEV"

    if was_originally_installed "ddev"; then
        print_status "INFO" "DDEV was already installed before NWP setup"
        print_status "INFO" "Skipping DDEV removal"
        return 0
    fi

    if command -v ddev &> /dev/null; then
        if ask_yes_no "Remove DDEV?" "y"; then
            print_status "INFO" "Stopping all DDEV projects..."
            ddev poweroff 2>/dev/null || true

            print_status "INFO" "Removing DDEV..."
            sudo rm -f /usr/local/bin/ddev
            sudo rm -f /usr/bin/ddev

            if ask_yes_no "Remove DDEV global configuration (~/.ddev)?" "n"; then
                rm -rf ~/.ddev
                print_status "OK" "DDEV configuration removed"
            fi

            print_status "OK" "DDEV removed"
        fi
    else
        print_status "INFO" "DDEV not installed"
    fi
}

remove_linode_cli() {
    print_header "Removing Linode CLI"

    if was_originally_installed "linode_cli"; then
        print_status "INFO" "Linode CLI was already installed before NWP setup"
        print_status "INFO" "Skipping Linode CLI removal"
        return 0
    fi

    if command -v linode-cli &> /dev/null; then
        if ask_yes_no "Remove Linode CLI?" "y"; then
            if command -v pipx &> /dev/null; then
                pipx uninstall linode-cli 2>/dev/null || true
            fi
            print_status "OK" "Linode CLI removed"
        fi
    else
        print_status "INFO" "Linode CLI not installed"
    fi
}

restore_shell_config() {
    print_header "Restoring Shell Configuration"

    local modified_bashrc=$(read_state_value "modified_bashrc")

    if [ "$modified_bashrc" == "true" ]; then
        if [ -f "$STATE_DIR/bashrc.backup" ]; then
            if ask_yes_no "Restore original ~/.bashrc?" "y"; then
                cp "$STATE_DIR/bashrc.backup" ~/.bashrc
                print_status "OK" "~/.bashrc restored from backup"
            fi
        else
            print_status "WARN" "No bashrc backup found"

            if ask_yes_no "Remove NWP-related lines from ~/.bashrc?" "y"; then
                # Remove lines added by NWP
                sed -i '/# Add local bin to PATH for pipx and other local tools/d' ~/.bashrc
                sed -i '/export PATH="\$HOME\/.local\/bin:\$PATH"/d' ~/.bashrc
                sed -i '/# NWP CLI/d' ~/.bashrc
                sed -i '/alias pl=/d' ~/.bashrc

                print_status "OK" "NWP lines removed from ~/.bashrc"
            fi
        fi
    else
        print_status "INFO" "Shell configuration was not modified"
    fi
}

remove_cli_command() {
    print_header "Removing CLI Command"

    # Determine project root (uninstall script is in scripts/commands/)
    local project_root="$(cd "$SCRIPT_DIR/../.." && pwd)"

    # Source CLI registration library if available
    if [ -f "$project_root/lib/cli-register.sh" ]; then
        # Temporarily set PROJECT_ROOT_CLI for the library
        export PROJECT_ROOT_CLI="$project_root"
        source "$project_root/lib/cli-register.sh"

        if ask_yes_no "Remove NWP CLI command?" "y"; then
            unregister_cli_command
        else
            print_status "INFO" "Keeping CLI command"
        fi
    else
        # Fallback to old method
        local cli_prompt=$(read_config_value "cliprompt")
        cli_prompt=${cli_prompt:-pl}

        if [ -f "/usr/local/bin/$cli_prompt" ]; then
            if ask_yes_no "Remove CLI command '$cli_prompt'?" "y"; then
                sudo rm -f "/usr/local/bin/$cli_prompt"
                print_status "OK" "CLI command removed"
            fi
        else
            print_status "INFO" "No CLI command to remove"
        fi
    fi
}

remove_ssh_keys() {
    print_header "Removing SSH Keys"

    local has_keys=false

    if [ -f "$SCRIPT_DIR/keys/nwp" ]; then
        has_keys=true
    fi

    if [ -f "$HOME/.ssh/nwp" ]; then
        has_keys=true
    fi

    if [ "$has_keys" = true ]; then
        if ask_yes_no "Remove NWP SSH keys?" "n"; then
            rm -f "$SCRIPT_DIR/keys/nwp" "$SCRIPT_DIR/keys/nwp.pub" 2>/dev/null || true
            rm -f "$HOME/.ssh/nwp" "$HOME/.ssh/nwp.pub" 2>/dev/null || true
            print_status "OK" "SSH keys removed"
        else
            print_status "INFO" "Keeping SSH keys"
        fi
    else
        print_status "INFO" "No SSH keys to remove"
    fi
}

remove_config_files() {
    print_header "Removing NWP Configuration Files"

    if [ -f "$CONFIG_FILE" ]; then
        if ask_yes_no "Remove cnwp.yml configuration file?" "n"; then
            rm -f "$CONFIG_FILE"
            print_status "OK" "cnwp.yml removed"
        else
            print_status "INFO" "Keeping cnwp.yml"
        fi
    fi

    if [ -d "$HOME/.nwp" ]; then
        echo ""
        print_status "INFO" "NWP configuration directory: $HOME/.nwp"
        print_status "INFO" "This contains:"
        echo "  - Setup state snapshots"
        echo "  - Linode/GitLab configurations"
        echo "  - SSH keys"
        echo ""

        if ask_yes_no "Remove entire ~/.nwp directory?" "n"; then
            rm -rf "$HOME/.nwp"
            print_status "OK" "~/.nwp removed"
        else
            print_status "INFO" "Keeping ~/.nwp directory"

            if ask_yes_no "Remove only setup state files?" "y"; then
                rm -rf "$STATE_DIR"
                print_status "OK" "Setup state files removed"
            fi
        fi
    fi
}

################################################################################
# Main Uninstall Process
################################################################################

main() {
    print_header "NWP Uninstaller"

    echo -e "${YELLOW}${BOLD}WARNING: This will remove NWP and potentially Docker, DDEV, and other tools.${NC}"
    echo -e "${YELLOW}Make sure you have backups of any important data!${NC}"
    echo ""

    # Check for state file
    local state_file=$(get_state_file)
    if [ -z "$state_file" ]; then
        print_status "WARN" "No installation state file found"
        print_status "INFO" "Checked locations:"
        print_status "INFO" "  - $ORIGINAL_STATE_FILE (new format)"
        print_status "INFO" "  - $LEGACY_STATE_FILE (legacy format)"
        echo ""
        print_status "INFO" "Without a state file, the uninstaller cannot determine what was"
        print_status "INFO" "installed by NWP vs. what was already on your system."
        echo ""

        if ! ask_yes_no "Continue with uninstall anyway (will prompt for each action)?" "n"; then
            echo "Uninstall cancelled."
            exit 0
        fi
        echo ""
    else
        local state_date=""
        if grep -q '"saved_date"' "$state_file" 2>/dev/null; then
            state_date=$(grep '"saved_date"' "$state_file" | cut -d'"' -f4)
        elif grep -q '"setup_date"' "$state_file" 2>/dev/null; then
            state_date=$(grep '"setup_date"' "$state_file" | cut -d'"' -f4)
        fi

        print_status "OK" "Found installation state from: $state_date"
        print_status "INFO" "State file: $state_file"
        echo ""
        print_status "INFO" "The uninstaller will:"
        echo "  - Skip removing tools that existed before NWP setup"
        echo "  - Remove only what NWP installed"
        echo "  - Restore modified configuration files"
        echo ""
    fi

    if ! ask_yes_no "Proceed with uninstall?" "n"; then
        echo "Uninstall cancelled."
        exit 0
    fi

    # Perform uninstall steps (in reverse dependency order)
    remove_ssh_keys
    remove_cli_command
    remove_linode_cli
    remove_ddev
    remove_mkcert
    remove_docker_group
    remove_docker
    restore_shell_config
    remove_config_files

    print_header "Uninstall Complete"

    echo "NWP has been uninstalled from your system."
    echo ""
    echo "What was removed/restored:"
    echo "  - Docker (if installed by NWP)"
    echo "  - DDEV (if installed by NWP)"
    echo "  - mkcert (if installed by NWP)"
    echo "  - Shell configuration changes"
    echo "  - CLI commands"
    echo ""
    echo "What you may need to do manually:"
    echo "  - Log out and log back in (if docker group was modified)"
    echo "  - Source ~/.bashrc or restart terminal"
    echo "  - Review ~/.nwp directory if not removed"
    echo ""

    if [ -f "$INSTALL_LOG" ]; then
        if ask_yes_no "View the installation log?" "n"; then
            less "$INSTALL_LOG"
        fi
    fi
}

# Run main
main "$@"
