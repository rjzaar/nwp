#!/bin/bash
set -uo pipefail
################################################################################
# pl library — build and publish the docs library, in two versions
#
# WHY THIS EXISTS
# ---------------
# The console holds no docs, the same way it holds no sites: the corpus lives in
# this repo, on the workstation. So the workstation builds two bundles and ships
# them to the console host, exactly as `pl fleet publish` ships fleet state.
#
#   library.json         every doc, classified by audience. The "complete set as
#                        is". The console renders it filtered by the reader's
#                        library_shards().
#   library-public.json  ONLY the docs certified public — the artefact you could
#                        put on a website, and what /library?view=public shows.
#
# WHY A SEPARATE VERB AND NOT A FLEET FEED
# ----------------------------------------
#   freshness  fleet state is published every 30 minutes because a RAG grade
#              goes stale in minutes. Docs change on a commit, days apart. The
#              two want different cadences and different max-ages.
#   size       the corpus is ~110 KB of prose against a ~40 KB fleet snapshot.
#              Riding the */30 cron would triple that cron's bandwidth forever
#              to re-ship bytes that did not change.
#   provenance a doc bundle's useful provenance is the git commit it was built
#              from (and whether the tree was dirty). Fleet state's is the host
#              and the clock. Same idiom, different facts.
#   blast      a library build can REFUSE (see below). Wiring a refusal into the
#              fleet cron would take out the Fleet and Todo panes because a doc
#              was mis-tagged.
#
# THE IDENTITY CHECK IS NOT NEW CODE
# ----------------------------------
# It is tests/helpers/pubrel-docs-check.sh — the six operator-identity rules and
# the fail-closed gitleaks discipline landed with B1 — sourced and applied per
# file. This script adds NO patterns of its own. It produces one verdict per doc:
#
#   clean    the grep mirror found nothing AND gitleaks scanned it and found
#            nothing
#   dirty    either found something
#   unknown  gitleaks could not run, errored, or wrote no/an unreadable report
#
# `unknown` never publishes. On a machine with no gitleaks, EVERY doc is unknown
# and the build refuses every public and contributor doc — which is the correct
# behaviour for a verb that authorises publication, and is a test case.
#
#   pl library check    verdicts + classification, build nothing
#   pl library build    build both bundles locally (refuses on any rule break)
#   pl library publish  build, then ship both to the console host (0600, atomic)
#   pl library status   what is built here / published on the host
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"

# impact_rm_scratch: the tree's single audited primitive for removing a throwaway
# directory this process created (lib/impact.sh). The scan sandbox below is a
# `mktemp -d` this function made three lines earlier — not scope a human cares
# about — but a bare `rm -rf` is indistinguishable from the real thing to any
# scanner, so it goes through the audited primitive instead. A future edit that
# passes the wrong variable then gets a refusal rather than a catastrophe.
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/impact.sh"

# The existing checker. Sourcing it (rather than reimplementing it) is the whole
# point: one identity ruleset, one place it can be wrong.
PUBREL_HELPER="$REPO_ROOT/tests/helpers/pubrel-docs-check.sh"

MANIFEST="${NWP_LIBRARY_MANIFEST:-$PROJECT_ROOT/docs/library-manifest.yml}"
OUT_DIR="${NWP_LIBRARY_OUT:-$PROJECT_ROOT/private/library}"
BUILDER="$REPO_ROOT/scripts/console/app/library.py"
DEFAULT_REMOTE_REL=".local/share/nwp-console"
SSH_STEP_BUDGET="${NWP_SSH_STEP_BUDGET:-45}"
SSH_SHIP_BUDGET="${NWP_SSH_SHIP_BUDGET:-120}"

# The corpus. Two globs, deliberately narrow: this is the "library that was
# created" (the overview set) plus the how-to guides. Everything else in docs/
# is proposals, ADRs and reports — not library material, and silently sweeping
# them in is how a corpus grows a doc nobody classified.
CORPUS_GLOBS=("docs/overview/*.md" "docs/guides/howto-*.md")

