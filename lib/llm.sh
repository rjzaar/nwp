#!/usr/bin/env bash
# lib/llm.sh — one backend-switchable LLM contract for the podcast pipeline.
#
# Part of NWP (Narrow Way Project). Tracks nwp/ops#34; design in
#   ~/central/PODCAST-PIPELINE-PROPOSAL-2026-07-02.md §6 "AI handoff".
#
# Public contract:
#
#   llm_invoke <prompt-file> <output-file> \
#              [--context-dir DIR] [--expect yaml|json|md] [--log-dir DIR]
#
# Behaviour:
#   - LLM_BACKEND=claude (default): headless `claude -p` in tool-less print
#     mode. Context is pre-assembled into the prompt (no worktree, no
#     permissions). Model = ${PIPELINE_CLAUDE_MODEL:-<nwp.yml default_model>:-
#     claude-opus-4-8}.
#   - LLM_BACKEND=ollama: POST $OLLAMA_URL/api/chat (default localhost:11434 —
#     point it at the compute host directly, or open an SSH tunnel to it),
#     model gpt-oss-code. HEALTH-GATED: fails fast with a clear message if the
#     endpoint is unreachable (the compute host's ollama currently IS down), so
#     the pipeline degrades gracefully instead of hanging.
#   - LLM_BACKEND=echo / stub: test backends (no real spend). See below.
#
#   - Caller-side validation + retry: --expect runs a parse check
#     (yq/py-yaml for yaml, jq/py-json for json, non-empty for md). On failure
#     the validator stderr is appended to the prompt and the call is retried;
#     at most LLM_MAX_ATTEMPTS (default 3) attempts. Every attempt's rendered
#     prompt + raw output is archived to the caller's --log-dir (llm-log/).
#
#   - NEVER prints secrets. This layer reads no secret material.
#
# Test backends
#   LLM_BACKEND=echo  — echoes the assembled prompt back as the output (lets a
#                       caller confirm the prompt pack renders with sample
#                       placeholders).
#   LLM_BACKEND=stub  — returns canned per-attempt output from
#                       $LLM_STUB_DIR/attempt<N>.txt (N = attempt number). Used
#                       to unit-test the validate/retry loop: good→1 attempt,
#                       bad-then-good→2, always-bad→fail after 3.
#
# Env knobs:
#   LLM_BACKEND            claude (default) | ollama | echo | stub
#   LLM_MAX_ATTEMPTS       retry budget (default 3)
#   LLM_LOG_DIR            default --log-dir if the option is omitted
#   PIPELINE_CLAUDE_MODEL  override model for the claude backend
#   PIPELINE_CLAUDE_EXTRA_FLAGS  extra flags appended to `claude -p` (e.g.
#                                effort/thinking flags if the CLI grows them)
#   CLAUDE_BIN             claude binary (default "claude")
#   OLLAMA_URL             ollama base URL (default http://localhost:11434;
#                          set to the compute host, or SSH-tunnel to it)
#   OLLAMA_MODEL           default gpt-oss-code
#   OLLAMA_TIMEOUT         curl --max-time for the chat call (default 600)
#   LLM_STUB_DIR           canned-output dir for the stub backend

