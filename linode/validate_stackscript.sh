#!/bin/bash

################################################################################
# validate_stackscript.sh - Validate StackScript for Linode compatibility
################################################################################
#
# Checks a StackScript for issues that would prevent upload to Linode:
#   - Unicode/non-ASCII characters
#   - Missing shebang
#   - File size limits
#
# Usage:
#   ./validate_stackscript.sh <script_file>
#
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_error() { echo -e "${RED}ERROR:${NC} $1"; }
print_warning() { echo -e "${YELLOW}WARNING:${NC} $1"; }
print_success() { echo -e "${GREEN}OK:${NC} $1"; }

if [ $# -ne 1 ]; then
    echo "Usage: $0 <script_file>"
    exit 1
fi

SCRIPT_FILE="$1"

if [ ! -f "$SCRIPT_FILE" ]; then
    print_error "File not found: $SCRIPT_FILE"
    exit 1
fi

echo "Validating StackScript: $SCRIPT_FILE"
echo ""

ERRORS=0
WARNINGS=0

# Check 1: Shebang
if ! head -n 1 "$SCRIPT_FILE" | grep -q '^#!'; then
    print_error "Missing shebang (#!/bin/bash) at start of file"
    ERRORS=$((ERRORS + 1))
else
    print_success "Shebang present"
fi

# Check 2: Unicode characters
if python3 -c "
import sys
with open('$SCRIPT_FILE', 'r', encoding='utf-8') as f:
    content = f.read()
    non_ascii = [c for c in content if ord(c) > 127]
    if non_ascii:
        unique = set(non_ascii)
        print('Found', len(non_ascii), 'non-ASCII characters:')
        for char in sorted(unique, key=ord):
            count = content.count(char)
            print(f'  {repr(char)} (U+{ord(char):04X}) - {count} times')
        sys.exit(1)
" 2>&1; then
    print_success "No Unicode characters found"
else
    print_error "Unicode characters detected (Linode doesn't support these)"
    print_warning "Run this to fix: sed -i 's/✓/[OK]/g; s/⚠/[!]/g' $SCRIPT_FILE"
    ERRORS=$((ERRORS + 1))
fi

# Check 3: File size
SIZE=$(stat -f%z "$SCRIPT_FILE" 2>/dev/null || stat -c%s "$SCRIPT_FILE")
if [ "$SIZE" -gt 65535 ]; then
    print_warning "Script is large (${SIZE} bytes). Linode limit is 65535 bytes."
    WARNINGS=$((WARNINGS + 1))
else
    print_success "File size OK (${SIZE} bytes)"
fi

# Check 4: UDF format
if grep -q '^# <UDF' "$SCRIPT_FILE"; then
    print_success "UDF (User Defined Fields) detected"
else
    print_warning "No UDF fields found (consider adding for user input)"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    print_success "Validation passed! Script is ready for upload."
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}Validation completed with $WARNINGS warning(s)${NC}"
    exit 0
else
    echo -e "${RED}Validation failed with $ERRORS error(s) and $WARNINGS warning(s)${NC}"
    exit 1
fi
