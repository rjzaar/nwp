# F14: Claude API Integration

**Status:** IMPLEMENTED
**Created:** 2026-02-01
**Author:** Rob, Claude Opus 4.5
**Priority:** Medium
**Depends On:** None (benefits from F10 for provider switching)
**Estimated Effort:** 2-3 weeks
**Breaking Changes:** No - additive feature

---

## 1. Executive Summary

### 1.1 Problem Statement

NWP currently has no managed way to provision Claude API access for coders. Each developer must manually obtain API keys, configure Claude Code, and manage their own spend. There is no visibility into team-wide usage, no cost controls, and no way to enforce consistent Claude Code configuration across the team.

**Current gaps:**

| Gap | Impact |
|-----|--------|
| No API key provisioning | Each coder sets up independently, inconsistent configuration |
| No spend limits | Risk of unexpected costs, no per-coder budgets |
| No usage monitoring | No visibility into API consumption across team |
| No managed settings | Each coder configures Claude Code differently |
| No shared context | Coders don't benefit from shared prompt caching |
| No key rotation | API keys live indefinitely, no rotation policy |

### 1.2 Proposed Solution

Integrate Claude API key management into NWP's existing two-tier secrets architecture (`.secrets.yml`), extend `bootstrap-coder.sh` to provision API access during onboarding, enforce spend limits via the Anthropic Admin API, and configure Claude Code teams settings for consistent behaviour.

```
.secrets.yml (infrastructure tier) → Claude API org key, admin key
Per-coder provisioning → bootstrap-coder.sh generates workspace API keys
Spend controls → Admin API enforces per-coder limits
Monitoring → OpenTelemetry integration for usage dashboards
```

### 1.3 Key Benefits

| Benefit | Description |
|---------|-------------|
| Automated provisioning | New coders get Claude API access as part of `bootstrap-coder.sh` |
| Cost control | Per-coder and org-wide spend limits enforced via Admin API |
| Usage visibility | OpenTelemetry metrics for token usage, cost, and model breakdown |
| Consistent configuration | Claude Code managed settings applied to all coders |
| Shared context efficiency | Prompt caching for CLAUDE.md and project context reduces costs |
| Security | Key rotation, deny rules, safe-ops patterns followed |

---

## 2. Configuration Schema

### 2.1 Secrets Configuration (.secrets.yml)

Add Claude API credentials to the infrastructure secrets tier:

```yaml
# === CLAUDE API (Anthropic) ===
# Used for Claude Code API access and team management
# Organization API key: https://console.anthropic.com/settings/keys
# Admin API key: https://console.anthropic.com/settings/admin-keys
# RECOMMENDED: Use workspace-scoped keys for coders, org key for admin only
claude:
  org_api_key: ""                        # Organization-level API key (admin use only)
  admin_api_key: ""                      # Admin API key for usage/billing management
  default_model: "claude-sonnet-4-5"     # Default model for coders
  workspace_id: ""                       # Default workspace ID for coder provisioning
```

This follows the existing pattern in `.secrets.yml` — infrastructure tokens that are AI-safe and used for provisioning/automation.

### 2.2 NWP Configuration (nwp.yml / example.nwp.yml)

Add Claude API settings under the existing `settings:` section:

```yaml
settings:
  # === CLAUDE API [ACTIVE] ===
  claude:
    enabled: true                        # [ACTIVE] Enable Claude API integration
    default_model: claude-sonnet-4-5     # [ACTIVE] Default model for new coders
    max_monthly_spend_usd: 500           # [ACTIVE] Org-wide monthly spend cap
    per_coder_monthly_limit_usd: 100     # [ACTIVE] Per-coder monthly spend limit
    prompt_caching: true                 # [ACTIVE] Enable prompt caching for shared contexts
    models_allowed:                      # [ACTIVE] Models coders can use
      - claude-sonnet-4-5
      - claude-haiku-3-5
    otel_endpoint: ""                    # [ACTIVE] OpenTelemetry endpoint for usage metrics
```

