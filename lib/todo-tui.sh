#!/bin/bash
################################################################################
# NWP Todo TUI Library
#
# Interactive TUI interface for the todo command
# See docs/proposals/F12-todo-command.md for specification
################################################################################

# Get the directory where this script is located
TODO_TUI_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TODO_TUI_PROJECT_ROOT="${TODO_TUI_PROJECT_ROOT:-$( cd "$TODO_TUI_DIR/.." && pwd )}"

# Source UI library for colors
if [ -f "$TODO_TUI_DIR/ui.sh" ]; then
    source "$TODO_TUI_DIR/ui.sh"
fi

# TUI State
TODO_TUI_ITEMS=()
TODO_TUI_SELECTED=()
TODO_TUI_FILTERED=()
TODO_TUI_CURRENT_ROW=0
TODO_TUI_FILTER_PRIORITY="all"
TODO_TUI_SORT_MODE="priority"

################################################################################
# Terminal Control Functions
################################################################################

tui_cursor_hide() { printf "\033[?25l"; }
tui_cursor_show() { printf "\033[?25h"; }
tui_clear_screen() { printf "\033[2J\033[H"; }
tui_clear_line() { printf "\033[2K"; }
tui_move_to() { printf "\033[%d;%dH" "$1" "$2"; }

# Read a single key from the terminal
tui_read_key() {
    local key
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.1 rest
        case "$rest" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            *) echo "ESC" ;;
        esac
    elif [[ $key == $'\t' ]]; then
        echo "TAB"
    elif [[ $key == "" ]]; then
        echo "ENTER"
    elif [[ $key == " " ]]; then
        echo "SPACE"
    else
        echo "$key"
    fi
}

################################################################################
# Data Loading
################################################################################

# Load todo items from JSON
tui_load_items() {
    local json_data="$1"

    TODO_TUI_ITEMS=()
    TODO_TUI_SELECTED=()

    # Parse JSON data
    while IFS= read -r line; do
        [[ "$line" == "["* ]] || [[ "$line" == "]"* ]] || [[ -z "$line" ]] && continue
        [[ "$line" != *"\"id\":"* ]] && continue

        TODO_TUI_ITEMS+=("$line")
        TODO_TUI_SELECTED+=("0")
    done <<< "$json_data"
}

# Get field from item JSON
tui_get_field() {
    local item="$1"
    local field="$2"
    echo "$item" | grep -o "\"$field\":\"[^\"]*\"" | cut -d'"' -f4
}

# Apply filters and sorting
tui_apply_filters() {
    TODO_TUI_FILTERED=()

    # Build filtered list
    for i in "${!TODO_TUI_ITEMS[@]}"; do
        local item="${TODO_TUI_ITEMS[$i]}"
        local priority=$(tui_get_field "$item" "priority")
        local include=true

        # Filter by priority
        if [ "$TODO_TUI_FILTER_PRIORITY" != "all" ] && [ "$priority" != "$TODO_TUI_FILTER_PRIORITY" ]; then
            include=false
        fi

        [ "$include" = true ] && TODO_TUI_FILTERED+=("$i")
    done

    # Sort by priority (high first)
    if [ "$TODO_TUI_SORT_MODE" = "priority" ]; then
        local -a high_items=() medium_items=() low_items=()
        for idx in "${TODO_TUI_FILTERED[@]}"; do
            local priority=$(tui_get_field "${TODO_TUI_ITEMS[$idx]}" "priority")
            case "$priority" in
                high) high_items+=("$idx") ;;
                medium) medium_items+=("$idx") ;;
                low) low_items+=("$idx") ;;
            esac
        done
        TODO_TUI_FILTERED=("${high_items[@]}" "${medium_items[@]}" "${low_items[@]}")
    fi
}

################################################################################
# Drawing Functions
################################################################################

