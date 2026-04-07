# ADR-0010: TUI Framework Design (checkbox.sh and tui.sh)

**Status:** Accepted
**Date:** 2025-12-01 (original), refined 2026-01-14
**Decision Makers:** Rob
**Related Issues:** P31 (Enhanced Site Management TUI), F04 (Coders TUI)
**References:** [checkbox.sh](../../lib/checkbox.sh) (1487 lines), [tui.sh](../../lib/tui.sh) (758 lines)

## Context

NWP commands needed interactive user interfaces for:
- **install.sh** - Selecting installation options (dev modules, security, redis, solr, etc.)
- **modify.sh** - Changing site configurations with arrow navigation
- **coders.sh** - Managing distributed developers
- **verify.sh** - Interactive verification console with keyboard shortcuts
- **import.sh** - Selecting remote sites to import

Key requirements:
1. **Arrow key navigation** - Intuitive up/down/left/right
2. **Multi-select checkboxes** - Space to toggle, Enter to confirm
3. **Full-screen TUI** - Clear screen, refresh, restore terminal
4. **Keyboard shortcuts** - Single-key actions (v:Verify, i:Checklist, etc.)
5. **NO_COLOR support** - Respect standard (https://no-color.org/)
6. **Pure bash** - No external dependencies (no dialog, whiptail, etc.)

## Decision

Create two-tier TUI framework:

**Tier 1: checkbox.sh (1487 lines)** - Multi-select checkbox UI
- Option system with metadata (labels, descriptions, dependencies, conflicts)
- Arrow navigation (↑↓ between items)
- Space to toggle, Enter to confirm
- Category grouping
- Dependency resolution
- Input field collection

**Tier 2: tui.sh (758 lines)** - Full-screen terminal UI
- Clear screen, cursor positioning
- Arrow navigation with state management
- Keyboard shortcut system
- Screen refresh/restore
- Color output with NO_COLOR support

## Rationale

### Why Custom TUI Instead of dialog/whiptail?

**Rejected alternatives:**
- **dialog** - Not installed by default, inconsistent across distros
- **whiptail** - Limited customization, ugly on macOS
- **ncurses** - C library, would require rewrite
- **Python curses** - Requires Python, mixing languages

**Pure bash advantages:**
- Works everywhere (only requires bash 4+)
- No installation step
- Full control over UI/UX
- Can integrate tightly with NWP conventions
- 2245 lines is manageable

### checkbox.sh Design Decisions

**Option Definition System:**
```bash
define_option "option_id" \
    --label "User-visible label" \
    --description "What this does" \
    --environment "dev,stg,live" \
    --category "Development" \
    --default "y" \
    --depends "other_option" \
    --conflicts "incompatible_option" \
    --inputs "key:label,key2:label2"
```

**Why metadata-driven?**
- Options defined in recipe YAML
- TUI built dynamically from metadata
- Adding new option requires 0 code changes
- Self-documenting (description shown in UI)

**Key features:**
- Dependency resolution (auto-select dependencies)
- Conflict detection (auto-deselect conflicts)
- Input collection (prompt for values)
- Category grouping (organize by function)

### tui.sh Design Decisions

**Arrow key handling:**
```bash
read_arrow_key() {
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.1 key
        case "$key" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
        esac
    fi
}
```

**Why manual escape sequence parsing?**
- `read -rsn1` works everywhere
- No terminfo/termcap dependencies
- Handles arrow keys, Enter, Space, single chars
- Timeout prevents blocking

**Full-screen mode:**
```bash
# Enter full-screen
tput smcup  # Save screen
clear

# ... interactive UI ...

# Exit full-screen
tput rmcup  # Restore screen
```

**Why tput instead of raw ANSI?**
- Terminal-independent
- Works on xterm, screen, tmux, etc.
- Graceful degradation

### NO_COLOR Support

**Standard compliance:**
```bash
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    # Disable all colors
    RED='' GREEN='' YELLOW='' NC=''
else
    # Enable colors
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
fi
```

**Why NO_COLOR?**
- Industry standard (https://no-color.org/)
- Used by 300+ CLI tools
- Respects user preference
- CI/CD friendly (no color codes in logs)
- Accessibility (screen readers)

## Consequences

### Positive
- **No external dependencies** - Works on any bash 4+ system
- **Consistent UX** - Same look/feel across all NWP commands
- **Extensible** - Easy to add new TUI features
- **Metadata-driven** - Options come from YAML, not code
- **Well-tested** - Used in 10+ NWP commands

### Negative
- **2245 lines** - Large codebase to maintain
- **Bash limitations** - Not as featureful as ncurses
- **ASCII only** - No mouse support, limited drawing chars

## Implementation Notes

**Used by:**
- `scripts/commands/install.sh` - Installation options
- `scripts/commands/modify.sh` - Site configuration
- `scripts/commands/coders.sh` - Developer management
- `scripts/commands/verify.sh` - Verification console
- `scripts/commands/import.sh` - Server/site selection
- `scripts/commands/dev2stg.sh` - Deployment options

**Key functions:**
- `show_checkbox_menu()` - Main checkbox UI (checkbox.sh)
- `tui_console()` - Full-screen console (tui.sh)
- `read_arrow_key()` - Keyboard input (tui.sh)
- `define_option()` - Option metadata (checkbox.sh)

## Review

**30-day review date:** 2026-02-14
**Review outcome:** Pending

**Success Metrics:**
- [x] Used in 6+ NWP commands
- [x] NO_COLOR support implemented
- [x] Works on Linux, macOS, Windows (WSL)
- [x] Zero external dependencies
- [ ] Mouse support (future enhancement)

## Related Decisions

- **ADR-0008: Recipe System Architecture** - Options defined in recipes
- **ADR-0007: Verification Schema v2** - Verification console uses tui.sh
