#!/usr/bin/env bash
# Connects Copilot CLI and Claude Code in this devcontainer to the agent
# Chrome on the host (host/start-agent-chrome.sh in nevva/devcontainer-features).
# Installed as /usr/local/bin/chrome-mcp by the chrome-mcp feature.
#
#   install    register as the `chrome-devtools` MCP server (Copilot CLI, and
#              Claude Code local scope if `claude` exists). Idempotent; the
#              feature's postStartCommand runs it.
#   run        what the agents execute: start the tunnel, then the MCP server
#   uninstall  remove both registrations
#
# Ports: host 9333, container 9222, or the feature's hostPort/localPort. They
# differ so a stray VS Code forward of container 9222 can't loop back into the
# tunnel. CHROME_HOST_ADDR / CHROME_HOST_PORT / CHROME_LOCAL_PORT at `install`
# override them; they're saved in the registration.
#
# Why the socat tunnel: Chrome's DevTools endpoint rejects a Host header that
# isn't localhost or an IP, so host.docker.internal can't be used directly.
set -uo pipefail

DEFAULTS=/usr/local/share/chrome-mcp/defaults
# shellcheck source=/dev/null
[ -f "$DEFAULTS" ] && . "$DEFAULTS"

HOST_ADDR="${CHROME_HOST_ADDR:-${CHROME_MCP_HOST_ADDR:-}}"
if [ -z "$HOST_ADDR" ]; then
  # Rancher's hostname also works in containers with an old host-gateway override.
  if getent hosts host.rancher-desktop.internal >/dev/null 2>&1; then
    HOST_ADDR="host.rancher-desktop.internal"
  else
    HOST_ADDR="host.docker.internal"
  fi
fi
HOST_PORT="${CHROME_HOST_PORT:-${CHROME_MCP_HOST_PORT:-9333}}"
LOCAL_PORT="${CHROME_LOCAL_PORT:-${CHROME_MCP_LOCAL_PORT:-9222}}"

SERVER_NAME="chrome-devtools"
MCP_CONFIG="${COPILOT_HOME:-${COPILOT_CONFIG_DIR:-$HOME/.copilot}}/mcp-config.json"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Claude Code's local scope is keyed by the repo it runs in: the repo of the
# current directory (postStartCommand runs in the workspace folder).
repo_root() {
  if [ -n "${REPO_ROOT:-}" ]; then
    echo "$REPO_ROOT"
  else
    git rev-parse --show-toplevel 2>/dev/null || pwd
  fi
}

host_chrome_hint() {
  cat <<EOF
Start the agent Chrome on your host (not in the container) with
host/start-agent-chrome.sh from https://github.com/nevva/devcontainer-features
EOF
}

install_server() {
  install_copilot
  install_claude
}

install_copilot() {
  command -v node >/dev/null 2>&1 || {
    echo "Copilot CLI: skipped, no Node (the MCP server needs npx too; add ghcr.io/devcontainers/features/node)." >&2
    return 0
  }
  mkdir -p "$(dirname "$MCP_CONFIG")"
  node -e '
    const fs = require("fs");
    const [file, name, command, hostAddr, hostPort, localPort] = process.argv.slice(1);
    let config = {};
    if (fs.existsSync(file)) {
      config = JSON.parse(fs.readFileSync(file, "utf8"));
    }
    config.mcpServers = config.mcpServers ?? {};
    config.mcpServers[name] = {
      type: "local",
      command,
      args: ["run"],
      env: {
        CHROME_HOST_ADDR: hostAddr,
        CHROME_HOST_PORT: hostPort,
        CHROME_LOCAL_PORT: localPort,
      },
      tools: ["*"],
    };
    fs.writeFileSync(file, JSON.stringify(config, null, 2) + "\n");
  ' "$MCP_CONFIG" "$SERVER_NAME" "$SELF" "$HOST_ADDR" "$HOST_PORT" "$LOCAL_PORT"
  echo "Copilot CLI: registered '${SERVER_NAME}' in ${MCP_CONFIG}."
  echo "  Run /restart in Copilot CLI to pick it up."
}

