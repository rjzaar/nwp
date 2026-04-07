# F22: Claude Code Web Access — Remote CLI via Drupal

**Status:** PROPOSED
**Created:** 2026-03-23
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** Medium
**Depends On:** None (standalone, uses existing NWP infrastructure)
**Breaking Changes:** No
**Site:** Any NWP-managed Drupal site (e.g., nwp.nwpcode.org)
**Design Principle:** Enable secure, authenticated access to Claude Code CLI sessions from any web browser, allowing remote interaction with the NWP development server from anywhere.

---

## 1. Executive Summary

### 1.1 Purpose

Provide remote web-based access to the Claude Code CLI running on the NWP server (97.107.137.88), enabling the user to interact with Claude Code — including its full tool suite (file editing, shell access, code search, etc.) — from any device with a web browser. Four architectural options are evaluated, each with a complete phased implementation plan.

### 1.2 Problem Statement

Claude Code currently requires direct terminal access (SSH or local shell) to the development server. This limits access to machines with SSH clients configured and SSH keys available. The user wants to be able to access Claude Code from any location — including mobile devices, borrowed computers, or environments where SSH is unavailable.

### 1.3 Requirements

| Requirement | Priority |
|---|---|
| Access Claude Code from any web browser | Must |
| Full CLI functionality (file editing, shell, tools) | Must |
| Authentication (prevent unauthorised access) | Must |
| TLS encryption (HTTPS) | Must |
| Works on mobile browsers | Should |
| Session persistence (survive page reload) | Should |
| Drupal integration (accessible from site) | Could |
| Multi-user support | Won't (single user) |

---

## 2. Option A — Web Terminal via ttyd

### 2.1 Overview

**ttyd** is a lightweight C tool that shares a terminal session over HTTP/WebSocket. It spawns a process (e.g., `claude`) and exposes it as a fully interactive web terminal using xterm.js.

### 2.2 Architecture

```
Browser --> HTTPS --> nginx (reverse proxy) --> ttyd (:7681) --> claude CLI
```

### 2.3 Phased Implementation

#### Phase A1: Install ttyd (30 min)

1. Install ttyd from package manager or compile from source
2. Verify it runs: `ttyd --version`
3. Test basic operation: `ttyd -p 7681 bash` and access `http://localhost:7681`

#### Phase A2: Configure ttyd for Claude Code (30 min)

1. Create a wrapper script `/usr/local/bin/claude-web` that:
   - Sets up the Claude Code environment (PATH, API keys via `.env`)
   - Launches `claude` with appropriate flags
   - Optionally starts in a tmux session for persistence
2. Configure ttyd to run the wrapper: `ttyd -p 7681 /usr/local/bin/claude-web`
3. Test locally

#### Phase A3: Create systemd Service (30 min)

1. Create `/etc/systemd/system/claude-web.service`:
   - `ExecStart=/usr/bin/ttyd -p 7681 -c user:PASSWORD /usr/local/bin/claude-web`
   - Set `User=gitlab` (or appropriate user)
   - Enable basic credential authentication (`-c user:pass`)
2. Enable and start the service
3. Verify auto-restart on failure

#### Phase A4: nginx Reverse Proxy with TLS (1 hr)

1. Create nginx server block for `claude.nwpcode.org` (or a subpath on an existing site)
2. Configure reverse proxy to `localhost:7681`
3. Enable WebSocket proxying (`proxy_set_header Upgrade`, `Connection`)
4. Obtain Let's Encrypt certificate via certbot
5. Force HTTPS redirect
6. Test from external browser

#### Phase A5: Security Hardening (1 hr)

1. Add HTTP Basic Auth at nginx level (double auth layer)
2. Configure `allow`/`deny` IP blocks in nginx (optional allowlisting)
3. Set up fail2ban rule for repeated failed auth attempts
4. Configure ttyd with `--max-clients 1` (single session only)
5. Add `--readonly` flag option for view-only sharing
6. Firewall: ensure port 7681 is NOT exposed directly (nginx-only access)

#### Phase A6: Drupal Integration (Optional) (1 hr)

1. Create a simple Drupal block or page that embeds the terminal via iframe
2. Restrict access to authenticated Drupal admin users
3. Add a link in the Drupal admin toolbar

### 2.4 Pros

| Advantage | Detail |
|---|---|
| Simplest to implement | Under 5 hours for full setup |
| Full Claude Code experience | Exact same CLI, all tools work |
| Lightweight | ttyd is ~3MB, minimal resource usage |
| Session quality | xterm.js provides excellent terminal emulation |
| tmux integration | Session survives disconnects when paired with tmux |
| Battle-tested | ttyd is widely used in production environments |

