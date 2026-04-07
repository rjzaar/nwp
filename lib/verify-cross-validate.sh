#!/bin/bash
################################################################################
# NWP Cross-Validation Library
#
# Part of P51: AI-Powered Deep Verification (Phase 2)
#
# This library provides database verification and cross-validation functions
# to verify that NWP reporting commands return accurate data by checking
# against actual system state.
#
# Key Functions:
#   - capture_baseline() - Store values before operations
#   - compare_values() - Compare with tolerance support
#   - cross_validate_*() - Validate specific command outputs
#   - log_mismatch() - Record validation failures
#
# The 9 Live State Commands validated:
#   1. pl doctor - System environment checks
#   2. pl status - Site status (users, db size, health)
#   3. pl storage - File/database sizes
#   4. pl security-check - Security configuration
#   5. pl testos - Docker/PHP environment
#   6. pl seo-check - SEO configuration
#   7. pl badges - Coverage metrics
#   8. pl avc-moodle-status - Moodle integration
#   9. pl report - Site reports
#
# Source this file: source "$PROJECT_ROOT/lib/verify-cross-validate.sh"
#
# Dependencies:
#   - lib/verify-scenarios.sh (P51 Phase 1)
#   - lib/verify-runner.sh (P50 infrastructure)
#   - yq (YAML parsing)
#   - jq (JSON parsing)
#
# Reference:
#   - P51: AI-Powered Deep Verification
#   - docs/proposals/P51-ai-powered-verification.md Section 4
################################################################################

# Determine paths
CROSSVAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROSSVAL_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$CROSSVAL_LIB_DIR/.." && pwd)}"

# Make PROJECT_ROOT available if not set
PROJECT_ROOT="${PROJECT_ROOT:-$CROSSVAL_PROJECT_ROOT}"

# Source dependencies
if [[ -f "$CROSSVAL_PROJECT_ROOT/lib/verify-runner.sh" ]]; then
    source "$CROSSVAL_PROJECT_ROOT/lib/verify-runner.sh"
fi

if [[ -f "$CROSSVAL_PROJECT_ROOT/lib/verify-scenarios.sh" ]]; then
    source "$CROSSVAL_PROJECT_ROOT/lib/verify-scenarios.sh"
fi

# Configuration
CROSSVAL_LOG_DIR="${CROSSVAL_LOG_DIR:-$CROSSVAL_PROJECT_ROOT/.logs/verification}"
CROSSVAL_FINDINGS_FILE="${CROSSVAL_FINDINGS_FILE:-$CROSSVAL_LOG_DIR/cross-validation-findings.json}"

# Storage for baseline values
declare -A BASELINE_VALUES=()
declare -A CROSSVAL_ERRORS=()

################################################################################
# SECTION 1: Core Functions
################################################################################

#######################################
# Initialize cross-validation logging
# Creates the findings directory and file
#######################################
crossval_init() {
    mkdir -p "$CROSSVAL_LOG_DIR"

    # Initialize findings file
    cat > "$CROSSVAL_FINDINGS_FILE" << 'EOF'
{
  "generated_at": "",
  "findings": [],
  "summary": {
    "total_validations": 0,
    "passed": 0,
    "failed": 0,
    "warnings": 0
  }
}
EOF

    # Update timestamp
    local timestamp
    timestamp=$(date -Iseconds)
    if command -v jq &>/dev/null; then
        jq ".generated_at = \"$timestamp\"" "$CROSSVAL_FINDINGS_FILE" > "${CROSSVAL_FINDINGS_FILE}.tmp" && \
        mv "${CROSSVAL_FINDINGS_FILE}.tmp" "$CROSSVAL_FINDINGS_FILE"
    fi

    # Reset counters
    BASELINE_VALUES=()
    CROSSVAL_ERRORS=()
}

#######################################
# Capture a baseline value before an operation
# Arguments:
#   $1 - Variable name (key)
#   $2 - Command to capture value
#   $3 - Description (optional)
# Returns: 0 on success, 1 on failure
#######################################
capture_baseline() {
    local var_name="$1"
    local cmd="$2"
    local description="${3:-$var_name}"

    if [[ -z "$var_name" || -z "$cmd" ]]; then
        echo "ERROR: capture_baseline requires var_name and command" >&2
        return 1
    fi

    local value
    local exit_code

    value=$(eval "$cmd" 2>/dev/null)
    exit_code=$?

    if [[ $exit_code -eq 0 && -n "$value" ]]; then
        BASELINE_VALUES[$var_name]="$value"
        echo "  Baseline captured: $description = $value"
        return 0
    else
        echo "  WARNING: Failed to capture baseline for $description" >&2
        BASELINE_VALUES[$var_name]=""
        return 1
    fi
}

