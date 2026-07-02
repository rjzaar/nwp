#!/bin/bash
#
# mons-setup.sh — one-shot, idempotent setup the OPERATOR runs ON mons
#                 (role: ver, the offline verifier host) to enable AI-free
#                 `nwp`/`pl` use with error reporting routed to the ops queue
#                 via the `verifier-say` mechanism.
#
# It is deliberately conservative and fail-closed:
#   - It NEVER reads, writes, prints, or transmits the real token value. It only
#     checks that the token file exists with 0600 perms, and tells you how to
#     place it via your own secret store if it is missing.
#   - It only reaches the network when you pass --smoke (and even then it posts a
#     single, clearly-labelled TEST issue). The default run is offline.
#   - It appends the verification stanza to nwp.yml ONLY after you confirm.
#   - Re-running it is safe (idempotent): existing symlinks/env/stanza are
#     detected and left alone.
#
# Usage (run from inside the nwp checkout on mons):
#   ./scripts/mons-setup.sh                    # set up, no network
#   ./scripts/mons-setup.sh --smoke            # also post a labelled TEST issue
#   NWP_GITLAB_HOST=git.example NWP_OPS_LOG_PROJECT=ops/verifier-log \
#     ./scripts/mons-setup.sh                  # supply the two identifiers
#   ./scripts/mons-setup.sh --help
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

SAY_SRC="$SCRIPT_DIR/mons-say.sh"
STANZA_SRC="$PROJECT_ROOT/docs/guides/mons-verification.stanza.yml"

BIN_DIR="$HOME/bin"
SAY_LINK="$BIN_DIR/verifier-say"
CONFIG_DIR="$HOME/.config"
TOKEN_FILE="${VERIFIER_LOG_TOKEN_FILE:-$CONFIG_DIR/verifier-log.token}"
ENV_FILE="$CONFIG_DIR/nwp-verifier.env"

# Non-secret identifiers. Pre-fill from the environment if already exported.
GITLAB_HOST="${NWP_GITLAB_HOST:-}"
OPS_LOG_PROJECT="${NWP_OPS_LOG_PROJECT:-}"

SMOKE=0

# ── tiny UI helpers (self-contained; no repo lib needed on mons) ─────────────
c_ok(){    printf '  \033[32m✓\033[0m %s\n' "$*"; }
c_warn(){  printf '  \033[33m!\033[0m %s\n' "$*"; }
c_err(){   printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
c_info(){  printf '    %s\n' "$*"; }
c_head(){  printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die(){ c_err "$*"; exit 1; }

usage(){ sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --smoke) SMOKE=1; shift ;;
        --gitlab-host) GITLAB_HOST="$2"; shift 2 ;;
        --gitlab-host=*) GITLAB_HOST="${1#*=}"; shift ;;
        --ops-project) OPS_LOG_PROJECT="$2"; shift 2 ;;
        --ops-project=*) OPS_LOG_PROJECT="${1#*=}"; shift ;;
        -h|--help) usage 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# ── 1. curl ─────────────────────────────────────────────────────────────────
c_head "1. curl"
if command -v curl >/dev/null 2>&1; then
    c_ok "curl present: $(command -v curl)"
else
    c_err "curl not found — verifier-say needs it."
    c_info "Install it, e.g.:  sudo apt install curl"
    die "cannot continue without curl"
fi

# ── 2. token file (existence + perms only; NEVER its value) ─────────────────
c_head "2. verifier-log token"
mkdir -p "$CONFIG_DIR"
if [ -r "$TOKEN_FILE" ]; then
    perms=$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || stat -f '%Lp' "$TOKEN_FILE" 2>/dev/null || echo '?')
    if [ "$perms" = "600" ]; then
        c_ok "token present with 0600 perms: $TOKEN_FILE"
    else
        c_warn "token present but perms are $perms (want 600). Tightening…"
        chmod 600 "$TOKEN_FILE" && c_ok "chmod 600 applied"
    fi
else
    c_warn "token file absent: $TOKEN_FILE"
    c_info "Place it from YOUR secret store (this script will not read/write the value)."
    c_info "The project-scoped PAT for ops/verifier-log goes there, 0600, e.g.:"
    c_info "    umask 077 && printf '%s\\n' '<glpat-…>' > \"$TOKEN_FILE\""
    c_info "    chmod 600 \"$TOKEN_FILE\""
    c_info "Then re-run this script."
fi

# ── 3. env file (non-secret identifiers) ────────────────────────────────────
c_head "3. environment file"
[ -n "$GITLAB_HOST" ]     || c_warn "NWP_GITLAB_HOST not supplied (env or --gitlab-host)."
[ -n "$OPS_LOG_PROJECT" ] || c_warn "NWP_OPS_LOG_PROJECT not supplied (env or --ops-project)."
: "${GITLAB_HOST:=<gitlab-host>}"
: "${OPS_LOG_PROJECT:=ops/verifier-log}"

# Write only if changed, to keep the run idempotent and quiet.
new_env="$(cat <<EOF
# nwp-verifier.env — non-secret identifiers for verifier-say on mons.
# Written by scripts/mons-setup.sh. Source it from your shell rc:
#   [ -f "$ENV_FILE" ] && . "$ENV_FILE"
# The token itself lives separately in $TOKEN_FILE (never here).
export NWP_GITLAB_HOST="$GITLAB_HOST"
export NWP_OPS_LOG_PROJECT="$OPS_LOG_PROJECT"
EOF
)"
if [ -f "$ENV_FILE" ] && [ "$(cat "$ENV_FILE")" = "$new_env" ]; then
    c_ok "env file already current: $ENV_FILE"
