import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import test from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { createMcpServer } from "../src/server.js";

test("advertises focused AI tools and returns structured capability data", async () => {
  const root = await mkdtemp(`${tmpdir()}/cineleaf-mcp-`);
  const adapter = {
    async inspectMedia() { return { kind: "video", durationSeconds: 5, width: 1920, height: 1080, frameRate: 30, hasAudio: true, fileType: "mp4", fileSize: 1 }; },
    async validateProject() { return { valid: true }; },
    async renderProject() { return {}; }
  };
  const server = createMcpServer({ roots: [root], adapter });
  const client = new Client({ name: "test", version: "1.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  try {
    const listed = await client.listTools();
    assert.deepEqual(listed.tools.map(tool => tool.name).sort(), [
      "cineleaf_capabilities", "cineleaf_create_video", "cineleaf_create_video_batch", "cineleaf_edit_project", "cineleaf_inspect_project"
    ]);
    const result = await client.callTool({ name: "cineleaf_capabilities", arguments: {} });
    assert.equal(result.structuredContent.protocolVersion, 1);
    assert.equal(result.structuredContent.localOnly, true);
  } finally {
    await client.close();
    await server.close();
  }
});
