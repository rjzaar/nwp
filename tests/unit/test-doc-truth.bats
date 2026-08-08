#!/usr/bin/env bats
# Fix-programme item 9 (`docs-pl-first`) — the acceptance suite for `pl doc-truth`.
#
# THE DEFECT THIS SUITE EXISTS TO CATCH. `pl doc-truth` was green by design:
# its own header said it "deliberately does NOT check `pl <verb>` mentions",
# and `scan_files()` read only CLAUDE.md, README.md and `docs/**` while the CI
# job that runs it triggers on `**/*.md`. So:
#
#   * six guides taught 118 invocations of `./backup.sh`, `./restore.sh`,
#     `./dev2stg.sh`, `./stg2prod.sh` and `./report.sh` — none of which exist —
#     and the gate could not see a single one;
#   * `docs/guides/art9-golive-runbook.md`, the counsel-facing Art.9 go-live
#     switch, step 2 was `pl deploy nwc --tier=live --code-only --apply`.
#     `pl deploy` does not exist (`ERROR: Unknown command: deploy`, exit 1), so
#     the highest-stakes runbook in the tree failed at its second step with
#     member exposure open between steps 2 and 3;
#   * ~35 tracked markdown files outside `docs/` (CONTRIBUTING.md,
#     KNOWN_ISSUES.md, lib/README.md, and all four
#     `scripts/agent-loop/prompts/*.md`, which route issues to fixes) fired a
#     blocking gate that never opened them.
#
# EVERY CASE BELOW WAS OBSERVED RED against the pre-fix tree. Cases 1/2/6 fail
# because `dead-command-ref` did not exist; case 4/5 because the scan was
# docs-only; case 7 because eight `print_error` call sites in the deploy verbs
# printed a raw `sudo -u www-data … drush …` recovery line, training the exact
# hand-ssh reflex `pl drush` was built to retire — at the moment a live site is
# dark.
#
# Case 3 is the over-fire guard: a gate that reddens on `pl backup` would be
# uninstallable, so it is asserted green on purpose.

setup() {
    PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    export PROJECT_ROOT
    DT="${PROJECT_ROOT}/scripts/commands/doc-truth.sh"
    PROBES=()
}

teardown() {
    local p
    for p in "${PROBES[@]:-}"; do
        [ -n "$p" ] && rm -f "$p" || true
    done
    return 0
}

# _probe <repo-relative path> <content> — plant a markdown file in the real
# tree (this suite runs in an isolated worktree) and register it for teardown.
# Probes are deliberately UNTRACKED: the scan must see a doc an MR has added
# but not yet committed, which is exactly when a bad instruction is cheapest
# to catch.
_probe() {
    local rel="$1"; shift
    PROBES+=("${PROJECT_ROOT}/${rel}")
    mkdir -p "$(dirname "${PROJECT_ROOT}/${rel}")"
    printf '%s\n' "$1" > "${PROJECT_ROOT}/${rel}"
}

# ─── 1. dead script references ────────────────────────────────────────────────

@test "doc-truth: a guide teaching ./backup.sh (a script that does not exist) is NEW drift" {
    # The single most-copied line in the onboarding path. `./backup.sh` was
    # removed when everything moved behind `pl`; six guides never noticed.
    [ ! -e "${PROJECT_ROOT}/backup.sh" ]   # premise: the script really is gone

    _probe "docs/guides/zz-doc-truth-probe.md" '# probe

```bash
./backup.sh -y probe
```'
    run "$DT"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'dead-command-ref'
    echo "$output" | grep -q 'backup.sh'
}

@test "doc-truth: a fenced pl verb that cannot dispatch is NEW drift" {
    # This is the art9-golive-runbook class: `pl deploy` reads like a real verb,
    # is fenced like a real verb, and exits 1 with "Unknown command".
    run "${PROJECT_ROOT}/pl" zznosuchverb
    [ "$status" -ne 0 ]                     # premise: the verb really is dead

    _probe "docs/guides/zz-doc-truth-probe.md" '# probe

```bash
pl zznosuchverb nwc --tier=live
```'
    run "$DT"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'dead-command-ref'
    echo "$output" | grep -q 'zznosuchverb'
}

