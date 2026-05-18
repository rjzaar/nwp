#!/usr/bin/env bash
# F33 Phase 3: replace each nwp/sites/<name>/ with a symlink to
# nwp-instances/<name>/ so tooling that uses the old path keeps working.
#
# Refuses to symlink over a non-empty source directory unless --force.
# (Use migrate-sites-to-instances.sh first to copy content to the overlay,
# then call this script.)

set -euo pipefail

NWP_DIR="${NWP_DIR:-$HOME/nwp}"
NWP_INSTANCES_DIR="${NWP_INSTANCES_DIR:-$HOME/nwp-instances}"
FORCE="${1:-}"

if [[ ! -d "${NWP_INSTANCES_DIR}" ]]; then
  echo "ERROR: ${NWP_INSTANCES_DIR} does not exist; run migrate-sites-to-instances.sh first" >&2
  exit 1
fi

linked=0
skipped=0
for dst in "${NWP_INSTANCES_DIR}"/*/; do
  name=$(basename "${dst}")
  case "${name}" in
    _global|_servers|_proposals-private) continue ;;
  esac

  src="${NWP_DIR}/sites/${name}"

  if [[ -L "${src}" ]]; then
    echo "skip ${name}: ${src} is already a symlink"
    skipped=$((skipped+1))
    continue
  fi

  if [[ -d "${src}" ]] && [[ -n "$(ls -A "${src}" 2>/dev/null)" ]]; then
    if [[ "${FORCE}" != "--force" ]]; then
      echo "skip ${name}: ${src} is a non-empty directory; pass --force to replace"
      skipped=$((skipped+1))
      continue
    fi
    rm -rf "${src}"
  fi

  ln -s "${dst%/}" "${src}"
  echo "symlinked ${src} -> ${dst%/}"
  linked=$((linked+1))
done

echo ""
echo "Done. ${linked} sites symlinked; ${skipped} skipped."
