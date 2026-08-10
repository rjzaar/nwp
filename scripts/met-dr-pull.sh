#!/bin/bash
################################################################################
# scripts/met-dr-pull.sh — met's USER-LEVEL DR puller: dev laptop + the
# LIVE box → restic (ops#330).
#
# Two sources, one pattern (the same rsync-pull → restic → verify shape as
# the root-level /etc/cron.d/nwp-dr-pull that covers the git box):
#
#   dev  the dev laptop's curated export (see dev-backup-export.sh).
#          Pull via the single-purpose read-only key ~/.ssh/nwp-dev-pull,
#          jailed on the laptop to `rrsync -ro ~/.nwp-backup-export`. Until
#          the operator enables sshd on the laptop the pull leg cannot
#          connect; the laptop pushes the identical set nightly, and this
#          script falls back to that pushed staging ONLY while it is fresh
#          (<26 h). A stale push is a failed backup, said loudly — never a
#          quiet snapshot of old bytes dressed up as tonight's.
#
#   live   the LIVE box's own nightly /var/backups/nwp-pull (nwd/ssd/nwc/ss
#          site DBs + nginx state, produced 01:30 by nwp-box-backup.sh).
#          The ops#329 D3/D5 research proved this dir had NO off-box
#          consumer — the dr-pull and stick crons pull only the git box.
#          met's existing ~/.ssh/nwp-dr-pull key is ALREADY authorized on
#          the live box (tracked in servers/live/system/authorized-keys,
#          rrsync -ro jail), so this leg adds zero new credentials.
#
# WHY USER-LEVEL: rob on met has no passwordless sudo, so this route cannot
# extend /etc/cron.d/nwp-dr-pull or write /srv/nwp-dr. It is a SIBLING of
# that layout under $HOME (staging-*/ + repo/), with its own password file.
# The operator may later fold it into /srv/nwp-dr so the 03:15 stick pull
# carries it too — flagged in the MR, one sudo mv + cron edit.
#
# VERIFICATION IS THE POINT. After each snapshot the script re-reads the
# repo and fails RED unless (a) the newest snapshot for the tag is recent
# and (b) its stats are plausibly sized (file count + bytes ≥ per-source
# floors). A backup that silently stops is the failure mode that matters;
# every failure here exits non-zero (cron mail) and, on state change, posts
# to the walled ops-log project using the same token as the nightly audit
# (never on argv — 0600 curl config).
#
# Exit codes: 0 backed up + verified · 1 backup/verify FAILED · 2 CANNOT
# (precondition missing — key, repo, password file; fail closed, never 0).
################################################################################
set -uo pipefail

BASE="${NWP_DR_BASE:-$HOME/nwp-dr}"
RESTIC="${NWP_DR_RESTIC:-restic}"
RSYNC="${NWP_DR_RSYNC:-rsync}"
PW_FILE="${NWP_DR_PW_FILE:-$HOME/.nwp-dr-user-restic-pw}"
REPO="$BASE/repo"

DEV_SRC="${NWP_DR_DEV_SRC:-rob@100.64.0.1:}"        # laptop, headscale addr
DEV_KEY="${NWP_DR_DEV_KEY:-$HOME/.ssh/nwp-dev-pull}"
# The LIVE box address never appears in tracked content (leakage gate). It is
# read from the tracked-on-host route file servers/live/.nwp-server.yml
# (gitignored), or env-injected by the cron line — fail closed otherwise.
live_src_default() {
    local f="$HOME/nwp/servers/live/.nwp-server.yml" ip user
    [[ -r "$f" ]] || return 1
    ip="$(sed -n 's/^[[:space:]]*ip:[[:space:]]*//p' "$f" | head -1)"
    user="$(sed -n 's/^[[:space:]]*ssh_user:[[:space:]]*//p' "$f" | head -1)"
    [[ -n "$ip" && -n "$user" ]] || return 1
    printf '%s@%s:' "$user" "$ip"
}
LIVE_SRC="${NWP_DR_LIVE_SRC:-$(live_src_default || true)}"   # rrsync-jailed to /var/backups/nwp-pull
LIVE_KEY="${NWP_DR_LIVE_KEY:-$HOME/.ssh/nwp-dr-pull}"

