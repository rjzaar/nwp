# git.nwpcode.org — nginx vhosts (versioned for DR reproducibility)

This directory versions the nginx configuration of the **git.nwpcode.org box**
(97.107.137.88 — hosts GitLab plus the avc / ss / dir / nwc / mt / … vhosts) so
that a box rebuild is reproducible. Filed against the P1 / DR gap.

## Critical: this box uses GitLab's BUNDLED nginx, not system nginx

The nginx that actually serves every vhost is **GitLab's bundled nginx**
(`/opt/gitlab/embedded/sbin/nginx -p /var/opt/gitlab/nginx`, managed by runit).
The system `nginx.service` is **failed/disabled** and serves nothing — do not
`systemctl start nginx` (it would fight GitLab nginx for :80/:443).

Custom vhosts are wired in because GitLab's
`/var/opt/gitlab/nginx/conf/nginx.conf` contains:

```
include /etc/nginx/conf.d/*.conf;
```

So each file in `conf.d/` here corresponds to `/etc/nginx/conf.d/<name>.conf`
on the box.

- **Test config:** `sudo /opt/gitlab/embedded/sbin/nginx -p /var/opt/gitlab/nginx -t`
- **Reload:** `sudo gitlab-ctl hup nginx`  (NOT `systemctl reload nginx`)

## Contents

- `conf.d/*.conf` — the ACTIVE vhosts captured (read-only) from
  `/etc/nginx/conf.d/*.conf` on the box. `.bak` / `.backup` files on the box
  were intentionally **not** captured. These are verbatim copies containing no
  secrets — only public server names and standard `/etc/letsencrypt/live/<host>/`
  cert paths (the private keys themselves live only on the box and are never
  copied here).
- `renew-hook.sh` — certbot renew **deploy-hook** that reloads GitLab nginx
  after a certificate renews. See below.

## Certbot renewal gap (why `renew-hook.sh` exists)

`certbot renew` renews the cert files under `/etc/letsencrypt/live/<host>/` but
does **not** know how to reload GitLab's bundled nginx. Without a deploy hook,
every renewed cert on the box keeps serving the OLD certificate until it
expires — a silent, box-wide cert-expiry outage risk. `renew-hook.sh` closes
this by running `gitlab-ctl hup nginx` after each successful renewal.

## Applying on a rebuilt / repaired box

Do this **on the box** as root (never from the tool repo automatically):

1. Restore the vhosts:

   ```bash
   sudo cp conf.d/*.conf /etc/nginx/conf.d/
   sudo /opt/gitlab/embedded/sbin/nginx -p /var/opt/gitlab/nginx -t   # validate
   sudo gitlab-ctl hup nginx                                          # apply
   ```

   (TLS certs are issued/renewed separately via
   `certbot certonly --webroot -w <docroot> -d <host> --key-type ecdsa`; the
   vhosts reference `/etc/letsencrypt/live/<host>/` which must exist first.)

2. Install the renewal deploy-hook (currently MISSING on the box):

   ```bash
   sudo install -m 0755 renew-hook.sh \
     /etc/letsencrypt/renewal-hooks/deploy/reload-gitlab-nginx.sh
   sudo certbot renew --dry-run    # verify the hook wiring
   ```

## Re-capturing after a change on the box

These are copies. If a vhost changes on the box, re-capture it (read-only) and
commit the update:

```bash
for f in $(ssh -i ~/.ssh/gitlab_linode gitlab@ss.nwpcode.org \
             'sudo ls /etc/nginx/conf.d/*.conf' | xargs -n1 basename); do
  case "$f" in *.bak*|*.backup*) continue;; esac
  ssh -i ~/.ssh/gitlab_linode gitlab@ss.nwpcode.org "sudo cat /etc/nginx/conf.d/$f" \
    > "conf.d/$f"
done
```

## Repository placement note

`servers/*` contents are gitignored by design in the public `nwp` tool repo
(per-host operator config). These files were added with `git add -f` so the
capture is reviewable on the branch; the operator should confirm whether they
belong here or in the separate `servers/nwpcode/` local repo (alongside the
existing `backup/` scripts).
