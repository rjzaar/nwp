#!/usr/bin/env bats
#
# ops#73 (NWP-ADR-0031 D4 residue) — THE PER-TREE PLUGIN LOCKFILE.
#
# THE GAP, measured on this estate 2026-08-07: `pl moodle plugin deploy` ships a
# plugin dir to a live tree, gates it six ways, snapshots it — and records the
# provenance of what it shipped NOWHERE. "What is deployed on ssd right now,
# and from which canonical commit?" is answerable only by ssh-ing to the box
# and reading version.php, which gives the version but never the commit. The
# ops#73 design (docs/guides/ops73-moodle-plugin-manifest-design.md §3) named
# the fix in July: a per-tree lockfile, the Moodle analogue of composer.lock.
# The deploy verb is the only writer that can record it honestly, because only
# the deploy knows which resolved source dir actually shipped.
#
# HONESTY RULES THESE TESTS PIN:
#   * the lockfile is a CLAIM (the box is the fact — moodle.sh's own rollback
#     ledger comment); the report must say so and point at `plugin drift`;
#   * a source dir that is NOT tracked content of a git repo records NO commit
#     — a Moodle-clone dev tree would otherwise launder MOODLE CORE's HEAD (or
#     nwp/nwp's) as the plugin's provenance;
#   * an unreadable source version REFUSES to record (no literal substituted
#     for a measurement not taken);
#   * a missing lockfile reads NOT RECORDED, non-zero — never "no drift".

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  source "${REPO_ROOT}/lib/ui.sh"
  source "${REPO_ROOT}/lib/moodle-promote.sh"   # _mp_yq
  source "${REPO_ROOT}/lib/moodle-deploy.sh"
  MOODLE="${REPO_ROOT}/scripts/commands/moodle.sh"
  LOCK="${TEST_TMP}/.nwp-plugins.lock.yml"

  # A plugin dir with version + release, NOT in any git repo.
  PLAIN="${TEST_TMP}/plain/mod/thing"
  mkdir -p "$PLAIN"
  printf '<?php\n$plugin->version = 2026080701;\n$plugin->release = '"'"'1.2.0'"'"';\n' \
    > "${PLAIN}/version.php"

  # A git repo in which the plugin dir is TRACKED (the canonical-cache shape).
  CANON="${TEST_TMP}/canon"
  mkdir -p "${CANON}/mod/thing"
  printf '<?php\n$plugin->version = 2026080701;\n$plugin->release = '"'"'1.2.0'"'"';\n' \
    > "${CANON}/mod/thing/version.php"
  git -C "$CANON" init -q
  git -C "$CANON" -c user.email=t@t -c user.name=t add -A
  git -C "$CANON" -c user.email=t@t -c user.name=t commit -qm seed
  CANON_SHA="$(git -C "$CANON" rev-parse HEAD)"

  # A git repo in which the plugin dir is UNTRACKED (the Moodle-clone shape:
  # upstream core is tracked, the custom plugin is loose files inside it).
  CLONE="${TEST_TMP}/clone"
  mkdir -p "$CLONE"
  echo core > "${CLONE}/core.txt"
  git -C "$CLONE" init -q
  git -C "$CLONE" -c user.email=t@t -c user.name=t add core.txt
  git -C "$CLONE" -c user.email=t@t -c user.name=t commit -qm core
  mkdir -p "${CLONE}/mod/thing"
  printf '<?php\n$plugin->version = 2026080701;\n' > "${CLONE}/mod/thing/version.php"
}
teardown() { rm -rf "${TEST_TMP}"; }

# ── reading $plugin->release ─────────────────────────────────────────────────

@test "moodle_plugin_release_dir reads the release string" {
  run moodle_plugin_release_dir "$PLAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.0" ]
}

@test "a release-less version.php FAILS rather than echoing empty-success (format_tabbed shape)" {
  mkdir -p "$TEST_TMP/norel"
  printf '<?php\n$plugin->version = 2026030900;\n' > "$TEST_TMP/norel/version.php"
  run moodle_plugin_release_dir "$TEST_TMP/norel"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]   # "function does not exist" is not a refusal
}

# ── provenance: which commit did this source dir come from? ──────────────────

@test "provenance of a tracked plugin dir is the repo commit, clean" {
  run moodle_plugin_source_provenance "${CANON}/mod/thing"
  [ "$status" -eq 0 ]
  [[ "$output" == "${CANON_SHA} clean"* ]]
}

@test "provenance of a MODIFIED tracked plugin dir says dirty" {
  echo '// edit' >> "${CANON}/mod/thing/version.php"
  run moodle_plugin_source_provenance "${CANON}/mod/thing"
  [[ "$output" == "${CANON_SHA} dirty"* ]]
}