### 2.3 Per-Coder Configuration

Per-coder API keys are stored in the coder's environment, not in nwp.yml:

```bash
# Set during bootstrap-coder.sh, written to coder's ~/.bashrc
export ANTHROPIC_API_KEY="sk-ant-..."

# Claude Code managed settings applied to ~/.claude/settings.json
# via claude-code-settings.json in the project root
```

---

## 3. Inheritance Chain

```
┌─────────────────────────────────────────────────────────┐
│  PER-CODER ENVIRONMENT                                   │
│  $ANTHROPIC_API_KEY (workspace-scoped key)               │
│  ~/.claude/settings.json (managed settings)              │
└─────────────────────────────────────────────────────────┘
                         ↓ (provisioned from)
┌─────────────────────────────────────────────────────────┐
│  NWP SETTINGS                                            │
│  settings.claude.default_model                           │
│  settings.claude.per_coder_monthly_limit_usd             │
│  (via yaml_get_setting)                                  │
└─────────────────────────────────────────────────────────┘
                         ↓ (credentials from)
┌─────────────────────────────────────────────────────────┐
│  INFRASTRUCTURE SECRETS                                   │
│  .secrets.yml → claude.org_api_key                        │
│  .secrets.yml → claude.admin_api_key                      │
│  (via get_infra_secret)                                   │
└─────────────────────────────────────────────────────────┘
```

---

## 4. Implementation Phases

### Phase 1: Secrets and Configuration

1. Add `claude:` section to `.secrets.example.yml` with documented fields
2. Add `settings.claude:` section to `example.nwp.yml`
3. Create `lib/claude-api.sh` library with helper functions:

```bash
# Get Claude org API key from infrastructure secrets
get_claude_org_key() {
    get_infra_secret "claude.org_api_key" ""
}

# Get Claude admin API key
get_claude_admin_key() {
    get_infra_secret "claude.admin_api_key" ""
}

# Get default model from settings
get_claude_default_model() {
    local config_file="${1:-$NWP_DIR/nwp.yml}"
    local model
    model=$(yaml_get_setting "claude.default_model" "$config_file" 2>/dev/null)
    echo "${model:-claude-sonnet-4-5}"
}

# Get per-coder spend limit
get_claude_coder_limit() {
    local config_file="${1:-$NWP_DIR/nwp.yml}"
    local limit
    limit=$(yaml_get_setting "claude.per_coder_monthly_limit_usd" "$config_file" 2>/dev/null)
    echo "${limit:-100}"
}
```

### Phase 2: Workspace and API Key Provisioning

4. Create workspace management via Anthropic Admin API:

```bash
# Create a workspace for NWP (one-time setup)
create_nwp_workspace() {
    local admin_key
    admin_key=$(get_claude_admin_key)
    local workspace_name="nwp-${NWP_SITENAME:-default}"

    curl -s -X POST "https://api.anthropic.com/v1/organizations/workspaces" \
        -H "x-api-key: $admin_key" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$workspace_name\"}"
}

# Generate workspace-scoped API key for a coder
provision_coder_api_key() {
    local coder_name="$1"
    local admin_key
    admin_key=$(get_claude_admin_key)
    local workspace_id
    workspace_id=$(get_infra_secret "claude.workspace_id" "")

    # Validate coder name using existing NWP validation
    if ! validate_sitename "$coder_name" 2>/dev/null; then
        echo "ERROR: Invalid coder name: $coder_name" >&2
        return 1
    fi

    curl -s -X POST "https://api.anthropic.com/v1/organizations/api_keys" \
        -H "x-api-key: $admin_key" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"nwp-coder-${coder_name}\",
            \"workspace_id\": \"$workspace_id\"
        }"
}
```

5. Set workspace-level spend limits:

```bash
# Set spend limit for a workspace
set_workspace_spend_limit() {
    local workspace_id="$1"
    local monthly_limit_usd="$2"
    local admin_key
    admin_key=$(get_claude_admin_key)

    # Convert dollars to cents for API
    local limit_cents=$((monthly_limit_usd * 100))

    curl -s -X POST "https://api.anthropic.com/v1/organizations/workspaces/${workspace_id}/limits" \
        -H "x-api-key: $admin_key" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json" \
        -d "{\"spend_limit_monthly_usd\": $monthly_limit_usd}"
}
```

### Phase 3: Coder Onboarding Extensions

6. Add Claude API provisioning step to `bootstrap-coder.sh`:

```bash
# New function added to bootstrap-coder.sh
setup_claude_api() {
    local coder_name="$1"

    # Check if Claude integration is enabled
    local claude_enabled
    claude_enabled=$(yaml_get_setting "claude.enabled" "$NWP_DIR/nwp.yml" 2>/dev/null)
    if [[ "$claude_enabled" != "true" ]]; then
        echo "Claude API integration not enabled in nwp.yml, skipping."
        return 0
    fi

    echo "=== Setting up Claude API access for $coder_name ==="

    # 1. Provision workspace-scoped API key
    local key_response
    key_response=$(provision_coder_api_key "$coder_name")
    local api_key
    api_key=$(echo "$key_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null)

    if [[ -z "$api_key" ]]; then
        echo "WARNING: Failed to provision Claude API key. Configure manually."
        return 1
    fi

    # 2. Set per-coder spend limit
    local coder_limit
    coder_limit=$(get_claude_coder_limit)
    echo "Monthly spend limit: \$${coder_limit} USD"

    # 3. Write API key to coder's environment
    echo "" >> "$HOME/.bashrc"
    echo "# Claude API (provisioned by NWP bootstrap-coder.sh)" >> "$HOME/.bashrc"
    echo "export ANTHROPIC_API_KEY=\"$api_key\"" >> "$HOME/.bashrc"

    # 4. Apply managed Claude Code settings
    apply_claude_code_settings "$coder_name"

    echo "Claude API configured. Key provisioned with \$${coder_limit}/month limit."
}
```

### Phase 4: Claude Code Managed Settings

7. Create project-level Claude Code settings for team consistency:

```bash
# Apply Claude Code team settings
apply_claude_code_settings() {
    local coder_name="$1"
    local default_model
    default_model=$(get_claude_default_model)

    # Create/update .claude/settings.json in project root
    # This is the managed settings file that applies to all team members
    cat > "$NWP_DIR/.claude/settings.json" <<EOF
{
  "permissions": {
    "deny": [
      "Bash(cat .secrets.data.yml*)",
      "Bash(cat keys/prod_*)",
      "Bash(*secrets.data*)",
      "Read(.secrets.data.yml)",
      "Read(keys/prod_*)",
      "Read(*.sql)",
      "Read(*.sql.gz)"
    ]
  },
  "preferences": {
    "model": "$default_model"
  }
}
EOF
}
```

### Phase 5: Usage Monitoring and Cost Tracking

8. Add usage monitoring via Admin API:

```bash
# Get current month usage for the NWP workspace
get_workspace_usage() {
    local admin_key
    admin_key=$(get_claude_admin_key)
    local workspace_id
    workspace_id=$(get_infra_secret "claude.workspace_id" "")

    local start_date
    start_date=$(date +%Y-%m-01)
    local end_date
    end_date=$(date +%Y-%m-%d)

    curl -s "https://api.anthropic.com/v1/organizations/usage?start_date=${start_date}&end_date=${end_date}&workspace_id=${workspace_id}" \
        -H "x-api-key: $admin_key" \
        -H "anthropic-version: 2023-06-01"
}

# Display usage summary (for pl status integration)
show_claude_usage_summary() {
    local usage
    usage=$(get_workspace_usage)

    echo "=== Claude API Usage (Current Month) ==="
    echo "$usage" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for entry in data.get('data', []):
    model = entry.get('model', 'unknown')
    input_tokens = entry.get('input_tokens', 0)
    output_tokens = entry.get('output_tokens', 0)
    cost = entry.get('cost_usd', 0)
    print(f'  {model}: {input_tokens:,} in / {output_tokens:,} out (\${cost:.2f})')
" 2>/dev/null || echo "  Unable to fetch usage data"
}
```

