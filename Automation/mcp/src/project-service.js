import { createHash, randomUUID } from "node:crypto";
import { existsSync, realpathSync } from "node:fs";
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import { batchSchema, createVideoSchema, editProjectSchema, extractAudioSchema, extractFrameSchema } from "./schemas.js";

const APPLE_EPOCH_SECONDS = 978307200;
const canvasSizes = {
  landscape16x9: { width: 1920, height: 1080 },
  vertical9x16: { width: 1080, height: 1920 },
  square1x1: { width: 1080, height: 1080 },
  portrait4x5: { width: 1080, height: 1350 }
};

export class AutomationError extends Error {
  constructor(code, message, details) {
    super(message);
    this.name = "AutomationError";
    this.code = code;
    this.details = details;
  }
}

export class ProjectService {
  constructor({ roots, adapter }) {
    if (!Array.isArray(roots) || roots.length === 0) throw new Error("At least one allowed root is required.");
    this.roots = roots.map(item => canonicalPath(item));
    this.adapter = adapter;
    this.projectLocks = new Map();
  }

  async createVideo(rawRequest, context = {}) {
    const request = this.#parse(createVideoSchema, rawRequest);
    const dryRun = rawRequest.dryRun ?? !request.confirmWrite;
    const projectPath = this.#allowed(request.projectPath, "projectPath");
    if (path.extname(projectPath).toLowerCase() !== ".cineleaf")
      throw new AutomationError("invalid_project_path", "Project paths must end in .cineleaf.");
    const outputPath = request.outputPath ? this.#allowed(request.outputPath, "outputPath") : undefined;
    const canonicalMedia = new Map();
    for (const clip of request.media) {
      const key = comparablePath(path.resolve(clip.path));
      if (!canonicalMedia.has(key)) canonicalMedia.set(key, this.#allowed(clip.path, "media.path"));
      clip.path = canonicalMedia.get(key);
    }
    if (outputPath && request.media.some(clip => samePath(clip.path, outputPath)))
      throw new AutomationError("output_conflicts_with_source", "outputPath cannot replace one of the source media files.");
    if (!dryRun && !request.confirmWrite) throw new AutomationError("confirmation_required", "Set confirmWrite=true after reviewing a dry run.");
    if (!dryRun && !request.idempotencyKey) throw new AutomationError("idempotency_key_required", "Writes require an idempotencyKey so retries are safe.");
    return this.#withProjectLock(projectPath, () => this.#createVideoLocked(request, dryRun, projectPath, outputPath, context));
  }

  async #createVideoLocked(request, dryRun, projectPath, outputPath, context) {
    const requestHash = hashRequest({ ...request, dryRun: false, confirmWrite: true });
    let resume;
    if (!dryRun) {
      const replay = await this.#readReplay(projectPath, request.idempotencyKey, requestHash);
      if (replay?.state === "completed") return { ...replay.result, idempotentReplay: true };
      resume = replay?.state === "pending";
      if (await exists(projectPath) && !request.overwrite && !resume)
        throw new AutomationError("project_exists", "The project already exists. Use overwrite=true only after confirming replacement.");
      if (outputPath && await exists(outputPath) && !request.overwrite && !resume)
        throw new AutomationError("output_exists", "The output file already exists. Use overwrite=true only after confirming replacement.");
    }

    let project;
    if (resume) {
      if (!await exists(path.join(projectPath, "project.json")))
        throw new AutomationError("retry_state_invalid", "The saved retry state exists but project.json is missing.");
      project = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));
    } else {
      const uniquePaths = [...new Set(request.media.map(clip => path.resolve(clip.path)))];
      const uniqueInspections = await mapLimit(uniquePaths, 4, mediaPath => this.adapter.inspectMedia(mediaPath, context.signal));
      const inspectionByPath = new Map(uniquePaths.map((mediaPath, index) => [mediaPath, uniqueInspections[index]]));
      const inspections = request.media.map(clip => inspectionByPath.get(path.resolve(clip.path)));
      project = this.#buildProject(request, inspections);
    }
    const summary = summarize(project);
    if (dryRun) {
      await this.#validateDraft(projectPath, project);
      return { written: false, rendered: false, idempotentReplay: false, projectPath, outputPath, summary };
    }

    const pendingResult = { written: true, rendered: false, idempotentReplay: false, projectPath, outputPath, summary };
    if (!resume) {
      await this.#writeProject(projectPath, project, request.overwrite);
      await this.#writeCreateMarker(projectPath, { version: 2, state: "pending", key: request.idempotencyKey, requestHash, result: pendingResult });
    }
    let renderResult;
    if (outputPath) renderResult = await this.adapter.renderProject(projectPath, outputPath, request.export, context.signal, context.onProgress);
    const result = { written: true, rendered: Boolean(renderResult), idempotentReplay: false, projectPath, outputPath, summary, render: renderResult };
    await this.#writeCreateMarker(projectPath, { version: 2, state: "completed", key: request.idempotencyKey, requestHash, result });
    return result;
  }

  async createVideoBatch(rawRequest, context = {}) {
    if (Array.isArray(rawRequest?.jobs) && rawRequest.jobs.length > 32)
      throw new AutomationError("batch_too_large", "A batch can contain at most 32 videos.");
    const request = this.#parse(batchSchema, rawRequest);
    let completed = 0;
    return mapLimit(request.jobs, request.concurrency, async job => {
      const result = await this.createVideo(job, context);
      completed += 1;
      await context.onBatchProgress?.(completed, request.jobs.length);
      return result;
    });
  }

  async inspectProject(rawRequest) {
    const projectPath = this.#allowed(rawRequest?.projectPath, "projectPath");
    const project = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));
    await this.adapter.validateProject(projectPath);
    return {
      projectPath,
      summary: summarize(project),
      assets: project.assets.map(asset => ({ id: asset.id, name: asset.displayName, kind: asset.kind, path: asset.reference.lastKnownPath })),
      clips: project.timeline.tracks.flatMap(track => track.clips.map(clip => ({
        id: clip.id, trackId: track.id, track: track.name, name: clip.name, kind: clip.kind,
        startSeconds: seconds(clip.timelineStart), durationSeconds: seconds(clip.duration), assetId: clip.assetID
      }))),
      markers: project.timeline.markers.map(marker => ({ id: marker.id, name: marker.name, atSeconds: seconds(marker.time) }))
    };
  }

  async editProject(rawRequest) {
    const request = this.#parse(editProjectSchema, rawRequest);
    const dryRun = rawRequest.dryRun ?? !request.confirmWrite;
    const projectPath = this.#allowed(request.projectPath, "projectPath");
    if (!dryRun && !request.confirmWrite) throw new AutomationError("confirmation_required", "Set confirmWrite=true after reviewing a dry run.");
    if (!dryRun && !request.idempotencyKey) throw new AutomationError("idempotency_key_required", "Writes require an idempotencyKey.");
    return this.#withProjectLock(projectPath, () => this.#editProjectLocked(request, dryRun, projectPath));
  }

  async extractAudio(rawRequest, context = {}) {
    const request = this.#parse(extractAudioSchema, rawRequest);
    const dryRun = rawRequest.dryRun ?? !request.confirmWrite;
    const sourcePath = this.#allowed(request.sourcePath, "sourcePath");
    const outputPath = this.#allowed(request.outputPath, "outputPath");
    if (path.extname(outputPath).toLowerCase() !== ".m4a")
      throw new AutomationError("invalid_output_path", "Extracted audio must use the .m4a extension.");
    this.#validateDerivedWrite(request, dryRun, sourcePath, outputPath);
    const inspection = await this.adapter.inspectMedia(sourcePath, context.signal);
    if (!inspection.hasAudio) throw new AutomationError("media_has_no_audio", "The source media does not contain an audio track.");
    validateSourceRange(inspection, request.startSeconds, request.durationSeconds);
    const plan = { operation: "extract_audio", sourcePath, outputPath, startSeconds: request.startSeconds, durationSeconds: request.durationSeconds, format: "m4a" };
    if (dryRun) return { written: false, ...plan };
    return this.#withProjectLock(outputPath, () => this.#writeDerivedOutput(
      outputPath, request.overwrite,
      temporary => this.adapter.extractAudio(sourcePath, temporary, request, context.signal),
      plan
    ));
  }

  async extractFrame(rawRequest, context = {}) {
    const request = this.#parse(extractFrameSchema, rawRequest);
    const dryRun = rawRequest.dryRun ?? !request.confirmWrite;
    const sourcePath = this.#allowed(request.sourcePath, "sourcePath");
    const outputPath = this.#allowed(request.outputPath, "outputPath");
    if (path.extname(outputPath).toLowerCase() !== ".png")
      throw new AutomationError("invalid_output_path", "Extracted frames must use the .png extension.");
    this.#validateDerivedWrite(request, dryRun, sourcePath, outputPath);
    const inspection = await this.adapter.inspectMedia(sourcePath, context.signal);
    if (inspection.kind === "audio") throw new AutomationError("media_has_no_video", "The source media does not contain a video frame.");
    if (inspection.durationSeconds != null && request.atSeconds >= inspection.durationSeconds)
      throw new AutomationError("source_range_invalid", "The requested frame is outside the source media.");
    const plan = { operation: "extract_frame", sourcePath, outputPath, atSeconds: request.atSeconds, format: "png" };
    if (dryRun) return { written: false, ...plan };
    return this.#withProjectLock(outputPath, () => this.#writeDerivedOutput(
      outputPath, request.overwrite,
      temporary => this.adapter.extractFrame(sourcePath, temporary, request, context.signal),
      plan
    ));
  }

  async #editProjectLocked(request, dryRun, projectPath) {
    const requestHash = hashRequest({ ...request, dryRun: false, confirmWrite: true });
    if (!dryRun) {
      const replay = await this.#readEditReplay(projectPath, request.idempotencyKey, requestHash);
      if (replay) return replay;
    }
    const project = JSON.parse(await readFile(path.join(projectPath, "project.json"), "utf8"));
    for (const operation of request.operations) applyOperation(project, operation);
    project.modifiedAt = appleNow();
    const summary = summarize(project);
    if (dryRun) {
      await this.#validateDraft(projectPath, project);
      return { written: false, idempotentReplay: false, projectPath, summary };
    }
    await this.#validateDraft(projectPath, project);
    await this.#replaceProjectJson(projectPath, project);
    const result = { written: true, idempotentReplay: false, projectPath, summary };
    await this.#writeEditReplay(projectPath, request.idempotencyKey, requestHash, result);
    return result;
  }

  #parse(schema, value) {
    const parsed = schema.safeParse(value);
    if (!parsed.success) throw new AutomationError("validation_error", "The automation request is invalid.", parsed.error.issues);
    return parsed.data;
  }

  #validateDerivedWrite(request, dryRun, sourcePath, outputPath) {
    if (samePath(sourcePath, outputPath))
      throw new AutomationError("output_conflicts_with_source", "outputPath cannot replace the source media file.");
    if (!dryRun && !request.confirmWrite)
      throw new AutomationError("confirmation_required", "Set confirmWrite=true after reviewing a dry run.");
  }

  #allowed(value, field) {
    if (typeof value !== "string" || value.length === 0) throw new AutomationError("validation_error", `${field} is required.`);
    const candidate = canonicalPath(value);
    if (!this.roots.some(root => isWithin(root, candidate)))
      throw new AutomationError("path_outside_allowed_roots", `${field} is outside the configured allowed roots.`, { field, candidate });
    return candidate;
  }

  async #withProjectLock(projectPath, action) {
    const previous = this.projectLocks.get(projectPath) ?? Promise.resolve();
    let release;
    const current = new Promise(resolve => { release = resolve; });
    this.projectLocks.set(projectPath, current);
    await previous;
    try { return await action(); }
    finally {
      release();
      if (this.projectLocks.get(projectPath) === current) this.projectLocks.delete(projectPath);
    }
  }

  #buildProject(request, inspections) {
    const now = appleNow();
    const assets = [];
    const tracks = [];
    const assetByPath = new Map();
    const getTrack = (kind, start, duration) => {
      let track = tracks.filter(item => item.kind === kind).find(item => item.clips.every(clip => !overlap(start, duration, seconds(clip.timelineStart), seconds(clip.duration))));
      if (!track) {
        const number = tracks.filter(item => item.kind === kind).length + 1;
        track = { id: randomUUID(), name: `${kind === "video" ? "V" : "A"}${number}`, kind, isMuted: false, isLocked: false, clips: [] };
        tracks.push(track);
      }
      return track;
    };

    request.media.forEach((input, index) => {
      const mediaPath = path.resolve(input.path);
      const inspection = inspections[index];
      let asset = assetByPath.get(mediaPath);
      if (!asset) {
        asset = makeAsset(mediaPath, inspection);
        assetByPath.set(mediaPath, asset);
        assets.push(asset);
      }
      const sourceAvailable = inspection.durationSeconds == null ? undefined : Math.max(0, inspection.durationSeconds - input.sourceStartSeconds);
      const duration = input.durationSeconds ?? (inspection.kind === "image" ? 5 : sourceAvailable == null ? undefined : sourceAvailable / input.speed);
      if (!(duration > 0)) throw new AutomationError("duration_required", `A positive duration is required for ${mediaPath}.`);
      if (sourceAvailable != null && duration * input.speed > sourceAvailable + 0.0001)
        throw new AutomationError("source_range_invalid", `The requested range exceeds ${mediaPath}.`);
      const kind = inspection.kind === "audio" ? "audio" : inspection.kind;
      const trackKind = kind === "audio" ? "audio" : "video";
      const existing = tracks.filter(item => item.kind === trackKind);
      const appendAt = existing.length === 0 ? 0 : Math.max(...existing.flatMap(item => item.clips.map(clip => seconds(clip.timelineStart) + seconds(clip.duration))), 0);
      const start = input.startSeconds ?? appendAt;
      const track = getTrack(trackKind, start, duration);
      track.clips.push(makeMediaClip(asset, kind, input, start, duration));
    });

    for (const input of request.texts) {
      const track = getTrack("video", input.startSeconds, input.durationSeconds);
      track.clips.push(makeTextClip(input));
    }
    if (!tracks.some(item => item.kind === "video")) tracks.push(emptyTrack("video", tracks));
    if (!tracks.some(item => item.kind === "audio")) tracks.push(emptyTrack("audio", tracks));
    for (const track of tracks) track.clips.sort((left, right) => seconds(left.timelineStart) - seconds(right.timelineStart));
    return {
      formatVersion: 2, id: randomUUID(), name: request.name, createdAt: now, modifiedAt: now,
      canvas: canvasSizes[request.canvasPreset], canvasPreset: request.canvasPreset, frameRate: `fps${request.frameRate}`,
      assets, timeline: { tracks, markers: [] },
      exportPreferences: { resolution: request.export.resolution, frameRate: `fps${request.frameRate}`, quality: request.export.quality, codec: request.export.codec, container: "mp4" }
    };
  }

  async #readReplay(projectPath, key, requestHash) {
    const markerPath = path.join(projectPath, ".cineleaf-ai.json");
    if (!await exists(markerPath)) return undefined;
    const marker = JSON.parse(await readFile(markerPath, "utf8"));
    if (marker.key !== key) return undefined;
    if (marker.requestHash !== requestHash) throw new AutomationError("idempotency_conflict", "That idempotencyKey was already used for a different request.");
    return { state: marker.state ?? "completed", result: marker.result };
  }

  async #writeCreateMarker(projectPath, marker) {
    const markerPath = path.join(projectPath, ".cineleaf-ai.json");
    const temporary = `${markerPath}.tmp-${randomUUID()}`;
    await writeFile(temporary, JSON.stringify(marker, null, 2), "utf8");
    await rename(temporary, markerPath);
  }

  async #writeProject(projectPath, project, overwrite) {
    const parent = path.dirname(projectPath);
    await mkdir(parent, { recursive: true });
    const temporary = path.join(parent, `${path.basename(projectPath, ".cineleaf")}.tmp-${randomUUID()}.cineleaf`);
    const backup = `${projectPath}.backup-${randomUUID()}`;
    await mkdir(temporary);
    await writeFile(path.join(temporary, "project.json"), JSON.stringify(project, null, 2), "utf8");
    let backedUp = false;
    try {
      await this.adapter.validateProject(temporary);
      if (overwrite && await exists(projectPath)) { await rename(projectPath, backup); backedUp = true; }
      await rename(temporary, projectPath);
      if (backedUp) await rm(backup, { recursive: true, force: true });
    } catch (error) {
      await rm(temporary, { recursive: true, force: true });
      if (backedUp && !await exists(projectPath)) await rename(backup, projectPath);
      throw error;
    }
  }

  async #replaceProjectJson(projectPath, project) {
    const destination = path.join(projectPath, "project.json");
    const temporary = `${destination}.tmp-${randomUUID()}`;
    await writeFile(temporary, JSON.stringify(project, null, 2), "utf8");
    await rename(temporary, destination);
  }

  async #writeDerivedOutput(outputPath, overwrite, action, plan) {
    if (await exists(outputPath) && !overwrite)
      throw new AutomationError("output_exists", "The output file already exists. Use overwrite=true only after confirming replacement.");
    const parent = path.dirname(outputPath);
    await mkdir(parent, { recursive: true });
    const extension = path.extname(outputPath);
    const temporary = path.join(parent, `.${path.basename(outputPath, extension)}.tmp-${randomUUID()}${extension}`);
    const backup = `${outputPath}.backup-${randomUUID()}`;
    let backedUp = false;
    try {
      const nativeResult = await action(temporary);
      if (!await exists(temporary)) throw new AutomationError("output_missing", "The native media engine did not create the requested output.");
      if (overwrite && await exists(outputPath)) { await rename(outputPath, backup); backedUp = true; }
      await rename(temporary, outputPath);
      if (backedUp) await rm(backup, { force: true }).catch(() => {});
      return { written: true, ...plan, result: { ...nativeResult, path: outputPath } };
    } catch (error) {
      await rm(temporary, { force: true });
      if (backedUp && !await exists(outputPath)) await rename(backup, outputPath);
      throw error;
    }
  }

  async #validateDraft(projectPath, project) {
    const requestedParent = path.dirname(projectPath);
    const parent = await exists(requestedParent) ? requestedParent : tmpdir();
    const temporary = path.join(parent, `${path.basename(projectPath, ".cineleaf")}.validation-${randomUUID()}.cineleaf`);
    await mkdir(temporary);
    try {
      await writeFile(path.join(temporary, "project.json"), JSON.stringify(project, null, 2), "utf8");
      await this.adapter.validateProject(temporary);
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  }

  async #readEditReplay(projectPath, key, requestHash) {
    const logPath = path.join(projectPath, ".cineleaf-ai-edits.json");
    if (!await exists(logPath)) return undefined;
    const log = JSON.parse(await readFile(logPath, "utf8"));
    const item = log.entries?.find(entry => entry.key === key);
    if (!item) return undefined;
    if (item.requestHash !== requestHash) throw new AutomationError("idempotency_conflict", "That idempotencyKey was already used for a different edit.");
    return { ...item.result, idempotentReplay: true };
  }

  async #writeEditReplay(projectPath, key, requestHash, result) {
    const logPath = path.join(projectPath, ".cineleaf-ai-edits.json");
    let entries = [];
    if (await exists(logPath)) entries = JSON.parse(await readFile(logPath, "utf8")).entries ?? [];
    entries.push({ key, requestHash, result });
    entries = entries.slice(-1000);
    const temporary = `${logPath}.tmp-${randomUUID()}`;
    await writeFile(temporary, JSON.stringify({ version: 1, entries }, null, 2), "utf8");
    await rename(temporary, logPath);
  }
}