@test "an UNTRACKED plugin dir inside a git repo is 'none' — never the host repo's HEAD" {
  # The load-bearing honesty case: sites/<s>/dev is an upstream-Moodle clone
  # whose custom plugins are untracked files. rev-parse alone would record
  # MOODLE CORE's commit as the plugin's provenance — a well-formed lie.
  run moodle_plugin_source_provenance "${CLONE}/mod/thing"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "a plugin dir outside any git repo is 'none'" {
  run env GIT_CEILING_DIRECTORIES="$TEST_TMP" bash -c \
    "source '$REPO_ROOT/lib/ui.sh'; source '$REPO_ROOT/lib/moodle-deploy.sh'; moodle_plugin_source_provenance '$PLAIN'"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

# ── recording ────────────────────────────────────────────────────────────────

@test "moodle_lock_record creates the lockfile with the deployed fact" {
  run moodle_lock_record "$LOCK" tsite live mod/thing "${CANON}/mod/thing" "canonical-repo-cache"
  [ "$status" -eq 0 ]
  [ -f "$LOCK" ]
  yq_bin="$(_mp_yq)"
  [ "$("$yq_bin" eval '.lockfile_version' "$LOCK")" = "1" ]
  [ "$("$yq_bin" eval '.site' "$LOCK")" = "tsite" ]
  [ "$("$yq_bin" eval '.tiers.live["mod/thing"].version' "$LOCK")" = "2026080701" ]
  [ "$("$yq_bin" eval '.tiers.live["mod/thing"].release' "$LOCK")" = "1.2.0" ]
  [ "$("$yq_bin" eval '.tiers.live["mod/thing"].repo_commit' "$LOCK")" = "$CANON_SHA" ]
  [ "$("$yq_bin" eval '.tiers.live["mod/thing"].repo_dirty' "$LOCK")" = "false" ]
  [ "$("$yq_bin" eval '.tiers.live["mod/thing"].source_origin' "$LOCK")" = "canonical-repo-cache" ]
  [ -n "$("$yq_bin" eval '.tiers.live["mod/thing"].deployed_at' "$LOCK")" ]
}

@test "recording a second plugin preserves the first (upsert, not overwrite)" {
  moodle_lock_record "$LOCK" tsite live mod/thing "${CANON}/mod/thing" "canonical-repo-cache"
  mkdir -p "$TEST_TMP/other/local/two"
  printf '<?php\n$plugin->version = 2026010100;\n$plugin->release = '"'"'0.1.0'"'"';\n' \
    > "$TEST_TMP/other/local/two/version.php"
  run moodle_lock_record "$LOCK" tsite live local/two "$TEST_TMP/other/local/two" "flag:--from"
  [ "$status" -eq 0 ]
  yq_bin="$(_mp_yq)"
  [ "$("$yq_bin" eval '.tiers.live["mod/thing"].version' "$LOCK")" = "2026080701" ]
  [ "$("$yq_bin" eval '.tiers.live["local/two"].version' "$LOCK")" = "2026010100" ]
}

@test "re-recording the same plugin updates the entry in place" {
  moodle_lock_record "$LOCK" tsite live mod/thing "${CANON}/mod/thing" "canonical-repo-cache"
  printf '<?php\n$plugin->version = 2026080999;\n$plugin->release = '"'"'1.3.0'"'"';\n' \
    > "${CANON}/mod/thing/version.php"
  moodle_lock_record "$LOCK" tsite live mod/thing "${CANON}/mod/thing" "canonical-repo-cache"
  yq_bin="$(_mp_yq)"
  [ "$("$yq_bin" eval '.tiers.live["mod/thing"].version' "$LOCK")" = "2026080999" ]
  [ "$("$yq_bin" eval '.tiers.live["mod/thing"].release' "$LOCK")" = "1.3.0" ]
}

@test "an unreadable source version REFUSES to record — no entry, non-zero" {
  mkdir -p "$TEST_TMP/broken/mod/x"
  printf '<?php\n// no version at all\n' > "$TEST_TMP/broken/mod/x/version.php"
  run moodle_lock_record "$LOCK" tsite live mod/x "$TEST_TMP/broken/mod/x" "dev-tree"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]   # "function does not exist" is not a refusal
  if [ -f "$LOCK" ]; then
    yq_bin="$(_mp_yq)"
    [ "$("$yq_bin" eval '.tiers.live["mod/x"]' "$LOCK")" = "null" ]
  fi
}

@test "a non-git source records repo_commit null, not a fabricated commit" {
  run env GIT_CEILING_DIRECTORIES="$TEST_TMP" bash -c \
    "source '$REPO_ROOT/lib/ui.sh'; source '$REPO_ROOT/lib/moodle-promote.sh'; source '$REPO_ROOT/lib/moodle-deploy.sh';
     moodle_lock_record '$LOCK' tsite live mod/thing '$PLAIN' 'dev-tree (default)'"
  [ "$status" -eq 0 ]
  yq_bin="$(_mp_yq)"
  [ "$("$yq_bin" eval '.tiers.live["mod/thing"].repo_commit' "$LOCK")" = "null" ]
}

@test "a release-less plugin still records (release null) — version is the required field" {
  mkdir -p "$TEST_TMP/norel2/course/format/tabbed"
  printf '<?php\n$plugin->version = 2026030900;\n' > "$TEST_TMP/norel2/course/format/tabbed/version.php"
  run moodle_lock_record "$LOCK" tsite live course/format/tabbed "$TEST_TMP/norel2/course/format/tabbed" "dev-tree"
  [ "$status" -eq 0 ]
  yq_bin="$(_mp_yq)"
  [ "$("$yq_bin" eval '.tiers.live["course/format/tabbed"].release' "$LOCK")" = "null" ]
  [ "$("$yq_bin" eval '.tiers.live["course/format/tabbed"].version' "$LOCK")" = "2026030900" ]
}

# ── reporting ────────────────────────────────────────────────────────────────

@test "a missing lockfile reads NOT RECORDED and exits non-zero — never 'fine'" {
  run moodle_lock_report "$TEST_TMP/absent.lock.yml" tsite
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT RECORDED"* ]]
}

@test "the report prints the recorded facts and the claim-vs-fact caveat" {
  moodle_lock_record "$LOCK" tsite live mod/thing "${CANON}/mod/thing" "canonical-repo-cache"
  run moodle_lock_report "$LOCK" tsite
  [ "$status" -eq 0 ]
  [[ "$output" == *"mod/thing"* ]]
  [[ "$output" == *"2026080701"* ]]
  [[ "$output" == *"1.2.0"* ]]
  [[ "$output" == *"${CANON_SHA:0:12}"* ]]
  # the lockfile is a claim; the box is the fact
  [[ "$output" == *"claim"* ]]
  [[ "$output" == *"plugin drift"* ]]
}

# ── the command wires it ─────────────────────────────────────────────────────

@test "pl moodle plugin lock <site> reports the site's lockfile" {
  # Fixture site under an overridden PROJECT_ROOT — real command, no ssh.
  mkdir -p "$TEST_TMP/proot/sites/tsite"
  printf 'project:\n  type: moodle\n' > "$TEST_TMP/proot/sites/tsite/.nwp.yml"
  moodle_lock_record "$TEST_TMP/proot/sites/tsite/.nwp-plugins.lock.yml" tsite live \
    mod/thing "${CANON}/mod/thing" "canonical-repo-cache"
  run env PROJECT_ROOT="$TEST_TMP/proot" bash "$MOODLE" plugin lock tsite
  [ "$status" -eq 0 ]
  [[ "$output" == *"mod/thing"* ]]
  [[ "$output" == *"2026080701"* ]]
}

@test "pl moodle plugin lock on a site with no lockfile says NOT RECORDED, non-zero" {
  mkdir -p "$TEST_TMP/proot/sites/tsite"
  printf 'project:\n  type: moodle\n' > "$TEST_TMP/proot/sites/tsite/.nwp.yml"
  run env PROJECT_ROOT="$TEST_TMP/proot" bash "$MOODLE" plugin lock tsite
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT RECORDED"* ]]
}

@test "plugin lock with no site prints usage, non-zero" {
  run bash "$MOODLE" plugin lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "help lists plugin lock" {
  run bash "$MOODLE" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin lock"* ]]
}

# ── deploy wiring (structural — the behavioural halves are above) ────────────

@test "the deploy path records the lockfile once per shipped plugin" {
  run grep -c 'moodle_lock_record' "$MOODLE"
  [ "$output" -ge 1 ]
}

@test "ORDER: the lock is recorded AFTER the rsync ships and BEFORE the upgrade" {
  # After: it records what IS on the target, not what was about to be. Before
  # the upgrade: the bytes are the deployed fact whether or not upgrade.php
  # then succeeds, and an upgrade failure must not lose the record of what shipped.
  rs=$(grep -n 'moodle_plugin_rsync "' "$MOODLE" | head -1 | cut -d: -f1)
  lk=$(grep -n 'LOCKFILE (ops#73)' "$MOODLE" | head -1 | cut -d: -f1)
  up=$(grep -n '# 10. Upgrade' "$MOODLE" | head -1 | cut -d: -f1)
  [ -n "$rs" ] && [ -n "$lk" ] && [ -n "$up" ]
  [ "$rs" -lt "$lk" ]
  [ "$lk" -lt "$up" ]
}

@test "the lock is written on APPLY only — a dry run records nothing" {
  # The block is guarded on the apply flag; a dry-run writing 'deployed' would
  # be the lockfile's own vacuous pass.
  lk=$(grep -n 'LOCKFILE (ops#73)' "$MOODLE" | head -1 | cut -d: -f1)
  guard=$(sed -n "${lk},$((lk+12))p" "$MOODLE" | grep -c '"\$apply" = "true"')
  [ "$guard" -ge 1 ]
}

@test "a failed lock write FAILS the verb loudly — deploy applied, record missing is not OK" {
  lk=$(grep -n 'LOCKFILE (ops#73)' "$MOODLE" | head -1 | cut -d: -f1)
  seg="$(sed -n "${lk},$((lk+20))p" "$MOODLE")"
  [[ "$seg" == *"applied"* ]]
  [[ "$seg" == *"return 1"* ]]
}
