#!/bin/bash
set -euo pipefail

################################################################################
# NWP Installation Script
#
# Reads cnwp.yml and installs OpenSocial based on the specified recipe
# Usage: ./install.sh <recipe_name> [target_name] [options]
#
# Arguments:
#   recipe_name                  - Name of recipe from cnwp.yml
#   target_name                  - Optional: custom directory/site name
#
# Examples:
#   ./install.sh nwp              - Install using 'nwp' recipe in 'nwp' directory
#   ./install.sh nwp client1      - Install using 'nwp' recipe in 'client1' directory
#   ./install.sh nwp mysite s=3   - Resume 'mysite' installation from step 3
#   ./install.sh nwp site1 c      - Install 'nwp' recipe as 'site1' with test content
#
# Options:
#   c, --create-content          - Create test content (5 users, 5 docs, 5 workflow assignments)
#   s=N, --step=N                - Resume installation from step N
#
# Environment Variables:
#   TEST_PASSWORD                - Password for test users (default: test123)
#
# Installation Steps:
#   1  - Initialize project with Composer (includes Drush installation)
#   2  - Generate environment configuration (.env files)
#   3  - Configure DDEV
#   4  - Configure memory settings
#   5  - Start DDEV services
#   6  - Verify Drush is available
#   7  - Configure private file system
#   8  - Install Drupal profile
#   9  - Install additional modules and export config
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source shared libraries
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Source YAML library for site registration
if [ -f "$SCRIPT_DIR/lib/yaml-write.sh" ]; then
    source "$SCRIPT_DIR/lib/yaml-write.sh"
fi

# Source Linode library for DNS registration
if [ -f "$SCRIPT_DIR/lib/linode.sh" ]; then
    source "$SCRIPT_DIR/lib/linode.sh"
fi

################################################################################
# DNS Pre-registration for Live Sites
################################################################################

# Pre-register DNS entry for future live site deployment
# This eliminates DNS propagation wait time when running pl live
pre_register_live_dns() {
    local site_name="$1"

    # Get base name (strip _stg or _prod suffix)
    local base_name=$(echo "$site_name" | sed -E 's/_(stg|prod|dev)$//')

    # Get base domain from settings
    local base_domain=$(get_settings_value "url" "$SCRIPT_DIR/cnwp.yml")
    if [ -z "$base_domain" ]; then
        print_info "DNS pre-registration skipped: No 'url' in cnwp.yml settings"
        return 0
    fi

    # Get Linode API token
    local token=""
    if command -v get_linode_token &> /dev/null; then
        token=$(get_linode_token "$SCRIPT_DIR")
    fi

    if [ -z "$token" ]; then
        print_info "DNS pre-registration skipped: No Linode API token in .secrets.yml"
        return 0
    fi

    # Get shared GitLab server IP
    local gitlab_host="git.${base_domain}"
    local server_ip=""

    # Try to get IP via SSH first
    if ssh -o BatchMode=yes -o ConnectTimeout=3 "gitlab@${gitlab_host}" "hostname -I" 2>/dev/null | awk '{print $1}' | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        server_ip=$(ssh -o BatchMode=yes -o ConnectTimeout=3 "gitlab@${gitlab_host}" "hostname -I" 2>/dev/null | awk '{print $1}')
    else
        # Fall back to DNS lookup
        server_ip=$(dig +short "$gitlab_host" 2>/dev/null | head -1)
    fi

    if [ -z "$server_ip" ]; then
        print_info "DNS pre-registration skipped: Cannot reach shared server ${gitlab_host}"
        return 0
    fi

    # Get domain ID
    local domain_id=""
    local response=$(curl -s -H "Authorization: Bearer $token" "https://api.linode.com/v4/domains")

    if command -v jq &> /dev/null; then
        domain_id=$(echo "$response" | jq -r ".data[] | select(.domain == \"${base_domain}\") | .id")
    fi

    if [ -z "$domain_id" ]; then
        print_info "DNS pre-registration skipped: Domain ${base_domain} not found in Linode"
        return 0
    fi

    # Check if DNS record already exists
    local existing=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains/${domain_id}/records" | \
        grep -o "\"name\":\"${base_name}\"" || true)

    if [ -n "$existing" ]; then
        print_info "DNS record already exists: ${base_name}.${base_domain}"
        return 0
    fi

    # Create A record
    print_info "Pre-registering DNS for future live site: ${base_name}.${base_domain}"

    local create_response=$(curl -s -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        "https://api.linode.com/v4/domains/${domain_id}/records" \
        -d "{
            \"type\": \"A\",
            \"name\": \"${base_name}\",
            \"target\": \"${server_ip}\",
            \"ttl_sec\": 300
        }")

    if echo "$create_response" | grep -q '"id"'; then
        print_status "OK" "DNS pre-registered: ${base_name}.${base_domain} -> ${server_ip}"
    fi

    return 0
}

################################################################################
# YAML Parsing Functions
################################################################################

# Parse YAML file and extract value for a given recipe and key
get_recipe_value() {
    local recipe=$1
    local key=$2
    local config_file="${3:-cnwp.yml}"

    # Use awk to extract the value
    awk -v recipe="$recipe" -v key="$key" '
        BEGIN { in_recipe = 0; found = 0 }
        /^  [a-zA-Z0-9_-]+:/ {
            if ($1 == recipe":") {
                in_recipe = 1
            } else if (in_recipe && /^  [a-zA-Z0-9_-]+:/) {
                in_recipe = 0
            }
        }
        in_recipe && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            print
            found = 1
            exit
        }
    ' "$config_file"
}

# Parse YAML file and extract root-level value
get_root_value() {
    local key=$1
    local config_file="${2:-cnwp.yml}"

    # Use awk to extract root-level values (not indented)
    awk -v key="$key" '
        /^[a-zA-Z0-9_-]+:/ && $1 == key":" {
            sub("^" key ": *", "")
            print
            exit
        }
    ' "$config_file"
}

# Get value from settings section
get_settings_value() {
    local key=$1
    local config_file="${2:-cnwp.yml}"

    # Use awk to extract values from settings section (indented under settings:)
    awk -v key="$key" '
        BEGIN { in_settings = 0 }
        /^settings:/ {
            in_settings = 1
            next
        }
        in_settings && /^[a-zA-Z0-9_-]+:/ {
            # Exited settings section
            in_settings = 0
        }
        in_settings && /^  [a-zA-Z0-9_-]+:/ && $1 == key":" {
            sub("^  " key ": *", "")
            print
            exit
        }
    ' "$config_file"
}

# Check if recipe exists in config file
recipe_exists() {
    local recipe=$1
    local config_file="${2:-cnwp.yml}"

    grep -q "^  ${recipe}:" "$config_file"
    return $?
}

