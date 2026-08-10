#!/usr/bin/env bats
# BOOTSTRAP FROM NOTHING — the estate's own doctrine, applied at the CLI edge.
#
# Same defect class as tests/unit/test-secrets-not-provisioned.bats (ops#331):
# a verb written for the steady state meets a thing that has not been created
# yet and reports it as BROKEN. These four are the ones a fresh clone, a linked
# worktree or a first-ever site actually walks into.
#
# The doctrine is already written down, twice, in this repo:
#
#   lib/canonical.sh:51-64  "ABSENT BY CONTEXT vs PRESENT BUT UNREADABLE …
#                            THE LINE IS DRAWN AT PARSEABILITY, NOT PRESENCE:
#                            · config EXISTS and does not parse → CANNOT VERIFY,
#                              refuse, always.
#                            · config MISSING → today's defaults, as before."
#   lib/rotation-debt.sh:51  "registry MISSING → no debt (fresh clone, CI, a
#                             checkout that never had one)"
#
# and lib/canonical.sh says exactly why it matters here: "`pl` runs from a fresh
# clone, from CI, and from ~40 linked worktrees, and in those contexts nwp.yml
# legitimately does not exist". The COMMAND layer forgot it. `pl canonical show`
# is red in every one of those ~40 worktrees today, for the one condition the
# library it wraps documents as normal.
#
# `pl class check` is the model the other verbs are measured against here — it
# separates UNDECLARED ("nobody has said what this is") from BROKEN, names the
# verb that fixes it, and grades them differently. `pl class evidence` does not,
# in the same file.
#
# Fully offline; nothing here touches the real estate.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  export ROOT="${TEST_TMP}/root"
  mkdir -p "${ROOT}/scripts/commands" "${ROOT}/sites/demo" "${ROOT}/classes"
  ln -sfn "${REPO_ROOT}/lib" "${ROOT}/lib"
  cp "${REPO_ROOT}/pl" "${ROOT}/pl"
  cp "${REPO_ROOT}/example.nwp.yml" "${ROOT}/example.nwp.yml"
  # A site that exists ON DISK but has never been configured — the shape a
  # first-ever `pl site init` meets.
  printf '{}\n' > "${ROOT}/sites/demo/composer.json"
  # DELIBERATELY no ${ROOT}/nwp.yml: that is the whole subject of this file.
}

teardown() { rm -rf "$TEST_TMP"; }

# Run a command script from a sandbox root, so its
# PROJECT_ROOT="$SCRIPT_DIR/../.." lands inside the fixture rather than in the
# real checkout. Containment has to be a property of WHERE the subject sits,
# not of a variable it is asked to honour (helpers/secrets-sandbox.bash).
sandboxed() { # script-basename  args…
  local s="$1"; shift
  cp "${REPO_ROOT}/scripts/commands/${s}" "${ROOT}/scripts/commands/${s}"
  run bash "${ROOT}/scripts/commands/${s}" "$@"
}

# ── pl canonical: the command layer is STRICTER than the library it wraps ────

@test "canonical show: a missing nwp.yml is the fresh-clone case, not an error" {
  run env NWP_YML="${ROOT}/nwp.yml" bash "${REPO_ROOT}/scripts/commands/canonical.sh" show
  [ "$status" -eq 0 ]
  # It must say which state this is, and that nothing is classified here.
  [[ "$output" == *"NOT CREATED YET"* ]]
  [[ "$output" != *"ERROR"* ]]
}

@test "canonical show: names the verb that creates nwp.yml" {
  run env NWP_YML="${ROOT}/nwp.yml" bash "${REPO_ROOT}/scripts/commands/canonical.sh" show
  [[ "$output" == *"pl setup"* ]] || [[ "$output" == *"example.nwp.yml"* ]]
}

@test "canonical show: NEGATIVE CONTROL — a real nwp.yml still lists its sites" {
  cat > "${ROOT}/nwp.yml" <<'YML'
sites:
  demo:
    recipe: pod
    canonical: live
YML
  run env NWP_YML="${ROOT}/nwp.yml" bash "${REPO_ROOT}/scripts/commands/canonical.sh" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"demo"* ]]
  [[ "$output" == *"live"* ]]
}

