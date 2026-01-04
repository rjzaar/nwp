#!/bin/bash

################################################################################
# NWP Dev2Stg TUI Library
#
# Interactive Terminal UI for dev2stg deployment planner
# Source this file: source "$SCRIPT_DIR/lib/dev2stg-tui.sh"
#
# Requires: lib/ui.sh, lib/state.sh, lib/testing.sh to be sourced first
################################################################################

# Prevent double-sourcing
[[ -n "${_DEV2STG_TUI_SH_LOADED:-}" ]] && return 0
_DEV2STG_TUI_SH_LOADED=1

################################################################################
# Terminal Control Functions
################################################################################

tui_clear() { printf "\033[2J\033[H"; }
tui_cursor_hide() { printf "\033[?25l"; }
tui_cursor_show() { printf "\033[?25h"; }
tui_cursor_to() { printf "\033[%d;%dH" "$1" "$2"; }

tui_read_key() {
    local key
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.1 rest || true
        case "$rest" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            *) echo "ESC" ;;
        esac
    elif [[ $key == "" ]]; then
        echo "ENTER"
    elif [[ $key == " " ]]; then
        echo "SPACE"
    else
        echo "$key"
    fi
}

################################################################################
# State Variables for TUI
################################################################################

# Current selections
declare -g TUI_DB_SOURCE="auto"
declare -g TUI_TEST_SELECTION="essential"
declare -g TUI_CREATE_STG="prompt"
declare -g TUI_SANITIZE="true"

# Detected state (set by load_tui_state)
declare -g TUI_DEV_EXISTS="false"
declare -g TUI_DEV_RUNNING="false"
declare -g TUI_STG_EXISTS="false"
declare -g TUI_STG_RUNNING="false"
declare -g TUI_RECENT_BACKUP=""
declare -g TUI_SANITIZED_BACKUP=""
declare -g TUI_BACKUP_AGE=""
declare -g TUI_PROD_ACCESSIBLE="false"
declare -g TUI_LIVE_DOMAIN=""
declare -g TUI_AVAILABLE_TESTS=""

################################################################################
# Load State for TUI
################################################################################

# Load site state into TUI variables
# Usage: load_tui_state "sitename"
load_tui_state() {
    local sitename="$1"

    # Use state.sh functions
    local stg_name=$(get_staging_name "$sitename")

    TUI_DEV_EXISTS="false"
    TUI_DEV_RUNNING="false"
    if site_exists "$sitename"; then
        TUI_DEV_EXISTS="true"
        if site_running "$sitename"; then
            TUI_DEV_RUNNING="true"
        fi
    fi

    TUI_STG_EXISTS="false"
    TUI_STG_RUNNING="false"
    if site_exists "$stg_name"; then
        TUI_STG_EXISTS="true"
        if site_running "$stg_name"; then
            TUI_STG_RUNNING="true"
        fi
    fi

    TUI_RECENT_BACKUP=$(find_recent_backup "$sitename" 24 2>/dev/null || echo "")
    TUI_SANITIZED_BACKUP=$(find_sanitized_backup "$sitename" 24 2>/dev/null || echo "")

    if [ -n "$TUI_SANITIZED_BACKUP" ]; then
        TUI_BACKUP_AGE=$(backup_age_human "$TUI_SANITIZED_BACKUP")
    elif [ -n "$TUI_RECENT_BACKUP" ]; then
        TUI_BACKUP_AGE=$(backup_age_human "$TUI_RECENT_BACKUP")
    else
        TUI_BACKUP_AGE=""
    fi

    TUI_PROD_ACCESSIBLE="false"
    TUI_LIVE_DOMAIN=""
    if has_live_config "$sitename" 2>/dev/null; then
        TUI_LIVE_DOMAIN=$(get_live_domain "$sitename" 2>/dev/null || echo "")
        if check_prod_ssh "$sitename" 2>/dev/null; then
            TUI_PROD_ACCESSIBLE="true"
        fi
    fi

    TUI_AVAILABLE_TESTS=$(detect_test_suites "$sitename" 2>/dev/null || echo "")

    # Set recommended defaults based on state
    if [ -n "$TUI_SANITIZED_BACKUP" ]; then
        TUI_DB_SOURCE="backup:$TUI_SANITIZED_BACKUP"
    elif [ -n "$TUI_RECENT_BACKUP" ]; then
        TUI_DB_SOURCE="backup:$TUI_RECENT_BACKUP"
    elif [ "$TUI_PROD_ACCESSIBLE" = "true" ]; then
        TUI_DB_SOURCE="production"
    else
        TUI_DB_SOURCE="development"
    fi
}

