# lib/raw-remote-patterns.sh — ONE source of truth for the raw-remote idiom class.
#
# The idioms `pl drush` / `pl moodle cli` / `pl moodle plugin deploy` were built
# to retire: raw remote one-liners that bypass the dry-run default, the typed
# live confirm, the live.enabled check, the ADR-0028 deploy gate, pair_guard,
# the fate manifest and the rollback ledger (CLAUDE.md, "everything goes
# through pl"; recorded failure: the 2026-07-28 ops#149 scp+sudo-cp deploy).
#
# TWO consumers, one oracle (ops#319 F4, meta-pass2 §2.4 "shared pattern
# file"):
#   scripts/commands/doc-truth.sh          — docs must not PRESCRIBE the idiom
#   scripts/hooks/pretooluse-raw-remote.sh — the live Bash stream must not RUN it
# Do not fork these patterns back inline into either consumer; a policy
# expressed in several places is a policy that drifts. The bats suite
# (tests/unit/test-pretooluse-raw-remote.bats) fails if either consumer stops
# sourcing this file.
#
# POSIX-sh sourceable; no dependencies; EREs usable with grep -E and [[ =~ ]].

# Shape (a) + (b) — the exact regex doc-truth's check 3 has always used:
#   (a) `ssh … drush …` / `ssh … admin/cli/…`   — the direct one-liner;
#   (b) `sudo -u www-data … drush|admin/cli/…`  — the remote invocation itself,
#       which catches the alias trick (`D="sudo -u www-data … drush"; ssh … "$D …"`).
#       A gate that a shell variable defeats is a vacuous gate.
# `[^|]*` keeps a match from spanning a pipe: `ssh host 'tail …' | grep drush`
# is recon plus local grep, not a remote drush.
RAW_REMOTE_CLI_REGEX='ssh[^|]*(drush|admin/cli/)|sudo[[:space:]]+-u[[:space:]]+www-data[^|]*(drush|admin/cli/)'

# Shape (c) — the scp+`ssh … sudo cp` deploy idiom (ops#149; the MEMORY.md
# "Deploy via scp to /tmp then sudo cp" recipe). The mutation half is the
# remote sudo file-write; the scp-to-/tmp half alone is not blocked.
# HOOK-ONLY today: adding it to doc-truth's corpus scan changes the doc
# baseline and belongs to the F3 lint MR (Tranche-0 MR-A/B), not this one.
RAW_REMOTE_DEPLOY_REGEX='ssh[^|]*[[:space:]'\''"](sudo[[:space:]]+(cp|mv|rsync|tee|install|chown|chmod)|sudo[[:space:]]+-u[[:space:]]+www-data)[[:space:]]'

# Read-only recon (`ssh host 'tail …'`, `free -h`, `systemctl status`) matches
# none of the above — CLAUDE.md's one standing exception is preserved without
# needing a carve-out.
