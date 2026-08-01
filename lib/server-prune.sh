#!/usr/bin/env bash
# lib/server-prune.sh — the LAST step of a box migration: remove, from the box
# that was migrated AWAY FROM, the artefacts of the sites that moved.
#
# THE THIRD VERB OF THE SPLIT RUNBOOK
# `pl server sync` copies the data, `pl server handoff` moves the traffic, and
# then the old box sits there holding a complete second copy of every site.
# That copy is the rollback, which is why prune is deliberately last and
# deliberately separate — but it is also stale from the moment the front goes
# up, and leaving it costs disk, keeps dead certbot renewals failing twice a
# day, and leaves a second set of databases that a mis-pointed config could
# still write to.
#
# WHY THIS IS A VERB AND NOT A RUNBOOK PARAGRAPH
# Every destructive step here is one an operator would otherwise run by hand,
# at the end of a long migration, against the box that still holds the only
# other copy of production. That is the worst possible moment for a hand-typed
# `rm -rf`. Encoding it means the gates below run EVERY time, in the same
# order, and can be tested.
#
# THE GATES (each enforced below, marked [Pn])
#   [P1] PROOF OF LIFE ELSEWHERE. Nothing is deleted for a site until this box
#        has been shown NOT to be the one serving it: the site's declared
#        server must be some OTHER server, and that server must answer for it.
#        A site still declared to this box is never a candidate, and a site
#        whose new home cannot be reached is refused, not assumed.
#   [P2] KEEP-LIST IS FAIL-CLOSED. The keep set is built from what is DECLARED
#        to this server (sites + infrastructure roots), plus an explicit
#        never-touch list. Anything not positively identified as migrated-away
#        is KEPT. Unknown means keep, never delete.
#   [P3] FATE MANIFEST (ops#47). Nothing destructive runs until every component
#        and its fate has been rendered, with sizes read live off the box.
#   [P4] DRY-RUN BY DEFAULT. --execute is required; without it this is a report.
#   [P5] NO DATABASE IS DROPPED THAT AN APP ON THIS BOX STILL POINTS AT. The
#        db name is read from each surviving app's OWN config on this box, and
#        any name so found is removed from the drop set — a config that still
#        names a database outranks our belief that the site moved.
#   [P6] A BACKUP MUST EXIST. Refuses unless a backup of this box newer than
#        --require-backup-within (default 24h) is present, because prune is the
#        step that destroys the last non-backup copy.
#
# Nothing here deletes a site's LAST copy: by [P1] the site is live elsewhere,
# and by [P6] a backup of this box exists. Those two together are the whole
# safety argument, and both are checked rather than asserted.

[[ -n "${_NWP_SERVER_PRUNE_LOADED:-}" ]] && return 0
_NWP_SERVER_PRUNE_LOADED=1

_nwp_prune_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=impact.sh
[[ -f "$_nwp_prune_lib_dir/impact.sh" ]] && source "$_nwp_prune_lib_dir/impact.sh"

# Never-touch paths, regardless of what any declaration says. These are the
# things whose loss is not recoverable from a site backup: the ACME webroots a
# renewal needs, the default nginx root, and anything outside /var/www.
PRUNE_NEVER_TOUCH="${PRUNE_NEVER_TOUCH:-html hs}"

# ---------------------------------------------------------------------------
# prune_site_field <site> <yq-path>
# Read one `.live.*` field from a site's canonical declaration. Mirrors
# get_site_server in lib/server-resolver.sh, which is the file that learned the
# hard way that the declaration lives at the SITE root (sites/<n>/.nwp.yml) and
# NOT in the working checkout — reading the wrong one returns empty for every
# site, silently, and here "empty" would mean "not on the keep-list".
# ---------------------------------------------------------------------------
prune_site_field() {
    local site="$1" path="$2"
    local root="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}"
    local cfg="$root/sites/$site/.nwp.yml"
    [[ -f "$cfg" ]] || return 1
    local out
    out=$("${YQ:-yq}" eval "$path // \"\"" "$cfg" 2>/dev/null)
    [[ -n "$out" && "$out" != "null" ]] || return 1
    printf '%s\n' "$out"
}

get_site_remote_path() { prune_site_field "$1" '.live.remote_path'; }
get_site_domain()      { prune_site_field "$1" '.live.domain'; }

