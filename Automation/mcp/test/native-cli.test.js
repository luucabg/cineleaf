import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { NativeCliAdapter } from "../src/native-cli.js";

test("parses structured native CLI output without using a shell", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-cli-test-"));
  const fake = path.join(root, "fake.mjs");
  const count = path.join(root, "calls.txt");
  const clip = path.join(root, "clip.mp4");
  await writeFile(clip, "media", "utf8");
  await writeFile(fake, `import{appendFileSync}from'node:fs';appendFileSync(${JSON.stringify(count)},'1');process.stdout.write(JSON.stringify({ok:true,data:{kind:'video',durationSeconds:3}})+'\\n')`, "utf8");
  const adapter = new NativeCliAdapter({ executable: process.execPath, prefixArguments: [fake] });

  const result = await adapter.inspectMedia(clip);
  await adapter.inspectMedia(clip);

  assert.equal(result.kind, "video");
  assert.equal(result.durationSeconds, 3);
  assert.equal(await readFile(count, "utf8"), "1");
});

test("reassembles progress messages split across native stderr chunks", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-cli-progress-"));
  const fake = path.join(root, "fake-progress.mjs");
  await writeFile(fake, `process.stderr.write('{"type":"pro');setTimeout(()=>{process.stderr.write('gress","progress":0.5}\\n');process.stdout.write(JSON.stringify({ok:true,data:{path:'out.mp4'}})+'\\n')},10)`, "utf8");
  const adapter = new NativeCliAdapter({ executable: process.execPath, prefixArguments: [fake] });
  const progress = [];

  await adapter.renderProject("project.cineleaf", "out.mp4", { resolution: "p720", codec: "h264", quality: "compact" }, undefined, value => progress.push(value));

  assert.deepEqual(progress, [0.5]);
});
