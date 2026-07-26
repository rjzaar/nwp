#!/bin/bash
#
# pl doc-truth — NWP-side documentation-truth gate (P62, Phase 1).
#
# P62's premise: docs drift from reality and can't self-check. `central-verify`
# (in ~/central) checks the private operational index; this is its public-repo
# sibling. It asserts the *structural* claims NWP docs make against the tree —
# the unambiguous, low-false-positive class the 2026-07-06 audit (ops#53) found
# drifting (dead doc paths in CLAUDE.md, stale ADR references):
#
#   1. dead-file-links  — every repo-relative markdown link resolves to a file
#                         that exists (tried relative-to-file AND relative-to-root).
#   2. dead-adr-refs    — every `ADR-NNNN` mention resolves to docs/decisions/NNNN-*.md.
#   3. raw-remote-cli   — no runbook prescribes a raw `ssh … drush …` or
#                         `ssh … admin/cli/…` one-liner (item 9). Those are the
#                         exact idioms `pl drush` and `pl moodle cli` were built
#                         to retire: they bypass the dry-run default, the
#                         ADR-0028 deploy gate, the live.enabled flag, the
#                         no-secret-printing rule and the rollback ledger — at
#                         go-live, when it matters most. This one IS a prose
#                         assertion, but it is mechanical (a command shape, not
#                         a claim) and every hit has a one-line `pl` rewrite.
#
# It deliberately does NOT check `pl <verb>` mentions or prose assertions: the
# proposal docs describe unbuilt future commands, so those checks are noisy.
#
# Pre-existing rot is captured in `.doc-truth-baseline` (like `.gitleaksignore`),
# so the gate fails only on NEW drift and is safe to wire into CI / `pl verify`.
#
# Usage:
#   pl doc-truth              scan + report NEW drift; exit 1 if any
#   pl doc-truth --all        report every drift item incl. baselined
#   pl doc-truth --baseline   (re)write .doc-truth-baseline from current drift
#   pl doc-truth --json       machine-readable summary to stdout
#   pl doc-truth -h|--help
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# Libs load from the repo; the SCANNED tree honours a pre-set PROJECT_ROOT so
# the gate is testable on a fixture tree instead of only on the live repo.
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"
source "$REPO_ROOT/lib/ui.sh"

BASELINE="$PROJECT_ROOT/.doc-truth-baseline"
ADR_RESERVED=" 0023 "   # intentionally file-less (reserved slot)