#######################################
# Compare two values with optional tolerance
# Arguments:
#   $1 - Expected value
#   $2 - Actual value
#   $3 - Tolerance (optional, default 0)
#        Can be absolute number or percentage (e.g., "5%")
# Returns: 0 if match, 1 if mismatch
#######################################
compare_values() {
    local expected="$1"
    local actual="$2"
    local tolerance="${3:-0}"

    # Handle empty values
    if [[ -z "$expected" && -z "$actual" ]]; then
        return 0
    fi

    if [[ -z "$expected" || -z "$actual" ]]; then
        return 1
    fi

    # Exact string match
    if [[ "$expected" == "$actual" ]]; then
        return 0
    fi

    # Try numeric comparison with tolerance
    if [[ "$expected" =~ ^-?[0-9]+\.?[0-9]*$ ]] && [[ "$actual" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        local diff
        local tol_value

        # Calculate absolute difference
        diff=$(echo "$expected - $actual" | bc -l 2>/dev/null | tr -d '-')

        # Handle percentage tolerance
        if [[ "$tolerance" == *"%" ]]; then
            local percent="${tolerance%\%}"
            if [[ "$expected" != "0" ]]; then
                tol_value=$(echo "scale=2; $expected * $percent / 100" | bc -l 2>/dev/null | tr -d '-')
            else
                tol_value=0
            fi
        else
            tol_value="$tolerance"
        fi

        # Compare with tolerance
        local comparison
        comparison=$(echo "$diff <= $tol_value" | bc -l 2>/dev/null)

        if [[ "$comparison" == "1" ]]; then
            return 0
        fi
    fi

    # Boolean normalization
    local norm_expected norm_actual
    norm_expected=$(normalize_boolean "$expected")
    norm_actual=$(normalize_boolean "$actual")

    if [[ "$norm_expected" == "$norm_actual" ]]; then
        return 0
    fi

    return 1
}

#######################################
# Normalize boolean values to true/false
# Arguments:
#   $1 - Value to normalize
# Outputs: "true", "false", or original value
#######################################
normalize_boolean() {
    local value="$1"

    case "${value,,}" in
        "true"|"yes"|"1"|"on"|"enabled")
            echo "true"
            ;;
        "false"|"no"|"0"|"off"|"disabled")
            echo "false"
            ;;
        *)
            echo "$value"
            ;;
    esac
}

#######################################
# Log a cross-validation mismatch
# Arguments:
#   $1 - Command name (e.g., "pl status")
#   $2 - Field name (e.g., "user_count")
#   $3 - Expected value
#   $4 - Actual value
#   $5 - Severity (warning/error/critical)
#   $6 - Message (optional)
#######################################
log_mismatch() {
    local command="$1"
    local field="$2"
    local expected="$3"
    local actual="$4"
    local severity="${5:-error}"
    local message="${6:-}"

    local timestamp
    timestamp=$(date -Iseconds)

    # Store in memory
    local key="${command}::${field}"
    CROSSVAL_ERRORS[$key]="$expected vs $actual"

    # Log to console
    local color=""
    case "$severity" in
        critical) color="\033[0;31m" ;;  # Red
        error) color="\033[0;31m" ;;      # Red
        warning) color="\033[1;33m" ;;    # Yellow
    esac

    echo -e "${color}MISMATCH [$severity]:${NC:-\033[0m} $command.$field"
    echo "  Expected: $expected"
    echo "  Actual:   $actual"
    [[ -n "$message" ]] && echo "  Note:     $message"

    # Append to findings file
    if command -v jq &>/dev/null && [[ -f "$CROSSVAL_FINDINGS_FILE" ]]; then
        local finding
        finding=$(jq -n \
            --arg ts "$timestamp" \
            --arg cmd "$command" \
            --arg fld "$field" \
            --arg exp "$expected" \
            --arg act "$actual" \
            --arg sev "$severity" \
            --arg msg "$message" \
            '{
                timestamp: $ts,
                command: $cmd,
                field: $fld,
                expected: $exp,
                actual: $act,
                severity: $sev,
                message: $msg
            }')

        jq ".findings += [$finding]" "$CROSSVAL_FINDINGS_FILE" > "${CROSSVAL_FINDINGS_FILE}.tmp" && \
        mv "${CROSSVAL_FINDINGS_FILE}.tmp" "$CROSSVAL_FINDINGS_FILE"
    fi

    # Log to verification log if available
    if [[ -n "${VERIFY_LOG_FILE:-}" ]]; then
        echo "[$timestamp] [MISMATCH] $command.$field: expected=$expected actual=$actual severity=$severity" >> "$VERIFY_LOG_FILE"
    fi

    return 1
}

#######################################
# Log a successful validation
# Arguments:
#   $1 - Command name
#   $2 - Field name
#   $3 - Value
#######################################
log_match() {
    local command="$1"
    local field="$2"
    local value="$3"

    echo -e "\033[0;32m✓\033[0m $command.$field = $value"
}

################################################################################
# SECTION 2: Cross-Validation Functions for Live State Commands
################################################################################

