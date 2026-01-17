#!/bin/bash
################################################################################
# NWP Auto-Fix Engine Library
#
# Part of P51: AI-Powered Deep Verification (Phase 4)
#
# This library provides automatic fixing of common issues discovered during
# AI verification. It pattern-matches error messages, applies appropriate
# fixes, verifies the fix worked, and logs all actions.
#
# Key Functions:
#   - autofix_analyze() - Analyze error and suggest fixes
#   - autofix_apply() - Apply a fix
#   - autofix_verify() - Verify fix was successful
#   - autofix_register_pattern() - Register custom fix patterns
#
# Built-in Fix Patterns:
#   - Permission errors (chmod/chown)
#   - Missing modules (composer/drush)
#   - Cache issues (drush cr)
#   - Database migrations (drush updb)
#   - Config sync issues (drush cim)
#   - File ownership issues
#
# Source this file: source "$PROJECT_ROOT/lib/verify-autofix.sh"
#
# Reference:
#   - P51: AI-Powered Deep Verification
#   - docs/proposals/P51-ai-powered-verification.md
################################################################################

# Determine paths
AUTOFIX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOFIX_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$AUTOFIX_LIB_DIR/.." && pwd)}"

# Make PROJECT_ROOT available if not set
PROJECT_ROOT="${PROJECT_ROOT:-$AUTOFIX_PROJECT_ROOT}"

# Configuration
AUTOFIX_LOG_DIR="${AUTOFIX_LOG_DIR:-$AUTOFIX_PROJECT_ROOT/.logs/autofix}"
AUTOFIX_LOG_FILE="${AUTOFIX_LOG_FILE:-$AUTOFIX_LOG_DIR/autofix.log}"
AUTOFIX_FINDINGS_FILE="${AUTOFIX_FINDINGS_FILE:-$AUTOFIX_LOG_DIR/autofix-findings.json}"
AUTOFIX_DRY_RUN="${AUTOFIX_DRY_RUN:-false}"
AUTOFIX_MAX_ATTEMPTS="${AUTOFIX_MAX_ATTEMPTS:-3}"

# Counters
AUTOFIX_TOTAL_ANALYZED=0
AUTOFIX_TOTAL_FIXED=0
AUTOFIX_TOTAL_FAILED=0
AUTOFIX_TOTAL_SKIPPED=0

# Pattern storage
declare -A AUTOFIX_PATTERNS=()
declare -A AUTOFIX_PATTERN_FIX=()
declare -A AUTOFIX_PATTERN_VERIFY=()
declare -A AUTOFIX_PATTERN_SEVERITY=()

################################################################################
# SECTION 1: Initialization
################################################################################

#######################################
# Initialize auto-fix system
#######################################
autofix_init() {
    mkdir -p "$AUTOFIX_LOG_DIR"

    # Initialize findings file
    cat > "$AUTOFIX_FINDINGS_FILE" << 'EOF'
{
  "generated_at": "",
  "fixes_applied": [],
  "fixes_failed": [],
  "patterns_matched": [],
  "summary": {
    "analyzed": 0,
    "fixed": 0,
    "failed": 0,
    "skipped": 0
  }
}
EOF

    # Update timestamp
    local timestamp
    timestamp=$(date -Iseconds)
    if command -v jq &>/dev/null; then
        jq ".generated_at = \"$timestamp\"" "$AUTOFIX_FINDINGS_FILE" > "${AUTOFIX_FINDINGS_FILE}.tmp" && \
        mv "${AUTOFIX_FINDINGS_FILE}.tmp" "$AUTOFIX_FINDINGS_FILE"
    fi

    # Initialize log
    echo "[$(date -Iseconds)] Auto-fix engine initialized" >> "$AUTOFIX_LOG_FILE"

    # Register built-in patterns
    autofix_register_builtin_patterns

    # Reset counters
    AUTOFIX_TOTAL_ANALYZED=0
    AUTOFIX_TOTAL_FIXED=0
    AUTOFIX_TOTAL_FAILED=0
    AUTOFIX_TOTAL_SKIPPED=0
}

