# Performance evidence

Performance is a release requirement for Cineleaf, not decorative polish. This document separates measured engine results from design targets and work that still requires a physical Mac.

## Recorded Windows baseline

- Date: 27 July 2026
- Windows 11 Pro 10.0.26200
- AMD Ryzen 5 5600X (6 cores / 12 threads), 31.9 GB RAM
- .NET 8.0.23, Release configuration
- Test project: 100 clips, 10 tracks, exactly one hour; timeline query: 10,000 clips

| Repeatable case | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: |
| Project validation | 0.2212 ms | 0.2289 ms | 0.3385 ms |
| Project JSON serialization | 1.4631 ms | 1.5378 ms | 4.1786 ms |
| Project JSON encode + decode | 8.5561 ms | 9.4908 ms | 17.7783 ms |
| Move command with safe clone, validation and undo | 8.5739 ms | 9.9172 ms | 18.9379 ms |
| Visible-range lookup in 10,000 clips | 0.0075 ms | 0.0079 ms | 0.0088 ms |

These are in-memory engine microbenchmarks captured by `Windows/tools/Cineleaf.Windows.Benchmarks`. They do not measure decode, screen refresh, storage, or final export speed. Reproduce them with `dotnet run --project Windows/tools/Cineleaf.Windows.Benchmarks -c Release`.

## Recorded AI planning baseline

- Date: 27 July 2026
- Same Windows workstation as the engine baseline
- Node.js 24.16.0
- Workload: one dry-run batch of 32 videos, 100 repeated-source clips per video, concurrency 2
- Samples: 3 warm-ups and 20 recorded iterations

| Repeatable case | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: |
| MCP validation, exact planning and temporary package lifecycle | 78.388 ms | 86.391 ms | 104.964 ms |

The media adapter is deterministic in this benchmark and each video's repeated source is inspected once. It includes writing and deleting each temporary project JSON used by a dry run, but deliberately excludes native validation, real media probing, decode and export. It therefore measures automation and temporary-package overhead rather than encoding speed. Reproduce it with `npm run benchmark --prefix Automation/mcp`.

## Recorded automated baseline

- Measurement revision: `6c4e455`
- GitHub Actions run: [30235867829](https://github.com/luucabg/cineleaf/actions/runs/30235867829)
- Date: 27 July 2026
- Environment label: GitHub-hosted `macos-15` runner
- Xcode: 16.4 build 16F6
- Swift: Apple Swift 6.1.2
- SDK: macOS 15.5
- Configuration: Swift Package XCTest performance build used by `swift test`

The runner log did not record a Mac model, processor name, memory capacity, power state, or thermal state. Those fields are intentionally marked **unknown** rather than guessed. This baseline is useful for regressions on the same CI class, not for comparing consumer Macs.

| Repeatable case | Test data | Observed wall time |
| --- | --- | --- |
| Project validation | 100 clips, 10 tracks, at least one hour | 0.390–0.427 ms after warm-up; first sample 0.611 ms |
| Project JSON serialization | 100 media assets | 1.405–1.600 ms after warm-up; first sample 4.223 ms |
| Project JSON encode + decode | 100 clips, 10 tracks, at least one hour | 11.799–18.556 ms |
| Move + trim + split sequence | 100 clips, 10 tracks, at least one hour; each edit fully validates | 1.645–1.699 ms after warm-up; first sample 1.791 ms |
| Visible timeline lookup | 10,000 clips; return 15 clips in a 30-second window | 0.039–0.059 ms in settled samples; first sample 0.286 ms |

The table uses the unrounded samples printed in the XCTest log. Timing noise is significant at this scale, especially for the timeline query, so the individual range is more honest than excessive decimal precision. The encode/decode case measures the versioned JSON codec in memory; it does not include physical disk latency.

## What is optimized in the implementation

- `TimelineIndex` uses a per-track sorted interval index and binary search, so drawing a visible window does not scan an entire long project.
- The WPF timeline uses the same index and draws visible clips in one custom control rather than creating one heavyweight control per clip.
- The AppKit timeline draws only the dirty visible region plus a small preload margin. Waveforms are downsampled peak arrays, not raw samples or a view per point.
- Preview compositions and resolved AVFoundation source metadata are reused by project revision. Source caches use bounded least-recently-used eviction.
- Inspector edits are coalesced before preview rebuild; stale rebuilds, thumbnails, waveforms, proxies, speech recognition, audio analysis, and exports observe cancellation.
- Preview may use a lightweight proxy while export always resolves the original media.
- Thumbnail, waveform, metadata, preview derivative, reverse-media, and proxy caches are bounded. Disk usage is visible and clearable in Settings.
- Audio analysis streams decoded samples in bounded buffers. Reverse video writes one frame at a time. No source movie is loaded completely into memory.
- Undo history is capped at 50 project snapshots.
- Windows undo history is capped at 100 snapshots; preview work is debounced, cancellable, and stored in a bounded 2 GB disk cache.
- Project validation fast-paths default transforms, fades, color, effects, and keyframes to avoid unnecessary temporary allocations.
- AI requests deduplicate repeated media paths per plan; the native adapter also keeps a bounded 512-entry metadata cache invalidated by file size and modification time.
- Batch output order is stable while work uses bounded concurrency. The default of two avoids starting enough simultaneous encoders to starve typical GPUs and storage.

## Engineering budgets

- Lightweight interface actions target about 100 ms or less.
- Timeline drag, trim, scroll, and zoom target the active display refresh rate.
- Background work must show progress when noticeable and support cancellation where Apple’s framework permits it.
- Preview quality may decrease through a proxy; final export quality must never inherit that decrease.
- Memory and disk use must remain bounded for long media.

These are targets. They are not measured end-to-end latency claims.

## Still required on physical hardware

Before `0.1.0`, record the Mac model, processor, memory, macOS version, power state, and thermal state, then exercise at least one hour of mixed media with 100 clips across 10 tracks. Measure:

- initial project open and save/reopen;
- timeline load, scrolling, zooming, move, trim, and split;
- thumbnail and waveform cold/warm cache;
- preview rebuild, playback startup, and rapid seeking;
- proxy creation and cancellation;
- synthetic and real-media export, cancellation, and peak resident memory.

Use Main Thread Checker, Time Profiler, Allocations, Leaks, SwiftUI redraw inspection, File Activity, Energy Log, and Core Animation/Metal tools where relevant. The current Windows workstation cannot run Instruments or the macOS UI.

## Known bottlenecks and next optimizations

- Custom Core Image effects and reverse-video preparation are intentionally more expensive than straight cuts; proxies and disk derivatives reduce repeated work, but physical-hardware profiling is still required.
- A project edit currently invalidates the composed preview by project revision. Source assets and prepared derivatives are reused, but section-level AVComposition patching remains future work.
- Automatic captions depend on the speed and language support of Apple’s on-device recognizer.
- Timeline drawing is virtualized, but smoothness at extreme zoom on Retina displays still needs frame-time measurement on real hardware.