################################################################################
# Display Functions
################################################################################

# Draw the main TUI screen
# Usage: draw_main_screen "sitename"
draw_main_screen() {
    local sitename="$1"
    local stg_name=$(get_staging_name "$sitename")

    tui_clear

    # Header
    echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║                    dev2stg Deployment Planner                     ║${NC}"
    echo -e "${BLUE}${BOLD}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}${BOLD}║${NC} Source: ${BOLD}$sitename${NC} (development)                                    ${BLUE}${BOLD}║${NC}"
    echo -e "${BLUE}${BOLD}║${NC} Target: ${BOLD}$stg_name${NC} (staging)                                    ${BLUE}${BOLD}║${NC}"
    echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Current State Section
    echo -e "${BOLD}━━━ Current State ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Dev site status
    if [ "$TUI_DEV_EXISTS" = "true" ]; then
        if [ "$TUI_DEV_RUNNING" = "true" ]; then
            echo -e "  ${GREEN}✓${NC} Development site: Running"
        else
            echo -e "  ${YELLOW}○${NC} Development site: Exists (stopped)"
        fi
    else
        echo -e "  ${RED}✗${NC} Development site: Not found"
    fi

    # Staging site status
    if [ "$TUI_STG_EXISTS" = "true" ]; then
        if [ "$TUI_STG_RUNNING" = "true" ]; then
            echo -e "  ${GREEN}✓${NC} Staging site: Running"
        else
            echo -e "  ${YELLOW}○${NC} Staging site: Exists (stopped)"
        fi
    else
        echo -e "  ${YELLOW}○${NC} Staging site: Will be created"
    fi

    # Backup status
    if [ -n "$TUI_SANITIZED_BACKUP" ]; then
        echo -e "  ${GREEN}✓${NC} Sanitized backup: $(basename "$TUI_SANITIZED_BACKUP") ($TUI_BACKUP_AGE)"
    elif [ -n "$TUI_RECENT_BACKUP" ]; then
        echo -e "  ${YELLOW}○${NC} Recent backup: $(basename "$TUI_RECENT_BACKUP") ($TUI_BACKUP_AGE) - will sanitize"
    else
        echo -e "  ${YELLOW}○${NC} No recent backup found"
    fi

    # Production status
    if [ -n "$TUI_LIVE_DOMAIN" ]; then
        if [ "$TUI_PROD_ACCESSIBLE" = "true" ]; then
            echo -e "  ${GREEN}✓${NC} Production: Accessible ($TUI_LIVE_DOMAIN)"
        else
            echo -e "  ${YELLOW}○${NC} Production: Configured but not accessible"
        fi
    else
        echo -e "  ${CYAN}i${NC} Production: Not configured"
    fi

    # Tests available
    if [ -n "$TUI_AVAILABLE_TESTS" ]; then
        echo -e "  ${GREEN}✓${NC} Tests available: $TUI_AVAILABLE_TESTS"
    else
        echo -e "  ${CYAN}i${NC} Tests: None detected"
    fi

    echo ""

    # Proposed Plan Section
    echo -e "${BOLD}━━━ Proposed Plan ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local step=1

    if [ "$TUI_STG_EXISTS" != "true" ]; then
        echo -e "  [${step}] Create staging site"
        ((step++))
    elif [ "$TUI_STG_RUNNING" != "true" ]; then
        echo -e "  [${step}] Start staging DDEV"
        ((step++))
    fi

    echo -e "  [${step}] Export dev config"; ((step++))
    echo -e "  [${step}] Sync code to staging"; ((step++))

    # Database source display
    local db_display
    case "$TUI_DB_SOURCE" in
        backup:*)
            db_display="Use backup: $(basename "${TUI_DB_SOURCE#backup:}")"
            ;;
        production)
            db_display="Fresh backup from production"
            ;;
        development)
            db_display="Clone development database"
            ;;
        *)
            db_display="Auto-select database source"
            ;;
    esac
    echo -e "  [${step}] ${db_display} ${YELLOW}★${NC}"; ((step++))

    echo -e "  [${step}] Run composer install --no-dev"; ((step++))
    echo -e "  [${step}] Run database updates"; ((step++))
    echo -e "  [${step}] Import configuration (3x retry)"; ((step++))
    echo -e "  [${step}] Set production mode"; ((step++))

    # Test display
    local test_display
    local test_duration=$(estimate_test_duration "$TUI_TEST_SELECTION" 2>/dev/null || echo "?")
    case "$TUI_TEST_SELECTION" in
        skip)
            test_display="Skip tests"
            ;;
        *)
            test_display="Run tests: $TUI_TEST_SELECTION (~${test_duration}min)"
            ;;
    esac
    echo -e "  [${step}] ${test_display} ${YELLOW}★${NC}"; ((step++))

    echo -e "  [${step}] Display staging URL"

    echo ""
    echo -e "  ${YELLOW}★${NC} = configurable"
    echo ""

    # Options Menu
    echo -e "${BOLD}━━━ Options ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  [${GREEN}E${NC}] Execute plan as shown"
    echo -e "  [${CYAN}D${NC}] Change database source"
    echo -e "  [${CYAN}T${NC}] Change test selection (current: $TUI_TEST_SELECTION)"
    echo -e "  [${CYAN}P${NC}] Run preflight checks only"
    echo -e "  [${RED}Q${NC}] Quit"
    echo ""
    echo -n "Select option: "
}

