#!/bin/bash
#
# verify.sh - NWP Feature Verification Tracking
#
# This script manages the verification status of NWP features.
# It tracks which features have been manually verified by a human,
# and automatically invalidates verification when code changes.
#
# Usage:
#   ./verify.sh              # Interactive TUI console (default)
#   ./verify.sh report       # Show verification status report
#   ./verify.sh check        # Check for invalidated verifications
#   ./verify.sh details <id> # Show what changed and verification checklist
#   ./verify.sh verify       # Interactive verification mode
#   ./verify.sh verify <id>  # Mark a specific feature as verified
#   ./verify.sh unverify <id> # Mark a specific feature as unverified
#   ./verify.sh list         # List all feature IDs
#   ./verify.sh summary      # Show summary statistics
#   ./verify.sh reset        # Reset all verifications

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFICATION_FILE="${PROJECT_ROOT}/.verification.yml"

# Source UI library for colors
source "$PROJECT_ROOT/lib/ui.sh"

# Additional colors for TUI not in ui.sh
if [[ -t 1 ]]; then
    WHITE=$'\033[1;37m'
    DIM=$'\033[2m'
else
    WHITE=''
    DIM=''
fi

# Checkbox characters
CHECK_ON="[✓]"
CHECK_OFF="[ ]"
CHECK_INVALID="[!]"

