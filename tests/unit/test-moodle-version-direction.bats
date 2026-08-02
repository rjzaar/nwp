#!/usr/bin/env bats
#
# ops#229 — A DEPLOY MUST NOT MOVE $plugin->version BACKWARDS BY ACCIDENT.
#
# THE HAZARD, measured on this estate 2026-08-03 (pl moodle plugin drift ssd):
#
#     sites/ssd/dev/mod/depthcontent                     2026072000
#     sites/ssd/.plugin-src/ss-moodle-plugins/…          2026072600
#     LIVE /var/www/ssd/mod/depthcontent                 2026080101
#
# `_moodle_resolve_source` defaults to the DEV tree, and the dev tree has no
# video renderer. So a naive
#
#     pl moodle plugin deploy ssd mod/depthcontent --tier=live --apply
#
# shipped 2026072000 over 2026080101 and silently removed video from all 175
# clips on a live site. Same shape as ops#103: the verb's default source is not
# the canonical source, and the resulting deploy LOOKS SUCCESSFUL. The pre-existing
# drift warning compares source trees to each other and never looks at the target,
# so nothing in the deploy output said the version had gone backwards.
#
# The decision is a pure function of two numbers, which is why it is one
# (`moodle_version_direction`) and why these cases need no ssh, no site config
# and no live host. The command's use of it is asserted separately, including
# the ORDERING — which was got wrong first time, see below.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  source "${REPO_ROOT}/lib/ui.sh"
  source "${REPO_ROOT}/lib/moodle-deploy.sh"
  MOODLE="${REPO_ROOT}/scripts/commands/moodle.sh"
}
teardown() { rm -rf "${TEST_TMP}"; }

# ── the decision ─────────────────────────────────────────────────────────────

@test "backwards is named backwards — the real ssd numbers" {
  run moodle_version_direction 2026072000 2026080101
  [ "$output" = "backwards" ]
}

@test "forward, same and first-install are each distinct" {
  run moodle_version_direction 2026080102 2026080101; [ "$output" = "forward" ]
  run moodle_version_direction 2026080101 2026080101; [ "$output" = "same" ]
  run moodle_version_direction 2026080101 none;       [ "$output" = "first-install" ]
}

@test "an unreadable SOURCE is its own answer, never 'first-install'" {
  # Both involve a missing version, and collapsing them would mean either
  # refusing every genuine first install or waving through a source nobody can
  # read. Two halves of the same vacuous pass.
  run moodle_version_direction "" 2026080101;  [ "$output" = "unreadable-source" ]
  run moodle_version_direction "" "";          [ "$output" = "unreadable-source" ]
}

@test "non-numeric junk on either side is handled, not arithmetic-crashed" {
  # `[ "$src" -lt "$tgt" ]` on a non-numeric string is a bash error, and under
  # `set -e` in the deploy path that is an exit with no explanation.
  run moodle_version_direction "v1.2.3" 2026080101; [ "$status" -eq 0 ]; [ "$output" = "unreadable-source" ]
  run moodle_version_direction 2026080101 "abc";    [ "$status" -eq 0 ]; [ "$output" = "first-install" ]
  run moodle_version_direction 2026080101 unreachable; [ "$status" -eq 0 ]; [ "$output" = "unreadable-target" ]
}

@test "one-off boundary: a single tick backwards is still backwards" {
  run moodle_version_direction 2026080100 2026080101
  [ "$output" = "backwards" ]
}

# ── reading the version out of a tree ────────────────────────────────────────

@test "moodle_plugin_version_dir reads the plugin dir's own version.php" {
  mkdir -p "$TEST_TMP/p"
  printf '<?php\n$plugin->version = 2026080101;\n' > "$TEST_TMP/p/version.php"
  run moodle_plugin_version_dir "$TEST_TMP/p"
  [ "$status" -eq 0 ]
  [ "$output" = "2026080101" ]
}

@test "an absent or version-less version.php FAILS rather than echoing empty-success" {
  run moodle_plugin_version_dir "$TEST_TMP/nope"; [ "$status" -ne 0 ]
  mkdir -p "$TEST_TMP/q"; printf '<?php\n$plugin->component = "mod_x";\n' > "$TEST_TMP/q/version.php"
  run moodle_plugin_version_dir "$TEST_TMP/q";    [ "$status" -ne 0 ]
}

