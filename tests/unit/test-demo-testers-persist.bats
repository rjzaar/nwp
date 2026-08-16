#!/usr/bin/env bats
#
# test-demo-testers-persist.bats — ops#369: a tester's login must survive the
# nightly demo reset, and a run that FAILS to preserve it must never look like
# a run that succeeded.
#
# THE DEFECT THIS PINS, and it has two halves, both measured on live 2026-08-15.
#
#   HALF ONE — the loss the operator asked about. A tester in the golden kept
#   their username but their CHOSEN password reverted to the golden's hash
#   (Benedict-0000: $2y$12$IrJ4… before a real reset, $2y$10$Wq9z… after), and
#   a tester who joined after the seal was erased outright (tester_daytwo, uid
#   41 — no row at all). So a tester had to ask for a new invite every day.
#
#   HALF TWO — and this is the one these tests actually exist for. The FIRST
#   deployment of the preservation leg had a defect: the export used
#   CONCAT_WS('\t', …), the '\t' reached MySQL as a literal backslash-t, the
#   field split never happened, and every tester was discarded. The box printed
#
#       2026-08-15T21:12:54Z|testers-exported|listed=9 captured=0 absent=9
#       OK  tester identities captured: 0/9
#       OK  nwd demo reset complete
#
#   and EXITED 0. Nine named testers were wiped while the transcript reported
#   success. That is the estate's "swallowed verdict" class (CLAUDE.md), caught
#   in the very feature meant to stop silent tester loss — so the guards below
#   are written against an OBSERVED silent success, not a synthetic fixture.
#
# THE PROPERTIES THAT MATTER
#   1. `preserved` is true for EXACTLY ONE verdict (`restored`). Every other
#      value — including ones that sound harmless, like `exported` — means
#      somebody has to be given a login again.
#   2. A wrapper too old to report at all is NOT REPORTED, never "preserved".
#   3. The UID-lock verdict belongs to the CONSUMER half and must survive the
#      pair's by-design absence folding, which hides the provider-owned blocks.
#   4. install-box.sh refuses to stage a roster the wrapper would refuse —
#      asserted by ERROR TEXT, never by "it exited non-zero".

setup() {
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  LIB="$ROOT/lib/demo-box-status.sh"
  INSTALLER="$ROOT/servers/live/demo/install-box.sh"
  WRAPPER="$ROOT/servers/live/demo/nwd-demo-reset-restricted"
  SSD_WRAPPER="$ROOT/servers/live/demo/ssd-demo-reset-restricted"
  TEST_TMP=$(mktemp -d)

  # Real shape of the provider wrapper's `status` word after ops#369.
  RAW_OK='site:        nwd (nwd.example)
golden:      captured 2026-08-15T12:20:15Z
last reset:  2026-08-16 1786806065
testers_registry: 9 tester(s) generated=2026-08-16T06:40:00Z staged_age=3083s
last_testers_preserved: 2026-08-15T21:39:53Z|restored|restored=8 created=1 collided=0 failed=0
--- last 15 log lines ---'

  # The same box on the night the leg failed.
  RAW_FAIL='site:        nwd (nwd.example)
testers_registry: 8 tester(s) generated=2026-08-16T06:40:00Z staged_age=152s
last_testers_preserved: 2026-08-15T22:04:51Z|unlisted-accounts|listed=8 captured=8 absent=0 unlisted=1
--- last 15 log lines ---'

  # A wrapper that predates the feature: neither line is present.
  RAW_OLD='site:        nwd (nwd.example)
last reset:  2026-08-16 1786806065
--- last 15 log lines ---'
}

teardown() { rm -rf "$TEST_TMP"; }

