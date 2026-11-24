#!/bin/sh
# Installs socat, ss and curl, and the bridge as /usr/local/bin/chrome-mcp. The feature's postStartCommand runs
# `chrome-mcp install`, which registers the MCP server in the volumes and repo the container starts with.
set -eu

dir=/usr/local/share/chrome-mcp

for port in "${HOSTPORT:-9333}" "${LOCALPORT:-9222}"; do
  case "$port" in
    '' | *[!0-9]*) echo "chrome-mcp: port '$port' is not a number." >&2; exit 1 ;;
  esac
done
case "${HOSTADDR:-}" in
  *[!A-Za-z0-9.:_-]*) echo "chrome-mcp: hostAddr '$HOSTADDR' is not a host name or IP." >&2; exit 1 ;;
esac

missing=""
command -v socat >/dev/null 2>&1 || missing="socat"
command -v ss >/dev/null 2>&1 || missing="$missing iproute2"
command -v curl >/dev/null 2>&1 || missing="$missing curl ca-certificates"
if [ -n "$missing" ]; then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "chrome-mcp: install$missing first; only apt-get images are handled." >&2
    exit 1
  fi
  apt-get update -y
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $missing
  rm -rf /var/lib/apt/lists/*
fi

install -d "$dir"
install -m 755 "$(dirname "$0")/chrome-host-bridge.sh" "$dir/chrome-host-bridge.sh"
ln -sf "$dir/chrome-host-bridge.sh" /usr/local/bin/chrome-mcp
cat >"$dir/defaults" <<EOF
CHROME_MCP_HOST_ADDR='${HOSTADDR:-}'
CHROME_MCP_HOST_PORT='${HOSTPORT:-9333}'
CHROME_MCP_LOCAL_PORT='${LOCALPORT:-9222}'
EOF

command -v npx >/dev/null 2>&1 ||
  echo "chrome-mcp: no Node in the image yet; the MCP server runs with npx, so add ghcr.io/devcontainers/features/node." >&2
echo "chrome-mcp: installed /usr/local/bin/chrome-mcp."