#######################################
# Register built-in fix patterns
#######################################
autofix_register_builtin_patterns() {
    # Permission errors
    autofix_register_pattern \
        "permission_denied" \
        "Permission denied|EACCES|Operation not permitted" \
        "chmod -R 755 {path}; chown -R \$(whoami) {path}" \
        "test -w {path}" \
        "high"

    # Settings.php permission
    autofix_register_pattern \
        "settings_permission" \
        "settings.php.*not writable|Cannot write to settings" \
        "chmod 644 {site_path}/html/sites/default/settings.php" \
        "test -w {site_path}/html/sites/default/settings.php" \
        "high"

    # Files directory permission
    autofix_register_pattern \
        "files_permission" \
        "files.*not writable|Cannot write to files directory" \
        "chmod -R 775 {site_path}/html/sites/default/files" \
        "test -w {site_path}/html/sites/default/files" \
        "medium"

    # Missing module
    autofix_register_pattern \
        "missing_module" \
        "Module .* not found|Class .* not found|Target module .* is missing" \
        "cd {site_path} && ddev composer require {module}" \
        "cd {site_path} && ddev drush pm:list | grep -q {module_name}" \
        "high"

    # Module not enabled
    autofix_register_pattern \
        "module_not_enabled" \
        "Module .* is not enabled|The .* module is not enabled" \
        "cd {site_path} && ddev drush en {module_name} -y" \
        "cd {site_path} && ddev drush pm:list --status=enabled | grep -q {module_name}" \
        "medium"

    # Cache issues
    autofix_register_pattern \
        "cache_stale" \
        "Cache .* stale|Stale cache|cache.*expired|bootstrap caches" \
        "cd {site_path} && ddev drush cr" \
        "cd {site_path} && ddev drush status --field=bootstrap" \
        "low"

    # Database updates pending
    autofix_register_pattern \
        "db_updates_pending" \
        "pending database updates|updatedb|hook_update_N|Schema version" \
        "cd {site_path} && ddev drush updb -y" \
        "cd {site_path} && ddev drush updb --no || true" \
        "high"

    # Config sync needed
    autofix_register_pattern \
        "config_mismatch" \
        "configuration.*out of sync|Configuration.*mismatch|config.*differ" \
        "cd {site_path} && ddev drush cim -y" \
        "cd {site_path} && ddev drush config:status 2>&1 | grep -q 'No differences'" \
        "medium"

    # DDEV not running
    autofix_register_pattern \
        "ddev_not_running" \
        "DDEV.*not running|ddev.*stopped|Project is not running" \
        "cd {site_path} && ddev start" \
        "cd {site_path} && ddev describe | grep -q running" \
        "critical"

    # Database connection failed
    autofix_register_pattern \
        "db_connection" \
        "Database connection failed|SQLSTATE|MySQL.*refused|mariadb.*refused" \
        "cd {site_path} && ddev restart" \
        "cd {site_path} && ddev drush status --field=db-status | grep -qi connected" \
        "critical"

    # Composer autoload
    autofix_register_pattern \
        "composer_autoload" \
        "autoload.*not found|Class.*not found|composer.*dump" \
        "cd {site_path} && ddev composer dump-autoload" \
        "cd {site_path} && ddev exec 'php -r \"require vendor/autoload.php;\"'" \
        "medium"

    # Memory exhausted
    autofix_register_pattern \
        "memory_exhausted" \
        "Allowed memory size.*exhausted|memory_limit|Out of memory" \
        "cd {site_path} && ddev config --php-version=8.2 --memory-limit=512M && ddev restart" \
        "cd {site_path} && ddev exec 'php -r \"echo ini_get(\\\"memory_limit\\\");\"' | grep -E '512|1024|2048'" \
        "high"

    # Twig cache
    autofix_register_pattern \
        "twig_cache" \
        "Twig.*error|template.*not found|Twig.*cache" \
        "cd {site_path} && ddev drush cr && ddev drush twig:compile" \
        "cd {site_path} && ddev drush status --field=theme" \
        "low"

    # Entity updates
    autofix_register_pattern \
        "entity_updates" \
        "entity.*schema|Mismatched entity|entity_update" \
        "cd {site_path} && ddev drush entity:updates -y" \
        "cd {site_path} && ddev drush entity:updates 2>&1 | grep -q 'No entity schema'" \
        "medium"

    # File not found (in site)
    autofix_register_pattern \
        "file_not_found" \
        "file.*not found.*sites|No such file.*html" \
        "cd {site_path} && ddev drush cr" \
        "test -f {path}" \
        "low"

    # SSL certificate
    autofix_register_pattern \
        "ssl_cert" \
        "SSL.*certificate|HTTPS.*failed|certificate.*expired" \
        "cd {site_path} && ddev restart" \
        "curl -sk https://{site}.ddev.site/ | head -1" \
        "medium"
}