# Draw database source selection menu
draw_db_menu() {
    local sitename="$1"

    tui_clear

    echo -e "${BOLD}━━━ Database Source Selection ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local opt=1
    local recommended=""

    # Option 1: Sanitized backup (if exists)
    if [ -n "$TUI_SANITIZED_BACKUP" ]; then
        recommended="★"
        echo -e "  [${opt}] Use sanitized backup: $(basename "$TUI_SANITIZED_BACKUP") ${YELLOW}$recommended${NC}"
        echo -e "      Age: $TUI_BACKUP_AGE"
    else
        echo -e "  ${DIM}[${opt}] No sanitized backup available${NC}"
    fi
    ((opt++))

    # Option 2: Recent backup (if exists)
    if [ -n "$TUI_RECENT_BACKUP" ] && [ "$TUI_RECENT_BACKUP" != "$TUI_SANITIZED_BACKUP" ]; then
        if [ -z "$recommended" ]; then recommended="★"; fi
        echo -e "  [${opt}] Use backup (will sanitize): $(basename "$TUI_RECENT_BACKUP")"
        echo -e "      Age: $(backup_age_human "$TUI_RECENT_BACKUP")"
    else
        echo -e "  ${DIM}[${opt}] No other recent backup available${NC}"
    fi
    ((opt++))

    # Option 3: Production backup
    if [ "$TUI_PROD_ACCESSIBLE" = "true" ]; then
        if [ -z "$recommended" ]; then recommended="★"; fi
        echo -e "  [${opt}] Create fresh backup from production"
        echo -e "      Domain: $TUI_LIVE_DOMAIN"
    else
        echo -e "  ${DIM}[${opt}] Production not accessible${NC}"
    fi
    ((opt++))

    # Option 4: Development database
    echo -e "  [${opt}] Clone development database"
    echo -e "      No production data"
    ((opt++))

    # Option 5: Select from backup history
    echo -e "  [${opt}] Select from backup history..."
    ((opt++))

    echo ""
    echo -e "  [${RED}B${NC}] Back to main menu"
    echo ""
    echo -e "  ${YELLOW}★${NC} = recommended"
    echo ""
    echo -n "Select option: "
}