# Detect the best available editor for the current environment
# Returns editor command or empty string if none found
# Usage: editor=$(detect_best_editor [--wait])
#   --wait: Return editor with blocking flag (for editing, not viewing)
detect_best_editor() {
    local wait_flag=""
    [[ "${1:-}" == "--wait" ]] && wait_flag="--wait"

    # Graphical editors (non-blocking by default, good for viewing from TUI)
    # Only try GUI editors if we're in a graphical environment
    if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]] || [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] || [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
        for editor in codium code code-insiders; do
            if command -v "$editor" &>/dev/null; then
                if [[ -n "$wait_flag" ]]; then
                    echo "$editor --wait"
                else
                    echo "$editor"
                fi
                return 0
            fi
        done
    fi

    # User preference from environment
    if [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" &>/dev/null; then
        echo "$EDITOR"
        return 0
    fi

    # Terminal fallbacks
    for editor in nano vim vi; do
        if command -v "$editor" &>/dev/null; then
            echo "$editor"
            return 0
        fi
    done

    return 1
}

# Calculate SHA256 hash for a list of files
calculate_hash() {
    local files="$1"
    local combined_hash=""

    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            local filepath="${PROJECT_ROOT}/${file}"
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

# Get a YAML value using simple parsing
get_yaml_value() {
    local feature="$1"
    local field="$2"

    awk -v feature="$feature" -v field="$field" '
    BEGIN { in_feature = 0; indent = 0 }
    /^  [a-z0-9_]+:/ {
        gsub(/^  /, "")
        gsub(/:.*/, "")
        if ($0 == feature) {
            in_feature = 1
            indent = 4
        } else if (in_feature) {
            in_feature = 0
        }
    }
    in_feature && $0 ~ "^    " field ":" {
        gsub(/^    [a-z_]+: */, "")
        gsub(/^"/, "")
        gsub(/"$/, "")
        print
        exit
    }
    ' "$VERIFICATION_FILE"
}

# Get files list for a feature
get_feature_files() {
    local feature="$1"

    awk -v feature="$feature" '
    BEGIN { in_feature = 0; in_files = 0 }
    /^  [a-z0-9_]+:/ {
        gsub(/^  /, "")
        gsub(/:.*/, "")
        if ($0 == feature) {
            in_feature = 1
        } else if (in_feature) {
            in_feature = 0
            in_files = 0
        }
    }
    in_feature && /^    files:/ {
        in_files = 1
        next
    }
    in_feature && in_files && /^      - / {
        gsub(/^      - /, "")
        print
    }
    in_feature && in_files && /^    [a-z]/ {
        in_files = 0
    }
    ' "$VERIFICATION_FILE"
}

# Get schema version from YAML file
get_schema_version() {
    awk '/^version:/ {print $2; exit}' "$VERIFICATION_FILE"
}

# Get checklist items for a feature (v1/v3 format - extracts text field)
get_feature_checklist() {
    local feature="$1"

    awk -v feature="$feature" '
    BEGIN { in_feature = 0; in_checklist = 0 }
    /^  / && $0 ~ "^  " feature ":$" {
        in_feature = 1
        next
    }
    in_feature && /^  [a-z_]+:$/ {
        # Another feature started - exit
        in_feature = 0
        in_checklist = 0
    }
    in_feature && /^    checklist:/ {
        in_checklist = 1
        next
    }
    in_feature && in_checklist && /^    - text:/ {
        line = $0
        gsub(/^    - text: */, "", line)
        gsub(/^"/, "", line)
        gsub(/"$/, "", line)
        print line
    }
    in_feature && in_checklist && /^    [a-z]/ && !/^    - / && !/^    checklist:/ {
        in_checklist = 0
    }
    ' "$VERIFICATION_FILE"
}

# Get checklist items with v2 format (objects with text/completed fields)
# Returns text content only (for backward compatibility)
get_feature_checklist_v2() {
    local feature="$1"
    local version=$(get_schema_version)

    if [[ "$version" == "2" ]]; then
        # Parse v2 format (objects)
        awk -v feature="$feature" '
        BEGIN { in_feature = 0; in_checklist = 0; in_item = 0 }
        /^  [a-z0-9_]+:/ {
            gsub(/^  /, "")
            gsub(/:.*/, "")
            if ($0 == feature) {
                in_feature = 1
            } else if (in_feature) {
                in_feature = 0
                in_checklist = 0
            }
        }
        in_feature && /^    checklist:/ {
            in_checklist = 1
            next
        }
        in_feature && in_checklist && /^      - text:/ {
            gsub(/^      - text: *"?/, "")
            gsub(/"$/, "")
            print
        }
        in_feature && in_checklist && /^    [a-z]/ {
            in_checklist = 0
        }
        ' "$VERIFICATION_FILE"
    else
        # Fall back to v1 parser for backward compatibility
        get_feature_checklist "$feature"
    fi
}

# Count total checklist items for a feature
get_checklist_item_count() {
    local feature="$1"
    local version=$(get_schema_version)

    if [[ "$version" == "2" || "$version" == "3" ]]; then
        # v2/v3 format - count checklist items with - text: at 4 spaces
        awk -v feature="$feature" '
        BEGIN { in_feature = 0; in_checklist = 0; count = 0 }
        /^  [a-z0-9_]+:/ {
            gsub(/^  /, "")
            gsub(/:.*/, "")
            if ($0 == feature) {
                in_feature = 1
            } else if (in_feature) {
                exit
            }
        }
        in_feature && /^    checklist:/ {
            in_checklist = 1
            next
        }
        in_feature && in_checklist && /^    - text:/ {
            count++
        }
        in_feature && in_checklist && /^    [a-z]/ && !/^    - / {
            exit
        }
        /^  [a-z]/ && in_feature && in_checklist {
            exit
        }
        END { print count }
        ' "$VERIFICATION_FILE"
    else
        # v1 format - count simple list items
        get_feature_checklist "$feature" | wc -l
    fi
}

# Count completed checklist items for a feature
get_completed_checklist_item_count() {
    local feature="$1"
    local version=$(get_schema_version)

    if [[ "$version" == "2" || "$version" == "3" ]]; then
        # v2/v3 format - count items with completed: true at 6 spaces
        awk -v feature="$feature" '
        BEGIN { in_feature = 0; in_checklist = 0; in_item = 0; count = 0; completed = "" }
        /^  [a-z0-9_]+:/ {
            gsub(/^  /, "")
            gsub(/:.*/, "")
            if ($0 == feature) {
                in_feature = 1
            } else if (in_feature) {
                exit
            }
        }
        in_feature && /^    checklist:/ {
            in_checklist = 1
            next
        }
        in_feature && in_checklist && /^    - text:/ {
            in_item = 1
            completed = ""
        }
        in_feature && in_checklist && in_item && /^      completed:/ {
            gsub(/^      completed: */, "")
            if ($0 == "true") {
                count++
            }
            in_item = 0
        }
        in_feature && in_checklist && /^    [a-z]/ && !/^    - / {
            exit
        }
        /^  [a-z]/ && in_feature && in_checklist {
            exit
        }
        END { print count }
        ' "$VERIFICATION_FILE"
    else
        # v1 format - no completion tracking, return 0
        echo "0"
    fi
}

# Get checklist item completion status by index
get_checklist_item_status() {
    local feature="$1"
    local idx="$2"
    local version=$(get_schema_version)

    if [[ "$version" == "2" ]]; then
        awk -v feature="$feature" -v idx="$idx" '
        BEGIN { in_feature = 0; in_checklist = 0; current_idx = -1; in_item = 0; found = 0 }
        /^  [a-z0-9_]+:/ {
            gsub(/^  /, "")
            gsub(/:.*/, "")
            if ($0 == feature) {
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
            }
        }
        in_item && /^        completed:/ {
            gsub(/^        completed: */, "")
            print
            found = 1
            exit
        }
        in_feature && in_checklist && /^    [a-z]/ {
            exit
        }
        END { if (!found && in_item && current_idx == idx) print "false" }
        ' "$VERIFICATION_FILE"
    else
        # v1 format - no completion tracking
        echo "false"
    fi
}

# Get checklist item details (how_to_verify, related_docs) by index
# Returns multiline output: first line is how_to_verify, remaining lines are related_docs
get_checklist_item_details() {
    local feature="$1"
    local idx="$2"
    local version=$(get_schema_version)

    if [[ "$version" != "2" ]]; then
        echo ""
        return
    fi

    # Use a state machine to parse the YAML
    local in_feature=0 in_checklist=0 in_item=0 current_idx=-1
    local in_how_to_verify=0 in_related_docs=0
    local how_to_verify="" related_docs=""
    local how_to_verify_indent=0

    while IFS= read -r line; do
        # Check for feature start
        if [[ "$line" =~ ^[[:space:]]{2}[a-z0-9_]+:$ ]]; then
            local feat_name="${line#  }"
            feat_name="${feat_name%:}"
            if [[ "$feat_name" == "$feature" ]]; then
                in_feature=1
            elif [[ $in_feature -eq 1 ]]; then
                break
            fi
            continue
        fi

        # Check for checklist section
        if [[ $in_feature -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{4}checklist: ]]; then
            in_checklist=1
            continue
        fi

        # Exit checklist on next section
        if [[ $in_feature -eq 1 ]] && [[ $in_checklist -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{4}[a-z] ]] && [[ ! "$line" =~ ^[[:space:]]{4}checklist ]]; then
            break
        fi

        # Check for new checklist item
        if [[ $in_feature -eq 1 ]] && [[ $in_checklist -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{6}-[[:space:]]text: ]]; then
            # If we were in the target item, we're done
            if [[ $in_item -eq 1 ]]; then
                break
            fi
            current_idx=$((current_idx + 1))
            if [[ $current_idx -eq $idx ]]; then
                in_item=1
            fi
            in_how_to_verify=0
            in_related_docs=0
            continue
        fi

        # Parse fields for target item
        if [[ $in_item -eq 1 ]]; then
            # Check for how_to_verify field (block scalar or quoted)
            if [[ "$line" =~ ^[[:space:]]{8}how_to_verify:[[:space:]]*\|[-]?$ ]]; then
                in_how_to_verify=1
                in_related_docs=0
                how_to_verify_indent=10
                continue
            elif [[ "$line" =~ ^[[:space:]]{8}how_to_verify:[[:space:]]+(.*) ]]; then
                # Inline value (quoted string)
                how_to_verify="${BASH_REMATCH[1]}"
                # Remove surrounding quotes
                how_to_verify="${how_to_verify#\'}"
                how_to_verify="${how_to_verify%\'}"
                how_to_verify="${how_to_verify#\"}"
                how_to_verify="${how_to_verify%\"}"
                in_how_to_verify=0
                continue
            fi

            # Check for related_docs field
            if [[ "$line" =~ ^[[:space:]]{8}related_docs: ]]; then
                in_how_to_verify=0
                in_related_docs=1
                continue
            fi

            # Continue reading how_to_verify block content
            if [[ $in_how_to_verify -eq 1 ]]; then
                if [[ "$line" =~ ^[[:space:]]{10} ]] || [[ -z "${line// }" ]]; then
                    local content="${line#          }"
                    if [[ -n "$how_to_verify" ]]; then
                        how_to_verify="$how_to_verify"$'\n'"$content"
                    else
                        how_to_verify="$content"
                    fi
                else
                    in_how_to_verify=0
                fi
            fi

            # Continue reading related_docs entries (at 8 spaces with dash)
            if [[ $in_related_docs -eq 1 ]]; then
                if [[ "$line" =~ ^[[:space:]]{8}-[[:space:]]+(.*) ]]; then
                    local doc="${BASH_REMATCH[1]}"
                    if [[ -n "$related_docs" ]]; then
                        related_docs="$related_docs"$'\n'"$doc"
                    else
                        related_docs="$doc"
                    fi
                elif [[ ! "$line" =~ ^[[:space:]]{8}- ]] && [[ -n "${line// }" ]]; then
                    in_related_docs=0
                fi
            fi

            # Check for end of item (next field at 8-space indent)
            if [[ "$line" =~ ^[[:space:]]{8}(completed|verified|history): ]]; then
                in_how_to_verify=0
                in_related_docs=0
            fi
        fi
    done < "$VERIFICATION_FILE"

    # Output format: HOW_TO_VERIFY|||RELATED_DOCS
    echo "${how_to_verify}|||${related_docs}"
}

# Get checklist items as arrays (for iteration)
# Usage: get_checklist_items_array "feature_id" items_array completed_array
get_checklist_items_array() {
    local feature="$1"
    local -n items_ref="$2"
    local -n completed_ref="$3"
    local version=$(get_schema_version)

    items_ref=()
    completed_ref=()

    if [[ "$version" == "2" ]]; then
        # Parse v2 format
        local in_feature=0 in_checklist=0 current_text="" current_completed="false"

        while IFS= read -r line; do
            # Check for feature start
            if [[ "$line" =~ ^[[:space:]]{2}[a-z0-9_]+: ]]; then
                local feat_name=$(echo "$line" | sed 's/^  //' | sed 's/:.*//')
                if [[ "$feat_name" == "$feature" ]]; then
                    in_feature=1
                elif [[ $in_feature -eq 1 ]]; then
                    break
                fi
            fi

            # Check for checklist section
            if [[ $in_feature -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{4}checklist: ]]; then
                in_checklist=1
                continue
            fi

            # Parse checklist items
            if [[ $in_feature -eq 1 ]] && [[ $in_checklist -eq 1 ]]; then
                if [[ "$line" =~ ^[[:space:]]{6}-[[:space:]]text: ]]; then
                    # Save previous item if exists
                    if [[ -n "$current_text" ]]; then
                        items_ref+=("$current_text")
                        completed_ref+=("$current_completed")
                    fi
                    # Start new item
                    current_text=$(echo "$line" | sed 's/^      - text: *//' | sed 's/^"//' | sed 's/"$//')
                    current_completed="false"
                elif [[ "$line" =~ ^[[:space:]]{8}completed: ]]; then
                    current_completed=$(echo "$line" | sed 's/^        completed: *//')
                elif [[ "$line" =~ ^[[:space:]]{4}[a-z] ]]; then
                    # End of checklist section
                    if [[ -n "$current_text" ]]; then
                        items_ref+=("$current_text")
                        completed_ref+=("$current_completed")
                        current_text=""  # Clear to prevent duplicate addition
                    fi
                    break
                fi
            fi
        done < "$VERIFICATION_FILE"

        # Add last item if we reached EOF (only if not already added above)
        if [[ $in_checklist -eq 1 ]] && [[ -n "$current_text" ]]; then
            items_ref+=("$current_text")
            completed_ref+=("$current_completed")
        fi
    else
        # v1 format - simple string list
        while IFS= read -r item; do
            items_ref+=("$item")
            completed_ref+=("false")
        done < <(get_feature_checklist "$feature")
    fi
}

# Update a YAML value for a feature
update_yaml_value() {
    local feature="$1"
    local field="$2"
    local value="$3"
    local tmpfile=$(mktemp)

    awk -v feature="$feature" -v field="$field" -v value="$value" '
    BEGIN { in_feature = 0; updated = 0 }
    /^  [a-z0-9_]+:/ {
        test = $0
        gsub(/^  /, "", test)
        gsub(/:.*/, "", test)
        if (test == feature) {
            in_feature = 1
        } else if (in_feature && !updated) {
            # Insert field before next feature if it doesnt exist
            print "    " field ": " value
            updated = 1
            in_feature = 0
        } else {
            in_feature = 0
        }
    }
    in_feature && $0 ~ "^    " field ":" {
        print "    " field ": " value
        updated = 1
        next
    }
    { print }
    END {
        if (in_feature && !updated) {
            # Field was last in file
            print "    " field ": " value
        }
    }
    ' "$VERIFICATION_FILE" > "$tmpfile"

    mv "$tmpfile" "$VERIFICATION_FILE"
}

# Update a specific checklist item field
update_checklist_item() {
    local feature="$1"
    local idx="$2"
    local field="$3"  # completed, completed_by, completed_at
    local value="$4"
    local tmpfile=$(mktemp)

    awk -v feature="$feature" -v idx="$idx" -v field="$field" -v value="$value" '
    BEGIN { in_feature = 0; in_checklist = 0; current_idx = -1; in_item = 0; field_updated = 0 }
    /^  [a-z0-9_]+:/ {
        test = $0
        gsub(/^  /, "", test)
        gsub(/:.*/, "", test)
        if (test == feature) {
            in_feature = 1
        } else if (in_feature) {
            in_feature = 0
            in_checklist = 0
        }
    }
    in_feature && /^    checklist:/ {
        in_checklist = 1
        print
        next
    }
    in_feature && in_checklist && /^      - text:/ {
        # Reset in_item before checking if this is the target
        in_item = 0
        field_updated = 0
        current_idx++
        if (current_idx == idx) {
            in_item = 1
        }
        print
        next
    }
    in_feature && in_checklist && in_item && $0 ~ "^        " field ":" {
        # Update existing field
        print "        " field ": " value
        field_updated = 1
        next
    }
    in_feature && in_checklist && in_item && /^      - text:/ {
        # Next item started, insert field if it wasnt found
        if (!field_updated) {
            print "        " field ": " value
        }
        in_item = 0
        field_updated = 0
        current_idx++
        if (current_idx == idx) {
            in_item = 1
        }
        print
        next
    }
    in_feature && in_checklist && in_item && /^    [a-z]/ {
        # End of checklist, insert field if not found
        if (!field_updated) {
            print "        " field ": " value
        }
        in_item = 0
        in_checklist = 0
    }
    { print }
    END {
        if (in_item && !field_updated) {
            # Field was last in item
            print "        " field ": " value
        }
    }
    ' "$VERIFICATION_FILE" > "$tmpfile"

    mv "$tmpfile" "$VERIFICATION_FILE"
}

# Add history entry to a feature
add_history_entry() {
    local feature="$1"
    local action="$2"
    local username="$3"
    local context="${4:-}"
    local timestamp=$(date -Iseconds)
    local version=$(get_schema_version)

    # Only add history for v2 schema
    [[ "$version" != "2" ]] && return 0

    local tmpfile=$(mktemp)

    awk -v feature="$feature" -v action="$action" -v by="$username" \
        -v at="$timestamp" -v context="$context" '
    BEGIN { in_feature = 0; in_history = 0; inserted = 0 }
    /^  [a-z0-9_]+:/ {
        test = $0
        gsub(/^  /, "", test)
        gsub(/:.*/, "", test)
        if (test == feature) {
            in_feature = 1
        } else if (in_feature && !inserted) {
            # End of feature, insert history section if it didnt exist
            if (!in_history) {
                print "    history:"
            }
            print "      - action: \"" action "\""
            print "        by: \"" by "\""
            print "        at: \"" at "\""
            if (context != "") print "        context: \"" context "\""
            inserted = 1
            in_feature = 0
            in_history = 0
        } else {
            in_feature = 0
            in_history = 0
        }
    }
    in_feature && /^    history:/ {
        in_history = 1
        print
        # Insert new entry at beginning (most recent first)
        print "      - action: \"" action "\""
        print "        by: \"" by "\""
        print "        at: \"" at "\""
        if (context != "") print "        context: \"" context "\""
        inserted = 1
        next
    }
    { print }
    END {
        if (in_feature && !inserted) {
            # Feature was last in file
            if (!in_history) {
                print "    history:"
            }
            print "      - action: \"" action "\""
            print "        by: \"" by "\""
            print "        at: \"" at "\""
            if (context != "") print "        context: \"" context "\""
        }
    }
    ' "$VERIFICATION_FILE" > "$tmpfile"

    mv "$tmpfile" "$VERIFICATION_FILE"
}

# Get list of files that changed since last verification
get_changed_files() {
    local feature="$1"
    local stored_hash=$(get_yaml_value "$feature" "file_hash")
    local changed_files=()

    if [[ -z "$stored_hash" || "$stored_hash" == "null" ]]; then
        # No stored hash, return all files as "unknown"
        get_feature_files "$feature"
        return
    fi

    # We need to track individual file hashes to detect which changed
    # For now, just return all files if the combined hash changed
    local files=$(get_feature_files "$feature")
    # Prefix with sites/ if referencing site directories
    echo "$files" | sed 's|^scripts/commands/|sites/|g' || echo "$files"
}

# Show git diff for a file if available
show_file_diff() {
    local file="$1"
    local filepath="${PROJECT_ROOT}/${file}"

    if [[ ! -f "$filepath" ]]; then
        echo -e "    ${RED}File not found${NC}"
        return
    fi

    # Check if file is tracked by git
    if git -C "$PROJECT_ROOT" ls-files --error-unmatch "$file" &>/dev/null; then
        # Show recent changes (last commit that modified this file)
        local last_commit=$(git -C "$PROJECT_ROOT" log -1 --format="%h %s" -- "$file" 2>/dev/null)
        if [[ -n "$last_commit" ]]; then
            echo -e "    ${DIM}Last commit: ${last_commit}${NC}"
        fi

        # Show summary of changes if file has uncommitted changes
        if ! git -C "$PROJECT_ROOT" diff --quiet -- "$file" 2>/dev/null; then
            echo -e "    ${YELLOW}Has uncommitted changes${NC}"
            local stats=$(git -C "$PROJECT_ROOT" diff --stat -- "$file" 2>/dev/null | tail -1)
            if [[ -n "$stats" ]]; then
                echo -e "    ${DIM}${stats}${NC}"
            fi
        fi
    fi
}

# Get all feature IDs
get_feature_ids() {
    # Only extract feature IDs from under the features: section
    awk '
    BEGIN { in_features = 0 }
    /^features:/ { in_features = 1; next }
    /^[a-z]/ && !/^features:/ { in_features = 0 }
    in_features && /^  [a-z0-9_]+:$/ {
        gsub(/^  /, "")
        gsub(/:$/, "")
        print
    }
    ' "$VERIFICATION_FILE"
}

# Update YAML value
update_yaml_value() {
    local feature="$1"
    local field="$2"
    local value="$3"

    # Create a temporary file
    local tmpfile=$(mktemp)

    awk -v feature="$feature" -v field="$field" -v value="$value" '
    BEGIN { in_feature = 0 }
    /^  [a-z0-9_]+:/ {
        test = $0
        gsub(/^  /, "", test)
        gsub(/:.*/, "", test)
        if (test == feature) {
            in_feature = 1
        } else {
            in_feature = 0
        }
    }
    in_feature && $0 ~ "^    " field ":" {
        print "    " field ": " value
        next
    }
    { print }
    ' "$VERIFICATION_FILE" > "$tmpfile"

    mv "$tmpfile" "$VERIFICATION_FILE"
}

# Check if a feature's files have changed since verification
check_feature_changed() {
    local feature="$1"
    local stored_hash=$(get_yaml_value "$feature" "file_hash")

    if [[ -z "$stored_hash" || "$stored_hash" == "null" ]]; then
        return 1  # No hash stored, can't determine
    fi

    local files=$(get_feature_files "$feature")
    local current_hash=$(calculate_hash "$files")

    if [[ "$current_hash" != "$stored_hash" ]]; then
        return 0  # Changed
    fi
    return 1  # Not changed
}

# Display status for all features
show_status() {
    echo -e "${BOLD}${WHITE}NWP Feature Verification Status${NC}"
    echo -e "${DIM}════════════════════════════════════════════════════════════════${NC}"
    echo ""

    local verified_count=0
    local unverified_count=0
    local invalid_count=0
    local partial_count=0
    local current_section=""

    while IFS= read -r feature; do
        local name=$(get_yaml_value "$feature" "name")
        local desc=$(get_yaml_value "$feature" "description")
        local verified=$(get_yaml_value "$feature" "verified")
        local verified_by=$(get_yaml_value "$feature" "verified_by")
        local verified_at=$(get_yaml_value "$feature" "verified_at")

        # Detect section from comments (simplified - use feature prefix)
        local section=""
        case "$feature" in
            setup|install|status|modify|backup|restore|sync|copy|delete|make|migration|import)
                section="CORE SCRIPTS"
                ;;
            live|dev2stg|stg2prod|prod2stg|stg2live|live2stg|live2prod|produce)
                section="DEPLOYMENT"
                ;;
            podcast|schedule|security|setup_ssh|uninstall)
                section="INFRASTRUCTURE"
                ;;
            pl_cli|test_nwp)
                section="CLI & TESTING"
                ;;
            lib_*)
                section="LIBRARIES"
                ;;
            moodle)
                section="MOODLE"
                ;;
            gitlab_*)
                section="GITLAB"
                ;;
            linode_*)
                section="LINODE"
                ;;
            config_*)
                section="CONFIGURATION"
                ;;
            tests_*)
                section="TESTS"
                ;;
        esac

        # Print section header if changed
        if [[ "$section" != "$current_section" ]]; then
            if [[ -n "$current_section" ]]; then
                echo ""
            fi
            echo -e "${CYAN}${BOLD}${section}${NC}"
            echo -e "${DIM}────────────────────────────────────────────────────${NC}"
            current_section="$section"
        fi

        # Get machine verification counts for this feature
        local machine_verified=$(count_feature_machine_verified "$feature" 2>/dev/null || echo "0")
        local machine_checkable=$(count_feature_machine_checkable "$feature" 2>/dev/null || echo "0")

        # Determine checkbox state
        local checkbox
        local status_color
        local status_info=""
        local machine_info=""

        # Add machine verification indicator if feature has machine checks
        if [[ $machine_checkable -gt 0 ]]; then
            if [[ $machine_verified -eq $machine_checkable ]]; then
                machine_info="${GREEN}⚙${NC}"
            elif [[ $machine_verified -gt 0 ]]; then
                machine_info="${YELLOW}⚙${NC}"
            else
                machine_info="${DIM}⚙${NC}"
            fi
        fi

        if [[ "$verified" == "true" ]]; then
            # Check if files have changed
            if check_feature_changed "$feature"; then
                checkbox="${YELLOW}${CHECK_INVALID}${NC}"
                status_color="${YELLOW}"
                status_info=" ${DIM}(modified since verification)${NC}"
                ((++invalid_count))
            else
                checkbox="${GREEN}${CHECK_ON}${NC}"
                status_color="${GREEN}"
                if [[ -n "$verified_by" && "$verified_by" != "null" ]]; then
                    if [[ "$verified_by" == "checklist" ]]; then
                        status_info=" ${DIM}via checklist${NC}"
                    else
                        status_info=" ${DIM}by ${verified_by}${NC}"
                    fi
                fi
                ((++verified_count))
            fi
        else
            # Check for partial completion (some checklist items done)
            local total_items=$(get_checklist_item_count "$feature" 2>/dev/null || echo "0")
            local completed_items=$(get_completed_checklist_item_count "$feature" 2>/dev/null || echo "0")

            if [[ $total_items -gt 0 ]] && [[ $completed_items -gt 0 ]]; then
                local pct=$((completed_items * 100 / total_items))
                checkbox="${YELLOW}◐${NC}"
                status_color="${YELLOW}"
                status_info=" ${DIM}(${completed_items}/${total_items} human)${NC}"
                ((++partial_count))
            elif [[ $machine_verified -gt 0 ]]; then
                checkbox="${CYAN}◐${NC}"
                status_color="${CYAN}"
                status_info=" ${DIM}(${machine_verified}/${machine_checkable} machine)${NC}"
                ((++partial_count))
            else
                checkbox="${RED}${CHECK_OFF}${NC}"
                status_color="${RED}"
                ((++unverified_count))
            fi
        fi

        # Add machine info if present
        if [[ -n "$machine_info" ]]; then
            status_info="${machine_info} ${status_info}"
        fi

        # Print feature line
        printf "  %b %-45s %b\n" "$checkbox" "${name}" "$status_info"
        printf "    %b%-20s%b %b%s%b\n" "${DIM}" "$feature" "${NC}" "${DIM}" "$desc" "${NC}"

    done <<< "$(get_feature_ids)"

    echo ""
    echo -e "${DIM}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}Summary:${NC}"
    echo -e "  ${GREEN}✓ Verified:${NC}   $verified_count"
    echo -e "  ${YELLOW}◐ Partial:${NC}    $partial_count"
    echo -e "  ${RED}○ Unverified:${NC} $unverified_count"
    echo -e "  ${YELLOW}! Modified:${NC}   $invalid_count"
    echo ""
    echo -e "${DIM}Use './verify.sh verify <id>' to mark a feature as verified${NC}"
    echo -e "${DIM}Use './verify.sh list' to see all feature IDs${NC}"
}