#######################################
# Cross-validate pl doctor output
# Arguments:
#   $1 - Site name (optional, for site-specific checks)
# Returns: 0 if all validations pass, 1 if any fail
#######################################
cross_validate_doctor() {
    local site="${1:-}"
    local failures=0

    echo ""
    echo "Cross-validating: pl doctor"
    echo "─────────────────────────────────────────"

    # Get pl doctor output (try JSON first)
    local doctor_output
    doctor_output=$(./pl doctor --json 2>/dev/null || ./pl doctor 2>&1)

    # 1. Docker availability
    local doctor_docker actual_docker
    if command -v jq &>/dev/null && [[ "$doctor_output" == "{"* ]]; then
        doctor_docker=$(echo "$doctor_output" | jq -r '.docker.available // empty')
    else
        doctor_docker=$(echo "$doctor_output" | grep -qi "docker.*ok\|docker.*available" && echo "true" || echo "false")
    fi

    actual_docker=$(docker --version &>/dev/null && echo "true" || echo "false")

    if compare_values "$doctor_docker" "$actual_docker"; then
        log_match "pl doctor" "docker.available" "$actual_docker"
    else
        log_mismatch "pl doctor" "docker.available" "$doctor_docker" "$actual_docker" "critical" "Docker availability mismatch"
        ((failures++))
    fi

    # 2. Docker running
    local doctor_running actual_running
    if command -v jq &>/dev/null && [[ "$doctor_output" == "{"* ]]; then
        doctor_running=$(echo "$doctor_output" | jq -r '.docker.running // empty')
    else
        doctor_running=$(echo "$doctor_output" | grep -qi "docker.*running" && echo "true" || echo "false")
    fi

    actual_running=$(docker info &>/dev/null && echo "true" || echo "false")

    if compare_values "$doctor_running" "$actual_running"; then
        log_match "pl doctor" "docker.running" "$actual_running"
    else
        log_mismatch "pl doctor" "docker.running" "$doctor_running" "$actual_running" "critical" "Docker daemon state mismatch"
        ((failures++))
    fi

    # 3. DDEV version
    local doctor_ddev actual_ddev
    if command -v jq &>/dev/null && [[ "$doctor_output" == "{"* ]]; then
        doctor_ddev=$(echo "$doctor_output" | jq -r '.ddev.version // empty')
    fi

    actual_ddev=$(ddev version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1)

    if [[ -n "$doctor_ddev" && -n "$actual_ddev" ]]; then
        if compare_values "$doctor_ddev" "$actual_ddev"; then
            log_match "pl doctor" "ddev.version" "$actual_ddev"
        else
            log_mismatch "pl doctor" "ddev.version" "$doctor_ddev" "$actual_ddev" "warning" "DDEV version mismatch"
            ((failures++))
        fi
    fi

    # 4. Disk space (with tolerance)
    local doctor_disk actual_disk
    if command -v jq &>/dev/null && [[ "$doctor_output" == "{"* ]]; then
        doctor_disk=$(echo "$doctor_output" | jq -r '.disk.available_gb // empty')
    fi

    actual_disk=$(df -BG . 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')

    if [[ -n "$doctor_disk" && -n "$actual_disk" ]]; then
        if compare_values "$doctor_disk" "$actual_disk" "2"; then
            log_match "pl doctor" "disk.available_gb" "$actual_disk"
        else
            log_mismatch "pl doctor" "disk.available_gb" "$doctor_disk" "$actual_disk" "warning" "Disk space may have changed"
            ((failures++))
        fi
    fi

    # 5. Memory (with tolerance)
    local doctor_mem actual_mem
    if command -v jq &>/dev/null && [[ "$doctor_output" == "{"* ]]; then
        doctor_mem=$(echo "$doctor_output" | jq -r '.memory.available_mb // empty')
    fi

    actual_mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')

    if [[ -n "$doctor_mem" && -n "$actual_mem" ]]; then
        if compare_values "$doctor_mem" "$actual_mem" "200"; then
            log_match "pl doctor" "memory.available_mb" "$actual_mem"
        else
            log_mismatch "pl doctor" "memory.available_mb" "$doctor_mem" "$actual_mem" "warning" "Memory may have changed"
            ((failures++))
        fi
    fi

    echo ""
    [[ $failures -eq 0 ]] && return 0 || return 1
}

#######################################
# Cross-validate pl status output for a site
# Arguments:
#   $1 - Site name (required)
# Returns: 0 if all validations pass, 1 if any fail
#######################################
cross_validate_status() {
    local site="$1"
    local failures=0

    if [[ -z "$site" ]]; then
        echo "ERROR: cross_validate_status requires a site name" >&2
        return 1
    fi

    echo ""
    echo "Cross-validating: pl status -s $site"
    echo "─────────────────────────────────────────"

    # Check site exists
    if [[ ! -d "$PROJECT_ROOT/sites/$site" ]]; then
        echo "Site $site does not exist"
        return 1
    fi

    # Get pl status output
    local status_output
    status_output=$(./pl status -s "$site" --json 2>/dev/null || ./pl status -s "$site" 2>&1)

    # 1. User count cross-validation
    local status_users actual_users
    if command -v jq &>/dev/null && [[ "$status_output" == "{"* ]]; then
        status_users=$(echo "$status_output" | jq -r '.users // empty')
    else
        status_users=$(echo "$status_output" | grep -oP 'users?:\s*\K\d+' | head -1)
    fi

    actual_users=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0" 2>/dev/null | tr -d '[:space:]')

    if [[ -n "$status_users" && -n "$actual_users" ]]; then
        if compare_values "$status_users" "$actual_users" "0"; then
            log_match "pl status" "users" "$actual_users"
        else
            log_mismatch "pl status" "users" "$status_users" "$actual_users" "critical" "User count mismatch - possible data issue"
            ((failures++))
        fi
    fi

    # 2. Database size cross-validation
    local status_db actual_db
    if command -v jq &>/dev/null && [[ "$status_output" == "{"* ]]; then
        status_db=$(echo "$status_output" | jq -r '.db_size_mb // .database_size_mb // empty')
    fi

    actual_db=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && \
        ddev mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 0) FROM information_schema.tables WHERE table_schema = DATABASE();" 2>/dev/null | tr -d '[:space:]')

    if [[ -n "$status_db" && -n "$actual_db" ]]; then
        if compare_values "$status_db" "$actual_db" "2"; then
            log_match "pl status" "db_size_mb" "$actual_db"
        else
            log_mismatch "pl status" "db_size_mb" "$status_db" "$actual_db" "warning" "Database size may have changed"
            ((failures++))
        fi
    fi

    # 3. Health status cross-validation
    local status_health actual_health
    if command -v jq &>/dev/null && [[ "$status_output" == "{"* ]]; then
        status_health=$(echo "$status_output" | jq -r '.health // empty')
    fi

    # Determine actual health by checking DDEV and DB connection
    local ddev_running db_connected
    ddev_running=$(ddev describe "$site" 2>/dev/null | grep -q "running" && echo "true" || echo "false")
    db_connected=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && ddev drush status --field=db-status 2>/dev/null | grep -qi "connected" && echo "true" || echo "false")

    if [[ "$ddev_running" == "true" && "$db_connected" == "true" ]]; then
        actual_health="healthy"
    elif [[ "$ddev_running" == "true" ]]; then
        actual_health="degraded"
    else
        actual_health="down"
    fi

    if [[ -n "$status_health" ]]; then
        if compare_values "$status_health" "$actual_health"; then
            log_match "pl status" "health" "$actual_health"
        else
            log_mismatch "pl status" "health" "$status_health" "$actual_health" "high" "Health status mismatch"
            ((failures++))
        fi
    fi

    echo ""
    [[ $failures -eq 0 ]] && return 0 || return 1
}

