#!/bin/bash
# Options reach the Copilot CLI registration; the tunnel run fails clearly when no Chrome answers.
set -e
source dev-container-features-test-lib

config="$HOME/.copilot/mcp-config.json"
check "install succeeds" chrome-mcp install
check "copilot registration" node -e '
  const s = require(process.argv[1]).mcpServers["chrome-devtools"];
  if (s.command !== "/usr/local/bin/chrome-mcp" || s.args[0] !== "run") process.exit(1);
  if (s.env.CHROME_HOST_ADDR !== "host.example.internal") process.exit(1);
  if (s.env.CHROME_HOST_PORT !== "9444" || s.env.CHROME_LOCAL_PORT !== "9223") process.exit(1);
' "$config"
check "install is idempotent" bash -c "chrome-mcp install && node -e 'process.exit(Object.keys(require(process.argv[1]).mcpServers).length === 1 ? 0 : 1)' $config"
check "run reports an unreachable Chrome" bash -c 'out=$(chrome-mcp run 2>&1 </dev/null); test $? -eq 1 && grep -q "Cannot reach the agent Chrome at host.example.internal:9444" <<<"$out"'
check "uninstall removes it" bash -c "chrome-mcp uninstall && node -e 'process.exit(require(process.argv[1]).mcpServers[\"chrome-devtools\"] ? 1 : 0)' $config"

reportResults
