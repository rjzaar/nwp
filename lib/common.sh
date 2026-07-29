#!/bin/bash

################################################################################
# NWP Common Library
#
# Shared utility functions for all NWP scripts
# Source this file: source "$SCRIPT_DIR/lib/common.sh"
#
# Note: This library requires lib/ui.sh to be sourced first for print_error
################################################################################

# F23 Phase 6: project resolver helpers
# Autoload on source so every consumer of common.sh gets resolve_project,
# get_backup_dir, get_site_config_value, etc.
_common_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_common_sh_dir/project-resolver.sh" ]]; then
    # shellcheck source=project-resolver.sh
    source "$_common_sh_dir/project-resolver.sh"
fi
# F23 Phase 8: server resolver helpers
if [[ -f "$_common_sh_dir/server-resolver.sh" ]]; then
    # shellcheck source=server-resolver.sh
    source "$_common_sh_dir/server-resolver.sh"
fi
# SSH hardening helpers (nwp_ssh / nwp_scp / nwp_rsync wrappers and the
# NWP_SSH_HARDENING_OPTS variable). Auto-sourcing here means every script
# that already sources lib/common.sh gets the lockout-safe ssh wrappers
# without needing an extra `source lib/ssh.sh`.
if [[ -f "$_common_sh_dir/ssh.sh" ]]; then
    # shellcheck source=ssh.sh
    source "$_common_sh_dir/ssh.sh"
fi
unset _common_sh_dir

# Debug message - only prints when DEBUG=true
# Usage: debug_msg "message"
debug_msg() {
    local message=$1
    # ${DEBUG:-false}: sourced by scripts that run under `set -u`, where a bare
    # $DEBUG is fatal. `pl backup sweep` dispatches before main() declares its
    # local DEBUG, so this line silently killed the NIGHTLY SWEEP for 15 days —
    # every site drifted to "backup 14 days old" while the cron logged nothing
    # anyone read. Never reintroduce an unguarded expansion here.
    if [ "${DEBUG:-false}" == "true" ]; then
        echo -e "${CYAN:-\033[0;36m}[DEBUG]${NC:-\033[0m} $message"
    fi
}

# Alias for backwards compatibility
ocmsg() {
    debug_msg "$@"
}

