# NWP deep audit — Researched Recommendations (2026-07-09)

Companion to `nwp-deep-audit-2026-07-09.md` (the findings). For each finding: the recommended action,
the *researched* rationale (with sources), the options weighed, and effort/risk/priority. Assembled
from five parallel web-researched streams; appended as each lands. **Nothing changed — analysis only.**

Streams: ① security/mons/tokens/keys · ② nwc auth "next P73s" · ③ bash tooling · ④ leakage/gitleaks/
consistency (below) · ⑤ docs/ADRs + the overall prioritised roadmap (capstone).

---

# ④ Public/private divide, leakage hygiene & consistency

## C3 · Live gotify token on the public GitHub mirror
**Recommend (all three, in order):** (1) **rotate `gotify.mini_health_token` now** — mandatory
regardless of any history surgery; (2) then decide history — the clean path is the **P61 §3
single-fresh-commit rebuild** of the mirror (already the recorded operator strategy), else
`git filter-repo --replace-text` on a fresh clone + force-push; (3) **enable GitHub push-protection +
secret-scanning** so the next one is blocked server-side.
**Why:** GitHub's own guidance — scrubbing HEAD ≠ removing from history; **rotation is the primary
mitigation**, history rewrite is cosmetic and *cannot* reach forks/clones/cached PR views. A verified
leak is a rotate-within-hours P1.
**Options weighed:** rotate-and-accept-history (lowest risk, string is inert once rotated — recommended
given the bounded blast radius) · filter-repo (removes from *your* history only, breaks sigs/PR diffs,
incomplete) · take-mirror-down (over-reaction; the mirror is a release deliverable).
**Effort:** rotate ~10 min; rebuild ~1–2 h. **Priority: P0 rotate-now; history = P2 operator choice.**

## `.gitignore` whitelist gap (secret-shaped files trackable)
**Recommend:** append, at the very end (last-match-wins, *after* all `!…/**` whitelists):
`**/*.pem`, `**/*.key`, `**/id_rsa`, `**/id_ed25519`, `**/*credential*`, `**/*.env`, `**/*.sql`,
`**/*.sql.gz`. Verify each with `git check-ignore -v` resolves to a *denial*.
**Why:** git resolves ignore by **last-matching pattern**; the current `!docs/** !lib/** !tests/**
!bin/**` negations are the *deciding* rule for `docs/foo/id_rsa`, `lib/x/credentials.txt`,
`tests/x/prod.pem`, `docs/x/dump.sql[.gz]` — all trackable today (verified). Denies *after* the
whitelists flip the last match. The `*.sql`/`*.sql.gz` lines also close the consistency gap (no global
dump deny; inconsistent with the `.claude` `**/*.sql` read-deny) and would have caught the raw
`mayo-live-*.sql.gz`.
**Options weighed:** deny-after-whitelist (recommended, matches the documented idiom) · per-subtree
denies (easy to miss a subtree) · gitleaks-only (rejected — scans content not filenames; a binary key
or `.sql.gz` may not trip a content rule; want both).
**Effort ~5 min. Priority: P1, safe-to-do-now** (ignore rules only, no gate semantics).

## `.gitleaks.toml` whole-subtree, all-rule allowlists (H9)
**Recommend:** (1) **delete** the blanket `docs/reports/**`, `docs/archive/**`, `tests/**` entries
(lines 27,61,66) — they exempt those trees from **every** rule incl. credential rules (the root cause
of the doc leaks); (2) re-express each legit exemption as **per-rule/hostname** allowlists (as the
file already does for `operator-home-path`/`internal-hostname-fqdn`); (3) for `tests/`, allowlist only
specific fixture files (or use `stopwords`) so a real key in a new test still trips; (4) **add a
raw-IPv4 rule** (gitleaks has none — the prod IP is ungated) with an RFC1918/CGNAT/TEST-NET allowlist
(regex provided in the stream output).
**Why:** fail-safe defaults / economy of mechanism (Saltzer & Schroeder) — a broad exclusion "tends to
fail by allowing access, a failure which may go unnoticed." The subtree allowlist silences *hostname*
false-positives but silently disables *credential* detection there. Per-rule allowlists keep the
credential floor.
**Options weighed:** per-rule allowlists (recommended) · a second credential-only gitleaks pass with no
path allowlist (two configs to maintain) · status quo (the demonstrated root cause).
**Effort ~1–2 h (retune via baseline mode). Priority: P2, operator-gated** (edits a security gate).

## P61 leakage-hygiene CI unshipped (H7)
**Recommend the documented four-gate model** (not the single incremental gate): **Gate 1** pre-commit
gitleaks (`protect --staged`, authored, *install it*) **+ a server-side `pre-receive` hook** (pre-commit
is `--no-verify`-bypassable); **Gate 2** the existing diff-scoped CI job (`base..HEAD`,
`allow_failure:false`) — **keep it and wire `main` branch protection to require it**; **Gate 3** a
**scheduled (weekly) full-history trufflehog `--only-verified`** run — the layer that says which
historical secret is *still live* and must be rotated (how C3 should have been caught); **Gate 4**
GitHub push-protection + secret-scanning on the mirror. Roll out in **baseline mode** (record the ~30
legacy IP hits + fixtures to `.gitleaksignore`, then enforce only-new) so legacy findings don't wedge
the gate.
**Why:** 2025–26 consensus is a layered gates model; **full-history-on-every-PR is an explicit
anti-pattern** (slow, noisy — it was the prior timeout cause), so history belongs on a schedule with a
*verifying* scanner (trufflehog). Pre-commit must be paired with a server-side hook. Baseline mode is
the documented adoption tactic to avoid false-positive fatigue.
**Effort:** pre-commit+branch-protection ~30 min; pre-receive ~1–2 h; scheduled trufflehog ~1–2 h.
**Priority: P1** (branch-protection + pre-commit safe-now; trufflehog + pre-receive operator-gated).

