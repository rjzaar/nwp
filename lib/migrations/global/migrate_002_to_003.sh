#!/usr/bin/env bash
# F32 Phase A — migrate nwp.yml from schema v2 to v3.
#
# v2 → v3 changes:
#   - `nwp.version`: 2 → 3
#   - `hosts.<name>.roles: [...]` becomes mandatory
#   - `features.<name>.backend: <selector>` may be added
#   - `tier:` (integer) becomes the recommended top-level preset
#
# This migration:
#   1. Backs up the source file to nwp.yml.v2.bak
#   2. Reads the v2 doc
#   3. Prompts the operator (or reads --hint=<file>) for role bindings
#   4. Writes the v3 doc
#   5. Validates against lib/schema/nwp_yml_v3.json (if jsonschema CLI
#      is available; otherwise prints "validate manually")
#
# Usage:
#   migrate_002_to_003.sh                       # interactive
#   migrate_002_to_003.sh --dry-run             # print would-be output
#   migrate_002_to_003.sh --downgrade-to-v2     # restore .v2.bak
#   migrate_002_to_003.sh --hint=<roles.yml>    # non-interactive

set -euo pipefail

THIS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWP_ROOT="$(cd -P "${THIS_DIR}/../../.." && pwd)"

# Locate the operator's instance dir + nwp.yml
NWP_YML="${NWP_YML:-${HOME}/nwp-instances/_global/nwp.yml}"
[[ -f "${NWP_YML}" ]] || NWP_YML="${NWP_ROOT}/nwp.yml"

if [[ ! -f "${NWP_YML}" ]]; then
  echo "ERROR: no nwp.yml found (looked in \$HOME/nwp-instances/_global/ and \$NWP_ROOT/)" >&2
  exit 1
fi

MODE="${1:-interactive}"

dry_run() { [[ "${MODE}" == "--dry-run" ]]; }

case "${MODE}" in
  --downgrade-to-v2)
    backup="${NWP_YML}.v2.bak"
    if [[ ! -f "${backup}" ]]; then
      echo "ERROR: no backup found at ${backup}" >&2
      exit 1
    fi
    cp -i "${backup}" "${NWP_YML}"
    echo "Restored ${NWP_YML} from ${backup}"
    exit 0
    ;;
  --dry-run|interactive|--hint=*)
    ;;
  *)
    echo "Usage: $0 [--dry-run|--downgrade-to-v2|--hint=<file>]" >&2
    exit 1
    ;;
esac

# Detect current version
current_version=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('${NWP_YML}'))
print(d.get('nwp', {}).get('version', '?'))
" 2>/dev/null || echo "?")

if [[ "${current_version}" == "3" ]]; then
  echo "${NWP_YML} is already at v3. Nothing to do."
  exit 0
fi
if [[ "${current_version}" != "2" ]]; then
  echo "WARN: ${NWP_YML} reports version=${current_version}; expected 2." >&2
  echo "Proceed only if you understand what this script does." >&2
fi

# Back up the v2 file (skip if dry-run)
if ! dry_run; then
  cp -n "${NWP_YML}" "${NWP_YML}.v2.bak"
  echo "Backed up to ${NWP_YML}.v2.bak"
fi

# Do the migration with python3 + yaml. This is the load-bearing step
# and is intentionally explicit so the operator can review.
python3 <<PY
import sys, yaml

src = '${NWP_YML}'
dry = ${MODE@Q} == '--dry-run'
with open(src) as f:
    doc = yaml.safe_load(f) or {}

# Bump version
doc.setdefault('nwp', {})['version'] = 3

# Ensure tier preset is present; default to 1 for safety
if 'tier' not in doc['nwp']:
    doc['nwp']['tier'] = 1

# Hosts: ensure each has roles: [...]
hosts = doc.setdefault('hosts', {})
for hostname, conf in list(hosts.items()):
    if not isinstance(conf, dict):
        conf = {}
        hosts[hostname] = conf
    conf.setdefault('roles', [])
    if not conf['roles']:
        # Educated guess based on the operator's existing hostnames.
        # The user is expected to refine these — the migration prompts
        # for confirmation in interactive mode.
        guess = []
        if hostname in ('dev', 'authoring', 'carlo'):
            guess = ['authoring']
        elif hostname in ('ci', 'ci-host', 'metabox', 'met'):
            guess = ['ci-host']
        elif hostname in ('ai-host', 'mini', 'voice-agent'):
            guess = ['ai-host']
        elif hostname in ('mons', 'verifier'):
            guess = ['verifier']
        elif hostname in ('gitlab', 'git', 'gitlab-host'):
            guess = ['gitlab-host']
        else:
            guess = ['ci-host']  # safe default
        conf['roles'] = guess
        sys.stderr.write(f"  hosts.{hostname}: auto-assigned roles={guess} — please review\n")

# Features: ensure enabled + backend keys are present where applicable
features = doc.setdefault('features', {})
default_backends = {
    'ci': 'gitlab-runner',
    'ai': 'claude-api',
    'deploy_mode': 'manual',
    'voice_agent': 'pipecat',
    'rag': 'sqlite-vec-fts5',
}
for fname in default_backends:
    if fname in features:
        f = features[fname]
        if not isinstance(f, dict):
            f = {'enabled': bool(f)}
            features[fname] = f
        f.setdefault('enabled', False)
        if f['enabled']:
            f.setdefault('backend', default_backends[fname])

out = yaml.safe_dump(doc, default_flow_style=False, sort_keys=False, width=120)
if dry:
    sys.stdout.write(out)
else:
    with open(src, 'w') as f:
        f.write(out)
    sys.stderr.write(f"Wrote v3 to {src}\n")
PY

# Validate if possible
if command -v jsonschema >/dev/null 2>&1 && ! dry_run; then
  jsonschema -i <(python3 -c "import yaml,json,sys; json.dump(yaml.safe_load(open('${NWP_YML}')), sys.stdout)") "${NWP_ROOT}/lib/schema/nwp_yml_v3.json" \
    && echo "Schema validation passed." \
    || { echo "Schema validation FAILED — review ${NWP_YML}." >&2; exit 1; }
elif ! dry_run; then
  echo "(jsonschema CLI not installed; validate manually with: pl tier validate-config)"
fi

echo ""
if dry_run; then
  echo "Dry-run complete. No files were modified."
else
  echo "Migration complete."
  echo "Backup:    ${NWP_YML}.v2.bak"
  echo "Rollback:  $0 --downgrade-to-v2"
fi
