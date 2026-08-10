#!/usr/bin/env bats
#
# tests/unit/test-pipeline.bats — ops#326 Phase 1 tranche 3.
#
# `pl pipeline` is the GENERIC replacement for a verb that was named after one
# private site's data pipeline and hardcoded that site's directory:
#
#     MT_DIR="$PROJECT_ROOT/<private-site>"      # engine tree, public mirror
#     exec "$MT_DIR/<verb>.sh" "$@"
#
# Two things were wrong with it. The privacy one is obvious. The functional one
# is that the path had been dead since the F23 layout change — per-site
# pipelines live at sites/<site>/dev/pipeline/, so the verb exec'd a directory
# that does not exist and exited 127 on every invocation:
#
#     $ pl <old-verb> --status
#     .../scripts/commands/<old-verb>.sh: line 72:
#         .../<private-site>/<old-verb>.sh: No such file or directory ; EXIT=127
#
# `pl pipeline` describes the FUNCTION — run a site's project-specific data
# pipeline — takes the site as an argument, and resolves the entrypoint from
# the site's own tree. Nothing in the engine names a site.
#
# The old verb survives as a thin deprecation shim that names the new verb and
# still WORKS: it resolves which site owns an entrypoint of that name by
# scanning sites/*/dev/pipeline/, so it never has to hardcode a site either.
#
# Every case below was RED before scripts/commands/pipeline.sh existed
# ("pipeline: command not found" / no such file).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PL="${REPO_ROOT}/pl"
  TMP="${BATS_TEST_TMPDIR}"
  ROOT="${TMP}/root"
  mkdir -p "$ROOT/sites"
  export NWP_DIR="$ROOT"
}

# _site_pipeline <site> <entrypoint-basename> — make a fixture pipeline that
# echoes a marker and its argv so we can prove the exec really happened.
_site_pipeline() {
  local site="$1" entry="$2" dir="$ROOT/sites/$1/dev/pipeline"
  mkdir -p "$dir"
  printf 'name: %s\n' "$site" > "$ROOT/sites/$site/.nwp.yml"
  cat > "$dir/${entry}.sh" <<EOF
#!/usr/bin/env bash
printf 'RAN %s ARGV=%s\n' "${entry}" "\$*"
EOF
  chmod +x "$dir/${entry}.sh"
}

@test "pl pipeline exists and its help names the generic function, not a site" {
  run "$PL" pipeline --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pipeline"* ]]
  [[ "$output" == *"sites/<site>/dev/pipeline"* ]]
}

@test "pl pipeline with no arguments REFUSES rather than guessing a site" {
  run "$PL" pipeline
  [ "$status" -ne 0 ]
  [[ "$output" == *"site"* ]]
}

@test "pl pipeline list reports sites that HAVE a pipeline, and says so when none do" {
  run "$PL" pipeline list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no site"* || "$output" == *"No site"* ]]

  _site_pipeline fxa run-fxa-flow
  run "$PL" pipeline list
  [ "$status" -eq 0 ]
  [[ "$output" == *"fxa"* ]]
}

@test "pl pipeline REFUSES an unknown site by name (no silent no-op)" {
  run "$PL" pipeline fxnope
  [ "$status" -ne 0 ]
  [[ "$output" == *"fxnope"* ]]
}

@test "pl pipeline REFUSES a site that has no pipeline directory" {
  mkdir -p "$ROOT/sites/fxb/dev"
  printf 'name: fxb\n' > "$ROOT/sites/fxb/.nwp.yml"
  run "$PL" pipeline fxb
  [ "$status" -ne 0 ]
  [[ "$output" == *"pipeline"* ]]
  [[ "$output" == *"fxb"* ]]
}

@test "pl pipeline runs the site's entrypoint and forwards argv verbatim" {
  _site_pipeline fxa run-fxa-flow
  run "$PL" pipeline fxa --extract --limit=3
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN run-fxa-flow"* ]]
  [[ "$output" == *"ARGV=--extract --limit=3"* ]]
}

