#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/ssd-rebuild.sh — rebuild the ssd Moodle demo half from source
# (ops#133 Phase 2)
#
# ssd is the Moodle consumer of the nwd↔ssd demo pair. Before Phase 2 it was
# stale: it carried only 2 of the 8 first-party plugins and its .nwp.yml named
# `auth_nwc_oauth2` — the LOCK-LESS DECOY that was deleted fleet-wide. The real
# consumer is `auth/nwc` in nwp/ss-moodle-plugins, which also carries the
# ops#118 Art.9 consent gate and the ops#93 privacy providers.
#
# This script is the repeatable "rebuild from code" leg the proposal asks for
# (§2.2 "a weekly full rebuild from code catches install-drift the golden image
# would mask"). It is IDEMPOTENT and DEV/STG ONLY.
#
#   scripts/demo/ssd-rebuild.sh [--site=ssd] [--tier=dev] [--ref=main] [--no-pull]
#
# What it does:
#   1. clone/pull nwp/ss-moodle-plugins into sites/<site>/.plugin-src/ (records
#      the resolved SHA — the rebuild is reproducible);
#   2. DECOY SWEEP (fail-loud): refuse to continue if auth_nwc_oauth2 exists in
#      the tree or in mdl_config_plugins;
#   3. rsync each <type>/<name> plugin into the Moodle root (the repo layout is
#      1:1 with a Moodle root, so no path rewriting) + .git/info/exclude hygiene
#      so the upstream moodle/moodle clone stops reporting them untracked;
#   4. admin/cli/upgrade.php --non-interactive, then purge_caches.php;
#   5. apply the DEMO POSTURE (noindex / mail-kill / banner / no self-signup).
#
# Guards (fail-closed):
#   * tier must be dev|stg — a Moodle prod/live rebuild goes through the
#     guarded `pl moodle plugin deploy --tier=live` path, never this script.
#   * refuses if the target is not a Moodle root (no version.php + lib/).
#   * refuses if the plugin source tree lacks a version.php for any manifest
#     entry (a truncated clone must not silently install half a plugin).
#   * refuses if any decoy trace is found and --allow-decoy is not passed
#     (there is no legitimate reason for one to exist).
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"

# Plugin source repo. Read from the site config (sites/<site>/.nwp.yml →
# moodle.plugins_repo), which is gitignored — no internal host is committed here.
# Resolved after the site is known; PLUGINS_REPO overrides for a one-off run.
PLUGINS_REPO="${PLUGINS_REPO:-}"

# The manifest: repo-relative <type>/<name> paths, 1:1 with the Moodle root.
SSD_PLUGINS=(
    auth/nwc
    course/format/tabbed
    local/browse
    local/feedback
    local/mentor
    local/nwc_copyright_sync
    local/practice
    mod/depthcontent
)

# The decoy. Never legitimate — see the ops#73 drift audit.
DECOY_DIR="auth/nwc_oauth2"
DECOY_PLUGIN="auth_nwc_oauth2"

SITE="ssd"
TIER="dev"
REF="main"
DO_PULL="true"
ALLOW_DECOY="false"

usage() {
    sed -n '3,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*)  SITE="${1#--site=}"; shift ;;
        --tier=*)  TIER="${1#--tier=}"; shift ;;
        --ref=*)   REF="${1#--ref=}"; REF_EXPLICIT=1; shift ;;
        --no-pull) DO_PULL="false"; shift ;;
        --allow-decoy) ALLOW_DECOY="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown option '$1'"; usage; exit 1 ;;
    esac
done

case "$TIER" in
    dev|stg) ;;
    *) print_error "REFUSED: tier '$TIER' — this rebuild is dev|stg only."
       print_info  "A live Moodle plugin change goes through 'pl moodle plugin deploy <site> … --tier=live' (guarded: freshness gate, deploy-gate, snapshot, rollback)."
       exit 1 ;;
esac