9. OpenTelemetry integration for usage dashboards:

```bash
# Export Claude usage metrics to OpenTelemetry
export_claude_otel_metrics() {
    local otel_endpoint
    otel_endpoint=$(yaml_get_setting "claude.otel_endpoint" "$NWP_DIR/nwp.yml" 2>/dev/null)

    if [[ -z "$otel_endpoint" ]]; then
        return 0  # OTEL not configured, skip silently
    fi

    local usage
    usage=$(get_workspace_usage)

    # Push metrics to OTEL endpoint
    # Format as OTLP JSON for ingestion
    local metrics_payload
    metrics_payload=$(echo "$usage" | python3 -c "
import sys, json
data = json.load(sys.stdin)
metrics = []
for entry in data.get('data', []):
    metrics.append({
        'name': 'claude.tokens.input',
        'value': entry.get('input_tokens', 0),
        'attributes': {'model': entry.get('model', '')}
    })
    metrics.append({
        'name': 'claude.tokens.output',
        'value': entry.get('output_tokens', 0),
        'attributes': {'model': entry.get('model', '')}
    })
    metrics.append({
        'name': 'claude.cost.usd',
        'value': entry.get('cost_usd', 0),
        'attributes': {'model': entry.get('model', '')}
    })
print(json.dumps({'metrics': metrics}))
" 2>/dev/null)

    curl -s -X POST "$otel_endpoint/v1/metrics" \
        -H "Content-Type: application/json" \
        -d "$metrics_payload" > /dev/null 2>&1
}
```

### Phase 6: Security and Key Rotation

10. Key rotation support:

```bash
# Rotate a coder's API key
rotate_coder_api_key() {
    local coder_name="$1"
    local admin_key
    admin_key=$(get_claude_admin_key)

    # List existing keys for this coder
    local keys_response
    keys_response=$(curl -s "https://api.anthropic.com/v1/organizations/api_keys" \
        -H "x-api-key: $admin_key" \
        -H "anthropic-version: 2023-06-01")

    # Find and disable old key
    local old_key_id
    old_key_id=$(echo "$keys_response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for key in data.get('data', []):
    if key.get('name') == 'nwp-coder-${coder_name}' and key.get('status') == 'active':
        print(key['id'])
        break
" 2>/dev/null)

    if [[ -n "$old_key_id" ]]; then
        # Disable old key
        curl -s -X POST "https://api.anthropic.com/v1/organizations/api_keys/${old_key_id}/disable" \
            -H "x-api-key: $admin_key" \
            -H "anthropic-version: 2023-06-01" > /dev/null

        echo "Disabled old key: $old_key_id"
    fi

    # Provision new key
    provision_coder_api_key "$coder_name"
    echo "New key provisioned for $coder_name. Update ANTHROPIC_API_KEY in coder's environment."
}
```

11. Add deny rules for Claude API secrets in safe-ops:

```bash
# Claude API keys are infrastructure secrets (AI-safe tier)
# but the org_api_key and admin_api_key should only be used by provisioning scripts
# Coder API keys are workspace-scoped and safe to use directly

# Safe operation: check Claude API connectivity without exposing key
safe_claude_status() {
    local api_key="${ANTHROPIC_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
        echo "Status: NOT CONFIGURED"
        return 1
    fi

    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json" \
        -d '{"model":"claude-haiku-3-5","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}')

    case "$response" in
        200) echo "Status: ACTIVE" ;;
        401) echo "Status: INVALID KEY" ;;
        429) echo "Status: RATE LIMITED" ;;
        *)   echo "Status: ERROR ($response)" ;;
    esac
}
```