@test "doc-truth: real verbs and real paths are NOT drift (over-fire guard)" {
    _probe "docs/guides/zz-doc-truth-probe.md" '# probe

```bash
pl backup nwc --remote
pl drush nwc --tier=live --execute -- cr
./pl status
```'
    run "$DT"
    [ "$status" -eq 0 ]
}

# ─── 2. scan scope ────────────────────────────────────────────────────────────

@test "doc-truth: a root-level markdown file (CONTRIBUTING.md) is in scope" {
    # The CI job triggers on **/*.md. Before this fix the scanner opened only
    # CLAUDE.md, README.md and docs/** — so an edit to CONTRIBUTING.md could
    # fire a blocking gate that never read the file that fired it. Proven both
    # directions at the time: a dead link under docs/ → rc=1; the IDENTICAL
    # dead link in CONTRIBUTING.md → rc=0.
    #
    # The probe has to go into the real CONTRIBUTING.md rather than a planted
    # file, because `.gitignore:7` is `/*` — the repo root is an allowlist, so
    # an untracked root-level file is gitignored by construction and correctly
    # invisible to the scan.
    local target="${PROJECT_ROOT}/CONTRIBUTING.md"
    cp "$target" "${BATS_TEST_TMPDIR}/CONTRIBUTING.md.orig"
    printf '\n[probe](docs/zz-no-such-target.md)\n' >> "$target"

    run "$DT"
    local st="$status" out="$output"
    cp "${BATS_TEST_TMPDIR}/CONTRIBUTING.md.orig" "$target"      # restore first

    [ "$st" -ne 0 ]
    echo "$out" | grep -q 'dead-link'
    echo "$out" | grep -q 'CONTRIBUTING.md'
}

@test "doc-truth: the agent-loop prompt docs are in scope" {
    # scripts/agent-loop/prompts/*.md route issues to fixes. Drift there sends
    # an autonomous agent at a file that moved.
    _probe "scripts/agent-loop/prompts/zz-doc-truth-probe.md" '# probe

Read [the playbook](docs/zz-no-such-target.md) first.'
    run "$DT"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'scripts/agent-loop/prompts/zz-doc-truth-probe.md'
}

@test "doc-truth: the scan does not follow gitignored trees (vendor/node_modules/sites)" {
    # Over-fire guard for the widened scope: `git ls-files --others
    # --exclude-standard` must honour .gitignore, or the gate would try to
    # parse every markdown file in every Drupal vendor tree.
    run bash -c "'$DT' --json"
    [ "$status" -eq 0 ] || true
    # A scan that wandered into sites/ would take minutes and report thousands.
    total="$(echo "$output" | sed -E 's/.*"total":([0-9]+).*/\1/')"
    [ "$total" -lt 2000 ]
}

@test "doc-truth: the forensic-record exemption is narrow, and does not disable dead-link" {
    # The arc decision-log / rollback-registry are exempt from the two
    # PRESCRIPTION checks (raw-remote-cli, dead-command-ref) because quoting a
    # dead command is what a defect report is FOR. That exemption must not
    # quietly turn those files into unchecked territory: dead-link still
    # applies, and the exemption must not have grown.
    run bash -c "grep -A6 '^skip_prescription_checks()' '${PROJECT_ROOT}/scripts/commands/doc-truth.sh' \
                 | grep -c 'return 0'"
    [ "$output" -le 2 ]   # exactly the two ledgers; growing this is a decision

    local target="${PROJECT_ROOT}/docs/reports/consolidation-arc-2026-07/decision-log.md"
    cp "$target" "${BATS_TEST_TMPDIR}/decision-log.md.orig"
    printf '\n[probe](docs/zz-no-such-target.md)\n' >> "$target"

    run "$DT"
    local st="$status" out="$output"
    cp "${BATS_TEST_TMPDIR}/decision-log.md.orig" "$target"

    [ "$st" -ne 0 ]
    echo "$out" | grep 'dead-link' | grep -q 'decision-log.md'
}

# ─── 3. the runbooks that matter ──────────────────────────────────────────────

