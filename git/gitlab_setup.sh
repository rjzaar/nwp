#!/bin/bash

################################################################################
# gitlab_setup.sh - Set up Linode CLI and environment for GitLab
################################################################################
#
# This script prepares your local machine to work with Linode for GitLab by:
#   1. Installing Linode CLI
#   2. Configuring API authentication
#   3. Setting up SSH keys for server access
#   4. Creating necessary configuration files
#
# Usage:
#   ./gitlab_setup.sh [OPTIONS]
#
# Options:
#   -h, --help       Show this help message
#   -v, --verbose    Enable verbose output
#   -y, --yes        Skip confirmation prompts
#
################################################################################

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWP_ROOT="$(dirname "$SCRIPT_DIR")"
GIT_DIR="$SCRIPT_DIR"
KEYS_DIR="$GIT_DIR/keys"
CONFIG_DIR="$HOME/.nwp"
CONFIG_FILE="$CONFIG_DIR/gitlab.yml"

# Parse command line options
VERBOSE=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Helper functions
print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_info() {
    echo -e "${BLUE}${BOLD}INFO:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "${RED}${BOLD}ERROR:${NC} $1"
}

confirm() {
    if [ "$AUTO_YES" = true ]; then
        return 0
    fi

    local prompt="$1"
    local default="${2:-n}"  # Second argument for default (y/n), defaults to 'n'
    local response

    if [ "$default" = "y" ]; then
        read -p "$prompt [Y/n]: " response
        response=${response:-y}
    else
        read -p "$prompt [y/N]: " response
        response=${response:-n}
    fi

    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Main setup functions

check_sudo() {
    print_header "Checking Sudo Access"

    # Check if we have sudo access
    if ! sudo -n true 2>/dev/null; then
        print_info "This script needs sudo access to install missing packages."
        print_info "You may be prompted for your password."
        echo ""

        if sudo true; then
            print_success "Sudo access granted"
        else
            print_error "Unable to obtain sudo access"
            print_info "You can run the script without sudo, but you'll need to manually install prerequisites."
            echo ""
            if ! confirm "Continue without sudo?"; then
                exit 1
            fi
            return 1
        fi
    else
        print_success "Sudo access available"
    fi
    return 0
}

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v brew &> /dev/null; then
        echo "brew"
    else
        echo "unknown"
    fi
}

