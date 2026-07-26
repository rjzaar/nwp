# NWP Console — Feedback tab: build-ready specification

**Status:** SPEC ONLY — nothing built. Do not implement until the console v2 workflow
lands and the operator decisions in §14 are answered.
**Date:** 2026-07-26
**Author:** design pass (research agent), consolidation arc 2026-07
**Collision:** a concurrent workflow owns `scripts/console/`. **No file under
`scripts/console/` was written by this pass.** Everything in §13 that lives under that
tree is handed to the v2 owner; everything outside it is buildable immediately.

---

## 0. The ask, restated

> "add a feedback tab for console so fixes/improvements to it also get processed."

The operative word is **processed**. A note left in the console must end up as a merged,
deployed improvement to the console, through the same machinery everything else uses —
and the reporter must be told, truthfully, when that has happened.

This is therefore not a form. It is a **status-bearing pipeline** whose terminal state
("deployed") is a claim that must be *provable*, and whose middle has an **AI that writes
code**, which means the gate in the middle is the most important thing in this document.

---

## 1. The end-to-end loop

```
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ 1. CAPTURE                                     console Feedback tab      │
  │    reporter types summary + detail + severity                           │
  │    console attaches its OWN state (route, version, role, PWA, audit,    │
  │    fleet provenance) — from the POST-SCOPE render context, never raw    │
  │    redaction (allowlist build + regex scrub) → preview → submit         │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                  │  POST /feedback   (viewer+, rate-limited)
                                  ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ 2. ISSUE          GitLab nwp/ops (project 21), via ops_note_token       │
  │    labels: console, feedback, kind::console, repo::nwp/nwp,             │
  │            severity::<s>, <project issue_label>                          │
  │    NOT agent-eligible.  ← the A14 boundary. Asserted by test T4.         │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                  │
                                  ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ 3. PROMOTION GATE (§7)         explicit human act, OWNER-role only       │
  │    "Arm for the loop" → typed confirm + rate limit + loop-kill-switch    │
  │    check → adds `agent-eligible` → audit-logged twice (jsonl + GitLab    │
  │    note the agent cannot reach).  pl equivalent: pl console feedback arm │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                  │  (30-min cron on mini, or webhook respawn)
                                  ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ 4. AGENT-LOOP     scripts/agent-loop/agent-loop.sh                       │
  │    routes kind::console + repo::nwp/nwp → nwp/nwp checkout               │
  │    prompts/console.md → claude -p in a worktree                          │
  │    FAIL-CLOSED pre-push sensitive-path gate (must be EXTENDED — §9.3)    │
  │    pushes branch, opens MR, adds `pr-opened`.  NEVER auto-merges.        │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                  │
                                  ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ 5. HUMAN REVIEW + MERGE        nwp/nwp, CI green, reviewer approves      │
  │    (nwp/nwp merges trigger NO auto-deploy — deploy-on-merge.sh only      │
  │     knows nwc repos. This is a second, free human gate.)                 │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                  │
                                  ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ 6. DEPLOY          pl console deploy   (workstation → mini)             │
  │    gate 1 divergence guard · gate 2 fate manifest · ALWAYS-ON backup     │
  │    · rsync · venv · restart · /health/ui deep check (§9.4)               │
  │    writes ~/.config/nwp-console/deploy-stamp.json  ← the proof (§10)     │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                  │
                                  ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ 7. CLOSE THE LOOP  status in the tab, derived from GitLab + stamp        │
  │    new → armed → mr-open → merged → DEPLOYED (ancestry-proven)          │
  │    Gotify push on every state change.                                    │
  └─────────────────────────────────────────────────────────────────────────┘
```

Out-of-band channel, deliberately independent of the console being up:
`pl console feedback create|list|arm|status` on the workstation (§11).

---

## 2. Verified ground truth

Everything below was read, not assumed. Paths are absolute-from-repo-root.

| Claim | Verified at | Notes |
|---|---|---|
| Console is FastAPI+Jinja+htmx, 7 panes, role-gated | `scripts/console/app/main.py:31-34,284-495` | `PANES` list is the tab bar |
| Roles viewer/operator/owner, fail-closed ordering | `scripts/console/app/authz.py` | v2 adds a second *project* axis, capped by the global role |
| Action allowlist: literal argv, no live/prod verbs | `scripts/console/app/actions.py:33-39,120-132` | `FORBIDDEN_VERBS` + metachar guard |
| Audit log jsonl, 0600, append+flock | `scripts/console/app/store.py:188-212` | `{ts,user,role,action,detail,ok}` |
| GitLab client has no `create_issue` | `scripts/console/app/gitlab_api.py:70-113` | list/notes/label/close/MR/retry only — **must be added** |
| Console token is the walled `ops_note_token` pattern, 0600 file, never in argv | `scripts/console/app/gitlab_api.py:1-11,29-34` | absent token ⇒ `{"ok":false,"error":"no-token"}`, UI degrades |
| Fleet state is *published*, provenance rendered, staleness loud | `scripts/console/app/fleet_state.py:13-26,185-238` | `decide()` is the honesty contract |
| Deploy = divergence guard + fate manifest + rsync + health | `scripts/commands/console.sh:232-477`, `lib/console-deploy.sh` | |
| Agent-loop requires human `agent-eligible` + `kind::` + `repo::`/`site::` | `scripts/agent-loop/agent-loop.sh:33-40,455-527` | unroutable ⇒ one comment + de-eligibilise |
| Fail-closed pre-push sensitive-path gate exists | `scripts/agent-loop/agent-loop.sh:733-760` | ops#91 Half A |
| MRs never auto-merge | `scripts/agent-loop/agent-loop.sh:~830` | `"Human review required; this MR will NOT auto-merge."` |
| Loop kill switches: `.loop-paused`, `~/.config/nwp-loop/parts.state` | `lib/loop-parts.sh:14,55-56,92-126` | wrapper-enforced, host-local |
| `deploy-on-merge.sh` knows only nwc repos | `scripts/agent-loop/deploy-on-merge.sh:87-88` | ⇒ **nwp/nwp merge does not deploy anything** |
| Existing feedback→issue: `pl demo harvest-post` | `scripts/commands/demo.sh:1242-1308`, `lib/demo.sh:455-491` | see §2.1 |
| Reusable GitLab plumbing | `lib/gitlab-issues.sh:34-96` | `_host/_token/_api_get/_api_send/_jget/_require_ok` |
| Drupal-side feedback→issue with real dedupe + explicit A14 doctrine | `sites/nwc/stg/html/profiles/custom/nwc/modules/nwc_features/nwc_feedback/src/Service/GitLabSyncService.php:46-60,287-370,424` | the model to copy |

### 2.1 Does the existing demo pipeline fit? — evidence-based answer

**Reuse the transport and the doctrine. Do NOT reuse `pl demo harvest-post` itself.**

`pl demo harvest-post` is not a feedback submitter; it is a **spool drainer** bound to
`pl demo reset`. Specifically:

- It has **no tester-authored text at all**. Its only content source is
  `drush watchdog:show --severity=Error` + `tail /var/log/php-fpm-error.log`
  (`scripts/commands/demo.sh:401-407,363-367`). There is no capture form anywhere in it.
- It reads a filesystem spool `sites/<site>/demo-harvest/harvest-*.md` on the
  **workstation** (`lib/demo.sh:66,472-473`). The console runs on **mini** and has no
  `sites/` tree — this is the same reason the Fleet tab needed `pl fleet publish`.
