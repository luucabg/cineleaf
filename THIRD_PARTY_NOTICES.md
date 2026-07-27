# Third-party notices

## Windows application

- **.NET 8 / WPF** — MIT License and related .NET Foundation notices — the self-contained Windows package redistributes the Microsoft .NET runtime and WPF components.
- **System.Speech** — MIT License — used for optional offline speech recognition on Windows.
- **FFmpeg** — GNU Lesser General Public License version 3 or later — Cineleaf redistributes unmodified `ffmpeg.exe` and `ffprobe.exe` from the BtbN Windows build. The chosen build enables `version3` and does not enable GPL-only codecs. Its license text is included beside the binaries. Corresponding FFmpeg source is linked and archived with the release materials.
- **Inno Setup** — custom permissive license — used to create the Windows installer; it is not shipped as part of Cineleaf.

## Mac application

Cineleaf links Apple system frameworks supplied with macOS: SwiftUI, AppKit, AVFoundation, AVKit, CoreMedia, CoreImage/ImageIO, CoreAnimation/QuartzCore, CoreGraphics, CoreText, AudioToolbox, UniformTypeIdentifiers, Combine, Foundation, and `os`. They are not redistributed by this repository.

`CineleafCore` has no third-party package dependency.

## Build and repository tooling

- **Model Context Protocol TypeScript SDK** — MIT License — stable version 1.29.0 provides the optional local MCP server and is installed only when AI automation is enabled.
- **Zod** — MIT License — version 4.4.3 validates the optional automation contract. Transitive npm packages retain the license files recorded in the locked dependency tree.

- **XcodeGen** — MIT License — used to generate the Xcode project; not shipped in Cineleaf.
- **Pillow** — HPND License — used by `scripts/generate_branding_assets.py`; not shipped in Cineleaf.
- **DejaVu Sans** — Bitstream Vera and Arev-derived permissive licenses — used when available for repository artwork; no font file is redistributed.
- **GitHub Actions runner software** — used only in CI under its respective licenses.

The Cineleaf logo, icon, social preview, and UI source are original project assets released under the repository's MIT License.
