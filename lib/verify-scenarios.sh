#!/bin/bash
################################################################################
# NWP AI Verification Scenario Framework
#
# Part of P51: AI-Powered Deep Verification
#
# This library provides the scenario execution framework for AI-driven
# verification. It parses scenario YAML files, resolves dependencies,
# executes verification steps, and manages checkpoints.
#
# Scenario YAML Schema:
# ----------------------
# scenario:
#   id: S1                              # Unique scenario ID (S1-S17)
#   name: "Foundation Setup"            # Human-readable name
#   description: "Description..."       # What this scenario verifies
#   depends_on: []                       # List of scenario IDs that must pass first
#   estimated_duration: 5               # Expected duration in minutes
#   is_gate: false                      # If true, failure blocks all other scenarios
#
#   commands_tested:                    # Commands verified by this scenario
#     - setup.sh
#     - doctor.sh
#
#   live_state_commands:                # Commands reporting live state
#     - command: pl doctor
#       validates:
#         - Docker availability
#         - DDEV status
#
#   steps:                              # Ordered list of verification steps
#     - name: "Step name"
#       cmd: "command to run"           # Bash command to execute
#       expect_exit: 0                  # Expected exit code (optional)
#       expect_contains: "text"         # Output must contain (optional)
#       expect_not_contains: "text"     # Output must not contain (optional)
#       timeout: 60                     # Step timeout in seconds (optional)
#       store_as: variable_name         # Store output in variable (optional)
#       on_failure:                     # Action on failure (optional)
#         severity: critical|high|warning
#         message: "Error message"
#       validate:                       # Sub-validations (optional)
#         - name: "Sub-check name"
#           cmd: "validation command"
#           expect_exit: 0
#       live_state:                     # Cross-validation (optional)
#         command: "pl command"
#         verify: "verification command"
#         tolerance: 0
#
#   capture_baseline:                   # Values to capture before testing
#     variable_name:
#       cmd: "command"
#       store_as: "name"
#       expected: value                 # Optional expected value
#
#   cleanup:                            # Cleanup commands run after scenario
#     - cmd: "cleanup command"
#
#   success_criteria:                   # What constitutes success
#     all_required:
#       - "Criterion 1"
#       - "Criterion 2"
#
# Source this file: source "$PROJECT_ROOT/lib/verify-scenarios.sh"
#
# Dependencies:
#   - lib/verify-runner.sh (P50 infrastructure)
#   - yq (YAML parsing)
#
# Reference:
#   - P51: AI-Powered Deep Verification
#   - docs/proposals/P51-ai-powered-verification.md
################################################################################

# Note: Don't use set -e as we need to handle failures gracefully
# set -u is also avoided for uninitialized variables

# Determine paths
SCENARIO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCENARIO_LIB_DIR/.." && pwd)}"

# Make PROJECT_ROOT available if not set
PROJECT_ROOT="${PROJECT_ROOT:-$SCENARIO_PROJECT_ROOT}"

# Configuration
SCENARIO_DIR="${SCENARIO_DIR:-$SCENARIO_PROJECT_ROOT/.verification-scenarios}"
CHECKPOINT_FILE="${CHECKPOINT_FILE:-$SCENARIO_PROJECT_ROOT/.verification-checkpoint.yml}"
PEAKS_FILE="${PEAKS_FILE:-$SCENARIO_PROJECT_ROOT/.verification-peaks.yml}"
FINDINGS_DIR="${FINDINGS_DIR:-$SCENARIO_PROJECT_ROOT/.logs/verification}"

# Source P50 infrastructure if available
if [[ -f "$SCENARIO_PROJECT_ROOT/lib/verify-runner.sh" ]]; then
    source "$SCENARIO_PROJECT_ROOT/lib/verify-runner.sh"
fi

# Source UI library for colors
if [[ -f "$SCENARIO_PROJECT_ROOT/lib/ui.sh" ]]; then
    source "$SCENARIO_PROJECT_ROOT/lib/ui.sh"
fi

################################################################################
# SECTION 1: Utility Functions
################################################################################

#######################################
# Check if yq is available for YAML parsing
# Returns: 0 if available, 1 if not
#######################################
scenario_check_yq() {
    if ! command -v yq &>/dev/null; then
        echo "ERROR: yq is required for scenario parsing." >&2
        echo "Install Go yq: https://github.com/mikefarah/yq" >&2
        return 1
    fi
    return 0
}

