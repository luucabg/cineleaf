import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { ProjectService } from "../src/project-service.js";

const adapter = {
  async inspectMedia() { return { kind: "video", durationSeconds: 20, width: 1280, height: 720, frameRate: 30, hasAudio: true, fileType: "mp4", fileSize: 1 }; },
  async validateProject() { return { valid: true }; },
  async renderProject() { throw new Error("unexpected render"); }
};

test("edits clips by stable IDs and supports a safe dry run", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-edit-"));
  const service = new ProjectService({ roots: [root], adapter });
  const projectPath = path.join(root, "edit.cineleaf");
  await service.createVideo({
    projectPath,
    media: [{ path: path.join(root, "one.mp4"), durationSeconds: 10 }],
    idempotencyKey: "create",
    confirmWrite: true
  });
  const before = await service.inspectProject({ projectPath });
  const clipId = before.clips[0].id;

  const preview = await service.editProject({
    projectPath,
    operations: [
      { type: "update_clip", clipId, opacity: 0.5, volume: 0.8, speed: 2 },
      { type: "split_clip", clipId, atSeconds: 2 },
      { type: "add_marker", atSeconds: 1, name: "Beat" }
    ],
    dryRun: true
  });
  assert.equal(preview.written, false);
  assert.equal(preview.summary.clipCount, 2);

  const unchanged = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));
  assert.equal(unchanged.timeline.markers.length, 0);
});

test("confirmed edit retries are idempotent", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-edit-retry-"));
  const service = new ProjectService({ roots: [root], adapter });
  const projectPath = path.join(root, "retry.cineleaf");
  await service.createVideo({ projectPath, media: [], idempotencyKey: "create", confirmWrite: true });
  const request = {
    projectPath,
    operations: [{ type: "add_marker", atSeconds: 1, name: "Once" }],
    dryRun: false,
    confirmWrite: true,
    idempotencyKey: "edit-once"
  };

  const first = await service.editProject(request);
  const second = await service.editProject(request);
  const project = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));

  assert.equal(first.idempotentReplay, false);
  assert.equal(second.idempotentReplay, true);
  assert.equal(project.timeline.markers.length, 1);
});

test("adds subtitle clips and applies exact timeline and transform edits", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-edit-subtitle-"));
  const service = new ProjectService({ roots: [root], adapter });
  const projectPath = path.join(root, "subtitle.cineleaf");
  await service.createVideo({
    projectPath,
    media: [{ path: path.join(root, "one.mp4"), durationSeconds: 10 }],
    idempotencyKey: "create",
    confirmWrite: true
  });
  const clipId = (await service.inspectProject({ projectPath })).clips[0].id;

  await service.editProject({
    projectPath,
    operations: [
      {
        type: "update_clip",
        clipId,
        timelineStartSeconds: 1,
        sourceStartSeconds: 2,
        durationSeconds: 3,
        positionX: 12,
        positionY: -24,
        scale: 1.25,
        rotationDegrees: 5,
        muted: true
      },
      {
        type: "add_text",
        role: "subtitle",
        text: "Subtítulo automático revisado",
        startSeconds: 1,
        durationSeconds: 2,
        positionY: 380,
        backgroundHex: "#000000AA"
      }
    ],
    dryRun: false,
    confirmWrite: true,
    idempotencyKey: "subtitle-edit"
  });

  const project = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));
  const clips = project.timeline.tracks.flatMap(track => track.clips);
  const media = clips.find(clip => clip.id === clipId);
  const subtitle = clips.find(clip => clip.role === "subtitle");
  assert.deepEqual(media.timelineStart, { value: 1, timescale: 1 });
  assert.deepEqual(media.sourceStart, { value: 2, timescale: 1 });
  assert.deepEqual(media.duration, { value: 3, timescale: 1 });
  assert.equal(media.transform.scale, 1.25);
  assert.equal(media.isVideoMuted, true);
  assert.equal(subtitle.textStyle.text, "Subtítulo automático revisado");
  assert.equal(subtitle.transform.positionY, 380);
});

test("serializes concurrent edits to the same project without losing either edit", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-edit-concurrent-"));
  const slowAdapter = { ...adapter, async validateProject(projectPath) {
    if (projectPath.includes(".validation-")) await new Promise(resolve => setTimeout(resolve, 25));
    return { valid: true };
  } };
  const service = new ProjectService({ roots: [root], adapter: slowAdapter });
  const projectPath = path.join(root, "concurrent.cineleaf");
  await service.createVideo({ projectPath, media: [], idempotencyKey: "create", confirmWrite: true });

  await Promise.all(["One", "Two"].map((name, index) => service.editProject({
    projectPath,
    operations: [{ type: "add_marker", atSeconds: index + 1, name }],
    dryRun: false,
    confirmWrite: true,
    idempotencyKey: `concurrent-${index}`
  })));

  const project = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));
  assert.deepEqual(project.timeline.markers.map(marker => marker.name).sort(), ["One", "Two"]);
});

