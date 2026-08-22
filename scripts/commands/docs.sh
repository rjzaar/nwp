#!/bin/bash
#
# pl docs — recoverable retirement of dead documentation (ops#383).
#
# THE PROBLEM. A doc that has drifted past usefulness is worse than no doc: it
# is read with the authority of the repo and it teaches something false.
# `docs/COMMAND_INVENTORY.md` said so about itself ("Do not trust this
# inventory") for a month and stayed in the tree anyway, because the only two
# options were "leave it" and "delete it", and deleting a document nobody has
# re-read is a bet you cannot take back without git archaeology.
#
# THE OPERATOR'S REQUIREMENT (2026-08-22, verbatim):
#
#   "backup as you go so dead documents get put into a 'dead documents' (or
#    some other appropriate title) folder that can be checked if needed later.
#    It should be clear when clean up happens what is cleaned and what is
#    removed. Whatever is removed is still findable if a mistake in the process
#    has been made."
#
# So: retirement is a MOVE plus a LEDGER, never a delete. The file keeps its
# relative path inside a dated bucket under `docs/_retired/`, its content hash
# at the moment of retirement is recorded, and `pl docs restore <original-path>`
# puts it back. That last verb is the point: a mistake is undone by a command,
# not by an archaeologist.
#
#   pl docs retire <path> --reason='…' [--ref=ops#N] [--slug=NAME] [--json]
#       Move a tracked file or directory to
#       docs/_retired/<YYYY-MM-DD>-<slug>/<original relative path>,
#       append a row to docs/_retired/MANIFEST.md, and print BOTH what moved
#       and every tracked file that still points at the old path.
#
#   pl docs retired [--list] [--json] [--all]
#       What has been retired. Default lists the still-retired entries;
#       --all includes ones that have since been restored.
#
#   pl docs restore <original-path> [--allow-modified] [--json]
#       Put it back and mark the manifest row restored.
#
#   pl docs -h|--help
#
# WHY IT PRINTS INBOUND REFERENCES AND DOES NOT REFUSE ON THEM. Retiring
# `docs/reference/commands/` broke 45 markdown links, 328 `related_docs:`
# entries in .verification.yml and one live test fixture. Refusing to move
# until every reader is fixed is unusable (you cannot fix a link to a file you
# have not moved yet); moving silently is how a tree acquires 61 dead links.
# So the verb MEASURES the readers and prints them as work to do in this same
# MR. Nothing about that is advisory: `pl doc-truth` fails on the dead links
# the very next time it runs.
#
# EXIT CODES
#   0  did the thing
#   1  REFUSED — a precondition is not met (named, with the way out)
#   2  CANNOT VERIFY / usage — not a git checkout, no sha256, unparseable
#      manifest, bad flags. "I could not look" is never reported as success.
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# The SCANNED/EDITED tree honours a pre-set PROJECT_ROOT so the verb is testable
# against a fixture repo instead of only against the live checkout.
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/ui.sh" 2>/dev/null || {
    print_header(){ echo "== $* =="; }; print_error(){ echo "ERROR: $*" >&2; }
    print_success(){ echo "SUCCESS: $*"; }; print_warning(){ echo "WARNING: $*"; }
    print_info(){ echo "INFO: $*"; }; print_hint(){ echo "HINT: $*"; }
}

RETIRED_DIR="docs/_retired"
MANIFEST_REL="$RETIRED_DIR/MANIFEST.md"
NL=$'\n'

