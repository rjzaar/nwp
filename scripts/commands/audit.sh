#!/bin/bash
set -euo pipefail

################################################################################
# NWP Update-Awareness Audit  (pl audit)
#
# READ-ONLY fleet update + security awareness. Mirrors the `pl secrets` model:
# a per-site awareness record + a status table + a `pl todo`-friendly exit code.
#
# For each Drupal site (DDEV-backed) it runs, NON-MUTATING:
#   - composer audit            (vendor advisories — exit nonzero on findings)
#   - drush pm:security         (Drupal core/contrib advisories; catches CVE-less SAs)
#   - composer outdated --direct (version drift)
# and writes private/update-awareness/<site>.json  (the cached awareness state).
#
# NOTHING is updated/applied — this only reports. Apply with the (separate)
# update flow once it exists; today: `pl security update <site>`.
#
# Usage: pl audit [--all | --site <name>] [--security-only] [--notify] [--format=json]
# Exit:  0 clean · 3 security findings present · 1 usage/error   (3 matches drush)
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
# yaml helpers (yaml_get_all_sites / yaml_get_site_field) per ADR-0015 (yq-first)
source "$PROJECT_ROOT/lib/yaml-write.sh" 2>/dev/null || true

CONFIG_FILE="${NWP_CONFIG_FILE:-$PROJECT_ROOT/nwp.yml}"
STATE_DIR="$PROJECT_ROOT/private/update-awareness"

show_help() {
    cat << EOF
${BOLD}NWP Update-Awareness Audit${NC}  (read-only)

${BOLD}USAGE:${NC}
    pl audit [options]

${BOLD}OPTIONS:${NC}
    --all                 Audit every Drupal site in nwp.yml (default if no --site)
    --site <name>         Audit a single site
    --security-only       Skip the "outdated/drift" sweep; advisories only
    --notify              Email the operator (settings.todo.notifications.email)
                          once when a NEW advisory appears vs the last record.
                          Used by the daily cron; quiet for known-open sets.
    --format=json         Emit the merged result as JSON (no table)
    -h, --help            This help

${BOLD}WHAT IT RUNS (non-mutating, per site):${NC}
    composer audit · drush pm:security · composer outdated --direct

${BOLD}OUTPUT:${NC}
    A per-site record at  private/update-awareness/<site>.json
    A fleet summary table; exit code 3 if any security advisory is present.

${BOLD}NOTE:${NC} This only DETECTS. To apply security updates today use
    pl security update <site>   (the generalized 'pl update' is on the roadmap).
EOF
}

# --- resolve a site's Drupal webroot (returns "" if not a runnable Drupal/DDEV site) ---
resolve_webroot() {
    local site="$1" dir
    dir=$(yaml_get_site_field "$site" "directory" "$CONFIG_FILE" 2>/dev/null || true)
    [ -z "$dir" ] && dir="$PROJECT_ROOT/sites/$site"
    # F23 dev-tree layout: most sites live under <dir>/dev
    local base
    for base in "$dir/dev" "$dir"; do
        local w
        for w in html web docroot .; do
            if [ -f "$base/$w/core/lib/Drupal.php" ]; then
                echo "$base"        # echo the site root that holds .ddev
                return 0
            fi
        done
    done
    return 1
}

# Extract the integer that precedes a phrase in composer audit's summary lines,
# e.g. "Found 20 security vulnerability advisories affecting 8 packages" -> 20.
_num_before() {  # $1 = text, $2 = phrase regex
    printf '%s' "$1" | grep -oiE "found [0-9]+ $2" | grep -oE '[0-9]+' | head -1
}

# JSON-escape a blob for embedding as a string value in the record.
_json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}'; }

