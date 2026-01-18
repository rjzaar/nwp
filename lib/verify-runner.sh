#!/bin/bash
################################################################################
# NWP Verification Runner Library
#
# Machine execution infrastructure for NWP verification system.
# Provides helper functions for running machine-verifiable tests as defined
# in .verification.yml.
#
# This library is sourced by verify.sh for --run mode and provides:
#   - Site query functions (from test-nwp.sh)
#   - 5-Layer YAML Protection (ADR-0009 - CRITICAL)
#   - Test site lifecycle management
#   - Command execution framework
#   - YAML parsing helpers for verification
#   - Result tracking and badge generation
#
# Source this file: source "$PROJECT_ROOT/lib/verify-runner.sh"
#
# Required Variables (set by caller):
#   PROJECT_ROOT or VERIFY_PROJECT_ROOT - Path to NWP project root
#
# Dependencies:
#   lib/ui.sh - For color output functions (optional, has fallbacks)
#
# Reference:
#   - ADR-0009: Five-Layer YAML Protection System
#   - P50: Layered Verification System
#   - test-nwp.sh lines 98-318 for original helper functions
################################################################################

# Note: We don't use set -e here because this library may be sourced
# and we want tests to continue even on failures
# We also don't use set -u because some variables may be initialized later

# Determine paths
VERIFY_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$VERIFY_RUNNER_DIR/.." && pwd)}"

# Make PROJECT_ROOT available if not set
PROJECT_ROOT="${PROJECT_ROOT:-$VERIFY_PROJECT_ROOT}"

# Source UI library for colors if available
if [[ -f "$VERIFY_PROJECT_ROOT/lib/ui.sh" ]]; then
    source "$VERIFY_PROJECT_ROOT/lib/ui.sh"
else
    # Minimal fallback colors
    if [[ -t 1 ]]; then
        RED=$'\033[0;31m'
        GREEN=$'\033[0;32m'
        YELLOW=$'\033[1;33m'
        BLUE=$'\033[0;34m'
        CYAN=$'\033[0;36m'
        NC=$'\033[0m'
        BOLD=$'\033[1m'
        DIM=$'\033[2m'
    else
        RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC='' BOLD='' DIM=''
    fi
    print_error() { echo -e "${RED}ERROR:${NC} $1" >&2; }
    print_info() { echo -e "${BLUE}INFO:${NC} $1"; }
    print_warning() { echo -e "${YELLOW}WARNING:${NC} $1"; }
    print_success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
fi

################################################################################
# CONFIGURATION DEFAULTS
################################################################################

VERIFY_TEST_PREFIX="${VERIFY_TEST_PREFIX:-verify-test}"
VERIFY_LOG_DIR="${VERIFY_LOG_DIR:-$VERIFY_PROJECT_ROOT/.logs/verification}"
VERIFY_PRESERVE_ON_FAILURE="${VERIFY_PRESERVE_ON_FAILURE:-true}"
VERIFY_CLEANUP_ON_SUCCESS="${VERIFY_CLEANUP_ON_SUCCESS:-true}"
VERIFY_CONFIG_FILE="${VERIFY_CONFIG_FILE:-$VERIFY_PROJECT_ROOT/nwp.yml}"
VERIFY_YAML_FILE="${VERIFY_YAML_FILE:-$VERIFY_PROJECT_ROOT/.verification.yml}"
VERIFY_DEFAULT_TIMEOUT="${VERIFY_DEFAULT_TIMEOUT:-300}"

# Execution state
VERIFY_TESTS_RUN=0
VERIFY_TESTS_PASSED=0
VERIFY_TESTS_FAILED=0
VERIFY_TESTS_SKIPPED=0
VERIFY_TESTS_WARNED=0
declare -a VERIFY_FAILED_ITEMS=()
declare -a VERIFY_PASSED_ITEMS=()
declare -a VERIFY_WARNED_ITEMS=()

################################################################################
# SECTION 1: Logging Functions
################################################################################

#######################################
# Initialize logging
# Creates log directory and sets up log file
#######################################
init_verify_log() {
    mkdir -p "$VERIFY_LOG_DIR"
    VERIFY_LOG_FILE="$VERIFY_LOG_DIR/verify-$(date +%Y%m%d-%H%M%S).log"
    echo "[$(date -Iseconds)] Verification run started" >> "$VERIFY_LOG_FILE"
    echo "Log file: $VERIFY_LOG_FILE"
}

