# `ver` provisioning runbook — turnkey (ops#25)

> **Status:** READY TO RUN — every AI-preparable piece is built; what remains is
> operator-hands-on (hardware, physical transfer, key registration, token
> enrollment). **Date:** 2026-07-03.
> **Audience:** the operator, sitting at the `ver` box (and briefly at
> `build-host` and a browser). `ai-host`/`authoring` assistants cannot reach
> `ver` — every command in an OPERATOR step is typed by you.
> **Companion:** [`ver-setup.md`](ver-setup.md) (concepts + trust posture +
> smoke-test table). This runbook is the *do-it* sequence; that guide is the
> *why*. Roles per [`role-vocabulary.md`](../reference/role-vocabulary.md);
> resolve any role to your concrete box with `pl host ver` (private
> instance manifest — bare hostnames never appear in-repo).
> **ADRs:** ADR-0024 (deploy authority — runner-resident model canonical per
> ops#28), ADR-0025 (custodian-pull backups), ADR-0026 (the `nwp-server`
> capability agent; renumbered from a duplicate ADR-0024 — lands with MR !28),
> ADR-0022 (AI-free build split).

> **⚠ AMENDED BY [ADR-0028](../decisions/0028-ver-single-operator-human-gated-workstation.md) (2026-07-09).**
> ver is now a **single-operator desktop workstation running the full `pl`
> surface**, with **browser-based AI allowed** (read-only, human-gated — **no live
> AI agent / loop / MCP on the box**). This supersedes §2's "minimal server / no
> desktop / no browser" posture. Hardware is **two WebAuthn tokens — Solo W + Solo
> W2 (backup)** — *not* the Solo K/W split in §4; the **Solo K keystore + restic
> DR-backup half (§4-Solo-K, §5, §8) is DEFERRED** (a separate DR capability, not
> needed to deploy). Per-deploy authorization is an **SSH `ed25519-sk` Solo touch**
> (`lib/deploy-gate.sh`); minisign is retained only for the one-time kit bootstrap.
> **Deploy-half fast path:** §1 + §3 (kit) + only the **Solo W** part of §4 + the
> linchpin sweep — skip §4-Solo-K, §5, §8. Operator walkthrough:
> [`ver-soloW-setup-walkthrough.md`](ver-soloW-setup-walkthrough.md).

---

## 0. What's AI-prepared vs. what needs your hands

| # | Step | Who | Why |
|---|------|-----|-----|
| 1 | Provisioning kit: signed tool set + scripts (`prepare-ver-kit.sh`) | **AI-PREPARED** (built; you run one command) | runs on `build-host` inside the repo |
| 2 | Tool sha256 pins | **OPERATOR** | trust anchor — a human confirms upstream checksums out-of-band |
| 3 | Base OS install + hardening on `ver` | **OPERATOR** | physical box, offline posture |
| 4 | Kit + artifact transfer | **OPERATOR** | offline channel (USB) by design |
| 5 | Kit verify + tool install (`ver-provision.sh`) | **AI-PREPARED** (scripted; you run it) | on `ver`, fail-closed |
| 6 | Solo enrollment (both tokens) | **OPERATOR + HARDWARE** | PIN + touch cannot be delegated |
| 7 | Sealed keystore + escrow (`ver-seal-keystore.sh`) | **AI-PREPARED** script, **OPERATOR + HARDWARE** run | token touch per unseal |
| 8 | Issue the one-way keys (`ver-provision.sh issue-keys`) | **AI-PREPARED** script, **OPERATOR** registers public halves | registration = browser session with WebAuthn |
| 9 | WireGuard 1:1 tunnel(s) | **OPERATOR** (template provided) | private keys generated per-side, never transported |
| 10 | First backup pull + smoke tests | **OPERATOR** (scripts do the work) | first run is supervised by policy (ADR-0025) |

Everything marked AI-PREPARED exists on branch `feat/ops25-ver-provision`:
`scripts/ver-provision/` (4 scripts + pins example), `templates/ver-*.tmpl`,
this runbook.

