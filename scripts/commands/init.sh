#!/usr/bin/env bash
# NWP init — one-command install of all required software prerequisites.
#
# Non-interactive front door to `pl setup --auto`: installs Docker, Docker
# Compose, DDEV, PHP, Composer, mkcert (+CA), yq and the nwp CLI/config —
# everything needed to run pl on a fresh machine — then verifies with pl doctor.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

show_help() {
    cat <<'EOF'
pl init — install all required software prerequisites (non-interactive)

Installs everything pl needs on a fresh machine — Docker, Docker Compose, DDEV,
PHP, Composer, mkcert (+CA), yq, and the nwp CLI/config — via `pl setup --auto`,
then runs `pl doctor` to verify.

Usage:
  pl init            Install all prerequisites, then verify
  pl init --check    Just verify (run pl doctor; install nothing)
  pl init -h|--help  Show this help

Notes:
  - You'll be asked for your sudo password (apt / the installers need it).
  - If Docker is newly installed, log out and back in (or run 'newgrp docker')
    so the docker group takes effect, then re-run 'pl doctor'.
EOF
}

case "${1:-}" in
    -h|--help) show_help; exit 0 ;;
    --check)   exec "$PROJECT_ROOT/pl" doctor ;;
    "")        ;;
    *) echo "pl init: unknown option '$1'"; echo; show_help; exit 2 ;;
esac

echo "════════════════════════════════════════════════════════════"
echo "  pl init — installing all required prerequisites"
echo "════════════════════════════════════════════════════════════"
echo

"$PROJECT_ROOT/scripts/commands/setup.sh" --auto
rc=$?

echo
echo "──── verifying (pl doctor) ────"
"$PROJECT_ROOT/pl" doctor || true

echo
echo "If Docker was just installed, log out/in (or run 'newgrp docker') so the"
echo "docker group applies, then re-run: pl doctor"
exit $rc