#######################################
# Wrapper for yq that handles both Go (mikefarah) and Python versions
# Arguments:
#   $1 - YAML path expression (Go yq syntax)
#   $2 - File path
# Outputs: Value at path or empty string
#######################################
_yq_get() {
    local path="$1"
    local file="$2"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    # Try Go yq syntax first (mikefarah/yq)
    local result
    result=$(yq eval "$path" "$file" 2>/dev/null)

    # Handle null/empty
    if [[ "$result" == "null" || -z "$result" ]]; then
        echo ""
    else
        echo "$result"
    fi
}

#######################################
# Get current timestamp in ISO format
# Outputs: ISO timestamp string
#######################################
scenario_timestamp() {
    date -Iseconds
}

#######################################
# Generate a unique run ID
# Outputs: Run ID string
#######################################
scenario_generate_run_id() {
    echo "ai-verify-$(date +%Y%m%d-%H%M%S)"
}

################################################################################
# SECTION 2: Scenario Loading and Parsing
################################################################################

#######################################
# List all available scenario files
# Outputs: List of scenario file paths, one per line
#######################################
scenario_list_files() {
    if [[ -d "$SCENARIO_DIR" ]]; then
        find "$SCENARIO_DIR" -name "S*.yml" -type f | sort
    fi
}

#######################################
# Get the path to a scenario file by ID
# Arguments:
#   $1 - Scenario ID (e.g., S1, S03, S17)
# Outputs: Full path to scenario file
# Returns: 0 if found, 1 if not
#######################################
scenario_get_file() {
    local id="$1"
    # Normalize ID to two-digit format
    local num="${id#S}"
    local normalized_id
    printf -v normalized_id "S%02d" "$num"

    # Try both formats
    local file="$SCENARIO_DIR/${normalized_id}-*.yml"
    local match
    match=$(ls $file 2>/dev/null | head -1)

    if [[ -n "$match" && -f "$match" ]]; then
        echo "$match"
        return 0
    fi

    # Try without leading zero
    file="$SCENARIO_DIR/S${num}-*.yml"
    match=$(ls $file 2>/dev/null | head -1)

    if [[ -n "$match" && -f "$match" ]]; then
        echo "$match"
        return 0
    fi

    return 1
}

#######################################
# Parse a scenario file and extract a field
# Arguments:
#   $1 - Scenario file path
#   $2 - YAML path (e.g., ".scenario.id", ".scenario.name")
# Outputs: Field value
#######################################
scenario_get_field() {
    local file="$1"
    local path="$2"

    _yq_get "$path" "$file"
}

#######################################
# Get scenario ID from a scenario file
# Arguments:
#   $1 - Scenario file path
# Outputs: Scenario ID
#######################################
scenario_get_id() {
    scenario_get_field "$1" ".scenario.id"
}

#######################################
# Get scenario name from a scenario file
# Arguments:
#   $1 - Scenario file path
# Outputs: Scenario name
#######################################
scenario_get_name() {
    scenario_get_field "$1" ".scenario.name"
}

#######################################
# Get scenario dependencies from a scenario file
# Arguments:
#   $1 - Scenario file path
# Outputs: Space-separated list of dependency IDs
#######################################
scenario_get_dependencies() {
    local file="$1"
    scenario_get_field "$file" '.scenario.depends_on | if type == "array" then .[] else empty end' | tr '\n' ' '
}

#######################################
# Check if a scenario is a gate (blocks others on failure)
# Arguments:
#   $1 - Scenario file path
# Returns: 0 if gate, 1 if not
#######################################
scenario_is_gate() {
    local file="$1"
    local is_gate
    is_gate=$(scenario_get_field "$file" ".scenario.is_gate")
    [[ "$is_gate" == "true" ]]
}

#######################################
# Get the number of steps in a scenario
# Arguments:
#   $1 - Scenario file path
# Outputs: Number of steps
#######################################
scenario_get_step_count() {
    local file="$1"
    scenario_get_field "$file" '.scenario.steps | length'
}

#######################################
# Get step details from a scenario
# Arguments:
#   $1 - Scenario file path
#   $2 - Step index (0-based)
# Outputs: Step YAML content
#######################################
scenario_get_step() {
    local file="$1"
    local index="$2"

    yq ".scenario.steps[$index]" "$file" 2>/dev/null
}

