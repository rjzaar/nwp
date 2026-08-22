# Command Reference

**The command reference is generated, not written.** There is exactly one list
of what `pl` can dispatch, and `pl` itself is the one that holds it.

| What you want | Command |
|---|---|
| Every verb, with a one-line synopsis | `pl commands` |
| The same thing, machine-readable | `pl commands --json` |
| The guided tour plus the generated list | `pl help` |
| Everything one verb can do | `pl <verb> --help` |

Each synopsis in `pl commands` is read out of the command's own file header, so
a verb cannot exist without appearing here and cannot be renamed without the
listing following it. `pl doc-truth`'s `dead-command-ref` rule uses the same
list as its oracle: any doc in this repo that writes `pl <verb>` for a verb
that does not exist fails the gate.

## Why there are no per-command pages any more

There used to be 48 hand-written pages under `docs/reference/commands/`. On
2026-08-22 they were measured: they covered **46 of 119 verbs (38.7%)**, one
page (`test-nwp.md`) documented a verb that no longer exists, and the surviving
pages predated the 2026 guard flags — so the pages that were *not* missing were
in several cases wrong about the flags that keep a live deploy safe. A
73-verb blind spot in the document people are pointed at for "what can I run?"
is worse than no document, because it is read with the repo's authority.

Two other hand-maintained inventories were retired in the same pass, for the
same reason:

- `docs/COMMAND_INVENTORY.md` — 55 of 119 verbs, and its own banner already
  said *"Do not trust this inventory … should be replaced by a generated
  listing."*
- `pl-completion.bash` — 40 real verbs of 119, plus four completions for verbs
  that do not exist (`test-nwp`, `security-update`, `security-audit`, `coder`).
  One commit, ever, on 2026-04-07.

**Nothing was deleted.** All three were retired with `pl docs retire`, which
moves rather than removes:

```bash
pl docs retired --list          # what was retired, when, why, and its sha256
pl docs restore docs/reference/commands   # put it back if this was a mistake
```

The bytes are in `docs/_retired/2026-08-22-command-reference/`, indexed by
[`docs/_retired/MANIFEST.md`](../_retired/MANIFEST.md).

## If you want a page back

Retiring is reversible by command, not by archaeology. If a specific page was
carrying weight — a worked example, a migration note — the right move is
usually not to restore the whole directory but to fold that content into the
verb's own `--help` (which is what people actually read) or into the relevant
guide under [`docs/guides/`](../guides/), where `pl doc-truth` checks it.

## Tab completion

`pl-completion.bash` is retired and is no longer sourced by `pl help`. If you
want completion, generate it from the live inventory rather than maintaining a
second list:

```bash
complete -W "$(pl commands --json | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')" pl
```