# Draw the main screen
tui_draw_screen() {
    local term_height=$(tput lines 2>/dev/null || echo 24)
    local term_width=$(tput cols 2>/dev/null || echo 80)

    tui_clear_screen

    # Header
    printf "${BOLD}┌─ NWP Todo List ──────────────────────────────────────────────────┐${NC}\n"
    printf "│                                                                   │\n"

    # Filter bar
    printf "│  Filter: "
    if [ "$TODO_TUI_FILTER_PRIORITY" = "all" ]; then
        printf "${CYAN}[All]${NC} "
    else
        printf "[All] "
    fi
    if [ "$TODO_TUI_FILTER_PRIORITY" = "high" ]; then
        printf "${RED}[High]${NC} "
    else
        printf "[High] "
    fi
    if [ "$TODO_TUI_FILTER_PRIORITY" = "medium" ]; then
        printf "${YELLOW}[Medium]${NC} "
    else
        printf "[Medium] "
    fi
    if [ "$TODO_TUI_FILTER_PRIORITY" = "low" ]; then
        printf "[Low] "
    else
        printf "[Low] "
    fi
    printf "    Sort: "
    if [ "$TODO_TUI_SORT_MODE" = "priority" ]; then
        printf "${CYAN}[Priority]${NC}"
    else
        printf "[Priority]"
    fi
    printf "    │\n"
    printf "│                                                                   │\n"

    # Count items by priority
    local high_count=0 medium_count=0 low_count=0
    for idx in "${TODO_TUI_FILTERED[@]}"; do
        local priority=$(tui_get_field "${TODO_TUI_ITEMS[$idx]}" "priority")
        case "$priority" in
            high) ((high_count++)) ;;
            medium) ((medium_count++)) ;;
            low) ((low_count++)) ;;
        esac
    done

    # Calculate available rows for items
    local header_rows=8
    local footer_rows=5
    local available_rows=$((term_height - header_rows - footer_rows))
    [ "$available_rows" -lt 5 ] && available_rows=5

    # Draw items by priority section
    local row=0
    local current_section=""

    for idx in "${TODO_TUI_FILTERED[@]}"; do
        [ "$row" -ge "$available_rows" ] && break

        local item="${TODO_TUI_ITEMS[$idx]}"
        local id=$(tui_get_field "$item" "id")
        local title=$(tui_get_field "$item" "title")
        local priority=$(tui_get_field "$item" "priority")
        local selected="${TODO_TUI_SELECTED[$idx]}"

        # Section header
        if [ "$priority" != "$current_section" ]; then
            current_section="$priority"
            case "$priority" in
                high)
                    printf "│  ${RED}${BOLD}─ HIGH PRIORITY ─────────────────────────────────────────────${NC}  │\n"
                    ;;
                medium)
                    printf "│  ${YELLOW}${BOLD}─ MEDIUM PRIORITY ───────────────────────────────────────────${NC}  │\n"
                    ;;
                low)
                    printf "│  ${DIM}${BOLD}─ LOW PRIORITY ──────────────────────────────────────────────${NC}  │\n"
                    ;;
            esac
            ((row++))
            [ "$row" -ge "$available_rows" ] && break
        fi

        # Item row
        local is_current=false
        [ "$row" -eq "$TODO_TUI_CURRENT_ROW" ] && is_current=true

        # Checkbox
        local checkbox="[ ]"
        [ "$selected" = "1" ] && checkbox="[${GREEN}✓${NC}]"

        # Highlight current row
        local prefix="  "
        local color=""
        if [ "$is_current" = true ]; then
            prefix="${CYAN}>${NC} "
            color="${BOLD}"
        fi

        # Priority color
        local priority_color=""
        case "$priority" in
            high) priority_color="${RED}" ;;
            medium) priority_color="${YELLOW}" ;;
            low) priority_color="${DIM}" ;;
        esac

        # Truncate title if needed
        local max_title_len=$((term_width - 30))
        [ ${#title} -gt $max_title_len ] && title="${title:0:$max_title_len}..."

        printf "│%s$checkbox ${priority_color}%-8s${NC} ${color}%s${NC}" "$prefix" "$id" "$title"

        # Pad to border
        local line_len=$((${#prefix} + 4 + 9 + ${#title}))
        local padding=$((term_width - line_len - 5))
        [ "$padding" -gt 0 ] && printf "%*s" "$padding" ""
        printf "│\n"

        ((row++))
    done

    # Fill remaining space
    while [ "$row" -lt "$available_rows" ]; do
        printf "│%-$((term_width-4))s│\n" ""
        ((row++))
    done

    # Footer
    printf "├───────────────────────────────────────────────────────────────────┤\n"
    printf "│ ${BOLD}[Enter]${NC} Details  ${BOLD}[Space]${NC} Select  ${BOLD}[r]${NC} Resolve  ${BOLD}[i]${NC} Ignore    │\n"
    printf "│ ${BOLD}[a]${NC} Select All   ${BOLD}[f]${NC} Filter   ${BOLD}[R]${NC} Refresh  ${BOLD}[q]${NC} Quit       │\n"
    printf "└───────────────────────────────────────────────────────────────────┘\n"

    # Summary
    local total=${#TODO_TUI_FILTERED[@]}
    printf "\nSummary: ${BOLD}$total items${NC} (${RED}$high_count high${NC}, ${YELLOW}$medium_count medium${NC}, $low_count low)"
}

# Show item details
tui_show_details() {
    local idx="${TODO_TUI_FILTERED[$TODO_TUI_CURRENT_ROW]}"
    local item="${TODO_TUI_ITEMS[$idx]}"

    local id=$(tui_get_field "$item" "id")
    local title=$(tui_get_field "$item" "title")
    local description=$(tui_get_field "$item" "description")
    local priority=$(tui_get_field "$item" "priority")
    local site=$(tui_get_field "$item" "site")
    local action=$(tui_get_field "$item" "action")

    tui_clear_screen

    echo ""
    echo -e "${BOLD}Todo Item Details${NC}"
    echo -e "════════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "  ${BOLD}ID:${NC}          $id"
    echo -e "  ${BOLD}Title:${NC}       $title"
    echo -e "  ${BOLD}Priority:${NC}    $priority"
    [ -n "$site" ] && echo -e "  ${BOLD}Site:${NC}        $site"
    echo ""
    echo -e "  ${BOLD}Description:${NC}"
    echo -e "    $description"
    echo ""
    [ -n "$action" ] && echo -e "  ${BOLD}Suggested Action:${NC}"
    [ -n "$action" ] && echo -e "    ${CYAN}$action${NC}"
    echo ""
    echo -e "════════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "Press ${BOLD}[r]${NC} to resolve, ${BOLD}[i]${NC} to ignore, or any key to go back"

    local key=$(tui_read_key)
    case "$key" in
        r|R)
            tui_cursor_show
            echo ""
            echo -n "Mark as resolved? [y/N] "
            read -r confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                add_to_ignored "$id" "Manually resolved"
            fi
            tui_cursor_hide
            ;;
        i|I)
            tui_cursor_show
            echo ""
            echo -n "Ignore this item? [y/N] "
            read -r confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo -n "Reason (optional): "
                read -r reason
                add_to_ignored "$id" "${reason:-Manual ignore}"
            fi
            tui_cursor_hide
            ;;
    esac
}

# Cycle through filter options
tui_cycle_filter() {
    case "$TODO_TUI_FILTER_PRIORITY" in
        all) TODO_TUI_FILTER_PRIORITY="high" ;;
        high) TODO_TUI_FILTER_PRIORITY="medium" ;;
        medium) TODO_TUI_FILTER_PRIORITY="low" ;;
        low) TODO_TUI_FILTER_PRIORITY="all" ;;
    esac
    tui_apply_filters
    TODO_TUI_CURRENT_ROW=0
}