_console_cfg_file() {
    if [ -n "${NWP_CONSOLE_CONFIG:-}" ]; then
        [ -f "$NWP_CONSOLE_CONFIG" ] && printf '%s' "$NWP_CONSOLE_CONFIG"
        return 0
    fi
    local f
    for f in "$PROJECT_ROOT/nwp.yml" "$HOME/nwp-instances/_global/nwp.yml" "$HOME/nwp/nwp.yml"; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 0
}

_console_cfg() { # $1 key under settings.console, $2 default
    local f v=""
    f=$(_console_cfg_file)
    if [ -n "$f" ] && command -v yq >/dev/null 2>&1; then
        v=$(yq e ".settings.console.$1 // \"\"" "$f" 2>/dev/null | grep -v '^null$' || true)
    fi
    printf '%s' "${v:-$2}"
}

CONSOLE_HOST="${NWP_CONSOLE_HOST:-$(_console_cfg host "")}"

show_help() {
    cat <<EOF
${BOLD}pl library${NC} — build and publish the docs library (full + public)

${BOLD}USAGE:${NC}
    pl library check   [--root <dir>] [--manifest <file>]
    pl library build   [--root <dir>] [--manifest <file>] [--out <dir>] [--sites a,b]
    pl library publish [--to <ssh-host>] [--dest <dir>] [--dry-run] [--quiet]
    pl library status  [--to <ssh-host>]

${BOLD}THE TWO VERSIONS:${NC}
    library.json         every doc, classified. The complete set as is.
    library-public.json  only docs certified public — purged of operator
                         identity, naming only allowlisted sites.

${BOLD}FAIL-CLOSED:${NC}
    A doc is PRIVATE unless docs/library-manifest.yml marks it otherwise, and a
    doc may be public or contributor only if the identity checker returned a
    positive 'clean'. "Could not scan" is 'unknown', and unknown never
    publishes. Any rule break refuses the WHOLE build — no bundle is written.

${BOLD}OPTIONS:${NC}
    --root <dir>      build from this tree instead of the repo (tests use this)
    --manifest <file> audience manifest (default docs/library-manifest.yml)
    --out <dir>       where to write the bundles (default private/library/)
    --sites a,b       fleet site vocabulary. Default: nwp.yml + sites/*/.
                      An EMPTY vocabulary refuses the build — a scan that knows
                      no site names would call every doc free of site names.
    --to <ssh-host>   console host (default settings.console.host in nwp.yml)
    --dest <dir>      absolute directory on the host (default \$HOME/$DEFAULT_REMOTE_REL)
EOF
}

# --- corpus ------------------------------------------------------------------
_corpus_files() { # $1 root -> repo-relative paths, one per line
    local root="$1" g
    for g in "${CORPUS_GLOBS[@]}"; do
        # shellcheck disable=SC2086
        ( cd "$root" && compgen -G "$g" || true )
    done | sort -u
}

# --- site vocabulary ---------------------------------------------------------
# Sources, unioned: --sites, $NWP_LIBRARY_SITES, nwp.yml `sites:` keys, sites/*/.
# Deliberately NOT defaulted to a hardcoded list: a stale hardcoded vocabulary
# would go quietly blind to a new site, which is the failure mode this whole
# check exists to prevent.
_site_vocab() { # $1 explicit csv, $2 root
    local explicit="$1" root="$2" out=""
    if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
    if [ -n "${NWP_LIBRARY_SITES:-}" ]; then printf '%s' "$NWP_LIBRARY_SITES"; return 0; fi
    local cfg; cfg=$(_console_cfg_file)
    if [ -n "$cfg" ] && command -v yq >/dev/null 2>&1; then
        out=$(yq e '.sites | keys | .[]' "$cfg" 2>/dev/null | grep -vE '^(null|)$' | tr '\n' ',' || true)
    fi
    # The last published fleet snapshot names every site `pl rag` graded, which
    # is the most complete list this machine has when nwp.yml is not readable.
    local fs="$PROJECT_ROOT/private/fleet/fleet-state.json"
    if [ -f "$fs" ] && command -v python3 >/dev/null 2>&1; then
        out="${out}$(python3 - "$fs" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
rows = ((d.get("feeds") or {}).get("rag") or {}).get("data") or {}
if isinstance(rows, dict):
    rows = rows.get("sites") or []
for r in rows if isinstance(rows, list) else []:
    if isinstance(r, dict) and r.get("site"):
        print(str(r["site"]), end=",")
PY
)"
    fi
    local d
    for d in "$root"/sites/*/; do
        [ -d "$d" ] || continue
        out="${out}$(basename "$d"),"
    done
    printf '%s' "$(printf '%s' "$out" | tr ',' '\n' | grep -vE '^$' | sort -u | tr '\n' ',' | sed 's/,$//')"
}

# --- verdicts ----------------------------------------------------------------
# One JSON object {path: clean|dirty|unknown}. Two independent checks, and the
# WORSE answer wins:
#
#   grep mirror  PUBREL_IDENTITY_RE over the allowlist-masked file. Pure bash,
#                always runs, cannot be skipped. This is why a missing gitleaks
#                cannot make the whole check vacuous.
#   gitleaks     the full .gitleaks.toml, over a tree containing ONLY the
#                candidate docs and NO .gitleaksignore. The ledger is excluded
#                on purpose: a fingerprint that suppresses a finding in the repo
#                must not also suppress it in a doc about to be published.
_verdicts() { # $1 root, $2 file-list file, $3 out json
    local root="$1" list="$2" out="$3"

    # shellcheck source=/dev/null
    if ! source "$PUBREL_HELPER" 2>/dev/null; then
        print_error "cannot source the identity checker: $PUBREL_HELPER"
        return 2
    fi
    if [ -z "${PUBREL_IDENTITY_RE:-}" ] || [ -z "${PUBREL_ALLOWLIST_SED:-}" ]; then
        print_error "the identity checker did not define its patterns — refusing to guess"
        return 2
    fi

    # ---- half 1: the grep mirror (always runs) -------------------------------
    local dirty_list; dirty_list=$(mktemp)
    local f hits
    while read -r f; do
        [ -n "$f" ] || continue
        hits=$(sed "$PUBREL_ALLOWLIST_SED" "${root}/${f}" 2>/dev/null | grep -ciE "$PUBREL_IDENTITY_RE")
        [ "${hits:-0}" -gt 0 ] && printf '%s\n' "$f" >> "$dirty_list"
    done < "$list"

    # ---- half 2: the gitleaks backstop --------------------------------------
    local scan_state="unknown" gl_bin report scan_dir gl_rc=0
    gl_bin="$(pubrel_gitleaks_bin 2>/dev/null || true)"
    if [ -z "$gl_bin" ] || [ ! -x "$gl_bin" ]; then
        print_warning "no gitleaks binary — every doc's verdict is 'unknown'"
        print_hint "  install gitleaks or set NWP_GITLEAKS_BIN; public/contributor docs cannot publish without it"
    else
        scan_dir=$(mktemp -d); report=$(mktemp)
        while read -r f; do
            [ -n "$f" ] || continue
            mkdir -p "${scan_dir}/$(dirname "$f")"
            cp "${root}/${f}" "${scan_dir}/${f}" 2>/dev/null || true
        done < "$list"
        cp "$REPO_ROOT/.gitleaks.toml" "${scan_dir}/.gitleaks.toml"
        # NO .gitleaksignore is copied — see the comment above.
        ( cd "$scan_dir" && "$gl_bin" detect --no-git --source . --config .gitleaks.toml \
              --report-format json --report-path "$report" --redact --no-banner \
              >/dev/null 2>&1 ) || gl_rc=$?
        if [ "$gl_rc" -ne 0 ] && [ "$gl_rc" -ne 1 ]; then
            print_warning "gitleaks exited $gl_rc (scanner error, not a verdict) — verdicts stay 'unknown'"
        elif [ ! -s "$report" ]; then
            print_warning "gitleaks wrote no report — verdicts stay 'unknown'"
        else
            local found
            found=$(python3 - "$report" <<'PY' 2>/dev/null
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(3)
if not isinstance(rows, list):
    sys.exit(3)
for r in rows:
    print(r.get("File", ""))
PY
) || { found=""; gl_rc=99; }
            if [ "$gl_rc" -eq 99 ]; then
                print_warning "gitleaks report unreadable — verdicts stay 'unknown'"
            else
                scan_state="ran"
                printf '%s\n' "$found" | grep -vE '^$' >> "$dirty_list" || true
            fi
        fi
        impact_rm_scratch "$scan_dir" >/dev/null \
            || print_warning "library: could not remove scratch dir $scan_dir"
        rm -f "$report"
    fi

    python3 - "$list" "$dirty_list" "$scan_state" "$out" <<'PY'
import json, sys
list_f, dirty_f, scan_state, out_f = sys.argv[1:5]
paths = [l.strip() for l in open(list_f) if l.strip()]
dirty = {l.strip().lstrip("./") for l in open(dirty_f) if l.strip()}
# "ran" == gitleaks actually produced a verdict we could read. Anything else and
# a doc that merely looks clean to the grep mirror is still UNKNOWN, because
# half the check did not happen. That is the whole fail-closed contract.
verdicts = {p: ("dirty" if p in dirty else ("clean" if scan_state == "ran" else "unknown"))
            for p in paths}
json.dump(verdicts, open(out_f, "w"), indent=1, sort_keys=True)
PY
    rm -f "$dirty_list"
    return 0
}

_git_meta() { # prints "commit dirty"
    local c d=0
    c=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')
    git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || d=1
    printf '%s %s' "$c" "$d"
}

# --- build -------------------------------------------------------------------
_build() { # $1 root, $2 manifest, $3 out dir, $4 sites csv, $5 quiet
    local root="$1" manifest="$2" out_dir="$3" sites="$4" quiet="$5"

    [ -f "$manifest" ] || { print_error "no manifest: $manifest"; return 1; }
    [ -f "$BUILDER" ]  || { print_error "no builder: $BUILDER"; return 1; }
    command -v python3 >/dev/null 2>&1 || { print_error "python3 is required"; return 1; }

    local list; list=$(mktemp)
    _corpus_files "$root" > "$list"
    if [ ! -s "$list" ]; then
        print_error "the corpus globs matched NOTHING under $root"
        print_hint "  ${CORPUS_GLOBS[*]}"
        print_hint "  An empty corpus is not an empty library — it is a broken build."
        rm -f "$list"; return 1
    fi

    local verdicts; verdicts=$(mktemp)
    _verdicts "$root" "$list" "$verdicts" || { rm -f "$list" "$verdicts"; return 1; }

    local vocab; vocab=$(_site_vocab "$sites" "$root")
    local gm; gm=$(_git_meta)

    mkdir -p "$out_dir"; chmod 700 "$out_dir" 2>/dev/null || true
    python3 "$BUILDER" build \
        --manifest "$manifest" --root "$root" --files "$list" \
        --sites "$vocab" --verdicts "$verdicts" \
        --out-full "$out_dir/library.json" --out-public "$out_dir/library-public.json" \
        --host "$(hostname)" --user "${USER:-}" \
        --git-commit "${gm%% *}" --git-dirty "${gm##* }"
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        print_error "library build REFUSED — nothing was written."
        print_hint "  Fix docs/library-manifest.yml (or the doc) and re-run."
        print_hint "  See the reasons above; 'not certified clean' means the identity"
        print_hint "  checker said dirty, or could not scan at all."
    elif [ "$quiet" != true ]; then
        print_success "library built in $out_dir"
        _summarise "$out_dir"
    fi
    rm -f "$list" "$verdicts"
    return $rc
}

_summarise() { # $1 out dir
    local d="$1"
    python3 - "$d/library.json" "$d/library-public.json" <<'PY' 2>/dev/null || true
import json, sys
for f in sys.argv[1:]:
    try:
        b = json.load(open(f))
    except Exception:
        print(f"  {f}: unreadable"); continue
    counts = ", ".join(f"{k} {v}" for k, v in sorted(b.get("counts", {}).items()))
    g = b.get("generated_by", {})
    print(f"  {b.get('variant','?'):7s} {len(b.get('docs',[])):3d} docs  [{counts}]"
          f"  @{g.get('git_commit','?')}{'+dirty' if g.get('git_dirty') else ''}")
PY
}

# --- verbs -------------------------------------------------------------------
cmd_check() {
    local root="$PROJECT_ROOT" manifest="$MANIFEST"
    while [ $# -gt 0 ]; do
        case "$1" in
            --root) root="${2:-}"; shift 2 ;;      --root=*) root="${1#--root=}"; shift ;;
            --manifest) manifest="${2:-}"; shift 2 ;; --manifest=*) manifest="${1#--manifest=}"; shift ;;
            -h|--help) show_help; return 0 ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done
    local list verdicts
    list=$(mktemp); verdicts=$(mktemp)
    _corpus_files "$root" > "$list"
    [ -s "$list" ] || { print_error "corpus is empty under $root"; rm -f "$list" "$verdicts"; return 1; }
    _verdicts "$root" "$list" "$verdicts" || { rm -f "$list" "$verdicts"; return 1; }
    print_info "Identity verdicts (clean = may be public/contributor):"
    python3 - "$verdicts" "$manifest" <<'PY'
import json, sys, re
v = json.load(open(sys.argv[1]))
aud = {}
path = None
for line in open(sys.argv[2]):
    m = re.match(r"^  - path:\s*(\S+)", line)
    if m: path = m.group(1); aud[path] = "private"
    m = re.match(r"^    audience:\s*(\S+)", line)
    if m and path: aud[path] = m.group(1)
mark = {"clean": "ok     ", "dirty": "DIRTY  ", "unknown": "UNKNOWN"}
for p in sorted(v):
    a = aud.get(p, "private (unlisted)")
    flag = "  <-- REFUSES" if (a in ("public", "contributor") and v[p] != "clean") else ""
    print(f"  {mark.get(v[p], '?')} {a:22s} {p}{flag}")
PY
    rm -f "$list" "$verdicts"
}

cmd_build() {
    local root="$PROJECT_ROOT" manifest="$MANIFEST" out="$OUT_DIR" sites="" quiet=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --root) root="${2:-}"; shift 2 ;;      --root=*) root="${1#--root=}"; shift ;;
            --manifest) manifest="${2:-}"; shift 2 ;; --manifest=*) manifest="${1#--manifest=}"; shift ;;
            --out) out="${2:-}"; shift 2 ;;        --out=*) out="${1#--out=}"; shift ;;
            --sites) sites="${2:-}"; shift 2 ;;    --sites=*) sites="${1#--sites=}"; shift ;;
            --quiet|-q) quiet=true; shift ;;
            -h|--help) show_help; return 0 ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done
    _build "$root" "$manifest" "$out" "$sites" "$quiet"
}

cmd_publish() {
    local host="$CONSOLE_HOST" dest="" dry_run=false quiet=false sites=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --to) host="${2:-}"; shift 2 ;;    --to=*) host="${1#--to=}"; shift ;;
            --dest) dest="${2:-}"; shift 2 ;;  --dest=*) dest="${1#--dest=}"; shift ;;
            --sites) sites="${2:-}"; shift 2 ;; --sites=*) sites="${1#--sites=}"; shift ;;
            --dry-run) dry_run=true; shift ;;
            --quiet|-q) quiet=true; shift ;;
            -h|--help) show_help; return 0 ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done

    _build "$PROJECT_ROOT" "$MANIFEST" "$OUT_DIR" "$sites" "$quiet" || return 1

    if [ "$dry_run" = true ]; then
        print_info "--dry-run: nothing shipped (would go to ${host:-<no host>}:${dest:-\$HOME/$DEFAULT_REMOTE_REL})"
        return 0
    fi
    if [ -z "$host" ]; then
        print_error "no console host: pass --to <ssh-host> or set settings.console.host in nwp.yml"
        return 1
    fi
    if [ -z "$dest" ]; then
        local rhome
        rhome=$(timeout "$SSH_STEP_BUDGET" ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" \
                'printf %s "$HOME"' 2>/dev/null) \
            || { print_error "cannot ssh to $host (within ${SSH_STEP_BUDGET}s)"; return 1; }
        [ -n "$rhome" ] || { print_error "could not resolve \$HOME on $host"; return 1; }
        dest="$rhome/$DEFAULT_REMOTE_REL"
    fi
    case "$dest" in
        /|/etc|/etc/*|/usr|/usr/*|/bin/*|/sbin/*|*..*) print_error "refusing suspicious --dest: $dest"; return 1 ;;
        /*) : ;;
        *) print_error "--dest must be absolute: $dest"; return 1 ;;
    esac

    local f
    for f in library.json library-public.json; do
        [ "$quiet" = true ] || print_info "Shipping $f to ${host}:${dest}/$f (0600, atomic)"
        if ! timeout "$SSH_SHIP_BUDGET" ssh -o ConnectTimeout=20 -o BatchMode=yes "$host" \
                "umask 077; mkdir -p '$dest' && cat > '$dest/$f.tmp.\$\$' && chmod 600 '$dest/$f.tmp.\$\$' && mv -f '$dest/$f.tmp.\$\$' '$dest/$f'" \
                < "$OUT_DIR/$f"; then
            print_error "failed to ship $f to ${host}:${dest} (within ${SSH_SHIP_BUDGET}s)"
            return 1
        fi
        local local_size remote_size
        local_size=$(wc -c < "$OUT_DIR/$f" | tr -d ' ')
        remote_size=$(timeout "$SSH_STEP_BUDGET" ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" \
                      "wc -c < '$dest/$f'" 2>/dev/null | tr -d ' ' || true)
        if [ "$local_size" != "$remote_size" ]; then
            print_error "verification failed for $f: shipped $local_size bytes, host reports '${remote_size:-none}'"
            return 1
        fi
        [ "$quiet" = true ] || print_success "published $f ($local_size bytes)"
    done
    return 0
}

cmd_status() {
    local host="$CONSOLE_HOST"
    while [ $# -gt 0 ]; do
        case "$1" in
            --to) host="${2:-}"; shift 2 ;; --to=*) host="${1#--to=}"; shift ;;
            *) shift ;;
        esac
    done
    print_info "Local bundles: $OUT_DIR"
    if [ -f "$OUT_DIR/library.json" ]; then
        _summarise "$OUT_DIR"
        local age; age=$(( $(date +%s) - $(stat -c %Y "$OUT_DIR/library.json") ))
        echo "  age          : $((age / 3600)) h"
    else
        print_warning "  none yet — run: pl library build"
    fi
    if [ -n "$host" ]; then
        print_info "On ${host}:"
        # `… || print_warning` was a fail-open: print_warning returns 0 and it
        # was the verb's last statement, so an unreachable console host exited
        # 0 having measured nothing (ops#383). Estate rule: exit 2 CANNOT
        # VERIFY, never 0 — "$f: not published" above is a measurement this
        # branch may report; "the host did not answer" is not.
        if ! ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" \
            'd="$HOME/.local/share/nwp-console";
             for f in library.json library-public.json; do
               if [ -f "$d/$f" ]; then
                 printf "  %s  mtime: %s  size: %s  mode: %s\n" "$f" \
                   "$(date -r "$d/$f" -u +%FT%TZ)" "$(wc -c < "$d/$f" | tr -d " ")" "$(stat -c %a "$d/$f")"
               else
                 echo "  $f: not published"
               fi
             done' 2>/dev/null; then
            print_error "CANNOT VERIFY: ${host} did not answer — 'could not look' is not 'not published'"
            print_info  "recheck: re-run 'pl library status' when the host is reachable; the verdict clears on its own terms"
            return 2
        fi
    fi
}

case "${1:-help}" in
    check)   shift; cmd_check "$@" ;;
    build)   shift; cmd_build "$@" ;;
    publish) shift; cmd_publish "$@" ;;
    status)  shift; cmd_status "$@" ;;
    -h|--help|help) show_help ;;
    *) print_error "unknown subcommand: $1"; show_help; exit 1 ;;
esac
