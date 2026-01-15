# Claude Code CLI Cheatsheet

Based on the official documentation, here's a comprehensive cheatsheet to maximize your use of Claude Code:

## 1. AUTO-ACCEPTANCE & PERMISSION MODES

### Auto-Accept Settings
Control how Claude approves tool use via **permission modes**:

```bash
# Start in Auto-Accept Mode (accepts all edits, no prompts)
claude --permission-mode acceptEdits

# Start in Plan Mode (read-only, no modifications)
claude --permission-mode plan

# Start in Normal Mode (prompts for each tool)
claude --permission-mode default

# Bypass all permissions (use cautiously)
claude --dangerously-skip-permissions
```

### Permission Mode Shortcuts (During Session)
- **Shift+Tab** - Cycle through permission modes: Normal → Auto-Accept → Plan → Normal
- First Shift+Tab: Switch to Auto-Accept (⏵⏵ accept edits on)
- Second Shift+Tab: Switch to Plan Mode (⏸ plan mode on)
- Third Shift+Tab: Return to Normal mode

### Set Default Permission Mode
```json
// .claude/settings.json (project) or ~/.claude/settings.json (user)
{
  "permissions": {
    "defaultMode": "acceptEdits"
  }
}
```

### Pre-Approve Specific Tools
```bash
# Allow specific bash commands without asking
claude --allowedTools "Bash(git diff:*),Bash(git commit:*),Read,Edit"

# Auto-approve in non-interactive mode
claude -p "your task" --allowedTools "Bash,Edit,Read"
```

---

## 2. KEY SETTINGS & CONFIGURATION

### Essential Settings File Locations
- **User settings**: `~/.claude/settings.json` (applies everywhere)
- **Project settings**: `.claude/settings.json` (shared with team)
- **Local project**: `.claude/settings.local.json` (personal, not committed)
- **Managed (Enterprise)**: `/Library/Application Support/ClaudeCode/managed-settings.json` (macOS)

### Top Settings to Configure
```json
{
  "model": "sonnet",                          // sonnet, opus, haiku, opusplan
  "permissions": {
    "defaultMode": "acceptEdits",             // acceptEdits, plan, default
    "allow": ["Bash(npm run:*)", "Read"],     // Pre-approve tools
    "deny": ["Read(.env)", "Read(secrets/**)", "WebFetch"]
  },
  "alwaysThinkingEnabled": true,              // Enable extended thinking by default
  "respectGitignore": false,                  // Include .gitignored files in @ autocomplete
  "autoUpdatesChannel": "stable",             // latest or stable
  "sandbox": {
    "enabled": true,                          // Enable filesystem isolation
    "autoAllowBashIfSandboxed": true
  }
}
```

### Environment Variables for Auto-Configuration
```bash
export ANTHROPIC_MODEL="claude-opus-4-5-20251101"
export DISABLE_AUTOUPDATER=1
export CLAUDE_CODE_SKIP_BEDROCK_AUTH=1
export MAX_THINKING_TOKENS=5000
export DISABLE_PROMPT_CACHING=1
```

---

## 3. PRODUCTIVITY TIPS & WORKFLOWS

### Quick Task Execution (Non-Interactive Mode)
```bash
# Run a task and exit
claude -p "Find and fix the bug in auth.py"

# Get structured JSON output
claude -p "Extract function names from auth.py" \
  --output-format json \
  --json-schema '{"type":"object","properties":{"functions":{"type":"array","items":{"type":"string"}}}}'

# Continue previous conversation
claude -c -p "Now add error handling"

# Resume specific session
claude --resume "auth-refactor" -p "Continue with tests"
```

### Session Management
```bash
# Name your session for easy resuming
/rename "payment-integration"

# Resume by name
claude --resume "payment-integration"

# List and pick from sessions
claude --resume  # Opens interactive picker

# Continue most recent in current directory
claude --continue
```

### Using Plan Mode Effectively
```bash
# Start planning without code changes
claude --permission-mode plan

# Ask Claude to analyze before implementing
# > Create a detailed migration plan for OAuth2
# > What about backward compatibility?
# > How should we handle database migration?

# Then let Claude create the plan safely
```

### Reference Files Without Reading Them First
```bash
# Include file in conversation without waiting for Claude to read
> Explain @src/utils/auth.js

# Reference multiple files
> Compare @src/old-version.js with @src/new-version.js

# Reference directories (shows structure, not contents)
> What's the structure of @src/components?
```

### Piping Data Through Claude
```bash
# Use Claude as a linter
cat my-code.js | claude -p "Find issues with this code" --output-format json

# Process logs
cat error.log | claude -p "Explain the root cause"

# Integrate into scripts
build_output=$(npm run build 2>&1)
claude -p "These build errors occurred: $build_output" > build-analysis.txt
```

