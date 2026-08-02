# miniterm — watching agent sessions on the `ai-host`

The **`ai-host`** is the durable agent host. Long agent runs live in tmux there so they
survive a disconnect — the dev laptop crashed mid-operation on 2026-08-02 and
killed seven running agents; the `ai-host` had 35 days of uptime at the time.

`miniterm` is the operator's way in.

## Install (dev workstation, one time)

    ln -sf "$HOME/nwp/scripts/bin/miniterm" ~/.local/bin/miniterm

The SSH alias for the `ai-host` is resolved from the operator's private
instance manifest (override with `NWP_AI_HOST_SSH`); it is deliberately not
written into the repo — see `docs/reference/role-vocabulary.md`.

## Use

    miniterm              interactive picker
    miniterm --help       key reference
    pl ai-host sessions      plain list, scriptable
    pl ai-host attach nwp    attach directly (read-only)
    pl ai-host attach nwp --write

## Read-only by default — and why

Attaching read-**write** to a session where an agent is working means your
keystrokes go into its prompt. One stray keypress injects input into a task
mid-flight. `miniterm` attaches with `tmux attach -r` unless you explicitly
choose write mode, which warns first.

## Inside tmux

| keys | effect |
|---|---|
| `Ctrl-b` `d` | detach — the session keeps running on the host |
| `Ctrl-b` `[` | scrollback (arrows/PageUp, `q` to exit) |
| `Ctrl-b` `w` | list windows, pick one |
| `Ctrl-b` `n` / `p` | next / previous window |
| `Ctrl-b` `?` | tmux's own key list |

**Gotcha:** tmux sizes the display to the *smallest* attached client, so
attaching from a phone shrinks it for everyone. Read-only attach avoids most
of this; `tmux attach -d` evicts other clients.

## Three states, never two

`pl ai-host sessions` distinguishes **sessions** / **none** / **UNREACHABLE**
(exit 3). "Could not look" must never render as "nothing is running" — that
conflation is the failure class tracked in ops#214.

## See also

- `docs/guides/durable-agent-host.md` — what the `ai-host` holds, and what it must never hold
- `pl ai-host llm health` — the LLM stack on the same host