### 2.5 Cons

| Disadvantage | Detail |
|---|---|
| Shell exposure risk | A bug or misconfiguration exposes a real shell session |
| Basic UI | Terminal only — no rich web UI for file browsing, etc. |
| Authentication is minimal | HTTP Basic Auth + ttyd credentials — no MFA without extra tooling |
| No audit trail | No built-in session recording (can be added with `script` or tmux logging) |
| Single user | Designed for one concurrent session |
| Mobile experience | Usable but not optimised — terminal on small screens is awkward |

---

## 3. Option B — Apache Guacamole

### 3.1 Overview

**Apache Guacamole** is a clientless remote desktop gateway. It supports SSH, VNC, and RDP protocols via a web browser with no plugins required. It provides enterprise-grade authentication, session recording, and connection management.

### 3.2 Architecture

```
Browser --> HTTPS --> nginx --> Guacamole Web App (Tomcat :8080)
                                    |
                                    v
                              guacd (proxy daemon)
                                    |
                                    v
                              SSH to localhost --> tmux --> claude CLI
```

### 3.3 Phased Implementation

#### Phase B1: Install Prerequisites (1 hr)

1. Install Java JDK 11+ and Apache Tomcat 9
2. Install guacd build dependencies (libcairo2-dev, libjpeg-dev, libpng-dev, libssh2-1-dev, etc.)
3. Compile and install guacd from source (or install from packages if available)
4. Verify guacd runs: `guacd -f` (foreground mode for testing)

#### Phase B2: Install Guacamole Web Application (1 hr)

1. Download guacamole.war and deploy to Tomcat webapps
2. Create `/etc/guacamole/guacamole.properties` with:
   - `guacd-hostname: localhost`
   - `guacd-port: 4822`
3. Create `/etc/guacamole/user-mapping.xml` with a single user and SSH connection
4. Start Tomcat, access `http://localhost:8080/guacamole`
5. Test SSH connection to localhost

#### Phase B3: Configure SSH Connection to Claude Code (1 hr)

1. Create a dedicated SSH key pair for Guacamole -> localhost connections
2. Configure the SSH connection in Guacamole to:
   - Connect to `localhost:22`
   - Authenticate with the dedicated key
   - Execute a startup command: `tmux new-session -A -s claude 'claude'`
3. Test: login to Guacamole, verify Claude Code session starts
4. Verify tmux persistence — disconnect and reconnect, session should survive

#### Phase B4: nginx Reverse Proxy with TLS (1 hr)

1. Create nginx server block for `claude.nwpcode.org`
2. Configure reverse proxy to Tomcat (`localhost:8080/guacamole`)
3. Enable WebSocket proxying for Guacamole's tunnel
4. Obtain Let's Encrypt certificate
5. Force HTTPS redirect
6. Test from external browser

#### Phase B5: Authentication Hardening (1 hr)

1. Replace user-mapping.xml with a database backend (MySQL/PostgreSQL):
   - Create guacamole database and schema
   - Configure `guacamole.properties` for JDBC auth
2. Set strong password with bcrypt hashing
3. Enable TOTP (Time-based One-Time Password) two-factor authentication:
   - Install guacamole-auth-totp extension
   - Configure with authenticator app (e.g., Aegis, Google Authenticator)
4. Configure session timeout (e.g., 30 minutes idle)
5. Enable login attempt limiting

#### Phase B6: Session Recording and Audit (30 min)

1. Enable session recording in Guacamole connection settings
2. Configure recording storage path (`/var/lib/guacamole/recordings/`)
3. Set retention policy (e.g., 30 days)
4. Test playback of recorded sessions

#### Phase B7: Drupal Integration (Optional) (1 hr)

1. Create Drupal page with iframe embedding Guacamole
2. Alternatively, link from Drupal admin menu to `claude.nwpcode.org`
3. Restrict access to Drupal admin role

### 3.4 Pros

| Advantage | Detail |
|---|---|
| Enterprise-grade security | MFA (TOTP), session recording, database-backed auth |
| Session recording | Full audit trail with playback |
| Connection management | Web UI for managing multiple connections |
| Mature and proven | Apache Foundation project, widely deployed |
| Protocol flexibility | Can also provide VNC/RDP access if needed later |
| Session persistence | SSH + tmux = sessions survive disconnects natively |
| Mobile support | Responsive web UI works on tablets and phones |

### 3.5 Cons

