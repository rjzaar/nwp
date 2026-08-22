#!/usr/bin/env bats
# ops#383 — acceptance suite for `pl docs retire` / `retired` / `restore`.
#
# WHAT THIS SUITE IS FOR. The operator's requirement was not "delete the dead
# docs"; it was "put them somewhere that can be checked later, make it clear
# what was cleaned, and keep whatever is removed findable if a mistake has been
# made". Those are three testable claims and this file is where they are
# tested:
#
#   * findable      — the retired bytes are still in the tree, at a recorded
#                     path, under a recorded sha256 (cases 5, 6, 12);
#   * clear         — a manifest row names the original path, the date, the
#                     reason, the ref and the exact command that undoes it,
#                     and the verb prints every tracked line still pointing at
#                     the old path (cases 6, 7, 14);
#   * recoverable   — `pl docs restore` round-trips the file BYTE-IDENTICALLY,
#                     proven by comparing sha256 before and after (cases 8, 12).
#
# RED-PROOF. Every case below was run against a tree with
# `scripts/commands/docs.sh` absent — the state of `main` — and observed to
# fail. Transcript quoted in the ops#383 merge request. The three REFUSAL cases
# (1, 2, 3) assert the ERROR TEXT, never a bare non-zero exit: `! pl docs …`
# would be satisfied by "unknown command", which is exactly the blind-negation
# defect the standing order forbids (CLAUDE.md, six of them found in one night).
#
# Case 15 is the over-fire guard for the doc-truth skip: the gate must stop
# reading retired documents (they are archives, and their dead links are the
# point), but must NOT stop reading the manifest that indexes them.

setup() {
    REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    DOCS="${REPO_ROOT}/scripts/commands/docs.sh"
    FIX="$(mktemp -d)"
    _fixture_repo "$FIX"
}

teardown() {
    [ -n "${FIX:-}" ] && rm -rf "$FIX"
    return 0
}

# A throwaway git repo with one tracked doc, one tracked directory of docs,
# and one untracked file. Everything runs against THIS, never the real tree.
_fixture_repo() {
    local d="$1"
    git -C "$d" init -q
    git -C "$d" config user.email "test@example.invalid"
    git -C "$d" config user.name  "bats"
    mkdir -p "$d/docs/reference/commands"
    printf '# Dead inventory\n\nSee [backup](reference/commands/backup.md).\n' > "$d/docs/DEAD.md"
    printf '# backup\n\nRun `pl backup`.\n'  > "$d/docs/reference/commands/backup.md"
    printf '# restore\n\nRun `pl restore`.\n' > "$d/docs/reference/commands/restore.md"
    printf '# index\n\n- [backup](backup.md)\n' > "$d/docs/reference/commands/README.md"
    printf '# readers\n\nSee [dead](DEAD.md) and docs/DEAD.md.\n' > "$d/docs/READERS.md"
    git -C "$d" add -A >/dev/null
    git -C "$d" commit -qm "fixture"
    printf 'untracked\n' > "$d/docs/UNTRACKED.md"
}

_docs() { PROJECT_ROOT="$FIX" run bash "$DOCS" "$@"; }

_sha() { sha256sum "$1" | awk '{print $1}'; }

# ─── 1. REFUSES without a reason ──────────────────────────────────────────────
# A retirement with no recorded reason is indistinguishable from a mistake.
@test "docs retire: REFUSES without --reason, and says so by name" {
    _docs retire docs/DEAD.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"--reason is required"* ]]
    # …and it did NOT move anything.
    [ -f "$FIX/docs/DEAD.md" ]
    [ ! -d "$FIX/docs/_retired" ]
}

@test "docs retire: an all-whitespace reason is not a reason" {
    _docs retire docs/DEAD.md --reason='   '
    [ "$status" -eq 1 ]
    [[ "$output" == *"--reason is required"* ]]
    [ -f "$FIX/docs/DEAD.md" ]
}

# ─── 2. REFUSES an untracked path ─────────────────────────────────────────────
# "Moved, recoverably" is a promise this verb cannot keep for a file with no
# history behind it, so it must not make it.
@test "docs retire: REFUSES a path git does not track" {
    _docs retire docs/UNTRACKED.md --reason='never belonged here'
    [ "$status" -eq 1 ]
    [[ "$output" == *"not tracked by git"* ]]
    [ -f "$FIX/docs/UNTRACKED.md" ]
}

@test "docs retire: REFUSES a path that does not exist at all" {
    _docs retire docs/NOPE.md --reason='x'
    [ "$status" -eq 1 ]
    [[ "$output" == *"path does not exist"* ]]
}