# Validate site name to prevent dangerous operations
# Returns 0 if valid, 1 if invalid
# Usage: validate_sitename "name" ["context"]
validate_sitename() {
    local name="$1"
    local context="${2:-site name}"

    # Check for empty name
    if [ -z "$name" ]; then
        print_error "Empty $context provided"
        return 1
    fi

    # Check for absolute paths
    if [[ "$name" == /* ]]; then
        print_error "Absolute paths not allowed for $context: $name"
        return 1
    fi

    # Check for path traversal
    if [[ "$name" == *".."* ]]; then
        print_error "Path traversal not allowed in $context: $name"
        return 1
    fi

    # Check for dangerous patterns (just dots, slashes only, etc.)
    if [[ "$name" =~ ^[./]+$ ]]; then
        print_error "Invalid $context: $name"
        return 1
    fi

    # Only allow safe characters: alphanumeric, hyphen, underscore, dot
    if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "Invalid characters in $context: $name (only alphanumeric, hyphen, underscore, dot allowed)"
        return 1
    fi

    return 0
}

# True if a site name is test/verify fixture debris (not a real site).
# Canonical fixture-prefix predicate (ops#37) — the same set rag.sh's
# _rag_eligible_sites excludes; keep the two in sync. Deliberately does NOT
# match the special names tmp/latest/(global) — those aren't prunable fixtures.
# Usage: is_fixture_sitename "verify-test3" && echo debris
is_fixture_sitename() {
    case "$1" in
        verify-test*|bats-test*|trace-*|*-del|*-del[0-9]*|*delete*) return 0 ;;
        *) return 1 ;;
    esac
}

# Ask a yes/no question
# Usage: ask_yes_no "question" "default" (y or n)
# Returns 0 for yes, 1 for no
ask_yes_no() {
    local question=$1
    local default=${2:-n}
    local response

    if [ "$default" == "y" ]; then
        read -p "$question [Y/n]: " response
        response=${response:-y}
    else
        read -p "$question [y/N]: " response
        response=${response:-n}
    fi

    case "$response" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

################################################################################
# Password Generation Functions
################################################################################

# Generate a cryptographically secure random password
# Uses OpenSSL for high-quality entropy
# Usage: generate_secure_password [length]
# Default length: 24 characters
# Returns: Alphanumeric password (no special chars that might cause escaping issues)
generate_secure_password() {
    local length=${1:-24}
    openssl rand -base64 48 | tr -d '/=+' | cut -c -"$length"
}

################################################################################
# Configuration Reading Functions
################################################################################

# Resolve the infrastructure secrets file (.secrets.yml). It is gitignored, so
# in a linked git worktree it exists only in the MAIN working tree — fall back
# to that copy so code/agents running inside a worktree still resolve infra
# secrets instead of silently getting the default (ops#70).
# Deliberately NOT applied to .secrets.data.yml — data secrets must stay hard to
# reach from worktree/AI contexts.
_resolve_infra_secrets_file() {
    local f="${PROJECT_ROOT}/.secrets.yml"
    if [ ! -f "$f" ]; then
        local common
        common=$(git -C "${PROJECT_ROOT:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
        if [ -n "$common" ] && [ -f "$(dirname "$common")/.secrets.yml" ]; then
            f="$(dirname "$common")/.secrets.yml"
        fi
    fi
    printf '%s' "$f"
}

# Get secret value from .secrets.yml with fallback
# Usage: get_secret "section.key" "default_value"
# Example: get_secret "moodle.admin_password" "Admin123!"
get_secret() {
    local path="$1"
    local default="$2"
    local secrets_file
    secrets_file="$(_resolve_infra_secrets_file)"

    if [ ! -f "$secrets_file" ]; then
        echo "$default"
        return
    fi

    # Resolve the dotted path robustly, the same way get_data_secret already
    # does (ops#70): yq with each segment quoted, then an ARBITRARY-DEPTH awk
    # fallback. The old inline awk here was hardcoded to exactly TWO levels
    # (`section:` then `  key:`), so a legitimately nested key like
    # `gitlab.server.ip` silently returned the default — automation then made
    # empty-token API calls. yq quoting also fixes keys containing '-' or
    # leading digits.
    local value="" yq_bin
    if yq_bin="$(_nwp_yq_bin 2>/dev/null)"; then
        local expr="" seg
        local IFS_SAVE="$IFS"; IFS='.'
        for seg in $path; do expr="${expr}[\"${seg}\"]"; done
        IFS="$IFS_SAVE"
        value="$("$yq_bin" eval ".${expr}" "$secrets_file" 2>/dev/null || true)"
        [ "$value" = "null" ] && value=""
    fi
    if [ -z "$value" ] && declare -F _nwp_yaml_deep_awk >/dev/null 2>&1; then
        value="$(_nwp_yaml_deep_awk "$secrets_file" "$path")"
    fi
    # Last-resort compatibility with the historical 2-level shape if the deep
    # helpers are somehow unavailable (kept so a partial source can't regress
    # the common gitlab.<key> case to empty).
    if [ -z "$value" ]; then
        local section="${path%%.*}" key="${path#*.}"
        value=$(awk -v section="$section" -v key="$key" '
            $0 ~ "^" section ":" { in_section = 1; next }
            in_section && /^[a-zA-Z]/ && !/^  / { in_section = 0 }
            in_section && $0 ~ "^  " key ":" {
                sub("^  " key ": *", ""); gsub(/["'"'"']/, "")
                sub(/ *#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
                print; exit
            }
        ' "$secrets_file")
    fi

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Get infrastructure secret (from .secrets.yml - safe for AI assistants)
# Usage: get_infra_secret "section.key" "default_value"
# These secrets are for provisioning/automation, NOT user data access
get_infra_secret() {
    local path="$1"
    local default="$2"
    # Uses standard .secrets.yml (infrastructure secrets)
    get_secret "$path" "$default"
}

# Resolve a yq binary for data-secret parsing. Echoes the binary, or returns 1.
# Deliberately local to the secret helpers so a missing yq degrades to the awk
# fallback below rather than failing the caller.
_nwp_yq_bin() {
    if command -v yq >/dev/null 2>&1; then echo yq; return 0; fi
    if [ -x "$HOME/.local/bin/yq" ]; then echo "$HOME/.local/bin/yq"; return 0; fi
    if [ -x /snap/bin/yq ]; then echo /snap/bin/yq; return 0; fi
    return 1
}

# Arbitrary-depth dotted-path reader for a YAML file, awk-only (no yq).
#
# Maintains an indent→key stack, so the *full* dotted path of every mapping key
# is known as it is read; a match against the requested path prints the scalar.
# Handles any nesting depth (the old reader was hardcoded to exactly two).
# Sequences and multi-line scalars are deliberately NOT supported — secrets are
# flat scalars, and quietly half-parsing a block scalar would be worse than a
# clean miss (the caller then sees status 3, "key absent").
_nwp_yaml_deep_awk() {
    local file="$1" path="$2"
    awk -v want="$path" '
        function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function unquote(s){ gsub(/^["'"'"']|["'"'"']$/, "", s); return s }
        {
            line = $0; sub(/\r$/, "", line)
            if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) next
            if (line ~ /^[ \t]*-/) next                 # sequence item: unsupported
            match(line, /^ */); ind = RLENGTH
            body = substr(line, ind + 1)
            if (body !~ /:/) next
            key = body; sub(/:.*$/, "", key); key = unquote(trim(key))
            if (key == "" || key ~ /[ \t]/) next        # not a plain mapping key

            # pop every stack frame at or deeper than this indent
            while (top > 0 && stack_ind[top] >= ind) top--
            top++; stack_ind[top] = ind; stack_key[top] = key

            cur = stack_key[1]
            for (i = 2; i <= top; i++) cur = cur "." stack_key[i]
            if (cur != want) next

            val = body; sub(/^[^:]*:[ \t]*/, "", val); val = trim(val)
            sub(/[ \t]+#.*$/, "", val)
            val = unquote(val)
            if (val == "") next                         # a parent, not a scalar
            print val
            exit
        }
    ' "$file" 2>/dev/null
}

# Get data secret (from .secrets.data.yml - NEVER share with AI)
# Usage: get_data_secret "a.b.c.d" "default_value"
#
# ARBITRARY DEPTH (item 9). The previous implementation hardcoded a 2-level awk
# (`section:` then `  key:`), so any deeper path silently returned the DEFAULT.
# lib/moodle-promote.sh:101 passes a FOUR-level path
# (`moodle.<site>.<tier>.db_password`), so every Moodle stg/dev config write
# resolved an empty password and moodle_write_config then wrote an EMPTY
# $CFG->dbpass while advising the operator to "provision the secret" — advice
# that could not work because the reader could never see the value.
#
# EXIT STATUS is now meaningful (the value/default is always on stdout):
#   0  value found
#   2  secrets file absent      (distinct: "cannot verify" ≠ "not configured")
#   3  file present, key absent
# Callers that care (moodle_write_config) MUST distinguish these; callers that
# do not are unaffected because the default is still echoed.
#
# DELIBERATELY NOT worktree-resolving: unlike _resolve_infra_secrets_file, this
# does NOT fall back to the main checkout's copy via git-common-dir. That
# asymmetry is an intentional security boundary (ops#70) — data secrets stay
# hard to reach from worktree/AI contexts. Status 2 makes the resulting
# "unreachable here" state loud instead of silently defaulting.
get_data_secret() {
    local path="$1"
    local default="${2:-}"
    local data_secrets_file="${PROJECT_ROOT}/.secrets.data.yml"

    # Warn if we're in an AI-accessible context (optional env var)
    if [ "${AI_CONTEXT:-}" = "true" ]; then
        echo "[SECURITY WARNING] Data secret accessed in AI context: $path" >&2
    fi

    if [ ! -f "$data_secrets_file" ]; then
        echo "$default"
        return 2
    fi

    # Escape hatch for one release: NWP_DATA_SECRET_LEGACY=1 restores the old
    # 2-level parser exactly (see the item-9 rollback note).
    if [ "${NWP_DATA_SECRET_LEGACY:-0}" = "1" ]; then
        local lsection="${path%%.*}" lkey="${path#*.}" lvalue
        lvalue=$(awk -v section="$lsection" -v key="$lkey" '
            $0 ~ "^" section ":" { in_section = 1; next }
            in_section && /^[a-zA-Z]/ && !/^  / { in_section = 0 }
            in_section && $0 ~ "^  " key ":" {
                sub("^  " key ": *", ""); gsub(/["'"'"']/, "")
                sub(/ *#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
                print; exit
            }
        ' "$data_secrets_file")
        if [ -n "$lvalue" ]; then echo "$lvalue"; return 0; fi
        echo "$default"; return 3
    fi

    local value="" yq_bin
    if yq_bin="$(_nwp_yq_bin)"; then
        # Build a yq expression from the dotted path with each segment quoted,
        # so keys containing '-' or digits resolve correctly.
        local expr="" seg
        local IFS_SAVE="$IFS"; IFS='.'
        for seg in $path; do expr="${expr}[\"${seg}\"]"; done
        IFS="$IFS_SAVE"
        value="$("$yq_bin" eval ".${expr}" "$data_secrets_file" 2>/dev/null || true)"
        [ "$value" = "null" ] && value=""
    fi
    if [ -z "$value" ]; then
        value="$(_nwp_yaml_deep_awk "$data_secrets_file" "$path")"
    fi

    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi
    echo "$default"
    return 3
}

# Get nested data secret (from .secrets.data.yml)
# Usage: get_data_secret_nested "section.subsection.key" "default_value"
get_data_secret_nested() {
    local path="$1"
    local default="$2"
    local data_secrets_file="${PROJECT_ROOT}/.secrets.data.yml"

    if [ "${AI_CONTEXT:-}" = "true" ]; then
        echo "[SECURITY WARNING] Data secret accessed in AI context: $path" >&2
    fi

    if [ ! -f "$data_secrets_file" ]; then
        echo "$default"
        return
    fi

    local depth=$(echo "$path" | tr -cd '.' | wc -c)

    if [ "$depth" -eq 1 ]; then
        get_data_secret "$path" "$default"
        return
    fi

    local section="${path%%.*}"
    local rest="${path#*.}"
    local subsection="${rest%%.*}"
    local key="${rest#*.}"

    local value=$(awk -v section="$section" -v subsection="$subsection" -v key="$key" '
        $0 ~ "^" section ":" { in_section = 1; next }
        in_section && /^[a-zA-Z]/ && !/^  / { in_section = 0 }
        in_section && $0 ~ "^  " subsection ":" { in_subsection = 1; next }
        in_subsection && /^  [a-zA-Z]/ && !/^    / { in_subsection = 0 }
        in_subsection && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$data_secrets_file")

    if [ -n "$value" ] && [ "$value" != "" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Get nested secret value from .secrets.yml (for deeper nesting like gitlab.server.ip)
# Usage: get_secret_nested "section.subsection.key" "default_value"
get_secret_nested() {
    local path="$1"
    local default="$2"
    local secrets_file="${PROJECT_ROOT}/.secrets.yml"

    if [ ! -f "$secrets_file" ]; then
        echo "$default"
        return
    fi

    # Count depth
    local depth=$(echo "$path" | tr -cd '.' | wc -c)

    if [ "$depth" -eq 1 ]; then
        # Simple section.key
        get_secret "$path" "$default"
        return
    fi

    # For section.subsection.key format
    local section="${path%%.*}"
    local rest="${path#*.}"
    local subsection="${rest%%.*}"
    local key="${rest#*.}"

    local value=$(awk -v section="$section" -v subsection="$subsection" -v key="$key" '
        $0 ~ "^" section ":" { in_section = 1; next }
        in_section && /^[a-zA-Z]/ && !/^  / { in_section = 0 }
        in_section && $0 ~ "^  " subsection ":" { in_subsection = 1; next }
        in_subsection && /^  [a-zA-Z]/ && !/^    / { in_subsection = 0 }
        in_subsection && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$secrets_file")

    if [ -n "$value" ] && [ "$value" != "" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Get setting value from nwp.yml with fallback
# Usage: get_setting "section.key" "default_value"
# Example: get_setting "php_settings.memory_limit" "512M"
get_setting() {
    local path="$1"
    local default="$2"
    local config_file="${PROJECT_ROOT}/nwp.yml"

    if [ ! -f "$config_file" ]; then
        echo "$default"
        return
    fi

    # Parse section.key format
    local section="${path%%.*}"
    local key="${path#*.}"

    # Special handling for settings section
    if [ "$section" == "settings" ] || [ "$section" == "$key" ]; then
        # Direct settings lookup
        local value=$(awk -v key="$key" '
            /^settings:/ { in_settings = 1; next }
            in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
            in_settings && $0 ~ "^  " key ":" {
                sub("^  " key ": *", "")
                gsub(/["'"'"']/, "")
                sub(/ *#.*$/, "")
                gsub(/^[ \t]+|[ \t]+$/, "")
                print
                exit
            }
        ' "$config_file")
    else
        # Nested settings lookup (e.g., php_settings.memory_limit)
        local value=$(awk -v section="$section" -v key="$key" '
            /^settings:/ { in_settings = 1; next }
            in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
            in_settings && $0 ~ "^  " section ":" { in_section = 1; next }
            in_section && /^  [a-zA-Z]/ && !/^    / { in_section = 0 }
            in_section && $0 ~ "^    " key ":" {
                sub("^    " key ": *", "")
                gsub(/["'"'"']/, "")
                sub(/ *#.*$/, "")
                gsub(/^[ \t]+|[ \t]+$/, "")
                print
                exit
            }
        ' "$config_file")
    fi

    if [ -n "$value" ] && [ "$value" != "" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

################################################################################
# Environment Detection Functions
################################################################################

# Get environment type from site name (NWP naming convention)
# Usage: get_env_type_from_name "sitename"
# Returns: local, dev, stage, prod
get_env_type_from_name() {
    local site="$1"

    if [[ "$site" =~ -stg$ ]]; then
        echo "stage"
    elif [[ "$site" =~ _prod$ ]]; then
        echo "prod"
    else
        echo "local"
    fi
}

# Get base site name (without environment suffix)
# Usage: get_base_name "sitename-stg" -> "sitename"
get_base_name() {
    local site="$1"
    echo "$site" | sed -E 's/[-_](stg|prod)$//'
}

# Resolve the site name from a directory path (v1 or v2 aware).
#
# v1 (flat):   sites/<name>/         → site name = <name>
# v2 (nested): sites/<name>/<env>/   → site name = <name>, not <env>
#
# Without this helper, $(basename "$install_dir") returns "dev" / "stg" /
# "prod" / "live" for every v2 site, which collides across all v2 sites
# in nwp.yml and breaks DNS pre-registration. Found 2026-05-20 during the
# nwt system-test exercise.
#
# Usage: get_site_name_from_dir "/path/to/sites/nwt/dev" → "nwt"
get_site_name_from_dir() {
    local dir="$1"
    [[ -z "$dir" ]] && return 1
    local leaf parent grandparent
    leaf=$(basename "$dir")
    parent=$(dirname "$dir")
    grandparent=$(basename "$(dirname "$parent")")

    case "$leaf" in
        dev|stg|prod|live)
            # v2 layout if grandparent is "sites"
            if [[ "$grandparent" == "sites" ]]; then
                basename "$parent"
                return 0
            fi
            ;;
    esac
    echo "$leaf"
}

# Get Drupal environment from a running DDEV site
# Usage: get_drupal_environment "sitename"
# Returns: local, dev, stage, prod, ci, or "unknown"
get_drupal_environment() {
    local site="$1"
    local site_path=""

    # Determine site path
    if [ -d "$site" ]; then
        site_path="$site"
    elif [ -d "${PROJECT_ROOT}/sites/${site}" ]; then
        site_path="${PROJECT_ROOT}/sites/${site}"
    else
        # Fallback to name-based detection
        get_env_type_from_name "$site"
        return
    fi

    # Check if DDEV is running for this site
    local ddev_status=$(cd "$site_path" && ddev describe 2>/dev/null | grep -c "OK" || echo "0")

    if [ "$ddev_status" -gt 0 ]; then
        # Get environment from Drupal settings
        local drupal_env=$(cd "$site_path" && ddev drush php-eval "echo \Drupal\Core\Site\Settings::get('environment', 'unknown');" 2>/dev/null || echo "")
        if [ -n "$drupal_env" ] && [ "$drupal_env" != "unknown" ]; then
            echo "$drupal_env"
            return
        fi
    fi

    # Fallback to name-based detection
    get_env_type_from_name "$(basename "$site_path")"
}

# Get environment indicator color for terminal output
# Usage: get_env_color "environment"
# Returns: ANSI color code
get_env_color() {
    local env="$1"

    case "$env" in
        prod|production)
            echo "\033[0;31m"  # Red
            ;;
        stage|staging)
            echo "\033[1;33m"  # Yellow
            ;;
        dev|development)
            echo "\033[0;32m"  # Green
            ;;
        local)
            echo "\033[0;34m"  # Blue
            ;;
        ci)
            echo "\033[0;35m"  # Purple
            ;;
        *)
            echo "\033[0;37m"  # Gray
            ;;
    esac
}

# Print environment status with color coding
# Usage: print_env_status "sitename" "environment"
print_env_status() {
    local site="$1"
    local env="$2"
    local color=$(get_env_color "$env")
    local NC=$'\033[0m'

    printf "  %-20s ${color}[%s]${NC}\n" "$site" "$env"
}

# Get environment label for display (uppercase, formatted)
# Usage: get_env_label "stage" -> "STAGING"
get_env_label() {
    local env="$1"

    case "$env" in
        prod)
            echo "PRODUCTION"
            ;;
        stage|stg)
            echo "STAGING"
            ;;
        live)
            echo "LIVE"
            ;;
        dev)
            echo "DEVELOPMENT"
            ;;
        local)
            echo "LOCAL"
            ;;
        ci)
            echo "CI"
            ;;
        *)
            echo "$env" | tr '[:lower:]' '[:upper:]'
            ;;
    esac
}

# Get environment display label (Title Case, formatted)
# Usage: get_env_display_label "prod" -> "Production"
get_env_display_label() {
    local env="$1"

    case "$env" in
        prod)
            echo "Production"
            ;;
        stage|stg)
            echo "Staging"
            ;;
        live)
            echo "Live"
            ;;
        dev)
            echo "Development"
            ;;
        local)
            echo "Local"
            ;;
        ci)
            echo "CI"
            ;;
        *)
            # Capitalize first letter
            echo "${env^}"
            ;;
    esac
}