| Disadvantage | Detail |
|---|---|
| Heavy stack | Java + Tomcat + guacd + database = significant resource overhead |
| Complex setup | 6-7 hours for full implementation |
| Resource usage | Tomcat alone uses 200-500MB RAM |
| Maintenance burden | Java ecosystem updates, Tomcat security patches |
| Overkill for single user | Enterprise features not needed for one person |
| Double SSH hop | Browser -> Guacamole -> SSH -> claude (adds latency) |
| Build complexity | guacd must be compiled from source on many distros |

---

## 4. Option C — Drupal Module with Anthropic API

### 4.1 Overview

Build a custom Drupal module that provides a chat interface calling the Anthropic API directly. This creates a Claude conversation embedded natively within the Drupal site. **Important:** This is NOT Claude Code — it does not have file system access, shell execution, or tool use on the server.

### 4.2 Architecture

```
Browser --> HTTPS --> Drupal --> Custom Module (chat UI)
                                    |
                                    v
                              Anthropic API (api.anthropic.com)
                                    |
                                    v
                              Claude model response
```

### 4.3 Phased Implementation

#### Phase C1: Module Scaffolding (1 hr)

1. Create module structure:
   - `modules/claude_chat/claude_chat.info.yml`
   - `modules/claude_chat/claude_chat.module`
   - `modules/claude_chat/claude_chat.routing.yml`
   - `modules/claude_chat/claude_chat.permissions.yml`
2. Define permission: `access claude chat`
3. Define route: `/claude` (or `/admin/claude`)
4. Enable module

#### Phase C2: API Service (1 hr)

1. Create `src/Service/AnthropicClient.php`:
   - Inject HttpClientInterface
   - Method: `sendMessage(array $messages, string $systemPrompt): string`
   - Call `https://api.anthropic.com/v1/messages` with API key from settings
   - Handle streaming responses (optional, Phase C5)
2. Register as a Drupal service in `claude_chat.services.yml`
3. Store API key in Drupal settings.php or config (NOT in module code)
4. Test with a simple API call

#### Phase C3: Chat Controller and Template (2 hr)

1. Create `src/Controller/ClaudeChatController.php`:
   - Render chat page with conversation history
   - Handle AJAX POST for new messages
   - Store conversation in user's session (or database for persistence)
2. Create `templates/claude-chat.html.twig`:
   - Chat message display area (scrollable)
   - Input textarea with send button
   - Markdown rendering for responses
3. Create `css/claude-chat.css` and `js/claude-chat.js`:
   - AJAX submission without page reload
   - Auto-scroll to latest message
   - Loading indicator during API call
4. Register libraries in `claude_chat.libraries.yml`

#### Phase C4: Conversation Management (1 hr)

1. Create database schema for conversation storage:
   - `claude_chat_conversations` table (id, uid, title, created, updated)
   - `claude_chat_messages` table (id, conversation_id, role, content, created)
2. Implement conversation list page (`/claude/history`)
3. Allow starting new conversations and resuming old ones
4. Add conversation title auto-generation (first message summary)

#### Phase C5: Streaming Responses (1 hr)

1. Implement Server-Sent Events (SSE) endpoint for streaming
2. Update JavaScript to consume SSE stream
3. Render tokens as they arrive (typewriter effect)
4. Handle stream interruption and reconnection

#### Phase C6: System Prompt and Context (1 hr)

1. Create admin settings form (`/admin/config/claude-chat`):
   - System prompt textarea (pre-load with NWP context)
   - Model selection (opus-4-6, sonnet-4-6, haiku-4-5)
   - Max tokens setting
   - Temperature setting
2. Optionally inject file contents into context (read-only):
   - Allow specifying file paths whose contents are included in the system prompt
   - This gives Claude awareness of the codebase without shell access

#### Phase C7: Security and Access Control (1 hr)

1. Restrict to admin role only
2. Rate limiting (max requests per minute)
3. Input sanitisation (prevent prompt injection display issues)
4. API key rotation support
5. Cost tracking (log token usage per conversation)

### 4.4 Pros

| Advantage | Detail |
|---|---|
| Native Drupal integration | Lives within the CMS, uses Drupal auth and permissions |
| Clean UI | Purpose-built chat interface, not a terminal |
| No shell exposure | Zero risk of accidental shell access — API calls only |
| Easy to secure | Drupal's existing auth, CSRF protection, and role system |
| Mobile-friendly | Can build a responsive chat UI |
| Familiar UX | Users expect chat interfaces |
| Extensible | Can add features like file upload, context injection, tool use |
| Low maintenance | No additional server daemons — just a Drupal module |

### 4.5 Cons

