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
#                         `ssh … admin/cli/…` one-liner. Those are the
#                         exact idioms `pl drush` and `pl moodle cli` were built
#                         to retire: they bypass the dry-run default, the
#                         ADR-0028 deploy gate, the live.enabled flag, the
#                         no-secret-printing rule and the rollback ledger — at
#                         go-live, when it matters most. This one IS a prose
#                         assertion, but it is mechanical (a command shape, not
#                         a claim) and every hit has a one-line `pl` rewrite.
#   4. dead-command-ref — every `./<script>.sh` a doc tells you to run resolves
#                         to a file that exists, and every `pl <verb>` written
#                         in a code span or fenced block resolves to something
#                         `pl` can actually dispatch (`pl commands` is the
#                         oracle — one source of truth, not a second list).
#
# WHY 4 EXISTS (fix-programme item 9, `docs-pl-first`). The header used to say
# this gate "deliberately does NOT check `pl <verb>` mentions … those checks
# are noisy". The cost of that exemption:
#   * `./backup.sh`, `./restore.sh`, `./dev2stg.sh`, `./stg2prod.sh` and
#     `./report.sh` were deleted when everything moved behind `pl`, yet six
#     guides — the onboarding path — still taught 118 invocations of them. A
#     new coder, or the operator under pressure, copies a restore command and
#     gets "No such file or directory".
#   * `docs/guides/art9-golive-runbook.md` — the counsel-facing Art.9 switch,
#     stamped "Last verified" — had `pl deploy nwc --tier=live --code-only
#     --apply` as step 2. `pl deploy` does not exist. The switch stopped at its
#     second step, in maintenance mode, with both gates open.
# Noise is handled the way `.gitleaksignore` handles it: today's rot is
# baselined (SHRINK-ONLY) so the gate blocks NEW drift from day one. Proposal
# docs describing unbuilt verbs live in the baseline, where they are visible,
# rather than in an exemption, where they are not.
#
# Pre-existing rot is captured in `.doc-truth-baseline` (like `.gitleaksignore`),
# so the gate fails only on NEW drift and is safe to wire into CI / `pl verify`.
#
# Escape hatch for 3 and 4: put `<!-- doc-truth:retired -->` on the line. A doc
# must be able to say "./backup.sh was removed, use pl backup" and name the dead
# thing. The marker is per-LINE, invisible when rendered, and greps in one
# command — unlike a directory exemption, it cannot quietly cover a live
# instruction.
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

# Files exempt from the two PRESCRIPTION checks — `raw-remote-cli` and
# `dead-command-ref` — while `dead-link` and `dead-adr` still apply. These are
# append-only FORENSIC RECORDS of defects that were fixed: quoting the raw
# `sudo -u www-data … drush …` line, or naming the dead `./backup.sh`, is their
# entire function, and a report OF a defect is not an instruction to run it.
# Marking every such line individually would mean a dozen
# `<!-- doc-truth:retired -->` markers per arc entry, which pressures the next
# author into `pl doc-truth --baseline` instead. Kept deliberately narrow: two
# files, both write-once ledgers, neither ever read as a runbook.
skip_prescription_checks(){
    case "$1" in
        docs/reports/consolidation-arc-2026-07/decision-log.md) return 0 ;;
        docs/reports/consolidation-arc-2026-07/rollback-registry.md) return 0 ;;
    esac
    return 1
}