### Extended Thinking for Complex Problems
```bash
# Enable thinking for a single request
> ultrathink: design a caching layer for our API

# Toggle thinking globally
/config → "Extended thinking enabled"

# View Claude's thinking process
Ctrl+O  # Toggle verbose mode

# Set custom thinking token budget
export MAX_THINKING_TOKENS=10000
```

---

## 4. KEYBOARD SHORTCUTS

### Essential Shortcuts
| Shortcut | Action |
|----------|--------|
| `Ctrl+C` | Cancel current input or generation |
| `Ctrl+D` | Exit session |
| `Ctrl+L` | Clear screen (preserves history) |
| `Ctrl+O` | Toggle verbose output (see Claude's thinking) |
| `Ctrl+B` | Background bash tasks (tmux users press twice) |
| `Ctrl+R` | Reverse search command history |
| `Shift+Tab` | Cycle permission modes |
| `Option+P` (Mac) / `Alt+P` | Switch model mid-session |
| `Option+T` (Mac) / `Alt+T` | Toggle extended thinking |
| `Esc` + `Esc` | Rewind code/conversation to previous point |

### Text Editing
| Shortcut | Action |
|----------|--------|
| `Ctrl+K` | Delete to end of line |
| `Ctrl+U` | Delete entire line |
| `Ctrl+Y` | Paste deleted text |
| `Alt+B` | Move back one word |
| `Alt+F` | Move forward one word |
| `Up/Down` | Navigate command history |

### Multiline Input
- **`\` + `Enter`** - Works in all terminals
- **`Option+Enter`** (Mac default)
- **`Shift+Enter`** - Works in iTerm2, WezTerm, Ghostty, Kitty
- **`Ctrl+J`** - Line feed character

---

## 5. HOOKS FOR AUTOMATION

### Quick Hook Setup
```bash
# Open hooks configuration
/hooks

# Add a simple pre-tool hook to validate commands
```

### Common Hook Patterns

**Auto-format code after edits:**
```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{
          "type": "command",
          "command": "jq -r '.tool_input.file_path' | { read f; if [[ \"$f\" == *.ts ]]; then npx prettier --write \"$f\"; fi; }"
        }]
      }
    ]
  }
}
```

**Log all commands Claude runs:**
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{
          "type": "command",
          "command": "jq -r '.tool_input.command' >> ~/.claude/command-log.txt"
        }]
      }
    ]
  }
}
```

**Block edits to sensitive files:**
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{
          "type": "command",
          "command": "python3 -c \"import json,sys; d=json.load(sys.stdin); p=d.get('tool_input',{}).get('file_path',''); sys.exit(2 if any(s in p for s in ['.env','package-lock.json','.git/']) else 0)\""
        }]
      }
    ]
  }
}
```

---

## 6. MODEL SELECTION & WHEN TO USE EACH

### Available Models & Aliases
```bash
# Use latest Sonnet (good default)
/model sonnet
claude --model sonnet

# Use Opus for complex reasoning
/model opus
claude --model opus

# Use Haiku for quick tasks
/model haiku

# Special hybrid mode: Opus in plan, Sonnet for execution
claude --model opusplan

# Extended context (1M tokens)
claude --model sonnet[1m]

# Use specific model version
claude --model claude-opus-4-5-20251101
```

### When to Use Each
| Model | Use For | Cost |
|-------|---------|------|
| **Sonnet** | Daily work, most tasks | Medium |
| **Opus** | Complex architecture, multi-step refactors | High |
| **Haiku** | Quick questions, background tasks | Low |
| **opusplan** | Complex planning → fast execution | Medium |

### Environment Variable Overrides
```bash
export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-4-5-20250929"
export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-4-5-20251101"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-3-5-haiku-20241022"
```

---

## 7. SLASH COMMANDS FOR POWER USERS

### Most Useful Slash Commands
```
/cost          - Show token usage and cost for session
/context       - Visualize context window usage
/model         - Switch AI model
/plan          - Enter Plan Mode
/status        - Show version, model, account info
/help          - List all commands
/config        - Open settings interface
/memory        - Edit CLAUDE.md files
/rename NAME   - Name current session
/resume        - Pick previous session to continue
/clear         - Clear conversation history
/compact       - Summarize conversation
/vim           - Enter vim mode for text editing
/theme         - Change color scheme
/sandbox       - Enable sandboxed bash
/export [file] - Export conversation to file
```

### Creating Custom Commands
```bash
# Create project command
mkdir -p .claude/commands
echo "Analyze this code for performance issues and suggest optimizations:" \
  > .claude/commands/optimize.md

# Use with /optimize

# Create reusable command with arguments
echo "Fix issue #\$ARGUMENTS following coding standards" \
  > .claude/commands/fix-issue.md

# Use with /fix-issue 123
```

---

## 8. ADVANCED FEATURES FOR POWER USERS

### MCP Servers (Extend Functionality)
```bash
# Configure MCP servers
/mcp

