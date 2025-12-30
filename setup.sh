#!/bin/bash

################################################################################
# NWP Setup Manager
#
# A complete tool for managing NWP prerequisites installation.
# Features:
#   - Only stores original configuration once (first run)
#   - Captures current state on each run
#   - Interactive checkbox UI with dependency hierarchy
#   - Can install or remove components based on user selection
#
# Use install.sh to create and configure actual projects.
################################################################################

set -e

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HOME/.nwp/setup_state"
ORIGINAL_STATE_FILE="$STATE_DIR/original_state.json"
CURRENT_STATE_FILE="$STATE_DIR/current_state.json"
INSTALL_LOG="$STATE_DIR/install.log"
CONFIG_FILE="$SCRIPT_DIR/cnwp.yml"
EXAMPLE_CONFIG="$SCRIPT_DIR/example.cnwp.yml"

# Source UI library if available
if [ -f "$SCRIPT_DIR/lib/ui.sh" ]; then
    source "$SCRIPT_DIR/lib/ui.sh"
else
    # Fallback colors
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
    BOLD='\033[1m'

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
            *)    echo -e "[${BLUE}i${NC}] $message" ;;
        esac
    }
fi

################################################################################
# Component Hierarchy Definition
#
# Format: COMPONENT_ID|DISPLAY_NAME|PARENT_ID|CATEGORY
# Parent ID of "-" means no parent (root level)
################################################################################

declare -a COMPONENTS=(
    # Core Infrastructure - grouped by dependency
    "docker|Docker Engine|-|core"
    "docker_compose|Docker Compose Plugin|docker|core"
    "docker_group|Docker Group Membership|docker|core"
    "ddev|DDEV Development Environment|docker|core"
    "ddev_config|DDEV Global Configuration|ddev|core"
    "mkcert|mkcert SSL Tool|-|core"
    "mkcert_ca|mkcert Certificate Authority|mkcert|core"

    # NWP Tools
    "nwp_cli|NWP CLI Command|-|tools"
    "nwp_config|NWP Configuration (cnwp.yml)|-|tools"

    # Optional Infrastructure
    "linode_cli|Linode CLI|-|optional"
    "ssh_keys|SSH Keys for Deployment|linode_cli|optional"
)

# Track component states
declare -A COMPONENT_INSTALLED    # Currently installed
declare -A COMPONENT_ORIGINAL     # Was installed before NWP
declare -A COMPONENT_SELECTED     # User wants it installed

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
    local message="$1"
    mkdir -p "$STATE_DIR"
    echo "[$(date -Iseconds)] $message" >> "$INSTALL_LOG"
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

get_component_field() {
    local component_id="$1"
    local field="$2"  # 1=id, 2=name, 3=parent, 4=category

    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        if [ "$id" == "$component_id" ]; then
            echo "$comp" | cut -d'|' -f"$field"
            return 0
        fi
    done
    return 1
}

get_children() {
    local parent_id="$1"
    local children=""

    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        local parent=$(echo "$comp" | cut -d'|' -f3)
        if [ "$parent" == "$parent_id" ]; then
            children="$children $id"
        fi
    done
    echo "$children" | xargs
}

################################################################################
# State Detection Functions
################################################################################

check_docker_installed() {
    command -v docker &> /dev/null && docker --version &> /dev/null
}

check_docker_running() {
    docker ps &> /dev/null 2>&1
}

check_docker_compose_installed() {
    docker compose version &> /dev/null 2>&1
}

check_docker_group() {
    groups 2>/dev/null | grep -q docker
}

check_mkcert_installed() {
    command -v mkcert &> /dev/null
}

check_mkcert_ca_installed() {
    if check_mkcert_installed; then
        local ca_root=$(mkcert -CAROOT 2>/dev/null)
        [ -n "$ca_root" ] && [ -f "$ca_root/rootCA.pem" ]
    else
        return 1
    fi
}

check_ddev_installed() {
    command -v ddev &> /dev/null
}

check_ddev_config_exists() {
    [ -f "$HOME/.ddev/global_config.yaml" ]
}

