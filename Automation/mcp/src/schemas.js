import { z } from "zod";

const seconds = z.number().finite().min(0).max(604800);
const positiveSeconds = z.number().finite().positive().max(604800);
const hexColor = z.string().regex(/^#[0-9a-fA-F]{8}$/);
const effect = z.object({
  kind: z.enum(["gaussianBlur", "sharpen", "vignette", "monochrome", "sepia", "bloom"]),
  amount: z.number().finite().min(0).max(1).default(0.5)
}).strict();
const transition = z.object({
  kind: z.enum(["crossDissolve", "fadeThroughBlack", "slideLeft", "slideRight", "wipeLeft", "blur"]),
  durationSeconds: positiveSeconds.max(30).default(0.5)
}).strict();

export const mediaClipSchema = z.object({
  path: z.string().min(1).max(32767),
  startSeconds: seconds.optional(),
  sourceStartSeconds: seconds.default(0),
  durationSeconds: positiveSeconds.optional(),
  speed: z.number().finite().min(0.25).max(4).default(1),
  reverse: z.boolean().default(false),
  opacity: z.number().finite().min(0).max(1).default(1),
  volume: z.number().finite().min(0).max(2).default(1),
  positionX: z.number().finite().min(-100000).max(100000).default(0),
  positionY: z.number().finite().min(-100000).max(100000).default(0),
  scale: z.number().finite().positive().max(100).default(1),
  rotationDegrees: z.number().finite().min(-36000).max(36000).default(0),
  contentMode: z.enum(["fit", "fill", "crop"]).default("fit"),
  fadeInSeconds: seconds.max(60).default(0),
  fadeOutSeconds: seconds.max(60).default(0),
  transitionIn: transition.optional(),
  transitionOut: transition.optional(),
  effects: z.array(effect).max(16).default([]),
  muted: z.boolean().default(false)
}).strict();

export const textClipSchema = z.object({
  role: z.enum(["standard", "subtitle"]).default("standard"),
  text: z.string().min(1).max(10000),
  startSeconds: seconds.default(0),
  durationSeconds: positiveSeconds.max(86400),
  fontName: z.string().min(1).max(256).default(".AppleSystemUIFont"),
  fontSize: z.number().finite().min(6).max(1000).default(64),
  foregroundHex: hexColor.default("#FFFFFFFF"),
  backgroundHex: hexColor.default("#00000000"),
  strokeHex: hexColor.default("#000000FF"),
  strokeWidth: z.number().finite().min(0).max(50).default(0),
  shadowOpacity: z.number().finite().min(0).max(1).default(0),
  animation: z.enum(["none", "fade", "slideUp"]).default("none"),
  positionX: z.number().finite().min(-100000).max(100000).default(0),
  positionY: z.number().finite().min(-100000).max(100000).default(0),
  scale: z.number().finite().positive().max(100).default(1),
  rotationDegrees: z.number().finite().min(-36000).max(36000).default(0),
  opacity: z.number().finite().min(0).max(1).default(1)
}).strict();

export const createVideoSchema = z.object({
  projectPath: z.string().min(1).max(32767),
  outputPath: z.string().min(1).max(32767).optional(),
  name: z.string().min(1).max(200).default("AI Video"),
  canvasPreset: z.enum(["landscape16x9", "vertical9x16", "square1x1", "portrait4x5"]).default("landscape16x9"),
  frameRate: z.union([z.literal(24), z.literal(25), z.literal(30), z.literal(50), z.literal(60)]).default(30),
  media: z.array(mediaClipSchema).max(500).default([]),
  texts: z.array(textClipSchema).max(500).default([]),
  export: z.object({
    resolution: z.enum(["p720", "p1080", "p1440", "p2160"]).default("p1080"),
    codec: z.enum(["h264", "hevc"]).default("h264"),
    quality: z.enum(["compact", "balanced", "high"]).default("balanced")
  }).strict().default({}),
  dryRun: z.boolean().default(true),
  confirmWrite: z.boolean().default(false),
  overwrite: z.boolean().default(false),
  idempotencyKey: z.string().regex(/^[A-Za-z0-9._-]{1,128}$/).optional()
}).strict();

const editOperation = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("update_clip"),
    clipId: z.string().uuid(),
    timelineStartSeconds: seconds.optional(),
    sourceStartSeconds: seconds.optional(),
    durationSeconds: positiveSeconds.optional(),
    opacity: z.number().finite().min(0).max(1).optional(),
    volume: z.number().finite().min(0).max(2).optional(),
    speed: z.number().finite().min(0.25).max(4).optional(),
    positionX: z.number().finite().min(-100000).max(100000).optional(),
    positionY: z.number().finite().min(-100000).max(100000).optional(),
    scale: z.number().finite().positive().max(100).optional(),
    rotationDegrees: z.number().finite().min(-36000).max(36000).optional(),
    contentMode: z.enum(["fit", "fill", "crop"]).optional(),
    reverse: z.boolean().optional(),
    muted: z.boolean().optional(),
    enabled: z.boolean().optional(),
    name: z.string().min(1).max(200).optional(),
    text: z.string().min(1).max(10000).optional()
  }).strict(),
  z.object({ type: z.literal("split_clip"), clipId: z.string().uuid(), atSeconds: seconds }).strict(),
  z.object({ type: z.literal("delete_clips"), clipIds: z.array(z.string().uuid()).min(1).max(500), ripple: z.boolean().default(false) }).strict(),
  z.object({ type: z.literal("add_marker"), atSeconds: seconds, name: z.string().min(1).max(200).default("Marker") }).strict(),
  textClipSchema.extend({ type: z.literal("add_text") })
]);

export const editProjectSchema = z.object({
  projectPath: z.string().min(1).max(32767),
  operations: z.array(editOperation).min(1).max(1000),
  dryRun: z.boolean().default(true),
  confirmWrite: z.boolean().default(false),
  idempotencyKey: z.string().regex(/^[A-Za-z0-9._-]{1,128}$/).optional()
}).strict();

export const batchSchema = z.object({
  jobs: z.array(createVideoSchema).min(1).max(32),
  concurrency: z.number().int().min(1).max(4).default(2)
}).strict();