check_prerequisites() {
    print_header "Checking Prerequisites"

    local MISSING_PACKAGES=()
    local PACKAGE_MANAGER=$(detect_package_manager)
    local HAS_SUDO=false

    # Check for sudo access first
    if check_sudo; then
        HAS_SUDO=true
    fi

    # Check for Python 3
    if ! command -v python3 &> /dev/null; then
        print_warning "Python 3 is not installed"
        case "$PACKAGE_MANAGER" in
            apt)
                MISSING_PACKAGES+=("python3")
                ;;
            dnf|yum)
                MISSING_PACKAGES+=("python3")
                ;;
            brew)
                MISSING_PACKAGES+=("python@3")
                ;;
        esac
    else
        print_success "Python 3 found: $(python3 --version)"
    fi

    # Check for pip3
    if ! command -v pip3 &> /dev/null; then
        print_warning "pip3 is not installed"
        case "$PACKAGE_MANAGER" in
            apt)
                MISSING_PACKAGES+=("python3-pip")
                ;;
            dnf|yum)
                MISSING_PACKAGES+=("python3-pip")
                ;;
            brew)
                # pip comes with python on brew
                ;;
        esac
    else
        print_success "pip3 found"
    fi

    # Check for SSH
    if ! command -v ssh &> /dev/null; then
        print_warning "SSH client is not installed"
        case "$PACKAGE_MANAGER" in
            apt)
                MISSING_PACKAGES+=("openssh-client")
                ;;
            dnf|yum)
                MISSING_PACKAGES+=("openssh-clients")
                ;;
            brew)
                # SSH comes with macOS
                ;;
        esac
    else
        print_success "SSH found"
    fi

    # Check for ssh-keygen specifically
    if ! command -v ssh-keygen &> /dev/null; then
        print_warning "ssh-keygen is not installed"
        if [[ "$PACKAGE_MANAGER" == "apt" ]]; then
            MISSING_PACKAGES+=("openssh-client")
        fi
    fi

    # Check for pipx (recommended for installing Python CLI tools)
    if ! command -v pipx &> /dev/null; then
        print_info "pipx is recommended for installing Python CLI tools (like Linode CLI)"
        case "$PACKAGE_MANAGER" in
            apt)
                MISSING_PACKAGES+=("pipx")
                ;;
            dnf|yum)
                MISSING_PACKAGES+=("pipx")
                ;;
            brew)
                MISSING_PACKAGES+=("pipx")
                ;;
        esac
    fi

    # If we have missing packages, offer to install them
    if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
        echo ""
        print_info "Missing packages detected:"
        for pkg in "${MISSING_PACKAGES[@]}"; do
            echo "  - $pkg"
        done
        echo ""

        if [ "$PACKAGE_MANAGER" == "unknown" ]; then
            print_error "Unable to detect package manager"
            print_info "Please install the missing packages manually and run this script again."
            exit 1
        fi

        if [ "$HAS_SUDO" = false ]; then
            print_error "Sudo access is required to install packages"
            print_info "Please install the missing packages manually:"
            case "$PACKAGE_MANAGER" in
                apt)
                    echo "  sudo apt-get update && sudo apt-get install -y ${MISSING_PACKAGES[*]}"
                    ;;
                dnf)
                    echo "  sudo dnf install -y ${MISSING_PACKAGES[*]}"
                    ;;
                yum)
                    echo "  sudo yum install -y ${MISSING_PACKAGES[*]}"
                    ;;
                brew)
                    echo "  brew install ${MISSING_PACKAGES[*]}"
                    ;;
            esac
            exit 1
        fi

        # Ask to install with Y as default
        local response
        if [ "$AUTO_YES" = true ]; then
            response="y"
        else
            read -p "Install missing packages now? [Y/n]: " response
            response=${response:-y}  # Default to 'y' if empty
        fi

        case "$response" in
            [yY][eE][sS]|[yY])
                print_info "Installing missing packages..."
                case "$PACKAGE_MANAGER" in
                    apt)
                        sudo apt-get update
                        sudo apt-get install -y "${MISSING_PACKAGES[@]}"
                        ;;
                    dnf)
                        sudo dnf install -y "${MISSING_PACKAGES[@]}"
                        ;;
                    yum)
                        sudo yum install -y "${MISSING_PACKAGES[@]}"
                        ;;
                    brew)
                        brew install "${MISSING_PACKAGES[@]}"
                        ;;
                esac
                print_success "Packages installed successfully"

                # Verify installation
                local install_failed=false
                if ! command -v python3 &> /dev/null; then
                    print_error "Python 3 installation failed"
                    install_failed=true
                fi
                if ! command -v pip3 &> /dev/null; then
                    print_error "pip3 installation failed"
                    install_failed=true
                fi
                if ! command -v ssh &> /dev/null; then
                    print_error "SSH installation failed"
                    install_failed=true
                fi

                if [ "$install_failed" = true ]; then
                    print_error "Some packages failed to install. Please install manually."
                    exit 1
                fi
                ;;
            *)
                print_error "Installation cancelled"
                print_info "Please install the missing packages manually and run this script again."
                exit 1
                ;;
        esac
    fi

    print_success "All prerequisites are installed"
}