#######################################
# Cross-validate pl storage output
# Arguments:
#   $1 - Site name (optional, for site-specific storage)
# Returns: 0 if all validations pass, 1 if any fail
#######################################
cross_validate_storage() {
    local site="${1:-}"
    local failures=0

    echo ""
    echo "Cross-validating: pl storage${site:+ $site}"
    echo "─────────────────────────────────────────"

    # Get pl storage output
    local storage_output
    if [[ -n "$site" ]]; then
        storage_output=$(./pl storage "$site" --json 2>/dev/null || ./pl storage "$site" 2>&1)
    else
        storage_output=$(./pl storage --json 2>/dev/null || ./pl storage 2>&1)
    fi

    if [[ -n "$site" && -d "$PROJECT_ROOT/sites/$site" ]]; then
        # 1. Site files size
        local storage_files actual_files
        if command -v jq &>/dev/null && [[ "$storage_output" == "{"* ]]; then
            storage_files=$(echo "$storage_output" | jq -r '.files_mb // empty')
        fi

        actual_files=$(du -sm "$PROJECT_ROOT/sites/$site/html/sites/default/files" 2>/dev/null | cut -f1)

        if [[ -n "$storage_files" && -n "$actual_files" ]]; then
            if compare_values "$storage_files" "$actual_files" "2"; then
                log_match "pl storage" "files_mb" "$actual_files"
            else
                log_mismatch "pl storage" "files_mb" "$storage_files" "$actual_files" "warning" "Files size may have changed"
                ((failures++))
            fi
        fi

        # 2. Files count
        local storage_count actual_count
        if command -v jq &>/dev/null && [[ "$storage_output" == "{"* ]]; then
            storage_count=$(echo "$storage_output" | jq -r '.files_count // empty')
        fi

        actual_count=$(find "$PROJECT_ROOT/sites/$site/html/sites/default/files" -type f 2>/dev/null | wc -l)

        if [[ -n "$storage_count" && -n "$actual_count" ]]; then
            if compare_values "$storage_count" "$actual_count" "5"; then
                log_match "pl storage" "files_count" "$actual_count"
            else
                log_mismatch "pl storage" "files_count" "$storage_count" "$actual_count" "warning"
                ((failures++))
            fi
        fi

        # 3. Database size
        local storage_db actual_db
        if command -v jq &>/dev/null && [[ "$storage_output" == "{"* ]]; then
            storage_db=$(echo "$storage_output" | jq -r '.database_mb // empty')
        fi

        actual_db=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && \
            ddev mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 0) FROM information_schema.tables WHERE table_schema = DATABASE();" 2>/dev/null | tr -d '[:space:]')

        if [[ -n "$storage_db" && -n "$actual_db" ]]; then
            if compare_values "$storage_db" "$actual_db" "2"; then
                log_match "pl storage" "database_mb" "$actual_db"
            else
                log_mismatch "pl storage" "database_mb" "$storage_db" "$actual_db" "warning"
                ((failures++))
            fi
        fi

        # 4. Total site size
        local storage_total actual_total
        if command -v jq &>/dev/null && [[ "$storage_output" == "{"* ]]; then
            storage_total=$(echo "$storage_output" | jq -r '.total_mb // empty')
        fi

        actual_total=$(du -sm "$PROJECT_ROOT/sites/$site" 2>/dev/null | cut -f1)

        if [[ -n "$storage_total" && -n "$actual_total" ]]; then
            if compare_values "$storage_total" "$actual_total" "10"; then
                log_match "pl storage" "total_mb" "$actual_total"
            else
                log_mismatch "pl storage" "total_mb" "$storage_total" "$actual_total" "warning"
                ((failures++))
            fi
        fi
    fi

    # 5. Available disk space (global)
    local storage_avail actual_avail
    if command -v jq &>/dev/null && [[ "$storage_output" == "{"* ]]; then
        storage_avail=$(echo "$storage_output" | jq -r '.available_gb // empty')
    fi

    actual_avail=$(df -BG . 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')

    if [[ -n "$storage_avail" && -n "$actual_avail" ]]; then
        if compare_values "$storage_avail" "$actual_avail" "2"; then
            log_match "pl storage" "available_gb" "$actual_avail"
        else
            log_mismatch "pl storage" "available_gb" "$storage_avail" "$actual_avail" "warning"
            ((failures++))
        fi
    fi

    echo ""
    [[ $failures -eq 0 ]] && return 0 || return 1
}

