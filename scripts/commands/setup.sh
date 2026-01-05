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
# Format: COMPONENT_ID|DISPLAY_NAME|PARENT_ID|CATEGORY|PRIORITY
# Parent ID of "-" means no parent (root level)
# Priority: required = needed for NWP to work
#           recommended = suggested for full experience
#           optional = extra features (server provisioning, GitLab)
################################################################################

declare -a COMPONENTS=(
    # Core Infrastructure - grouped by dependency
    "docker|Docker Engine|-|core|required"
    "script_symlinks|Script Symlinks (backward compat)|-|core|recommended"
    "docker_compose|Docker Compose Plugin|docker|core|required"
    "docker_group|Docker Group Membership|docker|core|required"
    "ddev|DDEV Development Environment|docker|core|required"
    "ddev_config|DDEV Global Configuration|ddev|core|required"
    "mkcert|mkcert SSL Tool|-|core|recommended"
    "mkcert_ca|mkcert Certificate Authority|mkcert|core|recommended"

    # NWP Tools
    "nwp_cli|NWP CLI Command|-|tools|recommended"
    "nwp_config|NWP Configuration (cnwp.yml)|-|tools|required"
    "nwp_secrets|NWP Secrets (.secrets.yml)|-|tools|recommended"

    # Testing Tools
    "bats|BATS Testing Framework|-|testing|optional"

    # Linode Infrastructure
    # NOTE: SSH keys are passed directly to servers via StackScripts during
    # provisioning. Adding keys to Linode profile is NOT required for NWP.
    "linode_cli|Linode CLI|-|linode|optional"
    "linode_config|Linode CLI Configuration|linode_cli|linode|optional"
    "ssh_keys|SSH Keys for Deployment|linode_cli|linode|optional"

    # GitLab Infrastructure (requires Linode)
    "gitlab_keys|GitLab SSH Keys|linode_config|gitlab|optional"
    "gitlab_server|GitLab Server|gitlab_keys|gitlab|optional"
    "gitlab_dns|GitLab DNS Record|gitlab_server|gitlab|optional"
    "gitlab_ssh_config|GitLab SSH Config|gitlab_server|gitlab|optional"
    "gitlab_composer|GitLab Composer Registry|gitlab_server|gitlab|optional"

    # AI Assistant Security
    "claude_config|Claude Code Security Config|-|security|recommended"
)

# Priority colors
PRIORITY_REQUIRED="${RED}"      # Red = Required for NWP to work
PRIORITY_RECOMMENDED="${YELLOW}" # Yellow = Recommended for full experience
PRIORITY_OPTIONAL="${CYAN}"      # Cyan = Optional extra features

# Manual input storage (collected once, used by multiple components)
declare -A MANUAL_INPUTS

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