install_linode_cli() {
    print_header "Installing Linode CLI"

    # Check if already installed
    if command -v linode-cli &> /dev/null; then
        local version=$(linode-cli --version 2>&1)
        print_success "Linode CLI already installed: $version"

        if confirm "Do you want to upgrade to the latest version?" "n"; then
            print_info "Upgrading Linode CLI..."
            if command -v pipx &> /dev/null; then
                pipx upgrade linode-cli || pip3 install --upgrade --user linode-cli 2>/dev/null || pip3 install --upgrade --break-system-packages linode-cli
            else
                pip3 install --upgrade --user linode-cli 2>/dev/null || pip3 install --upgrade --break-system-packages linode-cli
            fi
            print_success "Linode CLI upgraded"
        fi
    else
        # Check for pipx (recommended for modern Python)
        if command -v pipx &> /dev/null; then
            print_info "Installing Linode CLI via pipx (recommended)..."
            pipx install linode-cli
            print_success "Linode CLI installed successfully via pipx"
        else
            # pipx not available - offer to install it
            print_info "Modern Python environments prefer 'pipx' for installing CLI tools."
            print_info "This avoids conflicts with system packages."
            echo ""

            if confirm "Install pipx and use it to install Linode CLI?" "y"; then
                print_info "Installing pipx..."

                # Detect package manager and install pipx
                local pkg_mgr=$(detect_package_manager)
                case "$pkg_mgr" in
                    apt)
                        sudo apt-get update
                        sudo apt-get install -y pipx
                        pipx ensurepath
                        print_success "pipx installed"
                        ;;
                    dnf)
                        sudo dnf install -y pipx
                        pipx ensurepath
                        print_success "pipx installed"
                        ;;
                    yum)
                        sudo yum install -y pipx
                        pipx ensurepath
                        print_success "pipx installed"
                        ;;
                    brew)
                        brew install pipx
                        pipx ensurepath
                        print_success "pipx installed"
                        ;;
                    *)
                        print_warning "Unable to auto-install pipx"
                        print_info "Installing via pip3 instead..."
                        python3 -m pip install --user pipx
                        python3 -m pipx ensurepath
                        ;;
                esac

                # Add pipx to PATH for this session
                export PATH="$HOME/.local/bin:$PATH"

                # Now install linode-cli with pipx
                print_info "Installing Linode CLI via pipx..."
                pipx install linode-cli
                print_success "Linode CLI installed successfully"
            else
                # Fallback to pip3 with various strategies
                print_info "Installing Linode CLI via pip3..."

                # Try different installation methods in order of preference
                if pip3 install --user linode-cli 2>/dev/null; then
                    print_success "Linode CLI installed via pip3 --user"
                elif pip3 install --break-system-packages linode-cli 2>/dev/null; then
                    print_warning "Installed using --break-system-packages (not recommended)"
                    print_success "Linode CLI installed"
                else
                    print_error "Unable to install Linode CLI"
                    print_info "Please try one of these methods manually:"
                    echo "  1. sudo apt-get install pipx && pipx install linode-cli"
                    echo "  2. pip3 install --user linode-cli"
                    echo "  3. python3 -m venv ~/.venv && source ~/.venv/bin/activate && pip install linode-cli"
                    exit 1
                fi
            fi
        fi

        # Check if in PATH
        if ! command -v linode-cli &> /dev/null; then
            print_warning "linode-cli not found in PATH"

            # Add to PATH for this session
            export PATH="$HOME/.local/bin:$PATH"

            # Check again
            if command -v linode-cli &> /dev/null; then
                print_success "linode-cli is now available (for this session)"

                # Check if PATH is already configured in shell config
                local path_configured=false
                if [ -f ~/.bashrc ] && grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc; then
                    path_configured=true
                fi
                if [ -f ~/.bash_profile ] && grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bash_profile; then
                    path_configured=true
                fi
                if [ -f ~/.profile ] && grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.profile; then
                    path_configured=true
                fi

                if [ "$path_configured" = true ]; then
                    print_success "PATH already configured in shell config"
                    print_info "Run 'source ~/.bashrc' or start a new terminal for changes to take effect"
                else
                    # Offer to add to shell config
                    echo ""
                    print_info "To make linode-cli available in future sessions, add this to your ~/.bashrc:"
                    echo -e "  ${BOLD}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
                    echo ""

                    if confirm "Add to ~/.bashrc automatically?" "y"; then
                        echo '' >> ~/.bashrc
                        echo '# Add local bin to PATH for pipx and other local tools' >> ~/.bashrc
                        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
                        print_success "Added to ~/.bashrc"
                        print_info "Run 'source ~/.bashrc' or start a new terminal for changes to take effect"
                    else
                        print_info "You can add it manually later to make it permanent"
                    fi
                fi
            else
                print_error "linode-cli still not found after installation"
                print_info "Please log out and log back in, or run: source ~/.bashrc"
                print_info "Then re-run this script."
                exit 1
            fi
        else
            print_success "linode-cli is available in PATH"
        fi
    fi
}

