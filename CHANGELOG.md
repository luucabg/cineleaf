# Changelog

All notable changes are recorded here. Cineleaf follows semantic versioning after the first public release.

## Unreleased

## 0.3.0-beta.1 — 2026-07-27

### Added

- Project settings on Mac and Windows for canvas format, 24–60 fps, 720p–4K export resolution, codec and quality.
- Exact black-pause insertion, interval removal, safe duplication and independent audio detachment with locked-track protection.
- Original-audio extraction to M4A and current/source-frame capture to PNG through verified temporary outputs.
- Windows inspector controls for fit/fill/crop, clip visibility, reverse, video-only hiding, fades, crop edges and entrance/exit transitions.
- MCP operations for project settings, gaps, range removal, duplicate, detached audio, crop, fades, effects and transitions.
- MCP tools for local audio and frame extraction with dry runs, allowed-root checks, explicit writes, extension validation and atomic promotion.
- Keyboard shortcuts for duplicate, markers, black pauses and audio detachment on both platforms.

### Fixed

- Duplicating a clip beside occupied material now uses the earliest compatible free position instead of producing an overlap.
- Audio detachment now selects a non-overlapping audio track, rejects silent assets and creates a truly independent clip.
- Gap insertion preserves source-time mapping, reverse playback, fades, transitions, keyframes and marker timing across splits.
- Windows window disposal no longer calls itself recursively.

### Performance and compatibility

- New media utilities run asynchronously, are cancellable and avoid full-timeline composition for source-only extraction.
- The shared `.cineleaf` format remains version 2 and the native automation protocol remains version 1; all new API fields and operations are additive.
- Regression benchmarks and their limits are recorded in `Documentation/PERFORMANCE.md`.

## 0.2.0-beta.1 — 2026-07-27

### Added

- Local MCP server and native Windows/macOS automation bridges for structured AI control without screen scraping.
- Safe dry-run/confirmation workflow, allowed-root isolation, idempotent and resumable writes, stable clip IDs, structured results, progress, and bounded batches of up to 32 videos.
- AI operations for exact project creation, inspection, move/trim/transform/split/delete edits, text/subtitle layers, markers, and native H.264/HEVC export.
- Optional setup scripts and a low-technical automation guide for MCP-compatible clients.

- Native Windows 10/11 x64 editor built with .NET 8 and WPF, sharing the Mac `.cineleaf` version-2 project format.
- Self-contained Windows EXE installer and portable ZIP with bundled LGPLv3 FFmpeg tools and SHA-256 checksums.
- Windows composed preview/export through FFmpeg, verified hardware encoder probing, offline System.Speech captions, SRT/WebVTT, beat markers and reviewed silence removal.
- Windows custom virtualized timeline, English/Spanish interface, autosave/recovery, exact-time edit engine, bounded preview cache, 33 unit tests, 2 real-media integration tests and reproducible benchmarks.

- Native macOS editor with English/Spanish interface, original branding, keyboard commands, accessibility labels, and a custom virtualized AppKit timeline.
- Versioned `.cineleaf` projects, safe v1→v2 migration, autosave/recovery, recents, missing-media relinking, atomic JSON save, and optional portable media consolidation.
- Multi-track editing, snapping, ripple/insert/overwrite, group/link, markers, property copy/paste, bounded undo/redo, speed, reverse, freeze frames, and keyframes.
- Text/image overlays, color adjustments, reusable looks, Core Image effects, clip-edge transitions, subtitles, voiceover, normalization, silence review/removal, and local beat markers.
- On-device-only automatic captions with no cloud fallback plus SRT/WebVTT import and export.
- Cancellable preview proxies, thumbnail/waveform/metadata/derivative caches, cache controls, source/composition reuse, and local diagnostics.
- H.264/HEVC MP4/MOV export with progress, cancellation, disk checks, output validation, saved presets, AAC audio, and 720p through 4K plans.
- Unit, integration, localization, UI, and performance tests; macOS CI; universal ad-hoc-signed app/ZIP/DMG/checksum tooling.

### Performance

- Added binary-search visible timeline indexing and validation fast paths.
- Streamed audio analysis and bounded frame-at-a-time reverse rendering avoid loading complete media into memory.
- Deduplicated AI media inspection, bounded automation concurrency, modification-aware metadata caching and a reproducible 32-video planning benchmark.
- Recorded the first non-fabricated macOS CI engine baseline in `Documentation/PERFORMANCE.md`.

### Release status

- Automated macOS builds, tests, synthetic export, and packaging pass.
- `0.1.0` remains unreleased until manual Mac workflow, profiling, installation, and screenshot gates pass.
