#!/usr/bin/env bash
#
# sensitive-path-hold-gate.sh — CI entry point for the D13 sensitive-path HOLD.
#
# WHY THIS FILE EXISTS
#   `security:review` already refused a sensitive-path change that carried no
#   `REVIEW:` marker. That is a LABELLING gate: type `REVIEW:` in the title and
#   it goes green. On 2026-08-01 a `REVIEW:`-titled MR — correctly labelled,
#   deliberately held, two-person-approval class — was auto-merged the moment
#   the pipeline went green, because a sweeper had armed
#   `merge_when_pipeline_succeeds` on it and nothing about the "hold" was
#   machine-readable.
#
#   Labelling a change as needing two people does not make two people look at
#   it. This job HOLDS it instead.
#
# WHAT IT DOES
#   Delegates to `pl mr guard --ci` (STANDING ORDER: everything goes through a
#   `pl` verb — the logic lives in the verb so an operator can run exactly what
#   CI runs). That verb:
#     * computes the sensitive paths in this MR's diff from CLAUDE.md's own list
#     * allows the MR if a release record exists that is bound to THIS head sha
#     * otherwise sets the MR to Draft (GitLab then refuses the merge), cancels
#       any armed auto-merge, labels and explains it — and fails this job.
#
# TWO LAYERS, AND THIS JOB IS BOTH
#   The Draft is the lock, and it needs a token. This job's FAILURE is the
#   credential-free backstop: `merge_when_pipeline_succeeds` cannot fire on a
#   red pipeline. So even with no NWP_MR_TOKEN configured, an unreleased
#   sensitive-path MR cannot auto-merge.
#
# EXIT
#   0 — no sensitive path touched, or released for this head commit
#   1 — held
#   2 — cannot verify (no diff base, unreadable CLAUDE.md) — fail closed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# The CI variable is the preferred home for the token; `pl mr` falls back to
# .secrets.yml when a human runs it locally. Never echoed, never in argv.
if [ -n "${NWP_MR_TOKEN:-}" ]; then
    export NWP_MR_TOKEN
elif [ -n "${MR_HOLD_TOKEN:-}" ]; then
    export NWP_MR_TOKEN="$MR_HOLD_TOKEN"
fi

exec "$PROJECT_ROOT/scripts/commands/mr.sh" guard --ci "$@"
