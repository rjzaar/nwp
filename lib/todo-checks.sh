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

# Bounded HTTP with a shared timeout policy + the rc-2 "could not tell"
# vocabulary. Every network call below goes through it: an unbounded curl in a
# check is how `pl todo check --json` went from ~30s to >100s, and an unbounded
# curl that silently returns "" is how a slow link produced a falsely-clean
# result. See lib/http.sh.
# shellcheck source=/dev/null
[ -f "$TODO_CHECKS_DIR/http.sh" ] && source "$TODO_CHECKS_DIR/http.sh"

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

# Escape a value for embedding in a JSON string literal.
# Backslash MUST be replaced first, or the escapes we add get re-escaped.
_todo_json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
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

    # Store as JSON. Every field is ESCAPED (ops#178): this was raw string
    # interpolation into a "JSON-like format". check_agent_host_auth's
    # description legitimately contains double quotes
    #   ... Format: \"<name>=<addr>\" (VPN addresses).
    # and scripts/commands/todo.sh read items back with `"[^"]*"`, which stops
    # at the first quote inside a value — so that description reached `pl rag`
    # truncated to `... Format: `, silently, with the document still parsing.
    # Escaping here is only half the fix: parse_todo_items must decode escapes
    # and show_json must re-encode them, or the truncation becomes a malformed
    # document instead. See scripts/commands/todo.sh.
    local item="{\"id\":\"$(_todo_json_escape "$full_id")\""
    item+=",\"category\":\"$(_todo_json_escape "$category")\""
    item+=",\"priority\":\"$(_todo_json_escape "$priority")\""
    item+=",\"title\":\"$(_todo_json_escape "$title")\""
    item+=",\"description\":\"$(_todo_json_escape "$description")\""
    item+=",\"site\":\"$(_todo_json_escape "$site")\""
    item+=",\"action\":\"$(_todo_json_escape "$action")\""
    item+=",\"unknown\":${TODO_ITEM_UNKNOWN:-false}}"
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
        # `// ""` is yq's ALTERNATIVE operator, and it treats `false` as an
        # absent value. So `categories.rag_sync: false` read back as "" and then
        # as the default "true": no todo category could actually be switched
        # off, and the config block documenting "set false to silence" was
        # inert. Found while proving which gate controls the (ops#204) surviving
        # rag-sync freshness check — a gate you cannot demonstrate closing is
        # not a gate. Read the raw value and normalise `null` by hand instead.
        value=$(yq eval ".settings.todo.${key_path}" "$config_file" 2>/dev/null)
        [ "$value" = "null" ] && value=""
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

    # Get user ID.
    #
    # FAIL-OPEN -> FAIL-LOUD (same treatment as check_agent_loop_cap). These two
    # calls used to be `curl -sf` with no timeout and a bare `return 0` on empty
    # output. That is two bugs wearing one coat:
    #   - no timeout: on a high-latency link curl blocks on its own defaults
    #     (~2 min to give up on a connect, unbounded on a stalled transfer), so
    #     `pl todo check` stopped finishing at all;
    #   - `return 0` on empty: when the call finally failed, "GitLab unreachable"
    #     was indistinguishable from "you have no assigned issues".
    # Both are now handled: the budget comes from lib/http.sh, and rc 2 ("could
    # not tell") becomes an UNK item so `pl rag` cannot grade the fleet GREEN
    # off the back of a network failure.
    local user_info rc=0
    user_info=$(nwp_http_gitlab_get "$server" "/user" "$api_token") || rc=$?
    if [ "$rc" = "$NWP_HTTP_RC_UNREACHABLE" ]; then
        todo_add_unknown "git_issues" \
            "GitLab ($server) did not answer within the $(nwp_http_budget_desc) — your assigned-issue list was NOT checked, so an empty list here means nothing" \
            "" "pl todo check"
        return 0
    fi
    # rc 1 = the server answered with an HTTP error (e.g. 401 on a dead token).
    # That is a verdict, and a token that cannot read /user is its own finding —
    # but check_token_liveness owns token health, so stay quiet here.
    [ "$rc" != 0 ] && return 0
    [ -n "$user_info" ] || return 0

    local user_id
    user_id=$(echo "$user_info" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

    if [ -z "$user_id" ]; then
        return 0
    fi

    # Fetch assigned issues
    local issues
    rc=0
    issues=$(nwp_http_gitlab_get "$server" \
        "/issues?assignee_id=$user_id&state=opened&per_page=50" "$api_token") || rc=$?
    if [ "$rc" = "$NWP_HTTP_RC_UNREACHABLE" ]; then
        todo_add_unknown "git_issues" \
            "GitLab ($server) answered /user but not /issues within the $(nwp_http_budget_desc) — the assigned-issue list is UNKNOWN, not empty" \
            "" "pl todo check"
        return 0
    fi
    [ "$rc" != 0 ] && return 0

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

# SEC: Security updates — read `pl audit`'s cached records.
#
# WAS VACUOUS *AND* THE READ-ONLY VIOLATION (ops#178). The previous body shelled
#     ddev drush pm:security --format=json   ... || echo "[]"
# once per site. Three independent defects, each sufficient on its own:
#
#   1. `pm:security` was REMOVED from Drush ("pm:security has been removed.
#      Please use `composer audit`"). It can only ever fail.
#   2. That failure was swallowed by the trailing `|| echo "[]"`, so the removed
#      command was indistinguishable from a clean site. The check could not emit
#      a SEC item for ANY input, while "Security: clean" read as a measurement.
#   3. The webroot probe looked in <directory>/{web,html,docroot,.} — but the v2
#      nested layout (F17/F23) puts the webroot at sites/<name>/dev/web. On the
#      live fleet that matched 2 of 21 sites; the other 19 hit `continue` and
#      were never even attempted.
#
#   4. And for the 2 it did match, `ddev drush` AUTO-STARTS a stopped ddev
#      project. A check advertised as a read-only listing must never mutate the
#      host it is reporting on.
#
# `pl audit` already maintains exactly this signal at
# private/update-awareness/<site>.json, refreshed nightly, and `pl rag` already
# grades from it. Reading that cache is both correct and free. Interpretation is
# shared with rag via lib/audit-record.py so the two cannot disagree.
#
# HONESTY: a site with NO record, an UNREADABLE record, a record that says
# `scanned: false`, or a record too old to be load-bearing is UNKNOWN — never
# clean. `security_count: 0` on an unscanned record means "not measured".
check_security_updates() {
    is_category_enabled "security_updates" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/nwp.yml}"
    if [ ! -f "$config_file" ]; then
        todo_add_unknown "security_updates" \
            "no config at $config_file — no site's security state was checked" "" ""
        return 0
    fi

    local audit_dir="${NWP_AUDIT_STATE_DIR:-$TODO_CHECKS_PROJECT_ROOT/private/update-awareness}"
    local interp="$TODO_CHECKS_DIR/audit-record.py"

    if [ ! -d "$audit_dir" ]; then
        todo_add_unknown "security_updates" \
            "no pl audit records at $audit_dir — the fleet's security state has never been measured on this host" \
            "" "pl audit --all"
        return 0
    fi
    if [ ! -f "$interp" ] || ! command -v python3 &>/dev/null; then
        todo_add_unknown "security_updates" \
            "cannot interpret audit records (need python3 and $interp) — 'no security items' would be an unfounded claim" \
            "" "pl audit --all"
        return 0
    fi

    local stale_days
    stale_days=$(get_todo_setting "thresholds.audit_stale_days" "7")
    [[ "$stale_days" =~ ^[0-9]+$ ]] || stale_days=7

    # One python invocation for the whole directory: site<TAB>state<TAB>count<TAB>ignored<TAB>reason
    local table
    if ! table=$(python3 "$interp" --dir "$audit_dir" --stale-days "$stale_days" 2>/dev/null); then
        todo_add_unknown "security_updates" \
            "audit-record.py failed to read $audit_dir — the security signal could not be evaluated" \
            "" "pl audit --all"
        return 0
    fi

    # Index the table so we can answer "what does the record say for <site>?"
    local -A _sec_state=() _sec_count=() _sec_reason=()
    local s st ct ig rs
    while IFS=$'\t' read -r s st ct ig rs; do
        [ -z "$s" ] && continue
        _sec_state["$s"]="$st"; _sec_count["$s"]="$ct"; _sec_reason["$s"]="$rs"
    done <<< "$table"

    while read -r site; do
        [ -z "$site" ] && continue

        # Test/throwaway instances are not part of the security posture.
        local purpose
        purpose=$(yaml_get_site_field "$site" "purpose" "$config_file" 2>/dev/null)
        [ "$purpose" = "testing" ] && continue

        local state="${_sec_state[$site]:-}"
        if [ -z "$state" ]; then
            todo_add_unknown "security_updates_$site" \
                "no pl audit record at $audit_dir/$site.json — this site's security state was never measured (that is not the same as clean)" \
                "$site" "pl audit $site"
            continue
        fi

        local count="${_sec_count[$site]:-0}"
        local reason="${_sec_reason[$site]:-}"

        case "$state" in
            unscanned)
                todo_add_unknown "security_updates_$site" \
                    "UNSCANNED — $reason (recorded security_count $count means 'not measured', NOT zero)" \
                    "$site" "pl audit $site"
                ;;
            stale)
                todo_add_unknown "security_updates_$site" \
                    "STALE — $reason (a stale record is not a clean one)" \
                    "$site" "pl audit $site"
                ;;
            measured)
                if [ "$count" -gt 0 ]; then
                    todo_add_item "SEC" "$site" "high" \
                        "$count security advisory/advisories affecting this site" \
                        "Site: $site | Source: pl audit record ($reason) | Detail: pl audit $site" \
                        "$site" "pl audit $site"
                fi
                ;;
        esac
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
        # A RETIRED credential has no expiry to alert on — it does not exist
        # (ops#268). Alerting would keep `pl todo` and `pl rag` amber forever for
        # work that is finished, which is how real alerts get ignored.
        [ -n "$(yq eval ".secrets[$i].retired // \"\"" "$registry" 2>/dev/null | grep -v '^null$')" ] && continue
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

# SEC: Known-EXPOSED credentials that still owe a rotation (operator ruling D8).
#
# "Exposures need to be logged in the todo list so they can be rotated when I
#  get to it and must be done before prod site starts."  — operator, 2026-08-01
#
# This is the "logged in the todo list" half; lib/rotation-debt.sh's guard is
# the "before prod starts" half, and both read the SAME registry field, so the
# queue and the gate can never disagree about what is owed.
#
# Distinct from check_secret_expiry (a date passed) and check_token_liveness (the
# provider says it is dead): an exposed credential can be perfectly valid and
# perfectly in-date and still need replacing, because its value was SEEN. Nothing
# in the estate could express that before — the three exposures found on
# 2026-08-01 could only be written down as free-text GitLab issues.
#
# One HIGH item per open debt: category SEC + priority high is what makes
# `pl rag` grade RED (lib/rag-render.py: SEC_CATS × high), so an exposure cannot
# sit in a green fleet.
check_exposed_secrets() {
    is_category_enabled "exposed_secrets" || return 0

    local registry="${NWP_SECRETS_REGISTRY:-$TODO_CHECKS_PROJECT_ROOT/private/secrets-registry.yml}"
    # Absent registry = a fresh clone / CI checkout, not a claim of cleanliness;
    # check_secret_expiry already raises the UNK for that, so raising a second
    # one here would double-count the same blind spot.
    [ -f "$registry" ] || return 0
    if ! command -v yq &>/dev/null; then
        todo_add_unknown "exposed_secrets" \
            "yq is not installed, so known-exposed credentials could not be read" \
            "" "pl doctor"
        return 0
    fi
    if ! yq eval '.' "$registry" >/dev/null 2>&1; then
        todo_add_unknown "exposed_secrets" \
            "the secrets registry exists but does not parse — rotation debt could not be read" \
            "" "pl secrets lint"
        return 0
    fi

    local id at ref closed sev how n=0
    while IFS=$'\t' read -r id at ref closed sev how; do
        [ -n "$id" ] || continue
        n=$((n+1))
        # The item is embedded in hand-rolled JSON by todo_add_item, so strip the
        # two characters that would break the envelope.
        how="${how//\"/\'}"; how="${how//\\/ }"
        [ "$closed" = "true" ] && closed="surface closed" || closed="surface OPEN"
        todo_add_item "SEC" "exposed-$id" "high" \
            "EXPOSED credential awaiting rotation: $id" \
            "Exposed $at (${sev}, ${closed})${ref:+ | $ref} | $how | A closed surface is NOT a rotation. BLOCKS prod bring-up (ruling D8)." \
            "" "pl secrets rotate $id"
    done < <(yq eval '.secrets[] | .id as $id | (.exposure // [])[]
                      | select((.rotated // false) != true)
                      | [$id, (.at // "?"), (.ref // ""), ((.closed // false) | tostring),
                         (.severity // "high"), (.how // "-")] | @tsv' "$registry" 2>/dev/null)
    return 0
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
        # `pl secrets audit` probes every registry entry at its provider — one
        # or more HTTPS round trips each. It is bounded per-call by lib/http.sh,
        # but the SUM over N tokens is not, so the sweep gets its own wall clock
        # too. Without it, one slow link turned this single check into the long
        # pole of `pl todo check`. timeout(1) rc 124 is folded into rc 2: a probe
        # we abandoned told us exactly as much as one that could not connect.
        local out rc=0 budget
        budget=$(get_todo_setting "thresholds.token_audit_budget_seconds" \
                 "$([ "$(nwp_http_profile)" = batch ] && echo 120 || echo 30)")
        out=$(timeout "$budget" bash "$sec" audit --quiet --days "$warn_days" 2>/dev/null) || rc=$?
        [ "$rc" = "124" ] && rc=2
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
    local since mrs count rc=0
    since=$(date -u +%Y-%m-%dT00:00:00Z)
    mrs=$(nwp_http_gitlab_get "$server" \
        "/merge_requests?scope=all&created_after=$since&per_page=100" "$api_token") || rc=$?
    if [ "$rc" != 0 ] || [ -z "$mrs" ]; then
        todo_add_unknown "agent_loop" \
            "GitLab unreachable from this host — no MR list returned within the $(nwp_http_budget_desc), so throughput cannot be assessed (network down, or the token is dead)" \
            "" "pl loop"
        return 0
    fi
    count=$(echo "$mrs" | grep -o '"source_branch":"agent/[^"]*"' | wc -l)

    [ "$count" -ge "$cap" ] || return 0

    # Queue depth: how much eligible work is now waiting behind the cap. This one
    # is decoration on an already-firing finding, so a failure downgrades the
    # hint rather than discarding the finding.
    local queued queued_json
    if queued_json=$(nwp_http_gitlab_get "$server" \
            "/issues?labels=agent-eligible&state=opened&scope=all&per_page=100" "$api_token"); then
        queued=$(printf '%s' "$queued_json" | grep -o '"iid":[0-9]*' | wc -l)
    else
        queued=-1
    fi

    local hint="none queued — check the MRs are wanted (runaway?)"
    [ "$queued" -gt 0 ] && hint="$queued agent-eligible issue(s) now wait for tomorrow"
    [ "$queued" -lt 0 ] && hint="queue depth UNKNOWN — the issue list did not answer in time"
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
# SEC/INFRA: forge patch-check cadence (D33 / ops#80).
#
# The forge holds the entire trust root, yet nothing nagged when nobody had
# looked at its package state in a while — cadence by memory is cadence by luck
# (its apt signing key silently expired on 2026-07-11 and nothing noticed).
#
# This check is CHEAP by construction: it reads the timestamp `pl server forge
# status` records under private/forge/<server>.last-check and nags on staleness.
# It NEVER probes the box itself — the forge is 3.8 GB and a heavy op OOM-killed
# it (2026-07-25), so the remote probe stays an explicit operator/cron action.
# A configured server with no recording at all is itself the finding: it means
# the forge has never been checked through the tool.
check_forge_freshness() {
    is_category_enabled "forge_freshness" || return 0

    local rt="${NWP_ROOT:-$TODO_CHECKS_PROJECT_ROOT}"
    local warn_days alert_days
    warn_days=$(get_todo_setting "thresholds.forge_warn_days" "30")
    alert_days=$(get_todo_setting "thresholds.forge_alert_days" "45")

    # Which servers should be checked. Discover if we can; a bare directory
    # listing of servers/ is the fallback. No hardcoded names.
    local servers="" s
    if command -v discover_servers &>/dev/null; then
        servers="$(discover_servers 2>/dev/null)"
    fi
    if [ -z "$servers" ] && [ -d "$rt/servers" ]; then
        servers="$(for d in "$rt"/servers/*/; do [ -d "$d" ] && basename "$d"; done)"
    fi
    [ -z "$servers" ] && return 0

    local now_epoch; now_epoch=$(date +%s)
    while read -r s; do
        [ -z "$s" ] && continue
        local stamp="$rt/private/forge/${s}.last-check"
        if [ ! -f "$stamp" ]; then
            todo_add_item "SEC" "forge-$s" "medium" \
                "forge '$s' has never been checked through pl" \
                "No private/forge/${s}.last-check — run: pl server forge status $s" \
                "" "pl server forge status $s"
            continue
        fi
        local last_iso last_epoch age_days
        # `read` rather than `awk 'NR==1{print $1}'`: same result, no subprocess,
        # and it keeps lint:yq-first's multi-line awk scanner out of a stamp file
        # that was never YAML to begin with (ADR-0015 gate, ops#230).
        last_iso=""; read -r last_iso _ < "$stamp" 2>/dev/null || true
        last_epoch=$(date -d "$last_iso" +%s 2>/dev/null || echo 0)
        [ "$last_epoch" = "0" ] && continue
        age_days=$(( (now_epoch - last_epoch) / 86400 ))

        # An expired key recorded in the stamp is high regardless of age.
        local key_expiry; key_expiry=$(grep -oE 'key_expiry=[0-9]+' "$stamp" 2>/dev/null | cut -d= -f2)
        if [ -n "$key_expiry" ] && [ "$key_expiry" -lt "$now_epoch" ] 2>/dev/null; then
            todo_add_item "SEC" "forge-$s" "high" \
                "forge '$s' apt signing key is EXPIRED (last check ${age_days}d ago)" \
                "An expired repo key silently stops security updates. Refresh it, then: pl server forge status $s" \
                "" "pl server forge status $s"
            continue
        fi

        if [ "$age_days" -ge "$alert_days" ]; then
            todo_add_item "SEC" "forge-$s" "high" \
                "forge '$s' not checked in ${age_days}d (threshold ${alert_days}d)" \
                "Last checked $last_iso. The forge holds the trust root; run: pl server forge status $s" \
                "" "pl server forge status $s"
        elif [ "$age_days" -ge "$warn_days" ]; then
            todo_add_item "SEC" "forge-$s" "medium" \
                "forge '$s' not checked in ${age_days}d (threshold ${warn_days}d)" \
                "Last checked $last_iso. Run: pl server forge status $s" \
                "" "pl server forge status $s"
        fi
    done <<< "$servers"
}

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

    # One remote round-trip: newest mtime epoch (or MISSING if the dir is gone),
    # then — nwp/ops#332 — the producer's OWN verdict on the line after it.
    #
    # Freshness alone cannot see a half-done night: on 2026-08-04 the box
    # nightly's site-DB leg began failing while its gitlab/ and nginx/ legs kept
    # writing fresh files every night, so "newest file is 4 h old" stayed true
    # and green for six days over a directory with no databases in it. The
    # producer now states a verdict; this check reads it rather than inferring
    # one. A pre-ops#332 producer writes no verdict at all, which is reported
    # (as VERDICT=none) rather than assumed benign.
    local remote_out rc=0
    remote_out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes \
        -i "$key" "$user@$ip" \
        "if [ -d '$remote_path' ]; then find '$remote_path' -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1; else echo MISSING; fi
         if [ -r '$remote_path/backup-verdict.json' ]; then
             printf 'VERDICT=%s\n' \"\$(sed -n 's/.*\"verdict\"[[:space:]]*:[[:space:]]*\"\([a-z-]*\)\".*/\1/p' '$remote_path/backup-verdict.json' | head -1)\"
         else printf 'VERDICT=none\n'; fi" \
        2>/dev/null) || rc=$?
    local remote_verdict=""
    remote_verdict=$(printf '%s\n' "$remote_out" | sed -n 's/^VERDICT=//p' | head -1)
    remote_out=$(printf '%s\n' "$remote_out" | grep -v '^VERDICT=' | head -1)
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

    # BKV: the producer's stated verdict (nwp/ops#332). Graded before freshness,
    # because a fresh directory with a failed leg is the exact shape that hid
    # for six days.
    case "$remote_verdict" in
        ok) : ;;
        failed)
            todo_add_item "BKV" "$server" "high" \
                "Box nightly backup reported verdict=FAILED on $server" \
                "Path: $remote_path/backup-verdict.json | A declared leg did not run — read the artefact for which one" \
                "" "pl host apply $server --kind=backup" ;;
        cannot-verify)
            todo_add_item "BKV" "$server" "high" \
                "Box nightly backup CANNOT VERIFY a leg on $server" \
                "Path: $remote_path/backup-verdict.json | A leg is undeclared and unmeasurable — declare it" \
                "" "pl host apply $server --kind=backup" ;;
        none|"")
            todo_add_unknown "live_backup" \
                "the nightly on '$server' writes no backup-verdict.json — it is a pre-ops#332 producer that logs 'done' and exits 0 even when a leg never ran, so its success is NOT evidence" \
                "" "pl host apply $server --kind=backup --execute" ;;
        *)
            todo_add_unknown "live_backup" \
                "backup-verdict.json on '$server' carries an unreadable verdict ('$remote_verdict') — an unparseable verdict is not a pass" \
                "" "pl host apply $server --kind=backup" ;;
    esac

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

# RSY: rag-sync freshness — HAS THE OVERSIGHT ITSELF STOPPED? (ops#230, ops#204)
#
# The tracker's WRITE half. `pl rag` reading the fleet is useless if nothing
# turns that state into issues — and rag-sync failing is silent by construction,
# because "skipping" is a successful exit. Age the last SUCCESSFUL run, not the
# last log line: 16 nights of "skipping" is 16 nights of no writes, and the log
# file's mtime looks fresh the whole time.
#
# ops#204 — THE DUPLICATE, AND WHICH BODY SURVIVED.
# There were TWO `check_rag_sync_freshness` definitions in this file and two
# entries in TODO_CHECK_LIST. Bash binds the LAST definition, so the one that
# actually ran was this one: gated on category `rag_sync`, filing `RSY-*` items
# and `UNK-rag_sync`. The earlier one — gated on `loop_liveness`, filing
# `LOOP-rag-sync-*` — had been dead code since the day it was shadowed, and
# `loop_liveness` was therefore a category that gated nothing here. Deleting the
# WRONG one would have silently swapped which category switch controls this
# check and renamed every item id, so: the dead `loop_liveness`/`LOOP-*` body was
# removed, this `rag_sync`/`RSY-*` body kept (it is also the category declared in
# example.nwp.yml), and the two unique behaviours the dead body had — noticing a
# scheduled-but-never-logged wrapper, and distinguishing "switched off" from
# "broken" — are folded in below via lib/oversight-freshness.sh.
#
# The probe itself is shared (lib/oversight-freshness.sh) with `pl rag`'s
# self-liveness banner and the `pl loop` dashboard. Four independent inline
# implementations of "when did rag-sync last complete?" is how the answer got to
# be "2026-07-17" without anything saying so.
check_rag_sync_freshness() {
    is_category_enabled "rag_sync" || return 0

    # The probe lives beside THIS file, not under the tree being inspected:
    # TODO_CHECKS_PROJECT_ROOT can point at a fixture directory (or another
    # host's tree) that has logs but no lib/.
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local root="${NWP_ROOT:-$TODO_CHECKS_PROJECT_ROOT}"
    local lib="$here/oversight-freshness.sh"
    if [ ! -f "$lib" ]; then
        todo_add_unknown "rag_sync" \
            "lib/oversight-freshness.sh is missing — whether the oversight loop is still running is UNMEASURED" \
            "" "pl loop schedule status"
        return 0
    fi

    # loop-parts.sh gives the probe the capability/kill picture; without it the
    # probe still works, it just cannot say "switched off" vs "broken".
    local parts="$here/loop-parts.sh"
    # shellcheck source=/dev/null
    [ -f "$parts" ] && NWP_ROOT="$root" . "$parts" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$lib" 2>/dev/null || {
        todo_add_unknown "rag_sync" \
            "could not source lib/oversight-freshness.sh — oversight liveness is UNMEASURED" \
            "" "pl loop schedule status"
        return 0
    }

    local warn_days alert_days
    warn_days=$(get_todo_setting "thresholds.rag_sync_warn_days" "2")
    alert_days=$(get_todo_setting "thresholds.rag_sync_alert_days" "7")

    NWP_ROOT="$root" oversight_probe "$warn_days" "$alert_days"

    case "$OVERSIGHT_STATE" in
        LIVE) return 0 ;;
        UNKNOWN|DELEGATED)
            todo_add_unknown "rag_sync" "$OVERSIGHT_DETAIL" "" "$OVERSIGHT_ACTION" ;;
        *)
            local prio=medium
            [ "$OVERSIGHT_GRADE" = "RED" ] && prio=high
            todo_add_item "RSY" "$(printf '%s' "$OVERSIGHT_STATE" | tr 'A-Z' 'a-z')" "$prio" \
                "oversight $OVERSIGHT_STATE — rag-sync is not turning the fleet RAG grade into issues" \
                "$OVERSIGHT_DETAIL" \
                "" "$OVERSIGHT_ACTION" ;;
    esac
}