function makeAsset(mediaPath, inspection) {
  const metadata = {
    fileType: inspection.fileType ?? path.extname(mediaPath).slice(1).toLowerCase(), hasAudio: Boolean(inspection.hasAudio), fileSize: inspection.fileSize ?? 0
  };
  if (inspection.durationSeconds != null) metadata.duration = rational(inspection.durationSeconds);
  if (inspection.width && inspection.height) metadata.resolution = { width: inspection.width, height: inspection.height };
  if (inspection.frameRate) metadata.frameRate = rationalRate(inspection.frameRate);
  return { id: randomUUID(), displayName: path.basename(mediaPath), kind: inspection.kind, reference: { lastKnownPath: mediaPath }, metadata };
}

function makeMediaClip(asset, kind, input, start, duration) {
  const fades = Math.min(input.fadeInSeconds, duration / 2);
  const fadeOut = Math.min(input.fadeOutSeconds, duration / 2);
  return {
    id: randomUUID(), name: asset.displayName, kind, assetID: asset.id, timelineStart: rational(start), duration: rational(duration), sourceStart: rational(input.sourceStartSeconds),
    transform: transform(input), opacity: input.opacity, isEnabled: true, isVideoMuted: input.muted, audioVolume: input.volume,
    fades: { videoIn: rational(fades), videoOut: rational(fadeOut), audioIn: rational(fades), audioOut: rational(fadeOut) },
    playbackRate: input.speed, isReversed: input.reverse, role: "standard", colorAdjustments: neutralColor(),
    effects: input.effects.map(effect => ({ id: randomUUID(), kind: effect.kind, isEnabled: true, amount: effect.amount })),
    keyframes: emptyKeyframes(),
    ...(input.transitionIn ? { transitionIn: { kind: input.transitionIn.kind, duration: rational(Math.min(input.transitionIn.durationSeconds, duration)) } } : {}),
    ...(input.transitionOut ? { transitionOut: { kind: input.transitionOut.kind, duration: rational(Math.min(input.transitionOut.durationSeconds, duration)) } } : {})
  };
}

