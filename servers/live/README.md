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

## What is NOT here

`conf.d/*.bak*`, `retired-*/` and `mothballed-*/` on the box are excluded:
nginx loads `conf.d/*.conf` only, so they are history, not configuration.
`cccrdf` is mothballed on both boxes while its A record still points at the old
one — a repoint decision, not drift. See `DNS-JUNK-AUDIT-2026-08-01.md`.
