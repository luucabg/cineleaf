# Project status

## Windows — `0.2.0-beta.1` candidate

The native Windows editor and downloadable self-contained installer are prepared for Windows 10/11 x64. The package includes .NET and FFmpeg, installs without administrator privileges, and does not require a separate runtime.

Verified locally on 27 July 2026:

- 33 unit/localization/regression tests and 21 MCP contract/service tests pass.
- 2 FFmpeg integration tests create, inspect, render, cancel, and re-inspect real synthetic media.
- The MCP path has also created, natively validated, exported and re-inspected a real 720p project with video, audio and a text layer.
- The application builds with 0 warnings and 0 errors.
- The installer completes silently, the installed application reaches an idle input state and remains running, and the uninstaller exits successfully and removes the test installation.
- H.264 hardware encoders are probed and only selected after a real test; a compatible fallback remains available.
- Windows performance measurements and environment details are recorded in `Documentation/PERFORMANCE.md`.

The Windows workstation became locked during final visual inspection. Accessibility inspection confirmed the complete Spanish editor and a prior launch crash was diagnosed and fixed, but a final pixel-by-pixel screenshot review is still pending. The installer is unsigned, so SmartScreen can warn. No blocking defects are currently known after the automated and smoke checks.

## Mac — source pre-release

GitHub Actions run [30236063915](https://github.com/luucabg/cineleaf/actions/runs/30236063915) passed with Xcode 16.4 and Apple Swift 6.1.2:

- 39 core tests, 15 application/localization tests and 2 critical UI flows passed.
- Real synthetic media covered import, derivatives, analysis, effects, composition, cancellation and verified MP4 export.
- Packaging produced a universal `arm64`/`x86_64` app, ZIP, DMG and checksums.

Mac still needs a complete hands-on review on physical hardware before a signed public Mac download: playback feel, microphone permissions, Gatekeeper flow, long-session memory/energy profiling and final screenshots.

## Shared capabilities

Both implementations use the version-2 `.cineleaf` project format and exact rational time. They cover multi-track cuts, trims, split, duplicate, ripple editing, markers, transforms, text, fades, effects, transitions, subtitles, audio tools, background work, bounded caches, autosave/recovery and cancellable export. Windows currently preserves all version-2 keyframe data but its FFmpeg renderer does not yet evaluate animated keyframe curves; static values are rendered.

Both source trees now include the same local automation contract. A stable MCP server calls a small native bridge on each platform to inspect media, validate projects and export. It supports dry runs, explicit write confirmation, stable IDs, allowed-root isolation, idempotent replays and resumable failed renders. The Windows bridge has passed a real end-to-end export locally; the Mac bridge is verified by its CI build/test gate because this workstation cannot execute macOS binaries.

Automated evidence does not prove that software can never contain a bug. Report reproducible problems with the bug template and attach non-private diagnostics when possible.
