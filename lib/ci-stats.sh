#!/bin/bash

################################################################################
# NWP CI Stats Library
#
# Adaptive thresholds via rolling-window p95. Replaces hand-picked numeric
# limits (lint timeouts, artifact expiry, etc.) with measurements derived
# from recent job history.
#
# Per F36 §6.5. Two-layer enforcement is intended:
#   1. Soft assertion (this library): warn/fail when value > 1.5 × p95
#   2. Hard ceiling (GitLab `timeout:` / shell wrapper): generous, never tuned
#
# Source as a library:  source "$PROJECT_ROOT/lib/ci-stats.sh"
# Or invoke as a CLI:   ./lib/ci-stats.sh {record|p95|check|band|n} <metric> [args]
#
# Storage model:
#   - .ci-stats/bootstrap.yml      — hardcoded cold-start thresholds (on main)
#   - .ci-stats/<metric>.tsv       — runtime samples (on `stats` branch only;
#                                    gitignored on main to avoid noise)
#
# See docs/reference/ci-stats.md for the full operational model, including
# how runtime stats persist to the `stats` branch.
#
# Dependencies: lib/ui.sh (for print_error / print_warning — soft dep with
# fallback for CLI use without sourcing common.sh)
################################################################################

# Soft dependency on ui.sh — source if not already loaded, fall back to
# plain stderr writers if ui.sh is missing (e.g. tests running in isolation).
if ! type -t print_error >/dev/null 2>&1; then
    _ci_stats_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$_ci_stats_lib_dir/ui.sh" ]]; then
        # shellcheck source=ui.sh
        source "$_ci_stats_lib_dir/ui.sh"
    else
        print_error()   { echo "ERROR: $*" >&2; }
        print_warning() { echo "WARN: $*" >&2; }
    fi
    unset _ci_stats_lib_dir
fi

# Tunables (overridable via env)
: "${CI_STATS_WINDOW:=20}"             # rolling window size
: "${CI_STATS_REGRESSION_FACTOR:=1.5}" # soft threshold = p95 * this
: "${CI_STATS_BOOTSTRAP_MIN:=5}"       # need this many samples before adaptive
: "${CI_STATS_OUTLIER_FACTOR:=3}"      # trim sample if > this × median

################################################################################
# Internal helpers
################################################################################

# Validate metric name — filesystem-safe, no shell metacharacters
_ci_stats_validate_metric() {
    local metric="$1"
    if [[ -z "$metric" ]]; then
        print_error "ci-stats: metric name required"
        return 1
    fi
    if [[ ! "$metric" =~ ^[a-z0-9._-]+$ ]]; then
        print_error "ci-stats: invalid metric name (must match [a-z0-9._-]+): $metric"
        return 1
    fi
    return 0
}

# Resolve stats directory. CI_STATS_DIR env var wins; otherwise look for
# .ci-stats/ relative to the project root.
_ci_stats_dir() {
    if [[ -n "${CI_STATS_DIR:-}" ]]; then
        echo "$CI_STATS_DIR"
        return 0
    fi
    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # lib/ is one level below project root
    echo "${self_dir%/lib}/.ci-stats"
}

# TSV file path for a metric
_ci_stats_file() {
    local metric="$1"
    echo "$(_ci_stats_dir)/${metric}.tsv"
}

# Trim a TSV to last $CI_STATS_WINDOW successful samples.
# (Failures and skips are preserved as audit trail but not counted toward p95.)
_ci_stats_trim() {
    local file="$1"
    local window="${CI_STATS_WINDOW:-20}"
    [[ -f "$file" ]] || return 0

    local tmp
    tmp=$(mktemp)
    # Keep up to $window most-recent successes, then append any failures/skips
    # from the same window (so we don't lose audit history).
    tail -n "$((window * 2))" "$file" \
        | awk -F'\t' -v w="$window" '
            $4 == "success" { succ[++sn] = $0 }
            $4 != "success" { other[++on] = $0 }
            END {
                start = sn - w + 1
                if (start < 1) start = 1
                for (i = start; i <= sn; i++) print succ[i]
                # Preserve same-window failures/skips for audit
                for (i = 1; i <= on; i++) print other[i]
            }
        ' \
        | sort \
        > "$tmp"
    mv "$tmp" "$file"
}