configure_linode_api() {
    print_header "Configuring Linode API"

    # Check if already configured and working
    if [ -f "$HOME/.config/linode-cli" ]; then
        print_success "Linode CLI configuration file already exists"

        # Test if it works
        if linode-cli regions list --text &> /dev/null; then
            print_success "Linode API connection verified"

            if confirm "Linode CLI is already configured and working. Reconfigure?" "n"; then
                print_info "Reconfiguring Linode CLI..."
                configure_linode_cli_interactive
            fi
            return 0
        else
            print_warning "Configuration exists but API connection failed"
            print_info "Let's reconfigure with a valid token..."
            configure_linode_cli_interactive
        fi
    else
        print_info "Linode CLI needs to be configured with your API token."
        echo ""
        configure_linode_cli_interactive
    fi
}

configure_linode_cli_interactive() {
    echo "To get a Linode API token:"
    echo "  1. Open: ${BOLD}https://cloud.linode.com/profile/tokens${NC}"
    echo "  2. Click 'Create Personal Access Token'"
    echo "  3. Label: 'GitLab Deployment'"
    echo "  4. Grant these permissions:"
    echo "     - Linodes: ${BOLD}Read/Write${NC}"
    echo "     - StackScripts: ${BOLD}Read/Write${NC}"
    echo "     - Images: ${BOLD}Read/Write${NC}"
    echo "  5. Copy the token"
    echo ""

    if confirm "Do you have your API token ready?" "y"; then
        print_info "Starting Linode CLI configuration..."
        echo ""
        echo "${BOLD}Configuration prompts you'll see:${NC}"
        echo "  • Configure custom API target? → Answer: ${GREEN}N${NC}"
        echo "  • Suppress API warnings? → Answer: ${GREEN}N${NC} (so you can see any issues)"
        echo "  • Personal Access Token → Paste your token"
        echo "  • Default region → Enter: ${GREEN}us-east${NC}"
        echo "  • Default type → Enter: ${GREEN}g6-standard-1${NC} (2GB RAM, for GitLab)"
        echo "  • Default image → Enter: ${GREEN}linode/ubuntu24.04${NC}"
        echo ""

        if confirm "Ready to configure now?" "y"; then
            # Run the configuration
            linode-cli configure --token

            # Verify it worked
            if linode-cli regions list --text &> /dev/null; then
                print_success "Linode CLI configured successfully!"
            else
                print_error "Configuration may have failed"
                print_info "Try running: linode-cli configure --token"
                return 1
            fi
        else
            print_warning "Skipping configuration"
            print_info "You can configure later with: linode-cli configure --token"
            return 1
        fi
    else
        print_info "Please get your API token first, then run: linode-cli configure --token"
        return 1
    fi
}