# Show detailed information about a feature including changes and checklist
show_details() {
    local feature="$1"

    # Check if feature exists
    if ! get_feature_ids | grep -q "^${feature}$"; then
        echo -e "${RED}Error:${NC} Feature '$feature' not found"
        echo "Use './verify.sh list' to see all feature IDs"
        return 1
    fi

    local name=$(get_yaml_value "$feature" "name")
    local desc=$(get_yaml_value "$feature" "description")
    local verified=$(get_yaml_value "$feature" "verified")
    local verified_by=$(get_yaml_value "$feature" "verified_by")
    local verified_at=$(get_yaml_value "$feature" "verified_at")
    local notes=$(get_yaml_value "$feature" "notes")

    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${WHITE}  $name${NC}"
    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${DIM}$desc${NC}"
    echo ""

    # Status
    echo -e "${BOLD}Status:${NC}"
    if [[ "$verified" == "true" ]]; then
        if check_feature_changed "$feature"; then
            echo -e "  ${YELLOW}${CHECK_INVALID}${NC} ${YELLOW}MODIFIED${NC} - verification invalidated"
            if [[ -n "$verified_by" && "$verified_by" != "null" ]]; then
                if [[ "$verified_by" == "checklist" ]]; then
                    echo -e "  ${DIM}Previously verified via checklist at ${verified_at}${NC}"
                else
                    echo -e "  ${DIM}Previously verified by ${verified_by} at ${verified_at}${NC}"
                fi
            fi
        else
            echo -e "  ${GREEN}${CHECK_ON}${NC} ${GREEN}VERIFIED${NC}"
            if [[ -n "$verified_by" && "$verified_by" != "null" ]]; then
                if [[ "$verified_by" == "checklist" ]]; then
                    echo -e "  ${DIM}Verified via checklist at ${verified_at}${NC}"
                else
                    echo -e "  ${DIM}Verified by ${verified_by} at ${verified_at}${NC}"
                fi
            fi
        fi
    else
        echo -e "  ${RED}${CHECK_OFF}${NC} ${RED}UNVERIFIED${NC}"
        if [[ -n "$notes" && "$notes" != "null" ]]; then
            echo -e "  ${DIM}Note: $notes${NC}"
        fi
    fi
    echo ""

    # Files that changed
    echo -e "${BOLD}Files:${NC}"
    local files=$(get_feature_files "$feature")
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            local filepath="${PROJECT_ROOT}/${file}"
            if [[ -f "$filepath" ]]; then
                echo -e "  ${CYAN}•${NC} $file"
                show_file_diff "$file"
            else
                echo -e "  ${RED}•${NC} $file ${DIM}(missing)${NC}"
            fi
        fi
    done <<< "$files"
    echo ""

    # Verification checklist
    echo -e "${BOLD}Verification Checklist:${NC}"
    local -a checklist_items=()
    local -a checklist_completed=()
    get_checklist_items_array "$feature" checklist_items checklist_completed

    if [[ ${#checklist_items[@]} -eq 0 ]]; then
        echo -e "  ${DIM}No specific checklist defined for this feature.${NC}"
        echo -e "  ${DIM}General verification steps:${NC}"
        echo -e "    ${WHITE}□${NC} Review the code changes"
        echo -e "    ${WHITE}□${NC} Test the feature manually"
        echo -e "    ${WHITE}□${NC} Check for edge cases"
        echo -e "    ${WHITE}□${NC} Verify error handling"
    else
        for i in "${!checklist_items[@]}"; do
            local check_icon="□"
            local item_color="$WHITE"
            if [[ "${checklist_completed[$i]}" == "true" ]]; then
                check_icon="✓"
                item_color="$GREEN"
            fi
            echo -e "  ${item_color}${check_icon}${NC} ${checklist_items[$i]}"
        done
    fi
    echo ""

    # Recent git history for these files
    echo -e "${BOLD}Recent Changes (git log):${NC}"
    local all_files=""
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            all_files+=" $file"
        fi
    done <<< "$files"

    if [[ -n "$all_files" ]]; then
        local git_log=$(git -C "$PROJECT_ROOT" log --oneline -5 -- $all_files 2>/dev/null)
        if [[ -n "$git_log" ]]; then
            echo "$git_log" | while IFS= read -r line; do
                echo -e "  ${DIM}$line${NC}"
            done
        else
            echo -e "  ${DIM}No recent commits found${NC}"
        fi
    fi
    echo ""

    # Action hint
    if [[ "$verified" != "true" ]] || check_feature_changed "$feature"; then
        echo -e "${YELLOW}To verify this feature after checking:${NC}"
        echo -e "  ./verify.sh verify $feature"
    fi
}

# Check for invalidated verifications and update them
check_invalidations() {
    echo -e "${BOLD}Checking for modified files...${NC}"
    echo ""

    local invalidated=0
    local invalidated_features=()

    while IFS= read -r feature; do
        local verified=$(get_yaml_value "$feature" "verified")
        local name=$(get_yaml_value "$feature" "name")

        if [[ "$verified" == "true" ]]; then
            if check_feature_changed "$feature"; then
                echo -e "${YELLOW}!${NC} ${name}"

                # Show which files changed
                local files=$(get_feature_files "$feature")
                while IFS= read -r file; do
                    if [[ -n "$file" ]]; then
                        local last_commit=$(git -C "$PROJECT_ROOT" log -1 --format="%h %s" -- "$file" 2>/dev/null)
                        echo -e "    ${DIM}${file}: ${last_commit}${NC}"
                    fi
                done <<< "$files"

                # Mark as unverified
                update_yaml_value "$feature" "verified" "false"
                update_yaml_value "$feature" "verified_by" "null"
                update_yaml_value "$feature" "verified_at" "null"
                update_yaml_value "$feature" "notes" "\"Auto-invalidated: files changed\""

                # Add history entry
                add_history_entry "$feature" "invalidated" "system" "Files changed - auto-invalidated"

                invalidated_features+=("$feature")
                ((++invalidated))
                echo ""
            fi
        fi
    done <<< "$(get_feature_ids)"

    if [[ $invalidated -eq 0 ]]; then
        echo -e "${GREEN}✓${NC} All verifications are still valid"
    else
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}!${NC} $invalidated verification(s) invalidated due to file changes"
        echo ""
        echo -e "${BOLD}To see what needs to be re-verified:${NC}"
        for feat in "${invalidated_features[@]}"; do
            echo -e "  ./verify.sh details $feat"
        done
    fi
}

# Mark a feature as verified
verify_feature() {
    local feature="$1"
    local verifier="${2:-$(whoami)}"

    # Check if feature exists
    if ! get_feature_ids | grep -q "^${feature}$"; then
        echo -e "${RED}Error:${NC} Feature '$feature' not found"
        echo "Use './verify.sh list' to see all feature IDs"
        return 1
    fi

    local name=$(get_yaml_value "$feature" "name")
    local files=$(get_feature_files "$feature")
    local hash=$(calculate_hash "$files")
    local timestamp=$(date -Iseconds)

    update_yaml_value "$feature" "verified" "true"
    update_yaml_value "$feature" "verified_by" "\"$verifier\""
    update_yaml_value "$feature" "verified_at" "\"$timestamp\""
    update_yaml_value "$feature" "file_hash" "\"$hash\""
    update_yaml_value "$feature" "notes" "null"

    # Add history entry
    add_history_entry "$feature" "verified" "$verifier" "Manual verification"

    echo -e "${GREEN}✓${NC} Marked '$name' as verified by $verifier"
}

# Mark a feature as unverified
unverify_feature() {
    local feature="$1"

    # Check if feature exists
    if ! get_feature_ids | grep -q "^${feature}$"; then
        echo -e "${RED}Error:${NC} Feature '$feature' not found"
        echo "Use './verify.sh list' to see all feature IDs"
        return 1
    fi

    local name=$(get_yaml_value "$feature" "name")

    update_yaml_value "$feature" "verified" "false"
    update_yaml_value "$feature" "verified_by" "null"
    update_yaml_value "$feature" "verified_at" "null"
    update_yaml_value "$feature" "file_hash" "null"
    update_yaml_value "$feature" "notes" "null"

    # Add history entry
    add_history_entry "$feature" "unverified" "$(whoami)" "Manual unverification"

    echo -e "${RED}○${NC} Marked '$name' as unverified"
}

# List all feature IDs
list_features() {
    echo -e "${BOLD}Feature IDs:${NC}"
    echo ""

    while IFS= read -r feature; do
        local name=$(get_yaml_value "$feature" "name")
        local verified=$(get_yaml_value "$feature" "verified")

        local status
        if [[ "$verified" == "true" ]]; then
            if check_feature_changed "$feature"; then
                status="${YELLOW}!${NC}"
            else
                status="${GREEN}✓${NC}"
            fi
        else
            status="${RED}○${NC}"
        fi

        printf "  %b %-25s %b%b\n" "$status" "$feature" "${DIM}${name}" "${NC}"
    done <<< "$(get_feature_ids)"
}

# Show summary statistics
show_summary() {
    local verified=0
    local unverified=0
    local modified=0
    local total_features=0

    while IFS= read -r feature; do
        ((++total_features))
        local v=$(get_yaml_value "$feature" "verified")

        if [[ "$v" == "true" ]]; then
            if check_feature_changed "$feature"; then
                ((++modified))
            else
                ((++verified))
            fi
        else
            ((++unverified))
        fi
    done <<< "$(get_feature_ids)"

    local pct=0
    if [[ $total_features -gt 0 ]]; then
        pct=$((verified * 100 / total_features))
    fi

    # Get checklist item counts
    local total_items=$(count_total_items)
    local machine_verified=$(count_machine_verified_items)
    local human_verified=$(count_human_verified_items)
    local fully_verified=$(count_fully_verified_items)

    local machine_pct=0
    local human_pct=0
    local full_pct=0

    if [[ $total_items -gt 0 ]]; then
        machine_pct=$((machine_verified * 100 / total_items))
        human_pct=$((human_verified * 100 / total_items))
        full_pct=$((fully_verified * 100 / total_items))
    fi

    echo -e "${BOLD}Verification Summary${NC}"
    echo -e "${DIM}═══════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Features:${NC}"
    echo -e "    Total:         $total_features"
    echo -e "    ${GREEN}Verified:${NC}      $verified (${pct}%)"
    echo -e "    ${RED}Unverified:${NC}    $unverified"
    echo -e "    ${YELLOW}Modified:${NC}      $modified"
    echo ""
    echo -e "  ${BOLD}Checklist Items:${NC}"
    printf "    Total:           %d\n" "$total_items"
    printf "    ${CYAN}Machine Verified:${NC} %d (%d%%)\n" "$machine_verified" "$machine_pct"
    printf "    ${BLUE}Human Verified:${NC}   %d (%d%%)\n" "$human_verified" "$human_pct"
    printf "    ${GREEN}Fully Verified:${NC}   %d (%d%%)\n" "$fully_verified" "$full_pct"
    echo ""

    # Progress bar for features
    local bar_width=40
    local filled=$((verified * bar_width / total_features))
    local empty=$((bar_width - filled))

    echo -e "  ${DIM}Feature Progress:${NC}"
    printf "  ["
    if [[ $filled -gt 0 ]]; then
        for ((i=0; i<filled; i++)); do printf "${GREEN}█${NC}"; done
    fi
    for ((i=0; i<empty; i++)); do printf "${DIM}░${NC}"; done
    printf "] %d%%\n" $pct
    echo ""

    # Progress bar for machine verification
    local machine_filled=$((machine_verified * bar_width / total_items))
    local machine_empty=$((bar_width - machine_filled))

    echo -e "  ${DIM}Machine Verification:${NC}"
    printf "  ["
    if [[ $machine_filled -gt 0 ]]; then
        for ((i=0; i<machine_filled; i++)); do printf "${CYAN}█${NC}"; done
    fi
    for ((i=0; i<machine_empty; i++)); do printf "${DIM}░${NC}"; done
    printf "] %d%%\n" $machine_pct
}

# Interactive verification mode
interactive_verify() {
    echo -e "${BOLD}Interactive Verification Mode${NC}"
    echo -e "${DIM}Enter feature ID to verify, or 'q' to quit${NC}"
    echo ""

    list_features
    echo ""

    while true; do
        echo -n "Feature ID (or 'q'): "
        read -r input

        if [[ "$input" == "q" || "$input" == "quit" ]]; then
            break
        fi

        if [[ -n "$input" ]]; then
            echo -n "Your name (or Enter for $(whoami)): "
            read -r verifier
            verifier="${verifier:-$(whoami)}"

            verify_feature "$input" "$verifier" || true
            echo ""
        fi
    done
}

# Reset all verifications
reset_all() {
    echo -n "Are you sure you want to reset all verifications? [y/N] "
    read -r confirm

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        while IFS= read -r feature; do
            update_yaml_value "$feature" "verified" "false"
            update_yaml_value "$feature" "verified_by" "null"
            update_yaml_value "$feature" "verified_at" "null"
            update_yaml_value "$feature" "file_hash" "null"
            update_yaml_value "$feature" "notes" "null"
        done <<< "$(get_feature_ids)"

        echo -e "${GREEN}✓${NC} All verifications have been reset"
    else
        echo "Cancelled"
    fi
}

# Terminal control functions
cursor_hide() { printf '\033[?25l'; }
cursor_show() { printf '\033[?25h'; }
cursor_to() { printf '\033[%d;%dH' "$1" "$2"; }
clear_screen() { printf '\033[2J\033[H'; }
clear_line() { printf '\033[2K'; }

# Get category for a feature (max 14 per group for TUI display)
get_feature_category() {
    local feature="$1"
    case "$feature" in
        # Group 1: Core Scripts (12)
        setup|install|status|modify|backup|restore|sync|copy|delete|make|migration|import)
            echo "Core Scripts" ;;

        # Group 2: Deployment (8)
        live|dev2stg|stg2prod|prod2stg|stg2live|live2stg|live2prod|produce)
            echo "Deployment" ;;

        # Group 3: Infrastructure (11)
        podcast|schedule|security|setup_ssh|uninstall|pl_cli|test_nwp|moodle|theme|doctor|bootstrap_coder)
            echo "Infrastructure" ;;

        # Group 4: AVC-Moodle Integration (4)
        avc_moodle_setup|avc_moodle_status|avc_moodle_sync|avc_moodle_test)
            echo "AVC-Moodle" ;;

        # Group 5: Installation Libraries (6)
        lib_install_common|lib_install_drupal|lib_install_gitlab|lib_install_moodle|lib_install_podcast|lib_install_steps)
            echo "Lib: Install" ;;

        # Group 6: Core Utilities (7)
        lib_common|lib_ui|lib_terminal|lib_state|lib_safe_ops|lib_database_router|lib_preflight)
            echo "Lib: Core Utils" ;;

        # Group 7: Infrastructure & Cloud (7)
        lib_cloudflare|lib_linode|lib_b2|lib_remote|lib_badges|lib_server_scan|lib_live_server_setup)
            echo "Lib: Cloud" ;;

        # Group 8: Git & Development (4)
        lib_git|lib_developer|lib_ddev_generate|lib_env_generate)
            echo "Lib: Git & Dev" ;;

        # Group 9: User Interface (5)
        lib_tui|lib_checkbox|lib_cli_register|lib_dev2stg_tui|lib_import_tui)
            echo "Lib: UI" ;;

        # Group 10: Data & Configuration (4)
        lib_yaml_write|lib_import|lib_sanitize|lib_testing)
            echo "Lib: Data" ;;

        # Group 11: Specialized Libraries (4)
        lib_frontend|lib_avc_moodle|lib_podcast|lib_ssh)
            echo "Lib: Specialized" ;;

        # Group 12: Services & Config (future features)
        gitlab_*|linode_*|config_*|example_*|tests_*)
            echo "Services & Config" ;;

        # Group 13: CI/CD & Quality (future features)
        ci_*|renovate|dependabot|security_update|notify_*|phpstan_config|pre_commit_hook|pr_templates)
            echo "CI/CD & Quality" ;;

        # Group 14: Server & Production (future features)
        server_*|coder_*|monitoring_daemon|production_dashboard|scheduled_backup|verify_backup|disaster_recovery|preview_environments|environments_doc|bluegreen_deploy|canary_release|perf_baseline|visual_regression|advanced_deployment_doc)
            echo "Server & Production" ;;

        *)
            echo "Other" ;;
    esac
}

