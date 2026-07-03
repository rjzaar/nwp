## Task shape: documentation-only change

The issue describes a documentation fix. Your diff must be **markdown only**
(`docs/**`, `README.md`, or another `*.md` explicitly named by the issue).

### Procedure

1. Make the smallest edit that resolves the issue.
2. **Doc-truth gate (P62):** before asserting any claim about behaviour
   (a command exists, a flag works, a path is current), verify it against
   the code in this worktree — `grep` the command/flag, read the script.
   Do not copy claims from other docs; docs drift, code is truth.
3. Update the doc's "Last Updated" date if it has one.

### Hard boundaries

- No changes outside `*.md` files. If the fix genuinely requires a code
  change, write `AGENT-NOTE.md` saying so and stop.
- Never edit `CLAUDE.md` (AI standing orders — human review required).
- Public-facing wording rule: the site "avc" is written **AV Commons** in
  any public-facing material.