check_script_symlinks_exist() {
    # Check if symlinks exist in root pointing to scripts/commands/
    local script_dir="$SCRIPT_DIR"
    # If we're in scripts/commands/, go up two levels
    if [[ "$script_dir" == */scripts/commands ]]; then
        script_dir="${script_dir%/scripts/commands}"
    fi
    # Check for at least one symlink
    [ -L "$script_dir/install.sh" ] && [ -L "$script_dir/backup.sh" ]
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

check_nwp_secrets_exist() {
    [ -f "$SCRIPT_DIR/.secrets.yml" ]
}

check_linode_config_exists() {
    # Check if linode-cli is configured with a token
    if ! command -v linode-cli &> /dev/null; then
        return 1
    fi
    # Check if config file exists first (avoid API call hanging)
    if [ ! -f "$HOME/.config/linode-cli" ]; then
        return 1
    fi
    # Verify token works with timeout (use linodes list - works with limited scopes)
    timeout 5 linode-cli linodes list --text --no-headers &> /dev/null
    return $?
}

check_gitlab_keys_exist() {
    [ -f "$SCRIPT_DIR/git/keys/gitlab_linode" ]
}

check_bats_installed() {
    command -v bats &> /dev/null
}

check_gitlab_server_exists() {
    # Check if GitLab server is registered in cnwp.yml or .secrets.yml
    if [ -f "$SCRIPT_DIR/.secrets.yml" ]; then
        grep -q "^gitlab:" "$SCRIPT_DIR/.secrets.yml" 2>/dev/null && \
        grep -q "linode_id:" "$SCRIPT_DIR/.secrets.yml" 2>/dev/null
        return $?
    fi
    return 1
}

check_gitlab_dns_exists() {
    # Check if GitLab DNS is configured
    if ! check_linode_config_exists; then
        return 1
    fi
    local base_url=$(get_base_url_from_config 2>/dev/null)
    [ -z "$base_url" ] && return 1

    # Check if domain exists in Linode DNS (with timeout)
    timeout 5 linode-cli domains list --text --no-headers 2>/dev/null | grep -q "$base_url"
}

check_gitlab_ssh_config_exists() {
    # Check if git-server SSH config exists
    [ -f "$HOME/.ssh/config" ] && grep -q "Host git-server" "$HOME/.ssh/config" 2>/dev/null
}

check_claude_config_exists() {
    # Check if Claude Code security config exists with deny rules
    [ -f "$HOME/.claude/settings.json" ] && grep -q '"deny"' "$HOME/.claude/settings.json" 2>/dev/null
}

check_gitlab_composer_exists() {
    # Check if GitLab Composer Registry is set up with at least one package
    if [ ! -f "$SCRIPT_DIR/.secrets.yml" ]; then
        return 1
    fi
    # Check if we can access the GitLab API and package registry
    source "$SCRIPT_DIR/lib/git.sh" 2>/dev/null || return 1
    local gitlab_url=$(get_gitlab_url 2>/dev/null)
    local token=$(get_gitlab_token 2>/dev/null)
    [ -z "$gitlab_url" ] && return 1
    [ -z "$token" ] && return 1
    # Check if package registry is accessible (timeout to avoid hanging)
    timeout 5 curl -s --header "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/packages" &>/dev/null
}

# Get base URL from cnwp.yml
get_base_url_from_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi
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

# Main detection function
detect_component_state() {
    local component_id="$1"

    case "$component_id" in
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

install_script_symlinks() {
    print_header "Creating Script Symlinks"
    log_action "Creating script symlinks for backward compatibility"

    # Determine root directory
    local root_dir="$SCRIPT_DIR"
    if [[ "$root_dir" == */scripts/commands ]]; then
        root_dir="${root_dir%/scripts/commands}"
    fi

    local commands_dir="$root_dir/scripts/commands"

    if [ ! -d "$commands_dir" ]; then
        print_status "FAIL" "scripts/commands/ directory not found"
        return 1
    fi

    local created=0
    local skipped=0

    # List of scripts to symlink
    local scripts=(
        backup.sh coder-setup.sh copy.sh delete.sh dev2stg.sh
        import.sh install.sh live.sh live2prod.sh live2stg.sh
        make.sh migrate-secrets.sh migration.sh modify.sh
        podcast.sh prod2stg.sh produce.sh report.sh restore.sh
        schedule.sh security.sh setup.sh setup-ssh.sh status.sh
        stg2live.sh stg2prod.sh sync.sh test-nwp.sh test.sh
        testos.sh uninstall_nwp.sh verify.sh
    )

    for script in "${scripts[@]}"; do
        local target="$root_dir/$script"
        local source="scripts/commands/$script"

        if [ -L "$target" ]; then
            # Already a symlink
            skipped=$((skipped + 1))
        elif [ -f "$target" ]; then
            # Regular file exists - skip to avoid overwriting
            print_status "WARN" "Skipping $script (regular file exists)"
            skipped=$((skipped + 1))
        elif [ -f "$commands_dir/$script" ]; then
            # Create symlink
            ln -s "$source" "$target"
            created=$((created + 1))
        fi
    done

    print_status "OK" "Created $created symlinks ($skipped already existed)"
    echo ""
    echo "Scripts accessible via:"
    echo "  ./install.sh, ./backup.sh, ./status.sh, etc."
    echo ""
    echo "To use scripts without symlinks, use:"
    echo "  ./scripts/commands/install.sh"
    echo "  or: pl install (NWP CLI)"

    log_action "Script symlinks created: $created new, $skipped existing"
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

install_nwp_secrets() {
    print_header "Creating NWP Secrets File"
    log_action "Creating .secrets.yml"

    local secrets_file="$SCRIPT_DIR/.secrets.yml"

    if [ -f "$secrets_file" ]; then
        print_status "OK" ".secrets.yml already exists"
        return 0
    fi

    cat > "$secrets_file" << 'EOF'
# NWP Infrastructure Secrets Configuration
# NEVER commit this file to version control!

# Linode API Configuration
# Get your API token from: https://cloud.linode.com/profile/tokens
# Create a Personal Access Token with Read/Write permissions for:
# - Linodes, StackScripts, Domains
linode:
  api_token: ""

# GitLab Server (auto-populated by setup)
# gitlab:
#   server:
#     domain: git.yourdomain.org
#     ip: 0.0.0.0
#     linode_id: 0
#     ssh_user: gitlab
#     ssh_key: git/keys/gitlab_linode
#   admin:
#     url: https://git.yourdomain.org
#     username: root
#     initial_password: ""
#     password: ""
EOF

    chmod 600 "$secrets_file"
    print_status "OK" ".secrets.yml created"
    print_status "INFO" "Add your Linode API token to .secrets.yml for server provisioning"
    log_action ".secrets.yml created"
}

install_linode_config() {
    print_header "Configuring Linode CLI"
    log_action "Configuring Linode CLI"

    # Check if already configured
    if check_linode_config_exists; then
        print_status "OK" "Linode CLI already configured"
        return 0
    fi

    # Try to get token from .secrets.yml
    local token=""
    if [ -f "$SCRIPT_DIR/.secrets.yml" ]; then
        token=$(grep "api_token:" "$SCRIPT_DIR/.secrets.yml" 2>/dev/null | head -1 | awk -F'"' '{print $2}')
    fi

    # Also check MANUAL_INPUTS
    [ -z "$token" ] && token="${MANUAL_INPUTS[linode_token]:-}"

    if [ -z "$token" ] || [ "$token" == "" ]; then
        print_status "WARN" "No Linode API token found"
        echo ""
        echo "To configure Linode CLI, you need an API token."
        echo "Get one from: https://cloud.linode.com/profile/tokens"
        echo ""

        read -p "Enter your Linode API token (or press Enter to skip): " token
        if [ -z "$token" ]; then
            print_status "INFO" "Skipping Linode CLI configuration"
            return 1
        fi

        # Save token to .secrets.yml
        if [ -f "$SCRIPT_DIR/.secrets.yml" ]; then
            sed -i "s/api_token: \"\"/api_token: \"$token\"/" "$SCRIPT_DIR/.secrets.yml"
            print_status "OK" "Token saved to .secrets.yml"
        fi
        MANUAL_INPUTS[linode_token]="$token"
    fi

    # Configure linode-cli non-interactively
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

    # Verify configuration (with timeout to avoid hanging)
    # Use 'linodes list' instead of 'account view' - works with more limited token scopes
    if timeout 10 linode-cli linodes list --text --no-headers &> /dev/null; then
        print_status "OK" "Linode CLI configured successfully"
        log_action "Linode CLI configured"
    else
        print_status "FAIL" "Failed to configure Linode CLI - check your token"
        return 1
    fi
}

install_gitlab_keys() {
    print_header "Generating GitLab SSH Keys"
    log_action "Generating GitLab SSH keys"

    local keys_dir="$SCRIPT_DIR/git/keys"
    local key_file="$keys_dir/gitlab_linode"

    mkdir -p "$keys_dir"

    if [ -f "$key_file" ]; then
        print_status "OK" "GitLab SSH keys already exist"
        return 0
    fi

    # Get email from config or use default
    local base_url=$(get_base_url_from_config 2>/dev/null)
    local email="gitlab@${base_url:-localhost}"

    print_status "INFO" "Generating SSH keys for GitLab..."
    ssh-keygen -t ed25519 -f "$key_file" -N "" -C "$email"

    print_status "OK" "GitLab SSH keys generated: $key_file"
    log_action "GitLab SSH keys generated"
}

install_gitlab_server() {
    print_header "Provisioning GitLab Server"
    log_action "Provisioning GitLab server"

    if ! check_linode_config_exists; then
        print_status "FAIL" "Linode CLI not configured"
        return 1
    fi

    local base_url=$(get_base_url_from_config 2>/dev/null)
    if [ -z "$base_url" ]; then
        print_status "FAIL" "No URL configured in cnwp.yml settings.url"
        echo ""
        echo "Please add your domain to cnwp.yml:"
        echo "  settings:"
        echo "    url: yourdomain.org"
        return 1
    fi

    local gitlab_domain="git.$base_url"

    # Check if server already exists
    if check_gitlab_server_exists; then
        print_status "OK" "GitLab server already provisioned"
        return 0
    fi

    print_status "INFO" "Setting up GitLab at $gitlab_domain"

    # Use the setup_gitlab_site.sh script if available
    if [ -x "$SCRIPT_DIR/git/setup_gitlab_site.sh" ]; then
        print_status "INFO" "Running GitLab setup script..."
        if "$SCRIPT_DIR/git/setup_gitlab_site.sh" -y; then
            print_status "OK" "GitLab server provisioned"
            log_action "GitLab server provisioned"
        else
            print_status "FAIL" "GitLab setup failed"
            return 1
        fi
    else
        print_status "FAIL" "git/setup_gitlab_site.sh not found"
        return 1
    fi
}

install_gitlab_dns() {
    print_header "Configuring GitLab DNS"
    log_action "Configuring GitLab DNS"

    if ! check_linode_config_exists; then
        print_status "FAIL" "Linode CLI not configured"
        return 1
    fi

    local base_url=$(get_base_url_from_config 2>/dev/null)
    if [ -z "$base_url" ]; then
        print_status "FAIL" "No URL configured in cnwp.yml"
        return 1
    fi

    # Check if domain exists
    local domain_id=$(linode-cli domains list --text --no-headers 2>/dev/null | grep "$base_url" | awk '{print $1}')

    if [ -z "$domain_id" ]; then
        print_status "INFO" "Creating domain $base_url in Linode DNS..."
        local admin_email="admin@$base_url"
        domain_id=$(linode-cli domains create --domain "$base_url" --type master --soa_email "$admin_email" --text --no-headers 2>/dev/null | awk '{print $1}')

        if [ -z "$domain_id" ]; then
            print_status "FAIL" "Failed to create domain"
            return 1
        fi
        print_status "OK" "Domain created: $base_url (ID: $domain_id)"
    else
        print_status "OK" "Domain already exists: $base_url (ID: $domain_id)"
    fi

    # Get GitLab server IP from .secrets.yml
    local server_ip=""
    if [ -f "$SCRIPT_DIR/.secrets.yml" ]; then
        server_ip=$(grep "ip:" "$SCRIPT_DIR/.secrets.yml" 2>/dev/null | head -1 | awk '{print $2}')
    fi

    if [ -z "$server_ip" ]; then
        print_status "WARN" "GitLab server IP not found in .secrets.yml"
        print_status "INFO" "DNS record will need to be created manually"
        return 0
    fi

    # Check if git record exists
    local existing_record=$(linode-cli domains records-list "$domain_id" --text --no-headers 2>/dev/null | grep "^git[[:space:]]")

    if [ -n "$existing_record" ]; then
        print_status "OK" "DNS record for git.$base_url already exists"
    else
        print_status "INFO" "Creating A record: git.$base_url -> $server_ip"
        if linode-cli domains records-create "$domain_id" --type A --name git --target "$server_ip" --text --no-headers; then
            print_status "OK" "DNS record created"
        else
            print_status "FAIL" "Failed to create DNS record"
            return 1
        fi
    fi

    log_action "GitLab DNS configured"

    # Reminder about nameservers
    echo ""
    print_status "INFO" "Remember to update nameservers at your domain registrar:"
    echo "    ns1.linode.com, ns2.linode.com, ns3.linode.com, ns4.linode.com, ns5.linode.com"
}

install_gitlab_ssh_config() {
    print_header "Configuring GitLab SSH Access"
    log_action "Configuring GitLab SSH"

    # Get GitLab server IP from .secrets.yml
    local server_ip=""
    local gitlab_domain=""

    if [ -f "$SCRIPT_DIR/.secrets.yml" ]; then
        server_ip=$(grep "ip:" "$SCRIPT_DIR/.secrets.yml" 2>/dev/null | head -1 | awk '{print $2}')
        gitlab_domain=$(grep "domain:" "$SCRIPT_DIR/.secrets.yml" 2>/dev/null | head -1 | awk '{print $2}')
    fi

    if [ -z "$server_ip" ]; then
        print_status "FAIL" "GitLab server IP not found"
        return 1
    fi

    # Copy key to ~/.ssh/
    local src_key="$SCRIPT_DIR/git/keys/gitlab_linode"
    local dest_key="$HOME/.ssh/gitlab_linode"

    if [ -f "$src_key" ]; then
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"

        cp "$src_key" "$dest_key"
        cp "${src_key}.pub" "${dest_key}.pub"
        chmod 600 "$dest_key"
        chmod 644 "${dest_key}.pub"
        print_status "OK" "SSH key copied to ~/.ssh/gitlab_linode"
    fi

    # Add SSH config entry
    local ssh_config="$HOME/.ssh/config"
    if ! grep -q "Host git-server" "$ssh_config" 2>/dev/null; then
        cat >> "$ssh_config" << SSHCONFIG

# GitLab Server ($gitlab_domain)
Host git-server gitlab $gitlab_domain
    HostName $server_ip
    User gitlab
    IdentityFile ~/.ssh/gitlab_linode
    IdentitiesOnly yes
    StrictHostKeyChecking no
SSHCONFIG
        chmod 600 "$ssh_config"
        print_status "OK" "SSH config entry added"
    else
        # Update IP if needed
        if ! grep -q "$server_ip" "$ssh_config" 2>/dev/null; then
            sed -i "/Host git-server/,/^Host /{ s/HostName .*/HostName $server_ip/; }" "$ssh_config"
            print_status "OK" "SSH config updated with new IP"
        else
            print_status "OK" "SSH config already configured"
        fi
    fi

    print_status "INFO" "You can now connect with: ssh git-server"
    log_action "GitLab SSH config created"
}

install_gitlab_composer() {
    print_header "Setting up GitLab Composer Registry"
    log_action "Setting up GitLab Composer Registry"

    # Source git library for Composer functions
    if [ -f "$SCRIPT_DIR/lib/git.sh" ]; then
        source "$SCRIPT_DIR/lib/git.sh"
    else
        print_status "FAIL" "lib/git.sh not found"
        return 1
    fi

    # Check GitLab is accessible
    if ! gitlab_composer_check; then
        return 1
    fi

    echo ""
    echo "GitLab Composer Package Registry allows you to host private Composer"
    echo "packages (Drupal profiles, modules, themes) on your GitLab server."
    echo ""
    echo "This enables:"
    echo "  - Installing private packages with: composer require vendor/package"
    echo "  - Proper dependency management for custom code"
    echo "  - Version control and caching via Composer"
    echo ""

    # Show instructions
    print_header "How to Use GitLab Composer Registry"

    echo "1. PUBLISH A PACKAGE"
    echo ""
    echo "   First, ensure your package has a valid composer.json with:"
    echo '     {"name": "nwp/avc", "type": "drupal-profile", ...}'
    echo ""
    echo "   Then create a git tag and publish:"
    echo ""
    echo "     cd /path/to/your/package"
    echo "     git tag v1.0.0"
    echo "     git push origin v1.0.0"
    echo ""
    echo "   Publish to registry (from NWP directory):"
    echo ""
    echo "     source lib/git.sh"
    echo "     gitlab_composer_publish \"/path/to/package\" \"v1.0.0\" \"root/project\""
    echo ""

    echo "2. CONFIGURE A PROJECT TO USE THE REGISTRY"
    echo ""
    echo "   Add to your project's composer.json:"
    echo ""

    local gitlab_url=$(get_gitlab_url)
    local group_id=$(gitlab_get_group_id "root" 2>/dev/null)
    if [ -n "$group_id" ]; then
        echo "     \"repositories\": {"
        echo "       \"gitlab\": {"
        echo "         \"type\": \"composer\","
        echo "         \"url\": \"https://${gitlab_url}/api/v4/group/${group_id}/-/packages/composer/packages.json\""
        echo "       }"
        echo "     }"
    else
        echo "     \"repositories\": {"
        echo "       \"gitlab\": {"
        echo "         \"type\": \"composer\","
        echo "         \"url\": \"https://${gitlab_url}/api/v4/group/<GROUP_ID>/-/packages/composer/packages.json\""
        echo "       }"
        echo "     }"
    fi
    echo ""

    echo "3. INSTALL A PACKAGE"
    echo ""
    echo "   composer require nwp/avc:^0.2"
    echo ""

    echo "4. AUTOMATED PUBLISHING (CI/CD)"
    echo ""
    echo "   Add to .gitlab-ci.yml:"
    echo ""
    echo "     publish:"
    echo "       stage: deploy"
    echo "       script:"
    echo "         - 'curl --header \"Job-Token: \$CI_JOB_TOKEN\" --data tag=\$CI_COMMIT_TAG \"\${CI_API_V4_URL}/projects/\$CI_PROJECT_ID/packages/composer\"'"
    echo "       only:"
    echo "         - tags"
    echo ""

    print_status "OK" "GitLab Composer Registry setup complete"
    echo ""
    echo "Available functions (source lib/git.sh first):"
    echo "  gitlab_composer_publish       - Publish a package"
    echo "  gitlab_composer_list          - List published packages"
    echo "  gitlab_composer_configure_client - Configure a project"
    echo "  gitlab_composer_create_deploy_token - Create access token"
    echo ""
    echo "Documentation: docs/GITLAB_COMPOSER.md"

    log_action "GitLab Composer Registry setup complete"
}

install_bats() {
    print_header "Installing BATS Testing Framework"
    log_action "Installing BATS"

    # Check if available via apt
    if command -v apt-get &> /dev/null; then
        echo "Installing BATS via apt..."
        sudo apt-get update
        sudo apt-get install -y bats
    elif command -v brew &> /dev/null; then
        echo "Installing BATS via Homebrew..."
        brew install bats-core
    else
        echo "Installing BATS from source..."
        local bats_version="1.10.0"
        cd /tmp
        curl -sSL "https://github.com/bats-core/bats-core/archive/refs/tags/v${bats_version}.tar.gz" -o bats.tar.gz
        tar -xzf bats.tar.gz
        cd "bats-core-${bats_version}"
        sudo ./install.sh /usr/local
        cd - > /dev/null
        rm -rf /tmp/bats.tar.gz /tmp/bats-core-*
    fi

    if check_bats_installed; then
        print_status "OK" "BATS installed: $(bats --version)"
        log_action "BATS installed"
    else
        print_status "FAIL" "BATS installation failed"
        log_action "BATS installation failed"
        return 1
    fi
}

install_claude_config() {
    print_header "Configuring Claude Code Security"
    log_action "Installing Claude Code security config"

    local claude_dir="$HOME/.claude"
    local settings_file="$claude_dir/settings.json"

    # Create .claude directory if it doesn't exist
    if [ ! -d "$claude_dir" ]; then
        mkdir -p "$claude_dir"
        print_status "OK" "Created $claude_dir directory"
    fi

    # Two-tier secrets architecture:
    # - .secrets.yml = infrastructure secrets (ALLOWED - API tokens for provisioning)
    # - .secrets.data.yml = data secrets (BLOCKED - production DB, SSH, etc.)
    #
    # See docs/DATA_SECURITY_BEST_PRACTICES.md for full documentation.

    # Define the security deny rules (data secrets only)
    local deny_rules='[
      "**/.secrets.data.yml",
      "**/.secrets.prod.yml",
      "**/keys/prod_*",
      "**/keys/*_prod",
      "**/keys/*_production",
      "~/.ssh/*",
      "**/*.sql",
      "**/*.sql.gz",
      "**/settings.php",
      "**/settings.local.php",
      "**/.env.production",
      "**/.credentials.json",
      "**/id_rsa",
      "**/id_ed25519",
      "**/*.pem",
      "**/*.key"
    ]'

    if [ -f "$settings_file" ]; then
        # Check if deny rules already exist
        if grep -q '"deny"' "$settings_file" 2>/dev/null; then
            # Check if using old rules (blocking .secrets.yml)
            if grep -q '"\*\*/\.secrets\.yml"' "$settings_file" 2>/dev/null; then
                print_status "WARN" "Old deny rules detected - updating to two-tier architecture"
                # Update to new rules
                local temp_file=$(mktemp)
                jq --argjson deny "$deny_rules" '.permissions.deny = $deny' "$settings_file" > "$temp_file" 2>/dev/null
                if [ $? -eq 0 ]; then
                    mv "$temp_file" "$settings_file"
                    print_status "OK" "Updated to two-tier secrets architecture"
                else
                    rm -f "$temp_file"
                    print_status "WARN" "Could not update - please update deny rules manually"
                fi
            else
                print_status "OK" "Claude security config already configured"
            fi
        else
            # Merge deny rules into existing settings
            local temp_file=$(mktemp)
            jq --argjson deny "$deny_rules" '. + {permissions: {deny: $deny}}' "$settings_file" > "$temp_file" 2>/dev/null
            if [ $? -eq 0 ]; then
                mv "$temp_file" "$settings_file"
                print_status "OK" "Added security deny rules to existing config"
            else
                rm -f "$temp_file"
                print_status "WARN" "Could not update settings.json - please add deny rules manually"
            fi
        fi
    else
        # Create new settings file with deny rules
        cat > "$settings_file" << 'CLAUDE_EOF'
{
  "permissions": {
    "deny": [
      "**/.secrets.data.yml",
      "**/.secrets.prod.yml",
      "**/keys/prod_*",
      "**/keys/*_prod",
      "**/keys/*_production",
      "~/.ssh/*",
      "**/*.sql",
      "**/*.sql.gz",
      "**/settings.php",
      "**/settings.local.php",
      "**/.env.production",
      "**/.credentials.json",
      "**/id_rsa",
      "**/id_ed25519",
      "**/*.pem",
      "**/*.key"
    ]
  }
}
CLAUDE_EOF
        chmod 600 "$settings_file"
        print_status "OK" "Created Claude security config at $settings_file"
    fi

    echo ""
    echo "Two-Tier Secrets Architecture:"
    echo ""
    echo "  ALLOWED (infrastructure secrets):"
    echo "    .secrets.yml     - API tokens for provisioning"
    echo "    .env, .env.local - Development environment"
    echo ""
    echo "  BLOCKED (data secrets):"
    echo "    .secrets.data.yml - Production DB, SSH, SMTP"
    echo "    keys/prod_*       - Production SSH keys"
    echo "    *.sql, *.sql.gz   - Database dumps"
    echo "    settings.php      - Drupal credentials"
    echo ""
    echo "Run: ./migrate-secrets.sh --check  to verify your secrets"
    echo "See: docs/DATA_SECURITY_BEST_PRACTICES.md for full documentation"

    log_action "Claude Code security config installed (two-tier architecture)"
}

# Main install dispatcher
install_component() {
    local component_id="$1"

    case "$component_id" in
        docker)           install_docker ;;
        docker_compose)   print_status "OK" "Docker Compose included with Docker" ;;
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
        *)                print_status "WARN" "Unknown component: $component_id" ;;
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