@test "doc-truth: the Art.9 go-live runbook prescribes only commands that exist" {
    # RED before the fix: step 2 was `pl deploy nwc --tier=live --code-only
    # --apply`. The whole switch stops there, in maintenance mode, with the new
    # code half-deployed and both gates open.
    run bash -c "'$DT' --all"
    ! echo "$output" | grep 'dead-command-ref' | grep -q 'art9-golive-runbook'
}

@test "doc-truth: the onboarding guides prescribe only commands that exist" {
    # training-booklet / developer-workflow / working-with-claude-securely /
    # migration-sites-tracking / coder-onboarding / setup are THE onboarding
    # path. A new coder copying from them must not hit "No such file".
    run bash -c "'$DT' --all"
    for g in training-booklet developer-workflow working-with-claude-securely \
             migration-sites-tracking coder-onboarding setup; do
        ! echo "$output" | grep 'dead-command-ref' | grep -q "guides/${g}.md" \
            || { echo "still teaching a dead command: $g"; return 1; }
    done
}

# ─── 4. the recovery strings ──────────────────────────────────────────────────

@test "no print_error in a deploy verb prescribes a raw drush/ssh recovery" {
    # The instruction printed while a LIVE SITE IS DARK is the one that trains
    # the reflex. Eight call sites across stg2live/live2prod/stg2prod told the
    # operator to "Fix on the host: sudo -u www-data … drush … sset
    # system.maintenance_mode 0", bypassing the dry-run default, the ADR-0028
    # deploy gate, the live.enabled flag and the rollback ledger.
    #
    # lib/moodle-deploy.sh already does it right ("Recover: pl moodle rollback
    # … --execute"); the Drupal path was the outlier.
    # The pattern matches a COMMAND SHAPE, not the word "drush": a diagnostic
    # ("drush updatedb FAILED on live") is fine and must stay. What must not
    # survive is an instruction the operator can paste into a terminal —
    # `ssh …`, `sudo -u www-data …`, `…/vendor/bin/drush …`, `&& drush …`.
    run bash -c "grep -nE 'print_error[^\"]*\"[^\"]*(ssh [^\"]*@|sudo +-u +www-data|vendor/bin/drush|&& *drush|; *drush)' \
                   '${PROJECT_ROOT}'/scripts/commands/stg2live.sh \
                   '${PROJECT_ROOT}'/scripts/commands/live2prod.sh \
                   '${PROJECT_ROOT}'/scripts/commands/stg2prod.sh \
                 | grep -v 'pl drush' | grep -v 'pl moodle' || true"
    [ -z "$output" ] || { echo "raw recovery strings still present:"; echo "$output"; return 1; }
}

@test "the recovery strings name a pl verb that actually dispatches" {
    # A recovery string pointing at an invented verb is worse than a raw one:
    # it fails at the prompt during an outage. Assert every `pl <verb>` printed
    # by the three deploy verbs resolves.
    run bash -c "grep -hoE 'pl [a-z][a-z0-9-]+' \
                   '${PROJECT_ROOT}'/scripts/commands/stg2live.sh \
                   '${PROJECT_ROOT}'/scripts/commands/live2prod.sh \
                   '${PROJECT_ROOT}'/scripts/commands/stg2prod.sh \
                 | sed 's/^pl //' | sort -u"
    local verb
    for verb in $output; do
        run "${PROJECT_ROOT}/pl" commands
        echo "$output" | grep -qE "^[[:space:]]+${verb}[[:space:]]" \
            || { echo "recovery string names a non-existent verb: pl $verb"; return 1; }
    done
}

@test "the recovery strings do not name a FLAG the verb refuses" {
    # Caught during this item's own implementation: the first draft of the prod
    # recovery strings said `pl monitor uptime --tier=prod`, and
    # monitor.sh:203 refuses anything but --tier=live ("Unsupported tier"). A
    # recovery line that fails at the prompt during an outage is the same defect
    # as a dead verb, one level down. `pl drush` is stg|live only for the same
    # reason, so `--tier=prod` must not appear in a printed instruction either.
    run bash -c "grep -n 'print_error' \
                   '${PROJECT_ROOT}'/scripts/commands/stg2live.sh \
                   '${PROJECT_ROOT}'/scripts/commands/live2prod.sh \
                   '${PROJECT_ROOT}'/scripts/commands/stg2prod.sh \
                 | grep -- '--tier=prod' || true"
    [ -z "$output" ] || { echo "printed instruction uses an unsupported tier:"; echo "$output"; return 1; }
}

