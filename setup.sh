#!/bin/bash

################################################################################
# DDEV + OpenSocial Installation Checker and Installer (v2)
# 
# This script checks if all components from the installation guide are properly
# installed and configured, and offers to install/fix any missing components.
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Status tracking - using regular arrays to avoid bash version issues
declare -a FAILED_ITEMS
declare -a PARTIAL_ITEMS
declare -a WARNING_ITEMS

# Project directory (can be customized)
PROJECT_DIR="$(pwd)"

# Component status flags
DOCKER_STATUS=""
DOCKER_GROUP_STATUS=""
DOCKER_COMPOSE_STATUS=""
MKCERT_STATUS=""
MKCERT_CA_STATUS=""
DDEV_STATUS=""
DDEV_CONFIG_STATUS=""
PROJECT_DIR_STATUS=""
DDEV_PROJECT_STATUS=""
OPENSOCIAL_STATUS=""
DRUPAL_STATUS=""
MODULE_STATUS=""

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
# Check Functions
################################################################################

check_ubuntu_version() {
    echo -e "${BOLD}Checking Ubuntu version...${NC}"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
            local version=$(echo $VERSION_ID | cut -d. -f1)
            if [ "$version" -ge 20 ]; then
                print_status "OK" "Ubuntu $VERSION_ID detected"
            else
                print_status "WARN" "Ubuntu $VERSION_ID detected (recommended: 20.04+)"
                WARNING_ITEMS+=("ubuntu_version")
            fi
        else
            print_status "WARN" "Not Ubuntu, detected: $ID"
            WARNING_ITEMS+=("not_ubuntu")
        fi
    else
        print_status "WARN" "Cannot determine OS version"
        WARNING_ITEMS+=("unknown_os")
    fi
}

check_docker() {
    echo -e "\n${BOLD}Checking Docker installation...${NC}"
    
    if command -v docker &> /dev/null; then
        local docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | cut -d',' -f1)
        print_status "OK" "Docker installed: version $docker_version"
        DOCKER_STATUS="installed"
        
        # Check if Docker is running
        if docker ps &> /dev/null; then
            print_status "OK" "Docker daemon is running"
            
            # Check if user is in docker group
            if groups | grep -q docker; then
                print_status "OK" "User is in docker group"
                DOCKER_GROUP_STATUS="ok"
            else
                print_status "FAIL" "User NOT in docker group - will need sudo"
                DOCKER_GROUP_STATUS="missing"
                FAILED_ITEMS+=("docker_group")
            fi
        else
            print_status "FAIL" "Docker daemon NOT running"
            DOCKER_STATUS="not_running"
            FAILED_ITEMS+=("docker_daemon")
        fi
    else
        print_status "FAIL" "Docker NOT installed"
        DOCKER_STATUS="missing"
        FAILED_ITEMS+=("docker")
    fi
}

check_docker_compose() {
    echo -e "\n${BOLD}Checking Docker Compose...${NC}"
    
    if docker compose version &> /dev/null; then
        local compose_version=$(docker compose version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1)
        print_status "OK" "Docker Compose plugin: $compose_version"
        DOCKER_COMPOSE_STATUS="ok"
    else
        print_status "FAIL" "Docker Compose plugin NOT installed"
        DOCKER_COMPOSE_STATUS="missing"
        FAILED_ITEMS+=("docker_compose")
    fi
}

check_mkcert() {
    echo -e "\n${BOLD}Checking mkcert...${NC}"
    
    if command -v mkcert &> /dev/null; then
        local mkcert_version=$(mkcert -version 2>&1 | grep -oP 'v\d+\.\d+\.\d+' || echo "unknown")
        print_status "OK" "mkcert installed: $mkcert_version"
        MKCERT_STATUS="installed"
        
        # Check if CA is installed
        if mkcert -CAROOT &> /dev/null; then
            local ca_root=$(mkcert -CAROOT)
            if [ -f "$ca_root/rootCA.pem" ]; then
                print_status "OK" "mkcert CA is installed"
                MKCERT_CA_STATUS="ok"
            else
                print_status "FAIL" "mkcert CA NOT installed"
                MKCERT_CA_STATUS="missing"
                FAILED_ITEMS+=("mkcert_ca")
            fi
        fi
    else
        print_status "FAIL" "mkcert NOT installed"
        MKCERT_STATUS="missing"
        FAILED_ITEMS+=("mkcert")
    fi
}

