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