## Prod IP + Mazenod/RE + operator PII in published docs (H7/H8)
**Recommend:** (1) scrub `97.107.137.88` → role label / `<gitlab-host>` in the named tracked docs
(`roadmap.md:622`, `milestones.md:427`, F15/F16/F17/P59, `deploy-on-merge.sh:235`, `site.sh:143`,
`tests/fixtures/cnwp.yml`); (2) scrub **Mazenod/RE** from the two *published* reports
(`nwp-executive-summary-2026-03-10.md`, `nwp-landscape-analysis-2026-03-12.md`) — a standing-rule
violation, not a judgment call; (3) run the **F34 role-vocabulary sweep** repo-wide as the systematic
pass; (4) **unpublish** (keep out of the tracked tree) the two root handover docs + `example.nwp.v2.yml`.
**Why:** fail-safe defaults — operator infra identifiers should default to *absent* from the public
tier (ADR-0021). The prod IP is the highest-value leak (it locates the box hosting GitLab + live test
sites); a role label is equivalent for readers, non-actionable for an attacker. Doing F34 *before*
tightening gitleaks lets the subtree allowlists be *deleted* (they exist only to hide these strings) —
collapsing two workarounds into one clean state.
**Effort:** named files ~1 h; full F34 sweep ~half-day. **Priority: P2, operator-gated** (paired with
the gitleaks rewrite).