#######################################
# Log a message with timestamp and level
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR, DEBUG)
#   $2 - Message
#######################################
verify_log() {
    local level="${1:-INFO}"
    local message="$2"
    # Only log if VERIFY_LOG_FILE is set
    if [[ -n "${VERIFY_LOG_FILE:-}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$VERIFY_LOG_FILE"
    fi
}

################################################################################
# SECTION 2: Site Query Functions (from test-nwp.sh lines 253-318)
################################################################################

#######################################
# Check if a site exists (has directory and DDEV config)
# Arguments:
#   $1 - Site name (supports both "sitename" and "sites/sitename" formats)
# Returns:
#   0 if site exists with valid DDEV config, 1 otherwise
#######################################
site_exists() {
    local site="$1"
    local site_name="${site#sites/}"  # Strip sites/ prefix if present

    # Check sites/ subdirectory first (standard location)
    if [[ -d "$VERIFY_PROJECT_ROOT/sites/$site_name" ]] && \
       [[ -f "$VERIFY_PROJECT_ROOT/sites/$site_name/.ddev/config.yaml" ]]; then
        return 0
    fi

    # Fall back to root directory (legacy support)
    if [[ -d "$VERIFY_PROJECT_ROOT/$site_name" ]] && \
       [[ -f "$VERIFY_PROJECT_ROOT/$site_name/.ddev/config.yaml" ]]; then
        return 0
    fi

    return 1
}

#######################################
# Check if a site's DDEV service is running
# Arguments:
#   $1 - Site name
# Returns:
#   0 if DDEV is running, 1 otherwise
#######################################
site_is_running() {
    local site="$1"
    local site_name="${site#sites/}"
    local site_path=""

    # Find site path
    if [[ -d "$VERIFY_PROJECT_ROOT/sites/$site_name" ]]; then
        site_path="$VERIFY_PROJECT_ROOT/sites/$site_name"
    elif [[ -d "$VERIFY_PROJECT_ROOT/$site_name" ]]; then
        site_path="$VERIFY_PROJECT_ROOT/$site_name"
    else
        return 1
    fi

    # Check DDEV status
    (cd "$site_path" && ddev describe >/dev/null 2>&1)
    return $?
}

#######################################
# Check if Drush works for a site (with 3-attempt retry logic)
# Arguments:
#   $1 - Site name
#   $2 - Max retry attempts (default: 3)
# Returns:
#   0 if drush works, 1 otherwise
#######################################
drush_works() {
    local site="$1"
    local max_attempts="${2:-3}"
    local site_name="${site#sites/}"
    local site_path=""
    local attempt=1

    # Find site path
    if [[ -d "$VERIFY_PROJECT_ROOT/sites/$site_name" ]]; then
        site_path="$VERIFY_PROJECT_ROOT/sites/$site_name"
    elif [[ -d "$VERIFY_PROJECT_ROOT/$site_name" ]]; then
        site_path="$VERIFY_PROJECT_ROOT/$site_name"
    else
        return 1
    fi

    # Retry loop with 2-second delays (matching test-nwp.sh)
    while [[ $attempt -le $max_attempts ]]; do
        if (cd "$site_path" && ddev drush status >/dev/null 2>&1); then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            sleep 2  # Wait 2 seconds before retry
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

#######################################
# Check if backup exists for a site
# Arguments:
#   $1 - Site name
# Returns:
#   0 if backups exist, 1 otherwise
#######################################
backup_exists() {
    local site="$1"
    local site_name="${site#sites/}"  # Extract just the site name

    [[ -d "$VERIFY_PROJECT_ROOT/sitebackups/$site_name" ]] && \
        [[ -n "$(ls -A "$VERIFY_PROJECT_ROOT/sitebackups/$site_name" 2>/dev/null)" ]]
}

#######################################
# Get the resolved path to a site directory
# Arguments:
#   $1 - Site name
# Outputs:
#   Full path to site directory
# Returns:
#   0 if found, 1 if not found
#######################################
get_site_path() {
    local site="$1"
    local site_name="${site#sites/}"

    if [[ -d "$VERIFY_PROJECT_ROOT/sites/$site_name" ]]; then
        echo "$VERIFY_PROJECT_ROOT/sites/$site_name"
        return 0
    elif [[ -d "$VERIFY_PROJECT_ROOT/$site_name" ]]; then
        echo "$VERIFY_PROJECT_ROOT/$site_name"
        return 0
    fi

    return 1
}

################################################################################
# SECTION 3: Five-Layer YAML Protection System (ADR-0009 - CRITICAL)
#
# This protection was implemented after the January 2026 data loss incident.
# All AWK operations on critical YAML files MUST use this pattern.
#
# Layer 1: Store original line count for validation
# Layer 2: Use mktemp for atomic write (prevents race conditions)
# Layer 3: Validate AWK output is not empty
# Layer 4: Sanity check - prevent removing too many lines
# Layer 5: Atomic move (only if all validations pass)
################################################################################

#######################################
# Perform atomic YAML update with 5-layer protection
# This is the REQUIRED pattern for all AWK operations on nwp.yml
#
# Arguments:
#   $1 - YAML file path
#   $2 - AWK pattern/script
#   $3 - Maximum lines to remove (default: 100)
# Returns:
#   0 on success, 1 on failure (original file unchanged)
#######################################
atomic_yaml_update() {
    local file="$1"
    local awk_pattern="$2"
    local max_lines_removed="${3:-100}"

    # Validate file exists
    if [[ ! -f "$file" ]]; then
        verify_log "ERROR" "File not found: $file"
        return 1
    fi

    # LAYER 1: Store original line count for validation
    local original_lines
    original_lines=$(wc -l < "$file") || {
        verify_log "ERROR" "Failed to count lines in $file"
        return 1
    }

    # LAYER 2: Use mktemp for atomic write (secure, unique temp file)
    local tmpfile
    tmpfile=$(mktemp "${file}.XXXXXX") || {
        verify_log "ERROR" "Failed to create temporary file for $file"
        return 1
    }

    # Ensure cleanup on any exit
    trap "rm -f '$tmpfile' 2>/dev/null" RETURN

    # LAYER 3: Perform AWK operation
    if ! awk "$awk_pattern" "$file" > "$tmpfile" 2>/dev/null; then
        verify_log "ERROR" "AWK operation failed on $file"
        rm -f "$tmpfile"
        return 1
    fi

    # LAYER 4: Validate output is not empty
    if [[ ! -s "$tmpfile" ]]; then
        verify_log "ERROR" "AWK produced empty output - aborting operation on $file"
        verify_log "WARN" "This may indicate duplicate entries or AWK script error"
        rm -f "$tmpfile"
        return 1
    fi

    # LAYER 5: Sanity check - prevent large deletions
    local new_lines
    new_lines=$(wc -l < "$tmpfile")
    local lines_removed=$((original_lines - new_lines))

    if [[ $lines_removed -gt $max_lines_removed ]]; then
        verify_log "ERROR" "Would remove $lines_removed lines (>$max_lines_removed) from $file"
        verify_log "WARN" "This may indicate a bug. Original file unchanged."
        rm -f "$tmpfile"
        return 1
    fi

    # All validations passed - atomic move
    if ! mv "$tmpfile" "$file"; then
        verify_log "ERROR" "Failed to update $file (move operation failed)"
        rm -f "$tmpfile"
        return 1
    fi

    verify_log "INFO" "YAML update successful: removed $lines_removed lines"
    return 0
}

#######################################
# Clean up YAML block with 5-layer protection (convenience wrapper)
# Arguments:
#   $1 - YAML file path
#   $2 - Block pattern to remove (e.g., site name)
# Returns:
#   0 on success, 1 on failure
#######################################
atomic_yaml_cleanup() {
    local file="$1"
    local pattern="$2"

    if ! grep -q "^  ${pattern}:" "$file" 2>/dev/null; then
        verify_log "INFO" "Pattern not found in YAML, nothing to clean: $pattern"
        return 0
    fi

    verify_log "INFO" "Removing YAML block: $pattern"

    local awk_script='
        $0 ~ "^  '"$pattern"':" { skip=1; next }
        skip && /^  [a-z]/ && !/^    / { skip=0 }
        !skip
    '

    atomic_yaml_update "$file" "$awk_script" 50
}

################################################################################
# SECTION 4: Test Site Lifecycle Management
################################################################################

#######################################
# Pre-configure DDEV hostnames to avoid sudo prompts during tests
# Arguments:
#   $1 - Site name prefix
# Returns:
#   0 on success
#######################################
preconfigure_ddev_hostnames() {
    local prefix="$1"

    verify_log "INFO" "Pre-configuring DDEV hostnames for: $prefix"

    # Configure common test hostnames
    sudo ddev hostname "${prefix}.ddev.site" 127.0.0.1 2>/dev/null || {
        verify_log "WARN" "Could not configure hostname (may require manual sudo)"
    }
    sudo ddev hostname "${prefix}_copy.ddev.site" 127.0.0.1 2>/dev/null || true
    sudo ddev hostname "${prefix}_files.ddev.site" 127.0.0.1 2>/dev/null || true
    sudo ddev hostname "${prefix}-stg.ddev.site" 127.0.0.1 2>/dev/null || true

    return 0
}

#######################################
# Create a test site for verification
# Arguments:
#   $1 - Site name prefix (default: VERIFY_TEST_PREFIX)
#   $2 - Recipe (default: d)
# Outputs:
#   Created site name
# Returns:
#   0 on success, 1 on failure
#######################################
create_test_site() {
    local prefix="${1:-$VERIFY_TEST_PREFIX}"
    local recipe="${2:-d}"

    verify_log "INFO" "Creating test site: $prefix with recipe: $recipe"

    # Pre-configure DDEV hostname to avoid sudo prompts
    preconfigure_ddev_hostnames "$prefix"

    # Create site using install.sh
    if [[ -x "$VERIFY_PROJECT_ROOT/scripts/commands/install.sh" ]]; then
        if ! "$VERIFY_PROJECT_ROOT/scripts/commands/install.sh" "$recipe" "$prefix" --auto >> "${VERIFY_LOG_FILE:-/dev/null}" 2>&1; then
            verify_log "ERROR" "Failed to create test site: $prefix"
            return 1
        fi
    else
        verify_log "ERROR" "install.sh not found or not executable"
        return 1
    fi

    # Verify site is running
    if ! site_is_running "$prefix"; then
        verify_log "ERROR" "Test site created but not running: $prefix"
        return 1
    fi

    verify_log "INFO" "Test site created successfully: $prefix"
    echo "$prefix"
    return 0
}

#######################################
# Clean up test site - stop DDEV, remove directories, clean nwp.yml
# Arguments:
#   $1 - Site name prefix
#   $2 - Preserve on failure flag (default: VERIFY_PRESERVE_ON_FAILURE)
# Returns:
#   0 on success
#######################################
cleanup_test_site() {
    local prefix="$1"
    local preserve="${2:-$VERIFY_PRESERVE_ON_FAILURE}"

    verify_log "INFO" "Cleaning up test site: $prefix (preserve_on_failure=$preserve)"

    # Stop DDEV
    if [[ -d "$VERIFY_PROJECT_ROOT/sites/$prefix" ]]; then
        (cd "$VERIFY_PROJECT_ROOT/sites/$prefix" && ddev stop 2>/dev/null) || true
        verify_log "INFO" "Stopped DDEV for: $prefix"
    fi

    # Check if we should preserve due to failures
    if [[ "$preserve" = "true" ]] && [[ -n "${VERIFY_FAILED_ITEMS[*]:-}" ]]; then
        verify_log "INFO" "Preserving test site due to failures: $prefix"
        echo "Test site preserved for debugging: sites/$prefix"
        return 0
    fi

    # Remove site directory
    if [[ -d "$VERIFY_PROJECT_ROOT/sites/$prefix" ]]; then
        rm -rf "$VERIFY_PROJECT_ROOT/sites/$prefix"
        verify_log "INFO" "Removed site directory: sites/$prefix"
    fi

    # Remove backups
    if [[ -d "$VERIFY_PROJECT_ROOT/sitebackups/$prefix" ]]; then
        rm -rf "$VERIFY_PROJECT_ROOT/sitebackups/$prefix"
        verify_log "INFO" "Removed backup directory: sitebackups/$prefix"
    fi

    # Remove from nwp.yml with 5-layer protection
    if [[ -f "$VERIFY_CONFIG_FILE" ]] && grep -q "^  ${prefix}:" "$VERIFY_CONFIG_FILE" 2>/dev/null; then
        atomic_yaml_cleanup "$VERIFY_CONFIG_FILE" "$prefix"
    fi

    return 0
}

#######################################
# Clean up all test sites matching the verification prefix
# Returns:
#   0 on success
#######################################
cleanup_all_test_sites() {
    print_info "Cleaning up all test sites with prefix: $VERIFY_TEST_PREFIX..."

    # Stop and remove all test site directories
    if [[ -d "$VERIFY_PROJECT_ROOT/sites" ]]; then
        for site in "$VERIFY_PROJECT_ROOT/sites/${VERIFY_TEST_PREFIX}"*; do
            if [[ -d "$site" ]]; then
                local site_name
                site_name=$(basename "$site")
                print_info "Cleaning up: $site_name"
                cleanup_test_site "$site_name" "false"  # Force cleanup
            fi
        done
    fi

    print_success "Cleanup complete"
    return 0
}

################################################################################
# SECTION 5: Execution Framework
################################################################################

#######################################
# Execute a command with timeout and variable substitution
# Replaces {site} placeholder with actual site name
# Arguments:
#   $1 - Command to execute
#   $2 - Expected exit code (default: 0)
#   $3 - Timeout in seconds (default: VERIFY_DEFAULT_TIMEOUT)
#   $4 - Site name for {site} substitution (optional)
# Returns:
#   Command exit code, 124 on timeout
#######################################
execute_check() {
    local command="$1"
    local expect_exit="${2:-0}"
    local timeout_secs="${3:-${VERIFY_DEFAULT_TIMEOUT:-60}}"
    local site="${4:-}"

    # Variable substitution - replace {site} with actual site name
    if [[ -n "$site" ]]; then
        command="${command//\{site\}/$site}"
    fi

    verify_log "INFO" "Executing: $command (expect_exit=$expect_exit, timeout=${timeout_secs}s)"

    local start_time output exit_code
    start_time=$(date +%s)

    # Execute with timeout
    output=$(timeout "$timeout_secs" bash -c "$command" 2>&1)
    exit_code=$?

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Handle timeout
    if [[ "$exit_code" = "124" ]]; then
        verify_log "ERROR" "TIMEOUT after ${timeout_secs}s"
        return 124
    fi

    # Check expected exit code
    if [[ "$exit_code" = "$expect_exit" ]]; then
        verify_log "INFO" "PASSED in ${duration}s (exit=$exit_code)"
        return 0
    else
        verify_log "ERROR" "FAILED in ${duration}s (exit=$exit_code, expected=$expect_exit)"
        verify_log "ERROR" "Output: $output"
        return 1
    fi
}

#######################################
# Log a test result with timestamp
# Arguments:
#   $1 - Test name
#   $2 - Result (pass/fail/skip/warn)
#   $3 - Message (optional)
#######################################
log_result() {
    local test_name="$1"
    local result="$2"
    local message="${3:-}"

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local log_line="[$timestamp] $result: $test_name"
    [[ -n "$message" ]] && log_line="$log_line - $message"

    # Output to console with colors
    case "$result" in
        pass|PASS)
            echo -e "${GREEN}[PASS]${NC} $test_name"
            ;;
        fail|FAIL)
            echo -e "${RED}[FAIL]${NC} $test_name"
            ;;
        skip|SKIP)
            echo -e "${YELLOW}[SKIP]${NC} $test_name"
            ;;
        warn|WARN)
            echo -e "${YELLOW}[WARN]${NC} $test_name"
            ;;
        *)
            echo "[$result] $test_name"
            ;;
    esac

    verify_log "INFO" "$log_line"
}