# Double-source guard.
if [[ "${_LLM_SH_LOADED:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
_LLM_SH_LOADED=1

# ── logging fallbacks (use NWP's print_* if already sourced) ───────────────
if ! declare -f print_error >/dev/null 2>&1; then
    print_error()   { printf 'ERROR: %s\n' "$*" >&2; }
    print_warning() { printf 'WARN:  %s\n' "$*" >&2; }
    print_info()    { printf 'INFO:  %s\n' "$*" >&2; }
    print_success() { printf 'OK:    %s\n' "$*" >&2; }
fi

LLM_MAX_ATTEMPTS="${LLM_MAX_ATTEMPTS:-3}"

# ── model resolution ───────────────────────────────────────────────────────
# Precedence: PIPELINE_CLAUDE_MODEL > nwp.yml settings.claude.default_model >
# claude-opus-4-8 (best-available default).
_llm_resolve_model() {
    if [[ -n "${PIPELINE_CLAUDE_MODEL:-}" ]]; then
        printf '%s' "$PIPELINE_CLAUDE_MODEL"
        return 0
    fi
    local cfg="${PROJECT_ROOT:-$HOME/nwp}/nwp.yml" m=""
    if [[ -f "$cfg" ]]; then
        m=$(awk '/^settings:/{f=1} f&&/claude:/{c=1} c&&/default_model:/{print $2; exit}' "$cfg" 2>/dev/null)
    fi
    printf '%s' "${m:-claude-opus-4-8}"
}

# ── prompt assembly ────────────────────────────────────────────────────────
# Build the effective prompt: the template, with any --context-dir contents
# substituted for the {{CONTEXT}} placeholder (or appended under a "## Context"
# heading when the placeholder is absent), plus any validator feedback from a
# previous attempt.
_llm_assemble_prompt() {
    local prompt_file="$1" context_dir="$2" feedback="$3" out="$4"
    local ctx="" body f
    if [[ -n "$context_dir" && -d "$context_dir" ]]; then
        while IFS= read -r -d '' f; do
            ctx+=$'\n=== '"${f#"${context_dir%/}"/}"$' ==='$'\n'
            ctx+="$(cat "$f")"$'\n'
        done < <(find "$context_dir" -type f -print0 2>/dev/null | sort -z)
    fi
    body="$(cat "$prompt_file")"
    if [[ "$body" == *"{{CONTEXT}}"* ]]; then
        printf '%s' "${body//\{\{CONTEXT\}\}/$ctx}" > "$out"
    else
        {
            printf '%s\n' "$body"
            if [[ -n "$ctx" ]]; then
                printf '\n## Context\n%s\n' "$ctx"
            fi
        } > "$out"
    fi
    if [[ -n "$feedback" ]]; then
        {
            printf '\n---\n'
            printf 'Your PREVIOUS attempt failed validation. Fix these errors and re-emit '
            printf 'the FULL corrected output (and nothing else):\n\n'
            printf '%s\n' "$feedback"
        } >> "$out"
    fi
}

# ── output cleanup ─────────────────────────────────────────────────────────
# LLMs frequently wrap YAML/JSON in a ``` fenced block. Extract the first
# fenced block if present so the written output is directly parseable
# (validate_catalog.py / jq / yq all expect raw payload).
_llm_strip_fences() {
    local in="$1" out="$2"
    if grep -qE '^[[:space:]]*```' "$in" 2>/dev/null; then
        awk '
            BEGIN { inb = 0 }
            /^[[:space:]]*```/ { if (inb) { exit } else { inb = 1; next } }
            inb { print }
        ' "$in" > "$out"
    else
        cp "$in" "$out"
    fi
}

# ── validation ─────────────────────────────────────────────────────────────
# Returns 0 if the candidate parses for the given --expect kind; writes a
# human-readable reason to stderr on failure (fed back into the retry prompt).
_llm_validate() {
    local file="$1" expect="$2"
    case "$expect" in
        yaml)
            if command -v yq >/dev/null 2>&1; then
                yq eval '.' "$file" >/dev/null
            else
                python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$file"
            fi
            ;;
        json)
            if command -v jq >/dev/null 2>&1; then
                jq empty "$file"
            else
                python3 -c 'import sys,json; json.load(open(sys.argv[1]))' "$file"
            fi
            ;;
        md|"")
            if grep -q '[^[:space:]]' "$file" 2>/dev/null; then
                return 0
            fi
            echo "output is empty" >&2
            return 1
            ;;
        *)
            echo "llm_invoke: unknown --expect kind: $expect" >&2
            return 2
            ;;
    esac
}

# ── backends ───────────────────────────────────────────────────────────────
# Each backend: $1 = effective-prompt file, $2 = raw-output file. Return 0 on
# a successful call (validation is separate).

_llm_call_claude() {
    local prompt_file="$1" raw="$2"
    local model bin
    model="$(_llm_resolve_model)"
    bin="${CLAUDE_BIN:-claude}"
    local -a flags=( -p --model "$model" --output-format text )
    # Extra flags (e.g. future --effort / thinking flags) are word-split on
    # purpose so callers can pass several.
    if [[ -n "${PIPELINE_CLAUDE_EXTRA_FLAGS:-}" ]]; then
        # shellcheck disable=SC2206
        flags+=( ${PIPELINE_CLAUDE_EXTRA_FLAGS} )
    fi
    "$bin" "${flags[@]}" "$(cat "$prompt_file")" > "$raw" 2>"${raw}.err"
}

# Probe ollama; echo the reachable base URL on success, non-zero on failure.
_llm_ollama_health() {
    local base
    for base in "${OLLAMA_URL:-http://localhost:11434}" "http://localhost:11434"; do
        if curl -sf --max-time 5 "${base}/api/tags" >/dev/null 2>&1; then
            printf '%s' "$base"
            return 0
        fi
    done
    return 1
}

_llm_call_ollama() {
    local prompt_file="$1" raw="$2" base model resp rc
    if ! base="$(_llm_ollama_health)"; then
        print_error "ollama backend unreachable (tried \$OLLAMA_URL + localhost:11434). Use LLM_BACKEND=claude."
        return 3
    fi
    model="${OLLAMA_MODEL:-gpt-oss-code}"
    resp=$(jq -n --arg model "$model" --rawfile content "$prompt_file" \
              '{model:$model, stream:false, messages:[{role:"user", content:$content}]}' \
           | curl -sf --max-time "${OLLAMA_TIMEOUT:-600}" \
                  -X POST "${base}/api/chat" \
                  -H 'Content-Type: application/json' -d @-)
    rc=$?
    if [[ $rc -ne 0 ]]; then
        print_error "ollama chat request failed (rc=$rc) against ${base}"
        return "$rc"
    fi
    printf '%s' "$resp" | jq -r '.message.content // .response // empty' > "$raw"
}

_llm_call_echo() {
    cat "$1" > "$2"
}

_llm_call_stub() {
    local raw="$2" n="${_LLM_ATTEMPT:-1}" f
    f="${LLM_STUB_DIR:?LLM_STUB_DIR required for stub backend}/attempt${n}.txt"
    if [[ ! -f "$f" ]]; then
        print_error "stub backend: canned output missing: $f"
        return 9
    fi
    cat "$f" > "$raw"
}

# ── logging ────────────────────────────────────────────────────────────────
_llm_log() {
    local log_dir="$1" attempt="$2" prompt_file="$3" raw="$4"
    [[ -z "$log_dir" ]] && return 0
    mkdir -p "$log_dir" 2>/dev/null || return 0
    cp "$prompt_file" "${log_dir%/}/attempt${attempt}.prompt.txt" 2>/dev/null
    cp "$raw"         "${log_dir%/}/attempt${attempt}.output.txt" 2>/dev/null
}

# ── public entry point ─────────────────────────────────────────────────────
llm_invoke() {
    local prompt_file="$1" out_file="$2"
    if [[ -z "$prompt_file" || -z "$out_file" ]]; then
        print_error "usage: llm_invoke <prompt-file> <output-file> [--context-dir DIR] [--expect yaml|json|md] [--log-dir DIR]"
        return 2
    fi
    shift 2
    local context_dir="" expect="" log_dir="${LLM_LOG_DIR:-}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --context-dir) context_dir="$2"; shift 2 ;;
            --expect)      expect="$2";      shift 2 ;;
            --log-dir)     log_dir="$2";     shift 2 ;;
            *) print_error "llm_invoke: unknown option: $1"; return 2 ;;
        esac
    done

    if [[ ! -f "$prompt_file" ]]; then
        print_error "llm_invoke: prompt file not found: $prompt_file"
        return 2
    fi

    local backend="${LLM_BACKEND:-claude}"

    # Health-gate ollama up-front so a down endpoint fails fast (before any
    # attempt) with a clear message, rather than burning the retry budget.
    if [[ "$backend" == "ollama" ]]; then
        if ! _llm_ollama_health >/dev/null; then
            print_error "LLM_BACKEND=ollama but the ollama host is DOWN (\$OLLAMA_URL and localhost:11434 both unreachable). Aborting fast — set LLM_BACKEND=claude."
            return 3
        fi
    fi

    local tmp feedback="" attempt rc=1 call_rc
    tmp="$(mktemp -d)"
    for (( attempt=1; attempt <= LLM_MAX_ATTEMPTS; attempt++ )); do
        export _LLM_ATTEMPT="$attempt"
        local eff="$tmp/a${attempt}.prompt" raw="$tmp/a${attempt}.raw"
        local cand="$tmp/a${attempt}.cand" verr="$tmp/a${attempt}.verr"

        _llm_assemble_prompt "$prompt_file" "$context_dir" "$feedback" "$eff"

        case "$backend" in
            claude) _llm_call_claude "$eff" "$raw" ;;
            ollama) _llm_call_ollama "$eff" "$raw" ;;
            echo)   _llm_call_echo   "$eff" "$raw" ;;
            stub)   _llm_call_stub   "$eff" "$raw" ;;
            *) print_error "unknown LLM_BACKEND: $backend"; rm -rf "$tmp"; unset _LLM_ATTEMPT; return 2 ;;
        esac
        call_rc=$?

        _llm_log "$log_dir" "$attempt" "$eff" "$raw"

        if [[ $call_rc -ne 0 ]]; then
            feedback="The backend invocation itself failed (rc=$call_rc). Re-emit the requested output."
            print_warning "attempt ${attempt}/${LLM_MAX_ATTEMPTS}: backend '${backend}' call failed (rc=$call_rc)"
            continue
        fi

        _llm_strip_fences "$raw" "$cand"

        if _llm_validate "$cand" "$expect" 2>"$verr"; then
            cp "$cand" "$out_file"
            print_success "llm_invoke ok on attempt ${attempt}/${LLM_MAX_ATTEMPTS} (backend=${backend}, expect=${expect:-none})"
            rc=0
            break
        fi

        feedback="$(cat "$verr")"
        print_warning "attempt ${attempt}/${LLM_MAX_ATTEMPTS}: ${expect:-output} validation failed: ${feedback}"
        if [[ -n "$log_dir" ]]; then
            cp "$verr" "${log_dir%/}/attempt${attempt}.verr.txt" 2>/dev/null
        fi
    done

    unset _LLM_ATTEMPT
    rm -rf "$tmp"

    if [[ $rc -ne 0 ]]; then
        print_error "llm_invoke FAILED after ${LLM_MAX_ATTEMPTS} attempts (backend=${backend}, expect=${expect:-none}); logs: ${log_dir:-<none>}"
    fi
    return $rc
}
