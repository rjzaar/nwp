#!/bin/bash

################################################################################
# NWP Sanitizer Helper: deterministic OIDC email
#
# F26 Phase 3: the shared email-sanitisation primitive that both the AVC
# (Drupal) sanitizer and the SS (Moodle) sanitizer call so that the same
# real email hashes to the same fake email on both sides — preserving the
# OIDC linkage in dev/preview environments without leaking real emails.
#
# Hash rule (F26 § 3.3):
#
#     sanitized_email = sha256(real_email || shared_salt)[:16] + "@sanitized.test"
#
# The shared salt lives in .secrets.data.yml at oidc.sanitizer_salt and is
# **never rotated** — see F26 § 4.2 for the justification (rotating it
# would de-link AVC/SS dev users every time a new fixture run happened).
#
# Source: source "$PROJECT_ROOT/lib/sanitizers/oidc-email.sh"
#
# Main functions:
#   oidc_email_sanitize <real_email>         - echo the fake email
#   oidc_email_salt_load                     - load the salt into the
#                                              OIDC_SANITIZER_SALT env var
#   oidc_email_batch <input_file> <col>      - sanitize column $col of a
#                                              CSV-ish file (used by the
#                                              sanitizer SQL dump rewrite)
#
# Security properties enforced here:
#   - The salt is never echoed. Never logged. Never written to stdout.
#   - Empty or missing input echoes an empty string (not the salt-only
#     hash, which would be a fingerprint of the salt).
#   - The function refuses to run if the salt is shorter than 16 bytes —
#     F26 § 4.2 says 32 bytes is the target; 16 is the floor.
#
# See:
#   docs/proposals/F26-avc-ss-oidc.md § 3.3 and § 4.2
################################################################################

if [[ -z "${NWP_ROOT:-}" ]]; then
    NWP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# Default location of the data-tier secrets file
OIDC_SANITIZER_SALT_FILE="${OIDC_SANITIZER_SALT_FILE:-${NWP_ROOT}/.secrets.data.yml}"
OIDC_SANITIZER_SALT_KEY="${OIDC_SANITIZER_SALT_KEY:-oidc.sanitizer_salt}"

