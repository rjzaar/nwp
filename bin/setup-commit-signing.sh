#!/bin/bash
################################################################################
# NWP — Commit signing + minisign bootstrap (F36 Phase 1 prerequisite)
#
# Sets up the operator's machine for signed commits and signed deploy
# bundles. Run this once; afterwards every commit and every CI build
# is signed automatically.
#
# What this script does (idempotent — safe to re-run):
#   1. Installs minisign via apt (sudo)
#   2. Ensures an SSH signing key exists (~/.ssh/id_ed25519 by default)
#   3. Generates the NWP minisign keypair in keys/minisign/
#   4. Configures git commit signing (SSH-based per F36 prerequisites discussion)
#   5. Sets up ~/.ssh/allowed_signers so signatures verify locally
#   6. Smoke-tests both signing paths
#
# What this script does NOT do:
#   - Modify --global git config (defaults to repo-local; pass --global to change)
#   - Re-sign existing unsigned commits (do that yourself if you want)
#   - Upload the SSH public key to GitLab (manual step — instructions printed)
#   - Wire the CI jobs (Claude does that in the Phase 1 follow-up)
#
# Usage:
#   ./bin/setup-commit-signing.sh [--global] [--ssh-key PATH]
#
# Options:
#   --global         Set git signing config in --global scope instead of repo-local
#   --ssh-key PATH   Use this SSH key for signing (default: ~/.ssh/id_ed25519)
#   --help           Show this message
################################################################################

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults & arg parsing
# -----------------------------------------------------------------------------

GIT_SCOPE="--local"
SSH_KEY="$HOME/.ssh/id_ed25519"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --global)       GIT_SCOPE="--global"; shift ;;
        --ssh-key)      SSH_KEY="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# *$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# Resolve repo root from script location (bin/ is at repo root)
NWP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$NWP_ROOT"

