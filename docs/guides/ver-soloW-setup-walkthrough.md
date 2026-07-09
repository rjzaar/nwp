# ver + Solo W setup — operator walkthrough

> **Audience:** the operator, at the ver box + a browser. Written for someone who
> is **not a full-time terminal user** — every command says what it does and why.
> **Basis:** [ADR-0028](../decisions/0028-ver-single-operator-human-gated-workstation.md).
> **Companion:** [`ver-provisioning-runbook.md`](ver-provisioning-runbook.md) (the
> full turnkey sequence; this is the *deploy-half fast path*).

**What you'll have at the end:** a desktop ver box you can sit at, run the full
`pl` on, use a browser (incl. AI) on — where **pushing to prod needs a Solo touch**
and nothing else can reach prod. Two Solos (W = carry, W2 = drawer backup), your
phone as a passkey, no daily passwords beyond your vault + laptop login.

The **only two "somethings you know"** in the whole setup: your **disk/login
password** and your **vault master password**. Everything else is a tap.

---

## Part A — the ver box (desktop, encrypted, full `pl`)

1. **Install Ubuntu Desktop LTS** with **"Encrypt the disk" (LUKS)** ticked during
   install. (Which version → see the note at the bottom.) Set a strong disk
   password; you'll type it (or tap — Part E) once per boot.
2. **Don't** install any AI agent, autonomous loop, or MCP server on it. A browser
   (for claude.ai/reference) is fine — that's not "AI on the box", it can't run
   commands.
3. **Get the full `pl`** onto it:
   ```bash
   git clone <your-gitlab-host>/nwp/nwp.git ~/nwp
   cd ~/nwp && ./pl doctor        # sanity check
   ```
4. **Install a graphical diff tool** so reviewing a change before deploy is
   point-and-click (pick one): `sudo apt install -y meld` (or `gitg` / `git-cola`).
5. **Keep it offline by default** — connect Wi-Fi/ethernet only during a deliberate
   window; ver is **not** on the mesh/tailnet.

## Part B — the Solos and your phone

6. **Factory-reset the part-built Solo K** (you're repurposing it — this wipes the
   half-done keystore credential + its PIN):
   ```bash
   sudo apt install -y fido2-tools
   fido2-token -L                 # find the device path, e.g. /dev/hidraw0
   fido2-token -R /dev/hidraw0    # RESET — wipes all credentials on the key
   ```
   This is now your **Solo W** (label it `W` with tape). The other Solo is **W2**
   (label it, keep it in a drawer).
7. **Enrol both on GitLab as WebAuthn** (in the **browser**, on your laptop or ver):
   *Profile → Account → Two-Factor Authentication → Register WebAuthn device.*
   Do it **twice** — once with Solo W, once with Solo W2. They are separate
   registrations (a backup key is not a copy).
8. **Add your phone** as a passkey/WebAuthn method too (same screen, or via your
   phone's passkey prompt). Now GitLab login = a tap on the phone or a Solo.
9. **Print the GitLab recovery codes → your vault.** (WebAuthn has no recovery codes
   of its own; this + Solo W2 is your "lost key" story.)
10. Keep your **GitLab account password in your vault** (KeePassXC). Day-to-day login
    is: vault fills the password + one tap. No device PIN needed for 2FA use.

## Part C — the linchpin sweep (do this once, it's the real security win)

11. **Revoke the two root-admin GitLab PATs** (dev "nwp-api", the local-agent host "llm_bot"):
    *Profile → Access Tokens → Revoke.* Reissue the loop's token as **Developer**
    role, `read_repository`+`write_repository` only (no `api`, not admin).
12. **Shred the stale PATs** the ops#25 scan already found on the dev box:
    ```bash
    shred -u ~/.config/nwp-agent-loop-backup/nwp-agent-loop.env.20260520
    # + the VSCodium history copies it flagged
    ```
13. **Confirm** admin is now tokenless (WebAuthn-only): log out, log back in with
    Solo W. There should be no admin PAT left on any AI-reachable machine.

## Part D — the deploy touch-key + gate

14. **Generate your `ed25519-sk` signing key on Solo W** (touch when it flashes):
    ```bash
    ssh-keygen -t ed25519-sk -O resident -C "rob-deploy" -f ~/.ssh/id_ed25519_sk
    ```
    (`-O resident` lets you recover it onto a fresh machine from the key itself.)
15. **Build the allowed-signers file** ver checks against (public key only — safe):
    ```bash
    mkdir -p ~/nwp/keys
    printf 'rob@nwp %s\n' "$(cut -d' ' -f1-2 ~/.ssh/id_ed25519_sk.pub)" \
      > ~/nwp/keys/allowed_signers
    ```
    (When a co-signer earns release rights later, append their line here — that's
    rung 3 of the dev ladder.)
16. **Turn the gate ON and fail-closed** on ver — add to `~/.bashrc`:
    ```bash
    export NWP_DEPLOY_ALLOWED_SIGNERS="$HOME/nwp/keys/allowed_signers"
    export NWP_DEPLOY_SK_KEY="$HOME/.ssh/id_ed25519_sk"
    export NWP_DEPLOY_GATE_REQUIRE=true    # unconfigured = ABORT, never silent-skip
    ```
    Now every `pl stg2live` / `live2prod` / `stg2prod` prints a plain-English
    "here's what this will do", asks you to **touch Solo W**, verifies the touch,
    and only then writes to prod. No touch → no deploy.

## Part E — (optional) unlock the disk with a Solo tap

17. Turn the boot password into a Solo tap:
    ```bash
    sudo systemd-cryptenroll --fido2-device=auto /dev/<your-luks-partition>
    ```
    (Keep the disk password too, as a fallback.) Now boot = tap Solo W.

## Part F — prove it works (safe, no real deploy)

18. **Dry run** — shows the flow, writes nothing:
    ```bash
    ./pl stg2live <a-test-site> --dry-run
    ```
19. Then on a **throwaway test site** (never real prod), run it for real once and
    confirm: you get the DEPLOY GATE box → touch prompt → `✓ authorized by: rob@nwp`
    → deploy proceeds; and that **declining the touch aborts** it.

---

## How the two "touches" split (they're on different machines)

| Touch | Where | Authorizes |
|---|---|---|
| **Phone / Solo W (WebAuthn)** | laptop or phone **browser** | GitLab: login, merge, ▶ |
| **Solo W on USB (`ed25519-sk`)** | **ver** console | signing the deploy — the "push to prod" tap |

ver never needs a browser *for the touch* — the WebAuthn taps happen wherever you
have a browser; the deploy tap is Solo-in-USB at the ver keyboard.

## The one rule
Every prod-write goes through the touch+signature gate. That — not the absence of a
browser — is what keeps prod safe, so even a mistyped command or a bad paste can't
reach production without your physical Solo touch.

## Which Ubuntu?
Use an **LTS** (never an interim like 25.10). Both **24.04 LTS** and **26.04 LTS**
work. **24.04 LTS** is the safer pick for this box — it's battle-tested and every
tool `pl` leans on (Docker/ddev, `libfido2`, `systemd-cryptenroll`) is known-good on
it, with support to 2029. **26.04 LTS** is fine if you want the longer runway and
don't mind a ~3-month-young ecosystem. When unsure: **24.04 LTS**.