test("splits reversed media with the same exact source ranges as the native edit engine", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-edit-reversed-"));
  const service = new ProjectService({ roots: [root], adapter });
  const projectPath = path.join(root, "reversed.cineleaf");
  await service.createVideo({
    projectPath,
    media: [{ path: path.join(root, "one.mp4"), durationSeconds: 10, speed: 2, reverse: true }],
    idempotencyKey: "create",
    confirmWrite: true
  });
  const clipId = (await service.inspectProject({ projectPath })).clips[0].id;
  await service.editProject({
    projectPath,
    operations: [{ type: "split_clip", clipId, atSeconds: 4 }],
    dryRun: false,
    confirmWrite: true,
    idempotencyKey: "split-reversed"
  });

  const project = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));
  const clips = project.timeline.tracks.flatMap(track => track.clips).filter(clip => clip.kind === "video");
  assert.deepEqual(clips.map(clip => clip.sourceStart), [{ value: 12, timescale: 1 }, { value: 0, timescale: 1 }]);
  assert.deepEqual(clips.map(clip => clip.duration), [{ value: 4, timescale: 1 }, { value: 6, timescale: 1 }]);
});

test("rejects delete operations that contain an unknown clip ID", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-edit-missing-"));
  const service = new ProjectService({ roots: [root], adapter });
  const projectPath = path.join(root, "missing.cineleaf");
  await service.createVideo({ projectPath, media: [], idempotencyKey: "create", confirmWrite: true });
  await assert.rejects(
    service.editProject({ projectPath, operations: [{ type: "delete_clips", clipIds: [crypto.randomUUID()] }], dryRun: true }),
    error => error.code === "clip_not_found"
  );
});

test("changes project resolution and fps, inserts a black pause, duplicates, and detaches audio", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-edit-utilities-"));
  const service = new ProjectService({ roots: [root], adapter });
  const projectPath = path.join(root, "utilities.cineleaf");
  await service.createVideo({
    projectPath,
    media: [{ path: path.join(root, "one.mp4"), durationSeconds: 10 }],
    idempotencyKey: "create",
    confirmWrite: true
  });
  const clipId = (await service.inspectProject({ projectPath })).clips[0].id;

  await service.editProject({
    projectPath,
    operations: [
      { type: "update_project_settings", name: "Vertical cut", canvasPreset: "vertical9x16", frameRate: 60, exportResolution: "p2160" },
      { type: "add_marker", atSeconds: 4, name: "Pause" },
      { type: "insert_gap", atSeconds: 4, durationSeconds: 2 },
      { type: "duplicate_clip", clipId },
      { type: "detach_audio", clipId }
    ],
    dryRun: false,
    confirmWrite: true,
    idempotencyKey: "utility-pass"
  });

  const project = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));
  const clips = project.timeline.tracks.flatMap(track => track.clips);
  assert.equal(project.name, "Vertical cut");
  assert.deepEqual(project.canvas, { width: 1080, height: 1920 });
  assert.equal(project.frameRate, "fps60");
  assert.equal(project.exportPreferences.resolution, "p2160");
  assert.deepEqual(project.timeline.markers[0].time, { value: 6, timescale: 1 });
  assert.equal(clips.filter(clip => clip.kind === "video").length, 3);
  assert.equal(clips.filter(clip => clip.kind === "audio").length, 1);
  assert.equal(clips.find(clip => clip.id === clipId).audioVolume, 0);
});

test("removes an arbitrary timeline range and preserves exact source continuity", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-edit-range-"));
  const service = new ProjectService({ roots: [root], adapter });
  const projectPath = path.join(root, "range.cineleaf");
  await service.createVideo({ projectPath, media: [{ path: path.join(root, "one.mp4"), durationSeconds: 10 }], idempotencyKey: "create", confirmWrite: true });

  await service.editProject({
    projectPath,
    operations: [{ type: "remove_time_range", startSeconds: 3, durationSeconds: 2 }],
    dryRun: false,
    confirmWrite: true,
    idempotencyKey: "remove-range"
  });

  const project = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));
  const clips = project.timeline.tracks[0].clips;
  assert.deepEqual(clips.map(clip => clip.timelineStart), [{ value: 0, timescale: 1 }, { value: 3, timescale: 1 }]);
  assert.deepEqual(clips.map(clip => clip.duration), [{ value: 3, timescale: 1 }, { value: 5, timescale: 1 }]);
  assert.deepEqual(clips[1].sourceStart, { value: 5, timescale: 1 });
});

test("rejects a black pause after all timeline content instead of reporting a no-op", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "cineleaf-edit-gap-end-"));
  const service = new ProjectService({ roots: [root], adapter });
  const projectPath = path.join(root, "gap-end.cineleaf");
  await service.createVideo({ projectPath, media: [{ path: path.join(root, "one.mp4"), durationSeconds: 10 }], idempotencyKey: "create", confirmWrite: true });

  await assert.rejects(
    service.editProject({ projectPath, operations: [{ type: "insert_gap", atSeconds: 10, durationSeconds: 1 }], dryRun: true }),
    error => error.code === "invalid_gap"
  );
});