# Docs excluded from the gate: historical archives + teaching docs that contain
# deliberately-illustrative example links (not real targets).
skip_file(){
    case "$1" in
        docs/archive/*|docs/onboarding/*|docs/governance/documentation-standards.md) return 0 ;;
    esac
    return 1
}

usage(){ sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

scan_files(){
    { printf '%s\n' "$PROJECT_ROOT/CLAUDE.md" "$PROJECT_ROOT/README.md"
      find "$PROJECT_ROOT/docs" -type f -name '*.md' 2>/dev/null
    } | while read -r f; do
        [ -f "$f" ] || continue
        skip_file "${f#$PROJECT_ROOT/}" && continue
        echo "$f"
    done
}

# Emit every drift item as "kind|relpath|ref", one per line.
collect_drift(){
    local file reldir target adr num rel
    while read -r file; do
        reldir="$(dirname "$file")"; rel="${file#$PROJECT_ROOT/}"
        while IFS= read -r target; do
            [ -n "$target" ] || continue
            case "$target" in http://*|https://*|mailto:*|\#*|/*) continue ;; esac
            target="${target%%#*}"; target="${target%% *}"     # strip #anchor and any "title"
            [ -n "$target" ] || continue
            case "$target" in *.md|*.sh|*.yml|*.yaml|*.py|*.json|*.toml|*.txt) ;; *) continue ;; esac
            [ -e "$reldir/$target" ] || [ -e "$PROJECT_ROOT/$target" ] || echo "dead-link|$rel|$target"
        done < <(grep -oE '\]\([^)]+\)' "$file" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//')

        while IFS= read -r adr; do
            num="${adr#ADR-}"
            case "$ADR_RESERVED" in *" $num "*) continue ;; esac
            compgen -G "$PROJECT_ROOT/docs/decisions/${num}-*.md" >/dev/null 2>&1 || echo "dead-adr|$rel|ADR-$num"
        done < <(grep -oE 'ADR-[0-9]{4}' "$file" 2>/dev/null | sort -u)

        # 3. raw-remote-cli — an `ssh …` line that runs drush or a Moodle
        #    admin/cli script directly. Reported as "file:line" so a rewrite is
        #    unambiguous. Lines that mention the shape *in order to forbid it*
        #    (this file's own docs, or prose containing `pl drush`/`pl moodle`)
        #    are not hits.
        raw_remote_cli_hits "$file" "$rel"
    done < <(scan_files)
}

# Emit one `raw-remote-cli|<rel>|L<line>` per offending line in <file>.
#
# TWO shapes, because one is how the rule gets evaded:
#   (a) `ssh … drush …` / `ssh … admin/cli/…`  — the direct one-liner;
#   (b) `sudo -u www-data … drush` / `… admin/cli/…` — the *remote* invocation
#       itself, which catches the alias trick. NWC-LIVE-DEPLOY-RUNBOOK assigns
#       `D="sudo -u www-data /var/www/nwc/vendor/bin/drush --root=…"` and then
#       writes `ssh … "$D updatedb -y"`; shape (a) alone reads that as clean and
#       reports a runbook full of raw remote drush as compliant. A gate that a
#       shell variable defeats is a vacuous gate.
raw_remote_cli_hits(){
    local file="$1" rel="$2" lineno text
    while IFS=: read -r lineno text; do
        [ -n "$lineno" ] || continue
        # A line that ALSO shows the sanctioned form is teaching the contrast.
        case "$text" in
            *"pl drush"*|*"pl moodle cli"*|*"raw-remote-cli"*) continue ;;
        esac
        echo "raw-remote-cli|$rel|L$lineno"
    done < <(grep -nE 'ssh[^|]*(drush|admin/cli/)|sudo[[:space:]]+-u[[:space:]]+www-data[^|]*(drush|admin/cli/)' "$file" 2>/dev/null \
             | grep -vE '^[0-9]+:[[:space:]]*(#|//)' || true)
}

main(){
    local mode=report
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        --baseline) mode=baseline ;;
        --all)      mode=all ;;
        --json)     mode=json ;;
        "")         ;;
        *) print_error "unknown arg: $1"; usage; exit 2 ;;
    esac

    local all_drift; all_drift="$(collect_drift | sort)"

    if [ "$mode" = baseline ]; then
        { echo "# doc-truth baseline — known-existing doc drift (P62). Regenerate: pl doc-truth --baseline"
          echo "$all_drift"; } > "$BASELINE"
        print_success "wrote $(grep -c '^[^#]' "$BASELINE" 2>/dev/null || echo 0) baselined item(s) → ${BASELINE#$PROJECT_ROOT/}"
        exit 0
    fi

    local baseline_items=""; [ -f "$BASELINE" ] && baseline_items="$(grep -v '^#' "$BASELINE" 2>/dev/null || true)"
    local new_drift known_drift
    new_drift="$(comm -23 <(printf '%s\n' "$all_drift" | grep -v '^$' | sort) <(printf '%s\n' "$baseline_items" | grep -v '^$' | sort) 2>/dev/null || true)"
    local n_all n_new n_known
    n_all="$(printf '%s\n' "$all_drift" | grep -c '^[a-z]' || true)"
    n_new="$(printf '%s\n' "$new_drift" | grep -c '^[a-z]' || true)"
    n_known=$((n_all - n_new))

    if [ "$mode" = json ]; then
        printf '{"total":%d,"new":%d,"baselined":%d}\n' "$n_all" "$n_new" "$n_known"
        [ "$n_new" -eq 0 ]; return
    fi

    print_header "doc-truth gate (P62) — structural doc claims vs the tree"
    local show="$new_drift" label="NEW drift (not baselined)"
    [ "$mode" = all ] && { show="$all_drift"; label="ALL drift"; }
    if [ -n "$(printf '%s' "$show" | tr -d '[:space:]')" ]; then
        local kind f ref
        while IFS='|' read -r kind f ref; do
            [ -n "$kind" ] || continue
            print_error "[$kind] $f → $ref"
        done < <(printf '%s\n' "$show")
    fi

    if [ "$n_new" -eq 0 ]; then
        print_success "no new drift ($n_known known/baselined item(s) ignored — see .doc-truth-baseline)"
        return 0
    fi
    print_warning "$n_new NEW drift item(s) above ($n_known baselined). Fix them, or run 'pl doc-truth --baseline' to accept."
    return 1
}

main "$@"