SITE_DIR="${PROJECT_ROOT}/sites/${SITE}"
MOODLE_ROOT="$(resolve_project "$SITE" "$TIER")" || {
    print_error "Cannot resolve $SITE ($TIER)"; exit 1
}
[[ -f "$MOODLE_ROOT/version.php" && -d "$MOODLE_ROOT/lib" ]] || {
    print_error "REFUSED: '$MOODLE_ROOT' is not a Moodle root (no version.php + lib/)."
    exit 1
}
[[ -d "$MOODLE_ROOT/.ddev" ]] || {
    print_error "REFUSED: no DDEV project at $MOODLE_ROOT"
    exit 1
}

if [[ -z "$PLUGINS_REPO" ]] && command -v yq >/dev/null 2>&1; then
    PLUGINS_REPO="$(yq e '.moodle.plugins_repo // ""' "${SITE_DIR}/.nwp.yml" 2>/dev/null)"
    [[ "$PLUGINS_REPO" == "null" ]] && PLUGINS_REPO=""
fi
[[ -n "$PLUGINS_REPO" ]] || {
    print_error "REFUSED: no plugin source repo (sites/${SITE}/.nwp.yml → moodle.plugins_repo, or \$PLUGINS_REPO)."
    exit 1
}
if [[ -z "${REF_EXPLICIT:-}" ]] && command -v yq >/dev/null 2>&1; then
    v="$(yq e '.moodle.plugins_ref // ""' "${SITE_DIR}/.nwp.yml" 2>/dev/null)"
    [[ -n "$v" && "$v" != "null" ]] && REF="$v"
fi

SRC_ROOT="${SITE_DIR}/.plugin-src/ss-moodle-plugins"

print_header "Rebuilding $SITE ($TIER) from ss-moodle-plugins@${REF}"
print_info "Moodle root: $MOODLE_ROOT"

################################################################################
# 1. Plugin source — clone or fetch, then detach at the requested ref.
################################################################################

if [[ ! -d "$SRC_ROOT/.git" ]]; then
    print_info "Cloning $PLUGINS_REPO → $SRC_ROOT"
    mkdir -p "$(dirname "$SRC_ROOT")"
    git clone -q "$PLUGINS_REPO" "$SRC_ROOT" || { print_error "clone failed"; exit 1; }
elif [[ "$DO_PULL" == "true" ]]; then
    print_info "Fetching $PLUGINS_REPO"
    git -C "$SRC_ROOT" fetch -q --all || { print_error "fetch failed"; exit 1; }
fi

if [[ "$DO_PULL" == "true" ]]; then
    git -C "$SRC_ROOT" checkout -q --detach "origin/${REF}" 2>/dev/null \
        || git -C "$SRC_ROOT" checkout -q --detach "$REF" \
        || { print_error "cannot check out ref '$REF'"; exit 1; }
fi

PLUGIN_SHA="$(git -C "$SRC_ROOT" rev-parse HEAD)"
print_status "OK" "Plugin source at ${REF} = ${PLUGIN_SHA:0:12}"

# Every manifest entry must really be a plugin — a truncated clone must never
# result in half a plugin being installed.
for p in "${SSD_PLUGINS[@]}"; do
    [[ -f "$SRC_ROOT/$p/version.php" ]] || {
        print_error "REFUSED: $SRC_ROOT/$p has no version.php — plugin source is incomplete."
        exit 1
    }
done
print_status "OK" "All ${#SSD_PLUGINS[@]} manifest plugins present in the source tree"

################################################################################
# 2. DECOY SWEEP — fail-loud. auth_nwc_oauth2 is the lock-less decoy.
################################################################################

decoy_found="false"
if [[ -e "$MOODLE_ROOT/$DECOY_DIR" ]]; then
    print_error "DECOY PRESENT: $MOODLE_ROOT/$DECOY_DIR"
    decoy_found="true"
fi
# Check the VALUE, not the prose: the .nwp.yml legitimately *names* the decoy
# in its notes ("this is NOT what we use"), and a naive grep would refuse on
# the very documentation that records the fix.
if [[ -f "$SITE_DIR/.nwp.yml" ]] && command -v yq >/dev/null 2>&1; then
    cfg_plugin="$(yq e '.oauth2.provider_plugin // ""' "$SITE_DIR/.nwp.yml" 2>/dev/null)"
    if [[ "$cfg_plugin" == "$DECOY_PLUGIN" ]]; then
        print_error "DECOY REFERENCE: $SITE_DIR/.nwp.yml oauth2.provider_plugin = $DECOY_PLUGIN (expected: auth_nwc)"
        decoy_found="true"
    fi