#######################################
# Run a test and capture result
# Arguments:
#   $1 - Test name
#   $2 - Test command
#   $3 - Expected result (pass/warn, default: pass)
# Returns:
#   0 if test matches expected, 1 otherwise
#######################################
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected="${3:-pass}"

    VERIFY_TESTS_RUN=$((VERIFY_TESTS_RUN + 1))

    if eval "$test_command" >> "${VERIFY_LOG_FILE:-/dev/null}" 2>&1; then
        # Command succeeded
        if [[ "$expected" == "warn" ]]; then
            VERIFY_TESTS_WARNED=$((VERIFY_TESTS_WARNED + 1))
            VERIFY_WARNED_ITEMS+=("$test_name")
            log_result "$test_name" "WARN" "expected warning, but passed"
            return 0
        else
            VERIFY_TESTS_PASSED=$((VERIFY_TESTS_PASSED + 1))
            VERIFY_PASSED_ITEMS+=("$test_name")
            log_result "$test_name" "PASS"
            return 0
        fi
    else
        # Command failed
        if [[ "$expected" == "warn" ]]; then
            VERIFY_TESTS_WARNED=$((VERIFY_TESTS_WARNED + 1))
            VERIFY_WARNED_ITEMS+=("$test_name")
            log_result "$test_name" "WARN" "expected behavior"
            return 0
        else
            VERIFY_TESTS_FAILED=$((VERIFY_TESTS_FAILED + 1))
            VERIFY_FAILED_ITEMS+=("$test_name")
            log_result "$test_name" "FAIL"
            return 1
        fi
    fi
}