#######################################
# Cross-validate pl security-check output
# Arguments:
#   $1 - Site name (required)
# Returns: 0 if all validations pass, 1 if any fail
#######################################
cross_validate_security() {
    local site="$1"
    local failures=0

    if [[ -z "$site" ]]; then
        echo "ERROR: cross_validate_security requires a site name" >&2
        return 1
    fi

    echo ""
    echo "Cross-validating: pl security-check $site"
    echo "─────────────────────────────────────────"

    # Check site exists
    if [[ ! -d "$PROJECT_ROOT/sites/$site" ]]; then
        echo "Site $site does not exist"
        return 1
    fi

    # Get pl security-check output
    local security_output
    security_output=$(./pl security-check "$site" --json 2>/dev/null || ./pl security-check "$site" 2>&1)

    # 1. Settings.php protection
    local sec_settings actual_settings
    if command -v jq &>/dev/null && [[ "$security_output" == "{"* ]]; then
        sec_settings=$(echo "$security_output" | jq -r '.permissions.settings_protected // empty')
    fi

    local settings_path="$PROJECT_ROOT/sites/$site/html/sites/default/settings.php"
    if [[ -f "$settings_path" ]]; then
        local perm
        perm=$(stat -c "%a" "$settings_path" 2>/dev/null)
        if [[ "$perm" =~ ^4[04][04]$ ]]; then
            actual_settings="true"
        else
            actual_settings="false"
        fi

        if [[ -n "$sec_settings" ]]; then
            if compare_values "$sec_settings" "$actual_settings"; then
                log_match "pl security-check" "settings_protected" "$actual_settings"
            else
                log_mismatch "pl security-check" "settings_protected" "$sec_settings" "$actual_settings" "high" "Settings.php permission mismatch"
                ((failures++))
            fi
        fi
    fi

    # 2. Files directory writable
    local sec_files actual_files
    if command -v jq &>/dev/null && [[ "$security_output" == "{"* ]]; then
        sec_files=$(echo "$security_output" | jq -r '.permissions.files_writable // empty')
    fi

    local files_path="$PROJECT_ROOT/sites/$site/html/sites/default/files"
    actual_files=$(test -w "$files_path" 2>/dev/null && echo "true" || echo "false")

    if [[ -n "$sec_files" ]]; then
        if compare_values "$sec_files" "$actual_files"; then
            log_match "pl security-check" "files_writable" "$actual_files"
        else
            log_mismatch "pl security-check" "files_writable" "$sec_files" "$actual_files" "warning"
            ((failures++))
        fi
    fi

    # 3. Debug mode status
    local sec_debug actual_debug
    if command -v jq &>/dev/null && [[ "$security_output" == "{"* ]]; then
        sec_debug=$(echo "$security_output" | jq -r '.config.debug_disabled // empty')
    fi

    local error_level
    error_level=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && ddev drush config:get system.logging error_level --format=string 2>/dev/null)
    if [[ "$error_level" == "hide" || "$error_level" == "none" ]]; then
        actual_debug="true"
    else
        actual_debug="false"
    fi

    if [[ -n "$sec_debug" ]]; then
        if compare_values "$sec_debug" "$actual_debug"; then
            log_match "pl security-check" "debug_disabled" "$actual_debug"
        else
            log_mismatch "pl security-check" "debug_disabled" "$sec_debug" "$actual_debug" "high"
            ((failures++))
        fi
    fi

    # 4. Security updates count
    local sec_updates actual_updates
    if command -v jq &>/dev/null && [[ "$security_output" == "{"* ]]; then
        sec_updates=$(echo "$security_output" | jq -r '.updates.security_count // empty')
    fi

    actual_updates=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && ddev drush pm:security --format=json 2>/dev/null | jq 'length' 2>/dev/null)

    if [[ -n "$sec_updates" && -n "$actual_updates" ]]; then
        if compare_values "$sec_updates" "$actual_updates" "0"; then
            log_match "pl security-check" "security_updates" "$actual_updates"
        else
            log_mismatch "pl security-check" "security_updates" "$sec_updates" "$actual_updates" "high" "Security update count mismatch"
            ((failures++))
        fi
    fi

    echo ""
    [[ $failures -eq 0 ]] && return 0 || return 1
}

#######################################
# Cross-validate pl testos output
# Arguments:
#   $1 - Site name (required)
# Returns: 0 if all validations pass, 1 if any fail
#######################################
cross_validate_testos() {
    local site="$1"
    local failures=0

    if [[ -z "$site" ]]; then
        echo "ERROR: cross_validate_testos requires a site name" >&2
        return 1
    fi

    echo ""
    echo "Cross-validating: pl testos $site"
    echo "─────────────────────────────────────────"

    # Get pl testos output
    local testos_output
    testos_output=$(./pl testos "$site" --json 2>/dev/null || ./pl testos "$site" 2>&1)

    # 1. Docker container running
    local testos_running actual_running
    if command -v jq &>/dev/null && [[ "$testos_output" == "{"* ]]; then
        testos_running=$(echo "$testos_output" | jq -r '.docker.container_running // empty')
    fi

    actual_running=$(docker ps --filter "name=ddev-$site" --format "{{.Status}}" 2>/dev/null | grep -q "Up" && echo "true" || echo "false")

    if [[ -n "$testos_running" ]]; then
        if compare_values "$testos_running" "$actual_running"; then
            log_match "pl testos" "container_running" "$actual_running"
        else
            log_mismatch "pl testos" "container_running" "$testos_running" "$actual_running" "critical"
            ((failures++))
        fi
    fi

    # 2. Docker container healthy
    local testos_healthy actual_healthy
    if command -v jq &>/dev/null && [[ "$testos_output" == "{"* ]]; then
        testos_healthy=$(echo "$testos_output" | jq -r '.docker.container_healthy // empty')
    fi

    actual_healthy=$(docker ps --filter "name=ddev-$site-web" --format "{{.Status}}" 2>/dev/null | grep -q "healthy" && echo "true" || echo "false")

    if [[ -n "$testos_healthy" ]]; then
        if compare_values "$testos_healthy" "$actual_healthy"; then
            log_match "pl testos" "container_healthy" "$actual_healthy"
        else
            log_mismatch "pl testos" "container_healthy" "$testos_healthy" "$actual_healthy" "high"
            ((failures++))
        fi
    fi

    # 3. Files directory permissions
    local testos_perms actual_perms
    if command -v jq &>/dev/null && [[ "$testos_output" == "{"* ]]; then
        testos_perms=$(echo "$testos_output" | jq -r '.filesystem.files_permissions // empty')
    fi

    actual_perms=$(stat -c "%a" "$PROJECT_ROOT/sites/$site/html/sites/default/files" 2>/dev/null)

    if [[ -n "$testos_perms" && -n "$actual_perms" ]]; then
        if compare_values "$testos_perms" "$actual_perms"; then
            log_match "pl testos" "files_permissions" "$actual_perms"
        else
            log_mismatch "pl testos" "files_permissions" "$testos_perms" "$actual_perms" "warning"
            ((failures++))
        fi
    fi

    # 4. PHP memory limit
    local testos_mem actual_mem
    if command -v jq &>/dev/null && [[ "$testos_output" == "{"* ]]; then
        testos_mem=$(echo "$testos_output" | jq -r '.php.memory_limit // empty')
    fi

    actual_mem=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && ddev exec "php -r 'echo ini_get(\"memory_limit\");'" 2>/dev/null)

    if [[ -n "$testos_mem" && -n "$actual_mem" ]]; then
        if compare_values "$testos_mem" "$actual_mem"; then
            log_match "pl testos" "php_memory_limit" "$actual_mem"
        else
            log_mismatch "pl testos" "php_memory_limit" "$testos_mem" "$actual_mem" "warning"
            ((failures++))
        fi
    fi

    # 5. MySQL running
    local testos_mysql actual_mysql
    if command -v jq &>/dev/null && [[ "$testos_output" == "{"* ]]; then
        testos_mysql=$(echo "$testos_output" | jq -r '.database.mysql_running // empty')
    fi

    actual_mysql=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && ddev mysql -e "SELECT 1" &>/dev/null && echo "true" || echo "false")

    if [[ -n "$testos_mysql" ]]; then
        if compare_values "$testos_mysql" "$actual_mysql"; then
            log_match "pl testos" "mysql_running" "$actual_mysql"
        else
            log_mismatch "pl testos" "mysql_running" "$testos_mysql" "$actual_mysql" "critical"
            ((failures++))
        fi
    fi

    echo ""
    [[ $failures -eq 0 ]] && return 0 || return 1
}

