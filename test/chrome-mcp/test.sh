#!/bin/bash
# Default options on a bare image: tools and the bridge are installed, `install` tolerates missing Node and Claude.
set -e
source dev-container-features-test-lib

check "socat" command -v socat
check "ss" command -v ss
check "curl" command -v curl
check "bridge on PATH" test -x /usr/local/bin/chrome-mcp
check "default host port" grep -qx "CHROME_MCP_HOST_PORT='9333'" /usr/local/share/chrome-mcp/defaults
check "default local port" grep -qx "CHROME_MCP_LOCAL_PORT='9222'" /usr/local/share/chrome-mcp/defaults
check "install succeeds" chrome-mcp install
check "unknown command exits 64" bash -c 'chrome-mcp bogus; test $? -eq 64'

reportResults