# ─── 5. ops#319 — stale baseline rows, ADR hygiene, the memory corpus ─────────
#
# Each check below was OBSERVED MISSING against the pre-fix tree (2026-08-09),
# red-then-green:
#
#   * STALE ROWS — a fixture whose baseline carried a row reproducing NOWHERE
#     ran GREEN: "SUCCESS: no new drift (0 known/baselined item(s) ignored)",
#     rc=0 — while the count itself said "0 baselined" over a 1-row baseline.
#     The real .doc-truth-baseline had grown exactly 14 such dead rows of 392
#     (meta-2026-08-09 pass 3, probe P1: 392 non-comment rows, 378 reproduce).
#     Both sibling lints already fail on stale rows; this file did not.
#
#   * ADR HYGIENE — a fixture docs/decisions with TWO 0001-*.md files and a
#     Status-less ADR ran GREEN, rc=0 — while the real tree had two 0032-*.md
#     files coexisting since 2026-08-06 (0032-non-prod-data-refresh vs
#     0032-review-mode-follows-approvers, renumbered to 0037 in this MR) and
#     ADR-0034 carried its status as a `- **Status:**` list item that ops#318
#     recorded as "no Status line at all".
#
#   * MEMORY — `--memory` did not exist while the injected auto-memory's
#     MEMORY.md:31-33 PRESCRIBED the raw scp/sudo-cp/admin-cli deploy idiom
#     (the recorded pl-first violation vector, meta-2026-08-09 item 8/RC3).

# A minimal NON-GIT tree: scan_files falls back to `find`, and the engine
# honours a pre-set PROJECT_ROOT, so every case here runs against a fixture
# instead of the live repo.
_fixture_tree() {
    FIX="${BATS_TEST_TMPDIR}/fixture"
    mkdir -p "${FIX}/docs"
    printf '# clean doc\n' > "${FIX}/docs/clean.md"
}

@test "doc-truth: a baseline row that no longer reproduces FAILS, naming the row" {
    _fixture_tree
    printf 'dead-command-ref|docs/gone.md|./zz-no-such.sh\n' > "${FIX}/.doc-truth-baseline"
    run env PROJECT_ROOT="$FIX" "$DT"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'STALE BASELINE ROW'
    echo "$output" | grep -q 'zz-no-such.sh'
}

@test "doc-truth: --json carries the stale count and fails on it" {
    _fixture_tree
    printf 'dead-command-ref|docs/gone.md|./zz-no-such.sh\n' > "${FIX}/.doc-truth-baseline"
    run env PROJECT_ROOT="$FIX" "$DT" --json
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"stale":1'
}

@test "doc-truth: a baseline that exactly matches live drift stays green (control)" {
    _fixture_tree
    printf '# probe\n\n```bash\n./zz-no-such.sh\n```\n' > "${FIX}/docs/teaches-dead.md"
    printf 'dead-command-ref|docs/teaches-dead.md|./zz-no-such.sh\n' > "${FIX}/.doc-truth-baseline"
    run env PROJECT_ROOT="$FIX" "$DT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'no stale baseline rows'
}

@test "doc-truth: a duplicated ADR number is drift (adr-dup)" {
    _fixture_tree
    mkdir -p "${FIX}/docs/decisions"
    printf '# ADR-0001: a\n\n**Status:** Accepted\n' > "${FIX}/docs/decisions/0001-first.md"
    printf '# ADR-0001: b\n\n**Status:** Accepted\n' > "${FIX}/docs/decisions/0001-second.md"
    run env PROJECT_ROOT="$FIX" "$DT"
    [ "$status" -eq 1 ]
    echo "$output" | grep 'adr-dup' | grep -q '0001'
}

@test "doc-truth: an ADR without a template-shape Status line is drift (adr-status)" {
    # The 0034 shape: a `- **Status:**` list item is NOT the template's
    # column-0 `**Status:**` and counts as zero — that variant was invisible
    # to every Status-grep in the estate (ops#318: "no Status line at all").
    _fixture_tree
    mkdir -p "${FIX}/docs/decisions"
    printf '# ADR-0002: x\n\n- **Status:** Proposed (list-item shape)\n' > "${FIX}/docs/decisions/0002-liststatus.md"
    run env PROJECT_ROOT="$FIX" "$DT"
    [ "$status" -eq 1 ]
    echo "$output" | grep 'adr-status' | grep -q '0002-liststatus.md'
    echo "$output" | grep -q '0-status-lines'
}

