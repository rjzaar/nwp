#!/usr/bin/env bash
#
# lib/server-assets.sh — the engine behind `pl server assets`.
#
# WHY THIS EXISTS (static image-host handover, 2026-08-22)
# -----------------------------------------------------
# `pl server vhost --create` closed half a gap: it writes the nginx server block
# for a DECLARED root. Nothing then put content into that root, so the handover
# still prescribed, as its Step 1:
#
#     rsync … gitlab@<box>:/tmp/summit-2026/
#     ssh  … 'sudo cp /tmp/summit-2026/*.png /var/www/img/… && sudo chown …'
#
# That is the `scp` + `sudo cp` idiom CLAUDE.md lists as FORBIDDEN, and it is
# the same shape as the ops#149 violation of 2026-07-28 — an operation that
# worked, was backed up, was verified, and still left no ledger and passed
# through none of the guards. A verb that creates a docroot but cannot fill it
# does not remove the hand-run step, it just moves it one line down.
#
# DESIGN RULES (the same four lib/server-vhost.sh works to)
# --------------------------------------------------------
#  1. THE PLAN IS A MEASUREMENT. What would change is computed by diffing a
#     local inventory against an inventory read off the TARGET — never from an
#     assumption about what is there. `rsync -av` prints what it did; this
#     prints what it would do, from the same facts.
#  2. THE ANALYSIS IS LOCAL AND PURE. The probe ships bytes; every verdict is
#     computed here over strings, which is what lets the whole verb be driven
#     from fixtures with no ssh and no box.
#  3. FAIL CLOSED. An inventory that did not run is CANNOT VERIFY, never "the
#     target is empty" — which would grade every file NEW and overwrite a
#     docroot the probe merely failed to read.
#  4. THIS VERB ADDS. It never deletes. A file present only on the target is
#     REPORTED (it may be an orphan, it may be load-bearing) and left alone.
#     There is deliberately no --delete: `rsync --delete` is a loaded gun and
#     nothing about publishing images needs one.

[ -n "${_NWP_SERVER_ASSETS_SOURCED:-}" ] && return 0
_NWP_SERVER_ASSETS_SOURCED=1

################################################################################
# SECTION 1 — validation. This runs before anything is sent.
################################################################################

