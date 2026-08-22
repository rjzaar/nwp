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
#   2. dead-adr-refs    — every `NWP-ADR-NNNN` mention resolves to
#                         docs/decisions/NNNN-*.md. ENGINE SERIES ONLY, and only
#                         where the reference says so (ops#383): a bare number
#                         names no series and is refused by `lint:adr-namespace`
#                         instead; `NWC-`/`AVC-` numbers live in profile repos
#                         this gate cannot see, so it says nothing about them.
#   3. raw-remote-cli   — no runbook prescribes a raw `ssh … drush …` or
#                         `ssh … admin/cli/…` one-liner. Those are the
#                         exact idioms `pl drush` and `pl moodle cli` were built
#                         to retire: they bypass the dry-run default, the
#                         NWP-ADR-0028 deploy gate, the live.enabled flag, the
#                         no-secret-printing rule and the rollback ledger — at
#                         go-live, when it matters most. This one IS a prose
#                         assertion, but it is mechanical (a command shape, not
#                         a claim) and every hit has a one-line `pl` rewrite.
#   4. dead-command-ref — every `./<script>.sh` a doc tells you to run resolves
#                         to a file that exists, and every `pl <verb>` written
#                         in a code span or fenced block resolves to something
#                         `pl` can actually dispatch (`pl commands` is the
#                         oracle — one source of truth, not a second list).
#   5. adr-hygiene      — (ops#319 / F3(2)+(5)) every docs/decisions/NNNN-*.md
#                         carries EXACTLY ONE `**Status:**` line in the
#                         template's shape, and no ADR number names two files.
#                         Both shapes were live when this check was written:
#                         two 0032-*.md files coexisted for three days, and
#                         NWP-ADR-0034's status was a `- **Status:**` list item no
#                         Status-grep in the estate could see — recorded in
#                         ops#318 as "no Status line at all". A status the
#                         tooling cannot parse is a status it silently stops
#                         checking (the stored_in-grammar rule, applied here).
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
# THE BASELINE IS CHECKED BOTH WAYS (ops#319 / F3(3)). A baseline row that no
# longer reproduces is a fix nobody banked (delete the row — SHRINK-ONLY) or a
# corpus that diverges between machines (fix the doc so both machines agree).
# Both siblings — scripts/ci/lint-test-honesty.sh and lint-gate-redproof.sh —
# have had STALE-BASELINE-ROW failures from day one; this file did not, and
# grew exactly 14 dead rows of 392 before anyone counted (meta-2026-08-09
# pass 3, probe P1). Dead rows are now reported BY NAME and fail the gate.
#
# --memory (ops#319 / F3(1)): the raw-remote-cli check pointed at the AI
# auto-memory corpus (~/.claude/projects/<slug>/memory/*.md). That corpus is
# INJECTED into sessions with the authority of ground truth, and on 2026-08-09
# its MEMORY.md was found PRESCRIBING the exact scp/sudo-cp/raw-admin-cli
# deploy idiom the pl-first standing order forbids — the injected corpus was
# teaching the violation (meta-2026-08-09, catalogue item 8 / RC3). Memory may
# DESCRIBE; only verbs may PRESCRIBE. Host-side only: where the corpus is
# unreadable (every CI runner), this exits 2 CANNOT VERIFY — absence of the
# corpus is not a clean corpus, and an unreadable store never grades green.
#
# --projection (ops#319 / F2, Tranche 2): the INJECTED read-first document
# (`~/central/nwc-internal/OPERATING-MODEL.md`) must not assert, in hand-written
# prose, anything that disagrees with what the estate actually measures. That
# document is re-read into context on every ops-related prompt, so a stale
# sentence in it is not a stale doc — it is a falsehood re-asserted to the AI
# with the authority of ground truth, every single turn. Measured 2026-08-09:
# it said the agent-loop was "paused" while the loop was armed and running on
# the ai-host, and printed an issue map stopping at ops#53 while the queue was
# past ops#332.
#
# Two shapes, both fatal:
#   * projection-contradiction — a hand-written claim disagrees with a LIVE
#     measurement (`pl operating-model state`). Conditional on the measurement
#     by construction: if the loop really is paused, "the loop is paused" is
#     correct and nothing fires; if the probe is blind, the rule STANDS DOWN
#     and the blindness is reported as CANNOT VERIFY. A lint that fires on a
#     literal it never measured is itself the stale literal.
#   * state-banner — a "⇢ STATE UPDATE … supersedes the claims below" banner.
#     A banner that has to exist at all is a body that should have been
#     regenerated: the document's own top carried TWO of them, the later one
#     partially correcting the earlier. Correction-by-accretion is the disease,
#     not the treatment.
# Plus the projection's own gate: no generated block (unprojected-state), a
# hand-edited block (hand-edited-state), or one past its horizon (stale-state).
# Host-side only, exactly like --memory: the document lives in the operator's
# private ~/central tree, which no CI runner can read — and an unreadable
# corpus exits 2 CANNOT VERIFY, never a silent green.
#
# Escape hatch for 3 and 4: put `<!-- doc-truth:retired -->` on the line. A doc
# must be able to say "./backup.sh was removed, use pl backup" and name the dead
# thing. The marker is per-LINE, invisible when rendered, and greps in one
# command — unlike a directory exemption, it cannot quietly cover a live
# instruction.
#
# Usage:
#   pl doc-truth              scan + report NEW drift and STALE baseline rows;
#                             exit 1 if either exists
#   pl doc-truth --all        report every drift item incl. baselined
#   pl doc-truth --baseline   (re)write .doc-truth-baseline from current drift
#   pl doc-truth --json       machine-readable summary to stdout
#   pl doc-truth --memory[=DIR]  lint the AI auto-memory corpus (host-side);
#                             exit 2 CANNOT VERIFY where the corpus is unreadable
#   pl doc-truth --adr-namespace  every ADR reference names WHICH series it
#                             means (lint:adr-namespace, ops#383). No baseline
#                             and no override by design; exit 2 CANNOT VERIFY
#                             if the corpus is unreadable.
#   pl doc-truth --adr-namespace-list   the same, machine-readable
#   pl doc-truth --projection[=FILE]  the injected read-first document's
#                             hand-written claims vs LIVE measurements
#                             (host-side; exit 2 where it cannot be read)
#   pl doc-truth -h|--help
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# Libs load from the repo; the SCANNED tree honours a pre-set PROJECT_ROOT so
# the gate is testable on a fixture tree instead of only on the live repo.
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"
source "$REPO_ROOT/lib/ui.sh"
# One source of truth for the raw-remote idiom class (ops#319 F4): this lint
# and the act-time PreToolUse hook (scripts/hooks/pretooluse-raw-remote.sh)
# read the SAME patterns. Do not fork them back inline.
source "$REPO_ROOT/lib/raw-remote-patterns.sh"