@test "pl pipeline prefers a run-* wrapper over the bare entrypoint" {
  _site_pipeline fxa fxa-flow
  _site_pipeline fxa run-fxa-flow
  run "$PL" pipeline fxa
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN run-fxa-flow"* ]]
}

@test "pl pipeline REFUSES an ambiguous entrypoint instead of picking one" {
  _site_pipeline fxa alpha-flow
  _site_pipeline fxa beta-flow
  run "$PL" pipeline fxa
  [ "$status" -ne 0 ]
  [[ "$output" == *"alpha-flow"* ]]
  [[ "$output" == *"beta-flow"* ]]
  [[ "$output" == *"--entrypoint"* ]]
}

@test "pl pipeline --entrypoint selects one of several" {
  _site_pipeline fxa alpha-flow
  _site_pipeline fxa beta-flow
  run "$PL" pipeline fxa --entrypoint=beta-flow
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN beta-flow"* ]]
}

@test "pl pipeline --setup/--deploy dispatch to the sibling setup-/deploy- scripts" {
  _site_pipeline fxa fxa-flow
  _site_pipeline fxa setup-fxa-flow
  _site_pipeline fxa deploy-fxa-flow
  run "$PL" pipeline fxa --setup --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN setup-fxa-flow"* ]]
  [[ "$output" == *"ARGV=--check"* ]]
  run "$PL" pipeline fxa --deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN deploy-fxa-flow"* ]]
}

@test "pl pipeline --find resolves the OWNING site of an entrypoint" {
  _site_pipeline fxa some-flow
  run "$PL" pipeline --find=some-flow --dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"fxa"* ]]
}

@test "pl pipeline --find REFUSES when two sites own the same entrypoint" {
  _site_pipeline fxa some-flow
  _site_pipeline fxb some-flow
  run "$PL" pipeline --find=some-flow --dry
  [ "$status" -ne 0 ]
  [[ "$output" == *"fxa"* ]]
  [[ "$output" == *"fxb"* ]]
}

@test "pl pipeline --find REFUSES when no site owns the entrypoint (never exits 0 blind)" {
  run "$PL" pipeline --find=nobody-owns-this --dry
  [ "$status" -ne 0 ]
  [[ "$output" == *"nobody-owns-this"* ]]
}

################################################################################
# The retired verb's DEPRECATION SHIM.
#
# The old verb was API surface, so it is not simply deleted: it keeps working,
# names its replacement, and — crucially — resolves the owning site by SCANNING
# rather than by hardcoding it, so the shim itself contains no site name either.
# Before this tranche the same invocation exited 127 with a bare
# "No such file or directory".
################################################################################

@test "the retired scraper verb prints a DEPRECATION notice naming pl pipeline" {
  run "$PL" mass-times --help
  [[ "$output" == *"DEPRECATED"* || "$output" == *"deprecated"* ]]
  [[ "$output" == *"pl pipeline"* ]]
}

@test "the retired verb still WORKS — it resolves the owning site and forwards argv" {
  _site_pipeline fxa mass-times
  run "$PL" mass-times --extract --limit=3
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN mass-times"* ]]
  [[ "$output" == *"ARGV=--extract --limit=3"* ]]
  [[ "$output" == *"pl pipeline"* ]]
}

@test "the retired verb maps its old --setup-check flag onto the new verb" {
  _site_pipeline fxa mass-times
  _site_pipeline fxa setup-mass-times
  run "$PL" mass-times --setup-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN setup-mass-times"* ]]
  [[ "$output" == *"ARGV=--check"* ]]
}

@test "the retired verb REFUSES loudly when no checked-out site owns the pipeline" {
  run "$PL" mass-times --status
  [ "$status" -ne 0 ]
  [[ "$output" == *"mass-times"* ]]
  [[ "$output" != *"No such file or directory"* ]]
}

@test "the retired verb hardcodes no site directory" {
  run grep -nE '(^|[^A-Za-z_])(MT_DIR|PROJECT_ROOT)/[a-z0-9]+"?$' "${REPO_ROOT}/scripts/commands/mass-times.sh"
  [ "$status" -ne 0 ]
}
