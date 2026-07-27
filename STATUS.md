# Project status

## Windows — `0.3.0-beta.1` candidate

The native Windows editor and downloadable self-contained installer are prepared for Windows 10/11 x64. The package includes .NET and FFmpeg, installs without administrator privileges, and does not require a separate runtime.

Verified locally on 27 July 2026:

- 39 unit/localization/regression tests and 28 MCP contract/service tests pass.
- 3 FFmpeg integration tests create, inspect, render, cancel, extract audio and a frame, and re-inspect real synthetic media.
- The MCP path has also created, natively validated, exported and re-inspected a real 720p project with video, audio and a text layer.
- The application builds with 0 warnings and 0 errors.
- The installer completes silently, the installed application reaches an idle input state and remains running, and the uninstaller exits successfully and removes the test installation.
- H.264 hardware encoders are probed and only selected after a real test; a compatible fallback remains available.
- Resolution/project settings, exact black pauses, range removal, safe duplicate, detached audio, original-audio extraction and frame capture are covered by regression tests.
- Windows performance measurements and environment details are recorded in `Documentation/PERFORMANCE.md`.

The Windows workstation became locked during final visual inspection. Accessibility inspection confirmed the complete Spanish editor and a prior launch crash was diagnosed and fixed, but a final pixel-by-pixel screenshot review is still pending. The installer is unsigned, so SmartScreen can warn. No blocking defects are currently known after the automated and smoke checks.

## Mac — `0.3.0-beta.1` source candidate

GitHub Actions run [30236063915](https://github.com/luucabg/cineleaf/actions/runs/30236063915) passed with Xcode 16.4 and Apple Swift 6.1.2:

- 39 core tests, 15 application/localization tests and 2 critical UI flows passed.
- Real synthetic media covered import, derivatives, analysis, effects, composition, cancellation and verified MP4 export.
- Packaging produced a universal `arm64`/`x86_64` app, ZIP, DMG and checksums.

The new utility pass adds the same project settings, black pauses, safe duplication, detached audio, verified M4A extraction and verified PNG frame capture. The source now contains 44 core tests, 17 application/localization/integration tests and 2 critical UI flows. This Windows workstation cannot compile AVFoundation code, so the updated Mac candidate must pass the macOS GitHub Actions gate before release.

Mac still needs a complete hands-on review on physical hardware before a signed public Mac download: playback feel, microphone permissions, Gatekeeper flow, long-session memory/energy profiling and final screenshots.

## Shared capabilities

Both implementations use the version-2 `.cineleaf` project format and exact rational time. They cover multi-track cuts, trims, split, duplicate, ripple editing, markers, transforms, text, fades, effects, transitions, subtitles, audio tools, background work, bounded caches, autosave/recovery and cancellable export. Windows currently preserves all version-2 keyframe data but its FFmpeg renderer does not yet evaluate animated keyframe curves; static values are rendered.

Both source trees include the same local automation contract. A stable MCP server calls a small native bridge on each platform to inspect media, validate projects, extract derived media and export. It supports dry runs, explicit write confirmation, stable IDs, allowed-root isolation, idempotent project writes and resumable failed renders. Audio/frame outputs are produced through verified temporary files before atomic promotion. The Windows bridge has passed real end-to-end export and extraction locally; the Mac bridge is verified by its CI build/test gate because this workstation cannot execute macOS binaries.

Automated evidence does not prove that software can never contain a bug. Report reproducible problems with the bug template and attach non-private diagnostics when possible.