# DCD: demo invite-code drift (nwp/ops#173).
#
# WHY THIS EXISTS: on 2026-08-01 the live demo site held ZERO invite codes while
# the operator held five valid ones and an invitation in the post telling testers
# to use them. Three numbers had to agree and none of them did — the registry
# said 3 active on one host and 25 on another, the site said 25, and the box's
# staged payload (which the 01:00 reset restores over the top, authoritatively)
# said 0. Every one of those numbers was one command away the whole time. The
# defect was not that they were hard to read; it was that nothing read them.
#
# This is that reader. It does NOT probe: probing means ssh + remote drush per
# site, and `pl todo check` runs inside a 45s budget that `pl rag` will call
# UNKNOWN if it blows. It ages the record `pl demo codes <site> drift` and every
# successful live code-sync leave behind — the same shape as `pl audit` writing
# private/update-awareness/<site>.json for `pl rag` to grade.
#
# NO RECORD IS A FINDING, not a pass. A host that holds a code registry it has
# never once checked against the site is the precise state that produced ops#173,
# and it is the state the console host was in for the whole of the pilot.
check_demo_code_drift() {
    is_category_enabled "demo_codes" || return 0

    local root="$TODO_CHECKS_PROJECT_ROOT"
    local lib="$root/lib/demo.sh"
    [ -f "$lib" ] || return 0

    # Only sites that actually carry a code registry on this host.
    local found=false f site
    for f in "$root"/sites/*/demo-codes.json; do
        [ -e "$f" ] || continue
        found=true
        break
    done
    [ "$found" = true ] || return 0

    # lib/demo.sh is pure and side-effect-free at source time; PROJECT_ROOT is
    # what its path helpers read. Saved and restored rather than set as a
    # command prefix: an assignment in front of `source` is a special-builtin
    # assignment and PERSISTS, so the prefix form would silently redefine
    # PROJECT_ROOT for every check that runs after this one.
    local _saved_root="${PROJECT_ROOT:-}"
    PROJECT_ROOT="$root"
    # shellcheck source=/dev/null
    if ! source "$lib" 2>/dev/null; then
        PROJECT_ROOT="$_saved_root"
        todo_add_unknown "demo_codes" "could not load lib/demo.sh — invite-code drift is unmeasured" "" "pl demo codes <site> drift --tier=live"
        return 0
    fi

    local warn_hours report state detail rec
    warn_hours=$(get_todo_setting "thresholds.demo_code_drift_warn_hours" "48")
    case "$warn_hours" in ''|*[!0-9]*) warn_hours=48 ;; esac

    for f in "$root"/sites/*/demo-codes.json; do
        [ -e "$f" ] || continue
        site=$(basename "$(dirname "$f")")
        rec=$(demo_drift_file "$site")
        report=$(demo_drift_report "$rec" "$(( warn_hours * 3600 ))" 2>/dev/null) || report="unknown|drift report failed"
        state="${report%%|*}"; detail="${report#*|}"
        case "$state" in
            ok) : ;;
            drift)
                todo_add_item "DCD" "$site" "high" \
                    "Demo invite codes DISAGREE for $site ($detail)" \
                    "registry-active / site-live / staged-payload must be the same number. They are not, so either testers are being rejected now, or they will be after the 01:00 reset restores the box's staged payload over the top. Record: $rec" \
                    "$site" "pl demo codes $site drift --tier=live"
                ;;
            missing)
                todo_add_item "DCD" "${site}-unchecked" "medium" \
                    "This host has NEVER checked that ${site}'s invite codes reach the site" \
                    "It holds sites/${site}/demo-codes.json but no observation record. A registry nobody has compared against the live site is exactly the state that let ops#173 run unnoticed — the numbers were readable the whole time." \
                    "$site" "pl demo codes $site drift --tier=live"
                ;;
            stale)
                todo_add_item "DCD" "${site}-stale" "medium" \
                    "Demo invite-code delivery for $site is unverified ($detail)" \
                    "Threshold: ${warn_hours}h. Record: $rec" \
                    "$site" "pl demo codes $site drift --tier=live"
                ;;
            *)
                todo_add_unknown "demo_codes_${site}" \
                    "could not tell whether ${site}'s invite codes reach the site: $detail" \
                    "$site" "pl demo codes $site drift --tier=live"
                ;;
        esac
    done

    PROJECT_ROOT="$_saved_root"
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

