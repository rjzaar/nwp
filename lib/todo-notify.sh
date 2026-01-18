#!/bin/bash
################################################################################
# NWP Todo Notification Library
#
# Notification functions for the unified todo system
# Supports desktop notifications (notify-send) and email
# See docs/proposals/F12-todo-command.md for specification
################################################################################

# Get the directory where this script is located
TODO_NOTIFY_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TODO_NOTIFY_PROJECT_ROOT="${TODO_NOTIFY_PROJECT_ROOT:-$( cd "$TODO_NOTIFY_DIR/.." && pwd )}"

# Source UI library for colors (if available)
if [ -f "$TODO_NOTIFY_DIR/ui.sh" ]; then
    source "$TODO_NOTIFY_DIR/ui.sh"
fi

################################################################################
# Configuration Reading
################################################################################

# Get notification setting with default
# Args: $1=key_path $2=default
get_notify_setting() {
    local key_path="$1"
    local default="${2:-}"
    local config_file="${TODO_CONFIG_FILE:-$TODO_NOTIFY_PROJECT_ROOT/nwp.yml}"

    if [ ! -f "$config_file" ]; then
        config_file="$TODO_NOTIFY_PROJECT_ROOT/example.nwp.yml"
    fi

    local value=""
    if command -v yq &>/dev/null; then
        value=$(yq eval ".settings.todo.notifications.${key_path} // \"\"" "$config_file" 2>/dev/null | grep -v '^null$')
    fi

    [ -z "$value" ] && value="$default"
    echo "$value"
}

# Check if notifications are enabled
is_notify_enabled() {
    local enabled=$(get_notify_setting "enabled" "false")
    [ "$enabled" = "true" ] || [ "$enabled" = "yes" ] || [ "$enabled" = "1" ]
}

# Check if desktop notifications are enabled
is_desktop_notify_enabled() {
    is_notify_enabled || return 1
    local enabled=$(get_notify_setting "desktop.enabled" "false")
    [ "$enabled" = "true" ] || [ "$enabled" = "yes" ] || [ "$enabled" = "1" ]
}

# Check if email notifications are enabled
is_email_notify_enabled() {
    is_notify_enabled || return 1
    local enabled=$(get_notify_setting "email.enabled" "false")
    [ "$enabled" = "true" ] || [ "$enabled" = "yes" ] || [ "$enabled" = "1" ]
}

################################################################################
# Desktop Notifications
################################################################################

# Send a desktop notification using notify-send (Linux) or osascript (macOS)
# Args: $1=title $2=message $3=urgency (low/normal/critical)
notify_desktop() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"

    # Check if desktop notifications are enabled
    is_desktop_notify_enabled || return 0

    # Check minimum priority
    local min_priority=$(get_notify_setting "desktop.min_priority" "high")
    case "$min_priority" in
        high)
            [ "$urgency" != "critical" ] && return 0
            ;;
        medium)
            [ "$urgency" = "low" ] && return 0
            ;;
        # low: show all
    esac

    # Linux (notify-send)
    if command -v notify-send &>/dev/null; then
        notify-send -u "$urgency" "$title" "$message" 2>/dev/null
        return $?
    fi

    # macOS (osascript)
    if command -v osascript &>/dev/null; then
        osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null
        return $?
    fi

    # No notification system available
    return 1
}

################################################################################
# Email Notifications
################################################################################

