#!/usr/bin/env bats
# nwp/ops#83 — pair_guard_restore (both-or-forward restore invariant, NWP-ADR-0031 D9).
#
# Self-contained fixtures (fake nwp.yml + coupled/uncoupled pair contracts +
# scratch state/ledger dirs). Touches no network, no real site, no secrets.
#
#   prov ↔ cons        coupled (uid_lock, coupled_tiers [live,prod]) + restore block
#   demoprov ↔ democons UNcoupled (uid_lock:false)
#   solo               unpaired

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"
  export NWP_PAIR_STATE_DIR="${PROJECT_ROOT}/private/pairs"
  export NWP_PAIR_LEDGER_DIR="${PROJECT_ROOT}/private/pairs/ledger"
  mkdir -p "${NWP_PAIR_CONTRACT_DIR}" "${NWP_PAIR_STATE_DIR}" "${NWP_PAIR_LEDGER_DIR}"

  cat > "${NWP_YML}" <<'EOF'
sites:
  prov:
    recipe: d
  cons:
    recipe: d
    paired_with: prov
  demoprov:
    recipe: d
  democons:
    recipe: d
    paired_with: demoprov
  solo:
    recipe: d
EOF

  cat > "${NWP_PAIR_CONTRACT_DIR}/cons.pair-contract.yml" <<'EOF'
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
identity:
  uid_lock: true
  coupled_tiers: [live, prod]
  sub_stability: uuid
  restore:
    invariant: both-or-forward
    ledger: provider
    reconcile: from-ledger
    pre_check_required: true
EOF

  cat > "${NWP_PAIR_CONTRACT_DIR}/democons.pair-contract.yml" <<'EOF'
pair: democons-demoprov
contract_version: 1
provider: demoprov
consumer: democons
identity:
  uid_lock: false
  coupled_tiers: []
EOF

  source "${BATS_TEST_DIRNAME}/../../lib/ui.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/pair.sh"

  # Helper: stand up the two required pre-check inputs for the coupled pair.
  _prechecks_ok() {
    echo '{"t":"snap","snap":1,"sha256":"x"}' > "${NWP_PAIR_LEDGER_DIR}/cons.provider-identity.jsonl"
    echo 'row' > "${NWP_PAIR_STATE_DIR}/cons.live.join-snapshot.tsv"
  }
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset NWP_YML PROJECT_ROOT NWP_PAIR_CONTRACT_DIR NWP_PAIR_STATE_DIR NWP_PAIR_LEDGER_DIR
}

# --- off-unless-configured ---------------------------------------------------

@test "unpaired site restore is a no-op (0)" {
  run pair_guard_restore solo live restore 5 false
  [ "$status" -eq 0 ]
}

@test "uncoupled tier (dev) restore is a no-op (0)" {
  run pair_guard_restore cons dev restore 5 false
  [ "$status" -eq 0 ]
}

@test "uncoupled pair (uid_lock:false) restore is a no-op (0)" {
  run pair_guard_restore demoprov live restore 5 false
  [ "$status" -eq 0 ]
}

# --- fail-closed pre-checks --------------------------------------------------

@test "coupled tier with NO ledger/snapshot → REFUSE (fail closed)" {
  run pair_guard_restore prov live restore 5 false
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"MISSING"* ]]
}

# --- both-or-forward invariant ----------------------------------------------

@test "older restore (target_anchor < counterpart) → REFUSE" {
  _prechecks_ok
  pair_anchor_set cons consumer live 10
  run pair_guard_restore prov live restore 5 false
  [ "$status" -ne 0 ]
  [[ "$output" == *"OLDER than"* ]]
  [[ "$output" == *"strand"* ]]
}

@test "forward restore (target_anchor >= counterpart) → PASS" {
  _prechecks_ok
  pair_anchor_set cons consumer live 10
  run pair_guard_restore prov live restore 12 false
  [ "$status" -eq 0 ]
}