#######################################
# Cross-validate pl seo-check output
# Arguments:
#   $1 - Site name (required)
# Returns: 0 if all validations pass, 1 if any fail
#######################################
cross_validate_seo() {
    local site="$1"
    local failures=0

    if [[ -z "$site" ]]; then
        echo "ERROR: cross_validate_seo requires a site name" >&2
        return 1
    fi

    echo ""
    echo "Cross-validating: pl seo-check $site"
    echo "─────────────────────────────────────────"

    # Determine site URL
    local site_url
    site_url=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && ddev describe -j 2>/dev/null | jq -r '.raw.primary_url // empty')
    if [[ -z "$site_url" ]]; then
        site_url="https://${site}.ddev.site"
    fi

    # Get pl seo-check output
    local seo_output
    seo_output=$(./pl seo-check "$site" --json 2>/dev/null || ./pl seo-check "$site" 2>&1)

    # 1. Meta title present
    local seo_title actual_title
    if command -v jq &>/dev/null && [[ "$seo_output" == "{"* ]]; then
        seo_title=$(echo "$seo_output" | jq -r '.meta.title_present // empty')
    fi

    actual_title=$(curl -sL "$site_url" 2>/dev/null | grep -q "<title>" && echo "true" || echo "false")

    if [[ -n "$seo_title" ]]; then
        if compare_values "$seo_title" "$actual_title"; then
            log_match "pl seo-check" "title_present" "$actual_title"
        else
            log_mismatch "pl seo-check" "title_present" "$seo_title" "$actual_title" "warning"
            ((failures++))
        fi
    fi

    # 2. Meta description present
    local seo_desc actual_desc
    if command -v jq &>/dev/null && [[ "$seo_output" == "{"* ]]; then
        seo_desc=$(echo "$seo_output" | jq -r '.meta.description_present // empty')
    fi

    actual_desc=$(curl -sL "$site_url" 2>/dev/null | grep -qi 'name="description"' && echo "true" || echo "false")

    if [[ -n "$seo_desc" ]]; then
        if compare_values "$seo_desc" "$actual_desc"; then
            log_match "pl seo-check" "description_present" "$actual_desc"
        else
            log_mismatch "pl seo-check" "description_present" "$seo_desc" "$actual_desc" "warning"
            ((failures++))
        fi
    fi

    # 3. Robots.txt accessible
    local seo_robots actual_robots
    if command -v jq &>/dev/null && [[ "$seo_output" == "{"* ]]; then
        seo_robots=$(echo "$seo_output" | jq -r '.robots.accessible // empty')
    fi

    local robots_status
    robots_status=$(curl -sL -o /dev/null -w "%{http_code}" "${site_url}/robots.txt" 2>/dev/null)
    actual_robots=$([[ "$robots_status" == "200" ]] && echo "true" || echo "false")

    if [[ -n "$seo_robots" ]]; then
        if compare_values "$seo_robots" "$actual_robots"; then
            log_match "pl seo-check" "robots_accessible" "$actual_robots"
        else
            log_mismatch "pl seo-check" "robots_accessible" "$seo_robots" "$actual_robots" "warning"
            ((failures++))
        fi
    fi

    # 4. Sitemap accessible
    local seo_sitemap actual_sitemap
    if command -v jq &>/dev/null && [[ "$seo_output" == "{"* ]]; then
        seo_sitemap=$(echo "$seo_output" | jq -r '.sitemap.accessible // empty')
    fi

    local sitemap_status
    sitemap_status=$(curl -sL -o /dev/null -w "%{http_code}" "${site_url}/sitemap.xml" 2>/dev/null)
    actual_sitemap=$([[ "$sitemap_status" == "200" ]] && echo "true" || echo "false")

    if [[ -n "$seo_sitemap" ]]; then
        if compare_values "$seo_sitemap" "$actual_sitemap"; then
            log_match "pl seo-check" "sitemap_accessible" "$actual_sitemap"
        else
            log_mismatch "pl seo-check" "sitemap_accessible" "$seo_sitemap" "$actual_sitemap" "warning"
            ((failures++))
        fi
    fi

    echo ""
    [[ $failures -eq 0 ]] && return 0 || return 1
}