# Read bootstrap threshold for a metric from .ci-stats/bootstrap.yml
# Echoes the value, or empty string if no config / no entry.
# Uses yq when present; falls back to a pure-awk parse of the flat
# `metrics: { <name>: <value> }` structure so this works in minimal CI
# images (the test:unit job ships only bats+git, no yq).
_ci_stats_bootstrap() {
    local metric="$1"
    local config value
    config="$(_ci_stats_dir)/bootstrap.yml"
    [[ -f "$config" ]] || { echo ""; return 0; }

    if command -v yq >/dev/null 2>&1; then
        # yq returns "null" for missing keys; normalize to empty
        value=$(yq eval ".metrics.\"${metric}\" // \"\"" "$config" 2>/dev/null)
        [[ "$value" == "null" ]] && value=""
        echo "$value"
        return 0
    fi

    # Fallback: parse the `metrics:` block without yq. Keys live one level
    # under `metrics:` as `  <name>: <value>` (name optionally quoted; names
    # may contain dots). Match by exact key, echo the trimmed scalar value.
    value=$(awk -v want="$metric" '
        /^[^[:space:]#]/ { inm = ($0 ~ /^metrics:[[:space:]]*$/) ? 1 : 0; next }
        inm && /^[[:space:]]+[^[:space:]#]/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            key = line; sub(/:.*/, "", key)
            gsub(/^["\x27]|["\x27]$/, "", key)        # strip surrounding quotes
            if (key == want) {
                val = line; sub(/^[^:]*:[[:space:]]*/, "", val)
                gsub(/[[:space:]]+$/, "", val)
                gsub(/^["\x27]|["\x27]$/, "", val)
                print val; exit
            }
        }
    ' "$config")
    echo "$value"
}

################################################################################
# Public API
################################################################################

# Record a sample.
# Usage: ci_stats_record <metric> <value> [outcome]
#   metric:  [a-z0-9._-]+ — e.g. ci.lint-bash.seconds
#   value:   numeric (int or decimal)
#   outcome: success|failure|skip|bootstrap (default: success)
# Returns: 0 on success, 1 on validation error.
ci_stats_record() {
    local metric="$1"
    local value="$2"
    local outcome="${3:-success}"

    _ci_stats_validate_metric "$metric" || return 1

    if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        print_error "ci-stats: value must be numeric: $value"
        return 1
    fi

    case "$outcome" in
        success|failure|skip|bootstrap) ;;
        *)
            print_error "ci-stats: invalid outcome (must be success|failure|skip|bootstrap): $outcome"
            return 1
            ;;
    esac

    local timestamp commit file dir
    timestamp=$(date -u +%FT%TZ)
    commit="${CI_COMMIT_SHA:-${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}}"
    file=$(_ci_stats_file "$metric")
    dir=$(dirname "$file")
    mkdir -p "$dir"

    printf '%s\t%s\t%s\t%s\n' "$timestamp" "$commit" "$value" "$outcome" >> "$file"
    _ci_stats_trim "$file"
    return 0
}

# Count successful samples for a metric.
# Usage: ci_stats_n <metric>
ci_stats_n() {
    local metric="$1"
    _ci_stats_validate_metric "$metric" || return 1

    local file
    file=$(_ci_stats_file "$metric")
    [[ -f "$file" ]] || { echo 0; return 0; }

    awk -F'\t' '$4 == "success"' "$file" | wc -l | tr -d ' '
}

# Compute p95 from successful samples (with outlier trimming).
# Usage: ci_stats_p95 <metric>
# Echoes p95 value, or empty string if no samples.
ci_stats_p95() {
    local metric="$1"
    _ci_stats_validate_metric "$metric" || return 1

    local file
    file=$(_ci_stats_file "$metric")
    [[ -f "$file" ]] || { echo ""; return 0; }

    awk -F'\t' -v outlier="${CI_STATS_OUTLIER_FACTOR:-3}" '
        $4 == "success" { values[NR] = $3 + 0; n++ }
        END {
            if (n == 0) { print ""; exit }
            # Sort values (simple bubble — n is small, max 20)
            for (i = 1; i <= n; i++) sorted[i] = values[i]
            for (i = 1; i <= n; i++) {
                for (j = i+1; j <= n; j++) {
                    if (sorted[i] > sorted[j]) {
                        t = sorted[i]; sorted[i] = sorted[j]; sorted[j] = t
                    }
                }
            }
            # Trim outliers: if max > outlier × median, drop the max
            median_idx = int((n + 1) / 2)
            median = sorted[median_idx]
            if (n > 3 && sorted[n] > outlier * median) {
                n = n - 1
            }
            if (n == 0) { print ""; exit }
            # p95 index (1-based, rounded), clamp
            idx = int(n * 0.95 + 0.5)
            if (idx < 1) idx = 1
            if (idx > n) idx = n
            printf "%g", sorted[idx]
        }
    ' "$file"
}