- It applies **zero redaction**. `grep -E 'redact|sanitiz|scrub'` across `lib/demo.sh`,
  `scripts/commands/demo.sh`, `lib/gitlab-issues.sh` returns nothing. Raw watchdog tables
  (usernames, URIs, referrers) go to nwp/ops verbatim, fenced in a code block. A console
  feedback envelope carrying audit lines and Quokka transcripts through that path would
  be a disclosure.
- Its labels are the hardcoded constant `DEMO_HARVEST_LABELS="demo-tester,auto-harvest"`
  (`scripts/commands/demo.sh:1240`) — **no** `kind::`, `repo::`, `severity::`,
  `agent-eligible`. So harvest issues are, by construction, never picked up by the loop.
  Adding console routing labels to that constant would silently re-route every demo
  harvest as well.
- Its only dedupe is `mv` to `posted/` **after** a successful POST
  (`scripts/commands/demo.sh:1293-1294`). If the `mv` fails post-POST, the next run
  duplicates. Not adequate for a user-facing submit button.

**What we do reuse, and why it counts as "not a second mechanism":**

1. **The same GitLab transport and token discipline** — `lib/gitlab-issues.sh` on the
   workstation (`_api_send POST /projects/21/issues`, 0600 curl config, token from
   `.secrets.yml:gitlab.ops_note_token` with the root PAT never used:
   `lib/gitlab-issues.sh:41-46`), and the console's existing `gitlab_api.GitLab` class
   with its identical 0600-token-file rule on mini.
2. **The same tracker** — nwp/ops, project 21.
3. **The same routing contract** — `kind::` + `repo::` + `agent-eligible`, ops#41.
4. **The same doctrine as the mature Drupal pipeline** — `GitLabSyncService.php:46-60`
   states outright that `agent-eligible` "must come from a human" and is deliberately
   never auto-applied. We inherit that verbatim, plus its dedupe-by-writeback pattern
   (`:296-302,:370`).

Net: one *conceptual* pipeline, three *call sites* (demo spool, Drupal feedback, console
feedback), all landing in nwp/ops with the same label grammar and the same human gate.
The alternative — bolting console capture onto `harvest-post` — would couple a web
submit button to `pl demo reset` on a host that has no sites.

### 2.2 Three findings that change the design

These were surprises. Each one is load-bearing.

**F1 — `/health` is a vacuous check.**
```python
# scripts/console/app/main.py:168-170
@app.get("/health")
def health():
    return {"ok": True, "app": "nwp-console"}
```
It is a literal. `cmd_deploy`'s step 5/5 greps this for `"ok"`
(`scripts/commands/console.sh:469-476`). A console whose every pane raises a
`TemplateSyntaxError` would deploy **green**. In a self-referential loop this is exactly
the failure that must not pass silently. See §9.4.

**F2 — the agent-loop's fail-closed sensitive-path gate does not cover a single console
file.** Verified by running the live regex from `agent-loop.sh:735-738` against the
candidate paths:

```
scripts/console/app/authz.py          → NO MATCH
scripts/console/app/actions.py        → NO MATCH   (the action ALLOWLIST)
scripts/console/app/scope.py          → NO MATCH   (the v2 tenancy choke point)
scripts/console/app/webauthn_flow.py  → NO MATCH   (passkey verification)
scripts/console/app/store.py          → NO MATCH   (credentials + audit log)
scripts/console/nwp-console.service   → NO MATCH
lib/console-deploy.sh                 → NO MATCH   (the divergence guard)
scripts/commands/console.sh           → NO MATCH   (the deploy path)
```
The regex catches `lib/(auth|secrets|sanitizers)` — the console's auth lives at
`scripts/console/app/authz.py`, which is not under `lib/`. So today, an armed console
issue could produce a pushed branch that rewrites the console's own authorisation, its
own action allowlist, or its own deploy guard. Human review would still be the merge
gate, but the *fail-closed* backstop — the one that exists precisely because prompts are
advisory — is absent. **This must be fixed before the first console issue is armed.**
See §9.3. Note the fix is in `scripts/agent-loop/agent-loop.sh`, which *is* on the
blocked list, so an agent can never make this change itself.

**F3 — merging a console fix deploys nothing.** `deploy-on-merge.sh:87-88` maps only
`nwc | nwc-project | nwd-project | local-nwc-copyright-sync | auth-nwc-oauth2`. A merged
nwp/nwp MR triggers no deploy. This is *good* — it is a free second human gate — but it
means `merged ≠ deployed` is a real, common, long-lived state, so the status ladder in
§10 must model it and the tab must never collapse the two.

---

## 3. Data model

### 3.1 The feedback envelope (the single shared contract)

One JSON shape, produced identically by the web POST handler and by
`pl console feedback create`. Both render it to the same markdown issue body. A golden-file
test (T9) asserts they cannot drift.

```jsonc
{
  "schema": "nwp.console-feedback",
  "schema_version": 1,

  // -- reporter-authored (untrusted; scrubbed, never rewritten) --------------
  "kind":     "bug" | "improvement" | "question",
  "severity": "blocks" | "annoying" | "nice",
  "summary":  "string, 1..120 chars, single line",
  "detail":   "string, 1..4000 chars",

  // -- console-attached (machine-generated; each item individually opt-out) --
  "context": {
    "route":        "/panes/fleet?force=1",   // path+query, query values dropped
    "tab":          "fleet",
    "console": {
      "commit":        "1b0af43…",   // from the deploy stamp
      "commit_short":  "1b0af43",
      "dirty":         false,        // stamp said the source tree was dirty
      "deployed_at":   "2026-07-26T04:11:02Z",
      "deploy_age":    "3 h 20 min",
      "tree_ok":       true          // running tree hash == stamp tree hash
    },
    "reporter": {
      "user":          "dana",       // console username, pseudonymous. NEVER an email.
      "global_role":   "operator",
      "project_id":    "ss",
      "project_role":  "operator"
    },
    "client": {                       // from an inline script; "" when JS is off
      "ua":            "Mozilla/5.0 (Linux; Android 14) …",   // capped 300 chars
      "display_mode":  "standalone" | "browser" | "",
      "viewport":      "412x915",
      "dpr":           "2.625"
    },
    "audit": [                        // last N=10, scope-filtered, key-allowlisted
      {"ts": "…Z", "user": "dana", "role": "operator",
       "action": "action.demo_reset", "ok": false, "rc": 1, "secs": 4.2}
    ],
    "fleet": {                        // provenance ONLY, never rows
      "source": "published" | "local",
      "age_human": "22 min",
      "stale": false,
      "host": "carlo"                 // OWNER-scoped readers only; else omitted
    }
  },

  "attached": ["route","console","reporter","client","audit","fleet"],  // what survived opt-out
  "redactions": [                      // what the scrubber removed, by rule name
    {"rule": "gitlab-pat", "count": 1, "where": "detail"}
  ],
  "dedupe_key": "sha256:…"             // see §3.3
}
```

### 3.2 The rendered issue

**Title** — `[console] <summary>` truncated to 200 chars. The `[console]` prefix makes
the tab's own issues greppable and lets `pl issue` users see the surface at a glance.

**Body** (markdown; the `UNTRUSTED` fences matter — the agent-loop prompt already teaches
the model that a fenced `UNTRUSTED_ISSUE_BODY` block is data, `agent-loop.sh:~640`):

