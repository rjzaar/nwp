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

# Box drawing characters (ASCII for compatibility)
BOX_H="-"
BOX_V="|"
BOX_TL="+"
BOX_TR="+"
BOX_BL="+"
BOX_BR="+"
BOX_LT="+"
BOX_RT="+"

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
            '[5') echo "PGUP" ;;
            '[6') echo "PGDN" ;;
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

# Load todo items from JSON string
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

# Load items from TODO_ITEMS array (for progressive loading)
tui_load_items_from_array() {
    TODO_TUI_ITEMS=()
    TODO_TUI_SELECTED=()

    # Copy from global TODO_ITEMS array (populated by checks)
    for item in "${TODO_ITEMS[@]}"; do
        TODO_TUI_ITEMS+=("$item")
        TODO_TUI_SELECTED+=("0")
    done
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

################################################################################
# Drawing Functions
################################################################################

# Draw a horizontal line
tui_draw_hline() {
    local width="$1"
    local left="${2:-$BOX_TL}"
    local right="${3:-$BOX_TR}"
    local fill="${4:-$BOX_H}"

    printf "%s" "$left"
    for ((i=0; i<width-2; i++)); do
        printf "%s" "$fill"
    done
    printf "%s\n" "$right"
}

# Draw a text line with borders
tui_draw_line() {
    local width="$1"
    local text="$2"
    local text_len=${#text}
    local padding=$((width - text_len - 2))

    printf "%s%s" "$BOX_V" "$text"
    [ "$padding" -gt 0 ] && printf "%${padding}s" ""
    printf "%s\n" "$BOX_V"
}

# Build page tabs string
tui_build_page_tabs() {
    local total_tabs=$(tui_get_total_tabs)
    local result=""

    if [ "$total_tabs" -le 1 ]; then
        echo ""
        return
    fi

    for ((p=0; p<total_tabs; p++)); do
        if [ "$p" -eq "$TODO_TUI_CURRENT_TAB" ]; then
            result="${result}${CYAN}[Page $((p+1))]${NC} "
        else
            result="${result}[Page $((p+1))] "
        fi
    done

    echo "$result"
}

# Draw the main screen
tui_draw_screen() {
    local term_width=$(tput cols 2>/dev/null || echo 80)
    local box_width=72
    [ "$term_width" -lt "$box_width" ] && box_width=$((term_width - 2))

    tui_clear_screen

    # Calculate tab info
    local total_tabs=$(tui_get_total_tabs)
    local tab_start=$(tui_get_tab_start)
    local tab_end=$(tui_get_tab_end)

    # Header line
    tui_draw_hline "$box_width" "$BOX_TL" "$BOX_TR"

    # Title
    printf "%s ${BOLD}NWP Todo List${NC}" "$BOX_V"
    printf "%$((box_width - 17))s%s\n" "" "$BOX_V"

    # Separator
    tui_draw_hline "$box_width" "$BOX_LT" "$BOX_RT"

    # Page tabs (if multiple pages)
    if [ "$total_tabs" -gt 1 ]; then
        local page_tabs=$(tui_build_page_tabs)
        printf "%s  %s" "$BOX_V" "$page_tabs"
        # Calculate visible length (without ANSI codes)
        local visible_len=$((3 + total_tabs * 9))
        local pad=$((box_width - visible_len - 1))
        [ "$pad" -gt 0 ] && printf "%${pad}s" ""
        printf "%s\n" "$BOX_V"

        # Navigation hint
        printf "%s  ${DIM}<- Left/Right arrows to change page ->${NC}" "$BOX_V"
        printf "%$((box_width - 44))s%s\n" "" "$BOX_V"

        tui_draw_hline "$box_width" "$BOX_LT" "$BOX_RT"
    fi

    # Filter bar
    printf "%s  Filter: " "$BOX_V"
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
        printf "${YELLOW}[Med]${NC} "
    else
        printf "[Med] "
    fi
    if [ "$TODO_TUI_FILTER_PRIORITY" = "low" ]; then
        printf "${DIM}[Low]${NC} "
    else
        printf "[Low] "
    fi
    printf "  (f to cycle)"
    printf "%$((box_width - 52))s%s\n" "" "$BOX_V"

    # Empty line
    tui_draw_line "$box_width" ""

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
            local section_text=""
            local section_color=""
            case "$priority" in
                high)
                    section_text="--- HIGH PRIORITY "
                    section_color="${RED}"
                    ;;
                medium)
                    section_text="--- MEDIUM PRIORITY "
                    section_color="${YELLOW}"
                    ;;
                low)
                    section_text="--- LOW PRIORITY "
                    section_color="${DIM}"
                    ;;
            esac
            printf "%s  ${section_color}${BOLD}%s" "$BOX_V" "$section_text"
            local fill_len=$((box_width - ${#section_text} - 5))
            for ((f=0; f<fill_len; f++)); do printf "-"; done
            printf "${NC} %s\n" "$BOX_V"
            ((row++))
        fi

        # Item row - check if this is the current selection
        local is_current=false
        [ "$display_row" -eq "$TODO_TUI_CURRENT_ROW" ] && is_current=true

        # Checkbox
        local checkbox="[ ]"
        [ "$selected" = "1" ] && checkbox="[${GREEN}x${NC}]"

        # Highlight current row
        local prefix="  "
        local suffix=""
        if [ "$is_current" = true ]; then
            prefix="${CYAN}> ${NC}"
            suffix="${BOLD}"
        fi

        # Priority color for ID
        local id_color=""
        case "$priority" in
            high) id_color="${RED}" ;;
            medium) id_color="${YELLOW}" ;;
            low) id_color="${DIM}" ;;
        esac

        # Truncate title if needed
        local max_title_len=$((box_width - 24))
        [ ${#title} -gt $max_title_len ] && title="${title:0:$max_title_len}..."

        # Print item line
        printf "%s%s%s ${id_color}%-10s${NC} ${suffix}%s${NC}" "$BOX_V" "$prefix" "$checkbox" "$id" "$title"

        # Pad to border
        local content_len=$((4 + 4 + 11 + ${#title}))
        local pad=$((box_width - content_len - 1))
        [ "$pad" -gt 0 ] && printf "%${pad}s" ""
        printf "%s\n" "$BOX_V"

        ((row++))
        ((display_row++))
    done

    # Fill remaining space to reach 14 rows
    while [ "$row" -lt "$TODO_TUI_ITEMS_PER_TAB" ]; do
        tui_draw_line "$box_width" ""
        ((row++))
    done

    # Footer separator
    tui_draw_hline "$box_width" "$BOX_LT" "$BOX_RT"

    # Help line 1
    printf "%s ${BOLD}d${NC}=Details  ${BOLD}Space${NC}=Select  ${BOLD}x${NC}=Execute  ${BOLD}p${NC}=Done  ${BOLD}i${NC}=Ignore" "$BOX_V"
    printf "%$((box_width - 57))s%s\n" "" "$BOX_V"

    # Help line 2
    printf "%s ${BOLD}a${NC}=All  ${BOLD}n${NC}=None  ${BOLD}f${NC}=Filter  ${BOLD}r${NC}=Refresh  ${BOLD}Esc${NC}=Quit" "$BOX_V"
    printf "%$((box_width - 50))s%s\n" "" "$BOX_V"

    # Bottom border
    tui_draw_hline "$box_width" "$BOX_BL" "$BOX_BR"

    # Summary line (outside box)
    local total=${#TODO_TUI_FILTERED[@]}
    printf "\nTotal: ${BOLD}%d${NC} items  " "$total"
    printf "(${RED}%d high${NC}, ${YELLOW}%d medium${NC}, %d low)" "$high_count" "$medium_count" "$low_count"
    if [ "$total_tabs" -gt 1 ]; then
        printf "  |  Showing %d-%d of %d" "$((tab_start + 1))" "$tab_end" "$total"
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
    echo "========================================================================"
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

    # Check if executable
    local is_exec=false
    tui_is_executable "$item" && is_exec=true

    echo "========================================================================"
    echo ""
    if [ "$is_exec" = true ]; then
        echo -e "Press ${BOLD}[x]${NC} to execute, ${BOLD}[p]${NC} to mark done, ${BOLD}[i]${NC} to ignore, ${BOLD}Esc${NC} to go back"
    else
        echo -e "Press ${BOLD}[p]${NC} to mark done, ${BOLD}[i]${NC} to ignore, ${BOLD}Esc${NC} to go back"
    fi

    local key=$(tui_read_key)
    case "$key" in
        x|X)
            if [ "$is_exec" = true ]; then
                tui_execute_item "$item"
            else
                echo -e "${YELLOW}This item type is not executable${NC}"
                sleep 1
            fi
            ;;
        p|P)
            tui_cursor_show
            echo ""
            echo -n "Mark as processed (done)? [y/N] "
            read -r confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                add_to_ignored "$id" "Processed"
                echo -e "${GREEN}Item marked as processed${NC}"
                sleep 0.5
            fi
            tui_cursor_hide
            ;;
        i|I)
            tui_cursor_show
            echo ""
            echo -n "Ignore this item (skip without completing)? [y/N] "
            read -r confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo -n "Reason (optional): "
                read -r reason
                add_to_ignored "$id" "${reason:-Ignored}"
                echo -e "${YELLOW}Item ignored${NC}"
                sleep 0.5
            fi
            tui_cursor_hide
            ;;
        ESC)
            # Go back to main screen
            return
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
# Execute Functions
################################################################################

# Get executable command for an item (returns empty if not executable)
tui_get_exec_command() {
    local item="$1"
    local action=$(tui_get_field "$item" "action")
    local category=$(tui_get_field "$item" "category")
    local site=$(tui_get_field "$item" "site")

    # Extract command from action field
    local cmd=""

    case "$category" in
        TST)
            # Delete test site
            [ -n "$site" ] && cmd="pl delete $site"
            ;;
        BAK)
            # Run backup
            [ -n "$site" ] && cmd="pl backup $site"
            ;;
        SEC)
            # Security update
            [ -n "$site" ] && cmd="pl security update $site"
            ;;
        SCH)
            # Install schedule
            [ -n "$site" ] && cmd="pl schedule install $site"
            ;;
        GHO)
            # Unlist ghost site
            [ -n "$site" ] && cmd="ddev stop --unlist $site"
            ;;
        ORP)
            # Delete orphaned site
            [ -n "$site" ] && cmd="pl delete $site"
            ;;
        INC)
            # Continue incomplete install - extract step from action
            if [[ "$action" =~ pl\ install\ -s=([0-9]+) ]]; then
                local step="${BASH_REMATCH[1]}"
                [ -n "$site" ] && cmd="pl install -s=$step $site"
            fi
            ;;
        VER)
            # Run verification
            cmd="pl verify --run"
            ;;
        GIT)
            # Open GitLab URL
            if [[ "$action" =~ Open:\ (https://[^ ]+) ]]; then
                local url="${BASH_REMATCH[1]}"
                cmd="xdg-open '$url' 2>/dev/null || open '$url' 2>/dev/null"
            fi
            ;;
        SSL)
            # SSL renewal (needs sudo typically)
            cmd="sudo certbot renew"
            ;;
        TOK)
            # Token rotation tracking
            local token_name=$(echo "$item" | grep -o '"id":"TOK-[^"]*"' | cut -d'-' -f2 | tr -d '"')
            [ -n "$token_name" ] && cmd="pl todo token $token_name"
            ;;
        *)
            # Not executable
            cmd=""
            ;;
    esac

    echo "$cmd"
}