install_claude() {
  command -v claude >/dev/null 2>&1 || return 0
  local root
  root="$(repo_root)"
  (
    cd "$root" || exit 1
    claude mcp remove "$SERVER_NAME" --scope local >/dev/null 2>&1
    claude mcp add "$SERVER_NAME" --scope local \
      -e "CHROME_HOST_ADDR=${HOST_ADDR}" \
      -e "CHROME_HOST_PORT=${HOST_PORT}" -e "CHROME_LOCAL_PORT=${LOCAL_PORT}" \
      -- "$SELF" run >/dev/null
  ) || { echo "Claude Code: registration failed." >&2; return 1; }
  echo "Claude Code: registered '${SERVER_NAME}' (local scope, ${root})."
  echo "  Restart Claude Code to pick it up."
}

uninstall_server() {
  uninstall_copilot
  uninstall_claude
}

uninstall_copilot() {
  [ -f "$MCP_CONFIG" ] || { echo "No ${MCP_CONFIG} to clean up."; return; }
  node -e '
    const fs = require("fs");
    const [file, name] = process.argv.slice(1);
    const config = JSON.parse(fs.readFileSync(file, "utf8"));
    delete config.mcpServers?.[name];
    fs.writeFileSync(file, JSON.stringify(config, null, 2) + "\n");
  ' "$MCP_CONFIG" "$SERVER_NAME"
  echo "Copilot CLI: removed '${SERVER_NAME}' from ${MCP_CONFIG}."
}

uninstall_claude() {
  command -v claude >/dev/null 2>&1 || return 0
  if (cd "$(repo_root)" && claude mcp remove "$SERVER_NAME" --scope local >/dev/null 2>&1); then
    echo "Claude Code: removed '${SERVER_NAME}'."
  fi
}

# Goes through the tunnel, so it proves both socat and Chrome are up.
probe() {
  curl -sf -m 2 "http://127.0.0.1:${LOCAL_PORT}/json/version" >/dev/null 2>&1
}

listening() {
  ss -ltn "sport = :${LOCAL_PORT}" 2>/dev/null | grep -q LISTEN
}

# A socat on LOCAL_PORT that forwards somewhere other than HOST_PORT is left
# over from a previous port override; it must be replaced.
stale_tunnel_pid() {
  local pid
  pid="$(ss -ltnpH "sport = :${LOCAL_PORT}" 2>/dev/null |
    grep -o '"socat",pid=[0-9]*' | head -n1 | cut -d= -f2)"
  [ -n "$pid" ] || return 1
  tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null |
    grep -q "TCP:${HOST_ADDR}:${HOST_PORT} " && return 1
  echo "$pid"
}

# Runs as a stdio MCP server: stdout belongs to the MCP protocol, so every
# message goes to stderr and the final step is an exec of chrome-devtools-mcp.
run_server() {
  command -v socat >/dev/null 2>&1 || {
    echo "socat is required but not installed: sudo apt-get install -y socat" >&2
    exit 1
  }
  command -v npx >/dev/null 2>&1 || {
    echo "npx is required: add ghcr.io/devcontainers/features/node to devcontainer.json" >&2
    exit 1
  }

  local stale
  if stale="$(stale_tunnel_pid)"; then
    kill "$stale" 2>/dev/null
    sleep 0.5
  fi

  # The tunnel is detached (own session, stdio closed) so it outlives this
  # script and later runs reuse it.
  if ! listening; then
    setsid socat "TCP-LISTEN:${LOCAL_PORT},bind=127.0.0.1,reuseaddr,fork" \
          "TCP:${HOST_ADDR}:${HOST_PORT}" </dev/null >/dev/null 2>&1 &
    for _ in 1 2 3 4 5; do
      listening && break
      sleep 0.5
    done
  fi

  local reachable=""
  for _ in 1 2 3 4 5; do
    probe && { reachable=1; break; }
    sleep 1
  done
  if [ -z "$reachable" ]; then
    echo "Cannot reach the agent Chrome at ${HOST_ADDR}:${HOST_PORT}." >&2
    host_chrome_hint >&2
    exit 1
  fi

  exec npx -y chrome-devtools-mcp@latest --browserUrl "http://127.0.0.1:${LOCAL_PORT}"
}

case "${1:-run}" in
  install) install_server ;;
  uninstall) uninstall_server ;;
  run) run_server ;;
  *)
    echo "Usage: ${0##*/} [run|install|uninstall]" >&2
    exit 64
    ;;
esac
