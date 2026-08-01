# `live` (sites1) — the box that serves every live site

Mirror of what is actually configured on the box, so a rebuild does not depend
on one machine's disk. Captured 2026-08-01, after the 2026-07-31 box split.

> **Read `servers/nwpcode/` for the OTHER box.** After the split, `nwpcode`
> (git.nwpcode.org) runs GitLab, headscale and `pray.rosaryforge.org` only. Its
> `nginx/conf.d/` copies of the site vhosts are the PRE-SPLIT history — the
> sites they describe now live here. The two boxes are genuinely different
> shapes and their configs must not be cross-applied:
>
> | | `live` | `nwpcode` |
> |---|---|---|
> | web server | **system nginx**, systemd | **GitLab's bundled nginx**, runit |
> | `/opt/gitlab` | absent (purged in the split) | present |
> | certbot deploy hook | `systemctl reload nginx` | `gitlab-ctl hup nginx` |

## What was fixed here on 2026-08-01

Three faults, all of them consequences of the split, all found while auditing
something else. Each was invisible until the moment it would have mattered.
A fourth item (§4) is not split damage — it is the one renewal that would have
undone the fix to §2 by keeping `certbot.service` permanently red.

### 1. `nginx -t` FAILED — the box could not have rebooted

`conf.d/nwd.conf:45` still did `include /opt/gitlab/embedded/conf/fastcgi_params`,
a path purged with GitLab. The **running** master (started 07:38 on 31 July) held
the last good config in memory, so every site served normally and nothing looked
wrong. Any reload, restart or reboot would have taken **every live site down**,
and the box would not have come back on its own.

Fixed to the stock `/etc/nginx/fastcgi_params`. The vhost already sets
`SCRIPT_FILENAME` itself, which is exactly why `fastcgi_params` (not
`fastcgi.conf`) is the right one.

### 2. Every certbot lineage would have failed to renew

**13 of the 14 loaded vhosts returned a bare `301` from their port-80 block**,
including `/.well-known/acme-challenge/`. Every lineage on this box uses the
**webroot** authenticator. So the challenge could never be answered and no
certificate could ever renew. Only `rgv.conf` had the exception.

This was not theoretical and not future: `ss2` had already been failing **every
day since the split** (19 days of validity left when found), and `certbot.service`
had been red that whole time. `ba` was 4 days from starting to fail, then `hs`,
`sso`, `mt`, and in time all of them.

Every port-80 block now carries:

```nginx
location ^~ /.well-known/acme-challenge/ { auth_basic off; root <webroot>; allow all; }
location / { return 301 <original target>; }
```

`<webroot>` is read from that lineage's own
`/etc/letsencrypt/renewal/<name>.conf`, never guessed — `ss` renews against
`/var/www/ssc`, which no amount of inference would have produced.

Verified by planting a token in each webroot and fetching it over plain HTTP:
**13/13 returned 200 with the right body**, and `certbot renew --dry-run`
succeeds for the lineage that had been failing.

### 3. The certbot deploy hook pointed at a binary that no longer exists

`reload-gitlab-nginx.sh` ran `/opt/gitlab/bin/gitlab-ctl hup nginx` under
`set -e`. On this box that can only fail — which means certbot counted an
otherwise successful renewal as a **failure**, and the renewed certificate was
never loaded. A hook written for a machine that no longer exists is worse than
no hook.

Replaced by `letsencrypt/renewal-hooks/deploy/reload-nginx.sh`, which tests the
config first and then `systemctl reload nginx`. The `nginx -t` step is
deliberate: fault 1 above is exactly the case where a bare reload would fail
with nothing in the journal explaining why.

**The equivalent hook on `nwpcode` is correct as written and must be left
alone** — that box really does run GitLab's nginx.

### 4. `cccrdf`'s renewal was the last thing that would have turned the service red

Fixing faults 1–3 took the fleet dry-run to **14 success / 1 failure**. The one
failure was `cccrdf.nwpcode.org`, and it was on a clock: that certificate
expires 2026-10-12, so it enters its 30-day renewal window around **2026-09-12**
and from then fails *every night*. A permanently-red `certbot.service` is
precisely the condition that hid fault 2 for 19 days — one lineage nobody
believes in makes the signal useless for the fourteen that matter.

The cause was **DNS only**: `cccrdf.nwpcode.org` still resolves to
`97.107.137.88` (the old box), so the webroot challenge is fetched from a
machine that does not serve it and 404s. The renewal conf's `webroot_map` was
**correctly populated** (`cccrdf.nwpcode.org = /var/www/cccrdf/web`) — an
earlier note claiming it was empty was wrong.

