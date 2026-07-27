# Rendering pipeline

On Windows, `Cineleaf.Windows.Media` builds an FFmpeg filter graph for the composed video and audio timeline. It handles gaps, transforms, crop/scale/rotation, opacity, text, color/effects, speed/reverse, fades, transitions, delay and mixing. A short real encode chooses a working hardware encoder; a compatible fallback remains available. Render processes are cancellable, progress is parsed, free space is checked first, incomplete outputs are removed, and the result is probed again before success is reported.

Preview and export start from the same validated project snapshot and render decisions.

Audio extraction and frame capture use a smaller derived-media path. Windows invokes FFmpeg without a command shell; Mac uses AVFoundation/ImageIO. Both validate time ranges and extensions, write to a unique temporary file beside the destination, inspect the produced media, and only then promote it atomically. Failure or cancellation removes the temporary result and preserves any previous destination.

1. Resolve enabled media through a security-scoped, project-relative, or last-known file reference.
2. For preview, prefer a valid 540p proxy when present. For export, always resolve the original source.
3. Reuse cached AVFoundation assets, tracks, source geometry, and a matching composition revision.
4. Insert exact source ranges into video/audio composition tracks. Apply speed scaling and cached bounded reverse derivatives where requested.
5. Apply preferred orientation, fit/fill/crop, user transform, keyframed motion, opacity, clip-edge transitions, audio level, and volume/fade ramps.
6. When color or image effects require it, render frames through the cancellable Core Image compositor. Straight edits stay on AVFoundation’s standard composition path.
7. Render installed-font text, subtitles, and image overlays with Core Animation.
8. Preview through `AVPlayerItem`. Inspector changes are debounced, obsolete rebuilds are cancelled, and project-revision checks prevent stale results replacing newer work.
9. Export with an available AVFoundation H.264/HEVC preset and AAC audio, show framework progress, prevent idle sleep during the job, and support cancellation.
10. Inspect the finished asset for playable duration, dimensions, video, and audio before reporting success. Remove partial output after failure or cancellation.

## Performance and memory rules

- Source movies are streamed; no step intentionally loads a complete video into memory.
- Reverse video generates and writes one frame at a time. Streaming audio analysis uses decoded PCM buffers.
- Thumbnail, waveform, proxy, reverse, and preview work uses stable modification-aware keys and bounded memory/disk stores.
- Cache clearing never removes original media, collected project media, or project JSON.
- A proxy changes preview decoding cost only. It cannot lower final export quality.
- Extracting original audio or a source frame does not rebuild the full timeline composition and runs away from the interface thread.

## Current transition scope

The current renderer provides clip-edge entrance and exit effects: dissolve-style fade, fade through black, slide, wipe, and blur with duration control. A future handle-based editor will overlap moving frames from two adjacent clips. The current UI and documentation do not claim that deeper adjacent-clip workflow exists.
