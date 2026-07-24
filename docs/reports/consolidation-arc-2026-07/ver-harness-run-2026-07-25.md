# pl ver-test — real end-to-end run, 2026-07-25 (task #11; ops#25 + ops#127)

First full execution of the pl-driven ver DR test harness (`scripts/commands/ver-test.sh`,
`pl ver-test <provision|provision-prod|cycle|teardown|status>`). Two fresh disposable
Linodes (tags `arc-disposable`,`ver-harness`; ids in DISPOSABLE-LINODE.md) ran the FULL
DR chain with the REAL scripts under test — no mocks:

- **test-ver** id 101309316 (172.239.153.133) — custodian stand-in: restic+minisign,
  nwp-server artifact at /opt/nwp-server, the real `ver-pull-session.sh`, keystore shim.
- **test-prod** id 101310154 (172.239.154.43) — minimal Drupal 11 fixture (composer +
  MariaDB + drush; uid1 `admin@vertest-harness.org` real-domain email, 5 planted members
  `member<i>@harness-member.net`), nwp-server artifact, ver→prod dedicated-key ssh path.

## Scorecard (`pl ver-test cycle`, 2026-07-25 — 16/16 PASS, exit 0)

```
✓ PASS  raw-backup — prod: RAW restic snapshot (db+files) → /var/backups/nwp-server/drupalfx
✓ PASS  sanitized-backup — prod: sanitise (preserve-admin) + fail-closed PII gate → drupalfx-sanitized repo
✓ PASS  prod-pii-gate — prod: independent PII gate PASSED on the sanitised dump (admin sidecar)
✓ PASS  session-preflight — ver: pull-sources.conf --check (data classes validate fail-closed)
✓ PASS  pull-session — ver: ver-pull-session --execute drained both sources
✓ PASS  session-both-sources — ver: session reports 2/2 sources drained
✓ PASS  raw-keep-within — ver: RAW repo pruned with --keep-within 30d (ops#127 erasure ceiling)
✓ PASS  sanitized-tiered — ver: sanitised repo kept the tiered daily/weekly/monthly policy
✓ PASS  restic-check-raw — ver: restic check --read-data PASSED on the raw repo
✓ PASS  restic-check-sanitized — ver: restic check --read-data PASSED on the sanitised repo
✓ PASS  snapshots-present — ver: both durable repos hold >=1 snapshot
✓ PASS  restore-sanitized — ver: sanitised db snapshot restored to scratch
✓ PASS  gate-sanitized-pass — ver: PII gate PASSES on restored sanitised dump (admin allowlisted)
✓ PASS  gate-needs-allowlist — ver: without the admin allowlist the gate FAILS → admin really preserved (real domain)
✓ PASS  restore-raw — ver: raw db snapshot restored to scratch
✓ PASS  gate-raw-fails — ver: PII gate FAILS (rc=1) on the RAW dump — planted member@harness-member.net detected

SUCCESS: CYCLE PASS — 16/16 checks green
```

Key evidence lines from the session/drill logs:

```
== Source: drupalfx (raw) ==            Step 3 · Retention (erasure ceiling: keep-within 30d)
== Source: drupalfx-sanitized (sanitized) ==   Step 3 · Retention (d:7 w:8 m:12)
✓ session complete: 2 source(s) drained
[standard-sanitizer] preserve-admin: uid 1 retained; scrub floor = uid>1
[standard-sanitizer] wrote admin-allow sidecar → …/db.sql.gz.admin-allow
✓ sanitised + PII-gate clean (admin preserved, all other users scrubbed)
SNAPSHOTS raw=2 sanitized=1
GATE_SANITIZED_WITH_ALLOW rc=0 · GATE_SANITIZED_NO_ALLOW rc=1 · GATE_RAW rc=1
```

## What this proves (composition, not just pieces)

The #120 validation proved the ops#127 pieces on ONE host. This run proves the
**composition as repeatable `pl` commands with the ver↔prod split**: prod stages
raw + sanitised restic repos → ver drains them over its own dedicated path via the
real `ver-pull-session.sh` (MR !152 kind-field wiring exercised live: RAW got the
30d erasure ceiling, sanitised kept the tiered policy, and a mis-classed conf line
fails the whole session closed) → full-read integrity checks → a restore drill in
both gate directions. The same commands are the dress rehearsal for building real ver.

## Bug found & fixed by this run

- `build/nwp-server.include` omitted `lib/server-backup-resolve.sh` and
  `lib/prod-guard.sh`, which `server-backup.sh` / the sanitizers hard-source —
  the shipped artifact's backup verb would have died at source-time on a real
  prod host. Added to the allowlist (deny-scan still clean, 29 files).
- Recycled cloud IPs + a stale global known_hosts entry made `accept-new` refuse
  (the #120 box's IP came straight back on the first create). The harness now uses
  a dedicated known_hosts under its state dir and purges the IP on each create.

## Honest deltas vs the real ver (harness stand-ins, deliberate)

1. **Transport:** plain ssh (dedicated ephemeral ed25519 key generated on test-ver,
   root@test-prod) stands in for the real 1:1 WireGuard tunnel with prod sshd bound
   to the tunnel interface and a forced-command chrooted sftp backup user.
2. **Keystore:** a plaintext-file shim with the exact `ver-seal-keystore.sh` CLI —
   the real ver seals restic passwords to a Solo token via age-plugin-fido2-hmac
   (unseal = physical touch + PIN). Not reproducible on a cloud VM.
3. **Signing:** an ephemeral harness minisign keypair signs the restic binaries;
   the real ver pins the NWP minisign key delivered via the signed ver-kit.
4. **Offline posture / Solo enrolment / keystore escrow:** human-runbook steps
   (docs/guides/ver-provisioning-runbook.md) — not assertable here.

## Teardown

Both instances destroyed via API immediately after the run and verified gone
(DELETE 200, verify GET 404, account sweep for tag `ver-harness` = 0 remaining);
per-instance confirmation lines are appended to DISPOSABLE-LINODE.md.

Cost: 2 × g6-standard-2 for ~1.5 h ≈ US$0.11.
