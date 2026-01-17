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
TODO_TUI_CURRENT_TAB=0
TODO_TUI_ITEMS_PER_TAB=14
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
            '[5') echo "PGUP" ;;   # Page Up
            '[6') echo "PGDN" ;;   # Page Down
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

    # Reset to first tab when filters change
    TODO_TUI_CURRENT_TAB=0
    TODO_TUI_CURRENT_ROW=0
}

################################################################################
# Pagination Functions
################################################################################

# Get total number of tabs
tui_get_total_tabs() {
    local total=${#TODO_TUI_FILTERED[@]}
    local tabs=$(( (total + TODO_TUI_ITEMS_PER_TAB - 1) / TODO_TUI_ITEMS_PER_TAB ))
    [ "$tabs" -lt 1 ] && tabs=1
    echo "$tabs"
}

# Get start index for current tab
tui_get_tab_start() {
    echo $((TODO_TUI_CURRENT_TAB * TODO_TUI_ITEMS_PER_TAB))
}

# Get end index for current tab (exclusive)
tui_get_tab_end() {
    local start=$(tui_get_tab_start)
    local end=$((start + TODO_TUI_ITEMS_PER_TAB))
    local total=${#TODO_TUI_FILTERED[@]}
    [ "$end" -gt "$total" ] && end=$total
    echo "$end"
}

# Get items count on current tab
tui_get_tab_item_count() {
    local start=$(tui_get_tab_start)
    local end=$(tui_get_tab_end)
    echo $((end - start))
}

# Convert global row index to tab-relative row
tui_global_to_tab_row() {
    local global_row="$1"
    local start=$(tui_get_tab_start)
    echo $((global_row - start))
}

# Convert tab-relative row to global index
tui_tab_to_global_row() {
    local tab_row="$1"
    local start=$(tui_get_tab_start)
    echo $((start + tab_row))
}

################################################################################
# Drawing Functions
################################################################################

# Draw the main screen
tui_draw_screen() {
    local term_width=$(tput cols 2>/dev/null || echo 80)
    local box_width=69
    [ "$term_width" -lt "$box_width" ] && box_width=$((term_width - 2))

    tui_clear_screen

    # Calculate tab info
    local total_tabs=$(tui_get_total_tabs)
    local tab_start=$(tui_get_tab_start)
    local tab_end=$(tui_get_tab_end)
    local tab_items=$((tab_end - tab_start))

    # Header
    printf "${BOLD}┌─ NWP Todo List "
    # Tab indicator
    if [ "$total_tabs" -gt 1 ]; then
        printf "─── Tab %d/%d " "$((TODO_TUI_CURRENT_TAB + 1))" "$total_tabs"
    fi
    # Fill rest of header
    local header_used=17
    [ "$total_tabs" -gt 1 ] && header_used=$((header_used + 12))
    local header_fill=$((box_width - header_used - 1))
    printf "%${header_fill}s┐${NC}\n" "" | tr ' ' '─'

    printf "│%-$((box_width-2))s│\n" ""

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
    # Pad filter line
    local filter_len=48
    printf "%$((box_width - filter_len - 1))s│\n" ""

    printf "│%-$((box_width-2))s│\n" ""

    # Count items by priority (total, not just current tab)
    local high_count=0 medium_count=0 low_count=0
    for idx in "${TODO_TUI_FILTERED[@]}"; do
        local priority=$(tui_get_field "${TODO_TUI_ITEMS[$idx]}" "priority")
        case "$priority" in
            high) ((high_count++)) ;;
            medium) ((medium_count++)) ;;
            low) ((low_count++)) ;;
        esac
    done

    # Draw items for current tab only
    local row=0
    local current_section=""
    local display_row=0

    for ((i=tab_start; i<tab_end; i++)); do
        local idx="${TODO_TUI_FILTERED[$i]}"
        local item="${TODO_TUI_ITEMS[$idx]}"
        local id=$(tui_get_field "$item" "id")
        local title=$(tui_get_field "$item" "title")
        local priority=$(tui_get_field "$item" "priority")
        local selected="${TODO_TUI_SELECTED[$idx]}"

        # Section header (only show if first item of this priority on this tab)
        if [ "$priority" != "$current_section" ]; then
            current_section="$priority"
            case "$priority" in
                high)
                    printf "│  ${RED}${BOLD}─ HIGH PRIORITY "
                    printf "%$((box_width - 21))s${NC}│\n" "" | tr ' ' '─'
                    ;;
                medium)
                    printf "│  ${YELLOW}${BOLD}─ MEDIUM PRIORITY "
                    printf "%$((box_width - 23))s${NC}│\n" "" | tr ' ' '─'
                    ;;
                low)
                    printf "│  ${DIM}${BOLD}─ LOW PRIORITY "
                    printf "%$((box_width - 20))s${NC}│\n" "" | tr ' ' '─'
                    ;;
            esac
            ((row++))
        fi

        # Item row - check if this is the current selection
        local is_current=false
        [ "$display_row" -eq "$TODO_TUI_CURRENT_ROW" ] && is_current=true

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
        local max_title_len=$((box_width - 22))
        [ ${#title} -gt $max_title_len ] && title="${title:0:$max_title_len}..."

        # Print item line
        printf "│%s$checkbox ${priority_color}%-8s${NC} ${color}%s${NC}" "$prefix" "$id" "$title"

        # Pad to border (account for ANSI codes not taking visual space)
        local visible_len=$((4 + 1 + 9 + ${#title}))
        local padding=$((box_width - visible_len - 3))
        [ "$padding" -gt 0 ] && printf "%${padding}s" ""
        printf "│\n"

        ((row++))
        ((display_row++))
    done

    # Fill remaining space to reach 14 rows
    while [ "$row" -lt "$TODO_TUI_ITEMS_PER_TAB" ]; do
        printf "│%-$((box_width-2))s│\n" ""
        ((row++))
    done

    # Footer with navigation hints
    printf "├"
    printf "%$((box_width-2))s" "" | tr ' ' '─'
    printf "┤\n"

    # Navigation line - show tab navigation if multiple tabs
    if [ "$total_tabs" -gt 1 ]; then
        printf "│ ${BOLD}[←/→]${NC} Tabs  ${BOLD}[↑/↓]${NC} Navigate  ${BOLD}[Space]${NC} Select  ${BOLD}[Enter]${NC} Details"
        printf "%$((box_width - 64))s│\n" ""
    else
        printf "│ ${BOLD}[↑/↓]${NC} Navigate  ${BOLD}[Space]${NC} Select  ${BOLD}[Enter]${NC} Details  ${BOLD}[f]${NC} Filter"
        printf "%$((box_width - 60))s│\n" ""
    fi

    printf "│ ${BOLD}[r]${NC} Resolve  ${BOLD}[i]${NC} Ignore  ${BOLD}[a]${NC} All  ${BOLD}[R]${NC} Refresh  ${BOLD}[q]${NC} Quit"
    printf "%$((box_width - 56))s│\n" ""

    printf "└"
    printf "%$((box_width-2))s" "" | tr ' ' '─'
    printf "┘\n"

    # Summary line
    local total=${#TODO_TUI_FILTERED[@]}
    printf "\nTotal: ${BOLD}$total items${NC} (${RED}$high_count high${NC}, ${YELLOW}$medium_count medium${NC}, $low_count low)"
    if [ "$total_tabs" -gt 1 ]; then
        printf " │ Showing %d-%d" "$((tab_start + 1))" "$tab_end"
    fi
    printf "\n"
}

# Show item details
tui_show_details() {
    local tab_start=$(tui_get_tab_start)
    local global_idx=$((tab_start + TODO_TUI_CURRENT_ROW))
    local idx="${TODO_TUI_FILTERED[$global_idx]}"
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
    TODO_TUI_CURRENT_TAB=0
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

    while true; do
        local key=$(tui_read_key)
        local total_tabs=$(tui_get_total_tabs)
        local tab_items=$(tui_get_tab_item_count)

        case "$key" in
            UP|k)
                # Move up within current tab
                if [ "$TODO_TUI_CURRENT_ROW" -gt 0 ]; then
                    ((TODO_TUI_CURRENT_ROW--))
                elif [ "$TODO_TUI_CURRENT_TAB" -gt 0 ]; then
                    # Move to previous tab, last item
                    ((TODO_TUI_CURRENT_TAB--))
                    TODO_TUI_CURRENT_ROW=$((TODO_TUI_ITEMS_PER_TAB - 1))
                    # Adjust if previous tab has fewer items
                    local prev_tab_items=$(tui_get_tab_item_count)
                    [ "$TODO_TUI_CURRENT_ROW" -ge "$prev_tab_items" ] && TODO_TUI_CURRENT_ROW=$((prev_tab_items - 1))
                else
                    # Wrap to last tab, last item
                    TODO_TUI_CURRENT_TAB=$((total_tabs - 1))
                    local last_tab_items=$(tui_get_tab_item_count)
                    TODO_TUI_CURRENT_ROW=$((last_tab_items - 1))
                fi
                ;;
            DOWN|j)
                # Move down within current tab
                if [ "$TODO_TUI_CURRENT_ROW" -lt $((tab_items - 1)) ]; then
                    ((TODO_TUI_CURRENT_ROW++))
                elif [ "$TODO_TUI_CURRENT_TAB" -lt $((total_tabs - 1)) ]; then
                    # Move to next tab, first item
                    ((TODO_TUI_CURRENT_TAB++))
                    TODO_TUI_CURRENT_ROW=0
                else
                    # Wrap to first tab, first item
                    TODO_TUI_CURRENT_TAB=0
                    TODO_TUI_CURRENT_ROW=0
                fi
                ;;
            LEFT|PGUP)
                # Previous tab
                if [ "$TODO_TUI_CURRENT_TAB" -gt 0 ]; then
                    ((TODO_TUI_CURRENT_TAB--))
                else
                    TODO_TUI_CURRENT_TAB=$((total_tabs - 1))
                fi
                # Adjust row if current tab has fewer items
                local new_tab_items=$(tui_get_tab_item_count)
                [ "$TODO_TUI_CURRENT_ROW" -ge "$new_tab_items" ] && TODO_TUI_CURRENT_ROW=$((new_tab_items - 1))
                [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                ;;
            RIGHT|TAB|PGDN)
                # Next tab
                if [ "$TODO_TUI_CURRENT_TAB" -lt $((total_tabs - 1)) ]; then
                    ((TODO_TUI_CURRENT_TAB++))
                else
                    TODO_TUI_CURRENT_TAB=0
                fi
                # Adjust row if current tab has fewer items
                local new_tab_items=$(tui_get_tab_item_count)
                [ "$TODO_TUI_CURRENT_ROW" -ge "$new_tab_items" ] && TODO_TUI_CURRENT_ROW=$((new_tab_items - 1))
                [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                ;;
            SPACE)
                local tab_start=$(tui_get_tab_start)
                local global_idx=$((tab_start + TODO_TUI_CURRENT_ROW))
                local idx="${TODO_TUI_FILTERED[$global_idx]}"
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
                # Adjust current position if needed
                total_tabs=$(tui_get_total_tabs)
                [ "$TODO_TUI_CURRENT_TAB" -ge "$total_tabs" ] && TODO_TUI_CURRENT_TAB=$((total_tabs - 1))
                [ "$TODO_TUI_CURRENT_TAB" -lt 0 ] && TODO_TUI_CURRENT_TAB=0
                tab_items=$(tui_get_tab_item_count)
                [ "$TODO_TUI_CURRENT_ROW" -ge "$tab_items" ] && TODO_TUI_CURRENT_ROW=$((tab_items - 1))
                [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                ;;
            a|A)
                # Select all items (across all tabs)
                for idx in "${TODO_TUI_FILTERED[@]}"; do
                    TODO_TUI_SELECTED[$idx]="1"
                done
                ;;
            n|N)
                # Deselect all items
                for idx in "${TODO_TUI_FILTERED[@]}"; do
                    TODO_TUI_SELECTED[$idx]="0"
                done
                ;;
            f|F)
                tui_cycle_filter
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
                    # Adjust position
                    total_tabs=$(tui_get_total_tabs)
                    [ "$TODO_TUI_CURRENT_TAB" -ge "$total_tabs" ] && TODO_TUI_CURRENT_TAB=$((total_tabs - 1))
                    [ "$TODO_TUI_CURRENT_TAB" -lt 0 ] && TODO_TUI_CURRENT_TAB=0
                    tab_items=$(tui_get_tab_item_count)
                    [ "$TODO_TUI_CURRENT_ROW" -ge "$tab_items" ] && TODO_TUI_CURRENT_ROW=$((tab_items - 1))
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
                    # Adjust position
                    total_tabs=$(tui_get_total_tabs)
                    [ "$TODO_TUI_CURRENT_TAB" -ge "$total_tabs" ] && TODO_TUI_CURRENT_TAB=$((total_tabs - 1))
                    [ "$TODO_TUI_CURRENT_TAB" -lt 0 ] && TODO_TUI_CURRENT_TAB=0
                    tab_items=$(tui_get_tab_item_count)
                    [ "$TODO_TUI_CURRENT_ROW" -ge "$tab_items" ] && TODO_TUI_CURRENT_ROW=$((tab_items - 1))
                    [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                fi
                ;;
            R)
                # Refresh data
                todo_cache_clear 2>/dev/null || true
                json_data=$(run_all_checks "true")
                tui_load_items "$json_data"
                tui_apply_filters
                ;;
            q|Q|ESC)
                break
                ;;
        esac

        # Check if we still have items
        if [ ${#TODO_TUI_FILTERED[@]} -eq 0 ]; then
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
export -f tui_get_total_tabs
export -f tui_get_tab_start
export -f tui_get_tab_end
export -f tui_get_tab_item_count
export -f tui_draw_screen
export -f tui_show_details
export -f tui_cycle_filter
export -f todo_tui_main
