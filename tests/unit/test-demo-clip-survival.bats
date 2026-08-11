#!/usr/bin/env bats
#
# ops#338 — would an author's clip choices survive tonight's demo reset?
#
# The nightly reset is a full destroy-and-restore with no allowlist:
#   drush sql:drop -y && gunzip -c golden.db.sql.gz | drush sql:cli
# It has pre-wipe legs for watchdog (`harvest`) and tester feedback
# (`feedback-sync`) — both added after a loss was noticed — and NONE for clip
# choices.
#
# Today the authoring site is off the reset path and the demo site is on it.
# That is the entire safety argument and it rests on convention: nwc simply
# has no `class: demo`. This suite exists so that convention can go RED.
#
# EVERY assertion below has been observed failing against a deliberately
# broken predicate; the fixtures are synthetic so the check is exercised
# rather than merely consulted about the real estate.

setup() {
    PROJECT_ROOT="$BATS_TEST_TMPDIR/root"
    export PROJECT_ROOT
    mkdir -p "$PROJECT_ROOT"/{sites,pairs,private/pairs,lib,scripts/commands,servers/live/demo}
    # The orchestrator files the predicate greps. Empty = no leg wired.
    : > "$PROJECT_ROOT/lib/demo.sh"
    : > "$PROJECT_ROOT/scripts/commands/demo.sh"
    source "$BATS_TEST_DIRNAME/../../lib/demo-clip-survival.sh"
}

# A site that declares itself part of the demo tier.
mk_demo_site() {
    local name="$1"
    mkdir -p "$PROJECT_ROOT/sites/$name/dev"
    printf 'name: %s\nclass: demo\n' "$name" > "$PROJECT_ROOT/sites/$name/.nwp.yml"
}

mk_plain_site() {
    local name="$1"
    mkdir -p "$PROJECT_ROOT/sites/$name/dev"
    printf 'name: %s\n' "$name" > "$PROJECT_ROOT/sites/$name/.nwp.yml"
}

# Give a site clip-review authoring data.
add_clip_review() {
    mkdir -p "$PROJECT_ROOT/sites/$1/dev/html/profiles/custom/nwc/modules/nwc_features/nwc_clip_review"
}

# Wire a leg: BOTH the box wrapper and the orchestrator must invoke the export.
wire_leg() {
    local name="$1"
    printf '#!/bin/bash\nnwc-clip-choice:export-history\n' \
        > "$PROJECT_ROOT/servers/live/demo/${name}-demo-reset-restricted"
    printf 'nwc-clip-choice:export-history\n' >> "$PROJECT_ROOT/lib/demo.sh"
}

# ── The exposure this issue is about ────────────────────────────────────────

@test "a demo-tier site holding clip-review data with no leg is AT RISK" {
    mk_demo_site demosite
    add_clip_review demosite
    run demo_clip_survival_report demosite
    [ "$status" -eq 1 ]
    [[ "$output" == *"AT RISK"* ]]
    [[ "$output" == *"no pre-wipe leg"* ]]
}

@test "wiring the leg turns the same site GREEN" {
    mk_demo_site demosite
    add_clip_review demosite
    wire_leg demosite
    run demo_clip_survival_report demosite
    [ "$status" -eq 0 ]
    [[ "$output" == *"pre-wipe leg is wired"* ]]
}

# THE HALF-WIRED CASE. A leg present in only one of the two places is a leg
# that never runs — the wrapper is what executes on the box, the orchestrator
# is what the scheduled nightly calls. Either alone must NOT read as safe.
@test "a leg wired ONLY in the box wrapper is still AT RISK" {
    mk_demo_site demosite
    add_clip_review demosite
    printf '#!/bin/bash\nnwc-clip-choice:export-history\n' \
        > "$PROJECT_ROOT/servers/live/demo/demosite-demo-reset-restricted"
    run demo_clip_survival_report demosite
    [ "$status" -eq 1 ]
    [[ "$output" == *"AT RISK"* ]]
}

@test "a leg wired ONLY in the orchestrator is still AT RISK" {
    mk_demo_site demosite
    add_clip_review demosite
    printf 'nwc-clip-choice:export-history\n' >> "$PROJECT_ROOT/lib/demo.sh"
    run demo_clip_survival_report demosite
    [ "$status" -eq 1 ]
}