# Draw test selection menu
draw_test_menu() {
    tui_clear

    echo -e "${BOLD}━━━ Test Selection ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BOLD}Presets:${NC}"
    echo -e "  [1] quick      (~1 min)  - PHPCS, ESLint syntax checks"
    echo -e "  [2] essential  (~5 min)  - PHPUnit, PHPStan, PHPCS ${YELLOW}★${NC}"
    echo -e "  [3] functional (~15 min) - Behat BDD scenarios"
    echo -e "  [4] full       (~30 min) - All test types"
    echo -e "  [5] security   (~3 min)  - Security + static analysis"
    echo -e "  [6] skip                 - No tests"
    echo ""
    echo -e "${BOLD}Individual Tests:${NC}"
    echo -e "  [P] phpunit       PHPUnit unit/integration tests"
    echo -e "  [H] behat         Behat BDD scenario tests"
    echo -e "  [S] phpstan       PHPStan static analysis"
    echo -e "  [C] phpcs         PHP CodeSniffer style checks"
    echo -e "  [E] eslint        JavaScript/TypeScript linting"
    echo -e "  [Y] stylelint     CSS/SCSS linting"
    echo -e "  [U] security      Security vulnerability scan"
    echo -e "  [A] accessibility WCAG accessibility checks"
    echo ""
    echo -e "  [${RED}B${NC}] Back to main menu"
    echo ""
    echo -e "  ${YELLOW}★${NC} = recommended"
    echo ""
    echo -e "Current selection: ${BOLD}$TUI_TEST_SELECTION${NC}"
    echo ""
    echo -n "Select option (or type comma-separated types): "
}

################################################################################
# Main TUI Loop
################################################################################

# Run the interactive TUI
# Usage: run_dev2stg_tui "sitename"
# Returns: 0 to proceed with deployment, 1 to cancel
# Sets: TUI_DB_SOURCE, TUI_TEST_SELECTION
run_dev2stg_tui() {
    local sitename="$1"

    # Load state
    load_tui_state "$sitename"

    # Main loop
    while true; do
        draw_main_screen "$sitename"

        local key
        read -rsn1 key

        case "$key" in
            e|E)
                # Execute - return to proceed
                echo ""
                return 0
                ;;
            d|D)
                # Database selection
                run_db_menu "$sitename"
                ;;
            t|T)
                # Test selection
                run_test_menu
                ;;
            p|P)
                # Run preflight only
                echo ""
                preflight_check "$sitename"
                echo ""
                read -p "Press Enter to continue..."
                ;;
            q|Q)
                # Quit
                echo ""
                return 1
                ;;
        esac
    done
}

# Database selection submenu
run_db_menu() {
    local sitename="$1"

    while true; do
        draw_db_menu "$sitename"

        local key
        read -rsn1 key

        case "$key" in
            1)
                if [ -n "$TUI_SANITIZED_BACKUP" ]; then
                    TUI_DB_SOURCE="backup:$TUI_SANITIZED_BACKUP"
                    return
                fi
                ;;
            2)
                if [ -n "$TUI_RECENT_BACKUP" ]; then
                    TUI_DB_SOURCE="backup:$TUI_RECENT_BACKUP"
                    return
                fi
                ;;
            3)
                if [ "$TUI_PROD_ACCESSIBLE" = "true" ]; then
                    TUI_DB_SOURCE="production"
                    return
                fi
                ;;
            4)
                TUI_DB_SOURCE="development"
                return
                ;;
            5)
                # Show backup history
                echo ""
                list_backups "$sitename" 10
                echo ""
                read -p "Enter backup filename (or press Enter to cancel): " backup_file
                if [ -n "$backup_file" ]; then
                    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
                    local full_path="$script_dir/sitebackups/$sitename/$backup_file"
                    if [ -f "$full_path" ]; then
                        TUI_DB_SOURCE="backup:$full_path"
                        return
                    elif [ -f "$backup_file" ]; then
                        TUI_DB_SOURCE="backup:$backup_file"
                        return
                    else
                        echo "File not found: $backup_file"
                        read -p "Press Enter to continue..."
                    fi
                fi
                ;;
            b|B)
                return
                ;;
        esac
    done
}

