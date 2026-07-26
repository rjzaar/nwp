#!/bin/bash
################################################################################
# NWP Todo Checks Library
#
# Individual check functions for the unified todo system
# See docs/proposals/F12-todo-command.md for full specification
################################################################################

# Get the directory where this script is located
TODO_CHECKS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TODO_CHECKS_PROJECT_ROOT="${TODO_CHECKS_PROJECT_ROOT:-$( cd "$TODO_CHECKS_DIR/.." && pwd )}"

# Cache settings
TODO_CACHE_DIR="${TODO_CACHE_DIR:-/tmp/nwp-todo-cache}"
TODO_CACHE_TTL="${TODO_CACHE_TTL:-300}"  # 5 minutes default

# Todo item storage (arrays for building results)
TODO_ITEMS=()
TODO_ITEM_ID=0

################################################################################
# Cache Management
################################################################################

# Check if cache file is valid (exists and not expired)
# Args: $1 = cache_file
# Returns: 0 if valid, 1 if expired or missing
todo_cache_valid() {
    local cache_file="$1"
    local ttl="${2:-$TODO_CACHE_TTL}"

    [ ! -f "$cache_file" ] && return 1

    local file_age
    if [[ "$(uname)" == "Darwin" ]]; then
        file_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null)))
    else
        file_age=$(($(date +%s) - $(stat -c%Y "$cache_file" 2>/dev/null)))
    fi

    [ "$file_age" -lt "$ttl" ] && return 0
    return 1
}

# Ensure cache directory exists
todo_cache_init() {
    mkdir -p "$TODO_CACHE_DIR"
}

# Clear all cache files
todo_cache_clear() {
    rm -rf "$TODO_CACHE_DIR"
    todo_cache_init
}

################################################################################
# Todo Item Builder Functions
################################################################################

