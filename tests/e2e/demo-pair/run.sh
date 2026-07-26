#!/usr/bin/env bash
set -euo pipefail
################################################################################
# tests/e2e/demo-pair/run.sh — one-command runner for the nwd<->ssd demo-pair
# browser e2e (ops#133 Phase 2).
#
#   DEV DDEV SITES ONLY — never point this at anything but *-dev.ddev.site.
#
#   tests/e2e/demo-pair/run.sh                # full run (captures a golden first)
#   SKIP_GOLDEN=1 tests/e2e/demo-pair/run.sh  # reuse the existing paired golden
#
# ⚠ Step 7 of the spec performs a REAL paired reset: both dev sites are wiped
#   back to the golden cut. That is the thing under test. Do not run this
#   against a dev site whose state you care about.
################################################################################
cd "$(dirname "$0")"
E2E_DIR="$(pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$E2E_DIR/../../.." && pwd)}"
export PROJECT_ROOT
PL="${PL_BIN:-$PROJECT_ROOT/pl}"
export PL_BIN="$PL"

NWD_DIR="${NWD_DEV_DIR:-$PROJECT_ROOT/sites/nwd/dev}"
SSD_DIR="${SSD_DEV_DIR:-$PROJECT_ROOT/sites/ssd/dev}"
export NWD_DEV_DIR="$NWD_DIR" SSD_DEV_DIR="$SSD_DIR"

# 0. Both halves up (start gently — the laptop runs many ddev projects).
for d in "$NWD_DIR" "$SSD_DIR"; do
  if ! ( cd "$d" && ddev describe >/dev/null 2>&1 ); then
    echo "== starting ddev project at $d"
    ( cd "$d" && ddev start )
  fi
done

# 1. Seed the provider's consent-matrix accounts and give them a run-local
#    password (the non-consenting half of the test needs a real login).
echo "== seeding nwd demo accounts"
( cd "$NWD_DIR" && ddev exec drush nwc:seed-demo --force ) | tail -2
PASS="$(openssl rand -hex 12)"
umask 077
printf '%s' "$PASS" > "$E2E_DIR/.demo-pass"
for u in nwcdemo_consenting nwcdemo_trialing nwcdemo_tester; do
  ( cd "$NWD_DIR" && ddev exec drush user:password "$u" "$PASS" ) >/dev/null
done

# 2. Consumer must be built, wired and seeded (all idempotent).
echo "== asserting the ssd half is built, wired and seeded"
bash "$PROJECT_ROOT/scripts/demo/ssd-oidc-wire.sh"    --site=ssd --tier=dev --check
bash "$PROJECT_ROOT/scripts/demo/ssd-demo-posture.sh" --site=ssd --tier=dev --check
bash "$PROJECT_ROOT/scripts/demo/ssd-seed-courses.sh" --site=ssd --tier=dev --check

# 3. A paired golden the reset step can restore to.
if [[ "${SKIP_GOLDEN:-0}" != "1" ]]; then
  echo "== capturing a paired golden (nwd + ssd, one cut)"
  bash "$PL" demo golden nwd --with-pair
fi

# 4. Issue the invite code the tester will redeem. Plaintext is printed once,
#    so we capture it here into a 0600 file the spec reads (and delete after).
echo "== issuing an invite code"
CODE="$(bash "$PL" demo codes nwd issue tester-member --expires=1d \
        | grep -oE '[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}' | head -1)"
[[ -n "$CODE" ]] || { echo "FATAL: could not issue an invite code"; exit 1; }
printf '{"member":"%s"}' "$CODE" > "$E2E_DIR/.demo-codes.json"

# 5. Deps (first run only).
if [[ ! -d node_modules ]]; then
  npm install --no-fund --no-audit
  npx playwright install chromium
fi

# 6. Run.
set +e
npx playwright test "$@"
rc=$?
set -e

# 7. Housekeeping: the plaintext code file must not outlive the run, and every
#    code this harness minted is revoked (they were only ever for the test).
rm -f "$E2E_DIR/.demo-codes.json" "$E2E_DIR/.demo-pass"
echo "== revoking every code this run minted"
bash "$PL" demo codes nwd rotate >/dev/null 2>&1 || true
for id in $(jq -r '.codes[] | select(.revoked == false) | .id' \
              "$PROJECT_ROOT/sites/nwd/demo-codes.json" 2>/dev/null); do
  bash "$PL" demo codes nwd revoke "$id" >/dev/null 2>&1 || true
done
echo "== done (exit $rc)"
exit "$rc"