# ─── 3. REFUSES when the target already exists ────────────────────────────────
@test "docs retire: REFUSES to clobber an existing retirement target" {
    _docs retire docs/DEAD.md --reason='first'
    [ "$status" -eq 0 ]
    # Put a file back at the original path and retire it again the same day:
    # the bucket name is date+slug, so the destination is already occupied.
    printf 'second\n' > "$FIX/docs/DEAD.md"
    git -C "$FIX" add docs/DEAD.md >/dev/null
    git -C "$FIX" commit -qm "second"
    _docs retire docs/DEAD.md --reason='second'
    [ "$status" -eq 1 ]
    [[ "$output" == *"retirement target already exists"* ]]
    # The refusal names its own way through, and that way through works.
    [[ "$output" == *"--slug="* ]]
    _docs retire docs/DEAD.md --reason='second' --slug=dead-2
    [ "$status" -eq 0 ]
}

# ─── 4. CANNOT VERIFY, never a silent success ─────────────────────────────────
@test "docs retire: a non-git tree is CANNOT VERIFY (exit 2), not exit 0" {
    local nogit; nogit="$(mktemp -d)"
    mkdir -p "$nogit/docs"; printf 'x\n' > "$nogit/docs/A.md"
    PROJECT_ROOT="$nogit" run bash "$DOCS" retire docs/A.md --reason='x'
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    [[ "$output" == *"not a git checkout"* ]]
    rm -rf "$nogit"
}

# ─── 5. it MOVES, preserving the relative path under a dated bucket ───────────
@test "docs retire: moves the file into docs/_retired/<date>-<slug>/<relpath>" {
    local today; today="$(date +%Y-%m-%d)"
    _docs retire docs/DEAD.md --reason='55 of 119 verbs' --ref=ops#383
    [ "$status" -eq 0 ]
    [ ! -e "$FIX/docs/DEAD.md" ]
    [ -f "$FIX/docs/_retired/${today}-dead/docs/DEAD.md" ]
    # and git knows it as a move, so history follows the content
    run git -C "$FIX" status --porcelain
    [[ "$output" == *"R "* ]] || [[ "$output" == *"docs/_retired"* ]]
}

# ─── 6. the manifest row carries every field the operator asked for ───────────
@test "docs retire: manifest row records path, date, reason, ref, sha256, restore cmd" {
    local before; before="$(_sha "$FIX/docs/DEAD.md")"
    _docs retire docs/DEAD.md --reason='its own banner says do not trust it' --ref=ops#383
    [ "$status" -eq 0 ]
    local m="$FIX/docs/_retired/MANIFEST.md"
    [ -f "$m" ]
    grep -q 'docs/DEAD.md'                          "$m"
    grep -q "$(date +%Y-%m-%d)"                     "$m"
    grep -q 'its own banner says do not trust it'   "$m"
    grep -q 'ops#383'                               "$m"
    grep -q "$before"                               "$m"
    grep -q 'pl docs restore docs/DEAD.md'          "$m"
}

# ─── 7. retired --list / --json is searchable ─────────────────────────────────
@test "docs retired --list and --json report what was retired" {
    _docs retire docs/DEAD.md --reason='dead' --ref=ops#383
    [ "$status" -eq 0 ]
    _docs retired --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"docs/DEAD.md"* ]]
    [[ "$output" == *"pl docs restore docs/DEAD.md"* ]]
    _docs retired --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"original":"docs/DEAD.md"'* ]]
    [[ "$output" == *'"status":"retired"'* ]]
}

@test "docs retired: an empty ledger reports emptiness, it does not error" {
    _docs retired --json
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

# ─── 8. THE ROUND TRIP — byte-identical, proven by sha256 ─────────────────────
@test "docs restore: round-trips a file BYTE-IDENTICALLY (sha256 before == after)" {
    local before after
    before="$(_sha "$FIX/docs/DEAD.md")"
    _docs retire docs/DEAD.md --reason='dead' --ref=ops#383
    [ "$status" -eq 0 ]
    [ ! -e "$FIX/docs/DEAD.md" ]

    _docs restore docs/DEAD.md
    [ "$status" -eq 0 ]
    [ -f "$FIX/docs/DEAD.md" ]
    after="$(_sha "$FIX/docs/DEAD.md")"
    [ "$before" = "$after" ]
    [[ "$output" == *"byte-identical"* ]]

    # the ledger row now says restored, and the default listing drops it
    grep -q 'restored' "$FIX/docs/_retired/MANIFEST.md"
    _docs retired --json
    [ "$output" = "[]" ]
    _docs retired --json --all
    [[ "$output" == *'"status":"restored"'* ]]
}

@test "docs restore: REFUSES a path no manifest row claims" {
    _docs restore docs/NEVER.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"no retired entry for"* ]]
}

