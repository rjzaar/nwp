#!/bin/bash
#
# Migrate .verification.yml from version 1 to version 2
# This converts checklist items from simple strings to objects with completion tracking
#

set -euo pipefail

VERIFICATION_FILE="/home/rob/nwp/.verification.yml"
BACKUP_FILE="${VERIFICATION_FILE}.v1.backup"

# Backup original file
echo "Creating backup: $BACKUP_FILE"
cp "$VERIFICATION_FILE" "$BACKUP_FILE"

# Migrate to v2 format
echo "Migrating to version 2 format..."

awk '
BEGIN {
    in_checklist = 0
    checklist_indent = ""
}

# Update version number
/^version: 1/ {
    print "version: 2"
    next
}

# Detect checklist section start
/^    checklist:/ {
    in_checklist = 1
    print
    next
}

# Convert checklist items
in_checklist && /^      - / {
    # Extract the checklist item text
    text = $0
    gsub(/^      - "?/, "", text)
    gsub(/"$/, "", text)

    # Output as object with completed fields
    print "      - text: \"" text "\""
    print "        completed: false"
    print "        completed_by: null"
    print "        completed_at: null"
    next
}

# End of checklist section
in_checklist && /^    [a-z]/ {
    in_checklist = 0
}

# Pass through all other lines
{ print }
' "$BACKUP_FILE" > "$VERIFICATION_FILE"

echo "Migration complete!"
echo "Original file backed up to: $BACKUP_FILE"
echo ""
echo "You can now use the new features:"
echo "  - pl verify console  # Interactive console with new shortcuts"
echo "  - Press 'i' to edit checklist items"
echo "  - Press 'n' to edit notes"
echo "  - Press 'h' to view history"
echo "  - Press 'p' to toggle checklist preview"