################################################################################
# SECTION 6: YAML Parsing Helpers for Verification System
################################################################################

#######################################
# Get list of all feature IDs from verification file
# Arguments:
#   $1 - Verification file (optional, uses VERIFY_YAML_FILE)
# Outputs:
#   Feature IDs, one per line
#######################################
get_verification_features() {
    local file="${1:-$VERIFY_YAML_FILE}"

    if [[ ! -f "$file" ]]; then
        verify_log "ERROR" "Verification file not found: $file"
        return 1
    fi

    awk '
        /^  [a-z0-9_]+:$/ {
            id = $0
            gsub(/^  /, "", id)
            gsub(/:$/, "", id)
            if (id != "version") print id
        }
    ' "$file"
}

#######################################
# Get checklist items for a feature
# Arguments:
#   $1 - Feature ID
#   $2 - Verification file (optional)
# Outputs:
#   Checklist item text, one per line
#######################################
get_feature_items() {
    local feature="$1"
    local file="${2:-$VERIFY_YAML_FILE}"

    [[ ! -f "$file" ]] && return 1

    awk -v feature="$feature" '
        BEGIN { in_feature = 0; in_checklist = 0 }
        /^  [a-z0-9_]+:$/ {
            test = $0
            gsub(/^  /, "", test)
            gsub(/:$/, "", test)
            if (test == feature) {
                in_feature = 1
            } else if (in_feature) {
                exit
            }
        }
        in_feature && /^    checklist:/ {
            in_checklist = 1
            next
        }
        in_feature && in_checklist && /^      - text:/ {
            line = $0
            gsub(/^      - text: *"?/, "", line)
            gsub(/"$/, "", line)
            print line
        }
        in_feature && in_checklist && /^    [a-z]/ && !/^      / {
            exit
        }
    ' "$file"
}

#######################################
# Get machine verification checks for an item at a specific depth
# Arguments:
#   $1 - Feature ID
#   $2 - Item index (0-based)
#   $3 - Depth (1, 2, or 3 - default: 1)
#   $4 - Verification file (optional)
# Outputs:
#   Machine check commands, one per line
#######################################
get_machine_checks() {
    local feature="$1"
    local item_idx="$2"
    local depth="${3:-1}"
    local file="${4:-$VERIFY_YAML_FILE}"

    [[ ! -f "$file" ]] && return 1

    # Select the section based on depth
    local section
    case "$depth" in
        1) section="quick" ;;
        2) section="standard" ;;
        3) section="thorough" ;;
        *) section="quick" ;;
    esac

    awk -v feature="$feature" -v idx="$item_idx" -v section="$section" '
        BEGIN {
            in_feature = 0; in_checklist = 0; in_item = 0
            in_machine = 0; in_checks = 0; in_section = 0; in_commands = 0
            current_idx = -1
        }
        /^  [a-z0-9_]+:$/ {
            test = $0
            gsub(/^  /, "", test)
            gsub(/:$/, "", test)
            if (test == feature) {
                in_feature = 1
            } else if (in_feature) {
                exit
            }
        }
        in_feature && /^    checklist:/ {
            in_checklist = 1
            next
        }
        in_feature && in_checklist && /^      - text:/ {
            current_idx++
            if (current_idx == idx) {
                in_item = 1
            } else {
                in_item = 0
            }
            in_machine = 0; in_checks = 0; in_section = 0; in_commands = 0
        }
        in_item && /^        machine:/ {
            in_machine = 1
        }
        in_machine && /^          checks:/ {
            in_checks = 1
        }
        in_checks && $0 ~ "^            " section ":" {
            in_section = 1
        }
        in_section && /^              commands:/ {
            in_commands = 1
            next
        }
        in_commands && /^                - / {
            line = $0
            gsub(/^                - /, "", line)
            gsub(/^"/, "", line)
            gsub(/"$/, "", line)
            print line
        }
        in_commands && /^            [a-z]/ && !/^              / {
            in_commands = 0; in_section = 0
        }
    ' "$file"
}

#######################################
# Update machine verification state for a checklist item
# Arguments:
#   $1 - Feature ID
#   $2 - Item index (0-based)
#   $3 - Depth (1, 2, or 3)
#   $4 - State (passed/failed/pending)
#   $5 - Verification file (optional)
# Returns:
#   0 on success, 1 on failure
#######################################
update_machine_state() {
    local feature="$1"
    local item_idx="$2"
    local depth="$3"
    local state="$4"
    local file="${5:-$VERIFY_YAML_FILE}"

    [[ ! -f "$file" ]] && return 1

    local section timestamp
    case "$depth" in
        1) section="quick" ;;
        2) section="standard" ;;
        3) section="thorough" ;;
        *) section="quick" ;;
    esac

    timestamp=$(date -Iseconds)

    # Build AWK script to update the state
    local awk_script='
        BEGIN {
            in_feature = 0; in_checklist = 0; in_item = 0; in_section = 0
            current_idx = -1; updated = 0
        }
        /^  [a-z0-9_]+:$/ {
            test = $0
            gsub(/^  /, "", test)
            gsub(/:$/, "", test)
            if (test == "'"$feature"'") {
                in_feature = 1
            } else if (in_feature) {
                in_feature = 0; in_checklist = 0; in_item = 0
            }
        }
        in_feature && /^    checklist:/ {
            in_checklist = 1
            print; next
        }
        in_feature && in_checklist && /^      - text:/ {
            current_idx++
            if (current_idx == '"$item_idx"') {
                in_item = 1
            } else {
                in_item = 0
            }
            in_section = 0
        }
        in_item && $0 ~ "^            '"$section"':" {
            in_section = 1
            print; next
        }
        in_item && in_section && /^              state:/ {
            print "              state: '"$state"'"
            updated = 1; next
        }
        in_item && in_section && /^              last_run:/ {
            print "              last_run: \"'"$timestamp"'\""
            next
        }
        { print }
    '

    atomic_yaml_update "$file" "$awk_script" 20
}

