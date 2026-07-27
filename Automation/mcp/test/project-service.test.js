import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { AutomationError, ProjectService } from "../src/project-service.js";

class FakeAdapter {
  constructor() { this.renderCalls = []; this.audioCalls = []; this.frameCalls = []; }
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
  async extractAudio(inputPath, outputPath, options) {
    this.audioCalls.push({ inputPath, outputPath, options });
    await writeFile(outputPath, "audio", "utf8");
    return { path: outputPath, durationSeconds: options.durationSeconds ?? 60, hasAudio: true };
  }
  async extractFrame(inputPath, outputPath, options) {
    this.frameCalls.push({ inputPath, outputPath, options });
    await writeFile(outputPath, "png", "utf8");
    return { path: outputPath, width: 1920, height: 1080 };
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

test("rejects an output overwrite unless overwrite is explicitly confirmed", async () => {
  const { root, service } = await setup();
  const outputPath = path.join(root, "existing.mp4");
  await writeFile(outputPath, "keep me", "utf8");
  await assert.rejects(
    service.createVideo({
      projectPath: path.join(root, "new.cineleaf"), outputPath, media: [],
      dryRun: false, confirmWrite: true, idempotencyKey: "no-output-overwrite"
    }),
    error => error instanceof AutomationError && error.code === "output_exists"
  );
});

test("canonical path checks reject a junction or symlink that escapes an allowed root", async () => {
  const { root, service } = await setup();
  const outside = await mkdtemp(path.join(tmpdir(), "cineleaf-outside-"));
  const link = path.join(root, "outside-link");
  await symlink(outside, link, process.platform === "win32" ? "junction" : "dir");
  await assert.rejects(
    service.createVideo({ projectPath: path.join(link, "escape.cineleaf"), media: [], dryRun: true }),
    error => error instanceof AutomationError && error.code === "path_outside_allowed_roots"
  );
});

test("an explicitly allowed filesystem root includes its descendants", async () => {
  const { root, adapter } = await setup();
  const service = new ProjectService({ roots: [path.parse(root).root], adapter });
  const result = await service.createVideo({ projectPath: path.join(root, "drive-root.cineleaf"), media: [], dryRun: true });
  assert.equal(result.summary.clipCount, 0);
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

test("batch stops scheduling new jobs after a failure and waits for in-flight work", async () => {
  const { root, adapter } = await setup();
  let validationCalls = 0;
  let inFlightSettled = false;
  adapter.validateProject = async () => {
    const call = validationCalls++;
    if (call === 0) throw new Error("invalid first job");
    await new Promise(resolve => setTimeout(resolve, 30));
    inFlightSettled = true;
    return { valid: true };
  };
  const service = new ProjectService({ roots: [root], adapter });
  const jobs = Array.from({ length: 4 }, (_, index) => ({
    projectPath: path.join(root, `failure-${index}.cineleaf`), media: [], dryRun: true
  }));

  await assert.rejects(service.createVideoBatch({ jobs, concurrency: 2 }), /invalid first job/);

  assert.equal(validationCalls, 2);
  assert.equal(inFlightSettled, true);
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

test("previews and atomically writes extracted audio and frames inside allowed roots", async () => {
  const { root, adapter, service } = await setup();
  const source = path.join(root, "source.mp4");
  const audio = path.join(root, "source-audio.m4a");
  const frame = path.join(root, "frame.png");
  await writeFile(source, "media", "utf8");

  const audioPlan = await service.extractAudio({ sourcePath: source, outputPath: audio, startSeconds: 2, durationSeconds: 3, dryRun: true });
  assert.equal(audioPlan.written, false);
  assert.equal(adapter.audioCalls.length, 0);
  await service.extractAudio({ sourcePath: source, outputPath: audio, startSeconds: 2, durationSeconds: 3, dryRun: false, confirmWrite: true });
  await service.extractFrame({ sourcePath: source, outputPath: frame, atSeconds: 1, dryRun: false, confirmWrite: true });

  assert.equal(await readFile(audio, "utf8"), "audio");
  assert.equal(await readFile(frame, "utf8"), "png");
  assert.equal(adapter.audioCalls[0].options.startSeconds, 2);
  assert.equal(adapter.frameCalls[0].options.atSeconds, 1);
});

test("derived media never replaces a source or existing output without explicit overwrite", async () => {
  const { root, service } = await setup();
  const source = path.join(root, "source.m4a");
  const output = path.join(root, "existing.m4a");
  await writeFile(source, "source", "utf8");
  await writeFile(output, "keep", "utf8");

  await assert.rejects(
    service.extractAudio({ sourcePath: source, outputPath: source, dryRun: false, confirmWrite: true }),
    error => error.code === "output_conflicts_with_source"
  );
  await assert.rejects(
    service.extractAudio({ sourcePath: source, outputPath: output, dryRun: false, confirmWrite: true }),
    error => error.code === "output_exists"
  );
  assert.equal(await readFile(output, "utf8"), "keep");
});

test("a failed verified overwrite preserves the previous derived output and cleans temporary files", async () => {
  const { root, adapter, service } = await setup();
  const source = path.join(root, "source.m4a");
  const output = path.join(root, "existing.m4a");
  await writeFile(source, "source", "utf8");
  await writeFile(output, "previous", "utf8");
  adapter.extractAudio = async (_source, temporary) => {
    await writeFile(temporary, "incomplete", "utf8");
    throw new Error("verification failed");
  };

  await assert.rejects(
    service.extractAudio({ sourcePath: source, outputPath: output, dryRun: false, confirmWrite: true, overwrite: true }),
    /verification failed/
  );

  assert.equal(await readFile(output, "utf8"), "previous");
  assert.deepEqual((await readdir(root)).sort(), ["existing.m4a", "source.m4a"]);
});