check_nwp_cli_installed() {
    local cli_prompt=$(read_config_value "cliprompt")
    cli_prompt=${cli_prompt:-pl}
    [ -f "/usr/local/bin/$cli_prompt" ]
}

check_nwp_config_exists() {
    [ -f "$CONFIG_FILE" ]
}

check_linode_cli_installed() {
    command -v linode-cli &> /dev/null
}

check_ssh_keys_exist() {
    [ -f "$SCRIPT_DIR/keys/nwp" ] || [ -f "$HOME/.ssh/nwp" ]
}

# Main detection function
detect_component_state() {
    local component_id="$1"

    case "$component_id" in
        docker)         check_docker_installed ;;
        docker_compose) check_docker_compose_installed ;;
        docker_group)   check_docker_group ;;
        mkcert)         check_mkcert_installed ;;
        mkcert_ca)      check_mkcert_ca_installed ;;
        ddev)           check_ddev_installed ;;
        ddev_config)    check_ddev_config_exists ;;
        nwp_cli)        check_nwp_cli_installed ;;
        nwp_config)     check_nwp_config_exists ;;
        linode_cli)     check_linode_cli_installed ;;
        ssh_keys)       check_ssh_keys_exist ;;
        *)              return 1 ;;
    esac
}

detect_all_current_states() {
    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        if detect_component_state "$id"; then
            COMPONENT_INSTALLED[$id]=1
        else
            COMPONENT_INSTALLED[$id]=0
        fi
    done
}

################################################################################
# Original State Management (Only saved once)
################################################################################

save_original_state() {
    mkdir -p "$STATE_DIR"

    # Only save if it doesn't exist
    if [ -f "$ORIGINAL_STATE_FILE" ]; then
        print_status "OK" "Original state already recorded ($(grep 'saved_date' "$ORIGINAL_STATE_FILE" | cut -d'"' -f4))"
        return 0
    fi

    print_status "INFO" "Recording original system state (first run)..."

    # Detect current state of all components
    detect_all_current_states

    # Build JSON
    cat > "$ORIGINAL_STATE_FILE" << EOF
{
  "saved_date": "$(date -Iseconds)",
  "user": "$USER",
  "hostname": "$(hostname)",
  "components": {
EOF

    local first=true
    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        local name=$(echo "$comp" | cut -d'|' -f2)
        [ "$first" = true ] && first=false || echo "," >> "$ORIGINAL_STATE_FILE"
        echo -n "    \"$id\": ${COMPONENT_INSTALLED[$id]:-0}" >> "$ORIGINAL_STATE_FILE"
    done

    cat >> "$ORIGINAL_STATE_FILE" << EOF

  }
}
EOF

    # Backup bashrc
    if [ -f "$HOME/.bashrc" ]; then
        cp "$HOME/.bashrc" "$STATE_DIR/bashrc.backup"
    fi

    # Record packages
    dpkg -l > "$STATE_DIR/packages_before.txt" 2>/dev/null || true

    print_status "OK" "Original state saved to: $ORIGINAL_STATE_FILE"
    log_action "Original state saved"
}

load_original_state() {
    if [ ! -f "$ORIGINAL_STATE_FILE" ]; then
        return 1
    fi

    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        local value=$(grep "\"$id\":" "$ORIGINAL_STATE_FILE" | grep -oE '[0-9]+' | head -1)
        COMPONENT_ORIGINAL[$id]=${value:-0}
    done
}

save_current_state() {
    mkdir -p "$STATE_DIR"

    detect_all_current_states

    cat > "$CURRENT_STATE_FILE" << EOF
{
  "saved_date": "$(date -Iseconds)",
  "components": {
EOF

    local first=true
    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        [ "$first" = true ] && first=false || echo "," >> "$CURRENT_STATE_FILE"
        echo -n "    \"$id\": ${COMPONENT_INSTALLED[$id]:-0}" >> "$CURRENT_STATE_FILE"
    done

    cat >> "$CURRENT_STATE_FILE" << EOF

  }
}
EOF
}

