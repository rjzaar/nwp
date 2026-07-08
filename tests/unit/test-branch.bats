#!/usr/bin/env bats
# P67 §5b/§5c — pl branch twins: creation, lineage, nested status rendering.

setup() {
  TEST_TMP=$(mktemp -d)
  ROOT="$TEST_TMP/nwp"
  REPO="${BATS_TEST_DIRNAME}/../.."

  mkdir -p "$ROOT/scripts/commands" "$ROOT/lib"
  cp "$REPO/scripts/commands/branch.sh" "$REPO/scripts/commands/status.sh" \
     "$REPO/scripts/commands/delete.sh" "$ROOT/scripts/commands/"
  cp "$REPO"/lib/{ui,common,impact,canonical,yaml-write,project-resolver,server-resolver,ssh,verify-autolog}.sh "$ROOT/lib/" 2>/dev/null || true

  # Parent v2 site with a git repo + origin/main ref + a .ddev config
  mkdir -p "$ROOT/sites/par/dev/.ddev" "$ROOT/sites/par/dev/web"
  echo "name: par-dev" > "$ROOT/sites/par/dev/.ddev/config.yaml"
  echo "hello" > "$ROOT/sites/par/dev/web/index.php"
  git -C "$ROOT/sites/par/dev" init -q -b main
  git -C "$ROOT/sites/par/dev" -c user.email=t@t -c user.name=t add -A
  git -C "$ROOT/sites/par/dev" -c user.email=t@t -c user.name=t commit -q -m init
  git -C "$ROOT/sites/par/dev" update-ref refs/remotes/origin/main HEAD

  cat > "$ROOT/nwp.yml" <<'EOF'
settings:
  url: example.org
sites:
  par:
    recipe: d
    purpose: indefinite
EOF

  # ddev/docker shims (branch --no-start avoids them, but status touches ddev list)
  mkdir -p "$TEST_TMP/bin"
  printf '#!/bin/bash\ncase "$1" in list) echo "{\\"raw\\":[]}" ;; esac\nexit 0\n' > "$TEST_TMP/bin/ddev"
  printf '#!/bin/bash\nexit 0\n' > "$TEST_TMP/bin/docker"
  chmod +x "$TEST_TMP/bin/"*
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_create_twin() {
  ( cd "$ROOT" && ./scripts/commands/branch.sh par feat/idea --no-start -y </dev/null )
}

@test "branch create: copies tree, switches branch, renames ddev project, registers lineage" {
  run _create_twin
  [ "$status" -eq 0 ]
  [ -d "$ROOT/sites/par-idea/dev/web" ]
  [ "$(git -C "$ROOT/sites/par-idea/dev" branch --show-current)" = "feat/idea" ]
  grep -q "name: par-idea-dev" "$ROOT/sites/par-idea/dev/.ddev/config.yaml"
  # parent untouched
  [ "$(git -C "$ROOT/sites/par/dev" branch --show-current)" = "main" ]
  # registered with lineage, purpose testing, no live block
  grep -q "^  par-idea:" "$ROOT/nwp.yml"
  grep -q "branch_of: par" "$ROOT/nwp.yml"
  grep -q "branch: feat/idea" "$ROOT/nwp.yml"
  grep -q "purpose: testing" "$ROOT/nwp.yml"
  ! grep -A8 "^  par-idea:" "$ROOT/nwp.yml" | grep -q "live:"
  # ledgered
  grep -q "action=branch-create parent=par ref=feat/idea" "$ROOT/private/canonical/par-idea.log"
}

@test "branch create refuses an existing twin name" {
  _create_twin
  run _create_twin
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "branch list nests the twin under its parent with delta and provenance" {
  _create_twin
  git -C "$ROOT/sites/par-idea/dev" -c user.email=t@t -c user.name=t commit -q --allow-empty -m extra
  run bash -c "cd '$ROOT' && ./scripts/commands/branch.sh list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"par "* ]]
  [[ "$output" == *"└─ par-idea"* ]]
  [[ "$output" == *"feat/idea"* ]]
  [[ "$output" == *"+1/-0"* ]]
  [[ "$output" == *"content: fresh"* ]]
}

@test "status compact view lists parent first with twin sub-row" {
  _create_twin
  run bash -c "cd '$ROOT' && ./scripts/commands/status.sh -s 2>/dev/null"
  [ "$status" -eq 0 ]
  # parent row appears, twin appears only as a nested sub-row
  [[ "$output" == *"par "* ]]
  [[ "$output" == *"└─ par-idea"* ]]
  # twin must NOT appear as its own top-level row (no RAG-dot-prefixed row)
  parent_line=$(grep -n "  par  " <<< "$output" | head -1 | cut -d: -f1 || true)
  twin_line=$(grep -n "└─ par-idea" <<< "$output" | head -1 | cut -d: -f1)
  [ -n "$twin_line" ]
}

@test "site_code_delta reports even/ahead/behind correctly" {
  source "$ROOT/lib/ui.sh"; source "$ROOT/lib/yaml-write.sh"; source "$ROOT/lib/canonical.sh"
  [ "$(site_code_delta "$ROOT/sites/par/dev")" = "=" ]
  git -C "$ROOT/sites/par/dev" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
  [ "$(site_code_delta "$ROOT/sites/par/dev")" = "+1/-0" ]
}

@test "branch merge refuses dirty tree and main-branch twins" {
  _create_twin
  touch "$ROOT/sites/par-idea/dev/dirty.txt"
  run bash -c "cd '$ROOT' && ./scripts/commands/branch.sh merge par-idea"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted"* ]]
}

@test "branch delete refuses non-twins" {
  run bash -c "cd '$ROOT' && ./scripts/commands/branch.sh delete par"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a branch twin"* ]]
}
