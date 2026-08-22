# Runbook / design: erasure-propagation channel (nwc → ssc) — ops#81

**Scope:** propagating a right-to-be-forgotten / account deletion from nwc (OIDC provider,
Drupal/Open Social) to ssc (consumer, Moodle) so a delete on nwc does not leave PII stranded on
the Moodle side. `ver` role-vocab; no real prod domain; no secrets. **Status: DESIGN + P0
(schema + contract + `pl erasure`).** The receiver + sender plugins are PHASED (P1–P5) and are
**not deployed anywhere** — `pl erasure execute` fails closed with `CHANNEL-NOT-DEPLOYED` rather
than reporting an erasure the estate cannot perform. See §6 for the operator runbook that is
usable today.

**Framing:** general data-protection / RTBF *hygiene* (relevant for EU users on a US-based
international 13+ site) — **not** a minors-compliance blocker. Data protection by design.

---

## 0. The problem (un-propagated erasure)

SSO runs through `auth_nwc` with the UID-lock (`mdl_user.idnumber == nwc sub == Drupal account`,
now UUID-anchored per ops#83). Deleting a person on nwc does **nothing** to their Moodle side.
Left behind on ssc: the `mdl_user` row + PII, `grade_grades` / `quiz_attempts` /
`course_completions`, `tool_policy_acceptances` (consent), `auth_oauth2_linked_login`, and
**moodledata** files (submissions, certificates, profile images).

---

## 1. Decision: a bespoke WS-erase channel (not OpenID Provider Commands yet)

**OpenID Provider Commands 1.0** is the right-shaped emerging standard (an OP POSTs a signed
Command Token to an RP Command Endpoint; `delete` is a defined command) — but it is draft-02,
has no stable implementations, and neither `simple_oauth` nor Moodle ship a Command Endpoint.

**Build a bespoke WS-erase channel that borrows Provider Commands' *shape* (signed, sub-keyed,
idempotent, audited delete instruction) but rides NWP's already-proven transport.** NWP already
runs exactly this pattern for `copyright_sync`: nwc Guzzle-POSTs to a plain Moodle endpoint with
`Authorization: Bearer <token>`, IP-allowlist, JSON body, idempotency guard. The erasure channel
is a second receiver of the same family — reuses a live, reviewed transport; no dependency on a
moving spec; keeps the door open to swap in Provider Commands later.

---

## 2. What must actually be erased — use the Privacy API, not `delete_user()`

Moodle's ordinary `delete_user()` is only a **soft delete** (sets `deleted=1`, scrambles
username/email) and leaves residual PII (lastip, phone, address, idnumber) — explicitly **not
GDPR-compliant**. True erasure is the **Privacy API** (`\core_privacy\manager` +
`admin/tool/dataprivacy`), which walks every component's `delete_data_for_user()`.

| Target | Erased by |
|---|---|
| `mdl_user` row + residual PII (lastip/phone/address/idnumber) | Privacy API core_user provider |
| `grade_grades`, `quiz_attempts`, `course_completions` | per-component `delete_data_for_user()` (some aggregate rows lawfully retained) |
| `tool_policy_acceptances` (consent) | tool_policy privacy provider |
| `auth_oauth2_linked_login` (the SSO link) | auth_oauth2 provider — also deleted proactively to sever re-link |
| **moodledata** files | Privacy API file deletion per context → reuse the ops#84 moodledata scrub |

**Delete vs anonymise.** Default = **delete** (Privacy-API erasure = the honest RTBF action).
Offer **anonymise** (keep de-identified aggregate rows where a legitimate record-keeping basis
exists) as a per-request flag, not the default.

Programmatic trigger: `\tool_dataprivacy\api::create_data_request($userid, DATATYPE_DELETE)` →
`approve_data_request()` (auto-approved for a trusted OP-driven request) → run the ad-hoc
`process_data_request_task`, which fans out `delete_data_for_user`.

---

## 3. Channel design — `local_nwc_erase` (mirror of the copyright receiver)

**Provider (nwc, Drupal).** New service `nwc_moodle_erase` (sibling of `nwc_moodle_sync`).
Hook `hook_user_predelete($account)` → enqueue a job (reuse the `nwc_moodle_sync` queue + cron)
→ worker Guzzle-POSTs (reuse the `MoodleToolPolicySync` HTTP shape) to the ssc receiver. Payload
keyed on the **OIDC `sub`** (the durable UUID anchor == Moodle idnumber, never email) —
validated against `contracts/erasure.command.schema.json`:

```json
{ "sub": "8f14e45f-ceea-467a-9e2b-2c3b0a1d4e5f", "request_id": "<uuid>",
  "action": "delete", "issuer": "https://nwc.<example-prod-domain>/", "timestamp": 1752000000 }
```

**Consumer (ssc, Moodle).** New plugin `local_nwc_erase`, endpoint `/local/nwc_erase/erase.php`
— clone the `policy_set.php` guard rail (`AJAX_SCRIPT` + `NO_MOODLE_COOKIES`, `enabled` config
gate, IP allowlist, `hash_equals` Bearer check, JSON validate). On a valid POST:
1. Resolve `mdl_user` **by `idnumber == sub`** (never email); no row → `200 {"action":"noop"}`
   (idempotent — already gone).
2. Delete `auth_oauth2_linked_login` for that user (sever re-link).
3. `create_data_request(DELETE)` → auto-approve → run `process_data_request_task` (the
   Privacy-API fan-out).
4. Invoke the ops#84 moodledata scrub for the user's file areas + capture its verification result.
5. Write an audit row (`local_nwc_erase_log`) and return `200 {"action":"deleted","request_id":…}`.