################################################################################
# Installation Functions
################################################################################

install_docker() {
    print_header "Installing Docker Engine"
    log_action "Installing Docker Engine"

    echo "Removing old Docker versions..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    echo "Installing prerequisites..."
    sudo apt-get update
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common

    echo "Adding Docker's GPG key..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker-archive-keyring.gpg

    echo "Adding Docker repository..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    echo "Installing Docker Engine..."
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    echo "Starting Docker service..."
    sudo systemctl start docker
    sudo systemctl enable docker

    print_status "OK" "Docker installed successfully"
    log_action "Docker Engine installed"
}

install_docker_group() {
    print_header "Adding User to Docker Group"
    log_action "Adding user to docker group"

    sudo groupadd docker 2>/dev/null || true
    sudo usermod -aG docker $USER

    print_status "OK" "User added to docker group"
    print_status "WARN" "You need to log out and log back in for this to take effect"
    log_action "User added to docker group"
}

install_mkcert() {
    print_header "Installing mkcert"
    log_action "Installing mkcert"

    echo "Installing NSS tools..."
    sudo apt-get update
    sudo apt install -y libnss3-tools

    echo "Downloading mkcert..."
    curl -JLO "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
    chmod +x mkcert-v*-linux-amd64
    sudo mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert

    print_status "OK" "mkcert installed"
    log_action "mkcert installed"
}

install_mkcert_ca() {
    print_header "Installing mkcert Certificate Authority"
    log_action "Installing mkcert CA"

    mkcert -install

    print_status "OK" "mkcert CA installed"
    log_action "mkcert CA installed"
}

install_ddev() {
    print_header "Installing DDEV"
    log_action "Installing DDEV"

    echo "Downloading and installing DDEV..."
    curl -fsSL https://ddev.com/install.sh | bash

    print_status "OK" "DDEV installed"
    log_action "DDEV installed"
}

install_ddev_config() {
    print_header "Creating DDEV Global Configuration"
    log_action "Creating DDEV config"

    mkdir -p ~/.ddev

    cat > ~/.ddev/global_config.yaml << 'EOF'
# DDEV Global Configuration
use_dns_when_possible: false
router_http_port: "80"
router_https_port: "443"
instrumentation_opt_in: false
php_version: "8.3"
EOF

    print_status "OK" "DDEV global config created"
    log_action "DDEV config created"
}

install_nwp_cli() {
    print_header "Installing NWP CLI"
    log_action "Installing NWP CLI"

    local cli_prompt=$(read_config_value "cliprompt")
    cli_prompt=${cli_prompt:-pl}
    local cli_script="/usr/local/bin/$cli_prompt"

    print_status "INFO" "Creating CLI command: $cli_prompt"

    sudo tee "$cli_script" > /dev/null << 'CLIEOF'
#!/bin/bash
# NWP CLI Wrapper

NWP_DIR="$HOME/nwp"

# Try to find NWP directory
if [ ! -d "$NWP_DIR" ]; then
    for dir in "$HOME/nwp" "$HOME/projects/nwp" "$HOME/setup" "/opt/nwp"; do
        if [ -d "$dir" ] && [ -f "$dir/install.sh" ]; then
            NWP_DIR="$dir"
            break
        fi
    done
fi

if [ ! -d "$NWP_DIR" ]; then
    echo "Error: NWP directory not found"
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "NWP CLI - Narrow Way Project"
    echo ""
    echo "Usage: $(basename "$0") <script> [arguments]"
    echo ""
    echo "Scripts: install, make, backup, restore, copy, delete, dev2stg, setup, test-nwp"
    exit 0
fi

SCRIPT_NAME="$1"
shift

case "$SCRIPT_NAME" in
    install|i)    SCRIPT="install.sh" ;;
    make|m)       SCRIPT="make.sh" ;;
    backup|b)     SCRIPT="backup.sh" ;;
    restore|r)    SCRIPT="restore.sh" ;;
    copy|cp)      SCRIPT="copy.sh" ;;
    delete|del)   SCRIPT="delete.sh" ;;
    dev2stg|d2s)  SCRIPT="dev2stg.sh" ;;
    setup|check)  SCRIPT="setup.sh" ;;
    test|test-nwp) SCRIPT="test-nwp.sh" ;;
    --list)       cd "$NWP_DIR" && ./install.sh --list; exit $? ;;
    *)            echo "Unknown: $SCRIPT_NAME"; exit 1 ;;
