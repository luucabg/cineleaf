# Roadmap

## 0.1.0 — fast everyday editor

Implemented in the current source:

- Native English/Spanish editor, exact-time project format, autosave/recovery, relinking, and portable media consolidation.
- Fast multi-track timeline with normal and ripple edits, insert/overwrite, groups, links, markers, shortcuts, undo/redo, and a 10,000-clip visible-range index.
- Text, transforms, crop, fades, audio mixing, speed, reverse, freeze frames, keyframes, color controls, effects, reusable looks, and clip-edge transitions.
- On-device automatic captions, subtitle import/export, voiceover, normalization, reviewed silence removal, and local beat markers.
- Preview proxies, bounded/clearable caches, local diagnostics, verified AVFoundation export, saved export settings, and universal unsigned packaging.
- Local AI/MCP control with exact project inspection and editing, safe previews, stable IDs, subtitle/text layers, batches of up to 32 videos and native exports on Windows and Mac.

Remaining release work is hands-on validation, profiling, installation, and real screenshots on physical Mac hardware. These are evidence gates, not more hidden features.

## 0.3.0 beta — practical editor utilities

Implemented in the current source:

- Change project format, frame rate, export resolution, codec and quality after creating a project.
- Insert an exact black pause, remove a time range, duplicate into the next free position and detach audio without colliding with adjacent clips.
- Extract original audio as M4A and save a source frame as PNG through cancellable, verified and atomic jobs.
- Full Windows inspector for display mode, enable/reverse/video visibility, fades, crop and entrance/exit transitions.
- The same structured controls for AI: project settings, gaps, range removal, duplicate, audio detachment, crop, effects, transitions, audio extraction and frame capture.
- Regression tests for locked tracks, split continuity, silent assets, path isolation, output conflicts, failed overwrite recovery and real FFmpeg media.

## Next — deeper editing and polish

- Handle-based transitions between adjacent clips with a dedicated transition editor.
- A visual keyframe lane with curve selection and batch keyframe editing.
- Optional, carefully tested noise reduction and more detailed audio meters.
- Timeline guides/rulers beyond markers, range selection, and a richer trimming monitor.
- Section-level composition patching and further measured preview optimizations.
- Searchable effects, user-created look presets, project templates, and improved media organization.
- More UI automation, accessibility review, and large-project performance baselines across several Mac models.

## Advanced local tools

- Chroma key, masks, and LUT import.
- Vision-powered motion tracking, supported-device subject segmentation, and background removal.
- Adjustment layers, nested timelines, and multicam foundations.
- Color scopes and expanded audio metering.
- An optional extension architecture and, only after a licensing review, an isolated external media backend.
- Optional native speech-to-subtitle and richer media-analysis tools exposed directly through MCP, while retaining the current local-only privacy model.

Advanced tools must remain local, optional, cancellable, and honest about hardware support. Cineleaf will not require a paid API, account, or media upload.