usage(){ sed -n '3,61p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# EVERY markdown file the repo owns — not just docs/.
#
# This used to be `CLAUDE.md + README.md + docs/**`, while the CI job that runs
# it triggers on `**/*.md`. So ~35 tracked markdown files — CONTRIBUTING.md,
# KNOWN_ISSUES.md, CHANGELOG.md, lib/README.md, pairs/README.md and all four
# `scripts/agent-loop/prompts/*.md` (which route issues to fixes) — fired a
# blocking gate that never opened them. Proven both directions before the fix:
# a dead link in docs/ → rc=1; the identical dead link in CONTRIBUTING.md → rc=0.
#
# `--cached --others --exclude-standard` = tracked files PLUS untracked ones
# that .gitignore does not cover. Untracked matters: a doc an MR has added but
# not yet committed is exactly when a bad instruction is cheapest to catch. The
# exclude-standard half is what keeps the scan out of vendor/, node_modules/
# and the gitignored `sites/` trees. `find` is the fallback for a non-git
# fixture tree.
scan_files(){
    local rel
    {
        if git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
            git -C "$PROJECT_ROOT" ls-files --cached --others --exclude-standard -- '*.md' 2>/dev/null
        else
            ( cd "$PROJECT_ROOT" && find . -type f -name '*.md' \
                -not -path './.git/*' -not -path '*/vendor/*' \
                -not -path '*/node_modules/*' 2>/dev/null | sed 's|^\./||' )
        fi
    } | sort -u | while read -r rel; do
        [ -n "$rel" ] || continue
        [ -f "$PROJECT_ROOT/$rel" ] || continue
        skip_file "$rel" && continue
        echo "$PROJECT_ROOT/$rel"
    done
}

# ── the command oracle ────────────────────────────────────────────────────────
#
# What `pl` can dispatch, asked of `pl` itself so there is ONE list rather than
# a second one here that drifts. Filesystem enumeration is the fallback for a
# fixture tree with no `pl`.
KNOWN_COMMANDS=""
load_known_commands(){
    [ -n "$KNOWN_COMMANDS" ] && return 0
    if [ -x "$PROJECT_ROOT/pl" ]; then
        KNOWN_COMMANDS="$("$PROJECT_ROOT/pl" commands --json 2>/dev/null \
            | grep -oE '"name":"[^"]+"' | sed 's/"name":"//; s/"$//' | sort -u)"
    fi
    if [ -z "$KNOWN_COMMANDS" ]; then
        KNOWN_COMMANDS="$( { compgen -G "$PROJECT_ROOT/scripts/commands/*.sh" >/dev/null 2>&1 \
              && for f in "$PROJECT_ROOT"/scripts/commands/*.sh; do basename "$f" .sh; done
            printf '%s\n' uninstall list status version help gitlab-create gitlab-list commands
          } | sort -u)"
    fi
    # A truly empty oracle would red-flag every `pl` mention in the tree. That
    # is a broken gate, not a finding — fail loudly instead of vacuously.
    if [ -z "$KNOWN_COMMANDS" ]; then
        print_error "doc-truth: could not enumerate any pl command (oracle empty) — refusing to scan"
        exit 2
    fi
}

is_known_command(){
    local want="$1" c
    while IFS= read -r c; do [ "$c" = "$want" ] && return 0; done <<< "$KNOWN_COMMANDS"
    return 1
}

# Emit only the parts of a markdown file that are COMMANDS: whole lines inside
# a fenced block, plus the contents of inline `backtick spans`. Prose that
# happens to contain the words "pl deploy" is not an instruction; a fenced
# `pl deploy …` is.
code_text(){
    awk '
        /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
        fence == 1 { print; next }
        {
            line = $0
            while (match(line, /`[^`]+`/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$1" 2>/dev/null
}

# Emit one `dead-command-ref|<rel>|<ref>` per distinct dead reference.
#
# Two shapes:
#   (a) `./path/to/x.sh` — checked ANYWHERE in the file, prose included: a
#       relative script path is unambiguous, and "run ./backup.sh" in a
#       sentence is as broken as in a code block.
#   (b) `pl <verb>` — checked only in command context (fence or code span), so
#       ordinary prose about "the pl commands" is not a finding.
# A line that names the rule itself is teaching the contrast, not committing it.
#
# ESCAPE HATCH — `<!-- doc-truth:retired -->` on the same line.
# "This script was removed; use `pl x` instead" is a sentence a good doc needs
# to be able to write, and naming the retired thing is the whole point of it.
# The marker is an HTML comment (invisible when rendered), it is per-line (not
# per-file), and it greps in one command — so it can be audited and cannot
# quietly exempt a live instruction the way a directory-wide exemption can.
dead_command_ref_hits(){
    local file="$1" rel="$2" ref verb
    load_known_commands
    local body; body="$(grep -v 'doc-truth:retired' "$file" 2>/dev/null || true)"
    {
        while IFS= read -r ref; do
            [ -n "$ref" ] || continue
            ref="${ref#\"}"; ref="${ref%\"}"
            [ -e "$PROJECT_ROOT/${ref#./}" ] && continue
            [ -e "$(dirname "$file")/${ref#./}" ] && continue
            echo "dead-command-ref|$rel|$ref"
        done < <(printf '%s\n' "$body" | grep -oE '\./[A-Za-z0-9_./-]+\.sh' 2>/dev/null | sort -u)

        while IFS= read -r verb; do
            [ -n "$verb" ] || continue
            is_known_command "$verb" && continue
            echo "dead-command-ref|$rel|pl $verb"
        done < <(code_text "$file" \
                 | grep -v 'dead-command-ref' | grep -v 'doc-truth:retired' \
                 | grep -oE '(^[[:space:]]*([#$>][[:space:]]*)?|[|;(]|&&|\|\||\$\()[[:space:]]*pl [a-z][a-z0-9-]*' \
                 | sed -E 's/.*pl //' | sort -u)
    } | sort -u
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
        skip_prescription_checks "$rel" && continue
        raw_remote_cli_hits "$file" "$rel"

        # 4. dead-command-ref — a doc that tells you to run something that is
        #    not there. See the header: this is the class that let six guides
        #    teach 118 invocations of five deleted scripts, and put a
        #    nonexistent `pl deploy` in the Art.9 go-live switch.
        dead_command_ref_hits "$file" "$rel"
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