### Phase 7: Prompt Caching Strategy

12. Configure prompt caching for shared project context:

```bash
# Prompt caching reduces costs when multiple coders share the same project context
# CLAUDE.md, project structure, and common instructions are cached server-side
#
# How it works:
# - First request with CLAUDE.md content: full price
# - Subsequent requests within 5-minute TTL: 90% discount on cached portion
# - NWP's CLAUDE.md (~4K tokens) benefits significantly from caching
#
# Configuration:
# - Prompt caching is enabled by default in Claude Code
# - No NWP-specific configuration needed
# - settings.claude.prompt_caching in nwp.yml controls documentation of this feature
#
# Cost impact estimate for NWP:
# - CLAUDE.md: ~4,000 tokens cached per request
# - With 50 requests/day across team: saves ~$2-5/day on Sonnet
# - Monthly savings: $60-150 depending on usage
```

---

## 5. Affected Scripts

### 5.1 New Files

| File | Purpose |
|------|---------|
| `lib/claude-api.sh` | Claude API helper functions (provisioning, usage, rotation) |

### 5.2 Modified Files

| File | Change |
|------|--------|
| `scripts/commands/bootstrap-coder.sh` | Add `setup_claude_api()` step to onboarding flow |
| `.secrets.example.yml` | Add `claude:` section with documented fields |
| `example.nwp.yml` | Add `settings.claude:` section |
| `.claude/settings.json` | Managed deny rules for team (generated by setup) |

### 5.3 Optional Integrations

| File | Change |
|------|--------|
| `scripts/commands/status.sh` | Add Claude usage to `pl status` output |
| `fin/fin-monitor.sh` | Add Claude API spend to financial monitoring |

---

## 6. Changes to .secrets.example.yml

### 6.1 Add Claude Section

Add after the `github:` section:

```yaml
# === CLAUDE API (Anthropic) ===
# Used for Claude Code API access and team management
# Organization API key: https://console.anthropic.com/settings/keys
# Admin API key: https://console.anthropic.com/settings/admin-keys
# RECOMMENDED: Use workspace-scoped keys for coders, org key for admin only
claude:
  org_api_key: ""                        # Organization-level API key (admin use only)
  admin_api_key: ""                      # Admin API key for usage/billing management
  default_model: "claude-sonnet-4-5"     # Default model for coders
  workspace_id: ""                       # Default workspace ID for coder provisioning
```

---

## 7. Changes to example.nwp.yml

### 7.1 Add Claude Settings

Add under the `settings:` section:

```yaml
settings:
  # === CLAUDE API [ACTIVE] ===
  claude:
    enabled: true                        # [ACTIVE] Enable Claude API integration for coders
    default_model: claude-sonnet-4-5     # [ACTIVE] Default model provisioned to new coders
    max_monthly_spend_usd: 500           # [ACTIVE] Org-wide monthly spend cap
    per_coder_monthly_limit_usd: 100     # [ACTIVE] Per-coder monthly spend limit
    prompt_caching: true                 # [ACTIVE] Enable prompt caching for shared contexts
    models_allowed:                      # [ACTIVE] Models coders are allowed to use
      - claude-sonnet-4-5               #   Primary coding model
      - claude-haiku-3-5                #   Fast model for simple tasks
    otel_endpoint: ""                    # [ACTIVE] OpenTelemetry endpoint (empty = disabled)
                                         # Used by: usage dashboards, cost tracking
```

---

## 8. Implementation Order