esac

cd "$NWP_DIR"
exec "./$SCRIPT" "$@"
CLIEOF

    sudo chmod +x "$cli_script"

    print_status "OK" "CLI command '$cli_prompt' installed"
    log_action "NWP CLI installed: $cli_prompt"
}

install_nwp_config() {
    print_header "Creating NWP Configuration"
    log_action "Creating NWP config"

    if [ -f "$EXAMPLE_CONFIG" ]; then
        cp "$EXAMPLE_CONFIG" "$CONFIG_FILE"
        print_status "OK" "cnwp.yml created from example"
    else
        print_status "FAIL" "example.cnwp.yml not found"
        return 1
    fi

    log_action "NWP config created"
}

install_linode_cli() {
    print_header "Installing Linode CLI"
    log_action "Installing Linode CLI"

    # Install pipx if needed
    if ! command -v pipx &> /dev/null; then
        echo "Installing pipx..."
        sudo apt-get update
        sudo apt-get install -y pipx
        pipx ensurepath
    fi

    echo "Installing linode-cli..."
    pipx install linode-cli

    print_status "OK" "Linode CLI installed"
    print_status "INFO" "Run 'linode-cli configure' to set up authentication"
    log_action "Linode CLI installed"
}

install_ssh_keys() {
    print_header "Setting up SSH Keys"
    log_action "Setting up SSH keys"

    if [ -x "$SCRIPT_DIR/setup-ssh.sh" ]; then
        "$SCRIPT_DIR/setup-ssh.sh"
    else
        print_status "FAIL" "setup-ssh.sh not found or not executable"
        return 1
    fi

    log_action "SSH keys configured"
}

# Main install dispatcher
install_component() {
    local component_id="$1"

    case "$component_id" in
        docker)         install_docker ;;
        docker_compose) print_status "OK" "Docker Compose included with Docker" ;;
        docker_group)   install_docker_group ;;
        mkcert)         install_mkcert ;;
        mkcert_ca)      install_mkcert_ca ;;
        ddev)           install_ddev ;;
        ddev_config)    install_ddev_config ;;
        nwp_cli)        install_nwp_cli ;;
        nwp_config)     install_nwp_config ;;
        linode_cli)     install_linode_cli ;;
        ssh_keys)       install_ssh_keys ;;
        *)              print_status "WARN" "Unknown component: $component_id" ;;
    esac
}

################################################################################
# Removal Functions
################################################################################

remove_docker() {
    print_header "Removing Docker"
    log_action "Removing Docker"

    # Check if it was originally installed
    if [ "${COMPONENT_ORIGINAL[docker]:-0}" -eq 1 ]; then
        print_status "WARN" "Docker was installed before NWP - keeping it"
        return 0
    fi

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
    log_action "Docker removed"
}

remove_docker_group() {
    print_header "Removing User from Docker Group"
    log_action "Removing from docker group"

    if [ "${COMPONENT_ORIGINAL[docker_group]:-0}" -eq 1 ]; then
        print_status "WARN" "User was in docker group before NWP - keeping membership"
        return 0
    fi

    if groups | grep -q docker; then
        sudo gpasswd -d $USER docker 2>/dev/null || true
        print_status "OK" "User removed from docker group"
        print_status "WARN" "Log out and back in to take effect"
    fi

    log_action "Docker group membership removed"
}

remove_mkcert() {
    print_header "Removing mkcert"
    log_action "Removing mkcert"

    if [ "${COMPONENT_ORIGINAL[mkcert]:-0}" -eq 1 ]; then
        print_status "WARN" "mkcert was installed before NWP - keeping it"
        return 0
    fi

    if command -v mkcert &> /dev/null; then
        sudo rm -f /usr/local/bin/mkcert
        print_status "OK" "mkcert removed"
    fi

    log_action "mkcert removed"
}