function makeTextClip(input) {
  return {
    id: randomUUID(), name: input.text.slice(0, 80), kind: "text", timelineStart: rational(input.startSeconds), duration: rational(input.durationSeconds), sourceStart: rational(0),
    transform: transform(input), opacity: input.opacity, isEnabled: true, isVideoMuted: false, audioVolume: 1,
    fades: { videoIn: rational(0), videoOut: rational(0), audioIn: rational(0), audioOut: rational(0) },
    textStyle: { text: input.text, fontName: input.fontName, fontSize: input.fontSize, fontWeight: 0, alignment: "center", foregroundHex: input.foregroundHex, backgroundHex: input.backgroundHex, strokeHex: input.strokeHex, strokeWidth: input.strokeWidth, shadowOpacity: input.shadowOpacity, animation: input.animation },
    playbackRate: 1, isReversed: false, role: input.role, colorAdjustments: neutralColor(), effects: [], keyframes: emptyKeyframes()
  };
}

function transform(input) { return { positionX: input.positionX, positionY: input.positionY, scale: input.scale, rotationDegrees: input.rotationDegrees, cropTop: 0, cropLeading: 0, cropBottom: 0, cropTrailing: 0, contentMode: input.contentMode ?? "fit" }; }
function neutralColor() { return { exposure: 0, contrast: 1, saturation: 1, temperature: 0, tint: 0, highlights: 0, shadows: 0, sharpen: 0, vignette: 0 }; }
function emptyKeyframes() { return { positionX: [], positionY: [], scale: [], rotationDegrees: [], opacity: [], volume: [] }; }
function emptyTrack(kind, tracks) { return { id: randomUUID(), name: `${kind === "video" ? "V" : "A"}${tracks.filter(item => item.kind === kind).length + 1}`, kind, isMuted: false, isLocked: false, clips: [] }; }
function overlap(aStart, aDuration, bStart, bDuration) { return aStart < bStart + bDuration && bStart < aStart + aDuration; }
function appleNow() { return Date.now() / 1000 - APPLE_EPOCH_SECONDS; }
function seconds(value) { return value.value / value.timescale; }
function rationalRate(value) { const rates = [[23.976, 24000, 1001], [29.97, 30000, 1001], [59.94, 60000, 1001]]; const match = rates.find(item => Math.abs(item[0] - value) < 0.02); return match ? { numerator: match[1], denominator: match[2] } : { numerator: Math.round(value), denominator: 1 }; }
function rational(value) { if (!Number.isFinite(value)) throw new AutomationError("invalid_time", "Time values must be finite."); const scaled = Math.round(value * 60000); const divisor = gcd(Math.abs(scaled), 60000); return { value: scaled / divisor, timescale: 60000 / divisor }; }
function gcd(left, right) { while (right) [left, right] = [right, left % right]; return Math.max(left, 1); }
function summarize(project) { const clips = project.timeline.tracks.flatMap(track => track.clips); return { name: project.name, assetCount: project.assets.length, clipCount: clips.length, videoTrackCount: project.timeline.tracks.filter(track => track.kind === "video").length, audioTrackCount: project.timeline.tracks.filter(track => track.kind === "audio").length, durationSeconds: clips.reduce((max, clip) => Math.max(max, seconds(clip.timelineStart) + seconds(clip.duration)), 0), canvas: project.canvas, frameRate: Number(project.frameRate.slice(3)) }; }
function hashRequest(request) { return createHash("sha256").update(JSON.stringify(sortObject(request))).digest("hex"); }
function sortObject(value) { if (Array.isArray(value)) return value.map(sortObject); if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map(key => [key, sortObject(value[key])])); return value; }
async function exists(target) { try { await stat(target); return true; } catch (error) { if (error?.code === "ENOENT") return false; throw error; } }
async function mapLimit(items, concurrency, action) {
  const results = new Array(items.length);
  let next = 0;
  let failure;
  async function worker() {
    for (;;) {
      if (failure) return;
      const index = next++;
      if (index >= items.length) return;
      try { results[index] = await action(items[index], index); }
      catch (error) { failure ??= error; return; }
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, Math.max(items.length, 1)) }, worker));
  if (failure) throw failure;
  return results;
}