# Build feature data arrays grouped by category
build_feature_arrays() {
    FEATURE_IDS=()
    FEATURE_NAMES=()
    FEATURE_CATEGORIES=()
    FEATURE_STATUS=()  # 0=unverified, 1=verified, 2=modified, 3=partial, 4=machine-only
    FEATURE_MACHINE=()  # "M/N" format for machine verification
    CATEGORY_LIST=()
    declare -gA CATEGORY_START=()  # Start index for each category
    declare -gA CATEGORY_COUNT=()  # Count of features in each category

    # First pass: collect all features with their categories
    local -a all_features=()
    local -a all_names=()
    local -a all_categories=()
    local -a all_status=()
    local -a all_machine=()

    while IFS= read -r feature; do
        [[ -z "$feature" ]] && continue

        local name=$(get_yaml_value "$feature" "name")
        local verified=$(get_yaml_value "$feature" "verified")
        local category=$(get_feature_category "$feature")
        local status=0

        # Calculate status based on verification and checklist completion
        local total_items=$(get_checklist_item_count "$feature")
        local completed_items=$(get_completed_checklist_item_count "$feature")

        # Get machine verification counts
        local machine_verified=$(count_feature_machine_verified "$feature" 2>/dev/null || echo "0")
        local machine_checkable=$(count_feature_machine_checkable "$feature" 2>/dev/null || echo "0")
        local machine_info=""
        if [[ $machine_checkable -gt 0 ]]; then
            machine_info="${machine_verified}/${machine_checkable}"
        fi

        if [[ "$verified" == "true" ]]; then
            if check_feature_changed "$feature" 2>/dev/null; then
                status=2  # Modified since verification
            else
                status=1  # Verified
            fi
        elif [[ $total_items -gt 0 ]] && [[ $completed_items -gt 0 ]]; then
            # Some checklist items completed but not fully verified
            local pct=$((completed_items * 100 / total_items))
            if [[ $pct -eq 100 ]]; then
                # All items done but not verified yet - still partial
                status=3
            else
                status=3  # Partial completion
            fi
        elif [[ $machine_verified -gt 0 ]]; then
            # Has machine verification but no human verification
            status=4  # Machine-only partial
        fi

        all_features+=("$feature")
        all_names+=("${name:-$feature}")
        all_categories+=("$category")
        all_status+=("$status")
        all_machine+=("$machine_info")
    done <<< "$(get_feature_ids)"

    # Define category order (for consistent ordering)
    local -a category_order=("Core Scripts" "Deployment" "Infrastructure" "AVC-Moodle" "Lib: Install" "Lib: Core Utils" "Lib: Cloud" "Lib: Git & Dev" "Lib: UI" "Lib: Data" "Lib: Specialized" "Services & Config" "CI/CD & Quality" "Server & Production" "Other")

    # Second pass: add features in category order
    local idx=0
    for cat in "${category_order[@]}"; do
        local cat_has_features=false

        for i in "${!all_features[@]}"; do
            if [[ "${all_categories[$i]}" == "$cat" ]]; then
                if [[ "$cat_has_features" == false ]]; then
                    CATEGORY_LIST+=("$cat")
                    CATEGORY_START["$cat"]=$idx
                    CATEGORY_COUNT["$cat"]=0
                    cat_has_features=true
                fi

                FEATURE_IDS+=("${all_features[$i]}")
                FEATURE_NAMES+=("${all_names[$i]}")
                FEATURE_CATEGORIES+=("$cat")
                FEATURE_STATUS+=("${all_status[$i]}")
                FEATURE_MACHINE+=("${all_machine[$i]}")
                CATEGORY_COUNT["$cat"]=$((CATEGORY_COUNT["$cat"] + 1))
                idx=$((idx + 1))
            fi
        done
    done
}

