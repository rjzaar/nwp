#!/bin/bash
################################################################################
# lib/impact.sh — the impact-report contract for destructive verbs (nwp/ops#47)
#
# CONTRACT: no destructive verb acts on inferred scope. Before any
# irreversible action the command prints a fate manifest — every affected
# component labeled DELETE / OVERWRITE / ARCHIVE / KEEP, with sizes, names
# and data-loss warnings computed live from the system (du, docker, git,
# DB queries — never assumptions, never AI). `-y` skips the PROMPT, never
# the REPORT (the manifest still lands in logs/transcripts as an audit
# record of what the command believed at the time). Confirmation strength
# matches reversibility: y/N while a recovery path survives ("standard"),
# typed-name when none will ("typed").
#
# Usage shape (see delete.sh for the reference consumer):
#   impact_reset
#   impact_delete    "Files"   "/path (4.5G)"
#   impact_overwrite "Database" "current avc-dev DB (63.8M) replaced by backup X"
#   impact_archive   "Backups" "43 file(s), 2.8G → sitebackups/avc/"
#   impact_keep      "Live server (https://…) — files, DB and certs stay"
#   impact_warn      "git repo dev: 2 commit(s) not pushed to any remote"
#   impact_render
#   impact_confirm standard "delete 'avc'" "$AUTO_CONFIRM" || abort
#   impact_confirm typed   "avc"          "$AUTO_CONFIRM" || abort   # purge tier
#
# Enforcement: tests/unit/test-impact-contract.bats fails any command
# script that performs destructive operations without sourcing this lib
# (with a shrink-only allowlist for not-yet-converted verbs).
################################################################################

# Colors: use ui.sh definitions when present, define minimal fallbacks
# otherwise (mirrors the yaml-write.sh pattern).
if [[ -z "${RED+x}" ]]; then
    if [[ -t 1 ]]; then
        RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
        BOLD=$'\033[1m'; NC=$'\033[0m'
    else
        RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
    fi
fi

# Fate collectors (globals; one report in flight at a time)
IMPACT_DELETE=()
IMPACT_OVERWRITE=()
IMPACT_ARCHIVE=()
IMPACT_KEEP=()
IMPACT_WARNINGS=()

impact_reset() {
    IMPACT_DELETE=()
    IMPACT_OVERWRITE=()
    IMPACT_ARCHIVE=()
    IMPACT_KEEP=()
    IMPACT_WARNINGS=()
}

# impact_delete <label> <detail>  — component destroyed with no copy kept
impact_delete()    { IMPACT_DELETE+=("$1|$2"); }
# impact_overwrite <label> <detail> — current state replaced (the sneaky fate:
# restore/copy/deploy clobber things that still exist afterwards)
impact_overwrite() { IMPACT_OVERWRITE+=("$1|$2"); }
# impact_archive <label> <detail> — moved out of harm's way, still recoverable
impact_archive()   { IMPACT_ARCHIVE+=("$1|$2"); }
# impact_keep <text> — explicitly NOT affected (answers the collateral fear)
impact_keep()      { IMPACT_KEEP+=("$1"); }
# impact_warn <text> — data-loss warning (work that exists only here, etc.)
impact_warn()      { IMPACT_WARNINGS+=("$1"); }

_impact_section() {
    local heading="$1"; shift
    local color="$1"; shift
    [ $# -eq 0 ] && return 0
    echo -e "${BOLD}${color}${heading}${NC}"
    local entry
    for entry in "$@"; do
        printf "  %-11s %s\n" "${entry%%|*}:" "${entry#*|}"
    done
    echo ""
}

# Print the fate manifest. ALWAYS call this before impact_confirm — the
# report is unconditional; only the prompt is skippable.
impact_render() {
    echo ""
    _impact_section "WILL BE PERMANENTLY DELETED:" "$RED"    "${IMPACT_DELETE[@]}"
    _impact_section "WILL BE OVERWRITTEN:"         "$RED"    "${IMPACT_OVERWRITE[@]}"
    _impact_section "ARCHIVED (kept, relocated):"  "$YELLOW" "${IMPACT_ARCHIVE[@]}"

    if [ ${#IMPACT_WARNINGS[@]} -gt 0 ]; then
        echo -e "${BOLD}${YELLOW}DATA-LOSS WARNINGS:${NC}"
        local w
        for w in "${IMPACT_WARNINGS[@]}"; do
            echo -e "  ${YELLOW}⚠${NC} $w"
        done
        echo ""
    fi

    if [ ${#IMPACT_KEEP[@]} -gt 0 ]; then
        echo -e "${BOLD}${GREEN}NOT AFFECTED:${NC}"
        local k
        for k in "${IMPACT_KEEP[@]}"; do
            echo "  • $k"
        done
        echo ""
    fi
}

# impact_confirm <tier> <subject> [auto_confirm]
#   tier "standard": y/N prompt — for actions where a recovery path survives
#                    (subject is the question text, e.g. "delete site 'avc'").
#   tier "typed":    the operator must type <subject> exactly — for actions
#                    that destroy the last recovery path (purge tier).
#   auto_confirm "true": skip the prompt (the report was already printed).
# Returns 0 = proceed, 1 = abort.
impact_confirm() {
    local tier="$1"
    local subject="$2"
    local auto="${3:-false}"

    if [ "$auto" = "true" ]; then
        return 0
    fi

    # No TTY and no -y: fail closed — a destructive verb must never guess.
    if [ ! -t 0 ]; then
        echo -e "${RED}No terminal available for confirmation and -y not given — aborting.${NC}" >&2
        return 1
    fi

    case "$tier" in
        standard)
            echo -e "${RED}${BOLD}WARNING: This action cannot be undone!${NC}"
            local reply
            read -r -p "Are you sure you want to ${subject}? [y/N] " reply
            case "$reply" in
                y|Y|yes|YES) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        typed)
            echo -e "${RED}${BOLD}WARNING: This destroys the LAST recovery path — no undo, no restore.${NC}"
            local typed
            read -r -p "Type the name '${subject}' to confirm: " typed
            if [ "$typed" = "$subject" ]; then
                return 0
            fi
            echo -e "${YELLOW}Name mismatch — aborting.${NC}" >&2
            return 1
            ;;
        *)
            echo -e "${RED}impact_confirm: unknown tier '$tier'${NC}" >&2
            return 1
            ;;
    esac
}
