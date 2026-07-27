#!/usr/bin/env node
import path from "node:path";
import process from "node:process";

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { NativeCliAdapter } from "./native-cli.js";
import { createMcpServer } from "./server.js";

const options = parseArguments(process.argv.slice(2));
const roots = options.roots.length > 0
  ? options.roots
  : (process.env.CINELEAF_ALLOWED_ROOTS?.split(path.delimiter).filter(Boolean) ?? [process.cwd()]);
const adapter = new NativeCliAdapter({ executable: options.cli ?? process.env.CINELEAF_AUTOMATION_CLI });
const server = createMcpServer({ roots: roots.map(item => path.resolve(item)), adapter });
const transport = new StdioServerTransport();

process.on("SIGINT", async () => { await server.close(); process.exit(0); });
process.on("SIGTERM", async () => { await server.close(); process.exit(0); });
await server.connect(transport);
console.error(`Cineleaf MCP ready; ${roots.length} allowed root(s).`);

function parseArguments(args) {
  const result = { roots: [], cli: undefined };
  for (let index = 0; index < args.length; index++) {
    if (args[index] === "--root" && args[index + 1]) result.roots.push(args[++index]);
    else if (args[index] === "--cli" && args[index + 1]) result.cli = args[++index];
    else throw new Error("Usage: cineleaf-mcp [--root <allowed-directory>]... [--cli <native-cli-path>]");
  }
  return result;
}