################################################################################
# Migration Functions
################################################################################

# Setup migration folder structure for a site
# Usage: setup_migration_folder "/path/to/site" ["source_type"]
# Creates: migration/source/, migration/database/, migration/README.md
setup_migration_folder() {
    local site_dir="$1"
    local source_type="${2:-other}"
    local migration_dir="$site_dir/migration"

    # Check if site directory exists
    if [ ! -d "$site_dir" ]; then
        print_error "Site directory does not exist: $site_dir"
        return 1
    fi

    # Check if migration folder already exists
    if [ -d "$migration_dir" ]; then
        print_warning "Migration folder already exists: $migration_dir"
        return 0
    fi

    # Create migration directory structure
    print_info "Creating migration folder structure..."
    mkdir -p "$migration_dir/source"
    mkdir -p "$migration_dir/database"

    # Create README with instructions
    cat > "$migration_dir/README.md" << 'MIGRATION_README'
# Migration Folder

This folder is prepared for importing content from an existing site.

## Directory Structure

- `source/` - Place your source site files here
- `database/` - Place SQL database dumps here

## Next Steps

1. **Copy source files**: Copy your existing site into `source/`
   - For Drupal: Copy the entire Drupal root
   - For WordPress: Copy wp-content and wp-config.php
   - For static HTML: Copy all HTML/CSS/JS files

2. **Copy database**: Place SQL dump in `database/`
   - Name the file: `database.sql` or `source.sql`

3. **Analyze**: Run migration analysis
   ```bash
   ./migration.sh analyze <sitename>
   ```

4. **Prepare**: Set up migration modules
   ```bash
   ./migration.sh prepare <sitename>
   ```

5. **Run**: Execute the migration
   ```bash
   ./migration.sh run <sitename>
   ```

6. **Verify**: Check migration results
   ```bash
   ./migration.sh verify <sitename>
   ```

## Supported Source Types

| Type | Detection | Migration Method |
|------|-----------|------------------|
| drupal7 | `includes/bootstrap.inc` | Migrate Drupal module |
| drupal8/9/10 | `core/lib/Drupal.php` | Upgrade path |
| wordpress | `wp-config.php` | WordPress Migrate module |
| joomla | `configuration.php` | Custom migration |
| html | `index.html` | migrate_source_html |
| other | Manual | Custom migration needed |

## Tips

- Always backup your source before migrating
- Test migrations on a development copy first
- Check `/admin/reports/dblog` for migration errors
- Use `drush migrate:status` to monitor progress

MIGRATION_README

    print_status "OK" "Migration folder created: $migration_dir"
    return 0
}