BASELINE="$PROJECT_ROOT/.doc-truth-baseline"
ADR_RESERVED=" 0023 "   # intentionally file-less (reserved slot)

# The AI auto-memory corpus for THIS checkout: Claude Code keys the memory
# directory on the project path with `/` → `-` (a checkout at /home/x/nwp
# reads ~/.claude/projects/-home-x-nwp/memory). NWP_MEMORY_DIR overrides it
# for fixtures and for pointing a worktree's run at the canonical corpus.
MEMORY_DIR="${NWP_MEMORY_DIR:-$HOME/.claude/projects/$(printf '%s' "$PROJECT_ROOT" | tr '/' '-')/memory}"

# Docs excluded from the gate: historical archives + teaching docs that contain
# deliberately-illustrative example links (not real targets).
# `docs/onboarding/*` WAS excluded here and no longer is (ops#383). The wholesale
# directory exemption is exactly the failure mode this file's own escape-hatch
# comment warns about: it "quietly covers a live instruction". It covered one for
# three months. docs/onboarding/adrs.md invented a whole third ADR numbering
# scheme — banded 10/20/30/40/50/60/70 — with six numbers naming no file in any
# repo, and shipped it to every new coder as the reviewer's index. No gate ever
# opened the file, so nobody noticed between 2026-05-20 and 2026-08-22.
#
# Narrowing cost NOTHING, which is the argument for having done it sooner:
# measured 2026-08-22 with the directory scanned, `--all` reports ZERO findings
# across all eleven files, so no baseline row was needed. Proven scanned rather
# than assumed — a deliberate dead link injected into docs/onboarding/README.md
# fired `dead-link`, and was then reverted.
skip_file(){
    case "$1" in
        docs/archive/*|docs/governance/documentation-standards.md) return 0 ;;
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

usage(){ sed -n '3,123p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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

# 5. adr-hygiene (ops#319). Two shapes, one per emitted item:
#
#   adr-dup|docs/decisions|NNNN          — NNNN names MORE THAN ONE file.
#       A reused number makes every `ADR-NNNN` reference in the tree ambiguous
#       (which decision does the deploy gate implement?). Found live: 0024 was
#       reused once (fixed by renumbering to 0026, 2026-07-02) and then 0032
#       was reused again 2026-08-06 — the check that would have refused the
#       second collision did not exist after the first one.
#
#   adr-status|docs/decisions/<file>|N-status-lines — the file does not carry
#       EXACTLY ONE `**Status:**` line in the template's shape (template.md:3,
#       column 0). Zero is a decision whose state nobody recorded; two is the
#       correction-by-accretion pattern (a second status stacked on a stale
#       first). The shape is strict ON PURPOSE: NWP-ADR-0034 carried its status as
#       a `- **Status:** ` list item, which every Status-grep in the estate
#       missed — ops#318 recorded it as "no Status line at all". A status the
#       tooling cannot parse is a status nothing checks.
adr_hygiene_hits(){
    local d="$PROJECT_ROOT/docs/decisions" f b num n
    [ -d "$d" ] || return 0
    for num in $(
        for f in "$d"/[0-9][0-9][0-9][0-9]-*.md; do
            [ -e "$f" ] || continue
            b="${f##*/}"; echo "${b%%-*}"
        done | sort | uniq -d
    ); do
        echo "adr-dup|docs/decisions|$num"
    done
    for f in "$d"/[0-9][0-9][0-9][0-9]-*.md; do
        [ -e "$f" ] || continue
        n="$(grep -c '^\*\*Status:\*\*' "$f" 2>/dev/null || true)"
        [ "${n:-0}" -eq 1 ] || echo "adr-status|docs/decisions/${f##*/}|${n:-0}-status-lines"
    done
}