remove_mkcert_ca() {
    print_header "Removing mkcert CA"
    log_action "Removing mkcert CA"

    if [ "${COMPONENT_ORIGINAL[mkcert_ca]:-0}" -eq 1 ]; then
        print_status "WARN" "mkcert CA was installed before NWP - keeping it"
        return 0
    fi

    if command -v mkcert &> /dev/null; then
        mkcert -uninstall 2>/dev/null || true
        print_status "OK" "mkcert CA removed"
    fi

    log_action "mkcert CA removed"
}

remove_ddev() {
    print_header "Removing DDEV"
    log_action "Removing DDEV"

    if [ "${COMPONENT_ORIGINAL[ddev]:-0}" -eq 1 ]; then
        print_status "WARN" "DDEV was installed before NWP - keeping it"
        return 0
    fi

    if command -v ddev &> /dev/null; then
        ddev poweroff 2>/dev/null || true
        sudo rm -f /usr/local/bin/ddev /usr/bin/ddev
        print_status "OK" "DDEV removed"
    fi

    log_action "DDEV removed"
}

remove_ddev_config() {
    print_header "Removing DDEV Configuration"
    log_action "Removing DDEV config"

    if [ "${COMPONENT_ORIGINAL[ddev_config]:-0}" -eq 1 ]; then
        print_status "WARN" "DDEV config existed before NWP - keeping it"
        return 0
    fi

    if [ -f "$HOME/.ddev/global_config.yaml" ]; then
        rm -f "$HOME/.ddev/global_config.yaml"
        print_status "OK" "DDEV config removed"
    fi

    log_action "DDEV config removed"
}

remove_nwp_cli() {
    print_header "Removing NWP CLI"
    log_action "Removing NWP CLI"

    local cli_prompt=$(read_config_value "cliprompt")
    cli_prompt=${cli_prompt:-pl}

    if [ -f "/usr/local/bin/$cli_prompt" ]; then
        sudo rm -f "/usr/local/bin/$cli_prompt"
        print_status "OK" "CLI command '$cli_prompt' removed"
    fi

    log_action "NWP CLI removed"
}

remove_nwp_config() {
    print_header "Removing NWP Configuration"
    log_action "Removing NWP config"

    if [ "${COMPONENT_ORIGINAL[nwp_config]:-0}" -eq 1 ]; then
        print_status "WARN" "NWP config existed before - keeping it"
        return 0
    fi

    if [ -f "$CONFIG_FILE" ]; then
        rm -f "$CONFIG_FILE"
        print_status "OK" "cnwp.yml removed"
    fi

    log_action "NWP config removed"
}

remove_linode_cli() {
    print_header "Removing Linode CLI"
    log_action "Removing Linode CLI"

    if [ "${COMPONENT_ORIGINAL[linode_cli]:-0}" -eq 1 ]; then
        print_status "WARN" "Linode CLI was installed before NWP - keeping it"
        return 0
    fi

    if command -v pipx &> /dev/null; then
        pipx uninstall linode-cli 2>/dev/null || true
        print_status "OK" "Linode CLI removed"
    fi

    log_action "Linode CLI removed"
}

remove_ssh_keys() {
    print_header "Removing SSH Keys"
    log_action "Removing SSH keys"

    if [ "${COMPONENT_ORIGINAL[ssh_keys]:-0}" -eq 1 ]; then
        print_status "WARN" "SSH keys existed before NWP - keeping them"
        return 0
    fi

    if [ -f "$SCRIPT_DIR/keys/nwp" ]; then
        rm -f "$SCRIPT_DIR/keys/nwp" "$SCRIPT_DIR/keys/nwp.pub"
        print_status "OK" "SSH keys removed from keys/"
    fi

    if [ -f "$HOME/.ssh/nwp" ]; then
        rm -f "$HOME/.ssh/nwp" "$HOME/.ssh/nwp.pub"
        print_status "OK" "SSH keys removed from ~/.ssh/"
    fi

    log_action "SSH keys removed"
}

