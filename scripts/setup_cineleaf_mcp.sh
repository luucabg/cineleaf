#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: $0 <allowed-directory>" >&2; exit 2; }
ROOT="$(cd "$1" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/mcp/package.json" ]]; then
  SOURCE_MCP="$SCRIPT_DIR/mcp"
else
  REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  SOURCE_MCP="$REPOSITORY_ROOT/Automation/mcp"
fi
command -v node >/dev/null || { echo "Node.js 20 or later is required." >&2; exit 1; }
command -v npm >/dev/null || { echo "npm is required." >&2; exit 1; }
MCP="${CINELEAF_MCP_INSTALL_ROOT:-$HOME/Library/Application Support/Cineleaf/Automation/mcp}"
mkdir -p "$MCP/src"
ditto "$SOURCE_MCP/package.json" "$MCP/package.json"
ditto "$SOURCE_MCP/package-lock.json" "$MCP/package-lock.json"
ditto "$SOURCE_MCP/src" "$MCP/src"
npm ci --omit=dev --prefix "$MCP"
if [[ -x "$SCRIPT_DIR/../../MacOS/CineleafCLI" ]]; then
  CINELEAF_CLI="$(cd "$SCRIPT_DIR/../../MacOS" && pwd)/CineleafCLI"
else
  CINELEAF_CLI="${CINELEAF_AUTOMATION_CLI:-/Applications/Cineleaf.app/Contents/MacOS/CineleafCLI}"
fi
CINELEAF_NODE_BINARY="$(command -v node)" node - "$MCP" "$ROOT" "$CINELEAF_CLI" <<'NODE'
const [mcp, root, cli] = process.argv.slice(2);
const configuration = { mcpServers: { cineleaf: { command: process.env.CINELEAF_NODE_BINARY, args: [`${mcp}/src/index.js`, "--root", root, "--cli", cli] } } };
require("node:fs").writeFileSync(`${mcp}/cineleaf-mcp-config.json`, `${JSON.stringify(configuration, null, 2)}\n`);
NODE
echo "MCP installed. Copy the cineleaf entry from $MCP/cineleaf-mcp-config.json"