# Send an email notification
# Args: $1=subject $2=body
notify_email() {
    local subject="$1"
    local body="$2"

    # Check if email notifications are enabled
    is_email_notify_enabled || return 0

    # Get recipient
    local recipient=$(get_notify_setting "email.recipient" "")
    if [ -z "$recipient" ]; then
        echo "Warning: No email recipient configured" >&2
        return 1
    fi

    # Get SMTP profile
    local smtp_profile=$(get_notify_setting "email.smtp_profile" "default")
    local secrets_file="$TODO_NOTIFY_PROJECT_ROOT/.secrets.yml"

    # Try to get SMTP settings
    local smtp_host="" smtp_port="" smtp_user="" smtp_pass=""
    if [ -f "$secrets_file" ] && command -v yq &>/dev/null; then
        smtp_host=$(yq eval ".smtp.${smtp_profile}.host // \"\"" "$secrets_file" 2>/dev/null | grep -v '^null$')
        smtp_port=$(yq eval ".smtp.${smtp_profile}.port // 587" "$secrets_file" 2>/dev/null | grep -v '^null$')
        smtp_user=$(yq eval ".smtp.${smtp_profile}.user // \"\"" "$secrets_file" 2>/dev/null | grep -v '^null$')
        smtp_pass=$(yq eval ".smtp.${smtp_profile}.password // \"\"" "$secrets_file" 2>/dev/null | grep -v '^null$')
    fi

    # Try different email methods

    # Method 1: msmtp (recommended)
    if command -v msmtp &>/dev/null; then
        echo -e "Subject: $subject\nTo: $recipient\n\n$body" | msmtp "$recipient" 2>/dev/null
        return $?
    fi

    # Method 2: sendmail
    if command -v sendmail &>/dev/null; then
        echo -e "Subject: $subject\nTo: $recipient\n\n$body" | sendmail "$recipient" 2>/dev/null
        return $?
    fi

    # Method 3: mail command
    if command -v mail &>/dev/null; then
        echo "$body" | mail -s "$subject" "$recipient" 2>/dev/null
        return $?
    fi

    # Method 4: curl with SMTP (if we have credentials)
    if command -v curl &>/dev/null && [ -n "$smtp_host" ] && [ -n "$smtp_user" ] && [ -n "$smtp_pass" ]; then
        local from="${smtp_user}"
        curl --ssl-reqd \
            --url "smtp://${smtp_host}:${smtp_port}" \
            --user "${smtp_user}:${smtp_pass}" \
            --mail-from "$from" \
            --mail-rcpt "$recipient" \
            -T <(echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$body") \
            2>/dev/null
        return $?
    fi

    echo "Warning: No email method available" >&2
    return 1
}

################################################################################
# Notification Triggers
################################################################################

# Notify about new high priority items
# Args: $1=count of high priority items
notify_new_high_priority() {
    local count="$1"

    [ "$count" -eq 0 ] && return 0

    local on_new_high=$(get_notify_setting "on_new_high" "true")
    [ "$on_new_high" != "true" ] && return 0

    local title="NWP Todo Alert"
    local message="$count high priority item(s) need attention"

    notify_desktop "$title" "$message" "critical"
    notify_email "[NWP Alert] $message" "You have $count high priority todo items that require attention within 24 hours.\n\nRun 'pl todo' to view and manage these items."
}

# Send scheduled run summary
# Args: $1=json_results
notify_schedule_run() {
    local json_results="$1"

    local on_schedule=$(get_notify_setting "on_schedule_run" "true")
    [ "$on_schedule" != "true" ] && return 0

    # Parse results to count priorities
    local high_count=0 medium_count=0 low_count=0

    while IFS= read -r line; do
        local priority=$(echo "$line" | grep -o '"priority":"[^"]*"' | cut -d'"' -f4)
        case "$priority" in
            high) ((high_count++)) ;;
            medium) ((medium_count++)) ;;
            low) ((low_count++)) ;;
        esac
    done <<< "$json_results"

    local total=$((high_count + medium_count + low_count))

    # Only notify if there are items (especially high priority)
    if [ "$high_count" -gt 0 ]; then
        notify_desktop "NWP Todo Check" "$high_count high priority items" "critical"
    fi

    # Email summary
    if is_email_notify_enabled && [ "$total" -gt 0 ]; then
        local body="NWP Todo Daily Summary\n"
        body="${body}========================\n\n"
        body="${body}Total items: $total\n"
        body="${body}  High priority: $high_count\n"
        body="${body}  Medium priority: $medium_count\n"
        body="${body}  Low priority: $low_count\n\n"
        body="${body}Run 'pl todo' to view and manage these items.\n"

        notify_email "[NWP] Daily Todo Summary: $total items" "$body"
    fi
}

# Send daily digest
send_daily_digest() {
    local daily_digest=$(get_notify_setting "daily_digest" "false")
    [ "$daily_digest" != "true" ] && return 0

    # Check if it's the right time
    local digest_time=$(get_notify_setting "digest_time" "08:00")
    local current_time=$(date +%H:%M)

    # Allow 5 minute window around digest time
    local digest_hour=$(echo "$digest_time" | cut -d: -f1)
    local digest_min=$(echo "$digest_time" | cut -d: -f2)
    local current_hour=$(echo "$current_time" | cut -d: -f1)
    local current_min=$(echo "$current_time" | cut -d: -f2)

    # Simple time comparison (within same hour and within 5 min of target)
    if [ "$current_hour" = "$digest_hour" ]; then
        local diff=$((current_min - digest_min))
        [ "$diff" -lt 0 ] && diff=$((-diff))
        if [ "$diff" -le 5 ]; then
            # Run checks and send summary
            if command -v run_all_checks &>/dev/null; then
                local results=$(run_all_checks)
                notify_schedule_run "$results"
            fi
        fi
    fi
}

################################################################################
# Scheduled Run Handler
################################################################################

# Main function for scheduled (cron) runs
# Called by: pl todo check (when run from cron)
todo_scheduled_run() {
    # Check if notifications are enabled
    is_notify_enabled || return 0

    # Run all checks
    local results=""
    if command -v run_all_checks &>/dev/null; then
        results=$(run_all_checks)
    else
        echo "Error: run_all_checks not available" >&2
        return 1
    fi

    # Count high priority items
    local high_count=0
    while IFS= read -r line; do
        local priority=$(echo "$line" | grep -o '"priority":"high"')
        [ -n "$priority" ] && ((high_count++))
    done <<< "$results"

    # Notify about high priority items
    if [ "$high_count" -gt 0 ]; then
        notify_new_high_priority "$high_count"
    fi

    # Send schedule run summary
    notify_schedule_run "$results"

    # Log results
    local log_file=$(get_notify_setting "schedule.log_file" "/var/log/nwp/todo.log")
    local log_dir=$(dirname "$log_file")

    if [ -d "$log_dir" ] || mkdir -p "$log_dir" 2>/dev/null; then
        local total=$(echo "$results" | grep -c '"id":' 2>/dev/null || echo "0")
        echo "[$(date -Iseconds)] Checked: Total=$total, High=$high_count" >> "$log_file"
    fi

    return 0
}

################################################################################
# Export Functions
################################################################################

export -f get_notify_setting
export -f is_notify_enabled
export -f is_desktop_notify_enabled
export -f is_email_notify_enabled
export -f notify_desktop
export -f notify_email
export -f notify_new_high_priority
export -f notify_schedule_run
export -f send_daily_digest
export -f todo_scheduled_run
