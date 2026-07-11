# Runbook: DR / paired restore for the nwc ↔ ssc identity lock — ops#83

**Scope:** restoring or rebuilding either half of the nwc (provider) ↔ ssc (consumer) pair
without severing the F26 UID-lock. `ver` role-vocab; no real prod domain
(`<example-prod-domain>`); no secrets. Implements ADR-0031 **D9**; pairs with
`pairs/ssc.pair-contract.yml` (`identity.sub_stability`, `identity.restore`).

---

## 0. The gap this closes

ADR-0031 **D5** says code rollback is safe per-site because contract changes are
expand-contract. That is true for **code** and **false for a DB restore that renumbers Drupal
uids.** The UID-lock binds `mdl_user.idnumber == OIDC sub == Drupal account`. Any operation
that changes a provider account's identity anchor — a full-DB push (blocked by `--code-only`),
a rebuild / re-seed / migrate, or a **point-in-time-asymmetric restore** — can silently
re-point every ssc `idnumber` at the wrong or a missing nwc user.

The durable fix is already live: **`sub` is now the Drupal account UUID, not the serial uid**
(`identity.sub_stability: uuid`; emitted by the `nwc_oidc_claims` alter hook). The UUID is
row-stored, never renumbered, never reused, so the lock survives a *within-half*
renumber/rebuild. This runbook governs the *cross-half* point-in-time case.

---

## 1. The invariant (both clauses required)

- **(A) Durable anchor.** `sub` = the Drupal account UUID (live-proven). Survives renumber /
  rebuild / migrate / uid-reuse within a half.
- **(B) Both-or-forward restore.** At a `coupled_tier`, either restore **both halves to the
  same logical cut**, or restore/rebuild the provider to a point **no older than the consumer's
  newest locked identity** — provider identities move only *forward*, never behind a consumer
  lock. In one line: **when in doubt, restore both halves to one instant, or neither.**

(A) makes the lock survive a within-half renumber; (B) governs cross-half point-in-time
consistency. Neither alone is sufficient.

---

## 2. Pre-checks (before restoring EITHER half)

`pair_guard` refuses a coupled-tier restore/rebuild that lacks these two artifacts
(`identity.restore.pre_check_required: true`; escape = ledgered `--override-pair`).

1. **Snapshot the live join** on the consumer — the ground truth to reconcile against:
   ```sql
   -- ssc: current UID-locks (import later as tmp_locks)
   SELECT id AS mdl_id, idnumber AS locked_sub, email, deleted
   FROM mdl_user WHERE idnumber <> '' AND deleted = 0;
   ```
2. **Decide the cut.** Prefer restoring **both halves to the same instant**. If restoring only
   the provider, it MUST be **≥** the newest `locked_sub` on the consumer (invariant B) — never
   behind.
3. **Provider identity ledger** — an append-only `(uuid, uid, email, created_ts)` snapshot taken
   with every nwc backup (`identity.restore.ledger: provider`). This is the deterministic
   old-uid→uuid repair map; do **not** trust email.

---

## 3. Reconciliation / repair (after a provider restore, if uids may have shifted)

Only needed for a rebuild or a legacy uid-`sub` era restore; a plain UUID-`sub` restore keeps
the anchor intact.

```sql
-- Orphaned locks: ssc idnumbers that no longer resolve on nwc.
-- (uuid-sub era: join on u.uuid; legacy uid-sub era: join on u.uid.)
SELECT l.mdl_id, l.locked_sub, l.email
FROM tmp_locks l
LEFT JOIN nwc_users n ON n.uuid = l.locked_sub   -- or n.uid = l.locked_sub
WHERE n.uuid IS NULL;                            -- each row = a severed identity
```
```sql
-- Repair from the LEDGER (deterministic): re-point idnumber to the durable uuid.
UPDATE mdl_user m
JOIN ledger g ON g.uid = m.idnumber   -- old serial captured in the ledger
SET m.idnumber = g.uuid
WHERE m.idnumber IN (SELECT uid FROM ledger);
```

Email fallback (`JOIN … ON n.mail = m.email`) is a **human-gated last resort only** — recycled
or changed emails make it unsafe. Gate on email-unique-and-unchanged before ever using it.

---

## 4. Post-restore verification

Re-run the pair smoke (`pl pair smoke ssc`) **plus a join-integrity probe** — the smoke suite
today is liveness only (JWKS 200, endpoints up):

- Pick a real `idnumber` on ssc, confirm it still resolves to the **correct** nwc account (not
  just that the endpoints answer).
- Only once the probe is green, clear the ssc `autoredirect` guard.

---

## 5. What is a standing operator rule vs. tooling

- **Live now:** `sub_stability: uuid` (the durable anchor) is deployed on the nwc live tier.
- **Standing operator rule until the gate lands:** the both-or-forward rule (§1B) and the
  pre-checks (§2). Do not restore a coupled-tier half without the join snapshot + ledger.
- **Phased build (tracked under ops#83 / ADR-0031 ops C / ops#49):**
  1. the **provider identity ledger** (append-only, per-backup) — the only trustworthy reconcile
     source;
  2. the **`pair_guard` restore choke-point** that enforces the pre-checks;
  3. the **join-integrity smoke probe** (resolve a real idnumber, not just liveness).

---

## Contract linkage

`pairs/ssc.pair-contract.yml` → `identity.sub_stability: uuid` and the `identity.restore` block
(`invariant: both-or-forward`, `ledger: provider`, `reconcile: from-ledger`,
`pre_check_required: true`). Governed by ADR-0031 **D9** with the D5 carve-out (code rollback ≠
identity restore).
