#!/usr/bin/env bash
# F33 §4.2 — high-level helpers for resolving per-site paths through the
# instance overlay.
#
# Source this from any `pl` subcommand that needs to read per-site
# configuration. It in turn sources find-instance-dir.sh and exposes:
#
#   instance_dir_or_die           — fail loudly if no instance dir found
#   site_path <name>              — absolute path to <instance>/<name>/
#   site_config_path <name>       — absolute path to <instance>/<name>/nwp.yml
#   site_secrets_path <name>      — absolute path to <instance>/<name>/.secrets.yml
#   instance_global_path <name>   — absolute path to <instance>/_global/<name>
#   instance_server_path <host>   — absolute path to <instance>/_servers/<host>/
#
# All return values are stable across the cutover between sites/<name>/
# and nwp-instances/<name>/.

# Resolve SCRIPT_DIR to find this dir; tolerant of being sourced from
# pl or from a test fixture.
__INSTANCE_PATHS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./find-instance-dir.sh
source "${__INSTANCE_PATHS_DIR}/find-instance-dir.sh"

instance_dir_or_die() {
  local dir
  dir=$(find_instance_dir)
  if [[ -z "${dir}" ]]; then
    echo "Error: no NWP instance directory found." >&2
    echo "       Set NWP_INSTANCES_DIR or create ~/nwp-instances (see F33)." >&2
    return 1
  fi
  printf '%s\n' "${dir}"
}

site_path() {
  local name="${1:?usage: site_path <name>}"
  local base
  base=$(instance_dir_or_die) || return $?
  printf '%s/%s\n' "${base}" "${name}"
}

site_config_path() {
  local name="${1:?usage: site_config_path <name>}"
  printf '%s/nwp.yml\n' "$(site_path "${name}")"
}

site_secrets_path() {
  local name="${1:?usage: site_secrets_path <name>}"
  printf '%s/.secrets.yml\n' "$(site_path "${name}")"
}

instance_global_path() {
  local name="${1:?usage: instance_global_path <name>}"
  local base
  base=$(instance_dir_or_die) || return $?
  printf '%s/_global/%s\n' "${base}" "${name}"
}

instance_server_path() {
  local host="${1:?usage: instance_server_path <host>}"
  local base
  base=$(instance_dir_or_die) || return $?
  printf '%s/_servers/%s\n' "${base}" "${host}"
}