# Load the shared salt into OIDC_SANITIZER_SALT.
#
# Reads .secrets.data.yml directly with grep/sed (avoids yq dependency and
# avoids sourcing a yaml file that might contain other data-tier secrets).
# The key lookup is dotted (oidc.sanitizer_salt → section oidc, field
# sanitizer_salt).
#
# Returns 0 on success (salt loaded into OIDC_SANITIZER_SALT), 1 on failure.
oidc_email_salt_load() {
    # If caller pre-exported the salt (tests do this), respect it.
    if [[ -n "${OIDC_SANITIZER_SALT:-}" ]]; then
        if (( ${#OIDC_SANITIZER_SALT} < 16 )); then
            echo "ERROR: OIDC_SANITIZER_SALT too short (<16 bytes); refusing to proceed" >&2
            return 1
        fi
        return 0
    fi

    if [[ ! -f "$OIDC_SANITIZER_SALT_FILE" ]]; then
        echo "ERROR: salt file not found: $OIDC_SANITIZER_SALT_FILE" >&2
        echo "       populate $OIDC_SANITIZER_SALT_KEY in .secrets.data.yml" >&2
        return 1
    fi

    # Parse a simple dotted key. We only support one level of nesting
    # because that's all F26 needs. The parser is deliberately dumb:
    #   oidc:
    #     sanitizer_salt: <32 bytes>
    local section field
    section="${OIDC_SANITIZER_SALT_KEY%%.*}"
    field="${OIDC_SANITIZER_SALT_KEY#*.}"
    if [[ -z "$section" || -z "$field" || "$section" == "$field" ]]; then
        echo "ERROR: key must be dotted: $OIDC_SANITIZER_SALT_KEY" >&2
        return 1
    fi

    # Find the section, then the field under it. Stop at the next
    # top-level key to avoid cross-section bleed.
    local salt
    salt=$(awk -v section="$section" -v field="$field" '
        BEGIN { in_section = 0 }
        /^[a-zA-Z0-9_-]+:[[:space:]]*$/ {
            # Top-level key line
            if ($0 ~ "^"section":[[:space:]]*$") {
                in_section = 1
                next
            } else {
                in_section = 0
                next
            }
        }
        in_section && $0 ~ "^[[:space:]]+"field":" {
            # Extract value after the first colon
            sub("^[[:space:]]+"field":[[:space:]]*", "", $0)
            # Strip surrounding quotes if present
            gsub("^[\"'\'']|[\"'\'']$", "", $0)
            print $0
            exit
        }
    ' "$OIDC_SANITIZER_SALT_FILE")

    if [[ -z "$salt" ]]; then
        echo "ERROR: key $OIDC_SANITIZER_SALT_KEY not found in $OIDC_SANITIZER_SALT_FILE" >&2
        return 1
    fi
    if (( ${#salt} < 16 )); then
        echo "ERROR: $OIDC_SANITIZER_SALT_KEY is shorter than 16 bytes; refusing to proceed" >&2
        return 1
    fi

    export OIDC_SANITIZER_SALT="$salt"
    return 0
}

# Sanitize a single email address to its deterministic F26 form.
#
# Usage: oidc_email_sanitize <real_email>
#
# Echoes the sanitized email. Empty or whitespace-only input echoes
# an empty string (never the salt-only hash).
#
# Returns 0 on success.
oidc_email_sanitize() {
    local real="$1"

    # Reject empty — do not let an attacker recover "what does the empty
    # string hash to with your salt" which is a useful fingerprint.
    if [[ -z "$real" ]] || [[ "${real// /}" == "" ]]; then
        echo ""
        return 0
    fi

    if ! command -v sha256sum &>/dev/null; then
        echo "ERROR: sha256sum required" >&2
        return 1
    fi

    oidc_email_salt_load || return 1

    # Compute sha256(real_email + salt) and take the first 16 hex chars.
    # NOTE: the F26 spec says [:16] which we interpret as 16 hex chars
    # (64 bits of entropy). Adjust both sides consistently if this ever
    # changes.
    local hash
    hash=$(printf '%s%s' "$real" "$OIDC_SANITIZER_SALT" \
        | sha256sum \
        | awk '{print $1}' \
        | cut -c1-16)

    echo "${hash}@sanitized.test"
    return 0
}

# Sanitize column $col of a TSV-like file in place. This is the helper
# used by the per-site sanitizer SQL dump rewrites.
#
# Usage: oidc_email_batch <input_file> <col_index_1based>
#
# The file is modified in place. Only rows whose column $col looks
# like an email (contains @) are touched. Non-email rows pass through.
# A backup is written to <input_file>.orig.
oidc_email_batch() {
    local input="$1"
    local col="$2"

    if [[ ! -f "$input" ]]; then
        echo "ERROR: input file not found: $input" >&2
        return 1
    fi
    if ! [[ "$col" =~ ^[0-9]+$ ]] || (( col < 1 )); then
        echo "ERROR: column index must be a positive integer: $col" >&2
        return 1
    fi

    oidc_email_salt_load || return 1

    cp "$input" "${input}.orig"

    local tmp
    tmp=$(mktemp) || return 1

    local line fields
    while IFS= read -r line; do
        # Split on tab; fields is 1-indexed to match $col
        IFS=$'\t' read -r -a fields <<<"$line"
        local idx=$((col - 1))
        if (( idx < ${#fields[@]} )) && [[ "${fields[$idx]}" == *"@"* ]]; then
            fields[$idx]=$(oidc_email_sanitize "${fields[$idx]}")
        fi
        # Re-join with tabs
        local out=""
        local i
        for ((i=0; i<${#fields[@]}; i++)); do
            if (( i == 0 )); then
                out="${fields[$i]}"
            else
                out="${out}"$'\t'"${fields[$i]}"
            fi
        done
        printf '%s\n' "$out" >> "$tmp"
    done < "$input"

    mv "$tmp" "$input"
    return 0
}