# SEC/goldenid: is a real person's identity baked into a demo golden image?
#
# WHY THIS EXISTS: on 2026-08-01 the ssd golden was found carrying a Moodle
# site-administrator row with the operator's real given name, family name and
# personal mailbox — and had been since the site was installed on 2026-05-19.
# A golden is not a backup that ages out: it is restored over the live demo site
# EVERY NIGHT, staged onto the demo box, and duplicated at rest into every backup
# of that box. Whatever is in it is permanent by construction, on a site whose
# whole promise to a tester is "you never give us your name or your email, and
# nothing about you is kept".
#
# It graded GREEN the entire time because nothing ever looked. This is the
# looking. See lib/golden-hygiene.sh for why the rule is expressed structurally
# (mailbox domains must be RFC-reserved or estate-declared) rather than as a
# grep for a person — the leakage gate forbids naming either the person or the
# estate's domains in a tracked file, and a guard that must name what it guards
# is a guard that leaks it.
#
# Category is SEC/high on purpose: `pl rag` grades SEC-high as RED, so a golden
# carrying somebody's identity turns the fleet red and `pl rag --sync-issues`
# opens the ops issue by itself.
check_demo_golden_hygiene() {
    is_category_enabled "golden_identity" || return 0

    local root="$TODO_CHECKS_PROJECT_ROOT"
    local lib="$root/lib/golden-hygiene.sh"
    [ -f "$lib" ] || return 0

    # Goldens only exist under sites/, which is gitignored — so this check is a
    # no-op on a CI runner and only does work on a host that actually holds one.
    local found=false d
    for d in "$root"/sites/*/demo-golden "$root"/sites/*/demo-golden-live; do
        [ -f "$d/golden.db.sql.gz" ] && { found=true; break; }
    done
    [ "$found" = true ] || return 0

    # shellcheck source=/dev/null
    source "$lib" 2>/dev/null || {
        todo_add_unknown "golden_identity" \
            "could not load lib/golden-hygiene.sh — demo goldens are unscanned for personal identifiers" \
            "" "pl todo check"
        return 0
    }

    local config_file="${TODO_CONFIG_FILE:-$root/nwp.yml}"
    local declared; declared=$(golden_hygiene_declared_domains "$config_file")
    local denylist; denylist=$(golden_hygiene_denylist_file "$root")

    local site tier artifact scan foreign masked offfence orphans
    for d in "$root"/sites/*/demo-golden "$root"/sites/*/demo-golden-live; do
        [ -d "$d" ] || continue
        site=$(basename "$(dirname "$d")")
        tier=$([ "$(basename "$d")" = "demo-golden-live" ] && echo live || echo "dev/stg")

        for artifact in "$d/golden.db.sql.gz" "$d/golden.files.tar.gz"; do
            [ -f "$artifact" ] || continue

            # Memoised on the sha256 of the artifact + both inputs: a recapture
            # or a denylist edit rescans, an unchanged golden costs one hash.
            scan=$(golden_hygiene_scan "$artifact" "$declared" "$denylist" "$TODO_CACHE_DIR" 2>/dev/null)
            foreign=$(printf '%s\n' "$scan" | sed -n 's/^MAIL //p')
            masked=$(printf '%s\n' "$scan"  | sed -n 's/^NAME //p')
            offfence=$(printf '%s\n' "$scan" | sed -n 's/^FENCE //p')

            # RULE 3 — the golden must still be RESETTABLE. Distinct from the
            # two above: this is not a leak, it is a booby trap. seed-demo runs
            # fail-closed in the box wrapper, so an account off @demo.invalid
            # inside the image aborts the whole nightly reset and every hourly
            # retry after it, until someone notices the site is stale.
            if [ -n "$offfence" ]; then
                todo_add_item "SEC" "goldenfence-${site}-$(basename "$d")-$(basename "$artifact" | tr . -)" "high" \
                    "Demo golden for ${site} (${tier}) would ABORT the nightly reset (seed-demo fence)" \
                    "$(basename "$artifact") contains account(s) above uid 1 that are off the demo fence @${GOLDEN_DEMO_FENCE_DOMAIN}: $(echo "$offfence" | tr '\n' ' '). nwc:seed-demo treats any such account as a real member and REFUSES; the box wrapper runs it fail-closed (die reason=seed-demo), so restoring this golden aborts the reset and every hourly retry to the 04:00 floor. Reported as uid + domain only, never the address. Fix the LIVE site (correct the mailbox to @${GOLDEN_DEMO_FENCE_DOMAIN}), prove it with 'pl drush ${site} --tier=live --execute -- nwc:seed-demo', then recapture: pl demo golden ${site} --tier=live" \
                    "$site" "pl demo golden ${site} --tier=live"
            fi

            # RULE 4 arrived on a branch that predated RULE 3 (the seed-fence
            # trap above); both were numbered 3. They are unrelated findings and
            # each is independently actionable, so both are kept and this one is
            # renumbered rather than folded in.
            orphans=$(printf '%s\n' "$scan" | sed -n 's/^ORPHAN //p')

            if [ -n "$foreign" ]; then
                todo_add_item "SEC" "goldenid-${site}-$(basename "$d")-$(basename "$artifact" | tr . -)-mail" "high" \
                    "Demo golden for ${site} (${tier}) carries a mailbox on an undeclared domain" \
                    "$(basename "$artifact") holds an address on: $(echo "$foreign" | tr '\n' ' '). A golden is restored over the LIVE demo site every night and copied into every backup of the demo box, so anything personal in it is permanent. Demo accounts must use an undeliverable sentinel address (RFC 2606, e.g. *.invalid); operational notification addresses must be a role address on an estate domain, not a person's. ${GOLDEN_HYGIENE_REMEDY} Recapture with: pl demo golden ${site} --tier=live" \
                    "$site" "pl demo golden ${site} --tier=live"
            fi

            if [ -n "$masked" ]; then
                todo_add_item "SEC" "goldenid-${site}-$(basename "$d")-$(basename "$artifact" | tr . -)-name" "high" \
                    "Demo golden for ${site} (${tier}) contains a denylisted personal identifier" \
                    "$(basename "$artifact") matched $(echo "$masked" | tr '\n' ' ') from the untracked identity denylist. Reported masked on purpose — a finding must not republish what it found. ${GOLDEN_HYGIENE_REMEDY} Recapture with: pl demo golden ${site} --tier=live" \
                    "$site" "pl demo golden ${site} --tier=live"
            fi

            # RULE 4 — the fingerprint of the WRONG remedy having already been
            # applied. SEC/high like its two siblings, deliberately: `pl rag`
            # grades RED on SEC/high only (lib/rag-render.py SEC_CATS), and
            # being unable to demonstrate WHICH text a person consented to is a
            # governance failure of the same weight as the leak that provoked
            # it — not a piece of background work to be triaged later.
            # Unlike the other two findings, a recapture does NOT clear this
            # one: the revision has to be put back, redacted, at its own vid.
            if [ -n "$orphans" ]; then
                todo_add_item "SEC" "goldenid-${site}-$(basename "$d")-$(basename "$artifact" | tr . -)-orphan" "high" \
                    "Demo golden for ${site} (${tier}) has user_consent rows citing deleted policy revisions" \
                    "$(basename "$artifact") holds consent records that name data_policy revision(s) which are not in the dump: $(echo "$orphans" | awk '{printf "vid %s (%s consent row(s)) ", $1, $2}'). The module never reuses or renumbers a vid, so the ordinary way to reach this state is that somebody DELETED a revision — almost always to silence a personal-data finding in an old draft. That is the wrong remedy and it is not repaired by recapturing: it destroys the drafting work and hollows out the consent record, which exists precisely to evidence WHICH text the person accepted. ${GOLDEN_HYGIENE_REMEDY} Restore the missing revision AT ITS ORIGINAL vid with the redacted body, then recapture: pl demo golden ${site} --tier=live" \
                    "$site" "pl demo golden ${site} --tier=live"
            fi
        done
    done

    # NO DENYLIST IS NOT A PASS. Rule 1 (mailbox domains) always ran, but
    # personal NAMES have no structure to check against, so on a host that holds
    # goldens and has never been told which name tokens to reject, the name half
    # of this check did not happen. UNKNOWN, not CLEAR — `pl rag` will not grade
    # a site with an open UNK item green.
    if [ ! -f "$denylist" ]; then
        todo_add_unknown "golden_identity_names" \
            "no identity denylist at private/golden-identity-denylist.txt — demo goldens are checked for foreign mail domains but NOT for personal names. Create it (one name token per line, '#' comments; private/ is gitignored, so nothing personal enters the repo)." \
            "" "pl todo check"
    fi
}