function applyOperation(project, operation) {
  const all = () => project.timeline.tracks.flatMap(track => track.clips.map(clip => ({ track, clip })));
  if (operation.type === "update_project_settings") {
    if ([operation.name, operation.canvasPreset, operation.frameRate, operation.exportResolution, operation.exportCodec, operation.exportQuality].every(value => value == null))
      throw new AutomationError("empty_edit", "update_project_settings needs at least one setting to change.");
    if (operation.name != null) project.name = operation.name.trim();
    if (operation.canvasPreset != null) { project.canvasPreset = operation.canvasPreset; project.canvas = canvasSizes[operation.canvasPreset]; }
    if (operation.frameRate != null) { project.frameRate = `fps${operation.frameRate}`; project.exportPreferences.frameRate = `fps${operation.frameRate}`; }
    if (operation.exportResolution != null) project.exportPreferences.resolution = operation.exportResolution;
    if (operation.exportCodec != null) project.exportPreferences.codec = operation.exportCodec;
    if (operation.exportQuality != null) project.exportPreferences.quality = operation.exportQuality;
    return;
  }
  if (operation.type === "insert_gap") {
    insertGap(project, operation.atSeconds, operation.durationSeconds);
    return;
  }
  if (operation.type === "remove_time_range") {
    removeTimeRange(project, operation.startSeconds, operation.durationSeconds);
    return;
  }
  if (operation.type === "add_marker") {
    project.timeline.markers.push({ id: randomUUID(), time: rational(operation.atSeconds), name: operation.name, colorHex: "#F7C948FF" });
    project.timeline.markers.sort((left, right) => seconds(left.time) - seconds(right.time));
    return;
  }
  if (operation.type === "add_text") {
    const clip = makeTextClip(operation);
    const track = compatibleTrack(project, "video", operation.startSeconds, operation.durationSeconds);
    track.clips.push(clip);
    track.clips.sort((left, right) => seconds(left.timelineStart) - seconds(right.timelineStart));
    return;
  }
  if (operation.type === "delete_clips") {
    const ids = new Set(operation.clipIds);
    const existing = new Set(all().map(item => item.clip.id));
    const missing = operation.clipIds.filter(id => !existing.has(id));
    if (missing.length > 0) throw new AutomationError("clip_not_found", `Clip ${missing[0]} was not found.`, { clipIds: missing });
    for (const track of project.timeline.tracks) {
      const removed = track.clips.filter(clip => ids.has(clip.id));
      if (removed.length > 0 && track.isLocked) throw new AutomationError("track_locked", `Track ${track.name} is locked.`);
      track.clips = track.clips.filter(clip => !ids.has(clip.id));
      if (operation.ripple) for (const clip of track.clips) for (const item of removed.filter(item => seconds(item.timelineStart) + seconds(item.duration) <= seconds(clip.timelineStart))) clip.timelineStart = rational(seconds(clip.timelineStart) - seconds(item.duration));
    }
    return;
  }
  const found = all().find(item => item.clip.id === operation.clipId);
  if (!found) throw new AutomationError("clip_not_found", `Clip ${operation.clipId} was not found.`);
  if (found.track.isLocked) throw new AutomationError("track_locked", `Track ${found.track.name} is locked.`);
  if (operation.type === "duplicate_clip") {
    const duplicate = structuredClone(found.clip);
    duplicate.id = randomUUID();
    duplicate.timelineStart = rational(operation.atSeconds ?? firstAvailableStart(
      found.track.clips,
      seconds(found.clip.timelineStart) + seconds(found.clip.duration),
      seconds(found.clip.duration),
      found.clip.id
    ));
    delete duplicate.groupID;
    delete duplicate.linkGroupID;
    found.track.clips.push(duplicate);
    relocateIfOverlapping(project, { track: found.track, clip: duplicate });
    return;
  }
  if (operation.type === "detach_audio") {
    const asset = project.assets.find(item => item.id === found.clip.assetID);
    if (found.clip.kind !== "video" || !asset?.metadata?.hasAudio)
      throw new AutomationError("media_has_no_audio", "The selected video does not contain detachable audio.");
    const start = seconds(found.clip.timelineStart); const duration = seconds(found.clip.duration);
    let destination = operation.audioTrackId == null
      ? project.timeline.tracks.find(track => track.kind === "audio" && !track.isLocked && track.clips.every(clip => !overlap(start, duration, seconds(clip.timelineStart), seconds(clip.duration))))
      : project.timeline.tracks.find(track => track.id === operation.audioTrackId);
    if (!destination && operation.audioTrackId == null) { destination = emptyTrack("audio", project.timeline.tracks); project.timeline.tracks.push(destination); }
    if (!destination || destination.kind !== "audio" || destination.isLocked || destination.clips.some(clip => overlap(start, duration, seconds(clip.timelineStart), seconds(clip.duration))))
      throw new AutomationError("track_unavailable", "Choose an unlocked audio track without another clip in that range.");
    const audio = structuredClone(found.clip);
    audio.id = randomUUID(); audio.kind = "audio"; audio.isVideoMuted = true;
    audio.transform = { positionX: 0, positionY: 0, scale: 1, rotationDegrees: 0, cropTop: 0, cropLeading: 0, cropBottom: 0, cropTrailing: 0, contentMode: "fit" };
    audio.opacity = 1;
    delete audio.groupID; delete audio.linkGroupID;
    found.clip.audioVolume = 0;
    destination.clips.push(audio);
    destination.clips.sort((left, right) => seconds(left.timelineStart) - seconds(right.timelineStart));
    return;
  }
  if (operation.type === "update_clip") {
    if (operation.timelineStartSeconds != null) found.clip.timelineStart = rational(operation.timelineStartSeconds);
    if (operation.sourceStartSeconds != null) found.clip.sourceStart = rational(operation.sourceStartSeconds);
    if (operation.durationSeconds != null) found.clip.duration = rational(operation.durationSeconds);
    if (operation.opacity != null) found.clip.opacity = operation.opacity;
    if (operation.volume != null) found.clip.audioVolume = operation.volume;
    if (operation.speed != null) found.clip.playbackRate = operation.speed;
    if (operation.positionX != null) found.clip.transform.positionX = operation.positionX;
    if (operation.positionY != null) found.clip.transform.positionY = operation.positionY;
    if (operation.scale != null) found.clip.transform.scale = operation.scale;
    if (operation.rotationDegrees != null) found.clip.transform.rotationDegrees = operation.rotationDegrees;
    if (operation.contentMode != null) found.clip.transform.contentMode = operation.contentMode;
    if (operation.reverse != null) found.clip.isReversed = operation.reverse;
    if (operation.muted != null) found.clip.isVideoMuted = operation.muted;
    if (operation.enabled != null) found.clip.isEnabled = operation.enabled;
    if (operation.name != null) found.clip.name = operation.name;
    if (operation.text != null) {
      if (!found.clip.textStyle) throw new AutomationError("clip_kind_invalid", "Only text clips can update text.");
      found.clip.textStyle.text = operation.text;
    }
    if (operation.cropTop != null) found.clip.transform.cropTop = operation.cropTop;
    if (operation.cropLeading != null) found.clip.transform.cropLeading = operation.cropLeading;
    if (operation.cropBottom != null) found.clip.transform.cropBottom = operation.cropBottom;
    if (operation.cropTrailing != null) found.clip.transform.cropTrailing = operation.cropTrailing;
    if (found.clip.transform.cropTop + found.clip.transform.cropBottom >= 1 || found.clip.transform.cropLeading + found.clip.transform.cropTrailing >= 1)
      throw new AutomationError("invalid_crop", "Opposite crop edges must leave part of the image visible.");
    if (operation.videoFadeInSeconds != null) found.clip.fades.videoIn = rational(operation.videoFadeInSeconds);
    if (operation.videoFadeOutSeconds != null) found.clip.fades.videoOut = rational(operation.videoFadeOutSeconds);
    if (operation.audioFadeInSeconds != null) found.clip.fades.audioIn = rational(operation.audioFadeInSeconds);
    if (operation.audioFadeOutSeconds != null) found.clip.fades.audioOut = rational(operation.audioFadeOutSeconds);
    if (operation.effects != null) found.clip.effects = operation.effects.map(item => ({ id: randomUUID(), kind: item.kind, isEnabled: true, amount: item.amount }));
    if (operation.transitionIn !== undefined) found.clip.transitionIn = operation.transitionIn == null ? undefined : { kind: operation.transitionIn.kind, duration: rational(operation.transitionIn.durationSeconds) };
    if (operation.transitionOut !== undefined) found.clip.transitionOut = operation.transitionOut == null ? undefined : { kind: operation.transitionOut.kind, duration: rational(operation.transitionOut.durationSeconds) };
    clampClipDurations(found.clip);
    relocateIfOverlapping(project, found);
    return;
  }
  if (operation.type === "split_clip") {
    const start = seconds(found.clip.timelineStart); const duration = seconds(found.clip.duration);
    if (operation.atSeconds <= start || operation.atSeconds >= start + duration) throw new AutomationError("invalid_split", "Split time must be inside the clip.");
    const leftDuration = operation.atSeconds - start;
    const right = structuredClone(found.clip);
    right.id = randomUUID(); right.timelineStart = rational(operation.atSeconds); right.duration = rational(duration - leftDuration);
    if (right.kind !== "text") {
      const leftSourceDuration = leftDuration * right.playbackRate;
      if (right.isReversed) found.clip.sourceStart = rational(seconds(found.clip.sourceStart) + duration * right.playbackRate - leftSourceDuration);
      else right.sourceStart = rational(seconds(right.sourceStart) + leftSourceDuration);
    }
    found.clip.duration = rational(leftDuration); found.track.clips.push(right); found.track.clips.sort((a, b) => seconds(a.timelineStart) - seconds(b.timelineStart));
  }
}

