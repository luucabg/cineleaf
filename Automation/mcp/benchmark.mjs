import { performance } from "node:perf_hooks";
import path from "node:path";

import { ProjectService } from "./src/project-service.js";

const root = path.resolve(process.cwd(), ".benchmark-root");
const source = path.join(root, "source.mp4");
const adapter = {
  async inspectMedia() {
    return { kind: "video", durationSeconds: 600, width: 1920, height: 1080, frameRate: 30, hasAudio: true, fileType: "mp4", fileSize: 1_000_000 };
  },
  async validateProject() { return { valid: true }; },
  async renderProject() { throw new Error("The benchmark is planning-only and must not render."); }
};
const service = new ProjectService({ roots: [root], adapter });
const jobs = Array.from({ length: 32 }, (_, jobIndex) => ({
  projectPath: path.join(root, `video-${jobIndex}.cineleaf`),
  name: `Video ${jobIndex}`,
  media: Array.from({ length: 100 }, (_, clipIndex) => ({
    path: source,
    sourceStartSeconds: clipIndex * 2,
    durationSeconds: 2
  })),
  dryRun: true
}));

for (let index = 0; index < 3; index += 1) await service.createVideoBatch({ jobs, concurrency: 2 });
const samples = [];
for (let index = 0; index < 20; index += 1) {
  const start = performance.now();
  await service.createVideoBatch({ jobs, concurrency: 2 });
  samples.push(performance.now() - start);
}
samples.sort((left, right) => left - right);
const median = samples[Math.floor(samples.length / 2)];
process.stdout.write(`${JSON.stringify({
  runtime: process.version,
  videosPerBatch: jobs.length,
  clipsPerVideo: jobs[0].media.length,
  phase: "MCP request validation, exact planning, and temporary project write/delete; no native validation, media decode, or export",
  milliseconds: {
    minimum: Number(samples[0].toFixed(3)),
    median: Number(median.toFixed(3)),
    maximum: Number(samples.at(-1).toFixed(3))
  }
}, null, 2)}\n`);