#######################################
# Get feature name from verification file
# Arguments:
#   $1 - Feature ID
#   $2 - Verification file (optional)
# Outputs:
#   Feature name
#######################################
get_feature_name() {
    local feature="$1"
    local file="${2:-$VERIFY_YAML_FILE}"

    awk -v feature="$feature" '
        BEGIN { in_feature = 0 }
        /^  [a-z0-9_]+:$/ {
            test = $0
            gsub(/^  /, "", test)
            gsub(/:$/, "", test)
            if (test == feature) {
                in_feature = 1
            } else if (in_feature) {
                exit
            }
        }
        in_feature && /^    name:/ {
            line = $0
            gsub(/^    name: *"?/, "", line)
            gsub(/"$/, "", line)
            print line
            exit
        }
    ' "$file"
}

#######################################
# Get total checklist item count for a feature
# Arguments:
#   $1 - Feature ID
#   $2 - Verification file (optional)
# Outputs:
#   Item count
#######################################
get_feature_item_count() {
    local feature="$1"
    local file="${2:-$VERIFY_YAML_FILE}"

    get_feature_items "$feature" "$file" | wc -l
}

#######################################
# Get files associated with a feature
# Arguments:
#   $1 - Feature ID
#   $2 - Verification file (optional)
# Outputs:
#   File paths, one per line
#######################################
get_feature_files() {
    local feature="$1"
    local file="${2:-$VERIFY_YAML_FILE}"

    awk -v feature="$feature" '
        BEGIN { in_feature = 0; in_files = 0 }
        /^  [a-z0-9_]+:$/ {
            test = $0
            gsub(/^  /, "", test)
            gsub(/:$/, "", test)
            if (test == feature) {
                in_feature = 1
            } else if (in_feature) {
                exit
            }
        }
        in_feature && /^    files:/ {
            in_files = 1
            next
        }
        in_feature && in_files && /^      - / {
            line = $0
            gsub(/^      - /, "", line)
            print line
        }
        in_feature && in_files && /^    [a-z]/ && !/^      / {
            exit
        }
    ' "$file"
}

#######################################
# Check if an item has machine checks at the specified depth
# Arguments:
#   $1 - Feature ID
#   $2 - Item index (0-based)
#   $3 - Depth (1, 2, or 3)
#   $4 - Verification file (optional)
# Returns:
#   0 if checks exist, 1 otherwise
#######################################
has_machine_checks() {
    local feature="$1"
    local item_idx="$2"
    local depth="$3"
    local file="${4:-$VERIFY_YAML_FILE}"

    local checks
    checks=$(get_machine_checks "$feature" "$item_idx" "$depth" "$file")
    [[ -n "$checks" ]]
}

################################################################################
# SECTION 7: Result Tracking and Summary
################################################################################

#######################################
# Track a test result
# Arguments:
#   $1 - Feature ID
#   $2 - Item identifier
#   $3 - Result (passed/failed/skipped)
#   $4 - Duration in seconds (optional)
#######################################
track_result() {
    local feature="$1"
    local item_id="$2"
    local result="$3"
    local duration="${4:-0}"

    VERIFY_TESTS_RUN=$((VERIFY_TESTS_RUN + 1))

    case "$result" in
        passed)
            VERIFY_TESTS_PASSED=$((VERIFY_TESTS_PASSED + 1))
            VERIFY_PASSED_ITEMS+=("$feature:$item_id")
            ;;
        failed)
            VERIFY_TESTS_FAILED=$((VERIFY_TESTS_FAILED + 1))
            VERIFY_FAILED_ITEMS+=("$feature:$item_id")
            ;;
        skipped)
            VERIFY_TESTS_SKIPPED=$((VERIFY_TESTS_SKIPPED + 1))
            ;;
    esac

    verify_log "INFO" "Result: $feature:$item_id = $result (${duration}s)"
}