# Emit every drift item as "kind|relpath|ref", one per line.
collect_drift(){
    local file reldir target adr num rel
    adr_hygiene_hits
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

        # 2. dead-adr — resolve ONLY the ENGINE series, and only when the
        #    reference says it means the engine series (ops#383).
        #
        #    This used to extract a bare `ADR-[0-9]{4}` and resolve it against
        #    docs/decisions/. That is a guess, not a resolution: three series
        #    wrote that same token, so a bare number resolved here and reported
        #    GREEN while naming a document in some other repo. Measured before
        #    the fix: 904 such references across the site trees, 22 distinct
        #    numbers, every one green and every one pointing at the wrong ADR.
        #
        #    Now the prefix carries the namespace. `NWP-ADR-NNNN` is ours and
        #    must resolve. `NWC-ADR-NNNN` / `AVC-ADR-NNNN` belong to profile
        #    repos this gate cannot see, so it says nothing about them rather
        #    than resolving them against the wrong directory — silence is the
        #    honest answer to "is a file in another repo present?".
        #
        #    A BARE reference is not checked here at all, because there is
        #    nothing to check: it names no series. `lint:adr-namespace` is the
        #    gate that refuses it, and it has no baseline, so bareness cannot
        #    accumulate behind this check's back.
        while IFS= read -r adr; do
            num="${adr#NWP-ADR-}"
            case "$ADR_RESERVED" in *" $num "*) continue ;; esac
            compgen -G "$PROJECT_ROOT/docs/decisions/${num}-*.md" >/dev/null 2>&1 \
                || echo "dead-adr|$rel|NWP-ADR-$num"
        done < <(grep -oE 'NWP-ADR-[0-9]{4}' "$file" 2>/dev/null | sort -u)

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
    done < <(grep -nE "$RAW_REMOTE_CLI_REGEX" "$file" 2>/dev/null \
             | grep -vE '^[0-9]+:[[:space:]]*(#|//)' || true)
}