else
    printf '%s\n' "$new_env" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    c_ok "wrote $ENV_FILE"
fi
c_info "NWP_GITLAB_HOST=$GITLAB_HOST   NWP_OPS_LOG_PROJECT=$OPS_LOG_PROJECT"
case "$GITLAB_HOST" in *'<'*'>'*) c_warn "GITLAB_HOST is still a placeholder — set the real host before posting.";; esac
# Ensure the env file is sourced by the login shell (idempotent).
RC="$HOME/.bashrc"
SRC_LINE="[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\""
if [ -f "$RC" ] && grep -Fq "$ENV_FILE" "$RC"; then
    c_ok "$RC already sources the env file"
else
    printf '%s\n' "$SRC_LINE" >> "$RC"
    c_ok "added source line to $RC (open a new shell or: . \"$ENV_FILE\")"
fi

# ── 4. verifier-say on PATH ─────────────────────────────────────────────────
c_head "4. verifier-say on PATH"
[ -f "$SAY_SRC" ] || die "helper not found in checkout: $SAY_SRC"
mkdir -p "$BIN_DIR"
if [ -L "$SAY_LINK" ] && [ "$(readlink "$SAY_LINK")" = "$SAY_SRC" ]; then
    c_ok "symlink already points at the checkout: $SAY_LINK"
else
    ln -sfn "$SAY_SRC" "$SAY_LINK"
    c_ok "linked $SAY_LINK -> $SAY_SRC"
fi
chmod +x "$SAY_SRC" 2>/dev/null || true
if printf '%s' "$PATH" | tr ':' '\n' | grep -Fxq "$BIN_DIR"; then
    c_ok "$BIN_DIR is on PATH"
else
    c_warn "$BIN_DIR is NOT on PATH yet."
    c_info "Add it:  echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> \"$RC\" && . \"$RC\""
fi

# ── 5. append verification stanza to nwp.yml (on confirm) ───────────────────
c_head "5. nwp.yml verification stanza"
NWP_YML="$PROJECT_ROOT/nwp.yml"
[ -f "$STANZA_SRC" ] || die "stanza source missing: $STANZA_SRC"
if [ ! -f "$NWP_YML" ]; then
    c_warn "no nwp.yml at $NWP_YML — skipping (create your site config first)."
elif grep -Eq '^[[:space:]]*via:[[:space:]]*verifier-say' "$NWP_YML"; then
    c_ok "nwp.yml already has 'via: verifier-say' — leaving it alone."
elif grep -Eq '^[[:space:]]*verification:' "$NWP_YML"; then
    c_warn "nwp.yml already has a 'verification:' block."
    c_info "Not editing it automatically. Merge the 'error_reporting:' keys from:"
    c_info "    $STANZA_SRC"
else
    printf '    Append the verification stanza to %s now? [y/N] ' "$NWP_YML"
    read -r reply || reply="n"
    case "$reply" in
        [Yy]*)
            {
                printf '\n# --- appended by scripts/mons-setup.sh (%s) ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                # Emit only the YAML body of the stanza (skip its leading comment header).
                sed -n '/^  # === VERIFICATION SYSTEM ===/,$p' "$STANZA_SRC"
            } >> "$NWP_YML"
            c_ok "appended stanza to $NWP_YML (still ships consent OFF / via commented)"
            c_info "To activate: uncomment 'via: verifier-say' (+ 'auto_post: true' on headless)."
            ;;
        *) c_info "skipped. You can paste it yourself from $STANZA_SRC" ;;
    esac
fi

# ── 6. smoke test ───────────────────────────────────────────────────────────
c_head "6. smoke test"
if [ "$SMOKE" -eq 1 ]; then
    if [ ! -r "$TOKEN_FILE" ]; then
        die "cannot smoke-test: token file missing (see step 2)."
    fi
    case "$GITLAB_HOST" in *'<'*'>'*) die "cannot smoke-test: NWP_GITLAB_HOST is still a placeholder.";; esac
    c_info "posting a clearly-labelled TEST issue to $OPS_LOG_PROJECT …"
    NWP_GITLAB_HOST="$GITLAB_HOST" NWP_OPS_LOG_PROJECT="$OPS_LOG_PROJECT" \
        "$SAY_LINK" "TEST: mons-setup smoke test — safe to close ($(hostname) $(date -u +%FT%TZ))" \
        && c_ok "smoke post succeeded — check $OPS_LOG_PROJECT and close the issue." \
        || die "smoke post FAILED — check token, host, and network."
else
    c_info "offline check only (pass --smoke to post a labelled TEST issue)."
    # Don't run verifier-say here: it checks the token file before printing usage,
    # so a bare invocation would fail when the token is (legitimately) absent.
    # An executable, resolvable link is the offline proof the helper is wired up.
    if [ -x "$SAY_LINK" ] && [ -e "$SAY_LINK" ]; then
        c_ok "verifier-say is executable on PATH ($SAY_LINK)."
    else
        c_warn "verifier-say link is not executable/resolvable — re-check step 4."
    fi
fi

c_head "done"
c_info "Next: enable reporting in nwp.yml (step 5) or 'export NWP_REPORT_VIA=verifier-say'."
c_info "See docs/guides/mons-operational-readiness.md for the full runbook."
