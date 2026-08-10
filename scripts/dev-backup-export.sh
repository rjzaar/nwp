#!/bin/bash
################################################################################
# scripts/dev-backup-export.sh — build (and optionally push) the dev
# laptop's curated backup export (ops#330).
#
# The ops#330 audit found the dev laptop (dev) has NO scheduled backup and
# holds singleton state the estate cannot run without: private/ (registry +
# operational records), the full .secrets.yml, the servers/* local repos,
# sites/*/backups, classes/, and ~/central. The operator ruling (2026-08-09)
# is a met→laptop PULL route on the proven rrsync-ro + restic pattern, plus
# presence on all three of laptop/met/agent-host until external drives arrive.
#
# THIS script is the laptop half. It builds a HARDLINK FARM at
# ~/.nwp-backup-export containing exactly the curated set — and nothing else —
# so the inbound met key can be jailed to ONE directory with
# `rrsync -ro <export>` (rrsync scopes a single root, and scoping the key to
# $HOME or to ~/nwp would hand met the deny-tier files: .secrets.data.yml,
# keys/prod_*). Hardlinks, not symlinks, because rrsync DISABLES -L on the
# server side (verified 2026-08-09: "option -L has been disabled"), and not
# copies, because the laptop has ~10 GB free against an ~13 GB set. Same
# filesystem, so the farm costs metadata only.
#
# The farm contains:
#   nwp-private/      ← ~/nwp/private       (registry, deploy/rollback ledgers)
#   nwp-servers/      ← ~/nwp/servers       (per-server repos, incl. nwpcode)
#   nwp-classes/      ← ~/nwp/classes
#   secrets.yml       ← ~/nwp/.secrets.yml  (infra tier ONLY — the AI-readable
#                                            tier; .secrets.data.yml is deny-
#                                            tier and is asserted ABSENT)
#   sites-backups/<s>/← ~/nwp/sites/<s>/backups (dev-tier DB snapshots)
#   central/          ← ~/central           (operator docs. Included by the
#                       2026-08-09 ruling: it is the operator knowledge base
#                       and existed nowhere else; it lands on met INSIDE the
#                       encrypted restic repo — backup, not replication)
#   demo-registry/    ← pulled FROM the agent host (the invite-code registry home) so a
#                       third host holds the registry (agent-host=home, met=pull,
#                       laptop=this)
#
# --push: until the operator enables sshd on the laptop the met→laptop PULL
# leg cannot run, so this pushes the farm to met's staging (and a small core
# to the agent host) over the laptop's existing outbound ssh. The met puller prefers
# its own pull and uses the pushed staging only while it is FRESH (see
# met-dr-pull.sh). When the pull leg is armed the push becomes a no-op
# double-write of identical bytes; removing it then is an operator tidy-up.
#
# Fail-closed: a missing curated path is exit 2 CANNOT EXPORT, never a
# quietly smaller backup. Everything is NWP_*-overridable for tests.
################################################################################
set -uo pipefail

EXPORT_DIR="${NWP_DEV_EXPORT_DIR:-$HOME/.nwp-backup-export}"
NWP_ROOT="${NWP_DEV_NWP_ROOT:-$HOME/nwp}"
CENTRAL="${NWP_DEV_CENTRAL:-$HOME/central}"
MINI_SRC="${NWP_DEV_MINI_SRC:-rob@100.64.0.2}"   # agent host (registry home), headscale addr
MINI_REG_SITE="${NWP_DEV_MINI_REG_SITE:-nwd}"
PUSH_DEST="${NWP_DEV_PUSH_DEST:-rob@100.64.0.3:nwp-dr/staging-dev}"
MINI_CORE_DEST="${NWP_DEV_MINI_CORE_DEST:-rob@100.64.0.2:nwp-backup-set/dev-core}"
RSYNC="${NWP_DEV_RSYNC:-rsync}"

# Junk that never belongs in a backup.
EXCLUDES=(--exclude='__pycache__/' --exclude='*.pyc' --exclude='node_modules/'
          --exclude='.cache/' --exclude='.venv/' --exclude='*.tmp'
          --exclude='.token-audit-cache')

do_push=false
for a in "$@"; do
    case "$a" in
        --push) do_push=true ;;
        -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown option '$a'" >&2; exit 1 ;;
    esac
done

err=0

die_cannot() { echo "ERROR: CANNOT EXPORT — $*" >&2; exit 2; }

# --- preflight: the curated set must exist in full --------------------------
[[ -d "$NWP_ROOT/private" ]]      || die_cannot "$NWP_ROOT/private missing"
[[ -d "$NWP_ROOT/servers" ]]      || die_cannot "$NWP_ROOT/servers missing"
[[ -d "$NWP_ROOT/classes" ]]      || die_cannot "$NWP_ROOT/classes missing"
[[ -f "$NWP_ROOT/.secrets.yml" ]] || die_cannot "$NWP_ROOT/.secrets.yml missing"
[[ -d "$CENTRAL" ]]               || die_cannot "$CENTRAL missing"

mkdir -p "$EXPORT_DIR"

# --- hardlink farm ----------------------------------------------------------
link_tree() { # src dst
    local src="$1" dst="$2"
    mkdir -p "$dst"
    "$RSYNC" -a --delete --link-dest="$src" "${EXCLUDES[@]}" "$src/" "$dst/" \
        || die_cannot "farm build failed for $src"
}

