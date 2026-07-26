#!/usr/bin/env bash
#
# nwp-daily-audit.sh — daily read-only dependency + upstream-drift audit for
#                      NWP-managed Drupal sites.
#
# ============================================================================
# WHY THIS FILE LOOKS THE WAY IT DOES (read before editing)
# ============================================================================
#
# From 2026-06-23 to 2026-07-25 this audit ran 33 consecutive nights, logged
# "no change" and "DONE (changes=0)", exited 0, and notified nobody — while
# auditing NOTHING. The composer probes ran via `ddev exec`; the DDEV project
# had been stopped; every probe produced an empty file; and an empty result was
# indistinguishable from a clean result. The first real audit after this fix
# found 20 advisories (1 high) that had been sitting unreported the whole time.
#
# This is the "structurally vacuous check" defect class — the same one fixed in
# f9b95c9 ("make pl's oversight surfaces able to report 'I am blind'") and in
# the boundary manifest gate ("cannot verify" is not "clean", exit 2). This
# file reuses that vocabulary deliberately. The rules below are not style
# preferences; each is the direct counter to a way this script lied.
#
#   R1. COULD NOT AUDIT IS A FAILURE, NOT A PASS. An empty or unparseable probe
#       result never means "clean". It sets that axis BLIND, forces a non-zero
#       exit, and is eligible to notify.
#   R2. A BLIND AXIS NEVER ADVANCES THE BASELINE. If we could not see, we do
#       not get to overwrite what we last actually saw. Previous values are
#       carried forward, so a blind axis cannot masquerade as "all findings
#       resolved", and the next sighted run diffs against the last genuinely
#       observed state rather than against a hole.
#   R3. NO CONTAINER IN THE PATH OF A SECURITY CHECK. The CVE probe reads
#       composer.lock directly on the host: no DDEV, no Docker, no vendor/
#       tree, no registry credentials. The 33-night outage is not merely
#       fixed — its cause is designed out.
#   R4. THE EXIT CODE IS THE CONTINUOUS SIGNAL; ISSUES ARE THE RATE-LIMITED
#       ONE. Blindness exits non-zero EVERY run (cron mail, pl rag and host
#       state capture all see it) but opens an issue only on the first blind
#       run and every Nth consecutive one after. 33 blind nights would be 33
#       red exits and 5 issues — not 33 issues, and not the 1 we actually got.
#   R5. THIS FILE IS CANONICAL. It previously existed in two versions; only the
#       unversioned box-only one ever ran. See "SPLIT-BRAIN" below.
#
# ============================================================================
# STATE MODEL (explicit — the point of the fix)
# ============================================================================
#
# Three per-axis outcomes. "Empty" is not one of them:
#
#   OK      — the probe ran and returned parseable output. Findings may be zero
#             (audited-clean) or N (audited-found-N). Both are OK, because both
#             mean WE LOOKED.
#   BLIND   — the probe could not run, returned nothing, or returned something
#             unparseable. We did not look. This is a FAILURE.
#   SKIP    — the axis is not configured for this site (e.g. no upstream
#             package declared). Not a failure; nothing was promised.
#
# Axes and their fingerprint contributions:
#   adv       composer audit --locked    -> "ADV <pkg> <id> <sev>", "ABANDONED <pkg>"
#   outdated  composer outdated --direct -> "OUTDATED <pkg> <cur> -> <latest>"
#   upstream  upstream composer.json     -> "UPSTREAM <pkg>: ours=X upstream=Y"
#
# Per-site rollup:
#   AUDITED_CLEAN     every non-skipped axis OK, zero findings  -> silent
#   AUDITED_FOUND_N   every non-skipped axis OK, N findings     -> post on change
#   COULD_NOT_AUDIT   one or more axes BLIND                    -> post on cadence
#
# Run exit codes:
#   0  every site audited (clean or with findings); notifications delivered
#   2  COULD NOT AUDIT — at least one axis on at least one site was BLIND
#   3  configuration error — could not even begin (no composer, no sites, ...)
#   4  audited fine, but a notification that needed to go out could not be sent
#
# Exit 2 matches the convention already used by `pl impact --honesty` and
# `pl secrets audit` for "cannot verify" as distinct from "verified clean".
#
# ============================================================================
# SPLIT-BRAIN (resolved 2026-07-26)
# ============================================================================
#
# Two versions existed. The build host's ~/bin/nwp-daily-audit was what cron
# actually ran: unversioned, box-only, invisible to review. The repo copy
# carried a header admitting it was a "lightly parameterised RECONSTRUCTION"
# written while the build host was unreachable — so the reviewed copy had never
# been the running copy, and nothing would have detected them diverging.
#
# They HAD diverged, in both directions. Reconciled INTO this file from the box
# copy (real behaviour the reconstruction had dropped):
#   - ABANDONED package reporting from the audit JSON
#   - composer audit "advisories" as a LIST as well as a dict (the shape varies
#     by composer version; the reconstruction handled only the dict form and
#     would have thrown away a whole advisory set silently)
#   - parse failures surfaced rather than swallowed (the box copy was MORE
#     honest here: it emitted ADV_PARSE_ERROR into the fingerprint, where the
#     reconstruction caught the exception and exited 0)
#   - the site profile's composer.json merged over the project's, profile
#     constraints winning, for the upstream comparison
#   - upstream compared against the upstream repo's `main` branch, not the
#     latest Packagist release (the reconstruction guessed Packagist, then
#     documented its own guess as fact)
#   - first-run bootstrap: no baseline yet => create it silently, do not post
#   - one batched summary issue per run, not one issue per site
#
# KEPT from the repo copy (genuine improvements the box copy lacked):
#   - the token reaches curl only through a 0600 config file, never on argv,
#     where the box copy's -H "PRIVATE-TOKEN: $TOKEN" exposed it in
#     /proc/<pid>/cmdline for the life of the process
#   - host / project / token path / site list all env-injected; defaults are
#     role-label placeholders, never a real hostname
#   - a failed POST does not advance the baseline (the box copy advanced it
#     BEFORE posting and regardless of the result, so a failed notification
#     lost that finding permanently)
#   - set -euo pipefail, malformed-entry guards
#
# THREAT MODEL: the audit token is scoped Developer/api on the ops-log project
# ONLY. This script performs NO writes to any site: it copies composer.lock to
# a scratch dir, reads composer.json, and fetches a public upstream
# composer.json over HTTPS. It never mutates a site, never starts or stops a
# container, and never runs composer install/update.
#
# CONFIGURATION (environment overrides):
#   NWP_ROOT                repo root         (default: resolved from script)
#   NWP_AUDIT_TOKEN_FILE    0600 PAT file     (default: ~/.config/nwp-audit.token)
#   NWP_GITLAB_HOST         GitLab host       (default: <gitlab-host> placeholder)
#   NWP_OPS_LOG_PROJECT     namespace/project or numeric project id
#                                             (default: ops/verifier-log placeholder)
#   NWP_AUDIT_CACHE_DIR     baseline cache    (default: ~/.cache/nwp-daily-audit)
#   NWP_AUDIT_LOG           log file          (default: $NWP_ROOT/logs/daily-audit.log)
#   NWP_AUDIT_SITES         override SITES ("key:dir:upstream-pkg" entries)
#   NWP_AUDIT_BLIND_EVERY   re-notify cadence for continued blindness, in runs
#                                             (default: 7; 1 = every run)
#   NWP_AUDIT_GIT_PULL      1 = ff-only pull the checkout before auditing, so
#                           cron runs the reviewed copy. Refuses on a dirty
#                           tree or a non-default branch; never fatal.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths / config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NWP_ROOT="${NWP_ROOT:-$( cd "$SCRIPT_DIR/.." && pwd )}"