#######################################
# Get pass rate as percentage
# Outputs:
#   Pass rate (0-100)
#######################################
get_pass_rate() {
    if [[ $VERIFY_TESTS_RUN -eq 0 ]]; then
        echo "0"
        return
    fi
    echo $((VERIFY_TESTS_PASSED * 100 / VERIFY_TESTS_RUN))
}

#######################################
# Print summary of test results
#######################################
print_verify_summary() {
    local pass_rate
    pass_rate=$(get_pass_rate)

    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  Verification Summary${NC}"
    echo -e "${BOLD}================================================================${NC}"
    echo ""
    echo -e "  Tests Run:    $VERIFY_TESTS_RUN"
    echo -e "  ${GREEN}Passed:${NC}       $VERIFY_TESTS_PASSED"
    echo -e "  ${RED}Failed:${NC}       $VERIFY_TESTS_FAILED"
    echo -e "  ${YELLOW}Skipped:${NC}      $VERIFY_TESTS_SKIPPED"
    echo -e "  ${YELLOW}Warned:${NC}       $VERIFY_TESTS_WARNED"
    echo -e "  Pass Rate:    ${pass_rate}%"
    echo ""

    if [[ -n "${VERIFY_FAILED_ITEMS[*]:-}" ]]; then
        echo -e "  ${RED}${BOLD}Failed Items:${NC}"
        for item in "${VERIFY_FAILED_ITEMS[@]}"; do
            echo -e "    ${RED}-${NC} $item"
        done
        echo ""
    fi

    if [[ -n "${VERIFY_LOG_FILE:-}" ]]; then
        echo -e "  Log file: $VERIFY_LOG_FILE"
    fi
    echo ""
}