################################################################################
# SECTION 2: Pattern Management
################################################################################

#######################################
# Register a fix pattern
# Arguments:
#   $1 - Pattern ID (unique identifier)
#   $2 - Regex pattern to match error messages
#   $3 - Fix command (with {placeholders})
#   $4 - Verification command
#   $5 - Severity (low/medium/high/critical)
#######################################
autofix_register_pattern() {
    local id="$1"
    local pattern="$2"
    local fix_cmd="$3"
    local verify_cmd="$4"
    local severity="${5:-medium}"

    AUTOFIX_PATTERNS[$id]="$pattern"
    AUTOFIX_PATTERN_FIX[$id]="$fix_cmd"
    AUTOFIX_PATTERN_VERIFY[$id]="$verify_cmd"
    AUTOFIX_PATTERN_SEVERITY[$id]="$severity"
}

#######################################
# Find matching pattern for an error message
# Arguments:
#   $1 - Error message
# Outputs: Pattern ID if found, empty otherwise
#######################################
autofix_find_pattern() {
    local error_msg="$1"

    for pattern_id in "${!AUTOFIX_PATTERNS[@]}"; do
        local pattern="${AUTOFIX_PATTERNS[$pattern_id]}"
        if echo "$error_msg" | grep -qiE "$pattern"; then
            echo "$pattern_id"
            return 0
        fi
    done

    return 1
}

################################################################################
# SECTION 3: Fix Analysis and Application
################################################################################

#######################################
# Analyze an error and suggest fixes
# Arguments:
#   $1 - Error message
#   $2 - Site name (optional)
#   $3 - Context (optional JSON with extra info)
# Outputs: JSON with analysis results
#######################################
autofix_analyze() {
    local error_msg="$1"
    local site="${2:-}"
    local context="${3:-{}}"

    ((AUTOFIX_TOTAL_ANALYZED++))

    local pattern_id
    pattern_id=$(autofix_find_pattern "$error_msg")

    if [[ -z "$pattern_id" ]]; then
        echo '{"can_fix": false, "reason": "No matching pattern found"}'
        return 1
    fi

    local fix_cmd="${AUTOFIX_PATTERN_FIX[$pattern_id]}"
    local verify_cmd="${AUTOFIX_PATTERN_VERIFY[$pattern_id]}"
    local severity="${AUTOFIX_PATTERN_SEVERITY[$pattern_id]}"

    # Substitute placeholders
    if [[ -n "$site" ]]; then
        local site_path="$PROJECT_ROOT/sites/$site"
        fix_cmd="${fix_cmd//\{site\}/$site}"
        fix_cmd="${fix_cmd//\{site_path\}/$site_path}"
        verify_cmd="${verify_cmd//\{site\}/$site}"
        verify_cmd="${verify_cmd//\{site_path\}/$site_path}"
    fi

    # Extract module name if present
    local module_name
    module_name=$(echo "$error_msg" | grep -oP "Module ['\"]\K[^'\"]+|module \K\w+" | head -1)
    if [[ -n "$module_name" ]]; then
        fix_cmd="${fix_cmd//\{module_name\}/$module_name}"
        fix_cmd="${fix_cmd//\{module\}/drupal/$module_name}"
        verify_cmd="${verify_cmd//\{module_name\}/$module_name}"
    fi

    # Record pattern match
    autofix_log "MATCH" "Pattern '$pattern_id' matched: $error_msg"

    cat << EOF
{
    "can_fix": true,
    "pattern_id": "$pattern_id",
    "severity": "$severity",
    "fix_command": "$fix_cmd",
    "verify_command": "$verify_cmd",
    "error_message": "$error_msg"
}
EOF
}

