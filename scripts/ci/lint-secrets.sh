#!/usr/bin/env bash
#
# lint-secrets.sh — the CI half of the secrets gate.
#
# WHY THIS FILE EXISTS
#   `pl secrets lint|audit|discover-copies|consumers` were invoked by no cron,
#   no CI job and no verb — the only two matches in the whole tree were comments.
#   CLAUDE.md asserted a daily audit that was installed on zero hosts. So the
#   registry could disagree with reality indefinitely and nothing would ever say
#   so. `pl secrets cron install` fixes the daily half; this fixes the CI half.
#
# WHAT CI CAN HONESTLY CHECK
#   CI has no estate: no .secrets.yml, no private/secrets-registry.yml, no
#   provider reachability. Running the real `pl secrets lint` here would either
#   error out or — worse — "pass" against an absent registry, which is precisely
#   the vacuous shape this programme exists to remove. So this gate checks the
#   three things that ARE decidable from the repo alone:
#
#     1. CONTAINMENT — no credential file and no registry may be tracked here.
#        nwp/nwp is the public-release track. Measured 2026-07-26: gitleaks over
#        private/secrets-registry.yml reports 162 findings, all identity /
#        topology (live domains, operator public IP, operator personal email)
#        and zero credential. It is value-free by design and is still a complete
#        map of the estate. It belongs in a nested private repo — see
#        `pl secrets registry-track` — never in this one.
#
#     2. THE RULES ARE WIRED — the hermetic secrets bats suites must run, and
#        must run a plausible NUMBER of tests. A floor defeats the failure mode
#        where a rename or a bad glob silently reduces the gate to zero cases
#        and the job still goes green.
#
#     3. THE RULES CAN STILL GO RED — a live self-test. We build a throwaway
#        registry that declares a scope with no probe: block and assert that
#        `pl secrets lint` actually fails on it. This is the anti-vacuity check:
#        it proves, in the pipeline, on every run, that the gate is capable of
#        failing. If someone weakens the NO-PROBE rule, this job goes red even
#        though every other test still passes.
#
# EXIT
#   0 — contained, wired, and demonstrably able to fail
#   1 — at least one of the three failed
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
rc=0
say(){ printf '%s\n' "$*"; }
fail(){ printf 'FAIL: %s\n' "$*"; rc=1; }
ok(){ printf 'ok:   %s\n' "$*"; }

say "== 1. containment — no credential material tracked in this repo =="
# Exact paths that must never be tracked, plus shape-based globs.
FORBIDDEN_PATHS=(
  "private/secrets-registry.yml"
  ".secrets.yml"
  ".secrets.data.yml"
  ".nwp-agent-loop.env"
)
for p in "${FORBIDDEN_PATHS[@]}"; do
  if git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    fail "$p is TRACKED — it must not live in the public-release repo"
  fi
done
# Shape-based sweep: anything that looks like a key/token/credential file.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    # Fixtures and templates are fine — they are the documented, value-free form.
    *.example|*.example.*|*example*|tests/*|*/fixtures/*|*.tpl|*.template) continue ;;
    # keys/ is an intentionally EMPTY tracked directory; .gitkeep is what makes
    # it exist in git at all and carries nothing.
    */.gitkeep|.gitkeep) continue ;;
  esac
  fail "tracked credential-shaped file: $f"
done < <(git ls-files -- '*.token' '*.pem' 'keys/*' '*_rsa' '*id_ed25519' 2>/dev/null)
[ "$rc" -eq 0 ] && ok "no credential file or registry is tracked here"

say ""
say "== 2. the secrets rules are wired into a suite that actually runs =="
if ! command -v bats >/dev/null 2>&1; then
  fail "bats is not installed — cannot verify the secrets rules run at all"
else
  SUITES=(
    tests/unit/test-secrets-registry-truth.bats
    tests/unit/test-secrets-audit.bats
  )
  present=0
  for s in "${SUITES[@]}"; do
    [ -f "$s" ] || { fail "missing suite: $s"; continue; }
    present=$((present+1))
  done
  if [ "$present" -eq 0 ]; then
    fail "no secrets suite present — the gate would be checking nothing"
  else
    out=$(bats "${SUITES[@]}" 2>&1); brc=$?
    n=$(printf '%s\n' "$out" | grep -cE '^(ok|not ok) ')
    nf=$(printf '%s\n' "$out" | grep -cE '^not ok ')
    say "     ran $n test(s), $nf failure(s)"
    # FLOOR: an empty or gutted suite must not read as a pass. 30 is comfortably
    # below today's count and comfortably above "something broke and ran nothing".
    FLOOR="${NWP_SECRETS_TEST_FLOOR:-30}"
    [ "$n" -lt "$FLOOR" ] && fail "only $n secrets test(s) ran (floor $FLOOR) — the suite is not really running"
    [ "$brc" -ne 0 ] && { fail "secrets suite failed"; printf '%s\n' "$out" | grep -A3 '^not ok ' | head -40; }
    [ "$brc" -eq 0 ] && [ "$n" -ge "$FLOOR" ] && ok "secrets suite ran $n tests, all passing"
  fi
fi

say ""
say "== 3. self-test — prove the gate is still CAPABLE of failing =="
# The whole point of item 1: a registry that declares a capability it never
# checks must be a lint ERROR. Build exactly that and assert lint rejects it.
if ! command -v yq >/dev/null 2>&1; then
  say "     yq unavailable — skipping the live self-test (suite above still covers it)"
else
  TMP=$(mktemp -d) || { fail "mktemp"; TMP=""; }
  if [ -n "$TMP" ]; then
    mkdir -p "$TMP/estate/private"
    cat > "$TMP/secrets.yml" <<'YML'
gitlab:
  server:
    domain: selftest.invalid
selftest:
  token: PLACEHOLDER_selftest_value
YML
    chmod 600 "$TMP/secrets.yml"
    cat > "$TMP/registry.yml" <<YML
version: 1
secrets:
  - id: selftest_token
    provider: gitlab
    type: CI self-test entry — claims a scope, declares no probe
    scopes: [api]
    stored_in:
      - .secrets.yml:selftest.token
    rotate_via: manual
    cadence_days: 365
    expires: "2099-01-01"
    owner: ci
    status: active
ignored_keys:
  - gitlab.server.domain
YML
    out=$(NWP_ROOT="$TMP/estate" NWP_SECRETS_FILE="$TMP/secrets.yml" \
          NWP_SECRETS_REGISTRY="$TMP/registry.yml" \
          bash "$ROOT/scripts/commands/secrets.sh" lint 2>&1); lrc=$?
    if [ "$lrc" -eq 0 ]; then
      fail "lint PASSED a registry that claims a scope with no probe — the NO-PROBE rule is not working"
    elif ! printf '%s' "$out" | grep -q 'NO-PROBE'; then
      fail "lint failed, but not with NO-PROBE — the rule may have been renamed or weakened"
      printf '%s\n' "$out" | tail -10
    else
      ok "lint correctly rejects a scope-without-probe entry (gate can go red)"
    fi
    rm -rf "$TMP"
  fi
fi

say ""
if [ "$rc" -eq 0 ]; then
  say "SECRETS GATE OK — contained, wired, and provably able to fail"
else
  say "SECRETS GATE FAILED"
fi
exit "$rc"
