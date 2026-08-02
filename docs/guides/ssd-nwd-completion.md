# ssd → nwd: making course progress flow back

**Status:** demo tier wired and proven end-to-end on live, 2026-08-02.
**Direction:** Moodle → Drupal, **one direction only**.

## The question this answers

The tester invitation asks *"would you expect finishing a course to move your
community progress?"* That was always meant to be an opinion question. Until
now the answer was that it *could not*, by construction: every bridge between
the two halves was unconfigured, and two of them ran the wrong way.

## The three bridges, and what each turned out to be

| Bridge | What it actually is | Direction | Verdict |
|---|---|---|---|
| `nwc_moodle_sync` | Drupal module: pushes guild membership out as Moodle cohort/role assignments | **nwd → ssd** | **Not wired.** Wrong direction for progress; superseded on this pair by `auth_nwc`'s own guild-claim reconciliation at login (`pairs/ssd.pair-contract.yml`, `surfaces.role_cohort_sync`); and its `hook_cron` calls `createInstance('nwc_moodle_sync_user')` for a QueueWorker plugin **that does not exist anywhere in the tree**. Enabling it would have armed a broken push. |
| `nwc_sojourner_completion` | **Not a module** — a database table owned by `nwc_guild`, written by `SojournerProgressionService` | n/a (sink) | **Wired as the sink.** It was empty because nothing had ever called `recordCompletion()` except a manual drush command. Its `source` column has anticipated the value `moodle_pull` since ops#65; this is the first thing to write it. |
| `auth/nwc` (Moodle) | The OIDC/SSO consumer plugin | **nwd → ssd** | **Not changed.** It has *no outbound HTTP at all* — OIDC carries claims **into** Moodle at login and carries nothing back out. `GuildClaimsService` emits guild uuids the same way, also inbound, also inert here. |

### The fourth thing, which is the one that mattered

`nwc_moodle_data` — the sibling module that already reads Moodle over its REST
web service to display badges on profiles. It is the **only** existing channel
that runs ssd → nwd, and it already owns a `moodle_url` + `webservice_token`
pair. The bridge is built on it rather than beside it.

We also checked the other Moodle-side plugins before adding anything, so as not
to build a fourth channel next to three existing ones:

* `local/practice` — no network egress at all; its "sync" reads JSON off disk.
* `mod/depthcontent` — has one outbound curl to Drupal, permanently dead: it
  reads its base URL and token from `get_config('local_avc_copyright_sync', …)`
  and **that component does not exist** (the plugin is `local_nwc_copyright_sync`).
* `local/feedback` — a real, working Moodle → Drupal push, but for feedback, and
  unconfigured. It is the house pattern for cross-site auth, not for completion.
* **No plugin anywhere on ssd or ssc observes `\core\event\course_completed`.**

That last fact is the whole argument for a pull. There is no completion event
leaving Moodle to hook, so a push would have meant inventing a new channel and a
new inbound endpoint on nwd. A pull reuses a channel, a credential shape and a
transport that already exist.

## What was actually wrong upstream

Measured on ssd live before any change:

```
courses with enablecompletion=1 ............ 58 of 59
depthcontent activities tracking completion . all (completion=2, completionview=1)
rows in {course_completion_criteria} ........ 0        <-- site-wide
rows in {course_completions} ................ 0
```

A member could finish every activity in a course and the course would still
never complete, because nothing had ever been declared to *be* the completion
condition. Over the web service that reads exactly as:

```
demo_discern   completed=False   progress=100
```

No amount of Drupal-side wiring can fix that: there is no completion to carry.
`scripts/demo/ssd-completion-criteria.sh` declares one
`COMPLETION_CRITERIA_TYPE_ACTIVITY` row per completion-tracked activity,
aggregated `ALL` — "finish every activity, finish the course", which is the
reading the checkboxes already imply to a tester.

**It is deliberately not applied to all 58 courses.** `--courses` is required
and there is no `all` shortcut; ssd course content is owned elsewhere.