# Main remove dispatcher
remove_component() {
    local component_id="$1"

    case "$component_id" in
        docker)         remove_docker ;;
        docker_compose) print_status "OK" "Docker Compose removed with Docker" ;;
        docker_group)   remove_docker_group ;;
        mkcert)         remove_mkcert ;;
        mkcert_ca)      remove_mkcert_ca ;;
        ddev)           remove_ddev ;;
        ddev_config)    remove_ddev_config ;;
        nwp_cli)        remove_nwp_cli ;;
        nwp_config)     remove_nwp_config ;;
        linode_cli)     remove_linode_cli ;;
        ssh_keys)       remove_ssh_keys ;;
        *)              print_status "WARN" "Unknown component: $component_id" ;;
    esac
}

################################################################################
# Interactive UI Functions
################################################################################

check_dialog_available() {
    if command -v dialog &> /dev/null; then
        echo "dialog"
    elif command -v whiptail &> /dev/null; then
        echo "whiptail"
    else
        echo "none"
    fi
}

install_dialog() {
    echo "Installing dialog for interactive UI..."
    sudo apt-get update
    sudo apt-get install -y dialog
}

show_checkbox_ui() {
    local dialog_cmd=$(check_dialog_available)

    if [ "$dialog_cmd" == "none" ]; then
        if ask_yes_no "Install 'dialog' for better UI?" "y"; then
            install_dialog
            dialog_cmd="dialog"
        else
            show_text_ui
            return $?
        fi
    fi

    # Build checklist items with hierarchy
    local items=()
    local current_category=""

    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        local name=$(echo "$comp" | cut -d'|' -f2)
        local parent=$(echo "$comp" | cut -d'|' -f3)
        local category=$(echo "$comp" | cut -d'|' -f4)

        # Add indentation for children
        local display_name="$name"
        if [ "$parent" != "-" ]; then
            display_name="  └─ $name"
        fi

        # Default selection based on current state
        local state="off"
        if [ "${COMPONENT_INSTALLED[$id]:-0}" -eq 1 ]; then
            state="on"
        fi

        # For core items, default to on if not installed but needed
        if [ "$category" == "core" ] && [ "$parent" == "-" ]; then
            state="on"
        fi

        items+=("$id" "$display_name" "$state")
    done

    # Show dialog
    local result
    result=$($dialog_cmd --title "NWP Setup Manager" \
        --backtitle "Select components to install/keep (Space to toggle, Enter to confirm)" \
        --checklist "Use SPACE to select/deselect components.\nComponents with └─ depend on their parent.\n\nLegend: [*] = installed, [ ] = not installed" \
        25 70 15 \
        "${items[@]}" \
        3>&1 1>&2 2>&3)

    local exit_status=$?

    if [ $exit_status -ne 0 ]; then
        return 1
    fi

    # Parse selections
    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        COMPONENT_SELECTED[$id]=0
    done

    for selected in $result; do
        # Remove quotes
        selected=$(echo "$selected" | tr -d '"')
        COMPONENT_SELECTED[$selected]=1
    done

    return 0
}

