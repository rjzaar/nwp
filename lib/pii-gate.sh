#!/bin/bash
################################################################################
# lib/pii-gate.sh — reusable, fail-closed PII scanner for sanitized DB dumps.
#
# This is the SECOND, independent gate between "sanitize" and "import/publish"
# (OPERATING-MODEL.md §5,§7). The FIRST gate runs ON PROD inside the per-site
# sanitizer (lib/sanitizers/<site>.sh --verify); this one re-scans the artifact
# AFTER it crosses the prod boundary — defence in depth, so a sanitizer bug or a
# truncated transfer can never let raw PII land on dev/in a published artifact.
#
# Deliberately ADDITIVE: it does NOT modify the prod sanitizers (those are
# security-critical and change only under human review, per CLAUDE.md). It only
# mirrors their pattern/allowlist vocabulary so the two gates agree.
#
# Fail-closed contract:
#   pii_gate_scan <file> [extra_allowlist_file]
#     0  artifact is clean (no PII, OR every hit is fully allowlisted)
#     1  PII found — offending lines printed (capped, with the column elided)
#     2  usage / unreadable file / missing tooling  ← treated as FAIL by callers
#
#   "fail-closed" means: ANY uncertainty (unreadable file, no patterns, gunzip
#   error) returns non-zero. A caller must only proceed on an explicit 0.
#
# Pattern/allowlist sources, in order (later entries ADD, never replace):
#   1. The built-in defaults below (email + AU phone — matches mayo.sh).
#   2. NWP_PII_PATTERNS_FILE / NWP_PII_ALLOWLIST_FILE  (one ERE per line, '#' = comment).
#   3. The optional <extra_allowlist_file> arg (per-site public-contact addresses).
################################################################################

# Patterns that must NOT survive sanitization. Mirrors lib/sanitizers/mayo.sh.
PII_GATE_DEFAULT_PATTERNS=(
    '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'   # Email addresses
    '\b04[0-9]{8}\b'                                     # AU mobile (04XX XXX XXX)
    '\b\+61[0-9]{9,10}\b'                                # AU international
    '\b1[38]00[0-9 ]{6,8}\b'                             # AU 1300/1800 numbers
)

# Tokens that are OK to appear in a sanitized dump (test fixtures, public contacts,
# fake-data domains). A line is only a real hit if PII remains AFTER these are removed.
PII_GATE_DEFAULT_ALLOWLIST=(
    'admin@example\.com'
    'user[0-9]+@example\.com'
    'noreply@'
    'no-reply@'
    '@example\.(com|org|net)'
    '@drupal\.org'
    '@nwpcode\.org'
    'webmaster@'
    'postmaster@'
)

# Load extra ERE lines from a file (blank lines and '#' comments ignored).
_pii_gate_load_file() { # $1 = file ; appends to the named array $2
    local file="$1" arrname="$2" line
    [ -n "$file" ] && [ -f "$file" ] || return 0
    while IFS= read -r line; do
        line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] && eval "$arrname+=(\"\$line\")"
    done < "$file"
}

# Stream a possibly-gzipped SQL dump to stdout. Fail-closed on read errors.
_pii_gate_cat() { # $1 = file
    local file="$1"
    case "$file" in
        *.gz) command -v gunzip >/dev/null 2>&1 || { echo "__PII_GATE_NO_GUNZIP__"; return 2; }
              gunzip -c -- "$file" ;;
        *)    cat -- "$file" ;;
    esac
}

################################################################################
# pii_gate_scan <file> [extra_allowlist_file]
################################################################################
pii_gate_scan() {
    local file="${1:-}" extra_allow="${2:-}"
    if [ -z "$file" ]; then
        echo "pii_gate_scan: usage: pii_gate_scan <sql-or-sql.gz file> [allowlist-file]" >&2
        return 2
    fi
    if [ ! -r "$file" ]; then
        echo "pii_gate_scan: cannot read file: $file" >&2
        return 2
    fi

    # Assemble patterns (built-ins + optional override file).
    local -a patterns=("${PII_GATE_DEFAULT_PATTERNS[@]}")
    _pii_gate_load_file "${NWP_PII_PATTERNS_FILE:-}" patterns
    if [ "${#patterns[@]}" -eq 0 ]; then
        echo "pii_gate_scan: no patterns configured — refusing to declare clean" >&2
        return 2   # fail-closed: an empty pattern set must never pass
    fi
    local union; union=$(IFS='|'; echo "${patterns[*]}")

    # Assemble allowlist (built-ins + env file + per-call file).
    local -a allow=("${PII_GATE_DEFAULT_ALLOWLIST[@]}")
    _pii_gate_load_file "${NWP_PII_ALLOWLIST_FILE:-}" allow
    _pii_gate_load_file "$extra_allow" allow
    local allow_union=""; [ "${#allow[@]}" -gt 0 ] && allow_union=$(IFS='|'; echo "${allow[*]}")

    # Pull candidate lines that match any PII pattern.
    local candidates rc
    candidates=$(_pii_gate_cat "$file" 2>/dev/null | grep -E -- "$union" 2>/dev/null)
    rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 2 ] || [ "$candidates" = "__PII_GATE_NO_GUNZIP__" ]; then
        echo "pii_gate_scan: could not decompress $file (gunzip missing or corrupt)" >&2
        return 2   # fail-closed
    fi
    [ -z "$candidates" ] && return 0   # nothing matched any PII pattern → clean

    # For each candidate, strip allowlisted tokens, then re-test. A line is a real
    # hit only if PII survives the allowlist removal.
    local line stripped hits=0
    local -a samples=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        stripped="$line"
        if [ -n "$allow_union" ]; then
            stripped=$(printf '%s' "$line" | sed -E "s/(${allow_union})//g")
        fi
        if printf '%s' "$stripped" | grep -E -q -- "$union"; then
            hits=$((hits + 1))
            if [ "${#samples[@]}" -lt 10 ]; then
                # Elide the value that matched so we report a location, not the PII.
                samples+=("$(printf '%s' "$line" | sed -E "s/(${union})/[REDACTED-PII]/g" | cut -c1-160)")
            fi
        fi
    done <<< "$candidates"

    if [ "$hits" -eq 0 ]; then
        return 0   # every candidate was fully allowlisted
    fi

    echo "pii_gate_scan: FAIL — $hits line(s) contain unsanitized PII in $file" >&2
    local s
    for s in "${samples[@]}"; do echo "    $s" >&2; done
    [ "$hits" -gt "${#samples[@]}" ] && echo "    … and $((hits - ${#samples[@]})) more" >&2
    return 1
}

# Allow standalone use:  bash lib/pii-gate.sh <file> [allowlist]
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if pii_gate_scan "$@"; then
        echo "PII gate: PASS (no unsanitized PII found)"
    else
        rc=$?
        echo "PII gate: ${rc} (1=PII found, 2=error) — FAIL-CLOSED" >&2
        exit "$rc"
    fi
fi