check_ddev() {
    echo -e "\n${BOLD}Checking DDEV...${NC}"
    
    if command -v ddev &> /dev/null; then
        local ddev_version=$(ddev version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1)
        print_status "OK" "DDEV installed: $ddev_version"
        DDEV_STATUS="ok"
    else
        print_status "FAIL" "DDEV NOT installed"
        DDEV_STATUS="missing"
        FAILED_ITEMS+=("ddev")
    fi
}

check_ddev_config() {
    echo -e "\n${BOLD}Checking DDEV global configuration...${NC}"
    
    if [ -f "$HOME/.ddev/global_config.yaml" ]; then
        print_status "OK" "DDEV global config exists"
        DDEV_CONFIG_STATUS="ok"
    else
        print_status "WARN" "DDEV global config not found (optional but recommended)"
        DDEV_CONFIG_STATUS="missing"
        WARNING_ITEMS+=("ddev_config")
    fi
}

check_opensocial_project() {
    echo -e "\n${BOLD}Checking OpenSocial project at: $PROJECT_DIR${NC}"
    
    if [ -d "$PROJECT_DIR" ]; then
        print_status "OK" "Project directory exists"
        PROJECT_DIR_STATUS="exists"
        
        cd "$PROJECT_DIR"
        
        # Check if DDEV is configured
        if [ -f ".ddev/config.yaml" ]; then
            print_status "OK" "DDEV configuration found"
            
            # Check docroot
            local docroot=$(grep "^docroot:" .ddev/config.yaml 2>/dev/null | awk '{print $2}')
            if [ "$docroot" == "html" ]; then
                print_status "OK" "Correct docroot (html)"
            else
                print_status "WARN" "Docroot is '$docroot' (should be 'html')"
                WARNING_ITEMS+=("wrong_docroot")
            fi
            
            # Check if project is running
            if ddev describe &> /dev/null 2>&1; then
                print_status "OK" "DDEV project is running"
                DDEV_PROJECT_STATUS="running"
                
                # Check database type
                local db_info=$(ddev describe 2>/dev/null | grep -A 5 "DATABASE" | grep "Type:" | awk '{print $2}')
                if [ -n "$db_info" ]; then
                    print_status "OK" "Database: $db_info"
                fi
            else
                print_status "WARN" "DDEV project NOT running"
                DDEV_PROJECT_STATUS="stopped"
                PARTIAL_ITEMS+=("ddev_project_stopped")
            fi
            
            # Check if OpenSocial is installed
            if [ -d "html/profiles/contrib/social" ] || [ -d "html/profiles/social" ]; then
                print_status "OK" "OpenSocial profile found"
                OPENSOCIAL_STATUS="installed"
                
                # Check if Drupal site is installed
                if [ -f "html/sites/default/settings.php" ]; then
                    if grep -q "^\$databases\['default'\]" html/sites/default/settings.php 2>/dev/null || \
                       grep -q "^\$databases\[\"default\"\]" html/sites/default/settings.php 2>/dev/null; then
                        print_status "OK" "Drupal appears to be installed"
                        DRUPAL_STATUS="installed"
                    else
                        print_status "FAIL" "Drupal NOT installed (settings.php exists but no database config)"
                        DRUPAL_STATUS="not_installed"
                        FAILED_ITEMS+=("drupal_install")
                    fi
                else
                    print_status "FAIL" "Drupal NOT installed (no settings.php)"
                    DRUPAL_STATUS="not_installed"
                    FAILED_ITEMS+=("drupal_install")
                fi
            else
                print_status "FAIL" "OpenSocial profile NOT found"
                OPENSOCIAL_STATUS="missing"
                FAILED_ITEMS+=("opensocial")
            fi
        else
            print_status "FAIL" "DDEV NOT configured in project"
            DDEV_PROJECT_STATUS="not_configured"
            FAILED_ITEMS+=("ddev_project_config")
        fi
    else
        print_status "FAIL" "Project directory does NOT exist"
        PROJECT_DIR_STATUS="missing"
        FAILED_ITEMS+=("project_directory")
    fi
}

