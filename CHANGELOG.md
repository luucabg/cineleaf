# Changelog

All notable changes are recorded here. Cineleaf follows semantic versioning after the first public release.

## Unreleased

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
