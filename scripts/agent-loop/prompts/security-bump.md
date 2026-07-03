## Task shape: composer security bump

This repo is a **composer project root** for one NWP site. The linked issue
(usually a `[RAG]` auto-issue from `pl rag --sync-issues`) reports open
`composer audit` security advisories. Your ONLY job is to clear as many of
those advisories as possible with the smallest dependency movement.

### Procedure

1. `composer audit --format=json` (fall back to plain `composer audit`) —
   record which packages carry advisories and the fixed-in versions.
2. For each advisory package, bump minimally:
   `composer update <vendor/pkg> --with-dependencies`.
   Prefer patch/minor movement within the existing constraints.
3. Only touch `composer.lock` — and `composer.json` ONLY if an advisory is
   unfixable within the current constraint AND the constraint change stays
   within the same major version. NEVER jump a major version; if the only
   fix is a major bump (or a pinned fork blocks the update), write
   `AGENT-NOTE.md` explaining exactly what blocks it and stop.
4. Do NOT edit application code, config, or scaffold files. If
   `composer update` rewrites scaffold files as a side effect, that is
   acceptable; anything else is out of scope.
5. Re-run `composer audit` — the advisory count MUST go down. Put the
   before/after audit summary in the commit message body.
6. `composer validate --no-check-publish` must pass.

### Constraints

- One commit, lockfile-focused, message form
  `[agent-loop] fix(issue-<iid>): security bump <pkg list>`.
- If ANY advisory remains after your bump, say so explicitly in the commit
  body (count before → after) — the reviewer must see the residue.
- No new dependencies, no removals, no `composer require`.