# Draw checklist preview below feature line
draw_checklist_preview() {
    local feature="$1"
    local max_items="${2:-3}"

    local -a items=()
    local -a completed=()
    get_checklist_items_array "$feature" items completed

    [[ ${#items[@]} -eq 0 ]] && return

    local count=0
    for i in "${!items[@]}"; do
        [[ $count -ge $max_items ]] && break

        local check_icon="[ ]"
        local item_color="$DIM"
        [[ "${completed[$i]}" == "true" ]] && check_icon="[✓]" && item_color="$GREEN"

        # Tree character
        local tree_char="├─"
        [[ $i -eq $((${#items[@]} - 1)) || $count -eq $((max_items - 1)) ]] && tree_char="└─"

        # Truncate long items
        local item_text="${items[$i]}"
        local max_len=$(($(tput cols) - 20))
        [[ ${#item_text} -gt $max_len ]] && item_text="${item_text:0:$((max_len - 3))}..."

        printf "    ${DIM}%s${NC} ${item_color}%s${NC} %s\n" "$tree_char" "$check_icon" "$item_text"
        count=$((count + 1))
    done

    # Show "X more..." if there are more items
    if [[ ${#items[@]} -gt $max_items ]]; then
        local remaining=$((${#items[@]} - max_items))
        printf "    ${DIM}    ... %d more item(s)${NC}\n" "$remaining"
    fi
}

# Draw the console TUI with category pages
draw_console() {
    local cat_idx="$1"
    local feat_idx="$2"  # Index within current category
    local preview_mode="${3:-false}"  # Preview mode flag
    local width=$(tput cols)
    local max_lines=$(($(tput lines) - 10))

    local category="${CATEGORY_LIST[$cat_idx]}"
    local cat_start="${CATEGORY_START[$category]}"
    local cat_count="${CATEGORY_COUNT[$category]}"
    local global_idx=$((cat_start + feat_idx))

    clear_screen

    # Header (split into two lines for readability)
    echo -e "${BOLD}NWP Verification Console${NC}"
    echo -e "${DIM}←→:Category ↑↓:Feature | v:Verify i:Checklist u:Unverify | d:Details n:Notes h:History p:Preview | c:Check r:Refresh q:Quit${NC}"
    printf '═%.0s' $(seq 1 $width)
    echo ""

    # Count stats
    local verified_count=0 unverified_count=0 modified_count=0 partial_count=0 machine_count=0
    for stat in "${FEATURE_STATUS[@]}"; do
        case "$stat" in
            0) unverified_count=$((unverified_count + 1)) ;;
            1) verified_count=$((verified_count + 1)) ;;
            2) modified_count=$((modified_count + 1)) ;;
            3) partial_count=$((partial_count + 1)) ;;
            4) machine_count=$((machine_count + 1)) ;;
        esac
    done

    printf "  ${GREEN}[✓]Verified: %d${NC}  |  ${YELLOW}[◐]Partial: %d${NC}  |  ${CYAN}[⚙]Machine: %d${NC}  |  ${DIM}[○]Unverified: %d${NC}  |  ${YELLOW}[!]Modified: %d${NC}\n" \
        "$verified_count" "$partial_count" "$machine_count" "$unverified_count" "$modified_count"
    printf '─%.0s' $(seq 1 $width)
    echo ""

    # Category navigation bar
    printf "  "
    for i in "${!CATEGORY_LIST[@]}"; do
        local cat="${CATEGORY_LIST[$i]}"
        local cat_verified=0 cat_total=0
        local start="${CATEGORY_START[$cat]}"
        local count="${CATEGORY_COUNT[$cat]}"

        for ((j=start; j<start+count; j++)); do
            cat_total=$((cat_total + 1))
            if [[ "${FEATURE_STATUS[$j]}" == "1" ]]; then
                cat_verified=$((cat_verified + 1))
            fi
        done

        if [[ $i -eq $cat_idx ]]; then
            printf "${WHITE}${BOLD}[%s (%d/%d)]${NC} " "$cat" "$cat_verified" "$cat_total"
        else
            printf "${DIM}%s${NC} " "$cat"
        fi
    done
    echo ""
    printf '─%.0s' $(seq 1 $width)
    echo ""

    # Category header
    echo -e "  ${BOLD}${CYAN}── $category ──${NC}  (${cat_count} features, page $((cat_idx + 1))/${#CATEGORY_LIST[@]})"
    echo ""

    # Features in this category
    local line_count=0
    for ((i=0; i<cat_count && line_count<max_lines; i++)); do
        local idx=$((cat_start + i))
        local feature="${FEATURE_IDS[$idx]}"
        local name="${FEATURE_NAMES[$idx]}"
        local status="${FEATURE_STATUS[$idx]}"
        local machine="${FEATURE_MACHINE[$idx]}"

        # Status indicator
        local indicator status_color machine_indicator=""
        case "$status" in
            0) indicator="$CHECK_OFF"; status_color="$DIM" ;;
            1) indicator="$CHECK_ON"; status_color="$GREEN" ;;
            2) indicator="$CHECK_INVALID"; status_color="$YELLOW" ;;
            3) indicator="[◐]"; status_color="$YELLOW" ;;  # Partial completion (human)
            4) indicator="[◐]"; status_color="$CYAN" ;;    # Partial completion (machine)
        esac

        # Add machine verification indicator
        if [[ -n "$machine" ]]; then
            local m_done="${machine%/*}"
            local m_total="${machine#*/}"
            if [[ "$m_done" -eq "$m_total" ]]; then
                machine_indicator="${GREEN}⚙${NC}"
            elif [[ "$m_done" -gt 0 ]]; then
                machine_indicator="${YELLOW}⚙${NC}"
            else
                machine_indicator="${DIM}⚙${NC}"
            fi
        fi

        # Highlight current selection
        if [[ $i -eq $feat_idx ]]; then
            printf "${WHITE}>${NC}"
        else
            printf " "
        fi

        # Truncate name if too long
        local max_name_len=$((width - 40))
        local display_name="$name"
        if [[ ${#display_name} -gt $max_name_len ]]; then
            display_name="${display_name:0:$((max_name_len-3))}..."
        fi

        # Display with machine info
        if [[ -n "$machine_indicator" ]]; then
            printf " ${status_color}%s${NC} %b %-16s %s ${DIM}(%s)${NC}\n" "$indicator" "$machine_indicator" "($feature)" "$display_name" "$machine"
        else
            printf " ${status_color}%s${NC}   %-16s %s\n" "$indicator" "($feature)" "$display_name"
        fi
        line_count=$((line_count + 1))

        # Show checklist preview if enabled
        if [[ "$preview_mode" == "true" ]] && [[ $line_count -lt $max_lines ]]; then
            draw_checklist_preview "$feature" 3
            # Adjust line count (estimate 4 lines for preview)
            local preview_lines=$(get_checklist_item_count "$feature")
            [[ $preview_lines -gt 3 ]] && preview_lines=4 || preview_lines=$((preview_lines + 1))
            line_count=$((line_count + preview_lines))
        fi
    done

    # Footer with current feature details
    echo ""
    printf '─%.0s' $(seq 1 $width)
    echo ""

    if [[ $cat_count -gt 0 ]]; then
        local current_feature="${FEATURE_IDS[$global_idx]}"
        local current_name="${FEATURE_NAMES[$global_idx]}"
        local desc=$(get_yaml_value "$current_feature" "description")
        local verified_by=$(get_yaml_value "$current_feature" "verified_by")
        local verified_at=$(get_yaml_value "$current_feature" "verified_at")

        printf "  ${BOLD}%s${NC}" "$current_name"
        if [[ -n "$desc" && "$desc" != "null" ]]; then
            echo ""
            printf "  ${DIM}%s${NC}" "$desc"
        fi
        echo ""

        if [[ "${FEATURE_STATUS[$global_idx]}" == "1" && "$verified_by" != "null" ]]; then
            if [[ "$verified_by" == "checklist" ]]; then
                printf "  ${GREEN}✓ Verified via checklist at %s${NC}\n" "$verified_at"
            else
                printf "  ${GREEN}✓ Verified by %s at %s${NC}\n" "$verified_by" "$verified_at"
            fi
        elif [[ "${FEATURE_STATUS[$global_idx]}" == "2" ]]; then
            printf "  ${YELLOW}⚠ Modified since last verification${NC}\n"
        fi
    fi
}

# Toggle checklist item completion
toggle_checklist_item() {
    local feature="$1"
    local item_idx="$2"
    local username="$(whoami)"
    local timestamp="$(date -Iseconds)"

    local is_completed=$(get_checklist_item_status "$feature" "$item_idx")

    if [[ "$is_completed" == "true" ]]; then
        # Mark as incomplete
        update_checklist_item "$feature" "$item_idx" "completed" "false"
        update_checklist_item "$feature" "$item_idx" "completed_by" "null"
        update_checklist_item "$feature" "$item_idx" "completed_at" "null"
        add_history_entry "$feature" "checklist_item_uncompleted" "$username" "Item $((item_idx + 1)) marked incomplete"

        # If feature was auto-verified via checklist, unverify it
        local verified_by=$(get_yaml_value "$feature" "verified_by")
        if [[ "$verified_by" == "checklist" ]]; then
            update_yaml_value "$feature" "verified" "false"
            update_yaml_value "$feature" "verified_by" "null"
            update_yaml_value "$feature" "verified_at" "null"
            add_history_entry "$feature" "unverified" "$username" "Checklist item uncompleted"
        fi
    else
        # Mark as complete
        update_checklist_item "$feature" "$item_idx" "completed" "true"
        update_checklist_item "$feature" "$item_idx" "completed_by" "\"$username\""
        update_checklist_item "$feature" "$item_idx" "completed_at" "\"$timestamp\""
        add_history_entry "$feature" "checklist_item_completed" "$username" "Item $((item_idx + 1)) completed"

        # Check if all checklist items are now complete - auto-verify
        local total_items=$(get_checklist_item_count "$feature" 2>/dev/null || echo "0")
        local completed_items=$(get_completed_checklist_item_count "$feature" 2>/dev/null || echo "0")

        if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
            local current_verified=$(get_yaml_value "$feature" "verified")
            if [[ "$current_verified" != "true" ]]; then
                # Auto-verify: all checklist items complete
                local files=$(get_feature_files "$feature")
                local hash=$(calculate_hash "$files")
                update_yaml_value "$feature" "verified" "true"
                update_yaml_value "$feature" "verified_by" "\"checklist\""
                update_yaml_value "$feature" "verified_at" "\"$timestamp\""
                update_yaml_value "$feature" "file_hash" "\"$hash\""
                add_history_entry "$feature" "verified" "checklist" "All checklist items completed"
            fi
        fi
    fi
}

# Open a file with the system's default handler or editor
# Note: For the verify TUI, docs are opened inline in show_item_details()
# This function is kept for potential future use or external calls
open_doc_file() {
    local filepath="$1"
    local full_path

    # Get absolute path
    if [[ "$filepath" = /* ]]; then
        full_path="$filepath"
    else
        full_path="$(cd "$(dirname "$VERIFICATION_FILE")" && pwd)/$filepath"
    fi

    # Check if file exists
    if [[ ! -f "$full_path" ]]; then
        echo -e "${RED}File not found: $full_path${NC}"
        return 1
    fi

    # Reset terminal state
    stty sane 2>/dev/null

    local ext="${filepath##*.}"

    # Try to detect best editor (non-blocking for viewing)
    local editor=$(detect_best_editor)
    if [[ -n "$editor" ]]; then
        # Check if it's a GUI editor (non-blocking)
        if [[ "$editor" =~ ^(codium|code) ]]; then
            # GUI editor - open and return immediately (non-blocking)
            eval "$editor" '"$full_path"' &>/dev/null &
            return 0
        else
            # Terminal editor - open and wait
            eval "$editor" '"$full_path"'
            return 0
        fi
    fi

    # Fallback: display with cat for text files
    if [[ "$ext" == "md" || "$ext" == "txt" || "$ext" == "sh" ]]; then
        clear
        echo -e "${BOLD}=== $filepath ===${NC}"
        echo ""
        cat "$full_path"
        echo ""
        echo -e "${DIM}─── End of file ───${NC}"
        read -p "Press Enter to return..."
        return 0
    fi

    # Fallback to cat for any file
    clear
    cat "$full_path"
    echo ""
    read -p "Press Enter to continue..."
    return 0
}

# Create OSC 8 hyperlink (clickable in modern terminals)
# Format: \e]8;;URL\e\\TEXT\e]8;;\e\\
make_hyperlink() {
    local url="$1"
    local text="$2"
    local full_path

    # Convert to absolute file:// URL
    if [[ "$url" = /* ]]; then
        full_path="$url"
    else
        full_path="$(cd "$(dirname "$VERIFICATION_FILE")" && pwd)/$url"
    fi

    # OSC 8 hyperlink format
    printf '\e]8;;file://%s\e\\%s\e]8;;\e\\' "$full_path" "$text"
}

# Show item details (how_to_verify and related_docs)
show_item_details() {
    local feature="$1"
    local item_idx="$2"
    local item_text="$3"

    # Get details once
    local details=$(get_checklist_item_details "$feature" "$item_idx")
    local how_to_verify="${details%%|||*}"
    local related_docs="${details##*|||}"

    # Store docs in array for selection
    local -a docs_array=()
    if [[ -n "$related_docs" ]]; then
        while IFS= read -r doc; do
            [[ -n "$doc" ]] && docs_array+=("$doc")
        done <<< "$related_docs"
    fi

    # Reset terminal and show cursor
    stty sane 2>/dev/null
    cursor_show
    clear_screen

    # Header
    echo -e "${BOLD}Item Details${NC}"
    printf '═%.0s' $(seq 1 $(tput cols))
    echo ""

    # Item text
    echo -e "${CYAN}Item:${NC}"
    echo -e "  $item_text"
    echo ""

    # How to verify section
    echo -e "${CYAN}How to Verify:${NC}"
    if [[ -n "$how_to_verify" ]]; then
        echo "$how_to_verify" | while IFS= read -r line; do
            echo -e "  $line"
        done
    else
        echo -e "  ${DIM}No verification instructions available${NC}"
    fi
    echo ""

    # Related docs section with numbered links
    echo -e "${CYAN}Related Documentation:${NC}"
    if [[ ${#docs_array[@]} -gt 0 ]]; then
        for i in "${!docs_array[@]}"; do
            local doc="${docs_array[$i]}"
            local num=$((i + 1))
            printf "  ${WHITE}[%d]${NC} " "$num"
            make_hyperlink "$doc" "$doc"
            echo ""
        done
        echo ""
        printf '─%.0s' $(seq 1 $(tput cols))
        echo ""
        echo -e "Press ${WHITE}1-${#docs_array[@]}${NC} to open a doc, ${WHITE}Enter${NC} to return"
        echo ""

        # Read user choice
        read -rsn1 key

        case "$key" in
            [1-9])
                local doc_idx=$((key - 1))
                if [[ $doc_idx -lt ${#docs_array[@]} ]]; then
                    local doc_to_open="${docs_array[$doc_idx]}"
                    local full_doc_path

                    # Build full path (use PROJECT_ROOT)
                    if [[ "$doc_to_open" = /* ]]; then
                        full_doc_path="$doc_to_open"
                    else
                        full_doc_path="$PROJECT_ROOT/$doc_to_open"
                    fi

                    # Try to open with best editor
                    local editor=$(detect_best_editor)
                    if [[ -n "$editor" ]] && [[ -f "$full_doc_path" ]]; then
                        # Check if it's a GUI editor (non-blocking)
                        if [[ "$editor" =~ ^(codium|code) ]]; then
                            # GUI editor - open and return immediately
                            eval "$editor" '"$full_doc_path"' &>/dev/null &
                            sleep 0.2  # Brief pause to let editor launch
                        else
                            # Terminal editor - open and wait
                            eval "$editor" '"$full_doc_path"'
                        fi
                    else
                        # Fallback to cat display
                        clear
                        echo -e "${BOLD}=== $doc_to_open ===${NC}"
                        echo ""
                        if [[ -f "$full_doc_path" ]]; then
                            cat "$full_doc_path"
                        else
                            echo -e "${RED}File not found: $full_doc_path${NC}"
                        fi
                        echo ""
                        echo -e "${DIM}─── End of file ───${NC}"
                        read -p "Press Enter to return..."
                    fi
                fi
                ;;
        esac
    else
        echo -e "  ${DIM}No related documentation${NC}"
        echo ""
        printf '─%.0s' $(seq 1 $(tput cols))
        echo ""
        read -p "Press Enter to return..."
    fi

    cursor_hide
}

# Draw checklist editor screen
draw_checklist_editor() {
    local feature="$1"
    local selected="$2"
    local feat_name="$3"

    clear_screen
    echo -e "${BOLD}Checklist Editor: $feat_name${NC}"
    echo -e "${DIM}Use ↑↓ to navigate, Space to toggle, ${WHITE}d${DIM} for details, Enter/q to exit${NC}"
    printf '═%.0s' $(seq 1 $(tput cols))
    echo ""

    # Get checklist items with completion status
    local -a items=()
    local -a completed=()
    get_checklist_items_array "$feature" items completed

    if [[ ${#items[@]} -eq 0 ]]; then
        echo -e "  ${DIM}No checklist items for this feature${NC}"
        return
    fi

    for i in "${!items[@]}"; do
        local check_mark="[ ]"
        local item_color="$DIM"
        if [[ "${completed[$i]}" == "true" ]]; then
            check_mark="[✓]"
            item_color="$GREEN"
        fi

        if [[ $i -eq $selected ]]; then
            printf "${WHITE}> %s %s${NC}\n" "$check_mark" "${items[$i]}"
        else
            printf "  ${item_color}%s${NC} %s\n" "$check_mark" "${items[$i]}"
        fi
    done

    echo ""
    local completed_count=0
    for c in "${completed[@]}"; do
        [[ "$c" == "true" ]] && completed_count=$((completed_count + 1))
    done
    printf "${DIM}Progress: %d/%d items completed${NC}\n" "$completed_count" "${#items[@]}"
}

# Edit checklist items interactively
edit_checklist_items() {
    local feature="$1"
    local feat_name="$2"
    local selected_idx=0

    cursor_hide

    # Get initial item count
    local -a items=()
    local -a completed=()
    get_checklist_items_array "$feature" items completed
    local total=${#items[@]}

    if [[ $total -eq 0 ]]; then
        cursor_show
        clear_screen
        echo -e "${YELLOW}No checklist items for this feature${NC}"
        echo ""
        read -p "Press Enter to continue..."
        return
    fi

    while true; do
        draw_checklist_editor "$feature" "$selected_idx" "$feat_name"

        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')  # Escape sequence
                read -rsn2 -t 0.1 key2
                case "$key2" in
                    '[A')  # Up arrow
                        if [[ $selected_idx -gt 0 ]]; then
                            selected_idx=$((selected_idx - 1))
                        fi
                        ;;
                    '[B')  # Down arrow
                        if [[ $selected_idx -lt $((total - 1)) ]]; then
                            selected_idx=$((selected_idx + 1))
                        fi
                        ;;
                    '')  # Plain Escape - go back
                        break
                        ;;
                esac
                ;;
            ' ')  # Space - toggle completion
                toggle_checklist_item "$feature" "$selected_idx"
                # Redraw immediately to show change
                ;;
            'd'|'D')  # Show item details
                show_item_details "$feature" "$selected_idx" "${items[$selected_idx]}"
                ;;
            'q'|'Q'|$'\n')  # Quit - go back to main console
                break
                ;;
        esac
    done

    cursor_show
}

# Edit feature notes in text editor
edit_feature_notes() {
    local feature="$1"
    local feat_name="$2"
    local current_notes=$(get_yaml_value "$feature" "notes")

    # Detect best editor (with --wait for blocking behavior)
    local editor=$(detect_best_editor --wait)

    if [[ -z "$editor" ]]; then
        echo -e "${RED}Error: No text editor found${NC}"
        echo -e "${DIM}Install codium, nano, vim, or vi${NC}"
        echo ""
        read -p "Press Enter to continue..."
        return 1
    fi

    # Create temp file
    local tmpfile=$(mktemp /tmp/nwp-verify-notes.XXXXXX)

    # Write current notes
    if [[ -n "$current_notes" && "$current_notes" != "null" ]]; then
        echo "$current_notes" > "$tmpfile"
    fi

    # Show instructions
    cursor_show
    clear_screen
    echo -e "${BOLD}Editing notes for: $feat_name${NC}"
    echo -e "${DIM}Editor: $editor${NC}"
    echo -e "${DIM}Save and exit editor when done${NC}"
    echo ""
    read -p "Press Enter to open editor..."

    # Open editor (use eval to handle editors with flags like "codium --wait")
    eval "$editor" '"$tmpfile"'

    # Read back notes
    local new_notes=$(cat "$tmpfile")

    # Update YAML
    if [[ -z "$new_notes" ]]; then
        # Remove notes if empty
        update_yaml_value "$feature" "notes" "null"
    else
        # Escape quotes and newlines for YAML
        new_notes="${new_notes//\\/\\\\}"  # Escape backslashes first
        new_notes="${new_notes//\"/\\\"}"  # Escape quotes
        # For multi-line notes, use YAML literal block scalar
        if [[ "$new_notes" == *$'\n'* ]]; then
            # Multi-line: use literal block scalar (|)
            # For simplicity, we'll just escape newlines for now
            new_notes="${new_notes//$'\n'/\\n}"
        fi
        update_yaml_value "$feature" "notes" "\"$new_notes\""
    fi

    # Cleanup
    rm -f "$tmpfile"

    cursor_hide
    clear_screen
    echo -e "${GREEN}✓${NC} Notes updated"
    echo ""
    read -p "Press Enter to continue..."

    # Add history entry
    add_history_entry "$feature" "notes_updated" "$(whoami)" ""
}

# Get feature history (limit to last N entries)
get_feature_history() {
    local feature="$1"
    local limit="${2:-10}"
    local version=$(get_schema_version)

    # Only show history for v2 schema
    [[ "$version" != "2" ]] && return 0

    awk -v feature="$feature" -v limit="$limit" '
    BEGIN { in_feature = 0; in_history = 0; count = 0; in_entry = 0 }
    BEGIN { action = ""; by = ""; at = ""; context = "" }
    /^  [a-z0-9_]+:/ {
        test = $0
        gsub(/^  /, "", test)
        gsub(/:.*/, "", test)
        if (test == feature) {
            in_feature = 1
        } else if (in_feature) {
            exit
        }
    }
    in_feature && /^    history:/ {
        in_history = 1
        next
    }
    in_feature && in_history && /^      - action:/ {
        # Print previous entry if it exists
        if (in_entry && count < limit) {
            print action "|" by "|" at "|" context
            count++
        }
        # Start new entry
        gsub(/^      - action: *"?/, "")
        gsub(/"$/, "")
        action = $0
        by = ""
        at = ""
        context = ""
        in_entry = 1
        if (count >= limit) exit
    }
    in_feature && in_history && in_entry && /^        by:/ {
        gsub(/^        by: *"?/, "")
        gsub(/"$/, "")
        by = $0
    }
    in_feature && in_history && in_entry && /^        at:/ {
        gsub(/^        at: *"?/, "")
        gsub(/"$/, "")
        at = $0
    }
    in_feature && in_history && in_entry && /^        context:/ {
        gsub(/^        context: *"?/, "")
        gsub(/"$/, "")
        context = $0
    }
    in_feature && in_history && /^    [a-z]/ {
        # End of history section
        if (in_entry && count < limit) {
            print action "|" by "|" at "|" context
        }
        exit
    }
    END {
        if (in_entry && count < limit) {
            print action "|" by "|" at "|" context
        }
    }
    ' "$VERIFICATION_FILE"
}

# Show history screen
show_history() {
    local feature="$1"
    local feat_name="$2"

    cursor_show
    clear_screen

    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${WHITE}  Verification History: $feat_name${NC}"
    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local history=$(get_feature_history "$feature" 10)

    if [[ -z "$history" ]]; then
        echo -e "  ${DIM}No history recorded for this feature${NC}"
        echo -e "  ${DIM}History tracking requires schema v2${NC}"
    else
        local entry_count=0
        while IFS='|' read -r action by at context; do
            entry_count=$((entry_count + 1))

            # Format timestamp
            local date_str=$(date -d "$at" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$at")

            # Action icon and color
            local icon="ℹ" color="$BLUE"
            case "$action" in
                verified) icon="✓"; color="$GREEN" ;;
                unverified) icon="○"; color="$RED" ;;
                invalidated) icon="!"; color="$YELLOW" ;;
                checklist_item_completed) icon="✓"; color="$GREEN" ;;
                checklist_item_uncompleted) icon="○"; color="$DIM" ;;
                notes_updated) icon="📝"; color="$CYAN" ;;
                *) icon="ℹ"; color="$BLUE" ;;
            esac

            # Format action name (capitalize and replace underscores)
            local action_display="$action"
            action_display="${action_display//_/ }"
            action_display="$(tr '[:lower:]' '[:upper:]' <<< ${action_display:0:1})${action_display:1}"

            printf "  %s  %-10s  %b%s%b %s\n" "$date_str" "$by" "$color" "$icon" "$NC" "$action_display"
            if [[ -n "$context" ]]; then
                printf "     ${DIM}%s${NC}\n" "$context"
            fi
        done <<< "$history"

        echo ""
        printf "${DIM}Showing last %d entries${NC}\n" "$entry_count"
    fi

    echo ""
    read -p "Press Enter to continue..."
    cursor_hide
}

# Interactive console TUI with category navigation
run_console() {
    # Build data
    build_feature_arrays

    if [[ ${#FEATURE_IDS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No features found in verification file${NC}"
        return 1
    fi

    local cat_idx=0      # Current category index
    local feat_idx=0     # Current feature index within category
    local preview_mode="false"  # Checklist preview mode

    cursor_hide
    trap 'cursor_show; clear_screen' EXIT

    while true; do
        local category="${CATEGORY_LIST[$cat_idx]}"
        local cat_count="${CATEGORY_COUNT[$category]}"
        local cat_start="${CATEGORY_START[$category]}"
        local global_idx=$((cat_start + feat_idx))

        draw_console "$cat_idx" "$feat_idx" "$preview_mode"

        # Read single keypress
        IFS= read -rsn1 key

        case "$key" in
            $'\x1b')  # Escape sequence
                read -rsn2 -t 0.1 key2
                case "$key2" in
                    '[A')  # Up arrow - previous feature in category
                        if [[ $feat_idx -gt 0 ]]; then
                            feat_idx=$((feat_idx - 1))
                        fi
                        ;;
                    '[B')  # Down arrow - next feature in category
                        if [[ $feat_idx -lt $((cat_count - 1)) ]]; then
                            feat_idx=$((feat_idx + 1))
                        fi
                        ;;
                    '[D')  # Left arrow - previous category
                        if [[ $cat_idx -gt 0 ]]; then
                            cat_idx=$((cat_idx - 1))
                            feat_idx=0
                        else
                            # Wrap to last category
                            cat_idx=$((${#CATEGORY_LIST[@]} - 1))
                            feat_idx=0
                        fi
                        ;;
                    '[C')  # Right arrow - next category
                        if [[ $cat_idx -lt $((${#CATEGORY_LIST[@]} - 1)) ]]; then
                            cat_idx=$((cat_idx + 1))
                            feat_idx=0
                        else
                            # Wrap to first category
                            cat_idx=0
                            feat_idx=0
                        fi
                        ;;
                esac
                ;;
            'q'|'Q')  # Quit
                cursor_show
                clear_screen
                echo "Exited verification console."
                return 0
                ;;
            'v'|'V')  # Verify current feature
                cursor_show
                clear_screen
                local feature="${FEATURE_IDS[$global_idx]}"
                echo -e "${BOLD}Verifying: ${FEATURE_NAMES[$global_idx]}${NC}"
                echo ""
                verify_feature "$feature" ""
                echo ""
                read -p "Press Enter to continue..."
                build_feature_arrays
                cursor_hide
                ;;
            'i'|'I')  # Edit checklist items
                cursor_show
                local feature="${FEATURE_IDS[$global_idx]}"
                edit_checklist_items "$feature" "${FEATURE_NAMES[$global_idx]}"
                build_feature_arrays  # Refresh data after editing
                cursor_hide
                ;;
            'u'|'U')  # Unverify current feature
                cursor_show
                clear_screen
                local feature="${FEATURE_IDS[$global_idx]}"
                echo -e "${BOLD}Unverifying: ${FEATURE_NAMES[$global_idx]}${NC}"
                echo ""
                unverify_feature "$feature"
                echo ""
                read -p "Press Enter to continue..."
                build_feature_arrays
                cursor_hide
                ;;
            'd'|'D'|'')  # Show details (d or Enter)
                cursor_show
                clear_screen
                local feature="${FEATURE_IDS[$global_idx]}"
                show_details "$feature"
                echo ""
                read -p "Press Enter to continue..."
                cursor_hide
                ;;
            'c'|'C')  # Check for invalidations
                cursor_show
                clear_screen
                check_invalidations
                echo ""
                read -p "Press Enter to continue..."
                build_feature_arrays
                cursor_hide
                ;;
            'n'|'N')  # Edit notes
                cursor_show
                local feature="${FEATURE_IDS[$global_idx]}"
                edit_feature_notes "$feature" "${FEATURE_NAMES[$global_idx]}"
                cursor_hide
                ;;
            'h'|'H')  # Show history
                cursor_show
                local feature="${FEATURE_IDS[$global_idx]}"
                show_history "$feature" "${FEATURE_NAMES[$global_idx]}"
                cursor_hide
                ;;
            'p'|'P')  # Toggle preview mode
                if [[ "$preview_mode" == "true" ]]; then
                    preview_mode="false"
                else
                    preview_mode="true"
                fi
                ;;
            'r'|'R')  # Refresh
                build_feature_arrays
                ;;
        esac
    done
}

# ============================================================================
# Machine Execution Mode (--run)
# These functions enable automated verification of checklist items
# ============================================================================

# Source the verify-runner library when needed
source_verify_runner() {
    local runner_lib="$PROJECT_ROOT/lib/verify-runner.sh"
    if [[ -f "$runner_lib" ]]; then
        source "$runner_lib"
        return 0
    else
        echo -e "${RED}Error:${NC} verify-runner.sh not found at $runner_lib"
        return 1
    fi
}

# Get all feature IDs that have machine-verifiable checks
get_machine_verifiable_features() {
    local depth="${1:-standard}"

    # For now, return all features - in v3 schema, filter by machine.automatable
    get_feature_ids
}

# Count total checklist items across all features
count_total_items() {
    local total=0
    while IFS= read -r feature; do
        local count=$(get_checklist_item_count "$feature")
        total=$((total + count))
    done <<< "$(get_feature_ids)"
    echo "$total"
}

# Count machine-verified items
# Parses checklist items looking for machine.state.verified: true
count_machine_verified_items() {
    # Count items where machine.state.verified is true in .verification.yml
    # The structure is: checklist item -> machine -> state -> verified: true
    # Indentation: machine (6 spaces), state (8 spaces), verified (10 spaces)
    local count=0
    count=$(awk '
    BEGIN { in_machine = 0; in_state = 0; count = 0 }
    /^      machine:/ { in_machine = 1; in_state = 0; next }
    in_machine && /^        state:/ { in_state = 1; next }
    in_machine && in_state && /^          verified: true/ { count++; in_machine = 0; in_state = 0; next }
    /^      [a-z]/ && !/^      machine:/ { in_machine = 0; in_state = 0 }
    /^    - text:/ { in_machine = 0; in_state = 0 }
    END { print count }
    ' "$VERIFICATION_FILE" 2>/dev/null)
    echo "${count:-0}"
}

# Count human-verified items
count_human_verified_items() {
    local total=0
    while IFS= read -r feature; do
        local completed=$(get_completed_checklist_item_count "$feature")
        total=$((total + completed))
    done <<< "$(get_feature_ids)"
    echo "$total"
}

# Count machine-verified items for a specific feature
# Usage: count_feature_machine_verified FEATURE_ID
count_feature_machine_verified() {
    local feature="$1"
    local count=0
    count=$(awk -v feat="$feature" '
    BEGIN { in_feature = 0; in_checklist = 0; in_machine = 0; in_state = 0; count = 0 }
    /^  [a-z_]+:$/ {
        gsub(/^  /, ""); gsub(/:$/, "")
        if ($0 == feat) { in_feature = 1 } else { in_feature = 0 }
        in_checklist = 0; in_machine = 0; in_state = 0
        next
    }
    in_feature && /^    checklist:/ { in_checklist = 1; next }
    in_feature && in_checklist && /^    - text:/ { in_machine = 0; in_state = 0; next }
    in_feature && in_checklist && /^      machine:/ { in_machine = 1; next }
    in_feature && in_checklist && in_machine && /^        state:/ { in_state = 1; next }
    in_feature && in_checklist && in_machine && in_state && /^          verified: true/ { count++; in_state = 0; next }
    END { print count }
    ' "$VERIFICATION_FILE" 2>/dev/null)
    echo "${count:-0}"
}

# Count total machine-checkable items for a specific feature
# Usage: count_feature_machine_checkable FEATURE_ID
count_feature_machine_checkable() {
    local feature="$1"
    local count=0
    count=$(awk -v feat="$feature" '
    BEGIN { in_feature = 0; in_checklist = 0; count = 0 }
    /^  [a-z_]+:$/ {
        gsub(/^  /, ""); gsub(/:$/, "")
        if ($0 == feat) { in_feature = 1 } else { in_feature = 0 }
        in_checklist = 0
        next
    }
    in_feature && /^    checklist:/ { in_checklist = 1; next }
    in_feature && in_checklist && /^      machine:/ { count++; next }
    END { print count }
    ' "$VERIFICATION_FILE" 2>/dev/null)
    echo "${count:-0}"
}

# Count fully verified items (both machine and human)
count_fully_verified_items() {
    # Count checklist items where BOTH machine.state.verified=true AND completed=true
    local count=0
    count=$(awk '
    BEGIN {
        in_item = 0
        machine_verified = 0
        human_completed = 0
        count = 0
    }
    /^    - text:/ {
        # New checklist item - check if previous was fully verified
        if (in_item && machine_verified && human_completed) {
            count++
        }
        in_item = 1
        machine_verified = 0
        human_completed = 0
        next
    }
    in_item && /^      completed: true/ {
        human_completed = 1
        next
    }
    in_item && /^          verified: true/ {
        machine_verified = 1
        next
    }
    END {
        # Check last item
        if (in_item && machine_verified && human_completed) {
            count++
        }
        print count
    }
    ' "$VERIFICATION_FILE" 2>/dev/null)
    echo "${count:-0}"
}

# Update machine verification state for a checklist item
# Usage: update_machine_verified FEATURE_ID ITEM_INDEX DEPTH [DURATION]
# This persists the machine test result to .verification.yml
update_machine_verified() {
    local feature="$1"
    local item_idx="$2"
    local depth="$3"
    local duration="${4:-0}"
    local timestamp=$(date -Iseconds)
    local tmpfile=$(mktemp)

    # Update machine.state for the specified checklist item
    # Structure: features -> feature -> checklist -> item[idx] -> machine -> state
    awk -v feature="$feature" -v idx="$item_idx" -v depth="$depth" \
        -v timestamp="$timestamp" -v duration="$duration" '
    BEGIN {
        in_feature = 0
        in_checklist = 0
        current_idx = -1
        in_target_item = 0
        in_machine = 0
        in_state = 0
        state_updated = 0
    }
    /^  [a-z0-9_]+:$/ {
        test = $0
        gsub(/^  /, "", test)
        gsub(/:$/, "", test)
        if (test == feature) {
            in_feature = 1
        } else if (in_feature) {
            in_feature = 0
            in_checklist = 0
            in_target_item = 0
        }
    }
    in_feature && /^    checklist:/ {
        in_checklist = 1
        print
        next
    }
    in_feature && in_checklist && /^    - text:/ {
        current_idx++
        if (current_idx == idx) {
            in_target_item = 1
        } else {
            in_target_item = 0
        }
        in_machine = 0
        in_state = 0
        print
        next
    }
    in_target_item && /^      machine:/ {
        in_machine = 1
        print
        next
    }
    in_target_item && in_machine && /^        state:/ {
        in_state = 1
        print
        next
    }
    in_target_item && in_machine && in_state && /^          verified:/ {
        print "          verified: true"
        state_updated = 1
        next
    }
    in_target_item && in_machine && in_state && /^          verified_at:/ {
        print "          verified_at: '\''" timestamp "'\''"
        next
    }
    in_target_item && in_machine && in_state && /^          depth:/ {
        print "          depth: " depth
        next
    }
    in_target_item && in_machine && in_state && /^          duration_seconds:/ {
        print "          duration_seconds: " duration
        next
    }
    # Exit state section on unindent
    in_state && /^        [a-z]/ && !/^          / {
        in_state = 0
    }
    in_machine && /^      [a-z]/ && !/^        / {
        in_machine = 0
        in_state = 0
    }
    { print }
    ' "$VERIFICATION_FILE" > "$tmpfile"

    mv "$tmpfile" "$VERIFICATION_FILE"
}

# Update statistics section in .verification.yml
# Usage: update_verification_statistics
update_verification_statistics() {
    local total=$(count_total_items)
    local machine_verified=$(count_machine_verified_items)
    local human_verified=$(count_human_verified_items)
    local fully_verified=$(count_fully_verified_items)

    local machine_pct=0
    local human_pct=0

    if [[ $total -gt 0 ]]; then
        # Calculate percentage with one decimal place
        machine_pct=$(awk "BEGIN {printf \"%.1f\", ($machine_verified * 100 / $total)}")
        human_pct=$(awk "BEGIN {printf \"%.1f\", ($human_verified * 100 / $total)}")
    fi

    local tmpfile=$(mktemp)

    awk -v total="$total" -v machine="$machine_verified" -v human="$human_verified" \
        -v fully="$fully_verified" -v mpct="$machine_pct" -v hpct="$human_pct" '
    BEGIN { in_statistics = 0; in_machine = 0; in_human = 0 }
    /^statistics:/ { in_statistics = 1; print; next }
    in_statistics && /^  total_items:/ { print "  total_items: " total; next }
    in_statistics && /^  machine:/ { in_machine = 1; in_human = 0; print; next }
    in_statistics && /^  human:/ { in_human = 1; in_machine = 0; print; next }
    in_statistics && /^  fully_verified:/ { print "  fully_verified: " fully; in_machine = 0; in_human = 0; next }
    in_statistics && in_machine && /^    verified:/ { print "    verified: " machine; next }
    in_statistics && in_machine && /^    coverage_percent:/ { print "    coverage_percent: " mpct; next }
    in_statistics && in_human && /^    verified:/ { print "    verified: " human; next }
    in_statistics && in_human && /^    coverage_percent:/ { print "    coverage_percent: " hpct; next }
    /^[a-z]/ && !/^statistics:/ { in_statistics = 0; in_machine = 0; in_human = 0 }
    { print }
    ' "$VERIFICATION_FILE" > "$tmpfile"

    mv "$tmpfile" "$VERIFICATION_FILE"
}

# Draw a progress bar for verification execution
# Usage: draw_progress_bar current total [width]
draw_progress_bar() {
    local current=$1
    local total=$2
    local width=${3:-40}

    if [[ $total -eq 0 ]]; then
        return
    fi

    local pct=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    # Build the bar
    local bar=""
    local j  # Use local variable to avoid clobbering outer loop variables
    for ((j=0; j<filled; j++)); do
        bar+="█"
    done
    for ((j=0; j<empty; j++)); do
        bar+="░"
    done

    # Print on single line with carriage return for updates
    printf "\r${DIM}Progress: [${NC}${GREEN}%s${NC}${DIM}%s${NC}${DIM}] %3d%% (%d/%d)${NC}" \
        "${bar:0:$filled}" "${bar:$filled}" "$pct" "$current" "$total"
}

# Clear progress bar line
clear_progress_bar() {
    printf "\r%-80s\r" ""
}

# Count total items with machine checks for progress tracking
count_total_machine_checkable_items() {
    local features="$1"
    local total=0

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local item_count=$(get_checklist_item_count "$f")
        total=$((total + item_count))
    done <<< "$features"

    echo "$total"
}

# Check if a checklist item has machine.checks at specified depth
# Usage: has_item_machine_checks feature_id item_index depth
has_item_machine_checks() {
    local feature_id="$1"
    local item_idx="$2"
    local depth="$3"

    # Use awk to check if machine.checks.{depth} exists for this item
    awk -v fid="$feature_id" -v idx="$item_idx" -v depth="$depth" '
    BEGIN {
        in_features = 0
        in_feature = 0
        in_checklist = 0
        item_count = 0
        in_machine = 0
        in_checks = 0
        found = 0
    }
    /^features:/ { in_features = 1; next }
    in_features && /^  [a-z_]+:$/ {
        gsub(/:$/, "", $1)
        gsub(/^  /, "", $1)
        if ($1 == fid) {
            in_feature = 1
        } else {
            in_feature = 0
        }
        in_checklist = 0
        item_count = 0
        next
    }
    in_feature && /^    checklist:/ { in_checklist = 1; item_count = 0; next }
    in_feature && in_checklist && /^    - / {
        if (item_count == idx) {
            in_machine = 0
            in_checks = 0
        }
        item_count++
        next
    }
    in_feature && in_checklist && item_count == idx + 1 {
        if (/^      machine:/) { in_machine = 1; next }
        if (in_machine && /^        checks:/) { in_checks = 1; next }
        if (in_checks && /^          '"$depth"':/) { found = 1; exit }
        if (/^      [a-z]/ && !/^      machine:/) { in_machine = 0; in_checks = 0 }
        if (/^    - /) { exit }
    }
    END { exit (found ? 0 : 1) }
    ' "$VERIFICATION_FILE"
}

# Get machine check commands for a checklist item at specified depth
# Usage: get_item_machine_commands feature_id item_index depth
# Returns commands one per line in format: cmd|expect_exit|timeout|expect_output
get_item_machine_commands() {
    local feature_id="$1"
    local item_idx="$2"
    local depth="$3"

    awk -v fid="$feature_id" -v idx="$item_idx" -v depth="$depth" '
    BEGIN {
        in_features = 0
        in_feature = 0
        in_checklist = 0
        item_count = 0
        in_machine = 0
        in_checks = 0
        in_depth = 0
        in_commands = 0
        cmd = ""
        expect_exit = "0"
        timeout = "60"
        expect_output = ""
    }
    /^features:/ { in_features = 1; next }
    in_features && /^  [a-z_]+:$/ {
        gsub(/:$/, "", $1)
        gsub(/^  /, "", $1)
        if ($1 == fid) {
            in_feature = 1
        } else {
            in_feature = 0
        }
        in_checklist = 0
        item_count = 0
        next
    }
    in_feature && /^    checklist:/ { in_checklist = 1; item_count = 0; next }
    in_feature && in_checklist && /^    - / {
        item_count++
        in_machine = 0
        in_checks = 0
        in_depth = 0
        in_commands = 0
        next
    }
    in_feature && in_checklist && item_count == idx + 1 {
        # Match machine: at 6 spaces (inside checklist item)
        if (/^      machine:/) { in_machine = 1; next }
        # Match checks: at 8 spaces
        if (in_machine && /^        checks:/) { in_checks = 1; next }
        # Match depth level (basic/standard/thorough/paranoid) at 10 spaces
        if (in_checks && $0 ~ "^          " depth ":") { in_depth = 1; next }
        # Match commands: at 12 spaces
        if (in_depth && /^            commands:/) { in_commands = 1; next }
        # Match - cmd: at 12 spaces
        if (in_depth && in_commands && /^            - cmd:/) {
            # Output previous command if exists (use tab as delimiter)
            if (cmd != "") {
                print cmd "\t" expect_exit "\t" timeout "\t" expect_output
            }
            # Parse new command - strip YAML prefix and outer double quotes only
            cmd = $0
            gsub(/^            - cmd: /, "", cmd)
            # Only strip matching outer quotes (double or single wrapping the whole command)
            if (cmd ~ /^".*"$/) {
                gsub(/^"/, "", cmd)
                gsub(/"$/, "", cmd)
            } else if (cmd ~ /^'\''.*'\''$/) {
                gsub(/^'\''/, "", cmd)
                gsub(/'\''$/, "", cmd)
            }
            expect_exit = "0"
            timeout = "60"
            expect_output = ""
            next
        }
        # Match expect_exit: at 14 spaces
        if (in_depth && in_commands && /^              expect_exit:/) {
            expect_exit = $2
            next
        }
        # Match timeout: at 14 spaces
        if (in_depth && in_commands && /^              timeout:/) {
            timeout = $2
            next
        }
        # Match expect_output at 14 spaces
        if (in_depth && in_commands && /^              expect_output/) {
            expect_output = $0
            gsub(/^              expect_output: /, "", expect_output)
            gsub(/^"/, "", expect_output)
            gsub(/"$/, "", expect_output)
            next
        }
        # End of depth section (another depth level at 10 spaces)
        if (in_depth && /^          [a-z]/ && $0 !~ "^            ") {
            if (cmd != "") {
                print cmd "\t" expect_exit "\t" timeout "\t" expect_output
            }
            exit
        }
        # End of machine section (another property at 6 spaces)
        if (in_machine && /^      [a-z]/ && !/^      machine:/) {
            if (cmd != "") {
                print cmd "\t" expect_exit "\t" timeout "\t" expect_output
            }
            exit
        }
        # End of item (new checklist item)
        if (/^    - /) {
            if (cmd != "") {
                print cmd "\t" expect_exit "\t" timeout "\t" expect_output
            }
            exit
        }
    }
    END {
        if (cmd != "") {
            print cmd "\t" expect_exit "\t" timeout "\t" expect_output
        }
    }
    ' "$VERIFICATION_FILE"
}

# Execute machine checks for a single item
# Usage: execute_item_machine_checks feature_id item_index depth test_site
# Returns: 0 on success, 1 on failure
execute_item_machine_checks() {
    local feature_id="$1"
    local item_idx="$2"
    local depth="$3"
    local test_site="$4"

    local commands
    commands=$(get_item_machine_commands "$feature_id" "$item_idx" "$depth")

    if [[ -z "$commands" ]]; then
        return 2  # No commands found
    fi

    local all_passed=true
    local start_time=$(date +%s)

    while IFS=$'\t' read -r cmd expect_exit timeout expect_output; do
        [[ -z "$cmd" ]] && continue

        # Replace {site} placeholder with test site
        cmd="${cmd//\{site\}/$test_site}"

        # Execute the command
        local output
        local exit_code

        # Run with timeout
        output=$(timeout "${timeout:-60}" bash -c "$cmd" 2>&1)
        exit_code=$?

        # Check exit code
        if [[ "$exit_code" != "$expect_exit" ]]; then
            verify_log "ERROR" "Command '$cmd' exited with $exit_code (expected $expect_exit)"
            all_passed=false
            break
        fi

        # Check output if expected
        if [[ -n "$expect_output" ]]; then
            if ! echo "$output" | grep -qE "$expect_output"; then
                verify_log "ERROR" "Output did not match expected pattern: $expect_output"
                all_passed=false
                break
            fi
        fi
    done <<< "$commands"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ "$all_passed" == true ]]; then
        return 0
    else
        return 1
    fi
}

################################################################################
# AI-Powered Deep Verification (P51)
################################################################################

# Run AI verification scenarios
# Usage: run_ai_verification [--dry-run] [--resume] [--fix] [--scenario=ID]
run_ai_verification() {
    # Source scenario library
    if [[ -f "$PROJECT_ROOT/lib/verify-scenarios.sh" ]]; then
        source "$PROJECT_ROOT/lib/verify-scenarios.sh"
    else
        echo -e "${RED}Error:${NC} AI verification library not found"
        echo "Expected: $PROJECT_ROOT/lib/verify-scenarios.sh"
        echo ""
        echo "P51 AI verification is not fully implemented yet."
        echo "Run 'pl verify --run' for machine verification (P50)."
        return 1
    fi

    # Check yq dependency
    if ! command -v yq &>/dev/null; then
        echo -e "${RED}Error:${NC} yq is required for AI verification"
        echo "Install with: pip install yq"
        return 1
    fi

    # Check if scenario directory exists
    if [[ ! -d "$PROJECT_ROOT/.verification-scenarios" ]]; then
        echo -e "${RED}Error:${NC} No verification scenarios found"
        echo "Expected: $PROJECT_ROOT/.verification-scenarios/"
        return 1
    fi

    # Parse arguments
    local dry_run=false
    local resume=false
    local auto_fix=false
    local scenario=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            --resume)
                resume=true
                shift
                ;;
            --fix)
                auto_fix=true
                shift
                ;;
            --scenario=*)
                scenario="${1#*=}"
                shift
                ;;
            *)
                echo "Unknown option: $1"
                echo "Usage: verify.sh --ai [--dry-run] [--resume] [--fix] [--scenario=ID]"
                return 1
                ;;
        esac
    done

    # Build arguments for scenario execution
    local args=()
    $dry_run && args+=("--dry-run")
    $resume && args+=("--resume")
    $auto_fix && args+=("--fix")

    # Execute specific scenario or all
    if [[ -n "$scenario" ]]; then
        echo ""
        echo "Running scenario: $scenario"
        scenario_execute "$scenario"
    else
        scenario_execute_all "${args[@]}"
    fi
}

################################################################################
# Machine Execution Mode (P50)
################################################################################

# Run machine checks for all or specified features
# Usage: run_machine_checks [--depth=LEVEL] [--feature=ID] [--all] [--affected] [--prefix=NAME]
run_machine_checks() {
    # Source runner library
    if ! source_verify_runner; then
        return 1
    fi

    # Parse arguments
    local depth="standard"
    local feature=""
    local run_all=false
    local run_affected=false
    local prefix="verify-test"
    local verbose=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --depth=*)
                depth="${1#*=}"
                shift
                ;;
            --feature=*)
                feature="${1#*=}"
                shift
                ;;
            --all)
                run_all=true
                shift
                ;;
            --affected)
                run_affected=true
                shift
                ;;
            --prefix=*)
                prefix="${1#*=}"
                shift
                ;;
            --verbose|-v)
                verbose=true
                shift
                ;;
            *)
                echo -e "${RED}Error:${NC} Unknown option: $1"
                echo "Usage: verify.sh --run [--depth=basic|standard|thorough|paranoid] [--feature=ID] [--all]"
                return 1
                ;;
        esac
    done

    # Validate depth
    case "$depth" in
        basic|standard|thorough|paranoid)
            ;;
        *)
            echo -e "${RED}Error:${NC} Invalid depth level: $depth"
            echo "Valid levels: basic, standard, thorough, paranoid"
            return 1
            ;;
    esac

    # Initialize logging
    init_verify_log

    echo -e "${BOLD}NWP Machine Verification${NC}"
    echo -e "${DIM}Depth level: $depth${NC}"
    echo ""

    # Determine which features to run
    local features_to_run=""
    if [[ -n "$feature" ]]; then
        # Single feature mode
        if ! get_feature_ids | grep -q "^${feature}$"; then
            echo -e "${RED}Error:${NC} Feature '$feature' not found"
            return 1
        fi
        features_to_run="$feature"
        echo -e "Testing feature: ${CYAN}$feature${NC}"
    elif [[ "$run_affected" == true ]]; then
        # Affected mode - features with changed files
        echo -e "Testing affected features..."
        while IFS= read -r f; do
            if check_feature_changed "$f" 2>/dev/null; then
                features_to_run+="$f"$'\n'
            fi
        done <<< "$(get_feature_ids)"
    else
        # All features
        features_to_run="$(get_machine_verifiable_features "$depth")"
        echo -e "Testing all features..."
    fi

    if [[ -z "$features_to_run" ]]; then
        echo -e "${YELLOW}No features to test${NC}"
        return 0
    fi

    # Count features and total items for progress tracking
    local feature_count=$(echo "$features_to_run" | grep -c '.')
    local total_items=$(count_total_machine_checkable_items "$features_to_run")
    local items_processed=0
    echo -e "Features to test: $feature_count (${total_items} items)"
    echo ""

    # Create test site if needed for commands that require it
    local test_site=""
    local needs_test_site=true  # In future, check if any commands need {site}

    if [[ "$needs_test_site" == true ]]; then
        echo -e "${BLUE}Creating test site...${NC}"
        VERIFY_TEST_PREFIX="$prefix"
        test_site=$(create_test_site "$prefix" "d" 2>/dev/null)
        if [[ -z "$test_site" ]]; then
            echo -e "${YELLOW}Warning:${NC} Could not create test site, some checks may be skipped"
        else
            echo -e "${GREEN}Test site created:${NC} $test_site"
        fi
        echo ""
    fi

    # Run checks for each feature
    local total_passed=0
    local total_failed=0
    local total_skipped=0

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue

        local fname=$(get_yaml_value "$f" "name")
        echo -e "${CYAN}[$f]${NC} $fname"

        # Get checklist item count
        local item_count=$(get_checklist_item_count "$f")

        if [[ $item_count -eq 0 ]]; then
            echo -e "  ${DIM}No checklist items${NC}"
            continue
        fi

        # For each checklist item, check if machine checks exist and run them
        local item_passed=0
        local item_failed=0
        local item_skipped=0

        for ((i=0; i<item_count; i++)); do
            # Get item text for display
            local -a items=()
            local -a completed=()
            get_checklist_items_array "$f" items completed
            local item_text="${items[$i]:-Item $i}"

            # Truncate item text for display
            if [[ ${#item_text} -gt 60 ]]; then
                item_text="${item_text:0:57}..."
            fi

            # Check if this item has machine checks at the specified depth
            if ! has_item_machine_checks "$f" "$i" "$depth"; then
                if [[ "$verbose" == true ]]; then
                    echo -e "  ${DIM}[skip]${NC} $item_text (no machine checks for $depth)"
                fi
                item_skipped=$((item_skipped + 1))
                total_skipped=$((total_skipped + 1))
                items_processed=$((items_processed + 1))
                draw_progress_bar "$items_processed" "$total_items"
                continue
            fi

            # Execute the actual machine checks from YAML
            local check_result
            local start_time=$(date +%s)

            if execute_item_machine_checks "$f" "$i" "$depth" "$test_site"; then
                check_result="pass"
                echo -e "  ${GREEN}[pass]${NC} $item_text"
                item_passed=$((item_passed + 1))
                total_passed=$((total_passed + 1))

                # Track result in memory
                track_result "$f" "$i" "passed" "0" ""

                # Persist machine verification to YAML
                local end_time=$(date +%s)
                local duration=$((end_time - start_time))
                update_machine_verified "$f" "$i" "$depth" "$duration"
            else
                check_result="fail"
                echo -e "  ${RED}[FAIL]${NC} $item_text"
                item_failed=$((item_failed + 1))
                total_failed=$((total_failed + 1))

                # Track failure
                track_result "$f" "$i" "failed" "0" "Command check failed"
            fi

            # Update progress
            items_processed=$((items_processed + 1))
            draw_progress_bar "$items_processed" "$total_items"
        done

        # Clear progress bar before showing feature results
        clear_progress_bar
        echo -e "  ${DIM}Results: $item_passed passed, $item_failed failed, $item_skipped skipped${NC}"
        echo ""
    done <<< "$features_to_run"

    # Final progress bar clear
    clear_progress_bar

    # Update statistics in .verification.yml
    update_verification_statistics

    # Cleanup test site
    if [[ -n "$test_site" ]]; then
        if [[ $total_failed -eq 0 ]] && [[ "$VERIFY_CLEANUP_ON_SUCCESS" == true ]]; then
            echo -e "${BLUE}Cleaning up test site...${NC}"
            cleanup_test_site "$test_site" "false"
        else
            echo -e "${YELLOW}Preserving test site for debugging:${NC} sites/$test_site"
        fi
    fi

    # Print summary
    print_verify_summary

    # Return non-zero if any failures
    if [[ $total_failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# CI mode - run checks and generate reports
# Usage: run_ci_mode [--depth=LEVEL] [--export-json] [--junit]
run_ci_mode() {
    # Source runner library
    if ! source_verify_runner; then
        return 1
    fi

    # Parse arguments
    local depth="standard"
    local export_json=false
    local junit_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --depth=*)
                depth="${1#*=}"
                shift
                ;;
            --export-json)
                export_json=true
                shift
                ;;
            --junit)
                junit_output=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    echo -e "${BOLD}NWP Verification CI Mode${NC}"
    echo -e "${DIM}Depth: $depth${NC}"
    echo ""

    # Initialize logging
    init_verify_log

    # Run all machine checks
    run_machine_checks --depth="$depth" --all

    local exit_code=$?

    # Export results
    if [[ "$export_json" == true ]]; then
        echo ""
        echo -e "${BLUE}Generating .badges.json...${NC}"

        local total=$(count_total_items)
        local machine_verified=$(count_machine_verified_items)
        local human_verified=$(count_human_verified_items)
        local fully_verified=$(count_fully_verified_items)

        local machine_pct=0
        local human_pct=0
        local full_pct=0

        if [[ $total -gt 0 ]]; then
            machine_pct=$((machine_verified * 100 / total))
            human_pct=$((human_verified * 100 / total))
            full_pct=$((fully_verified * 100 / total))
        fi

        generate_badges_json "$PROJECT_ROOT/.badges.json" "$machine_pct" "$human_pct" "$full_pct" "0"
        echo -e "${GREEN}Generated:${NC} .badges.json"
    fi

    if [[ "$junit_output" == true ]]; then
        echo ""
        echo -e "${BLUE}Generating JUnit XML...${NC}"
        local junit_file=$(generate_junit_xml)
        echo -e "${GREEN}Generated:${NC} $junit_file"
    fi

    # Check pass rate threshold
    local pass_rate=$(get_pass_rate)
    echo ""
    if [[ $pass_rate -lt 98 ]]; then
        echo -e "${RED}FAIL:${NC} Pass rate ${pass_rate}% below 98% threshold"
        return 1
    else
        echo -e "${GREEN}PASS:${NC} ${pass_rate}% pass rate"
    fi

    return $exit_code
}

# Generate badge information
# Usage: generate_badges [--update-readme]
generate_badges() {
    # Source runner library
    if ! source_verify_runner; then
        return 1
    fi

    local update_readme=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --update-readme)
                update_readme=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    echo -e "${BOLD}NWP Verification Badges${NC}"
    echo ""

    # Calculate coverage
    local total=$(count_total_items)
    local machine_verified=$(count_machine_verified_items)
    local human_verified=$(count_human_verified_items)
    local fully_verified=$(count_fully_verified_items)

    local machine_pct=0
    local human_pct=0
    local full_pct=0

    if [[ $total -gt 0 ]]; then
        machine_pct=$((machine_verified * 100 / total))
        human_pct=$((human_verified * 100 / total))
        full_pct=$((fully_verified * 100 / total))
    fi

    echo "Coverage Statistics:"
    echo "  Total items:      $total"
    echo "  Machine verified: $machine_verified ($machine_pct%)"
    echo "  Human verified:   $human_verified ($human_pct%)"
    echo "  Fully verified:   $fully_verified ($full_pct%)"
    echo ""

    # Generate .badges.json (don't need logging for this simple operation)
    echo -e "${BLUE}Generating .badges.json...${NC}"
    local badge_file="$PROJECT_ROOT/.badges.json"
    local machine_color=$(get_badge_color "$machine_pct" "machine")
    local human_color=$(get_badge_color "$human_pct" "human")
    local full_color=$(get_badge_color "$full_pct" "full")

    cat > "$badge_file" << EOF
{
  "version": 1,
  "schemaVersion": 1,
  "generated": "$(date -Iseconds)",
  "pipeline": {
    "id": "${CI_PIPELINE_ID:-local}",
    "ref": "${CI_COMMIT_REF_NAME:-$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "unknown")}",
    "sha": "${CI_COMMIT_SHA:-$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")}"
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
      "message": "0 open",
      "color": "brightgreen"
    }
  }
}
EOF

    echo -e "${GREEN}Generated:${NC} $badge_file"
    echo ""

    # Print badge URLs
    local base_url="https://raw.githubusercontent.com/rjzaar/nwp/main/.badges.json"
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

    if [[ "$update_readme" == true ]]; then
        echo ""
        echo -e "${YELLOW}Note:${NC} --update-readme flag detected but not yet implemented"
        echo "Manually add badge URLs to README.md"
    fi
}

