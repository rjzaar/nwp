#!/bin/bash
#
# userpromptsubmit-om-freshness.sh — F2, the staleness gate on the injected
# read-first document (ops#319, knowledge-honesty Tranche 2; spec: meta-pass2
# §6 F2, addendum S3 "prefer generate-at-injection").
#
# WHAT: a Claude Code UserPromptSubmit hook (registered in the repo's
# .claude/settings.json). When a prompt names an `ops#N` issue — the same
# trigger that makes the read-first injector paste
# `~/central/nwc-internal/OPERATING-MODEL.md` into context — this hook runs
# `pl operating-model inject` and adds its verdict to the same turn.
#
# WHY: that document is the most-injected surface in the estate and, measured
# 2026-08-09, one of the stalest. It asserted "the loop is **paused**" while
# the loop was armed and running on the ai-host, and printed an issue map
# stopping at ops#53 while the queue was past ops#332 — both re-asserted to the
# model, as ground truth, on every ops turn. A document that cannot demonstrate
# its state is current must not be allowed to LOOK current. So:
#
#   FRESH → one line confirming the age, so the model may rely on the block.
#   STALE / MISSING / HAND-EDITED → a loud banner saying the state claims in
#     the document just injected are NOT current, plus (budget permitting) a
#     block measured right now, which supersedes it.
#
# Fail-closed to LESS information, never to stale-as-fresh. This is the same
# direction `.nwp-review-mode` takes when it cannot read `approvers:`.
#
# WHY IT NEVER EXITS NON-ZERO: a UserPromptSubmit hook that fails hard can
# suppress the turn's context. The failure this exists to prevent is silence
# about staleness, so silence is exactly what it must not produce. Every path
# ends `exit 0`, and the only variable is WHAT it says.
#
# WHY IT DOES NOT RE-INJECT THE DOCUMENT: the generic read-first injector
# (`~/.claude/hooks/inject-readfirst.sh`, configured by
# `~/central/nwc-internal/hooks/issue-hooks.env`) already pastes the doctrine.
# Two hooks pasting the same document would double the context and, worse,
# leave the reader to guess which copy is current. This one adds only the thing
# the generic injector structurally cannot: a verdict about currency, produced
# by running something.
#
# Deliberately quiet on non-ops prompts: no output at all, so the hook costs
# nothing on the majority of turns.

set -uo pipefail

# The project root Claude Code exports for hooks; fall back to this file's repo
# so the hook is runnable by hand and by bats.
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PL="${NWP_PL:-$ROOT/pl}"

# Same trigger as the read-first injector, so the two cannot disagree about
# which turns are "ops work". Overridable for tests.
PATTERN="${NWP_OM_HOOK_PATTERN:-(nwp/)?ops#[0-9]+}"

# Total time this hook may spend. The harness gives UserPromptSubmit hooks a
# configured timeout; overshooting it silently drops the output, which would be
# the worst outcome (a gate nobody sees). Clamp ourselves first.
BUDGET="${NWP_OM_HOOK_BUDGET_SEC:-45}"

payload="$(cat 2>/dev/null || true)"
prompt=""
if command -v jq >/dev/null 2>&1; then
    prompt="$(printf '%s' "$payload" | jq -r '.prompt // ""' 2>/dev/null || true)"
fi
# No jq, or an envelope shape we do not recognise: fall back to the raw payload.
# Matching the whole envelope is over-inclusive, never under-inclusive — and on
# this gate, firing when it need not is harmless while staying silent is not.
[ -n "$prompt" ] || prompt="$payload"

printf '%s' "$prompt" | grep -qiE "$PATTERN" || exit 0

if [ ! -x "$PL" ]; then
    printf '=== ⛔ OPERATING-MODEL state gate: CANNOT VERIFY ===\n'
    printf 'No executable pl at %s, so the currency of the read-first document\n' "$PL"
    printf 'could not be checked. Treat every STATE claim in it as unverified.\n'
    exit 0
fi

out="$(timeout "$BUDGET" "$PL" operating-model inject 2>/dev/null)" || out=""
if [ -z "$out" ]; then
    printf '=== ⛔ OPERATING-MODEL state gate: CANNOT VERIFY ===\n'
    printf '`pl operating-model inject` produced nothing within %ss. The read-first\n' "$BUDGET"
    printf 'document may be current or may be months stale — this run could not tell.\n'
    printf 'Do not rely on its state claims; derive instead:\n'
    printf '  pl session brief  ·  pl issue ls  ·  pl rag  ·  pl loop --host <role> status\n'
    exit 0
fi

printf '%s\n' "$out"
exit 0