AUDIT_TOKEN_FILE="${NWP_AUDIT_TOKEN_FILE:-$HOME/.config/nwp-audit.token}"
GITLAB_HOST="${NWP_GITLAB_HOST:-<gitlab-host>}"
OPS_LOG_PROJECT="${NWP_OPS_LOG_PROJECT:-ops/verifier-log}"
CACHE_DIR="${NWP_AUDIT_CACHE_DIR:-$HOME/.cache/nwp-daily-audit}"
LOG_FILE="${NWP_AUDIT_LOG:-$NWP_ROOT/logs/daily-audit.log}"
BLIND_EVERY="${NWP_AUDIT_BLIND_EVERY:-7}"

# A numeric project id is used as-is; a namespace/project path is URL-encoded.
if [[ "$OPS_LOG_PROJECT" =~ ^[0-9]+$ ]]; then
    PROJECT_PATH="$OPS_LOG_PROJECT"
else
    PROJECT_PATH="${OPS_LOG_PROJECT//\//%2F}"
fi
API="https://${GITLAB_HOST}/api/v4/projects/${PROJECT_PATH}/issues"

# ---------------------------------------------------------------------------
# SITES array — "site-key:site-dir:upstream-pkg" (upstream-pkg may be empty)
# ---------------------------------------------------------------------------
if [[ -n "${NWP_AUDIT_SITES:-}" ]]; then
    # shellcheck disable=SC2206
    SITES=( ${NWP_AUDIT_SITES} )
else
    SITES=(
        "nwc-dev:${NWP_ROOT}/sites/nwc/dev:goalgorilla/open_social"
    )
fi