MAX_STAGING_AGE_HOURS="${NWP_DR_MAX_STAGING_AGE_HOURS:-26}"
VERIFY_MAX_AGE_MIN="${NWP_DR_VERIFY_MAX_AGE_MIN:-90}"
MIN_FILES_DEV="${NWP_DR_MIN_FILES_DEV:-100}"
MIN_BYTES_DEV="${NWP_DR_MIN_BYTES_DEV:-500000000}"    # curated set ≈ 13 GB
MIN_FILES_LIVE="${NWP_DR_MIN_FILES_LIVE:-20}"
MIN_BYTES_LIVE="${NWP_DR_MIN_BYTES_LIVE:-100000000}"      # box nightly ≈ 400 MB

TOKEN_FILE="${NWP_DR_TOKEN_FILE:-$HOME/.config/met-audit.token}"
GITLAB_HOST="${NWP_GITLAB_HOST:-<gitlab-host>}"   # placeholder by policy; cron env-injects the real host
OPS_LOG_PROJECT="${NWP_OPS_LOG_PROJECT:-11}"

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

# Post a note to the ops-log project on FAILURE, once per state change.
# Token via 0600 curl config, never argv. Non-fatal if it cannot post — the
# non-zero exit is the continuous signal, this is the rate-limited one.
notify() { # msg
    [[ "${NWP_DR_NO_NOTIFY:-0}" == "1" ]] && return 0
    local msg="$1" state_file="$BASE/.last-status"
    [[ "$GITLAB_HOST" == *"<"* ]] && { log "WARN: NWP_GITLAB_HOST not set — failure NOT posted to ops-log"; return 0; }
    [[ -r "$TOKEN_FILE" ]] || return 0
    if [[ -f "$state_file" ]] && [[ "$(cat "$state_file")" == "$msg" ]]; then
        return 0
    fi
    echo "$msg" > "$state_file"
    local cfg; cfg="$(mktemp)"; chmod 600 "$cfg"
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$(cat "$TOKEN_FILE")" > "$cfg"
    curl -sf --config "$cfg" --max-time 30 \
        --data-urlencode "title=met-dr-pull FAILED: ${msg:0:120}" \
        --data-urlencode "description=$(hostname): $msg — see ~/logs/met-dr-pull.log. Route: ops#330." \
        "https://${GITLAB_HOST}/api/v4/projects/${OPS_LOG_PROJECT}/issues" >/dev/null \
        || log "WARN: could not post failure note to ops-log"
    rm -f "$cfg"
}

clear_fail_state() { rm -f "$BASE/.last-status"; }

die_cannot() { log "ERROR: CANNOT back up — $*"; exit 2; }
fail_loud()  { log "ERROR: $*"; notify "$*"; exit 1; }

# --- preconditions (fail closed — an unmeasurable route is never healthy) ---
require_repo() {
    [[ -f "$REPO/config" ]] || die_cannot "restic repo $REPO not initialised (run install-dev-backup.sh); refusing to invent one here"
    [[ -r "$PW_FILE" ]]     || die_cannot "restic password file $PW_FILE missing/unreadable"
}

restic_cmd() { "$RESTIC" -r "$REPO" --password-file "$PW_FILE" "$@"; }

json_field() { # file jq-ish field via python3 (no jq dependency)
    python3 -c '
import json,sys
data=json.load(open(sys.argv[1]))
node=data[0] if isinstance(data,list) else data
print(node[sys.argv[2]])' "$1" "$2" 2>/dev/null
}

# --- acquire ----------------------------------------------------------------

