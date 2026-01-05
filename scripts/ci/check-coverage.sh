#!/usr/bin/env bash
#
# Check code coverage against a threshold
#
# Usage: check-coverage.sh [threshold] [coverage-file]
#
# Arguments:
#   threshold      Minimum coverage percentage required (default: 80)
#   coverage-file  Path to clover.xml coverage file (default: .logs/coverage/clover.xml)
#
# Exit codes:
#   0 - Coverage meets or exceeds threshold
#   1 - Coverage below threshold or error

set -e

# Default values
THRESHOLD=${1:-80}
COVERAGE_FILE=${2:-.logs/coverage/clover.xml}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

# Validate threshold is a number
if ! [[ "$THRESHOLD" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    print_error "Threshold must be a number (got: $THRESHOLD)"
    exit 1
fi

# Check if coverage file exists
if [[ ! -f "$COVERAGE_FILE" ]]; then
    print_error "Coverage file not found: $COVERAGE_FILE"
    echo "Please run tests with coverage enabled first."
    exit 1
fi

# Extract coverage metrics from clover.xml
# The clover format includes metrics like:
# <metrics statements="100" coveredstatements="85" ... />
# We calculate: (coveredstatements / statements) * 100

echo "Analyzing coverage from: $COVERAGE_FILE"
echo "Required threshold: ${THRESHOLD}%"
echo ""

# Extract total statements and covered statements
# We look for the project-level metrics (not file-level)
METRICS=$(grep -A 1 '<project' "$COVERAGE_FILE" | grep '<metrics' || true)

if [[ -z "$METRICS" ]]; then
    # Fallback: try to find any metrics tag
    METRICS=$(grep '<metrics' "$COVERAGE_FILE" | head -1 || true)
fi

if [[ -z "$METRICS" ]]; then
    print_error "Could not find coverage metrics in $COVERAGE_FILE"
    echo "The file may be empty or malformed."
    exit 1
fi

# Extract values using grep and sed
TOTAL_STATEMENTS=$(echo "$METRICS" | sed -n 's/.*statements="\([0-9]*\)".*/\1/p')
COVERED_STATEMENTS=$(echo "$METRICS" | sed -n 's/.*coveredstatements="\([0-9]*\)".*/\1/p')

# Also extract method and element coverage for additional context
TOTAL_METHODS=$(echo "$METRICS" | sed -n 's/.*methods="\([0-9]*\)".*/\1/p')
COVERED_METHODS=$(echo "$METRICS" | sed -n 's/.*coveredmethods="\([0-9]*\)".*/\1/p')

TOTAL_ELEMENTS=$(echo "$METRICS" | sed -n 's/.*elements="\([0-9]*\)".*/\1/p')
COVERED_ELEMENTS=$(echo "$METRICS" | sed -n 's/.*coveredelements="\([0-9]*\)".*/\1/p')

# Validate we got the data
if [[ -z "$TOTAL_STATEMENTS" ]] || [[ -z "$COVERED_STATEMENTS" ]]; then
    print_error "Could not parse coverage metrics from $COVERAGE_FILE"
    echo "Metrics line: $METRICS"
    exit 1
fi

# Prevent division by zero
if [[ "$TOTAL_STATEMENTS" -eq 0 ]]; then
    print_warning "No statements found in coverage report (total=0)"
    echo "This usually means no code was analyzed."
    exit 1
fi

# Calculate coverage percentage using bc for floating point arithmetic
COVERAGE=$(echo "scale=2; ($COVERED_STATEMENTS * 100) / $TOTAL_STATEMENTS" | bc)

# Display coverage information
echo "Coverage Statistics:"
echo "  Statements: $COVERED_STATEMENTS / $TOTAL_STATEMENTS"

if [[ -n "$TOTAL_METHODS" ]] && [[ "$TOTAL_METHODS" -gt 0 ]]; then
    METHOD_COVERAGE=$(echo "scale=2; ($COVERED_METHODS * 100) / $TOTAL_METHODS" | bc)
    echo "  Methods:    $COVERED_METHODS / $TOTAL_METHODS (${METHOD_COVERAGE}%)"
fi

if [[ -n "$TOTAL_ELEMENTS" ]] && [[ "$TOTAL_ELEMENTS" -gt 0 ]]; then
    ELEMENT_COVERAGE=$(echo "scale=2; ($COVERED_ELEMENTS * 100) / $TOTAL_ELEMENTS" | bc)
    echo "  Elements:   $COVERED_ELEMENTS / $TOTAL_ELEMENTS (${ELEMENT_COVERAGE}%)"
fi

echo ""
echo "Overall Coverage: ${COVERAGE}%"
echo ""

# Compare coverage against threshold using bc
# bc returns 1 for true, 0 for false
MEETS_THRESHOLD=$(echo "$COVERAGE >= $THRESHOLD" | bc)

if [[ "$MEETS_THRESHOLD" -eq 1 ]]; then
    print_success "PASS: Coverage of ${COVERAGE}% meets the ${THRESHOLD}% threshold"
    exit 0
else
    DEFICIT=$(echo "scale=2; $THRESHOLD - $COVERAGE" | bc)
    print_error "FAIL: Coverage of ${COVERAGE}% is below the ${THRESHOLD}% threshold"
    echo "Coverage deficit: ${DEFICIT}%"
    exit 1
fi