remove_script_symlinks() {
    print_header "Removing Script Symlinks"
    log_action "Removing script symlinks"

    # Determine root directory
    local root_dir="$SCRIPT_DIR"
    if [[ "$root_dir" == */scripts/commands ]]; then
        root_dir="${root_dir%/scripts/commands}"
    fi

    local removed=0

    # List of scripts that might have symlinks
    local scripts=(
        backup.sh coder-setup.sh copy.sh delete.sh dev2stg.sh
        import.sh install.sh live.sh live2prod.sh live2stg.sh
        make.sh migrate-secrets.sh migration.sh modify.sh
        podcast.sh prod2stg.sh produce.sh report.sh restore.sh
        schedule.sh security.sh setup.sh setup-ssh.sh status.sh
        stg2live.sh stg2prod.sh sync.sh test-nwp.sh test.sh
        testos.sh uninstall_nwp.sh verify.sh
    )

    for script in "${scripts[@]}"; do
        local target="$root_dir/$script"
        if [ -L "$target" ]; then
            rm -f "$target"
            removed=$((removed + 1))
        fi
    done

    print_status "OK" "Removed $removed symlinks"
    echo ""
    echo "Scripts now accessible via:"
    echo "  ./scripts/commands/install.sh"
    echo "  or: pl install (NWP CLI)"

    log_action "Script symlinks removed: $removed"
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

remove_nwp_secrets() {
    print_header "Removing NWP Secrets File"
    log_action "Removing .secrets.yml"

    if [ "${COMPONENT_ORIGINAL[nwp_secrets]:-0}" -eq 1 ]; then
        print_status "WARN" ".secrets.yml existed before NWP - keeping it"
        return 0
    fi

    if [ -f "$SCRIPT_DIR/.secrets.yml" ]; then
        # Backup before removing
        cp "$SCRIPT_DIR/.secrets.yml" "$STATE_DIR/secrets.yml.backup.$(date +%Y%m%d%H%M%S)"
        rm -f "$SCRIPT_DIR/.secrets.yml"
        print_status "OK" ".secrets.yml removed (backup saved)"
    fi

    log_action ".secrets.yml removed"
}

remove_linode_config() {
    print_header "Removing Linode CLI Configuration"
    log_action "Removing Linode config"

    if [ "${COMPONENT_ORIGINAL[linode_config]:-0}" -eq 1 ]; then
        print_status "WARN" "Linode CLI was configured before NWP - keeping config"
        return 0
    fi

    if [ -f "$HOME/.config/linode-cli" ]; then
        rm -f "$HOME/.config/linode-cli"
        print_status "OK" "Linode CLI configuration removed"
    fi

    log_action "Linode config removed"
}

remove_gitlab_keys() {
    print_header "Removing GitLab SSH Keys"
    log_action "Removing GitLab SSH keys"

    if [ "${COMPONENT_ORIGINAL[gitlab_keys]:-0}" -eq 1 ]; then
        print_status "WARN" "GitLab keys existed before NWP - keeping them"
        return 0
    fi

    if [ -f "$SCRIPT_DIR/git/keys/gitlab_linode" ]; then
        rm -f "$SCRIPT_DIR/git/keys/gitlab_linode" "$SCRIPT_DIR/git/keys/gitlab_linode.pub"
        print_status "OK" "GitLab SSH keys removed"
    fi

    log_action "GitLab SSH keys removed"
}

remove_gitlab_server() {
    print_header "Removing GitLab Server"
    log_action "Removing GitLab server"

    # WARNING: This is destructive - deletes the actual server
    if [ "${COMPONENT_ORIGINAL[gitlab_server]:-0}" -eq 1 ]; then
        print_status "WARN" "GitLab server existed before NWP - keeping it"
        return 0
    fi

    if ! check_linode_config_exists; then
        print_status "INFO" "Linode CLI not configured - cannot remove server"
        return 0
    fi

    # Get Linode ID from .secrets.yml
    local linode_id=""
    if [ -f "$SCRIPT_DIR/.secrets.yml" ]; then
        linode_id=$(grep "linode_id:" "$SCRIPT_DIR/.secrets.yml" 2>/dev/null | head -1 | awk '{print $2}')
    fi

    if [ -z "$linode_id" ] || [ "$linode_id" == "0" ]; then
        print_status "INFO" "No GitLab server to remove"
        return 0
    fi

    echo ""
    print_status "WARN" "This will DELETE the GitLab server (Linode ID: $linode_id)"
    print_status "WARN" "All data on the server will be PERMANENTLY LOST"
    echo ""

    if ! ask_yes_no "Are you SURE you want to delete the GitLab server?" "n"; then
        print_status "INFO" "Server deletion cancelled"
        return 0
    fi

    print_status "INFO" "Deleting GitLab server..."
    if linode-cli linodes delete "$linode_id" 2>/dev/null; then
        print_status "OK" "GitLab server deleted"

        # Remove from .secrets.yml
        if [ -f "$SCRIPT_DIR/.secrets.yml" ]; then
            # Create backup
            cp "$SCRIPT_DIR/.secrets.yml" "$STATE_DIR/secrets.yml.backup.$(date +%Y%m%d%H%M%S)"
            # Remove gitlab section
            sed -i '/^gitlab:/,/^[a-z]/{ /^gitlab:/d; /^  /d; }' "$SCRIPT_DIR/.secrets.yml"
            print_status "OK" "GitLab entry removed from .secrets.yml"
        fi
    else
        print_status "FAIL" "Failed to delete GitLab server"
        return 1
    fi

    log_action "GitLab server deleted"
}

remove_gitlab_dns() {
    print_header "Removing GitLab DNS Record"
    log_action "Removing GitLab DNS"

    if [ "${COMPONENT_ORIGINAL[gitlab_dns]:-0}" -eq 1 ]; then
        print_status "WARN" "GitLab DNS existed before NWP - keeping it"
        return 0
    fi

    if ! check_linode_config_exists; then
        print_status "INFO" "Linode CLI not configured - cannot remove DNS"
        return 0
    fi

    local base_url=$(get_base_url_from_config 2>/dev/null)
    if [ -z "$base_url" ]; then
        print_status "INFO" "No URL configured - nothing to remove"
        return 0
    fi

    local domain_id=$(linode-cli domains list --text --no-headers 2>/dev/null | grep "$base_url" | awk '{print $1}')
    if [ -z "$domain_id" ]; then
        print_status "INFO" "Domain not in Linode DNS"
        return 0
    fi

    # Find and remove git record
    local record_id=$(linode-cli domains records-list "$domain_id" --text --no-headers 2>/dev/null | grep "^git[[:space:]]" | awk '{print $1}')
    if [ -n "$record_id" ]; then
        linode-cli domains records-delete "$domain_id" "$record_id" 2>/dev/null
        print_status "OK" "DNS record for git.$base_url removed"
    else
        print_status "INFO" "No git DNS record found"
    fi

    log_action "GitLab DNS removed"
}

remove_gitlab_ssh_config() {
    print_header "Removing GitLab SSH Config"
    log_action "Removing GitLab SSH config"

    if [ "${COMPONENT_ORIGINAL[gitlab_ssh_config]:-0}" -eq 1 ]; then
        print_status "WARN" "GitLab SSH config existed before NWP - keeping it"
        return 0
    fi

    # Remove from ~/.ssh/config
    local ssh_config="$HOME/.ssh/config"
    if [ -f "$ssh_config" ] && grep -q "Host git-server" "$ssh_config"; then
        # Backup
        cp "$ssh_config" "$ssh_config.backup.$(date +%Y%m%d%H%M%S)"
        # Remove git-server block
        sed -i '/# GitLab Server/,/^$/d' "$ssh_config"
        sed -i '/Host git-server/,/^Host\|^$/{ /Host git-server/d; /^[[:space:]]/d; }' "$ssh_config"
        print_status "OK" "SSH config entry removed"
    fi

    # Remove key from ~/.ssh/
    if [ -f "$HOME/.ssh/gitlab_linode" ]; then
        rm -f "$HOME/.ssh/gitlab_linode" "$HOME/.ssh/gitlab_linode.pub"
        print_status "OK" "GitLab key removed from ~/.ssh/"
    fi

    log_action "GitLab SSH config removed"
}

remove_gitlab_composer() {
    print_header "Removing GitLab Composer Registry Setup"
    log_action "Removing GitLab Composer setup"

    # The Composer registry is a GitLab feature - we don't actually remove it
    # We just mark it as "not configured" locally

    print_status "INFO" "GitLab Composer Registry is a GitLab feature"
    print_status "INFO" "To remove packages, use the GitLab web UI:"
    echo ""
    echo "  1. Go to your GitLab project"
    echo "  2. Navigate to Deploy > Package Registry"
    echo "  3. Delete unwanted packages"
    echo ""

    log_action "GitLab Composer info displayed"
}

# Main remove dispatcher
remove_component() {
    local component_id="$1"

    case "$component_id" in
        docker)           remove_docker ;;
        docker_compose)   print_status "OK" "Docker Compose removed with Docker" ;;
        docker_group)     remove_docker_group ;;
        mkcert)           remove_mkcert ;;
        mkcert_ca)        remove_mkcert_ca ;;
        ddev)             remove_ddev ;;
        ddev_config)      remove_ddev_config ;;
        script_symlinks)  remove_script_symlinks ;;
        nwp_cli)          remove_nwp_cli ;;
        nwp_config)       remove_nwp_config ;;
        nwp_secrets)      remove_nwp_secrets ;;
        linode_cli)       remove_linode_cli ;;
        linode_config)    remove_linode_config ;;
        ssh_keys)         remove_ssh_keys ;;
        gitlab_keys)      remove_gitlab_keys ;;
        gitlab_server)    remove_gitlab_server ;;
        gitlab_dns)       remove_gitlab_dns ;;
        gitlab_ssh_config) remove_gitlab_ssh_config ;;
        gitlab_composer)  remove_gitlab_composer ;;
        *)                print_status "WARN" "Unknown component: $component_id" ;;
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
        local priority=$(echo "$comp" | cut -d'|' -f5)

        # Add priority indicator and indentation
        local priority_marker=""
        case "$priority" in
            required)    priority_marker="[REQ]" ;;
            recommended) priority_marker="[REC]" ;;
            optional)    priority_marker="[OPT]" ;;
        esac

        local display_name="$priority_marker $name"
        if [ "$parent" != "-" ]; then
            display_name="  └─ $priority_marker $name"
        fi

        # Default selection based on current state and priority
        local state="off"
        if [ "${COMPONENT_INSTALLED[$id]:-0}" -eq 1 ]; then
            state="on"
        elif [ "$priority" == "required" ]; then
            # Required components default to on
            state="on"
        fi

        items+=("$id" "$display_name" "$state")
    done

    # Show dialog
    local result
    result=$($dialog_cmd --title "NWP Setup Manager" \
        --backtitle "Select components to install/keep (Space to toggle, Enter to confirm)" \
        --checklist "Use SPACE to select/deselect components.\nComponents with └─ depend on their parent.\n\n[REQ]=Required  [REC]=Recommended  [OPT]=Optional" \
        25 75 15 \
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

    echo -e "Legend: ${RED}[REQ]${NC} Required  ${YELLOW}[REC]${NC} Recommended  ${CYAN}[OPT]${NC} Optional"
    echo ""
    echo "Current installation state:"
    echo ""

    local num=1
    declare -A NUM_TO_ID

    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        local name=$(echo "$comp" | cut -d'|' -f2)
        local parent=$(echo "$comp" | cut -d'|' -f3)
        local category=$(echo "$comp" | cut -d'|' -f4)
        local priority=$(echo "$comp" | cut -d'|' -f5)

        local indent=""
        if [ "$parent" != "-" ]; then
            indent="    "
        fi

        # Get priority color and marker
        local priority_color=""
        local priority_marker=""
        case "$priority" in
            required)    priority_color="${RED}"; priority_marker="[REQ]" ;;
            recommended) priority_color="${YELLOW}"; priority_marker="[REC]" ;;
            optional)    priority_color="${CYAN}"; priority_marker="[OPT]" ;;
        esac

        local status_icon="[ ]"
        if [ "${COMPONENT_INSTALLED[$id]:-0}" -eq 1 ]; then
            status_icon="[*]"
            COMPONENT_SELECTED[$id]=1
        elif [ "$priority" == "required" ]; then
            # Pre-select required components
            COMPONENT_SELECTED[$id]=1
        else
            COMPONENT_SELECTED[$id]=0
        fi

        printf "%s%2d) %s ${priority_color}%s${NC} %s\n" "$indent" "$num" "$status_icon" "$priority_marker" "$name"
        NUM_TO_ID[$num]=$id
        ((num++))
    done

    echo ""
    echo "Enter numbers to toggle (space-separated), 'a' for all required+recommended, or 'q' to proceed:"
    read -p "> " selections

    if [ "$selections" == "q" ] || [ -z "$selections" ]; then
        return 0
    fi

    if [ "$selections" == "a" ]; then
        # Select all required and recommended components
        for comp in "${COMPONENTS[@]}"; do
            local id=$(echo "$comp" | cut -d'|' -f1)
            local priority=$(echo "$comp" | cut -d'|' -f5)
            if [ "$priority" == "required" ] || [ "$priority" == "recommended" ]; then
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

    # Show legend
    echo -e "Legend: ${RED}■${NC} Required  ${YELLOW}■${NC} Recommended  ${CYAN}■${NC} Optional"
    echo ""

    local current_category=""

    for comp in "${COMPONENTS[@]}"; do
        local id=$(echo "$comp" | cut -d'|' -f1)
        local name=$(echo "$comp" | cut -d'|' -f2)
        local parent=$(echo "$comp" | cut -d'|' -f3)
        local category=$(echo "$comp" | cut -d'|' -f4)
        local priority=$(echo "$comp" | cut -d'|' -f5)

        # Print category header
        if [ "$category" != "$current_category" ]; then
            current_category="$category"
            echo ""
            case "$category" in
                core)     echo -e "${BOLD}Core Infrastructure:${NC}" ;;
                tools)    echo -e "${BOLD}NWP Tools:${NC}" ;;
                linode)   echo -e "${BOLD}Linode Infrastructure:${NC}" ;;
                gitlab)   echo -e "${BOLD}GitLab Deployment:${NC}" ;;
                optional) echo -e "${BOLD}Optional Components:${NC}" ;;
            esac
        fi

        local indent=""
        if [ "$parent" != "-" ]; then
            indent="  "
        fi

        # Get priority color
        local priority_color=""
        case "$priority" in
            required)    priority_color="${RED}" ;;
            recommended) priority_color="${YELLOW}" ;;
            optional)    priority_color="${CYAN}" ;;
        esac

        local status_icon=""
        local extra=""
        if [ "${COMPONENT_INSTALLED[$id]:-0}" -eq 1 ]; then
            status_icon="${GREEN}✓${NC}"
            if [ "${COMPONENT_ORIGINAL[$id]:-0}" -eq 1 ]; then
                extra=" (pre-existing)"
            fi
        else
            status_icon="${RED}✗${NC}"
        fi

        echo -e "${indent}[${status_icon}] ${priority_color}■${NC} ${name}${extra}"
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
    echo "  --status       Show current installation status"
    echo "  --auto         Auto-install all core components"
    echo "  --symlinks     Create script symlinks for backward compatibility"
    echo "  --no-symlinks  Remove script symlinks (use scripts/commands/ directly)"
    echo "  --help         Show this help message"
    echo ""
    echo "Without options, runs interactive setup."
    echo ""
    echo "Symlink Options:"
    echo "  With symlinks:    ./install.sh, ./backup.sh, etc. (traditional)"
    echo "  Without symlinks: ./scripts/commands/install.sh or 'pl install'"
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
        --symlinks)
            print_header "Enabling Script Symlinks"
            install_script_symlinks
            exit 0
            ;;
        --no-symlinks)
            print_header "Disabling Script Symlinks"
            remove_script_symlinks
            exit 0
            ;;
        --auto)
            save_original_state
            detect_all_current_states
            load_original_state

            # Select all required and recommended components
            for comp in "${COMPONENTS[@]}"; do
                local id=$(echo "$comp" | cut -d'|' -f1)
                local priority=$(echo "$comp" | cut -d'|' -f5)
                if [ "$priority" == "required" ] || [ "$priority" == "recommended" ]; then
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