# ── The answer the estate actually relies on, PROVEN not asserted ───────────

@test "a site that is not on the reset path is safe by construction" {
    mk_plain_site authoring
    add_clip_review authoring
    run demo_clip_survival_report authoring
    [ "$status" -eq 0 ]
    [[ "$output" == *"not on the nightly reset path"* ]]
}

# THE GUARD THAT ARMS ITSELF. If anybody ever puts the authoring site on the
# demo tier, this must go red on its own — nobody has to remember.
@test "adding class: demo to the authoring site ARMS the guard" {
    mk_plain_site authoring
    add_clip_review authoring
    run demo_clip_survival_report authoring
    [ "$status" -eq 0 ]

    printf 'name: authoring\nclass: demo\n' > "$PROJECT_ROOT/sites/authoring/.nwp.yml"
    run demo_clip_survival_report authoring
    [ "$status" -eq 1 ]
    [[ "$output" == *"AT RISK"* ]]
}

# A pair contract that opts into the demo tier drags BOTH halves onto the
# reset path — the contract resets them as one cut.
@test "a demo-enabled pair contract puts both halves on the reset path" {
    mk_plain_site prov
    mk_plain_site cons
    add_clip_review prov
    cat > "$PROJECT_ROOT/pairs/x.pair-contract.yml" <<YAML
provider: prov
consumer: cons
demo:
  enabled: true
  paired_reset: true
YAML
    run demo_clip_survival_report prov
    [ "$status" -eq 1 ]
    [[ "$output" == *"AT RISK"* ]]
}

# …and a contract WITHOUT a demo block must not. This is exactly what keeps
# the real authoring pair out of the nightly wipe, so it needs a test.
@test "a pair contract with no demo block leaves both halves off the path" {
    mk_plain_site prov
    mk_plain_site cons
    add_clip_review prov
    cat > "$PROJECT_ROOT/pairs/x.pair-contract.yml" <<YAML
provider: prov
consumer: cons
coupled_tiers: [live, prod]
YAML
    run demo_clip_survival_report prov
    [ "$status" -eq 0 ]
    [[ "$output" == *"not on the nightly reset path"* ]]
}

@test "a demo block explicitly disabled does not arm the guard" {
    mk_plain_site prov
    mk_plain_site cons
    add_clip_review prov
    cat > "$PROJECT_ROOT/pairs/x.pair-contract.yml" <<YAML
provider: prov
consumer: cons
demo:
  enabled: false
YAML
    run demo_clip_survival_report prov
    [ "$status" -eq 0 ]
}

# ── Fail closed ─────────────────────────────────────────────────────────────

@test "a demo site with NO clip-review data is not reported at risk" {
    mk_demo_site demosite
    run demo_clip_survival_report demosite
    [ "$status" -eq 0 ]
    [[ "$output" == *"holds no clip-review data"* ]]
}

