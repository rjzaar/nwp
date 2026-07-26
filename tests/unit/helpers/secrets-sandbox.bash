#!/usr/bin/env bash
# Containment helpers for the `pl secrets` suites.
#
# WHY THIS EXISTS
# ---------------
# The secrets suites declare hermeticity by exporting NWP_ROOT / NWP_SECRETS_FILE
# / NWP_SECRETS_REGISTRY. That is a request, not a guarantee: the script under
# test may simply ignore it. `NWP_TEST_SECRETS_SH=<pre-fix script>` — the exact
# reproduction the audit MR documents — points the suite at a script that has no
# NWP_ROOT support at all and derives its rotation log from its OWN location
# ($PROJECT_ROOT/private/rotation-YYYY-MM.md). Running it therefore appended
# `fixture_token` lines to the OPERATOR'S REAL rotation log. Five of them are in
# private/rotation-2026-07.md.
#
# So containment may not be a variable the subject is trusted to honour. It has
# to be a property of where the subject SITS:
#
#   secrets_sandbox_script  copies the script under test into a throwaway root
#                           that is its own git repo, so PROJECT_ROOT and any
#                           `git rev-parse --git-common-dir` lookup both land
#                           inside the sandbox no matter what the script does.
#   estate_guard_arm/assert hashes the real credential artefacts before the test
#                           and fails the test if any of them moved. A belt to
#                           the sandbox's braces: if a future path escapes, the
#                           suite says so instead of silently editing live state.

# Copy the script under test into a self-contained root and echo the new path.
secrets_sandbox_script() { # $1=script-under-test  $2=sandbox root dir
  local src="$1" root="$2" libdir
  libdir=$(cd "$(dirname "$src")/../../lib" && pwd) || return 1
  mkdir -p "$root/scripts/commands" "$root/private" "$root/logs" "$root/sites"
  cp "$src" "$root/scripts/commands/secrets.sh"
  ln -sfn "$libdir" "$root/lib"
  # Its own git repo: `git rev-parse --git-common-dir` from inside the sandbox
  # must resolve HERE and never walk up into the real checkout.
  git -C "$root" init -q >/dev/null 2>&1 || true
  printf '%s' "$root/scripts/commands/secrets.sh"
}

# --- real-estate canary ------------------------------------------------------

# Call BEFORE HOME is overridden.
# NWP_TEST_ESTATE_GUARD_FILES (colon-separated) overrides the watch list — used
# by the guard's own self-test, because a canary that has never been shown to
# sing is indistinguishable from a dead one.
estate_guard_arm() {
  local estate f
  if [ -n "${NWP_TEST_ESTATE_GUARD_FILES:-}" ]; then
    IFS=':' read -r -a ESTATE_GUARD_LIST <<< "$NWP_TEST_ESTATE_GUARD_FILES"
  else
  estate=$(git -C "${BATS_TEST_DIRNAME}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || estate=""
  [ -n "$estate" ] && estate=$(dirname "$estate")
  ESTATE_GUARD_LIST=(
    "${estate}/.secrets.yml"
    "${estate}/private/secrets-registry.yml"
    "${estate}/private/rotation-$(date +%Y-%m).md"
    "${HOME}/.nwp-agent-loop.env"
    "${HOME}/.ddev/homeadditions/.composer/auth.json"
  )
  fi
  ESTATE_GUARD_SNAP=""
  for f in "${ESTATE_GUARD_LIST[@]}"; do
    ESTATE_GUARD_SNAP+="${f} $(_estate_guard_hash "$f")"$'\n'
  done
  export ESTATE_GUARD_SNAP
}

_estate_guard_hash() {
  if [ -e "$1" ]; then sha256sum "$1" 2>/dev/null | cut -c1-16; else echo ABSENT; fi
}

# Call in teardown. Non-zero (and a loud message) if any real artefact changed.
estate_guard_assert() {
  [ -n "${ESTATE_GUARD_SNAP:-}" ] || return 0
  local f want got rc=0
  while read -r f want; do
    [ -z "$f" ] && continue
    got=$(_estate_guard_hash "$f")
    if [ "$got" != "$want" ]; then
      echo "ESTATE GUARD: the test suite modified real credential state: $f ($want -> $got)" >&2
      rc=1
    fi
  done <<< "$ESTATE_GUARD_SNAP"
  return $rc
}

# --- pty driver --------------------------------------------------------------
#
# `rotate` reads the new value and the expiry from /dev/tty on purpose — a
# credential must not be capturable from a pipe or a shell history. Testing it
# therefore needs a real terminal, not a heredoc.
pty_run() { # stdin-lines-as-$1, then the command
  local input="$1"; shift
  local script_out
  script_out=$(printf '%s' "$input" | timeout 60 script -qec "$*" /dev/null 2>&1)
  printf '%s' "$script_out"
}
