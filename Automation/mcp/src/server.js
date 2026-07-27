import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { AutomationError, ProjectService } from "./project-service.js";
import { batchSchema, createVideoSchema, editProjectSchema, extractAudioSchema, extractFrameSchema } from "./schemas.js";

const protocolVersion = 1;

export function createMcpServer({ roots, adapter }) {
  const service = new ProjectService({ roots, adapter });
  const server = new McpServer(
    { name: "cineleaf", version: "0.3.0" },
    { instructions: "Cineleaf edits video locally. Start with cineleaf_capabilities. For every write, call the same tool with dryRun=true first, show the plan to the user, then retry with dryRun=false and confirmWrite=true. Project creation, editing and export also require a unique idempotencyKey. Never invent paths or clip IDs: inspect the project first. Batch concurrency above 2 can reduce throughput on typical GPUs." }
  );

  server.registerTool("cineleaf_capabilities", {
    title: "Cineleaf automation capabilities",
    description: "Read the stable automation limits and recommended workflow. This tool never writes files.",
    inputSchema: z.object({}).strict(),
    outputSchema: z.object({ protocolVersion: z.number(), localOnly: z.boolean(), allowedRoots: z.array(z.string()), maxBatchSize: z.number(), maxConcurrency: z.number(), workflow: z.array(z.string()) }),
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true }
  }, async () => success({
    protocolVersion, localOnly: true, allowedRoots: roots, maxBatchSize: 32, maxConcurrency: 4,
    workflow: ["Inspect existing projects before editing.", "Dry-run every proposed write.", "Use explicit confirmation and an idempotency key.", "Render at concurrency 1 or 2 for best total throughput."]
  }));

  server.registerTool("cineleaf_create_video", {
    title: "Create or render one Cineleaf video",
    description: "Builds an exact-time .cineleaf timeline from local videos, audio, images and text. Automatically adds non-overlapping tracks. Defaults to dry-run. With outputPath and confirmed write, validates and renders through the native Windows or Mac engine.",
    inputSchema: createVideoSchema,
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true }
  }, (args, extra) => handle(() => service.createVideo(args, toolContext(extra))));

  server.registerTool("cineleaf_create_video_batch", {
    title: "Create a bounded batch of Cineleaf videos",
    description: "Creates up to 32 independent videos with bounded concurrency and stable result ordering. Each job has the same schema and safety controls as cineleaf_create_video.",
    inputSchema: batchSchema,
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true }
  }, (args, extra) => handle(() => service.createVideoBatch(args, toolContext(extra))));

  server.registerTool("cineleaf_inspect_project", {
    title: "Inspect a Cineleaf project",
    description: "Returns compact stable IDs, tracks, clips, media and markers so an AI can reason about the edit without parsing the entire project JSON.",
    inputSchema: z.object({ projectPath: z.string().min(1).max(32767) }).strict(),
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true }
  }, args => handle(() => service.inspectProject(args)));

  server.registerTool("cineleaf_edit_project", {
    title: "Apply exact edits to a Cineleaf project",
    description: "Moves, trims, transforms, fades, updates, splits, duplicates, detaches audio or deletes clips by stable ID; changes project resolution, inserts black pauses, removes time ranges, and adds markers or text/subtitle clips. Defaults to dry-run and validates the final project with the native engine before reporting success.",
    inputSchema: editProjectSchema,
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true }
  }, args => handle(() => service.editProject(args)));

  server.registerTool("cineleaf_extract_audio", {
    title: "Extract audio from local media",
    description: "Safely extracts all or part of a local video/audio source to a 48 kHz M4A file. Defaults to dry-run, never replaces the source, and refuses existing outputs unless overwrite is explicitly confirmed.",
    inputSchema: extractAudioSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false }
  }, (args, extra) => handle(() => service.extractAudio(args, toolContext(extra))));

  server.registerTool("cineleaf_extract_frame", {
    title: "Save an exact video frame",
    description: "Safely saves a frame from local video or image media as PNG at an exact time. Defaults to dry-run and never replaces the source.",
    inputSchema: extractFrameSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false }
  }, (args, extra) => handle(() => service.extractFrame(args, toolContext(extra))));

  server.registerResource("cineleaf-automation-contract", "cineleaf://automation/contract", {
    title: "Cineleaf AI automation contract",
    description: "Machine-readable usage rules for safe, local video automation.",
    mimeType: "application/json"
  }, async uri => ({ contents: [{ uri: uri.href, mimeType: "application/json", text: JSON.stringify({ protocolVersion, timeUnit: "seconds at the MCP boundary; exact rational time inside projects", projectFormatVersion: 2, destructiveWorkflow: ["dryRun", "user review", "confirmWrite", "idempotencyKey for project writes"], mediaOutputs: { audio: "m4a", frame: "png" }, limits: { batch: 32, concurrency: 4, clipsPerVideo: 500 } }, null, 2) }] }));

  server.registerPrompt("cineleaf-batch-workflow", {
    title: "Plan a reliable Cineleaf video batch",
    description: "A short workflow prompt for agents creating multiple edited videos.",
    argsSchema: { goal: z.string().min(1), quantity: z.string().regex(/^([1-9]|[12][0-9]|3[0-2])$/) }
  }, ({ goal, quantity }) => ({ messages: [{ role: "user", content: { type: "text", text: `Create ${quantity} Cineleaf videos for this goal: ${goal}. Inspect all sources, prepare dry-run jobs, verify durations and aspect ratios, ask for approval, then execute with concurrency 2 and unique idempotency keys. Inspect every output result before claiming completion.` } }] }));

  return server;
}

function toolContext(extra) {
  const progressToken = extra._meta?.progressToken;
  const notify = async (progress, total, message) => {
    if (progressToken == null) return;
    await extra.sendNotification({ method: "notifications/progress", params: { progressToken, progress, total, message } });
  };
  return {
    signal: extra.signal,
    onProgress: value => notify(value, 1, `Rendering ${Math.round(value * 100)}%`),
    onBatchProgress: (value, total) => notify(value, total, `Completed ${value} of ${total} videos`)
  };
}

async function handle(action) {
  try { return success(await action()); }
  catch (error) {
    const body = {
      error: {
        code: error?.code ?? "operation_failed",
        message: error instanceof AutomationError ? error.message : String(error?.message ?? error),
        ...(error instanceof AutomationError && error.details ? { details: error.details } : {})
      }
    };
    return { content: [{ type: "text", text: JSON.stringify(body) }], structuredContent: body, isError: true };
  }
}

function success(data) { return { content: [{ type: "text", text: JSON.stringify(data) }], structuredContent: data }; }