usage(){ sed -n '3,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

refuse(){ print_error "REFUSED: $1"; shift; local l; for l in "$@"; do echo "  $l" >&2; done; exit 1; }
cannot_verify(){ print_error "CANNOT VERIFY: $1"; shift; local l; for l in "$@"; do echo "  $l" >&2; done; exit 2; }

# ── preflight ────────────────────────────────────────────────────────────────
#
# Both of these are CANNOT VERIFY, not refusals: they say "this tool cannot
# establish the facts it needs", which is a different sentence from "the facts
# say no". Conflating them is how a missing tool becomes a green tick.
require_git(){
    git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
        || cannot_verify "not a git checkout: $PROJECT_ROOT" \
             "Retirement is a tracked move; without git there is nothing to move it in."
}
SHA_CMD=""
require_sha(){
    [ -n "$SHA_CMD" ] && return 0
    if command -v sha256sum >/dev/null 2>&1; then SHA_CMD="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then SHA_CMD="shasum -a 256"
    else
        cannot_verify "no sha256 tool (sha256sum / shasum) on this host" \
            "The manifest records content hashes so a restore can be PROVEN byte-identical." \
            "Refusing to retire a document whose recoverability cannot be evidenced."
    fi
}
sha_of_file(){ $SHA_CMD "$1" | awk '{print $1}'; }

# Deterministic hash of a directory: sha256 over the sorted "<sha>  <relpath>"
# listing of every file beneath it. Two trees hash equal iff every file's path
# AND content match, which is exactly the round-trip property `restore` claims.
sha_of_tree(){
    local dir="$1"
    ( cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z \
        | xargs -0 -r $SHA_CMD ) | $SHA_CMD | awk '{print "tree:" $1}'
}
tree_sums(){ ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r $SHA_CMD ); }

slugify(){
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/\.[a-z0-9]+$//; s#[^a-z0-9]+#-#g; s/^-+//; s/-+$//'
}

# Markdown table cells are pipe-delimited, so a reason containing `|` would
# silently split into two columns and every later field would shift by one.
# Escape on write, unescape on read — never drop the character.
esc(){ printf '%s' "$1" | sed 's/|/\&#124;/g' | tr -d '\n\r'; }
unesc(){ printf '%s' "$1" | sed 's/&#124;/|/g'; }
strip_ticks(){ printf '%s' "$1" | tr -d '`'; }

# ── the manifest ─────────────────────────────────────────────────────────────
MANIFEST_HEADER='# Retired documents — MANIFEST