# List all available recipes with their descriptions
list_recipes() {
    local config_file="${1:-cnwp.yml}"

    print_header "Available Recipes"

    echo -e "${BOLD}Recipes defined in $config_file:${NC}\n"

    # Extract recipe names only from the recipes: section
    local recipes=$(awk '
        /^recipes:/ { in_recipes = 1; next }
        /^[a-zA-Z]/ { in_recipes = 0 }
        in_recipes && /^  [a-zA-Z0-9_-]+:/ {
            match($0, /^  ([a-zA-Z0-9_-]+):/, arr)
            if (arr[1]) print arr[1]
        }
    ' "$config_file")

    for recipe in $recipes; do
        local recipe_type=$(get_recipe_value "$recipe" "type" "$config_file")
        local source=$(get_recipe_value "$recipe" "source" "$config_file")
        local profile=$(get_recipe_value "$recipe" "profile" "$config_file")
        local branch=$(get_recipe_value "$recipe" "branch" "$config_file")

        # Default to drupal if type not specified
        if [ -z "$recipe_type" ]; then
            recipe_type="drupal"
        fi

        echo -e "${BLUE}${BOLD}$recipe${NC} (${recipe_type})"

        if [ "$recipe_type" == "moodle" ]; then
            echo -e "  Source: $source"
            [ -n "$branch" ] && echo -e "  Branch: $branch"
        else
            echo -e "  Source: $source"
            [ -n "$profile" ] && echo -e "  Profile: $profile"
        fi

        echo ""
    done

    echo -e "${BOLD}Usage:${NC}"
    echo -e "  ./install.sh <recipe>           Install the specified recipe"
    echo -e "  ./install.sh <recipe> c         Install with test content creation"
    echo -e "  ./install.sh <recipe> s=N       Start from step N"
    echo ""
}

# Validate that a recipe has all required fields
validate_recipe() {
    local recipe=$1
    local config_file="${2:-cnwp.yml}"
    local errors=0

    local recipe_type=$(get_recipe_value "$recipe" "type" "$config_file")

    # Default to drupal if type not specified
    if [ -z "$recipe_type" ]; then
        recipe_type="drupal"
    fi

    # Check required fields based on type
    if [ "$recipe_type" == "moodle" ]; then
        # Moodle required fields
        local source=$(get_recipe_value "$recipe" "source" "$config_file")
        local branch=$(get_recipe_value "$recipe" "branch" "$config_file")
        local webroot=$(get_recipe_value "$recipe" "webroot" "$config_file")

        if [ -z "$source" ]; then
            print_error "Recipe '$recipe': Missing required field 'source'"
            errors=$((errors + 1))
        fi

        if [ -z "$branch" ]; then
            print_error "Recipe '$recipe': Missing required field 'branch'"
            errors=$((errors + 1))
        fi

        if [ -z "$webroot" ]; then
            print_error "Recipe '$recipe': Missing required field 'webroot'"
            errors=$((errors + 1))
        fi
    elif [ "$recipe_type" == "gitlab" ]; then
        # GitLab required fields - uses Docker, minimal requirements
        local source=$(get_recipe_value "$recipe" "source" "$config_file")
        # GitLab only needs source (git URL) - everything else has defaults
        if [ -z "$source" ]; then
            print_error "Recipe '$recipe': Missing required field 'source'"
            errors=$((errors + 1))
        fi
    elif [ "$recipe_type" == "migration" ]; then
        # Migration type has no required fields - just creates stub
        :
    else
        # Drupal required fields
        local source=$(get_recipe_value "$recipe" "source" "$config_file")
        local profile=$(get_recipe_value "$recipe" "profile" "$config_file")
        local webroot=$(get_recipe_value "$recipe" "webroot" "$config_file")

        if [ -z "$source" ]; then
            print_error "Recipe '$recipe': Missing required field 'source'"
            errors=$((errors + 1))
        fi

        if [ -z "$profile" ]; then
            print_error "Recipe '$recipe': Missing required field 'profile'"
            errors=$((errors + 1))
        fi

        if [ -z "$webroot" ]; then
            print_error "Recipe '$recipe': Missing required field 'webroot'"
            errors=$((errors + 1))
        fi
    fi

    return $errors
}

# Show help information
show_help() {
    local config_file="${1:-cnwp.yml}"

    echo -e "${BOLD}Narrow Way Project Installation Script${NC}"
    echo ""
    echo -e "${BOLD}USAGE:${NC}"
    echo -e "  ./install.sh [OPTIONS] <recipe> [target]"
    echo ""
    echo -e "${BOLD}ARGUMENTS:${NC}"
    echo -e "  recipe                  Recipe name from cnwp.yml (required)"
    echo -e "  target                  Custom directory/site name (optional)"
    echo ""
    echo -e "${BOLD}OPTIONS:${NC}"
    echo -e "  -l, --list              List all available recipes"
    echo -e "  -h, --help              Show this help message"
    echo -e "  c, --create-content     Create test content after installation"
    echo -e "  s=N, --step=N           Start installation from step N"
    echo -e "  -p=X, --purpose=X       Set site purpose (t=testing, i=indefinite, p=permanent, m=migration)"
    echo ""
    echo -e "${BOLD}PURPOSE VALUES:${NC}"
    echo -e "  testing (t)             Site can be deleted freely (default for test sites)"
    echo -e "  indefinite (i)          Site not auto-deleted but can be manually deleted (default)"
    echo -e "  permanent (p)           Site requires manual change in cnwp.yml before deletion"
    echo -e "  migration (m)           Migration site - creates folder stub only for importing"
    echo ""
    echo -e "${BOLD}EXAMPLES:${NC}"
    echo -e "  ./install.sh --list              List available recipes"
    echo -e "  ./install.sh nwp                 Install nwp recipe in 'nwp' directory"
    echo -e "  ./install.sh nwp client1         Install nwp recipe in 'client1' directory"
    echo -e "  ./install.sh nwp mysite c        Install nwp as 'mysite' with test content"
    echo -e "  ./install.sh nwp site2 s=3       Resume 'site2' from step 3"
    echo -e "  ./install.sh nwp prod -p=p       Install with permanent purpose"
    echo -e "  ./install.sh d oldsite -p=m      Create migration stub for importing old site"
    echo ""
    echo -e "${BOLD}TARGET NAMES:${NC}"
    echo -e "  The target parameter allows you to create multiple sites from the same recipe."
    echo -e "  If not specified, the recipe name is used as the directory/site name."
    echo -e "  Examples:"
    echo -e "    ./install.sh nwp          → Creates site in directory 'nwp'"
    echo -e "    ./install.sh nwp client1  → Creates site in directory 'client1'"
    echo -e "    ./install.sh nwp client2  → Creates site in directory 'client2'"
    echo ""
    echo -e "${BOLD}AVAILABLE RECIPES:${NC}"
    local recipes=$(awk '
        /^recipes:/ { in_recipes = 1; next }
        /^[a-zA-Z]/ { in_recipes = 0 }
        in_recipes && /^  [a-zA-Z0-9_-]+:/ {
            match($0, /^  ([a-zA-Z0-9_-]+):/, arr)
            if (arr[1]) print arr[1]
        }
    ' "$config_file")
    for recipe in $recipes; do
        echo -e "  - $recipe"
    done
    echo ""
    echo -e "For detailed recipe information, use: ./install.sh --list"
    echo ""
}

# Extract module name from git URL
get_module_name_from_git_url() {
    local git_url=$1
    # Extract last part of path and remove .git extension
    # Handles both git@github.com:user/repo.git and https://github.com/user/repo.git
    echo "$git_url" | sed -e 's/.*[:/]\([^/]*\)\.git$/\1/' -e 's/.*\/\([^/]*\)\.git$/\1/'
}

# Check if a string is a git URL
is_git_url() {
    local url=$1
    if [[ "$url" =~ ^git@ ]] || [[ "$url" =~ \.git$ ]]; then
        return 0
    fi
    return 1
}

# Install modules from git repositories
install_git_modules() {
    local git_modules=$1
    local webroot=$2
    local custom_dir="${webroot}/modules/custom"

    print_info "Installing modules from git repositories..."

    # Create custom modules directory if it doesn't exist
    if [ ! -d "$custom_dir" ]; then
        mkdir -p "$custom_dir"
        print_status "OK" "Created custom modules directory: $custom_dir"
    fi

    # Process each git module
    for git_url in $git_modules; do
        local module_name=$(get_module_name_from_git_url "$git_url")
        local module_path="${custom_dir}/${module_name}"

        if [ -d "$module_path" ]; then
            print_status "WARN" "Module $module_name already exists, skipping clone"
            continue
        fi

        print_info "Cloning $module_name from $git_url..."
        if git clone "$git_url" "$module_path"; then
            print_status "OK" "Module $module_name cloned successfully"
        else
            print_error "Failed to clone module $module_name from $git_url"
            return 1
        fi
    done

    return 0
}

# Find available directory name for recipe installation
get_available_dirname() {
    local recipe=$1
    local dirname="$recipe"
    local counter=1

    # If directory doesn't exist, return it
    if [ ! -d "$dirname" ]; then
        echo "$dirname"
        return 0
    fi

    # Otherwise, find the next available numbered directory
    while [ -d "${recipe}${counter}" ]; do
        counter=$((counter + 1))
    done

    echo "${recipe}${counter}"
    return 0
}

################################################################################
# Installation Functions (Following Part 2 of Guide - Method 1)
################################################################################

# Check if current step should be executed
should_run_step() {
    local current_step=$1
    local start_step=$2

    if [ -z "$start_step" ] || [ "$current_step" -ge "$start_step" ]; then
        return 0  # true - run this step
    else
        return 1  # false - skip this step
    fi
}

# Create test content for workflow_assignment module
# Create test content for workflow_assignment module
create_test_content() {
    print_header "Creating Test Content"

    print_info "Enabling workflow_assignment module..."
    if ! ddev drush pm:enable workflow_assignment -y 2>&1 | grep -v "Deprecated"; then
        print_error "Failed to enable workflow_assignment module"
        return 1
    fi

    print_info "Enabling page content type for workflow support and clearing cache..."
    if ! ddev drush php:eval "
        \$config = \Drupal::configFactory()->getEditable('workflow_assignment.settings');
        \$enabled_types = \$config->get('enabled_content_types') ?: [];
        if (!in_array('page', \$enabled_types)) {
            \$enabled_types[] = 'page';
            \$config->set('enabled_content_types', \$enabled_types);
            \$config->save();
        }
        drupal_flush_all_caches();
    " 2>&1 | grep -v "Deprecated" >/dev/null; then
        print_warning "Could not configure workflow settings (may already be configured)"
    fi

    print_info "Creating 5 test users..."
    local users=()
    for i in {1..5}; do
        local username="testuser$i"
        local email="testuser$i@example.com"

        if ddev drush user:info "$username" &>/dev/null; then
            print_info "User $username already exists, skipping..."
        else
            if ddev drush user:create "$username" --mail="$email" --password="${TEST_PASSWORD:-test123}" 2>&1 | grep -v "Deprecated" >/dev/null; then
                print_info "Created user: $username"
            else
                print_warning "Failed to create user: $username"
            fi
        fi
        users+=("$username")
    done

    print_info "Creating 5 test documents..."
    local doc_nids=()
    for i in {1..5}; do
        local title="Test Document $i"
        local body="This is test document number $i for workflow assignment testing."

        local nid=$(ddev drush php:eval "
            \$node = \Drupal\node\Entity\Node::create([
                'type' => 'page',
                'title' => '$title',
                'body' => [
                    'value' => '$body',
                    'format' => 'basic_html',
                ],
                'uid' => 1,
                'status' => 1,
            ]);
            \$node->save();
            echo \$node->id();
        " 2>/dev/null | tail -1)

        if [ -n "$nid" ]; then
            doc_nids+=("$nid")
            print_info "Created document: $title (NID: $nid)"
        fi
    done

    print_info "Creating 5 workflow assignments..."
    local workflow_ids=()
    for i in {1..5}; do
        local user_index=$((i - 1))
        local username="${users[$user_index]}"
        local wf_id="test_workflow_$i"

        if ddev drush php:eval "
            \$users = \Drupal::entityTypeManager()
                ->getStorage('user')
                ->loadByProperties(['name' => '$username']);
            \$user = reset(\$users);

            if (\$user) {
                \$workflow = \Drupal::entityTypeManager()
                    ->getStorage('workflow_list')
                    ->create([
                        'id' => '${wf_id}',
                        'label' => 'Workflow Task $i',
                        'description' => 'This is test workflow assignment $i for testing purposes.',
                        'assigned_type' => 'user',
                        'assigned_id' => \$user->id(),
                        'comments' => 'Test comment for workflow $i',
                    ]);
                \$workflow->save();
                echo 'OK';
            } else {
                echo 'USER_NOT_FOUND';
            }
        " 2>/dev/null | grep -q "OK"; then
            workflow_ids+=("$wf_id")
            print_info "Created workflow: Workflow Task $i (assigned to $username)"
        else
            print_warning "Failed to create workflow: Workflow Task $i"
        fi
    done

    # Link workflows to the first document
    if [ ${#doc_nids[@]} -gt 0 ] && [ ${#workflow_ids[@]} -gt 0 ]; then
        local target_nid="${doc_nids[0]}"

        print_info "Linking workflows to document (NID: $target_nid)..."
        # Build workflow IDs string safely
        local wf_ids_str=""
        for wf_id in "${workflow_ids[@]}"; do
            [ -n "$wf_ids_str" ] && wf_ids_str+=", "
            wf_ids_str+="'$wf_id'"
        done

        if ddev drush php:eval "
            \$node = \Drupal\node\Entity\Node::load($target_nid);
            if (\$node && \$node->hasField('field_workflow_list')) {
                \$workflow_ids = [$wf_ids_str];
                \$node->set('field_workflow_list', \$workflow_ids);
                \$node->save();
                echo 'OK';
            } else {
                echo 'FIELD_NOT_FOUND';
            }
        " 2>/dev/null | grep -q "OK"; then
            print_status "OK" "Test content created successfully"
        else
            print_warning "Could not link workflows to document (field may not exist)"
            print_status "OK" "Test content partially created"
        fi

        # Get one-time login URL and append workflow tab destination
        local uli_url=$(ddev drush uli --uri=default 2>/dev/null | tail -n 1)
        local workflow_url="${uli_url%/login}/login?destination=/node/${target_nid}/workflow"

        echo ""
        echo -e "${BOLD}Test Content Summary:${NC}"
        echo -e "  ${GREEN}✓${NC} ${#users[@]} users created (testuser1-${#users[@]}, password: ${TEST_PASSWORD:-test123})"
        echo -e "  ${GREEN}✓${NC} ${#doc_nids[@]} documents created (NIDs: ${doc_nids[*]})"
        echo -e "  ${GREEN}✓${NC} ${#workflow_ids[@]} workflow assignments linked to document $target_nid"
        echo ""
        echo -e "${BOLD}Login and view workflow assignments:${NC}"
        echo -e "  ${BLUE}${workflow_url}${NC}"
        echo ""

        # Try to open in browser with login URL that redirects to workflow tab
        if command -v xdg-open &> /dev/null; then
            xdg-open "$workflow_url" &>/dev/null &
            print_status "OK" "Browser opened with login to workflow tab"
        elif command -v open &> /dev/null; then
            open "$workflow_url" &>/dev/null &
            print_status "OK" "Browser opened with login to workflow tab"
        fi
    else
        print_error "No documents or workflows were created"
        return 1
    fi

    return 0
}

install_opensocial() {
    local recipe=$1
    local install_dir=$2
    local start_step=$3
    local create_content=$4
    local purpose=${5:-indefinite}
    local base_dir=$(pwd)

    print_header "Installing OpenSocial using recipe: $recipe"

    if [ -n "$start_step" ]; then
        print_info "Starting from step $start_step (skipping earlier steps)"
        echo ""
    fi

    # Setup installation directory
    local project_dir=""

    if [ -n "$start_step" ]; then
        # When resuming, directory must already exist
        if [ ! -d "$install_dir" ]; then
            print_error "Installation directory '$install_dir' does not exist. Cannot resume from step $start_step"
            print_info "To resume an installation, the directory must already exist"
            return 1
        fi

        if ! cd "$install_dir"; then
            print_error "Failed to enter directory: $install_dir"
            return 1
        fi

        project_dir=$(pwd)
        print_status "INFO" "Using existing directory: $project_dir"
    else
        # Fresh installation - create directory
        print_info "Installation directory: $install_dir"

        # Create and enter the installation directory using absolute path
        local abs_install_dir="$base_dir/$install_dir"
        if ! mkdir -p "$abs_install_dir"; then
            print_error "Failed to create directory: $abs_install_dir"
            return 1
        fi

        # Change to absolute path to avoid Docker mount issues
        if ! cd "$abs_install_dir"; then
            print_error "Failed to enter directory: $abs_install_dir"
            return 1
        fi

        project_dir=$(pwd)
        print_status "OK" "Created installation directory: $project_dir"
    fi

    # Extract configuration values from YAML
    local source=$(get_recipe_value "$recipe" "source" "$base_dir/cnwp.yml")
    local profile=$(get_recipe_value "$recipe" "profile" "$base_dir/cnwp.yml")
    local webroot=$(get_recipe_value "$recipe" "webroot" "$base_dir/cnwp.yml")
    local install_modules=$(get_recipe_value "$recipe" "install_modules" "$base_dir/cnwp.yml")

    # Get database and PHP configuration from settings section
    local database=$(get_settings_value "database" "$base_dir/cnwp.yml")
    local php_version=$(get_settings_value "php" "$base_dir/cnwp.yml")

    # Set defaults if not specified
    if [ -z "$php_version" ]; then
        php_version="8.3"  # Default from guide
        print_info "No PHP version specified, using default: 8.3"
    fi

    if [ -z "$database" ]; then
        database="mysql"  # Default
        print_info "No database specified, using default: mysql"
    fi

    # Validate required values
    if [ -z "$source" ]; then
        print_error "Recipe '$recipe' does not specify 'source'"
        return 1
    fi

    if [ -z "$profile" ]; then
        print_error "Recipe '$recipe' does not specify 'profile'"
        return 1
    fi

    if [ -z "$webroot" ]; then
        webroot="html"  # Default from guide
        print_info "No webroot specified, using default: html"
    fi

    print_info "Configuration:"
    echo "  Source:   $source"
    echo "  Profile:  $profile"
    echo "  Webroot:  $webroot"
    echo "  Database: $database"
    echo "  PHP:      $php_version"
    echo ""

    # Step 1: Initialize Project with Composer
    if should_run_step 1 "$start_step"; then
        print_header "Step 1: Initialize Project with Composer"
        print_info "This will take 10-15 minutes..."

        # Extract project without installing dependencies
        print_info "Extracting project template..."
        if ! composer create-project "$source" . --no-install --no-interaction; then
            print_error "Failed to extract project template"
            return 1
        fi

        # Add Asset Packagist repository to project composer.json
        print_info "Configuring repositories..."
        composer config repositories.asset-packagist composer https://asset-packagist.org
        composer config repositories.drupal composer https://packages.drupal.org/8

        # Install dependencies with Asset Packagist available
        print_info "Installing dependencies (this will take 10-15 minutes)..."
        if ! composer install --no-interaction; then
            print_error "Failed to install project dependencies"
            return 1
        fi

        # Install Drush
        print_info "Installing Drush..."
        if composer require drush/drush --dev --no-interaction; then
            print_status "OK" "Drush installed"
        else
            print_status "WARN" "Drush installation failed, but may already be available"
        fi

        print_status "OK" "Dependencies installed successfully"

        # Install additional modules if specified
        if [ -n "$install_modules" ]; then
            # Separate git modules from composer modules
            local git_modules=""
            local composer_modules=""

            for module in $install_modules; do
                if is_git_url "$module"; then
                    git_modules="$git_modules $module"
                else
                    composer_modules="$composer_modules $module"
                fi
            done

            # Install composer modules
            if [ -n "$composer_modules" ]; then
                # Configure dworkflow repository only when needed
                print_info "Configuring custom repositories for additional modules..."
                composer config repositories.dworkflow vcs https://github.com/rjzaar/dworkflow

                print_info "Installing composer modules:$composer_modules"
                if ! composer require $composer_modules --no-interaction; then
                    print_error "Failed to install composer modules"
                    return 1
                fi
                print_status "OK" "Composer modules installed"
            fi

            # Install git modules
            if [ -n "$git_modules" ]; then
                if ! install_git_modules "$git_modules" "$webroot"; then
                    print_error "Failed to install git modules"
                    return 1
                fi
                print_status "OK" "Git modules installed"
            fi
        fi

        print_status "OK" "Project initialized"
    else
        print_status "INFO" "Skipping Step 1: Project already initialized"
    fi

    # Step 2: Generate Environment Configuration
    if should_run_step 2 "$start_step"; then
        print_header "Step 2: Generate Environment Configuration"

        # Use base_dir (NWP root) to find vortex scripts
        local vortex_script="$base_dir/vortex/scripts/generate-env.sh"

        if [ ! -f "$vortex_script" ]; then
            print_error "Vortex environment generation script not found at $vortex_script"
            return 1
        fi

        # Generate .env file
        print_info "Generating .env file from cnwp.yml..."
        if ! "$vortex_script" "$recipe" "$install_dir" .; then
            print_error "Failed to generate environment configuration"
            return 1
        fi

        print_status "OK" "Environment configuration generated"

        # Load environment variables
        if [ -f ".env" ]; then
            print_info "Loading environment variables..."
            set -a
            source ".env"
            set +a
            print_status "OK" "Environment variables loaded"
        fi
    else
        print_status "INFO" "Skipping Step 2: Environment already configured"
    fi

    # Step 3: Configure DDEV
    if should_run_step 3 "$start_step"; then
        print_header "Step 3: Configure DDEV"

        # Use base_dir (NWP root) to find vortex scripts
        local ddev_script="$base_dir/vortex/scripts/generate-ddev.sh"

        if [ -f "$ddev_script" ]; then
            # Use vortex script to generate DDEV config
            print_info "Generating DDEV configuration from .env..."
            if ! "$ddev_script" .; then
                print_error "Failed to generate DDEV configuration"
                return 1
            fi
            print_status "OK" "DDEV configuration generated"
        else
            # Fallback to manual DDEV config
            print_warning "Vortex DDEV script not found, using manual configuration"

            # Map database type to DDEV database type
            local ddev_database="$database"
            # DDEV uses mariadb as the database type
            if [ "$database" == "mysql" ]; then
                ddev_database="mysql:8.0"
            elif [ "$database" == "mariadb" ]; then
                ddev_database="mariadb:10.11"
            fi

            if ! ddev config --project-type=drupal --docroot="$webroot" --php-version="$php_version" --database="$ddev_database"; then
                print_error "Failed to configure DDEV"
                return 1
            fi
            print_status "OK" "DDEV configured (Database: $ddev_database)"
        fi
    else
        print_status "INFO" "Skipping Step 3: DDEV already configured"
    fi

    # Step 4: Memory Configuration
    if should_run_step 4 "$start_step"; then
        print_header "Step 4: Memory Configuration"

        mkdir -p .ddev/php
        cat > .ddev/php/memory.ini << 'EOF'
memory_limit = 512M
max_execution_time = 600
EOF
        print_status "OK" "Memory limits configured"
    else
        print_status "INFO" "Skipping Step 4: Memory already configured"
    fi

    # Step 5: Launch Services
    if should_run_step 5 "$start_step"; then
        print_header "Step 5: Launch DDEV Services"

        if ! ddev start; then
            print_error "Failed to start DDEV"
            return 1
        fi
        print_status "OK" "DDEV services started"
    else
        print_status "INFO" "Skipping Step 5: DDEV already started"
    fi

    # Step 6: Verify Drush is Available
    if should_run_step 6 "$start_step"; then
        print_header "Step 6: Verify Drush is Available"

        # Check if Drush is available
        if [ -f "vendor/bin/drush" ]; then
            print_status "OK" "Drush is available"
        else
            print_error "Drush not found - installation may have failed in Step 1"
            print_info "Try manually installing with: composer require drush/drush --dev"
        fi
    else
        print_status "INFO" "Skipping Step 6: Drush verification"
    fi

    # Step 7: Configure Private File System
    if should_run_step 7 "$start_step"; then
        print_header "Step 7: Configure Private File System"

        # Create private files directory
        mkdir -p private

        # Ensure sites/default directory exists and is writable
        mkdir -p "${webroot}/sites/default"
        chmod 755 "${webroot}/sites/default"

        # Copy default.settings.php to settings.php and add private file path
        if [ -f "${webroot}/sites/default/default.settings.php" ]; then
            cp "${webroot}/sites/default/default.settings.php" "${webroot}/sites/default/settings.php"
        else
            # Create a minimal settings.php if default doesn't exist
            cat > "${webroot}/sites/default/settings.php" << 'EOF'
<?php
/**
 * Drupal settings file.
 */

$databases = [];
$settings['hash_salt'] = '';
EOF
        fi

        # Append private file path configuration to settings.php
        cat >> "${webroot}/sites/default/settings.php" << 'EOF'

/**
 * Private file system configuration.
 * Required for OpenSocial installation.
 */
$settings['file_private_path'] = '../private';

/**
 * Include DDEV settings.
 */
if (file_exists(__DIR__ . '/settings.ddev.php')) {
  include __DIR__ . '/settings.ddev.php';
}

/**
 * Include local development settings.
 */
if (file_exists(__DIR__ . '/settings.local.php')) {
  include __DIR__ . '/settings.local.php';
}
EOF

        chmod 644 "${webroot}/sites/default/settings.php"

        print_status "OK" "Private file system configured in settings.php"
    else
        print_status "INFO" "Skipping Step 7: Private file system already configured"
    fi

    # Step 8: Install Drupal Profile
    if should_run_step 8 "$start_step"; then
        print_header "Step 8: Install Drupal Profile"
        print_info "This will take 5-10 minutes..."

        # Verify DDEV is running and restart to ensure proper mount
        print_info "Verifying DDEV status..."
        if ! ddev describe >/dev/null 2>&1; then
            print_error "DDEV is not running. Starting DDEV..."
            if ! ddev start; then
                print_error "Failed to start DDEV"
                return 1
            fi
        else
            # Restart DDEV to ensure proper container mount context
            print_info "Restarting DDEV to ensure proper container configuration..."
            if ! ddev restart >/dev/null 2>&1; then
                print_error "Failed to restart DDEV"
                return 1
            fi
        fi

        # Verify current directory is accessible
        print_info "Working directory: $(pwd)"
        print_info "Verifying container access..."
        if ! ddev exec pwd >/dev/null 2>&1; then
            print_error "Container cannot access current directory"
            print_error "This is likely a Docker AppArmor/SELinux issue"
            print_info "Try running: sudo aa-status | grep docker"
            return 1
        fi

        # Determine database driver based on database type
        local db_driver="$database"
        # MariaDB uses the mysql driver in Drupal
        if [ "$database" == "mariadb" ]; then
            db_driver="mysql"
        fi

        if ! ddev drush site:install "$profile" \
            --db-url="${db_driver}://db:db@db:3306/db" \
            --account-name=admin \
            --account-pass=admin \
            --site-name="My OpenSocial Site" \
            -y; then
            print_error "Failed to install Drupal site"
            return 1
        fi
        print_status "OK" "Drupal site installed"
    else
        print_status "INFO" "Skipping Step 8: Drupal already installed"
    fi

    # Step 9: Additional modules and configuration
    if should_run_step 9 "$start_step"; then
        # Dev modules installation if dev mode enabled
        local dev=$(get_recipe_value "$recipe" "dev" "$base_dir/cnwp.yml")
        if [ "$dev" == "y" ]; then
            local dev_modules=$(get_recipe_value "$recipe" "dev_modules" "$base_dir/cnwp.yml")
            if [ -n "$dev_modules" ]; then
                print_header "Installing Development Modules"
                print_info "Modules: $dev_modules"

                if ! ddev drush pm:enable $dev_modules -y; then
                    print_error "Failed to install dev modules: $dev_modules"
                else
                    print_status "OK" "Development modules installed"
                fi
            fi
        fi

        # Clear cache and export configuration
        print_info "Clearing cache..."
        ddev drush cr

        print_info "Exporting configuration..."
        if ! ddev drush config:export -y; then
            print_error "Failed to export configuration (non-critical)"
        else
            print_status "OK" "Configuration exported"
        fi

        # Verify installation
        print_info "Verifying installation..."
        ddev drush status
    else
        print_status "INFO" "Skipping Step 9: Additional configuration"
    fi

    # Create test content if requested
    if [ "$create_content" == "y" ]; then
        if ! create_test_content; then
            print_error "Test content creation failed, but installation is complete"
        fi
        echo ""
    fi

    # Success message
    print_header "Installation Complete!"

    echo -e "${GREEN}${BOLD}✓ OpenSocial has been successfully installed!${NC}\n"
    echo -e "${BOLD}Login credentials:${NC}"
    echo -e "  Username: ${GREEN}admin${NC}"
    echo -e "  Password: ${GREEN}admin${NC}\n"

    # Open site with one-time login link
    print_info "Opening site in browser with one-time login link..."

    # Get the one-time login URL
    local uli_url=$(ddev drush uli 2>/dev/null | tail -n 1)

    if [ -n "$uli_url" ]; then
        echo -e "${BOLD}One-time login URL:${NC} ${BLUE}$uli_url${NC}\n"

        # Open in browser (try xdg-open for Linux, open for Mac, or just display)
        if command -v xdg-open &> /dev/null; then
            xdg-open "$uli_url" &>/dev/null &
            print_status "OK" "Site opened in browser"
        elif command -v open &> /dev/null; then
            open "$uli_url" &>/dev/null &
            print_status "OK" "Site opened in browser"
        else
            print_status "WARN" "Could not auto-open browser. Please visit the URL above."
        fi
    else
        print_status "WARN" "Could not generate one-time login link. Use: ddev drush uli"
    fi

    echo ""
    echo -e "${BOLD}Useful commands:${NC}"
    echo -e "  ${BLUE}ddev launch${NC}      - Open site in browser"
    echo -e "  ${BLUE}ddev drush uli${NC}    - Get one-time login link"
    echo -e "  ${BLUE}ddev ssh${NC}          - SSH into container\n"

    # Register site in cnwp.yml (if YAML library is available)
    if command -v yaml_add_site &> /dev/null; then
        print_info "Registering site in cnwp.yml..."

        # Get full directory path
        local site_dir=$(pwd)
        local site_name=$(basename "$site_dir")

        # Determine environment type from directory suffix
        local environment="development"
        if [[ "$site_name" =~ _stg$ ]]; then
            environment="staging"
        elif [[ "$site_name" =~ _prod$ ]]; then
            environment="production"
        elif [[ "$site_name" =~ _dev$ ]]; then
            environment="development"
        fi

        # Get installed modules from install_modules if any
        local installed_modules=""
        if [ -n "$install_modules" ]; then
            installed_modules="$install_modules"
        fi

        # Register the site
        if yaml_add_site "$site_name" "$site_dir" "$recipe" "$environment" "$purpose" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null; then
            print_status "OK" "Site registered in cnwp.yml (purpose: $purpose)"

            # Add installed modules if any
            if [ -n "$installed_modules" ] && command -v yaml_add_site_modules &> /dev/null; then
                yaml_add_site_modules "$site_name" "$installed_modules" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null
            fi
        else
            # Site already exists or registration failed - not critical
            print_info "Site registration skipped (may already exist)"
        fi
    fi

    # Pre-register DNS for live site (if shared server is configured)
    pre_register_live_dns "$site_name"

    return 0
}

################################################################################
# Moodle Installation Function
################################################################################

install_moodle() {
    local recipe=$1
    local install_dir=$2
    local start_step=$3
    local purpose=${4:-indefinite}
    local base_dir=$(pwd)

    print_header "Installing Moodle using recipe: $recipe"

    if [ -n "$start_step" ]; then
        print_info "Starting from step $start_step (skipping earlier steps)"
        echo ""
    fi

    # Setup installation directory
    local project_dir=""

    if [ -n "$start_step" ]; then
        # When resuming, directory must already exist
        if [ ! -d "$install_dir" ]; then
            print_error "Installation directory '$install_dir' does not exist. Cannot resume from step $start_step"
            print_info "To resume an installation, the directory must already exist"
            return 1
        fi

        if ! cd "$install_dir"; then
            print_error "Failed to enter directory: $install_dir"
            return 1
        fi

        project_dir=$(pwd)
        print_status "INFO" "Using existing directory: $project_dir"
    else
        # Fresh installation - create directory
        print_info "Installation directory: $install_dir"

        # Create and enter the installation directory using absolute path
        local abs_install_dir="$base_dir/$install_dir"
        if ! mkdir -p "$abs_install_dir"; then
            print_error "Failed to create directory: $abs_install_dir"
            return 1
        fi

        # Change to absolute path to avoid Docker mount issues
        if ! cd "$abs_install_dir"; then
            print_error "Failed to enter directory: $abs_install_dir"
            return 1
        fi

        project_dir=$(pwd)
        print_status "OK" "Created installation directory: $project_dir"
    fi

    # Extract configuration values from YAML
    local source=$(get_recipe_value "$recipe" "source" "$base_dir/cnwp.yml")
    local branch=$(get_recipe_value "$recipe" "branch" "$base_dir/cnwp.yml")
    local webroot=$(get_recipe_value "$recipe" "webroot" "$base_dir/cnwp.yml")
    local sitename=$(get_recipe_value "$recipe" "sitename" "$base_dir/cnwp.yml")

    # Get database and PHP configuration from settings section
    local database=$(get_settings_value "database" "$base_dir/cnwp.yml")
    local php_version=$(get_settings_value "php" "$base_dir/cnwp.yml")

    # Set defaults if not specified
    if [ -z "$php_version" ]; then
        php_version="8.1"  # Moodle 4.x default
        print_info "No PHP version specified, using default: 8.1"
    fi

    if [ -z "$database" ]; then
        database="mariadb"
        print_info "No database specified, using default: mariadb"
    fi

    if [ -z "$webroot" ]; then
        webroot="."
        print_info "No webroot specified, using default: . (current directory)"
    fi

    if [ -z "$sitename" ]; then
        sitename="My Moodle Site"
    fi

    if [ -z "$branch" ]; then
        branch="MOODLE_404_STABLE"
        print_info "No branch specified, using default: MOODLE_404_STABLE"
    fi

    # Validate required values
    if [ -z "$source" ]; then
        print_error "Recipe '$recipe' does not specify 'source'"
        return 1
    fi

    print_info "Configuration:"
    echo "  Source:   $source"
    echo "  Branch:   $branch"
    echo "  Webroot:  $webroot"
    echo "  Database: $database"
    echo "  PHP:      $php_version"
    echo "  Sitename: $sitename"
    echo ""

    # Step 1: Clone Moodle from Git
    if should_run_step 1 "$start_step"; then
        print_header "Step 1: Clone Moodle Repository"
        print_info "This may take several minutes..."

        if ! git clone --branch "$branch" --depth 1 "$source" .; then
            print_error "Failed to clone Moodle repository"
            return 1
        fi
        print_status "OK" "Moodle cloned successfully"
    else
        print_status "INFO" "Skipping Step 1: Moodle already cloned"
    fi

    # Step 2: Configure DDEV
    if should_run_step 2 "$start_step"; then
        print_header "Step 2: Configure DDEV"

        # Map database type to DDEV database type
        local ddev_database="$database"
        if [ "$database" == "mysql" ]; then
            ddev_database="mysql:8.0"
        elif [ "$database" == "mariadb" ]; then
            ddev_database="mariadb:10.11"
        fi

        # Moodle uses php project type
        if ! ddev config --project-type=php --docroot="$webroot" --php-version="$php_version" --database="$ddev_database"; then
            print_error "Failed to configure DDEV"
            return 1
        fi
        print_status "OK" "DDEV configured (Database: $ddev_database)"
    else
        print_status "INFO" "Skipping Step 2: DDEV already configured"
    fi

    # Step 3: Memory Configuration
    if should_run_step 3 "$start_step"; then
        print_header "Step 3: Memory Configuration"

        mkdir -p .ddev/php
        cat > .ddev/php/memory.ini << 'EOF'
memory_limit = 512M
max_execution_time = 600
post_max_size = 100M
upload_max_filesize = 100M
EOF
        print_status "OK" "Memory limits configured"
    else
        print_status "INFO" "Skipping Step 3: Memory already configured"
    fi

    # Step 4: Launch Services
    if should_run_step 4 "$start_step"; then
        print_header "Step 4: Launch DDEV Services"

        if ! ddev start; then
            print_error "Failed to start DDEV"
            return 1
        fi
        print_status "OK" "DDEV services started"
    else
        print_status "INFO" "Skipping Step 4: DDEV already started"
    fi

    # Step 5: Create Moodledata Directory (outside web root for security)
    if should_run_step 5 "$start_step"; then
        print_header "Step 5: Create Moodledata Directory"

        # Moodle requires dataroot to be OUTSIDE the web root
        # Create it as a sibling directory and add a DDEV mount
        # Use absolute path for docker-compose volume mount
        local moodledata_abs="${base_dir}/${install_dir}_moodledata"
        mkdir -p "$moodledata_abs"
        chmod 777 "$moodledata_abs"

        # Create DDEV docker-compose override to mount moodledata
        # Use absolute path to ensure Docker can find it
        cat > .ddev/docker-compose.moodledata.yaml << MOODLEDATA_EOF
# Moodle dataroot mount - outside web root for security
services:
  web:
    volumes:
      - "${moodledata_abs}:/var/www/moodledata:rw"
MOODLEDATA_EOF

        # Restart DDEV to apply the new mount
        print_info "Restarting DDEV to apply moodledata mount..."
        ddev restart

        print_status "OK" "Moodledata directory created at $moodledata_abs"
    else
        print_status "INFO" "Skipping Step 5: Moodledata already exists"
    fi

    # Step 6: Install Moodle
    if should_run_step 6 "$start_step"; then
        print_header "Step 6: Install Moodle"
        print_info "This will take 5-10 minutes..."

        # Verify DDEV is running and restart to ensure proper mount
        print_info "Verifying DDEV status..."
        if ! ddev describe >/dev/null 2>&1; then
            print_error "DDEV is not running. Starting DDEV..."
            if ! ddev start; then
                print_error "Failed to start DDEV"
                return 1
            fi
        else
            # Restart DDEV to ensure proper container mount context
            print_info "Restarting DDEV to ensure proper container configuration..."
            if ! ddev restart >/dev/null 2>&1; then
                print_error "Failed to restart DDEV"
                return 1
            fi
        fi

        # Verify current directory is accessible
        print_info "Working directory: $(pwd)"
        print_info "Verifying container access..."
        if ! ddev exec pwd >/dev/null 2>&1; then
            print_error "Container cannot access current directory"
            print_error "This is likely a Docker AppArmor/SELinux issue"
            print_info "Try running: sudo aa-status | grep docker"
            return 1
        fi

        # Determine database driver
        local db_driver="mariadb"
        if [ "$database" == "mysql" ]; then
            db_driver="mysqli"
        elif [ "$database" == "mariadb" ]; then
            db_driver="mariadb"
        fi

        # Get the site URL - try multiple methods
        local site_url=""

        # Method 1: Try to get primary_url from JSON
        site_url=$(ddev describe -j 2>/dev/null | grep -o '"primary_url":"[^"]*' | cut -d'"' -f4)

        # Method 2: If that fails, try httpurl
        if [ -z "$site_url" ]; then
            site_url=$(ddev describe -j 2>/dev/null | grep -o '"httpurl":"[^"]*' | cut -d'"' -f4)
        fi

        # Method 3: If that fails, try httpsurl
        if [ -z "$site_url" ]; then
            site_url=$(ddev describe -j 2>/dev/null | grep -o '"httpsurl":"[^"]*' | cut -d'"' -f4)
        fi

        # Method 4: Fallback to hostname-based URL
        if [ -z "$site_url" ]; then
            local hostname=$(ddev describe -j 2>/dev/null | grep -o '"hostname":"[^"]*' | cut -d'"' -f4)
            if [ -n "$hostname" ]; then
                site_url="https://$hostname"
            fi
        fi

        if [ -z "$site_url" ]; then
            print_error "Failed to get site URL from DDEV"
            ddev describe 2>&1 | head -10
            return 1
        fi

        print_info "Site URL: $site_url"

        # Run Moodle installation
        if ! ddev exec php admin/cli/install.php \
            --lang=en \
            --wwwroot="$site_url" \
            --dataroot=/var/www/moodledata \
            --dbtype="$db_driver" \
            --dbhost=db \
            --dbname=db \
            --dbuser=db \
            --dbpass=db \
            --fullname="$sitename" \
            --shortname=moodle \
            --adminuser=admin \
            --adminpass=Admin123! \
            --adminemail=admin@example.com \
            --non-interactive \
            --agree-license; then
            print_error "Failed to install Moodle"
            return 1
        fi
        print_status "OK" "Moodle site installed"
    else
        print_status "INFO" "Skipping Step 6: Moodle already installed"
    fi

    # Step 7: Post-installation configuration
    if should_run_step 7 "$start_step"; then
        print_header "Step 7: Post-Installation Configuration"

        # Set up cron (optional)
        print_info "Moodle installed successfully"
        print_status "OK" "Installation complete"
    else
        print_status "INFO" "Skipping Step 7: Already configured"
    fi

    # Success message
    print_header "Installation Complete!"

    echo -e "${GREEN}${BOLD}✓ Moodle has been successfully installed!${NC}\n"
    echo -e "${BOLD}Login credentials:${NC}"
    echo -e "  Username: ${GREEN}admin${NC}"
    echo -e "  Password: ${GREEN}Admin123!${NC}\n"

    # Open site
    print_info "Opening site in browser..."

    if command -v xdg-open &> /dev/null; then
        local site_url=$(ddev describe -j 2>/dev/null | grep -o '"url":"[^"]*' | cut -d'"' -f4)
        if [ -n "$site_url" ]; then
            xdg-open "$site_url" &>/dev/null &
            print_status "OK" "Site opened in browser: $site_url"
        fi
    elif command -v open &> /dev/null; then
        local site_url=$(ddev describe -j 2>/dev/null | grep -o '"url":"[^"]*' | cut -d'"' -f4)
        if [ -n "$site_url" ]; then
            open "$site_url" &>/dev/null &
            print_status "OK" "Site opened in browser: $site_url"
        fi
    fi

    echo ""
    echo -e "${BOLD}Useful commands:${NC}"
    echo -e "  ${BLUE}ddev launch${NC}      - Open site in browser"
    echo -e "  ${BLUE}ddev ssh${NC}          - SSH into container"
    echo -e "  ${BLUE}ddev exec php admin/cli/cron.php${NC} - Run Moodle cron\n"

    # Register site in cnwp.yml (if YAML library is available)
    if command -v yaml_add_site &> /dev/null; then
        print_info "Registering site in cnwp.yml..."

        # Get full directory path
        local site_dir=$(pwd)
        local site_name=$(basename "$site_dir")

        # Determine environment type from directory suffix
        local environment="development"
        if [[ "$site_name" =~ _stg$ ]]; then
            environment="staging"
        elif [[ "$site_name" =~ _prod$ ]]; then
            environment="production"
        elif [[ "$site_name" =~ _dev$ ]]; then
            environment="development"
        fi

        # Register the site (Moodle doesn't have install_modules typically)
        if yaml_add_site "$site_name" "$site_dir" "$recipe" "$environment" "$purpose" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null; then
            print_status "OK" "Site registered in cnwp.yml (purpose: $purpose)"
        else
            # Site already exists or registration failed - not critical
            print_info "Site registration skipped (may already exist)"
        fi

        # Pre-register DNS for live site (if shared server is configured)
        pre_register_live_dns "$site_name"
    fi

    return 0
}

################################################################################
# GitLab Installation Function
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
            ocmsg "Starting GitLab containers..."
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
    local site_dir="$SCRIPT_DIR/$install_dir"

    if command -v yaml_add_site &> /dev/null; then
        if yaml_add_site "$install_dir" "$site_dir" "$recipe" "development" "$purpose" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null; then
            print_status "OK" "Site registered in cnwp.yml (purpose: $purpose)"
        else
            print_info "Site registration skipped (may already exist)"
        fi
    fi

    # Show summary
    print_header "GitLab Installation Complete"
    echo ""
    echo -e "  Directory:    ${GREEN}$install_dir${NC}"
    echo -e "  External URL: ${GREEN}$external_url${NC}"
    echo -e "  Local URL:    ${GREEN}http://localhost:8080${NC}"
    echo -e "  Purpose:      ${GREEN}$purpose${NC}"
    echo ""
    print_info "See $install_dir/README.md for usage instructions"

    return 0
}

################################################################################
# Main Script
################################################################################

main() {
    local recipe=""
    local target=""
    local start_step=""
    local create_content="n"
    local config_file="cnwp.yml"
    local purpose="indefinite"
    local positional_args=()

    # Parse arguments
    for arg in "$@"; do
        if [[ "$arg" == "-l" ]] || [[ "$arg" == "--list" ]]; then
            list_recipes "$config_file"
            exit 0
        elif [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
            show_help "$config_file"
            exit 0
        elif [[ "$arg" =~ ^s=([0-9]+)$ ]]; then
            start_step="${BASH_REMATCH[1]}"
        elif [[ "$arg" =~ ^--step=([0-9]+)$ ]]; then
            start_step="${BASH_REMATCH[1]}"
        elif [[ "$arg" == "c" ]] || [[ "$arg" == "--create-content" ]]; then
            create_content="y"
        elif [[ "$arg" =~ ^-p=(.+)$ ]] || [[ "$arg" =~ ^--purpose=(.+)$ ]]; then
            local purpose_arg="${BASH_REMATCH[1]}"
            # Map short codes to full values
            case "$purpose_arg" in
                t|testing) purpose="testing" ;;
                i|indefinite) purpose="indefinite" ;;
                p|permanent) purpose="permanent" ;;
                m|migration) purpose="migration" ;;
                *)
                    print_error "Invalid purpose: $purpose_arg"
                    echo "Valid values: t(esting), i(ndefinite), p(ermanent), m(igration)"
                    exit 1
                    ;;
            esac
        else
            positional_args+=("$arg")
        fi
    done

    # Extract recipe and optional target from positional arguments
    if [ ${#positional_args[@]} -ge 1 ]; then
        recipe="${positional_args[0]}"
    fi
    if [ ${#positional_args[@]} -ge 2 ]; then
        target="${positional_args[1]}"
    fi

    # Default recipe if not specified
    if [ -z "$recipe" ]; then
        show_help "$config_file"
        exit 1
    fi

    print_header "NWP OpenSocial Installation"

    if [ -n "$start_step" ]; then
        print_info "Resuming from step $start_step"
    fi

    # Check if config file exists
    if [ ! -f "$config_file" ]; then
        print_error "Configuration file '$config_file' not found"
        exit 1
    fi

    # Check if recipe exists
    if ! recipe_exists "$recipe" "$config_file"; then
        print_error "Recipe '$recipe' not found in $config_file"
        echo ""
        echo "Available recipes:"
        awk '
            /^recipes:/ { in_recipes = 1; next }
            /^[a-zA-Z]/ { in_recipes = 0 }
            in_recipes && /^  [a-zA-Z0-9_-]+:/ {
                match($0, /^  ([a-zA-Z0-9_-]+):/, arr)
                if (arr[1]) print "  - " arr[1]
            }
        ' "$config_file"
        echo ""
        echo "Use './install.sh --list' to see detailed recipe information"
        exit 1
    fi

    # Validate recipe configuration
    print_info "Validating recipe configuration..."
    if ! validate_recipe "$recipe" "$config_file"; then
        print_error "Recipe '$recipe' has missing or invalid configuration"
        echo ""
        echo "Please check your $config_file and ensure all required fields are present:"
        echo "  For Drupal recipes: source, profile, webroot"
        echo "  For Moodle recipes: source, branch, webroot"
        exit 1
    fi
    print_status "OK" "Recipe configuration is valid"

    # Check prerequisites
    print_info "Checking prerequisites..."

    local missing_deps=0

    if ! command -v composer &> /dev/null; then
        print_status "FAIL" "composer is not installed"
        missing_deps=1
    fi

    if ! command -v ddev &> /dev/null; then
        print_status "FAIL" "ddev is not installed"
        missing_deps=1
    fi

    if [ $missing_deps -eq 1 ]; then
        print_error "Missing required dependencies. Please run setup.sh first."
        exit 1
    fi

    print_status "OK" "All prerequisites satisfied"

    # Handle migration purpose - create stub only
    if [ "$purpose" == "migration" ]; then
        print_header "Migration Site Setup"

        # Determine target name
        local migration_name=""
        if [ -n "$target" ]; then
            migration_name="$target"
        else
            migration_name="${recipe}_pre"
        fi

        # Check if directory already exists
        if [ -d "$migration_name" ]; then
            print_error "Directory '$migration_name' already exists"
            exit 1
        fi

        # Create migration directory structure
        print_info "Creating migration stub directory: $migration_name"
        mkdir -p "$migration_name"

        # Create placeholder README
        cat > "$migration_name/README.md" << 'MIGRATION_README'
# Migration Site

This directory is prepared for site migration.

## Next Steps

1. Copy/extract your source site files into this directory
2. Run `./migration.sh analyze <sitename>` to analyze the source
3. Run `./migration.sh prepare <sitename>` to set up target Drupal
4. Run `./migration.sh run <sitename>` to execute migration
5. Run `./migration.sh verify <sitename>` to verify success

## Directory Structure

Place your source site here:
- For Drupal sites: Copy the entire Drupal root
- For static HTML: Create an `html/` subdirectory with your files
- For database dumps: Place SQL files in `database/` subdirectory

## Source Types Supported

- drupal7: Drupal 7 sites (uses Migrate API)
- drupal8/9: Drupal 8/9 sites (upgrade path)
- html: Static HTML sites (uses migrate_source_html)
- wordpress: WordPress sites (uses migrate_wordpress)
- other: Custom migration needed

MIGRATION_README

        # Create subdirectories for source content
        mkdir -p "$migration_name/database"
        mkdir -p "$migration_name/source"

        print_status "OK" "Created migration stub directory"

        # Register in cnwp.yml
        if command -v yaml_add_migration_stub &> /dev/null; then
            print_info "Registering migration site in cnwp.yml..."
            local site_dir="$SCRIPT_DIR/$migration_name"

            # Prompt for source type
            local source_type="other"
            echo ""
            echo "Select source type:"
            echo "  1) drupal7  - Drupal 7 site"
            echo "  2) drupal8  - Drupal 8 site"
            echo "  3) drupal9  - Drupal 9 site"
            echo "  4) html     - Static HTML site"
            echo "  5) wordpress - WordPress site"
            echo "  6) joomla   - Joomla site"
            echo "  7) other    - Other/custom"
            echo ""
            read -p "Enter choice [1-7, default=7]: " source_choice
            case "$source_choice" in
                1) source_type="drupal7" ;;
                2) source_type="drupal8" ;;
                3) source_type="drupal9" ;;
                4) source_type="html" ;;
                5) source_type="wordpress" ;;
                6) source_type="joomla" ;;
                *) source_type="other" ;;
            esac

            if yaml_add_migration_stub "$migration_name" "$site_dir" "$source_type" "" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null; then
                print_status "OK" "Migration site registered in cnwp.yml"
            else
                print_warning "Could not register site in cnwp.yml"
            fi
        fi

        print_header "Migration Stub Complete"
        echo ""
        echo -e "${GREEN}Migration directory created: $migration_name${NC}"
        echo ""
        echo "Next steps:"
        echo "  1. Copy your source site files into: $migration_name/source/"
        echo "  2. Place database dumps in: $migration_name/database/"
        echo "  3. Run: ./migration.sh analyze $migration_name"
        echo ""
        exit 0
    fi

    # Determine base name for installation directory
    local base_name=""
    if [ -n "$target" ]; then
        # Use custom target name if provided
        base_name="$target"
    else
        # Use recipe name as default
        base_name="$recipe"
    fi

    # Determine installation directory based on whether we're resuming
    local install_dir=""
    if [ -n "$start_step" ]; then
        # When resuming, use base name directly (no auto-increment)
        install_dir="$base_name"
    else
        # Fresh install - find available directory with auto-increment
        install_dir=$(get_available_dirname "$base_name")
    fi

    # Read configuration values to display
    local recipe_type=$(get_recipe_value "$recipe" "type" "$config_file")
    local source=$(get_recipe_value "$recipe" "source" "$config_file")
    local profile=$(get_recipe_value "$recipe" "profile" "$config_file")
    local webroot=$(get_recipe_value "$recipe" "webroot" "$config_file")
    local database=$(get_settings_value "database" "$config_file")
    local php_version=$(get_settings_value "php" "$config_file")
    local auto_mode=$(get_recipe_value "$recipe" "auto" "$config_file")

    # Default to drupal if type not specified
    if [ -z "$recipe_type" ]; then
        recipe_type="drupal"
    fi

    # Set defaults for display
    if [ -z "$webroot" ]; then
        webroot="html"
    fi
    if [ -z "$php_version" ]; then
        php_version="8.3"
    fi
    if [ -z "$database" ]; then
        database="mysql"
    fi

    # Confirm installation
    echo ""
    if [ -n "$start_step" ]; then
        echo -e "${YELLOW}${BOLD}This will resume installation from step $start_step.${NC}"
    else
        echo -e "${YELLOW}${BOLD}This will install OpenSocial in a new directory.${NC}"
    fi
    echo ""
    echo -e "${BOLD}Installation Details:${NC}"
    echo -e "  Base directory:    ${BLUE}$(pwd)${NC}"
    echo -e "  Install directory: ${BLUE}$install_dir${NC}"
    echo -e "  Full path:         ${BLUE}$(pwd)/$install_dir${NC}"
    if [ -n "$start_step" ]; then
        echo -e "  Resume from step:  ${BLUE}$start_step${NC}"
    fi
    echo ""
    echo -e "${BOLD}Recipe Configuration: ${GREEN}$recipe${NC}"
    echo -e "  Type:     ${BLUE}$recipe_type${NC}"
    echo -e "  Source:   ${BLUE}$source${NC}"
    if [ "$recipe_type" == "drupal" ]; then
        echo -e "  Profile:  ${BLUE}$profile${NC}"
    fi
    echo -e "  Webroot:  ${BLUE}$webroot${NC}"
    echo -e "  Database: ${BLUE}$database${NC}"
    echo -e "  PHP:      ${BLUE}$php_version${NC}"
    echo ""

    # Check auto mode
    if [ "$auto_mode" == "y" ]; then
        print_status "OK" "Auto mode enabled - proceeding automatically"
        confirm="y"
    else
        read -p "Continue with installation? [Y/n]: " confirm

        # Default to 'y' if empty
        if [ -z "$confirm" ]; then
            confirm="y"
        fi

        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Installation cancelled"
            exit 0
        fi
    fi

    # Run installation based on recipe type
    if [ "$recipe_type" == "moodle" ]; then
        if install_moodle "$recipe" "$install_dir" "$start_step" "$purpose"; then
            exit 0
        else
            print_error "Installation failed"
            exit 1
        fi
    elif [ "$recipe_type" == "gitlab" ]; then
        if install_gitlab "$recipe" "$install_dir" "$start_step" "$purpose"; then
            exit 0
        else
            print_error "Installation failed"
            exit 1
        fi
    else
        # Default to Drupal/OpenSocial installation
        if install_opensocial "$recipe" "$install_dir" "$start_step" "$create_content" "$purpose"; then
            exit 0
        else
            print_error "Installation failed"
            exit 1
        fi
    fi
}

# Run main
main "$@"