## Consistency — standardise the fail-closed pattern (the highest-leverage structural work)
**Recommend four single-definition choke points, route every caller through them:** (1) **one shared
deploy-preamble** (`lib/deploy-preamble.sh`) — `set -euo pipefail` + canonical guard + sanitize/PII-gate
where data crosses a boundary + `nwp_ssh_opts`, called by every deploy/sanitize verb (today applied
unevenly; `server-publish` lacks even strict-mode); (2) **one fail-closed secret accessor** — collapse
`get_infra_secret` vs direct `yq`, refuse non-zero when yq/key absent, handle ≥3-level keys (fixes
ops#70's silent-empty→unauthenticated-curl); (3) **one machine-id `GuildLocator`** (built but
uninjected) replacing label-based lookup (rename ⇒ pool empties ⇒ four-eyes waived); (4) **one
domain-authz choke-point** the ~8 nwc services delegate to (so the empty-pool fallback can't be reused
as a fail-open boolean).
**Why:** the audit's meta-finding is that the fail-closed pattern is applied *unevenly* — exactly the
failure **complete mediation** exists to prevent: "every access to every object must be checked … a
control present in *most* paths provides *no* guarantee" because the attacker routes through the one
path that lacks it (the retrospective S&S analysis of SolarWinds/Log4j found the missing principles were
precisely fail-safe-defaults/economy-of-mechanism/complete-mediation/least-privilege). Consolidating each
control into a **single definition** is economy-of-mechanism (the security analogue of DRY): one place
to audit, one place a fix lands everywhere, no divergent copies to drift fail-open. This is why
consistency-of-the-pattern outranks any single bug fix — fixing one `sanitize` call-site leaves three
siblings fail-open; routing all four through one preamble closes the *class*.
**Options weighed:** four choke-points + mechanical routing (recommended — closes classes) · fix each
call-site in place (what's been happening; why P73 fixed 1 of 9 and the sanitizer has 4 implementations)
· lint-only (a useful *backstop* — add a CI grep for `ssh` not via `nwp_ssh_opts` — but can't guarantee
semantics; complements, doesn't replace).
**Effort:** deploy-preamble+ssh ~1 day; secret accessor ~½ day; guild resolver ~1 day; authz choke-point
~2–3 days. **Priority: P1 for the preamble + accessor (they gate the mons step); P1–P2 for the authz
choke-point (Tier 1).**

## `~/central` not backed up
**Recommend:** encrypt-locally-then-replicate, two tiers — (1) **primary:** nightly `git`-mirror + `tar`
+ **`age -p`/`gpg -c` encrypt locally** + `rsync` the *ciphertext* to met over the private mesh (met
never sees plaintext); passphrase stored **out-of-band** (Solo/paper, never in `~/central`); (2)
**secondary:** a **private git remote** on `git.nwpcode.org` for the tracked parts (history/branching);
(3) **test the restore** on a clean checkout.
**Why:** 3-2-1-1-0 — `~/central` today is a single un-replicated laptop disk holding the entire mons
procedure + legal canon + operating model (textbook SPOF). Encrypt-then-rsync is the standard offsite
pattern without exposing plaintext; back up the key out-of-band; verify restores (the "0"). Satisfies
the trust model: never push to public, don't put mons on the mesh — met is on the private mesh, the
copy is ciphertext.
**Options weighed:** encrypted-rsync-to-met + private-git-remote (recommended) · private-git-remote only
(remote holds plaintext — weaker; mitigate with git-remote-gcrypt) · plaintext rsync (rejected — makes
met a full plaintext replica) · any public/SaaS (rejected by the threat model).
**Effort ~2–3 h. Priority: P1, MUST-FIX-BEFORE-MONS, safe-to-do-now** (adds a backup).

## Recommended remediation ORDER (stream ④)
**A. Safe-and-now** (adds protection / removes live exposure; no gate-semantics change): ① rotate the
gotify token (P0) → ② enable GitHub push-protection + secret-scanning → ③ append the `.gitignore`
denies + verify → ④ back up `~/central` (encrypted rsync + restore test) → ⑤ install pre-commit + turn
on `main` branch protection requiring `lint:leakage`.
**B. Operator-gated** (edits a security gate / published content — batch one review): ⑥ rewrite
`.gitleaks.toml` (drop subtree allowlists → per-rule; add raw-IP rule; baseline mode) → ⑦ scrub prod IP
+ Mazenod/RE + PII + run the F34 sweep + unpublish the handover docs & `example.nwp.v2.yml` (do *with* ⑥
so the allowlists can be removed *because* the content is clean) → ⑧ add scheduled trufflehog +
pre-receive hook → ⑨ mirror history decision (prefer P61 fresh-commit rebuild; cosmetic once rotated).
**C. Consistency program** (highest leverage; around the mons blockers): ⑩ ship the deploy-preamble +
fail-closed secret accessor (mons-readiness blockers) → ⑪ machine-id guild resolver + domain-authz
choke-point (Tier 1 "next P73s").

**Sources:** GitHub Docs "Removing sensitive data"; MS Tech Community "safely remove secrets"; BIPI
"Secret Scanning in CI"; AppSecSanta "Gitleaks vs TruffleHog 2026"; Snyk "State of Secrets 2025";
git-scm gitignore docs; Saltzer & Schroeder (Jeremy Jordan / Shostack); arXiv 2211.02341 "Better Call
Saltzer & Schroeder"; GitProtect "3-2-1-1-0"; git-annex gcrypt.

---

# ① Security · mons-readiness · tokens & keys

Graded against NWP's own threat model (AI blast radius bounded to dev/stg/live/CI; "trust flows through
signatures, not machines") and the deploy ADRs (0017/0024/0026). **P0** = before any further mons work;
**P1** = before real-prod cutover; **P2** = hardening. **[OP-CALL]** = genuine operator judgment.

## C0 · Loop armed on dev *and* mini; "paused" is fiction; no infra kill-switch
**Recommend:** (1) correct `OPERATING-MODEL.md`'s false "paused since 2026-05-22" banner **today** —
a safety doc asserting a false state is worse than silence; (2) **remove the loop cron from dev**
entirely (mini is canonical) — a loop sourcing the C1 admin PAT on the authoring workstation is the
single highest-value thing to stop; (3) give the remaining mini loop an **infra-level kill-switch
outside the agent's execution** — `flock` single-instance (ops#37) + a `.loop-paused` sentinel the
**cron wrapper** (not the agent) honours + a dead-man heartbeat.
**Why:** agent-safety practice draws a hard line between a manual kill-switch and a wrapper-enforced
circuit breaker — "without a reliable pause at the infrastructure level, human-in-the-loop is
best-effort; the agent will try to pause unless it's in a state where it doesn't reach the pause logic."
An agent-checked `.loop-paused` is exactly that trap. The loop keeps the C1 token hot every 30 min, so
stopping it on dev is also the cheapest reduction of C1's exposure window.
**Effort low · Risk low · P0 — do first** (free, de-risks everything after). Sources: waxell.ai
kill-switch, nurbak dead-man's-switch.

## C1 & C2 · Two live root-admin GitLab PATs on AI-reachable hosts (dev "nwp-api"; mini "llm_bot")
**Recommend:** **revoke both today** before any downscope design (the token is compromised the moment
an AI process can read it; revocation is instant, reissue is forward-reversible). Reissue as
**least-privilege non-admin bot/service-account** — a project/group access token bound to a dedicated
bot user with **Developer** role and the narrowest scope the loop needs (`read_repository` +
`write_repository`, `api` only if the MR API is genuinely needed and then group-scoped, never
instance-admin). Verify out-of-band via `GET /personal_access_tokens/self` **and** `GET /user`
(`is_admin:false`, correct bot uid — C2 shows the registry *believed* uid 7 while it was minted under
root; trust the API, not the registry). Operator merge/deploy authority lives **only** in a WebAuthn
session, never a file.
**Why:** GitLab's own guidance — "avoid PATs for automation (they inherit the creator's permissions);
use service accounts with limited permissions"; a project access token's bot user "cannot be added to
any other group or project" → blast-radius-bounded by construction. "Rotate first" is the universal
incident rule. **ADR-0024 makes this the precondition for the whole self-deploying-prod model** ("no
`api`/`Maintainer` token on any AI-reachable machine … without this, merge-rights=deploy-authority is
hollow"). This is MUST-FIX-BEFORE-MONS blocker #1.
**Options:** downscope-in-place — **rejected** (GitLab PAT scopes can't be narrowed after creation, and
the value is already AI-exposed → must reissue). **Effort low-med · Risk low (brief loop outage) · P0
blocker #1.** Sequence: revoke *before* C0's loop re-enable; enroll WebAuthn same session.

## C1/C2 companion · Enforce WebAuthn/FIDO2 (Solo 2C+) on the GitLab admin account
**Recommend:** enroll **two** Solo 2C+ keys (daily + offsite backup) as WebAuthn authenticators + a TOTP
recovery factor; enable "Require administrators to enable 2FA" with **zero grace**. Authority moves from
a file-borne token to a hardware-gated session.
**Why:** GitLab 16.8+ supports admin-scoped 2FA enforcement; WebAuthn requires a physical device (email
OTP doesn't satisfy it). Two caveats: **no recovery codes for WebAuthn** → a backup OTP *and* a second
enrolled Solo are mandatory (FIDO2 keys can't be cloned); **access tokens bypass 2FA by design** →
which is exactly why C1/C2 must be *revoked*, not merely supplemented. Solo's *reliable* NFC capability
is WebAuthn (ADR-0024's own finding), so this uses the hardware for what it does well.
**Effort low · Risk low · P0 blocker #2** — same session as C1/C2 revocation.

## C3 · Live gotify token in public-mirror history *(cross-ref stream ④ C3)*
**Recommend (this stream concurs):** **rotate now** (generate new Gotify app token, update
`.secrets.yml` + consumers, delete old server-side). History-scrub is *optional cleanup*; for a
throwaway mirror the cleanest is delete/re-create from a filtered clone, not a force-push rewrite.
**Why:** unanimous rule is rotate-first, rewrite-second — "neither BFG nor filter-repo makes an
already-exposed credential safe; once pushed, consider it compromised"; rewrite changes hashes, removes
signatures, risks recontamination, and can't reach forks/caches. Bounded blast radius (notification POST
only, mesh host) is *why* rotation alone suffices. **Effort low · Risk low · P0.** [OP-CALL]: whether to
also scrub after rotating.

## C4 (+H3) · Minisign secret key on the AI-reachable disk; and the routine prod path doesn't verify
**Recommend two coupled actions.** **(a) Custody:** target = hardware-held key (Solo FIDO2 hmac-secret),
but stage it — *now* (P0): confirm the key is **passphrase-encrypted at rest** (one agent saw it
passwordless — verify/fix first), **delete the stray `~/nwp-ops23/keys/minisign/` copy**, move the
canonical key to a non-repo restricted path, write the missing **rotation/compromise runbook**;
*before real-prod* (P1): move signing to an **offline/air-gapped ceremony** or formally record
"software key = interim accepted-risk trust root" as an ADR note with an expiry + escalation trigger.
**(b) Verify-then-apply (H3, ops#52):** the canonical routine-prod path is a **bare `git pull` +
`pl stg2live` with no signature check** → a GitLab compromise ships to prod unverified. Route the
routine path through `nwp-server`'s `pull+verify` verb so the signature chain is actually *checked* on
the routine path, not just the escalation path.
**Why:** this key *is* the trust root ("a compromised AI session on dev can sign kits mons will
accept"); `lib/minisign.sh` self-labels "software interim." Best practice is unambiguous hardware
custody (private key non-exportable). H3 is ADR-0017's load-bearing property — "trust flows through
signatures, not machines"; a runner that pulls-and-applies without verifying discards exactly that.
ADR-0024 lists "no offline signature re-verification" as a residual risk, acceptable *only* if the
routine path still verifies at all.
**Effort:** interim-custody low-med, hardware ceremony med-high, verify-then-apply med · **P0 for
interim custody, P1 for hardware + verify-then-apply.** [OP-CALL]: hardware-Solo now vs
passphrase-software-key + offline ceremony (recommend staging — building Solo signing under time
pressure risks a broken pipeline right before mons).

## C2/H1/H2/H5/H6 cluster · Sanitizer + PII-gate fail *open* *(cross-ref stream ③ Cluster 4)*
**Recommend (both streams converge):** convert sanitize→gate from fail-open to fail-**closed**,
unconditional on every trust-boundary crossing: (1) land MR!47 / patch `main` so
`prod2stg`/`live2stg` sanitize+PII-gate by default (today `main` imports raw prod PII, `grep -c
sanitize`→0 — pre-P67 behavior); (2) fix `sanitize_staging_db` (`database-router.sh:445-493`) —
stop swallowing `2>/dev/null`, check exit codes, refuse to print "sanitized" on a non-Drupal schema
where the lone anonymize query silently no-ops; (3) fix the `pii-gate.sh:103-109` PIPESTATUS bug (a
truncated `.gz` scans CLEAN — the *last* backstop before publish); (4) route data-crossing verbs
through one shared deploy-preamble; (5) relocate the raw live mayo DB
(`sites/mayo/backups/mayo-live-20260412.sql.gz`, 112 MB) off the AI dev box.
**Why:** masked data must be the *only* permitted downstream input; "if in doubt, remove PII entirely."
A gate returning "clean" on a decompress error is textbook fail-open — defeats defence-in-depth exactly
when input is anomalous. ADR-0017 calls the sanitizer "security-critical"; ADR-0026 makes the
fail-closed PII gate a mandatory `nwp-server publish` step. **CLAUDE.md: sanitizer changes are
human-review-only** (these tighten, but still merit auth-code scrutiny). **Effort med · Risk med
(human-review the merge) · P0 for the 3 bug fixes + mayo relocation; P1 for the shared-preamble
refactor.** Sources: Redgate LLM-PII, hoop.dev.

## H4 · AI-held SSH reaches the GitLab+live-sites host; prod-vs-test boundary
**Recommend:** before ADR-0024 "flips on", **separate the GitLab control-plane host from AI-shell
reach.** Today `~/.ssh/nwp` + `gitlab_linode` give AI sessions a shell on `97.107.137.88`, which
co-hosts live test sites *and* `git.nwpcode.org` — fine for the A14 test tier, but once GitLab
authorises deploys an AI shell there **hollows the WebAuthn gate**. Move GitLab to its own Linode (also
frees ~3.6 GB, already parked), remove the AI-reachable key from the GitLab host, keep AI shell only to
genuine test hosts, and make prod-vs-test **host classification machine-checked** (a host-class
registry) so a host can't silently be both.
**Why:** ADR-0024 requires no AI host hold a prod key/Maintainer token, but forge/AI co-residency is a
lateral-movement path tokens don't cover (a shell can read runner config, tamper with the runner, mint
tokens locally — bypassing WebAuthn). ADR-0017: "software permissions can be bypassed; physical
separation cannot." Blocker #6. **Effort med · Risk med (GitLab migration) · P1 — hard precondition for
ADR-0024 activation, not for mons's first signed-deploy rehearsal.** [OP-CALL]: leave co-resident only
while GitLab is *not yet* the deploy root.

## H5 · TOFU ver-kit bootstrap (kit verified with the pubkey shipped *inside* the kit)
**Recommend:** make the out-of-band key-ID/fingerprint check a **required, scripted, non-skippable**
bootstrap step (the tp1 rehearsal skipped the manual one — runbook §3): refuse to proceed unless the
operator confirms the kit's minisign pubkey fingerprint against an **independent channel** (printed in
the runbook / read over the phone / fetched from a second host — not the kit), and **pin** the confirmed
fingerprint so later runs fail on change.
**Why:** textbook TOFU — "the fundamental vulnerability lies in that very first connection; verify the
fingerprint through an authenticated out-of-band channel before accepting"; "the majority of users cross
their fingers and type yes." The kit *is* mons's first trust anchor. **Effort low · Risk low · P1**
(before the real bootstrap). Sources: TOFU (Wikipedia), smallstep.

## ver-kit.pins provenance unverified
**Recommend:** **re-verify all three tool-pin SHA-256 hashes out-of-band** before the kit is trusted for
a real build (~5 min): `restic 0.19.1`, `age 1.3.1`, `age-plugin-fido2-hmac 0.5.0` were filled "during
this audit window by some session" — if filled by download-and-observe, the pin equals whatever was
downloaded (verifies nothing). Confirm each against upstream-published checksums (restic's GPG-signed
`SHA256SUMS`, age's release page) over a channel independent of the download, then re-commit.
**Why:** supply-chain TOFU — a pin observed by the same automation that downloads the artifact is a
self-certifying loop with no external anchor; fail-closed protects against a *changed* hash later, not a
*wrong* hash pinned at bootstrap. The ver-kit is the mons trust anchor's tooling; a poisoned restic/age
undermines DR-backup + keystore-seal at the root. **Effort ~5 min · Risk trivial · P1.**

## `mons-operational-readiness.md` contradicts the trust model
**Recommend:** **correct or delete before mons is provisioned.** It tells the operator to `cd ~/nwp` on
mons and frames "not on the tailnet" as a *gap* — both invert the resolved decision (artifact-only on
mons, never the full AI-adjacent repo; **no mesh, ever** — operator 2026-07-03). A solo operator
following it would put all of `~/nwp` on the prod-trust box, collapsing the isolation the design exists
for. Rewrite to: mons runs **only** the signed `nwp-server` artifact (ADR-0026), holds **exactly** the
three one-way keys, reaches prod **only** via the 1:1 WireGuard tunnel — never Headscale/home-LAN/`~/nwp`.
**Why:** a documentation-truth failure with security consequences (same class as C0's false banner) — a
read-first runbook instructing the *wrong* isolation posture is worse than none; it's the single most
likely way a *correct* design gets mis-provisioned under time pressure. **Effort low · Risk low to act,
high to leave · P0 (before hardware is touched).** [OP-CALL]: rewrite vs delete.

## H6 · Account-scoped Linode token + GitLab admin password in AI-readable `.secrets.yml`
**Recommend:** move both to an **AI-denied, encrypted-at-rest** store (**SOPS+age**, decrypt at point of
use) and **downscope the Linode token** to per-resource (not account-wide), ideally IP/use-restricted.
**Why:** plaintext-on-disk is "the most dangerous at scale — no encryption at rest, no rotation";
SOPS+age fits NWP's local-first/anti-SaaS posture (no server, no chicken-egg) far better than Vault
(now BSL/IBM, ~40h+FTE). C5 already proved the deny-list is *not* a control (bash reads the file) → real
protection = gitignore + host isolation + encryption at rest. Blast radius = the whole estate
(compromise ⇒ rebuild every Linode incl. GitLab+live). **Effort med (SOPS ~½ day) · Risk low-med · P1.**
[OP-CALL]: single Developer bot vs split read/MR identities.

## `~/central` has NO backup *(cross-ref stream ④)*
**Recommend:** 3-2-1 with **restic+age** (ADR-0025's stack): private encrypted remote (never-public git
remote and/or scheduled age/restic-encrypted rsync to met) + one offsite/immutable copy + a **restore
test**. **Why:** 3-2-1-1-0 (CISA/NIST) — "zero unverified backups: test the actual restore." `~/central`
holds the mons procedure + legal canon + operating model → losing it loses the *ability to operate mons
safely* → a mons precondition, not general hygiene. Encryption lets never-published content be backed up
without becoming public. **Effort low-med · Risk low · P1 (before mons depends on `~/central`).**

## The operator's live question — order of operations to make mons safe
**P0 gates, in order — do NOT provision mons hardware until step 8:**
1. **Stop the dev loop + un-lie the safety docs** (C0 + `mons-operational-readiness.md`) — free, and it
   de-risks everything after (those two docs would mis-guide every later step).
2. **Revoke both root-admin GitLab PATs** (C1, C2); confirm dead via the API.
3. **Enroll WebAuthn (two Solo 2C+) + enforce admin-2FA (zero grace); reissue the loop credential as a
   Developer bot** with minimal scope; verify `is_admin:false` + correct uid. *(2-3 = one session.)*
4. **Rotate the public-mirror gotify token** (C3).
5. **Sanitizer + PII-gate fail-closed** (land MR!47 / fix `sanitize_staging_db` + PIPESTATUS) + relocate
   the raw mayo live DB.
6. **Signing-key custody interim** (C4a): confirm passphrase, delete stray `~/nwp-ops23` copy, move off
   repo path, write the rotation runbook.
7. **Re-verify `ver-kit.pins` out-of-band + make the ver-kit fingerprint check scripted-mandatory** (H5).
8. **Provision mons per the *corrected* runbook** — artifact-only `nwp-server`, three one-way keys, 1:1
   WireGuard; rehearse signed pull→verify→apply→rollback on a disposable prod-boundary host first.
**Then before real prod cutover (P1, not gating the rehearsal):** 9. back up `~/central` (restic+age) ·
10. move GitLab off the AI-shell host + machine-check host-classification (H4) · 11. amend ADR-0024 to
verify-then-apply (H3, ops#52) + move signing to the hardware/offline ceremony (C4b) · 12. move Linode
token + GitLab admin password to SOPS+age + downscope the Linode token (H6).

**Sources:** GitLab token/2FA docs; GitHub "removing sensitive data" + BFG/filter-repo; minisign +
SoloKey FIDO2 + code-signing key protection; Redgate/hoop.dev PII; TOFU (Wikipedia/smallstep); SOPS+age;
waxell.ai/nurbak kill-switch; Backblaze/AvePoint 3-2-1-1-0.

---

# ② nwc authorization — "the next P73s"

Verified on `unfork/open-social-13` (P73 Phase A+B already merged). These concern the ~8 **other**
services with the two root causes P73 fixed for editorial: (1) authz at route/form layer while the
domain method trusts caller-supplied identity/role/method; (2) guild resolution by mutable label.
Design vocab: Drupal access returns a **trinary** (`allowed`/`neutral`/`forbidden`, forbidden-wins);
`checkAccess`/`checkCreateAccess`/`checkFieldAccess` are **distinct**; `->save()` runs **no** access
check (so entity handlers are the only thing covering JSON:API/REST/VBO). Governing risk = OWASP A01
(deny-by-default, enforce server-side, implement-once-reuse, log failures) + A03 (stored XSS).

## H1 · Legal-authoring route fail-OPEN to anonymous on an unseeded Copyright Guild 🔴
**Site:** `LegalGate::can()` (`nwc_editorial/…/LegalGate.php:63-82`) returns TRUE when the guild is
unseeded or empty-at-tier; `nwc_copyright.routing.yml:48-63` gates legal_admin/legal_edit **only** on
`_custom_access` (no `_permission`/`_role`). On a fresh install `can('edit')`→TRUE for **everyone incl.
anonymous** → author → `advance()` → advisory-passes → doc rides to `in_production` with zero four-eyes.
**Recommend:** add a hard **permission floor** to the routes (`_permission: 'author legal documents'`,
granted only to seeded Copyright-adjacent roles) AND keep the `_custom_access` tier check (Drupal ANDs
requirements). Decouple bootstrap from authenticated floor: in `can()`, `return FALSE` if
`$account->isAnonymous()` *before* the unseeded/empty-tier fallbacks; mirror the floor inside
`TransitionAuthorizer`'s legal path so `advance()` is floored too, not just the route.
**Why:** textbook A01 deny-by-default; P73 §1 itself warns the advisory fallback "becomes fail-OPEN when
reused as a raw boolean gate." Anonymous authoring of Terms/Privacy/AUP is a legal-integrity failure too.
**Effort S · Risk low · P1 (highest-stakes, trivially exploitable on fresh install) · two-person review.**

## H2 · Stored XSS in published legal HTML 🔴
**Site:** `LegalDocForm.php:56-63` authors body as `full_html`; `LegalDocRenderer::toCleanHtml()`
(:113-121) calls `stripInternalHtml()` — a **declared no-op** (:265-268 `return $html;`);
`LegalController::page()` emits via `Markup::create($html)` (:41, "this is safe, don't filter"); the
markdown link rule (:176) interpolates the URL without protocol stripping → `[x](javascript:…)` is a
live href. Chained with H1: unauthenticated persistent script for every visitor/applicant.
**Recommend:** run every stored body through `Xss::filter()` at the single choke-point (`toCleanHtml()`)
with an explicit tag allowlist (`p,br,h2-h4,ul,ol,li,strong,em,a,hr,blockquote`), replacing the no-op;
pass hrefs through `UrlHelper::stripDangerousProtocols()`; only *after* filtering wrap in
`Markup::create()` (better: return `#type => 'processed_text'` with a restricted `legal_html` format and
`#allowed_formats`). Never author legal docs in `full_html`.
**Why:** Drupal's explicit rule — "use `Xss::filter()` for text that should allow some HTML;
`UrlHelper::stripDangerousProtocols()` must be called for all URIs prior to HTML-attribute output."
`Markup::create()` on unfiltered stored input is the A03 sink. CSP on `/legal/*`+`/apply` = worthwhile
defence-in-depth. **Effort S-M · Risk low · P1 · two-person review.**

## H3/H4 · Editorial entity update/create/field access 🔴 (partially fixed)
Post-P73-B, `EditorialAccessControlHandler` hard-denies API writes + delegates non-API `update` to the
authorizer → **H3 largely closed.** Residuals: **H4 create** — `checkCreateAccess()` **not overridden**
(create routes through a *different* method than `checkAccess`; the `'create'` arm at :75 is never
reached on JSON:API POST) → a POST can mint a revision born at `in_production`; **field access** — no
`checkFieldAccess()`, so an allowed `update` can directly set `state`/`copyright_cleared`/`unilateral`.
**Recommend:** override `checkCreateAccess()` to mirror the hard-deny (creation only via the sanctioned
form/service path); add `checkFieldAccess()` returning `forbidden()` for `update` on
`state`/`copyright_cleared`/`unilateral` for non-admin actors (mutated only by the state machine).
**Why:** "checkCreateAccess is supposed to be overwritten by extending classes" and is distinct from
checkAccess; checkFieldAccess is the sanctioned per-field hook. A01 complete-mediation.
**Effort S · Risk low · P1 (create) / P2 (field) · two-person review.**

## H5 · `recordVote()` trusts caller-supplied `$method`, skipping self-review + eligibility 🔴
**Site:** `nwc_guild/…/SkillProgressionService.php:287-323` — checks only `isPending`/`hasVoted`; calls
`determineVerifierMethod()` **only when `$method===NULL`** (:303), but `LevelVerificationVoteForm`
**always** passes `$routed_method` (:250-262); **neither** path calls `canVerify()` (where the
self-exclusion guard lives) → a candidate can approve their own level-up; an unqualified member casts a
"mentor" vote.
**Recommend:** in `recordVote()`, **unconditionally** call `canVerify($verifier,$verification)` (throw
on fail) *before* recording, and **re-derive** the method server-side, ignoring any caller `$method` the
verifier doesn't qualify for (treat the argument as a hint). The form keeps passing it for display only.
**Why:** A01 record-ownership + separation-of-duties; the exact P73 root cause (authz in query/form
layer while the domain mutator trusts its caller). **Effort S · Risk low (guard already exists in
`canVerify()`) · P1 · two-person review.**

## H6 · Guild mutators (`approve`/`promoteMember`/`awardPoints`) have no domain authz 🔴
`RatificationService::approve/requestChanges/claim` trust caller `$mentor`, never verify actor may
ratify or ≠ junior; `GuildService::promoteMember` validates the role-transition *graph* but checks no
authority to promote; `ScoringService::awardPoints` is an open primitive that triggers auto-promotion.
**Recommend:** a shared **`GuildEligibility`** service (below) gating each: `approve` asserts actor holds
a ratifying tier + ≠ junior (reuse `nwc_guild_can_ratify()`); `promoteMember` takes explicit
`AccountInterface $actor` + asserts admin/mentor tier for the target role; `awardPoints` marked
`@internal` / actor+capability-checked. Each throws + audits. Add belt-and-suspenders entity handlers to
`Ratification`/`GuildScore`. **Why:** the role-graph check is *integrity*, not *authorization*; `->save()`
runs no access check. **Effort M · Risk med (live progression flow; needs positive regressions so it
doesn't deadlock) · P1 · two-person review.**

## H7 · `nwc_governance` mints authority with a forgeable `$grantor` 🔴 (built, unwired)
`ScopeGrantService::grant()` (`nwc_governance/…:23-64`) accepts caller `$grantor`, creates function-level
authority + records `$grantor` in the audit with **no check** the grantor holds grant-authority — the
class even has `assertFunction()` (:100-106) but `grant()` never calls it. `LegislationService::
enactDirect()` likewise trusts `$legislator`. **The audit trail is self-attested and forgeable.**
**Recommend:** every authority-minting method takes the **acting account** (`currentUser`, not a
free-form `$grantor`) and first `assertFunction($actor,'grant_scope'/'legislate',$scope…)` + ceiling
check, throwing on deny; derive audit `grantor`/`enacted_by` from the authenticated actor. Add entity
handlers so `scope_grant`/`policy_decision` can't be JSON:API-created. **Do not wire the governance
UI/API until this lands.** **Why:** confused-deputy / self-attested-audit anti-pattern; minting authority
is the highest-privilege op. **Effort M · Risk low NOW (unwired — cheap to fix before exposure) · P1
(before wiring) · two-person review.**

## H8 · `StoryModerationService::route()` injects into the Pedagogy queue with no authz 🔴
`nwc_story/…:38-96` — `route()` checks only `status===in_voting`, then creates an EditorialArtifact +
Revision landing **directly at `in_pedagogy_review`** (skipping writer review), no actor, no authz → any
caller promotes arbitrary `body` into the Pedagogy queue. `markApproved/markRejected` likewise unchecked.
**Recommend:** `route()` takes `AccountInterface $actor` + authorizes it (or asserts the call originates
from the verified peer-triage transition, not an arbitrary caller); route the revision creation through
the editorial create path so the H3/H4 handler governs it (not a raw `->create()->save()`); make
`markApproved/markRejected` reflections of an authorized editorial decision. **Why:** A01 complete
mediation; `->save()` bypasses access. **Effort S-M · Risk med · P2 · two-person review.**

## M1 · OIDC UserInfo — hardcoded `email_verified`, no token-type/scope/revocation check 🔴
`nwc_moodle_oauth/…/UserInfoController.php` — `email_verified=>TRUE` hardcoded (:113); bearer matched
against **any** `oauth2_token` row by value (:76) with no type/status/revocation filter (only `expire`,
:88); no scope filtering. **Recommend:** preferred — **drop the custom controller** for maintained
`simple_oauth`/OIDC UserInfo (the `feat/f26-drop-custom-userinfo` branch) **but confirm F26's spec
contradiction is resolved first** (stream ⑤ A4). If it must stay: constrain the query to access-token
type + non-revoked, derive `email_verified` from the account (or omit), filter claims by granted scope.
**Why:** A01 identity integrity on a live auth surface; accepting any token row is broken authentication;
unconditional `email_verified:true` lets Moodle trust an unverified email for account matching. **Effort
S (drop)/M (harden) · Risk med (live SSO) · P2 · two-person review.**

## M3 · Hardcoded `rjzaar@gmail.com` in shipped `/apply` webform + permission-string mismatch 🔴 (PII)
`nwc_registration/config/install/webform.webform.apply.yml:373` mails applications to a personal inbox on
any downstream install; separately (:345-360) four access blocks reference `administer nwc_registration`
(underscore) but the permission is defined `administer nwc registration` (spaces) → bound to a
**non-existent permission**. **Recommend:** replace `to_mail` with a config-driven site value (wire the
`nwc_registration.settings` approver keys the audit notes are read by zero PHP, or `[site:mail]`), ship
empty/placeholder default; fix the permission string in all four references (pick one spelling, grep to
prove zero drift); add an install/verify assertion that every config-referenced permission exists.
**Why:** PII egress to an unmanaged inbox + broken-access-control-by-typo; personal address in
installable config also violates public/private leakage hygiene. **Effort S · Risk low · P2 (PII)/P3
(typo) · two-person review.**

## M5 · `bypass editorial separation` promised but never implemented
`grep 'bypass editorial separation'` → **zero matches**; P73 §3.3 specified it as the loud gate on the
unilateral legal/doctrinal override — today `LegalGate`'s advisory pass grants unilateral legal advances
behind only the coarse surface permission, confirm step skippable. **Recommend:** define the (restricted)
permission in `nwc_editorial.permissions.yml`; in `TransitionAuthorizer`, when an allow is granted
**only** via `unilateral` **and** `change_kind ∈ {legal,doctrine-core}`, require it (else deny) + the
`ConfirmFormBase` step; persist the `unilateral` stamp + audit (fields/table already installed). Ordinary
unilateral proceeds stay frictionless. **Why:** four-eyes with an explicit permissioned audited exception,
never silent fall-through. **Effort S · Risk low · P2 · two-person review.**

## M6 · Extend `GuildLocator` (machine-id) across guild/governance/story
`GuildLocator` exists + is injected into `LegalGate`, but not the guild/governance/story services (which
resolve by label); and `GuildLocator::load()` still resolves key→label→Group *by label* (:79) because
groups carry no machine name. **Recommend:** inject `GuildLocator` everywhere a guild is resolved by name
(the shared `GuildEligibility` is the natural carrier); add a **stable machine-name base field** to the
guild group bundle and make `load()` resolve by it; ship a one-time label→key migration. **Why:** P73
identifies label resolution as fail-OPEN (rename ⇒ pool empties ⇒ four-eyes waived); implement-once-reuse.
**Effort M · Risk low-med (migration) · P2 · review recommended.**

## M7 · Fresh-install regression — `transition editorial revision` granted only by an update hook
`nwc_editorial.install:222-235` grants it to sitemanager/contentmanager **only** in
`nwc_editorial_update_10006`; no `hook_install`, no `config/optional` grant → a **fresh install** never
runs update hooks → granted to nobody → transition surface regresses to uid1-only (the P7 defect
re-manifested). **Recommend:** add `nwc_editorial_install()` doing the same grant (extract a shared
helper both call), or ship as `config/optional`; add an install-time test asserting ≥1 non-uid1 role
holds it. **Why:** update hooks run only on upgrade; install state must come from hook_install/config.
**Effort S · Risk low · P2 · no two-person review needed.**

## L-items
**L1 `nwc_collab` token IDOR 🔴** — `CollabTokenService::generateToken()` mints an editing token for any
document with no entity-update-access check; route requires only blanket `use collaborative editing`. Fix:
assert `->access('update',$actor)` before minting + entity-handler deny on JSON:API. Fold into H5/H6.
*Two-person review.* · **L2** registration form-alter regression Behat guard (one OS `form_id` rename
silently breaks `/apply`). · **L3** guild machine-name base field (durable half of M6). · **L4** entity
handlers for remaining mutable governance/guild entities (ScopeGrant/PolicyDecision/Ratification/
LevelVerification/GuildScore/data_policy) — batch with H6/H7.

## Unifying architecture — fix as a family, not one-by-one
H5/H6/H7/H8/L1 share the same two root causes → fix via a shared substrate; H1/H2/H3/H4/M1/M3/M7 are
one-off surfaces (fix directly, same principles). Recommended shape:
1. **`GuildLocator` (exists) — inject everywhere**; no call site references a label (implement-once,
   kills the rename fail-open).
2. **A shared `GuildEligibility` primitive (new, small)** — one fail-closed trinary: "does `$actor` hold
   ≥tier T in guild `$key`, and `$actor` ≠ subject?" (forbidden-wins, `neutral` for not-my-concern,
   cache-context `['user']`). Consulted by recordVote/Ratification/promoteMember/LegalGate/collab.
3. **One domain authorizer per bounded context** (`GuildActionAuthorizer`, `GovernanceAuthorizer`),
   modelled on `TransitionAuthorizer` — **not** one god-authorizer (different rules/audit needs; a single
   method couples unrelated domains + invites the create-across-bundles forbidden-poisoning bug).
4. **Belt-and-suspenders `EntityAccessControlHandler` per mutable entity** delegating update/create/
   field to its authorizer + hard-denying request-borne API writes (the only thing covering JSON:API/VBO
   since `->save()` runs no check).
5. **Every mutator takes `AccountInterface $actor` (from `currentUser`), never caller-supplied
   `$grantor`/`$mentor`/`$method`/`reporter_uid`**, authorizes first, throws on deny, derives audit
   identity from the authenticated actor.
**Sequencing:** land the substrate (GuildLocator injection + `GuildEligibility`) first behind the P73
test discipline (negative direct-service-call tests **and** positive regressions so nothing deadlocks),
then H5→H6→H7→H8→L1 on top; fix H1/H2/H3/H4/M1/M3/M5/M7 directly in parallel. All H-items + M1/M3/M5/L1
are security-critical → two-person review; M6/M7/L2/L3 are not.

**Sources:** OWASP A01/A03; Drupal change record 2337377 (trinary access, forbidden-wins);
EntityAccessControlHandler::checkCreateAccess API; Drupal "writing secure code" (Xss::filter /
UrlHelper::stripDangerousProtocols).

---
*(All five research streams — ①②③④⑤ — now integrated. See `nwp-deep-audit-2026-07-09.md` for the findings
these recommendations answer, and its MASTER ACTION PLAN for the tier structure this roadmap refines.)*
