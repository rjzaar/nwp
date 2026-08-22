# NWC FORK_GUIDE — generic package vs. your specific site

**Status:** skeleton (P65 item 6 / nwp/ops#32). Audience: anyone installing the
`nwp/nwc` community platform — including the operator running their own live site.
The rule this guide encodes: **behaviour/structure → the generic package;
content/identity → your private instance.**

---

## 1. The two layers

| Layer | Repo | Holds | Who owns |
|---|---|---|---|
| **Generic package** | `nwp/nwc` (public, versioned) | modules (engines/behaviour), the 9-tier `recipes/`, **template** content, site-neutral prose + `[nwc:*]` tokens | the project — improve it, everyone benefits |
| **Your instance** | a private root project (the operator's is `nwp/nwc-project`) | `composer.json` (requires `nwp/nwc`), **`config/sync/`** (your exported site config), `settings.php`, your `canonical_dir` legal texts, a content-seed manifest | you — never enters the package |
| **Content + files** | not git | DB (nodes, guilds, users) + uploaded files | you — via recipe-content or a sanitised DB copy |

A site = the package **installed and filled in**: `composer install` pulls
`nwp/nwc` → `drush site:install social` → apply a recipe → your config + content on top.

## 2. Install (any operator)

```bash
composer create-project <your>/nwc-project mysite   # root project requiring nwp/nwc
cd mysite && composer install                       # pulls the nwp/nwc package
ddev drush site:install social -y
ddev exec php -d memory_limit=2048M vendor/drush/drush/drush.php \
    recipe html/modules/custom/nwc/recipes/full     # generic community site (no demo, no content)
ddev drush cim -y                                   # import YOUR config/sync (identity, types, workflows)
```
A fresh `full` install with no demo and no content **is** the generic platform — that
is the "anyone can install" guarantee (kept green by the ops#3 fresh-install gate).
`recipes/demo` adds fixtures; your real content arrives per §4.

## 3. The generic-vs-specific rule (the discipline)

Every time you build, ask: **behaviour/structure, or content/identity?**

- **Behaviour / structure** (a module, field, workflow, recipe tier, rendering engine)
  → build it in **`nwp/nwc`**. Your site consumes it; so does everyone. *This is how your
  specific work improves the generic.*
- **Content / identity** (legal text, a course, org name, venue, guild charter prose)
  → keep it in **your instance** (config / `canonical_dir` / your content). The package
  ships only a **template/placeholder**.

**"Did I hardcode something specific?" checklist** — if any of these is baked into the
package, split it (generalise the code → token/config/template; move the value → instance):
- [ ] an organisation / site name, venue, jurisdiction, or person's name in code or prose
- [ ] a real legal text (vs a `template: true` placeholder) inside `nwc_copyright`
- [ ] a real email / domain in a webform, mailer, or config default
- [ ] seeded content that is *your* content rather than a demo fixture
- [ ] a statute citation or clause that is jurisdiction-specific presented as universal

## 4. Content: the three classes (what ships, and how it lands)

1. **Upstream-canonical governed docs** (legal texts, charters): version-synced;
   reconsent forced on version bump; a receiving operator can **pin or replace** the
   source dir (`nwc_copyright` `canonical_dir`). Identity substitution touches ONLY
   name/venue — never a substantive clause or statute citation.
2. **Editorial content** (courses, help pages): ships as **workflow-entering drafts**
   stamped `origin=upstream` on a site with the editorial workflow; published directly
   only on a demo install. `drush nwc-content:update` brings new versions as DRAFT
   revisions and skips locally-modified content.
3. **Fixtures** (`nwc_demo`, `nwc_devel`): install-time only; never on a canonical site.

## 5. Keeping your instance while the package improves

- Pull generic improvements: `composer update nwp/nwc && drush updatedb && drush cim`.
  Your config/content is untouched — it lives in your instance, not the package.
- Your identity/legal/content overrides survive package upgrades because they are
  config + `canonical_dir` + your content, applied *on top* of the package.
- Contribute back: when a specific need turns out to be general, build it in the
  package as behaviour + a template, and move your specific value into your instance.

## 6. Backup + build-prod (operator topology — see the session plan)

- **Backup the instance** = push the root project repo (code + `config/sync`) to a
  **private** git project + back up DB/files (`pl backup` / restic per NWP-ADR-0025).
- **Build prod** = clone the instance repo → `composer install` → `site:install social`
  + recipes → `drush cim` (config) → seed content (recipe-content or a sanitised DB
  copy through the deploy pipeline) → register in `nwp.yml`.
- **Keep working on dev** = dev *is* the instance checkout; `drush cex` + commit as you
  go; deploys flow dev → stg → live via the existing pipeline (`pl stg2live` / signed
  bundle / `nwp-server`). The package keeps improving on its own version track.

---
*Ratify as an ADR + fill the skeleton under nwp/ops#32 (P65 item 6). Legal-surface
substitution is fail-closed and human-reviewed; none of this rides in the ops#3
packaging MR.*