show_text_ui() {
    print_header "Component Selection"

    echo "Current installation state:"
    echo ""

    local num=1
    declare -A NUM_TO_ID

    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        local name=$(echo "$comp" | cut -d'|' -f2)
        local parent=$(echo "$comp" | cut -d'|' -f3)
        local category=$(echo "$comp" | cut -d'|' -f4)

        local indent=""
        if [ "$parent" != "-" ]; then
            indent="    "
        fi

        local status_icon="[ ]"
        if [ "${COMPONENT_INSTALLED[$id]:-0}" -eq 1 ]; then
            status_icon="[*]"
            COMPONENT_SELECTED[$id]=1
        else
            COMPONENT_SELECTED[$id]=0
        fi

        printf "%s%2d) %s %s\n" "$indent" "$num" "$status_icon" "$name"
        NUM_TO_ID[$num]=$id
        ((num++))
    done

    echo ""
    echo "Enter numbers to toggle (space-separated), 'a' for all core, or 'q' to proceed:"
    read -p "> " selections

    if [ "$selections" == "q" ] || [ -z "$selections" ]; then
        return 0
    fi

    if [ "$selections" == "a" ]; then
        # Select all core components
        for comp in "${COMPONENTS[@]}"; do
            local id=$(echo "$comp" | cut -d'|' -f1)
            local category=$(echo "$comp" | cut -d'|' -f4)
            if [ "$category" == "core" ]; then
                COMPONENT_SELECTED[$id]=1
            fi
        done
        return 0
    fi

    # Toggle selected items
    for sel in $selections; do
        if [[ "$sel" =~ ^[0-9]+$ ]]; then
            local id="${NUM_TO_ID[$sel]}"
            if [ -n "$id" ]; then
                if [ "${COMPONENT_SELECTED[$id]:-0}" -eq 1 ]; then
                    COMPONENT_SELECTED[$id]=0
                else
                    COMPONENT_SELECTED[$id]=1
                fi
            fi
        fi
    done

    return 0
}

################################################################################
# Dependency Enforcement
################################################################################

enforce_dependencies() {
    local changed=true

    while [ "$changed" = true ]; do
        changed=false

        for comp in "${COMPONENTS[@]}"; do
            local id=$(echo "$comp" | cut -d'|' -f1)
            local parent=$(echo "$comp" | cut -d'|' -f3)

            if [ "$parent" != "-" ]; then
                # If child is selected but parent is not, select parent
                if [ "${COMPONENT_SELECTED[$id]:-0}" -eq 1 ] && [ "${COMPONENT_SELECTED[$parent]:-0}" -eq 0 ]; then
                    print_status "INFO" "Selecting '$parent' (required by '$(get_component_field "$id" 2)')"
                    COMPONENT_SELECTED[$parent]=1
                    changed=true
                fi

                # If parent is deselected, deselect children
                if [ "${COMPONENT_SELECTED[$parent]:-0}" -eq 0 ] && [ "${COMPONENT_SELECTED[$id]:-0}" -eq 1 ]; then
                    print_status "INFO" "Deselecting '$(get_component_field "$id" 2)' (parent '$parent' deselected)"
                    COMPONENT_SELECTED[$id]=0
                    changed=true
                fi
            fi
        done
    done
}

################################################################################
# Apply Changes
################################################################################

