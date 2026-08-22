#!/usr/bin/env bash
# Locate the directory holding per-site configuration.
#
# `sites/` inside the repo is the PRIMARY per-site location (the F17/F23
# nested layout documented in CLAUDE.md). `~/nwp-instances` is an OPTIONAL
# private operator overlay (role manifest, _global config, _servers); when it
# exists it takes precedence so overlay users keep their current behaviour.
# (F33, which planned to deprecate sites/ in favour of the overlay, was
# SUPERSEDED, and NWP-ADR-0021 was rejected — sites/ is not deprecated.)
#
# Resolution order:
#   1. $NWP_INSTANCES_DIR if set
#   2. $HOME/nwp-instances if it exists (operator overlay)
#   3. ./sites/ (the primary in-repo location)
#
# Returns: prints the resolved directory path on stdout.
#          Returns 0 always (an empty stdout means "no instance dir found",
#          which is normal for a fresh contributor clone).
#
# Designed to be sourced or invoked. Idempotent. No side effects.
#
# Usage:
#   instance_dir=$(find_instance_dir)
#   if [[ -z "${instance_dir}" ]]; then
#     echo "No instance overlay found; run 'pl init' or set NWP_INSTANCES_DIR" >&2
#     exit 1
#   fi
#
# Tests: see tests/unit/find-instance-dir.bats

find_instance_dir() {
  if [[ -n "${NWP_INSTANCES_DIR:-}" ]]; then
    printf '%s\n' "${NWP_INSTANCES_DIR}"
    return 0
  fi
  if [[ -d "${HOME}/nwp-instances" ]]; then
    printf '%s\n' "${HOME}/nwp-instances"
    return 0
  fi
  # SCRIPT_DIR is set by the caller (typically pl itself).
  local script_dir="${SCRIPT_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../..}"
  local sites_dir="${script_dir}/sites"
  if [[ -d "${sites_dir}" ]]; then
    # Only resolve here if the dir contains real per-site content,
    # not just templates + README. Filter out *.example.* and README.
    local has_real_content
    has_real_content=$(ls -A "${sites_dir}" 2>/dev/null \
      | grep -v -E '^(README\.md|\.gitkeep|.+\.example\..*)$' \
      | head -1)
    if [[ -n "${has_real_content}" ]]; then
      printf '%s\n' "${sites_dir}"
      return 0
    fi
  fi
  # Nothing found — return empty stdout, success exit. Caller decides
  # whether to error out.
  return 0
}

# If invoked as a script (not sourced), print the path and exit.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  find_instance_dir
fi