## The wiring

```
ssd (Moodle)                                    nwd (Drupal)
────────────                                    ────────────
mdl_user.idnumber = nwd account uuid  ◄──── auth_nwc writes this at SSO
        │
        │  read-only WS, 3 functions, 1 restricted service account
        ▼
core_user_get_users_by_field(idnumber) ────►  MoodleDataService::getUserIdByIdnumber()
core_enrol_get_users_courses(userid)   ────►  MoodleDataService::getUsersCourses()
                                                        │
                                                        ▼
                                              SojournerCompletionPull::pullFor()
                                                        │  shortname matches /^[A-J]\d{1,2}$/
                                                        ▼
                                              nwc_sojourner_completion  (source=moodle_pull)
                                                        │
                                                        ▼
                                              SojournerProgressionService::applyFor()
                                                        │
                                                        ▼
                                              users_data nwc_guild:sojourner_level
```

The join key is `idnumber`, **not email**. `idnumber` is the contractual
UID-lock (`oidc.user_field_mappings: sub → idnumber`); the same contract sets
`link_legacy_by_email: 0` precisely to stop identities being joined on a mutable
field, and an email join would quietly reintroduce that.

### The credential

Registry id **`ssd_nwd_completion_ws`** (`private/secrets-registry.yml`, entry
#35). Minted by the provisioner, never printed, never in git.

The whole surface, and nothing more:

| Web-service functions (all read) | Capabilities |
|---|---|
| `core_webservice_get_site_info` | `webservice/rest:use` |
| `core_user_get_users_by_field` | `moodle/user:viewdetails` |
| `core_enrol_get_users_courses` | `moodle/site:viewuseridentity` |
| | `moodle/course:viewparticipants` |
| | `moodle/course:view` |
| | `report/completion:view` |
| | `moodle/course:viewhiddencourses` → **PREVENT** |
| | `moodle/course:viewhiddenuserfields` → **PREVENT** |

Service `nwd_completion_pull` is `restrictedusers=1`, bound to one account
(`nwd_completion_reader`, `auth=webservice`, cannot log in interactively). The
registry entry carries a **negative probe** asserting that a write call
(`core_user_update_users`) returns `accessexception`.

Every capability above was derived by **reading `enrol/externallib.php` on the
target**, not guessed. Two of them are non-obvious and both fail *silently*:

* without `moodle/course:view`, `validate_context()` throws inside the loop and
  every course is skipped by a `catch { continue; }` — the call returns an
  **empty array, not an error**;
* without `report/completion:view`, the courses come back but the `completed`
  flag never does.

An empty result from a member you know is enrolled means the token is
under-privileged. Re-run `--check`.

### One site setting had to change

`showuseridentity` on ssd: `email` → `email,idnumber`. Moodle only *searches*
the fields listed there, so with the stock value the idnumber lookup returns
`[]` — no error, just nothing. The provisioner asserts this and prints the
previous value when it changes it.

## The tier boundary

Two independent gates, and **both** must be true:

1. `nwc_moodle_data.settings:enable_completion_pull` — ships `false`.
2. `nwc_demo_access.settings:demo_mode` — ships `false`, and is true only on the
   daily-reset demo pair.

`nwc_demo_access` is **not even installed on nwc**, so `demo_mode` reads `NULL`
there and the pull is inert no matter what the first flag says. On the
provisioning side, both scripts resolve their target through
`demo_pair_contract_for`, which only matches a contract carrying
`demo.enabled: true` — `pairs/ssc.pair-contract.yml` has no `demo:` block at
all, so running either script against `ssc` refuses.

> **Not a plain boolean cast.** These flags are set on the demo tier through
> `settings.local.overrides.php`, which emits every value as a quoted PHP
> *string* — and `(bool) 'false'` is `TRUE`. `SojournerCompletionPull::flag()`
> treats `''`/`0`/`false`/`no`/`off` as false. There is a dataprovider test for
> exactly this.

### Phase 2 — what changes when ssc/nwc become prod

Three things must change, and none of them is a flag flip:

1. **The credential must leave the AI-readable tier.** `.secrets.yml` is
   acceptable here *only* because ssd's entire population is
   `user<N>@demo.invalid` and is wiped nightly. Against a prod Moodle holding
   real learners' completion records, a token that reads any member's course
   history is not infrastructure-tier. Use the provisioner's `--token-to-nwd`
   path instead: it writes the value straight into the co-located Drupal's
   `settings.local.overrides.php` on the same box, so it never crosses the
   network and never reaches `.secrets.yml`. That is the shape the registry
   already records for `nwc_ss_copyright_sync`.
2. **The tier gate must be re-expressed.** `demo_mode` is the demo tier's own
   flag; a prod pair will never set it. A prod arming needs its own condition —
   most naturally the site's canonical phase — and it must be an explicit
   decision recorded against the pair contract, not an inherited `true`.
3. **Completion criteria on a prod Moodle are a content decision.** Declaring
   "all activities ⇒ course complete" retroactively marks complete every learner
   who already finished the activities. On the demo tier that is the point. On
   prod it back-dates recognition for real people and must be reviewed by
   whoever owns the course design.

Until all three are answered, the honest state is: **demo only.**

## Running it

```bash
# Moodle side (dry-run by default)
scripts/demo/ssd-completion-ws-provision.sh --tier=live --check
scripts/demo/ssd-completion-ws-provision.sh --tier=live --apply
scripts/demo/ssd-completion-criteria.sh --tier=live --courses=B1,B2,B3,B4 --check

# Drupal side
pl secrets inject nwd --tier=live --dry-run
pl secrets inject nwd --tier=live --apply

# Status + a pull
pl drush nwd --tier=live --execute -- nwc-moodle:completion-status
pl drush nwd --tier=live --execute -- nwc-moodle:pull-completions 21
```

`hook_cron` runs `pullAll()` at most every `completion_pull_interval` seconds
(default 900), scanning `completion_pull_batch` most-recently-active members.

## Proven, on live, 2026-08-02

| | |
|---|---|
| Member | `Benedict-0000`, nwd uid 21, uuid `33992be8-…` |
| Resolved to | ssd uid 6 (`mdl_user.idnumber` = that uuid — the UID-lock held) |
| Did | self-enrolled in B1–B4, completed every tracked activity |
| Moodle decided | `completion_regular_task` marked all four courses complete |
| Over the wire | `B1..B4 completed=True`, `D1 completed=False progress=25` (negative control) |
| nwd recorded | 4 rows in `nwc_sojourner_completion`, `source=moodle_pull` |
| **The number moved** | `users_data nwc_guild:sojourner_level` **absent → 1** (L0 → L1, "Inquirer") |

## Two pre-existing defects this surfaced

1. **`nwc_notification` throws on every Sojourner level grant.**
   `SojournerProgressionService::applyFor()` invokes
   `hook_nwc_guild_level_granted` with the *string* `'sojourner-path'` as
   `$skill`; `nwc_notification.module:252` passes it to
   `SkillConfigurationService::getLevelConfig()`, which requires a
   `TermInterface`. Observed on the live run:
   `Failed to queue level-granted notification: … must be of type
   Drupal\taxonomy\TermInterface, string given`. **The level still moves** — the
   `catch (\Throwable)` swallows it — but the member is never congratulated.
   Not fixed here: it is `nwc_notification`'s contract with the skill path, and
   fixing it blind risks the *other* caller (`SkillProgressionService`, which
   does pass a term).

2. **`nwc_moodle_sync`'s queue has no worker.** `hook_cron` calls
   `createInstance('nwc_moodle_sync_user')` unconditionally and no such
   QueueWorker plugin exists in the tree. Anyone who enables that module gets a
   `PluginNotFoundException` on every cron run. It is off, and should stay off
   until that is either built or the module is retired.