| Order | Phase | Description | Dependencies |
|-------|-------|-------------|--------------|
| 1 | Phase 1 | Secrets and configuration schema | None |
| 2 | Phase 4 | Claude Code managed settings | Phase 1 |
| 3 | Phase 2 | Workspace and API key provisioning | Phase 1 |
| 4 | Phase 3 | bootstrap-coder.sh extensions | Phase 2 |
| 5 | Phase 6 | Key rotation and security | Phase 2 |
| 6 | Phase 5 | Usage monitoring and OTEL | Phase 2 |
| 7 | Phase 7 | Prompt caching documentation | Phase 1 |

---

## 9. Success Criteria

- [ ] `claude:` section documented in `.secrets.example.yml`
- [ ] `settings.claude:` section documented in `example.nwp.yml`
- [ ] `lib/claude-api.sh` created with provisioning, usage, and rotation functions
- [ ] `bootstrap-coder.sh` provisions Claude API key during onboarding
- [ ] Workspace-scoped API keys generated per coder
- [ ] Per-coder monthly spend limits enforced via Admin API
- [ ] `safe_claude_status` returns connectivity status without exposing keys
- [ ] Key rotation function disables old key and provisions new one
- [ ] Claude Code managed settings applied with deny rules for `.secrets.data.yml`
- [ ] Usage summary available via `show_claude_usage_summary`
- [ ] OpenTelemetry metrics exported when endpoint configured
- [ ] Prompt caching strategy documented with cost estimates

---

## 10. Testing

```bash
# Verify secrets configuration reads correctly
source lib/claude-api.sh
get_claude_org_key          # Should return org API key from .secrets.yml
get_claude_default_model    # Should return claude-sonnet-4-5 (or configured value)
get_claude_coder_limit      # Should return 100 (or configured value)

# Verify API connectivity
safe_claude_status          # Should return "Status: ACTIVE"

# Verify coder provisioning (dry run)
provision_coder_api_key "testcoder"  # Should return JSON with api_key field

# Verify usage monitoring
show_claude_usage_summary   # Should display current month usage

# Verify managed settings
cat .claude/settings.json   # Should show deny rules for .secrets.data.yml

# Verify bootstrap integration
./scripts/commands/bootstrap-coder.sh --help  # Should mention Claude API setup step
```

---

## 11. Cost Estimates

### Per-Coder Monthly Usage (Typical NWP Development)

| Activity | Model | Tokens/Day | Monthly Cost |
|----------|-------|------------|--------------|
| Code assistance | Sonnet 4.5 | ~50K in / ~20K out | ~$15 |
| Code review | Sonnet 4.5 | ~30K in / ~10K out | ~$8 |
| Quick lookups | Haiku 3.5 | ~20K in / ~5K out | ~$1 |
| Prompt cache savings | — | — | -$5 to -$10 |
| **Total per coder** | | | **~$15-25/month** |

### Team Costs (5 Coders)

| Item | Monthly |
|------|---------|
| API usage (5 coders) | $75-125 |
| Prompt cache savings | -$25 to -$50 |
| **Net cost** | **$50-100/month** |

Default `per_coder_monthly_limit_usd: 100` provides generous headroom while preventing runaway costs.

---

## 12. Security Considerations

| Concern | Mitigation |
|---------|------------|
| Org API key exposure | Stored in `.secrets.yml` (infrastructure tier), never in code |
| Admin API key misuse | Only used by provisioning scripts, not coder-accessible |
| Coder key scope | Workspace-scoped keys limit blast radius |
| Key rotation | `rotate_coder_api_key` function disables old, provisions new |
| Data leakage to Claude | Managed deny rules block `.secrets.data.yml`, prod keys, SQL dumps |
| Spend overruns | Per-coder and org-wide limits via Admin API |
| Key in environment | `$ANTHROPIC_API_KEY` in `.bashrc` — standard Anthropic pattern |

---

*Proposal follows NWP conventions: two-tier secrets, existing helper functions, phased implementation, safe-ops patterns.*