################################################################################
# Main TUI Loop
################################################################################

todo_tui_main() {
    # Ensure we have check functions
    if ! command -v run_all_checks &>/dev/null; then
        print_error "todo-checks.sh not loaded"
        return 1
    fi

    # Load items
    local json_data
    json_data=$(run_all_checks)
    tui_load_items "$json_data"
    tui_apply_filters

    if [ ${#TODO_TUI_FILTERED[@]} -eq 0 ]; then
        echo ""
        print_status "OK" "No todo items found"
        echo ""
        return 0
    fi

    # Setup terminal
    tui_cursor_hide
    trap 'tui_cursor_show; tui_clear_screen' EXIT

    # Initial draw
    tui_draw_screen

    local num_items=${#TODO_TUI_FILTERED[@]}

    while true; do
        local key=$(tui_read_key)

        case "$key" in
            UP|k)
                TODO_TUI_CURRENT_ROW=$(( (TODO_TUI_CURRENT_ROW - 1 + num_items) % num_items ))
                ;;
            DOWN|j)
                TODO_TUI_CURRENT_ROW=$(( (TODO_TUI_CURRENT_ROW + 1) % num_items ))
                ;;
            SPACE)
                local idx="${TODO_TUI_FILTERED[$TODO_TUI_CURRENT_ROW]}"
                if [ "${TODO_TUI_SELECTED[$idx]}" = "0" ]; then
                    TODO_TUI_SELECTED[$idx]="1"
                else
                    TODO_TUI_SELECTED[$idx]="0"
                fi
                ;;
            ENTER)
                tui_show_details
                # Reload data in case item was resolved
                json_data=$(run_all_checks)
                tui_load_items "$json_data"
                tui_apply_filters
                num_items=${#TODO_TUI_FILTERED[@]}
                [ "$TODO_TUI_CURRENT_ROW" -ge "$num_items" ] && TODO_TUI_CURRENT_ROW=$((num_items - 1))
                [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                ;;
            a|A)
                for idx in "${TODO_TUI_FILTERED[@]}"; do
                    TODO_TUI_SELECTED[$idx]="1"
                done
                ;;
            n|N)
                for idx in "${TODO_TUI_FILTERED[@]}"; do
                    TODO_TUI_SELECTED[$idx]="0"
                done
                ;;
            f|F)
                tui_cycle_filter
                num_items=${#TODO_TUI_FILTERED[@]}
                ;;
            r)
                # Resolve selected items
                local resolved=0
                for idx in "${TODO_TUI_FILTERED[@]}"; do
                    if [ "${TODO_TUI_SELECTED[$idx]}" = "1" ]; then
                        local id=$(tui_get_field "${TODO_TUI_ITEMS[$idx]}" "id")
                        add_to_ignored "$id" "Manually resolved" 2>/dev/null
                        ((resolved++))
                    fi
                done
                if [ "$resolved" -gt 0 ]; then
                    # Reload data
                    json_data=$(run_all_checks)
                    tui_load_items "$json_data"
                    tui_apply_filters
                    num_items=${#TODO_TUI_FILTERED[@]}
                    [ "$TODO_TUI_CURRENT_ROW" -ge "$num_items" ] && TODO_TUI_CURRENT_ROW=$((num_items - 1))
                    [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                fi
                ;;
            i|I)
                # Ignore selected items
                local ignored=0
                for idx in "${TODO_TUI_FILTERED[@]}"; do
                    if [ "${TODO_TUI_SELECTED[$idx]}" = "1" ]; then
                        local id=$(tui_get_field "${TODO_TUI_ITEMS[$idx]}" "id")
                        add_to_ignored "$id" "Bulk ignore" 2>/dev/null
                        ((ignored++))
                    fi
                done
                if [ "$ignored" -gt 0 ]; then
                    json_data=$(run_all_checks)
                    tui_load_items "$json_data"
                    tui_apply_filters
                    num_items=${#TODO_TUI_FILTERED[@]}
                    [ "$TODO_TUI_CURRENT_ROW" -ge "$num_items" ] && TODO_TUI_CURRENT_ROW=$((num_items - 1))
                    [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                fi
                ;;
            R)
                # Refresh data
                todo_cache_clear 2>/dev/null || true
                json_data=$(run_all_checks "true")
                tui_load_items "$json_data"
                tui_apply_filters
                num_items=${#TODO_TUI_FILTERED[@]}
                ;;
            q|Q|ESC)
                break
                ;;
        esac

        # Check if we still have items
        if [ "$num_items" -eq 0 ]; then
            tui_cursor_show
            tui_clear_screen
            print_status "OK" "All todo items handled"
            break
        fi

        tui_draw_screen
    done

    tui_cursor_show
    tui_clear_screen
}

# Export functions
export -f tui_cursor_hide
export -f tui_cursor_show
export -f tui_clear_screen
export -f tui_read_key
export -f tui_load_items
export -f tui_get_field
export -f tui_apply_filters
export -f tui_draw_screen
export -f tui_show_details
export -f tui_cycle_filter
export -f todo_tui_main