# Generate verification report
generate_verification_report() {
    local output_file="${1:-docs/VERIFICATION_REPORT.md}"
    local total_items=$(count_total_items)
    local machine_verified=$(count_machine_verified_items)
    local human_verified=$(count_human_verified_items)
    local fully_verified=$(count_fully_verified_items)
    local timestamp=$(date -Iseconds)

    mkdir -p "$(dirname "$output_file")"

    cat > "$output_file" << EOF
# NWP Verification Report

**Generated:** $timestamp
**Version:** $(grep "NWP_VERSION=" pl | cut -d'"' -f2)

## Summary

| Metric | Count | Percentage |
|--------|-------|------------|
| Total Items | $total_items | 100% |
| Machine Verified | $machine_verified | $((machine_verified * 100 / total_items))% |
| Human Verified | $human_verified | $((human_verified * 100 / total_items))% |
| Fully Verified | $fully_verified | $((fully_verified * 100 / total_items))% |

## Coverage by Feature

EOF

    # Add per-feature breakdown
    while IFS= read -r feature; do
        local name=$(get_yaml_value "$feature" "name")
        local total=$(get_checklist_item_count "$feature")
        local machine=$(count_feature_machine_verified "$feature" 2>/dev/null || echo "0")
        local checkable=$(count_feature_machine_checkable "$feature" 2>/dev/null || echo "0")

        if [[ $total -gt 0 ]]; then
            echo "### $name ($feature)" >> "$output_file"
            echo "" >> "$output_file"
            echo "- Total items: $total" >> "$output_file"
            if [[ $checkable -gt 0 ]]; then
                echo "- Machine verified: $machine/$checkable" >> "$output_file"
            fi
            echo "" >> "$output_file"
        fi
    done <<< "$(get_feature_ids)"

    echo "" >> "$output_file"
    echo "---" >> "$output_file"
    echo "*Report generated by \`pl verify report\`*" >> "$output_file"

    echo "Generated: $output_file"
}

