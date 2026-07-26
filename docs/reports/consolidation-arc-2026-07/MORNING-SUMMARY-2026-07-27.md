# Morning Summary — 2026-07-27

Covers the overnight run of 2026-07-26 → 27. Supersedes nothing; `MORNING-SUMMARY.md` is the
2026-07-25 edition and stays as-is.

**41 merges landed on `main` in 12 hours.** Twelve MRs are still open, most in `conflict` because
`main` moved under them; a serializer agent is working the queue.

---

## 1. Needs you — in this order

### 🔴 Revoke `linode.provision_token`

Verified by live probe:

| token | `/v4/linode/instances` | `/v4/domains` | `/v4/account` |
|---|---|---|---|
| `linode.api_token` | **401** | 200 | 401 |
| `linode.provision_token` | **200** | 200 | 401 |

`provision_token` enumerates **`gitlab-nwp-1767074243`** (the production forge — GitLab + 5 live
sites) and `podcast-gm-20260112`. A `DELETE /v4/linode/instances/99999999` probe returned **404 =
authorized, absent**: destroy power, not just read.

It lives in `.secrets.yml`, the tier CLAUDE.md designates **AI-readable**. So the threat model's
first rule — *no AI-run machine may hold a key that reaches a production server* — does not
currently hold.

The registry had it backwards: it labelled `api_token` "account-scoped = prod blast radius" (it is
DNS-only) and did not track `provision_token` at all.

**Cost of revoking: `pl ver-test` only.** Sole consumer is `scripts/commands/ver-test.sh:111`, which
already fails closed and prefers `NWP_VERTEST_LINODE_TOKEN`.

```
# https://cloud.linode.com/profile/tokens  → revoke, then:
yq e -i 'del(.linode.provision_token)' .secrets.yml
```

When test Linodes are next needed, mint a short-lived token — ideally in a Linode **child account**
holding no prod instances, so the blast radius is bounded structurally rather than by policy.

### 🔴 Move four credentials out of the AI-readable tier

`.secrets.yml` also holds `gitlab.admin.password`, `gitlab.admin.initial_password`,
`gotify.admin_password`, and **`restic.dr_pull.password`** — the last decrypts prod-user-data
backups. I am deny-ruled from `.secrets.data.yml` and must not perform the move.

```
pl secrets migrate-tier gitlab.admin.password        # …and the other three
```

Also decide `restic.dr_pull.password`: a grep across the repo **and** met finds **zero consumers**.
Adopt it with a named consumer, or delete the key. It is now recorded `criticality:
non-recoverable` — losing it makes every DR snapshot unreadable, and nothing currently tells you.

### 🟠 Review two `REVIEW:`-tagged MRs — auto-merge deliberately NOT armed

- **!213** — secrets registry truth. The agent **refused** to arm auto-merge because `lib/*secret*`
  and `.secrets*` are CLAUDE.md sensitive paths requiring two-person approval. That refusal was
  correct and I did not override it.
- **!212** already merged (fail-closed guards) but is also `REVIEW:` class.

### 🟠 Start mini's GitLab runner

mini sits at **load 0.02 on 32 cores** with a registered runner **stopped**, while met carries the
entire CI queue. MR !197's pipeline had all 13 jobs pending with *no runner* — so that work had
never been gated by CI at all. Needs your sudo password:

```
ssh rob@100.64.0.2 'sudo systemctl enable --now gitlab-runner'
```

### 🟡 Smaller ones

- **`pl pair record ssc provider live <cv>`** — `ssc` has no recorded provider deployment, so D5
  fires ahead of D6 and even `--code-only` is refused. Recording it is an assertion about what nwc
  live is actually running; an agent should not make it.
- **`met:~/backups/carlo/`** — 70 `auth.json` + one complete `.secrets.yml`; **6 of 7 credentials
  byte-identical to production**. Reported, not remediated — shredding your backups is your call.
  See `FINDING-met-credential-sprawl.md`. Revoking the old composer token neutralises 31 of the 70.
- **`nwp.yml` needs `sites.ssc.paired_with: nwc`** — applied by hand, but `nwp.yml` is gitignored,
  so **re-apply if this tree is rebuilt**. `example.nwp.yml` has instructed it since ops#75.
- **`gitlab.server.ip` is still the literal `YOUR_SERVER_IP`**, which blocks placeholdering the
  forge IP and therefore blocks tracking the registry in git.
- Delete `nwp/nwc!48` (a closed audit-probe MR; the non-admin bot gets 403).

---

## 2. Corrections to things I told you

- **`.secrets.yml:gitlab.api_token` is NOT the root admin PAT.** It is `group_9_bot` (id 27,
  `is_admin: null`, Developer) and has been since the 2026-07-18 cutover — CLAUDE.md says so at
  lines 172-178. My "~24 forced uses of the root admin PAT" was wrong. **No scoped MR token needs
  minting.**
- **`pl secrets audit` was not broken.** `pl` runs from `/home/rob/nwp`, which had drifted 16
  commits behind, so every call executed the pre-fix script. `rotate` *was* genuinely broken.
- **met can reach the forge** (https 302, api 200). Only its `~/nwp` remote points at a stale
  GitHub mirror.
- **Project IDs:** `nwp/nwp` = **9**, `nwp/nwc` = 16, `nwp/ops` = 21.

