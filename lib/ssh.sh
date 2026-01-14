#!/bin/bash

################################################################################
# NWP SSH Library
#
# Provides SSH connection helpers with security controls
# Source this file: source "$PROJECT_ROOT/lib/ssh.sh"
#
# Security Features:
# - NWP_SSH_STRICT environment variable for host key verification
# - User warnings about MITM vulnerabilities
# - Standardized SSH options across all connections
################################################################################

# Get SSH host key checking mode based on NWP_SSH_STRICT setting
# Returns: "yes" for strict mode, "accept-new" for convenient mode
get_ssh_host_key_checking() {
    if [ "${NWP_SSH_STRICT:-0}" = "1" ]; then
        echo "yes"
    else
        echo "accept-new"
    fi
}

# Display warning about SSH host key verification mode
# Call this before establishing first SSH connection
show_ssh_security_warning() {
    if [ "${NWP_SSH_STRICT:-0}" != "1" ]; then
        echo "⚠️  SSH Host Key Verification: Using 'accept-new' mode"
        echo "    First connection will accept server fingerprint automatically"
        echo "    This is convenient but vulnerable to MITM on first connection"
        echo ""
        echo "    For strict mode: export NWP_SSH_STRICT=1"
        echo ""
    fi
}

# Get standard SSH options array for NWP connections
# Usage: get_ssh_options
# Returns array via stdout (use mapfile or read -a to capture)
get_ssh_options() {
    local host_key_mode
    host_key_mode=$(get_ssh_host_key_checking)

    # Return options as newline-separated list
    echo "-o"
    echo "StrictHostKeyChecking=$host_key_mode"
    echo "-o"
    echo "ConnectTimeout=10"
}

# Build SSH command with standard security options
# Usage: ssh_cmd=($(build_ssh_command))
#        "${ssh_cmd[@]}" user@host "command"
build_ssh_command() {
    local host_key_mode
    host_key_mode=$(get_ssh_host_key_checking)

    echo "ssh"
    echo "-o"
    echo "StrictHostKeyChecking=$host_key_mode"
    echo "-o"
    echo "ConnectTimeout=10"
}

# Check if strict SSH mode is enabled
# Returns: 0 if strict, 1 if not
is_ssh_strict_mode() {
    [ "${NWP_SSH_STRICT:-0}" = "1" ]
}

################################################################################
# Security Documentation
################################################################################

# SSH Host Key Verification Modes:
#
# accept-new (default):
#   - Automatically accepts new host keys on first connection
#   - Subsequent connections verify against saved key
#   - Vulnerable to MITM on first connection only
#   - Convenient for development and testing
#
# yes (strict mode, NWP_SSH_STRICT=1):
#   - Only connects to hosts with known keys in known_hosts
#   - Rejects any unknown host key
#   - Maximum security, prevents MITM attacks
#   - Requires manual key management
#
# For production deployments, consider using NWP_SSH_STRICT=1 and
# pre-populating ~/.ssh/known_hosts with verified host keys.
#
# See docs/SECURITY.md for complete SSH security documentation.