> **⚠ Connectivity decision needed (flagged on ops#25).** The issue's first
> checkbox says "join `ver` to the tailnet", but the threat model (CLAUDE.md)
> and ADR-0017/0025 say the opposite: **`ver` never joins the mesh** — it is
> offline by default and goes online only per session, via (a) outbound
> HTTPS to `<gitlab-host>` for bundle pulls and (b) the dedicated 1:1
> WireGuard tunnel per prod host for backup drains, ideally over a hotspot /
> dedicated modem rather than the home LAN. **This runbook follows the
> ADRs (no mesh).** If you actually want `ver` on the mesh, that's a threat-model
> change — record it as an ADR amendment first.

---

## 1. On `build-host` — build the kit and the artifact  *(AI-PREPARABLE, one command each)*

```bash
# 1a. pin the tools (one-time; see the file's header for the verify procedure)
cp scripts/ver-provision/ver-kit.pins.example scripts/ver-provision/ver-kit.pins
scripts/ver-provision/prepare-ver-kit.sh --print-sha256 restic     # then confirm & pin
scripts/ver-provision/prepare-ver-kit.sh --print-sha256 age
scripts/ver-provision/prepare-ver-kit.sh --print-sha256 fido2hmac

# 1b. assemble + sign the kit (needs the minisign secret key on this host)
scripts/ver-provision/prepare-ver-kit.sh          # → build/out/ver-kit/

# 1c. build the AI-free artifact ver will run
pl build-server                                   # → build/out/nwp-server/ + MANIFEST.sha256
```

Pin rule (step 1a is the **OPERATOR** part): a pin goes into `ver-kit.pins`
only after you've matched the observed sha256 against the checksums the
upstream project publishes (restic's `SHA256SUMS` is GPG-signed — verify that
signature per restic's docs). The kit build fails closed without pins.

## 2. On `ver` — base OS + posture  *(OPERATOR)*

- [ ] Current Ubuntu/Debian install, **full-disk encryption** (LUKS; ideally
      Solo-touch unlock via `systemd-cryptenroll --fido2-device`). **Per ADR-0028 a
      desktop is fine** (operator workstation) and a **browser is permitted** for
      reference/AI — but **no live AI agent, loop, or MCP server** ever runs on the
      box, and the full `pl` checkout is expected (`cd ~/nwp`). ("No AI on ver" =
      no AI *process with a shell*, not "no browser".)
- [ ] Create the working user; sshd **disabled or not installed** (nothing
      dials into `ver` — all its connections are outbound).
- [ ] **No mesh/tailnet client** (see the §0 warning). Network default-off:
      Wi-Fi off, ethernet unplugged; per-session connectivity via hotspot or a
      dedicated modem.
- [ ] `sudo apt-get update && sudo apt-get install -y minisign wireguard-tools libfido2-1 openssh-client`
      (during a deliberate online window or from local media; minisign is the
      only bootstrap verifier — everything else arrives signed in the kit).
- [ ] Timezone/NTP sane (restic snapshot times matter for retention).

## 3. Transfer + verify  *(OPERATOR — offline channel)*

Copy `build/out/ver-kit/` **and** `build/out/nwp-server/` to a USB stick,
walk it to `ver`, then:

```bash
# kit first — its manifest signature is the root of trust for everything else
cd /path/to/ver-kit
minisign -V -p nwp-minisign.pub -m KIT.sha256 && sha256sum -c KIT.sha256

sudo bash scripts/ver-provision.sh install --kit .   # verify → install tools + layout

# artifact next (ver-setup.md §3 smoke tests 2–3)
sudo mkdir -p /opt && sudo cp -r /path/to/nwp-server /opt/nwp-server
cd /opt/nwp-server && sha256sum -c MANIFEST.sha256
```

Trust note: verifying the kit against `nwp-minisign.pub` *from the kit itself*
is trust-on-first-use for the key. Close the loop by comparing the key ID with
the one on `build-host` (`minisign -V` prints it) over a second channel — read
it off the other screen; the key is public, only its *authenticity* matters.

## 4. Solo enrollment checklist  *(OPERATOR + HARDWARE)*

> **ADR-0028 (2026-07-09) supersedes the K/W split below.** Both tokens are now
> **WebAuthn** tokens: **Solo W** (primary carry) + **Solo W2** (independently
> enrolled backup — FIDO2 keys can't be cloned, so register W2 *separately* on
> GitLab, it is not a copy). Do the **Solo W** subsection for *both* (label the
> second `W2`). The **Solo K keystore** subsection is **DEFERRED** with the
> DR-backup half — skip it unless/until you set up restic backups. If you already
> part-built Solo K, **factory-reset it** and re-enrol it as Solo W. Full operator
> steps: [`ver-soloW-setup-walkthrough.md`](ver-soloW-setup-walkthrough.md).

### Solo K — the keystore token (stays with `ver`)  *(DEFERRED per ADR-0028 — skip for the deploy-half fast path)*

- [ ] Physically label it `K` (tape/engrave).
- [ ] Set a FIDO2 PIN (8+ digits, in the vault):
      `fido2-token -S /dev/hidraw<N>` (from `libfido2-1`'s tools, or
      `fido2-token -L` to find the device).
- [ ] Enroll the keystore identity (creates a new hmac-secret credential):
      `sudo /usr/local/share/nwp-ver/ver-seal-keystore.sh init`
- [ ] Round-trip test **twice**:
      `sudo /usr/local/share/nwp-ver/ver-seal-keystore.sh test`
- [ ] Storage: with `ver` (drawer/safe near the box). It never travels; it
      never touches another machine.
- [ ] Loss story: token lost ⇒ sealed entries unrecoverable **except via the
      escrow copies (§5)** — which is why escrow is mandatory, not optional.

### Solo W — the WebAuthn token (your carry token)

This one is **the linchpin precondition for the canonical runner-resident
ADR-0024**: production deploy authority = the right to merge / run the ▶ job in
GitLab, and that right must live **only** in a WebAuthn session — never in a
token file on any AI-reachable machine.

- [ ] Physically label it `W`.
- [ ] Set its FIDO2 PIN (different from Solo K's; in the vault).
- [ ] Enroll as WebAuthn 2FA on your `<gitlab-host>` account
      (Profile → Account → Two-factor authentication → WebAuthn device).
- [ ] Print/record the GitLab recovery codes → vault (this, not Solo K, is the
      W-loss story).
- [ ] Log out; log back in end-to-end with Solo W (browser **and** phone NFC —
      the phone tap is the whole point of the runner-resident model).
- [ ] Harden the account: TOTP fallback removed (or vaulted-only), strong
      password, admin sessions WebAuthn-only.
- [ ] **Linchpin sweep (pairs with this):** confirm no `api`-/`Maintainer`-scope
      GitLab token exists on any AI-reachable machine — bot tokens are
      Developer/`read_repository` only (`pl secrets check` covers the
      registry-known ones; the ADR-0024 admin-PAT downscope decision is still
      open — see the linchpin memory/ops notes).
- [ ] Only after all of the above may the protected `prod-deploy` runner work
      proceed (separate issue; not part of ops#25).

## 5. Sealed keystore + escrow  *(scripts ready; OPERATOR + Solo K to run)*

```bash
S=/usr/local/share/nwp-ver/ver-seal-keystore.sh
sudo $S seal ver-repo --generate --escrow        # ver's durable repo password
# one per prod source you'll drain (password of prod's LOCAL staging repo —
# generate here, seal here, then place the SAME value into
# /etc/nwp-server/restic.pass on that prod host, 0600, via the offline channel):
sudo $S seal <site>.from --generate --escrow
sudo $S list
```

- [ ] Move every `*.escrow.age` file to offline escrow media (vault), with the
      escrow passphrase written separately. Delete the `.escrow.age` files from
      `ver` once the vault copy is confirmed readable **on a third machine**.
- [ ] Also copy `keystore/fido2.identity` to the escrow media (it is required
      *in addition to* the token; without it even Solo K can't decrypt).
- [ ] Escrow drill (do it now, not during a disaster): on a scratch machine
      with `age`, decrypt one `.escrow.age` with the vault passphrase; confirm
      the plaintext matches (`sudo $S unseal <name>` on `ver` + compare); shred
      both plaintexts.

## 6. Issue + register the one-way keys  *(script ready; OPERATOR registers)*

```bash
sudo bash /usr/local/share/nwp-ver/ver-provision.sh issue-keys
```

Prints the two public halves and exact registration instructions:

- [ ] `bundle-pull.pub` → **read-only deploy key** on the signed-bundle project
      at `<gitlab-host>` (browser session, gated by Solo W — fitting).
- [ ] `restic-pull.pub` → each prod host's backup user, **using the
      forced-command template** (`templates/ver-restic-authorized-keys.tmpl`:
      `internal-sftp -R`, rooted at the repo parent, `restrict`) plus the sshd
      `Match`-address block from the WireGuard template.
- [ ] The **sanitized-publish** key is deliberately **not** issued here:
      `ver` doesn't publish. When provisioning a `prod-agent` host, add
      `--with-publish-key` — the publish verb's sanitize → PII-gate →
      write-only-upload chain was validated 2026-07-02 (nwp/ops#23).
- [ ] Optional (recommended): the **verifier-say** post-only token, so `ver` can
      report errors to the ops queue — the documented least-privilege exception
      to "zero tokens" (it can post issues to one log project, nothing else).
      Use the verifier-say setup kit already in-repo (the one-shot setup script
      under `scripts/` and its operational-readiness guide under `docs/guides/`
      — their filenames carry the host's private role binding, so they aren't
      spelled out here: `ls scripts/*-setup.sh docs/guides/*operational-readiness*`).
- [ ] Ledger assertion (ver-setup.md smoke test #4):
      `sudo bash /usr/local/share/nwp-ver/ver-provision.sh check`

## 7. Tunnel(s)  *(OPERATOR; template provided)*

Per prod host: follow `templates/ver-prod-wireguard.conf.tmpl` (in the kit).
Generate each side's keypair **on that side**; exchange only public keys.

- [ ] prod side: `verlink` interface up, sshd `Match` block installed,
      firewall allows udp/51820 only.
- [ ] `ver` side: config saved as `/etc/wireguard/verprod<N>.conf`, **not**
      enabled at boot — `ver-pull-session.sh --wg verprod<N>` brings it up and
      down per session.
- [ ] Connectivity check during one deliberate online window:
      `wg-quick up verprod<N>; ping -c2 10.66.<N>.1; sftp -i /etc/nwp-server/keys/restic-pull_ed25519 <backup-user>@10.66.<N>.1` (expect a
      read-only sftp prompt rooted at the repo parent — try `put`; it must fail);
      `wg-quick down verprod<N>`.

## 8. First backup, end to end  *(OPERATOR; supervised first run per ADR-0025)*

```bash
# on the prod host (the nwp-server artifact is already deployed there):
nwp-server backup --site-dir <SITE_DIR> --restic-pub /etc/nwp-server/nwp-minisign.pub          # dry-run
nwp-server backup --site-dir <SITE_DIR> --restic-pub /etc/nwp-server/nwp-minisign.pub --execute

# on ver — configure sources once:
echo '<site>|sftp:<backup-user>@10.66.<N>.1:/var/backups/nwp-server/<site>|/srv/ver-backups/<site>' \
  | sudo tee -a /etc/nwp-server/pull-sources.conf

# then the session (dry-run first, then execute; Solo K touch when prompted):
sudo /usr/local/share/nwp-ver/ver-pull-session.sh --wg verprod<N>
sudo /usr/local/share/nwp-ver/ver-pull-session.sh --wg verprod<N> --execute
```

The session script unseals → drains (`restic copy`) → applies retention →
`restic check --read-data-subset` → **shreds the unsealed passwords and tears
the tunnel down on every exit path**.

- [ ] Restore drill (the "0" in 3-2-1-1-0, monthly from now on): on `ver`,
      `restic -r /srv/ver-backups/<site> restore latest --target /tmp/drill`
      (password via `ver-seal-keystore.sh unseal ver-repo`), confirm the DB dump
      gunzips and the files tree looks sane, then shred `/tmp/drill`.

## 9. Close out ops#25

- [ ] Work through `ver-setup.md` §7's smoke-test table; every PENDING row above
      should now read DONE.
- [ ] `verifier-say` TEST message posted and visible in the ops queue.
- [ ] Record results (incl. the §0 tailnet decision) as a comment on nwp/ops#25
      and close it.

## Related

- [`ver-setup.md`](ver-setup.md) — concepts, trust posture, smoke-test table
- [`nwp-single-machine.md`](nwp-single-machine.md) — the same build as the minimal one-machine install
- ADR-0017 · ADR-0022 · ADR-0024 · ADR-0025 · ADR-0026 (post-MR !28 numbering)
- `scripts/ver-provision/` — the four scripts this runbook drives