# Check if item is executable
tui_is_executable() {
    local item="$1"
    local cmd=$(tui_get_exec_command "$item")
    [ -n "$cmd" ]
}

# Execute an item's action
tui_execute_item() {
    local item="$1"
    local id=$(tui_get_field "$item" "id")
    local cmd=$(tui_get_exec_command "$item")

    if [ -z "$cmd" ]; then
        echo -e "${YELLOW}This item type is not executable${NC}"
        sleep 1
        return 1
    fi

    tui_cursor_show
    echo ""
    echo -e "${BOLD}Command to execute:${NC}"
    echo -e "  ${CYAN}$cmd${NC}"
    echo ""
    echo -n "Execute this command? [y/N] "
    read -r confirm

    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        echo ""
        echo -e "${DIM}Running...${NC}"
        echo "------------------------------------------------------------------------"

        # Execute the command
        if eval "$cmd"; then
            echo "------------------------------------------------------------------------"
            echo -e "${GREEN}Command completed successfully${NC}"
            add_to_ignored "$id" "Executed" 2>/dev/null
            sleep 1
        else
            echo "------------------------------------------------------------------------"
            echo -e "${RED}Command failed${NC}"
            echo -n "Mark as processed anyway? [y/N] "
            read -r mark_anyway
            if [ "$mark_anyway" = "y" ] || [ "$mark_anyway" = "Y" ]; then
                add_to_ignored "$id" "Executed (with errors)" 2>/dev/null
            fi
            sleep 1
        fi
    fi

    tui_cursor_hide
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

    # Setup terminal early for progressive loading
    tui_cursor_hide
    trap 'tui_cursor_show; tui_clear_screen' EXIT

    # Initialize empty state
    TODO_TUI_ITEMS=()
    TODO_TUI_SELECTED=()
    TODO_TUI_FILTERED=()
    todo_cache_init

    # Draw initial screen with loading message
    tui_draw_screen
    local term_height=$(tput lines 2>/dev/null || echo 24)

    # Progressive loading: run each check and update display
    local total_checks=$(todo_get_check_count)
    todo_clear_items

    for ((check_idx=0; check_idx<total_checks; check_idx++)); do
        local check_name=$(todo_get_check_name "$check_idx")

        # Show loading status at bottom
        printf "\033[%d;1H" "$term_height"
        printf "\033[2K"
        printf " ${DIM}Checking: %s... (%d/%d)${NC}" "$check_name" "$((check_idx+1))" "$total_checks"

        # Run this check (adds to TODO_ITEMS array)
        todo_run_check_by_index "$check_idx"

        # Convert TODO_ITEMS to TUI format and refresh display
        tui_load_items_from_array
        tui_apply_filters
        tui_draw_screen
    done

    # Clear loading message
    printf "\033[%d;1H" "$term_height"
    printf "\033[2K"

    if [ ${#TODO_TUI_FILTERED[@]} -eq 0 ]; then
        tui_cursor_show
        tui_clear_screen
        echo ""
        print_status "OK" "No todo items found"
        echo ""
        return 0
    fi

    # Final draw
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
                # Previous page
                if [ "$TODO_TUI_CURRENT_TAB" -gt 0 ]; then
                    ((TODO_TUI_CURRENT_TAB--))
                else
                    TODO_TUI_CURRENT_TAB=$((total_tabs - 1))
                fi
                local new_tab_items=$(tui_get_tab_item_count)
                [ "$TODO_TUI_CURRENT_ROW" -ge "$new_tab_items" ] && TODO_TUI_CURRENT_ROW=$((new_tab_items - 1))
                [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                ;;
            RIGHT|TAB|PGDN)
                # Next page
                if [ "$TODO_TUI_CURRENT_TAB" -lt $((total_tabs - 1)) ]; then
                    ((TODO_TUI_CURRENT_TAB++))
                else
                    TODO_TUI_CURRENT_TAB=0
                fi
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
            d|D|ENTER)
                tui_show_details
                # Reload data in case item was processed/ignored
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
            x|X)
                # Execute selected items
                local executed=0
                local to_execute=()
                for idx in "${TODO_TUI_FILTERED[@]}"; do
                    if [ "${TODO_TUI_SELECTED[$idx]}" = "1" ]; then
                        to_execute+=("$idx")
                    fi
                done
                if [ ${#to_execute[@]} -eq 0 ]; then
                    # No selection, execute current item
                    local tab_start=$(tui_get_tab_start)
                    local global_idx=$((tab_start + TODO_TUI_CURRENT_ROW))
                    to_execute+=("${TODO_TUI_FILTERED[$global_idx]}")
                fi
                for idx in "${to_execute[@]}"; do
                    local item="${TODO_TUI_ITEMS[$idx]}"
                    if tui_is_executable "$item"; then
                        tui_clear_screen
                        tui_execute_item "$item"
                        ((executed++))
                    fi
                done
                if [ "$executed" -gt 0 ]; then
                    # Reload data
                    todo_clear_items
                    local total_checks=$(todo_get_check_count)
                    for ((check_idx=0; check_idx<total_checks; check_idx++)); do
                        todo_run_check_by_index "$check_idx"
                    done
                    tui_load_items_from_array
                    tui_apply_filters
                    total_tabs=$(tui_get_total_tabs)
                    [ "$TODO_TUI_CURRENT_TAB" -ge "$total_tabs" ] && TODO_TUI_CURRENT_TAB=$((total_tabs - 1))
                    [ "$TODO_TUI_CURRENT_TAB" -lt 0 ] && TODO_TUI_CURRENT_TAB=0
                    tab_items=$(tui_get_tab_item_count)
                    [ "$TODO_TUI_CURRENT_ROW" -ge "$tab_items" ] && TODO_TUI_CURRENT_ROW=$((tab_items - 1))
                    [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                fi
                ;;
            p|P)
                # Process selected items (mark as done)
                local processed=0
                for idx in "${TODO_TUI_FILTERED[@]}"; do
                    if [ "${TODO_TUI_SELECTED[$idx]}" = "1" ]; then
                        local id=$(tui_get_field "${TODO_TUI_ITEMS[$idx]}" "id")
                        add_to_ignored "$id" "Processed" 2>/dev/null
                        ((processed++))
                    fi
                done
                if [ "$processed" -gt 0 ]; then
                    json_data=$(run_all_checks)
                    tui_load_items "$json_data"
                    tui_apply_filters
                    total_tabs=$(tui_get_total_tabs)
                    [ "$TODO_TUI_CURRENT_TAB" -ge "$total_tabs" ] && TODO_TUI_CURRENT_TAB=$((total_tabs - 1))
                    [ "$TODO_TUI_CURRENT_TAB" -lt 0 ] && TODO_TUI_CURRENT_TAB=0
                    tab_items=$(tui_get_tab_item_count)
                    [ "$TODO_TUI_CURRENT_ROW" -ge "$tab_items" ] && TODO_TUI_CURRENT_ROW=$((tab_items - 1))
                    [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                fi
                ;;
            i|I)
                # Ignore selected items (skip without completing)
                local ignored=0
                for idx in "${TODO_TUI_FILTERED[@]}"; do
                    if [ "${TODO_TUI_SELECTED[$idx]}" = "1" ]; then
                        local id=$(tui_get_field "${TODO_TUI_ITEMS[$idx]}" "id")
                        add_to_ignored "$id" "Ignored" 2>/dev/null
                        ((ignored++))
                    fi
                done
                if [ "$ignored" -gt 0 ]; then
                    json_data=$(run_all_checks)
                    tui_load_items "$json_data"
                    tui_apply_filters
                    total_tabs=$(tui_get_total_tabs)
                    [ "$TODO_TUI_CURRENT_TAB" -ge "$total_tabs" ] && TODO_TUI_CURRENT_TAB=$((total_tabs - 1))
                    [ "$TODO_TUI_CURRENT_TAB" -lt 0 ] && TODO_TUI_CURRENT_TAB=0
                    tab_items=$(tui_get_tab_item_count)
                    [ "$TODO_TUI_CURRENT_ROW" -ge "$tab_items" ] && TODO_TUI_CURRENT_ROW=$((tab_items - 1))
                    [ "$TODO_TUI_CURRENT_ROW" -lt 0 ] && TODO_TUI_CURRENT_ROW=0
                fi
                ;;
            r|R)
                # Refresh data with progressive loading
                todo_cache_clear 2>/dev/null || true
                todo_clear_items
                local total_checks=$(todo_get_check_count)
                local term_height=$(tput lines 2>/dev/null || echo 24)

                for ((check_idx=0; check_idx<total_checks; check_idx++)); do
                    local check_name=$(todo_get_check_name "$check_idx")
                    printf "\033[%d;1H\033[2K ${DIM}Refreshing: %s... (%d/%d)${NC}" "$term_height" "$check_name" "$((check_idx+1))" "$total_checks"
                    todo_run_check_by_index "$check_idx"
                    tui_load_items_from_array
                    tui_apply_filters
                    tui_draw_screen
                done
                printf "\033[%d;1H\033[2K" "$term_height"
                ;;
            q|Q)
                break
                ;;
            ESC)
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
export -f tui_load_items_from_array
export -f tui_get_field
export -f tui_apply_filters
export -f tui_get_total_tabs
export -f tui_get_tab_start
export -f tui_get_tab_end
export -f tui_get_tab_item_count
export -f tui_draw_screen
export -f tui_show_details
export -f tui_cycle_filter
export -f tui_get_exec_command
export -f tui_is_executable
export -f tui_execute_item
export -f todo_tui_main