@test "canonical show: NEGATIVE CONTROL — a config that EXISTS and cannot be parsed still refuses" {
  # The line is drawn at parseability, not presence. A fix that made every
  # absent-or-broken config benign would erase the distinction the library
  # spent thirty lines establishing.
  printf 'sites:\n  demo:\n   bad: [unclosed\n' > "${ROOT}/nwp.yml"
  run env NWP_YML="${ROOT}/nwp.yml" bash "${REPO_ROOT}/scripts/commands/canonical.sh" show
  [ "$status" -ne 0 ]                       # present-and-corrupt still refuses
  [[ "$output" != *"NOT CREATED YET"* ]]    # …and is never described as absent
}

@test "canonical set: still refuses without a config, but names how to create one" {
  run env NWP_YML="${ROOT}/nwp.yml" bash "${REPO_ROOT}/scripts/commands/canonical.sh" set demo live
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT CREATED YET"* ]]
  [[ "$output" == *"pl setup"* ]]
}

# ── pl site init: a raw yq error is not a diagnosis ──────────────────────────

@test "site init: a missing nwp.yml does not surface as a bare yq error" {
  sandboxed site.sh init demo
  # Today: `Error: open …/nwp.yml: no such file or directory`, exit 1, and not
  # one word of NWP's own. A first-ever site cannot be configured and the
  # operator is handed a library's error message.
  [[ "$output" != *"Error: open"* ]]
  [[ "$output" != *"no such file or directory"* ]]
}

@test "site init: says the global config is absent and that defaults are being used" {
  sandboxed site.sh init demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT CREATED YET"* ]]
  [ -f "${ROOT}/sites/demo/.nwp.yml" ]
}

@test "site init: NEGATIVE CONTROL — with a real nwp.yml the values still come FROM it" {
  cat > "${ROOT}/nwp.yml" <<'YML'
sites:
  demo:
    recipe: pod
    environment: staging
YML
  sandboxed site.sh init demo
  [ "$status" -eq 0 ]
  grep -q 'staging' "${ROOT}/sites/demo/.nwp.yml"
  [[ "$output" != *"NOT CREATED YET"* ]]
}

# ── pl install: two different absences, two different fixes ──────────────────

@test "install: 'nwp.yml not found' must say it has never been CREATED, and how" {
  cd "$TEST_TMP" || return 1
  sandboxed install.sh pod demosite
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT CREATED YET"* ]]
  [[ "$output" == *"example.nwp.yml"* ]]
  [[ "$output" == *"pl setup"* ]]
}

@test "install: a config that EXISTS at the estate root but not at \$PWD is a different fault" {
  # `pl` is on \$PATH and this project's standing rule is to work inside a
  # worktree, so \$PWD is essentially never the estate root — and install.sh
  # reads a RELATIVE 'nwp.yml'. Telling an operator who has a perfectly good
  # config that it "was not found" sends them to create a second one.
  cat > "${ROOT}/nwp.yml" <<'YML'
recipes:
  pod:
    type: drupal
YML
  cd "$TEST_TMP" || return 1
  sandboxed install.sh pod demosite
  [ "$status" -ne 0 ]
  [[ "$output" == *"estate root"* ]]
  [[ "$output" != *"NOT CREATED YET"* ]]
}

# ── pl class evidence: CANNOT-VERIFY where its own sibling says NOT-DECLARED ─

@test "class evidence: an undeclared site reads as UNDECLARED, like class check" {
  cp "${REPO_ROOT}/classes/registry.yml" "${ROOT}/classes/registry.yml"
  run env PROJECT_ROOT="${ROOT}" NWP_SITECLASS_DIR="${ROOT}/classes" \
    bash "${REPO_ROOT}/scripts/commands/class.sh" evidence demo
  # exit 2 in class.sh means CANNOT VERIFY — "I could not look". Nothing
  # obstructed the look: the site has simply never been declared, which
  # cmd_check reports at exit 1 with the verb that fixes it.
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNDECLARED"* ]]
  [[ "$output" == *"pl class set demo"* ]]
}

@test "class evidence: NEGATIVE CONTROL — a declared site still reports its evidence" {
  cp "${REPO_ROOT}/classes/registry.yml" "${ROOT}/classes/registry.yml"
  cat > "${ROOT}/classes/demo.class.yml" <<'EOF'
site: demo
class: service
EOF
  run env PROJECT_ROOT="${ROOT}" NWP_SITECLASS_DIR="${ROOT}/classes" \
    bash "${REPO_ROOT}/scripts/commands/class.sh" evidence demo
  [[ "$output" != *"UNDECLARED"* ]]
}