#######################################
# Cross-validate pl badges output
# Returns: 0 if all validations pass, 1 if any fail
#######################################
cross_validate_badges() {
    local failures=0

    echo ""
    echo "Cross-validating: pl badges"
    echo "─────────────────────────────────────────"

    # Get pl badges output
    local badges_output
    badges_output=$(./pl badges --json 2>/dev/null || ./pl badges 2>&1)

    # 1. Machine coverage percentage
    local badges_machine actual_machine
    if command -v jq &>/dev/null && [[ "$badges_output" == "{"* ]]; then
        badges_machine=$(echo "$badges_output" | jq -r '.machine.coverage // empty')
    fi

    # Calculate actual coverage from verification results
    local total passed
    total=$(yq '.checklist | length' "$PROJECT_ROOT/.verification.yml" 2>/dev/null || echo "575")
    local latest_log
    latest_log=$(ls -t "$PROJECT_ROOT/.logs/verification/verify-"*.log 2>/dev/null | head -1)
    if [[ -f "$latest_log" ]]; then
        passed=$(grep -c "status: passed\|PASSED" "$latest_log" 2>/dev/null || echo "0")
        actual_machine=$(echo "scale=0; $passed * 100 / $total" | bc 2>/dev/null)
    fi

    if [[ -n "$badges_machine" && -n "$actual_machine" ]]; then
        if compare_values "$badges_machine" "$actual_machine" "2"; then
            log_match "pl badges" "machine_coverage" "${actual_machine}%"
        else
            log_mismatch "pl badges" "machine_coverage" "$badges_machine" "$actual_machine" "warning"
            ((failures++))
        fi
    fi

    # 2. Badge files exist
    local badges_svg actual_svg
    if command -v jq &>/dev/null && [[ "$badges_output" == "{"* ]]; then
        badges_svg=$(echo "$badges_output" | jq -r '.files.machine_svg // empty')
    fi

    actual_svg=$(test -f "$PROJECT_ROOT/.verification-badges/machine.svg" && echo "true" || echo "false")

    if [[ -n "$badges_svg" ]]; then
        if compare_values "$badges_svg" "$actual_svg"; then
            log_match "pl badges" "machine_svg_exists" "$actual_svg"
        else
            log_mismatch "pl badges" "machine_svg_exists" "$badges_svg" "$actual_svg" "warning"
            ((failures++))
        fi
    fi

    echo ""
    [[ $failures -eq 0 ]] && return 0 || return 1
}

#######################################
# Cross-validate pl avc-moodle-status output
# Returns: 0 if all validations pass, 1 if any fail
#######################################
cross_validate_moodle() {
    local failures=0

    echo ""
    echo "Cross-validating: pl avc-moodle-status"
    echo "─────────────────────────────────────────"

    # Check if AVC site exists
    if [[ ! -d "$PROJECT_ROOT/sites/avc" ]]; then
        echo "  AVC site not found - skipping Moodle validation"
        return 0
    fi

    # Get pl avc-moodle-status output
    local moodle_output
    moodle_output=$(./pl avc-moodle-status --json 2>/dev/null || ./pl avc-moodle-status 2>&1)

    # 1. Connection status
    local moodle_conn actual_conn
    if command -v jq &>/dev/null && [[ "$moodle_output" == "{"* ]]; then
        moodle_conn=$(echo "$moodle_output" | jq -r '.connection.status // empty')
    fi

    # Check actual Moodle connection using secrets
    if [[ -f "$PROJECT_ROOT/.secrets.yml" ]]; then
        local moodle_url moodle_token
        moodle_url=$(yq -r '.moodle.url // empty' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null)
        moodle_token=$(yq -r '.moodle.token // empty' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null)

        if [[ -n "$moodle_url" && -n "$moodle_token" ]]; then
            local api_status
            api_status=$(curl -s -o /dev/null -w "%{http_code}" \
                "${moodle_url}/webservice/rest/server.php?wstoken=${moodle_token}&wsfunction=core_webservice_get_site_info&moodlewsrestformat=json" 2>/dev/null)
            actual_conn=$([[ "$api_status" == "200" ]] && echo "connected" || echo "disconnected")
        else
            actual_conn="not_configured"
        fi
    else
        actual_conn="not_configured"
    fi

    if [[ -n "$moodle_conn" ]]; then
        if compare_values "$moodle_conn" "$actual_conn"; then
            log_match "pl avc-moodle-status" "connection" "$actual_conn"
        else
            log_mismatch "pl avc-moodle-status" "connection" "$moodle_conn" "$actual_conn" "high"
            ((failures++))
        fi
    fi

    # 2. Users synced count
    local moodle_users actual_users
    if command -v jq &>/dev/null && [[ "$moodle_output" == "{"* ]]; then
        moodle_users=$(echo "$moodle_output" | jq -r '.sync.users_synced // empty')
    fi

    actual_users=$(cd "$PROJECT_ROOT/sites/avc" 2>/dev/null && \
        ddev drush sqlq "SELECT COUNT(*) FROM user__field_moodle_id WHERE field_moodle_id_value IS NOT NULL" 2>/dev/null | tr -d '[:space:]')

    if [[ -n "$moodle_users" && -n "$actual_users" ]]; then
        if compare_values "$moodle_users" "$actual_users" "0"; then
            log_match "pl avc-moodle-status" "users_synced" "$actual_users"
        else
            log_mismatch "pl avc-moodle-status" "users_synced" "$moodle_users" "$actual_users" "high"
            ((failures++))
        fi
    fi

    # 3. Courses synced count
    local moodle_courses actual_courses
    if command -v jq &>/dev/null && [[ "$moodle_output" == "{"* ]]; then
        moodle_courses=$(echo "$moodle_output" | jq -r '.sync.courses_synced // empty')
    fi

    actual_courses=$(cd "$PROJECT_ROOT/sites/avc" 2>/dev/null && \
        ddev drush sqlq "SELECT COUNT(*) FROM node_field_data WHERE type='moodle_course'" 2>/dev/null | tr -d '[:space:]')

    if [[ -n "$moodle_courses" && -n "$actual_courses" ]]; then
        if compare_values "$moodle_courses" "$actual_courses" "0"; then
            log_match "pl avc-moodle-status" "courses_synced" "$actual_courses"
        else
            log_mismatch "pl avc-moodle-status" "courses_synced" "$moodle_courses" "$actual_courses" "high"
            ((failures++))
        fi
    fi

    echo ""
    [[ $failures -eq 0 ]] && return 0 || return 1
}