link_tree "$NWP_ROOT/private" "$EXPORT_DIR/nwp-private"
link_tree "$NWP_ROOT/servers" "$EXPORT_DIR/nwp-servers"
link_tree "$NWP_ROOT/classes" "$EXPORT_DIR/nwp-classes"
link_tree "$CENTRAL"          "$EXPORT_DIR/central"

# single file: hardlink (same fs), refreshed unconditionally
ln -f "$NWP_ROOT/.secrets.yml" "$EXPORT_DIR/secrets.yml" \
    || die_cannot "hardlink of .secrets.yml failed"

# per-site backups (a site without backups/ simply has none yet — skipped)
mkdir -p "$EXPORT_DIR/sites-backups"
for d in "$NWP_ROOT"/sites/*/backups; do
    [[ -d "$d" ]] || continue
    site="$(basename "$(dirname "$d")")"
    link_tree "$d" "$EXPORT_DIR/sites-backups/$site"
done
# drop farm entries for sites that no longer exist
for d in "$EXPORT_DIR"/sites-backups/*/; do
    [[ -d "$d" ]] || continue
    site="$(basename "$d")"
    [[ -d "$NWP_ROOT/sites/$site/backups" ]] || rm -rf "$d"
done

# --- third copy of the invite-code registry (home = agent host, pull = met) -------
if [[ "${NWP_DEV_SKIP_MINI:-0}" != "1" ]]; then
    mkdir -p "$EXPORT_DIR/demo-registry/$MINI_REG_SITE"
    if ! "$RSYNC" -a --timeout=60 \
            --include='demo-codes*' --include='demo-reset.log' --exclude='*' \
            -e "ssh -o BatchMode=yes -o ConnectTimeout=20" \
            "${MINI_SRC}:nwp/sites/${MINI_REG_SITE}/" \
            "$EXPORT_DIR/demo-registry/$MINI_REG_SITE/"; then
        echo "ERROR: demo-registry pull from the registry home failed — the laptop copy of the registry is NOT refreshed" >&2
        err=1
    fi
fi

# --- deny-tier assertion: the farm must never widen -------------------------
# The whole point of the farm is that the inbound key reads THIS and only
# this. If a deny-tier name ever appears here the export is wrong, whatever
# put it there.
bad="$(find "$EXPORT_DIR" \( -name '.secrets.data.yml' -o -name 'prod_*' -o -name 'keys' \) -print -quit)"
[[ -z "$bad" ]] || die_cannot "deny-tier path in export: $bad"

echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') export refreshed at $EXPORT_DIR"

# --- optional push legs -----------------------------------------------------
push_and_verify() { # dest, spot-file (relative to dest), spot-src (local), src... (rsync sources)
    local dest="$1" spot="$2" spotsrc="$3"; shift 3
    local host path lsha rsha
    if [[ "$dest" == *:* ]]; then host="${dest%%:*}"; path="${dest#*:}"; else host=""; path="$dest"; fi
    # the destination dir must exist before rsync can land in it
    if [[ -n "$host" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=20 "$host" "mkdir -p '$path'" \
            || { echo "ERROR: cannot create $dest — that host does NOT hold today's set" >&2; return 1; }
    else
        mkdir -p "$path"
    fi
    if ! "$RSYNC" -a --delete --timeout=300 "${EXCLUDES[@]}" \
            ${host:+-e "ssh -o BatchMode=yes -o ConnectTimeout=20"} \
            "$@" "$dest/"; then
        echo "ERROR: push to $dest failed — that host does NOT hold today's set" >&2
        return 1
    fi
    lsha="$(sha256sum "$spotsrc" | cut -d' ' -f1)"
    if [[ -n "$host" ]]; then
        ssh -o BatchMode=yes "$host" "touch '$path/.pushed-at'"
        rsha="$(ssh -o BatchMode=yes "$host" "sha256sum '$path/$spot'" 2>/dev/null | cut -d' ' -f1)"
    else
        touch "$path/.pushed-at"
        rsha="$(sha256sum "$path/$spot" | cut -d' ' -f1)"
    fi
    if [[ -z "$lsha" || "$lsha" != "$rsha" ]]; then
        echo "ERROR: push to $dest sha256 MISMATCH for $spot (${lsha:0:12}… != ${rsha:0:12}…)" >&2
        return 1
    fi
    echo "  ✓ pushed → $dest ($spot sha256 verified: ${lsha:0:12}…)"
}

if [[ "$do_push" == "true" ]]; then
    push_and_verify "$PUSH_DEST" "secrets.yml" "$EXPORT_DIR/secrets.yml" \
        "$EXPORT_DIR/" || err=1
    if [[ "${NWP_DEV_SKIP_PUSH_MINI:-0}" != "1" ]]; then
        # agent-host core: private + servers + classes only. Deliberately NOT
        # secrets.yml (registry D2: backup, don't replicate the full token set
        # to an AI host) and NOT central (operator-private: encrypted backup
        # on met, no plaintext replicas on AI hosts).
        push_and_verify "$MINI_CORE_DEST" \
            "nwp-private/secrets-registry.yml" \
            "$EXPORT_DIR/nwp-private/secrets-registry.yml" \
            "$EXPORT_DIR/nwp-private" "$EXPORT_DIR/nwp-servers" "$EXPORT_DIR/nwp-classes" || err=1
    fi
fi

exit "$err"