check_custom_module() {
    echo -e "\n${BOLD}Checking field_manager module...${NC}"
    
    if [ "$PROJECT_DIR_STATUS" == "exists" ]; then
        if [ -d "$PROJECT_DIR/html/modules/custom/field_manager" ]; then
            print_status "OK" "field_manager directory exists"
            
            # Check for key files
            local files_ok=true
            if [ -f "$PROJECT_DIR/html/modules/custom/field_manager/field_manager.info.yml" ]; then
                print_status "OK" "Module info file exists"
            else
                print_status "WARN" "Module info file missing"
                files_ok=false
            fi
            
            if [ -f "$PROJECT_DIR/html/modules/custom/field_manager/src/Form/AddFieldForm.php" ]; then
                print_status "OK" "AddFieldForm.php exists"
            else
                print_status "WARN" "AddFieldForm.php missing"
                files_ok=false
            fi
            
            if [ "$files_ok" == "true" ]; then
                MODULE_STATUS="exists"
                
                # Check if module is enabled (only if DDEV is running)
                if [ "$DDEV_PROJECT_STATUS" == "running" ]; then
                    cd "$PROJECT_DIR"
                    if ddev drush pm:list --status=enabled 2>/dev/null | grep -q "field_manager"; then
                        print_status "OK" "field_manager module is enabled"
                        MODULE_STATUS="enabled"
                    else
                        print_status "WARN" "field_manager module NOT enabled"
                        MODULE_STATUS="not_enabled"
                        PARTIAL_ITEMS+=("module_not_enabled")
                    fi
                fi
            else
                MODULE_STATUS="incomplete"
                PARTIAL_ITEMS+=("module_incomplete")
            fi
        else
            print_status "FAIL" "field_manager module NOT found"
            MODULE_STATUS="missing"
            FAILED_ITEMS+=("custom_module")
        fi
    else
        print_status "INFO" "Skipping module check (no project directory)"
        MODULE_STATUS="skipped"
    fi
}

################################################################################
# Installation Functions
################################################################################

install_docker() {
    print_header "Installing Docker Engine"
    
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
}

add_user_to_docker_group() {
    print_header "Adding User to Docker Group"
    
    sudo groupadd docker 2>/dev/null || true
    sudo usermod -aG docker $USER
    
    print_status "OK" "User added to docker group"
    echo -e "${YELLOW}${BOLD}IMPORTANT: You need to log out and log back in!${NC}"
    echo -e "${YELLOW}Or run: newgrp docker${NC}"
}

start_docker() {
    print_header "Starting Docker Daemon"
    
    sudo systemctl start docker
    sudo systemctl enable docker
    
    sleep 2
    
    if docker ps &> /dev/null; then
        print_status "OK" "Docker is now running"
    else
        print_status "FAIL" "Docker failed to start"
    fi
}

install_mkcert() {
    print_header "Installing mkcert"
    
    echo "Installing NSS tools..."
    sudo apt-get update
    sudo apt install -y libnss3-tools
    
    echo "Downloading mkcert..."
    curl -JLO "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
    chmod +x mkcert-v*-linux-amd64
    sudo mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert
    
    print_status "OK" "mkcert installed"
}

install_mkcert_ca() {
    print_header "Installing mkcert Certificate Authority"
    
    mkcert -install
    
    print_status "OK" "mkcert CA installed"
}

install_ddev() {
    print_header "Installing DDEV"
    
    echo "Downloading and installing DDEV..."
    curl -fsSL https://ddev.com/install.sh | bash
    
    echo "Running DDEV system check..."
    ddev debug test || true
    
    print_status "OK" "DDEV installed"
}

create_ddev_config() {
    print_header "Creating DDEV Global Configuration"
    
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
}

create_project_directory() {
    print_header "Creating Project Directory"
    
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    
    print_status "OK" "Project directory created: $PROJECT_DIR"
}

configure_ddev_project() {
    print_header "Configuring DDEV for Project"
    
    cd "$PROJECT_DIR"
    ddev config --project-type=drupal10 --docroot=html --create-docroot
    
    print_status "OK" "DDEV configured"
}