#######################################
# Reset verification state counters
#######################################
reset_verify_state() {
    VERIFY_TESTS_RUN=0
    VERIFY_TESTS_PASSED=0
    VERIFY_TESTS_FAILED=0
    VERIFY_TESTS_SKIPPED=0
    VERIFY_TESTS_WARNED=0
    VERIFY_FAILED_ITEMS=()
    VERIFY_PASSED_ITEMS=()
    VERIFY_WARNED_ITEMS=()
}

################################################################################
# SECTION 8: JUnit XML and Badge Generation
################################################################################

#######################################
# Generate JUnit XML from test results
# Arguments:
#   $1 - Output file (default: VERIFY_LOG_DIR/junit.xml)
# Outputs:
#   Path to generated file
#######################################
generate_junit_xml() {
    local output_file="${1:-$VERIFY_LOG_DIR/junit.xml}"

    mkdir -p "$(dirname "$output_file")"

    cat > "$output_file" << XMLHEADER
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="NWP Verification" tests="$VERIFY_TESTS_RUN" failures="$VERIFY_TESTS_FAILED" time="0">
XMLHEADER

    # Add test cases for passed items
    for item in "${VERIFY_PASSED_ITEMS[@]:-}"; do
        [[ -z "$item" ]] && continue
        local feature="${item%%:*}"
        local item_id="${item#*:}"
        echo "  <testcase classname=\"$feature\" name=\"$item_id\" time=\"0\"/>" >> "$output_file"
    done

    # Add test cases for failed items
    for item in "${VERIFY_FAILED_ITEMS[@]:-}"; do
        [[ -z "$item" ]] && continue
        local feature="${item%%:*}"
        local item_id="${item#*:}"
        cat >> "$output_file" << EOF
  <testcase classname="$feature" name="$item_id" time="0">
    <failure message="Verification failed"/>
  </testcase>
EOF
    done

    echo "</testsuites>" >> "$output_file"

    verify_log "INFO" "Generated JUnit XML: $output_file"
    echo "$output_file"
}

#######################################
# Calculate badge color based on percentage
# Arguments:
#   $1 - Percentage
#   $2 - Type (machine/human/full/issues)
# Outputs:
#   Color name
#######################################
get_badge_color() {
    local pct="$1"
    local type="${2:-machine}"

    case "$type" in
        machine)
            if [[ "$pct" -lt 50 ]]; then echo "red"
            elif [[ "$pct" -lt 80 ]]; then echo "yellow"
            else echo "brightgreen"
            fi
            ;;
        human|full)
            if [[ "$pct" -lt 25 ]]; then echo "red"
            elif [[ "$pct" -lt 60 ]]; then echo "yellow"
            else echo "green"
            fi
            ;;
        issues)
            if [[ "$pct" -gt 10 ]]; then echo "red"
            elif [[ "$pct" -gt 0 ]]; then echo "yellow"
            else echo "brightgreen"
            fi
            ;;
    esac
}