```markdown
## Console feedback — bug (severity: blocks)

Reported by **dana** (global: operator · project: ss/operator) from the **Fleet** tab.

### What happened
````text UNTRUSTED_REPORTER_TEXT
<detail, scrubbed, verbatim otherwise>
````

### Console state at the time of report
| field | value |
|---|---|
| route | `/panes/fleet` |
| console commit | `1b0af43` (clean) |
| deployed | 2026-07-26T04:11:02Z (3 h 20 min ago) |
| running tree matches stamp | yes |
| client | Android 14 · standalone PWA · 412x915 @2.6 |
| fleet snapshot | published, 22 min old, fresh |

### Recent console activity (last 10, scoped to this reporter's project)
| ts | user | action | ok |
|---|---|---|---|
| …Z | dana | action.demo_reset | ✗ (rc=1, 4.2s) |

---
*Redactions applied before posting: gitlab-pat ×1 (in reporter text).*
*Filed by the NWP Console Feedback tab. `agent-eligible` is NOT set — a human must
promote this deliberately (`pl console feedback arm <iid>`).*
*dedupe: `sha256:ab12…`*
```

### 3.3 Dedupe

`dedupe_key = sha256(kind + "\x00" + normalise(summary) + "\x00" + normalise(detail) + "\x00" + project_id)`
where `normalise` = lowercase, collapse whitespace, strip punctuation runs.

On submit, search open issues in nwp/ops with label `console` for the key in the body
(`GET /issues?labels=console&search=<key>&in=description&state=opened`). On hit:
post a "**+1** from `<user>` at `<ts>`" note on the existing issue and return **that**
iid — no new issue. Window: only open issues; a closed one may legitimately recur.

Rationale: this is the Drupal service's `gitlab_issue_url`-writeback idea
(`GitLabSyncService.php:296-302`) adapted to a stateless console — the key lives in the
issue body, which is the only store both the console and `pl` can read.

### 3.4 The deploy stamp (new file, on the console host)

`~/.config/nwp-console/deploy-stamp.json`, mode 0600, written by `pl console deploy`.

```jsonc
{
  "schema": "nwp.console-deploy-stamp",
  "schema_version": 1,
  "deployed_at": "2026-07-26T04:11:02Z",
  "deployed_by": "rob@carlo",
  "source_repo": "nwp/nwp",
  "source_branch": "main",
  "source_commit": "1b0af43…",
  "source_dirty": false,           // git status --porcelain -- scripts/console non-empty
  "source_tree_sha256": "…"        // sha256 of the console_manifest_local output
}
```

> **Placement is load-bearing.** The stamp MUST live in `~/.config/nwp-console/`, **not**
> in `~/nwp-console/src/`. `lib/console-deploy.sh` manifests `src/` and
> `console_deploy_classify` marks any target-only file `D` — a stamp inside `src/` would
> make the divergence guard refuse **every** subsequent deploy. `~/.config/nwp-console/`
> is already outside the rsync target and is already documented as never-overwritten
> (`scripts/commands/console.sh:347`).

`source_tree_sha256` reuses `CONSOLE_MANIFEST_CMD` (`lib/console-deploy.sh:29-34`)
verbatim, so the value the stamp records and the value the running console recomputes are
produced by the same code and cannot drift.

### 3.5 Console-local state

`~/.local/share/nwp-console/feedback-state.json` (0600):
```jsonc
{
  "arm_log":  [{"ts":"…","user":"rob","iid":412,"project":"ss"}],   // rolling, for the rate limit
  "notified": {"412": "mr-open"},                                    // Gotify high-water per iid
  "submit_log": [{"ts":"…","user":"dana"}]                           // per-user submit rate limit
}
```
No issue *content* is cached locally. Status is always derived live from GitLab + the
stamp (§10) — there is deliberately no hand-maintained status field anywhere.

---

## 4. Capture — what the form asks, and what it attaches

Mobile-first, one column, thumb-reachable, no external JS.

**Asked (4 controls, all above the fold on a 412px phone):**

| Control | Type | Why it makes a fix possible |
|---|---|---|
| Kind | 3 big radio pills: Bug / Improvement / Question | Selects the prompt's posture and the triage lane. |
| Summary | single-line, required, ≤120 | Becomes the title; forces one issue per problem. |
| What happened | textarea, required, ≤4000, autofocus | The one thing only the human knows. |
| Severity | 3 pills: Blocks me / Annoying / Nice to have | Drives `severity::` and the arming decision. **Reporter-declared, never inferred.** |

Deliberately **not** asked: "steps to reproduce" as a separate field (nobody fills it on a
phone — the auto-attached route + audit lines carry more signal), and any free-text
"which site" (that would be a tenancy hole; the project comes from the scope).

**Attached automatically** — each group shown collapsed with a checkbox to exclude, and
all of it visible in the preview before submit:

| Group | Source | Value to a fixer |
|---|---|---|
| `route` / `tab` | the current pane path, from the htmx request or a hidden field | tells the agent which module to open |
| `console` | the deploy stamp (§3.4) | "is this already fixed on main?" is answerable |
| `reporter` | the resolved `Scope` (v2) | role/project explains what they could see |
| `client` | inline script → hidden field | 90% of PWA-only bugs are display-mode or viewport |
| `audit` | `AuditLog.tail()`, scope-filtered, key-allowlisted | the failing action, with rc and duration |
| `fleet` | `fleet_state.decide()` provenance | distinguishes "console is broken" from "the data is 6 h stale" |

**The preview is the control.** `GET /feedback/preview` (htmx, same form payload) renders
the exact bytes that will be POSTed to GitLab. Nothing is submitted the reporter has not
been shown. This is a stronger privacy guarantee than any redaction rule, because it does
not depend on our rules being complete.

**Client context without external JS:** a ~12-line inline `<script>` in the feedback
template writes `navigator.userAgent`, `matchMedia('(display-mode: standalone)').matches`,
`innerWidth`x`innerHeight`, `devicePixelRatio` into one hidden field as `k=v;` pairs. No
fetch, no CDN, CSP-compatible. JS off ⇒ the field is empty ⇒ the envelope records
`"client": {}` and the body says *"not supplied"* — **never guessed**. Server-side the
field is untrusted input: parsed with a strict `^[a-z_]+=[^;]{0,300};` grammar, control
characters stripped, whole group dropped on any parse failure.

---

## 5. Redaction rules

Two layers, both fail-closed. If either raises, **the submit is refused** with a visible
error — never a silent partial post.

### Layer 1 — allowlist construction (primary)

The envelope is *built* from named fields, never by serialising a live object. Concretely:

- **Audit entries**: keep only `ts`, `user`, `role`, `action`, `ok`, and from `detail`
  only `rc`, `secs`, `iid`, `label`, `mode`, and `site` **iff in scope**.
  **Dropped unconditionally**: `transcript` (voice STT — the reporter's speech,
  `main.py:900`), `prompt` and `reply` (Quokka chat content, `main.py:685-686`),
  `email_chars`/`email`, `argv` (reduced to `argv[0]` only — it carries site names and
  demo code ids), `error` (truncated to 160 chars *and* passed through layer 2).
- **Cookies, headers, session data**: never read. The handler does not touch
  `request.cookies` or `request.headers` beyond the existing `_guard_origin` check.
- **Fleet**: provenance scalars only (`source`, `age_human`, `stale`). `prov.host` and
  `prov.note` are already in the v2 `scope.REDACT_PATHS` for scoped readers
  (`scope.py:59-66`) — the envelope honours the same list.
- **Filesystem paths**: `$HOME` → `~`; any absolute path outside `~/nwp` and
  `~/nwp-console` → basename only.
- **Identity**: console username only. No email, no IP, no WebAuthn credential id, no
  enrolment token, no session cookie value.

### Layer 2 — regex scrubber over the final rendered body (belt)