start_ddev_project() {
    print_header "Starting DDEV Project"
    
    cd "$PROJECT_DIR"
    ddev start
    
    print_status "OK" "DDEV project started"
}

install_opensocial() {
    print_header "Installing OpenSocial"
    
    cd "$PROJECT_DIR"
    
    echo "This will take 10-15 minutes..."
    ddev composer create goalgorilla/social_template --no-interaction
    
    print_status "OK" "OpenSocial installed"
}

install_drupal_site() {
    print_header "Installing Drupal Site"
    
    cd "$PROJECT_DIR"
    
    echo "This will take 5-10 minutes..."
    ddev drush site:install social \
        --db-url=mysql://db:db@db:3306/db \
        --account-name=admin \
        --account-pass=admin \
        --site-name="My OpenSocial Site" \
        -y
    
    ddev drush cr
    
    print_status "OK" "Drupal site installed"
    echo -e "${GREEN}${BOLD}Login: admin / admin${NC}"
}

create_field_manager_module() {
    print_header "Creating field_manager Module"
    
    cd "$PROJECT_DIR"
    
    mkdir -p html/modules/custom/field_manager/src/Form
    
    # Create info file
    cat > html/modules/custom/field_manager/field_manager.info.yml << 'EOF'
name: 'Field Manager'
type: module
description: 'Allows administrators to add fields to content types through a user interface.'
package: Custom
core_version_requirement: ^10 || ^11
dependencies:
  - drupal:field
  - drupal:node
  - drupal:field_ui
EOF
    
    # Create basic files
    touch html/modules/custom/field_manager/field_manager.module
    
    print_status "OK" "Module structure created"
    echo -e "${YELLOW}Note: Copy full AddFieldForm.php from the guide for complete functionality${NC}"
}

enable_field_manager() {
    print_header "Enabling field_manager Module"
    
    cd "$PROJECT_DIR"
    ddev drush cr
    ddev drush pm:enable field_manager -y
    
    print_status "OK" "Module enabled"
}

################################################################################
# Summary and Menu
################################################################################

print_summary() {
    print_header "Summary of Issues Found"
    
    local total_issues=$((${#FAILED_ITEMS[@]} + ${#PARTIAL_ITEMS[@]}))
    
    if [ ${#FAILED_ITEMS[@]} -gt 0 ]; then
        echo -e "${RED}${BOLD}Critical Issues (${#FAILED_ITEMS[@]}):${NC}"
        for item in "${FAILED_ITEMS[@]}"; do
            echo -e "  ${RED}✗${NC} $item"
        done
        echo ""
    fi
    
    if [ ${#PARTIAL_ITEMS[@]} -gt 0 ]; then
        echo -e "${YELLOW}${BOLD}Warnings (${#PARTIAL_ITEMS[@]}):${NC}"
        for item in "${PARTIAL_ITEMS[@]}"; do
            echo -e "  ${YELLOW}!${NC} $item"
        done
        echo ""
    fi
    
    if [ $total_issues -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✓ No issues found! Everything looks good.${NC}"
        return 0
    else
        echo -e "${BOLD}Total issues found: $total_issues${NC}"
        return 1
    fi
}

show_installation_menu() {
    print_header "Installation Options"
    
    echo "Select components to install:"
    echo ""
    
    local option_num=1
    
    # Build menu dynamically based on what's missing
    if [[ " ${FAILED_ITEMS[@]} " =~ " docker " ]]; then
        echo "  $option_num) Install Docker Engine"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " docker_group " ]]; then
        echo "  $option_num) Add user to docker group"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " docker_daemon " ]]; then
        echo "  $option_num) Start Docker daemon"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " docker_compose " ]]; then
        echo "  $option_num) Install Docker Compose (usually with Docker)"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " mkcert " ]]; then
        echo "  $option_num) Install mkcert"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " mkcert_ca " ]]; then
        echo "  $option_num) Install mkcert CA"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " ddev " ]]; then
        echo "  $option_num) Install DDEV"
        ((option_num++))
    fi
    
    if [[ " ${WARNING_ITEMS[@]} " =~ " ddev_config " ]]; then
        echo "  $option_num) Create DDEV global config (optional)"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " project_directory " ]]; then
        echo "  $option_num) Create project directory"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " ddev_project_config " ]]; then
        echo "  $option_num) Configure DDEV for project"
        ((option_num++))
    fi
    
    if [[ " ${PARTIAL_ITEMS[@]} " =~ " ddev_project_stopped " ]]; then
        echo "  $option_num) Start DDEV project"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " opensocial " ]]; then
        echo "  $option_num) Install OpenSocial (10-15 min)"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " drupal_install " ]]; then
        echo "  $option_num) Install Drupal site (5-10 min)"
        ((option_num++))
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " custom_module " ]]; then
        echo "  $option_num) Create field_manager module"
        ((option_num++))
    fi
    
    if [[ " ${PARTIAL_ITEMS[@]} " =~ " module_not_enabled " ]]; then
        echo "  $option_num) Enable field_manager module"
        ((option_num++))
    fi
    
    echo ""
    echo "  a) Install ALL missing components automatically"
    echo "  q) Quit without installing"
    echo ""
}

