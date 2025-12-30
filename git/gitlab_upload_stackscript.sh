#!/bin/bash

################################################################################
# gitlab_upload_stackscript.sh - Upload GitLab StackScript to Linode
################################################################################
#
# This script uploads the gitlab_server_setup.sh as a StackScript to your
# Linode account so it can be used for provisioning GitLab servers.
#
# Usage:
#   ./gitlab_upload_stackscript.sh [OPTIONS]
#
# Options:
#   --update         Update existing StackScript instead of creating new
#   --label LABEL    Custom label (default: GitLab CE Server Setup)
#   -h, --help       Show this help message
#
################################################################################

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACKSCRIPT_FILE="$SCRIPT_DIR/gitlab_server_setup.sh"
LABEL="GitLab CE Server Setup"
UPDATE_MODE=false

# Helper functions
print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --update)
            UPDATE_MODE=true
            shift
            ;;
        --label)
            LABEL="$2"
            shift 2
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

print_header "Upload GitLab StackScript to Linode"

# Check if linode-cli is installed
if ! command -v linode-cli &> /dev/null; then
    print_error "Linode CLI is not installed"
    print_info "Run ./gitlab_setup.sh first to install and configure Linode CLI"
    exit 1
fi

# Check if configured
if ! linode-cli linodes list &> /dev/null; then
    print_error "Linode CLI is not configured"
    print_info "Run: linode-cli configure --token"
    exit 1
fi

print_success "Linode CLI is configured"

# Check if stackscript file exists
if [ ! -f "$STACKSCRIPT_FILE" ]; then
    print_error "StackScript file not found: $STACKSCRIPT_FILE"
    exit 1
fi

print_success "StackScript file found: $STACKSCRIPT_FILE"

# Validate script for Unicode characters
print_info "Validating script content..."

# Check for non-ASCII characters
if grep -qP '[^\x00-\x7F]' "$STACKSCRIPT_FILE" 2>/dev/null || \
   python3 -c "import sys; sys.exit(0 if all(ord(c) < 128 for c in open('$STACKSCRIPT_FILE').read()) else 1)" 2>/dev/null; then
    print_error "StackScript contains Unicode/non-ASCII characters"
    print_info "Linode StackScripts only support ASCII characters"
    echo ""
    print_info "Automatically fixing Unicode characters..."

    # Create backup
    cp "$STACKSCRIPT_FILE" "$STACKSCRIPT_FILE.backup"

    # Fix Unicode characters
    python3 << PYEOF
with open("$STACKSCRIPT_FILE", 'r', encoding='utf-8') as f:
    content = f.read()

# Replace common Unicode characters with ASCII equivalents
replacements = {
    '✓': '[OK]', '✗': '[X]', '⚠': '[!]', '•': '*',
    '→': '->', '←': '<-', '↑': '^', '↓': 'v',
    '═': '=', '│': '|', '├': '|', '└': '+', '┘': '+',
    '┬': '-', '┴': '-', '┼': '+', '─': '-',
    '🌟': '', '✨': '', '🎯': '', '🔧': '', '📋': '', '🚀': '',
}

for unicode_char, ascii_replacement in replacements.items():
    content = content.replace(unicode_char, ascii_replacement)

# Remove any remaining non-ASCII characters
content = content.encode('ascii', 'ignore').decode('ascii')

with open("$STACKSCRIPT_FILE", 'w') as f:
    f.write(content)
PYEOF

    print_success "Unicode characters replaced with ASCII equivalents"
    print_info "Backup saved to: $STACKSCRIPT_FILE.backup"
fi

print_success "Script validation passed"

# Read the script content
SCRIPT_CONTENT=$(cat "$STACKSCRIPT_FILE")

# Check if we're updating or creating
if [ "$UPDATE_MODE" = true ]; then
    print_info "Searching for existing StackScript..."

    # Find existing StackScript by label
    STACKSCRIPT_ID=$(linode-cli stackscripts list --json | jq -r ".[] | select(.label == \"$LABEL\") | .id" | head -n1)

    if [ -z "$STACKSCRIPT_ID" ]; then
        print_error "No existing StackScript found with label: $LABEL"
        print_info "Use without --update flag to create a new one"
        exit 1
    fi

    print_success "Found existing StackScript ID: $STACKSCRIPT_ID"
    print_info "Updating StackScript..."

    # Update the StackScript using backticks
    linode-cli stackscripts update "$STACKSCRIPT_ID" \
        --label "$LABEL" \
        --description "Automated GitLab CE + Runner provisioning for Ubuntu 24.04" \
        --script "`cat "$STACKSCRIPT_FILE"`" \
        --images "linode/ubuntu24.04" \
        --is_public false

    print_success "StackScript updated successfully!"

else
    # Check if StackScript with this label already exists
    EXISTING_ID=$(linode-cli stackscripts list --json 2>/dev/null | jq -r ".[] | select(.label == \"$LABEL\") | .id" | head -n1)

    if [ -n "$EXISTING_ID" ]; then
        print_warning "StackScript with label '$LABEL' already exists (ID: $EXISTING_ID)"
        print_info "Use --update flag to update it, or --label to use a different name"
        exit 1
    fi

    print_info "Creating new StackScript..."

    # Create the StackScript using backticks (required by Linode CLI)
    RESPONSE=$(linode-cli stackscripts create \
        --label "$LABEL" \
        --description "Automated GitLab CE + Runner provisioning for Ubuntu 24.04" \
        --script "`cat "$STACKSCRIPT_FILE"`" \
        --images "linode/ubuntu24.04" \
        --is_public false \
        --json 2>&1)

    STACKSCRIPT_ID=$(echo "$RESPONSE" | jq -r '.[0].id' 2>/dev/null)

    if [ -z "$STACKSCRIPT_ID" ] || [ "$STACKSCRIPT_ID" = "null" ]; then
        print_error "Failed to create StackScript"
        echo "$RESPONSE"
        exit 1
    fi

    print_success "StackScript created successfully!"
fi

# Save the StackScript ID
CONFIG_DIR="$HOME/.nwp"
mkdir -p "$CONFIG_DIR"
echo "$STACKSCRIPT_ID" > "$CONFIG_DIR/gitlab_stackscript_id"

print_header "Upload Complete!"

echo "StackScript Details:"
echo "  ID: $STACKSCRIPT_ID"
echo "  Label: $LABEL"
echo ""
echo "View in Cloud Manager:"
echo "  https://cloud.linode.com/stackscripts/$STACKSCRIPT_ID"
echo ""
echo "Use with Linode CLI:"
echo "  linode-cli linodes create \\"
echo "    --label \"gitlab-prod\" \\"
echo "    --region us-east \\"
echo "    --type g6-standard-1 \\"
echo "    --image linode/ubuntu24.04 \\"
echo "    --root_pass \"SecurePassword123!\" \\"
echo "    --stackscript_id $STACKSCRIPT_ID \\"
echo "    --stackscript_data '{\"ssh_user\":\"gitlab\",\"ssh_pubkey\":\"YOUR_PUBLIC_KEY\",\"hostname\":\"gitlab.example.com\",\"email\":\"admin@example.com\",\"gitlab_external_url\":\"https://gitlab.example.com\"}'"
echo ""
echo "Or use the helper script:"
echo "  ./gitlab_create_server.sh --domain gitlab.example.com --email admin@example.com"
echo ""
print_success "StackScript ID saved to: $CONFIG_DIR/gitlab_stackscript_id"
