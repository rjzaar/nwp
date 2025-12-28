#!/bin/bash

################################################################################
# gitlab-register-runner.sh - Register GitLab Runner
################################################################################
#
# Registers a GitLab Runner with the GitLab instance.
# This script runs ON the GitLab server.
#
# Usage:
#   ./gitlab-register-runner.sh [OPTIONS]
#
# Options:
#   --url URL            GitLab instance URL (default: http://localhost)
#   --token TOKEN        Registration token (required)
#   --executor EXECUTOR  Executor type (default: docker)
#   --tags TAGS          Comma-separated tags (default: docker,shell)
#   --name NAME          Runner name (default: hostname-runner)
#   -h, --help           Show this help message
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

# Default configuration
GITLAB_URL="http://localhost"
REGISTRATION_TOKEN=""
EXECUTOR="docker"
TAGS="docker,shell"
RUNNER_NAME="$(hostname)-runner"

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
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --url)
            GITLAB_URL="$2"
            shift 2
            ;;
        --token)
            REGISTRATION_TOKEN="$2"
            shift 2
            ;;
        --executor)
            EXECUTOR="$2"
            shift 2
            ;;
        --tags)
            TAGS="$2"
            shift 2
            ;;
        --name)
            RUNNER_NAME="$2"
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

print_header "GitLab Runner Registration"

# Check if gitlab-runner is installed
if ! command -v gitlab-runner &> /dev/null; then
    print_error "gitlab-runner is not installed"
    print_info "Install with: curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | sudo bash && sudo apt-get install -y gitlab-runner"
    exit 1
fi

print_success "gitlab-runner is installed"

# Validate registration token
if [ -z "$REGISTRATION_TOKEN" ]; then
    print_error "Registration token is required"
    echo ""
    print_info "To get your registration token:"
    echo "  1. Open GitLab in your browser"
    echo "  2. Go to: Admin Area > CI/CD > Runners"
    echo "  3. Or for project runners: Project > Settings > CI/CD > Runners"
    echo "  4. Copy the registration token"
    echo ""
    print_info "Then run:"
    echo "  $0 --token YOUR_TOKEN"
    exit 1
fi

echo "Configuration:"
echo "  GitLab URL: $GITLAB_URL"
echo "  Executor: $EXECUTOR"
echo "  Tags: $TAGS"
echo "  Name: $RUNNER_NAME"
echo ""

# Set docker image based on executor
if [ "$EXECUTOR" = "docker" ]; then
    DOCKER_IMAGE="alpine:latest"
else
    DOCKER_IMAGE=""
fi

# Register the runner
print_info "Registering GitLab Runner..."

if [ "$EXECUTOR" = "docker" ]; then
    sudo gitlab-runner register \
        --non-interactive \
        --url "$GITLAB_URL" \
        --registration-token "$REGISTRATION_TOKEN" \
        --executor "docker" \
        --docker-image "$DOCKER_IMAGE" \
        --description "$RUNNER_NAME" \
        --tag-list "$TAGS" \
        --run-untagged="true" \
        --locked="false"
else
    sudo gitlab-runner register \
        --non-interactive \
        --url "$GITLAB_URL" \
        --registration-token "$REGISTRATION_TOKEN" \
        --executor "$EXECUTOR" \
        --description "$RUNNER_NAME" \
        --tag-list "$TAGS" \
        --run-untagged="true" \
        --locked="false"
fi

print_success "Runner registered successfully!"

# Verify registration
print_info "Verifying runner..."

if sudo gitlab-runner verify; then
    print_success "Runner verification passed!"
else
    print_warning "Runner verification failed"
    print_info "Check configuration: sudo gitlab-runner verify --delete"
fi

# Show runner status
print_info "Runner status:"
sudo gitlab-runner list

print_header "Registration Complete!"

echo "Runner Details:"
echo "  Name: $RUNNER_NAME"
echo "  Executor: $EXECUTOR"
echo "  Tags: $TAGS"
echo ""
echo "Next Steps:"
echo "  1. Verify runner appears in GitLab UI"
echo "  2. Test with a simple CI/CD pipeline"
echo "  3. Monitor runner: sudo gitlab-runner list"
echo ""
echo "Useful Commands:"
echo "  Start runner: sudo gitlab-runner start"
echo "  Stop runner: sudo gitlab-runner stop"
echo "  View logs: sudo journalctl -u gitlab-runner -f"
echo ""
print_success "Runner is ready to execute CI/CD jobs!"
