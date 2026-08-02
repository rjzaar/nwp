# Runbook — automatic session handover

**What this is.** A session that ends writes a handover; a supervisor starts the
next one; the next one begins from **generated state**, not prose. Sessions
become replaceable, so losing one costs a brief and nothing else.

**Why it exists.** On 2026-08-02 an orchestrating session fed its sub-agents four
premises from memory and all four were wrong: an MR "merged" that was open, a
branch "on main" that was not, a wrong root cause, and a "missing" video that was
present. Every one was caught only because an agent went and looked. Generated
state cannot go stale that way — that is the entire argument.

---

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Baton | `~/central/OVERNIGHT-BATON.md` | Line 1 is `STATUS: IN-PROGRESS\|READY\|ABANDONED`. 90-minute dropped-baton timeout. |
| Brief | `pl session brief` | Derives live state. The part that matters. |
| Bounds | `lib/session-bounds.sh` | Sensitive-path hold, demo-tier live bound, repeat-stop, token ceiling, notify preflight. |
| SessionEnd hook | `scripts/hooks/session-end-baton.sh` | Flips the baton automatically when a session dies or exits. |
| Supervisor | `servers/<ai-host>/system/systemd-nwp-session-supervisor.{service,timer}` | systemd **user** timer on the `ai-host`, ticking every 5 min. |

Everything is behind one verb: **`pl session`**. If a step here needs an `ssh` or
a hand-rolled script, that is a bug in the verb — fix the verb.

---

## Start / stop the supervisor

The supervisor belongs on the **`ai-host`** (the durable agent host). It does
*not* belong on `authoring`, which has no tmux and dies with the lid.

```bash
ssh <ai-host>
cd ~/nwp
pl session supervisor install     # copies this host's units, daemon-reload, enable --now
loginctl enable-linger $USER      # already on there; without it the timer dies at logout

pl session supervisor status      # timer state + the current baton
pl session supervisor run --dry-run   # one tick, decides but launches nothing

systemctl --user stop  nwp-session-supervisor.timer    # pause
systemctl --user start nwp-session-supervisor.timer    # resume
pl session supervisor uninstall                        # remove entirely
```

Logs: `~/.local/state/nwp/session/supervisor.log`, and
`journalctl --user -u nwp-session-supervisor.service`.

---

## Attach to a running session — READ-ONLY

```bash
ssh <ai-host>
tmux attach -r -t nwp-auto
```

**`-r` is not optional.** Without it a stray keystroke types into a running
agent's stdin, which at best corrupts a prompt and at worst answers a
confirmation you never saw. Detach with `Ctrl-b d`.

`nwp-auto` is the supervisor's session. The `ai-host`'s other durable session is
`nwp` (`nwp-tmux.service`), which the operator uses by hand — the two names are
deliberately distinct and a test pins that.

---

## Intervene

| Situation | Do this |
|---|---|
| Stop the current session now | `tmux kill-session -t nwp-auto` then `pl session baton abandon` |
| Stop everything starting | `systemctl --user stop nwp-session-supervisor.timer` |
| It stopped on repeat failure | Read `~/.local/state/nwp/session/failures.tsv`, fix the cause, then delete the offending rows (or the file) |
| It refuses: "cannot reach the operator" | `pl notify health` — fix Gotify. Override only deliberately: `NWP_SESSION_ALLOW_NO_NOTIFY=1` in `~/.config/nwp-session/env` |
| A session is wedged but the baton says IN-PROGRESS | Wait for the 90-min timeout, or force it: `pl session baton abandon` |
| Release a held MR | A human reads the diff, then removes the `Draft:` prefix in GitLab (once !314 lands, its release verb does this with a structured note) |

---

## Reading a brief

```bash
pl session brief                 # markdown, read-only
pl session brief --recompute     # also forces GitLab to recompute stale merge status (a WRITE)
pl session brief --format=json   # for tooling
```

**The generated / prose split.**

*Derived* — every figure below carries the command that produced it and the UTC
moment it was read:

- git: branch, HEAD, `origin/main`, ahead/behind
- issue queue: `pl issue ls` (see truncation, below)
- open MRs: iid, title, branch, draft flag, **merge status**
- fleet RAG: RED/AMBER/GREEN/UNSCANNED + the rollup's age
- staged demo goldens: site, `captured_utc`, db sha prefix
- forge-enforced holds: Draft MRs
- bounds in force: each bound and whether it is actually armed

