#!/bin/bash
#
# pl host — resolve a role label (or short alias) to its bound hostname(s).
#
# The role/hostname decoupling (ADR-0020 + docs/reference/role-vocabulary.md, F32)
# means code and docs refer to ROLES ("ci-host", "ver"), never raw box names.
# This is the ONE resolver from role -> hostname, reading the operator's private
# instance-manifest.yml. NO hostname is hardcoded here (leakage gate): every value
# comes from the manifest via yq. Boxes are multi-role, so a role may resolve to a
# host that also carries other roles — that's expected; the resolver is role-first.
#
# Usage:
#   pl host <role|alias>        print the hostname(s) bound to the role
#   pl host <role|alias> --all  same, all hosts if the role binds several
#   pl host --list              print the whole role -> host table
#   pl host --aliases           print the short-alias map
#   pl host -h|--help
#
# Env: NWP_INSTANCE_MANIFEST overrides the manifest path.
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"

MANIFEST="${NWP_INSTANCE_MANIFEST:-$HOME/nwp-instances/instance-manifest.yml}"
YQ="$(command -v yq || true)"

# short alias -> canonical role label (canonical labels per role-vocabulary.md)
_canon() {
    case "$1" in
        auth)  echo authoring ;;
        cih)   echo ci-host ;;
        bh)    echo build-host ;;
        aih)   echo ai-host ;;
        lmh)   echo llm-host ;;
        va)    echo voice-agent ;;
        tw)    echo transcription-worker ;;
        tg)    echo transcription-gpu ;;
        ms)    echo mirror-store ;;
        rag)   echo rag-backend ;;
        ver)   echo verifier ;;
        gh)    echo gitlab-host ;;
        prod)  echo prod-cluster ;;
        pa)    echo prod-agent ;;
        *)     echo "$1" ;;
    esac
}

show_help() {
    cat << EOF
${BOLD}pl host${NC} — resolve a role label (or short alias) to its hostname(s)

${BOLD}USAGE:${NC}
  pl host <role|alias>        print the hostname(s) bound to the role
  pl host <role|alias> --all  same (a role may bind several hosts)
  pl host --list              the whole role -> host table
  pl host --aliases           the short-alias map
  pl host -h|--help

Reads the private ${DIM}${MANIFEST/#$HOME/\~}${NC} (override: NWP_INSTANCE_MANIFEST).
Roles are the canonical vocabulary (docs/reference/role-vocabulary.md); boxes are
multi-role, so the same host answers for several roles.
EOF
}

_require() {
    [ -f "$MANIFEST" ] || { print_error "instance manifest not found: $MANIFEST"; exit 1; }
    [ -n "$YQ" ] || { print_error "yq is required (go-yq / mikefarah)"; exit 1; }
}

list_all() {
    _require
    print_header "Role -> host bindings"
    role="" "$YQ" e '.roles | to_entries | .[] | .key + "\t" + ((.value // []) | join(", "))' "$MANIFEST" \
        | while IFS=$'\t' read -r role hosts; do
            printf "  ${BOLD}%-20s${NC} %s\n" "$role" "${hosts:-${DIM}(unbound)${NC}}"
        done
    printf "\n  ${DIM}aliases: pl host --aliases${NC}\n"
}

list_aliases() {
    cat << EOF
  auth=authoring   cih=ci-host    bh=build-host   aih=ai-host   lmh=llm-host
  va=voice-agent   tw=transcription-worker        tg=transcription-gpu
  ms=mirror-store  rag=rag-backend                ver=verifier
  gh=gitlab-host   prod=prod-cluster              pa=prod-agent
EOF
}

resolve() {
    _require
    local in="$1" role hosts
    role="$(_canon "$in")"
    hosts="$(role="$role" "$YQ" e '.roles[strenv(role)] // [] | .[]' "$MANIFEST" 2>/dev/null || true)"
    if [ -z "$hosts" ]; then
        print_error "no host bound to role '$role'${role:+ (from '$in')}. Try: pl host --list"
        return 1
    fi
    echo "$hosts"
}

main() {
    case "${1:-}" in
        ""|-h|--help)  show_help ;;
        --list|list)   list_all ;;
        --aliases)     list_aliases ;;
        *)             resolve "$1" ;;   # --all is implied (all bound hosts printed)
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
