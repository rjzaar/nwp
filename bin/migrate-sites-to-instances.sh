#!/usr/bin/env bash
# F33 Phase 2: copy each nwp/sites/<name>/ to nwp-instances/<name>/.
#
# Idempotent. Refuses to overwrite a non-empty destination unless --force.
# Does NOT delete the source — call symlink-sites-from-instances.sh next
# to replace the source with a symlink for backwards compatibility through
# F33 Phase 4. The destructive delete happens only at F33 Phase 5 / repo
# restart.

set -euo pipefail

NWP_DIR="${NWP_DIR:-$HOME/nwp}"
NWP_INSTANCES_DIR="${NWP_INSTANCES_DIR:-$HOME/nwp-instances}"
FORCE="${1:-}"

if [[ ! -d "${NWP_DIR}/sites" ]]; then
  echo "ERROR: ${NWP_DIR}/sites does not exist" >&2
  exit 1
fi
mkdir -p "${NWP_INSTANCES_DIR}"

migrated=0
skipped=0
for src in "${NWP_DIR}"/sites/*/; do
  name=$(basename "${src}")
  case "${name}" in
    tmp|vendor|latest|*_moodledata|20[0-9][0-9][0-9][0-9][0-9][0-9]T*) continue ;;
  esac
  dst="${NWP_INSTANCES_DIR}/${name}"

  if [[ -L "${src%/}" ]]; then
    echo "skip ${name}: already a symlink to $(readlink "${src%/}")"
    skipped=$((skipped+1))
    continue
  fi

  if [[ -d "${dst}" ]] && [[ -n "$(ls -A "${dst}" 2>/dev/null)" ]]; then
    if [[ "${FORCE}" != "--force" ]]; then
      echo "skip ${name}: destination ${dst} exists and is non-empty; pass --force to overwrite"
      skipped=$((skipped+1))
      continue
    fi
    rm -rf "${dst}"
  fi

  echo "copy sites/${name}/ -> ${dst}/"
  cp -a "${src}" "${dst}/"
  migrated=$((migrated+1))
done

echo ""
echo "Done. ${migrated} sites copied; ${skipped} skipped."
echo "Next: bin/symlink-sites-from-instances.sh"