#######################################
# Cross-validate pl report output
# Arguments:
#   $1 - Site name (required)
# Returns: 0 if all validations pass, 1 if any fail
#######################################
cross_validate_report() {
    local site="$1"
    local failures=0

    if [[ -z "$site" ]]; then
        echo "ERROR: cross_validate_report requires a site name" >&2
        return 1
    fi

    echo ""
    echo "Cross-validating: pl report $site"
    echo "─────────────────────────────────────────"

    # Get pl report output
    local report_output
    report_output=$(./pl report "$site" --json 2>/dev/null || ./pl report "$site" 2>&1)

    # 1. Node count
    local report_nodes actual_nodes
    if command -v jq &>/dev/null && [[ "$report_output" == "{"* ]]; then
        report_nodes=$(echo "$report_output" | jq -r '.content.nodes // empty')
    fi

    actual_nodes=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && \
        ddev drush sqlq "SELECT COUNT(*) FROM node_field_data" 2>/dev/null | tr -d '[:space:]')

    if [[ -n "$report_nodes" && -n "$actual_nodes" ]]; then
        if compare_values "$report_nodes" "$actual_nodes" "0"; then
            log_match "pl report" "nodes" "$actual_nodes"
        else
            log_mismatch "pl report" "nodes" "$report_nodes" "$actual_nodes" "warning"
            ((failures++))
        fi
    fi

    # 2. Media count
    local report_media actual_media
    if command -v jq &>/dev/null && [[ "$report_output" == "{"* ]]; then
        report_media=$(echo "$report_output" | jq -r '.content.media // empty')
    fi

    actual_media=$(cd "$PROJECT_ROOT/sites/$site" 2>/dev/null && \
        ddev drush sqlq "SELECT COUNT(*) FROM media_field_data" 2>/dev/null | tr -d '[:space:]')

    if [[ -n "$report_media" && -n "$actual_media" ]]; then
        if compare_values "$report_media" "$actual_media" "0"; then
            log_match "pl report" "media" "$actual_media"
        else
            log_mismatch "pl report" "media" "$report_media" "$actual_media" "warning"
            ((failures++))
        fi
    fi

    echo ""
    [[ $failures -eq 0 ]] && return 0 || return 1
}

################################################################################
# SECTION 3: Convenience Functions
################################################################################

#######################################
# Run all cross-validations for a site
# Arguments:
#   $1 - Site name (required)
# Returns: 0 if all pass, number of failed validations otherwise
#######################################
cross_validate_all() {
    local site="$1"
    local total_failures=0

    if [[ -z "$site" ]]; then
        echo "ERROR: cross_validate_all requires a site name" >&2
        return 1
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Cross-Validation Suite: $site"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Initialize
    crossval_init

    # Run each cross-validation
    cross_validate_doctor || ((total_failures++))
    cross_validate_status "$site" || ((total_failures++))
    cross_validate_storage "$site" || ((total_failures++))
    cross_validate_security "$site" || ((total_failures++))
    cross_validate_testos "$site" || ((total_failures++))
    cross_validate_seo "$site" || ((total_failures++))
    cross_validate_badges || ((total_failures++))
    cross_validate_moodle || ((total_failures++))
    cross_validate_report "$site" || ((total_failures++))

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    if [[ $total_failures -eq 0 ]]; then
        echo "  All cross-validations PASSED"
    else
        echo "  $total_failures validation(s) FAILED"
    fi
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    return $total_failures
}

#######################################
# Get the findings summary
# Outputs: JSON summary of all findings
#######################################
crossval_get_findings() {
    if [[ -f "$CROSSVAL_FINDINGS_FILE" ]]; then
        cat "$CROSSVAL_FINDINGS_FILE"
    else
        echo '{"findings": [], "summary": {"total": 0}}'
    fi
}

#######################################
# Print cross-validation help
#######################################
crossval_help() {
    cat << 'EOF'
NWP Cross-Validation Library (P51 Phase 2)

Functions:
  capture_baseline VAR CMD [DESC]    Capture a baseline value
  compare_values EXPECTED ACTUAL [TOL]  Compare with tolerance
  log_mismatch CMD FIELD EXP ACT SEV [MSG]  Log validation failure

Cross-Validation Functions:
  cross_validate_doctor              Validate pl doctor output
  cross_validate_status SITE         Validate pl status output
  cross_validate_storage [SITE]      Validate pl storage output
  cross_validate_security SITE       Validate pl security-check output
  cross_validate_testos SITE         Validate pl testos output
  cross_validate_seo SITE            Validate pl seo-check output
  cross_validate_badges              Validate pl badges output
  cross_validate_moodle              Validate pl avc-moodle-status output
  cross_validate_report SITE         Validate pl report output
  cross_validate_all SITE            Run all validations for a site

Examples:
  # Capture baseline before backup
  capture_baseline "user_count" "ddev drush sqlq 'SELECT COUNT(*) FROM users_field_data'"

  # Compare after restore
  new_count=$(ddev drush sqlq "SELECT COUNT(*) FROM users_field_data")
  compare_values "${BASELINE_VALUES[user_count]}" "$new_count" || log_mismatch ...

  # Run full validation suite
  cross_validate_all mysite
EOF
}

# Export functions for use when sourced
export -f crossval_init capture_baseline compare_values normalize_boolean
export -f log_mismatch log_match
export -f cross_validate_doctor cross_validate_status cross_validate_storage
export -f cross_validate_security cross_validate_testos cross_validate_seo
export -f cross_validate_badges cross_validate_moodle cross_validate_report
export -f cross_validate_all crossval_get_findings crossval_help
