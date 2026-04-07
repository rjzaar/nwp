#!/usr/bin/env bats
################################################################################
# Unit Tests for lib/ui.sh
#
# Tests UI and output formatting functions
################################################################################

# Load test helpers
load ../helpers/test-helpers

setup() {
    test_setup
    # Source UI library directly (already loaded in test_setup but we ensure it)
    source_lib "ui.sh"
}

teardown() {
    test_teardown
}

################################################################################
# print_error() tests
################################################################################

@test "print_error: outputs error message" {
    run print_error "Test error message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ERROR:"* ]]
    [[ "$output" == *"Test error message"* ]]
}

@test "print_error: message goes to stderr" {
    # In BATS, stderr is captured separately, but we can test it outputs something
    run print_error "Test error"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

################################################################################
# print_info() tests
################################################################################

@test "print_info: outputs info message" {
    run print_info "Test info message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INFO:"* ]]
    [[ "$output" == *"Test info message"* ]]
}

@test "print_info: handles empty message" {
    run print_info ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"INFO:"* ]]
}

@test "print_info: handles special characters" {
    run print_info "Message with $special \$chars"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INFO:"* ]]
}

################################################################################
# print_warning() tests
################################################################################

@test "print_warning: outputs warning message" {
    run print_warning "Test warning message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING:"* ]]
    [[ "$output" == *"Test warning message"* ]]
}

@test "print_warning: handles multiline messages" {
    run print_warning "Line 1
Line 2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING:"* ]]
}

################################################################################
# print_header() tests
################################################################################

@test "print_header: outputs header with text" {
    run print_header "Test Header"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test Header"* ]]
}

@test "print_header: includes decorative elements" {
    run print_header "Test"
    [ "$status" -eq 0 ]
    # Should include the box drawing characters
    [[ "$output" == *"═"* ]]
}

################################################################################
# print_status() tests
################################################################################

@test "print_status: outputs OK status" {
    run print_status "OK" "Operation succeeded"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✓"* ]]
    [[ "$output" == *"Operation succeeded"* ]]
}

@test "print_status: outputs WARN status" {
    run print_status "WARN" "Warning message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"!"* ]]
    [[ "$output" == *"Warning message"* ]]
}

@test "print_status: outputs FAIL status" {
    run print_status "FAIL" "Operation failed"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✗"* ]]
    [[ "$output" == *"Operation failed"* ]]
}

@test "print_status: outputs INFO status" {
    run print_status "INFO" "Information"
    [ "$status" -eq 0 ]
    [[ "$output" == *"i"* ]]
    [[ "$output" == *"Information"* ]]
}

@test "print_status: handles unknown status as INFO" {
    run print_status "UNKNOWN" "Some message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"i"* ]]
}

################################################################################
# fail() tests (Vortex-style icon output)
################################################################################

@test "fail: outputs failure with icon" {
    run fail "Operation failed"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✗"* ]]
    [[ "$output" == *"Operation failed"* ]]
}

@test "fail: handles empty message" {
    run fail ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"✗"* ]]
}

################################################################################
# warn() tests
################################################################################

@test "warn: outputs warning with icon" {
    run warn "Warning message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"!"* ]]
    [[ "$output" == *"Warning message"* ]]
}

################################################################################
# info() tests
################################################################################

@test "info: outputs info with icon" {
    run info "Info message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ℹ"* ]]
    [[ "$output" == *"Info message"* ]]
}

################################################################################
# pass() tests
################################################################################

@test "pass: outputs success with icon" {
    run pass "Operation passed"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✓"* ]]
    [[ "$output" == *"Operation passed"* ]]
}

################################################################################
# task() tests
################################################################################

@test "task: outputs task indicator" {
    run task "Running task"
    [ "$status" -eq 0 ]
    # task() outputs "  > message" (indented with >)
    [[ "$output" == *">"* ]]
    [[ "$output" == *"Running task"* ]]
}

################################################################################
# note() tests
################################################################################

@test "note: outputs note with indentation" {
    run note "This is a note"
    [ "$status" -eq 0 ]
    # note() outputs indented text (4 spaces), no arrow icon
    [[ "$output" == *"This is a note"* ]]
}

################################################################################
# step() tests
################################################################################

@test "step: outputs progress indicator with step count" {
    # step() takes 3 args: current, total, message
    run step 1 5 "Running step one"
    [ "$status" -eq 0 ]
    # step() outputs "[current/total] message (pct%)"
    [[ "$output" == *"[1/5]"* ]]
    [[ "$output" == *"Running step one"* ]]
    [[ "$output" == *"20%"* ]]
}

################################################################################
# show_elapsed_time() tests
################################################################################

@test "show_elapsed_time: shows elapsed time with default label" {
    export START_TIME=$(($(date +%s) - 65))  # 1 minute 5 seconds ago
    run show_elapsed_time
    [ "$status" -eq 0 ]
    [[ "$output" == *"Operation completed"* ]]
    [[ "$output" == *"00:01:05"* ]]
}

@test "show_elapsed_time: shows elapsed time with custom label" {
    export START_TIME=$(($(date +%s) - 125))  # 2 minutes 5 seconds ago
    run show_elapsed_time "Custom task"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Custom task completed"* ]]
    [[ "$output" == *"00:02:05"* ]]
}

@test "show_elapsed_time: handles hours correctly" {
    export START_TIME=$(($(date +%s) - 3665))  # 1 hour 1 minute 5 seconds ago
    run show_elapsed_time "Long task"
    [ "$status" -eq 0 ]
    [[ "$output" == *"01:01:05"* ]]
}

@test "show_elapsed_time: handles zero elapsed time" {
    export START_TIME=$(date +%s)
    run show_elapsed_time "Quick task"
    [ "$status" -eq 0 ]
    [[ "$output" == *"00:00:00"* ]]
}

################################################################################
# Color handling tests
################################################################################

@test "colors are empty when not in terminal" {
    # In BATS tests, we're not in a terminal, so colors should be empty
    [ -z "$RED" ]
    [ -z "$GREEN" ]
    [ -z "$YELLOW" ]
    [ -z "$BLUE" ]
    [ -z "$NC" ]
}

################################################################################
# Edge cases and special handling
################################################################################

@test "print_error: handles quotes in message" {
    run print_error "Error with 'single' and \"double\" quotes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"single"* ]]
    [[ "$output" == *"double"* ]]
}

@test "print_info: handles newlines in message" {
    run print_info $'Line 1\nLine 2'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Line 1"* ]]
    [[ "$output" == *"Line 2"* ]]
}

@test "print_status: handles very long messages" {
    local long_msg="This is a very long message that goes on and on and on and on and on and on and on"
    run print_status "OK" "$long_msg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$long_msg"* ]]
}

@test "fail: handles special shell characters" {
    run fail "Error with \$VAR and \`command\`"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✗"* ]]
}

@test "info: preserves whitespace" {
    run info "  Indented   message  "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Indented   message"* ]]
}

################################################################################
# Integration tests - multiple functions together
################################################################################

@test "multiple output functions work in sequence" {
    {
        print_header "Test Suite"
        print_info "Starting tests"
        pass "Test 1 passed"
        warn "Test 2 warning"
        fail "Test 3 failed"
        print_status "OK" "All done"
    } > /tmp/test-output.txt

    [ -f /tmp/test-output.txt ]
    [ -s /tmp/test-output.txt ]  # File is not empty
    rm -f /tmp/test-output.txt
}
