#!/usr/bin/env bash
# Run on the HOST (macOS or Linux), not in the devcontainer.
#
# Starts a separate Chrome for the AI agents in your devcontainers to drive,
# with its own profile so your everyday browser and logins stay untouched.
# Containers connect through the chrome-mcp feature
# (ghcr.io/nevva/devcontainer-features/chrome-mcp).
#
# One agent Chrome is shared by every devcontainer (same port + profile), so
# logins made once are reused everywhere.
#
# Env overrides: CHROME_AGENT_PORT (default 9333), CHROME_AGENT_PROFILE
# (default "shared"), CHROME_BIN.
#
# Must stay compatible with bash 3.2, the macOS system bash.
set -euo pipefail

PORT="${CHROME_AGENT_PORT:-9333}"
PROFILE="$HOME/.chrome-agent-${CHROME_AGENT_PROFILE:-shared}"

if [ -f /.dockerenv ] || [ -n "${REMOTE_CONTAINERS:-}" ]; then
  echo "Run this on your host, not inside the devcontainer." >&2
  exit 1
fi

find_chrome() {
  if [ -n "${CHROME_BIN:-}" ]; then
    echo "$CHROME_BIN"
    return
  fi
  local candidate
  for candidate in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return
    fi
  done
  for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return
    fi
  done
  return 1
}

devtools_up() {
  curl -sf -m 2 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1
}

port_taken() {
  (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null
}

next_steps() {
  cat <<EOF

Log in to the sites the agent needs in that window; the profile keeps them.
Containers with the chrome-mcp feature register the MCP server on start;
then restart Copilot CLI (/restart) or Claude Code.
EOF
}

if devtools_up; then
  echo "Agent Chrome is already running on port ${PORT} (profile ${PROFILE})."
  next_steps
  exit 0
fi

if port_taken; then
  echo "Port ${PORT} is in use by something that isn't Chrome DevTools." >&2
  echo "Free it, or pick another port with CHROME_AGENT_PORT=<port> here and" >&2
  echo "the chrome-mcp feature's hostPort option in devcontainer.json." >&2
  exit 1
fi

chrome="$(find_chrome)" || {
  echo "Chrome not found. Set CHROME_BIN to the Chrome executable." >&2
  exit 1
}

mkdir -p "$PROFILE"
# --remote-debugging-port binds 127.0.0.1 only; host.docker.internal (or
# Rancher Desktop's equivalent) still reaches it from the container.
nohup "$chrome" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port="$PORT" \
  --no-first-run \
  --no-default-browser-check >/dev/null 2>&1 &

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if devtools_up; then
    echo "Agent Chrome started on port ${PORT} (profile ${PROFILE})."
    next_steps
    exit 0
  fi
  sleep 0.5
done

echo "Chrome launched but DevTools didn't answer on port ${PORT} within 10s." >&2
exit 1
