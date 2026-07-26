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
# Enforcement: tests/unit/test-impact-contract.bats fails any script that
# performs destructive operations without ADOPTING this lib (with a
# shrink-only allowlist for not-yet-converted files). The gate itself lives
# at the bottom of this file (impact_contract_* functions) so the test, CI
# and any future `pl` verb all run the SAME code, not three copies.
################################################################################

_IMPACT_LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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

################################################################################
# THE GATE (nwp/ops#47 + item 7) — enforce ADOPTION, not MENTION.
#
# The original gate was `grep -q 'lib/impact.sh' "$f"` over `scripts/commands/*.sh`.
# It had two holes, both proven with probes before this code was written:
#
#   1. A STRING MENTION passed. A file containing `rm -rf "$1"` and the comment
#      "# this file does NOT source lib/impact.sh" was green on all four cases.
#      This was not hypothetical: `scripts/commands/restore.sh` was believed
#      converted for a release because lib/restore-remote.sh's header mentioned
#      the path (recorded in the item-2 decision log), and `branch.sh` sources
#      the lib and prompts but never renders a manifest.
#   2. `lib/` and `servers/` were NEVER SCANNED — yet the destructive engines
#      (moodle-deploy, moodle-promote, rollback-remote, the sanitizers) live
#      there, and logic is actively MIGRATING from commands into lib. The gate's
#      coverage therefore shrank toward zero while staying green.
#
# ADOPTION now means one of two things, both checked on NON-COMMENT lines only:
#
#   (A) in-repo scripts — `source .../impact.sh` AND at least one `impact_render`
#       AND at least one `impact_confirm`. Render is required because the
#       contract is "print the manifest, THEN prompt": a confirm without a
#       manifest is the prompt without the information that makes it meaningful.
#
#   (B) box-resident scripts that CANNOT source the repo lib (a forced-command
#       shipped to a server that has no checkout) — the file declares the pragma
#         # impact-contract: inline
#       and emits a literal `FATE MANIFEST` block itself. The pragma alone is not
#       enough; a pragma with no manifest is a violation.
#
# Allowlist: lib/impact-contract.allowlist, keyed by repo-relative path, one
# justification per entry. SHRINK-ONLY.
################################################################################

# Destructive-operation signature. Matched on NON-COMMENT lines only, so a file
# that merely *documents* `rm -rf` is not dragged into the contract.
IMPACT_DESTRUCTIVE_PATTERN='rm -rf|ddev delete|DROP DATABASE|sql-drop|sql:drop|rsync .*--delete|--delete.*rsync'

impact_contract_root() {
    echo "${NWP_IMPACT_CONTRACT_ROOT:-$( cd "$_IMPACT_LIB_DIR/.." && pwd )}"
}

impact_contract_allowlist_file() {
    echo "${NWP_IMPACT_ALLOWLIST:-${_IMPACT_LIB_DIR}/impact-contract.allowlist}"
}

# Echo a file's code lines (comments and doc-block lines dropped).
_impact_code_lines() {
    grep -vE '^[[:space:]]*(#|\*|//|/\*)' "$1" 2>/dev/null
}

# impact_is_destructive <file> — 0 if it performs a destructive op in CODE.
impact_is_destructive() {
    _impact_code_lines "$1" | grep -qE "$IMPACT_DESTRUCTIVE_PATTERN"
}

# impact_contract_adopted <file> — 0 if the file genuinely adopts the contract.
impact_contract_adopted() {
    local f="$1" code
    code="$(_impact_code_lines "$f")"

    # (B) box-resident inline manifest.
    if grep -qE '^[[:space:]]*#[[:space:]]*impact-contract:[[:space:]]*inline([[:space:]]|$)' "$f" 2>/dev/null; then
        printf '%s\n' "$code" | grep -q 'FATE MANIFEST' && return 0
        return 1
    fi

    # (A) in-repo adoption: sourced AND rendered AND confirmed.
    printf '%s\n' "$code" | grep -qE '(^|[[:space:]])(source|\.)[[:space:]]+[^[:space:]]*impact\.sh' || return 1
    printf '%s\n' "$code" | grep -q 'impact_render'  || return 1
    printf '%s\n' "$code" | grep -q 'impact_confirm' || return 1
    return 0
}

# Echo allowlisted repo-relative paths, one per line (comments/blanks dropped).
impact_contract_allowlist() {
    local file; file="$(impact_contract_allowlist_file)"
    [ -f "$file" ] || return 0
    sed 's/[[:space:]]*#.*$//' "$file" | grep -vE '^[[:space:]]*$' | awk '{print $1}'
}

_impact_in_allowlist() {
    local needle="$1" entry
    while IFS= read -r entry; do
        [ "$entry" = "$needle" ] && return 0
    done < <(impact_contract_allowlist)
    return 1
}

# Echo every candidate file (repo-relative) the gate must consider.
#   scripts/commands/*.sh · lib/**/*.sh · servers/** (tracked, shebang)
# lib/impact.sh itself is excluded — it IS the contract, not a consumer.
impact_contract_candidates() {
    local root; root="$(impact_contract_root)"
    local f rel
    for f in "$root"/scripts/commands/*.sh; do
        [ -f "$f" ] && printf '%s\n' "${f#"$root"/}"
    done
    while IFS= read -r f; do
        rel="${f#"$root"/}"
        [ "$rel" = "lib/impact.sh" ] && continue
        printf '%s\n' "$rel"
    done < <(find "$root/lib" -type f -name '*.sh' 2>/dev/null | sort)
    # servers/: no .sh convention (forced commands are extensionless), so take
    # every TRACKED file carrying a shebang. Tracked-only keeps untracked box
    # scratch out of the gate.
    if [ -d "$root/servers" ] && command -v git >/dev/null 2>&1; then
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            [ -f "$root/$rel" ] || continue
            head -c 2 "$root/$rel" 2>/dev/null | grep -q '#!' && printf '%s\n' "$rel"
        done < <(git -C "$root" ls-files servers 2>/dev/null)
    fi
    return 0
}

# impact_contract_violations — echo "<path>\t<reason>" for each unadopted,
# unallowlisted destructive file. Returns 0 when clean, 1 when violations exist.
impact_contract_violations() {
    local root; root="$(impact_contract_root)"
    local rel found=0
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        impact_is_destructive "$root/$rel" || continue
        impact_contract_adopted "$root/$rel" && continue
        _impact_in_allowlist "$rel" && continue
        printf '%s\tdestructive operation without the impact contract\n' "$rel"
        found=1
    done < <(impact_contract_candidates)
    [ "$found" -eq 0 ]
}

# impact_contract_stale_allowlist — echo "<path>\t<reason>" for allowlist rows
# that no longer earn their place. Keeps the list SHRINK-ONLY in practice, not
# just by convention. Returns 0 when clean, 1 when stale rows exist.
impact_contract_stale_allowlist() {
    local root; root="$(impact_contract_root)"
    local entry found=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if [ ! -f "$root/$entry" ]; then
            printf '%s\tfile removed — delete the row\n' "$entry"; found=1; continue
        fi
        if ! impact_is_destructive "$root/$entry"; then
            printf '%s\tno longer destructive — delete the row\n' "$entry"; found=1; continue
        fi
        if impact_contract_adopted "$root/$entry"; then
            printf '%s\tCONVERTED — delete the row\n' "$entry"; found=1; continue
        fi
    done < <(impact_contract_allowlist)
    [ "$found" -eq 0 ]
}
