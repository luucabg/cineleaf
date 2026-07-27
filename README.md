<p align="center">
  <img src="Branding/Exports/cineleaf-logo-horizontal.svg" alt="Cineleaf" width="460">
</p>

<p align="center">
  <strong>A fast, private, and free video editor for Windows and Mac.</strong><br>
  No account, cloud upload, ads, subscription, watermark, or tracking.
</p>

<p align="center">
  <a href="https://github.com/luucabg/cineleaf/releases/tag/v0.3.0-beta.2"><img alt="Latest beta" src="https://img.shields.io/github/v/release/luucabg/cineleaf?include_prereleases&color=327C60"></a>
  <a href="https://github.com/luucabg/cineleaf/actions/workflows/windows-ci.yml"><img alt="Windows tests" src="https://github.com/luucabg/cineleaf/actions/workflows/windows-ci.yml/badge.svg"></a>
  <a href="https://github.com/luucabg/cineleaf/actions/workflows/ci.yml"><img alt="Mac tests" src="https://github.com/luucabg/cineleaf/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-327C60.svg"></a>
</p>

## Download Cineleaf

Choose your computer below. These are ready-to-use downloads; you do not need to install programming tools.

| Your computer | Recommended download | Other download |
| --- | --- | --- |
| **Windows 10/11, 64-bit** | **[Download the Windows installer (.exe)](https://github.com/luucabg/cineleaf/releases/download/v0.3.0-beta.2/Cineleaf-0.3.0-beta.2-Windows-x64-Setup.exe)** | [Portable Windows version (.zip)](https://github.com/luucabg/cineleaf/releases/download/v0.3.0-beta.2/Cineleaf-0.3.0-beta.2-Windows-x64-Portable.zip) |
| **macOS 14 or newer, Apple Silicon or Intel** | **[Download the Mac installer (.dmg)](https://github.com/luucabg/cineleaf/releases/download/v0.3.0-beta.2/Cineleaf-0.3.0-beta.2-macOS.dmg)** | [Mac app (.zip)](https://github.com/luucabg/cineleaf/releases/download/v0.3.0-beta.2/Cineleaf-0.3.0-beta.2-macOS.zip) |

You can verify the downloads with the [Windows SHA-256 checksums](https://github.com/luucabg/cineleaf/releases/download/v0.3.0-beta.2/Cineleaf-0.3.0-beta.2-Windows-SHA256SUMS.txt) or [Mac SHA-256 checksums](https://github.com/luucabg/cineleaf/releases/download/v0.3.0-beta.2/Cineleaf-0.3.0-beta.2-macOS-SHA256SUMS.txt).

### Install on Windows

1. Download and open the `.exe` file.
2. Follow the installer. Administrator access is not required.
3. Open Cineleaf from the Start menu.

The Windows installer is not digitally signed yet, so Microsoft SmartScreen may show a warning. The complete source code, build process, and tests are public in this repository.

### Install on Mac

1. Download and open the `.dmg` file.
2. Drag Cineleaf into the Applications folder.
3. Open Cineleaf from Applications.

The Mac build is ad-hoc signed but not Apple-notarized because this project does not use a paid Apple Developer account. If macOS blocks the first launch, right-click Cineleaf and choose **Open**. You can also use **System Settings > Privacy & Security > Open Anyway**. Cineleaf never disables macOS security settings.

## What is Cineleaf?

Cineleaf is designed for people who want to make a video without learning a complicated professional editor. Drag in videos, photos, or music; cut and arrange them; add text, effects, transitions, or subtitles; then export an MP4 that is ready to share.

Everything is processed on your computer. Cineleaf does not upload your videos anywhere. The app is available in English and Spanish.

Windows and Mac use the same `.cineleaf` project format. You can move a project between them as long as its original video, image, and audio files are also available.

## Highly optimized for speed

Performance is a core part of Cineleaf, not an afterthought. It is heavily optimized to stay quick and responsive, including with large projects:

- The timeline draws only the part you can see instead of creating thousands of hidden items.
- A fast index finds visible clips without scanning the entire project.
- Thumbnails, waveforms, analysis, subtitles, and exports run in the background.
- Outdated preview work is cancelled as soon as you make a newer change.
- A size-limited cache reuses safe results without filling the disk.
- Audio and video are streamed in small parts instead of loading complete files into memory.
- Exact rational time prevents cuts from drifting because of decimal rounding.
- Windows tests NVIDIA, Intel, AMD, or system hardware encoding and uses the fastest working option. Mac uses Apple media frameworks and hardware acceleration when available.
- Preview quality can be reduced for smooth editing without reducing the quality of the final export.
- The Windows installer includes .NET and FFmpeg, so there is nothing else to install.

On a Ryzen 5 5600X, isolated engine benchmarks measured a median of **0.0040 ms** to locate the visible section of a 10,000-clip timeline, **0.3286 ms** to validate a one-hour/100-clip project, and **11.8451 ms** to move a clip with safe copying, history, and full validation. These are engine measurements, not a promise that every export will finish in that time. See [performance measurements and their limits](Documentation/PERFORMANCE.md).

## Main features

### Comfortable editing

- Landscape, vertical, square, and 4:5 projects at 24, 25, 30, 50, or 60 fps.
- Import video, audio, and images with a button, double-click, or drag and drop.
- Multiple tracks; move, trim, split, duplicate, delete, ripple-delete, undo, and redo.
- Insert black pauses of any length, remove exact time ranges, and detach audio from video.
- Markers, private beat detection, and reviewed silence detection/removal.
- Smooth timeline zooming and scrolling with virtualized drawing.
- Background preview composition with caching and cancellation.

### Effects and creation

- Position, scale, rotation, crop, opacity, speed, and reverse playback.
- Change project shape, resolution, and frame rate, from 720p to 4K.
- Exposure, contrast, saturation, temperature, tint, highlights, shadows, sharpening, and vignette.
- Blur, monochrome, sepia, bloom, sharpen, and vignette effects.
- Dissolve, fade-through-black, slide, wipe, and blur transitions.
- Configurable text and subtitles over the video.
- H.264 or HEVC MP4 export from 720p to 4K with AAC audio, progress, and cancellation.
- Extract original audio to M4A or save the current frame as a PNG.

### Automatic subtitles and privacy

Cineleaf can create automatic subtitles using speech recognition on the computer when the operating system supports it. Your audio is not sent to a Cineleaf server. You can review and correct the text before export, and import or export SRT and WebVTT subtitle files. Available languages depend on the speech packages installed on the computer.

### Useful ideas already included

- The same project format works on Windows and Mac.
- Beat detection creates useful points for cutting to music.
- Silence detection proposes changes for review before deleting anything.
- Automatic encoder selection tests the GPU instead of assuming it will work.
- Atomic saving, autosave, and recovery reduce the risk of losing work.
- Export checks free disk space, removes incomplete temporary files, and inspects the finished video again.

## Control Cineleaf with AI

Cineleaf includes an optional **MCP server**. MCP is a standard connection that lets a compatible AI understand and control the editor directly instead of trying to find buttons on the screen.

You can ask an AI to do things such as: “Create 12 vertical videos from these clips, add this title, and export them.” The AI can:

- Read a project with clear IDs for clips, tracks, and media.
- Prepare between 1 and 32 videos in a batch while keeping results in order.
- Move, trim, split, duplicate, transform, mute, or delete clips using exact times.
- Add black pauses, remove intervals, detach audio, and change the name, shape, frame rate, or resolution.
- Add text, subtitles, and markers; extract audio or a frame; and export H.264 or HEVC from 720p to 4K.
- Show a dry-run plan first and make changes only after that plan is accepted.

AI automation remains local. It can access only the folders you allow, and every project is validated by the native Windows or Mac engine before it is saved. Retry keys let interrupted batch work continue without creating duplicate projects.

The optional AI connection requires Node.js 20 or newer. See the plain-language [AI automation guide](Documentation/AI_AUTOMATION.md) for setup, examples, and safety limits.

## Main keyboard shortcuts

| Action | Windows | Mac |
| --- | --- | --- |
| Save | Ctrl+S | Command+S |
| Undo / redo | Ctrl+Z / Ctrl+Y | Command+Z / Shift+Command+Z |
| Split at the playhead | Ctrl+B | Command+B |
| Delete | Delete | Delete |
| Duplicate | Ctrl+D | Command+D |
| Add marker | M | M |
| Insert black pause | Ctrl+Alt+G | Option+Command+G |
| Detach audio | Ctrl+Alt+A | Option+Command+A |
| Play / pause | Space | Space |

## Current quality and honest limitations

The Windows code currently passes 39 unit tests, 28 MCP contract tests, and 3 integration tests with real FFmpeg processing. Packaging checks cover the Release build, silent installation, launch, uninstall, audio/frame extraction, and SHA-256 files. The Mac code has 44 engine tests, 17 app/integration tests, and 2 UI workflows; GitHub Actions builds and checks the universal Apple Silicon/Intel package.

No honest project can promise that software has zero bugs. This beta has no known release-blocking failures after the automated checks, but the Windows pixel-by-pixel visual review and a complete manual Mac test on physical hardware are still pending. See [STATUS.md](STATUS.md) for the exact current state and [ROADMAP.md](ROADMAP.md) for planned work.

## Privacy

Cineleaf has no account, telemetry, analytics, ads, or cloud storage. Editing and AI automation are local. Read the complete [privacy statement](PRIVACY.md).

## Build it yourself

Most people should use the downloads at the top of this page. Developers can build from source.

Windows targets .NET 8 and uses WPF and FFmpeg. The downloadable installer is self-contained:

```powershell
git clone https://github.com/luucabg/cineleaf.git
cd cineleaf
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_release.ps1
```

Mac requires macOS 14 or newer, Xcode 16.4 (Swift 6.1.2), and XcodeGen 2.42 or newer:

```bash
git clone https://github.com/luucabg/cineleaf.git
cd cineleaf
brew install xcodegen
xcodegen generate
swift test --package-path Packages/CineleafCore
xcodebuild -project Cineleaf.xcodeproj -scheme Cineleaf -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
./scripts/build_release.sh
```

The Mac release script creates an ad-hoc signed universal `.app`, `.zip`, `.dmg`, and SHA-256 checksums in `dist/`. It does not claim Apple notarization.

Architecture, project format, and rendering details are in [Documentation](Documentation).

## Contributing and translations

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and use the issue templates for bugs, feature ideas, or performance problems.

English is the base language and Spanish is included. Mac translations live in `Cineleaf/Resources/Localizable.xcstrings`; Windows translations live in `Windows/src/Cineleaf.Windows.App/Resources/Strings.en.xaml` and `Strings.es.xaml`. Add the same key to every language, keep technical format names unchanged, run the localization tests, and check that longer text still fits.

## License

Cineleaf is available under the [MIT License](LICENSE). FFmpeg and every redistributed component keep their own licenses, listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