Applied to the *complete* markdown body immediately before the POST, so it also covers
reporter free-text. Each rule replaces the match with `‹redacted:RULE›` and appends to
`redactions[]` (which is printed in the body, so redaction is visible, not silent).

| Rule name | Pattern (illustrative) |
|---|---|
| `gitlab-pat` | `glpat-[A-Za-z0-9_\-]{20,}` |
| `gitlab-runner` | `glrt-[A-Za-z0-9_\-]{20,}` |
| `bearer` | `(?i)(authorization|private-token)\s*[:=]\s*\S+` |
| `pem` | `-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----` |
| `aws` | `A[KS]IA[0-9A-Z]{16}` |
| `kv-secret` | `(?i)\b(pass(word|wd)?|secret|token|api[_-]?key)\s*[:=]\s*\S{6,}` |
| `dsn` | `[a-z][a-z0-9+.-]*://[^\s:@/]+:[^\s@/]+@` (credentials in a URL) |
| `ssh-priv` | `\bssh-(rsa|ed25519)\s+AAAA\S+` in a context line naming a key file |
| `secrets-path` | `\.secrets(\.data)?\.ya?ml` → path kept, any following block dropped |

Rules live in **one** module with a name per rule, so T2 can be table-driven and each rule
individually deletable to prove the test goes red.

### What is deliberately NOT redacted

Site names *within the reporter's own scope*, console usernames, the console's own tailnet
address, GitLab issue/MR numbers, commit SHAs, `pl` verb names. Redacting these would make
reports useless and would be security theatre — they are all already visible to the
reporter and, for the most part, in the repo.

### The tenancy rule that subsumes the rest

> **The envelope may contain nothing the reporter could not already see on their own
> screen.**

Implemented by building the envelope from the **post-`scope.redact()` render context**,
not from the pre-scope gather. Tested by T3.

---

## 6. Routing

### 6.1 Labels applied at creation

| Label | Purpose | Notes |
|---|---|---|
| `console` | surface marker | what the Feedback tab lists and counts |
| `feedback` | matches the Drupal pipeline's constant (`GitLabSyncService.php:62-66`) | one vocabulary across all feedback sources |
| `kind::console` | agent-loop prompt selector | needs `prompts/console.md` (§6.3) |
| `repo::nwp/nwp` | explicit fix-repo routing | **wins over the map** (`agent-loop.sh:205-208`) — belt and braces |
| `severity::blocks` \| `severity::annoying` \| `severity::nice` | triage + arming policy | reporter-declared |
| `<project issue_label>` | tenancy, e.g. `project::ss` | verbatim from `projects[pid].gitlab.issue_label`; drives `Scope.issue_allowed` (`scope.py:120-124`) |

**Not applied:** `agent-eligible` (§7), `site::` (the console is not a site),
`tier-1/2/3` (the loop defaults to `T2`, `agent-loop.sh:613-624`, which is correct for
console work — `deploy-on-merge.sh` ignores nwp/nwp anyway, F3).

Added later, by machine: `pr-opened` (by the loop), `loop::refused-sensitive`
(recommended new label, §9.3).

### 6.2 `fix-repo-map.json` entry

Exactly one line, in `kinds`:

```jsonc
{
  "sites": { /* unchanged */ },
  "kinds": {
    "config": "nwp/nwp",
    "console": "nwp/nwp",     // ← ADD THIS
    "docs": "nwp/nwp",
    "nwc-drupal": "nwp/nwc"
  }
}
```

The console's code lives in the nwp meta repo at `scripts/console/`, so the fix repo is
`nwp/nwp` — the same target as `config` and `docs`. Because we *also* set
`repo::nwp/nwp` on every issue, routing survives even if this file is not updated; the
map entry exists so that `kind::console` alone is routable and so the unroutable-issue
comment (`agent-loop.sh:232`) lists `console` among the valid kinds.

`agent-loop.sh:544-549` additionally requires `prompts/<kind>.md` to exist, or the issue is
de-eligibilised. So the map entry and the prompt file must land in the **same** commit.

### 6.3 `scripts/agent-loop/prompts/console.md` (new)

`config.md` does not fit: it describes "bash tooling: `pl`, `scripts/commands/`, `lib/`,
`example.nwp.yml`" and its test step is `bash -n`. The console is a Python FastAPI app
with a pytest suite, a Jinja template set, a vendored-asset rule and a security posture
that has nothing to do with `example.nwp.yml`. Routing console work through `config.md`
would give the agent the wrong conventions and the wrong test command.

Proposed content:

```markdown
## Task shape: NWP Console change

The change lives under `scripts/console/` in the nwp meta repo — a FastAPI +
Jinja2 + htmx app deployed to a single mesh-only host. It is passkey-only,
role-gated, and multi-tenant (per-project scopes). Read
`scripts/console/README.md` before touching anything.

### Conventions

* Python 3.11+, **stdlib only** outside `requirements.txt`. Do not add a
  dependency; if the fix seems to need one, stop and write `AGENT-NOTE.md`.
* No external JS, no CDN, no webfonts. htmx 2.0.4 is vendored under
  `scripts/console/static/` with an SRI hash — do not change it or its hash.
* Mobile-first: the app is used from a phone in a PWA. Anything you add must
  work at 412px wide with one thumb, and must not depend on hover.
* Pure modules (`authz.py`, `actions.py`, `scope.py`, `parsers.py`,
  `fleet_state.py`, `notify.py`) are stdlib-only and unit-tested. Keep them
  importable without FastAPI; the AST tests assert this.
* Every new route declares its minimum role via `Depends(require(...))`,
  guards POSTs with `_guard_origin(request)`, and writes one `audit.append(...)`
  line. A route with no audit line will be rejected in review.
* Any pane that shows site-derived data must resolve a `Scope` first and read
  its allowed set from that object. Never filter by site anywhere else.

### Procedure

1. Make the smallest change that resolves the issue.
2. Run the suite: `cd scripts/console && python -m pytest tests/ -q`.
   It must be green. Add or extend a test for the behaviour you changed —
   a fix with no test is not finished.
3. If you touched a template, also run the render self-test:
   `python -m pytest tests/test_health_ui.py -q`.
4. Note in the commit body exactly which commands you ran and their result.

### Hard boundaries (STOP + write AGENT-NOTE.md instead of proceeding)

These are the guard rails that constrain YOU. You may not modify them, and a
fix that appears to require modifying them is a fix that needs a human:

- `scripts/console/app/authz.py`, `scope.py`, `actions.py`, `webauthn_flow.py`,
  `store.py`  — roles, tenancy, the action allowlist, passkeys, the audit log
- `scripts/console/app/main.py` **only** where it changes a `require(...)` role,
  removes a `_guard_origin` call, or removes an `audit.append` call
- the Feedback tab's promotion gate and anything that adds the
  `agent-eligible` label
- `scripts/commands/console.sh`, `lib/console-deploy.sh`  — the deploy gates
- `.gitlab-ci.yml`, `.github/`, git hooks, `lib/auth*`, `*secret*`, `keys/**`,
  `.env*`, sanitizers, `scripts/commands/live*.sh`, `scripts/agent-loop/**`
- adding or removing a dependency of any kind

These are ALSO enforced by a fail-closed pre-push check in the loop driver: if
your diff touches them, the branch is not pushed, the issue loses
`agent-eligible`, and a human is asked. Writing AGENT-NOTE.md is the correct,
credited outcome — pushing a change that gets refused is not.
```

---

## 7. The promotion gate

### 7.1 Honest blast radius

Pressing "Arm" in a web app on a phone causes, on mini:

1. `claude -p --dangerously-skip-permissions` to run headless in a git worktree of
   `nwp/nwp`, with a prompt that **contains reporter-controlled text**
   (`agent-loop.sh:~640`).
2. That agent to write and commit code.
3. A **push** of that branch to `git.nwpcode.org` using mini's `~/.ssh/nwp` key
   (`agent-loop.sh:~775`).
4. A **CI pipeline to run on that branch**, executing test code the agent wrote, on the
   nwp runner.
5. An MR to open on nwp/nwp.

What it **cannot** reach:

- **Merge.** The MR never auto-merges (`agent-loop.sh:~830`); a human approves.
- **Deploy.** `deploy-on-merge.sh` does not know nwp/nwp (F3); the console is only
  deployed by a human running `pl console deploy` from the workstation.
- **live / prod / mons.** No path here touches a production server, a prod key, or the
  deploy gate. The mons boundary is untouched.
- **Its own guard rails**, once F2 is fixed (§9.3): the pre-push gate refuses the branch.
- **More than the caps allow**: `AGENT_LOOP_DAILY_CAP=5`, `MAX_PER_RUN=1`,
  `MAX_RETRIES=3`, `MAX_AGE_DAYS=30`.

Two items in that list deserve to be said plainly rather than buried:

- **(4) is code execution on met from partly-attacker-influenced content.** The agent
  cannot edit `.gitlab-ci.yml` (blocked), but nothing blocks `tests/**`, and CI runs
  tests. A malicious or manipulated agent-authored test file executes on the runner. That
  runner is AI-tier by design (met, no prod access, per the actor glossary in
  `CLAUDE.md`), so the blast radius is bounded to the AI tier — but it is real, it is not
  new (it is inherent to the existing loop), and the Feedback tab **widens the aperture**
  by giving more people a way to inject the issue text that reaches the agent.
- **(1) runs on mini with filesystem access beyond the worktree.** The prompt says "stay
  inside this directory"; that is advisory. Also pre-existing, also widened by this tab.

Conclusion: **operator-only is not sufficient.** The existing operator role is calibrated
to a very different thing — allowlisted literal argv with strict validators and no live
verbs (`actions.py:1-15`). "Cause an AI to write and push code" is a different category of
authority and needs a different gate.

### 7.2 The gate

Six conditions, **all** required, all fail-closed:

1. **Global role `owner`.** Not operator. (Project role `maintainer` is additionally
   required when projects exist — but the global cap already implies it,
   `authz.py::effective_project_role`.)
2. **Typed confirmation.** The reporter must type the issue iid into the confirm field —
   the same "typed tier" idea as `impact_confirm typed` in the deploy path
   (`scripts/commands/console.sh:437`). Short enough for a phone, deliberate enough that
   it cannot be a mis-tap.
3. **Loop is armed.** The console reads the kill switches *before* offering the button and
   again before acting: `~/nwp/.loop-paused` and `~/.config/nwp-loop/parts.state`
   (`fix-loop` and `all`). The console runs on the same host as the loop, so this is a
   real check, not a guess. **Any error reading them ⇒ refuse.** Prefer
   `pl loop parts --json` (see §11 — needs adding) with a direct-file fallback that
   fails closed.
4. **Rate limit.** ≤3 arms per rolling 24 h across the whole console (below the loop's own
   `AGENT_LOOP_DAILY_CAP=5`, so the console can never be the thing that exhausts the
   loop's budget). Counter in `feedback-state.json`; **unwritable counter ⇒ refuse**.
5. **The issue was created by this pipeline.** Arm refuses unless the issue carries
   `console` + `feedback` + `kind::console`. This prevents the button becoming a generic
   "arm any ops issue" lever.
6. **Severity gate.** `severity::nice` issues cannot be armed without
   `--force` / a second confirm. Cosmetic requests are the ones most likely to produce
   a large speculative diff.

### 7.3 What arming does, exactly

```
POST /feedback/{iid}/arm   (owner)
  _guard_origin
  → re-read the 6 conditions (nothing cached from the GET)
  → gitlab.add_label(OPS_PROJECT, iid, "agent-eligible")
  → gitlab.post_note(OPS_PROJECT, iid,
       "🔓 Armed for agent-loop by **<user>** (owner) via the NWP Console at <ts>.\n"
       "Conditions checked: loop enabled, arms today <n>/3, severity <s>.\n"
       "The resulting MR will NOT auto-merge; a human reviewer is still the gate.")
  → audit.append(user, role, "feedback.arm",
       {"iid": iid, "project": pid, "severity": s, "arms_today": n,
        "loop_state": "enabled"}, ok)
  → feedback-state.json: append to arm_log
  → Gotify: "🔓 console feedback #412 armed" (priority P_LOW)
```

**Two independent records on purpose.** The jsonl audit lives on the console host, which
is also the host the agent runs on. The GitLab note lives on the forge, which the agent's
own token can write to but cannot delete without leaving a system note. Neither alone is
tamper-evident; together they are.

### 7.4 Disarm

`POST /feedback/{iid}/disarm` (owner) removes `agent-eligible`, posts a note, audits.
Needed because the loop's own de-eligibilise paths (unroutable, retry exhausted,
sensitive-path refusal) leave the issue in states an operator may want to re-enter or
abandon deliberately.

### 7.5 Explicitly rejected designs

- **Auto-arm on `severity::blocks`.** Tempting; it is exactly the A14 bypass already
  recorded as a P0 in the nwc/ssc audit (member→loop). The webhook `/feedback` endpoint
  already went partway down this road and had to be walked back to "the Drupal classifier
  is the single source of truth; the webhook does not create issues"
  (`gitlab-webhook-receiver.py:372-418`). Do not repeat it.
- **Operator-role arming.** See §7.1.
- **A Solo-touch (deploy-gate) requirement on arming.** `lib/deploy-gate.sh` exists for
  *writes that reach prod*; arming reaches an MR. Adding hardware presence here would
  dilute the meaning of the touch and make the gate ceremonial. **But** if the operator
  ever wants a console button that *merges* or *deploys*, that button must be
  deploy-gate-class — and my recommendation is that it should simply not exist.
  → **Operator decision, §14-D.**

---

## 8. Multi-tenancy

Console v2 introduces `Scope` (`scripts/console/app/scope.py`) as "THE tenancy choke
point", with `sites`, `issue_labels` (from `projects[pid].gitlab.issue_label`),
`ci_projects`, `demo_sites`, `library_shards`, and a `project` stamp on audit entries.
The Feedback tab reuses all of it and adds nothing.

**A dev on the ss/nw project files console feedback. Who sees it?**

| Viewer | Sees the issue? | Mechanism |
|---|---|---|
| The reporter | yes | it carries their project's `issue_label`; `Scope.issue_allowed` matches |
| Another member of project `ss` | yes | same label |
| A member of project `nwc` only | **no** | label mismatch ⇒ filtered by `filter_issues` |
| A user with no project membership | **no** | `empty_scope`, sees nothing (`scope.py:151-153`) |
| An owner | yes, all of them | `all_sites=True` |
| Anyone in GitLab with nwp/ops access | yes | **the tracker is not tenant-isolated** — see below |

**Leak vectors and their closures:**

| Vector | Closure |
|---|---|
| Auto-attached fleet provenance names another project's publisher host | envelope built from the post-`scope.redact()` context; `prov.host`/`prov.note` are already in `REDACT_PATHS` (`scope.py:59-66`) |
| Auto-attached audit lines from other projects | filtered by `Scope.audit_allowed` (`scope.py:135-141`) before the key-allowlist step |
| Auto-attached `argv` naming a foreign site | `argv` reduced to `argv[0]`; any `site` key intersected with `scope.sites` |
| Reporter free-texts a foreign site name | **not prevented, and correctly so** — that is their words, and they were shown the preview. It is a human disclosure, not a system one. |
| The Feedback *list* shows other projects' rows | `Scope.filter_issues` on the pane; `scope.scrub()` as the belt |
| Tab count leaks a magnitude | the count is computed over the filtered list, not the raw list — same pattern as `_issues_count` in `main.py:409-411` |

**The honest limitation, stated up front:** nwp/ops is a single GitLab project and its
issues are visible to anyone with access to it. The console's tenancy filter shapes *the
console's view*, not GitLab's. A project member who also has a GitLab account on nwp/ops
sees everything there. If real tenant isolation of the tracker is ever required, the
answer is separate GitLab projects per tenant — a much larger change.
→ **Operator decision, §14-E** (accept, or scope console feedback to a dedicated
tracker).

---

## 9. Self-referential safeguards

The console can request changes to itself, fixed by an agent, deployed back to the
console. Five failure modes.

### 9.1 A bad fix bricks the tab used to report it

*Scenario:* a merged, deployed fix raises on `/panes/feedback`. The reporting channel is
now the broken thing.

- **`pl console feedback create` from the workstation** is the out-of-band channel. It
  talks to GitLab directly via `lib/gitlab-issues.sh` and does not touch the console host
  at all. It works when the console is entirely down.
- **`pl console rollback`** (new, §11) restores the last pre-deploy backup and restarts.
- **`/health/ui`** (§9.4) is meant to catch this *before* the deploy is declared green.

### 9.2 Feedback storm

*Scenario:* a broken pane makes 40 people (or one enthusiastic tester) file the same
thing; nwp/ops floods; triage collapses.

- Content dedupe (§3.3) turns repeats into "+1" notes on one issue.
- Per-user submit rate limit: 10/day, 3/hour; over the limit the form still renders and
  says *"you've filed 10 today — add to an existing report instead"* with links to their
  open ones. Never a silent drop.
- Body size cap 4000 chars, envelope cap 16 KB, hard-refused above.
- The arm rate limit (§7.2.4) means a storm can never become a storm of *agent runs*.

### 9.3 An agent "fixes" the gate that constrains it

*This is the sharp one, and today it is unguarded (F2).*

**Required change** — extend the fail-closed pre-push regex at
`scripts/agent-loop/agent-loop.sh:735-738` with these alternatives:

```
(^|/)scripts/console/app/(authz|scope|actions|webauthn_flow|store)\.py$
(^|/)scripts/console/nwp-console\.service$
(^|/)scripts/console/static/(vendor|htmx)
(^|/)lib/console-deploy\.sh$
(^|/)scripts/commands/console\.sh$
(^|/)lib/(impact|loop-parts|deploy-gate)\.sh$
```

Notes:
- `main.py` is deliberately **not** wholly blocked — it is where almost every legitimate
  console fix lands, and blocking it would make `kind::console` useless. Its dangerous
  *lines* (a `require(...)` role, a `_guard_origin` call, an `audit.append` call) are
  covered by (a) the prompt's hard boundary, (b) a dedicated CI check that greps the diff
  for removed `require(`/`_guard_origin`/`audit.append` occurrences and fails the
  pipeline, and (c) human review. This is a deliberate, stated trade-off, not an
  oversight. → **Operator decision, §14-C** (accept the residual, or block `main.py`
  entirely and accept that console fixes mostly need a human).
- `lib/loop-parts.sh` and `lib/impact.sh` are added because they *are* the kill switch and
  the impact contract.
- **The agent can never make this change itself**: `(^|/)scripts/agent-loop/` is already
  on the blocked list, so the regex is self-protecting once written.

**Recommended companion:** on refusal the loop currently only posts a note and removes
`agent-eligible` (`agent-loop.sh:745-755`). Add a `loop::refused-sensitive` label so the
console can render the state without scraping notes, and so `pl console feedback list`
can filter on it.

### 9.4 A deploy that "succeeds" and bricks the UI (F1)

`/health` is a literal `{"ok": True}`. It proves uvicorn accepted a connection; it proves
nothing about the app.

**Add `GET /health/ui`** (unauthenticated is acceptable — it returns no data, only
pass/fail names; if the operator prefers, gate it to the tailnet, which is already the
only transport):

```jsonc
{
  "ok": false,
  "checks": {
    "templates": {"ok": false, "failed": ["pane_feedback.html: 'foo' is undefined"]},
    "routes":    {"ok": true,  "count": 41, "missing": []},
    "imports":   {"ok": true},
    "store":     {"ok": true},
    "stamp":     {"ok": true, "commit": "1b0af43", "tree_ok": true}
  }
}
```

- `templates` — render **every** template in `templates/` against a synthetic minimal
  context inside a try/except, collecting failures. Catches the whole
  `TemplateSyntaxError`/`UndefinedError`/missing-include class.
- `routes` — assert every path in a committed expected-route list is present in
  `app.routes`. Catches "the fix deleted a route".
- `imports` — assert the pure modules import standalone.
- `store` — assert `users.json` and `audit.jsonl` are readable/appendable.
- `stamp` — assert the deploy stamp parses and the recomputed tree hash matches.

Then change `scripts/commands/console.sh` step 5/5 to call `/health/ui` and **fail the
deploy** on `ok:false`, printing the failed check names. `/health` stays as the cheap
liveness probe.

**Honest limits:** this catches template, import, route-table and store failures. It does
**not** catch logic errors, wrong data, or a pane that renders but is unusable on a phone.
Say so in the code comment; a check that oversells itself is the same disease as the one
it replaces.

### 9.5 Deploy destroys work / cannot be undone

The divergence guard (`lib/console-deploy.sh`) and the fate manifest
(`scripts/commands/console.sh:303-351`) already cover "this deploy would destroy
target-local work". But a **backup is taken only under `--force-overwrite`**
(`_deploy_backup_target`, called at `console.sh:414`). A normal deploy of a bad merged fix
has no snapshot to go back to.

**Required change:** take the timestamped backup on **every** deploy, before the rsync.
The tree is small (~6500 lines of Python + templates); the cost is milliseconds. Keep the
last 10, prune older. Then add:

```
pl console rollback [--to <stamp>] [--list]
```
which untars `~/nwp-console/backups/src-<stamp>.tar.gz`, restarts the unit, runs
`/health/ui`, and **rewrites the deploy stamp** to record
`{"rolled_back_from": "<commit>", "source_commit": "<the restored stamp's commit>"}` — so
the status ladder cannot claim "deployed" for a fix that was just rolled back.

---

## 10. Closing the loop with the reporter

### 10.1 The status ladder — every rung derived, none stored

| Status | Derivation |
|---|---|
| `new` | issue open, no `agent-eligible`, no `pr-opened` |
| `armed` | `agent-eligible` present, no `pr-opened` |
| `mr-open` | `pr-opened` present **and** a related MR on nwp/nwp in state `opened` |
| `refused` | `loop::refused-sensitive` present (§9.3) |
| `stalled` | armed, and the loop's retry budget is exhausted — surfaced from the loop's own note; if unavailable, shown as `armed (no MR yet, N h)` rather than invented |
| `merged` | related MR state `merged`, **not** ancestry-proven in the running console |
| `deployed` | `merged` **and** all three proofs in §10.2 hold |
| `deployed?` | merged + ancestor, but the stamp says `source_dirty` or the tree hash mismatches — **shown as a caveat, never as `deployed`** |
| `closed` | issue closed with no merged MR (wontfix / duplicate / answered) |

### 10.2 "Deployed" is a claim, so it needs proof

Three independent conditions, **all** required:

1. **Ancestry.** The MR's `merge_commit_sha` (or `squash_commit_sha`) must be an ancestor
   of the deployed commit. Ask GitLab, which knows the graph:
   `GET /projects/nwp%2Fnwp/repository/merge_base?refs[]=<merge_sha>&refs[]=<stamp.source_commit>`
   — deployed iff the returned `id == merge_sha`. No local git needed; the console has no
   repo.
2. **Clean provenance.** `stamp.source_dirty == false`. If the console was deployed from a
   dirty working tree, the commit SHA does not describe the running bytes, and no ancestry
   test over it means anything. State it: *"deployed from an uncommitted tree — cannot
   confirm this fix is in it."*
3. **Tree integrity.** The console recomputes `CONSOLE_MANIFEST_CMD` over
   `~/nwp-console/src` (cached ~5 min) and compares to `stamp.source_tree_sha256`. A
   mismatch means somebody edited on the host after deploy — *"deployed, but the running
   tree has been modified since."* Never plain `deployed`.

Failure of any prerequisite (no stamp, no token, `merge_base` errors) resolves to
`unknown`, **never** to `deployed`. Fail-closed, tested by T6.

### 10.3 Gotify

New event kind `feedback` added to `notify.EVENT_KINDS`
(`scripts/console/app/notify.py:43`), with a detector `detect_feedback(issues, stamp,
prev)` following the existing pattern: compute each issue's derived status, compare to
`state["feedback"][iid]`, emit one `Event` per *transition*, persist the new high-water.
Priorities: `deployed` → `P_LOW` with a click-through to the tab; `refused` and `stalled`
→ `P_HIGH` (something needs a human); everything else → `P_MUTED`. Individually
toggleable like every other kind, off by default until the operator enables it.

### 10.4 In-tab presentation

Each row: status chip · `#iid` · summary · age · severity dot. Tapping expands to show the
GitLab deep link, the MR link when there is one, the derived-status *reason* in plain
words ("merged 2 days ago; the console currently runs commit `1b0af43` from before that
merge — run `pl console deploy`"), and, for owners, the Arm/Disarm control. Tab count =
number of the viewer's own non-terminal issues; alert flag when any is `refused` or
`stalled`.

---

## 11. The `pl` surface

Everything drivable from the workstation, so the loop is testable in CI and survives the
console being down.

```
pl console feedback list   [--project <pid>] [--status new|armed|mr-open|merged|deployed|refused|all]
                           [--mine] [--json]
pl console feedback show   <iid> [--json]
pl console feedback create --kind bug|improvement|question --severity blocks|annoying|nice
                           --summary <s> [--detail <d> | --detail-file <f>]
                           [--project <pid>] [--dry-run] [--json]
pl console feedback arm    <iid> [--yes] [--force]        # owner path; typed confirm unless --yes
pl console feedback disarm <iid> [--reason <r>]
pl console feedback status [--json]                        # the CI-testable derivation surface
pl console stamp           [--json]                        # read the deploy stamp off the host
pl console rollback        [--to <stamp>] [--list]         # §9.5
```

Plus one small prerequisite outside the feedback feature:

```
pl loop parts --json        # machine-readable kill-switch state, so the arm gate
                            # can check it without re-implementing lib/loop-parts.sh
```

Implementation notes:

- New subcommands go in `scripts/commands/console.sh`'s `main()` dispatch
  (`console.sh:562-573`) — outside `scripts/console/`, buildable now.
- Shared logic goes in a new `lib/console-feedback.sh`: envelope construction, label set,
  body rendering, the redaction rules, the dedupe key. `scripts/commands/console.sh`
  sources it; a small Python mirror under `scripts/console/app/feedback.py` implements the
  same contract for the web path. **T9 asserts the two produce byte-identical bodies for
  the same envelope.** (Single-implementation alternative — have the console shell out to
  `pl console feedback create` — was rejected: the console host has no `.secrets.yml` and
  the action allowlist deliberately forbids adding new shell-out verbs.)
- `create`/`arm` on the workstation use `lib/gitlab-issues.sh` with
  `.secrets.yml:gitlab.ops_note_token`. **Never** `gitlab.api_token`.
- `arm --yes` still writes both audit records and still honours the rate limit and kill
  switch; `--yes` skips only the typed prompt, exactly as `-y` does for the deploy fate
  manifest.

---

## 12. Acceptance tests

Design rule for this section: **every test below has a written "make it go red" recipe.**
A check whose failure mode nobody has demonstrated is a vacuous pass.

| # | Test | Asserts | Make it go red by |
|---|---|---|---|
| **T1a** | `tests/unit/test-console-feedback.bats` — stub `gitlab_curl`, run one agent-loop tick, capture the polled URL | the poll URL contains `labels=agent-eligible`; an issue without it never appears in the candidate list | removing `labels=agent-eligible` from `agent-loop.sh:456` |
| **T1b** | **Integration (the real one):** create a console feedback issue via `pl console feedback create` against a scratch tracker; assert `agent-eligible ∉ labels`; run one tick with `AGENT_LOOP_DRY_RUN=1`; assert the log contains **no** `examining <pid>#<iid>` for that iid; then `arm` it and assert the next tick **does** examine it | an unpromoted issue is not picked up; a promoted one is | adding `agent-eligible` to the creation label set — the first half must fail |
| **T2** | Table-driven redaction: one row per rule in §5, plus **negative controls** | each secret shape is absent from the rendered body and appears in `redactions[]`; **and** the benign controls (`site nwd`, `pl demo reset`, `#412`, `1b0af43`) survive **verbatim** | deleting the `gitlab-pat` rule (a row fails); making the scrubber redact everything (a *control* fails). The controls are what stop "redact the whole body" from passing. |
| **T3** | Tenancy: build an envelope as a user scoped to project A from a gather containing project B's sites, audit lines and publisher host | no B site name, no B audit entry, no `prov.host` appears anywhere in the rendered body | building the envelope from the pre-`scope.redact()` context |
| **T4a** | AST test over `scripts/console/app/` | no module that builds the issue-creation payload contains the literal `agent-eligible` | adding it to the creation label list |
| **T4b** | Route test on the arm endpoint | `operator` → 403; `owner` without typed confirm → 400; `owner` with confirm → 200 + exactly one `feedback.arm` audit line + one GitLab note | lowering the dependency to `require("operator")` |
| **T5** | Run the loop's live pre-push regex against a fixture path list | every path in §9.3 **matches** | reverting the regex extension. **This test is red today** — that is F2, and it is the proof the extension is needed. |
| **T6** | Derived-status truth table over fixtures: (ancestor+clean+tree-ok) → `deployed`; (ancestor+dirty) → `deployed?`; (ancestor+tree-mismatch) → `deployed?`; (non-ancestor) → `merged`; (no stamp) → `unknown`; (merge_base API error) → `unknown` | `deployed` is returned **only** in the first case | changing case 2 to return `deployed` |
| **T7a** | `/health/ui` against a fixture template dir containing one deliberately broken template | `ok:false` and the broken template is named | making `/health/ui` return a literal, i.e. reintroducing F1 |
| **T7b** | Deploy-step contract test | `cmd_deploy`'s health step fails (non-zero) when `/health/ui` returns `ok:false` | pointing the check back at `/health` |
| **T8** | Arm gate conditions | arm refuses with `.loop-paused` present; refuses with `parts.state` `fix-loop=disabled`; refuses on the 4th arm in 24 h; refuses when the counter file is unwritable; each refusal audited with a distinct reason | making any single condition non-fatal |
| **T9** | Golden-file parity: same envelope through `lib/console-feedback.sh` and `app/feedback.py` | identical title, identical label set, identical body bytes | changing a label in one implementation only |
| **T10** | Dedupe | two identical submits ⇒ one issue + one "+1" note; the second call returns the first iid; a submit differing only in whitespace/case also dedupes; a genuinely different one does not | removing the normalise step (the third case then wrongly dedupes) |
| **T11** | Envelope size/shape fuzz | 5000-char detail refused with a visible error; a `client` field with `;`-injection or control characters is dropped whole, not partially parsed; a 20 KB envelope refused | relaxing the grammar to a permissive split |

Where they live: `T1a/T5/T7b/T8(bats parts)` → `tests/unit/*.bats` (repo root, runnable in
CI today). `T2/T3/T4/T6/T7a/T9/T10/T11` → `scripts/console/tests/` (v2 owner's tree).
`T1b` → `tests/integration/` and it needs a scratch GitLab project — **operator decision
§14-F** on whether to point it at a disposable tracker or gate it behind a
`NWP_TEST_GITLAB` env var and skip loudly (skip must print *why*, never pass silently).

---

## 13. Build order

Each phase ends in something demonstrable. Phases 1–3 touch **nothing** under
`scripts/console/` and can start immediately, in parallel with the v2 workflow.

| # | Phase | Files | Depends on |
|---|---|---|---|
| **1** | **Close F2 first.** Extend the loop's pre-push regex; add `loop::refused-sensitive`; add T5 (goes green). *Do this before anything else — it is the guard rail everything later leans on, and it is a live gap today regardless of whether the Feedback tab is ever built.* | `scripts/agent-loop/agent-loop.sh`, `tests/unit/` | — |
| **2** | **Routing.** `kinds.console` in `fix-repo-map.json`; `prompts/console.md`. Verify with a hand-made ops issue labelled `kind::console repo::nwp/nwp agent-eligible` and `AGENT_LOOP_DRY_RUN=1` — assert it routes to nwp/nwp and picks the right template. | `scripts/agent-loop/fix-repo-map.json`, `scripts/agent-loop/prompts/console.md` | 1 |
| **3** | **Shared contract + `pl` surface.** `lib/console-feedback.sh` (envelope, labels, body, redaction, dedupe key); `pl console feedback list/show/create/arm/disarm/status`; `pl loop parts --json`. T2, T9, T10, T11 (bash side). **The whole loop is now drivable from the workstation with no web UI at all** — demo it end to end before writing a line of front-end. | `lib/console-feedback.sh`, `scripts/commands/console.sh`, `scripts/commands/loop.sh`, `tests/unit/` | 2 |
| **4** | **Deploy stamp + always-on backup + rollback.** Write `~/.config/nwp-console/deploy-stamp.json`; back up on every deploy; `pl console stamp`, `pl console rollback`. | `scripts/commands/console.sh`, `lib/console-deploy.sh` | — (parallel with 1–3) |
| **5** | **`/health/ui` + deploy gate.** Add the deep health route; switch step 5/5 to it; T7a, T7b. | `scripts/console/app/` *(v2 owner)* + `scripts/commands/console.sh` | 4 |
| **6** | **Console read path.** `gitlab_api.create_issue()` + `merge_base()`; `app/feedback.py` (Python mirror of the contract); derived-status engine; `pane_feedback.html` (read-only list, no submit yet). T6. | `scripts/console/app/`, `templates/` *(v2 owner)* | 3, 5 |
| **7** | **Capture.** The form, the inline client-context script, `GET /feedback/preview`, `POST /feedback`, rate limits, dedupe wiring, tab registration in `PANES`. T3, T4a, T10, T11. | *(v2 owner)* | 6 |
| **8** | **The gate.** `POST /feedback/{iid}/arm` + `/disarm`, all six conditions, dual audit. T4b, T8. | *(v2 owner)* | 7 |
| **9** | **Notify.** `feedback` event kind + detector + toggle row. | *(v2 owner)* | 6 |
| **10** | **Prove it.** T1b end to end on a real issue: file from a phone → arm → agent MR → review → merge → `pl console deploy` → status flips to `deployed` → Gotify arrives. Then deliberately break each of T1b/T2/T5/T6/T7a and confirm each goes red. Record the transcript in this arc's decision log. | — | all |

---

## 14. Operator decisions required

Flagged rather than decided.

**A. Is "arm" owner-only, or does it need a second person?**
Recommendation: owner-only + typed confirm + rate limit + kill-switch check (§7.2). Two-
person arming is available if wanted (arm records a request; a second owner confirms) at
the cost of making the phone workflow useless when only one owner is awake.

**B. Console GitLab token scope.**
The derived status needs **read** on nwp/nwp (MR state + `merge_base`), while the walled
`ops_note_token` is scoped to nwp/ops (project 21). The CI pane already lists nwp/nwp MRs
with the current token, so the read may already exist — **verify with `pl secrets whose`
before designing around it.** If it does not: issue a *second, read-only* token file
(`~/.config/nwp-console/gitlab-read.token`) rather than widening the write-capable one.

**C. Block `scripts/console/app/main.py` in the pre-push gate, or not?**
Blocking it makes the fail-closed guard complete but makes `kind::console` nearly useless
(most console fixes touch `main.py`). Not blocking it leaves route-role/CSRF-guard/audit
removals to a targeted CI grep + human review. Recommendation: **don't block; add the
targeted CI grep** (§9.3). This is a real residual risk and should be an explicit
acceptance, not a default.

**D. Should any console button ever merge or deploy?**
Recommendation: **no.** Arming is bounded because merge and deploy are human. A "deploy
now" button would be deploy-gate-class (hardware presence) and would collapse two
independent human gates into one tap on a phone.

**E. Tenancy of the tracker.**
nwp/ops is one GitLab project; console tenancy filters the console's *view*, not GitLab's
(§8). Accept, or give console feedback its own tracker.

**F. Integration-test target for T1b.**
A disposable GitLab project for the "unpromoted issue is not picked up" test, or an
env-gated skip. A skip must print why it skipped — a silently-skipped T1b would be the
exact vacuous pass this spec is trying to avoid.

**G. Rate-limit numbers.**
Proposed: 3 arms/24 h console-wide; 10 submits/day and 3/hour per user. Tune to taste;
the arm limit should stay strictly below `AGENT_LOOP_DAILY_CAP` (currently 5).

---

## 15. Appendix — what NOT to do

- **Do not auto-add `agent-eligible`,** on any severity, from any code path. Two prior
  systems arrived at this rule independently (`GitLabSyncService.php:46-60`;
  `gitlab-webhook-receiver.py:372-418`).
- **Do not put the deploy stamp inside `~/nwp-console/src/`.** It will make the divergence
  guard refuse every future deploy (§3.4).
- **Do not extend `DEMO_HARVEST_LABELS`** to carry console routing — it is shared with
  every demo harvest (`scripts/commands/demo.sh:1240`).
- **Do not ship Quokka transcripts, chat prompts/replies, or full `argv` in the envelope.**
  They are in the audit log and they are user speech and site data (§5).
- **Do not let `/health` keep standing in for a real check** once `/health/ui` exists; a
  green deploy that proves nothing is worse than no check, because it is believed.
- **Do not add a dependency** to the console for any of this. Everything specified here is
  stdlib + the existing FastAPI/Jinja/htmx stack.