# --- Moodle support ------------------------------------------------------------
# Moodle is NOT composer-managed, so composer audit can't see it. Moodle ships
# security fixes ONLY in the latest point release of a supported branch (older
# point releases never get them), so "behind the latest point release" is the
# actionable security signal. We read the installed version.php and compare its
# numeric $version against the head of MOODLE_<branch>_STABLE on github (one
# small file, no auth). Network failure ⇒ cache_stale=true (unknown, not clean).

_site_dir() {  # echo the site's base dir (mirrors resolve_webroot's dir logic)
    local site="$1" dir
    dir=$(yaml_get_site_field "$site" "directory" "$CONFIG_FILE" 2>/dev/null || true)
    [ -z "$dir" ] && dir="$PROJECT_ROOT/sites/$site"
    printf '%s' "$dir"
}

_moodle_version_php() {  # echo path to the site's version.php, or nothing
    local dir; dir="$(_site_dir "$1")"
    local base
    for base in "$dir/dev" "$dir/stg" "$dir"; do
        [ -f "$base/version.php" ] && grep -q 'MOODLE_INTERNAL\|\$branch' "$base/version.php" 2>/dev/null \
            && { printf '%s' "$base/version.php"; return 0; }
    done
    return 1
}

_site_is_moodle() {
    local cfg; cfg="$(_site_dir "$1")/.nwp.yml"
    [ -f "$cfg" ] && grep -qiE '^\s*type:\s*moodle' "$cfg" 2>/dev/null && return 0
    _moodle_version_php "$1" >/dev/null 2>&1
}

# Extract a PHP scalar assignment (`$version`, `$release`, `$branch`) from a
# Moodle version.php.
#
# NEVER use a greedy `s/.*=//` here. Moodle's real version.php line is:
#   $version  = 2024042212.01;   // 20240422  = branching date YYYYMMDD - do not modify!
# — a greedy `.*=` takes the LAST `=`, which lives inside the trailing comment,
# so BOTH the installed and the upstream version parsed to the literal string
# `branchingdateYYYYMMDD-donotmodify!`. `awk 'a+0 < b+0'` then compared 0 < 0 and
# `behind` was arithmetically incapable of being 1. Live ss/ssd awareness records
# carried that string with security_count: 0 for months.
# `[^=]*=` anchors on the FIRST `=` (the assignment), then `;.*` drops the
# statement terminator and everything after it, including the comment.
_moodle_field_from() {  # $1 = php text on stdin-substitute, $2 = var name
    printf '%s\n' "$1" | grep -E "^\s*\\\$$2\b" | head -1 \
        | sed 's/^[^=]*=//; s/;.*//' | tr -d " '\""
}
_moodle_field() { _moodle_field_from "$(cat "$1" 2>/dev/null)" "$2"; }