# ── the memory corpus (ops#319 / F3(1)) ──────────────────────────────────────
# The auto-memory files are injected into sessions as ground truth, so a
# forbidden idiom written there is not a stale doc — it is an instruction the
# AI will read with authority at the exact moment it acts. This applies the
# SAME raw-remote-cli oracle as the doc corpus (one pattern, two consumers;
# two implementations of "what is the forbidden idiom" would drift).
#
# Memory may DESCRIBE ("the deploy used to be done by hand, see ops#149");
# only verbs may PRESCRIBE. A hit here is fixed by rewriting the note to name
# the pl verb — exactly what happened to MEMORY.md's "Deployment Notes" on
# 2026-08-09, after that section's scp/sudo-cp recipe sat in every session's
# context alongside the standing order forbidding it.
#
# FAIL-CLOSED SPLIT, stated honestly: this corpus exists on the WORKSTATION
# (and any ai-host with a local memory). A CI runner has no ~/.claude, so CI
# cannot run this check — and must never report the corpus clean from a probe
# that saw nothing. Unreadable/empty corpus = exit 2 CANNOT VERIFY, which is
# UNCHECKED, not green. That is why this mode is NOT wired into a blocking CI
# job (a permanently-red honest job trains people to merge past red — the
# boundary:classify lesson, .gitlab-ci.yml ops#165); it belongs host-side,
# where the corpus is real.
run_memory_check(){
    print_header "doc-truth --memory — the injected corpus may not PRESCRIBE forbidden idioms"
    if [ ! -d "$MEMORY_DIR" ] || [ ! -r "$MEMORY_DIR" ]; then
        echo "CANNOT VERIFY: memory corpus not readable at: $MEMORY_DIR" >&2
        echo "  This check runs where the auto-memory lives (the workstation / ai-host)." >&2
        echo "  A CI runner has no memory corpus; absence of the corpus is NOT a clean" >&2
        echo "  corpus, so this is exit 2 (UNCHECKED) — never a silent green." >&2
        echo "  Point it explicitly with --memory=DIR or NWP_MEMORY_DIR." >&2
        exit 2
    fi
    local f rel n_files=0 hits="" h
    while IFS= read -r -d '' f; do
        n_files=$((n_files + 1))
        rel="memory/${f##*/}"
        h="$(raw_remote_cli_hits "$f" "$rel")"
        [ -n "$h" ] && hits="${hits}${h}"$'\n'
    done < <(find "$MEMORY_DIR" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null | sort -z)
    if [ "$n_files" -eq 0 ]; then
        echo "CANNOT VERIFY: zero markdown files under $MEMORY_DIR" >&2
        echo "  Refusing to grade an empty corpus as clean." >&2
        exit 2
    fi
    local n_hits
    n_hits="$(printf '%s' "$hits" | grep -c '^raw-remote-cli' || true)"
    if [ "${n_hits:-0}" -gt 0 ]; then
        local kind fr ref
        while IFS='|' read -r kind fr ref; do
            [ -n "$kind" ] || continue
            print_error "[memory-prescribes] $fr → $ref  (a memory note PRESCRIBES a raw remote CLI idiom)"
        done < <(printf '%s' "$hits")
        print_warning "$n_hits prescription(s) in the auto-memory corpus ($MEMORY_DIR)."
        print_warning "Memory may describe; only verbs prescribe. Rewrite the note to name the pl verb:"
        print_warning "  pl drush <site> --tier=live --execute -- <cmd>   |   pl moodle cli <site> --tier=live --execute -- <script>"
        exit 1
    fi
    print_success "memory corpus clean: $n_files file(s) under $MEMORY_DIR, no prescribed raw-remote idiom"
    exit 0
}

# ── the injected read-first document (ops#319 / F2) ──────────────────────────
#
# THE CORPUS THAT IS RE-ASSERTED EVERY TURN. `--memory` above exists because the
# auto-memory corpus is injected with the authority of ground truth. The SAME
# argument applies with more force to the read-first document, which a
# UserPromptSubmit hook re-reads into context on every prompt naming an ops
# issue — and which, unlike memory, presents itself as the operating model.
#
# WHAT THIS CHECKS IS AGREEMENT WITH A MEASUREMENT, NOT WITH A LITERAL. The
# rules live in lib/operating-model.sh, where each one is conditioned on a probe
# that ran in this same invocation. Nothing here has a hard-coded "the loop is
# armed": if the loop is paused, the paused sentence is correct and the check
# is silent. Blind probe ⇒ the rule stands down and the blindness is REPORTED.
#
# FAIL-CLOSED SPLIT, same as --memory: the document lives in the operator's
# private ~/central tree. No CI runner can read it, and a check that reported
# "clean" from a probe that saw nothing would be the exact defect this whole
# programme was opened to kill. Unreadable ⇒ exit 2 CANNOT VERIFY.
run_projection_check(){
    print_header "doc-truth --projection — the injected document may not assert what the estate contradicts"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/operating-model.sh"
    local file="${PROJECTION_FILE:-$OM_DOC}"
    if [ ! -r "$file" ]; then
        echo "CANNOT VERIFY: read-first document not readable at: $file" >&2
        echo "  This check runs where the private ~/central tree lives (the workstation)." >&2
        echo "  Absence of the document is NOT a clean document — exit 2 (UNCHECKED)." >&2
        echo "  Point it explicitly with --projection=FILE or NWP_OPERATING_MODEL_FILE." >&2
        exit 2
    fi
    om_collect_sections
    local out rc=0
    out="$(om_lint "$file")" || rc=$?
    local kind where detail nfind=0 nblind=0
    while IFS='|' read -r kind where detail; do
        [ -n "$kind" ] || continue
        case "$kind" in
            projection-blind) print_warning "[CANNOT VERIFY] $where → $detail"; nblind=$((nblind+1)) ;;
            *)                print_error   "[$kind] $where → $detail"; nfind=$((nfind+1)) ;;
        esac
    done < <(printf '%s\n' "$out")
    if [ "$nfind" -gt 0 ]; then
        print_warning "$nfind projection finding(s) in $file."
        print_warning "A generated block carries state; prose must not restate it. Delete the claim, then:"
        print_warning "  pl operating-model sync"
        exit 1
    fi
    if [ "$nblind" -gt 0 ]; then
        print_warning "$nblind measurement(s) unavailable — those rules did not run. UNCHECKED, not clean."
        exit 2
    fi
    print_success "projection clean: $file agrees with everything measured just now"
    exit 0
}