# -----------------------------------------------------------------------------
# Output helpers (kept inline to avoid sourcing dependencies)
# -----------------------------------------------------------------------------

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[0;31m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    GREEN=""; YELLOW=""; RED=""; BOLD=""; NC=""
fi

step()  { echo "${BOLD}→${NC} $*"; }
ok()    { echo "${GREEN}✓${NC} $*"; }
warn()  { echo "${YELLOW}⚠${NC} $*"; }
fail()  { echo "${RED}✗${NC} $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------

[[ "$EUID" -eq 0 ]] && fail "Do not run as root. Run as your normal user; the script uses sudo only for apt."

GIT_EMAIL=$(git config user.email 2>/dev/null || true)
GIT_NAME=$(git config user.name 2>/dev/null || true)
[[ -z "$GIT_EMAIL" ]] && fail "git config user.email is not set. Run: git config --global user.email you@example.com"
[[ -z "$GIT_NAME" ]] && fail "git config user.name is not set. Run: git config --global user.name 'Your Name'"

echo "${BOLD}================================================================${NC}"
echo "${BOLD}  NWP commit signing + minisign bootstrap${NC}"
echo "${BOLD}================================================================${NC}"
echo ""
echo "Repo root:    $NWP_ROOT"
echo "Git identity: $GIT_NAME <$GIT_EMAIL>"
echo "Git scope:    $GIT_SCOPE"
echo "SSH key:      $SSH_KEY"
echo ""

# -----------------------------------------------------------------------------
# Step 1 — minisign binary
# -----------------------------------------------------------------------------

step "Step 1/6 — minisign binary"
if command -v minisign &>/dev/null; then
    ok "minisign already installed: $(minisign -v 2>&1 | head -1)"
else
    step "Installing minisign (requires sudo)"
    sudo apt-get update -qq
    sudo apt-get install -y -qq minisign
    ok "minisign installed: $(minisign -v 2>&1 | head -1)"
fi
echo ""

# -----------------------------------------------------------------------------
# Step 2 — SSH signing key
# -----------------------------------------------------------------------------

step "Step 2/6 — SSH signing key at $SSH_KEY"
if [[ -f "$SSH_KEY" && -f "${SSH_KEY}.pub" ]]; then
    ok "SSH key already exists"
    echo "    Fingerprint: $(ssh-keygen -lf "${SSH_KEY}.pub" 2>/dev/null | awk '{print $2}')"
elif [[ -e "$SSH_KEY" || -e "${SSH_KEY}.pub" ]]; then
    fail "Partial SSH key at $SSH_KEY — refusing to overwrite. Remove or rename the existing files first."
else
    warn "No SSH key found. Generating a new ed25519 key for $GIT_EMAIL."
    warn "You will be prompted to choose a passphrase. Pick a strong one and"
    warn "store it in your password manager."
    echo ""
    ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$SSH_KEY"
    ok "SSH key generated"
fi
echo ""

# -----------------------------------------------------------------------------
# Step 3 — Minisign keypair
# -----------------------------------------------------------------------------

step "Step 3/6 — Minisign keypair at keys/minisign/"
MINI_DIR="$NWP_ROOT/keys/minisign"
MINI_KEY="$MINI_DIR/nwp-deploy.key"
MINI_PUB="$MINI_DIR/nwp-deploy.pub"
mkdir -p "$MINI_DIR"

if [[ -f "$MINI_KEY" && -f "$MINI_PUB" ]]; then
    ok "Minisign keypair already exists"
elif [[ -e "$MINI_KEY" || -e "$MINI_PUB" ]]; then
    fail "Partial minisign keypair in $MINI_DIR — refusing to overwrite."
else
    warn "Generating minisign keypair. You will be prompted twice:"
    warn "  1. Choose a passphrase for the secret key"
    warn "  2. Re-enter it to confirm"
    warn "This protects keys/minisign/nwp-deploy.key on disk."
    echo ""
    minisign -G -p "$MINI_PUB" -s "$MINI_KEY"
    chmod 600 "$MINI_KEY"
    ok "Minisign keypair generated"
fi
echo "    Public key path: $MINI_PUB"
echo ""

# -----------------------------------------------------------------------------
# Step 4 — Git commit signing config
# -----------------------------------------------------------------------------

step "Step 4/6 — Git commit signing config ($GIT_SCOPE)"

SET_OR_CONFIRM() {
    local key="$1" want="$2"
    local current
    current=$(git config $GIT_SCOPE --get "$key" 2>/dev/null || true)
    if [[ "$current" == "$want" ]]; then
        ok "$key already set to: $want"
    else
        git config $GIT_SCOPE "$key" "$want"
        ok "$key = $want"
    fi
}

SET_OR_CONFIRM gpg.format         "ssh"
SET_OR_CONFIRM user.signingkey    "${SSH_KEY}.pub"
SET_OR_CONFIRM commit.gpgsign     "true"
SET_OR_CONFIRM tag.gpgsign        "true"
echo ""

# -----------------------------------------------------------------------------
# Step 5 — allowed_signers file
# -----------------------------------------------------------------------------

step "Step 5/6 — ~/.ssh/allowed_signers for local verification"
ALLOWED_SIGNERS="$HOME/.ssh/allowed_signers"
PUB_CONTENT=$(cat "${SSH_KEY}.pub")
# Build the allowed_signers entry: <principal> <key-type> <key-data> [comment]
ENTRY="$GIT_EMAIL $PUB_CONTENT"

touch "$ALLOWED_SIGNERS"
chmod 600 "$ALLOWED_SIGNERS"

# Match on the public-key body (the long base64 part), ignoring the comment
PUB_BODY=$(awk '{print $2}' <<< "$PUB_CONTENT")
if grep -qF "$PUB_BODY" "$ALLOWED_SIGNERS"; then
    ok "Key already in $ALLOWED_SIGNERS"
else
    echo "$ENTRY" >> "$ALLOWED_SIGNERS"
    ok "Added to $ALLOWED_SIGNERS"
fi

SET_OR_CONFIRM gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
echo ""

# -----------------------------------------------------------------------------
# Step 6 — Smoke tests
# -----------------------------------------------------------------------------

step "Step 6/6 — Smoke tests"

# 6a — minisign sign/verify roundtrip
TMP_SIGN=$(mktemp)
echo "nwp bootstrap test" > "$TMP_SIGN"
if minisign -S -s "$MINI_KEY" -m "$TMP_SIGN" </dev/tty 2>/dev/null \
   && minisign -V -p "$MINI_PUB" -m "$TMP_SIGN" >/dev/null 2>&1; then
    ok "minisign sign + verify roundtrip works"
else
    warn "minisign roundtrip failed — you may need to enter your passphrase next time"
    warn "(this can happen if the script can't access /dev/tty; not fatal)"
fi
rm -f "$TMP_SIGN" "${TMP_SIGN}.minisig"

# 6b — git signed-commit verification on an isolated test repo
TMP_REPO=$(mktemp -d)
(
    cd "$TMP_REPO"
    git init -q
    git config user.email "$GIT_EMAIL"
    git config user.name "$GIT_NAME"
    git config gpg.format ssh
    git config user.signingkey "${SSH_KEY}.pub"
    git config commit.gpgsign true
    git config gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
    if git commit --allow-empty -m "nwp-bootstrap-test" -q 2>/dev/null; then
        if git log --show-signature 2>&1 | grep -qE "Good.*signature|Good \"git\""; then
            ok "git signed-commit verification works"
        else
            warn "git commit was created but signature didn't verify — output:"
            git log --show-signature 2>&1 | head -10
        fi
    else
        warn "git commit failed — possibly missing passphrase cache. Try:"
        warn "  ssh-add ${SSH_KEY}"
        warn "Then re-run this script."
    fi
)
rm -rf "$TMP_REPO"
echo ""

# -----------------------------------------------------------------------------
# Summary + next steps
# -----------------------------------------------------------------------------

echo "${BOLD}================================================================${NC}"
echo "${BOLD}  Bootstrap complete${NC}"
echo "${BOLD}================================================================${NC}"
echo ""
echo "What's set up:"
echo "  ${GREEN}✓${NC} minisign installed: $(command -v minisign)"
echo "  ${GREEN}✓${NC} SSH signing key: ${SSH_KEY}.pub"
echo "  ${GREEN}✓${NC} Minisign keypair: $MINI_KEY"
echo "  ${GREEN}✓${NC} Git commit signing: enabled ($GIT_SCOPE scope, gpg.format=ssh)"
echo "  ${GREEN}✓${NC} Allowed signers: $ALLOWED_SIGNERS"
echo ""
echo "${BOLD}One manual step left:${NC}"
echo "  Upload your SSH public key to your GitLab instance so signed commits"
echo "  show 'Verified' in the UI:"
echo ""
echo "    cat ${SSH_KEY}.pub"
echo ""
echo "  Paste into your GitLab instance under:"
echo "    Settings → SSH Keys → Add key (Usage type: Authentication & Signing)"
echo "    Path: /-/user_settings/ssh_keys"
echo ""
echo "${BOLD}When you're done:${NC} ask Claude to continue F36 Phase 1 — it will"
echo "wire the sign-artifact / upload-artifact / verify-bundle CI jobs and"
echo "flip verify-signature from placeholder to enforced."
echo ""
echo "${BOLD}Optional follow-ups (deferrable):${NC}"
echo "  - Cache passphrases this login session:"
echo "      ssh-add $SSH_KEY"
echo "  - Re-sign your recent unsigned commits via interactive rebase:"
echo "      git rebase --exec 'git commit --amend --no-edit -S' -i HEAD~7"
echo "  - Promote git signing to --global if you want it for all repos:"
echo "      git config --global commit.gpgsign true"
echo "      git config --global gpg.format ssh"
echo "      git config --global user.signingkey ${SSH_KEY}.pub"
echo "      git config --global gpg.ssh.allowedSignersFile $ALLOWED_SIGNERS"
echo ""