#######################################
# Generate .badges.json file
# Arguments:
#   $1 - Output file (default: PROJECT_ROOT/.badges.json)
#   $2 - Machine verification percentage
#   $3 - Human verification percentage
#   $4 - Full verification percentage
#   $5 - Open issues count
# Outputs:
#   Path to generated file
#######################################
generate_badges_json() {
    local output_file="${1:-$VERIFY_PROJECT_ROOT/.badges.json}"
    local machine_pct="${2:-0}"
    local human_pct="${3:-0}"
    local full_pct="${4:-0}"
    local issues="${5:-0}"

    local machine_color human_color full_color issues_color
    machine_color=$(get_badge_color "$machine_pct" "machine")
    human_color=$(get_badge_color "$human_pct" "human")
    full_color=$(get_badge_color "$full_pct" "full")
    issues_color=$(get_badge_color "$issues" "issues")

    local git_branch git_sha
    git_branch=$(git -C "$VERIFY_PROJECT_ROOT" branch --show-current 2>/dev/null || echo "unknown")
    git_sha=$(git -C "$VERIFY_PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")

    cat > "$output_file" << EOF
{
  "version": 1,
  "schemaVersion": 1,
  "generated": "$(date -Iseconds)",
  "pipeline": {
    "id": "${CI_PIPELINE_ID:-local}",
    "ref": "${CI_COMMIT_REF_NAME:-$git_branch}",
    "sha": "${CI_COMMIT_SHA:-$git_sha}"
  },
  "badges": {
    "verification_machine": {
      "label": "Machine Verified",
      "message": "${machine_pct}%",
      "color": "$machine_color"
    },
    "verification_human": {
      "label": "Human Verified",
      "message": "${human_pct}%",
      "color": "$human_color"
    },
    "verification_full": {
      "label": "Fully Verified",
      "message": "${full_pct}%",
      "color": "$full_color"
    },
    "issues_open": {
      "label": "Issues",
      "message": "${issues} open",
      "color": "$issues_color"
    }
  }
}
EOF

    verify_log "INFO" "Generated badges JSON: $output_file"
    echo "$output_file"
}

#######################################
# Print badge URLs for README
# Arguments:
#   $1 - Base URL for badges.json (optional)
#######################################
print_badge_urls() {
    local base_url="${1:-https://raw.githubusercontent.com/rjzaar/nwp/main/.badges.json}"

    echo "Badge URLs for README.md:"
    echo ""
    echo "Machine Verified:"
    echo "![Machine Verified](https://img.shields.io/badge/dynamic/json?url=$base_url&query=\$.badges.verification_machine.message&label=Machine%20Verified&color=brightgreen&logo=checkmarx)"
    echo ""
    echo "Human Verified:"
    echo "![Human Verified](https://img.shields.io/badge/dynamic/json?url=$base_url&query=\$.badges.verification_human.message&label=Human%20Verified&color=yellow&logo=statuspal)"
    echo ""
    echo "Fully Verified:"
    echo "![Fully Verified](https://img.shields.io/badge/dynamic/json?url=$base_url&query=\$.badges.verification_full.message&label=Fully%20Verified&color=green&logo=qualitybadge)"
    echo ""
}

################################################################################
# SECTION 9: Utility Functions
################################################################################

#######################################
# Calculate SHA256 hash for a list of files
# Arguments:
#   $1 - Newline-separated list of file paths (relative to PROJECT_ROOT)
# Outputs:
#   Combined hash
#######################################
calculate_file_hash() {
    local files="$1"
    local combined_hash=""

    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            local filepath="$VERIFY_PROJECT_ROOT/$file"
            if [[ -f "$filepath" ]]; then
                combined_hash+=$(sha256sum "$filepath" 2>/dev/null | cut -d' ' -f1)
            fi
        fi
    done <<< "$files"

    if [[ -n "$combined_hash" ]]; then
        echo -n "$combined_hash" | sha256sum | cut -d' ' -f1
    else
        echo ""
    fi
}

################################################################################
# Export functions for use in other scripts
################################################################################

export -f site_exists 2>/dev/null || true
export -f site_is_running 2>/dev/null || true
export -f drush_works 2>/dev/null || true
export -f backup_exists 2>/dev/null || true
export -f get_site_path 2>/dev/null || true
export -f atomic_yaml_update 2>/dev/null || true
export -f atomic_yaml_cleanup 2>/dev/null || true
export -f preconfigure_ddev_hostnames 2>/dev/null || true
export -f create_test_site 2>/dev/null || true
export -f cleanup_test_site 2>/dev/null || true
export -f cleanup_all_test_sites 2>/dev/null || true
export -f execute_check 2>/dev/null || true
export -f log_result 2>/dev/null || true
export -f run_test 2>/dev/null || true
export -f get_verification_features 2>/dev/null || true
export -f get_feature_items 2>/dev/null || true
export -f get_machine_checks 2>/dev/null || true
export -f update_machine_state 2>/dev/null || true
export -f get_feature_name 2>/dev/null || true
export -f get_feature_item_count 2>/dev/null || true
export -f get_feature_files 2>/dev/null || true
export -f has_machine_checks 2>/dev/null || true
export -f track_result 2>/dev/null || true
export -f get_pass_rate 2>/dev/null || true
export -f print_verify_summary 2>/dev/null || true
export -f reset_verify_state 2>/dev/null || true
export -f generate_junit_xml 2>/dev/null || true
export -f get_badge_color 2>/dev/null || true
export -f generate_badges_json 2>/dev/null || true
export -f print_badge_urls 2>/dev/null || true
export -f calculate_file_hash 2>/dev/null || true