function compatibleTrack(project, kind, start, duration, excludedClipId) {
  let track = project.timeline.tracks
    .filter(item => item.kind === kind && !item.isLocked)
    .find(item => item.clips.every(clip => clip.id === excludedClipId || !overlap(start, duration, seconds(clip.timelineStart), seconds(clip.duration))));
  if (!track) {
    track = emptyTrack(kind, project.timeline.tracks);
    project.timeline.tracks.push(track);
  }
  return track;
}

function insertGap(project, atSeconds, durationSeconds) {
  const timelineDuration = Math.max(0, ...project.timeline.tracks.flatMap(track => track.clips.map(clip => seconds(clip.timelineStart) + seconds(clip.duration))));
  if (atSeconds >= timelineDuration)
    throw new AutomationError("invalid_gap", "A black pause must be inserted before the end of existing timeline content.");
  for (const track of project.timeline.tracks) {
    if (track.isLocked && track.clips.some(clip => seconds(clip.timelineStart) + seconds(clip.duration) > atSeconds))
      throw new AutomationError("track_locked", `Track ${track.name} is locked.`);
    const edited = [];
    for (const clip of track.clips) {
      const start = seconds(clip.timelineStart); const duration = seconds(clip.duration); const end = start + duration;
      if (start >= atSeconds) { clip.timelineStart = rational(start + durationSeconds); edited.push(clip); }
      else if (end > atSeconds) {
        const leftDuration = atSeconds - start;
        edited.push(segmentClip(clip, 0, leftDuration, true));
        const right = segmentClip(clip, leftDuration, end - atSeconds, false);
        right.timelineStart = rational(atSeconds + durationSeconds);
        edited.push(right);
      } else edited.push(clip);
    }
    track.clips = edited.sort((left, right) => seconds(left.timelineStart) - seconds(right.timelineStart));
  }
  for (const marker of project.timeline.markers) if (seconds(marker.time) >= atSeconds) marker.time = rational(seconds(marker.time) + durationSeconds);
  project.timeline.markers.sort((left, right) => seconds(left.time) - seconds(right.time));
}