**Properties:** idempotent (request_id + noop-on-missing), authenticated (Bearer + IP allowlist),
audited (log table both sides), replayable (safe to re-POST after a 502).

---

## 4. ver / prod boundary (CLAUDE.md AI-never-prod)

This channel makes a **destructive** cross-site write. On dev/stg/live-test tiers
(`*.example.com`) AI/agents may operate it (A14). **Real prod erasure must run through the `ver`
desktop deploy gate** — a per-write Solo-touch (`lib/deploy-gate.sh`); no AI-accessible machine
may fire an erase at prod. The receiver token for a prod tier is a `ver`-held secret, never on any
AI-accessible build/agent host. The receiver is auth-adjacent + destructive → two-person review of the destructive path
(CLAUDE.md sensitive-path rule) is required before it lands.

---

## 5. Contract linkage + phased build

`pairs/ssc.pair-contract.yml` carries the 7th surface `erasure` (`provider_min: 0.6.0`
`nwc_moodle_erase`, `consumer_min: 1.0.0` `local_nwc_erase`, schema
`contracts/erasure.command.schema.json`) + its `boundary.erasure` paths. Feeds NWP-ADR-0031 as the
resolution of the un-propagated-erasure open question.

- **P0 (this change):** land `erasure.command.schema.json`, the pair-contract surface + boundary,
  audit-log table designs. **No behaviour.**
- **P1 — consumer receiver (dev):** `local_nwc_erase` + `erase.php` guard rail; wire Privacy-API
  delete; unit-test on an empty dev Moodle.
- **P2 — provider sender (dev):** `nwc_moodle_erase` `hook_user_predelete` → queue → POST; dev
  round-trip delete of a throwaway SSO user; assert all §2 rows + moodledata gone; assert
  idempotent replay = noop.
- **P3 — moodledata reuse:** integrate the ops#84 scrub + its verification signal into the
  receiver; assert zero orphaned user files.
- **P4 — anonymise mode + audit:** add the anonymise flag + both-side audit log + a
  `status.php`/report that proves convergence.
- **P5 — ver / prod gating:** prod-tier receiver token held by `ver`; erase-at-prod behind
  Solo-touch; two-person review of the destructive path.

Add a `smoke_url` (`/local/nwc_erase/status.php` → 200) when P1 lands; **never** exercise a real
delete in smoke.

---

## 6. Operator runbook — `pl erasure` (available NOW, at P0)

The channel is not built, but the *request* no longer has to be serviced by hand. `pl erasure`
exists at P0 and is deliberately honest about what it can and cannot do.

```bash
pl erasure plan   ssc --sub=<uuid> [--action=delete|anonymise] [--tier=live]
pl erasure verify ssc --sub=<uuid> [--tier=live]
pl erasure status <request-id>
pl erasure list
pl erasure execute ssc --request-id=<id>     # FAILS CLOSED until P1/P2 land
```

**`plan`** builds the erasure command, validates it against the signed
`contracts/erasure.command.schema.json` (structurally, and with `jsonschema` when available),
records it under `private/erasure/<pair>/<id>.json`, and prints the full §2 target inventory for
both stacks plus backups. This is the artifact that used to be assembled by hand under deadline.

**`verify`** is the honest answer to "is this person gone?" and is capable of going red. It
probes **both** halves and the backup ceiling:

| result | meaning |
|---|---|
| `RESIDUAL` | a side counted rows for this subject — **not erased** |
| `CANNOT-VERIFY` | a probe is unwired, errored, or printed a non-count — **not a pass** |
| `NO-BACKUP-CEILING` | no `--keep-within` window declared, so residual PII in the raw restic repo outlives the promise indefinitely (ops#127) |
| `ERASURE VERIFIED` | every configured probe **counted** zero and a ceiling is declared |

The probes are pluggable so this file holds no DB credentials: each is a command receiving the
sub as `$1` and printing one integer. Wire them once, in the pair contract:

```yaml
erasure:
  provider_probe_cmd: "<a pl drush nwc --tier=live residual-row count>"
  consumer_probe_cmd: "<a pl moodle cli ssc --tier=live residual-row count>"
  backup_ceiling: "30d"        # ONLY once the DR chain provably carries the flag
  semantics_approved: false    # OPERATOR
```

**`execute`** refuses, in this order, naming exactly which condition failed:

1. `NO-SUCH-REQUEST` — nothing was planned under that id.
2. `CHANNEL-NOT-DEPLOYED` — `local_nwc_erase` (P1) / `nwc_moodle_erase` (P2) are absent from the
   declared trees. **This is the state today**, so an erasure must be recorded, escalated and
   performed under the operator DR runbook — never marked done here.
3. `SEMANTICS-UNAPPROVED` — the pair contract does not record operator sign-off. Anonymise vs
   delete, which aggregates are lawfully retained, and what "verified erased" means across
   nwc + ssc + moodledata + restic snapshots is an Art.17 lawful-basis question. An agent must
   not settle it; flip `erasure.semantics_approved: true` in the contract when it is settled.
4. `NO-TRANSPORT` — nothing is wired to deliver the validated command.
5. `CONFIRM` — a coupled tier (live/prod) additionally needs `--confirm=ERASE-EXECUTE`.

Real **prod** erasure stays behind the `ver` Solo-touch gate (§4) regardless of the above.

**The subject is always the OIDC `sub`.** There is no `--email`; passing one is rejected with an
explanation. Recycled and changed addresses make an email-keyed erasure capable of deleting the
wrong person.