pull_dev() {
    [[ -r "$DEV_KEY" ]] || die_cannot "transport key $DEV_KEY not readable"
    mkdir -p "$BASE/staging-dev"
    if "$RSYNC" -a --delete --timeout=300 \
        -e "ssh -i $DEV_KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=20" \
        "$DEV_SRC" "$BASE/staging-dev/"; then
        touch "$BASE/staging-dev/.pulled-at"
        log "dev: pulled from $DEV_SRC (pull leg)"
        return 0
    fi
    # Pull leg down (expected until the operator enables sshd on the laptop).
    # The pushed staging stands in ONLY while fresh.
    local marker="$BASE/staging-dev/.pushed-at" age_s
    if [[ ! -f "$marker" ]]; then
        fail_loud "dev pull from $DEV_SRC failed and no pushed staging exists — the laptop is NOT backed up tonight"
    fi
    age_s=$(( $(date +%s) - $(stat -c %Y "$marker") ))
    if (( age_s > MAX_STAGING_AGE_HOURS * 3600 )); then
        fail_loud "dev pull failed and pushed staging is STALE ($((age_s/3600))h > ${MAX_STAGING_AGE_HOURS}h) — old bytes are not tonight's backup"
    fi
    log "dev: pull leg down; using FRESH pushed staging ($((age_s/60)) min old) — push-fallback"
}

pull_live() {
    [[ -n "$LIVE_SRC" ]] || die_cannot "live box source unknown — no servers/live/.nwp-server.yml and no NWP_DR_LIVE_SRC"
    [[ -r "$LIVE_KEY" ]] || die_cannot "transport key $LIVE_KEY not readable"
    mkdir -p "$BASE/staging-live"
    if ! "$RSYNC" -a --delete --timeout=300 \
        -e "ssh -i $LIVE_KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=yes" \
        "$LIVE_SRC" "$BASE/staging-live/"; then
        fail_loud "live-box pull from $LIVE_SRC failed — the live box nightly is NOT backed up off-box tonight"
    fi
    log "live: pulled from $LIVE_SRC"
    grade_producer_verdict "$BASE/staging-live" live
}

# --- the PRODUCER's own verdict (nwp/ops#332) -------------------------------
#
# Size and age alone cannot see a HALF-DONE night. On 2026-08-04 the box
# nightly's site-DB leg started failing; the script logged "done" and exited 0,
# and the pull side would have snapshotted a tree that still contained fresh
# gitlab/ and nginx/ files — plausible count, plausible bytes, no databases.
# The producer now writes backup-verdict.json saying which legs actually ran, so
# this side grades a stated verdict instead of re-deriving one from file counts.
#
# ABSENT IS NOT OK. A missing verdict means the box is running a producer older
# than ops#332, i.e. one that cannot tell success from silence — exactly the
# thing that must not pass quietly.
grade_producer_verdict() { # <staging-dir> <label>
    local dir="$1" label="$2" f="$1/backup-verdict.json" verdict finished age_s
    if [[ ! -r "$f" ]]; then
        fail_loud "${label}: no backup-verdict.json in tonight's pull — the box is running a pre-ops#332 producer that cannot report a failed leg. Fix with: pl host apply ${label} --kind=backup --execute"
    fi
    verdict="$(sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([a-z-]*\)".*/\1/p' "$f" | head -1)"
    finished="$(sed -n 's/.*"finished_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)"
    case "$verdict" in
        ok) : ;;
        failed)
            fail_loud "${label}: the box producer reported verdict=FAILED — $(tr -d '\n' < "$f" | sed 's/.*"errors"[[:space:]]*:[[:space:]]*\[//; s/\].*//' | cut -c1-400)" ;;
        cannot-verify)
            fail_loud "${label}: the box producer reported verdict=CANNOT-VERIFY (a leg is undeclared and unmeasurable) — $(tr -d '\n' < "$f" | sed 's/.*"errors"[[:space:]]*:[[:space:]]*\[//; s/\].*//' | cut -c1-400)" ;;
        *)
            fail_loud "${label}: backup-verdict.json carries no readable verdict ('${verdict:-empty}') — an unparseable verdict is not a pass" ;;
    esac
    age_s=$(( $(date +%s) - $(date -d "${finished:-1970-01-01}" +%s 2>/dev/null || echo 0) ))
    if (( age_s > MAX_STAGING_AGE_HOURS * 3600 || age_s < 0 )); then
        fail_loud "${label}: the box producer's verdict is ${finished:-unreadable} ($((age_s/3600))h old > ${MAX_STAGING_AGE_HOURS}h) — tonight's nightly did not run; yesterday's OK is not tonight's"
    fi
    log "${label}: producer verdict OK (finished ${finished}, $((age_s/60)) min ago)"
}