@test "same-cut restore (target_anchor == counterpart) → PASS" {
  _prechecks_ok
  pair_anchor_set cons consumer live 10
  run pair_guard_restore prov live restore 10 false
  [ "$status" -eq 0 ]
}

@test "unknown target anchor while counterpart has one → REFUSE (cannot prove forward)" {
  _prechecks_ok
  pair_anchor_set cons consumer live 10
  run pair_guard_restore prov live restore "" false
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNKNOWN"* ]]
}

# ⚠ THIS TEST USED TO ASSERT `status -eq 0`, and it was pinning the defect.
# "The counterpart has no recorded anchor" was read as "there is no lock to
# orphan". But no production code path has ever WRITTEN an anchor, so that was
# the state of every real pair — the both-or-forward comparison below it never
# ran outside this file's own fixtures. Absence of evidence is not evidence of
# an empty identity set; at a coupled tier it is CANNOT VERIFY, and CANNOT
# VERIFY refuses. See tests/unit/test-pair-restore-checkpoint.bats.
@test "no counterpart anchor → CANNOT VERIFY → REFUSE (was: PASS)" {
  _prechecks_ok
  run pair_guard_restore prov live restore 5 false
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

# --- override must be loud + typed + ledgered --------------------------------

@test "override without the typed confirmation → REFUSE (fail closed)" {
  _prechecks_ok
  pair_anchor_set cons consumer live 10
  run pair_guard_restore prov live restore 5 true ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"typed confirmation"* ]]
  grep -q "action=restore-override-DENIED" "${NWP_PAIR_STATE_DIR}/cons.log"
}

@test "override WITH the typed confirmation → PASS + audited" {
  _prechecks_ok
  pair_anchor_set cons consumer live 10
  run pair_guard_restore prov live restore 5 true RESTORE-OVERRIDE
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESTORE OVERRIDE"* ]]
  grep -q "action=restore-override cmd=restore site=prov" "${NWP_PAIR_STATE_DIR}/cons.log"
}

@test "override token can come from NWP_PAIR_OVERRIDE_CONFIRM env" {
  _prechecks_ok
  pair_anchor_set cons consumer live 10
  NWP_PAIR_OVERRIDE_CONFIRM=RESTORE-OVERRIDE run pair_guard_restore prov live restore 5 true
  [ "$status" -eq 0 ]
}

# --- monotonic anchor guard --------------------------------------------------

@test "pair_anchor_set refuses to move an anchor backward" {
  pair_anchor_set cons consumer live 10
  run pair_anchor_set cons consumer live 4
  [ "$status" -ne 0 ]
  [ "$(pair_anchor_get cons consumer live)" = "10" ]
}

# --- coupling-clause legibility (fail-closed, same class as membership) ------

@test "illegible coupling clause REFUSES the restore, it does not 'restore freely'" {
  # uid_lock:true with no coupled_tiers — declared coupling, unreadable extent.
  cat > "${NWP_PAIR_CONTRACT_DIR}/cons.pair-contract.yml" <<'YML'
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
identity:
  uid_lock: true
YML
  run pair_guard_restore cons live restore 5 false
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  grep -q "action=restore-coupling-blind-refuse" "${NWP_PAIR_STATE_DIR}/cons.log"
}

@test "illegible coupling clause on restore is escapable only by NWP_PAIR_GATE_SOFT (ledgered)" {
  cat > "${NWP_PAIR_CONTRACT_DIR}/cons.pair-contract.yml" <<'YML'
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
identity:
  uid_lock: true
YML
  # --override-pair must NOT buy a pass past a clause that cannot be read.
  run pair_guard_restore cons live restore 5 true RESTORE-OVERRIDE
  [ "$status" -ne 0 ]
  NWP_PAIR_GATE_SOFT=true run pair_guard_restore cons live restore 5 false
  [ "$status" -eq 0 ]
  grep -q "action=restore-coupling-blind-soft-skip" "${NWP_PAIR_STATE_DIR}/cons.log"
}