#######################################
# Get step name from a scenario
# Arguments:
#   $1 - Scenario file path
#   $2 - Step index (0-based)
# Outputs: Step name
#######################################
scenario_get_step_name() {
    local file="$1"
    local index="$2"

    scenario_get_field "$file" ".scenario.steps[$index].name"
}

#######################################
# Get step command from a scenario
# Arguments:
#   $1 - Scenario file path
#   $2 - Step index (0-based)
# Outputs: Step command
#######################################
scenario_get_step_cmd() {
    local file="$1"
    local index="$2"

    scenario_get_field "$file" ".scenario.steps[$index].cmd"
}

#######################################
# Get step expected exit code
# Arguments:
#   $1 - Scenario file path
#   $2 - Step index (0-based)
# Outputs: Expected exit code (default: 0)
#######################################
scenario_get_step_exit() {
    local file="$1"
    local index="$2"
    local exit_code

    exit_code=$(scenario_get_field "$file" ".scenario.steps[$index].expect_exit")
    echo "${exit_code:-0}"
}

#######################################
# Get step timeout
# Arguments:
#   $1 - Scenario file path
#   $2 - Step index (0-based)
# Outputs: Timeout in seconds (default: 60)
#######################################
scenario_get_step_timeout() {
    local file="$1"
    local index="$2"
    local timeout

    timeout=$(scenario_get_field "$file" ".scenario.steps[$index].timeout")
    echo "${timeout:-60}"
}

################################################################################
# SECTION 3: Dependency Resolution
################################################################################

# Global arrays for dependency resolution
declare -a SCENARIO_ORDER=()
declare -A SCENARIO_VISITED=()
declare -A SCENARIO_PROCESSING=()

#######################################
# Topological sort helper for dependency resolution
# Arguments:
#   $1 - Scenario ID to process
# Returns: 0 on success, 1 on cycle detected
#######################################
_scenario_topo_visit() {
    local id="$1"

    # Check for cycle
    if [[ "${SCENARIO_PROCESSING[$id]:-}" == "1" ]]; then
        echo "ERROR: Circular dependency detected involving $id" >&2
        return 1
    fi

    # Skip if already visited
    if [[ "${SCENARIO_VISITED[$id]:-}" == "1" ]]; then
        return 0
    fi

    SCENARIO_PROCESSING[$id]=1

    # Get scenario file and dependencies
    local file
    file=$(scenario_get_file "$id")

    if [[ -z "$file" ]]; then
        echo "WARNING: Scenario $id not found, skipping" >&2
        SCENARIO_VISITED[$id]=1
        unset SCENARIO_PROCESSING[$id]
        return 0
    fi

    local deps
    deps=$(scenario_get_dependencies "$file")

    # Process dependencies first
    for dep in $deps; do
        if [[ -n "$dep" ]]; then
            _scenario_topo_visit "$dep" || return 1
        fi
    done

    # Mark as visited and add to order
    SCENARIO_VISITED[$id]=1
    unset SCENARIO_PROCESSING[$id]
    SCENARIO_ORDER+=("$id")

    return 0
}