@test "the tree-root and plugin-dir readers agree — one regex, one answer" {
  # They used to be two separate seds. Two regexes for the same field is how two
  # callers come to disagree about what version a tree is at.
  mkdir -p "$TEST_TMP/root/mod/x"
  printf '<?php\n$plugin->version = 2026072600;\n' > "$TEST_TMP/root/mod/x/version.php"
  a="$(moodle_plugin_version_dir   "$TEST_TMP/root/mod/x")"
  b="$(moodle_plugin_version_local "$TEST_TMP/root" mod/x)"
  [ "$a" = "$b" ]
  [ "$a" = "2026072600" ]
}

# ── the remote read never invents a version ──────────────────────────────────

@test "an ssh that CANNOT BE ASKED is 'unreachable', never 'none'" {
  # This is the fail-open the three-state read exists to close. The older
  # two-state helper returns empty for BOTH "no version.php" and "ssh died", so
  # a gate built on it would treat an ssh timeout as a first install and wave a
  # downgrade straight through.
  STUB="$TEST_TMP/bin"; mkdir -p "$STUB"
  printf '#!/bin/bash\nexit 255\n' > "$STUB/ssh"; chmod +x "$STUB/ssh"
  run env PATH="$STUB:$PATH" bash -c "source '$REPO_ROOT/lib/ui.sh'; source '$REPO_ROOT/lib/moodle-deploy.sh';
        moodle_plugin_target_version u@h '' '' /var/www/x mod/y"
  [ "$output" = "unreachable" ]
  # …and the decision refuses on it.
  run moodle_version_direction 2026080101 unreachable
  [ "$output" = "unreadable-target" ]
}

@test "a REACHABLE host with no version.php is 'none' — a first install still works" {
  # Negative control. Without it, "refuse on unreachable" is satisfied by a
  # helper that says unreachable always, which would block every first install.
  STUB="$TEST_TMP/bin"; mkdir -p "$STUB"
  printf '#!/bin/bash\necho NOFILE\nexit 0\n' > "$STUB/ssh"; chmod +x "$STUB/ssh"
  run env PATH="$STUB:$PATH" bash -c "source '$REPO_ROOT/lib/ui.sh'; source '$REPO_ROOT/lib/moodle-deploy.sh';
        moodle_plugin_target_version u@h '' '' /var/www/x mod/y"
  [ "$output" = "none" ]
}

@test "a reachable host WITH a version returns exactly that version" {
  STUB="$TEST_TMP/bin"; mkdir -p "$STUB"
  printf '#!/bin/bash\necho 2026080101\nexit 0\n' > "$STUB/ssh"; chmod +x "$STUB/ssh"
  run env PATH="$STUB:$PATH" bash -c "source '$REPO_ROOT/lib/ui.sh'; source '$REPO_ROOT/lib/moodle-deploy.sh';
        moodle_plugin_target_version u@h '' '' /var/www/x mod/y"
  [ "$output" = "2026080101" ]
}

# ── the command wires it in, and in the right ORDER ──────────────────────────

# ── THE REFUSAL ITSELF ───────────────────────────────────────────────────────
# These are the cases that matter, and they are behavioural rather than greps.
# The first draft of this gate was inline in cmd_plugin_deploy, so the only
# tests possible were greps for a function name — and those stayed GREEN when
# the refusal was deleted (mutation-proven). The gate now lives in a function
# that can be called with two numbers.

@test "REFUSAL: a backwards deploy returns non-zero and says so" {
  run moodle_version_gate_report mod/depthcontent /src 2026072000 2026080101 false ssd live dev-tree
  [ "$status" -eq 1 ]
  [[ "$output" == *"BACKWARDS"* ]]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"2026080101 -> 2026072000"* ]]
  # and it must point at the fix, not merely complain
  [[ "$output" == *"--from-canonical"* ]]
  [[ "$output" == *"--allow-downgrade"* ]]
}

@test "REFUSAL: --allow-downgrade turns the same call into an accepted downgrade" {
  run moodle_version_gate_report mod/depthcontent /src 2026072000 2026080101 true ssd live dev-tree
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOWNGRADE ACCEPTED"* ]]
  [[ "$output" != *"REFUSED"* ]]
}

