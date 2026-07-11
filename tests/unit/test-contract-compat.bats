#!/usr/bin/env bats
# P74 Phase 3 — expand-and-contract (BACKWARD) schema-compat checker.
#
# Drives contracts/compat.py across the full delta matrix (the required
# guarantee: add-optional PASSES; field-removal / type-narrow / new-required /
# enum-drop FAIL) plus the scripts/commands/contracts.sh wrapper via its test
# hooks (NWP_CONTRACTS_FILES + NWP_CONTRACTS_BASE_DIR). No git, network, or
# secrets.

setup() {
  PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  COMPAT="${PROJECT_ROOT}/contracts/compat.py"
  WRAP="${PROJECT_ROOT}/scripts/commands/contracts.sh"
  TMP="$(mktemp -d)"
  OLD="${TMP}/old.json"
  NEW="${TMP}/new.json"
  cat > "$OLD" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["sub"],
  "properties": {
    "sub":    { "type": "string" },
    "email":  { "type": "string" },
    "status": { "type": "string", "enum": ["a", "b", "c"] },
    "guilds": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id"],
        "properties": { "id": { "type": "integer" } }
      }
    }
  }
}
EOF
}

teardown() { rm -rf "$TMP"; }

# --- the required matrix -----------------------------------------------------

@test "compat: identical schema is compatible" {
  run python3 "$COMPAT" "$OLD" "$OLD"
  [ "$status" -eq 0 ]
  [[ "$output" == *compatible* ]]
}

@test "compat: adding an OPTIONAL property PASSES (expand)" {
  sed 's/"email":  { "type": "string" },/"email": {"type":"string"}, "phone": {"type":"string"},/' "$OLD" > "$NEW"
  run python3 "$COMPAT" "$OLD" "$NEW"
  [ "$status" -eq 0 ]
}

@test "compat: adding an enum VALUE PASSES (widen)" {
  sed 's/\["a", "b", "c"\]/["a","b","c","d"]/' "$OLD" > "$NEW"
  run python3 "$COMPAT" "$OLD" "$NEW"
  [ "$status" -eq 0 ]
}

@test "compat: FIELD REMOVAL fails" {
  sed 's/"email":  { "type": "string" },//' "$OLD" > "$NEW"
  run python3 "$COMPAT" "$OLD" "$NEW"
  [ "$status" -eq 1 ]
  [[ "$output" == *"email: property removed"* ]]
}

@test "compat: TYPE NARROW fails" {
  sed 's/"sub":    { "type": "string" }/"sub": {"type":"integer"}/' "$OLD" > "$NEW"
  run python3 "$COMPAT" "$OLD" "$NEW"
  [ "$status" -eq 1 ]
  [[ "$output" == *"type narrowed"* ]]
}

@test "compat: NEW REQUIRED fails" {
  sed 's/"required": \["sub"\]/"required": ["sub","email"]/' "$OLD" > "$NEW"
  run python3 "$COMPAT" "$OLD" "$NEW"
  [ "$status" -eq 1 ]
  [[ "$output" == *"new required property 'email'"* ]]
}

@test "compat: ENUM VALUE DROPPED fails" {
  sed 's/\["a", "b", "c"\]/["a","b"]/' "$OLD" > "$NEW"
  run python3 "$COMPAT" "$OLD" "$NEW"
  [ "$status" -eq 1 ]
  [[ "$output" == *"enum value(s) dropped"* ]]
}

@test "compat: additionalProperties true->false fails" {
  sed 's/"additionalProperties": false/"additionalProperties": true/' "$OLD" > "$OLD.open"
  run python3 "$COMPAT" "$OLD.open" "$OLD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"additionalProperties tightened"* ]]
}

@test "compat: NESTED type-narrow inside array items fails" {
  sed 's/"id": { "type": "integer" }/"id": {"type":"string"}/' "$OLD" > "$NEW"
  run python3 "$COMPAT" "$OLD" "$NEW"
  [ "$status" -eq 1 ]
  [[ "$output" == *"guilds[].id"* ]]
}

@test "compat: --json emits a machine verdict" {
  run python3 "$COMPAT" --json "$OLD" "$OLD"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"compatible": true'* ]]
}

# --- the bash wrapper (contracts.sh compat) via its test hooks ---------------

@test "wrapper: a breaking change to a real schema is caught" {
  # Baseline = the committed schema; 'new' (on disk) = a narrowed copy.
  base="${TMP}/base"; mkdir -p "$base"
  cp "${PROJECT_ROOT}/contracts/oauth_sso.claims.schema.json" "$base/"
  # Narrow the on-disk schema in a throwaway PROJECT_ROOT copy so we don't touch the repo.
  work="${TMP}/work"; mkdir -p "$work/contracts" "$work/scripts/commands" "$work/lib"
  cp "${PROJECT_ROOT}/contracts/"*.json "${PROJECT_ROOT}/contracts/"*.py "$work/contracts/"
  cp "$WRAP" "$work/scripts/commands/"
  cp "${PROJECT_ROOT}/lib/minisign.sh" "$work/lib/" 2>/dev/null || true
  cp "${PROJECT_ROOT}/lib/ui.sh" "$work/lib/" 2>/dev/null || true
  # Break it: drop the required `sub` type to integer (type-narrow).
  sed -i 's/"type": "string",\n *"minLength": 1//' "$work/contracts/oauth_sso.claims.schema.json" 2>/dev/null || true
  python3 - "$work/contracts/oauth_sso.claims.schema.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["properties"]["sub"]["type"]="integer"     # narrow string -> integer
json.dump(d,open(p,"w"))
PY
  run env NWP_CONTRACTS_FILES="contracts/oauth_sso.claims.schema.json" \
          NWP_CONTRACTS_BASE_DIR="$base" \
          bash "$work/scripts/commands/contracts.sh" compat
  [ "$status" -eq 1 ]
  [[ "$output" == *"BREAKING"* ]]
}

@test "wrapper: no schema changes -> compatible (exit 0)" {
  run env NWP_CONTRACTS_FILES="" bash "$WRAP" compat
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to check"* ]]
}
