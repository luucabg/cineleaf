import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { AutomationError, ProjectService } from "../src/project-service.js";

class FakeAdapter {
  constructor() { this.renderCalls = []; }
  async inspectMedia(mediaPath) {
    return mediaPath.endsWith(".mp3")
      ? { kind: "audio", durationSeconds: 30, hasAudio: true, fileType: "mp3", fileSize: 100 }
      : { kind: "video", durationSeconds: 60, width: 1920, height: 1080, frameRate: 30, hasAudio: true, fileType: "mp4", fileSize: 200 };
  }
  async validateProject() { return { valid: true }; }
  async renderProject(projectPath, outputPath, options) {
    this.renderCalls.push({ projectPath, outputPath, options });
    return { path: outputPath, durationSeconds: 10, width: 1920, height: 1080, encoder: "test" };
  }
}

async function setup() {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-ai-"));
  const adapter = new FakeAdapter();
  return { root, adapter, service: new ProjectService({ roots: [root], adapter }) };
}

test("dry run validates and returns a deterministic summary without writing", async () => {
  const { root, service } = await setup();
  const projectPath = path.join(root, "draft.cineleaf");
  const result = await service.createVideo({
    projectPath,
    name: "Draft",
    media: [{ path: path.join(root, "one.mp4"), durationSeconds: 4 }],
    dryRun: true
  });

  assert.equal(result.written, false);
  assert.equal(result.summary.clipCount, 1);
  await assert.rejects(readFile(path.join(projectPath, "project.json")));
});

test("writes a valid v2 package atomically and renders only with explicit confirmation", async () => {
  const { root, adapter, service } = await setup();
  const projectPath = path.join(root, "batch-one.cineleaf");
  const outputPath = path.join(root, "batch-one.mp4");
  const result = await service.createVideo({
    projectPath,
    outputPath,
    name: "Batch one",
    canvasPreset: "landscape16x9",
    frameRate: 30,
    media: [
      { path: path.join(root, "one.mp4"), startSeconds: 0, sourceStartSeconds: 2, durationSeconds: 5 },
      { path: path.join(root, "two.mp4"), startSeconds: 5, durationSeconds: 5 }
    ],
    texts: [{ text: "Hello", startSeconds: 1, durationSeconds: 2 }],
    idempotencyKey: "video-001",
    confirmWrite: true,
    overwrite: false
  });

  const document = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));
  assert.equal(document.formatVersion, 2);
  assert.equal(document.timeline.tracks.flatMap(track => track.clips).length, 3);
  assert.deepEqual(document.timeline.tracks[0].clips[0].duration, { value: 5, timescale: 1 });
  assert.equal(result.written, true);
  assert.equal(result.rendered, true);
  assert.equal(adapter.renderCalls.length, 1);
});

test("allocates another compatible track for overlapping clips", async () => {
  const { root, service } = await setup();
  const result = await service.createVideo({
    projectPath: path.join(root, "overlap.cineleaf"),
    media: [
      { path: path.join(root, "one.mp4"), startSeconds: 0, durationSeconds: 10 },
      { path: path.join(root, "two.mp4"), startSeconds: 2, durationSeconds: 3 }
    ],
    dryRun: true
  });

  assert.equal(result.summary.videoTrackCount, 2);
});

test("rejects paths outside allowed roots and writes without confirmation", async () => {
  const { root, service } = await setup();
  await assert.rejects(
    service.createVideo({ projectPath: path.join(root, "..", "escape.cineleaf"), media: [], dryRun: true }),
    error => error instanceof AutomationError && error.code === "path_outside_allowed_roots"
  );
  await assert.rejects(
    service.createVideo({ projectPath: path.join(root, "unsafe.cineleaf"), media: [], dryRun: false }),
    error => error instanceof AutomationError && error.code === "confirmation_required"
  );
});

test("retries with the same idempotency key do not render twice", async () => {
  const { root, adapter, service } = await setup();
  const request = {
    projectPath: path.join(root, "same.cineleaf"),
    outputPath: path.join(root, "same.mp4"),
    media: [{ path: path.join(root, "one.mp4"), durationSeconds: 2 }],
    idempotencyKey: "same-job",
    confirmWrite: true
  };
  const first = await service.createVideo(request);
  const second = await service.createVideo(request);

  assert.equal(first.idempotentReplay, false);
  assert.equal(second.idempotentReplay, true);
  assert.equal(adapter.renderCalls.length, 1);
});

test("a failed render can resume safely with the same idempotency key", async () => {
  const { root, adapter, service } = await setup();
  let attempts = 0;
  adapter.renderProject = async (projectPath, outputPath) => {
    attempts += 1;
    if (attempts === 1) throw new Error("temporary encoder failure");
    return { path: outputPath, durationSeconds: 2, width: 1920, height: 1080, encoder: "test" };
  };
  const request = {
    projectPath: path.join(root, "resumable.cineleaf"),
    outputPath: path.join(root, "resumable.mp4"),
    media: [{ path: path.join(root, "one.mp4"), durationSeconds: 2 }],
    idempotencyKey: "resumable-job",
    confirmWrite: true
  };

  await assert.rejects(service.createVideo(request), /temporary encoder failure/);
  const resumed = await service.createVideo(request);
  const replay = await service.createVideo(request);

  assert.equal(resumed.rendered, true);
  assert.equal(resumed.idempotentReplay, false);
  assert.equal(replay.idempotentReplay, true);
  assert.equal(attempts, 2);
});

test("batch preserves result order and enforces the maximum", async () => {
  const { root, service } = await setup();
  const jobs = Array.from({ length: 6 }, (_, index) => ({
    projectPath: path.join(root, `${index}.cineleaf`),
    name: `Video ${index}`,
    media: [],
    dryRun: true
  }));
  const results = await service.createVideoBatch({ jobs, concurrency: 3 });
  assert.deepEqual(results.map(item => item.summary.name), jobs.map(item => item.name));
  await assert.rejects(
    service.createVideoBatch({ jobs: Array.from({ length: 33 }, () => jobs[0]) }),
    error => error instanceof AutomationError && error.code === "batch_too_large"
  );
});

test("inspects repeated media only once per video plan", async () => {
  const { root, adapter, service } = await setup();
  let calls = 0;
  const original = adapter.inspectMedia.bind(adapter);
  adapter.inspectMedia = async mediaPath => { calls += 1; return original(mediaPath); };
  const repeated = path.join(root, "same-source.mp4");
  await service.createVideo({
    projectPath: path.join(root, "deduplicated.cineleaf"),
    media: [
      { path: repeated, sourceStartSeconds: 0, durationSeconds: 2 },
      { path: repeated, sourceStartSeconds: 2, durationSeconds: 2 }
    ],
    dryRun: true
  });
  assert.equal(calls, 1);
});