setup_ssh_keys() {
    print_header "Setting Up SSH Keys"

    # Create keys directory
    mkdir -p "$KEYS_DIR"

    # Check for existing SSH key
    if [ -f "$HOME/.ssh/id_rsa.pub" ] || [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        print_success "SSH key already exists"

        if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
            local pubkey_file="$HOME/.ssh/id_ed25519.pub"
        else
            local pubkey_file="$HOME/.ssh/id_rsa.pub"
        fi

        print_info "Your public key:"
        echo ""
        cat "$pubkey_file"
        echo ""
    else
        print_info "No SSH key found. Creating a new one..."

        if confirm "Generate a new SSH key pair for GitLab?" "y"; then
            ssh-keygen -t ed25519 -C "gitlab-deployment" -f "$HOME/.ssh/id_ed25519" -N ""
            print_success "SSH key pair created"

            print_info "Your public key:"
            echo ""
            cat "$HOME/.ssh/id_ed25519.pub"
            echo ""
        else
            print_warning "Skipping SSH key generation"
            print_info "You can generate a key later with: ssh-keygen -t ed25519"
        fi
    fi

    # Create GitLab-specific key if desired
    if [ ! -f "$KEYS_DIR/gitlab_linode" ]; then
        echo ""
        print_info "You can create a dedicated SSH key pair for GitLab Linode servers"
        print_info "This is recommended for better security (separate keys for different servers)"
        echo ""

        if confirm "Create a dedicated GitLab Linode SSH key?" "y"; then
            ssh-keygen -t ed25519 -C "gitlab-linode-deployment" -f "$KEYS_DIR/gitlab_linode" -N ""
            chmod 600 "$KEYS_DIR/gitlab_linode"
            chmod 644 "$KEYS_DIR/gitlab_linode.pub"
            print_success "Dedicated GitLab Linode key created at: $KEYS_DIR/gitlab_linode"

            print_info "Your GitLab Linode public key:"
            echo ""
            cat "$KEYS_DIR/gitlab_linode.pub"
            echo ""

            # Add to SSH config
            setup_ssh_config
        fi
    else
        print_success "GitLab Linode SSH key already exists"
    fi
}

setup_ssh_config() {
    print_header "Setting Up SSH Configuration"

    local ssh_config="$HOME/.ssh/config"

    # Create SSH config if it doesn't exist
    touch "$ssh_config"
    chmod 600 "$ssh_config"

    # Check if GitLab config already exists
    if grep -q "# GitLab Linode Servers" "$ssh_config"; then
        print_success "SSH config for GitLab already exists"
    else
        print_info "Adding GitLab configuration to ~/.ssh/config"

        cat >> "$ssh_config" << 'EOF'

# GitLab Linode Servers
Host gitlab-*
    User gitlab
    IdentityFile ~/.nwp/git/keys/gitlab_linode
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

# GitLab Linode Production Server
Host gitlab-prod
    HostName # Set this to your GitLab server IP or domain
    User gitlab
EOF
        print_success "SSH config updated"
        print_info "Edit ~/.ssh/config to set HostName values for your servers"
    fi
}

create_config_files() {
    print_header "Creating Configuration Files"

    # Create config directory
    mkdir -p "$CONFIG_DIR"

    # Create gitlab.yml if it doesn't exist
    if [ -f "$CONFIG_FILE" ]; then
        print_success "Configuration file already exists: $CONFIG_FILE"
    else
        print_info "Creating configuration file: $CONFIG_FILE"

        cat > "$CONFIG_FILE" << 'EOF'
# GitLab Configuration for NWP

# API Configuration
api:
  # Get token from: https://cloud.linode.com/profile/tokens
  token: ""
  default_region: "us-east"
  default_plan: "g6-standard-1"  # 2GB RAM minimum for GitLab
  default_image: "linode/ubuntu24.04"

# Server Defaults
server:
  ssh_user: "gitlab"
  ssh_port: 22
  timezone: "America/New_York"
  ssh_key_path: "~/.nwp/git/keys/gitlab_linode.pub"

# GitLab Configuration
gitlab:
  external_url: "http://gitlab.example.com"
  initial_root_password: ""  # Auto-generated on first install
  letsencrypt_email: "admin@example.com"
  enable_registry: true
  enable_lfs: true

# Runner Configuration
runner:
  install_by_default: true
  default_executor: "docker"
  default_tags: "docker,linux,shell"
  concurrent_jobs: 1

# Backup Settings
backup:
  retention_days: 7
  backup_path: "/var/backups/gitlab"
  include_registry: true
  include_artifacts: true
  include_lfs: true

# Servers (managed automatically by scripts)
servers: []
EOF
        print_success "Configuration file created"
        print_warning "Edit $CONFIG_FILE to configure your settings"
    fi
}

verify_setup() {
    print_header "Verifying Setup"

    local errors=0
    local warnings=0

    # Check Linode CLI installation
    if command -v linode-cli &> /dev/null; then
        print_success "Linode CLI is installed"
    else
        print_error "Linode CLI is not installed or not in PATH"
        errors=$((errors + 1))
    fi

    # Check Linode CLI configuration
    if [ -f "$HOME/.config/linode-cli" ]; then
        # Test API connectivity
        if linode-cli regions list --text &> /dev/null; then
            print_success "Linode API connection working"
        else
            print_warning "Linode CLI configured but API connection failed"
            print_info "Your token may be invalid. Run: linode-cli configure --token"
            warnings=$((warnings + 1))
        fi
    else
        print_warning "Linode CLI not configured"
        print_info "Run: linode-cli configure --token"
        warnings=$((warnings + 1))
    fi

    # Check SSH keys
    local key_found=false
    if [ -f "$KEYS_DIR/gitlab_linode.pub" ]; then
        print_success "GitLab Linode SSH key found"
        key_found=true
    fi

    if [ -f "$HOME/.ssh/id_ed25519.pub" ] || [ -f "$HOME/.ssh/id_rsa.pub" ]; then
        print_success "Default SSH key found"
        key_found=true
    fi

    if [ "$key_found" = false ]; then
        print_warning "No SSH key found"
        print_info "Run: ssh-keygen -t ed25519 -f $KEYS_DIR/gitlab_linode"
        warnings=$((warnings + 1))
    fi

    # Check config file
    if [ -f "$CONFIG_FILE" ]; then
        print_success "Configuration file exists: $CONFIG_FILE"
    else
        print_warning "Configuration file not found"
        warnings=$((warnings + 1))
    fi

    # Check for jq (needed for deployment)
    if command -v jq &> /dev/null; then
        print_success "jq is installed (needed for server management)"
    else
        print_info "jq not installed (optional, needed for StackScript upload)"
        print_info "Install with: sudo apt-get install jq"
    fi

    echo ""
    if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
        print_success "✓ All checks passed! You're ready to deploy GitLab to Linode."
        echo ""
        echo "${BOLD}Next steps:${NC}"
        echo "  1. Install jq: ${GREEN}sudo apt-get install jq${NC}"
        echo "  2. Upload StackScript: ${GREEN}./gitlab_upload_stackscript.sh${NC}"
        echo "  3. Create GitLab server: ${GREEN}./gitlab_create_server.sh --domain gitlab.example.com --email admin@example.com${NC}"
        return 0
    elif [ $errors -eq 0 ]; then
        print_warning "Setup completed with $warnings warning(s)"
        print_info "Review the warnings above. Most are optional."
        return 0
    else
        print_error "Setup completed with $errors error(s) and $warnings warning(s)"
        print_info "Please address the errors above before proceeding"
        return 1
    fi
}

display_next_steps() {
    print_header "Next Steps"

    echo "Your GitLab Linode environment is now set up! Here's what to do next:"
    echo ""
    echo "1. ${BOLD}Review and edit configuration:${NC}"
    echo "   nano $CONFIG_FILE"
    echo ""
    echo "2. ${BOLD}List available Linode plans (GitLab needs 2GB+ RAM):${NC}"
    echo "   linode-cli linodes types"
    echo ""
    echo "3. ${BOLD}List available regions:${NC}"
    echo "   linode-cli regions list"
    echo ""
    echo "4. ${BOLD}Upload the GitLab StackScript:${NC}"
    echo "   cd $GIT_DIR"
    echo "   ./gitlab_upload_stackscript.sh"
    echo ""
    echo "5. ${BOLD}Create your GitLab server:${NC}"
    echo "   ./gitlab_create_server.sh --domain gitlab.example.com --email admin@example.com"
    echo ""
    echo "6. ${BOLD}Read the documentation:${NC}"
    echo "   cat $GIT_DIR/docs/SETUP_GUIDE.md"
    echo ""

    print_info "For help with any script, use the --help flag"
    print_warning "GitLab requires minimum 2GB RAM (g6-standard-1 plan or larger)"
}

# Main execution
main() {
    print_header "GitLab Linode Setup"

    echo "This script will set up your environment for deploying GitLab to Linode."
    echo ""
    echo "It will:"
    echo "  • Check and install missing prerequisites (Python, pip, SSH)"
    echo "  • Install Linode CLI"
    echo "  • Configure Linode API access"
    echo "  • Generate SSH keys"
    echo "  • Create configuration files"
    echo ""
    echo "${YELLOW}Note: GitLab requires minimum 2GB RAM${NC}"
    echo ""

    if ! confirm "Continue with setup?" "y"; then
        echo "Setup cancelled."
        exit 0
    fi

    check_prerequisites
    install_linode_cli
    configure_linode_api
    setup_ssh_keys
    create_config_files
    verify_setup
    display_next_steps

    print_header "Setup Complete!"
}

# Run main function
main