# --- snapshot + verify ------------------------------------------------------

snapshot() { # tag dir
    local tag="$1" dir="$2"
    restic_cmd backup --tag "$tag" "$dir" \
        || fail_loud "restic backup --tag $tag failed"
    restic_cmd forget --tag "$tag" --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune \
        || log "WARN: restic forget/prune for $tag failed (snapshot itself succeeded)"
}

verify() { # tag min_files min_bytes
    local tag="$1" min_files="$2" min_bytes="$3" tmp id when age_s files bytes
    tmp="$(mktemp -d)"
    restic_cmd snapshots --json --tag "$tag" --latest 1 > "$tmp/snap.json" 2>/dev/null \
        || { rm -rf "$tmp"; fail_loud "SANITY: cannot list snapshots for tag $tag"; }
    id="$(json_field "$tmp/snap.json" id)"
    when="$(json_field "$tmp/snap.json" time)"
    if [[ -z "$id" || -z "$when" ]]; then
        rm -rf "$tmp"; fail_loud "SANITY: no snapshot found for tag $tag after backup"
    fi
    age_s=$(( $(date +%s) - $(date -d "$when" +%s 2>/dev/null || echo 0) ))
    if (( age_s > VERIFY_MAX_AGE_MIN * 60 || age_s < 0 )); then
        rm -rf "$tmp"; fail_loud "SANITY: newest '$tag' snapshot is $((age_s/60)) min old (> ${VERIFY_MAX_AGE_MIN}) — tonight's backup did not land"
    fi
    restic_cmd stats --json "$id" > "$tmp/stats.json" 2>/dev/null \
        || { rm -rf "$tmp"; fail_loud "SANITY: cannot stat snapshot $id"; }
    files="$(json_field "$tmp/stats.json" total_file_count)"
    bytes="$(json_field "$tmp/stats.json" total_size)"
    rm -rf "$tmp"
    if [[ -z "$files" || -z "$bytes" ]] || (( files < min_files || bytes < min_bytes )); then
        fail_loud "SANITY: '$tag' snapshot implausibly small (files=${files:-?} < $min_files or bytes=${bytes:-?} < $min_bytes)"
    fi
    log "verified '$tag': snapshot ${id:0:8} — $files files, $bytes bytes, $((age_s/60)) min old"
}

# --- main -------------------------------------------------------------------

what="${1:-all}"
require_repo

case "$what" in
    dev)
        pull_dev
        snapshot dev-pull "$BASE/staging-dev"
        verify dev-pull "$MIN_FILES_DEV" "$MIN_BYTES_DEV"
        ;;
    live)
        pull_live
        snapshot live-pull "$BASE/staging-live"
        verify live-pull "$MIN_FILES_LIVE" "$MIN_BYTES_LIVE"
        ;;
    all)
        pull_dev
        snapshot dev-pull "$BASE/staging-dev"
        verify dev-pull "$MIN_FILES_DEV" "$MIN_BYTES_DEV"
        pull_live
        snapshot live-pull "$BASE/staging-live"
        verify live-pull "$MIN_FILES_LIVE" "$MIN_BYTES_LIVE"
        restic_cmd check || fail_loud "restic check failed — repo integrity in doubt"
        ;;
    *)
        echo "usage: met-dr-pull.sh [dev|live|all]" >&2; exit 1 ;;
esac

clear_fail_state
log "met-dr-pull $what: OK"
exit 0