**Resolution: the lineage was deleted, not repaired** (2026-08-01,
`certbot delete --cert-name cccrdf.nwpcode.org`). The evidence says this site is
not meant to serve from here:

- `PUBLIC-PRIVATE-STRATEGY.md` §2.10 classes cccrdf **PRIVATE-FOREVER**
  (early-stage); the copyright inventory classes it 🔒 **DEV-ONLY**.
- It is a Neo4j knowledge-graph browser over the **Catechism text**, which is
  LEV/USCCB copyright — the operator's permission is AU/NZ-only and scoped to
  `cathnet.org`, not to this hostname.
- `SYSTEM-AUDIT-AND-PHASED-PLAN-2026-07-18.md` Phase 2 moves **neo4j + cccrdf
  off this box to `met`**, then stops and disables them here. Its future is not
  on `live`.
- The stack is already switched off: `neo4j` inactive, `cccrdf-api.service`
  inactive **and disabled**, vhost mothballed on both boxes since 2026-07-29
  (deliberate, two days before the cutover). Restoring the vhost would publish a
  site whose backend is down.
- The Drupal has **0 nodes / 2 users** — no content — on 10.6.5 with **51 open
  composer advisories** (`pl rag`: RED) and `drupal:drupal` DB credentials.

Deleting a lineage is not deleting the ability to have one: if Phase 2 lands and
cccrdf is wanted here (as a `proxy_pass` to met), certbot re-issues in seconds
once DNS points at `live` and the ACME location exists. Nothing else was
touched — the data, the DNS record, the declaration and the mothballed vhost all
remain.

Backup before deletion: **`/root/cccrdf-cert-retire-20260801/`** on the box —
`live/`, `archive/` and `renewal/` copied verbatim, plus
`letsencrypt-cccrdf-20260801.tar.gz` (relative symlinks preserved) with a
`.sha256`.

⚠️ `mothballed-20260729/cccrdf.conf` now references
`/etc/letsencrypt/live/cccrdf.nwpcode.org/` which **no longer exists**. Restoring
that file into `conf.d/` without first re-issuing the certificate will fail
`nginx -t`. It also still carries the fault-1 bug
(`include /opt/gitlab/embedded/conf/fastcgi_params`) and has **no ACME challenge
location** — so a restore needs all three fixed, not just a `mv`.

Fleet dry-run after: **14 success / 0 failure**, `certbot.service`
`Result=success`. Fourteen lineages, fourteen served vhosts, no orphans.

### 5. Postfix still identified as `git.nwpcode.org` (fixed 2026-08-01, second pass)

`myhostname = git.nwpcode.org` — clone leftover from the split. Every message
this box sent HELO'd/stamped `Received:` headers as the *other* box. Set to
`live.nwpcode.org`, which is what forward AND reverse DNS already said this box
is (`live.nwpcode.org → 45.33.76.180`, PTR `45.33.76.180 → live.nwpcode.org`,
and the IP is in the nwpcode.org SPF record). `mydomain`/`myorigin` stay
`nwpcode.org`, so envelope-from domains and DKIM (opendkim milter on :8891) are
unaffected. Applied with `postconf -e` + `postfix reload`; prior main.cf backed
up to `/var/backups/main.cf.20260801`
(sha256 `6fa783a2788e3722e208ee739466cafb81bedc22e59c5d4106478d7550ce921b`).
The mirror of the resulting `/etc/postfix/main.cf` is `postfix/main.cf` here.

One deferred queue entry from the same morning — a Moodle new-sign-in notice to
the synthetic `policycheck20260801@invalid.local` probe account (device
`curl/8.5.0`, source IP the box itself) — was inspected with `postcat -q` and
deleted; `.local`/`invalid.local` can never deliver. Queue empty after.

⚠️ Still stale, deliberately untouched: the OS hostname is `git` (also a clone
leftover). Renaming a hostname mid-flight touches more than mail
(`/etc/hosts`, logs, monitoring identity), so it is left for an operator
decision rather than fixed as a side effect here.

## What is NOT here

`conf.d/*.bak*`, `retired-*/` and `mothballed-*/` on the box are excluded:
nginx loads `conf.d/*.conf` only, so they are history, not configuration.
`cccrdf` is mothballed on both boxes and its A record still points at the old
one; its certificate was retired on 2026-08-01 (see fault 4 above). See
`DNS-JUNK-AUDIT-2026-08-01.md`.