apply_changes() {
    print_header "Applying Changes"

    local to_install=()
    local to_remove=()

    # Determine what needs to change
    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        local name=$(echo "$comp" | cut -d'|' -f2)
        local installed=${COMPONENT_INSTALLED[$id]:-0}
        local selected=${COMPONENT_SELECTED[$id]:-0}

        if [ "$selected" -eq 1 ] && [ "$installed" -eq 0 ]; then
            to_install+=("$id")
        elif [ "$selected" -eq 0 ] && [ "$installed" -eq 1 ]; then
            to_remove+=("$id")
        fi
    done

    # Show summary
    if [ ${#to_install[@]} -eq 0 ] && [ ${#to_remove[@]} -eq 0 ]; then
        print_status "OK" "No changes needed - system matches selection"
        return 0
    fi

    echo "Changes to be made:"
    echo ""

    if [ ${#to_install[@]} -gt 0 ]; then
        echo -e "${GREEN}To install:${NC}"
        for id in "${to_install[@]}"; do
            echo "  + $(get_component_field "$id" 2)"
        done
        echo ""
    fi

    if [ ${#to_remove[@]} -gt 0 ]; then
        echo -e "${RED}To remove:${NC}"
        for id in "${to_remove[@]}"; do
            echo "  - $(get_component_field "$id" 2)"
        done
        echo ""
    fi

    if ! ask_yes_no "Proceed with these changes?" "y"; then
        print_status "INFO" "Cancelled"
        return 1
    fi

    # Remove components (in reverse order for dependencies)
    if [ ${#to_remove[@]} -gt 0 ]; then
        print_header "Removing Components"
        # Reverse array for proper dependency order
        local reversed=()
        for ((i=${#to_remove[@]}-1; i>=0; i--)); do
            reversed+=("${to_remove[$i]}")
        done
        for id in "${reversed[@]}"; do
            remove_component "$id"
        done
    fi

    # Install components (in order)
    if [ ${#to_install[@]} -gt 0 ]; then
        print_header "Installing Components"
        for id in "${to_install[@]}"; do
            install_component "$id"
        done
    fi

    print_status "OK" "All changes applied"
    return 0
}

################################################################################
# Status Display
################################################################################

show_status() {
    print_header "Current System Status"

    detect_all_current_states
    load_original_state

    local current_category=""

    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        local name=$(echo "$comp" | cut -d'|' -f2)
        local parent=$(echo "$comp" | cut -d'|' -f3)
        local category=$(echo "$comp" | cut -d'|' -f4)

        # Print category header
        if [ "$category" != "$current_category" ]; then
            current_category="$category"
            echo ""
            case "$category" in
                core)     echo -e "${BOLD}Core Infrastructure:${NC}" ;;
                tools)    echo -e "${BOLD}NWP Tools:${NC}" ;;
                optional) echo -e "${BOLD}Optional Components:${NC}" ;;
            esac
        fi

        local indent=""
        if [ "$parent" != "-" ]; then
            indent="  "
        fi

        local status="FAIL"
        local extra=""
        if [ "${COMPONENT_INSTALLED[$id]:-0}" -eq 1 ]; then
            status="OK"
            if [ "${COMPONENT_ORIGINAL[$id]:-0}" -eq 1 ]; then
                extra=" (pre-existing)"
            fi
        fi

        print_status "$status" "${indent}${name}${extra}"
    done

    echo ""
}

################################################################################
# Main Function
################################################################################

show_help() {
    echo "NWP Setup Manager"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --status    Show current installation status"
    echo "  --auto      Auto-install all core components"
    echo "  --help      Show this help message"
    echo ""
    echo "Without options, runs interactive setup."
}

main() {
    # Parse arguments
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --status)
            save_original_state
            show_status
            exit 0
            ;;
        --auto)
            save_original_state
            detect_all_current_states
            load_original_state

            # Select all core components
            for comp in "${COMPONENTS[@]}"; do
                local id=$(echo "$comp" | cut -d'|' -f1)
                local category=$(echo "$comp" | cut -d'|' -f4)
                if [ "$category" == "core" ]; then
                    COMPONENT_SELECTED[$id]=1
                else
                    COMPONENT_SELECTED[$id]=${COMPONENT_INSTALLED[$id]:-0}
                fi
            done

            apply_changes
            save_current_state
            exit 0
            ;;
    esac

    print_header "NWP Setup Manager"

    echo "This tool manages NWP prerequisites installation."
    echo "You can select which components to install or remove."
    echo ""

    # Save original state (only on first run)
    save_original_state

    # Detect current state
    detect_all_current_states
    load_original_state

    # Show current status
    show_status

    echo ""
    if ! ask_yes_no "Would you like to modify the installation?" "y"; then
        print_status "INFO" "No changes made"
        exit 0
    fi

    # Show component selection UI
    if ! show_checkbox_ui; then
        print_status "INFO" "Cancelled"
        exit 0
    fi

    # Enforce dependencies
    enforce_dependencies

    # Apply changes
    apply_changes

    # Save current state
    save_current_state

    print_header "Setup Complete"

    echo "Summary:"
    echo "  - Original state saved: $ORIGINAL_STATE_FILE"
    echo "  - Current state saved: $CURRENT_STATE_FILE"
    echo "  - Installation log: $INSTALL_LOG"
    echo ""
    echo "Next steps:"
    echo "  ./install.sh --list    # View available recipes"
    echo "  ./install.sh <recipe>  # Install a project"
    echo ""
    echo "To uninstall or modify:"
    echo "  ./setup.sh             # Run this script again"
    echo ""
}

# Run main
main "$@"