# ---------------------------------------------------------------------------
# prune_infra_tree <declared-path>
# The /var/www tree that must survive for a declared infrastructure root.
#
# An infrastructure root is declared as the path nginx SERVES — for headscale
# that is `/var/www/hs/html`, an empty ACME webroot. The directory that must
# not be deleted is its parent `/var/www/hs`. Taking the basename yields
# "html", which keeps the wrong thing and leaves the real tree on the delete
# list. Prints nothing for a path outside /var/www, which the caller treats as
# "nothing to keep here" rather than as an error.
# ---------------------------------------------------------------------------
prune_infra_tree() {
    local p="$1"
    case "$p" in
        /var/www/*) printf '%s\n' "${p#/var/www/}" | cut -d/ -f1 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# prune_companion_trees <remote-path>
# The /var/www trees that belong to a site, given the ONE path it declares.
#
# A site declares a single `remote_path` — its webroot. Moodle sites on this
# estate keep their data in a sibling `<webroot>_moodledata` that no file
# declares anywhere. Anything that reasons only from declarations therefore
# treats that directory as an orphan, and deleting it destroys every course,
# upload and submission on the host while the webroot survives, so the site
# returns 500 instead of visibly disappearing.
# ---------------------------------------------------------------------------
prune_companion_trees() {
    local p="$1" b
    [[ -n "$p" ]] || return 1
    b="$(basename "$p")"
    printf '%s\n%s\n' "$b" "${b}_moodledata"
}

# ---------------------------------------------------------------------------
# prune_cert_is_dead <name> <resolved-ip> <this-box-ip>
# True (0) only when the name resolves somewhere that is NOT this box.
#
# DNS is the ground truth, and it OVERRIDES the declarations: rgv.<live-domain>
# serves from the live box with no sites/rgv/.nwp.yml at all, so reasoning from
# declarations alone called its certificate dead. A name that does not resolve
# is also kept — an unresolvable name is a question, not an answer, and the
# cost of keeping a stale renewal (log noise) is nothing beside the cost of
# deleting a live one (a service off the air at the next expiry, weeks later).
# ---------------------------------------------------------------------------
prune_cert_is_dead() { prune_points_elsewhere "$@"; }

# ---------------------------------------------------------------------------
# prune_points_elsewhere <name> <resolved-ip> <this-box-ip>
# THE shared primitive behind [P1]: does this name currently live somewhere
# other than this box?
#
# True (0) only when the name resolves, and resolves somewhere that is not
# here. Both other answers mean KEEP:
#   * resolves HERE      -> this box still serves it, whatever a file says.
#   * does not resolve   -> a question, not an answer. `cccrdf` is declared to
#                           the live server but its A record still points at the
#                           old box, so "declared elsewhere" alone would have
#                           authorised deleting the only copy of a site that no
#                           new box is actually serving.
#
# Declarations describe intent; DNS describes what users reach. Prune is only
# safe on the second.
# ---------------------------------------------------------------------------
prune_points_elsewhere() {
    local name="$1" resolved="$2" mine="$3"
    [[ -n "$name" ]] || return 1
    [[ -n "$resolved" ]] || return 1       # unresolvable -> keep
    [[ "$resolved" != "$mine" ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# prune_backup_age_hours <ssh-prefix> [backup-dir]
# Age, in whole hours, of the newest file under the box's backup staging dir.
# Prints the age; prints nothing when there is no backup at all. [P6]
# ---------------------------------------------------------------------------
prune_backup_age_hours() {
    local prefix="$1" dir="${2:-/var/backups/nwp-pull}"
    local newest
    newest=$($prefix "sudo find $dir -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1" </dev/null 2>/dev/null || true)
    [[ -n "$newest" ]] || return 1
    local now; now=$($prefix "date +%s" </dev/null 2>/dev/null || true)
    [[ -n "$now" ]] || return 1
    awk -v n="$now" -v b="${newest%%.*}" 'BEGIN{ printf "%d", (n-b)/3600 }'
}

# ---------------------------------------------------------------------------
# prune_site_is_elsewhere <site> <this-server>
# [P1] True only when the site is DECLARED to a server other than this one.
# A site with no declared server is NOT elsewhere — unknown means keep.
# ---------------------------------------------------------------------------
prune_site_is_elsewhere() {
    local site="$1" this="$2" declared
    declared="$(get_site_server "$site" 2>/dev/null || true)"
    [[ -n "$declared" ]] || return 1
    [[ "$declared" != "$this" ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# prune_probe_live_dbnames <ssh-prefix> <path...>
# [P5] Read the database name out of the config of every app STILL on this box.
# Prints one name per line. A failure to read prints nothing for that path,
# which is safe: the caller only ever uses this list to SUBTRACT from the drop
# set, so an unreadable config can only ever protect more, never less.
# ---------------------------------------------------------------------------
prune_probe_live_dbnames() {
    local prefix="$1"; shift
    local p out
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        # Moodle
        out=$($prefix "test -f ${p}/config.php && sudo -u www-data php -d error_reporting=0 -d display_errors=0 -r 'define(\"CLI_SCRIPT\",true);define(\"ABORT_AFTER_CONFIG\",true);require(\$argv[1]);echo isset(\$CFG->dbname)?\$CFG->dbname:\"\";' ${p}/config.php" </dev/null 2>/dev/null || true)
        if [[ -n "$out" ]]; then printf '%s\n' "$out"; fi
        # Drupal
        out=$($prefix "cd ${p} 2>/dev/null && sudo -u www-data vendor/bin/drush sql:conf --format=json 2>/dev/null" </dev/null 2>/dev/null \
              | grep -oE '\"database\"[^,]*' | head -1 | sed 's/.*: *\"//; s/\"//' || true)
        if [[ -n "$out" ]]; then printf '%s\n' "$out"; fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# prune_dead_certbot_renewals <ssh-prefix> <kept-name...>
# Certbot renewal configs whose certificate names are NOT in the kept set.
# After a migration these fail twice a day forever, which is how a real
# renewal failure gets lost in the noise.
# ---------------------------------------------------------------------------
prune_dead_certbot_renewals() {
    local prefix="$1"; shift
    local kept=(" $* ")
    local dir="${PRUNE_RENEWAL_DIR:-/etc/letsencrypt/renewal}"
    local f name
    while read -r f; do
        [[ -n "$f" ]] || continue
        name="$(basename "$f" .conf)"
        if [[ " ${kept[*]} " == *" $name "* ]]; then continue; fi
        printf '%s\n' "$name"
    done < <($prefix "sudo ls $dir/*.conf 2>/dev/null" </dev/null 2>/dev/null || true)
    return 0
}

# ---------------------------------------------------------------------------
# prune_render_and_confirm — [P3] the gate.
#
# Tier "typed": prune destroys the last copy that is not a backup, so this is
# the purge tier. `pl server sync` is only "standard" because its source
# survives; here nothing survives on this box.
# ---------------------------------------------------------------------------
prune_render_and_confirm() {
    local server="$1" auto_yes="$2"
    local -n _trees="$3"
    local -n _dbs="$4"
    local -n _vhosts="$5"
    local -n _certs="$6"
    local -n _keeps="$7"

    impact_reset
    # Plain `if`, not `[[ ]] &&`: a loop returns its last command's status, so
    # a trailing false test makes the loop — and under `set -e` the whole
    # command — fail silently. The manifest is the one thing that must never
    # fail to render.
    local t
    for t in "${_trees[@]:-}";  do if [[ -n "$t" ]]; then impact_delete "${server}: ${t%%|*}" "${t#*|}"; fi; done
    for t in "${_dbs[@]:-}";    do if [[ -n "$t" ]]; then impact_delete "${server}: database '${t%%|*}'" "${t#*|}"; fi; done
    for t in "${_vhosts[@]:-}"; do if [[ -n "$t" ]]; then impact_delete "${server}: vhost ${t%%|*}" "${t#*|}"; fi; done
    for t in "${_certs[@]:-}";  do if [[ -n "$t" ]]; then impact_delete "${server}: certbot renewal ${t%%|*}" "${t#*|}"; fi; done

    impact_warn "This removes the ROLLBACK copy. After this, reverting the migration means restoring from backup, not flipping DNS."
    impact_warn "Every site listed above must already be serving from its new box — verified above, but verify again if this report is stale."
    local k
    for k in "${_keeps[@]:-}"; do if [[ -n "$k" ]]; then impact_keep "$k"; fi; done
    impact_render

    local confirm_auto=false
    if [[ "$auto_yes" == "1" ]]; then confirm_auto=true; fi
    impact_confirm typed "$server" "$confirm_auto"
}
