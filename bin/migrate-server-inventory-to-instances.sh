#!/usr/bin/env bash
# F33 Phase 2: copy each nwp/servers/<host>/ to nwp-instances/_servers/<host>/.
#
# Idempotent. Refuses to overwrite a non-empty destination unless --force.
# Does NOT delete the source.

set -euo pipefail

NWP_DIR="${NWP_DIR:-$HOME/nwp}"
NWP_INSTANCES_DIR="${NWP_INSTANCES_DIR:-$HOME/nwp-instances}"
FORCE="${1:-}"

if [[ ! -d "${NWP_DIR}/servers" ]]; then
  echo "ERROR: ${NWP_DIR}/servers does not exist" >&2
  exit 1
fi
mkdir -p "${NWP_INSTANCES_DIR}/_servers"

migrated=0
skipped=0
for src in "${NWP_DIR}"/servers/*/; do
  name=$(basename "${src}")
  dst="${NWP_INSTANCES_DIR}/_servers/${name}"

  if [[ -L "${src%/}" ]]; then
    echo "skip ${name}: already a symlink"
    skipped=$((skipped+1))
    continue
  fi

  if [[ -d "${dst}" ]] && [[ -n "$(ls -A "${dst}" 2>/dev/null)" ]]; then
    if [[ "${FORCE}" != "--force" ]]; then
      echo "skip ${name}: destination ${dst} exists; pass --force to overwrite"
      skipped=$((skipped+1))
      continue
    fi
    rm -rf "${dst}"
  fi

  echo "copy servers/${name}/ -> ${dst}/"
  cp -a "${src}" "${dst}/"
  migrated=$((migrated+1))
done

echo ""
echo "Done. ${migrated} server inventories copied; ${skipped} skipped."
