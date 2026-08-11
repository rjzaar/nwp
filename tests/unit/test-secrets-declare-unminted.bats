#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-secrets-declare-unminted.bats
# a credential that OUGHT to exist and does not is still a registry fact
# =============================================================================
# ops#336 found the shape. `/api/clip-review/slots/sync` and
# `/api/clip-review/signal` 401 on nwd live and nwc live, because
# `nwc_feedback.cross_site:bearer_token` is `''` — the shared bearer was NEVER
# MINTED. `learner_signal` is 0 and can only be 0.
#
# The registry could not record that. `pl secrets adopt` refuses:
#
#     <key> is empty or missing in .secrets.yml — nothing to adopt
#
# and there is no other verb that creates an entry, so a credential the estate
# is BLOCKED ON was invisible to `pl secrets status`, to `pl secrets debt`, and
# to `pl rag`. The one thing everybody needed to see — "this is owed" — was the
# one thing the source of record had no way to say.
#
# `status: not-provisioned` already exists and is already understood in eleven
# places (see test-secrets-not-provisioned.bats); what was missing was any way
# to CREATE an entry in that state. `--not-provisioned` is that way.
#
# Fully offline.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export NWP_ROOT="$BATS_TEST_TMPDIR/estate"
  mkdir -p "$NWP_ROOT/private"
  export NWP_SECRETS_REGISTRY="$NWP_ROOT/private/secrets-registry.yml"
  export NWP_SECRETS_FILE="$NWP_ROOT/.secrets.yml"
  cat > "$NWP_SECRETS_REGISTRY" <<'YML'
approvers:
  - operator
secrets:
  - id: an_existing_thing
    provider: gitlab
    type: something
    scopes: []
    stored_in: ['.secrets.yml:gitlab.api_token']
    rotate_via: manual
    rotate_url: ""
    cadence_days: 365
    expires: unknown
    last_rotated: ""
    owner: operator
    status: active
YML
  cat > "$NWP_SECRETS_FILE" <<'YML'
gitlab:
  api_token: "not-a-real-value-just-non-empty"
link:
  nwd_ssd:
    cross_site_bearer: ""
YML
}

adopt() { bash "$REPO_ROOT/scripts/commands/secrets.sh" adopt "$@"; }

# --------------------------------------------------------------------------
# THE RED
# --------------------------------------------------------------------------

@test "adopting an EMPTY key without saying so is still refused" {
  run adopt link.nwd_ssd.cross_site_bearer --as nwc_cross_site_bearer
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty or missing"* ]]
  # …and it must not have half-written an entry.
  run grep -c "nwc_cross_site_bearer" "$NWP_SECRETS_REGISTRY"
  [ "$output" = "0" ]
}

@test "--not-provisioned DECLARES the unminted credential" {
  run adopt link.nwd_ssd.cross_site_bearer --as nwc_cross_site_bearer --not-provisioned
  [ "$status" -eq 0 ]
  [[ "$output" == *"nwc_cross_site_bearer"* ]]
  run yq e '.secrets[] | select(.id=="nwc_cross_site_bearer") | .status' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "not-provisioned" ]
}

@test "the declared entry names the .secrets.yml key it is waiting for" {
  adopt link.nwd_ssd.cross_site_bearer --as nwc_cross_site_bearer --not-provisioned
  run yq e '.secrets[] | select(.id=="nwc_cross_site_bearer") | .stored_in[0]' "$NWP_SECRETS_REGISTRY"
  [ "$output" = ".secrets.yml:link.nwd_ssd.cross_site_bearer" ]
}

@test "declaring one that is ALREADY declared is refused, not duplicated" {
  adopt link.nwd_ssd.cross_site_bearer --as nwc_cross_site_bearer --not-provisioned
  run adopt link.nwd_ssd.cross_site_bearer --as nwc_cross_site_bearer --not-provisioned
  [ "$status" -ne 0 ]
  run yq e '[.secrets[] | select(.id=="nwc_cross_site_bearer")] | length' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "1" ]
}

@test "--not-provisioned on a key that ALREADY HAS a value is refused" {
  # Otherwise the flag becomes a way to mark a live credential as non-existent,
  # and eleven code paths would then skip auditing a credential that is real.
  run adopt gitlab.api_token --as a_second_name --not-provisioned
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has a value"* ]]
}

@test "it needs an explicit id — an unminted credential has no natural name yet" {
  run adopt link.nwd_ssd.cross_site_bearer --not-provisioned
  [ "$status" -ne 0 ]
  [[ "$output" == *"--as"* ]]
}