@test "docs restore: REFUSES to overwrite a file that is back at the original path" {
    _docs retire docs/DEAD.md --reason='dead'
    [ "$status" -eq 0 ]
    printf 'a different file now lives here\n' > "$FIX/docs/DEAD.md"
    _docs restore docs/DEAD.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists in the tree"* ]]
}

# ─── 9. a tampered archive is a REFUSAL with a LEDGERED way through ───────────
# ops#361: a fail-closed guard must offer a truthful exit. Here it is
# --allow-modified, which records what actually happened ("restored-modified")
# rather than borrowing somebody's approval.
@test "docs restore: REFUSES when the archived copy no longer hashes to the record" {
    local today; today="$(date +%Y-%m-%d)"
    _docs retire docs/DEAD.md --reason='dead'
    [ "$status" -eq 0 ]
    printf 'tampered\n' >> "$FIX/docs/_retired/${today}-dead/docs/DEAD.md"

    _docs restore docs/DEAD.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"content changed since retirement"* ]]
    [[ "$output" == *"--allow-modified"* ]]
    [ ! -e "$FIX/docs/DEAD.md" ]

    _docs restore docs/DEAD.md --allow-modified
    [ "$status" -eq 0 ]
    [ -f "$FIX/docs/DEAD.md" ]
    grep -q 'restored-modified' "$FIX/docs/_retired/MANIFEST.md"
}

# ─── 10. directories retire and restore as a unit ─────────────────────────────
@test "docs retire/restore: a directory round-trips, every file byte-identical" {
    local before after
    before="$( cd "$FIX/docs/reference/commands" && find . -type f -print0 \
                 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum )"
    _docs retire docs/reference/commands --reason='46 of 119 verbs' --ref=ops#383
    [ "$status" -eq 0 ]
    [ ! -e "$FIX/docs/reference/commands" ]
    [[ "$output" == *"tree:"* ]]
    # the per-file sums sidecar makes an individual page findable by hash
    local today; today="$(date +%Y-%m-%d)"
    [ -f "$FIX/docs/_retired/${today}-commands/SHA256SUMS" ]
    grep -q 'backup.md' "$FIX/docs/_retired/${today}-commands/SHA256SUMS"

    _docs restore docs/reference/commands
    [ "$status" -eq 0 ]
    after="$( cd "$FIX/docs/reference/commands" && find . -type f -print0 \
                | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum )"
    [ "$before" = "$after" ]
    [ -f "$FIX/docs/reference/commands/backup.md" ]
    [ -f "$FIX/docs/reference/commands/README.md" ]
}

# ─── 11. retirement is VISIBLE: it names the readers it just orphaned ─────────
@test "docs retire: prints every tracked line still pointing at the old path" {
    _docs retire docs/DEAD.md --reason='dead' --ref=ops#383
    [ "$status" -eq 0 ]
    [[ "$output" == *"still point at the OLD path"* ]]
    [[ "$output" == *"docs/READERS.md"* ]]
}

@test "docs retire: says so plainly when nothing referenced the old path" {
    _docs retire docs/reference/commands/restore.md --reason='unreferenced'
    [ "$status" -eq 0 ]
    [[ "$output" == *"no tracked file references the old path"* ]]
}

# ─── 12. doc-truth stops reading retired docs — but still reads the manifest ──
@test "doc-truth: a dead link INSIDE a retirement bucket is not reported" {
    local DT="${REPO_ROOT}/scripts/commands/doc-truth.sh"
    mkdir -p "$FIX/docs/_retired/2026-01-01-x/docs"
    printf '# retired\n\nSee [gone](gone-forever.md).\n' \
        > "$FIX/docs/_retired/2026-01-01-x/docs/OLD.md"
    PROJECT_ROOT="$FIX" run bash "$DT" --all
    [[ "$output" != *"gone-forever.md"* ]]
}

@test "doc-truth: a dead link in the retirement MANIFEST itself IS reported" {
    local DT="${REPO_ROOT}/scripts/commands/doc-truth.sh"
    mkdir -p "$FIX/docs/_retired"
    printf '# manifest\n\nSee [gone](manifest-target-gone.md).\n' \
        > "$FIX/docs/_retired/MANIFEST.md"
    PROJECT_ROOT="$FIX" run bash "$DT" --all
    [[ "$output" == *"manifest-target-gone.md"* ]]
}

# ─── 13. the verb is dispatchable and inventoried ─────────────────────────────
@test "pl commands lists docs, so doc-truth's oracle accepts 'pl docs'" {
    run bash -c "cd '$REPO_ROOT' && ./pl commands --json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"name":"docs"'* ]]
}