function removeTimeRange(project, startSeconds, durationSeconds) {
  const endSeconds = startSeconds + durationSeconds;
  for (const track of project.timeline.tracks) {
    if (track.isLocked && track.clips.some(clip => seconds(clip.timelineStart) + seconds(clip.duration) > startSeconds))
      throw new AutomationError("track_locked", `Track ${track.name} is locked.`);
    const edited = [];
    for (const clip of track.clips) {
      const start = seconds(clip.timelineStart); const duration = seconds(clip.duration); const end = start + duration;
      if (end <= startSeconds) edited.push(clip);
      else if (start >= endSeconds) { clip.timelineStart = rational(start - durationSeconds); edited.push(clip); }
      else {
        if (start < startSeconds) edited.push(segmentClip(clip, 0, startSeconds - start, true));
        if (end > endSeconds) {
          const right = segmentClip(clip, endSeconds - start, end - endSeconds, false);
          right.timelineStart = rational(startSeconds);
          edited.push(right);
        }
      }
    }
    track.clips = edited.sort((left, right) => seconds(left.timelineStart) - seconds(right.timelineStart));
  }
  project.timeline.markers = project.timeline.markers.flatMap(marker => {
    const time = seconds(marker.time);
    if (time >= startSeconds && time < endSeconds) return [];
    if (time >= endSeconds) marker.time = rational(time - durationSeconds);
    return [marker];
  }).sort((left, right) => seconds(left.time) - seconds(right.time));
}

