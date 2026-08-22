# Runbook: DR / paired restore for the nwc ↔ ssc identity lock — ops#83

**Scope:** restoring or rebuilding either half of the nwc (provider) ↔ ssc (consumer) pair
without severing the F26 UID-lock. `ver` role-vocab; no real prod domain
(`<example-prod-domain>`); no secrets. Implements NWP-ADR-0031 **D9**; pairs with
`pairs/ssc.pair-contract.yml` (`identity.sub_stability`, `identity.restore`).

---

## 0. The gap this closes

NWP-ADR-0031 **D5** says code rollback is safe per-site because contract changes are
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

> ⚠ **These two artifacts are necessary, not sufficient — and until 2026-07-28 capturing them
> made things WORSE.** The gate's last check compares the two halves' identity anchors, and no
> code has ever *recorded* an anchor, so it used to read "no anchor" as "no locks to orphan" and
> **pass**. The pre-checks above were the only thing refusing; satisfying them is what removed the
> refusal. That is now closed: an unrecorded counterpart position is `CANNOT VERIFY` and refuses.
> See [NWP-ADR-0034](../decisions/0034-paired-restore-identity-invariant-enforcement.md).

### 2b. Declare the cut — the BOTH branch

Restoring both halves to one instant is the *preferred* path, and it now has its own verb instead
of borrowing the danger override. Record the joint cut once, then name it on each half:

```bash
# Record the joint cut (both anchors required — one half is not a joint cut).
pl pair checkpoint ssc live CP-2026-07-28-live --provider-anchor=<N> --consumer-anchor=<M>
pl pair checkpoint ssc live --list

# Rehearse the decision. target-anchor is optional; omit it to see the "cut unknown" refusal.
pl pair restore-check ssc live
pl pair restore-check ssc live <N> --paired-restore-ack=CP-2026-07-28-live

# Then restore EACH half naming the same checkpoint.
pl restore <half> --tier=live --anchor=<N> --paired-restore-ack CP-2026-07-28-live
```

The ack is a **reference to the record**, not a promise: an unknown, ambiguous, wrong-tier, or
anchor-mismatched checkpoint id **refuses**. After the first half lands the pair goes RAG **red**
and stays red until §4's join probe passes — a half-restored pair must not look promotable.

**A code-only restore (no DB loaded) is always allowed** at any tier: it cannot move an identity
set. Note there is deliberately no `--code-only` flag on `pl restore` — every path in that verb
loads a database, so the flag could only silence the gate without changing the operation.

---

## 3. Reconciliation / repair (after a provider restore, if uids may have shifted)

Only needed for a rebuild or a legacy uid-`sub` era restore; a plain UUID-`sub` restore keeps
the anchor intact.

**Use the verb. Do not hand-write the SQL.**

```bash
pl pair reconcile ssc --tier=live                 # dry run (DEFAULT) — classify only
pl pair reconcile ssc --tier=live --json          # same, machine-readable
pl pair reconcile ssc --tier=live --apply \
    --repair-cmd="<cmd>" --confirm=RECONCILE-APPLY  # repair the repairable only
```

It reads the two artifacts §2 already requires — the provider identity ledger and the consumer
join snapshot — and classifies every **live** UID-lock:

| class | meaning | action |
|---|---|---|
| `intact` | `locked_sub` resolves to a uuid the provider still holds | none |
| `repairable` | `locked_sub` is a *serial uid* the ledger carries; the durable uuid is known | deterministic re-point, `--apply` |
| `orphaned` | resolves to nothing at all | **human-gated** — never auto-repaired |

Properties that matter under DR pressure:

* **Fail-closed.** A missing ledger, a missing join snapshot, or a snapshot with zero live rows
  is `CANNOT-VERIFY` and exits non-zero. "Nothing to reconcile" and "nothing to reconcile
  *with*" never print the same thing.
* **Dry run by default.** `--apply` additionally requires `--repair-cmd` and, on a coupled
  tier, the typed `--confirm=RECONCILE-APPLY`.
* **No credentials, no SQL of its own.** `--repair-cmd` is invoked once per repairable lock as
  `CMD <mdl_id> <new_idnumber>` — wrap `pl moodle cli <site> --tier=<t> --execute -- …`. Each
  repair runs in a subshell, so one failure fails that row, not the run, and every applied
  repair is appended to the pair ledger.
* **Email is not a fallback anywhere in the code path.** ops#83's email join (`JOIN … ON
  n.mail = m.email`) remains a **human-gated last resort only** — recycled or changed emails
  make it unsafe, and an email-keyed repair re-points a lock at the wrong person. The verb
  deliberately cannot do it; if you need it, you are doing it by hand, on purpose, having
  first gated on email-unique-and-unchanged.

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
- **Phased build (tracked under ops#83 / NWP-ADR-0031 ops C / ops#49):**
  1. the **provider identity ledger** (append-only, per-backup) — the only trustworthy reconcile
     source; **BUILT** (`scripts/f26/nwc-identity-ledger.sh dump|verify`);
  2. the **`pair_guard` restore choke-point** that enforces the pre-checks; **BUILT**
     (`pair_guard_restore`, dry-runnable via `pl pair restore-check`);
  3. the **join-integrity smoke probe** (resolve a real idnumber, not just liveness); **BUILT**
     (`pl pair-smoke <consumer> --join --join-uuid=<uuid>`);
  4. the **reconcile/repair step** itself; **BUILT** (`pl pair reconcile`, §3) — this is what
     replaced the raw SQL that used to live in §3.

---

## Contract linkage

`pairs/ssc.pair-contract.yml` → `identity.sub_stability: uuid` and the `identity.restore` block
(`invariant: both-or-forward`, `ledger: provider`, `reconcile: from-ledger`,
`pre_check_required: true`). Governed by NWP-ADR-0031 **D9** with the D5 carve-out (code rollback ≠
identity restore).