@test "doc-truth: two Status lines are as wrong as none (correction-by-accretion)" {
    _fixture_tree
    mkdir -p "${FIX}/docs/decisions"
    printf '# ADR-0003: y\n\n**Status:** Proposed\n\n**Status:** Accepted\n' > "${FIX}/docs/decisions/0003-double.md"
    run env PROJECT_ROOT="$FIX" "$DT"
    [ "$status" -eq 1 ]
    echo "$output" | grep 'adr-status' | grep -q '2-status-lines'
}

@test "doc-truth: well-formed ADRs are not drift (over-fire guard)" {
    _fixture_tree
    mkdir -p "${FIX}/docs/decisions"
    printf '# ADR-0001: a\n\n**Status:** Accepted\n' > "${FIX}/docs/decisions/0001-only.md"
    printf '# ADR-0002: b\n\n**Status:** Superseded by ADR-0001\n' > "${FIX}/docs/decisions/0002-only.md"
    run env PROJECT_ROOT="$FIX" "$DT"
    [ "$status" -eq 0 ]
}

@test "the real docs/decisions holds the adr-hygiene invariant (no dup numbers, one Status each)" {
    # Deterministic on any checkout: this is the invariant the born-red run
    # forced — 0032-review-mode → 0037, and 0034's status normalised.
    run bash -c "cd '${PROJECT_ROOT}/docs/decisions' && ls [0-9][0-9][0-9][0-9]-*.md | cut -c1-4 | sort | uniq -d"
    [ -z "$output" ]
    local f n
    for f in "${PROJECT_ROOT}"/docs/decisions/[0-9][0-9][0-9][0-9]-*.md; do
        n="$(grep -c '^\*\*Status:\*\*' "$f" || true)"
        [ "$n" -eq 1 ] || { echo "not exactly one Status line: $f ($n)"; return 1; }
    done
}

@test "doc-truth --memory: a memory note PRESCRIBING the raw idiom is RED (the MEMORY.md:31 incident)" {
    local M="${BATS_TEST_TMPDIR}/memory-bad"
    mkdir -p "$M"
    printf '# mem\n\n- Deploy: `sudo -u www-data php admin/cli/purge_caches.php`\n' > "${M}/note.md"
    run env NWP_MEMORY_DIR="$M" "$DT" --memory
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'memory-prescribes'
    echo "$output" | grep -q 'note.md'
}

@test "doc-truth --memory: a note that names the pl verb is clean (describe, don't prescribe)" {
    local M="${BATS_TEST_TMPDIR}/memory-good"
    mkdir -p "$M"
    printf '# mem\n\n- Moodle CLI: `pl moodle cli ss --tier=live --execute -- admin/cli/purge_caches.php`\n' > "${M}/note.md"
    run env NWP_MEMORY_DIR="$M" "$DT" --memory
    [ "$status" -eq 0 ]
}

@test "doc-truth --memory: an unreadable corpus is exit 2 CANNOT VERIFY, never green" {
    # The CI-runner case. A runner has no ~/.claude; grading that as 'clean'
    # would be the swallowed-verdict shape. This is also WHY the mode is not
    # wired into a blocking CI job: a job that is honestly, permanently exit-2
    # trains people to merge past red (the boundary:classify lesson, ops#165).
    run env NWP_MEMORY_DIR="${BATS_TEST_TMPDIR}/zz-absent" "$DT" --memory
    [ "$status" -eq 2 ]
    echo "$output" | grep -q 'CANNOT VERIFY'
}

@test "doc-truth --memory: an EMPTY corpus is exit 2, not a pass" {
    local M="${BATS_TEST_TMPDIR}/memory-empty"
    mkdir -p "$M"
    run env NWP_MEMORY_DIR="$M" "$DT" --memory
    [ "$status" -eq 2 ]
    echo "$output" | grep -q 'CANNOT VERIFY'
}
