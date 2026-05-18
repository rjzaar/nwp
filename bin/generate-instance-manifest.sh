#!/usr/bin/env bash
# F33 §4.3: emit nwp-instances/instance-manifest.yml from current host config.
#
# Reads ~/.ssh/config and the operator's existing nwp.yml to discover
# hostnames, then prompts for role-label bindings. Idempotent — skips
# generation if a manifest already exists, unless --force.

set -euo pipefail

NWP_INSTANCES_DIR="${NWP_INSTANCES_DIR:-$HOME/nwp-instances}"
MANIFEST="${NWP_INSTANCES_DIR}/instance-manifest.yml"
FORCE="${1:-}"

if [[ -f "${MANIFEST}" ]] && [[ "${FORCE}" != "--force" ]]; then
  echo "${MANIFEST} already exists; pass --force to regenerate."
  exit 0
fi

mkdir -p "${NWP_INSTANCES_DIR}"

cat > "${MANIFEST}" <<'EOF'
# nwp-instances/instance-manifest.yml — PRIVATE
# Edit hostnames to match the operator's environment.
# Role labels are stable (per ADR-0020); bindings are per-deployment.

roles:
  authoring:           [<authoring-host>]
  ci-host:             [<ci-host>]
  build-host:          [<ci-host>]
  ai-host:             [<ai-host>]
  llm-host:            [<ai-host>]
  voice-agent:         [<voice-agent-host>]
  transcription-worker: [<ci-host>]
  transcription-gpu:   [<gpu-host>]
  mirror-store:        [<mirror-store-host>]
  rag-backend:         [<rag-host>]
  verifier:            [<verifier-host>]
  signed-deploy:       [<verifier-host>]
  gitlab-host:         [<gitlab-host>]
  prod-cluster:        [<prod-cluster-host>]

operator:
  legal-name:          <name>
  email:               <email>
  github:              <handle>
  jurisdiction:        <state, country>

domains:
  prod-base:           <example.org>
  ddev-base:           ddev.site
EOF

echo "Generated ${MANIFEST}"
echo "Edit it now to bind role labels to your actual hostnames."