| Disadvantage | Detail |
|---|---|
| NOT Claude Code | No file editing, no shell access, no local tool use |
| No server interaction | Cannot read/write files, run commands, or search the codebase |
| API costs | Every message costs money (no local execution) |
| Latency | Round-trip to Anthropic API adds delay vs local CLI |
| Context limitations | Cannot dynamically explore the codebase |
| Requires internet | API calls fail if Anthropic is unreachable |
| Development effort | Custom module requires Drupal PHP development |
| Conversation context window | Limited by API context window (no auto-compression like CLI) |

---

## 5. Option D — Claude Code SDK + Custom Web Backend

### 5.1 Overview

Use the **Claude Code SDK** to drive Claude Code sessions programmatically from a backend service, with a custom web frontend for interaction. This provides the full Claude Code experience — including file editing, shell access, and all tools — through a purpose-built web interface.

### 5.2 Architecture

```
Browser --> HTTPS --> nginx --> Drupal (or standalone app)
                                    |
                                    v
                              Node.js/Python backend service
                                    |
                                    v
                              Claude Code SDK (spawns claude sessions)
                                    |
                                    v
                              Local filesystem, shell, tools
```

### 5.3 Phased Implementation

#### Phase D1: Research and Prototype (2 hr)

1. Review Claude Code SDK documentation and capabilities
2. Determine SDK language (Node.js `@anthropic-ai/claude-code` or Python equivalent)
3. Build minimal proof-of-concept:
   - Spawn a Claude Code session via SDK
   - Send a message, receive a response
   - Verify tool use works (file read, shell command)
4. Document API surface and limitations

#### Phase D2: Backend Service (3 hr)

1. Create a Node.js (or Python) service:
   - WebSocket endpoint for real-time communication
   - Session management (create, resume, destroy sessions)
   - Message routing (user input -> SDK -> response stream -> client)
2. Implement authentication middleware:
   - Token-based auth (JWT or API key)
   - Validate against Drupal user session or standalone credentials
3. Handle tool approval/denial flow:
   - Forward tool use requests to the client for approval
   - Support auto-approve for safe operations
4. Configure as a systemd service

#### Phase D3: Web Frontend (3 hr)

1. Build a chat/terminal hybrid interface:
   - Message input and response display (chat-style)
   - Tool use visualisation (show file reads, edits, shell commands)
   - File diff display for edit operations
   - Collapsible tool call details
2. WebSocket connection to backend
3. Implement streaming response display
4. Add session management UI:
   - New session button
   - Session history list
   - Resume previous sessions

#### Phase D4: Tool Approval UI (2 hr)

1. When Claude Code requests tool use, display approval dialog:
   - Tool name and parameters
   - Approve / Deny / Always Allow buttons
   - Show file diffs before applying edits
2. Implement permission presets:
   - "Read-only" — auto-approve reads, deny writes
   - "Full access" — auto-approve everything
   - "Supervised" — approve each action
3. Timeout handling for unapproved actions

#### Phase D5: nginx and TLS (1 hr)

1. Configure nginx reverse proxy to backend service
2. WebSocket support for real-time streaming
3. TLS via Let's Encrypt
4. Rate limiting and connection limits

#### Phase D6: Drupal Integration (2 hr)

1. Create Drupal module `claude_code_web`:
   - Admin page that loads the frontend app
   - Passes Drupal auth token to backend for validation
   - Settings form for backend URL configuration
2. Alternatively, deploy as standalone app at `claude.nwpcode.org`
3. Add link in Drupal admin toolbar

#### Phase D7: Security Hardening (2 hr)

1. Sandbox Claude Code sessions:
   - Run as a restricted user (not root, not the web user)
   - Use filesystem permissions to limit writable paths
   - Consider container isolation (Docker/Podman) per session
2. Audit logging:
   - Log all tool invocations with parameters
   - Log all shell commands executed
   - Store logs with timestamps and session IDs
3. Session timeout and cleanup
4. IP allowlisting (optional)
5. Maximum concurrent sessions = 1

#### Phase D8: Polish and Optimisation (2 hr)

1. Mobile-responsive frontend
2. Keyboard shortcuts (Enter to send, Ctrl+C to interrupt)
3. Syntax highlighting for code blocks
4. File tree browser sidebar (read-only view of project structure)
5. Search integration (show Grep/Glob results inline)

### 5.4 Pros

| Advantage | Detail |
|---|---|
| Full Claude Code power | All tools: file editing, shell, search, git — everything |
| Purpose-built UI | Better than a terminal — rich diffs, file trees, tool visualisation |
| Programmable | Can add custom workflows, presets, and automations |
| Approval workflow | Granular control over what Claude can do per session |
| Extensible | Can integrate with Drupal, add file upload, context injection |
| Modern architecture | WebSocket streaming, responsive UI |
| Audit trail | Full logging of every action Claude takes |
| Session management | Multiple named sessions, history, resume |