# assets_validate_root <path>
# The root is interpolated into a script that runs under sudo on the box. A
# value carrying `;`, `$` or `..` would run arbitrary commands as root on a
# machine that also serves GitLab. 2 = REFUSED.
assets_validate_root() {
    local p="${1:-}"
    if [ -z "$p" ]; then
        printf 'REFUSED: empty target root\n' >&2; return 2
    fi
    case "$p" in
        /*) ;;
        *)  printf 'REFUSED: %s is not an absolute path\n' "$p" >&2; return 2 ;;
    esac
    case "$p" in
        *[!a-zA-Z0-9._/-]*)
            printf 'REFUSED: %s contains characters not allowed in a target root\n' "$p" >&2
            return 2 ;;
    esac
    case "$p" in
        *..*) printf 'REFUSED: %s contains a path traversal\n' "$p" >&2; return 2 ;;
    esac
    # Depth floor. `chown -R www-data /` and `chown -R www-data /var` are not
    # recoverable mistakes, and no legitimate docroot is that shallow.
    local trimmed="${p%/}" depth
    depth=$(printf '%s' "$trimmed" | tr -cd '/' | wc -c)
    if [ "$depth" -lt 2 ]; then
        printf 'REFUSED: %s is too shallow to be a document root (needs at least two path segments)\n' \
            "${p}" >&2
        return 2
    fi
    return 0
}

################################################################################
# SECTION 2 — inventories. "<size> <sha256> <relative-path>", one per line.
################################################################################

# assets_local_inventory <dir>
# 2 = REFUSED (missing, or no files — an empty push is a mistake, not a no-op).
assets_local_inventory() {
    local dir="${1:-}"
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        printf 'REFUSED: source directory %s does not exist\n' "${dir:-<empty>}" >&2
        return 2
    fi
    local out
    out="$(cd "$dir" && find . -type f ! -name '.*' 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort | \
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            printf '%s %s %s\n' \
                "$(stat -c '%s' "$rel")" \
                "$(sha256sum "$rel" | cut -d' ' -f1)" \
                "$rel"
        done)"
    if [ -z "$out" ]; then
        printf 'REFUSED: %s contains no files to push\n' "$dir" >&2
        return 2
    fi
    printf '%s\n' "$out"
    return 0
}

# assets_inventory_script <validated-root>
# The remote probe: FIXED and READ-ONLY. A root that does not exist yet is the
# normal first-push case and reads as an empty inventory, not as an error.
assets_inventory_script() {
    local root="$1"
    cat <<PROBE
set -u
printf 'ASSETSINV v1\n'
root='${root}'
if sudo -n test -d "\$root"; then
  cd "\$root" || exit 0
  sudo -n find . -type f 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r rel; do
    [ -n "\$rel" ] || continue
    printf '%s %s %s\n' \\
      "\$(sudo -n stat -c '%s' "\$rel")" \\
      "\$(sudo -n sha256sum "\$rel" | cut -d' ' -f1)" \\
      "\$rel"
  done
fi
PROBE
}

# assets_parse_inventory <raw>
# RULE 3. A stream without the banner did not run; that is CANNOT VERIFY (3),
# never an empty inventory.
assets_parse_inventory() {
    local raw="${1:-}"
    if [[ "$raw" != *"ASSETSINV v1"* ]]; then
        printf 'CANNOT VERIFY: the target inventory did not run — this is NOT "the target is empty"\n' >&2
        return 3
    fi
    # Everything AFTER the banner line. Not `sed '1,/ASSETSINV v1/d'`: with the
    # banner on line 1 that range begins at line 1 and then hunts for a SECOND
    # match from line 2 onward — there is never a second banner, so sed deletes
    # through to end of file and every non-empty inventory comes back EMPTY.
    # Which grades every file NEW, which is precisely the blind overwrite RULE 3
    # exists to prevent. Caught on the live box on the first re-run after a
    # successful push; the unit test only covered the empty case, and the empty
    # case passes either way.
    printf '%s\n' "$raw" | awk 'seen { print } /^ASSETSINV v1$/ { seen = 1 }' | sed '/^$/d'
    return 0
}

################################################################################
# SECTION 3 — the plan (RULE 1, RULE 4)
################################################################################

# assets_plan <local-inventory> <target-inventory>
# Emits one line per path: NEW / REPLACE / UNCHANGED / ONLY-ON-TARGET.
assets_plan() {
    local local_inv="${1:-}" target_inv="${2:-}"
    local -A t_sha=()
    local size sha rel

    while IFS=' ' read -r size sha rel; do
        [ -n "$rel" ] || continue
        t_sha["$rel"]="$sha"
    done <<<"$target_inv"

    local -A seen=()
    while IFS=' ' read -r size sha rel; do
        [ -n "$rel" ] || continue
        seen["$rel"]=1
        if [ -z "${t_sha[$rel]:-}" ]; then
            printf 'NEW       %s (%s bytes)\n' "$rel" "$size"
        elif [ "${t_sha[$rel]}" = "$sha" ]; then
            printf 'UNCHANGED %s\n' "$rel"
        else
            # Same name, different bytes. Worth saying out loud: a static host
            # with a long Cache-Control serves the OLD bytes to anyone who has
            # already fetched this path, for the whole cache window.
            printf 'REPLACE   %s (%s bytes; target holds different content — cached copies keep the old bytes until the Cache-Control window expires)\n' \
                "$rel" "$size"
        fi
    done <<<"$local_inv"

    # RULE 4: reported, never deleted.
    for rel in "${!t_sha[@]}"; do
        [ -n "${seen[$rel]:-}" ] && continue
        printf 'ONLY-ON-TARGET %s (left alone — this verb never removes anything)\n' "$rel"
    done | LC_ALL=C sort

    return 0
}

# assets_plan_counts <plan>  — echoes "new replace unchanged orphan"
assets_plan_counts() {
    local plan="${1:-}" n=0 r=0 u=0 o=0 line
    while IFS= read -r line; do
        case "$line" in
            NEW\ *)            n=$((n+1)) ;;
            REPLACE\ *)        r=$((r+1)) ;;
            UNCHANGED\ *)      u=$((u+1)) ;;
            ONLY-ON-TARGET\ *) o=$((o+1)) ;;
        esac
    done <<<"$plan"
    printf '%s %s %s %s\n' "$n" "$r" "$u" "$o"
}

################################################################################
# SECTION 4 — the push (the only thing here that writes)
################################################################################

# assets_push_script <validated-root> <owner>
# Receives a tar on STDIN — content never reaches the remote command line, and
# nothing is left behind on the box for somebody to find later. Validates the
# archive, creates the docroot, unpacks, sets ownership, then normalises modes
# so nginx can actually read what was just written (a 600 file in a docroot is
# a 403).
#
# WHY THERE IS NO SCRATCH DIRECTORY HERE.
# The first cut staged into a `mktemp -d`, checked that files had landed, then
# `cp -a`'d them across — which meant the remote script contained `rm -rf` to
# clean the staging directory up. The ops#47 impact-contract gate flagged this
# file for it, and correctly: `rm -rf` is indistinguishable from the real thing
# to any scanner. lib/impact.sh answers that case with `impact_rm_scratch`, but
# that is a local bash function and this text runs on the BOX, so it cannot be
# called here — and the allowlist is explicitly not the escape ("a new
# destructive file must adopt the contract, not join this list").
#
# So the staging directory is gone rather than excused. The archive is buffered
# to a temp FILE and VALIDATED before anything is created, which is a stronger
# check than the old one: `tar -t` reads the archive end to end, so a corrupt or
# truncated stream is refused up front instead of being half-extracted into a
# staging area and partially copied across. It is also one copy fewer.
assets_push_script() {
    local root="$1" owner="$2"
    cat <<REMOTE
set -u
root='${root}'
owner='${owner}'

tmpf=\$(mktemp) || { printf 'FAILED: could not create a temporary file\n' >&2; exit 1; }
trap 'rm -f "\$tmpf" "\$tmpf.list"' EXIT

cat > "\$tmpf"

if [ ! -s "\$tmpf" ]; then
  printf 'REFUSED: the payload was empty — %s was not touched\n' "\$root" >&2
  exit 1
fi

# Read the archive end to end BEFORE creating or writing anything. A corrupt or
# truncated stream fails here, with the target untouched.
if ! tar -tf "\$tmpf" > "\$tmpf.list" 2>/dev/null; then
  printf 'REFUSED: the payload is not a readable archive — %s was not touched\n' "\$root" >&2
  exit 1
fi

# At least one entry must be a regular file; an archive of nothing but
# directories is not content. grep reads a FILE here, never a pipeline, so no
# writer can be killed by SIGPIPE and decide this branch by timing (ops#351).
if ! grep -qv '/\$' "\$tmpf.list"; then
  printf 'REFUSED: the payload delivered no files — %s was not touched\n' "\$root" >&2
  exit 1
fi

sudo -n mkdir -p "\$root" || { printf 'FAILED: could not create %s\n' "\$root" >&2; exit 1; }

# An overlay, straight out of the validated archive. This verb ADDS: no
# extraction flag here removes anything already in the target.
sudo -n tar -xf "\$tmpf" -C "\$root" || { printf 'FAILED: could not unpack into %s\n' "\$root" >&2; exit 1; }

sudo -n chown -R "\$owner" "\$root" || { printf 'FAILED: could not set ownership on %s\n' "\$root" >&2; exit 1; }
sudo -n find "\$root" -type d -exec chmod 755 {} + || true
sudo -n find "\$root" -type f -exec chmod 644 {} + || true

printf 'APPLIED: content installed under %s, owned by %s (dirs 755, files 644)\n' "\$root" "\$owner"
REMOTE
}
