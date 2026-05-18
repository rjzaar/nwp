#!/usr/bin/env bash
# F33 §4.2 — locate the operator's private instance overlay (`nwp-instances/`).
#
# Resolution order:
#   1. $NWP_INSTANCES_DIR if set
#   2. $HOME/nwp-instances if it exists
#   3. ./sites/ (the legacy in-repo location), with a DEPRECATION warning
#
# Returns: prints the resolved directory path on stdout.
#          Returns 0 always (an empty stdout means "no instance dir found",
#          which is normal for a fresh contributor clone).
#
# Designed to be sourced or invoked. Idempotent. No side effects beyond
# the optional deprecation warning on stderr.
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
  local legacy="${script_dir}/sites"
  if [[ -d "${legacy}" ]]; then
    # Only fall back if the legacy dir contains real per-site content,
    # not just templates + README. Filter out *.example.* and README.
    local has_real_content
    has_real_content=$(ls -A "${legacy}" 2>/dev/null \
      | grep -v -E '^(README\.md|\.gitkeep|.+\.example\..*)$' \
      | head -1)
    if [[ -n "${has_real_content}" ]]; then
      printf '%s\n' "${legacy}"
      printf 'DEPRECATION: per-site config in sites/ is deprecated; move to %s/nwp-instances/ (see F33). This fallback will be removed in v1.0.0.\n' "${HOME}" >&2
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