# Main
main() {
    local command="${1:-console}"

    if [[ ! -f "$VERIFICATION_FILE" ]]; then
        echo -e "${RED}Error:${NC} Verification file not found: $VERIFICATION_FILE"
        exit 1
    fi

    case "$command" in
        console|tui)
            run_console
            ;;
        report|status)
            show_status
            ;;
        check)
            check_invalidations
            ;;
        details)
            if [[ -z "${2:-}" ]]; then
                echo "Usage: ./verify.sh details <feature_id>"
                echo ""
                echo "Shows what changed and what needs to be verified."
                exit 1
            fi
            show_details "$2"
            ;;
        verify)
            if [[ -n "${2:-}" ]]; then
                verify_feature "$2" "${3:-}"
            else
                interactive_verify
            fi
            ;;
        unverify)
            if [[ -z "${2:-}" ]]; then
                echo "Usage: ./verify.sh unverify <feature_id>"
                exit 1
            fi
            unverify_feature "$2"
            ;;
        list)
            list_features
            ;;
        summary)
            show_summary
            ;;
        reset)
            reset_all
            ;;
        --run|run)
            shift
            run_machine_checks "$@"
            ;;
        --ai|ai)
            shift
            run_ai_verification "$@"
            ;;
        ci)
            shift
            run_ci_mode "$@"
            ;;
        badges)
            shift
            generate_badges "$@"
            ;;
        report)
            shift
            generate_verification_report "$@"
            ;;
        help|--help|-h)
            echo "Usage: ./verify.sh [command] [args]"
            echo ""
            echo "Human verification (TUI):"
            echo "  (default)     Interactive TUI console (navigate, verify, view details)"
            echo "  report        Show verification status report"
            echo "  check         Check for invalidated verifications"
            echo "  details <id>  Show what changed and verification checklist"
            echo "  verify        Interactive verification mode"
            echo "  verify <id>   Mark a specific feature as verified"
            echo "  unverify <id> Mark a specific feature as unverified"
            echo "  list          List all feature IDs"
            echo "  summary       Show summary statistics"
            echo "  reset         Reset all verifications"
            echo ""
            echo "Machine execution (replaces test-nwp.sh):"
            echo "  --run                    Run all machine-verifiable items"
            echo "  --run --depth=basic      Quick check (5-10s/item)"
            echo "  --run --depth=standard   Standard checks (default)"
            echo "  --run --depth=thorough   Full checks with state verification"
            echo "  --run --depth=paranoid   Full integration test"
            echo "  --run --feature=backup   Test specific feature"
            echo "  --run --affected         Only test features with changed files"
            echo "  --run --prefix=NAME      Custom test site prefix (default: verify-test)"
            echo ""
            echo "AI-powered deep verification (P51):"
            echo "  --ai                     Run AI verification scenarios (S1-S17)"
            echo "  --ai --dry-run           Show scenario order without executing"
            echo "  --ai --resume            Resume from checkpoint"
            echo "  --ai --fix               Enable auto-fix for errors"
            echo "  --ai --scenario=S1       Run specific scenario only"
            echo ""
            echo "CI/CD mode:"
            echo "  ci                       Machine checks with JUnit output"
            echo "  ci --export-json         Generate .badges.json"
            echo "  ci --depth=LEVEL         Specify depth level"
            echo "  ci --junit               Generate JUnit XML report"
            echo ""
            echo "Badges:"
            echo "  badges                   Generate badge URLs and .badges.json"
            echo "  badges --update-readme   Update README.md with badges"
            echo ""
            echo "Reports:"
            echo "  report                   Generate verification report (docs/VERIFICATION_REPORT.md)"
            echo "  report <path>            Generate report at specified path"
            echo ""
            echo "  help          Show this help message"
            echo ""
            echo "Depth levels:"
            echo "  basic     - Command exits 0 (5-10s/item)"
            echo "  standard  - Output valid, files created (10-20s/item)"
            echo "  thorough  - State verified, dependencies OK (20-40s/item)"
            echo "  paranoid  - Round-trip test, full integration (1-5min/item)"
            echo ""
            echo "When a verification is invalidated due to code changes:"
            echo "  1. Run './verify.sh details <id>' to see what changed"
            echo "  2. Review the verification checklist"
            echo "  3. Test the feature manually"
            echo "  4. Run './verify.sh verify <id>' to re-verify"
            ;;
        *)
            echo "Unknown command: $command"
            echo "Use './verify.sh help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