*Prose* — one quarantined section at the **end**, carried from the previous
baton, every line stamped **UNVERIFIED**. It is a list of leads, not premises.

### Three honesty rules the brief enforces

1. **BLIND is not empty.** A section that could not be read says so.
   `MR-BLIND` ≠ "no open MRs". A host provisioned with only
   `gitlab.ops_note_token` (Reporter on nwp/ops) gets `404` on nwp/nwp — which is
   the `ai-host`'s state today, so its MR section is blind and says so, loudly.
2. **TRUNCATED is not complete.** `pl issue ls` on `main` reads one page of 100
   and nwp/ops is at that cap. The brief warns until `!320`
   (`fix/issue-ls-truncation`) merges, then detects the paginating verb and
   drops the warning with no code change.
3. **A stale conflict is a claim, not a finding (ops#213).** This forge reports
   `cannot_be_merged` for branches that merge cleanly. The brief renders those
   as `cannot_be_merged?(STALE-SUSPECT…)`; `checking`/`unchecked` are retried,
   not read as failure. `--recompute` issues `PUT …/rebase` to force a real
   answer.

---

## The bounds, and how each is enforced

An unattended session may **read anything, fix, push, and open MRs**.

| Bound | Enforced by | Escape |
|---|---|---|
| No merging sensitive paths | **GitLab Draft** — the forge refuses the merge. `pl session guard mr <iid>` computes the diff's paths and Drafts the MR if any match. | A human reads it and un-Drafts |
| No live writes outside the demo tier | Local refusal in `session_guard_live`. Demo tier = `nwd ssd`. Unknown site or tier → refuse. | `NWP_SESSION_DEMO_SITES` (deliberately, not in passing) |
| **No prod writes, ever** | Refused outright, whatever the site. prod belongs to `ver`. | none |
| Same failure twice → STOP | `failures.tsv` ledger, checked **before** anything is spent | clear the signature |
| Token ceiling | `claude -p --max-turns` (structural) + a transcript tally (real) | `NWP_SESSION_TOKEN_CEILING` |
| Operator must be reachable | `pl notify health` preflight; **refuses to launch** if Gotify is dead | `NWP_SESSION_ALLOW_NO_NOTIFY=1` |

**Prose holds do not work.** On 2026-08-02 a hold recorded in a document was
overridden by its own author's sweeper within minutes. The brief's "Holds"
section therefore lists *only* forge-enforced holds. If it is not in the forge,
it is not a hold.

**The sensitive list is compiled, not copied.** It is the union of the
agent-loop's live `SENSITIVE_PATH_RE` and the bullet list under *Sensitive File
Paths* in `CLAUDE.md`, parsed out of the document at run time. Adding a bullet to
`CLAUDE.md` widens the enforced gate with no code change. If **either** source is
unreadable the gate refuses everything — half a rule set is not a rule set.

---

## Install the SessionEnd hook

`pl session end` is called automatically when a session terminates. Add to
`~/.claude/settings.json` (it composes with the existing issue-summary hook —
Claude Code runs every matching hook):

```json
{
  "hooks": {
    "SessionEnd": [
      { "hooks": [
          { "type": "command", "command": "$HOME/.claude/hooks/issue-summary-on-end.sh" },
          { "type": "command", "command": "$HOME/nwp/scripts/hooks/session-end-baton.sh" }
      ]}
    ]
  }
}
```

A clean exit flips the baton to `READY`; anything else flips it to `ABANDONED`,
so the next reader is told to re-derive rather than trusting a partial handover.
The hook can never fail a shutdown.

---

## What the handover records

Four things the next session cannot reconstruct on its own:

1. **Status** — clean or not
2. **In flight** — branch, ahead/behind `origin/main`
3. **HELD, and why** — the Draft MRs, or `UNKNOWN` if the forge could not be read
4. **UNVERIFIED** — claims this session did not check

---

## Tests

```bash
bats tests/unit/test-session-baton.bats \
     tests/unit/test-session-bounds.bats \
     tests/unit/test-session-brief.bats \
     tests/unit/test-session-supervisor.bats
```

95 cases. Per ops#214 every guard has a **red-proof** — a test that makes it
fire — beside a paired positive that makes it allow. A guard only ever observed
saying yes is not a guard.

The anti-staleness proof is the `MUTATION` group: change a fact in the estate,
regenerate, assert the brief moved with it.
