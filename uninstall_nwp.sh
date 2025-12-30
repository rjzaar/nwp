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
STATE_FILE="$STATE_DIR/pre_setup_state.json"
INSTALL_LOG="$STATE_DIR/install.log"

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

read_state_value() {
    local key="$1"

    if [ ! -f "$STATE_FILE" ]; then
        echo ""
        return 1
    fi

    # Simple JSON parsing (assumes values are on same line as key)
    local value=$(grep "\"$key\"" "$STATE_FILE" | sed 's/.*": "\?\([^",]*\)"\?.*/\1/' | head -1)
    echo "$value"
}

################################################################################
# Uninstall Functions
################################################################################

remove_docker() {
    print_header "Removing Docker"

    local had_docker=$(read_state_value "had_docker")

    if [ "$had_docker" == "true" ]; then
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

    local was_in_docker_group=$(read_state_value "was_in_docker_group")

    if [ "$was_in_docker_group" == "true" ]; then
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

    local had_mkcert=$(read_state_value "had_mkcert")

    if [ "$had_mkcert" == "true" ]; then
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

    local had_ddev=$(read_state_value "had_ddev")

    if [ "$had_ddev" == "true" ]; then
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

remove_cli_symlinks() {
    print_header "Removing CLI Symlinks"

    local installed_cli=$(read_state_value "installed_cli")
    local cli_prompt=$(read_state_value "cli_prompt")

    if [ "$installed_cli" == "true" ] && [ -n "$cli_prompt" ]; then
        if [ -L "/usr/local/bin/$cli_prompt" ]; then
            if ask_yes_no "Remove CLI command '$cli_prompt'?" "y"; then
                sudo rm -f "/usr/local/bin/$cli_prompt"
                print_status "OK" "CLI command removed"
            fi
        fi
    else
        print_status "INFO" "No CLI symlinks to remove"
    fi
}

remove_config_files() {
    print_header "Removing NWP Configuration Files"

    if [ -f "$SCRIPT_DIR/cnwp.yml" ]; then
        if ask_yes_no "Remove cnwp.yml configuration file?" "n"; then
            rm -f "$SCRIPT_DIR/cnwp.yml"
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
    if [ ! -f "$STATE_FILE" ]; then
        print_status "WARN" "No installation state file found"
        print_status "INFO" "State file expected at: $STATE_FILE"
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
        print_status "OK" "Found installation state from: $(read_state_value 'setup_date')"
        echo ""
        print_status "INFO" "The uninstaller will:"
        echo "  • Skip removing tools that existed before NWP setup"
        echo "  • Remove only what NWP installed"
        echo "  • Restore modified configuration files"
        echo ""
    fi

    if ! ask_yes_no "Proceed with uninstall?" "n"; then
        echo "Uninstall cancelled."
        exit 0
    fi

    # Perform uninstall steps
    remove_cli_symlinks
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
    echo "  • Docker (if installed by NWP)"
    echo "  • DDEV (if installed by NWP)"
    echo "  • mkcert (if installed by NWP)"
    echo "  • Shell configuration changes"
    echo "  • CLI symlinks"
    echo ""
    echo "What you may need to do manually:"
    echo "  • Log out and log back in (if docker group was modified)"
    echo "  • Source ~/.bashrc or restart terminal"
    echo "  • Review ~/.nwp directory if not removed"
    echo ""

    if ask_yes_no "View the installation log?" "n"; then
        if [ -f "$INSTALL_LOG" ]; then
            less "$INSTALL_LOG"
        else
            print_status "INFO" "No installation log found"
        fi
    fi
}

# Run main
main "$@"
