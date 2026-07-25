# Fleet test links — click-through smoke test

**What this is:** every clickable surface in the fleet, in one list, with a tick
box and a one-line "what you should see". Walk it top to bottom and you have
hand-tested the whole estate.

**Last verified:** 2026-07-25 (re-checked against `main` 2026-07-26). Verified links are marked ✅; problems found on the
day are marked ⚠️ and repeated in [Known problems](#known-problems-2026-07-25).

**How to use it:** open each link, compare with the expected result, tick the box.
If something differs, note it and move on — don't stop the walk.

> Some entries redirect on purpose. Those are listed under
> [Redirects that are correct](#redirects-that-are-correct) — do not report them
> as faults.

---

## 1. Narrow Way Commons — `nwc.nwpcode.org`

The main community site. Drupal on Open Social.

### Logged out

- [ ] https://nwc.nwpcode.org/ — ✅ home page loads, browser tab says *Narrow Way Commons*
- [ ] https://nwc.nwpcode.org/user/login — ✅ log-in form
- [ ] https://nwc.nwpcode.org/apply — ✅ "Apply to join the Narrow Way community" application form
- [ ] https://nwc.nwpcode.org/consecration — a Consecration page
- [ ] https://nwc.nwpcode.org/trial — ⚠️ should be "Try a course"; currently **404**
- [ ] https://nwc.nwpcode.org/demo/join — **404 is correct here.** This is the real site, not the demo.

### Logged in (log in first — all of these refuse anonymous visitors)

- [ ] https://nwc.nwpcode.org/welcome — the welcome/orientation page
- [ ] https://nwc.nwpcode.org/nwc/help/all — the help section, all topics
- [ ] https://nwc.nwpcode.org/my-work — your work queue
- [ ] https://nwc.nwpcode.org/nwc/achievements — your achievements
- [ ] https://nwc.nwpcode.org/story/contribute — contribute a story
- [ ] https://nwc.nwpcode.org/guild-resources — guild resources
- [ ] https://nwc.nwpcode.org/community/suggestions — suggestion box
- [ ] https://nwc.nwpcode.org/my/feedback — your feedback
- [ ] https://nwc.nwpcode.org/examen — the examen tool
- [ ] https://nwc.nwpcode.org/my/formation-consent — ⚠️ your consent settings (may 404 — see problem 4)
- [ ] https://nwc.nwpcode.org/my/formation-shares — ⚠️ who your formation data is shared with (may 404)
- [ ] https://nwc.nwpcode.org/report-error — the "report a problem" form

Guild pages need a guild id — from a guild page, check:
`/group/<id>/guild-dashboard`, `/leaderboard`, `/my-skills`, `/ratification-queue`, `/workflow`

### Administrator only

- [ ] https://nwc.nwpcode.org/admin/nwc/registration/review — pending applications
- [ ] https://nwc.nwpcode.org/admin/nwc/trials — trialing members
- [ ] https://nwc.nwpcode.org/admin/nwc/annotations — annotation moderation
- [ ] https://nwc.nwpcode.org/admin/nwc/help — help-topic management
- [ ] https://nwc.nwpcode.org/admin/config/nwc/guild — guild configuration

---

## 2. The demo tier — `nwd.nwpcode.org`

Wiped and rebuilt from a golden image. Safe to break.

- [ ] https://nwd.nwpcode.org/ — ✅ loads; site name reads **"Saint School Demo"** *(cosmetic oddity: this is the Commons demo — see problem 8)*
- [ ] https://nwd.nwpcode.org/demo/join — ✅ "Join the demo" — the invite-code box
- [ ] https://nwd.nwpcode.org/user/login — ✅ log-in form

**Full end-to-end demo test** (about two minutes):

- [ ] Get a code: `pl demo invite nwd`
- [ ] Paste it at `/demo/join` → you land logged in, with a saint's name
- [ ] Click around; confirm the "this is a demo" banner is visible
- [ ] Reset it: `pl demo reset nwd --tier=live`
- [ ] Confirm your test account is gone and the site is back to the golden state
- [ ] Confirm your code still works (codes survive the wipe)

### Demo Moodle — `ssd.nwpcode.org`

- [ ] https://ssd.nwpcode.org/ — ✅ home page, visible without logging in
- [ ] https://ssd.nwpcode.org/local/browse/ — ⚠️ should be the course front door; currently shows the plain home page (see problem 6)
- [ ] https://ssd.nwpcode.org/login/index.php — log-in form

---

## 3. Saint School — `ss.nwpcode.org`

The live Moodle for the whole fleet. **Note:** the address is `ss` but the files
it serves live in the `ssc` directory. That is expected.

- [ ] https://ss.nwpcode.org/ — ✅ **redirects to the log-in page** — correct, this Moodle requires log-in
- [ ] https://ss.nwpcode.org/local/browse/ — ✅ the course front door, "Saint School" — **works without logging in**
- [ ] https://ss.nwpcode.org/local/browse/?view=curated — the "Where to begin" tab
- [ ] https://ss.nwpcode.org/local/browse/?view=ascent — the "The journey" tab
- [ ] https://ss.nwpcode.org/local/browse/?view=browse — the "Browse everything" tab
- [ ] https://ss.nwpcode.org/my/ — your dashboard (log in first)
- [ ] https://ss.nwpcode.org/course/ — the course list (log in first)
- [ ] https://ss.nwpcode.org/local/feedback/index.php — the feedback plugin
- [ ] https://ss.nwpcode.org/admin/search.php — site administration (admin only)

**The single-sign-on test — the most valuable check on this page:**

- [ ] Log out of everything
- [ ] Go to Saint School and choose to sign in with Narrow Way Commons
- [ ] You land back in Saint School, logged in, without typing a second password
- [ ] Open a course with lesson content and answer a question — it saves

### Old addresses that now redirect

- [ ] https://ssc.nwpcode.org/ — ✅ redirects to `ss.nwpcode.org` (correct)
- [ ] https://ss2.nwpcode.org/ — ✅ redirects to `ss.nwpcode.org` (correct)

---

## 4. Other live sites

### AV Commons — `avc.nwpcode.org` (frozen; the predecessor to Narrow Way Commons)

- [ ] https://avc.nwpcode.org/ — ✅ home page
- [ ] https://avc.nwpcode.org/user/login — ✅ log-in form

### Divine Intimacy Radio — `dir.nwpcode.org`

- [ ] https://dir.nwpcode.org/ — ⚠️ **403 "Access denied"** for visitors. Gated on purpose, but a bare refusal rather than a log-in prompt (see problem 5)
- [ ] https://dir.nwpcode.org/user/login — ✅ log-in form
- [ ] the transcript search page — log in first; the path lives in site configuration, not code

### Restore The Glory — `rgs.nwpcode.org` (Moodle, gated)

- [ ] https://rgs.nwpcode.org/ — ✅ redirects to the log-in page (gated by design)

### benedicta.art

- [ ] https://ba.nwpcode.org/ — ✅ "Welcome | benedicta.art"
- [ ] https://benedicta.art/ — ⚠️ **times out** — the vanity domain points at the registrar, not our server (see problem 2)

### CathNet — `ccc.nwpcode.org`

- [ ] https://ccc.nwpcode.org/ — ✅ "CathNet — Catechism Concept Map"

### Mass Times — `mt.nwpcode.org`

- [ ] https://mt.nwpcode.org/ — ✅ home page

### Mayo Studios (a separate server)

- [ ] https://mayostudios.org/ — ✅ "Mission Action Youth Organization"
- [ ] https://mayostudios.org/user/login — ✅ log-in form
- [ ] https://saintschool.mayostudios.org/ — ✅ home page
- [ ] https://saintschool.mayostudios.org/user/login — ⚠️ **bare 404** (see problem 1 — the worst one on this page)

### Rosary Forge

- [ ] https://pray.rosaryforge.org/ — ✅ "The Mysteries of the Rosary" — ⚠️ **expect a slow load**, the page is about 4.4 MB

---

## 5. Infrastructure

### GitLab — `git.nwpcode.org`

All projects are private, so logged out you get the sign-in page. That is correct.

- [ ] https://git.nwpcode.org/ — ✅ sign-in page
- [ ] https://git.nwpcode.org/nwp/ops/-/boards — ✅ **the work board** — this is where all work is tracked
- [ ] https://git.nwpcode.org/nwp/ops/-/issues — the issue list
- [ ] https://git.nwpcode.org/nwp/nwp — the NWP tooling repository
- [ ] https://git.nwpcode.org/nwp/nwc — the Narrow Way Commons profile
- [ ] https://git.nwpcode.org/nwp/ss-moodle-plugins — the Saint School Moodle plugins
- [ ] https://git.nwpcode.org/groups/nwp/-/merge_requests — everything awaiting review

> ⚠️ This machine has only 3.8 GB of memory and also runs five live sites. Never
> run heavy administration commands on it — doing so took production down for
> several minutes on 2026-07-25.

### Headscale (the private network controller) — `hs.nwpcode.org`

- [ ] https://hs.nwpcode.org/ — ✅ a blank page with a 200 response is the healthy answer (there is no web interface)

### Test tier — `test.nwpcode.org`

- [ ] https://test.nwpcode.org/ — ⚠️ **certificate error** — nothing is set up here yet (see problem 3)

---

## 6. The NWP Console — private network only

**You must be on the network mesh for these to answer at all.** From an ordinary
internet connection they will hang. That is correct behaviour, not a fault.

- [ ] https://console.nwpcode.org:8600/health — a bare health response
- [ ] https://console.nwpcode.org:8600/ — the dashboard; sign in with your passkey
- [ ] **Fleet** tab — red/amber/green per site
- [ ] **Issues** tab — the work board
- [ ] **Todo** tab — outstanding tasks
- [ ] **Demo** tab — last reset and outstanding invite codes
- [ ] **Backups** tab — which sites have gone stale
- [ ] **CI** tab — merge requests and pipelines
- [ ] **Quokka** tab — ask it "summarize today". *"Quokka is asleep"* means the local
      model is not running — the other tabs still work, this is not a failure
- [ ] https://console.nwpcode.org:8600/audit — who did what
- [ ] https://console.nwpcode.org:8600/users — manage people (owner role only)

See [How to: use the NWP Console](howto-console.md).

---

## 7. Local development sites (DDEV)

These only work on the workstation, and only while the container is running.
Check with `ddev list`; start one with `ddev start` from its directory.

### Running as of 2026-07-25

| Link | What it is |
|------|-----------|
| [ ] https://nwc-dev.ddev.site | Narrow Way Commons — development |
| [ ] https://nwc-stg.ddev.site | Narrow Way Commons — staging |
| [ ] https://nwc-test.ddev.site | the isolated automated-test copy |
| [ ] https://nwd-dev.ddev.site | demo tier — development |
| [ ] https://nwd-stg.ddev.site | demo tier — staging |
| [ ] https://ssc-dev.ddev.site | Saint School Moodle — current development tree |
| [ ] https://ss-dev.ddev.site | Saint School v3 build tree |
| [ ] https://ss2-dev.ddev.site | Saint School v1 — frozen archive |
| [ ] https://avc-dev.ddev.site | AV Commons (frozen) |
| [ ] https://nw1-dev.ddev.site | the archived previous Commons |
| [ ] https://dir1-dev.ddev.site | Divine Intimacy Radio |
| [ ] https://cathnet-dev.ddev.site | CathNet |
| [ ] https://mt-dev.ddev.site | Mass Times |
| [ ] https://ba-dev.ddev.site | benedicta.art |
| [ ] https://mayo-dev.ddev.site | Mayo Studios |
| [ ] https://nwt-dev.ddev.site | test fixture |
| [ ] https://mg.ddev.site | mg |

Moodle development sites also have: `/local/browse/`, `/login/index.php`, `/my/`,
`/local/feedback/index.php`, and on `ssc-dev` also `/local/practice/index.php`.

### Registered but stopped

`ss-stg`, `ssd-dev`, `mayo-stg`, `nwt-stg` — run `ddev start` in the directory first.

### Configured but not registered

`avc/stg`, `ba/stg`, `cathnet/stg`, `cccrdf/dev`, `dir1/stg`, `mt/stg`, `nw1/stg`,
`saintschool/dev`, `ss2/stg` — these need `ddev start` from their directory before
any address exists.

---

## Redirects that are correct

Do not report these:

| Address | Goes to | Why |
|---------|---------|-----|
| `ss.nwpcode.org/` | its log-in page | Moodle requires log-in |
| `rgs.nwpcode.org/` | its log-in page | gated by design |
| `ssc.nwpcode.org/*` | `ss.nwpcode.org/*` | site consolidation |
| `ss2.nwpcode.org/*` | `ss.nwpcode.org/*` | site consolidation |
| `git.nwpcode.org/*` | the sign-in page | all projects are private |
| `nwc.nwpcode.org/demo/join` | 404 | correct — this is the real site |
| `nwt.nwpcode.org` | no such address | live deployment is switched off |
| the console, from off the mesh | no answer | private network only |

---

## Known problems (2026-07-25)

Worst first.

1. **`saintschool.mayostudios.org/user/login` returns a bare 404** while the home
   page works. A raw web-server 404 on a core path means the address-rewriting
   rule is missing from that site's web-server configuration — only the front
   page is reachable.
2. **`benedicta.art` times out.** The domain points at the registrar's parking
   address, not our server. The site itself is fine at `ba.nwpcode.org`; the
   vanity domain was never switched over.
3. **`test.nwpcode.org` has no certificate.** The address exists but nothing is
   configured. This is the address designated for automated testing, so it is not
   currently usable for that.
4. **`nwc.nwpcode.org/trial` returns 404** although the code for it ships in the
   site. Most likely the privacy module is not switched on in production — which
   would also explain the consent pages. Worth checking properly, because those
   are the data-protection surfaces.
5. **`dir.nwpcode.org` refuses visitors with a bare "Access denied".** Gating is
   intended, but it should send people to a log-in page like the other gated
   sites do, not a dead end.
6. **`ssd.nwpcode.org/local/browse/` shows the home page**, not the course front
   door. The course-browsing plugin appears to be missing from the demo Moodle.
7. **Configuration does not match reality for `ssc` and `ss2`.** Both still claim
   their own live addresses in configuration, but both now redirect to `ss`. And
   `sites/ss/.nwp.yml` still points at the retired `/var/www/ss`. Nothing is
   broken for a visitor, but tools that read those settings will aim at the wrong
   place.
8. **`nwd` calls itself "Saint School Demo"** even though it is the Commons demo.
   Cosmetic, but confusing to a first-time tester.
9. **`sites/nwc/.nwp.yml` does not exist.** The Commons site configuration is
   still physically at `sites/nw1/.nwp.yml`, left behind by a rename. Anything
   looking it up by the standard path will not find it.

---

## See also

- [How to: use the NWP Console](howto-console.md)
- [How to: run the demo tier](howto-demo-tier.md)
- [Fleet overview](../overview/README.md) — what each of these sites is for
- `pl monitor uptime` — the automated version of this page
- `pl rag` — the red/amber/green fleet rollup
