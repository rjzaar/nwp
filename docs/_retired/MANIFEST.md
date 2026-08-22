# Retired documents — MANIFEST

Generated and maintained by `pl docs retire` / `pl docs restore` (ops#383).
**Do not hand-edit.** Every row below is a document that was measured dead and
moved — never deleted. The file still exists, at `retired to`, at the byte
content whose `sha256` is recorded here, and `restore command` puts it back.

| # | status | original path | kind | retired | restored | ref | sha256 | retired to | restore command | reason |
|---|--------|---------------|------|---------|----------|-----|--------|------------|-----------------|--------|
| 1 | retired | `docs/COMMAND_INVENTORY.md` | file | 2026-08-22 | — | ops#383 | `b15d52d7327b480fb25752e7b36b87c3b2a9df20649e6260b109ee0bcca3c99c` | `docs/_retired/2026-08-22-command-inventory/docs/COMMAND_INVENTORY.md` | `pl docs restore docs/COMMAND_INVENTORY.md` | hand-maintained inventory: 55 of 119 verbs (blind to 64), and its own banner says "Do not trust this inventory ... should be replaced by a generated listing". Superseded by `pl commands` / `pl commands --json`, whose completeness is proven by tests/unit/test-todo-checks.bats. |
| 2 | retired | `docs/reference/commands` | dir | 2026-08-22 | — | ops#383 | `tree:d3ec2d5f47432531c4d1795706d7387f84e8fe216c3e1ed44da421fce2bcfb9f` | `docs/_retired/2026-08-22-command-reference/docs/reference/commands` | `pl docs restore docs/reference/commands` | 48 hand-written pages covering 46 of 119 verbs (38.7%); test-nwp.md documents a verb that no longer exists, and the pages predate the 2026 guard flags. Superseded by the generated listing: `pl commands`, `pl commands --json`, and each verb`s own --help. |
| 3 | retired | `pl-completion.bash` | file | 2026-08-22 | — | ops#383 | `3c21fcc5c1c361b5c558d94c25891ab37b4febe60f74552ce5ab08d4fb4b6a92` | `docs/_retired/2026-08-22-pl-completion/pl-completion.bash` | `pl docs restore pl-completion.bash` | hand-written completion list: 44 tokens, 40 real verbs of 119 (blind to 79), and it offers four verbs that DO NOT EXIST — test-nwp, security-update, security-audit, coder. One commit ever, 2026-04-07. Superseded by the generated inventory `pl commands --json`. |
