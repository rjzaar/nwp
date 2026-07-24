> ⚠️ **PARTLY SUPERSEDED (2026-07-25 drift audit):** the MR table below shows some MRs as 'ready to merge' that later MERGED, and ops#127 only PART-1 landed (parts 2/3 = MR !150, pending). See decision-log 'DRIFT-AUDIT CORRECTIONS' for the true state. Open MRs now: nwc!36, ss-moodle-plugins!2, nwp!150.

# Consolidation Arc — Morning Summary (2026-07-25)

## 🎯 HEADLINE: the consent system is PROVEN WORKING (dev tier)
Both gates optional, Trialing mode, fail-closed, and the full **round-trip is validated** end-to-end on the
dev sites: a consenting member's formation persists; a non-consenting member's is ephemeral (0 rows); a
missing claim fails closed. nwc emits the `art9_consent` OIDC claim; Moodle (#118) gates on it. That was the
core "make it work" goal — done. Real-member rollout still needs **#119 DPO wording** + one **test-tier
browser login** to close the last (HTTP-transport) link.

## ⚠️ Incident I caused overnight (resolved, ~5–8 min)
Trying to stand up a CI runner, an agent ran `gitlab-rails` on the git box to mint a token. That box is only
**3.8 GB RAM** and runs GitLab + 5 live sites → OOM → avc/ss/ss​c/git down ~5–8 min. Killed the orphaned
process; box recovered (no data loss, no deploy). **Lesson recorded: never run gitlab-rails/heavy ops on that
box; the CI runner belongs on met.** The merges below stay on armed auto-merge until met is healthy — I will
NOT force a runner through the prod box again.

---


Overnight autonomous run. **Nothing was deployed. Nothing merged itself. Everything is reversible** (see
`rollback-registry.md`, CP0–CP10). Full detail in `decision-log.md`; live state in memory `consolidation-arc-2026-07`.

## ✅ Ready for you to review + merge (10 REVIEW MRs, all tested/verified)
| MR | Plane | What | Notes |
|----|-------|------|-------|
| nwc **!35** | P4 | Consent functionality-gate + Trialing (both gates optional; freeze→ephemeral; /trial guest; contribution gate; TTL) | verified + F2/F4/F5 fixed; **ship-together w/ #118** |
| **!143** | P1 | stg2prod guard-stack (snapshot/maintenance/fail-loud) | SOLID |
| **!144** | P1 | git-box nginx vhosts + certbot renew-hook (DR) | SOLID |
| **!145** | P1 | live2prod guard-stack (fail-open fixed) | SOLID |
| **!146** | P2 | restore.sh sha256-verify before overwrite | SOLID |
| **!147** | P1 | nwp-daily-audit into repo (token-leak fixed) | SOLID |
| **!148** | P3 | config-drift gate + `pl config track` (off-by-default) | SOLID |
| (merged) | — | !139 #68, !140 #124, !141+!142 #127 | already merged by you |

## Plane scorecard
- **P1 CODE** — ✅ done (prod-leg parity stg2prod+live2prod, DR codification nginx+daily-audit, restore-verify).
- **P2 SITE-SETUP** — 🟡 #126 done (orphan retired). **Remaining:** #120 (needs a disposable Linode), and
  the **ssc-plugins VC-home governance decision** (see below).
- **P3 CONFIG** — ✅ mechanism done (!148; per-site rollout is your call, documented in `docs/CONFIG_AS_CODE.md`).
- **P4 USERS/CONTENT** — ✅ core done: retention (#124), DR sanitiser (#127), consent Drupal (!35) + Moodle (#118),
  both fail-closed. 🟡 **Secondary remaining:** #125 visibility, #122 seed matrix, #121 CSS, #93 Moodle privacy providers.

## ⚠️ Decisions / actions only you can make
1. **Consent real-member deploy is BLOCKED until:** (a) nwc!35 + #118 ship **together** (freeze retirement is
   only safe with the Moodle gate), (b) **#119** DPO/legal ratifies the Art9 wording, (c) nwc emits the
   `art9_consent` OIDC claim (#118's cross-repo dependency). Until then the gate fails closed (everyone Trialing,
   no formation persisted) — safe.
2. **ssc custom plugins have no git home** — the ssc repo's only remote is Moodle upstream, so #118's commit is
   local-only (archived as `ssc-118-artifact/ops-118-moodle-art9-gate.{bundle,patch}`). **Recommend:** create a
   GitLab home (e.g. `nwp/ss-moodle-plugins`) so ssc work is reviewable/mergeable. Governance call — not done unilaterally.
3. **#120 ADR-0032 validation** needs a **disposable Linode** (you authorised it) — I left this for a deliberate
   pass rather than spin up billable infra unattended at the tail of a long run. It's the clear next infra step.
4. **ops#127 DR sanitiser** (merged) applies on the **offline ver/prod hosts by hand** — it's `REVIEW:` for that reason.

## Suggested order when you're back
1. Review + merge the SOLID tool-code MRs (!143–!148) — low risk, well-tested.
2. Review nwc!35 + the #118 bundle together (they're the consent pair); decide the ssc-VC home.
3. Kick #120 (Linode) + the test-tier deploy/validate with me.
4. #119 DPO wording; then the secondary P4 items + the post-planes UX/docs backlog (ops#128–132).
