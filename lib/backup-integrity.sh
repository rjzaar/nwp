#!/bin/bash
################################################################################
# lib/backup-integrity.sh — is this backup artifact actually restorable?
#
# WHY THIS FILE EXISTS
#
# Freshness and integrity were conflated. Both `sweep_latest_backup_epoch`
# (scripts/commands/backup.sh) and `check_missing_backups` (lib/todo-checks.sh)
# selected the newest matching file by mtime and asked nothing else of it. So a
# 0-byte `.sql.gz` — the exact artifact a truncated or OOM-killed dump leaves
# behind — reported FRESH, and because it reported fresh it ALSO suppressed the
# next `pl backup` sweep and the BAK todo for another 7 days.
#
# The failure mode is self-reinforcing: the one artifact you cannot restore from
# is the one that persuades the system it does not need another.
#
# This is the single shared implementation both callers use, so the two can
# never drift apart again (they were already duplicated logic in two files).
################################################################################

# A gzipped SQL dump below this is not a dump. An empty database still produces
# a few hundred bytes of headers; gzip's own header alone is 20 bytes.
BACKUP_MIN_BYTES="${BACKUP_MIN_BYTES:-512}"

# backup_artifact_integrity <path>
# Prints OK on success, or a human-readable reason on failure.
# Returns 0 = restorable as far as we can tell, non-zero = do NOT count this.
backup_artifact_integrity() {
    local f="$1"

    [ -n "$f" ] || { echo "no path given"; return 2; }
    [ -e "$f" ] || { echo "missing: $f"; return 2; }
    [ -f "$f" ] || { echo "not a regular file: $f"; return 2; }

    local size
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$size" -eq 0 ]; then
        echo "empty (0 bytes) — this is what a killed dump leaves behind"
        return 1
    fi
    if [ "$size" -lt "$BACKUP_MIN_BYTES" ]; then
        echo "too small ($size bytes < $BACKUP_MIN_BYTES) — almost certainly truncated"
        return 1
    fi

    # Structural check for compressed artifacts. `gzip -t` decompresses and
    # verifies the CRC, so it catches truncation, bit rot and "not gzip at all".
    case "$f" in
        *.gz|*.tgz)
            if command -v gzip >/dev/null 2>&1; then
                if ! gzip -t "$f" 2>/dev/null; then
                    echo "gzip integrity check failed (truncated, corrupt, or not gzip)"
                    return 1
                fi
            fi
            ;;
    esac

    # Checksum sidecar, when one exists. We do NOT require one — demanding a
    # sidecar that most historical artifacts lack would turn the whole fleet red
    # for a reason nobody can act on — but where the producer wrote one, a
    # mismatch means the bytes changed after they were recorded.
    local sidecar=""
    if [ -f "$f.sha256" ]; then sidecar="$f.sha256"
    elif [ -f "${f%.*}.sha256" ]; then sidecar="${f%.*}.sha256"
    fi
    if [ -n "$sidecar" ] && command -v sha256sum >/dev/null 2>&1; then
        local want have
        want=$(awk '{print $1; exit}' "$sidecar" 2>/dev/null)
        have=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
        if [ -n "$want" ] && [ -n "$have" ] && [ "$want" != "$have" ]; then
            echo "checksum mismatch against $(basename "$sidecar") — the artifact changed after it was recorded"
            return 1
        fi
    fi

    echo "OK"
    return 0
}

# backup_latest_good_epoch <dir>
# Echo the mtime (epoch seconds) of the newest artifact in <dir> that PASSES
# integrity, ignoring newer artifacts that do not. Returns 1 if there is no good
# artifact at all — which is a finding, not a silence.
#
# This is the replacement for "newest file by mtime, no questions asked".
backup_latest_good_epoch() {
    local dir="$1"
    [ -d "$dir" ] || return 1

    local line epoch path
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        epoch="${line%% *}"
        path="${line#* }"
        if backup_artifact_integrity "$path" >/dev/null 2>&1; then
            printf '%s' "${epoch%%.*}"
            return 0
        fi
    done < <(find "$dir" -maxdepth 1 -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) \
                  -printf '%T@ %p\n' 2>/dev/null | sort -rn)
    return 1
}

# backup_first_bad_artifact <dir>
# Echo "<path>\t<reason>" for the newest artifact in <dir> that FAILS integrity,
# or nothing. Used to raise a distinct BAK-corrupt finding rather than letting a
# bad artifact masquerade as a fresh one.
backup_first_bad_artifact() {
    local dir="$1"
    [ -d "$dir" ] || return 1

    local line epoch path reason
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        epoch="${line%% *}"
        path="${line#* }"
        if ! reason=$(backup_artifact_integrity "$path" 2>/dev/null); then
            printf '%s\t%s' "$path" "$reason"
            return 0
        fi
    done < <(find "$dir" -maxdepth 1 -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) \
                  -printf '%T@ %p\n' 2>/dev/null | sort -rn)
    return 1
}