# ---------------------------------------------------------------------------
# Logging / small helpers
# ---------------------------------------------------------------------------
log() {
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[%s] %s\n' "$ts" "$*" | tee -a "$LOG_FILE" >&2
}

now_epoch() { date -u +%s; }

# Count non-empty lines without grep's "no match => exit 1" tripping set -e.
count_lines() { printf '%s' "${1:-}" | grep -c . 2>/dev/null || true; }

# Probes run inside command substitution, i.e. in a SUBSHELL, so a shell
# variable set there cannot reach the caller. The failure reason therefore
# travels out-of-band through a file. (Getting this wrong would have made every
# blindness report read "unknown reason" — a quieter version of the same bug.)
PROBE_REASON_FILE="$(mktemp)"
cleanup() { rm -f "$PROBE_REASON_FILE" 2>/dev/null || true; }
trap cleanup EXIT
set_reason() { printf '%s' "$*" > "$PROBE_REASON_FILE"; }
get_reason() { cat "$PROBE_REASON_FILE" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Provenance — say which version of this file ran, so a future split-brain is
# visible in the log rather than something a later session has to excavate.
# ---------------------------------------------------------------------------
provenance() {
    local sha branch state=""
    # The split-brain symptom itself: the file being executed is not the file in
    # the repo. That is exactly how ~/bin/nwp-daily-audit ran unreviewed for
    # months, so it gets its own loud label rather than being lumped in with
    # "locally modified".
    if [[ "$SCRIPT_DIR" != "$NWP_ROOT/scripts" ]]; then
        state=" UNVERSIONED-COPY(running outside \$NWP_ROOT/scripts)"
    fi
    if command -v git >/dev/null 2>&1 && git -C "$NWP_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        sha="$(git -C "$NWP_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        branch="$(git -C "$NWP_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        if [[ -z "$state" ]] \
           && ! git -C "$NWP_ROOT" diff --quiet -- "$NWP_ROOT/scripts/nwp-daily-audit.sh" 2>/dev/null; then
            state=" LOCALLY-MODIFIED"
        fi
        printf 'script=%s root=%s commit=%s branch=%s%s' \
            "${BASH_SOURCE[0]}" "$NWP_ROOT" "$sha" "$branch" "$state"
    else
        printf 'script=%s root=%s commit=not-a-git-checkout%s' \
            "${BASH_SOURCE[0]}" "$NWP_ROOT" "$state"
    fi
}

# Optional ff-only self-update so cron runs the reviewed copy. Deliberately
# timid: never on a dirty tree, never off the default branch, never fatal.
maybe_git_pull() {
    [[ "${NWP_AUDIT_GIT_PULL:-0}" == "1" ]] || return 0
    command -v git >/dev/null 2>&1 || { log "WARN: git absent — cannot self-update"; return 0; }
    git -C "$NWP_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
        log "WARN: $NWP_ROOT is not a git checkout — cannot self-update"; return 0; }
    local branch; branch="$(git -C "$NWP_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    if [[ "$branch" != "main" && "$branch" != "master" ]]; then
        log "WARN: checkout is on '$branch', not the default branch — skipping self-update"
        return 0
    fi
    if [[ -n "$(git -C "$NWP_ROOT" status --porcelain 2>/dev/null)" ]]; then
        log "WARN: checkout has local modifications — skipping self-update (may be running stale code)"
        return 0
    fi
    if git -C "$NWP_ROOT" pull --ff-only --quiet 2>/dev/null; then
        log "self-update: ff-only pull ok ($(git -C "$NWP_ROOT" rev-parse --short HEAD 2>/dev/null))"
    else
        log "WARN: ff-only pull failed — running the checked-out copy as-is"
    fi
}

# ---------------------------------------------------------------------------
# PROBES
#
# Every probe obeys one contract, which is what makes R1 enforceable:
#   stdout      the probe's parsed fingerprint lines (may legitimately be empty)
#   return 0    OK    — we looked
#   return 1    BLIND — we did not look; reason written via set_reason
#   return 3    SKIP  — nothing was configured to look at
# "Returned zero lines" and "could not run" are therefore DIFFERENT RESULTS —
# exactly the distinction the old script was unable to express.
# ---------------------------------------------------------------------------

# --- adv: CVE + abandoned-package audit, straight off composer.lock ---------
#
# R3 lives here. `composer audit --locked` resolves nothing and installs
# nothing: it reads the lock file's package/version list and asks the advisory
# database about it. No container, no vendor/ tree, no Docker.
#
# It runs in a scratch COPY of composer.json/composer.lock with private
# composer/vcs/path repositories stripped, because composer authenticates every
# configured repository before it will run any command — so a dead private
# registry credential blinds the CVE check even though the CVE check does not
# need that registry. (Observed on the build host: RC=100 "Invalid credentials"
# for the GitLab package registry.) Stripping costs nothing: advisories are
# looked up by package name and version, both already in the lock file. The
# site tree itself is never written to.
adv_probe() {
    local dir="$1"

    [[ -f "$dir/composer.lock" ]] || { set_reason "no composer.lock at $dir"; return 1; }
    [[ -f "$dir/composer.json" ]] || { set_reason "no composer.json at $dir"; return 1; }

    local work
    work="$(mktemp -d)" || { set_reason "mktemp failed"; return 1; }

    cp "$dir/composer.lock" "$work/composer.lock" 2>/dev/null || {
        rm -rf "$work"; set_reason "could not copy composer.lock"; return 1; }

    if ! SRC="$dir/composer.json" DST="$work/composer.json" python3 - <<'PY' 2>/dev/null
import json, os
src, dst = os.environ["SRC"], os.environ["DST"]
d = json.load(open(src))
repos = d.get("repositories")
if isinstance(repos, dict):
    repos = list(repos.values())
kept = []
for r in (repos or []):
    if isinstance(r, dict) and r.get("type") in ("composer", "vcs", "git", "path") \
       and "packagist.org" not in str(r.get("url", "")):
        continue          # private/self-hosted repo: not needed to audit a lock
    kept.append(r)
d["repositories"] = kept
d.pop("scripts", None)    # irrelevant to an audit, and needless attack surface
json.dump(d, open(dst, "w"))
PY
    then
        rm -rf "$work"
        set_reason "could not build scratch composer.json from $dir (unparseable?)"
        return 1
    fi

    # composer audit exits NON-ZERO WHEN IT FINDS ADVISORIES. That is a
    # successful look, not a failure, so rc cannot be the health signal — the
    # health signal is whether parseable JSON came back.
    local out rc=0
    out="$( cd "$work" && composer audit --locked --no-dev --format=json \
              --no-interaction --no-plugins 2>/dev/null )" || rc=$?
    rm -rf "$work"

    if [[ -z "$out" ]]; then
        set_reason "composer audit produced no output (rc=$rc)"
        return 1
    fi

    local parsed
    if ! parsed="$( AUDIT_JSON="$out" python3 - <<'PY'
import json, os, sys
try:
    d = json.loads(os.environ["AUDIT_JSON"])
except Exception as e:
    print("ADV_PARSE_ERROR " + repr(e)); sys.exit(0)

def fmt_adv(pkg, a):
    # advisoryId leads because it is stable; the CVE is appended when present
    # purely so a human triaging the issue has something searchable.
    aid = a.get("advisoryId") or a.get("cve") or a.get("id") or "?"
    sev = a.get("severity") or "unknown"
    cve = a.get("cve")
    return "ADV %s %s %s%s" % (pkg, aid, sev, (" " + cve) if cve else "")

advs = d.get("advisories") or []
if isinstance(advs, dict):
    for pkg, lst in sorted(advs.items()):
        if isinstance(lst, dict):
            lst = list(lst.values())
        for a in lst:
            print(fmt_adv(pkg, a))
elif isinstance(advs, list):
    for a in advs:
        print(fmt_adv(a.get("packageName") or a.get("package") or "?", a))
ab = d.get("abandoned") or {}
if isinstance(ab, dict):
    for pkg in sorted(ab.keys()):
        print("ABANDONED " + pkg)
elif isinstance(ab, list):
    for e in ab:
        print("ABANDONED " + ((e.get("packageName") or e.get("package") or "?")
                              if isinstance(e, dict) else str(e)))
PY
    )"; then
        set_reason "composer audit JSON parser crashed"
        return 1
    fi

    # A parse error is blindness, not a finding. The box copy at least recorded
    # it in the fingerprint; we go further and fail the run on it.
    if printf '%s' "$parsed" | grep -q '^ADV_PARSE_ERROR'; then
        set_reason "composer audit JSON was unparseable"
        return 1
    fi

    printf '%s' "$parsed" | sed '/^$/d'
    return 0
}

# --- outdated: newer releases available for DIRECT dependencies -------------
#
# Unlike adv, this genuinely needs live repository metadata — that is what "is
# there a newer version" means — so it runs in the site dir and needs the
# configured repositories reachable and authenticated. When the private
# registry credential is dead this axis goes BLIND: correctly, and loudly.
#
# CONSIDERED AND REJECTED: retrying in the stripped scratch copy to get a
# public-packages-only answer. That yields a number that LOOKS like a complete
# outdated report while silently omitting every private package — a partial
# truth wearing the costume of a whole one, which is the exact failure mode
# this file exists to eliminate. Better to say "I could not check" and have
# someone fix the credential.
outdated_probe() {
    local dir="$1"
    [[ -f "$dir/composer.json" ]] || { set_reason "no composer.json at $dir"; return 1; }

    local out rc=0
    out="$( cd "$dir" && composer outdated --direct --format=json \
              --no-interaction 2>/dev/null )" || rc=$?

    if [[ -z "$out" ]]; then
        set_reason "composer outdated produced no output (rc=$rc; registry unreachable or credentials rejected?)"
        return 1
    fi

    local parsed
    if ! parsed="$( OUTDATED_JSON="$out" python3 - <<'PY'
import json, os, sys
try:
    d = json.loads(os.environ["OUTDATED_JSON"])
except Exception as e:
    print("OUT_PARSE_ERROR " + repr(e)); sys.exit(0)
for p in d.get("installed", []) or []:
    name, cur, latest = p.get("name"), p.get("version"), p.get("latest")
    if latest and cur != latest:
        print("OUTDATED %s %s -> %s" % (name, cur, latest))
PY
    )"; then
        set_reason "composer outdated JSON parser crashed"
        return 1
    fi

    if printf '%s' "$parsed" | grep -q '^OUT_PARSE_ERROR'; then
        set_reason "composer outdated JSON was unparseable"
        return 1
    fi

    printf '%s' "$parsed" | sed '/^$/d'
    return 0
}