main(){
    local mode=report
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        --baseline) mode=baseline ;;
        --all)      mode=all ;;
        --json)     mode=json ;;
        --memory)   run_memory_check ;;
        --memory=*) MEMORY_DIR="${1#*=}"; run_memory_check ;;
        --projection)   run_projection_check ;;
        --projection=*) PROJECTION_FILE="${1#*=}"; run_projection_check ;;
        # --adr-namespace (ops#383): the operator-facing surface for
        # `lint:adr-namespace`. It lives in scripts/ci/ like every other lint,
        # but the standing order is that everything goes through a `pl` verb —
        # and this is the check an author most wants to run locally, right
        # after fixing a citation, rather than discovering it in CI. Delegates
        # to the ONE implementation (the same pattern `pl verify gates` uses for
        # lint-gate-redproof.sh); it does not reimplement the rule, because a
        # policy expressed in two places is a policy that drifts.
        --adr-namespace)
            exec "$REPO_ROOT/scripts/ci/lint-adr-namespace.sh" ;;
        --adr-namespace=--list|--adr-namespace-list)
            exec "$REPO_ROOT/scripts/ci/lint-adr-namespace.sh" --list ;;
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
    local new_drift stale_rows
    new_drift="$(comm -23 <(printf '%s\n' "$all_drift" | grep -v '^$' | sort) <(printf '%s\n' "$baseline_items" | grep -v '^$' | sort) 2>/dev/null || true)"
    # The other direction (ops#319 / F3(3)): rows the baseline still carries
    # that the scan no longer produces. Same multiset comm as new_drift, so a
    # deliberately-duplicated finding (one doc naming a target twice) is
    # matched copy-for-copy, not deduplicated into a phantom stale row.
    stale_rows="$(comm -13 <(printf '%s\n' "$all_drift" | grep -v '^$' | sort) <(printf '%s\n' "$baseline_items" | grep -v '^$' | sort) 2>/dev/null || true)"
    local n_all n_new n_known n_stale
    n_all="$(printf '%s\n' "$all_drift" | grep -c '^[a-z]' || true)"
    n_new="$(printf '%s\n' "$new_drift" | grep -c '^[a-z]' || true)"
    n_stale="$(printf '%s\n' "$stale_rows" | grep -c '^[a-z]' || true)"
    n_known=$((n_all - n_new))

    if [ "$mode" = json ]; then
        printf '{"total":%d,"new":%d,"baselined":%d,"stale":%d}\n' "$n_all" "$n_new" "$n_known" "$n_stale"
        [ "$n_new" -eq 0 ] && [ "$n_stale" -eq 0 ]; return
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

    if [ "$n_stale" -gt 0 ]; then
        local srow
        while IFS= read -r srow; do
            [ -n "$srow" ] || continue
            print_error "STALE BASELINE ROW (no longer reproduces — delete it): $srow"
        done < <(printf '%s\n' "$stale_rows")
        print_warning "$n_stale baseline row(s) describe drift the tree no longer has."
        print_warning "The baseline is SHRINK-ONLY: deleting a dead row is a fix — edit .doc-truth-baseline"
        print_warning "in this MR (or regenerate deliberately: pl doc-truth --baseline)."
    fi

    if [ "$n_new" -eq 0 ] && [ "$n_stale" -eq 0 ]; then
        print_success "no new drift, no stale baseline rows ($n_known known/baselined item(s) ignored — see .doc-truth-baseline)"
        return 0
    fi
    [ "$n_new" -gt 0 ] && print_warning "$n_new NEW drift item(s) above ($n_known baselined). Fix them, or run 'pl doc-truth --baseline' to accept."
    return 1
}

main "$@"
