# Architecture

> Cineleaf now has two native front ends over compatible project concepts: Swift/AppKit/AVFoundation on Mac and C#/WPF/FFmpeg on Windows. The Windows solution lives in `Windows/` and is divided into `Cineleaf.Windows.Core` (models, editing, persistence), `Cineleaf.Windows.Media` (inspection, preview, captions and export), and `Cineleaf.Windows.App` (native UI). Neither version embeds a website.

## AI automation boundary

`Automation/mcp` is a small Node.js MCP server shared by Windows and Mac. It owns public request schemas, allowed-root checks, dry-run/confirmation rules, idempotency, exact project construction, bounded batches and compact project inspection. It does not decode or render media itself.

The server starts a native process with an argument array and no shell. `Cineleaf.Windows.Automation` delegates inspection, validation and export to the same .NET/FFmpeg media services as the Windows app. `CineleafCLI` delegates those operations to `CineleafCore`, AVFoundation composition and export services on Mac. Both return a small JSON envelope on standard output, send progress separately on standard error and observe cancellation.

The boundary is intentionally schema-first: seconds are convenient at MCP input, then converted to normalized rational time before persistence. Projects are validated by the native platform before an atomic write is committed. MCP batches are orchestration, not 32 unbounded encoders; concurrency is limited to four and defaults to two.

## Boundaries

`CineleafCore` owns value models, exact timeline arithmetic, validation, interval indexing, editing commands, subtitle/automatic-caption rules, beat-marker selection, bounded history, project-format migration, and persistence primitives. It imports Foundation and CoreMedia where exact media interoperation is required, but never SwiftUI.

The `Cineleaf` application owns macOS presentation and Apple media frameworks. Its subsystems are deliberately narrow:

- `App`: application lifecycle, command routing, shared editor state, recent projects, recovery, and language state.
- `Services`: security-scoped/project-relative media access, metadata, thumbnails, waveforms, streaming audio analysis, captions, proxies, reverse/freeze derivatives, media consolidation, cache, composition, playback, export, and local diagnostics.
- `UI`: editor layout, media library, timeline, preview, inspectors, export, settings, and accessible native controls.

Protocols isolate media inspection, thumbnails, waveforms, composition, playback, and export so deterministic fakes can exercise UI and state without decoding media.

## Concurrency

UI state is `@MainActor`. File and media work lives in actors and asynchronous services. Operations accept or observe cancellation, cache only bounded derived data, and identify results by request/project revision before committing them to UI state. Transient drag state is separate from committed project snapshots.

No source video is read into memory in full. AVFoundation streams samples. Thumbnail and waveform requests are bounded, modification-aware, and cancel stale work. Audio analysis streams PCM buffers; reverse video writes one generated frame at a time. Composition changes are coalesced after committed edits rather than pointer-move frequency.

## Editing model

Frame-sensitive time is represented by a normalized rational value and converts losslessly to `CMTime` when the denominator fits CoreMedia. Every mutation is validated before commit. A bounded snapshot history provides undo and redo for destructive edits; transient playback and selection are not part of project history.

Tracks own clips. Overlap is permitted on distinct video tracks but rejected within a track unless an editing operation explicitly resolves it. Locked tracks reject mutations. Clip duration must remain positive, source time cannot be negative, and timeline time cannot be negative.

## Rendering

The composition builder maps enabled timeline clips into `AVMutableComposition`, scales speed, resolves bounded reverse derivatives, creates standard transform/opacity/audio ramps, and overlays text through Core Animation. Color, effects, wipes, and blur use a cancellable Core Image compositor. Preview and export consume the same project decisions. Preview may use lower-resolution proxy media; export always uses source media.

## Diagnostics and privacy

Local timed diagnostics currently cover project open/save, import, thumbnails, waveforms, composition rebuild, autosave, and export. Diagnostics remain on-device and contain no source content, account identifiers, or remote endpoint. Cineleaf has no telemetry or network service.
