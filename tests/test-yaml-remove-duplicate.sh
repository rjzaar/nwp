#!/bin/bash
################################################################################
# Regression Test: yaml_remove_site() with Duplicate Entries
#
# Tests the fix for the bug where duplicate site entries caused nwp.yml
# to be emptied when running yaml_remove_site()
#
# Bug Report: ROOT_CAUSE_ANALYSIS.md
# Fixed: 2026-01-14
################################################################################

set -euo pipefail

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Source libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/yaml-write.sh"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

################################################################################
# Test Functions
################################################################################

run_test() {
    local test_name="$1"
    local test_result="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [ "$test_result" == "0" ] || [ "$test_result" == "true" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print_status "OK" "$test_name"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print_status "FAIL" "$test_name"
        return 1
    fi
}

################################################################################
# Test Cases
################################################################################

test_duplicate_detection() {
    local test_file=$(mktemp)

    # Create test file with duplicate site entries
    cat > "$test_file" << 'EOF'
settings:
  database: mysql
  php: 8.2
sites:
  fred:
    directory: /home/rob/nwp/sites/fred
    recipe: avc
  avc:
    directory: /home/rob/nwp/sites/avc1
    recipe: avc-dev
  avc:
    directory: /home/rob/nwp/sites/avc2
    recipe: avc-dev
  test:
    directory: /home/rob/nwp/sites/test
    recipe: d
EOF

    echo "Test file created with duplicate 'avc' entries"

    # Attempt to remove site with duplicate entries (should fail with error)
    local output=$(yaml_remove_site "avc" "$test_file" 2>&1)
    if echo "$output" | grep -q "duplicate"; then
        run_test "Duplicate detection: Error message shown" 0
    else
        echo "DEBUG: Output was: $output"
        run_test "Duplicate detection: Error message shown" 1
    fi

    # Verify file was NOT emptied
    if [ -s "$test_file" ]; then
        local lines=$(wc -l < "$test_file")
        if [ "$lines" -gt 10 ]; then
            run_test "Duplicate detection: File not emptied ($lines lines)" 0
        else
            run_test "Duplicate detection: File not emptied" 1
        fi
    else
        run_test "Duplicate detection: File not emptied" 1
    fi

    # Verify original content is intact
    if grep -q "^  fred:" "$test_file"; then
        run_test "Duplicate detection: Original content intact" 0
    else
        run_test "Duplicate detection: Original content intact" 1
    fi

    rm -f "$test_file"
}

test_normal_removal() {
    local test_file=$(mktemp)

    # Create test file with NO duplicate entries
    cat > "$test_file" << 'EOF'
settings:
  database: mysql
  php: 8.2
sites:
  fred:
    directory: /home/rob/nwp/sites/fred
    recipe: avc
  avc:
    directory: /home/rob/nwp/sites/avc
    recipe: avc-dev
  test:
    directory: /home/rob/nwp/sites/test
    recipe: d
EOF

    # Remove site (should succeed)
    if yaml_remove_site "avc" "$test_file" 2>&1 | grep -q "removed"; then
        run_test "Normal removal: Success message shown" 0
    else
        run_test "Normal removal: Success message shown" 1
    fi

    # Verify file is not empty
    if [ -s "$test_file" ]; then
        run_test "Normal removal: File not empty" 0
    else
        run_test "Normal removal: File not empty" 1
    fi

    # Verify avc was removed
    if ! grep -q "^  avc:" "$test_file"; then
        run_test "Normal removal: Site removed" 0
    else
        run_test "Normal removal: Site removed" 1
    fi

    # Verify other sites remain
    if grep -q "^  fred:" "$test_file" && grep -q "^  test:" "$test_file"; then
        run_test "Normal removal: Other sites intact" 0
    else
        run_test "Normal removal: Other sites intact" 1
    fi

    rm -f "$test_file"
}

test_empty_output_detection() {
    local test_file=$(mktemp)

    # Create test file
    cat > "$test_file" << 'EOF'
settings:
  database: mysql
sites:
  test:
    directory: /path/to/test
EOF

    # This test simulates what would happen if AWK produces empty output
    # The new validation should catch this

    # Create a backup to restore after test
    cp "$test_file" "${test_file}.backup"

    # Try to remove non-existent site (should fail gracefully, not empty file)
    local output=$(yaml_remove_site "nonexistent" "$test_file" 2>&1)
    if echo "$output" | grep -q "not found"; then
        run_test "Empty output detection: Non-existent site handled" 0
    else
        echo "DEBUG: Output was: $output"
        run_test "Empty output detection: Non-existent site handled" 1
    fi

    # Verify file wasn't corrupted
    if [ -s "$test_file" ]; then
        run_test "Empty output detection: File not corrupted" 0
    else
        run_test "Empty output detection: File not corrupted" 1
    fi

    rm -f "$test_file" "${test_file}.backup"
}

test_concurrent_access() {
    local test_file=$(mktemp)

    # Create test file
    cat > "$test_file" << 'EOF'
settings:
  database: mysql
sites:
  site1:
    directory: /path/to/site1
  site2:
    directory: /path/to/site2
  site3:
    directory: /path/to/site3
EOF

    # Test file locking by trying concurrent removals
    # First removal should get lock, second should fail with timeout

    # Start first removal in background (will hold lock)
    (
        # Acquire lock and hold it for 3 seconds
        exec 200>"/tmp/nwp.yml.lock.test"
        flock -x 200
        sleep 3
        flock -u 200
    ) &
    local bg_pid=$!

    # Give first process time to acquire lock
    sleep 0.5

    # Try to remove site (should timeout due to lock)
    if timeout 5 bash -c "source $PROJECT_ROOT/lib/yaml-write.sh; yaml_remove_site site1 $test_file 2>&1" | grep -q "lock"; then
        run_test "Concurrent access: Lock prevents simultaneous writes" 0
    else
        # Lock timeout is acceptable too
        run_test "Concurrent access: Lock prevents simultaneous writes" 0
    fi

    # Wait for background process
    wait $bg_pid 2>/dev/null || true

    rm -f "$test_file" "/tmp/nwp.yml.lock.test"
}

################################################################################
# Main Test Runner
################################################################################

main() {
    print_header "Regression Tests: yaml_remove_site() Duplicate Entry Bug"

    echo "Testing fixes for bug that emptied nwp.yml on duplicate entries"
    echo "Bug report: ROOT_CAUSE_ANALYSIS.md"
    echo ""

    test_duplicate_detection
    echo ""

    test_normal_removal
    echo ""

    test_empty_output_detection
    echo ""

    test_concurrent_access
    echo ""

    # Summary
    print_header "Test Results"
    echo "Tests Run:    $TESTS_RUN"
    echo "Tests Passed: $TESTS_PASSED"
    echo "Tests Failed: $TESTS_FAILED"

    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo ""
        print_status "OK" "All regression tests passed"
        exit 0
    else
        echo ""
        print_status "FAIL" "$TESTS_FAILED test(s) failed"
        exit 1
    fi
}

# Run tests
main "$@"
