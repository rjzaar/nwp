# Handover — ops session hooks (read-first in, session-summary out)

**Date:** 2026-06-28 (generalised: mechanism/config split, global scope)
**Author:** rjzaar + Claude Code
**Scope:** This machine, **all directories** — registered in user-level
`~/.claude/settings.json`. The *mechanism* is generic and reusable; the *config* is
private to this host.

## Purpose

Tie an operational session to its `nwp/ops` GitLab issue, mechanically, in both
directions:

- **Context in** — when a prompt references `(nwp/)?ops#N`, inject the current
  `~/central/nwc-internal/OPERATING-MODEL.md` into context for that turn. So
  "Work on nwp/ops#1" is automatically "read the operating model, then work it".
  Re-read fresh on every matching prompt, so edits are always reflected.
- **Summary out** — when the session ends (or you type a `done` keyword), stage/post
  a summary (my closing message + tool-call count + files touched) back onto that
  issue. So decisions and done-state land in the tracker without discipline.

A `UserPromptSubmit` / `SessionEnd` hook is executed by the harness, so this happens
deterministically regardless of model state — unlike a CLAUDE.md instruction.

## Architecture — mechanism vs config (three homes)

| Home | Holds | Pushed? |
|------|-------|---------|
| **`~/claudemax/issue-hooks/`** | the **generic mechanism** (4 scripts, installer, README, env example) — zero hard-coded paths | yes (public-generic repo) |
| **`~/central/nwc-internal/hooks/issue-hooks.env`** | the **private config** (which file/pattern/tracker/token) — symlinked to `~/.claude/issue-hooks.env` | no (local-only) |
| **`~/cod/entries/ops-session-hooks/`** | dashboard entry tracking that this host has it wired (`cod check ops-session-hooks` → `ok`) | (machine registry) |

The scripts are *installed* to `~/.claude/hooks/` (from claudemax) and read their
particulars from `~/.claude/issue-hooks.env` (→ central). No private path or URL lives
in claudemax; no secret lives in central (only a token-*fetch* command).

## Scripts (installed in `~/.claude/hooks/`)

| Script | Event | Role |
|--------|-------|------|
| `inject-readfirst.sh` | `UserPromptSubmit` | Inject `READFIRST_FILE` when prompt matches `READFIRST_PATTERN` |
| `issue-summary-on-keyword.sh` | `UserPromptSubmit` | On a bare `done`/`wrap up`, stage/post a mid-session summary |
| `issue-summary-on-end.sh` | `SessionEnd` | One-time summary when the session terminates |
| `issue-summary-core.sh` | (library) | Shared render-from-transcript + stage/post |

## Config keys (`~/.claude/issue-hooks.env` → central)

```
READFIRST_FILE      $HOME/central/nwc-internal/OPERATING-MODEL.md
READFIRST_PATTERN   (nwp/)?ops#[0-9]+
ISSUE_PATTERN_PY    (?:nwp/)?ops#([0-9]+)        # python regex, 1 capture group = id
ISSUE_TRACKER_BASE  https://<gitlab-host>
ISSUE_PROJECT_ID    21                            # nwp/ops
ISSUE_TOKEN_CMD     yq e '.gitlab.ops_note_token // ""' "$HOME/nwp/.secrets.yml"
SUMMARY_KEYWORDS    /?done|wrap[[:space:]]?up
ISSUE_AUTOPOST=1    # LIVE — see Safety below
```

> **NB on `ISSUE_TOKEN_CMD`:** it must *print* the token to stdout. `pl secrets get`
> copies to the clipboard rather than printing, so the config reads `.secrets.yml`
> directly with `yq`, and uses the **least-privilege `ops_note_token`** — never the
> admin `gitlab.api_token`.

## Event semantics (the "exit" question)

- `SessionEnd` fires **once**, only on real termination: `/exit`, Ctrl-D, `/clear`,
  logout. Typing the word **`exit` as a prompt is a normal message** — it does *not*
  end the session, so it fires nothing. `Stop` was rejected (fires every turn).
- `done` keyword: only a **bare** trimmed keyword triggers; prose like "are we done
  yet?" does not. It uses `--trigger manual` → a distinct ledger key (`…:ops#N:manual`)
  and filename, so it never blocks the later `SessionEnd` summary and refreshes each
  time you re-checkpoint.

## Safety

- **LIVE since 2026-06-28 (`ISSUE_AUTOPOST=1`).** The linchpin token is wired:
  `ops_note_token` is a **GitLab project access token scoped to nwp/ops only**
  (verified: it can see project 21 and nothing else), scope `api`, role Reporter+,
  expires 2027-06-26 — distinct from the admin PAT. Summaries now POST for real.
  If the token read ever returns empty, the core safely falls back to staging in
  `~/.claude/ops-pending-summaries/` rather than posting.
- **No secret in config** — `ISSUE_TOKEN_CMD` fetches the token at run time; it's used
  only in the request header, never logged.
- **Idempotent** per session+issue (ledger `~/.claude/ops-session-posted.log`).
- **`settings.json` is hand-managed.** claudemax's `setup-*` only writes settings when
  the file is absent, so a re-run won't disturb the wiring.

## Verify / test / re-install

```bash
cod check ops-session-hooks                       # → STATE: ok …
~/claudemax/issue-hooks/setup-issue-hooks.sh      # re-install scripts from claudemax
jq -r '.hooks.UserPromptSubmit[0].hooks[].command, .hooks.SessionEnd[0].hooks[].command' ~/.claude/settings.json

# read-first injection
echo '{"prompt":"Work on nwp/ops#1"}' | ~/.claude/hooks/inject-readfirst.sh | head
echo '{"prompt":"fix a typo"}'        | ~/.claude/hooks/inject-readfirst.sh   # silent
```

Hooks load at session start — restart Claude (or `/hooks`) to pick up wiring changes.

## Disable

Remove the three references from `~/.claude/settings.json` (or toggle via `/hooks`).
To strip entirely, also delete the four scripts from `~/.claude/hooks/` and the
`~/.claude/issue-hooks.env` symlink.