#######################################
# Resolve scenario execution order based on dependencies
# Arguments:
#   [optional] List of scenario IDs to include (default: all)
# Outputs: Space-separated list of scenario IDs in execution order
# Returns: 0 on success, 1 on error
#######################################
scenario_resolve_order() {
    local scenarios=("$@")

    # Reset global arrays
    SCENARIO_ORDER=()
    SCENARIO_VISITED=()
    SCENARIO_PROCESSING=()

    # If no scenarios specified, get all available
    if [[ ${#scenarios[@]} -eq 0 ]]; then
        local files
        files=$(scenario_list_files)
        for file in $files; do
            local id
            id=$(scenario_get_id "$file")
            if [[ -n "$id" ]]; then
                scenarios+=("$id")
            fi
        done
    fi

    # Topological sort
    for id in "${scenarios[@]}"; do
        _scenario_topo_visit "$id" || return 1
    done

    echo "${SCENARIO_ORDER[*]}"
    return 0
}

#######################################
# Check if all dependencies of a scenario are satisfied
# Arguments:
#   $1 - Scenario ID
#   $2... - List of completed scenario IDs
# Returns: 0 if satisfied, 1 if not
#######################################
scenario_deps_satisfied() {
    local id="$1"
    shift
    local completed=("$@")

    local file
    file=$(scenario_get_file "$id")

    if [[ -z "$file" ]]; then
        return 1
    fi

    local deps
    deps=$(scenario_get_dependencies "$file")

    for dep in $deps; do
        if [[ -n "$dep" ]]; then
            local found=0
            for comp in "${completed[@]}"; do
                if [[ "$comp" == "$dep" ]]; then
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                return 1
            fi
        fi
    done

    return 0
}

################################################################################
# SECTION 4: Checkpoint Management
################################################################################

#######################################
# Initialize a new verification checkpoint
# Arguments:
#   $1 - Run ID (optional, generates if not provided)
# Outputs: Path to checkpoint file
#######################################
checkpoint_init() {
    local run_id="${1:-$(scenario_generate_run_id)}"
    local timestamp
    timestamp=$(scenario_timestamp)

    mkdir -p "$(dirname "$CHECKPOINT_FILE")"

    cat > "$CHECKPOINT_FILE" << EOF
# AI Verification Checkpoint
# Generated by P51 verify-scenarios.sh
# DO NOT EDIT MANUALLY

checkpoint:
  run_id: "$run_id"
  started_at: "$timestamp"
  last_updated: "$timestamp"

  progress:
    scenarios:
      total: 17
      completed: 0
      in_progress: 0
      remaining: 17
    items:
      total: 471
      verified: 0

  current:
    scenario: null
    step: 0
    step_name: null

  test_sites: []

  completed_scenarios: []

  findings: []

  errors_fixed: 0
  errors_pending: 0
EOF

    echo "$CHECKPOINT_FILE"
}

#######################################
# Check if a checkpoint exists and is valid
# Returns: 0 if valid checkpoint exists, 1 if not
#######################################
checkpoint_exists() {
    [[ -f "$CHECKPOINT_FILE" ]] && scenario_check_yq
}

#######################################
# Get a field from the checkpoint
# Arguments:
#   $1 - YAML path (e.g., ".checkpoint.run_id")
# Outputs: Field value
#######################################
checkpoint_get() {
    local path="$1"

    if [[ ! -f "$CHECKPOINT_FILE" ]]; then
        return 1
    fi

    # Handle paths with pipes by wrapping in parentheses for the alternative operator
    # yq v4 doesn't support "empty" like jq, use "" as default
    local result
    if [[ "$path" == *"|"* ]]; then
        # Path contains pipe - wrap in parentheses
        result=$(yq -r "($path) // \"\"" "$CHECKPOINT_FILE" 2>/dev/null)
    else
        result=$(yq -r "$path // \"\"" "$CHECKPOINT_FILE" 2>/dev/null)
    fi

    # Return empty string for null
    [[ "$result" == "null" ]] && result=""
    echo "$result"
}

#######################################
# Update a field in the checkpoint
# Arguments:
#   $1 - YAML path
#   $2 - New value
#######################################
checkpoint_set() {
    local path="$1"
    local value="$2"

    if [[ ! -f "$CHECKPOINT_FILE" ]]; then
        return 1
    fi

    # Update last_updated timestamp too
    local timestamp
    timestamp=$(scenario_timestamp)

    yq -i "$path = \"$value\" | .checkpoint.last_updated = \"$timestamp\"" "$CHECKPOINT_FILE"
}

#######################################
# Update checkpoint progress counters
# Arguments:
#   $1 - Completed count
#   $2 - In-progress count (optional)
#######################################
checkpoint_update_progress() {
    local completed="$1"
    local in_progress="${2:-0}"
    local remaining=$((17 - completed - in_progress))
    local timestamp
    timestamp=$(scenario_timestamp)

    yq -i "
        .checkpoint.progress.scenarios.completed = $completed |
        .checkpoint.progress.scenarios.in_progress = $in_progress |
        .checkpoint.progress.scenarios.remaining = $remaining |
        .checkpoint.last_updated = \"$timestamp\"
    " "$CHECKPOINT_FILE"
}

#######################################
# Mark a scenario as started
# Arguments:
#   $1 - Scenario ID
#   $2 - Step number (optional, default 0)
#######################################
checkpoint_start_scenario() {
    local id="$1"
    local step="${2:-0}"
    local file
    file=$(scenario_get_file "$id")
    local name
    name=$(scenario_get_name "$file")
    local timestamp
    timestamp=$(scenario_timestamp)

    yq -i "
        .checkpoint.current.scenario = \"$id\" |
        .checkpoint.current.step = $step |
        .checkpoint.current.step_name = \"Starting\" |
        .checkpoint.last_updated = \"$timestamp\"
    " "$CHECKPOINT_FILE"
}

#######################################
# Update current step in checkpoint
# Arguments:
#   $1 - Step number
#   $2 - Step name
#######################################
checkpoint_update_step() {
    local step="$1"
    local name="$2"
    local timestamp
    timestamp=$(scenario_timestamp)

    yq -i "
        .checkpoint.current.step = $step |
        .checkpoint.current.step_name = \"$name\" |
        .checkpoint.last_updated = \"$timestamp\"
    " "$CHECKPOINT_FILE"
}

#######################################
# Mark a scenario as completed
# Arguments:
#   $1 - Scenario ID
#   $2 - Status (passed/failed)
#   $3 - Duration in seconds
#   $4 - Confidence percentage
#   $5 - Items verified (optional)
#######################################
checkpoint_complete_scenario() {
    local id="$1"
    local status="$2"
    local duration="$3"
    local confidence="$4"
    local items="${5:-0}"
    local timestamp
    timestamp=$(scenario_timestamp)

    # Add to completed_scenarios array
    yq -i "
        .checkpoint.completed_scenarios += [{
            \"id\": \"$id\",
            \"status\": \"$status\",
            \"duration\": $duration,
            \"confidence\": $confidence,
            \"items_verified\": $items,
            \"completed_at\": \"$timestamp\"
        }] |
        .checkpoint.current.scenario = null |
        .checkpoint.current.step = 0 |
        .checkpoint.current.step_name = null |
        .checkpoint.last_updated = \"$timestamp\"
    " "$CHECKPOINT_FILE"

    # Update progress
    local completed
    completed=$(checkpoint_get '.checkpoint.completed_scenarios | length')
    checkpoint_update_progress "$completed"
}

#######################################
# Add a finding to the checkpoint
# Arguments:
#   $1 - Scenario ID
#   $2 - Step number
#   $3 - Type (warning/error/fixed)
#   $4 - Message
#######################################
checkpoint_add_finding() {
    local scenario="$1"
    local step="$2"
    local type="$3"
    local message="$4"
    local timestamp
    timestamp=$(scenario_timestamp)

    yq -i "
        .checkpoint.findings += [{
            \"scenario\": \"$scenario\",
            \"step\": $step,
            \"type\": \"$type\",
            \"message\": \"$message\",
            \"timestamp\": \"$timestamp\"
        }] |
        .checkpoint.last_updated = \"$timestamp\"
    " "$CHECKPOINT_FILE"
}

#######################################
# Add a test site to preserve list
# Arguments:
#   $1 - Site name
#   $2 - Reason
#######################################
checkpoint_add_test_site() {
    local name="$1"
    local reason="$2"

    yq -i "
        .checkpoint.test_sites += [{
            \"name\": \"$name\",
            \"preserve\": true,
            \"reason\": \"$reason\"
        }]
    " "$CHECKPOINT_FILE"
}

#######################################
# Get list of completed scenario IDs
# Outputs: Space-separated list of IDs
#######################################
checkpoint_get_completed() {
    if [[ ! -f "$CHECKPOINT_FILE" ]]; then
        return
    fi

    yq -r '.checkpoint.completed_scenarios[].id // empty' "$CHECKPOINT_FILE" 2>/dev/null | tr '\n' ' '
}

#######################################
# Get checkpoint summary for resume display
# Outputs: Human-readable summary
#######################################
checkpoint_summary() {
    if [[ ! -f "$CHECKPOINT_FILE" ]]; then
        echo "No checkpoint found"
        return 1
    fi

    local run_id
    run_id=$(checkpoint_get '.checkpoint.run_id')
    local last_updated
    last_updated=$(checkpoint_get '.checkpoint.last_updated')
    local completed
    completed=$(checkpoint_get '.checkpoint.progress.scenarios.completed')
    local total
    total=$(checkpoint_get '.checkpoint.progress.scenarios.total')
    local current
    current=$(checkpoint_get '.checkpoint.current.scenario')
    local current_step
    current_step=$(checkpoint_get '.checkpoint.current.step')

    echo "Run ID: $run_id"
    echo "Last Updated: $last_updated"
    echo "Progress: $completed/$total scenarios complete"

    if [[ -n "$current" && "$current" != "null" ]]; then
        echo "Current: $current (step $current_step)"
    fi
}

################################################################################
# SECTION 5: Step Execution
################################################################################

# Store captured values during execution
declare -A SCENARIO_CAPTURED=()

#######################################
# Execute a single step command with timeout
# Arguments:
#   $1 - Command to run
#   $2 - Timeout in seconds
# Outputs: Command output
# Returns: Command exit code
#######################################
step_execute_cmd() {
    local cmd="$1"
    local timeout="${2:-60}"
    local output
    local exit_code

    # Substitute captured variables
    for var in "${!SCENARIO_CAPTURED[@]}"; do
        cmd="${cmd//\{$var\}/${SCENARIO_CAPTURED[$var]}}"
    done

    # Execute with timeout
    output=$(timeout "$timeout" bash -c "$cmd" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    echo "$output"
    return $exit_code
}

#######################################
# Execute a scenario step
# Arguments:
#   $1 - Scenario file path
#   $2 - Step index
# Returns: 0 on success, 1 on failure
#######################################
step_execute() {
    local file="$1"
    local index="$2"

    local name
    name=$(scenario_get_step_name "$file" "$index")
    local cmd
    cmd=$(scenario_get_step_cmd "$file" "$index")
    local expected_exit
    expected_exit=$(scenario_get_step_exit "$file" "$index")
    local timeout
    timeout=$(scenario_get_step_timeout "$file" "$index")
    local expect_contains
    expect_contains=$(scenario_get_field "$file" ".scenario.steps[$index].expect_contains")
    local store_as
    store_as=$(scenario_get_field "$file" ".scenario.steps[$index].store_as")

    if [[ -z "$cmd" ]]; then
        echo "  ├─ $name: No command specified"
        return 0
    fi

    echo -n "  ├─ $name... "

    local output
    local actual_exit

    output=$(step_execute_cmd "$cmd" "$timeout") || actual_exit=$?
    actual_exit=${actual_exit:-0}

    # Store output if requested
    if [[ -n "$store_as" ]]; then
        SCENARIO_CAPTURED[$store_as]="$output"
    fi

    # Check exit code
    if [[ "$actual_exit" -ne "$expected_exit" ]]; then
        echo "FAILED (exit $actual_exit, expected $expected_exit)"
        echo "    Output: ${output:0:200}"
        return 1
    fi

    # Check contains
    if [[ -n "$expect_contains" && ! "$output" =~ $expect_contains ]]; then
        echo "FAILED (output missing: $expect_contains)"
        return 1
    fi

    echo "✓"
    return 0
}

################################################################################
# SECTION 6: Scenario Execution
################################################################################

#######################################
# Execute a complete scenario
# Arguments:
#   $1 - Scenario ID or file path
# Returns: 0 on success, 1 on failure
#######################################
scenario_execute() {
    local input="$1"
    local file
    local id

    # Get file path and ID
    if [[ -f "$input" ]]; then
        file="$input"
        id=$(scenario_get_id "$file")
    else
        id="$input"
        file=$(scenario_get_file "$id")
    fi

    if [[ -z "$file" || ! -f "$file" ]]; then
        echo "ERROR: Scenario $input not found" >&2
        return 1
    fi

    local name
    name=$(scenario_get_name "$file")
    local step_count
    step_count=$(scenario_get_step_count "$file")
    local description
    description=$(scenario_get_field "$file" ".scenario.description")

    local start_time
    start_time=$(date +%s)

    echo ""
    echo "[$id] $name ($step_count steps)"
    echo "  Description: $description"
    echo ""

    # Update checkpoint
    if checkpoint_exists; then
        checkpoint_start_scenario "$id"
    fi

    # Reset captured variables for this scenario
    SCENARIO_CAPTURED=()

    # Execute setup if present
    local setup_count
    setup_count=$(scenario_get_field "$file" '.scenario.setup | length')
    if [[ "$setup_count" -gt 0 ]]; then
        echo "  Setup:"
        for ((i=0; i<setup_count; i++)); do
            local setup_cmd
            local setup_name
            local setup_timeout=180

            # Try flat structure first: setup[i].cmd
            setup_cmd=$(scenario_get_field "$file" ".scenario.setup[$i].cmd")

            # If empty, try named structure: setup[i].<name>.cmd
            if [[ -z "$setup_cmd" ]]; then
                setup_cmd=$(yq eval ".scenario.setup[$i] | to_entries | .[0].value.cmd" "$file" 2>/dev/null)
                setup_name=$(yq eval ".scenario.setup[$i] | to_entries | .[0].key" "$file" 2>/dev/null)
                # Get timeout from named structure if present
                local named_timeout
                named_timeout=$(yq eval ".scenario.setup[$i] | to_entries | .[0].value.timeout" "$file" 2>/dev/null)
                [[ "$named_timeout" != "null" && -n "$named_timeout" ]] && setup_timeout="$named_timeout"
            else
                setup_name=$(scenario_get_field "$file" ".scenario.setup[$i]" | yq 'keys[0]' 2>/dev/null || echo "Setup step $((i+1))")
            fi

            if [[ -n "$setup_cmd" && "$setup_cmd" != "null" ]]; then
                [[ -z "$setup_name" || "$setup_name" == "null" ]] && setup_name="Setup step $((i+1))"
                echo -n "  ├─ $setup_name... "
                local setup_output
                setup_output=$(step_execute_cmd "$setup_cmd" "$setup_timeout" 2>&1)
                local setup_exit=$?
                if [[ $setup_exit -eq 0 ]]; then
                    echo "✓"
                else
                    echo "FAILED (exit $setup_exit)"
                    # Show last few lines of output for debugging
                    if [[ -n "$setup_output" ]]; then
                        echo "  │   Error output:"
                        echo "$setup_output" | tail -5 | sed 's/^/  │   /'
                    fi
                fi
            fi
        done
        echo ""
    fi

    # Execute capture_baseline if present
    local baseline_vars
    baseline_vars=$(scenario_get_field "$file" '.scenario.capture_baseline | keys | .[]' 2>/dev/null)
    if [[ -n "$baseline_vars" ]]; then
        echo "  Capturing baseline:"
        for var in $baseline_vars; do
            local capture_cmd
            capture_cmd=$(scenario_get_field "$file" ".scenario.capture_baseline.$var.cmd")
            if [[ -n "$capture_cmd" ]]; then
                local value
                value=$(step_execute_cmd "$capture_cmd" 30 2>/dev/null)
                SCENARIO_CAPTURED[$var]="$value"
                echo "    $var = $value"
            fi
        done
        echo ""
    fi

    # Execute steps
    local passed=0
    local failed=0

    for ((i=0; i<step_count; i++)); do
        if checkpoint_exists; then
            local step_name
            step_name=$(scenario_get_step_name "$file" "$i")
            checkpoint_update_step "$((i+1))" "$step_name"
        fi

        if step_execute "$file" "$i"; then
            ((passed++))
        else
            ((failed++))
            # Check if this is a critical failure
            local severity
            severity=$(scenario_get_field "$file" ".scenario.steps[$i].on_failure.severity")
            if [[ "$severity" == "critical" ]]; then
                echo "  └─ Critical failure - aborting scenario"
                break
            fi
        fi
    done

    # Execute cleanup
    local cleanup_count
    cleanup_count=$(scenario_get_field "$file" '.scenario.cleanup | length')
    if [[ "$cleanup_count" -gt 0 ]]; then
        echo ""
        echo "  Cleanup:"
        for ((i=0; i<cleanup_count; i++)); do
            local cleanup_cmd
            cleanup_cmd=$(scenario_get_field "$file" ".scenario.cleanup[$i].cmd")
            if [[ -n "$cleanup_cmd" ]]; then
                step_execute_cmd "$cleanup_cmd" 60 >/dev/null 2>&1 || true
                echo "  ├─ Cleanup step $((i+1)) done"
            fi
        done
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local confidence=0

    if [[ $step_count -gt 0 ]]; then
        confidence=$((passed * 100 / step_count))
    fi

    echo ""
    echo "  └─ Confidence: ${confidence}% ($passed/$step_count passed)"
    echo "     Duration: ${duration}s"

    # Update checkpoint
    if checkpoint_exists; then
        local status="passed"
        [[ $failed -gt 0 ]] && status="failed"
        checkpoint_complete_scenario "$id" "$status" "$duration" "$confidence" "$passed"
    fi

    [[ $failed -eq 0 ]]
}

#######################################
# Execute all scenarios in dependency order
# Arguments:
#   --dry-run: Show execution order without running
#   --resume: Resume from checkpoint
#   --fix: Enable auto-fix on errors
# Returns: 0 if all pass, 1 if any fail
#######################################
scenario_execute_all() {
    local dry_run=false
    local resume=false
    local auto_fix=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true ;;
            --resume) resume=true ;;
            --fix) auto_fix=true ;;
            *) break ;;
        esac
        shift
    done

    # Check yq
    if ! scenario_check_yq; then
        return 1
    fi

    # Resolve execution order
    local order
    order=$(scenario_resolve_order)

    if [[ -z "$order" ]]; then
        echo "No scenarios found in $SCENARIO_DIR"
        return 1
    fi

    local scenario_count
    scenario_count=$(echo "$order" | wc -w)

    echo ""
    echo "AI Deep Verification"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Scenario Execution Order ($scenario_count scenarios):"
    echo "  $order"
    echo ""

    if $dry_run; then
        echo "[DRY RUN] Would execute scenarios in the above order"
        return 0
    fi

    # Initialize or resume checkpoint
    local completed=()
    if $resume && checkpoint_exists; then
        echo "Resuming from checkpoint..."
        checkpoint_summary
        echo ""

        local completed_list
        completed_list=$(checkpoint_get_completed)
        read -ra completed <<< "$completed_list"
    else
        checkpoint_init
    fi

    # Execute scenarios
    local passed=0
    local failed=0
    local gate_failed=false

    for id in $order; do
        # Skip if already completed
        local skip=false
        for comp in "${completed[@]}"; do
            if [[ "$comp" == "$id" ]]; then
                echo "[$id] Already completed - skipping"
                ((passed++))
                skip=true
                break
            fi
        done
        $skip && continue

        # Check if gate failed
        if $gate_failed; then
            echo "[$id] Skipped - gate scenario failed"
            ((failed++))
            continue
        fi

        # Check dependencies
        if ! scenario_deps_satisfied "$id" "${completed[@]}"; then
            echo "[$id] Skipped - dependencies not satisfied"
            ((failed++))
            continue
        fi

        # Execute scenario
        if scenario_execute "$id"; then
            ((passed++))
            completed+=("$id")
        else
            ((failed++))

            # Check if this is a gate scenario
            local file
            file=$(scenario_get_file "$id")
            if scenario_is_gate "$file"; then
                echo ""
                echo "GATE FAILURE: $id is a gate scenario"
                echo "All remaining scenarios will be skipped"
                gate_failed=true
            fi
        fi
    done

    # Summary
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    VERIFICATION COMPLETE"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Scenarios: $passed/$scenario_count passed"
    [[ $failed -gt 0 ]] && echo "Failed: $failed"
    echo ""

    [[ $failed -eq 0 ]]
}

################################################################################
# SECTION 7: CLI Interface
################################################################################

#######################################
# Main entry point for scenario commands
# Arguments:
#   $@ - Command and arguments
#######################################
scenario_main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        list)
            scenario_list_files
            ;;
        order)
            scenario_resolve_order "$@"
            ;;
        run)
            scenario_execute_all "$@"
            ;;
        execute)
            scenario_execute "$@"
            ;;
        checkpoint)
            checkpoint_summary
            ;;
        help|--help|-h)
            cat << 'EOF'
