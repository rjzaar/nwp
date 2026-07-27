# ADR-0034: Paired-restore identity invariant — enforcement

- **Status:** Proposed (ops#83)
- **Date:** 2026-07-28
- **Supersedes:** nothing. **Amends:** [ADR-0031](0031-paired-site-versioning-and-promotion.md) **D9**.
- **Related:** [ADR-0029](0029-nwc-authorization-model.md), `pairs/ssc.pair-contract.yml`,
  `docs/guides/ops83-dr-restore.md`

## Why a second ADR

ADR-0031 **D9** already *decides* the invariant: `sub` is the durable UUID anchor (A), and a
coupled-tier restore is **both-or-forward** (B). That decision is sound and is not reopened here.

This ADR records what D9 did not: **what the enforcement actually refuses, and what it must
refuse when it knows nothing.** D9 was written as a rule for a human. Turning it into a gate
surfaced three questions D9 does not answer — what an *unknown* identity position means, how the
"both" branch is even expressed, and which operations are exempt. Answering those changes
operator-visible behaviour, so it needs its own record.

## Context — the gate was inert where it mattered

`pair_guard_restore` (lib/pair.sh) landed 2026-07-11 with the fail-closed pre-checks D9 asks for.
Auditing it for closure found it **could not refuse the operation it exists to refuse.**

Its both-or-forward comparison reads the counterpart's *identity anchor* — a monotonic integer
marking the newest identity cut recorded for that side. If the counterpart had no anchor, the guard
concluded there was "no lock to orphan" and **passed**.

`pair_anchor_set` **has no production caller.** No promotion, no ledger dump, no SSO lock, no
backup has ever written an anchor. Only the manual `pl pair anchor` verb and the test fixtures do.
So on every real pair the counterpart anchor is empty, and the comparison never ran outside its own
unit tests.

Two things hid this:

1. The two fail-closed pre-checks (provider ledger + consumer join-snapshot) refused first, so the
   gate *looked* like it worked.
2. **Satisfying them is what disarmed it.** The DR runbook tells an operator to capture exactly
   those two artifacts before a coupled-tier restore. Following the runbook moved the gate from
   "refuses for a reason unrelated to the invariant" to "allows". The safety property degraded as
   the operator did the right thing — the worst possible direction for a failure to point.

This is the same shape as the membership defect fixed on 2026-07-27 (`pair_scan` read one file in
one shape, found nothing, and read nothing as consent), one layer deeper. Unreadable read as
unpaired; **unrecorded read as empty**; empty read as consent.

## Decision

### 1. The invariant, stated precisely

> **A DB restore of EITHER half of a UID-locked pair at a coupled tier is identity-destructive
> unless both halves come to rest at the same logical cut.**
>
> The lock is `mdl_user.idnumber == OIDC sub == nwc users.uuid`. A restore that moves one half's
> identity set to a point the other half's locks do not describe orphans every lock in the
> difference. Only two positions are safe: **BOTH** halves at one cut, or the provider **FORWARD**
> of every consumer lock. Any third position is a guess about other people's identities.

### 2. Allowed operations

| Operation | Verdict | Why |
|---|---|---|
| **Code-only restore** (no DB loaded) | **ALLOWED** | Cannot renumber an identity set. Same reasoning as D5 for code rollback and D6's `--code-only` escape. Must be *derived from what the code does*, never asserted by a flag. |
| Restore at an **uncoupled tier** (dev/stg), or a pair with `uid_lock: false` | **ALLOWED** | No live locks to orphan. Off-unless-configured is preserved. |
| **Paired restore to matching checkpoints** (`--paired-restore-ack CP-<id>`) | **ALLOWED, then re-verified** | The BOTH branch. The pair is set RAG **red** on the first half's landing and stays red until the join probe passes — a half-restored pair must not look promotable. |
| **Forward restore** (target anchor ≥ counterpart anchor) | **ALLOWED** | The FORWARD branch: provider identities move only ahead of consumer locks. |
| **Single-half DB restore** at a coupled tier | **REFUSED** | The operation this ADR exists for. |
| Counterpart identity position **unknown** | **REFUSED — CANNOT VERIFY** | *The change.* Absence of a recorded anchor is not evidence of an empty identity set. |
| Missing provider ledger / consumer join-snapshot | **REFUSED** | Unchanged from D9: reconciliation would be impossible afterwards. |

The only escapes are the pre-existing typed, ledgered `--override-pair` (`RESTORE-OVERRIDE`) and
the audited `NWP_PAIR_GATE_SOFT=true`. Neither is widened here.

### 3. "Both" becomes expressible — the paired checkpoint

The invariant was named *both-or-forward*, but **only forward was expressible in code**. An
operator doing the correct thing — restoring nwc and ssc to the same instant — had to reach for the
same blanket `--override-pair` as an operator doing the dangerous thing. One signal for two
opposite intentions is not an audit trail, and it trains operators to type the override.

A **paired checkpoint** is a recorded joint cut: an id, plus the anchor each half sits at within it.

```
pl pair checkpoint ssc live CP-2026-07-28-live --provider-anchor=42 --consumer-anchor=42
pl restore <half> --tier=live --anchor=42 --paired-restore-ack CP-2026-07-28-live   # each half
```

`--paired-restore-ack` **names** a checkpoint; the guard **resolves the name against the record**.
It is a reference, not an assertion. An ack that names an unrecorded checkpoint, an ambiguous one
(same id, two different anchor pairs), one belonging to another tier, one carrying no counterpart
anchor, or one whose recorded anchor for this side disagrees with the backup being restored — all
**REFUSE**. Naming a nonexistent checkpoint must never be safer than naming none.

### 4. Fail-closed on absence, not just on contradiction

Every input to this gate is tri-state — resolved / not declared / **CANNOT VERIFY** — and the third
is never collapsed into the second. Vocabulary is reused from `pl impact --honesty` and the 2026-07-27
membership fix rather than reinvented: *"This is NOT a clean result."*

## The anchor question: is `sub` the right durable anchor?

**Asked:** should the OIDC `sub` claim be the durable anchor, replacing the `mdl_user.idnumber`
uid-lock? **Answer: the question is already settled in the code, and the settlement is correct.**

`sub` **is** the Drupal account UUID today, live:

- `sites/nwc/.../nwc_features/nwc_oidc_claims/nwc_oidc_claims.module:51` —
  `$claims["sub"] = $user->uuid();` (overrides simple_oauth's default `sub = uid`)
- `contracts/oauth_sso.claims.schema.json:13-16` — `sub` is pinned to a UUID regex, "NOT the serial uid"
- `pairs/ssc.pair-contract.yml` — `identity.sub_stability: uuid`, enforced by
  `pair_provider_sub_shape_guard` (`lib/pair.sh`) against `sub_source` / `sub_assert`
- Consumer side: `sites/ssc/dev/auth/nwc/auth.php:106-108` looks users up by
  `['idnumber' => $sub]`; `mdl_user.idnumber` is written **once**, by Moodle core `auth_oauth2`
  through the `sub → idnumber` issuer field mapping. `auth_nwc` never rewrites it
  (`auth.php:157-173`); empty `sub` is DENY (`classes/uid_lock.php:72-74`).

So `idnumber` and `sub` are not competing anchors — **`idnumber` is the consumer's stored copy of
`sub`.** There is one anchor, and it is already the immutable UUID, stored on both sides. D9(A) is
done.

### What this does and does not buy

The UUID makes a **within-half** renumber survivable: restore/rebuild/migrate nwc, uids shuffle,
UUIDs do not, locks hold. That is real and already banked.

It does **not** make a **cross-half point-in-time asymmetry** survivable, and this is the part that
gets misread as "the UUID fixed it". Restore nwc to a point *before* some accounts existed and
those UUIDs are not renumbered — **they are absent**. Every ssc lock pointing at them orphans.
Durability of an identifier cannot rescue the deletion of the row it identifies.

### Recommendation — make single-half restore SURVIVABLE, not merely forbidden (follow-up)

Refusal is the right gate but a poor destination: it makes DR slower exactly when it is most needed.
The smallest change that converts the refusal into a repair is **replay, not a new anchor**:

> After restoring the provider to an older cut, **replay from the provider identity ledger every
> `(uuid, uid, email, created_ts)` row newer than that cut, re-creating those accounts with their
> original UUIDs.** The identity set then moves *forward* again by construction, and the FORWARD
> branch of the invariant is satisfied without either half being rolled back.

This works because the ledger (`scripts/f26/nwc-identity-ledger.sh`, append-only + hash-chained)
already captures exactly the tuple needed, and Drupal permits setting `uuid` on user creation. It
needs no schema change, no new claim, and no cross-stack flag day — the expensive kind of change
this project rightly avoids while real students hold locks.

Deliberately **not** built tonight: it writes user rows on the provider, which is a change to
identity-bearing data and wants its own review, its own tests, and an operator decision about what
a replayed account's password/status should be. Filed as a follow-up.

**Rejected alternative:** adding a second anchor (e.g. storing `uid` alongside `sub` on the consumer
as a fallback join). It reintroduces the renumber-fragile identifier that D9 removed, and creates
two join keys that can disagree — an ambiguity this codebase has already learned to treat as a
refusal, not a feature.

## Consequences

- **More refusals, on purpose.** Until an operator records anchors or a paired checkpoint, every
  coupled-tier DB restore of `nwc`/`ssc` refuses. That is the correct posture for an unmeasured
  identity rail, and it is escapable by a typed, ledgered override.
- **The correct operation is now distinguishable from the dangerous one** in the ledger:
  `restore-paired-ack` vs `restore-override`.
- **Two side doors closed** (`pl moodle rollback … execute`; the local rollback arm's missing
  `--tier`). Others remain open and are enumerated on ops#83 — an ungated door that is named is
  worth more than one gated silently.
- **`pair_anchor_set` still has no automatic producer.** The gate now refuses rather than passes
  when that shows, so the gap is loud instead of silent — but wiring anchor-recording into backup
  and promotion is outstanding work, not a solved problem.