fi
decoy_rows="$( ( cd "$MOODLE_ROOT" && ddev mysql -N -e \
    "SELECT COUNT(*) FROM mdl_config_plugins WHERE plugin = '$DECOY_PLUGIN'" ) 2>/dev/null | tr -d '[:space:]' )"
if [[ "$decoy_rows" =~ ^[0-9]+$ ]] && (( decoy_rows > 0 )); then
    print_error "DECOY CONFIG in mdl_config_plugins: $decoy_rows row(s) for $DECOY_PLUGIN"
    decoy_found="true"
fi

if [[ "$decoy_found" == "true" && "$ALLOW_DECOY" != "true" ]]; then
    print_error "REFUSED: auth_nwc_oauth2 traces present. The decoy is lock-less (no UID-lock) and was removed fleet-wide."
    print_hint  "Remove them, then re-run. (--allow-decoy only for a deliberate forensic run.)"
    exit 1
fi
print_status "OK" "No auth_nwc_oauth2 decoy traces (tree, .nwp.yml, mdl_config_plugins)"

################################################################################
# 3. Overlay the plugins + .git/info/exclude hygiene.
################################################################################

EXCLUDE_FILE="$MOODLE_ROOT/.git/info/exclude"
for p in "${SSD_PLUGINS[@]}"; do
    dest="$MOODLE_ROOT/$p"
    mkdir -p "$(dirname "$dest")"
    rsync -a --delete --exclude='.git' --exclude='node_modules' \
        "$SRC_ROOT/$p/" "$dest/" || { print_error "rsync of $p failed"; exit 1; }
    # Upstream moodle/moodle clone must stop reporting first-party plugins as
    # untracked (Moodle's own guidance: .git/info/exclude, not .gitignore).
    if [[ -f "$EXCLUDE_FILE" ]] && ! grep -qxF "/$p/" "$EXCLUDE_FILE" 2>/dev/null; then
        printf '/%s/\n' "$p" >> "$EXCLUDE_FILE"
    fi
done
print_status "OK" "Overlaid ${#SSD_PLUGINS[@]} plugins into $MOODLE_ROOT"

# Record what was installed — the golden image is only reproducible if we know
# which commit produced it.
cat > "$SITE_DIR/.plugin-src/INSTALLED.json" <<EOF
{
  "repo": "$PLUGINS_REPO",
  "ref": "$REF",
  "sha": "$PLUGIN_SHA",
  "installed_utc": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "moodle_root": "$MOODLE_ROOT",
  "plugins": [$(printf '"%s",' "${SSD_PLUGINS[@]}" | sed 's/,$//')]
}
EOF
print_info "Recorded → $SITE_DIR/.plugin-src/INSTALLED.json"

################################################################################
# 4. Moodle upgrade + cache purge (Moodle 4.4 rejects PHP 8.4 → pin 8.3).
################################################################################

CLI_PHP="${CLI_PHP:-php8.3}"
print_info "Running admin/cli/upgrade.php (${CLI_PHP})…"
( cd "$MOODLE_ROOT" && ddev exec "$CLI_PHP -d max_input_vars=5000 admin/cli/upgrade.php --non-interactive" ) \
    || { print_error "Moodle upgrade failed"; exit 1; }
( cd "$MOODLE_ROOT" && ddev exec "$CLI_PHP admin/cli/purge_caches.php" ) >/dev/null \
    || print_warning "purge_caches failed (non-fatal)"
print_status "OK" "Moodle upgraded + caches purged"

################################################################################
# 5. Demo posture (§2.5): noindex, mail-kill, banner, no self-signup.
################################################################################

print_info "Applying demo posture…"
bash "$SCRIPT_DIR/ssd-demo-posture.sh" --site="$SITE" --tier="$TIER" || {
    print_error "Demo posture step failed"
    exit 1
}

print_status "OK" "ssd rebuild complete — plugins @ ${PLUGIN_SHA:0:12}"
print_hint "Next: scripts/demo/ssd-oidc-wire.sh (pair ssd to the nwd issuer), then 'pl demo golden nwd --with-pair'."
