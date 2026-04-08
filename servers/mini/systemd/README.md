# mini systemd units

Source of truth for the systemd --user units that run on **mini**
(Beelink Ryzen AI Max+ 395) as part of F21 Phase 3a. If mini's disk
dies, re-provisioning starts from the files in this directory.

See [F21 Phase 3a](../../../docs/proposals/F21-distributed-build-deploy-pipeline.md#phase-3a--mini-as-local-llm-agent-reversible)
and [`docs/guides/local-llm.md`](../../../docs/guides/local-llm.md)
for the rationale behind each environment flag.

## Units in this directory

| File | Purpose |
|---|---|
| `ollama.service` | The ollama daemon itself. Type=simple, restarts on failure, pins `OLLAMA_HOST`, `OLLAMA_VULKAN`, `OLLAMA_CONTEXT_LENGTH`. |
| `ollama-health.service` | Oneshot that runs `~/.local/bin/ollama-health-check`. Ordered `After=ollama.service`. |
| `ollama-health.timer` | Fires the health check on boot (after 60 s) and every 5 minutes thereafter. Persistent. |

The health check script itself lives at
[`../bin/ollama-health-check`](../bin/ollama-health-check).

## Install on a fresh mini

Assumes ollama is already installed at `~/.local/bin/ollama` and
`loginctl enable-linger rob` has been run once (these are separate
steps in the Phase 3a provisioning plan).

```bash
# 1. Copy unit files into place
mkdir -p ~/.config/systemd/user
cp servers/mini/systemd/ollama.service            ~/.config/systemd/user/
cp servers/mini/systemd/ollama-health.service     ~/.config/systemd/user/
cp servers/mini/systemd/ollama-health.timer       ~/.config/systemd/user/

# 2. Copy the health-check script
mkdir -p ~/.local/bin
cp servers/mini/bin/ollama-health-check ~/.local/bin/
chmod +x ~/.local/bin/ollama-health-check

# 3. Enable everything
systemctl --user daemon-reload
systemctl --user enable --now ollama.service
systemctl --user enable --now ollama-health.timer

# 4. Verify
systemctl --user status ollama.service
systemctl --user list-timers ollama-health.timer
~/.local/bin/ollama-health-check
```

## Operational notes

- **`loginctl enable-linger rob`** is the only sudo step in the whole
  stack. Without linger, these user units stop at logout and mini is
  almost always headless / logged out.
- **All three files together are what survives a reboot.** The reboot
  test that Phase 3a uses as its gate criterion depends on linger +
  both units being enabled + `ollama.service` being wired into
  `default.target`.
- **`ollama-health.service` is dev-free by design.** It runs the local
  `ollama-health-check` script, not `pl mini llm health`. The dev-side
  `pl mini llm health` command is interactive/operator-facing and SSHes
  in from outside; running it from mini against mini would self-loop
  and is slower for no benefit.
- **Don't add the endpoint to the LAN.** `OLLAMA_HOST=127.0.0.1:11434`
  is load-bearing — the health check's "loopback bind" test will fail
  loudly if the binding drifts. See
  [`docs/guides/local-llm.md`](../../../docs/guides/local-llm.md) for
  the interim SSH-tunnel pattern that replaces LAN exposure until
  Headscale is up.
