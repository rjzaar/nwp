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

################################################################################
# MEMOISATION (ops#178)
#
# `gzip -t` is a full decompression. On the live fleet that is ~10 GB across
# ~114 artifacts, and `check_missing_backups` re-verified ALL of them on EVERY
# `pl todo` run: 133 seconds, ~74% of the 180s budget `pl rag` allows the whole
# sweep. That single check is most of the reason `pl rag` printed TODO ● BLIND
# every night.
#
# The result of `gzip -t` on a file is a pure function of that file's bytes, so
# it is safe to remember — keyed on (path, size, mtime_ns). If any of those
# three change the key changes and the artifact is re-verified from scratch. A
# backup file that is rewritten in place with byte-identical size AND identical
# nanosecond mtime is not a case that occurs; a bit-rot event changes neither,
# but bit rot on a cold archive is also not what this check is for (it is for
# "the producer is writing garbage NOW"), and `pl backup verify --force` exists
# for a full re-scan.
#
# Set NWP_BACKUP_INTEGRITY_CACHE=/dev/null (or BACKUP_INTEGRITY_NO_CACHE=1) to
# disable, which is what the unit tests do when they assert on real gzip work.
################################################################################
BACKUP_INTEGRITY_CACHE="${NWP_BACKUP_INTEGRITY_CACHE:-${TMPDIR:-/tmp}/nwp-backup-integrity.tsv}"

# Identity of an artifact for cache purposes: path + size + mtime in ns.
_backup_cache_key() {
    stat -c '%n|%s|%Y|%y' "$1" 2>/dev/null || stat -f '%N|%z|%m' "$1" 2>/dev/null
}

_backup_cache_lookup() {
    [ "${BACKUP_INTEGRITY_NO_CACHE:-0}" = "1" ] && return 1
    [ -f "$BACKUP_INTEGRITY_CACHE" ] || return 1
    local key="$1" line
    line=$(grep -Fx -m1 -- "$key	OK" "$BACKUP_INTEGRITY_CACHE" 2>/dev/null) || return 1
    [ -n "$line" ]
}

_backup_cache_store() {
    [ "${BACKUP_INTEGRITY_NO_CACHE:-0}" = "1" ] && return 0
    local key="$1"
    local dir; dir=$(dirname "$BACKUP_INTEGRITY_CACHE")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
    # Only successes are memoised. A FAILURE must be re-derived every run: it is
    # the actionable state, and caching it would let a repaired artifact keep
    # reporting corrupt.
    printf '%s\tOK\n' "$key" >> "$BACKUP_INTEGRITY_CACHE" 2>/dev/null || true
}

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

    # MEMO HIT — both expensive legs below (gzip -t and sha256sum) read the
    # whole file, so the memo has to wrap BOTH of them, not just the gzip.
    # Caching only the gzip leg still left sha256sum re-hashing multi-GB
    # artifacts on every run (measured: 7.8s for one site with a warm gzip
    # cache). See the MEMOISATION note above; this is the 133s that used to
    # blind `pl rag` every night (ops#178).
    local _ck=""
    _ck=$(_backup_cache_key "$f")
    if [ -n "$_ck" ] && _backup_cache_lookup "$_ck"; then
        echo "OK"
        return 0
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

    # Passed every leg — remember it so the next sweep does not re-read the
    # whole file. Only successes are memoised (see _backup_cache_store).
    [ -n "$_ck" ] && _backup_cache_store "$_ck"

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
    local depth="${2:-${BACKUP_SCAN_DEPTH:-8}}"
    [ -d "$dir" ] || return 1

    local line epoch path reason n=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # DEPTH BOUND (ops#178). This scanned EVERY artifact in every site's
        # backup dir on every `pl todo` run. When nothing is corrupt that means
        # `gzip -t` over the whole corpus — 10 GB / 114 files / 133s on the live
        # fleet, which is 74% of the 180s budget `pl rag` gives the entire sweep
        # and the single largest reason rag went TODO ● BLIND nightly.
        #
        # What this check is FOR is stated in its caller: "otherwise the producer
        # keeps writing garbage and the only symptom is a silently ageing last
        # good date". That is a question about RECENT artifacts. Verifying the
        # newest few answers it; re-decompressing a year of cold archives every
        # 5 minutes does not, and its only measurable effect was to ensure the
        # answer never arrived at all.
        #
        # Full-corpus verification remains available deliberately:
        #   BACKUP_SCAN_DEPTH=0 (unbounded) — e.g. pl backup verify
        [ "$depth" -gt 0 ] && [ "$n" -ge "$depth" ] && break
        n=$((n + 1))
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
