# F17: Create and Deploy mt.nwpcode.org

**Status:** PROPOSED
**Created:** 2026-02-13
**Author:** Rob, Claude Opus 4.6
**Priority:** High (blocks F16 going live)
**Depends On:** F16 (mass times scraper — implemented)
**Breaking Changes:** No
**Site:** mt.nwpcode.org

---

## 1. Purpose

Create the mt.nwpcode.org Drupal site on the shared NWP server (97.107.137.88), install the `mass_times` module, and deploy the Python scraper pipeline so the F16 system can begin operating.

F16 implemented all the code — this proposal covers the infrastructure to make it live.

---

## 2. Prerequisites

| Requirement | Status |
|---|---|
| Python scraper pipeline (`mt/`) | Done (F16) |
| Drupal module (`modules/mass_times/`) | Done (F16) |
| `pl mass-times` CLI command | Done (F16) |
| Deploy/setup scripts | Done (F16) |
| Config in `example.nwp.yml` | Done (F16) |
| Secrets template in `.secrets.example.yml` | Done (F16) |
| Shared server at 97.107.137.88 | Exists (git.nwpcode.org) |

---

## 3. Implementation Phases

### 3.1 Phase 1: Recipe & Configuration

Add an `mt` recipe to `nwp.yml` and `example.nwp.yml` for the mass times Drupal site.

1. Add `mt` recipe under `recipes:` in `example.nwp.yml`:
   - `source: drupal/recommended-project:^10.2`
   - `profile: standard`
   - `webroot: web`
   - `install_modules:` — geofield, paragraphs, entity_reference_revisions, jsonapi_extras, pathauto, metatag, simple_sitemap, webform, leaflet
   - Options: environment_indicator, cron, backup, ssl
2. Copy the recipe to `nwp.yml`.
3. Enable mass_times settings in `nwp.yml` (`enabled: true`).
4. Set `shadow_mode: true` (all data provisional until validated).
5. Populate API keys in `.secrets.yml`:
   - `mass_times.claude_api_key` (for Tier 3 fallback)
   - `mass_times.google_places_api_key` (for parish discovery)
   - `mass_times.drupal_api_password` (for JSON:API sync)

**Verification:** `yq eval '.recipes.mt' nwp.yml` returns the recipe.

### 3.2 Phase 2: Local Site Installation

Create the Drupal site locally using the NWP install workflow.

1. Run `./install.sh mt mt` to create `sites/mt/`.
2. Verify Drupal installs and Drush is available.
3. Copy `modules/mass_times/` into `sites/mt/web/modules/custom/`.
4. Install required contrib modules:
   - `composer require drupal/geofield drupal/paragraphs drupal/entity_reference_revisions drupal/jsonapi_extras drupal/pathauto drupal/metatag drupal/simple_sitemap drupal/webform drupal/leaflet`
5. Enable the mass_times module: `drush en mass_times`.
6. Verify schema installs: `drush sqlq "SHOW TABLES LIKE 'mass_times_%'"` — expect 5 tables.
7. Verify config: `drush cget mass_times.settings` — expect centre_lat, centre_lng, radius_km, shadow_mode.
8. Verify admin dashboard: visit `/admin/mass-times`.
9. Register the site in `nwp.yml` under `sites:`:
   ```yaml
   mt:
     directory: /home/rob/nwp/sites/mt
     recipe: mt
     environment: development
     created: 2026-02-13T00:00:00Z
     purpose: indefinite
     installed_modules:
       - drupal/geofield
       - drupal/paragraphs
       - drupal/entity_reference_revisions
       - drupal/jsonapi_extras
     live:
       enabled: true
       domain: mt.nwpcode.org
       server_ip: 97.107.137.88
       linode_id: shared
       type: shared
   ```

**Verification:** `drush status` shows a working Drupal installation with mass_times enabled.

### 3.3 Phase 3: DNS & SSL

Configure DNS and SSL for mt.nwpcode.org on the shared server.