# Echo current operating band for a metric: "<low> <high>".
# low is always 0; high is the soft-threshold (p95 × factor, or bootstrap).
# Usage: ci_stats_band <metric>
ci_stats_band() {
    local metric="$1"
    _ci_stats_validate_metric "$metric" || return 1

    local n p95 high
    local factor="${CI_STATS_REGRESSION_FACTOR:-1.5}"

    n=$(ci_stats_n "$metric")
    if (( n < ${CI_STATS_BOOTSTRAP_MIN:-5} )); then
        high=$(_ci_stats_bootstrap "$metric")
        [[ -z "$high" ]] && high="(none)"
    else
        p95=$(ci_stats_p95 "$metric")
        high=$(awk -v p="$p95" -v f="$factor" 'BEGIN { printf "%g", p * f }')
    fi

    echo "0 $high"
}

# Check whether a value falls within the current operating band.
# Usage: ci_stats_check <metric> <value> [warn|fail]
#   Default mode is `warn` (prints warning, returns 0).
#   `fail` mode prints error and returns 1 on regression.
# Returns: 0 if in-band OR in bootstrap mode without config OR mode=warn
#          1 only when mode=fail AND value exceeds threshold
ci_stats_check() {
    local metric="$1"
    local value="$2"
    local mode="${3:-warn}"

    _ci_stats_validate_metric "$metric" || return 1

    if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        print_error "ci-stats: value must be numeric: $value"
        return 1
    fi

    case "$mode" in
        warn|fail) ;;
        *) print_error "ci-stats: invalid mode (must be warn|fail): $mode"; return 1 ;;
    esac

    local factor="${CI_STATS_REGRESSION_FACTOR:-1.5}"
    local n p95 threshold source

    n=$(ci_stats_n "$metric")

    if (( n < ${CI_STATS_BOOTSTRAP_MIN:-5} )); then
        threshold=$(_ci_stats_bootstrap "$metric")
        source="bootstrap (n=$n)"
        if [[ -z "$threshold" ]]; then
            print_warning "ci-stats: $metric: no history (n=$n) and no bootstrap threshold; allowing through"
            return 0
        fi
    else
        p95=$(ci_stats_p95 "$metric")
        threshold=$(awk -v p="$p95" -v f="$factor" 'BEGIN { printf "%g", p * f }')
        source="adaptive (p95=$p95, n=$n)"
    fi

    local in_band
    in_band=$(awk -v v="$value" -v t="$threshold" 'BEGIN { print (v <= t) ? 1 : 0 }')

    if [[ "$in_band" == "1" ]]; then
        return 0
    fi

    # Regression
    case "$mode" in
        warn)
            print_warning "ci-stats: $metric=$value exceeds threshold $threshold [$source]"
            return 0
            ;;
        fail)
            print_error "ci-stats: $metric=$value exceeds threshold $threshold [$source]"
            return 1
            ;;
    esac
}

################################################################################
# CLI entry — only runs when invoked directly, not when sourced
################################################################################

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail

    cmd="${1:-help}"
    shift || true

    case "$cmd" in
        record)  ci_stats_record  "$@" ;;
        p95)     ci_stats_p95     "$@" ;;
        n)       ci_stats_n       "$@" ;;
        band)    ci_stats_band    "$@" ;;
        check)   ci_stats_check   "$@" ;;
        help|--help|-h)
            cat <<'EOF'
ci-stats.sh — Adaptive thresholds via rolling-window p95.

USAGE:
    ci-stats.sh record <metric> <value> [outcome]
        Append a sample. outcome: success|failure|skip|bootstrap (default: success).

    ci-stats.sh p95 <metric>
        Echo p95 of last 20 successful samples (empty if none).

    ci-stats.sh n <metric>
        Echo successful-sample count.

    ci-stats.sh band <metric>
        Echo "low high" operating band (low=0; high=p95×factor or bootstrap).

    ci-stats.sh check <metric> <value> [warn|fail]
        Check whether value is in-band. warn (default) returns 0 with warning
        on regression; fail returns 1 on regression.

ENV TUNABLES:
    CI_STATS_DIR              Override stats directory (default: <repo>/.ci-stats)
    CI_STATS_WINDOW           Rolling window size (default: 20)
    CI_STATS_REGRESSION_FACTOR Soft threshold = p95 × this (default: 1.5)
    CI_STATS_BOOTSTRAP_MIN    Min samples before adaptive (default: 5)
    CI_STATS_OUTLIER_FACTOR   Drop max sample if > this × median (default: 3)

See docs/reference/ci-stats.md for the full operational model.
EOF
            ;;
        *)
            print_error "ci-stats: unknown subcommand: $cmd"
            echo "Run 'ci-stats.sh help' for usage." >&2
            exit 1
            ;;
    esac
fi