function segmentClip(original, offsetSeconds, durationSeconds, preserveId) {
  const segment = structuredClone(original);
  if (!preserveId) segment.id = randomUUID();
  segment.timelineStart = rational(seconds(original.timelineStart) + offsetSeconds);
  segment.duration = rational(durationSeconds);
  if (original.kind !== "text" && original.kind !== "image") {
    segment.sourceStart = rational(seconds(original.sourceStart) + (original.isReversed
      ? (seconds(original.duration) - offsetSeconds - durationSeconds) * original.playbackRate
      : offsetSeconds * original.playbackRate));
  }
  if (offsetSeconds > 0) delete segment.transitionIn;
  if (offsetSeconds + durationSeconds < seconds(original.duration)) delete segment.transitionOut;
  const half = durationSeconds / 2;
  for (const key of ["videoIn", "videoOut", "audioIn", "audioOut"]) segment.fades[key] = rational(Math.min(seconds(segment.fades[key]), half));
  for (const key of ["positionX", "positionY", "scale", "rotationDegrees", "opacity", "volume"]) {
    segment.keyframes[key] = (original.keyframes[key] ?? []).filter(frame => {
      const time = seconds(frame.time); return time >= offsetSeconds && time <= offsetSeconds + durationSeconds;
    }).map(frame => ({ ...frame, time: rational(seconds(frame.time) - offsetSeconds) }));
  }
  return segment;
}