# --- upstream: our constraints vs the upstream project's main branch --------
#
# Reconciled to the box copy's REAL behaviour: this fetches the upstream
# repository's composer.json from its `main` branch. The reconstruction had
# guessed Packagist p2 (latest tagged RELEASE) and then written a comment
# asserting that guess as fact. Both are defensible signals; only one of them
# was ever what ran, and the comment must describe the code.
#
# Assumption, stated rather than hidden: the upstream Composer package name is
# also its GitHub <org>/<repo> path. True for goalgorilla/open_social. If that
# stops holding for some future site the fetch 404s and this axis goes BLIND,
# which is the correct outcome rather than a silent skip.
upstream_probe() {
    local dir="$1" pkg="$2"
    [[ -n "$pkg" ]] || return 3                       # SKIP: nothing declared
    command -v curl >/dev/null 2>&1 || { set_reason "curl missing"; return 1; }

    local url="https://raw.githubusercontent.com/${pkg}/main/composer.json"
    local body
    if ! body="$(curl -fsSL --max-time 30 "$url" 2>/dev/null)" || [[ -z "$body" ]]; then
        set_reason "could not fetch $url"
        return 1
    fi

    # Profile constraints win over project constraints where both declare a
    # package — ported from the box copy; the reconstruction had dropped it.
    local parsed
    if ! parsed="$( UPSTREAM_JSON="$body" OUR_COMPOSER="$dir/composer.json" \
                    PROFILE_COMPOSER="$dir/html/profiles/custom/nwc/composer.json" \
                    python3 - <<'PY'
import json, os, sys
def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return {}
try:
    up = json.loads(os.environ["UPSTREAM_JSON"]).get("require", {}) or {}
except Exception as e:
    print("UPSTREAM_PARSE_ERROR " + repr(e)); sys.exit(0)
proj = load(os.environ["OUR_COMPOSER"]).get("require", {}) or {}
prof = load(os.environ["PROFILE_COMPOSER"]).get("require", {}) or {}
ours = {**proj, **prof}
if not ours:
    print("UPSTREAM_PARSE_ERROR 'no local require block'"); sys.exit(0)
for k, up_v in sorted(up.items()):
    if not k.startswith("drupal/") and k != "webonyx/graphql-php":
        continue
    our_v = ours.get(k)
    if our_v and our_v != up_v:
        print("UPSTREAM %s: ours=%s upstream=%s" % (k, our_v, up_v))
PY
    )"; then
        set_reason "upstream comparison parser crashed"
        return 1
    fi

    if printf '%s' "$parsed" | grep -q '^UPSTREAM_PARSE_ERROR'; then
        set_reason "upstream or local composer.json unparseable"
        return 1
    fi

    printf '%s' "$parsed" | sed '/^$/d'
    return 0
}

