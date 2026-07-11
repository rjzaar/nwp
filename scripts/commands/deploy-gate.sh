#!/usr/bin/env bash
# NWP Deploy Gate - status and self-test for the hardware+signature gate (ADR-0028/ops#79)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/deploy-gate.sh"

################################################################################
# Help Function
################################################################################

show_help() {
    cat << 'EOF'
Usage: pl deploy-gate <command>

Inspect and self-test the hardware+signature deploy gate (ADR-0028).
The gate requires a live Solo touch (ed25519-sk signature verified against
keys/allowed_signers) before any prod-write verb proceeds. It is a no-op
until configured, so the AI test tier is unaffected.

Commands:
    status    Show whether the gate is configured (which files exist, resolved
              paths) and whether fail-closed REQUIRE is enforced (and how).
    test      Run the full sign -> find-principals -> verify round-trip via
              deploy_gate_require (site=test target=test). Demos the Solo
              touch WITHOUT deploying anything. Exits nonzero on failure.

Options:
    -h, --help    Show this help message

Configuration (env overrides; see lib/deploy-gate.sh):
    NWP_DEPLOY_ALLOWED_SIGNERS   default: $PROJECT_ROOT/keys/allowed_signers
    NWP_DEPLOY_SK_KEY            default: ~/.ssh/id_ed25519_sk
    NWP_DEPLOY_GATE_REQUIRE      "true" => unconfigured gate fails CLOSED
    (REQUIRE can also be pinned by /etc/nwp/deploy-gate-require or
     keys/deploy-gate.require — marker files survive env stripping.)

Examples:
    pl deploy-gate status    # Is the gate configured/enforced on this host?
    pl deploy-gate test      # Touch the Solo, verify the signature, no deploy

EOF
}

################################################################################
# Commands
################################################################################

cmd_status() {
    print_header "Deploy Gate Status (ADR-0028)"

    local signers sk
    signers="$(_dg_allowed_signers)"
    sk="$(_dg_sk_key)"

    # Configuration files
    if [ -f "$signers" ]; then
        print_status "OK" "allowed_signers: $signers"
    else
        print_status "WARN" "allowed_signers: $signers (missing)"
    fi

    if [ -f "$sk" ]; then
        print_status "OK" "signing key:     $sk"
    else
        print_status "WARN" "signing key:     $sk (missing)"
    fi

    # Overall configured state
    if deploy_gate_configured; then
        print_status "OK" "Gate CONFIGURED — prod-write verbs will require a Solo touch"
    else
        print_status "INFO" "Gate NOT configured — prod-write verbs proceed without it (no-op)"
    fi

    # REQUIRE (fail-closed-when-unconfigured) enforcement, and via which mechanism
    local require_via=""
    if [ "${NWP_DEPLOY_GATE_REQUIRE:-false}" = "true" ]; then
        require_via="env var NWP_DEPLOY_GATE_REQUIRE=true"
    fi
    if [ -e /etc/nwp/deploy-gate-require ]; then
        require_via="${require_via:+$require_via, }marker file /etc/nwp/deploy-gate-require"
    fi
    if [ -e "$PROJECT_ROOT/keys/deploy-gate.require" ]; then
        require_via="${require_via:+$require_via, }marker file keys/deploy-gate.require"
    fi

    if [ -n "$require_via" ]; then
        print_status "OK" "REQUIRE enforced (unconfigured gate fails CLOSED) via: $require_via"
    else
        print_status "INFO" "REQUIRE not enforced — an unconfigured gate is a no-op (fail-open)"
        print_info "On ver, pin fail-closed with: sudo touch /etc/nwp/deploy-gate-require"
    fi

    # Verdict line
    echo ""
    if deploy_gate_configured; then
        print_status "OK" "Verdict: gate ACTIVE. Try it: pl deploy-gate test"
    elif [ -n "$require_via" ]; then
        print_status "FAIL" "Verdict: gate REQUIRED but unconfigured — prod-write verbs will ABORT"
    else
        print_status "INFO" "Verdict: gate inactive (test-tier default)"
    fi
    return 0
}

cmd_test() {
    print_header "Deploy Gate Self-Test (no deploy)"

    if ! deploy_gate_configured; then
        print_error "Gate not configured — nothing to test."
        print_info "Need both: $(_dg_allowed_signers) and $(_dg_sk_key)"
        print_info "Run 'pl deploy-gate status' for details."
        return 1
    fi

    print_info "Running the full sign -> find-principals -> verify round-trip."
    print_info "Nothing will be deployed; this only exercises the gate."

    if deploy_gate_require "test" "test" "gate self-test (no deploy)"; then
        echo ""
        print_status "OK" "Self-test PASSED — Solo touch + signature verification work end-to-end"
        return 0
    else
        echo ""
        print_status "FAIL" "Self-test FAILED — see the gate output above for the reason"
        return 1
    fi
}

################################################################################
# Main
################################################################################

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        status) cmd_status ;;
        test) cmd_test ;;
        -h|--help|help|"") show_help ;;
        *)
            print_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