# A Moodle $version is a numeric build stamp (YYYYMMDDXX.YY). Anything else means
# we did NOT parse a version — a distributor constant, a patched file, a parser
# regression. Refusing to compare is the honest answer; reporting 0 advisories is
# not, because "0" is indistinguishable from "audited and clean".
_moodle_version_is_numeric() { [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

# Persist "we could not scan this site" as a first-class awareness record.
#
# SKIP/DOWN used to be printed to stdout and thrown away. The consequence: a site
# that has NEVER been audited (no record at all) and a site audited clean
# (security_count: 0) were indistinguishable to `pl rag`, which happily graded
# both GREEN. Adding a site therefore made the fleet look safer. An unscanned
# site now writes a record carrying `scanned: false` so every downstream reader
# has something to go red on.
# Args: $1=site $2=reason
_write_unscanned_record() {
    local site="$1" reason="$2"
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    python3 - "$site" "$STAMP" "$reason" "$STATE_DIR/$site.json" <<'PY' 2>/dev/null || true
import sys, json
site, stamp, reason, path = sys.argv[1:5]
json.dump({
  "site": site, "checked": stamp,
  "source": "pl audit — site not scanned",
  "security_count": 0, "ignored_count": 0, "outdated_count": 0,
  "cache_stale": True, "scanned": False, "stale_reason": reason,
  "note": "UNSCANNED — %s. security_count 0 here means 'not measured', NOT 'clean'." % reason,
}, open(path, "w"), indent=2)
PY
}

moodle_audit_site() {
    local site="$1" vphp
    if ! vphp="$(_moodle_version_php "$site")"; then
        _write_unscanned_record "$site" "moodle: no version.php found"
        printf '%s\tSKIP\t-\t-\t-\tmoodle: no version.php\n' "$site"; return 0
    fi
    local inst_ver inst_rel branch
    inst_ver="$(_moodle_field "$vphp" version)"
    inst_rel="$(_moodle_field "$vphp" release)"
    branch="$(_moodle_field "$vphp" branch)"
    branch="${branch%%[!0-9]*}"

    # Latest point release on the site's stable branch.
    local latest_php latest_ver latest_rel stale="false" stale_reason=""
    latest_php="$(curl -fsS --max-time 20 "https://raw.githubusercontent.com/moodle/moodle/MOODLE_${branch}_STABLE/version.php" 2>/dev/null || true)"
    if [ -n "$latest_php" ]; then
        latest_ver="$(_moodle_field_from "$latest_php" version)"
        latest_rel="$(_moodle_field_from "$latest_php" release)"
    else
        stale="true"
        stale_reason="upstream MOODLE_${branch}_STABLE/version.php unreachable"
    fi

    # A version we could not parse is UNKNOWN, not "current". Anything that keeps
    # us from making a real comparison must set stale so the record, `pl audit`'s
    # table and `pl rag`'s SEC column all render "?" rather than a confident 0.
    if ! _moodle_version_is_numeric "$inst_ver"; then
        stale="true"
        stale_reason="installed \$version unparseable (got '${inst_ver:-<empty>}') in $vphp"
    elif [ "$stale" != "true" ] && ! _moodle_version_is_numeric "$latest_ver"; then
        stale="true"
        stale_reason="upstream \$version unparseable (got '${latest_ver:-<empty>}')"
    fi

    # behind = installed numeric $version < latest (awk float-safe).
    local behind=0
    if [ "$stale" != "true" ]; then
        behind=$(awk -v a="$inst_ver" -v b="$latest_ver" 'BEGIN{print (a+0 < b+0)?1:0}')
    fi
    local sec_count=0; [ "$behind" = "1" ] && sec_count=1
    [ "$sec_count" -gt 0 ] && had_sec=1

    local prev_sec=0
    [ -f "$STATE_DIR/$site.json" ] && prev_sec=$(python3 -c "import json;print(json.load(open('$STATE_DIR/$site.json')).get('security_count',0))" 2>/dev/null || echo 0)

    mkdir -p "$STATE_DIR"
    python3 - "$site" "$STAMP" "$sec_count" "$stale" "$inst_rel" "$latest_rel" "$branch" "$inst_ver" "$latest_ver" "$STATE_DIR/$site.json" "$stale_reason" <<'PY' 2>/dev/null || true
import sys, json
site, stamp, sec, stale, inst_rel, latest_rel, branch, inst_ver, latest_ver, path, reason = sys.argv[1:12]
stale = (stale == "true")
if stale:
    note = "UNSCANNED — no comparison was made: %s. This is NOT a clean result." % (reason or "reason not recorded")
elif sec == "1":
    note = "Behind the latest point release on this branch — Moodle ships security fixes only in the newest point release; review moodle.org/security and update."
else:
    note = "Current on the latest point release of this branch."
json.dump({
  "site": site, "checked": stamp, "platform": "moodle",
  "source": "Moodle point-release check (MOODLE_%s_STABLE version.php)" % branch,
  # security_count is only meaningful when a comparison actually happened.
  # `scanned: false` is what downstream (pl rag) must key on so an unscanned site
  # can never render identically to an audited-clean one.
  "security_count": (0 if stale else int(sec or 0)),
  "ignored_count": 0, "outdated_count": (0 if stale else int(sec or 0)),
  "cache_stale": stale, "scanned": (not stale), "stale_reason": (reason if stale else ""),
  "moodle_branch": branch, "moodle_installed": inst_rel, "moodle_latest": latest_rel,
  "moodle_installed_version": inst_ver, "moodle_latest_version": latest_ver,
  "note": note,
}, open(path, "w"), indent=2)
PY
    # A record we failed to write is itself a blind spot — say so rather than
    # leaving the previous (possibly clean) record standing as current truth.
    if [ ! -f "$STATE_DIR/$site.json" ]; then
        printf '%s\tUNKNOWN\t?\t0\t%s\tawareness record could not be written\n' "$site" "$STAMP"
        return 0
    fi

    if [ "$sec_count" -gt 0 ] || { [ "$stale" = "true" ]; }; then
        printf 'site=%s prev=%s now=%s stale=%s (moodle %s -> %s)\n%s\n' \
            "$site" "$prev_sec" "$sec_count" "$stale" "$inst_rel" "$latest_rel" \
            "$([ "$stale" = "true" ] \
                && printf 'Moodle version comparison could NOT be made for %s: %s. Treat as UNKNOWN, not clean.' "$site" "$stale_reason" \
                || printf 'Moodle %s is behind the latest point release %s on branch %s. Moodle ships security fixes only in the newest point release. Update + review moodle.org/security.' "$inst_rel" "$latest_rel" "$branch")" \
            > "$STATE_DIR/$site.alert" 2>/dev/null || true
        [ "$sec_count" -le "${prev_sec:-0}" ] && [ "$stale" != "true" ] && rm -f "$STATE_DIR/$site.alert" 2>/dev/null || true
    fi

    # "OK*" read as a pass with a footnote. It is not a pass — nothing was compared.
    local status="OK"; [ "$behind" = "1" ] && status="INSECURE"; [ "$stale" = "true" ] && status="UNKNOWN"
    local secfield="$sec_count"; [ "$stale" = "true" ] && secfield="?"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$site" "$status" "$secfield" "$sec_count" "$STAMP" "$STATE_DIR/$site.json"
}

# --- audit one site; prints a one-line TSV summary; sets GLOBAL had_sec ---
# Environment reality (verified 2026-06-27): drush pm:security is REMOVED in the
# installed Drush ("use composer audit"). composer audit is the source of truth,
# and it EXITS 3 when advisories are found — so we must capture output regardless
# of exit code (never `|| fallback`, which discards exactly the findings we want).
had_sec=0
audit_site() {
    local site="$1"
    # Moodle sites aren't composer-managed — audit against the Moodle release feed.
    if _site_is_moodle "$site"; then
        moodle_audit_site "$site"; return $?
    fi
    local root
    if ! root=$(resolve_webroot "$site"); then
        _write_unscanned_record "$site" "not a Drupal site (no resolvable webroot)"
        printf '%s\tSKIP\t-\t-\t-\tnot a Drupal site\n' "$site"; return 0
    fi
    if ! command -v ddev >/dev/null 2>&1 || [ ! -d "$root/.ddev" ]; then
        _write_unscanned_record "$site" "no ddev binary or no .ddev in the webroot — composer audit could not run"
        printf '%s\tSKIP\t-\t-\t-\tno ddev\n' "$site"; return 0
    fi
    if ! (cd "$root" && ddev describe >/dev/null 2>&1); then
        _write_unscanned_record "$site" "ddev project not running — composer audit could not run"
        printf '%s\tDOWN\t-\t-\t-\tddev not running\n' "$site"; return 0
    fi

    # composer audit (text) — capture stdout+stderr, tolerate nonzero exit.
    local audit_txt=""
    audit_txt=$(cd "$root" && ddev composer audit --locked --no-interaction 2>&1) || true

    local sec_count ignored_count abandoned_count
    sec_count=$(_num_before "$audit_txt" "security vulnerability advisor")
    ignored_count=$(_num_before "$audit_txt" "ignored security")
    abandoned_count=$(_num_before "$audit_txt" "abandoned package")
    sec_count=${sec_count:-0}; ignored_count=${ignored_count:-0}; abandoned_count=${abandoned_count:-0}
    # registry-auth failures (rotated PAT in auth.json) degrade to local cache;
    # flag staleness so a 0 isn't mistaken for "verified clean".
    local stale="false"
    printf '%s' "$audit_txt" | grep -qiE "could not be fully loaded|Invalid credentials|loaded from the local cache" && stale="true"

    local outdated_count=0 outdated_txt=""
    if [ "$SECURITY_ONLY" != "true" ]; then
        outdated_txt=$(cd "$root" && ddev composer outdated --direct --no-dev 2>/dev/null) || true
        # count lines that look like "vendor/name  cur  ...  new"
        outdated_count=$(printf '%s' "$outdated_txt" | grep -cE '^[a-z0-9._-]+/[a-z0-9._-]+ ' || true)
        outdated_count=${outdated_count:-0}
    fi

    [ "$sec_count" -gt 0 ] && had_sec=1

    # Read the PREVIOUS advisory count before we overwrite the record, so the
    # daily timer can email only on a NEW advisory (0→N or an increase) rather
    # than every run for the same known-open set. audit_site runs in a subshell,
    # so we signal a new advisory via a sibling .alert file that main() reads.
    local prev_sec=0
    if [ -f "$STATE_DIR/$site.json" ]; then
        prev_sec=$(python3 -c "import json,sys;print(json.load(open('$STATE_DIR/$site.json')).get('security_count',0))" 2>/dev/null || echo 0)
    fi

    # Write the record via python json.dump — bulletproof escaping of the
    # ANSI/control chars that composer audit emits (bash printf can't do this safely).
    mkdir -p "$STATE_DIR"
    AUDIT_TXT="$audit_txt" OUTDATED_TXT="$outdated_txt" python3 - \
        "$site" "$STAMP" "$sec_count" "$ignored_count" "$abandoned_count" \
        "$outdated_count" "$stale" "$STATE_DIR/$site.json" <<'PY' 2>/dev/null || true
import os, sys, json, re
site, stamp, sec, ign, ab, outd, stale, path = sys.argv[1:9]
ansi = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
def clean(s): return ansi.sub('', s or '')
rec = {
  "site": site, "checked": stamp,
  "source": "composer audit (drush pm:security removed in this Drush)",
  "security_count": int(sec or 0), "ignored_count": int(ign or 0),
  "abandoned_count": int(ab or 0), "outdated_count": int(outd or 0),
  # cache_stale == "composer fell back to the local cache / auth failed", i.e. the
  # advisory set we compared against is not trustworthy. That is not a scan.
  "cache_stale": (stale == "true"), "scanned": (stale != "true"),
  "stale_reason": ("composer advisory registry could not be fully loaded (rotated auth.json token?)" if stale == "true" else ""),
  "composer_audit_text": clean(os.environ.get("AUDIT_TXT", "")),
  "composer_outdated_text": clean(os.environ.get("OUTDATED_TXT", "")),
}
json.dump(rec, open(path, "w"), indent=2)
PY

    # Signal a NEW advisory (count went up, or first-ever record with advisories)
    # so main() can email. cache_stale (registry auth failed) is treated as
    # "unknown → alert" if advisories are present, never silently as clean.
    if [ "$sec_count" -gt "${prev_sec:-0}" ] || { [ "$stale" = "true" ] && [ "$sec_count" -gt 0 ]; }; then
        printf 'site=%s prev=%s now=%s stale=%s\n%s\n' \
            "$site" "${prev_sec:-0}" "$sec_count" "$stale" "$audit_txt" > "$STATE_DIR/$site.alert" 2>/dev/null || true
    fi

    local status="OK"
    [ "$sec_count" -gt 0 ] && status="INSECURE"
    [ "$stale" = "true" ] && status="${status}*"
    local secfield="$sec_count"
    [ "$ignored_count" -gt 0 ] && secfield="${sec_count}(+${ignored_count}i)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$site" "$status" "$secfield" "$outdated_count" "$STAMP" "$STATE_DIR/$site.json"
}

main() {
    local ALL=false SITE="" FORMAT="table" NOTIFY=false
    SECURITY_ONLY=false
    # a single timestamp for the whole run (records stay reproducible/diffable)
    STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --all) ALL=true; shift ;;
            --site) SITE="${2:-}"; shift 2 ;;
            --security-only) SECURITY_ONLY=true; shift ;;
            --notify) NOTIFY=true; shift ;;
            --format=json) FORMAT="json"; shift ;;
            --format) FORMAT="${2:-table}"; shift 2 ;;
            *) print_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done

    [ ! -f "$CONFIG_FILE" ] && { print_error "Config not found: $CONFIG_FILE"; exit 1; }

    # build the site list
    local sites=()
    if [ -n "$SITE" ]; then
        sites=("$SITE")
    else
        while read -r s; do [ -n "$s" ] && sites+=("$s"); done \
            < <(yaml_get_all_sites "$CONFIG_FILE" 2>/dev/null || true)
    fi
    [ "${#sites[@]}" -eq 0 ] && { print_error "No sites found"; exit 1; }

    print_header "Update-awareness audit (read-only) — ${#sites[@]} site(s)"
    # Clear last run's new-advisory markers so --notify only acts on THIS run.
    rm -f "$STATE_DIR"/*.alert 2>/dev/null || true
    local rows="" row
    for s in "${sites[@]}"; do
        # audit_site runs in a subshell here, so its had_sec can't propagate —
        # derive the fleet verdict from the collected rows below instead.
        row=$(audit_site "$s") || true
        rows+="$row"$'\n'
    done
    printf '%s' "$rows" | grep -q 'INSECURE' && had_sec=1 || true

    if [ "$FORMAT" = "json" ]; then
        # emit the collection of just-written records
        printf '['
        local first=1
        for s in "${sites[@]}"; do
            [ -f "$STATE_DIR/$s.json" ] || continue
            [ $first -eq 1 ] || printf ','
            cat "$STATE_DIR/$s.json"; first=0
        done
        printf ']\n'
    else
        printf '\n%-16s %-10s %-4s %-8s %s\n' "SITE" "STATUS" "SEC" "OUTDATED" "RECORD"
        printf '%s' "$rows" | while IFS=$'\t' read -r site status sec out stamp rec; do
            [ -z "$site" ] && continue
            printf '%-16s %-10s %-4s %-8s %s\n' "$site" "$status" "$sec" "$out" "${rec:-$stamp}"
        done
        echo
        printf '  legend: SEC = active advisories (+Ni = N ignored-by-policy); * = audited from local cache (registry auth failed)\n\n'
        if [ "$had_sec" -eq 1 ]; then
            print_warning "Security advisories present — review records in $STATE_DIR/ ; apply with: pl security update <site>"
        else
            print_status "OK" "No security advisories detected across audited (running) sites"
        fi
    fi

    # --notify: email the operator ONCE when a new advisory appears (an .alert
    # marker was written this run). Keeps the daily timer quiet for known-open
    # sets. Uses postfix (mail/sendmail) directly — no dependency on the todo
    # notification config. Recipient = settings.email.admin_email from nwp.yml.
    if [ "$NOTIFY" = "true" ]; then
        # Best-effort alerting: never let a nonzero here abort the run under the
        # script's `set -euo pipefail` (e.g. a false [ -gt 1 ] test in a command
        # substitution). Restore strict mode after the block.
        set +e
        local alerts=("$STATE_DIR"/*.alert)
        if [ -e "${alerts[0]}" ]; then
            local subj body
            subj="[nwp security] new advisory on $(basename "${alerts[0]}" .alert)$([ "${#alerts[@]}" -gt 1 ] && echo " +$(( ${#alerts[@]} - 1 )) more")"
            body="A new package security advisory was detected by 'pl audit' on $(hostname).

$(for a in "${alerts[@]}"; do echo "=== $(basename "$a" .alert) ==="; cat "$a"; echo; done)

Records: $STATE_DIR/
Next: 'pl rag --sync-issues --execute' files/updates the nwp/ops issue; review +
apply behind the human/hardware gate (pl security update <site> on dev, rehearse,
pl stg2live <site> --code-only)."
            # Reuse the standard notification transport (msmtp/sendmail/mail/curl-SMTP,
            # gated on nwp.yml settings.todo.notifications.email). Works as soon as a
            # transport is configured; today the reliable alert is the GitLab issue
            # that rag-sync files ~40 min later (GitLab emails the operator).
            local sent=false
            # Transport 1: the standard notify_email chain (msmtp/sendmail/mail/
            # curl-SMTP), if any is configured on this box.
            if [ -f "$PROJECT_ROOT/lib/todo-notify.sh" ]; then
                # shellcheck disable=SC1091
                TODO_NOTIFY_PROJECT_ROOT="$PROJECT_ROOT" . "$PROJECT_ROOT/lib/todo-notify.sh" 2>/dev/null || true
                if command -v notify_email >/dev/null 2>&1 && \
                   TODO_NOTIFY_PROJECT_ROOT="$PROJECT_ROOT" notify_email "$subj" "$body" 2>/dev/null; then
                    sent=true
                fi
            fi
            # Transport 2 (fallback): relay through a mail-capable host's postfix
            # over ssh (settings.todo.notifications.email.relay_ssh in nwp.yml).
            # This box has no local MTA, so this is what actually delivers today.
            if [ "$sent" != "true" ]; then
                local relay relay_key rcpt
                relay=$(grep -E '^\s*relay_ssh:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*relay_ssh:[[:space:]]*//; s/[[:space:]]*#.*//; s/[[:space:]]*$//')
                relay_key=$(grep -E '^\s*relay_ssh_key:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*relay_ssh_key:[[:space:]]*//; s/[[:space:]]*#.*//; s/[[:space:]]*$//')
                rcpt=$(grep -E '^\s*recipient:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*recipient:[[:space:]]*//; s/[[:space:]]*#.*//; s/[[:space:]]*$//')
                if [ -n "$relay" ] && [ -n "$rcpt" ]; then
                    local relay_dom="${relay#*@}"
                    if printf 'To: %s\nFrom: nwp-security@nwpcode.org\nSubject: %s\n\n%s\n' "$rcpt" "$subj" "$body" \
                        | ssh ${relay_key:+-i "$relay_key"} -o BatchMode=yes -o ConnectTimeout=15 "$relay" \
                          "$([ -x /usr/sbin/sendmail ] && echo /usr/sbin/sendmail || echo sendmail) -t" 2>/dev/null; then
                        sent=true
                        print_status "OK" "Emailed new-advisory alert to $rcpt (via ${relay_dom} postfix relay)"
                    fi
                fi
            fi
            [ "$sent" = "true" ] || print_warning "Advisory email not sent (no transport + relay failed) — the nwp/ops GitLab issue (rag-sync) is the working alert; set smtp.default.password or a valid relay_ssh to enable email."
        fi
        set -e  # restore strict mode after the best-effort notify block
    fi

    [ "$had_sec" -eq 1 ] && exit 3
    exit 0
}

# Do not run when sourced (06-scripts-validation.bats guard)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