# Test selection submenu
run_test_menu() {
    while true; do
        draw_test_menu

        local input
        read -r input

        case "$input" in
            1) TUI_TEST_SELECTION="quick"; return ;;
            2) TUI_TEST_SELECTION="essential"; return ;;
            3) TUI_TEST_SELECTION="functional"; return ;;
            4) TUI_TEST_SELECTION="full"; return ;;
            5) TUI_TEST_SELECTION="security-only"; return ;;
            6) TUI_TEST_SELECTION="skip"; return ;;
            b|B) return ;;
            p|P) TUI_TEST_SELECTION="phpunit"; return ;;
            h|H) TUI_TEST_SELECTION="behat"; return ;;
            s|S) TUI_TEST_SELECTION="phpstan"; return ;;
            c|C) TUI_TEST_SELECTION="phpcs"; return ;;
            e|E) TUI_TEST_SELECTION="eslint"; return ;;
            y|Y) TUI_TEST_SELECTION="stylelint"; return ;;
            u|U) TUI_TEST_SELECTION="security"; return ;;
            a|A) TUI_TEST_SELECTION="accessibility"; return ;;
            *)
                # Check if it's a comma-separated list
                if [[ "$input" =~ ^[a-z,]+$ ]]; then
                    if validate_test_selection "$input" 2>/dev/null; then
                        TUI_TEST_SELECTION="$input"
                        return
                    fi
                fi
                ;;
        esac
    done
}

################################################################################
# Simple Prompts (for non-TUI mode)
################################################################################

# Simple database source prompt
# Usage: prompt_db_source "sitename"
prompt_db_source() {
    local sitename="$1"

    load_tui_state "$sitename"

    echo ""
    echo "Database source options:"

    local opt=1
    declare -a options

    if [ -n "$TUI_SANITIZED_BACKUP" ]; then
        echo "  $opt) Use sanitized backup: $(basename "$TUI_SANITIZED_BACKUP") ($TUI_BACKUP_AGE) [recommended]"
        options[$opt]="backup:$TUI_SANITIZED_BACKUP"
        ((opt++))
    fi

    if [ -n "$TUI_RECENT_BACKUP" ] && [ "$TUI_RECENT_BACKUP" != "$TUI_SANITIZED_BACKUP" ]; then
        echo "  $opt) Use backup (will sanitize): $(basename "$TUI_RECENT_BACKUP")"
        options[$opt]="backup:$TUI_RECENT_BACKUP"
        ((opt++))
    fi

    if [ "$TUI_PROD_ACCESSIBLE" = "true" ]; then
        echo "  $opt) Fresh backup from production ($TUI_LIVE_DOMAIN)"
        options[$opt]="production"
        ((opt++))
    fi

    echo "  $opt) Clone development database"
    options[$opt]="development"
    ((opt++))

    echo "  $opt) Auto-select best option"
    options[$opt]="auto"

    echo ""
    read -p "Select [1]: " choice
    choice=${choice:-1}

    if [ -n "${options[$choice]}" ]; then
        TUI_DB_SOURCE="${options[$choice]}"
    else
        TUI_DB_SOURCE="auto"
    fi
}

# Simple test selection prompt
# Usage: prompt_test_selection
prompt_test_selection() {
    echo ""
    echo "Test options:"
    echo "  1) quick      - Syntax checks only (~1 min)"
    echo "  2) essential  - PHPUnit + PHPStan + PHPCS (~5 min) [recommended]"
    echo "  3) functional - Behat BDD scenarios (~15 min)"
    echo "  4) full       - All tests (~30 min)"
    echo "  5) security   - Security-focused (~3 min)"
    echo "  6) skip       - No tests"
    echo ""
    read -p "Select [2]: " choice
    choice=${choice:-2}

    case "$choice" in
        1) TUI_TEST_SELECTION="quick" ;;
        2) TUI_TEST_SELECTION="essential" ;;
        3) TUI_TEST_SELECTION="functional" ;;
        4) TUI_TEST_SELECTION="full" ;;
        5) TUI_TEST_SELECTION="security-only" ;;
        6) TUI_TEST_SELECTION="skip" ;;
        *) TUI_TEST_SELECTION="essential" ;;
    esac
}