# Check if a site has a migration folder
# Usage: has_migration_folder "/path/to/site"
# Returns: 0 if exists, 1 if not
has_migration_folder() {
    local site_dir="$1"
    [ -d "$site_dir/migration" ] && return 0
    return 1
}

# Remove migration folder from a site
# Usage: remove_migration_folder "/path/to/site"
remove_migration_folder() {
    local site_dir="$1"
    local migration_dir="$site_dir/migration"

    if [ ! -d "$migration_dir" ]; then
        print_info "No migration folder to remove"
        return 0
    fi

    # Check if migration folder has content
    if [ -n "$(ls -A "$migration_dir/source" 2>/dev/null)" ] || \
       [ -n "$(ls -A "$migration_dir/database" 2>/dev/null)" ]; then
        print_warning "Migration folder contains files. Remove manually if needed: $migration_dir"
        return 1
    fi

    rm -rf "$migration_dir"
    print_status "OK" "Migration folder removed"
    return 0
}

# Export functions for use in subshells
export -f get_secret
export -f get_secret_nested
export -f get_infra_secret
export -f get_data_secret
export -f get_data_secret_nested
export -f get_setting
export -f get_env_type_from_name
export -f get_base_name
export -f get_site_name_from_dir
export -f get_drupal_environment
export -f get_env_color
export -f print_env_status
export -f get_env_label
export -f setup_migration_folder
export -f has_migration_folder
export -f remove_migration_folder

# F23 Phase 6: project resolver exports
if declare -F resolve_project >/dev/null; then
    export -f resolve_project
    export -f find_project_from_cwd
    export -f resolve_site_config
    export -f get_backup_dir
    export -f get_site_config_value
    export -f discover_sites
fi
