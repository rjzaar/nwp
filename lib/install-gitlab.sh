#!/bin/bash
################################################################################
# NWP GitLab Installation Library
#
# Handles GitLab CE installations via Docker
# This file is lazy-loaded by install.sh when recipe type is "gitlab"
################################################################################

# Guard against multiple sourcing
if [ "${_INSTALL_GITLAB_LOADED:-}" = "1" ]; then
    return 0
fi
_INSTALL_GITLAB_LOADED=1

################################################################################
# Main GitLab Installation Function
################################################################################

install_gitlab() {
    local recipe=$1
    local install_dir=$2
    local start_step=${3:-1}
    local purpose=${4:-indefinite}
    local config_file="cnwp.yml"

    # Get recipe configuration
    local source=$(get_recipe_value "$recipe" "source" "$config_file")
    local sitename=$(get_recipe_value "$recipe" "sitename" "$config_file")
    local branch=$(get_recipe_value "$recipe" "branch" "$config_file")

    # Defaults
    sitename="${sitename:-GitLab Instance}"
    branch="${branch:-master}"

    # Get external URL from settings or use localhost
    local external_url=$(get_settings_value "url" "$config_file")
    if [ -n "$external_url" ]; then
        external_url="https://git.${external_url}"
    else
        external_url="http://${install_dir}.localhost"
    fi

    print_header "GitLab Installation: $install_dir"
    echo ""
    echo -e "  Site name:     ${BLUE}$sitename${NC}"
    echo -e "  External URL:  ${BLUE}$external_url${NC}"
    echo -e "  Purpose:       ${BLUE}$purpose${NC}"
    echo ""

    # Step 1: Create directory structure
    if [ "$start_step" -le 1 ]; then
        print_header "Step 1: Create Directory Structure"

        if [ -d "$install_dir" ]; then
            print_warning "Directory $install_dir already exists"
            read -p "Remove and recreate? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -rf "$install_dir"
            else
                print_error "Cannot continue - directory exists"
                return 1
            fi
        fi

        mkdir -p "$install_dir"/{config,logs,data}
        print_status "OK" "Created GitLab directory structure"
    fi

    cd "$install_dir"

    # Step 2: Create docker-compose.yml
    if [ "$start_step" -le 2 ]; then
        print_header "Step 2: Create Docker Compose Configuration"

        cat > docker-compose.yml << GITLAB_COMPOSE
version: '3.8'

services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: ${install_dir}-gitlab
    restart: unless-stopped
    hostname: '${install_dir}.localhost'
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url '${external_url}'
        gitlab_rails['gitlab_shell_ssh_port'] = 2222
        # Reduce memory usage for development
        puma['worker_processes'] = 2
        sidekiq['max_concurrency'] = 5
        prometheus_monitoring['enable'] = false
        grafana['enable'] = false
    ports:
      - '8080:80'
      - '8443:443'
      - '2222:22'
    volumes:
      - './config:/etc/gitlab'
      - './logs:/var/log/gitlab'
      - './data:/var/opt/gitlab'
    shm_size: '256m'
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/-/health"]
      interval: 60s
      timeout: 10s
      retries: 5
      start_period: 300s

networks:
  default:
    name: ${install_dir}-network
GITLAB_COMPOSE

        print_status "OK" "Created docker-compose.yml"
    fi

    # Step 3: Create environment file
    if [ "$start_step" -le 3 ]; then
        print_header "Step 3: Create Environment Configuration"

        cat > .env << GITLAB_ENV
# GitLab Environment Configuration
GITLAB_HOME=$(pwd)
EXTERNAL_URL=${external_url}
GITLAB_ROOT_PASSWORD=\${GITLAB_ROOT_PASSWORD:-ChangeMe123!}
GITLAB_ENV

        cat > README.md << GITLAB_README
# GitLab Instance: $install_dir

## Quick Start

1. Start GitLab:
   \`\`\`bash
   docker-compose up -d
   \`\`\`

2. Wait for GitLab to initialize (5-10 minutes on first run):
   \`\`\`bash
   docker-compose logs -f gitlab
   \`\`\`

3. Get the initial root password:
   \`\`\`bash
   docker-compose exec gitlab grep 'Password:' /etc/gitlab/initial_root_password
   \`\`\`

4. Access GitLab:
   - URL: ${external_url} (or http://localhost:8080 for local access)
   - Username: root
   - Password: (from step 3)

## Management Commands

- Stop: \`docker-compose down\`
- Start: \`docker-compose up -d\`
- Logs: \`docker-compose logs -f\`
- Shell: \`docker-compose exec gitlab bash\`
- Rails console: \`docker-compose exec gitlab gitlab-rails console\`

## Backup

\`\`\`bash
docker-compose exec gitlab gitlab-backup create
\`\`\`

Backups are stored in \`./data/backups/\`

## Configuration

Edit \`docker-compose.yml\` and modify GITLAB_OMNIBUS_CONFIG, then:
\`\`\`bash
docker-compose down
docker-compose up -d
\`\`\`

## Resource Requirements

- Minimum: 4GB RAM, 2 CPU cores
- Recommended: 8GB RAM, 4 CPU cores
GITLAB_README

        print_status "OK" "Created environment files and README"
    fi

    # Step 4: Start GitLab (optional - can take a while)
    if [ "$start_step" -le 4 ]; then
        print_header "Step 4: Start GitLab"

        echo ""
        print_info "GitLab requires significant resources (4GB+ RAM)"
        print_info "First startup takes 5-10 minutes"
        echo ""
        read -p "Start GitLab now? [Y/n]: " start_now

        if [[ -z "$start_now" || "$start_now" =~ ^[Yy]$ ]]; then
            print_info "Starting GitLab containers..."
            if docker-compose up -d; then
                print_status "OK" "GitLab containers started"
                echo ""
                print_info "GitLab is initializing. This takes 5-10 minutes."
                print_info "Monitor with: cd $install_dir && docker-compose logs -f"
                print_info "Get root password: docker-compose exec gitlab grep 'Password:' /etc/gitlab/initial_root_password"
            else
                print_warning "Failed to start containers - check Docker is running"
            fi
        else
            print_info "Skipping startup - run 'docker-compose up -d' when ready"
        fi
    fi

    cd "$SCRIPT_DIR"

    # Register site in cnwp.yml
    local site_dir="$PROJECT_ROOT/$install_dir"

    if command -v yaml_add_site &> /dev/null; then
        if yaml_add_site "$install_dir" "$site_dir" "$recipe" "development" "$purpose" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null; then
            print_status "OK" "Site registered in cnwp.yml (purpose: $purpose)"

            # Update site with selected options
            update_site_options "$install_dir" "$PROJECT_ROOT/cnwp.yml"
        else
            print_info "Site registration skipped (may already exist)"

            # Still try to update options if site exists
            if yaml_site_exists "$install_dir" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null; then
                update_site_options "$install_dir" "$PROJECT_ROOT/cnwp.yml"
            fi
        fi
    fi

    # Apply selected options from interactive checkbox
    apply_gitlab_options

    # Show summary
    print_header "GitLab Installation Complete"
    echo ""
    echo -e "  Directory:    ${GREEN}$install_dir${NC}"
    echo -e "  External URL: ${GREEN}$external_url${NC}"
    echo -e "  Local URL:    ${GREEN}http://localhost:8080${NC}"
    echo -e "  Purpose:      ${GREEN}$purpose${NC}"
    echo ""
    print_info "See $install_dir/README.md for usage instructions"

    # Show manual steps guide for selected options
    show_installation_guide "$install_dir" "development"

    return 0
}