install_by_status() {
    print_header "Installing Missing Components"
    
    # Install in logical order
    if [[ " ${FAILED_ITEMS[@]} " =~ " docker " ]]; then
        install_docker
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " docker_daemon " ]]; then
        start_docker
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " docker_group " ]]; then
        add_user_to_docker_group
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " mkcert " ]]; then
        install_mkcert
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " mkcert_ca " ]]; then
        install_mkcert_ca
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " ddev " ]]; then
        install_ddev
    fi
    
    if [[ " ${WARNING_ITEMS[@]} " =~ " ddev_config " ]]; then
        create_ddev_config
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " project_directory " ]]; then
        create_project_directory
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " ddev_project_config " ]]; then
        configure_ddev_project
    fi
    
    if [[ " ${PARTIAL_ITEMS[@]} " =~ " ddev_project_stopped " ]]; then
        start_ddev_project
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " opensocial " ]]; then
        install_opensocial
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " drupal_install " ]]; then
        install_drupal_site
    fi
    
    if [[ " ${FAILED_ITEMS[@]} " =~ " custom_module " ]]; then
        create_field_manager_module
    fi
    
    if [[ " ${PARTIAL_ITEMS[@]} " =~ " module_not_enabled " ]]; then
        enable_field_manager
    fi
    
    print_header "Installation Complete"
}

################################################################################
# Main Script
################################################################################

main() {
    print_header "DDEV + OpenSocial Installation Checker v2"
    
    echo "This script checks your installation and offers to fix issues."
    echo ""
    
    # Ask for project directory
    read -p "Project directory [$PROJECT_DIR]: " input_dir
    if [ -n "$input_dir" ]; then
        PROJECT_DIR="$input_dir"
    fi
    
    print_header "Running Checks"
    
    # Run all checks
    check_ubuntu_version
    check_docker
    check_docker_compose
    check_mkcert
    check_ddev
    check_ddev_config
    check_opensocial_project
    check_custom_module
    
    # Show summary
    echo ""
    if ! print_summary; then
        # Issues found
        echo ""
        show_installation_menu
        
        read -p "Enter selection (number or 'a' for all, 'q' to quit): " choice
        
        if [[ "$choice" =~ ^[Qq]$ ]]; then
            echo "Exiting..."
            exit 0
        elif [[ "$choice" =~ ^[Aa]$ ]]; then
            if ask_yes_no "Install all missing components?" "y"; then
                install_by_status
                
                # Re-run checks
                echo ""
                print_header "Re-checking Installation"
                FAILED_ITEMS=()
                PARTIAL_ITEMS=()
                WARNING_ITEMS=()
                
                check_ubuntu_version
                check_docker
                check_docker_compose
                check_mkcert
                check_ddev
                check_ddev_config
                check_opensocial_project
                check_custom_module
                
                echo ""
                print_summary
            fi
        fi
    else
        # No issues
        echo ""
        if [ -d "$PROJECT_DIR" ] && [ "$DRUPAL_STATUS" == "installed" ]; then
            echo -e "${BLUE}${BOLD}Quick Start:${NC}"
            echo "  cd $PROJECT_DIR"
            echo "  ddev launch"
            echo "  ddev drush uli"
        fi
    fi
    
    echo ""
    print_header "Done"
}

# Run main
main "$@"