1. Create DNS A record for `mt.nwpcode.org` → `97.107.137.88` via Cloudflare/Linode API.
2. Configure Apache/Nginx vhost on the shared server for mt.nwpcode.org.
3. Obtain SSL certificate (Let's Encrypt via certbot or Cloudflare origin cert).
4. Verify HTTPS: `curl -I https://mt.nwpcode.org` returns 200.

**Verification:** `https://mt.nwpcode.org` loads in a browser.

### 3.4 Phase 4: Deploy Drupal to Production

Deploy the Drupal site to the shared server.

1. Run `pl live mt` to deploy the site to the shared server.
2. Import the database or run `drush site:install` on the server.
3. Copy `modules/mass_times/` to the production site's `modules/custom/`.
4. Enable the module on production: `drush en mass_times`.
5. Configure mass_times settings via `/admin/mass-times/settings`:
   - Centre: -37.8131, 145.2285 (Ringwood)
   - Radius: 20 km
   - Shadow mode: on
6. Create the `mass_times_bot` Drupal user with JSON:API write access.
7. Verify JSON:API endpoint: `curl https://mt.nwpcode.org/jsonapi/node/parish`.

**Verification:** Admin dashboard at `https://mt.nwpcode.org/admin/mass-times` loads with zero parishes.

### 3.5 Phase 5: Deploy Scraper Pipeline

Deploy the Python scraper to the shared server and run the initial extraction cycle.

1. Run `pl mass-times --deploy` (executes `mt/deploy-mass-times.sh`).
2. Verify config generation: `mass-times.conf` written with correct values.
3. Verify rsync to server: `mt/` directory present at `~/mt/` on server.
4. Verify setup: `~/mt/setup-mass-times.sh` runs, creates venv, installs cron.
5. Run initial discovery: `~/mt/run-mass-times.sh --discover`.
6. Review discovered parishes: `~/mt/run-mass-times.sh --report`.
7. Build templates: `~/mt/run-mass-times.sh --build`.
8. Run first extraction (dry run): `~/mt/run-mass-times.sh --extract --check`.
9. Run first real extraction: `~/mt/run-mass-times.sh --extract`.
10. Verify Drupal sync: parishes appear at `https://mt.nwpcode.org/parishes`.

**Verification:** `~/mt/run-mass-times.sh --status` shows parishes discovered, templates built, extractions complete.

### 3.6 Phase 6: Validation & Shadow Mode Exit

Validate extracted data before making it public.

1. Review extraction report: `~/mt/run-mass-times.sh --report`.
2. Check tier distribution — target: >80% Tier 1/2 (no LLM).
3. Spot-check 5 parishes manually against their websites.
4. Monitor daily cron runs for 1 week (check `mass-times.log`).
5. Review any flagged extractions in Drupal admin.
6. If accuracy >95%: disable shadow mode in `nwp.yml` (`shadow_mode: false`).
7. Re-deploy config: `pl mass-times --deploy`.
8. Verify public pages show confirmed (not provisional) data.

**Verification:** `https://mt.nwpcode.org/parishes` displays mass times with "Confirmed" status.

---

## 4. Site Architecture

```
Shared Server (97.107.137.88)
├── Drupal site (mt.nwpcode.org)
│   ├── modules/custom/mass_times/     # Drupal module
│   ├── /admin/mass-times              # Admin dashboard
│   ├── /admin/mass-times/settings     # Settings form
│   ├── /admin/mass-times/parishes     # Admin parishes view
│   ├── /parishes                      # Public parishes listing
│   └── /jsonapi/node/parish           # JSON:API endpoint
│
└── ~/mt/                              # Python scraper pipeline
    ├── run-mass-times.sh              # Venv wrapper
    ├── mass-times.conf                # Generated config
    ├── templates/                     # Parish extraction templates
    ├── data/
    │   ├── parishes.json              # Discovered parishes
    │   ├── sources.json               # Source endpoints
    │   ├── results/                   # Extraction results (JSON)
    │   ├── bulletins/                 # Archived PDFs
    │   └── pages/                     # Archived HTML snapshots
    └── cron: 3am daily → --extract
```

---

## 5. Risk Mitigation

| Risk | Mitigation |
|---|---|
| Bad data published | Shadow mode on by default; manual review before exit |
| Scraper blocks parish websites | Rate limiting (2s delay), robots.txt respect, polite User-Agent |
| LLM costs spike | Daily limit (10 Tier 3/day), monthly cap ($5/month), code-first approach minimises LLM use |
| Server resource contention | Cron at 3am; lightweight Python; shared server has headroom |
| Parish website changes break extraction | Change detection flags issues; weekly report; user report form |

---

## 6. Success Criteria

- [ ] mt.nwpcode.org accessible via HTTPS
- [ ] mass_times module installed and functional
- [ ] Parish discovery finds >10 parishes within 20km
- [ ] >80% of parishes extract at Tier 1 or Tier 2 (no LLM)
- [ ] Daily cron runs reliably for 7 consecutive days
- [ ] Shadow mode exited after manual validation
- [ ] Public `/parishes` page displays mass times for nearby parishes

---

## 7. Estimated Costs

| Item | Cost |
|---|---|
| Server | $0 (shared with git.nwpcode.org) |
| Domain/DNS | $0 (subdomain of nwpcode.org) |
| SSL | $0 (Let's Encrypt / Cloudflare) |
| LLM (Tier 3 fallback) | ~$1/month (most parishes use Tier 1/2) |
| Google Places API | Free tier (discovery is one-off) |
| **Total ongoing** | **~$1/month** |