function clampClipDurations(clip) {
  const half = seconds(clip.duration) / 2;
  for (const key of ["videoIn", "videoOut", "audioIn", "audioOut"]) clip.fades[key] = rational(Math.min(seconds(clip.fades[key]), half));
  if (clip.transitionIn) clip.transitionIn.duration = rational(Math.min(seconds(clip.transitionIn.duration), seconds(clip.duration)));
  if (clip.transitionOut) clip.transitionOut.duration = rational(Math.min(seconds(clip.transitionOut.duration), seconds(clip.duration)));
}

function firstAvailableStart(clips, start, duration, excludedId) {
  let candidate = start;
  const ordered = clips.filter(clip => clip.id !== excludedId).sort((left, right) => seconds(left.timelineStart) - seconds(right.timelineStart));
  for (const clip of ordered) {
    const clipStart = seconds(clip.timelineStart); const clipEnd = clipStart + seconds(clip.duration);
    if (clipEnd <= candidate) continue;
    if (candidate + duration <= clipStart) return candidate;
    candidate = clipEnd;
  }
  return candidate;
}

function relocateIfOverlapping(project, found) {
  const start = seconds(found.clip.timelineStart);
  const duration = seconds(found.clip.duration);
  if (found.track.clips.every(clip => clip.id === found.clip.id || !overlap(start, duration, seconds(clip.timelineStart), seconds(clip.duration)))) {
    found.track.clips.sort((left, right) => seconds(left.timelineStart) - seconds(right.timelineStart));
    return;
  }
  found.track.clips = found.track.clips.filter(clip => clip.id !== found.clip.id);
  const destination = compatibleTrack(project, found.track.kind, start, duration, found.clip.id);
  destination.clips.push(found.clip);
  destination.clips.sort((left, right) => seconds(left.timelineStart) - seconds(right.timelineStart));
}

function canonicalPath(value) {
  const suffix = [];
  let current = path.resolve(value);
  while (!existsSync(current)) {
    const parent = path.dirname(current);
    if (parent === current) break;
    suffix.unshift(path.basename(current));
    current = parent;
  }
  const base = existsSync(current) ? realpathSync.native(current) : current;
  return path.resolve(base, ...suffix);
}

function comparablePath(value) { return process.platform === "win32" ? value.toLowerCase() : value; }
function samePath(left, right) { return comparablePath(left) === comparablePath(right); }
function isWithin(root, candidate) {
  const comparableRoot = comparablePath(root);
  const comparableCandidate = comparablePath(candidate);
  const prefix = comparableRoot.endsWith(path.sep) ? comparableRoot : comparableRoot + path.sep;
  return comparableCandidate === comparableRoot || comparableCandidate.startsWith(prefix);
}

function validateSourceRange(inspection, startSeconds, durationSeconds) {
  if (inspection.durationSeconds == null) return;
  if (startSeconds >= inspection.durationSeconds || (durationSeconds != null && startSeconds + durationSeconds > inspection.durationSeconds + 0.0001))
    throw new AutomationError("source_range_invalid", "The requested range is outside the source media.");
}