# Check if an item ID is in the ignored list
# Args: $1=item_id
# Returns: 0 if ignored, 1 if not
todo_is_ignored() {
    local item_id="$1"
    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"

    [ ! -f "$config_file" ] && return 1

    command -v yq &>/dev/null || return 1

    local found
    found=$(yq eval ".settings.todo.ignored[] | select(.id == \"$item_id\") | .id" "$config_file" 2>/dev/null)
    [ -n "$found" ] || return 1

    # HONOUR `expires`. It was write-only: add_to_ignored could record an expiry
    # and NOTHING read it, so every "snooze until next week" was in fact a
    # permanent silence. A snooze that never wakes is the same defect as a
    # permanent ignore — and it is how an SSL item got disarmed for good.
    #
    # An entry with no `expires` remains permanent: that is a deliberate,
    # explicit operator choice via `pl todo ignore`.
    local expires
    expires=$(yq eval ".settings.todo.ignored[] | select(.id == \"$item_id\") | .expires // \"\"" "$config_file" 2>/dev/null | grep -v '^null$' | head -1)
    if [ -n "$expires" ]; then
        local exp_epoch now_epoch
        exp_epoch=$(date -d "$expires" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        # An UNPARSEABLE expiry must not be treated as "never expires" — fail
        # towards visibility, because the cost of showing an item again is a
        # line of output and the cost of hiding one is an unnoticed outage.
        if [ "$exp_epoch" = "0" ] || [ "$exp_epoch" -le "$now_epoch" ]; then
            return 1
        fi
    fi
    return 0
}

# Add a todo item to the results (skips if ignored)
# Args: $1=category $2=id $3=priority $4=title $5=description $6=site $7=action
todo_add_item() {
    local category="$1"
    local id="$2"
    local priority="$3"
    local title="$4"
    local description="$5"
    local site="${6:-}"
    local action="${7:-}"

    ((TODO_ITEM_ID++))
    local full_id="${category}-$(printf '%03d' $TODO_ITEM_ID)"
    [ -n "$id" ] && full_id="${category}-${id}"

    # Skip if this item is ignored/processed
    if todo_is_ignored "$full_id"; then
        return 0
    fi

    # Store as JSON-like format for easy parsing
    local item="{\"id\":\"$full_id\",\"category\":\"$category\",\"priority\":\"$priority\",\"title\":\"$title\",\"description\":\"$description\",\"site\":\"$site\",\"action\":\"$action\",\"unknown\":${TODO_ITEM_UNKNOWN:-false}}"
    TODO_ITEMS+=("$item")
}

# UNKNOWN — the third outcome. A check has three possible results, not two:
#
#   FINDING   we looked, and there is something to do
#   CLEAR     we looked, and there is nothing to do
#   UNKNOWN   we could NOT look
#
# Before this existed, ~15 checks collapsed UNKNOWN into CLEAR with a bare
# `|| return 0` on transport/tool failure: no ssh key → clean; unroutable host →
# clean; no yq → clean; no api_token → clean; audit rc=2 → keep a 1-byte stale
# cache and say nothing. That is how a fleet reports green while nobody is
# actually looking at it. `pl rag` grades any site with an open UNK item AMBER
# and will never call it GREEN.
#
# Args: $1=check name (becomes UNK-<name>) $2=why we could not check
#       $3=site (optional) $4=action (optional)
todo_add_unknown() {
    local check="$1"
    local reason="$2"
    local site="${3:-}"
    local action="${4:-}"

    # Set explicitly rather than as a command prefix: bash's scoping of
    # `VAR=x func` differs between POSIX and default mode, and this flag must not
    # leak into the next todo_add_item call.
    TODO_ITEM_UNKNOWN=true
    todo_add_item "UNK" "$check" "medium" \
        "Check could not run: $check" \
        "NOT a clean result — this check did not complete. Reason: $reason" \
        "$site" "$action"
    TODO_ITEM_UNKNOWN=false
}

# Every check runs with this false unless todo_add_unknown flips it.
TODO_ITEM_UNKNOWN=false

# Output all collected items as JSON array
todo_output_items() {
    echo "["
    local first=true
    for item in "${TODO_ITEMS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo "  $item"
    done
    echo "]"
}

# Clear items array (for fresh check)
todo_clear_items() {
    TODO_ITEMS=()
    TODO_ITEM_ID=0
}

################################################################################
# Configuration Reading Helpers
################################################################################

# Get todo setting with default
# Args: $1=key_path $2=default
get_todo_setting() {
    local key_path="$1"
    local default="${2:-}"
    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"

    if [ ! -f "$config_file" ]; then
        config_file="$TODO_CHECKS_PROJECT_ROOT/example.nwp.yml"
    fi

    local value=""
    if command -v yq &>/dev/null; then
        value=$(yq eval ".settings.todo.${key_path} // \"\"" "$config_file" 2>/dev/null | grep -v '^null$')
    else
        # Simple AWK fallback for basic paths
        value=$(awk -v path="$key_path" '
            BEGIN { FS=": "; in_todo=0; depth=0 }
            /^  todo:/ { in_todo=1; depth=2; next }
            in_todo && /^[a-zA-Z]/ && !/^  / { exit }
            in_todo {
                # Count leading spaces
                match($0, /^[[:space:]]*/)
                spaces = RLENGTH
                if (spaces <= depth && !/^[[:space:]]*#/) { in_todo=0; next }
            }
        ' "$config_file")
    fi

    [ -z "$value" ] && value="$default"
    echo "$value"
}

# Check if a category is enabled
# Args: $1=category_name
is_category_enabled() {
    local category="$1"
    local value=$(get_todo_setting "categories.${category}" "true")
    [ "$value" = "true" ] || [ "$value" = "yes" ] || [ "$value" = "1" ]
}

################################################################################
# Check Functions
################################################################################

# GIT: Check GitLab issues
check_gitlab_issues() {
    is_category_enabled "git_issues" || return 0

    local secrets_file="$TODO_CHECKS_PROJECT_ROOT/.secrets.yml"

    # Get GitLab token
    local api_token=""
    if [ -f "$secrets_file" ] && command -v yq &>/dev/null; then
        api_token=$(yq eval '.gitlab.api_token // ""' "$secrets_file" 2>/dev/null | grep -v '^null$')
    fi

    if [ -z "$api_token" ]; then
        # No GitLab token configured, skip silently
        return 0
    fi

    # Get GitLab server
    local server=""
    if [ -f "$secrets_file" ] && command -v yq &>/dev/null; then
        server=$(yq eval '.gitlab.server.domain // ""' "$secrets_file" 2>/dev/null | grep -v '^null$')
    fi

    if [ -z "$server" ]; then
        server="${NWP_GITLAB_HOST:-<gitlab-host>}"
    fi

    # Get user ID
    local user_info
    user_info=$(curl -sf -H "PRIVATE-TOKEN: $api_token" \
        "https://$server/api/v4/user" 2>/dev/null)

    if [ -z "$user_info" ]; then
        return 0
    fi

    local user_id
    user_id=$(echo "$user_info" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

    if [ -z "$user_id" ]; then
        return 0
    fi

    # Fetch assigned issues
    local issues
    issues=$(curl -sf -H "PRIVATE-TOKEN: $api_token" \
        "https://$server/api/v4/issues?assignee_id=$user_id&state=opened&per_page=50" 2>/dev/null)

    if [ -z "$issues" ] || [ "$issues" = "[]" ]; then
        return 0
    fi

    # Parse issues and add to items (using process substitution to avoid subshell)
    while read -r iid; do
        [ -z "$iid" ] && continue
        local title=$(echo "$issues" | grep -o "\"iid\":$iid[^}]*\"title\":\"[^\"]*\"" | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
        local web_url=$(echo "$issues" | grep -o "\"iid\":$iid[^}]*\"web_url\":\"[^\"]*\"" | grep -o '"web_url":"[^"]*"' | cut -d'"' -f4)
        todo_add_item "GIT" "$iid" "medium" "GitLab Issue #$iid" "$title" "" "Open: $web_url"
    done < <(echo "$issues" | grep -o '"iid":[0-9]*' | cut -d: -f2)
}

# TST: Check test instances age
check_test_instances() {
    is_category_enabled "test_instances" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"
    [ ! -f "$config_file" ] && return 0

    local warn_days=$(get_todo_setting "thresholds.test_instance_warn_days" "7")
    local alert_days=$(get_todo_setting "thresholds.test_instance_alert_days" "14")
    local now_epoch=$(date +%s)

    # Get all sites with purpose=testing
    while read -r site; do
        [ -z "$site" ] && continue

        local purpose=$(yaml_get_site_field "$site" "purpose" "$config_file" 2>/dev/null)
        [ "$purpose" != "testing" ] && continue

        local created=$(yaml_get_site_field "$site" "created" "$config_file" 2>/dev/null)
        [ -z "$created" ] && continue

        # Calculate age in days
        local created_epoch
        created_epoch=$(date -d "$created" +%s 2>/dev/null || echo "0")
        [ "$created_epoch" = "0" ] && continue

        local age_days=$(( (now_epoch - created_epoch) / 86400 ))

        if [ "$age_days" -ge "$alert_days" ]; then
            todo_add_item "TST" "${site}" "high" "Test instance is $age_days days old" "Site: $site | Purpose: testing | Created: ${created%T*}" "$site" "pl delete $site"
        elif [ "$age_days" -ge "$warn_days" ]; then
            todo_add_item "TST" "${site}" "medium" "Test instance is $age_days days old" "Site: $site | Purpose: testing | Created: ${created%T*}" "$site" "pl delete $site"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# TOK: Check token rotation
check_token_rotation() {
    is_category_enabled "token_rotation" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"
    local rotation_days=$(get_todo_setting "thresholds.token_rotation_days" "90")
    local now_epoch=$(date +%s)

    local tokens=("linode" "cloudflare" "gitlab" "b2")

    for token_name in "${tokens[@]}"; do
        local last_rotated=""
        if command -v yq &>/dev/null && [ -f "$config_file" ]; then
            last_rotated=$(yq eval ".settings.todo.tokens.${token_name}.last_rotated // \"\"" "$config_file" 2>/dev/null | grep -v '^null$')
        fi

        if [ -z "$last_rotated" ]; then
            # No rotation date recorded - add as low priority reminder
            todo_add_item "TOK" "$token_name" "low" "Token rotation not tracked: $token_name" "Last rotated: unknown | Threshold: $rotation_days days" "" "pl todo token $token_name"
            continue
        fi

        # Calculate age
        local rotated_epoch
        rotated_epoch=$(date -d "$last_rotated" +%s 2>/dev/null || echo "0")
        [ "$rotated_epoch" = "0" ] && continue

        local age_days=$(( (now_epoch - rotated_epoch) / 86400 ))

        if [ "$age_days" -ge "$rotation_days" ]; then
            todo_add_item "TOK" "$token_name" "medium" "Token rotation due: $token_name ($age_days days old)" "Last rotated: ${last_rotated%T*} | Threshold: $rotation_days days" "" "Rotate token and run: pl todo token $token_name"
        fi
    done
}

# ORP: Check orphaned sites
check_orphaned_sites() {
    is_category_enabled "orphaned_sites" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"

    # Reuse find_orphaned_sites from status.sh if available
    if command -v find_orphaned_sites &>/dev/null; then
        while IFS=':' read -r name dir; do
            [ -z "$name" ] && continue
            todo_add_item "ORP" "$name" "low" "Orphaned site (has .ddev, not in config)" "Directory: $dir" "$name" "pl todo ignore ORP-$name OR pl delete $name"
        done < <(find_orphaned_sites "$config_file" "$TODO_CHECKS_PROJECT_ROOT" 2>/dev/null)
    else
        # Fallback: check sites directory manually
        if [ -d "$TODO_CHECKS_PROJECT_ROOT/sites" ]; then
            while IFS= read -r ddev_path; do
                local site_dir=$(dirname "$ddev_path")
                local site_name=$(basename "$site_dir")

                # Check if site is in config
                if ! yaml_site_exists "$site_name" "$config_file" 2>/dev/null; then
                    todo_add_item "ORP" "$site_name" "low" "Orphaned site (has .ddev, not in config)" "Directory: $site_dir" "$site_name" "pl todo ignore ORP-$site_name OR pl delete $site_name"
                fi
            done < <(find "$TODO_CHECKS_PROJECT_ROOT/sites" -maxdepth 2 -name ".ddev" -type d 2>/dev/null)
        fi
    fi
}

# GHO: Check ghost DDEV sites
check_ghost_sites() {
    is_category_enabled "ghost_sites" || return 0

    # No ddev binary = we cannot enumerate projects. That is UNKNOWN, not
    # "there are no ghost sites".
    if ! command -v ddev >/dev/null 2>&1; then
        todo_add_unknown "ghost_sites" \
            "ddev is not installed on this machine, so DDEV projects could not be enumerated" \
            "" ""
        return 0
    fi

    # Get DDEV list as JSON and parse it
    local ddev_json rc=0
    ddev_json=$(ddev list --json-output 2>/dev/null | grep -o '"raw":\[.*\]' | sed 's/"raw"://' 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$ddev_json" ]; then
        todo_add_unknown "ghost_sites" \
            "'ddev list --json-output' produced nothing usable (daemon down? ddev not initialised?)" \
            "" "ddev list"
        return 0
    fi

    # Parse JSON to find ghost sites (using process substitution to avoid subshell)
    while read -r entry; do
        [ -z "$entry" ] && continue
        local name=$(echo "$entry" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
        local approot=$(echo "$entry" | grep -o '"approot":"[^"]*"' | cut -d'"' -f4)
        local status=$(echo "$entry" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

        # Skip Router
        [ "$name" = "Router" ] && continue

        # Skip if not in nwp folder
        [[ "$approot" != "$TODO_CHECKS_PROJECT_ROOT"* ]] && continue

        # Check if directory is missing
        if [[ "$status" == *"missing"* ]]; then
            todo_add_item "GHO" "$name" "high" "Ghost DDEV site (directory missing)" "Was at: $approot" "$name" "ddev stop --unlist $name"
        fi
    done < <(echo "$ddev_json" | grep -o '{[^}]*}')
}

# INC: Check incomplete installations
check_incomplete_installs() {
    is_category_enabled "incomplete_installs" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"
    [ ! -f "$config_file" ] && return 0

    local alert_hours=$(get_todo_setting "thresholds.incomplete_install_hours" "24")
    local now_epoch=$(date +%s)

    while read -r site; do
        [ -z "$site" ] && continue

        local install_step=$(yaml_get_site_field "$site" "install_step" "$config_file" 2>/dev/null)

        # Skip if complete (-1) or not tracked
        [ "$install_step" = "-1" ] || [ -z "$install_step" ] && continue

        local created=$(yaml_get_site_field "$site" "created" "$config_file" 2>/dev/null)
        [ -z "$created" ] && continue

        # Calculate age in hours
        local created_epoch
        created_epoch=$(date -d "$created" +%s 2>/dev/null || echo "0")
        [ "$created_epoch" = "0" ] && continue

        local age_hours=$(( (now_epoch - created_epoch) / 3600 ))

        if [ "$age_hours" -ge "$alert_hours" ]; then
            todo_add_item "INC" "$site" "high" "Incomplete installation (step $install_step, ${age_hours}h old)" "Site: $site | Stalled at step $install_step" "$site" "pl install -s=$((install_step + 1)) $site"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# BAK: Check missing backups
check_missing_backups() {
    is_category_enabled "missing_backups" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"
    if [ ! -f "$config_file" ]; then
        todo_add_unknown "missing_backups" \
            "no config at $config_file — no site's backup state was checked" "" ""
        return 0
    fi

    # Shared integrity helper (see lib/backup-integrity.sh for why freshness
    # alone was not enough).
    if ! command -v backup_artifact_integrity &>/dev/null; then
        if [ -f "$TODO_CHECKS_DIR/backup-integrity.sh" ]; then
            # shellcheck source=/dev/null
            source "$TODO_CHECKS_DIR/backup-integrity.sh"
        else
            todo_add_unknown "missing_backups" \
                "lib/backup-integrity.sh is missing — backups could not be verified" "" ""
            return 0
        fi
    fi

    local warn_days=$(get_todo_setting "thresholds.backup_warn_days" "7")
    local now_epoch=$(date +%s)
    local warn_seconds=$((warn_days * 86400))

    while read -r site; do
        [ -z "$site" ] && continue

        # Skip test sites
        local purpose=$(yaml_get_site_field "$site" "purpose" "$config_file" 2>/dev/null)
        [ "$purpose" = "testing" ] && continue

        local directory=$(yaml_get_site_field "$site" "directory" "$config_file" 2>/dev/null)
        [ -z "$directory" ] && directory="$TODO_CHECKS_PROJECT_ROOT/sites/$site"

        # Check if backup directory exists
        local backup_dir="$directory/backups"
        if [ ! -d "$backup_dir" ]; then
            backup_dir="$TODO_CHECKS_PROJECT_ROOT/backups/$site"
        fi

        if [ ! -d "$backup_dir" ]; then
            todo_add_item "BAK" "$site" "medium" "No backup directory found" "Site: $site | Expected: $backup_dir" "$site" "pl backup $site"
            continue
        fi

        # Any backup files at all?
        if ! find "$backup_dir" -maxdepth 1 -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) 2>/dev/null | grep -q .; then
            todo_add_item "BAK" "$site" "medium" "No backup files found" "Site: $site | Directory: $backup_dir" "$site" "pl backup $site"
            continue
        fi

        # A corrupt artifact is a DISTINCT finding, filed even when a valid older
        # backup exists — otherwise the producer keeps writing garbage and the
        # only symptom is a silently ageing "last good" date.
        local bad bad_path bad_reason
        if bad=$(backup_first_bad_artifact "$backup_dir"); then
            bad_path="${bad%%$'\t'*}"; bad_reason="${bad#*$'\t'}"
            todo_add_item "BAK" "corrupt-$site" "high" \
                "Backup artifact is NOT restorable: $(basename "$bad_path")" \
                "Site: $site | $bad_reason | A bad artifact used to report FRESH and suppress the next backup for $warn_days more days." \
                "$site" "pl backup $site"
        fi

        # Freshness is measured against the newest artifact that actually passes
        # integrity, never merely the newest file.
        local latest_backup
        if ! latest_backup=$(backup_latest_good_epoch "$backup_dir"); then
            todo_add_item "BAK" "$site" "high" "No RESTORABLE backup exists" \
                "Site: $site | Directory: $backup_dir | Files are present but none passed an integrity check." \
                "$site" "pl backup $site"
            continue
        fi

        local backup_age=$((now_epoch - latest_backup))

        if [ "$backup_age" -gt "$warn_seconds" ]; then
            local days_ago=$((backup_age / 86400))
            todo_add_item "BAK" "$site" "medium" "Backup is $days_ago days old" "Site: $site | Threshold: $warn_days days" "$site" "pl backup $site"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# SCH: Check missing backup schedules
check_missing_schedules() {
    is_category_enabled "missing_schedules" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"
    [ ! -f "$config_file" ] && return 0

    # Get crontab entries for NWP
    local crontab_entries
    crontab_entries=$(crontab -l 2>/dev/null | grep -E "pl backup|nwp.*backup" || true)

    while read -r site; do
        [ -z "$site" ] && continue

        # Skip test sites
        local purpose=$(yaml_get_site_field "$site" "purpose" "$config_file" 2>/dev/null)
        [ "$purpose" = "testing" ] && continue

        # Check if site has a scheduled backup
        if ! echo "$crontab_entries" | grep -q "$site"; then
            todo_add_item "SCH" "$site" "low" "Site has no scheduled backups" "Site: $site" "$site" "pl schedule install $site"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# SEC: Check security updates
check_security_updates() {
    is_category_enabled "security_updates" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"
    [ ! -f "$config_file" ] && return 0

    while read -r site; do
        [ -z "$site" ] && continue

        local directory=$(yaml_get_site_field "$site" "directory" "$config_file" 2>/dev/null)
        [ -z "$directory" ] && directory="$TODO_CHECKS_PROJECT_ROOT/sites/$site"

        # Check for Drupal webroot
        local webroot=""
        for dir in "web" "html" "docroot" "."; do
            if [ -f "$directory/$dir/core/lib/Drupal.php" ]; then
                webroot="$directory/$dir"
                break
            fi
        done

        [ -z "$webroot" ] && continue

        # Check for security updates using drush (if available)
        if command -v ddev &>/dev/null && [ -d "$directory/.ddev" ]; then
            local updates
            updates=$(cd "$directory" && ddev drush pm:security --format=json 2>/dev/null || echo "[]")

            if [ "$updates" != "[]" ] && [ -n "$updates" ]; then
                # Count security updates
                local count
                count=$(echo "$updates" | grep -c '"name"' 2>/dev/null || echo "0")

                if [ "$count" -gt 0 ]; then
                    todo_add_item "SEC" "$site" "high" "$count security update(s) available" "Site: $site | Run: pl security update $site" "$site" "pl security update $site"
                fi
            fi
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# VER: Check verification failures.
#
# WAS VACUOUS: this queried `.status == "fail"`. No such key exists anywhere in
# .verification.yml — `grep -c 'status: fail'` returns 0 while 99 machine checks
# record `machine.state.verified: false`. The check could not produce an item
# for ANY input, and "Verification: clean" was a positive assertion with nothing
# behind it. The real schema is:
#     <feature>.<item>.machine.state.verified: true|false
#     <feature>.<item>.machine.state.verified_at: <iso8601>
#   (the sibling `verified:` next to `verified_by:` is the HUMAN sign-off flag —
#    a different, much lower-coverage axis; do not conflate the two.)
#
# Also stale-dates the corpus: a suite whose newest run is months old is not
# "passing", it is unmeasured. Threshold:
# settings.todo.thresholds.verification_stale_days (default 60).
check_verification() {
    is_category_enabled "verification_fails" || return 0

    local verification_file="$TODO_CHECKS_PROJECT_ROOT/.verification.yml"
    [ ! -f "$verification_file" ] && return 0
    command -v yq &>/dev/null || {
        # Cannot read the file at all -> say so rather than report clean.
        todo_add_item "VER" "noyq" "low" \
            "Verification state unknown: yq not installed" \
            "pl todo cannot parse .verification.yml without yq, so 'verification clean' would be an unfounded claim." \
            "" "install yq, then: pl verify --run"
        return 0
    }

    local fail_count never_count
    fail_count=$(yq eval '[.. | select(has("machine")) | select(.machine.state.verified == false)] | length' \
        "$verification_file" 2>/dev/null || echo 0)
    [[ "$fail_count" =~ ^[0-9]+$ ]] || fail_count=0

    # Machine blocks that have never recorded a state at all.
    never_count=$(yq eval '[.. | select(has("machine")) | select(.machine | has("state") | not)] | length' \
        "$verification_file" 2>/dev/null || echo 0)
    [[ "$never_count" =~ ^[0-9]+$ ]] || never_count=0

    if [ "$fail_count" -gt 0 ]; then
        todo_add_item "VER" "failing" "medium" \
            "$fail_count verification check(s) recorded as NOT verified" \
            "Schema: features.*.machine.state.verified == false in .verification.yml" \
            "" "pl verify --run"
    fi

    if [ "$never_count" -gt 0 ]; then
        todo_add_item "VER" "never-run" "medium" \
            "$never_count verification check(s) have never been run" \
            "No machine.state block recorded — these have never produced a result." \
            "" "pl verify --run"
    fi

    # Staleness: the newest recorded machine run.
    local newest stale_days newest_epoch now_epoch age_days
    newest=$(yq eval '[.. | select(has("machine")) | .machine.state.verified_at // ""] | map(select(. != "" and . != null)) | sort | .[-1] // ""' \
        "$verification_file" 2>/dev/null | grep -v '^null$')
    stale_days=$(get_todo_setting "thresholds.verification_stale_days" "60")

    if [ -z "$newest" ]; then
        todo_add_item "VER" "no-dates" "medium" \
            "Verification suite has no recorded run date" \
            "Nothing in .verification.yml records when it last ran — the pass rate describes an unknown point in time." \
            "" "pl verify --run"
        return 0
    fi

    newest_epoch=$(date -d "$newest" +%s 2>/dev/null || echo 0)
    [ "$newest_epoch" = "0" ] && return 0
    now_epoch=$(date +%s)
    age_days=$(( (now_epoch - newest_epoch) / 86400 ))

    if [ "$age_days" -ge "$stale_days" ]; then
        todo_add_item "VER" "stale" "medium" \
            "Verification results are stale (${age_days}d old — threshold ${stale_days}d)" \
            "Newest machine.state.verified_at is $newest. A stale green is not a green." \
            "" "pl verify --run"
    fi
}

# GWK: uncommitted work, stashes and worktrees across EVERY repo in the tree.
#
# WAS VACUOUS: the old loop did `[ ! -d "$directory/.git" ] && continue` against
# `sites/<name>/`. In the v2 layout no site has a repo at that path — see
# `discover_repos` in lib/project-resolver.sh for the full account. It also
# omitted `-uall` (so untracked directories counted as one entry), never looked
# at `servers/*`, never looked at stashes (11 stashes across 7 repos, one of
# them holding 179 lines of consent/legal canonical text), and filed everything
# `low` so it sank below the fold even when it did fire.
check_uncommitted_work() {
    is_category_enabled "uncommitted_work" || return 0

    # discover_repos lives in project-resolver.sh (auto-sourced via common.sh in
    # command contexts). Load it directly for standalone/cron use.
    if ! command -v discover_repos &>/dev/null; then
        if [ -f "$TODO_CHECKS_DIR/project-resolver.sh" ]; then
            # shellcheck source=/dev/null
            source "$TODO_CHECKS_DIR/project-resolver.sh"
        else
            todo_add_item "GWK" "noresolver" "medium" \
                "Cannot enumerate repos: lib/project-resolver.sh missing" \
                "Uncommitted-work status is UNKNOWN, not clean." "" "pl doctor"
            return 0
        fi
    fi

    local dirty_threshold worktree_threshold
    dirty_threshold=$(get_todo_setting "thresholds.uncommitted_file_alert" "200")
    worktree_threshold=$(get_todo_setting "thresholds.worktree_warn_count" "20")

    local repo rel slug status file_count stash_count prio
    local total_repos=0

    while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        [ -d "$repo" ] || continue
        total_repos=$((total_repos + 1))

        rel="${repo#$TODO_CHECKS_PROJECT_ROOT/}"
        # Stable, filename-safe item id (so `pl todo ignore` can pin one repo).
        slug=$(printf '%s' "$rel" | tr '/' '-' | tr -cd 'A-Za-z0-9._-')

        # A pathological repo (huge untracked vendor tree) must not hang cron.
        status=$(timeout 30 git -C "$repo" --no-optional-locks status --porcelain -uall 2>/dev/null || true)

        if [ -n "$status" ]; then
            file_count=$(printf '%s\n' "$status" | wc -l | tr -d ' ')
            prio="medium"
            [ "$file_count" -ge "$dirty_threshold" ] && prio="high"
            todo_add_item "GWK" "$slug" "$prio" \
                "Uncommitted work: $file_count entr(ies) in $rel" \
                "Repo: $repo | git status --porcelain -uall" \
                "$(_gwk_site_of "$rel")" "git -C $repo status -uall"
        fi

        # Each stash is its own item: a stash is invisible to every other
        # surface, and one of them held legal canonical text for two months.
        stash_count=$(timeout 15 git -C "$repo" stash list 2>/dev/null | wc -l | tr -d ' ')
        [[ "$stash_count" =~ ^[0-9]+$ ]] || stash_count=0
        if [ "$stash_count" -gt 0 ]; then
            local n=0 sref sdesc sage
            while IFS= read -r sline; do
                [ -z "$sline" ] && continue
                sref="${sline%%:*}"
                sdesc="${sline#*: }"
                sage=$(timeout 10 git -C "$repo" log -1 --format=%cr "$sref" 2>/dev/null || echo "unknown age")
                todo_add_item "GWK" "${slug}-stash${n}" "medium" \
                    "Stashed work in $rel ($sref, $sage)" \
                    "$sdesc | Stashes are invisible to every other pl surface." \
                    "$(_gwk_site_of "$rel")" "git -C $repo stash show -p $sref"
                n=$((n + 1))
            done < <(timeout 15 git -C "$repo" stash list 2>/dev/null)
        fi
    done < <(discover_repos 2>/dev/null)

    # Worktree sprawl (roll-up, not one item per worktree).
    local wt_count
    wt_count=$(timeout 20 git -C "$TODO_CHECKS_PROJECT_ROOT" worktree list 2>/dev/null | wc -l | tr -d ' ')
    [[ "$wt_count" =~ ^[0-9]+$ ]] || wt_count=0
    if [ "$wt_count" -gt "$worktree_threshold" ]; then
        todo_add_item "GWK" "worktrees" "medium" \
            "$wt_count git worktrees checked out (threshold $worktree_threshold)" \
            "Worktrees carry per-checkout state (rollback ledgers, .env). Prune the closed ones." \
            "" "pl branch stranded"
    fi
}

# Map a repo-relative path back to a site name for the `site` column, or "".
_gwk_site_of() {
    case "$1" in
        sites/*) local rest="${1#sites/}"; printf '%s' "${rest%%/*}" ;;
        *)       printf '' ;;
    esac
}

# DSK: Check disk usage
check_disk_usage() {
    is_category_enabled "disk_usage" || return 0

    local warn_percent=$(get_todo_setting "thresholds.disk_warn_percent" "80")
    local alert_percent=$(get_todo_setting "thresholds.disk_alert_percent" "90")

    # Get disk usage for the filesystem containing the project
    local disk_info
    disk_info=$(df -P "$TODO_CHECKS_PROJECT_ROOT" 2>/dev/null | tail -1)

    local usage_percent
    usage_percent=$(echo "$disk_info" | awk '{gsub(/%/,"",$5); print $5}')

    local mount_point
    mount_point=$(echo "$disk_info" | awk '{print $6}')

    if [ "$usage_percent" -ge "$alert_percent" ]; then
        todo_add_item "DSK" "001" "high" "Disk usage critical: ${usage_percent}%" "Mount: $mount_point | Threshold: ${alert_percent}%" "" "df -h $mount_point"
    elif [ "$usage_percent" -ge "$warn_percent" ]; then
        todo_add_item "DSK" "001" "medium" "Disk usage warning: ${usage_percent}%" "Mount: $mount_point | Threshold: ${warn_percent}%" "" "df -h $mount_point"
    fi
}

# SSL: Check SSL certificate expiry
check_ssl_expiry() {
    is_category_enabled "ssl_expiring" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"
    local warn_days=$(get_todo_setting "thresholds.ssl_warn_days" "30")
    local alert_days=$(get_todo_setting "thresholds.ssl_alert_days" "7")

    [ ! -f "$config_file" ] && return 0

    while read -r site; do
        [ -z "$site" ] && continue

        # Get live domain if configured
        local domain=""
        if command -v yq &>/dev/null; then
            domain=$(yq eval ".sites.${site}.live.domain // \"\"" "$config_file" 2>/dev/null | grep -v '^null$')
        fi

        [ -z "$domain" ] && continue

        # Check SSL certificate expiry
        local expiry_date
        expiry_date=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | \
            openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

        [ -z "$expiry_date" ] && continue

        local expiry_epoch
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
        [ "$expiry_epoch" = "0" ] && continue

        local now_epoch=$(date +%s)
        local days_until=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [ "$days_until" -le "$alert_days" ]; then
            todo_add_item "SSL" "$site" "high" "SSL certificate expires in $days_until days" "Domain: $domain" "$site" "certbot renew"
        elif [ "$days_until" -le "$warn_days" ]; then
            todo_add_item "SSL" "$site" "medium" "SSL certificate expires in $days_until days" "Domain: $domain" "$site" "certbot renew"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# SEC: Check secret/token expiry from the tokenless registry.
# Reads ONLY expiry dates from private/secrets-registry.yml — needs no secret value,
# so it is safe to run unattended (this is the "auto alerts, no token on the host" path).
check_secret_expiry() {
    is_category_enabled "secret_expiry" || return 0

    local registry="$TODO_CHECKS_PROJECT_ROOT/private/secrets-registry.yml"
    # No registry / no yq means we have NOT verified any secret's expiry. Saying
    # nothing here is what let expired credentials sit unreported.
    if [ ! -f "$registry" ]; then
        todo_add_unknown "secret_expiry" \
            "no secrets registry at $registry — no secret expiry was checked" \
            "" "pl secrets status"
        return 0
    fi
    if ! command -v yq &>/dev/null; then
        todo_add_unknown "secret_expiry" \
            "yq is not installed, so the secrets registry could not be read" \
            "" "pl doctor"
        return 0
    fi

    local warn_days=$(get_todo_setting "thresholds.secret_warn_days" "14")
    local alert_days=$(get_todo_setting "thresholds.secret_alert_days" "3")
    local now_epoch=$(date +%s)

    local count
    count=$(yq eval '.secrets | length' "$registry" 2>/dev/null || echo 0)
    { [ -z "$count" ] || [ "$count" = "null" ]; } && count=0

    local i untracked=0
    for ((i=0; i<count; i++)); do
        local id expires status
        id=$(yq eval ".secrets[$i].id // \"\"" "$registry" 2>/dev/null | grep -v '^null$')
        [ -z "$id" ] && continue
        status=$(yq eval ".secrets[$i].status // \"\"" "$registry" 2>/dev/null | grep -v '^null$')
        [ "$status" = "not-provisioned" ] && continue
        expires=$(yq eval ".secrets[$i].expires // \"unknown\"" "$registry" 2>/dev/null | grep -v '^null$')

        if [ -z "$expires" ] || [ "$expires" = "unknown" ]; then
            untracked=$((untracked+1))   # rolled into one summary item after the loop
            continue
        fi

        local exp_epoch
        exp_epoch=$(date -d "$expires" +%s 2>/dev/null || echo 0)
        [ "$exp_epoch" = "0" ] && continue
        local days_until=$(( (exp_epoch - now_epoch) / 86400 ))

        if [ "$days_until" -lt 0 ]; then
            todo_add_item "SEC" "$id" "high" \
                "Secret EXPIRED $(( -days_until )) days ago: $id" \
                "Expired: $expires" "" "pl secrets rotate $id"
        elif [ "$days_until" -le "$alert_days" ]; then
            todo_add_item "SEC" "$id" "high" \
                "Secret expires in $days_until days: $id" \
                "Expires: $expires" "" "pl secrets rotate $id"
        elif [ "$days_until" -le "$warn_days" ]; then
            todo_add_item "SEC" "$id" "medium" \
                "Secret expires in $days_until days: $id" \
                "Expires: $expires" "" "pl secrets rotate $id"
        fi
    done

    # One roll-up nag while the registry doesn't yet reflect reality.
    if [ "$untracked" -gt 0 ]; then
        todo_add_item "SEC" "untracked" "medium" \
            "$untracked of $count secret(s) have no recorded rotation" \
            "The registry only tracks what you record. Check each at its provider, then 'pl secrets done <#|id>' (or rotate via 'pl secrets rotate <#>')." \
            "" "pl secrets status"
    fi
}

# check_token_liveness — LIVE token validity + REAL expiry (daily-cached).
# Runs `pl secrets audit --quiet` at most once per ~20h (the only network in
# `pl todo`), caches the result, and turns DEAD/expiring tokens into todo items.
# Distinct from check_secret_expiry (recorded dates only) — THIS catches revoked/
# expired tokens whose recorded expiry still looks fine (the gap that hid 3 dead
# tokens). Exit 2 from the audit = host unreachable → keep stale cache, no alert.
check_token_liveness() {
    is_category_enabled "token_liveness" || return 0
    if ! command -v yq &>/dev/null; then
        todo_add_unknown "token_liveness" "yq is not installed — no token was probed" "" "pl doctor"
        return 0
    fi
    local root="$TODO_CHECKS_PROJECT_ROOT"
    local sec="$root/scripts/commands/secrets.sh"
    if [ ! -f "$sec" ]; then
        todo_add_unknown "token_liveness" "secrets.sh not found at $sec — no token was probed" "" ""
        return 0
    fi
    local cache="$root/private/.token-audit-cache"
    local warn_days=$(get_todo_setting "thresholds.secret_warn_days" "14")
    local now age=999999
    now=$(date +%s)
    [ -f "$cache" ] && age=$(( now - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -ge 72000 ]; then
        local out rc=0
        out=$(bash "$sec" audit --quiet --days "$warn_days" 2>/dev/null) || rc=$?
        if [ "$rc" = "2" ]; then
            # Host unreachable. The old code kept the stale cache and returned
            # clean — with NO age check, so a 1-byte cache from any point in the
            # past kept the fleet quiet indefinitely. Say we are blind instead,
            # and say how long we have been blind.
            local cache_age_desc="never successfully audited"
            if [ -f "$cache" ]; then
                cache_age_desc="last successful audit ~$(( age / 86400 ))d ago"
            fi
            todo_add_unknown "token_liveness" \
                "the token probe could not reach its host ($cache_age_desc) — no token liveness was verified this run" \
                "" "pl secrets audit"
            return 0
        fi
        printf '%s\n' "$out" > "$cache" 2>/dev/null && chmod 600 "$cache" 2>/dev/null || true
        # Record when we last actually managed to probe, so staleness is a fact
        # rather than an inference from a file we may never have rewritten.
        date -u +%FT%TZ > "$root/private/.token-audit-last-success" 2>/dev/null || true
    fi
    if [ ! -f "$cache" ]; then
        todo_add_unknown "token_liveness" \
            "no token-audit cache exists and none could be produced — no token liveness was verified" \
            "" "pl secrets audit"
        return 0
    fi
    local id live exp note
    while IFS=$'\t' read -r id live exp note; do
        [ -z "$id" ] && continue
        if [ "$live" = "DEAD" ]; then
            todo_add_item "SEC" "$id" "high" \
                "Token DEAD (revoked/invalid): $id" \
                "Live probe returned no valid identity. $note" "" "pl secrets steps $id"
        else
            todo_add_item "SEC" "$id" "medium" \
                "Token expiring soon: $id (live expiry $exp)" \
                "$note" "" "pl secrets steps $id"
        fi
    done < "$cache"
}

# LOOP: agent-loop daily MR cap (nwp/ops#46).
# The loop exits clean when it has opened AGENT_LOOP_DAILY_CAP (default 5) MRs in
# a UTC day — silently. Surface that here so `pl todo` (and `pl rag`, as amber)
# says "throughput is being clipped: runaway, or raise the cap?". Stateless: the
# loop's state file lives on the ai-host, so count today's MRs by their `agent/`
# source-branch prefix via the GitLab API instead. Cap override:
# settings.todo.thresholds.agent_loop_daily_cap (keep it matching the loop's
# AGENT_LOOP_DAILY_CAP on the ai-host).
check_agent_loop_cap() {
    is_category_enabled "agent_loop" || return 0

    local secrets_file="$TODO_CHECKS_PROJECT_ROOT/.secrets.yml"
    local api_token="" server=""
    if [ -f "$secrets_file" ] && command -v yq &>/dev/null; then
        api_token=$(yq eval '.gitlab.api_token // ""' "$secrets_file" 2>/dev/null | grep -v '^null$')
        server=$(yq eval '.gitlab.server.domain // ""' "$secrets_file" 2>/dev/null | grep -v '^null$')
    fi
    # FAIL-OPEN -> FAIL-LOUD. These three paths used to `return 0`, which is
    # indistinguishable from "checked, healthy". A cap check that cannot reach
    # GitLab knows nothing; it must say so — and via todo_add_unknown, so the
    # structured `unknown: true` flag is set and `pl rag` refuses to grade GREEN.
    if [ -z "$api_token" ]; then
        todo_add_unknown "agent_loop" \
            "no GitLab token on this host — check_agent_loop_cap could not authenticate, so 'loop healthy' is not being asserted" \
            "" "pl secrets status"
        return 0
    fi
    [ -z "$server" ] && server="${NWP_GITLAB_HOST:-}"
    if [ -z "$server" ]; then
        todo_add_unknown "agent_loop" \
            "no GitLab server configured — set gitlab.server.domain in .secrets.yml or NWP_GITLAB_HOST" \
            "" "pl secrets keys"
        return 0
    fi

    local cap
    cap=$(get_todo_setting "thresholds.agent_loop_daily_cap" "5")

    # MRs created since UTC midnight whose source branch is the loop's agent/ prefix.
    local since mrs count
    since=$(date -u +%Y-%m-%dT00:00:00Z)
    mrs=$(curl -sf -H "PRIVATE-TOKEN: $api_token" \
        "https://$server/api/v4/merge_requests?scope=all&created_after=$since&per_page=100" 2>/dev/null)
    if [ -z "$mrs" ]; then
        todo_add_unknown "agent_loop" \
            "GitLab unreachable from this host — no MR list returned, so throughput cannot be assessed (network down, or the token is dead)" \
            "" "pl loop"
        return 0
    fi
    count=$(echo "$mrs" | grep -o '"source_branch":"agent/[^"]*"' | wc -l)

    [ "$count" -ge "$cap" ] || return 0

    # Queue depth: how much eligible work is now waiting behind the cap.
    local queued
    queued=$(curl -sf -H "PRIVATE-TOKEN: $api_token" \
        "https://$server/api/v4/issues?labels=agent-eligible&state=opened&scope=all&per_page=100" 2>/dev/null \
        | grep -o '"iid":[0-9]*' | wc -l)

    local hint="none queued — check the MRs are wanted (runaway?)"
    [ "$queued" -gt 0 ] && hint="$queued agent-eligible issue(s) now wait for tomorrow"
    todo_add_item "LOOP" "daily-cap" "medium" \
        "Agent-loop hit its daily MR cap ($count/$cap today)" \
        "Review today's agent/* MRs first; $hint. If throughput is legit, raise AGENT_LOOP_DAILY_CAP in the loop env on the ai-host (and match your merge cadence)." \
        "" "pl issue ls"
}

# LOOP: is the self-healing loop actually alive?
#
# WHY (the met-audit-31-nights pattern, inside NWP's own automation): the loop
# was globally killed on 2026-07-18 13:50 via `.loop-paused`. For 8 consecutive
# nights rag-sync logged "part disabled — skipping" and exited 0 — a green cron.
# Over exactly that window `pl rag` was genuinely 12 red / 10 amber / 0 green
# and filed ZERO issues. `check_agent_loop_cap` only fires on EXCESS MRs, so
# zero MRs was indistinguishable from healthy, and nothing in `pl todo`,
# `pl rag` or `pl status` said the loop was dark. `pl loop` shows it, but only
# to someone who already suspects it.
#
# This check makes "the oversight machinery is switched off" a finding.
# Thresholds: settings.todo.thresholds.loop_dark_warn_days (default 2).
check_loop_liveness() {
    is_category_enabled "loop_liveness" || return 0

    local rt="${NWP_ROOT:-$TODO_CHECKS_PROJECT_ROOT}"
    local warn_days now_epoch
    warn_days=$(get_todo_setting "thresholds.loop_dark_warn_days" "2")
    now_epoch=$(date +%s)

    # 1. Global kill-switch (legacy sentinel or parts.state all=disabled).
    local killed="" since="" age_days=0
    if [ -f "$rt/.loop-paused" ]; then
        killed="legacy sentinel .loop-paused"
        local m; m=$(stat -c %Y "$rt/.loop-paused" 2>/dev/null || echo "$now_epoch")
        age_days=$(( (now_epoch - m) / 86400 ))
        since=" (set ${age_days}d ago)"
    fi
    if [ -z "$killed" ] && command -v loop_part_raw &>/dev/null; then
        [ "$(loop_part_raw all 2>/dev/null)" = "disabled" ] && killed="parts.state all=disabled"
    elif [ -z "$killed" ] && [ -f "$TODO_CHECKS_DIR/loop-parts.sh" ]; then
        # shellcheck source=/dev/null
        NWP_ROOT="$rt" source "$TODO_CHECKS_DIR/loop-parts.sh" 2>/dev/null || true
        if command -v loop_part_raw &>/dev/null; then
            [ "$(loop_part_raw all 2>/dev/null)" = "disabled" ] && killed="parts.state all=disabled"
        fi
    fi

    if [ -n "$killed" ]; then
        local prio="medium"
        [ "$age_days" -ge "$warn_days" ] && prio="high"
        todo_add_item "LOOP" "global-kill" "$prio" \
            "Self-healing loop is DARK — global kill active${since}" \
            "Cause: $killed. While this is set, rag-sync files no issues and the fix loop opens no MRs — every loop cron exits 0 and looks healthy. Re-arm with: pl loop enable all" \
            "" "pl loop"
    fi

    # 2. Individual parts disabled (visible even without a global kill).
    if command -v loop_part_raw &>/dev/null && [ -n "${LOOP_PARTS:-}" ]; then
        local p raw
        for p in "${LOOP_PARTS[@]}"; do
            raw=$(loop_part_raw "$p" 2>/dev/null)
            [ "$raw" = "disabled" ] || continue
            [ -n "$killed" ] && continue   # already reported by the roll-up above
            todo_add_item "LOOP" "part-$p" "medium" \
                "Loop part '$p' is disabled" \
                "This part's cron still runs and still exits 0 — it just does nothing." \
                "" "pl loop enable $p"
        done
    fi
}

# LOOP: rag-sync freshness — did stage 1 of the loop actually complete?
#
# Reads the cron wrapper's own log rather than trusting its exit code: the
# wrapper exits 0 both when it syncs and when it skips. AMBER past
# thresholds.rag_sync_warn_days (2), RED past thresholds.rag_sync_alert_days (7).
check_rag_sync_freshness() {
    is_category_enabled "loop_liveness" || return 0

    local rt="${NWP_ROOT:-$TODO_CHECKS_PROJECT_ROOT}"
    local log="$rt/logs/rag-sync.log"
    local warn_days alert_days
    warn_days=$(get_todo_setting "thresholds.rag_sync_warn_days" "2")
    alert_days=$(get_todo_setting "thresholds.rag_sync_alert_days" "7")

    # No cron installed at all is a different (and quieter) fact than a dead one.
    if [ ! -f "$log" ]; then
        if crontab -l 2>/dev/null | grep -q 'rag-sync\.sh'; then
            todo_add_item "LOOP" "rag-sync-nolog" "medium" \
                "rag-sync is scheduled but has never written a log" \
                "Expected: $log — the cron may be failing before it can log." \
                "" "pl loop"
        fi
        return 0
    fi

    # The ONLY line that proves a real sync happened.
    local last_done last_epoch now_epoch age_days
    last_done=$(grep 'rag-sync done' "$log" 2>/dev/null | tail -1 | awk '{print $1}')

    if [ -z "$last_done" ]; then
        todo_add_item "LOOP" "rag-sync-never" "high" \
            "rag-sync has never completed a run" \
            "No 'rag-sync done' line in $log. Skipped runs also exit 0, so cron looks green." \
            "" "pl loop"
        return 0
    fi

    last_epoch=$(date -d "$last_done" +%s 2>/dev/null || echo 0)
    [ "$last_epoch" = "0" ] && return 0
    now_epoch=$(date +%s)
    age_days=$(( (now_epoch - last_epoch) / 86400 ))

    local skipped=""
    grep -q 'disabled\|paused' <(tail -5 "$log" 2>/dev/null) && \
        skipped=" Recent runs logged 'disabled/paused' — the loop is switched off, not broken."

    if [ "$age_days" -ge "$alert_days" ]; then
        todo_add_item "LOOP" "rag-sync-stale" "high" \
            "rag-sync last completed ${age_days}d ago (threshold ${alert_days}d)" \
            "Last successful sync: $last_done.$skipped While this is stale, RED fleet state files no issues." \
            "" "pl loop"
    elif [ "$age_days" -ge "$warn_days" ]; then
        todo_add_item "LOOP" "rag-sync-stale" "medium" \
            "rag-sync last completed ${age_days}d ago (threshold ${warn_days}d)" \
            "Last successful sync: $last_done.$skipped" \
            "" "pl loop"
    fi
}

# LOOP: agent-host auth freshness.
#
# The host that runs the loop authenticates with an OAuth credential file that
# only an interactive login refreshes. On one host that file's mtime had not
# moved for ~15 weeks and nothing surfaced it — an expired credential silently
# converts the loop into a no-op whose cron still exits 0.
#
# Host identities live in config, never here: set
#   settings.todo.agent_hosts: "<name>=<addr> <name>=<addr>"
# in nwp.yml (use the VPN address, not a LAN alias — LAN aliases time out
# whenever the operator is away from that network, which would turn this check
# into a nightly false alarm). Unset = remote probing is skipped, and the check
# says so rather than pretending the hosts are healthy.
check_agent_host_auth() {
    is_category_enabled "agent_host_auth" || return 0

    local warn_days now_epoch
    warn_days=$(get_todo_setting "thresholds.agent_auth_warn_days" "30")
    now_epoch=$(date +%s)

    # Local credential file (when pl runs ON the agent host).
    local cred="$HOME/.claude/.credentials.json"
    if [ -f "$cred" ]; then
        local m age
        m=$(stat -c %Y "$cred" 2>/dev/null || echo "$now_epoch")
        age=$(( (now_epoch - m) / 86400 ))
        if [ "$age" -ge "$warn_days" ]; then
            todo_add_item "LOOP" "agent-auth" "medium" \
                "Agent OAuth credential not refreshed for ${age}d (threshold ${warn_days}d)" \
                "File: $cred. An expired credential turns the loop into a silent no-op — its cron still exits 0." \
                "" "re-run an interactive Claude login on this host"
        fi
    fi

    # Remote agent hosts — config-driven, no host identity in this repo.
    local hosts h name addr
    hosts=$(get_todo_setting "agent_hosts" "")
    if [ -z "$hosts" ]; then
        # Say nothing loudly: not configured is not the same as healthy, but it
        # is also not a nightly alarm. One low item, once.
        todo_add_item "LOOP" "hosts-unconfigured" "low" \
            "Agent-host reachability is not being checked" \
            "settings.todo.agent_hosts is unset in nwp.yml, so no remote agent host is probed. Format: \"<name>=<addr> <name>=<addr>\" (VPN addresses)." \
            "" "set settings.todo.agent_hosts in nwp.yml"
        return 0
    fi
    for h in $hosts; do
        name="${h%%=*}"; addr="${h#*=}"
        [ -n "$addr" ] || continue
        [ "$name" = "$addr" ] && continue
        if ! ping -c1 -W2 "$addr" >/dev/null 2>&1; then
            todo_add_item "LOOP" "host-$name" "medium" \
                "Agent host '$name' unreachable at its configured address" \
                "Work routed to $name is not running." \
                "" "pl loop"
        fi
    done
}

# DRIFT: the three site enumerations must agree, or say which is wrong.
#
# WHY: `pl backup sweep` walks discover_sites (on-disk .nwp.yml), `pl todo`'s
# BAK/SSL/TST checks walk yaml_get_all_sites (nwp.yml), `pl rag` walks a third
# list and rag-sync a fourth. Live divergence at the time of writing:
# cccrdf / fin / saintschool exist on disk and are absent from nwp.yml (so no
# backup check ever ran for them — all three have zero backups, ever), while
# nwp.yml carries 6 phantom entries (dev, hidden, rgs, ssc1, avc-stg,
# verify-test) with no directory. Each list independently reported "clean".
check_site_registry_drift() {
    is_category_enabled "site_registry_drift" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"
    [ -f "$config_file" ] || return 0

    if ! command -v discover_sites &>/dev/null; then
        if [ -f "$TODO_CHECKS_DIR/project-resolver.sh" ]; then
            # shellcheck source=/dev/null
            source "$TODO_CHECKS_DIR/project-resolver.sh"
        else
            return 0
        fi
    fi
    # The drift check compares TWO enumerations — if either is unavailable the
    # answer is "unknown", never "no drift".
    if ! command -v yaml_get_all_sites &>/dev/null; then
        if [ -f "$TODO_CHECKS_DIR/yaml-write.sh" ]; then
            # shellcheck source=/dev/null
            source "$TODO_CHECKS_DIR/yaml-write.sh" 2>/dev/null || true
        fi
    fi
    if ! command -v yaml_get_all_sites &>/dev/null; then
        todo_add_item "DRIFT" "unreadable" "low" \
            "Site-registry drift UNKNOWN: cannot read nwp.yml site list" \
            "yaml_get_all_sites unavailable — the two enumerations cannot be compared." \
            "" "pl doctor"
        return 0
    fi

    local disk_list yaml_list s
    disk_list=$(discover_sites 2>/dev/null | sort -u)
    yaml_list=$(yaml_get_all_sites "$config_file" 2>/dev/null | sort -u)

    # On disk, not registered -> every nwp.yml-driven check silently skips it.
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        if ! printf '%s\n' "$yaml_list" | grep -qx "$s"; then
            todo_add_item "DRIFT" "unregistered-$s" "medium" \
                "Site '$s' is on disk but absent from nwp.yml" \
                "Every nwp.yml-driven check (backups, SSL, security, schedules) skips it silently." \
                "$s" "pl site init $s"
        fi
    done <<< "$disk_list"

    # Registered, no directory -> a phantom entry inflating every count.
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        if command -v is_fixture_sitename >/dev/null 2>&1 && is_fixture_sitename "$s"; then
            continue
        fi
        if [ ! -d "$TODO_CHECKS_PROJECT_ROOT/sites/$s" ]; then
            todo_add_item "DRIFT" "phantom-$s" "low" \
                "nwp.yml lists site '$s' but no directory exists" \
                "Phantom entry: sites/$s is missing. It inflates every per-site count." \
                "$s" "remove the entry from nwp.yml"
        fi
    done <<< "$yaml_list"
}

# GWK: commits that exist on this laptop and nowhere else.
#
# A branch with unpushed commits is one disk failure from gone, and invisible to
# `git status`. `feat/nwptoolkit-deploy` (340 lines) sat on no remote at all.
check_unpushed_commits() {
    is_category_enabled "uncommitted_work" || return 0

    local warn_days
    warn_days=$(get_todo_setting "thresholds.unpushed_warn_days" "3")

    if ! command -v discover_repos &>/dev/null; then
        [ -f "$TODO_CHECKS_DIR/project-resolver.sh" ] || return 0
        # shellcheck source=/dev/null
        source "$TODO_CHECKS_DIR/project-resolver.sh"
    fi

    local repo rel slug branch n last_epoch now_epoch age_days
    now_epoch=$(date +%s)

    while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        branch=$(timeout 10 git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null) || continue
        [ -n "$branch" ] || continue
        n=$(timeout 20 git -C "$repo" rev-list --count "$branch" --not --remotes 2>/dev/null || echo 0)
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        [ "$n" -gt 0 ] || continue

        last_epoch=$(timeout 10 git -C "$repo" log -1 --format=%ct "$branch" 2>/dev/null || echo 0)
        [ "$last_epoch" = "0" ] && continue
        age_days=$(( (now_epoch - last_epoch) / 86400 ))
        [ "$age_days" -ge "$warn_days" ] || continue

        rel="${repo#$TODO_CHECKS_PROJECT_ROOT/}"
        [ "$rel" = "$repo" ] && rel="."
        slug=$(printf '%s' "$rel" | tr '/' '-' | tr -cd 'A-Za-z0-9._-')
        todo_add_item "GWK" "unpushed-$slug" "high" \
            "$n commit(s) on '$branch' exist only on this machine (${age_days}d old)" \
            "Repo: $repo | On no remote — a disk failure loses them." \
            "$(_gwk_site_of "$rel")" "git -C $repo push -u origin $branch"
    done < <( { discover_repos 2>/dev/null; printf '%s\n' "$TODO_CHECKS_PROJECT_ROOT"; } )
}

# LBK: live-tier backup freshness (nwp/ops#87 Part B).
# The live box runs a producer cron that deposits pulled site backups under
# /var/backups/nwp-pull. If the newest file there is older than
# settings.todo.thresholds.live_backup_warn_days (default 2), the producer
# has probably stopped — surface that as a MEDIUM finding. Fail-soft by
# design: no key, no config, or no network (offline dev) → silent return.
#
# Box resolution is config-driven, never hardcoded here:
#   - settings.todo.live_backup.server names a servers/<name>/.nwp-server.yml
#     entry (default: nwpcode); ip/user come from lib/server-resolver.sh
#     (which itself falls back to the legacy nwp.yml linode.servers block).
#   - settings.todo.live_backup.ssh_key overrides the key path
#     (default: ~/.ssh/gitlab_linode).
#   - settings.todo.live_backup.path overrides the remote backup dir.
# The action string for a DR-backup finding.
#
# All three branches used to file the literal string
#   "ssh into <server> and check the nwp-pull producer cron"
# which is not a command, so `tui_is_executable` returned false and the
# highest-consequence item in the whole list was inert — you could not act on it
# from `pl todo`, and it trained the reflex of starting an incident with raw ssh.
# Prefer `pl server backup verify` the moment that verb exists (item 7 ships it);
# until then fall back to the read-only server verb that does exist today. Either
# way the operator gets something they can press enter on.
_lbk_action() {
    local server="$1"
    if grep -qE '^\s*(verify|"verify")\)' "$TODO_CHECKS_PROJECT_ROOT/scripts/commands/server-backup.sh" 2>/dev/null; then
        printf 'pl server backup verify %s' "$server"
    else
        printf 'pl server status %s' "$server"
    fi
}

check_live_backup_freshness() {
    is_category_enabled "live_backup" || return 0

    # server-resolver is auto-sourced via lib/common.sh in command contexts;
    # load it here for standalone use.
    local server
    server=$(get_todo_setting "live_backup.server" "nwpcode")

    if ! command -v get_server_ip &>/dev/null; then
        if [ -f "$TODO_CHECKS_DIR/server-resolver.sh" ]; then
            # shellcheck source=/dev/null
            source "$TODO_CHECKS_DIR/server-resolver.sh"
        else
            todo_add_unknown "live_backup" \
                "lib/server-resolver.sh is missing, so '$server' could not be resolved — DR backup freshness was NOT checked" \
                "" ""
            return 0
        fi
    fi

    # EVERY failure below used to `return 0`, i.e. report the DR backup chain
    # clean. Proven with TEST-NET-1: pointing this check at 192.0.2.1 produced
    # silence, which `pl rag` rendered as green. The disaster-recovery signal is
    # precisely the one that must never fail open.
    local ip user key remote_path warn_days
    ip=$(get_server_ip "$server" 2>/dev/null)
    user=$(get_server_user "$server" 2>/dev/null)
    if [ -z "$ip" ]; then
        todo_add_unknown "live_backup" \
            "server '$server' has no resolvable IP (missing servers/$server/.nwp-server.yml?) — DR backup freshness was NOT checked" \
            "" "pl server list"
        return 0
    fi
    [ -z "$user" ] && user="gitlab"

    key=$(get_todo_setting "live_backup.ssh_key" "$HOME/.ssh/gitlab_linode")
    key="${key/#\~/$HOME}"
    if [ ! -f "$key" ]; then
        todo_add_unknown "live_backup" \
            "ssh key $key is not present on this machine — DR backup freshness on '$server' was NOT checked" \
            "" "pl secrets status"
        return 0
    fi

    remote_path=$(get_todo_setting "live_backup.path" "/var/backups/nwp-pull")
    warn_days=$(get_todo_setting "thresholds.live_backup_warn_days" "2")

    # One remote round-trip: newest mtime epoch, or MISSING if the dir is gone.
    local remote_out rc=0
    remote_out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes \
        -i "$key" "$user@$ip" \
        "if [ -d '$remote_path' ]; then find '$remote_path' -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1; else echo MISSING; fi" \
        2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        todo_add_unknown "live_backup" \
            "ssh to $user@$ip ('$server') failed with exit $rc — DR backup freshness was NOT checked. Being off-network looks identical to the producer cron being dead; this item exists so the two are distinguishable." \
            "" "pl server backup verify $server"
        return 0
    fi

    if [ "$remote_out" = "MISSING" ]; then
        todo_add_item "LBK" "$server" "medium" \
            "Live-tier backup dir missing on $server (box producer cron?)" \
            "Expected: $remote_path on $server | The producer cron may never have run" \
            "" "$(_lbk_action "$server")"
        return 0
    fi

    local now_epoch newest_epoch age_days
    now_epoch=$(date +%s)
    newest_epoch="${remote_out%%.*}"

    if [ -z "$newest_epoch" ] || ! [[ "$newest_epoch" =~ ^[0-9]+$ ]]; then
        # Dir exists but holds no files — same signal as stale.
        todo_add_item "LBK" "$server" "medium" \
            "Live-tier backup dir empty on $server (box producer cron?)" \
            "Path: $remote_path | No backup files found" \
            "" "$(_lbk_action "$server")"
        return 0
    fi

    age_days=$(( (now_epoch - newest_epoch) / 86400 ))
    if [ "$age_days" -ge "$warn_days" ]; then
        todo_add_item "LBK" "$server" "medium" \
            "Live-tier backup stale (${age_days}d old — box producer cron?)" \
            "Path: $remote_path on $server | Threshold: $warn_days days" \
            "" "$(_lbk_action "$server")"
    fi
}

# PAU: paused automation.
#
# WHY THIS EXISTS: a `.loop-paused` sentinel sat on all three AI hosts for over a
# week. Every night the wrapper logged "skipping" and exited 0 — a green cron, a
# green exit code, and not one `pl` surface anywhere that said the self-healing
# loop had been off since the middle of the month. A pause is a decision; a pause
# nobody can see is an outage. This check makes every pause visible, ages it, and
# demands a reason.
#
# NOTE ON SCOPE: this deliberately does NOT weaken the global kill switch.
# `.loop-paused` still stops every part including rag-sync (lib/loop-parts.sh).
# The defect was that a pause was INVISIBLE, not that the brake was too strong,
# and narrowing an operator's big red button is not a change an agent should make.
check_paused_automation() {
    is_category_enabled "paused_automation" || return 0

    local root="$TODO_CHECKS_PROJECT_ROOT"
    local now; now=$(date +%s)
    local sentinel name age_days mtime reason until_s until_epoch

    for sentinel in "$root/.loop-paused" "$root/.rag-sync-paused"; do
        [ -f "$sentinel" ] || continue
        name="$(basename "$sentinel")"
        mtime=$(stat -c %Y "$sentinel" 2>/dev/null || echo "$now")
        age_days=$(( (now - mtime) / 86400 ))

        # A pause file may carry `reason:` and `until:` lines. An unannotated
        # pause is indistinguishable from someone forgetting to un-pause.
        reason=$(grep -iE '^\s*reason:' "$sentinel" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//')
        until_s=$(grep -iE '^\s*until:' "$sentinel" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//')

        local title="Automation PAUSED: $name (${age_days} day(s))"
        local desc="Sentinel: $sentinel"
        if [ -n "$reason" ]; then
            desc="$desc | reason: $reason"
        else
            desc="$desc | no reason recorded — an unannotated pause is indistinguishable from a forgotten one. Add 'reason:' and 'until:' lines to the file."
        fi
        if [ -n "$until_s" ]; then
            until_epoch=$(date -d "$until_s" +%s 2>/dev/null || echo 0)
            if [ "$until_epoch" != "0" ] && [ "$until_epoch" -lt "$now" ]; then
                title="Automation PAUSED PAST ITS DEADLINE: $name (until $until_s, expired)"
                desc="$desc | until: $until_s — that window has expired"
            else
                desc="$desc | until: $until_s"
            fi
        fi
        todo_add_item "PAU" "${name#.}" "high" "$title" "$desc" "" "pl loop status"
    done

    # Per-part disables (lib/loop-parts.sh state file). Host-local by design, so
    # this reports THIS machine's arming state — which is the point: "armed on
    # two hosts" was previously one invisible switch.
    local state_file="${NWP_LOOP_STATE:-$HOME/.config/nwp-loop/parts.state}"
    if [ -f "$state_file" ]; then
        local k v
        while IFS='=' read -r k v; do
            k="${k%%[[:space:]]*}"; k="${k#"${k%%[![:space:]]*}"}"
            [ -z "$k" ] && continue
            case "$k" in \#*) continue ;; esac
            v="${v%%[[:space:]]*}"
            [ "$v" = "disabled" ] || continue
            local sage; sage=$(( (now - $(stat -c %Y "$state_file" 2>/dev/null || echo "$now")) / 86400 ))
            todo_add_item "PAU" "part-$k" "high" \
                "Loop part disabled: $k (state file ${sage} day(s) old)" \
                "State: $state_file | This host will not run '$k'. Re-enable with: pl loop enable $k" \
                "" "pl loop status"
        done < "$state_file"
    fi
}

# RSY: rag-sync freshness.
#
# The tracker's WRITE half. `pl rag` reading the fleet is useless if nothing
# turns that state into issues — and rag-sync failing is silent by construction,
# because "skipping" is a successful exit. Age the last SUCCESSFUL run, not the
# last log line: 8 nights of "skipping" is 8 nights of no writes, and the log
# file's mtime looks fresh the whole time.
check_rag_sync_freshness() {
    is_category_enabled "rag_sync" || return 0

    local log="$TODO_CHECKS_PROJECT_ROOT/logs/rag-sync.log"
    if [ ! -f "$log" ]; then
        todo_add_unknown "rag_sync" \
            "no rag-sync log at $log — cannot tell whether the RAG→issues writer has ever run on this host" \
            "" "pl loop status"
        return 0
    fi

    local warn_days alert_days
    warn_days=$(get_todo_setting "thresholds.rag_sync_warn_days" "2")
    alert_days=$(get_todo_setting "thresholds.rag_sync_alert_days" "7")

    # A "done" line is the only evidence a sync actually ran. "skipping" lines
    # are explicitly NOT evidence — they are the failure mode.
    local last_done
    last_done=$(grep -E 'rag-sync done' "$log" 2>/dev/null | tail -1 | awk '{print $1}')

    local now; now=$(date +%s)
    local age_days
    if [ -z "$last_done" ]; then
        local skips
        skips=$(grep -cE 'skipping' "$log" 2>/dev/null || echo 0)
        todo_add_item "RSY" "never" "high" \
            "rag-sync has NEVER completed a run on this host" \
            "Log: $log | ${skips} 'skipping' line(s) and no completed run. A skipped run exits 0, so cron looks healthy while nothing is written to the tracker." \
            "" "pl loop status"
        return 0
    fi

    local done_epoch
    done_epoch=$(date -d "$last_done" +%s 2>/dev/null || echo 0)
    if [ "$done_epoch" = "0" ]; then
        todo_add_unknown "rag_sync" \
            "could not parse a timestamp from the last rag-sync 'done' line ('$last_done')" \
            "" "pl loop status"
        return 0
    fi

    age_days=$(( (now - done_epoch) / 86400 ))
    if [ "$age_days" -ge "$alert_days" ]; then
        todo_add_item "RSY" "stale" "high" \
            "rag-sync has not completed for ${age_days} day(s)" \
            "Log: $log | Last completed run: $last_done | Threshold: $alert_days days. The fleet's RAG state is not reaching nwp/ops." \
            "" "pl loop status"
    elif [ "$age_days" -ge "$warn_days" ]; then
        todo_add_item "RSY" "stale" "medium" \
            "rag-sync has not completed for ${age_days} day(s)" \
            "Log: $log | Last completed run: $last_done | Threshold: $warn_days days." \
            "" "pl loop status"
    fi
}

# NTF: can this machine actually notify the operator?
#
# The guide's own conclusion about the old arrangement was "the notification
# system can't notify you that it can't notify you". This check is the answer:
# it ages the last successful `pl notify health` canary. It deliberately does NOT
# send a notification itself — `pl todo` runs often and must stay read-only and
# quiet — it reports on the freshness of the last proof.
check_notify_health() {
    is_category_enabled "notify_health" || return 0

    local notify="$TODO_CHECKS_PROJECT_ROOT/scripts/commands/notify.sh"
    if [ ! -x "$notify" ]; then
        todo_add_unknown "notify_health" \
            "pl notify is not available on this machine — cannot tell whether alerts would reach you" \
            "" ""
        return 0
    fi

    local stampfile="$TODO_CHECKS_PROJECT_ROOT/private/.notify-last-ok"
    local warn_days
    warn_days=$(get_todo_setting "thresholds.notify_health_warn_days" "7")

    if [ ! -f "$stampfile" ]; then
        todo_add_item "NTF" "never" "high" \
            "The notification path has NEVER been proven on this machine" \
            "No $stampfile. An alert path nobody has exercised is not an alert path — run: pl notify health" \
            "" "pl notify health"
        return 0
    fi

    local now age_days mtime
    now=$(date +%s)
    mtime=$(stat -c %Y "$stampfile" 2>/dev/null || echo "$now")
    age_days=$(( (now - mtime) / 86400 ))
    if [ "$age_days" -ge "$warn_days" ]; then
        todo_add_item "NTF" "stale" "medium" \
            "Notification path last proven ${age_days} day(s) ago" \
            "Threshold: $warn_days days | Run: pl notify health" \
            "" "pl notify health"
    fi
}

################################################################################
# Main Check Runner
################################################################################

# Run all enabled checks and return combined results
################################################################################
# Check Registry for Progressive Loading
################################################################################

# List of all checks with display names
# Format: "function_name:Display Name"
TODO_CHECK_LIST=(
    "check_ghost_sites:Ghost sites"
    "check_incomplete_installs:Incomplete installs"
    "check_security_updates:Security updates"
    "check_ssl_expiry:SSL certificates"
    "check_test_instances:Test instances"
    "check_token_rotation:Token rotation"
    "check_secret_expiry:Secret expiry"
    "check_token_liveness:Token liveness (live probe)"
    "check_missing_backups:Missing backups"
    "check_live_backup_freshness:Live backup freshness"
    "check_disk_usage:Disk usage"
    "check_gitlab_issues:GitLab issues"
    "check_agent_loop_cap:Agent-loop cap"
    "check_loop_liveness:Loop liveness (self-report)"
    "check_rag_sync_freshness:rag-sync freshness"
    "check_agent_host_auth:Agent host auth"
    "check_site_registry_drift:Site registry drift"
    "check_orphaned_sites:Orphaned sites"
    "check_missing_schedules:Missing schedules"
    "check_verification:Verification"
    "check_uncommitted_work:Uncommitted work"
    "check_unpushed_commits:Unpushed commits"
    "check_paused_automation:Paused automation"
    "check_rag_sync_freshness:RAG-sync freshness"
    "check_notify_health:Notification path health"
)

# Get check count
todo_get_check_count() {
    echo "${#TODO_CHECK_LIST[@]}"
}

# Get check name by index
todo_get_check_name() {
    local idx="$1"
    echo "${TODO_CHECK_LIST[$idx]}" | cut -d: -f2
}

# Run a single check by index
# Args: $1=index
# Returns items found by this check via TODO_ITEMS array
todo_run_check_by_index() {
    local idx="$1"
    local entry="${TODO_CHECK_LIST[$idx]}"
    local func="${entry%%:*}"

    # Run the check function (it adds to TODO_ITEMS)
    "$func" 2>/dev/null || true
}

run_all_checks() {
    local skip_cache="${1:-false}"

    todo_cache_init
    [ "$skip_cache" = "true" ] && todo_cache_clear

    todo_clear_items

    # Run all checks (they add to TODO_ITEMS)
    for entry in "${TODO_CHECK_LIST[@]}"; do
        local func="${entry%%:*}"
        "$func" 2>/dev/null || true
    done

    # Output results
    todo_output_items
}

# Export functions
export -f todo_cache_valid
export -f todo_cache_init
export -f todo_cache_clear
export -f todo_add_item
export -f todo_add_unknown
export -f _lbk_action
export -f todo_output_items
export -f todo_clear_items
export -f get_todo_setting
export -f is_category_enabled
export -f check_gitlab_issues
export -f check_test_instances
export -f check_token_rotation
export -f check_orphaned_sites
export -f check_ghost_sites
export -f check_incomplete_installs
export -f check_missing_backups
export -f check_missing_schedules
export -f check_security_updates
export -f check_verification
export -f check_uncommitted_work
export -f check_disk_usage
export -f check_ssl_expiry
export -f check_secret_expiry
export -f check_token_liveness
export -f check_agent_loop_cap
export -f check_loop_liveness
export -f check_rag_sync_freshness
export -f check_agent_host_auth
export -f check_site_registry_drift
export -f check_unpushed_commits
export -f _gwk_site_of
export -f check_live_backup_freshness
export -f check_paused_automation
export -f check_rag_sync_freshness
export -f check_notify_health
export -f run_all_checks
export -f todo_get_check_count
export -f todo_get_check_name
export -f todo_run_check_by_index
export -f todo_is_ignored
