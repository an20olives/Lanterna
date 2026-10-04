# Dependencies

Every SPM dependency, pinned to an exact version. Personal, sideloaded use only.

| package | version | license | used by | notes |
|---|---|---|---|---|
| [KSPlayer](https://github.com/kingslay/KSPlayer) | 2.3.4 (exact) | GPL-3.0 | LanternaPlayer/EngineC | Engine C (MEPlayer). Tag dated 2025-02-20; builds with Xcode 16.4 / Swift 6.1. |
| [FFmpegKit (kingslay)](https://github.com/kingslay/FFmpegKit) | 6.1.4 (exact) | GPL-3.0 (FFmpeg built with --enable-gpl --enable-version3) | LanternaPlayer/EngineA, via KSPlayer | FFmpeg 6.1 xcframeworks shared by Engine A and C. Not the archived arthenica FFmpegKit. Encoders: AAC, ALAC, FLAC, PCM only (no AC3/EAC3). |

System frameworks only otherwise (AVKit, Network, CryptoKit, Security, VideoToolbox).

Build note: on a Mac with Homebrew FFmpeg installed, `swift build` of LanternaPlayer for macOS fails because `/usr/local/include` shadows FFmpegKit's headers. Build and test it for the tvOS simulator with `xcodebuild` instead.