AI Verification Scenario Framework (P51)

Commands:
  list                List all scenario files
  order [ids...]      Show execution order (resolves dependencies)
  run [options]       Execute all scenarios
    --dry-run         Show order without executing
    --resume          Resume from checkpoint
    --fix             Enable auto-fix for errors
  execute <id>        Execute a single scenario
  checkpoint          Show checkpoint status

Examples:
  source lib/verify-scenarios.sh && scenario_main list
  source lib/verify-scenarios.sh && scenario_main order
  source lib/verify-scenarios.sh && scenario_main run --dry-run
  source lib/verify-scenarios.sh && scenario_main execute S1
EOF
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run 'scenario_main help' for usage"
            return 1
            ;;
    esac
}

# Export functions for use when sourced
export -f scenario_check_yq scenario_timestamp scenario_generate_run_id
export -f scenario_list_files scenario_get_file scenario_get_field
export -f scenario_get_id scenario_get_name scenario_get_dependencies
export -f scenario_is_gate scenario_get_step_count scenario_get_step
export -f scenario_get_step_name scenario_get_step_cmd
export -f scenario_resolve_order scenario_deps_satisfied
export -f checkpoint_init checkpoint_exists checkpoint_get checkpoint_set
export -f checkpoint_update_progress checkpoint_start_scenario
export -f checkpoint_update_step checkpoint_complete_scenario
export -f checkpoint_add_finding checkpoint_add_test_site
export -f checkpoint_get_completed checkpoint_summary
export -f step_execute_cmd step_execute
export -f scenario_execute scenario_execute_all scenario_main