# ---------------------------------------------------------------------------
# Notification. The token reaches curl only through a 0600 config file — never
# on argv, where it would sit in /proc/<pid>/cmdline for any local user to read.
# ---------------------------------------------------------------------------
post_issue() {
    local title="$1" body="$2"
    if [[ ! -r "$AUDIT_TOKEN_FILE" ]]; then
        log "NOTIFY-FAIL: cannot read audit token at $AUDIT_TOKEN_FILE — issue NOT posted: $title"
        return 1
    fi
    command -v curl >/dev/null 2>&1 || { log "NOTIFY-FAIL: curl missing"; return 1; }

    local preamble
    preamble="host: $(hostname)"$'\n'"time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"$'\n'"producer: $(provenance)"$'\n\n'

    local cfg; cfg="$(mktemp)"; chmod 600 "$cfg"
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$(cat "$AUDIT_TOKEN_FILE")" > "$cfg"

    local resp
    if ! resp="$(curl -sS --fail-with-body -X POST -K "$cfg" \
        --data-urlencode "title=${title}" \
        --data-urlencode "description=${preamble}${body}" \
        "${API}" 2>&1)"; then
        rm -f "$cfg"
        log "NOTIFY-FAIL: POST rejected: $resp"
        return 1
    fi
    rm -f "$cfg"
    log "posted: $title"
    return 0
}