Generated and maintained by `pl docs retire` / `pl docs restore` (ops#383).
**Do not hand-edit.** Every row below is a document that was measured dead and
moved — never deleted. The file still exists, at `retired to`, at the byte
content whose `sha256` is recorded here, and `restore command` puts it back.

| # | status | original path | kind | retired | restored | ref | sha256 | retired to | restore command | reason |
|---|--------|---------------|------|---------|----------|-----|--------|------------|-----------------|--------|'

ensure_manifest(){
    local m="$PROJECT_ROOT/$MANIFEST_REL"
    if [ ! -f "$m" ]; then
        mkdir -p "$(dirname "$m")"
        printf '%s\n' "$MANIFEST_HEADER" > "$m"
        return 0
    fi
    grep -q '^| # | status |' "$m" \
        || cannot_verify "manifest has no recognisable table header: $MANIFEST_REL" \
             "Refusing to append to a ledger whose shape this verb cannot parse —" \
             "a row appended into the wrong columns is a row nothing can restore."
}

# Emit every data row as TAB-separated fields (id, status, original, kind,
# retired, restored, ref, sha, dest, restorecmd, reason).
manifest_rows(){
    local m="$PROJECT_ROOT/$MANIFEST_REL"
    [ -f "$m" ] || return 0
    awk -F'|' '
        /^\|[[:space:]]*[0-9]+[[:space:]]*\|/ {
            out = ""
            for (i = 2; i <= NF - 1; i++) {
                f = $i
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", f)
                gsub(/`/, "", f)
                out = (out == "" ? f : out "\t" f)
            }
            print out
        }
    ' "$m"
}

next_id(){ local n; n="$(manifest_rows | awk -F'\t' 'END{print NR+0}')"; echo $((n + 1)); }

append_row(){
    ensure_manifest
    printf '| %s | %s | `%s` | %s | %s | %s | %s | `%s` | `%s` | `%s` | %s |\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "$(esc "${11}")" \
        >> "$PROJECT_ROOT/$MANIFEST_REL"
}

# Rewrite one row in place, keyed on its id. sed on a `| <id> |` anchor.
mark_row_restored(){
    local id="$1" today="$2" status="$3" m="$PROJECT_ROOT/$MANIFEST_REL"
    local tmp; tmp="$(mktemp)"
    awk -F'|' -v id="$id" -v today="$today" -v st="$status" '
        BEGIN { OFS="|" }
        {
            line = $0
            if (line ~ /^\|[[:space:]]*[0-9]+[[:space:]]*\|/) {
                rid = $2; gsub(/[[:space:]]/, "", rid)
                if (rid == id) {
                    $3 = " " st " "
                    $7 = " " today " "
                    line = $0
                }
            }
            print line
        }' "$m" > "$tmp"
    mv "$tmp" "$m"
}

# ── inbound references ───────────────────────────────────────────────────────
#
# Who still points at the thing we just moved? Tracked corpus only (git grep),
# excluding the manifest (which names it BY DESIGN) and the retired copy itself.
inbound_refs(){
    local path="$1"
    git -C "$PROJECT_ROOT" grep -In -F -e "$path" -- . \
        ":(exclude)$MANIFEST_REL" ":(exclude)$RETIRED_DIR" 2>/dev/null || true
}

# ── retire ───────────────────────────────────────────────────────────────────
cmd_retire(){
    local path="" reason="" ref="" slug="" as_json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --reason=*) reason="${1#--reason=}" ;;
            --reason)   shift; reason="${1:-}" ;;
            --ref=*)    ref="${1#--ref=}" ;;
            --ref)      shift; ref="${1:-}" ;;
            --slug=*)   slug="${1#--slug=}" ;;
            --json)     as_json=true ;;
            -*)         print_error "unknown option: $1"; usage; exit 2 ;;
            *)          [ -z "$path" ] && path="$1" || { print_error "unexpected argument: $1"; exit 2; } ;;
        esac
        shift
    done

    [ -n "$path" ] || { print_error "usage: pl docs retire <path> --reason='…' [--ref=ops#N]"; exit 2; }
    require_git; require_sha

    # Normalise to a repo-relative path so the ledger key is stable no matter
    # what the caller typed or which directory they typed it from.
    local abs rel
    abs="$(cd "$PROJECT_ROOT" && readlink -f "$path" 2>/dev/null || true)"
    [ -n "$abs" ] || abs="$PROJECT_ROOT/$path"
    rel="${abs#"$PROJECT_ROOT"/}"
    rel="${rel%/}"

    # 1. A reason is MANDATORY. The whole value of the ledger is that a future
    #    reader can tell a measured retirement from a tidy-up somebody felt
    #    like doing. Way out: say why. That is a fact the caller has, not a
    #    human act they have to invent (ops#361).
    if [ -z "${reason//[[:space:]]/}" ]; then
        refuse "--reason is required (retiring '$rel')" \
            "A retirement with no recorded reason is indistinguishable from a mistake." \
            "Say what you measured, e.g.:" \
            "  pl docs retire $rel --reason='55 of 119 verbs; superseded by pl commands --json' --ref=ops#383"
    fi

    [ -e "$PROJECT_ROOT/$rel" ] || refuse "path does not exist: $rel" \
        "Nothing to retire. Check the path, or 'pl docs retired --all' if it is already retired."

    # 2. Tracked-only. An untracked file has no history to fall back on, so
    #    "moved, recoverably" would be a claim this verb cannot keep.
    local tracked=0
    if [ -d "$PROJECT_ROOT/$rel" ]; then
        [ -n "$(git -C "$PROJECT_ROOT" ls-files -- "$rel" 2>/dev/null)" ] && tracked=1
    else
        git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && tracked=1
    fi
    [ "$tracked" -eq 1 ] || refuse "not tracked by git: $rel" \
        "Retirement preserves history; an untracked file has none to preserve." \
        "Either commit it first (then retire it), or just delete it — there is" \
        "nothing for this ledger to make recoverable."

    local kind="file"; [ -d "$PROJECT_ROOT/$rel" ] && kind="dir"
    local today; today="$(date +%Y-%m-%d)"
    [ -n "$slug" ] || slug="$(slugify "$(basename "$rel")")"
    [ -n "$slug" ] || slug="doc"
    local bucket="$RETIRED_DIR/${today}-${slug}"
    local dest="$bucket/$rel"

    # 3. Never clobber. A second same-day retirement of the same basename is a
    #    real case (two READMEs); --slug= is the way through, and it is a
    #    naming choice, not an approval.
    [ -e "$PROJECT_ROOT/$dest" ] && refuse "retirement target already exists: $dest" \
        "Something is already retired there. Either restore it first" \
        "  pl docs restore $rel" \
        "or give this retirement its own bucket:" \
        "  pl docs retire $rel --reason='…' --slug=${slug}-2"

    # Hash BEFORE the move: the manifest records the content at retirement.
    local sha
    if [ "$kind" = dir ]; then sha="$(sha_of_tree "$PROJECT_ROOT/$rel")"
    else sha="$(sha_of_file "$PROJECT_ROOT/$rel")"; fi

    # Measure readers before the move, while the old path is still the truth.
    local refs; refs="$(inbound_refs "$rel")"
    local n_refs; n_refs="$(printf '%s' "$refs" | grep -c . || true)"

    mkdir -p "$PROJECT_ROOT/$(dirname "$dest")"
    git -C "$PROJECT_ROOT" mv "$rel" "$dest" \
        || cannot_verify "git mv failed: $rel → $dest" "The tree is unchanged; nothing was recorded."

    local n_files=1
    if [ "$kind" = dir ]; then
        # One sidecar per bucket (a bucket holds exactly one retirement — a
        # same-day, same-slug second one is refused above), so the name needs
        # no disambiguator and `restore` can find it without re-deriving a slug.
        tree_sums "$PROJECT_ROOT/$dest" > "$PROJECT_ROOT/$bucket/SHA256SUMS"
        git -C "$PROJECT_ROOT" add "$bucket/SHA256SUMS" >/dev/null 2>&1 || true
        n_files="$(find "$PROJECT_ROOT/$dest" -type f | wc -l | tr -d ' ')"
    fi

    local id; id="$(next_id)"
    append_row "$id" "retired" "$rel" "$kind" "$today" "—" "${ref:-—}" \
        "$sha" "$dest" "pl docs restore $rel" "$reason"
    git -C "$PROJECT_ROOT" add "$MANIFEST_REL" >/dev/null 2>&1 || true

    if [ "$as_json" = true ]; then
        printf '{"id":%s,"status":"retired","original":"%s","kind":"%s","files":%s,"retired":"%s","ref":"%s","sha256":"%s","retired_to":"%s","inbound_refs":%s}\n' \
            "$id" "$rel" "$kind" "$n_files" "$today" "${ref:-}" "$sha" "$dest" "${n_refs:-0}"
        return 0
    fi

    print_header "retired — $rel"
    echo "  moved:      $rel"
    echo "         →    $dest"
    echo "  kind:       $kind ($n_files file(s))"
    echo "  sha256:     $sha"
    echo "  reason:     $reason"
    echo "  ref:        ${ref:-—}"
    echo "  manifest:   $MANIFEST_REL  (row #$id; $(manifest_rows | wc -l | tr -d ' ') row(s) total)"
    echo "  restore:    pl docs restore $rel"
    echo
    if [ "${n_refs:-0}" -gt 0 ]; then
        print_warning "$n_refs tracked line(s) still point at the OLD path — fix them in THIS merge request:"
        printf '%s\n' "$refs" | sed 's/^/    /'
        echo
        print_hint "pl doc-truth will fail on the markdown links among these the next time it runs."
    else
        print_success "no tracked file references the old path"
    fi
    return 0
}

# ── retired --list ───────────────────────────────────────────────────────────
cmd_retired(){
    local as_json=false show_all=false
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --list) : ;;
            --json) as_json=true ;;
            --all)  show_all=true ;;
            *) print_error "unknown option: $1"; exit 2 ;;
        esac
        shift
    done
    require_git

    local m="$PROJECT_ROOT/$MANIFEST_REL"
    if [ ! -f "$m" ]; then
        # Absence of a ledger is a FACT here, not a blindness: docs/_retired is
        # created by the first retirement, so "no manifest" means "nothing has
        # ever been retired". Say that, in the requested shape, and exit 0.
        if [ "$as_json" = true ]; then echo "[]"; else
            print_header "retired documents"; print_info "nothing retired yet ($MANIFEST_REL does not exist)"
        fi
        return 0
    fi

    local rows; rows="$(manifest_rows)"
    if [ "$as_json" = true ]; then
        # Build the body first so an empty result is `[]` and not `[\n\n]`.
        # "Nothing retired" and "nothing retired that is still retired" must
        # print the SAME token, or a caller has two shapes to parse for one fact.
        local body="" id st orig kind ret res ref sha dest rcmd reason
        while IFS=$'\t' read -r id st orig kind ret res ref sha dest rcmd reason; do
            [ -n "${id:-}" ] || continue
            [ "$show_all" = false ] && [ "$st" != "retired" ] && continue
            [ -n "$body" ] && body+=",${NL}"
            body+="$(printf '  {"id":%s,"status":"%s","original":"%s","kind":"%s","retired":"%s","restored":"%s","ref":"%s","sha256":"%s","retired_to":"%s","restore":"%s","reason":"%s"}' \
                "$id" "$st" "$orig" "$kind" "$ret" "$res" "$ref" "$sha" "$dest" "$rcmd" \
                "$(unesc "${reason:-}" | sed 's/\\/\\\\/g; s/"/\\"/g')")"
        done <<< "$rows"
        if [ -z "$body" ]; then echo "[]"; else printf '[\n%s\n]\n' "$body"; fi
        return 0
    fi

    print_header "retired documents — $MANIFEST_REL"
    local n=0 id st orig kind ret res ref sha dest rcmd reason
    while IFS=$'\t' read -r id st orig kind ret res ref sha dest rcmd reason; do
        [ -n "${id:-}" ] || continue
        [ "$show_all" = false ] && [ "$st" != "retired" ] && continue
        n=$((n + 1))
        printf '  #%-3s %-9s %s\n' "$id" "$st" "$orig"
        printf '       retired %s%s  ref %s  %s\n' "$ret" \
            "$( [ "$st" = retired ] || printf ', restored %s' "$res" )" "$ref" "$kind"
        printf '       at      %s\n' "$dest"
        printf '       sha256  %s\n' "$sha"
        printf '       why     %s\n' "$(unesc "${reason:-}")"
        printf '       restore %s\n\n' "$rcmd"
    done <<< "$rows"
    [ "$n" -eq 0 ] && print_info "no entries$( [ "$show_all" = true ] || printf ' (try --all to include restored ones)' )"
    return 0
}

# ── restore ──────────────────────────────────────────────────────────────────
cmd_restore(){
    local path="" allow_modified=false as_json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --allow-modified) allow_modified=true ;;
            --json) as_json=true ;;
            -*) print_error "unknown option: $1"; exit 2 ;;
            *) [ -z "$path" ] && path="$1" || { print_error "unexpected argument: $1"; exit 2; } ;;
        esac
        shift
    done
    [ -n "$path" ] || { print_error "usage: pl docs restore <original-path>"; exit 2; }
    require_git; require_sha

    local rel="${path#./}"; rel="${rel%/}"
    rel="${rel#"$PROJECT_ROOT"/}"

    local row
    row="$(manifest_rows | awk -F'\t' -v p="$rel" '$2=="retired" && $3==p {r=$0} END{if(r!="")print r}')"
    [ -n "$row" ] || refuse "no retired entry for: $rel" \
        "Nothing in $MANIFEST_REL claims to hold that path." \
        "List what is there:  pl docs retired --all"

    local id st orig kind ret res ref sha dest rcmd reason
    IFS=$'\t' read -r id st orig kind ret res ref sha dest rcmd reason <<< "$row"

    [ -e "$PROJECT_ROOT/$dest" ] || cannot_verify "manifest row #$id points at a missing file: $dest" \
        "The ledger and the tree disagree; refusing to guess which is right." \
        "Look for it in history:  git -C $PROJECT_ROOT log --diff-filter=D -- '$dest'"

    [ -e "$PROJECT_ROOT/$rel" ] && refuse "$rel already exists in the tree" \
        "Restoring would overwrite it. Move or delete the current file first."

    # Prove the retired copy is still the bytes we retired. A mismatch means
    # somebody edited the archived copy — restoring it anyway may be exactly
    # right, but it must be a recorded decision, not a silent one.
    local actual
    if [ "$kind" = dir ]; then actual="$(sha_of_tree "$PROJECT_ROOT/$dest")"
    else actual="$(sha_of_file "$PROJECT_ROOT/$dest")"; fi
    local status_word="restored"
    if [ "$actual" != "$sha" ]; then
        if [ "$allow_modified" = false ]; then
            refuse "content changed since retirement: $dest" \
                "recorded sha256: $sha" \
                "actual   sha256: $actual" \
                "The archived copy is no longer the bytes row #$id vouches for." \
                "Restore it anyway, recorded as such in the manifest:" \
                "  pl docs restore $rel --allow-modified"
        fi
        status_word="restored-modified"
    fi

    mkdir -p "$PROJECT_ROOT/$(dirname "$rel")"
    git -C "$PROJECT_ROOT" mv "$dest" "$rel" \
        || cannot_verify "git mv failed: $dest → $rel" "Nothing was recorded."

    # Tidy the bucket: its sums sidecar and any directories the move emptied.
    local bucket="${dest#"$RETIRED_DIR"/}"; bucket="$RETIRED_DIR/${bucket%%/*}"
    if [ -f "$PROJECT_ROOT/$bucket/SHA256SUMS" ]; then
        git -C "$PROJECT_ROOT" rm -q -f "$bucket/SHA256SUMS" >/dev/null 2>&1 || true
        rm -f "$PROJECT_ROOT/$bucket/SHA256SUMS"
    fi
    find "$PROJECT_ROOT/$bucket" -type d -empty -delete 2>/dev/null || true

    mark_row_restored "$id" "$(date +%Y-%m-%d)" "$status_word"
    git -C "$PROJECT_ROOT" add "$MANIFEST_REL" >/dev/null 2>&1 || true

    if [ "$as_json" = true ]; then
        printf '{"id":%s,"status":"%s","original":"%s","kind":"%s","sha256":"%s","verified":%s}\n' \
            "$id" "$status_word" "$rel" "$kind" "$actual" \
            "$( [ "$actual" = "$sha" ] && echo true || echo false )"
        return 0
    fi

    print_header "restored — $rel"
    echo "  moved:      $dest"
    echo "         →    $rel"
    if [ "$actual" = "$sha" ]; then
        print_success "sha256 matches the manifest ($sha) — byte-identical to what was retired"
    else
        print_warning "sha256 DIFFERS from the manifest; recorded in row #$id as '$status_word'"
        echo "    recorded: $sha"
        echo "    actual:   $actual"
    fi
    echo "  manifest:   $MANIFEST_REL row #$id → $status_word"
    return 0
}

main(){
    local sub="${1:-}"; shift || true
    case "$sub" in
        ""|-h|--help|help) usage; exit 0 ;;
        retire)            cmd_retire "$@" ;;
        retired|list)      cmd_retired "$@" ;;
        restore)           cmd_restore "$@" ;;
        *) print_error "unknown subcommand: $sub"; echo; usage; exit 2 ;;
    esac
}

main "$@"