#######################################
# Apply a fix
# Arguments:
#   $1 - Pattern ID or fix command
#   $2 - Site name (optional)
#   $3 - Capture before state (true/false)
# Returns: 0 if fix succeeded, 1 if failed
#######################################
autofix_apply() {
    local input="$1"
    local site="${2:-}"
    local capture_before="${3:-true}"

    local fix_cmd
    local verify_cmd
    local pattern_id=""

    # Check if input is a pattern ID or direct command
    if [[ -n "${AUTOFIX_PATTERN_FIX[$input]:-}" ]]; then
        pattern_id="$input"
        fix_cmd="${AUTOFIX_PATTERN_FIX[$input]}"
        verify_cmd="${AUTOFIX_PATTERN_VERIFY[$input]}"
    else
        fix_cmd="$input"
        verify_cmd=""
    fi

    # Substitute site placeholders
    if [[ -n "$site" ]]; then
        local site_path="$PROJECT_ROOT/sites/$site"
        fix_cmd="${fix_cmd//\{site\}/$site}"
        fix_cmd="${fix_cmd//\{site_path\}/$site_path}"
        [[ -n "$verify_cmd" ]] && verify_cmd="${verify_cmd//\{site\}/$site}"
        [[ -n "$verify_cmd" ]] && verify_cmd="${verify_cmd//\{site_path\}/$site_path}"
    fi

    echo ""
    echo "Applying fix: ${pattern_id:-custom}"
    echo "─────────────────────────────────────────"
    echo "Command: $fix_cmd"

    # Capture before state
    local before_state=""
    if [[ "$capture_before" == "true" && -n "$site" ]]; then
        before_state=$(autofix_capture_state "$site")
    fi

    # Check dry-run mode
    if [[ "$AUTOFIX_DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would execute: $fix_cmd"
        autofix_log "DRY_RUN" "Would execute: $fix_cmd"
        return 0
    fi

    # Execute fix
    local output exit_code
    local start_time
    start_time=$(date +%s)

    autofix_log "APPLY" "Executing: $fix_cmd"

    output=$(eval "$fix_cmd" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Log output
    autofix_log "OUTPUT" "Exit: $exit_code, Output: ${output:0:500}"

    # Verify fix if verification command provided
    local verified=false
    if [[ -n "$verify_cmd" ]]; then
        echo "Verifying..."
        if eval "$verify_cmd" &>/dev/null; then
            verified=true
            echo -e "\033[0;32m✓\033[0m Fix verified successfully"
        else
            echo -e "\033[0;31m✗\033[0m Fix verification failed"
        fi
    else
        # No verify command - assume success based on exit code
        [[ $exit_code -eq 0 ]] && verified=true
    fi

    # Capture after state
    local after_state=""
    if [[ -n "$site" ]]; then
        after_state=$(autofix_capture_state "$site")
    fi

    # Record result
    if [[ "$verified" == "true" ]]; then
        ((AUTOFIX_TOTAL_FIXED++))
        autofix_record_fix "$pattern_id" "$fix_cmd" "$before_state" "$after_state" "success" "$duration"
        echo ""
        echo "Fix applied successfully (${duration}s)"
        return 0
    else
        ((AUTOFIX_TOTAL_FAILED++))
        autofix_record_fix "$pattern_id" "$fix_cmd" "$before_state" "$after_state" "failed" "$duration"
        echo ""
        echo "Fix failed or could not be verified"
        return 1
    fi
}

#######################################
# Verify a fix was successful
# Arguments:
#   $1 - Pattern ID or verification command
#   $2 - Site name (optional)
# Returns: 0 if verified, 1 if not
#######################################
autofix_verify() {
    local input="$1"
    local site="${2:-}"

    local verify_cmd

    # Check if input is a pattern ID
    if [[ -n "${AUTOFIX_PATTERN_VERIFY[$input]:-}" ]]; then
        verify_cmd="${AUTOFIX_PATTERN_VERIFY[$input]}"
    else
        verify_cmd="$input"
    fi

    # Substitute placeholders
    if [[ -n "$site" ]]; then
        local site_path="$PROJECT_ROOT/sites/$site"
        verify_cmd="${verify_cmd//\{site\}/$site}"
        verify_cmd="${verify_cmd//\{site_path\}/$site_path}"
    fi

    echo "Verifying: $verify_cmd"

    if eval "$verify_cmd" &>/dev/null; then
        echo -e "\033[0;32m✓\033[0m Verification passed"
        return 0
    else
        echo -e "\033[0;31m✗\033[0m Verification failed"
        return 1
    fi
}

################################################################################
# SECTION 4: State Capture and Logging
################################################################################

#######################################
# Capture site state for before/after comparison
# Arguments:
#   $1 - Site name
# Outputs: JSON state object
#######################################
autofix_capture_state() {
    local site="$1"
    local site_path="$PROJECT_ROOT/sites/$site"

    if [[ ! -d "$site_path" ]]; then
        echo '{"error": "site_not_found"}'
        return
    fi

    local ddev_status db_status user_count timestamp
    timestamp=$(date -Iseconds)

    # DDEV status
    ddev_status=$(cd "$site_path" && ddev describe 2>/dev/null | grep -q "running" && echo "running" || echo "stopped")

    # DB status
    db_status=$(cd "$site_path" && ddev drush status --field=db-status 2>/dev/null || echo "unknown")

    # User count
    user_count=$(cd "$site_path" && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data" 2>/dev/null | tr -d '[:space:]')

    cat << EOF
{
    "timestamp": "$timestamp",
    "site": "$site",
    "ddev_status": "$ddev_status",
    "db_status": "$db_status",
    "user_count": "${user_count:-0}"
}
EOF
}

#######################################
# Log an auto-fix action
# Arguments:
#   $1 - Level (INFO, MATCH, APPLY, OUTPUT, ERROR, SUCCESS, FAILED)
#   $2 - Message
#######################################
autofix_log() {
    local level="$1"
    local message="$2"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$AUTOFIX_LOG_FILE"
}

#######################################
# Record a fix attempt in findings
# Arguments:
#   $1 - Pattern ID
#   $2 - Command executed
#   $3 - Before state (JSON)
#   $4 - After state (JSON)
#   $5 - Result (success/failed)
#   $6 - Duration in seconds
#######################################
autofix_record_fix() {
    local pattern_id="$1"
    local command="$2"
    local before_state="$3"
    local after_state="$4"
    local result="$5"
    local duration="$6"

    if command -v jq &>/dev/null && [[ -f "$AUTOFIX_FINDINGS_FILE" ]]; then
        local timestamp
        timestamp=$(date -Iseconds)

        local fix_record
        fix_record=$(jq -n \
            --arg ts "$timestamp" \
            --arg pid "${pattern_id:-custom}" \
            --arg cmd "$command" \
            --arg result "$result" \
            --argjson duration "$duration" \
            --argjson before "${before_state:-null}" \
            --argjson after "${after_state:-null}" \
            '{
                timestamp: $ts,
                pattern_id: $pid,
                command: $cmd,
                result: $result,
                duration_seconds: $duration,
                state_before: $before,
                state_after: $after
            }')

        local target_array
        [[ "$result" == "success" ]] && target_array="fixes_applied" || target_array="fixes_failed"

        jq ".$target_array += [$fix_record]" "$AUTOFIX_FINDINGS_FILE" > "${AUTOFIX_FINDINGS_FILE}.tmp" && \
        mv "${AUTOFIX_FINDINGS_FILE}.tmp" "$AUTOFIX_FINDINGS_FILE"

        # Update summary
        jq ".summary.analyzed = $AUTOFIX_TOTAL_ANALYZED |
            .summary.fixed = $AUTOFIX_TOTAL_FIXED |
            .summary.failed = $AUTOFIX_TOTAL_FAILED |
            .summary.skipped = $AUTOFIX_TOTAL_SKIPPED" \
            "$AUTOFIX_FINDINGS_FILE" > "${AUTOFIX_FINDINGS_FILE}.tmp" && \
        mv "${AUTOFIX_FINDINGS_FILE}.tmp" "$AUTOFIX_FINDINGS_FILE"
    fi
}

################################################################################
# SECTION 5: Batch Operations
################################################################################

#######################################
# Attempt to fix all errors in a list
# Arguments:
#   $1 - Site name
#   $@ - Error messages (one per argument)
# Returns: Number of unfixed errors
#######################################
autofix_batch() {
    local site="$1"
    shift
    local errors=("$@")

    local fixed=0
    local failed=0

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Auto-Fix Batch: ${#errors[@]} errors to analyze"
    echo "═══════════════════════════════════════════════════════════════"

    for error in "${errors[@]}"; do
        echo ""
        echo "Analyzing: ${error:0:80}..."

        local analysis
        analysis=$(autofix_analyze "$error" "$site")

        if echo "$analysis" | jq -e '.can_fix == true' &>/dev/null; then
            local pattern_id
            pattern_id=$(echo "$analysis" | jq -r '.pattern_id')

            if autofix_apply "$pattern_id" "$site"; then
                ((fixed++))
            else
                ((failed++))
            fi
        else
            echo "  No auto-fix available"
            ((AUTOFIX_TOTAL_SKIPPED++))
        fi
    done

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Batch complete: $fixed fixed, $failed failed, $AUTOFIX_TOTAL_SKIPPED skipped"
    echo "═══════════════════════════════════════════════════════════════"

    return $failed
}

#######################################
# Auto-fix common issues for a site
# Arguments:
#   $1 - Site name
# Returns: 0 if site is healthy, 1 if issues remain
#######################################
autofix_site() {
    local site="$1"

    if [[ -z "$site" ]]; then
        echo "ERROR: autofix_site requires a site name" >&2
        return 1
    fi

    local site_path="$PROJECT_ROOT/sites/$site"

    if [[ ! -d "$site_path" ]]; then
        echo "ERROR: Site $site does not exist" >&2
        return 1
    fi

    echo ""
    echo "Auto-fixing common issues for: $site"
    echo "═══════════════════════════════════════════════════════════════"

    local issues_found=0

    # Check DDEV status
    if ! (cd "$site_path" && ddev describe 2>/dev/null | grep -q "running"); then
        echo ""
        echo "Issue: DDEV not running"
        autofix_apply "ddev_not_running" "$site" && ((AUTOFIX_TOTAL_FIXED++)) || ((issues_found++))
    fi

    # Check database connection
    if ! (cd "$site_path" && ddev drush status --field=db-status 2>/dev/null | grep -qi "connected"); then
        echo ""
        echo "Issue: Database not connected"
        autofix_apply "db_connection" "$site" && ((AUTOFIX_TOTAL_FIXED++)) || ((issues_found++))
    fi

    # Check for pending updates
    local pending_updates
    pending_updates=$(cd "$site_path" && ddev drush updb --no 2>&1)
    if echo "$pending_updates" | grep -qi "pending\|available"; then
        echo ""
        echo "Issue: Database updates pending"
        autofix_apply "db_updates_pending" "$site" && ((AUTOFIX_TOTAL_FIXED++)) || ((issues_found++))
    fi

    # Clear cache as general fix
    echo ""
    echo "Clearing cache..."
    (cd "$site_path" && ddev drush cr &>/dev/null) && echo "  Cache cleared" || echo "  Cache clear failed"

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    if [[ $issues_found -eq 0 ]]; then
        echo "  Site $site is healthy"
        return 0
    else
        echo "  $issues_found issue(s) could not be auto-fixed"
        return 1
    fi
}

################################################################################
# SECTION 6: Summary and Help
################################################################################

#######################################
# Display auto-fix summary
#######################################
autofix_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    Auto-Fix Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Errors analyzed:  $AUTOFIX_TOTAL_ANALYZED"
    echo "  Fixes applied:    $AUTOFIX_TOTAL_FIXED"
    echo "  Fixes failed:     $AUTOFIX_TOTAL_FAILED"
    echo "  Skipped:          $AUTOFIX_TOTAL_SKIPPED"
    echo ""
    echo "  Registered patterns: ${#AUTOFIX_PATTERNS[@]}"
    echo ""
    echo "  Log file: $AUTOFIX_LOG_FILE"
    echo "  Findings: $AUTOFIX_FINDINGS_FILE"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
}

#######################################
# Get findings as JSON
#######################################
autofix_get_findings() {
    if [[ -f "$AUTOFIX_FINDINGS_FILE" ]]; then
        cat "$AUTOFIX_FINDINGS_FILE"
    else
        echo '{"findings": [], "summary": {"analyzed": 0, "fixed": 0}}'
    fi
}

#######################################
# List registered patterns
#######################################
autofix_list_patterns() {
    echo ""
    echo "Registered Auto-Fix Patterns"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    printf "%-20s %-10s %s\n" "ID" "SEVERITY" "PATTERN"
    printf "%-20s %-10s %s\n" "──────────────────" "────────" "───────────────────────────────"

    for id in $(echo "${!AUTOFIX_PATTERNS[@]}" | tr ' ' '\n' | sort); do
        local severity="${AUTOFIX_PATTERN_SEVERITY[$id]}"
        local pattern="${AUTOFIX_PATTERNS[$id]}"
        printf "%-20s %-10s %s\n" "$id" "$severity" "${pattern:0:40}..."
    done

    echo ""
    echo "Total: ${#AUTOFIX_PATTERNS[@]} patterns"
}

#######################################
# Print auto-fix help
#######################################
autofix_help() {
    cat << 'EOF'
NWP Auto-Fix Engine (P51 Phase 4)

Analysis:
  autofix_analyze ERROR [SITE] [CONTEXT]   Analyze error and suggest fix
  autofix_find_pattern ERROR               Find matching pattern for error

Fixing:
  autofix_apply PATTERN|CMD SITE [CAPTURE] Apply a fix
  autofix_verify PATTERN|CMD [SITE]        Verify fix was successful
  autofix_batch SITE ERROR...              Fix multiple errors
  autofix_site SITE                        Auto-fix common issues

Pattern Management:
  autofix_register_pattern ID PATTERN FIX VERIFY SEVERITY
  autofix_list_patterns                    List all registered patterns

Results:
  autofix_summary                          Show fix summary
  autofix_get_findings                     Get findings as JSON

Configuration:
  AUTOFIX_DRY_RUN         Set to "true" to preview without applying
  AUTOFIX_MAX_ATTEMPTS    Maximum fix attempts (default: 3)

Examples:
  # Analyze and fix an error
  analysis=$(autofix_analyze "Permission denied on files" mysite)
  autofix_apply "$(echo "$analysis" | jq -r '.pattern_id')" mysite

  # Auto-fix common issues
  autofix_site mysite

  # Batch fix
  autofix_batch mysite "Error 1" "Error 2" "Error 3"
EOF
}

#######################################
# CLI entry point
#######################################
autofix_main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        init)
            autofix_init
            ;;
        analyze)
            autofix_analyze "$@"
            ;;
        apply)
            autofix_apply "$@"
            ;;
        verify)
            autofix_verify "$@"
            ;;
        batch)
            autofix_batch "$@"
            ;;
        site)
            autofix_site "$@"
            ;;
        patterns)
            autofix_list_patterns
            ;;
        summary)
            autofix_summary
            ;;
        findings)
            autofix_get_findings
            ;;
        help|--help|-h)
            autofix_help
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run 'autofix_main help' for usage"
            return 1
            ;;
    esac
}

# Export functions
export -f autofix_init autofix_register_builtin_patterns
export -f autofix_register_pattern autofix_find_pattern
export -f autofix_analyze autofix_apply autofix_verify
export -f autofix_capture_state autofix_log autofix_record_fix
export -f autofix_batch autofix_site
export -f autofix_summary autofix_get_findings autofix_list_patterns
export -f autofix_help autofix_main