# ---------------------------------------------------------------------------
# R2 helper: carry a blind axis's previous lines forward, so blindness can
# never be mistaken for "all findings resolved".
# ---------------------------------------------------------------------------
carry_forward() {
    local baseline_file="$1" axis="$2" pattern
    [[ -f "$baseline_file" ]] || return 0
    case "$axis" in
        adv)      pattern='^(ADV|ABANDONED) ' ;;
        outdated) pattern='^OUTDATED ' ;;
        upstream) pattern='^UPSTREAM ' ;;
        *)        return 0 ;;
    esac
    grep -E "$pattern" "$baseline_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    mkdir -p "$CACHE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true

    maybe_git_pull
    log "START run — $(provenance)"

    command -v composer >/dev/null 2>&1 || { log "CONFIG-ERROR: composer not found — aborting"; exit 3; }
    command -v python3  >/dev/null 2>&1 || { log "CONFIG-ERROR: python3 not found — aborting";  exit 3; }
    [[ ${#SITES[@]} -gt 0 ]] || { log "CONFIG-ERROR: no sites configured — aborting"; exit 3; }

    local changed_sites=0 blind_sites=0 notify_failed=0 audited_sites=0
    local summary="" entry site dir upstream

    for entry in "${SITES[@]}"; do
        IFS=':' read -r site dir upstream <<< "$entry"
        if [[ -z "${site:-}" || -z "${dir:-}" ]]; then
            log "CONFIG-ERROR: malformed SITES entry '$entry' — skipping"
            continue
        fi
        log "START $site (dir=$dir, upstream=${upstream:-none})"

        local baseline_file="$CACHE_DIR/baseline-${site}.txt"
        local blind_axes="" ok_axes="" skip_axes="" fp="" site_blind_detail=""
        local axis out st carried

        if [[ ! -d "$dir" ]]; then
            # A missing site directory is blindness, not an absence of findings.
            log "$site: BLIND (all axes) — site dir not found: $dir"
            blind_axes="adv outdated upstream"
            site_blind_detail+="- \`$site\`: site directory not found: \`$dir\`"$'\n'
            for axis in adv outdated upstream; do
                carried="$(carry_forward "$baseline_file" "$axis")"
                [[ -n "$carried" ]] && fp+="$carried"$'\n'
            done
        else
            for axis in adv outdated upstream; do
                set +e
                case "$axis" in
                    adv)      out="$(adv_probe      "$dir")"            ; st=$? ;;
                    outdated) out="$(outdated_probe "$dir")"            ; st=$? ;;
                    upstream) out="$(upstream_probe "$dir" "$upstream")"; st=$? ;;
                esac
                set -e
                case "$st" in
                    0)
                        ok_axes+="$axis "
                        [[ -n "$out" ]] && fp+="$out"$'\n'
                        printf '%s\n' "$(now_epoch)" > "$CACHE_DIR/lastgood-${site}-${axis}.txt"
                        log "$site/$axis: OK ($(count_lines "$out") line(s))"
                        ;;
                    3)
                        skip_axes+="$axis "
                        log "$site/$axis: SKIP (not configured)"
                        ;;
                    *)
                        blind_axes+="$axis "
                        local reason; reason="$(get_reason)"
                        log "$site/$axis: BLIND — ${reason:-unknown reason}"
                        site_blind_detail+="- \`$site\` / **$axis**: ${reason:-unknown reason}"$'\n'
                        # R2: keep what we last actually saw for this axis.
                        carried="$(carry_forward "$baseline_file" "$axis")"
                        [[ -n "$carried" ]] && fp+="$carried"$'\n'
                        ;;
                esac
            done
        fi

        # ---- per-site rollup ------------------------------------------------
        #
        # Blindness and findings are ORTHOGONAL, and deliberately so. An early
        # cut of this fix skipped the findings comparison whenever any axis was
        # blind — which meant the permanently-blind `outdated` axis on the
        # build host would have suppressed CVE reporting forever. That is the
        # same defect class in a new costume: a check that cannot fire.
        #
        # So a blind site still gets its fingerprint compared and its findings
        # posted; blindness only adds the streak, the cadence notification and
        # the non-zero exit. R2 is preserved by carry_forward: a blind axis
        # contributes its PREVIOUS lines verbatim, so advancing the baseline
        # cannot erase a finding we merely failed to re-observe.
        local recovered=""
        if [[ -n "$blind_axes" ]]; then
            blind_sites=$((blind_sites + 1))
            local streak_file="$CACHE_DIR/blindstreak-${site}.txt" streak=0
            [[ -f "$streak_file" ]] && streak="$(cat "$streak_file" 2>/dev/null || echo 0)"
            streak=$((streak + 1))
            printf '%s\n' "$streak" > "$streak_file"

            # Staleness: name the day we last actually saw each blind axis, so
            # "how long have we been flying blind" never has to be excavated
            # from a log file again.
            for axis in $blind_axes; do
                local lg="$CACHE_DIR/lastgood-${site}-${axis}.txt" age="never in recorded history"
                if [[ -f "$lg" ]]; then
                    local then_e; then_e="$(cat "$lg" 2>/dev/null || echo 0)"
                    age="$(( ( $(now_epoch) - then_e ) / 86400 )) day(s) ago"
                fi
                site_blind_detail+="  - last successful \`$axis\` audit of \`$site\`: $age"$'\n'
            done

            log "$site: COULD_NOT_AUDIT (blind: ${blind_axes% }) — consecutive blind runs: $streak"
            log "$site: blind axes carried forward from the last sighted run (baseline not overwritten with a hole)"

            # R4: notify on the first blind run, then on a fixed cadence.
            if (( streak == 1 || BLIND_EVERY <= 1 || streak % BLIND_EVERY == 0 )); then
                if ! post_issue \
                    "daily-audit: COULD NOT AUDIT ${site} (${streak} consecutive run(s))" \
                    "**This audit did not run. That is a failure, not an all-clear.**"$'\n\n'"The axes below could not be checked, so the dependency state of \`${site}\` is currently UNKNOWN — not clean."$'\n\n'"${site_blind_detail}"$'\n'"consecutive blind runs: **${streak}**"$'\n\n'"Re-notification cadence: the first blind run, then every ${BLIND_EVERY} consecutive blind runs. The process exit code is non-zero on EVERY blind run, so the continuous signal is the exit status, not this issue."$'\n\n'"Do NOT close this as \"no findings\" — there were no findings because nobody looked."$'\n\n'"Triage: see docs/security/dependency-refresh-cadence.md."; then
                    notify_failed=1
                fi
            else
                log "$site: blind notification suppressed (streak $streak, cadence every $BLIND_EVERY) — exit code still non-zero"
            fi
        else
            # ---- fully sighted: audited-clean or audited-found-N ------------
            audited_sites=$((audited_sites + 1))
            local prev_streak_file="$CACHE_DIR/blindstreak-${site}.txt"
            if [[ -f "$prev_streak_file" ]]; then
                local prev; prev="$(cat "$prev_streak_file" 2>/dev/null || echo 0)"
                if [[ "${prev:-0}" -gt 0 ]]; then
                    recovered="Recovered after ${prev} consecutive blind run(s)."
                    log "$site: RECOVERED after $prev blind run(s)"
                fi
                rm -f "$prev_streak_file"
            fi
        fi

        # ---- findings comparison (runs for blind and sighted sites alike) ---
        fp="$(printf '%s' "$fp" | sed '/^$/d' | sort -u)"
        local n_find; n_find="$(printf '%s' "$fp" | grep -cE '^(ADV|ABANDONED) ' 2>/dev/null || true)"
        n_find="${n_find:-0}"
        if [[ -n "$blind_axes" ]]; then
            # Deliberately NOT called AUDITED_*: part of this site was not seen,
            # so the count is a floor, not a verdict.
            log "$site: findings visible despite blindness: ${n_find} (from axes: ${ok_axes:-none})"
        elif [[ "$n_find" -eq 0 ]]; then
            log "$site: AUDITED_CLEAN (axes ok: ${ok_axes% }${skip_axes:+; skipped: ${skip_axes% }})"
        else
            log "$site: AUDITED_FOUND_${n_find} (axes ok: ${ok_axes% }${skip_axes:+; skipped: ${skip_axes% }})"
        fi

        local current_file="$CACHE_DIR/current-${site}.txt"
        printf '%s\n' "$fp" > "$current_file"

        if [[ ! -f "$baseline_file" ]]; then
            log "$site: no baseline yet — creating one (silent run; not posting)"
            cp "$current_file" "$baseline_file"
            continue
        fi

        if diff -q "$baseline_file" "$current_file" >/dev/null 2>&1; then
            log "$site: no change (silent)"
            continue
        fi

        log "$site: STATE CHANGE detected"
        changed_sites=$((changed_sites + 1))
        local delta; delta="$(diff -u "$baseline_file" "$current_file" | head -120 || true)"
        summary+="### ${site}"$'\n'
        [[ -n "$recovered" ]] && summary+="_${recovered}_"$'\n'
        if [[ -n "$blind_axes" ]]; then
            summary+="> ⚠️ PARTIAL: the \`${blind_axes% }\` axis could not be checked on this run, so this diff is a floor, not a complete picture. Values for that axis are carried over from the last sighted run."$'\n'
        fi
        summary+=$'\n'"\`\`\`diff"$'\n'"${delta}"$'\n'"\`\`\`"$'\n\n'
        # The baseline advances only after a successful post (below), so a
        # failed notification is retried next run instead of being swallowed.
    done

    # ---- one batched findings issue per run --------------------------------
    if (( changed_sites > 0 )); then
        log "posting summary issue ($changed_sites site(s) changed)"
        if post_issue \
            "daily-audit: ${changed_sites} site(s) changed on $(date -u +%Y-%m-%d)" \
            "sites scanned: ${#SITES[@]}"$'\n'"sites audited: ${audited_sites}"$'\n'"sites COULD NOT AUDIT: ${blind_sites}"$'\n\n'"Fingerprint diff per site (\`+\` = new, \`-\` = gone):"$'\n\n'"- \`ADV <pkg> <id> <severity>\` — composer audit finding"$'\n'"- \`ABANDONED <pkg>\` — package abandoned upstream"$'\n'"- \`OUTDATED <pkg> <cur> -> <latest>\` — newer release available"$'\n'"- \`UPSTREAM <pkg>: ours=X upstream=Y\` — upstream main differs from ours"$'\n\n'"${summary}"$'\n'"Triage: see docs/security/dependency-refresh-cadence.md."; then
            for entry in "${SITES[@]}"; do
                IFS=':' read -r site dir upstream <<< "$entry"
                [[ -n "${site:-}" ]] || continue
                if [[ -f "$CACHE_DIR/current-${site}.txt" ]]; then
                    cp "$CACHE_DIR/current-${site}.txt" "$CACHE_DIR/baseline-${site}.txt"
                fi
            done
        else
            notify_failed=1
            log "summary post failed — baselines NOT advanced (will retry next run)"
        fi
    fi

    log "DONE (audited=$audited_sites changed=$changed_sites could_not_audit=$blind_sites)"

    # R1/R4: blindness is a failure and says so through the exit code on EVERY
    # run, whether or not an issue was posted this time.
    if (( blind_sites > 0 )); then
        log "EXIT 2 — COULD NOT AUDIT ${blind_sites} site(s). This run verified nothing for them."
        exit 2
    fi
    if (( notify_failed > 0 )); then
        log "EXIT 4 — audited successfully, but a required notification could not be delivered."
        exit 4
    fi
    exit 0
}