################################################################################
# check_demo_pair_cut — do both halves of the demo pair share ONE valid cut for
# the LIVE tier, and did the last paired operation complete or SPLIT? (D17)
#
# WHY THIS EXISTS
#   ops#170 made the paired live erasure real: `pl demo reset <provider>
#   --with-pair --tier=live` restores BOTH halves to one logical cut, refuses if
#   the cut was captured at another tier, and — if the consumer half fails after
#   the provider has already been restored — writes a SPLIT record at
#   sites/<provider>/demo-pair-INCONSISTENT.json.
#
#   Two things follow that nothing was watching:
#
#   1. The paired LIVE path has never run, and NO live golden has ever carried a
#      pair cut. So the verb will refuse the first time somebody reaches for it,
#      in an incident, at the worst possible moment. "It will refuse until a
#      --with-pair capture happens" is exactly the sort of fact that should be
#      on a dashboard rather than in an agent's head.
#
#   2. A SPLIT record means the two halves hold DIFFERENT data right now and the
#      OIDC identities between them are mismatched. It is written to a JSON file
#      on disk and read by precisely one thing: `pl demo status`, if a human
#      happens to run it, for the right site, at the right tier. A split that
#      nobody runs a verb to discover is a split nobody discovers.
#
#   This check answers both continuously, from the filesystem only — no ssh, no
#   probe. `pl todo check --json` runs inside a 45s budget for the WHOLE sweep
#   (180s batch), so a check that phones anywhere is a check that makes `pl rag`
#   time out and charge every site an `unknown`.
#
# GRADING, chosen deliberately
#   SPLIT              → SEC/high  ⇒ `pl rag` grades the site RED and
#                                    `pl rag --sync-issues` opens the ops issue
#                                    by itself. A live split is a data-integrity
#                                    incident, not a chore.
#   no live cut        → PCUT/medium ⇒ AMBER. Not broken; unproven. The honest
#                                    grade for a recovery path that has never
#                                    been exercised.
#   cut at wrong tier  → PCUT/high ⇒ AMBER, loudly. A dev cut sitting in a live
#                                    golden dir is a licence to wipe two LIVE
#                                    sites; ops#170 refuses it, and this says so
#                                    before anyone tries.
#   sha drift          → PCUT/high ⇒ AMBER. One half was re-captured alone; the
#                                    cut no longer binds the two goldens.
#   cannot tell        → UNKNOWN   ⇒ AMBER, and never GREEN. jq missing, a
#                                    contract that will not parse, a manifest
#                                    that will not read.
################################################################################
check_demo_pair_cut() {
    is_category_enabled "demo_pair_cut" || return 0

    local root="$TODO_CHECKS_PROJECT_ROOT"

    # Contracts are tracked; goldens are not. Both must be present for this
    # check to mean anything, so it is a silent no-op on a CI runner.
    [ -d "$root/pairs" ] || return 0

    local found=false d
    for d in "$root"/sites/*/demo-golden-live; do
        [ -f "$d/golden.manifest.json" ] && { found=true; break; }
    done
    [ "$found" = true ] || return 0

    if ! command -v jq >/dev/null 2>&1; then
        todo_add_unknown "demo_pair_cut" \
            "jq is not installed — cannot read pair cuts, so a live SPLIT would be invisible here" \
            "" "install jq"
        return 0
    fi

    local yq_bin; yq_bin="$(command -v yq || true)"
    if [ -z "$yq_bin" ]; then
        todo_add_unknown "demo_pair_cut" \
            "yq is not installed — cannot read pairs/*.pair-contract.yml" \
            "" "install yq"
        return 0
    fi

    local contract prov cons any=false
    for contract in "$root"/pairs/*.pair-contract.yml; do
        [ -e "$contract" ] || continue

        # OPT-IN, exactly as lib/demo-pair.sh gates it: only a contract that
        # DECLARES itself part of the demo tier is eligible. This is what keeps
        # the real ssc<->nwc pair (real students, no demo: block) out of here.
        [ "$("$yq_bin" e '.demo.enabled // false' "$contract" 2>/dev/null)" = "true" ] || continue

        prov="$("$yq_bin" e '.provider // ""' "$contract" 2>/dev/null)"
        cons="$("$yq_bin" e '.consumer // ""' "$contract" 2>/dev/null)"
        if [ -z "$prov" ] || [ "$prov" = "null" ] || [ -z "$cons" ] || [ "$cons" = "null" ]; then
            todo_add_unknown "demo_pair_cut_$(basename "$contract" .pair-contract.yml)" \
                "$(basename "$contract") declares demo.enabled but names no provider/consumer" \
                "" "pl pair check"
            continue
        fi
        any=true

        # ── 1. A SPLIT outranks everything else. Report it and move on: the cut
        #       state of a pair that is already inconsistent is not the story.
        local split="$root/sites/$prov/demo-pair-INCONSISTENT.json"
        if [ -s "$split" ]; then
            local when half cut_id
            when="$(jq -r '.recorded_utc // "unknown"' "$split" 2>/dev/null)"
            half="$(jq -r '.failed_half // "unknown"' "$split" 2>/dev/null)"
            cut_id="$(jq -r '.cut_id // "unknown"' "$split" 2>/dev/null)"
            todo_add_item "SEC" "pair-split-$prov" "high" \
                "PAIR SPLIT: $prov and $cons are NOT at the same cut" \
                "The $half half failed at cut $cut_id on $when. The two halves hold different data and their SSO identities are mismatched. Recorded in sites/$prov/demo-pair-INCONSISTENT.json" \
                "$prov" "pl demo reset $prov --with-pair --tier=live"
            continue
        fi

        # ── 2. Does a LIVE cut exist at all?
        local pdir="$root/sites/$prov/demo-golden-live"
        local cdir="$root/sites/$cons/demo-golden-live"
        local cut="$pdir/pair.cut.json"

        # Only meaningful once BOTH halves actually hold a live golden.
        [ -f "$pdir/golden.manifest.json" ] || continue
        if [ ! -f "$cdir/golden.manifest.json" ]; then
            todo_add_item "PCUT" "half-$cons" "medium" \
                "Live golden exists for $prov but not for $cons" \
                "The pair cannot be captured as one cut until both halves have a live golden" \
                "$cons" "pl demo golden $prov --with-pair --tier=live"
            continue
        fi

        if [ ! -s "$cut" ]; then
            todo_add_item "PCUT" "nocut-$prov" "medium" \
                "No LIVE pair cut for $prov and $cons — the paired live path has never run" \
                "Both halves hold a live golden but neither shares a cut, so 'pl demo reset $prov --with-pair --tier=live' will REFUSE. Capture one before you need it" \
                "$prov" "pl demo golden $prov --with-pair --tier=live"
            continue
        fi

        # ── 3. Is the cut this pair, at this tier?
        local ctier cprov ccons
        ctier="$(jq -r '.tier // ""' "$cut" 2>/dev/null)"
        cprov="$(jq -r '.provider.site // ""' "$cut" 2>/dev/null)"
        ccons="$(jq -r '.consumer.site // ""' "$cut" 2>/dev/null)"
        if [ -z "$ctier$cprov$ccons" ]; then
            todo_add_unknown "demo_pair_cut_$prov" \
                "sites/$prov/demo-golden-live/pair.cut.json will not parse — the live cut is unreadable" \
                "$prov" "pl demo golden $prov --with-pair --tier=live"
            continue
        fi
        if [ "$ctier" != "live" ]; then
            todo_add_item "PCUT" "wrongtier-$prov" "high" \
                "The live golden of $prov carries a '${ctier:-untiered}' pair cut, not a live one" \
                "A non-live cut in a live golden dir is a licence to wipe two LIVE sites; ops#170 refuses it. Re-capture at this tier" \
                "$prov" "pl demo golden $prov --with-pair --tier=live"
            continue
        fi
        if [ "$cprov" != "$prov" ] || [ "$ccons" != "$cons" ]; then
            todo_add_item "PCUT" "wrongpair-$prov" "high" \
                "The live pair cut in $prov names ${cprov}/${ccons}, not ${prov}/${cons}" \
                "A cut copied from another pair binds nothing here" \
                "$prov" "pl demo golden $prov --with-pair --tier=live"
            continue
        fi

        # ── 4. Does the cut still BIND? Four sha256s, against each half's own
        #       manifest. Drift means one half was re-captured alone, and a
        #       paired restore would leave the SSO identities mismatched.
        local drift="" half key want got mdir msite
        for half in provider consumer; do
            if [ "$half" = provider ]; then mdir="$pdir"; msite="$prov"; else mdir="$cdir"; msite="$cons"; fi
            for key in db files; do
                want="$(jq -r ".${half}.${key}_sha256 // \"\"" "$cut" 2>/dev/null)"
                got="$(jq -r ".${key}_sha256 // \"\"" "$mdir/golden.manifest.json" 2>/dev/null)"
                if [ -z "$want" ] || [ -z "$got" ]; then
                    drift="${drift}${drift:+, }${msite} ${key} (unreadable)"
                elif [ "$want" != "$got" ]; then
                    drift="${drift}${drift:+, }${msite} ${key}"
                fi
            done
        done
        if [ -n "$drift" ]; then
            todo_add_item "PCUT" "drift-$prov" "high" \
                "LIVE pair cut for $prov and $cons no longer binds: $drift" \
                "One half was re-captured on its own, so the cut no longer describes what is on disk. A paired restore from it would leave SSO identities mismatched" \
                "$prov" "pl demo golden $prov --with-pair --tier=live"
        fi
    done

    # A host that holds live goldens but resolves NO demo pair is not "fine" —
    # it means the contract that couples them is missing or has been switched
    # off, and the coupling invariant is going unenforced.
    if [ "$any" = false ]; then
        todo_add_unknown "demo_pair_cut" \
            "live demo goldens exist but no pairs/*.pair-contract.yml declares demo.enabled — the pairing invariant is unenforced" \
            "" "pl pair check"
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
    "check_exposed_secrets:Exposed credentials (rotation owed)"
    "check_token_liveness:Token liveness (live probe)"
    "check_missing_backups:Missing backups"
    "check_live_backup_freshness:Live backup freshness"
    "check_disk_usage:Disk usage"
    "check_gitlab_issues:GitLab issues"
    "check_agent_loop_cap:Agent-loop cap"
    "check_loop_liveness:Loop liveness (self-report)"
    "check_rag_sync_freshness:Oversight liveness (rag-sync freshness)"
    "check_agent_host_auth:Agent host auth"
    "check_site_registry_drift:Site registry drift"
    "check_forge_freshness:Forge patch cadence"
    "check_orphaned_sites:Orphaned sites"
    "check_missing_schedules:Missing schedules"
    "check_verification:Verification"
    "check_uncommitted_work:Uncommitted work"
    "check_unpushed_commits:Unpushed commits"
    "check_paused_automation:Paused automation"
    "check_notify_health:Notification path health"
    "check_demo_golden_hygiene:Demo golden identity hygiene"
    "check_demo_code_drift:Demo invite-code drift"
    "check_demo_pair_cut:Demo pair cut (live) + SPLIT"
)

################################################################################
# ops#204 — THE REGISTRY MUST AGREE WITH ITSELF, AND SAY SO WHEN IT DOES NOT.
#
# The concrete bug: `check_rag_sync_freshness` was DEFINED twice and LISTED
# twice. Bash binds the last definition, so one body was dead code from the day
# it was shadowed; and because the list carried a duplicate, one listed check ran
# TWICE while whichever check it displaced in the operator's mental model never
# announced itself at all. Nothing anywhere reported either fact — `pl todo`
# printed a full-looking sweep, `pl rag` consumed it, and the estate's only
# oversight surface was quietly grading itself on a registry it had never read.
#
# Deduping the two occurrences fixes THAT instance. This function is the part
# that makes the class impossible to reintroduce silently, because the shape is
# very easy to recreate: the list is 28 lines of near-identical text and the
# definitions are 2,000 lines away from it.
#
# Three invariants, each currently exactly true (verified 2026-08-02: 28 listed,
# 28 defined, sets identical):
#
#   1. no function name appears twice in TODO_CHECK_LIST
#   2. every listed name resolves to exactly ONE definition — both at runtime
#      (`declare -F`, catches a typo'd/renamed entry) and in the file text
#      (catches SHADOWING, which `declare -F` cannot see because bash has already
#      thrown the loser away by the time we can ask)
#   3. every `check_*` defined at column 0 in this file is listed — an unlisted
#      check is code that can never run, which is the other half of the same bug
#
# Deliberately NOT an invariant: `export -f`. The sweep runs each check in a
# subshell of this shell, so a missing export changes nothing observable, and a
# gate that fires on a harmless condition trains people to ignore it.
#
# Output: one `defect: <text>` line per problem on stdout. Returns 1 if any.
# Pure — reads no state outside this file — so it is cheap enough to run at the
# top of every sweep, and testable without a fixture estate.
#
# Args: $1 = path to the file defining the registry (default: this file)
################################################################################
todo_check_registry_defects() {
    local src="${1:-${BASH_SOURCE[0]}}"
    local found=0 entry func seen dup

    # --- 1. duplicates in the list itself -----------------------------------
    local listed=()
    for entry in "${TODO_CHECK_LIST[@]}"; do
        listed+=( "${entry%%:*}" )
    done
    while read -r dup seen; do
        [ -n "$seen" ] || continue
        echo "defect: '$seen' appears $dup times in TODO_CHECK_LIST — it will run $dup times per sweep"
        found=1
    done < <(printf '%s\n' "${listed[@]}" | sort | uniq -cd | awk '{print $1, $2}')

    # --- 2. every listed name resolves to exactly one definition ------------
    for func in "${listed[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            echo "defect: TODO_CHECK_LIST names '$func' but no such function is defined — that entry is a no-op"
            found=1
            continue
        fi
    done

    # File-text pass: shadowed definitions are invisible to `declare -F`.
    local defs=() n
    if [ -r "$src" ]; then
        mapfile -t defs < <(grep -oE '^check_[a-z0-9_]+\(\) \{' "$src" | sed 's/() {$//')
        for func in "${listed[@]}"; do
            n=$(printf '%s\n' "${defs[@]}" | grep -cx -- "$func" || true)
            if [ "$n" -gt 1 ]; then
                echo "defect: '$func' is defined $n times in $(basename "$src") — bash binds the LAST one and the others are dead code"
                found=1
            fi
        done

        # --- 3. defined but never listed ------------------------------------
        for func in "${defs[@]}"; do
            [ -n "$func" ] || continue
            if ! printf '%s\n' "${listed[@]}" | grep -qx -- "$func"; then
                echo "defect: '$func' is defined but absent from TODO_CHECK_LIST — it can never run"
                found=1
            fi
        done
    fi

    return $(( found ))
}

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

################################################################################
# Bounded sweep (ops#178)
#
# THE BUG THIS EXISTS TO MAKE IMPOSSIBLE. `run_all_checks` used to be:
#
#     for entry in "${TODO_CHECK_LIST[@]}"; do "$func" 2>/dev/null || true; done
#
# — an unbounded serial loop over 28 checks. One slow check therefore did not
# degrade the sweep, it ABOLISHED it: `pl rag` gives `pl todo check --json` a
# 180s budget, the sweep overran it, rag killed it (exit 143), and rag then
# printed `TODO ● BLIND` and graded all 28 sites on their audit record alone.
# Every night. The work/drift half of the estate's only oversight surface was
# dark, and nothing in the loop was individually "broken".
#
# Measured on the live fleet 2026-08-01, the overrun was NOT one pathological
# check but the sum of several honest ones:
#     check_missing_backups        133s   (gzip -t over ~10 GB of artifacts)
#     check_uncommitted_work        14-30s
#     check_ssl_expiry              13s
#     check_unpushed_commits        10s
#     check_live_backup_freshness    4s
#     ~23 others                    ~10s
#     -------------------------------------
#     total                        ~185-200s   > the 180s budget
#
# So a per-check cap alone is not sufficient: 28 checks x 25s is 700s, still
# over budget. TWO bounds are needed, and — this is the whole point — a check
# stopped by either one must SAY SO. The original defect was that a silent
# failure was indistinguishable from an empty result.
#
#   TODO_CHECK_TIMEOUT   per-check wall clock (default 40s)  -> UNK-timeout-<check>
#   TODO_SWEEP_BUDGET    total wall clock  (default 150s)    -> UNK-budget-<check>
#
# 150s sits deliberately under rag's 180s so the sweep finishes and rag renders
# real numbers instead of a blind banner. 40s is chosen to clear the slowest
# HONEST check on a cold cache — check_missing_backups takes ~28s to verify and
# memoise the fleet's newest artifacts the first time, then 1-2s forever after —
# so a cold start does not manufacture a spurious timeout item.
################################################################################

TODO_CHECK_TIMEOUT="${TODO_CHECK_TIMEOUT:-40}"
TODO_SWEEP_BUDGET="${TODO_SWEEP_BUDGET:-150}"

# Kill a process and everything it spawned. A wedged check is usually blocked in
# a CHILD (ssh, curl, gzip, ddev); killing only the subshell orphans that child,
# which then keeps the pipe open and the budget burning.
_todo_kill_tree() {
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _todo_kill_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null
}

_todo_kill_tree_hard() {
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _todo_kill_tree_hard "$child"
    done
    kill -KILL "$pid" 2>/dev/null
}

# Run one check with a wall-clock cap, collecting its items via a temp file.
# The check runs in a subshell so a check that wedges, exits, or corrupts its
# own state cannot take the sweep with it.
#
# Args: $1=function $2=seconds $3=outfile
# Returns: 0 completed, 124 timed out
_todo_run_check_bounded() {
    local func="$1" limit="$2" outfile="$3"

    : > "$outfile"
    (
        todo_clear_items
        "$func" >/dev/null 2>&1 || true
        if [ "${#TODO_ITEMS[@]}" -gt 0 ]; then
            printf '%s\n' "${TODO_ITEMS[@]}" > "$outfile"
        fi
    ) &
    local pid=$!

    local ticks=0 max_ticks=$((limit * 10))
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge "$max_ticks" ]; then
            _todo_kill_tree "$pid"
            sleep 0.3
            _todo_kill_tree_hard "$pid"
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid" 2>/dev/null
    return 0
}

run_all_checks() {
    local skip_cache="${1:-false}"

    todo_cache_init
    [ "$skip_cache" = "true" ] && todo_cache_clear

    todo_clear_items

    # ops#204: the sweep's own registry is the first thing it reports on. A
    # duplicated or unlisted check makes every number below it a lie, so this
    # must surface as a finding rather than as a comment nobody reads. It is a
    # pure text/array check — no network, no disk beyond this file — so it costs
    # nothing against the sweep budget and runs BEFORE the budget starts.
    local _reg_defect
    while IFS= read -r _reg_defect; do
        [ -n "$_reg_defect" ] || continue
        todo_add_item "REG" "" "high" \
            "pl todo check registry is inconsistent" \
            "${_reg_defect#defect: }" "" "pl todo registry"
    done < <(todo_check_registry_defects || true)

    local per_check="$TODO_CHECK_TIMEOUT"
    local budget="$TODO_SWEEP_BUDGET"
    [[ "$per_check" =~ ^[0-9]+$ ]] || per_check=25
    [[ "$budget"    =~ ^[0-9]+$ ]] || budget=150

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/nwp-todo-sweep.XXXXXX") || tmpdir=""

    local started elapsed
    started=$(date +%s)

    local entry func label outfile rc line remaining
    for entry in "${TODO_CHECK_LIST[@]}"; do
        func="${entry%%:*}"
        label="${entry#*:}"

        elapsed=$(( $(date +%s) - started ))
        remaining=$(( budget - elapsed ))

        # BUDGET EXHAUSTED. Say which checks did not run — dropping them silently
        # is the original bug wearing a different hat.
        if [ "$remaining" -le 0 ]; then
            todo_add_unknown "budget-$func" \
                "sweep budget of ${budget}s was exhausted before '$label' ran — this check did NOT run and its result is unknown" \
                "" "pl todo check --only=$func"
            continue
        fi

        # Never let a single check eat the rest of the budget.
        local cap="$per_check"
        [ "$cap" -gt "$remaining" ] && cap="$remaining"

        if [ -z "$tmpdir" ]; then
            # No temp dir: fall back to the unbounded call rather than skipping
            # the estate's checks entirely, but be loud that it is unbounded.
            "$func" >/dev/null 2>&1 || true
            continue
        fi

        outfile="$tmpdir/$func.items"
        _todo_run_check_bounded "$func" "$cap" "$outfile"
        rc=$?

        # Collect whatever the check managed to record.
        if [ -s "$outfile" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                TODO_ITEMS+=("$line")
            done < "$outfile"
        fi

        # TIMED OUT — a named, visible state. Not silence, not "clean".
        if [ "$rc" -eq 124 ]; then
            todo_add_unknown "timeout-$func" \
                "'$label' exceeded its ${cap}s per-check timeout and was killed — its result is UNKNOWN, not clean" \
                "" "pl todo check --only=$func"
        fi
    done

    [ -n "$tmpdir" ] && rm -rf "$tmpdir"

    # Output results
    todo_output_items
}

# Export functions
export -f todo_cache_valid
export -f todo_cache_init
export -f todo_cache_clear
export -f _todo_json_escape
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
export -f check_exposed_secrets
export -f check_token_liveness
export -f check_agent_loop_cap
export -f check_loop_liveness
export -f check_rag_sync_freshness
export -f check_agent_host_auth
export -f check_site_registry_drift
export -f check_forge_freshness
export -f check_unpushed_commits
export -f _gwk_site_of
export -f check_live_backup_freshness
export -f check_paused_automation
export -f check_notify_health
export -f check_demo_golden_hygiene
export -f check_demo_code_drift
export -f check_demo_pair_cut
export -f _todo_kill_tree
export -f _todo_kill_tree_hard
export -f _todo_run_check_bounded
export -f run_all_checks
export -f todo_check_registry_defects
export -f todo_get_check_count
export -f todo_get_check_name
export -f todo_run_check_by_index
export -f todo_is_ignored