# Use GitHub MCP
# Allows Claude to interact with GitHub directly
```

### Subagents for Specialized Tasks
```bash
# View and create subagents
/agents

# Let Claude delegate automatically
> Review my code for security issues
# Claude might delegate to security-focused subagent

# Create custom subagent
/agents → Create New → Define role and prompt
```

### Headless Mode (Scripts/CI)
```bash
# Run Claude programmatically
claude -p "Analyze this codebase for bugs" \
  --output-format json | jq '.result'

# Auto-approve specific tools in scripts
claude -p "Run tests and fix failures" \
  --allowedTools "Bash(npm test:*),Edit,Read"

# Use in CI/CD pipelines
claude -p "Review PR diff" --max-turns 5
```

### Git Worktrees for Parallel Sessions
```bash
# Create isolated workspace
git worktree add ../feature-branch -b feature-a

# Run Claude in isolated environment
cd ../feature-branch
claude  # Completely separate session

# No interference between sessions
```

---

## 9. COST OPTIMIZATION

### Reduce Token Usage
```bash
# Explicitly compact when needed
/compact Focus on code changes only

# Configure auto-compact threshold (default 95%)
# Edit settings.json to adjust

# Clear history between unrelated tasks
/clear

# Use specific queries instead of vague ones
# ✓ "Add error handling for network timeout"
# ✗ "Improve this code"
```

### Track Costs
```bash
/cost  # Shows token usage and cost

# View usage in Console
# https://console.anthropic.com (Admin/Billing role)
```

### Average Costs
- **Per developer per day**: ~$6
- **Per developer per month**: $100-200
- **90% of users**: Below $12/day

---

## 10. CLAUDE.MD - KNOWLEDGE MANAGEMENT

### Set Up Project Memory
```bash
# Bootstrap CLAUDE.md
/init

# Or manually create
echo "# Project Standards

- Use TypeScript with strict mode
- All functions require JSDoc
- Test coverage minimum 80%
" > CLAUDE.md
```

### Organize with Modular Rules
```bash
# Create rules directory
mkdir -p .claude/rules

# Create focused rule files
echo "---
paths:
  - 'src/**/*.ts'
---
# TypeScript Rules
- Use strict mode
- All functions typed
" > .claude/rules/typescript.md
```

### Memory Hierarchy (Higher Wins)
1. **Managed** (organization-level) - Highest
2. **Local** (project, personal)
3. **Project** (shared with team)
4. **User** (your preferences everywhere)

### Import External Files
```
See @README for overview and @docs/architecture.md for design

Individual preferences at @~/.claude/my-preferences.md
```

---

## 11. INSTALLATION & SETUP

### Install Claude Code
```bash
# macOS/Linux/WSL
curl -fsSL https://claude.ai/install.sh | bash

# Homebrew
brew install --cask claude-code

# WinGet (Windows)
winget install Anthropic.ClaudeCode

# Specific version
curl -fsSL https://claude.ai/install.sh | bash -s 1.0.58
```

### First Time Setup
```bash
cd your-project
claude            # Starts interactive session

claude doctor     # Verify installation
claude --version  # Check version

/login           # Switch accounts
/config          # Open settings UI
```

---

## 12. TROUBLESHOOTING

### Common Issues
```bash
# Installation problems
claude doctor

# Stuck permissions
/permissions    # View/modify rules

# Context running out
/compact        # Summarize conversation

# Reset everything (careful!)
rm -rf ~/.claude ~/.claude.json
```

### Enable Debug Mode
```bash
claude --debug "api,mcp"    # Debug specific categories
claude --verbose             # Verbose output
claude --debug "!statsig"    # Exclude categories
```

---

## QUICK REFERENCE TABLE

| Task | Command |
|------|---------|
| Start session | `claude` |
| Run task & exit | `claude -p "task"` |
| Continue work | `claude --continue` |
| Switch model | `/model opus` or `Alt+P` |
| Toggle think | `Alt+T` or `/config` |
| Permission modes | `Shift+Tab` |
| View costs | `/cost` |
| Compact | `/compact` |
| Help | `/help` or `?` |
| Settings | `/config` |
| Background job | `Ctrl+B` |
| Rewind | `Esc` `Esc` |

---

## RECOMMENDED WORKFLOW

1. **Start session**: `claude` (or `claude -p` for quick tasks)
2. **Set permission mode**: Press `Shift+Tab` to find right level
3. **Choose model**: `/model sonnet` (or use `Alt+P`)
4. **Create memory**: `/init` to set up CLAUDE.md
5. **Use Plan Mode**: For complex refactors first
6. **Track costs**: Check `/cost` periodically
7. **Name session**: `/rename` for important work
8. **Resume work**: `claude --resume name` next time

---

This cheatsheet covers the essential 80/20 of Claude Code functionality. For deeper dives, consult:
- Official docs: https://code.claude.com/docs
- In-session help: `/help`, `?`, or ask Claude directly