---

## 3. What landed

**The demo tier works end to end on live.** `nwd.nwpcode.org/.well-known/jwks.json` **500 → 200**
with a real RSA key; ssd's login page offers the **"nwd (F26)"** button; the full journey drives
through with real requests — join → IdP → `/oauth/authorize` → examen gate → callback → 200, with
`mdl_user.idnumber` matching the nwd account UUID (UID lock intact) and `auth_nwc_art9_consent = 1`.
`/apply` on nwd is fixed (nwd was **99 config entities** short of nwc — a reinstall, not drift).

**Guards that could not fail, now can.** `pl pair check ssc live` (full DB) → **REFUSE**; so does
`nwc live`. `lib/canonical.sh`, two PII sweeps and the Moodle core-patch gate now return
CANNOT-VERIFY instead of silently degrading to the weakest setting.

**Vacuous passes found and fixed:** `pl monitor uptime` was watching 2 of 8 targets (a `\t` yq
4.44 doesn't expand); the met nightly audit reported "no change" for **33 nights** over stopped
containers, hiding **20 advisories incl. a high-severity twig sandbox escape, CVE-2026-49981**.

**The public-release scrubber is now trustworthy — this unblocks the "public" docs library.**
Its test failed open: gitleaks' rc was discarded and cleanliness judged from a report that a bare
`except Exception: rows = []` turned into "0 findings". Reproduced with a malformed rule plus a real
`/home/rob/nwp/lib/common.sh` leak planted in an in-scope doc → **8/8 green with the leak present**.
Now `pubrel_scan` returns `0 clean / 1 findings / 2 COULD NOT SCAN`, rc and report must agree, and a
missing scanner **fails** the file rather than skipping (a skip reports as `ok`). The identity-rule
grep covered 4 of 6 and now mirrors all six.

⚠️ **Its sibling !193 had the same defect, pointed the other way and worse.** In the
`.gitleaksignore` checker an empty report classifies **every** fingerprint as STALE — and that
script's own workflow says "delete only the `-- stale --` lines". A stub scanner produced
*"79 declared / 0 live / 79 STALE, safe to retire"*. Acting on it would have deleted the entire
leakage-suppression ledger. Also fixed (exit 3 = CANNOT VERIFY, which its header already promised).

The two tools now cross-check: after !197's scrub, !193's checker independently reports
**4 declared / 4 load-bearing / 0 stale / 0 unsilenced** — confirmation of the scrub by a different
mechanism. Merged as `f7b0fca` and `fed28f6`; real pipelines (1157, 1162), all blocking jobs green.

---

## 4. The pattern

Nearly every serious finding tonight was the same shape: **a check that could not fail**, or a
guard that read "I could not tell" as "nothing to enforce."

`| head -1` on a multi-location audit · `set -o pipefail` with `yq | grep -q` where SIGPIPE makes
the guard never fire · `mapfile < <(reader)` discarding the reader's exit status · gitleaks' rc
thrown away and cleanliness judged from a report that failed to exist · empty config mapping to the
weakest enum · a nightly job whose "no change" and "couldn't look" were indistinguishable.

The countermeasure that actually worked was **making every fix prove its test goes red**, and
**gating merges on an independent adversarial reviewer** rather than running verification alongside
the merge. The gate refused work three times tonight; at least twice it was right in ways nobody
had suspected.

### A check I prescribed all night turned out to be insufficient

I told every agent to resolve append-only conflicts by keeping both sides and proving zero loss with
`comm` against both parents. On !206 that resolution **silently broke the YAML**: the conflict region
ended before a shared trailing `rules:`/`tags:`/`allow_failure:` block, so those bound to the wrong
job and left `lint:registry-ids` **untagged** — a blocking job no runner could ever claim, on every
merge request. It sat `pending` for 1205s while its stage-mates finished in ~3s.

`comm` did not catch it. **Every line was present; they were attached to the wrong key.** Line
presence is not structure preservation.

**New rule for structured files (YAML, JSON, TOML):** after a keep-both merge, re-verify
*structurally* — parse both parents and the result as data and diff the object, not the text. Now
recorded in the decision log.

Two related CI findings from the same pass, both `REVIEW:`-tagged and wanting human eyes:
- `test:unit` ran on a **shallow clone**, so three negative controls that read commits 104 and 558
  back silently **skipped** — and the skip count varied with runner cache, which is why main
  pipeline 1167 went red and 1169 didn't. Fixed with `GIT_DEPTH: "0"`.
- `NWP_BATS_MAX_SKIPPED` as a job variable **leaked into nested `run-bats.sh` invocations** that
  relied on the ambient default. `run-bats.sh` now unsets it after resolving its own.

And one more test that guarded nothing: a check grepped the bare substring `merge_requests|blob|tree`,
which also matches two **comment** lines in `.gitleaks.toml` — so deleting both live allowlist
regexes left 2 matches and the test stayed green. Now counts only `'''`-quoted rule lines.

Two structural weaknesses remain unfixed and will keep generating this class:
1. `pl` executes from `~/nwp`, which drifts behind while agents merge — every `pl` result is only
   as current as that directory, and nothing says so. (MR !200 addresses it.)
2. Guards whose only input is a gitignored file (`nwp.yml`, `sites/*`) cannot be observed to be
   wrong by any reviewer or CI job.