@test "REFUSAL: an unreadable source refuses even WITH --allow-downgrade" {
  # --allow-downgrade says "I know it goes backwards". It does not say "ship a
  # tree whose version nobody can read".
  run moodle_version_gate_report mod/x /src "" 2026080101 true ssd live dev-tree
  [ "$status" -eq 1 ]
  [[ "$output" == *"SOURCE VERSION UNREADABLE"* ]]
}

@test "REFUSAL: an unreachable target refuses even WITH --allow-downgrade" {
  run moodle_version_gate_report mod/x /src 2026080101 unreachable true ssd live dev-tree
  [ "$status" -eq 1 ]
  [[ "$output" == *"TARGET VERSION UNREADABLE"* ]]
  [[ "$output" == *"could not look"* ]]
}

@test "NEGATIVE CONTROL: forward, same and first-install all PASS" {
  # Without this, every refusal above is satisfied by a gate that refuses
  # everything — which would make the deploy verb unusable and would be a worse
  # bug than the one being fixed.
  run moodle_version_gate_report mod/x /src 2026080102 2026080101 false ssd live c; [ "$status" -eq 0 ]
  run moodle_version_gate_report mod/x /src 2026080101 2026080101 false ssd live c; [ "$status" -eq 0 ]
  run moodle_version_gate_report mod/x /src 2026080101 none       false ssd live c; [ "$status" -eq 0 ]
}

@test "the deploy path calls the gate function, once per plugin" {
  run grep -c 'moodle_version_gate_report' "$MOODLE"
  [ "$output" -ge 1 ]
  run grep -c 'allow_downgrade' "$MOODLE"
  [ "$output" -ge 3 ]
}

@test "ORDER: the version gate runs BEFORE the AMD freshness gate" {
  # Found the hard way. Placed after freshness, the gate was UNREACHABLE for the
  # very case that motivated it: ssd's dev tree has a stale amd build, so
  # freshness refused first and the operator never learned the version was going
  # backwards. Freshness catching it there was a coincidence, not a guarantee —
  # a freshly-built dev tree is still a downgrade, and then the version gate is
  # the only thing between the operator and the regression.
  vg=$(grep -n 'VERSION-DIRECTION GATE' "$MOODLE" | head -1 | cut -d: -f1)
  fg=$(grep -n '# 7. freshness gate' "$MOODLE" | head -1 | cut -d: -f1)
  [ -n "$vg" ] && [ -n "$fg" ]
  [ "$vg" -lt "$fg" ]
}

@test "ORDER: the version gate runs BEFORE anything is written" {
  # It must be a preflight, not a post-mortem: before the deploy gate, before the
  # pre-deploy snapshot, before the rsync.
  vg=$(grep -n 'VERSION-DIRECTION GATE' "$MOODLE" | head -1 | cut -d: -f1)
  for marker in 'deploy_gate_require "\$BASE"' 'Pre-deploy snapshot' 'moodle_plugin_rsync "'; do
    ln=$(grep -n "$marker" "$MOODLE" | head -1 | cut -d: -f1)
    [ -n "$ln" ] || { echo "marker not found: $marker"; false; }
    [ "$vg" -lt "$ln" ] || { echo "$marker at $ln precedes the gate at $vg"; false; }
  done
}

@test "the gate runs on DRY-RUN too — a refusal you need --apply to discover is not a preflight" {
  # The gate block sits above the `mode = apply` branches entirely; assert that
  # structurally rather than trusting the reading.
  vg=$(grep -n 'VERSION-DIRECTION GATE' "$MOODLE" | head -1 | cut -d: -f1)
  ap=$(grep -n 'local apply="false"; \[ "\$mode" = "apply" \] && apply="true"' "$MOODLE" | head -1 | cut -d: -f1)
  [ -n "$ap" ]
  [ "$vg" -lt "$ap" ]
}

@test "a downgrade is LEDGERED in the fate manifest, not only warned about" {
  run grep -c 'impact_warn "--allow-downgrade' "$MOODLE"
  [ "$output" -ge 1 ]
}

@test "--allow-downgrade is a real flag the parser accepts" {
  run grep -c -- '--allow-downgrade) allow_downgrade="true"' "$MOODLE"
  [ "$output" -eq 1 ]
}