main "$@"

# ===========================================================================
# WIRING
# ===========================================================================
#
# 1. TOKEN — a Developer/api PAT scoped to the ops-log project ONLY, installed
#    0600 on the audit host:
#        umask 077 && printf '%s\n' <the-token> > ~/.config/nwp-audit.token
#    (or point NWP_AUDIT_TOKEN_FILE at an existing path).
#
# 2. SCHEDULE (02:30 UTC daily). The cron entry must invoke THIS file out of a
#    git checkout — never a hand-copied file in ~/bin, which is exactly how the
#    two versions drifted apart unnoticed:
#
#        30 2 * * * NWP_AUDIT_GIT_PULL=1 NWP_GITLAB_HOST=<host> \
#            NWP_OPS_LOG_PROJECT=<id> NWP_AUDIT_TOKEN_FILE=$HOME/.config/<f>.token \
#            <nwp-root>/scripts/nwp-daily-audit.sh
#
#    `pl schedule` owns NWP cron entries; migrate this line to it if/when that
#    command grows a first-class audit verb. Any legacy ~/bin/nwp-daily-audit
#    must be a shim that execs this path, so both entry points run reviewed
#    code.
#
# 3. ADD A SITE — append "site-key:site-dir:upstream-pkg" to SITES, or set
#    NWP_AUDIT_SITES for a one-off run. The site needs a composer.lock; it does
#    NOT need a running container.
#
# 4. TRIAGE
#    - "COULD NOT AUDIT" issue  => the audit itself is broken. Fix the probe
#      named in the body. Never close it as "no findings" — there were no
#      findings because nobody looked.
#    - "N site(s) changed" issue => real dependency movement; see the legend in
#      the issue body and docs/security/dependency-refresh-cadence.md.
# ===========================================================================