@test "an empty corpus is CANNOT VERIFY (exit 2), never a pass" {
    run demo_clip_survival_report
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "an unreadable site name is CANNOT VERIFY, never a pass" {
    run demo_clip_survival_report no-such-site
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

# ── Discovery is self-contained ────────────────────────────────────────────
#
# The scan must not depend on discover_sites: a check whose verdict differs
# between a full checkout and a worktree is not a check. Proven by running
# with NO such helper defined (setup() never sources project-resolver).

@test "with no site named, every site under sites/ is examined" {
    mk_plain_site alpha
    mk_demo_site beta
    add_clip_review beta
    mk_plain_site gamma
    run demo_clip_survival_report
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
    [[ "$output" == *"gamma"* ]]
    [[ "$output" == *"examined 3 site(s); 1 at risk."* ]]
}

@test "moodledata siblings are not counted as sites" {
    mk_plain_site alpha
    mkdir -p "$PROJECT_ROOT/sites/alpha_moodledata"
    run demo_clip_survival_report
    [ "$status" -eq 0 ]
    [[ "$output" == *"examined 1 site(s)"* ]]
}

# ── The worktree false-green ────────────────────────────────────────────────
#
# RECORDED FAILURE ("worktree pl guards read BLANK state"): sites/ is
# gitignored, so a linked worktree has a blank sites/ tree. A scan there
# reports all-clear FOR THE REASON THAT IT COULD NOT LOOK. Observed for real
# while building this check: run from a worktree it printed
#   "SUCCESS: No site is about to lose an author's clip choices."
# having examined 1 site out of 22.

@test "a linked git worktree is CANNOT VERIFY, not a clean bill of health" {
    mk_demo_site demosite
    add_clip_review demosite
    # A linked worktree is identified by .git being a FILE, not a directory.
    printf 'gitdir: /somewhere/.git/worktrees/x\n' > "$PROJECT_ROOT/.git"
    run demo_clip_survival_report
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    [[ "$output" == *"worktree"* ]]
    # No VERDICT token may appear: the run took no measurement at all. (The
    # prose legitimately contains the words "nothing at risk" while explaining
    # why it refuses, so the assertion is on the uppercase verdict token.)
    [[ "$output" != *"AT RISK"* ]]
    [[ "$output" != *"examined"* ]]
}

@test "a main checkout (.git is a directory) scans normally" {
    mk_demo_site demosite
    add_clip_review demosite
    mkdir -p "$PROJECT_ROOT/.git"
    run demo_clip_survival_report
    [ "$status" -eq 1 ]
    [[ "$output" == *"AT RISK"* ]]
}

@test "naming a site explicitly still works inside a worktree" {
    mk_demo_site demosite
    add_clip_review demosite
    printf 'gitdir: /somewhere/.git/worktrees/x\n' > "$PROJECT_ROOT/.git"
    run demo_clip_survival_report demosite
    [ "$status" -eq 1 ]
    [[ "$output" == *"AT RISK"* ]]
}

# ── The two shapes the awk parser this file used to carry got WRONG ──────────
#
# lint:yq-first flagged that parser on !436 (pipeline 2252, job 19405) as an
# ADR-0015 violation. These two cases are why it was also a defect, not only a
# style breach — both were RED against the awk version and are the reason the
# rewrite is a fix rather than a reformat.

# awk's block reset was `/^[a-z_]+:/`, which never fires on an INDENTED key, so
# once `demo:` had been seen every later `enabled: true` at any depth counted.
# A pair that explicitly opted OUT was therefore dragged onto the reset path by
# an unrelated nested block.
@test "a nested enabled:true under a DISABLED demo block does not arm the guard" {
    mk_plain_site prov
    mk_plain_site cons
    add_clip_review prov
    cat > "$PROJECT_ROOT/pairs/x.pair-contract.yml" <<YAML
provider: prov
consumer: cons
demo:
  enabled: false
  smoke:
    enabled: true
YAML
    run demo_clip_survival_report prov
    [ "$status" -eq 0 ]
    [[ "$output" == *"not on the nightly reset path"* ]]
}

# A trailing comment is legal YAML and common in this estate's contracts
# (pairs/ssd.pair-contract.yml is full of them). `awk '{print $2}'` took the
# value only because it happened to be field 2.
@test "provider: is read as a YAML value, not as awk field 2" {
    mk_plain_site prov
    mk_plain_site cons
    add_clip_review prov
    cat > "$PROJECT_ROOT/pairs/x.pair-contract.yml" <<YAML
provider: "prov"   # the identity origin (ADR-0031 D5)
consumer: cons
demo:
  enabled: true
YAML
    run demo_clip_survival_report prov
    [ "$status" -eq 1 ]
    [[ "$output" == *"AT RISK"* ]]
}

# Host-blind branch, closed. Without the yq check the predicate answers "not on
# the reset path" on a host with no yq — the reassuring sentence over a reading
# that was never taken.
@test "contracts present but yq absent is CANNOT VERIFY, never a clean bill" {
    mk_plain_site prov
    mk_plain_site cons
    add_clip_review prov
    cat > "$PROJECT_ROOT/pairs/x.pair-contract.yml" <<YAML
provider: prov
consumer: cons
demo:
  enabled: true
YAML
    NWP_DEMO_CLIP_NO_YQ=1 run demo_clip_survival_report prov
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    # …and specifically NOT the reassuring sentence.
    [[ "$output" != *"not on the nightly reset path"* ]]
}
