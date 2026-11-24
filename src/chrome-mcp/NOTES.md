Lets Claude Code and Copilot CLI inside any devcontainer drive a Chrome running on your host, via the
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp) server. All containers share one
agent Chrome, so a login made once works everywhere.

## Use

**In `devcontainer.json`:**

```jsonc
"features": {
  "ghcr.io/devcontainers/features/node:1": {},          // skip if the image has Node
  "ghcr.io/nevva/devcontainer-features/chrome-mcp:1": {}
},
// On the host, whenever the container opens: download start-agent-chrome to ~/.local/bin the first time, then
// start the agent Chrome (port 9333, profile ~/.chrome-agent-shared). No-op when it is already running.
"initializeCommand": "f=\"$HOME/.local/bin/start-agent-chrome\"; [ -x \"$f\" ] || { mkdir -p \"${f%/*}\" && curl -fsSLo \"$f\" https://raw.githubusercontent.com/nevva/devcontainer-features/main/host/start-agent-chrome.sh && chmod +x \"$f\"; }; \"$f\" || true"
```

macOS and Linux hosts only. To update the script, delete `~/.local/bin/start-agent-chrome`; the next container
open downloads it again.

First time only: log in to the sites the agent needs in the agent Chrome window.

Rebuild, then restart Claude Code or run `/restart` in Copilot CLI.

## What it does

- **Build:** installs `socat`, `iproute2` and `curl` (apt-get images), and the bridge as `/usr/local/bin/chrome-mcp`.
- **Every container start** (`postStartCommand`): `chrome-mcp install` registers `chrome-devtools` in
  `~/.copilot/mcp-config.json` (or `$COPILOT_HOME`) and in Claude Code's local scope for the workspace repo, if
  `claude` is installed. It runs at start, not build, so the registration lands in config volumes mounted over the
  home directory.
- **When an agent starts the server:** `chrome-mcp run` opens a socat tunnel from `127.0.0.1:<localPort>` to
  `<hostAddr>:<hostPort>` and execs `npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:<localPort>`.
- `chrome-mcp uninstall` removes both registrations.

The tunnel exists because Chrome's DevTools endpoint rejects a `Host` header that isn't localhost or an IP, so
`host.docker.internal` can't be used directly.

## Requirements and gotchas

- Node/npx in the container (the node feature, or an image that has it).
- Host reachability: `host.docker.internal` (Docker Desktop) or `host.rancher-desktop.internal` (Rancher Desktop,
  preferred when it resolves). Plain Docker on Linux needs
  `"runArgs": ["--add-host=host.docker.internal:host-gateway"]`; a feature can't add it.
- All containers share one agent Chrome. Agents running at the same time in different containers can switch tabs
  under each other.
- The agent Chrome has remote debugging enabled and stays logged in. Use accounts you're comfortable letting an
  agent act as.

## Overrides

- Host: `CHROME_AGENT_PORT` (9333), `CHROME_AGENT_PROFILE` (`shared`), `CHROME_BIN`.
- Container: the `hostAddr`, `hostPort` and `localPort` options, or `CHROME_HOST_ADDR`, `CHROME_HOST_PORT`,
  `CHROME_LOCAL_PORT` and `REPO_ROOT` when running `chrome-mcp install` by hand. Host and local ports differ on
  purpose, so a VS Code port forward can't loop into the tunnel.