### 5.5 Cons

| Disadvantage | Detail |
|---|---|
| Most complex to build | 15+ hours of development across 8 phases |
| SDK maturity | Claude Code SDK is relatively new — API may change |
| Maintenance burden | Custom frontend + backend + Drupal module = three codebases |
| Resource usage | Node.js backend + Claude Code process per session |
| Security surface | Full tool access from a web interface requires careful sandboxing |
| Over-engineering risk | Building a web IDE when a terminal might suffice |
| Dependency on SDK | If Anthropic changes SDK APIs, the integration breaks |
| Testing complexity | Hard to automated-test a system with LLM-driven tool use |

---

## 6. Comparison Matrix

| Criterion | A: ttyd | B: Guacamole | C: Drupal API | D: SDK Backend |
|---|---|---|---|---|
| **Claude Code tools** | Full | Full | None | Full |
| **Setup time** | ~4 hr | ~7 hr | ~8 hr | ~17 hr |
| **Maintenance** | Low | Medium | Low | High |
| **Security** | Basic (auth + TLS) | Enterprise (MFA, recording) | Drupal-native | Custom (good if done right) |
| **Mobile UX** | Poor (terminal) | Fair (SSH terminal) | Good (chat UI) | Good (custom UI) |
| **Resource usage** | Minimal (~10MB) | Heavy (~500MB+) | Minimal (Drupal only) | Medium (~200MB) |
| **Drupal integration** | iframe | iframe/link | Native | Module or standalone |
| **Session persistence** | tmux | tmux | Database | SDK sessions |
| **Audit trail** | Manual (tmux log) | Built-in recording | Database log | Custom logging |
| **Complexity** | Very low | Medium | Medium | High |
| **Risk** | Shell exposure | Overengineered | No CLI access | SDK instability |

---

## 7. Recommendation

### For immediate use: Option A (ttyd)

ttyd provides the fastest path to remote Claude Code access with minimal complexity. Combined with nginx TLS and basic auth, it is secure enough for single-user access. Pair with tmux for session persistence.

**Estimated time to production: 4 hours.**

### For long-term investment: Option D (SDK Backend)

If the user wants a polished, purpose-built web interface with rich tool visualisation and granular approval workflows, Option D is the most capable. However, it requires significant development effort and ongoing maintenance.

**Estimated time to production: 17 hours across 8 phases.**

### Not recommended: Option B (Guacamole)

While Guacamole is excellent software, it is overengineered for this use case. The Java/Tomcat stack adds significant resource overhead for a single-user SSH terminal. The MFA and session recording features can be achieved with simpler tools.

### Viable alternative: Option C (Drupal API)

If the user only needs conversational Claude access (no file editing or shell commands), Option C provides the cleanest Drupal-native solution. However, it fundamentally cannot replace Claude Code — it is a different tool.

---

## 8. Hybrid Approach

Options are not mutually exclusive. A pragmatic path:

1. **Phase 1:** Deploy Option A (ttyd) for immediate Claude Code access (4 hr)
2. **Phase 2:** Build Option C (Drupal API chat) for lightweight queries that don't need CLI tools (8 hr)
3. **Phase 3 (future):** Evaluate Option D when the Claude Code SDK matures (17 hr)

This gives immediate CLI access, a convenient chat interface for simple questions, and a path to a richer experience in the future.

---

## 9. Success Criteria

- [ ] Claude Code accessible from a web browser over HTTPS
- [ ] Authentication prevents unauthorised access
- [ ] Session survives page refresh / reconnection
- [ ] Usable on mobile devices (at minimum for Option C)
- [ ] No credentials exposed in URL, logs, or client-side code
- [ ] Response latency acceptable for interactive use (<2s for terminal, <5s for API)

---

## 10. Open Questions

1. **DNS:** Should this live at `claude.nwpcode.org`, a subpath like `nwp.nwpcode.org/claude`, or elsewhere?
2. **User:** Which system user should Claude Code sessions run as? (`gitlab`, a dedicated `claude` user, or containerised?)
3. **Scope:** Should Claude Code have access to all of `/home/rob/nwp` or a restricted subset?
4. **API budget:** For Option C, what monthly API spend is acceptable?
5. **SDK availability:** Is the Claude Code SDK currently available for programmatic use, or is it still in preview?

---

*Last Updated: 2026-03-23*
