#!/bin/bash

################################################################################
# NWP Minisign Library
#
# Wrapper functions for minisign artifact signing and verification.
# Source this file: source "$PROJECT_ROOT/lib/minisign.sh"
#
# F21 Phase 5/7: Provides the signing primitives used by:
#   - pl build  (sign tarballs on dev / mirror-store)
#   - pl publish (include .minisig alongside artifact)
#   - verifier deploy script (verify before deploying)
#
# Key management:
#   - Secret key: $NWP_ROOT/keys/minisign/nwp-deploy.key (software interim)
#   - Public key: $NWP_ROOT/keys/minisign/nwp-deploy.pub
#   - When Solo 2C+ arrives, the secret key moves to hardware; the public
#     key stays the same on the verifier and in CI.
################################################################################

# Resolve NWP root if not already set
if [[ -z "${NWP_ROOT:-}" ]]; then
    NWP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

MINISIGN_KEY_DIR="${NWP_ROOT}/keys/minisign"
MINISIGN_SECRET_KEY="${MINISIGN_KEY_DIR}/nwp-deploy.key"
MINISIGN_PUBLIC_KEY="${MINISIGN_KEY_DIR}/nwp-deploy.pub"

# Check if minisign is installed
# Returns: 0 if installed, 1 if not
minisign_check() {
    if ! command -v minisign &>/dev/null; then
        echo "ERROR: minisign is not installed. Install with: sudo apt-get install -y minisign" >&2
        return 1
    fi
    return 0
}

# Check if signing keys exist
# Returns: 0 if both keys exist, 1 if not
minisign_keys_exist() {
    [[ -f "$MINISIGN_SECRET_KEY" && -f "$MINISIGN_PUBLIC_KEY" ]]
}

# Generate a new minisign keypair (interactive — prompts for password)
# Usage: minisign_generate_keys
# The password protects the secret key at rest. Use a strong password.
# When Solo 2C+ arrives, regenerate with hardware-backed key.
minisign_generate_keys() {
    minisign_check || return 1

    if minisign_keys_exist; then
        echo "ERROR: Keys already exist at ${MINISIGN_KEY_DIR}/" >&2
        echo "  Secret: ${MINISIGN_SECRET_KEY}" >&2
        echo "  Public: ${MINISIGN_PUBLIC_KEY}" >&2
        echo "Delete them first if you want to regenerate." >&2
        return 1
    fi

    mkdir -p "$MINISIGN_KEY_DIR"

    echo "Generating minisign keypair for NWP deploy signing..."
    echo "  Secret key: ${MINISIGN_SECRET_KEY}"
    echo "  Public key: ${MINISIGN_PUBLIC_KEY}"
    echo ""
    echo "You will be prompted for a password to protect the secret key."
    echo ""

    minisign -G \
        -s "$MINISIGN_SECRET_KEY" \
        -p "$MINISIGN_PUBLIC_KEY" \
        -c "NWP deploy signing key (software interim — replace with Solo 2C+ when available)"

    if [[ $? -eq 0 ]]; then
        chmod 600 "$MINISIGN_SECRET_KEY"
        chmod 644 "$MINISIGN_PUBLIC_KEY"
        echo ""
        echo "Keys generated. Public key:"
        cat "$MINISIGN_PUBLIC_KEY"
        echo ""
        echo "Copy the public key to the verifier host: ${MINISIGN_PUBLIC_KEY}"
        echo "The secret key MUST NOT leave this machine (or the mirror-store)."
        return 0
    else
        echo "ERROR: Key generation failed" >&2
        return 1
    fi
}

# Sign a file with the NWP deploy key
# Usage: minisign_sign <file> [trusted_comment]
# Creates <file>.minisig alongside the file
minisign_sign() {
    local file="$1"
    local trusted_comment="${2:-"NWP deploy artifact signed $(date -Iseconds)"}"

    minisign_check || return 1

    if [[ ! -f "$file" ]]; then
        echo "ERROR: File not found: $file" >&2
        return 1
    fi

    if [[ ! -f "$MINISIGN_SECRET_KEY" ]]; then
        echo "ERROR: Secret key not found: $MINISIGN_SECRET_KEY" >&2
        echo "Run: source lib/minisign.sh && minisign_generate_keys" >&2
        return 1
    fi

    minisign -S \
        -s "$MINISIGN_SECRET_KEY" \
        -m "$file" \
        -t "$trusted_comment"

    if [[ $? -eq 0 ]]; then
        echo "Signed: ${file}.minisig"
        return 0
    else
        echo "ERROR: Signing failed" >&2
        return 1
    fi
}

# Verify a file's minisign signature
# Usage: minisign_verify <file> [public_key_file]
# Looks for <file>.minisig alongside the file
minisign_verify() {
    local file="$1"
    local pubkey="${2:-$MINISIGN_PUBLIC_KEY}"

    minisign_check || return 1

    if [[ ! -f "$file" ]]; then
        echo "ERROR: File not found: $file" >&2
        return 1
    fi

    if [[ ! -f "${file}.minisig" ]]; then
        echo "ERROR: Signature not found: ${file}.minisig" >&2
        return 1
    fi

    if [[ ! -f "$pubkey" ]]; then
        echo "ERROR: Public key not found: $pubkey" >&2
        return 1
    fi

    minisign -V \
        -p "$pubkey" \
        -m "$file"

    return $?
}

# Extract the public key ID from the public key file
# Usage: minisign_key_id [public_key_file]
minisign_key_id() {
    local pubkey="${1:-$MINISIGN_PUBLIC_KEY}"
    if [[ ! -f "$pubkey" ]]; then
        echo "ERROR: Public key not found: $pubkey" >&2
        return 1
    fi
    # The public key file has two lines: comment and key
    tail -1 "$pubkey"
}
