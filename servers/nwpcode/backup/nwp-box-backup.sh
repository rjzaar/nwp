#!/usr/bin/env bash
# nwp-box-backup.sh — LOCAL backup producer on the GitLab/sites box.
# Installed as a ROOT cron (one-time operator step). Writes everything the
# met stick-backup pull needs into /var/backups/nwp-pull/ (gitlab-readable).
#
# Produces:
#   gitlab/  newest GitLab data tarball (repos+DB+uploads; NOT /etc/gitlab —
#            the secrets file is operator-carried by design, ops#25)
#   db/      per-database mysqldump .sql.gz for all site DBs
#   nginx/   /etc/nginx/conf.d + sites-enabled tarball
# Retention: keeps RETAIN_DAYS locally (the stick keeps its own generations).
#
# Install (operator, once):
#   sudo cp nwp-box-backup.sh /usr/local/sbin/ && sudo chmod 755 /usr/local/sbin/nwp-box-backup.sh
#   echo '30 1 * * * root /usr/local/sbin/nwp-box-backup.sh' | sudo tee /etc/cron.d/nwp-box-backup
set -u
OUT=/var/backups/nwp-pull
RETAIN_DAYS=2
LOG=/var/log/nwp-box-backup.log
log(){ printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

mkdir -p "$OUT"/{gitlab,db,nginx}

# 1. GitLab application backup (repos, DB, uploads, CI). Skip if one ran <20h ago.
#
# This script runs on BOTH boxes, and after the 2026-07-31 split only one of
# them has GitLab: `live` had its cloned copy purged, so `gitlab-backup` is not
# on that box at all. Without this guard the nightly run shells out to a
# missing binary, logs a command-not-found every night, and leaves an empty
# gitlab/ directory that looks like a backup that produced nothing — which is
# indistinguishable from a GitLab backup that FAILED. Absent is not broken;
# say so once and move on to the databases, which are the point on that box.
if ! command -v gitlab-backup >/dev/null 2>&1; then
    log "no gitlab-backup on this host — not a GitLab box, skipping section 1"
    rmdir "$OUT/gitlab" 2>/dev/null || true
else
    newest=$(ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null | head -1)
    if [ -z "$newest" ] || [ "$(find "$newest" -mmin +1200 2>/dev/null)" ]; then
        log "running gitlab-backup create"
        gitlab-backup create CRON=1 >> "$LOG" 2>&1
        newest=$(ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null | head -1)
    fi
    if [ -n "$newest" ]; then
        cp -u "$newest" "$OUT/gitlab/" && log "gitlab tarball staged: $(basename "$newest")"
    else
        log "ERROR: gitlab-backup exists but produced no tarball"
    fi
fi

# 2. All MySQL/MariaDB databases, one gz per DB (root cron → socket auth works).
stamp=$(date -u +%F)
for db in $(mysql -N -e "SHOW DATABASES" 2>>"$LOG" | grep -Ev '^(information_schema|performance_schema|sys|mysql)$'); do
    mysqldump --single-transaction --routines "$db" 2>>"$LOG" | gzip > "$OUT/db/${db}-${stamp}.sql.gz" \
        && log "dumped $db" || log "ERROR dumping $db"
done

# 3. nginx configs (server blocks are hand-tuned — cheap to save)
tar czf "$OUT/nginx/nginx-conf-${stamp}.tgz" /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null && log "nginx configs staged"

# 4. Make everything pullable by the gitlab user; apply local retention.
chown -R gitlab:gitlab "$OUT"
chmod -R u=rwX,g=rX,o= "$OUT"
find "$OUT" -type f -mtime +"$RETAIN_DAYS" -delete
log "done"