_lib() { bash -c "source '$LIB'; $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. The verdict → `preserved` mapping
# ─────────────────────────────────────────────────────────────────────────────

@test "a restored run reports preserved:true with its counts" {
  run _lib "demo_box_extras_json '$RAW_OK' | jq -r '.testers.preserved, .testers.verdict'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "true" ]]
  [[ "${lines[1]}" == "restored" ]]
}

@test "a run that exported but never restored is NOT preserved" {
  # THE HEADLINE RED. `exported` is what the box recorded on the night it
  # exited 0 having preserved nothing. It must never map to preserved:true.
  local raw='testers_registry: 9 tester(s)
last_testers_preserved: 2026-08-15T21:12:54Z|exported|listed=9 captured=0 absent=9'
  run _lib "demo_box_extras_json '$raw' | jq -r '.testers.preserved'"
  [ "$status" -eq 0 ]
  [[ "$output" == "false" ]]
}

@test "an unrecognised verdict fails CLOSED — it is not preserved" {
  local raw='testers_registry: 9 tester(s)
last_testers_preserved: 2026-08-15T22:04:51Z|something-nobody-has-seen|x=1'
  run _lib "demo_box_extras_json '$raw' | jq -r '.testers.preserved'"
  [ "$status" -eq 0 ]
  [[ "$output" == "false" ]]
}

@test "the anomaly verdict is carried through with its detail" {
  run _lib "demo_box_extras_json '$RAW_FAIL' | jq -r '.testers.verdict, .testers.preserved'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "unlisted-accounts" ]]
  [[ "${lines[1]}" == "false" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Absence must never render as success
# ─────────────────────────────────────────────────────────────────────────────

@test "a wrapper too old to report tester persistence is NOT REPORTED, not preserved" {
  run _lib "demo_box_extras_json '$RAW_OLD' | jq -r '.testers.reported'"
  [ "$status" -eq 0 ]
  [[ "$output" == "false" ]]
  run _lib "demo_box_extras_json '$RAW_OLD' | jq -r '.testers.reason'"
  [[ "$output" == *"redeploy"* ]]
}

@test "a box we did not read is UNKNOWN, never 'no testers' and never a redeploy nag" {
  # "I did not look" and "I looked and the wrapper is too old" are different
  # facts with different remedies. Only the second may carry a redeploy hint;
  # an instruction that cannot come true is the ops#329 D6 defect.
  run _lib "demo_box_extras_json '' | jq -r '.testers.reported, .testers.state, .testers.reason'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "false" ]]
  [[ "${lines[1]}" == "not-read" ]]
  [[ "${lines[2]}" == *"UNKNOWN"* ]]
  [[ "${lines[2]}" != *"install-box.sh"* ]]
}

@test "a wrapper we DID read and found too old is old-wrapper, and earns the hint" {
  run _lib "demo_box_extras_json '$RAW_OLD' | jq -r '.testers.state, .testers.reason'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "old-wrapper" ]]
  [[ "${lines[1]}" == *"install-box.sh"* ]]
}

@test "a NOT STAGED registry is carried verbatim so the renderer can warn" {
  local raw='testers_registry: NOT STAGED — no login survives a reset
last_testers_preserved: none'
  run _lib "demo_box_extras_json '$raw' | jq -r '.testers.registry, .testers.verdict'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "NOT STAGED"* ]]
  [[ "${lines[1]}" == "none" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. The consumer half owns the UID lock (ops#369)
# ─────────────────────────────────────────────────────────────────────────────

@test "the pair's by-design folding hides the provider's blocks but NOT the UID lock" {
  # The return leg and the backup census really are the provider's to report.
  # The UID lock is a fact about the CONSUMER's own user table and it must
  # survive the fold, or the one tester-facing check Moodle owns disappears.
  local raw='site:        ssd (ssd.example)
testers_uidlock: ok (checked=9 bound=4 unbound=5 forked=0)'
  run _lib "demo_box_extras_by_design_json nwd '$raw' | jq -r '.feedback_status.by_design, .testers.uid_lock'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "true" ]]
  [[ "${lines[1]}" == "ok (checked=9 bound=4 unbound=5 forked=0)" ]]
}

@test "a forked Moodle identity is reported as such" {
  local raw='testers_uidlock: forked (checked=9 bound=3 unbound=5 forked=1 names=Benedict-0000(2) )'
  run _lib "demo_box_extras_by_design_json nwd '$raw' | jq -r '.testers.uid_lock'"
  [ "$status" -eq 0 ]
  [[ "$output" == "forked"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. install-box.sh refuses a roster the wrapper would refuse
#    Asserted by ERROR TEXT — "exited non-zero" would pass for any reason at
#    all, which is the blind-negation shape CLAUDE.md names.
# ─────────────────────────────────────────────────────────────────────────────

_stage_refusal() {   # $1 = roster JSON → the installer's stderr
  local site_dir="${TEST_TMP}/sites/nwd"
  mkdir -p "$site_dir"
  printf '%s' "$1" > "${site_dir}/demo-testers.json"
  NWP_ROOT="$TEST_TMP" BOX_HOST=192.0.2.1 bash "$INSTALLER" nwd --stage-testers --no-key 2>&1
}

@test "staging refuses a roster whose version is not 1" {
  run _stage_refusal '{"version":2,"testers":[]}'
  [[ "$output" == *"not a version-1 tester roster"* ]]
}

@test "staging refuses a roster containing a PENDING entry" {
  run _stage_refusal '{"version":1,"testers":[{"account":"a"},{"account":"b","status":"pending"}]}'
  [[ "$output" == *"PENDING"* ]]
  [[ "$output" == *"by definition the APPROVED list"* ]]
}

@test "staging refuses an account name the wrapper would refuse" {
  run _stage_refusal '{"version":1,"testers":[{"account":"../../etc/passwd"}]}'
  [[ "$output" == *"account name the wrapper will refuse"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Wrapper-side invariants, read off the deployed source
# ─────────────────────────────────────────────────────────────────────────────

@test "both wrappers still pass bash -n" {
  run bash -n "$WRAPPER";     [ "$status" -eq 0 ]
  run bash -n "$SSD_WRAPPER"; [ "$status" -eq 0 ]
}

@test "the export never prints or logs a password hash" {
  # The capture holds hashes; nothing that reaches stdout or the log may. The
  # box serves four other live sites, so this is not merely tidiness.
  run grep -nE '(echo|printf|log)[^|]*\$\{?(rpass|pass)\b' "$WRAPPER"
  [ "$status" -ne 0 ]
}

@test "the export selects plain columns, never CONCAT_WS with a backslash-t" {
  # The exact defect that produced the observed silent success. Comment lines
  # are excluded on purpose — the fix's receipt is written there in prose, and
  # a test that forbade naming the bug would forbid explaining it.
  run bash -c "grep -vE '^[[:space:]]*#' '$WRAPPER' | grep -n 'CONCAT_WS'"
  [ "$status" -ne 0 ]
}

@test "listed>0 with captured=0 is CANNOT VERIFY, not 'nobody is here'" {
  run grep -n 'export-blind' "$WRAPPER"
  [ "$status" -eq 0 ]
  run grep -c 'listed" -gt 0 && "\$captured" -eq 0' "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "a failure verdict is STICKY — a clean restore cannot overwrite it" {
  # Found by the guard proof itself: the restore assigned TESTERS_VERDICT
  # unconditionally, so a run that had detected an unapproved login reported
  # itself fully preserved.
  run grep -n 'TESTERS_VERDICT" == "exported"' "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "the administrator role is never carried across a restore" {
  run grep -n 'administrator.*continue.*never carry admin\|never carry admin' "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "seeded persona and matrix fixtures are excluded from the unlisted anomaly" {
  # Counting furniture would make the check permanently red, and a permanently
  # red check is one an operator learns to ignore.
  run grep -c "nwcdemo\\\\_%" "$WRAPPER"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. GUILD MEMBERSHIP across the reset (ops#376)
#
# The extension the operator ordered: "yes extend to guild membership" — and
# explicitly NOT Article 9 consent, which is a legal record with its own
# lifecycle (nwc_art9_consent) and must move through that machinery.
#
# PROVEN RED ON LIVE FIRST, 2026-08-16. Andrew-6960 was put in the Theology
# guild as guild-mentor, a real `pl demo nightly nwd --tier=live --via-key
# --force` was run, and afterwards the account read back as
# `sojourners[guild-member]` — the membership was gone while the identity half
# reported restored=8 created=0 collided=0 failed=0 and both password hashes
# were byte-identical. So the loss is real, it is membership-only, and it is
# invisible to every check that existed before these.
#
# THE PROPERTY THAT MATTERS MOST HERE IS PARTIAL DEGRADATION: a membership that
# could not be carried must never be reported as a lost login, and a login that
# survived must never make a lost membership look fine.
# ─────────────────────────────────────────────────────────────────────────────

_raw_guilds() {   # $1 = the last_testers_guilds: value
  printf 'testers_registry: 8 tester(s) generated=2026-08-16T06:40:00Z staged_age=120s\nlast_testers_preserved: 2026-08-16T00:58:29Z|restored|restored=8 created=0 collided=0 failed=0\nlast_testers_guilds: %s\n' "$1"
}

@test "a restored membership leg reports carried:true with its counts" {
  local raw; raw="$(_raw_guilds '2026-08-16T00:58:40Z|restored|memberships_captured=21 memberships_present=20 memberships_restored=1 memberships_failed=0 dropped_roles=0')"
  run _lib "demo_box_extras_json '$raw' | jq -r '.testers.guilds.carried, .testers.guilds.memberships_restored, .testers.guilds.memberships_captured'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "true" ]]
  [[ "${lines[1]}" == "1" ]]
  [[ "${lines[2]}" == "21" ]]
}

@test "PARTIAL DEGRADATION: a failed membership leg does NOT drag the login verdict down" {
  # The headline property. The identity half says restored; the guild half says
  # degraded. Both must be readable, and neither may be inferred from the other.
  local raw; raw="$(_raw_guilds '2026-08-16T00:58:40Z|restore-degraded|memberships_captured=21 memberships_present=18 memberships_restored=1 memberships_failed=2 dropped_roles=4')"
  run _lib "demo_box_extras_json '$raw' | jq -r '.testers.preserved, .testers.guilds.carried, .testers.guilds.memberships_failed, .testers.guilds.dropped_roles'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "true"  ]]   # the LOGINS survived
  [[ "${lines[1]}" == "false" ]]   # the MEMBERSHIPS did not
  [[ "${lines[2]}" == "2" ]]
  [[ "${lines[3]}" == "4" ]]
}

@test "PARTIAL DEGRADATION, the other way: lost logins do not silently mark memberships carried" {
  local raw
  raw="$(printf 'last_testers_preserved: 2026-08-16T00:58:29Z|export-blind|listed=8 captured=0\nlast_testers_guilds: 2026-08-16T00:58:40Z|restored|memberships_captured=0 memberships_present=0 memberships_restored=0 memberships_failed=0 dropped_roles=0\n')"
  run _lib "demo_box_extras_json '$raw' | jq -r '.testers.preserved, .testers.guilds.carried'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "false" ]]
  [[ "${lines[1]}" == "true"  ]]
}

@test "a captured-but-never-restored membership leg is NOT carried" {
  # The `exported` shape, one leg over: the restore never reached its verdict,
  # so it did not run. It must not read as success — this is the exact class
  # that shipped green on live once already.
  local raw; raw="$(_raw_guilds '2026-08-16T00:58:40Z|captured|memberships_captured=21 dropped_roles=4 groups_unsupported=7')"
  run _lib "demo_box_extras_json '$raw' | jq -r '.testers.guilds.carried, .testers.guilds.verdict'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "false" ]]
  [[ "${lines[1]}" == "captured" ]]
}

@test "an unrecognised membership verdict fails CLOSED" {
  local raw; raw="$(_raw_guilds '2026-08-16T00:58:40Z|something-nobody-has-seen|x=1')"
  run _lib "demo_box_extras_json '$raw' | jq -r '.testers.guilds.carried'"
  [ "$status" -eq 0 ]
  [[ "$output" == "false" ]]
}

@test "no tester in any guild is carried:true — a real zero, not a blind one" {
  local raw; raw="$(_raw_guilds '2026-08-16T00:58:40Z|no-testers|the roster names nobody, so there is no membership to carry')"
  run _lib "demo_box_extras_json '$raw' | jq -r '.testers.guilds.carried'"
  [ "$status" -eq 0 ]
  [[ "$output" == "true" ]]
}

@test "a wrapper too old to report memberships is NOT REPORTED, never carried" {
  # RAW_OK predates ops#376: it carries the login line and no guild line.
  run _lib "demo_box_extras_json '$RAW_OK' | jq -r '.testers.guilds.reported, .testers.guilds.carried'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "false" ]]
  [[ "${lines[1]}" == "null"  ]]
  run _lib "demo_box_extras_json '$RAW_OK' | jq -r '.testers.guilds.reason'"
  [[ "$output" == *"redeploy"* ]]
}

@test "the Moodle half declares guilds BY DESIGN absent — and earns no redeploy nag" {
  # ssd has no Group entities and never will, so "redeploy the wrapper to fix
  # it" is an instruction that can never come true (the ops#329 D6 defect).
  local raw='site:        ssd (ssd.example)
testers_uidlock: ok (checked=8 bound=4 unbound=4 forked=0)'
  run _lib "demo_box_extras_by_design_json nwd '$raw' | jq -r '.testers.guilds.by_design, .testers.guilds.reason, .testers.uid_lock'"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "true" ]]
  [[ "${lines[1]}" != *"install-box.sh"* ]]
  [[ "${lines[1]}" == *"provider"* ]]
  [[ "${lines[2]}" == "ok"* ]]   # the UID lock still survives the fold
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Wrapper-side membership invariants, read off the deployed source
# ─────────────────────────────────────────────────────────────────────────────

@test "the membership leg restores through the site's OWN API, never raw SQL on group tables" {
  # nwc:tester-set-guild resolves by field_group_seed_key and REFUSES an unknown
  # key, so it can only ever join an EXISTING guild. That is what makes the
  # golden authoritative by construction. An INSERT into group_relationship
  # would throw the guarantee away.
  run grep -n 'TESTERS_SETGUILD_CMD="nwc:tester-set-guild"' "$WRAPPER"
  [ "$status" -eq 0 ]
  run bash -c "grep -vE '^[[:space:]]*#' '$WRAPPER' | grep -iE 'INSERT INTO (group_relationship|group_content)'"
  [ "$status" -ne 0 ]
}

@test "the membership leg is fail-OPEN for the identity leg — it can never abandon it" {
  # Both pre-wipe legs are `|| true`, and the guild one runs AFTER the identity
  # one. A membership failure costing a tester their password would be strictly
  # worse than the bug this whole feature fixes.
  run grep -n 'testers_guilds_export "\$TESTERS_ROSTER" || true' "$WRAPPER"
  [ "$status" -eq 0 ]
  run grep -n 'testers_guilds_restore || true' "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "the membership verdict is graded and persisted SEPARATELY from the login verdict" {
  run grep -c 'last-guilds' "$WRAPPER"
  [ "$status" -eq 0 ]
  run grep -n 'case "\$GUILDS_VERDICT" in' "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "a failed membership capture is STICKY — a clean restore cannot overwrite it" {
  run grep -n 'GUILDS_VERDICT" == "captured"' "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "the role precedence is declared ONCE and dropped roles are counted, never silent" {
  run grep -n 'TESTERS_ROLE_PRECEDENCE="guild-admin guild-mentor guild-verifier guild-editor guild-endorsed guild-junior"' "$WRAPPER"
  [ "$status" -eq 0 ]
  run grep -n 'dropped_roles=' "$WRAPPER"
  [ "$status" -eq 0 ]
  run grep -n 'testers-guilds-dropped-roles' "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "SOJOURNER LEVEL and ARTICLE 9 CONSENT are documented as deliberately NOT carried" {
  # The operator ruled membership in and consent out. A later session that
  # "helpfully" adds consent would be manufacturing a legal fact from a reading
  # taken a minute earlier; level would mean asserting course completions the
  # reset has just destroyed. Both refusals are load-bearing, so both are
  # pinned here rather than left to prose nobody re-reads.
  run grep -n 'NOT Article 9 consent' "$WRAPPER"
  [ "$status" -eq 0 ]
  run grep -n 'SOJOURNER LEVEL IS ALSO NOT CARRIED' "$WRAPPER"
  [ "$status" -eq 0 ]
  run bash -c "grep -vE '^[[:space:]]*#' '$WRAPPER' | grep -E 'nwc:tester-set-level|art9|nwc_art9_consent'"
  [ "$status" -ne 0 ]
}

@test "interest-group memberships are counted and named, never silently dropped" {
  # Measured live: nwc:tester-set-guild's refusal names nine guild seed keys and
  # the seven *-ig flexible_groups are not among them. A limit nobody reports
  # is a limit that reads as a feature.
  run grep -n 'groups_unsupported=' "$WRAPPER"
  [ "$status" -eq 0 ]
  run grep -n 'testers-guilds-unsupported' "$WRAPPER"
  [ "$status" -eq 0 ]
}
