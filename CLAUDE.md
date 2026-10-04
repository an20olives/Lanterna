# Lanterna

Personal media hub for iPhone and Apple TV. One owner, sideloaded only. It will never be submitted to the App Store, so App Review rules do not constrain design, but free-provisioning signing rules do (see Signing).

## Product scope

- Sources, all behind one `MediaSource` protocol:
  - AIOStreams: a Stremio addon protocol client (manifest, catalog, meta, stream, subtitles). Debrid provider is TorBox.
  - TorBox API: the user's own library (torrents, usenet, web downloads).
  - Jellyfin: on the home Raspberry Pi, reached over Tailscale (HTTPS through Caddy).
  - TMDB: metadata, artwork, and watch providers.
  - Trakt: watch history, watchlist, continue watching, cross-device sync.
- Subscribed services (Disney+, Apple TV+, Max, etc.): the user declares them in Settings. Titles are tagged from TMDB watch-provider data, and "Open in <service>" deep-links into the installed app. There is no subscription API; never pretend there is.
- Feature target: `replica/features.csv` from `/replica-recon` of Prism (prismhub.app). Rebuild features and flows clean-room. Never copy Prism code, assets, name, icon, or copy.

## Stack

- Swift 6, SwiftUI. Targets: iOS and tvOS, deployment target 26.0 (lower it to match the Apple TV's installed tvOS if needed; the Apple TV is frozen on updates because atvloadly lags new releases).
- XcodeGen. `project.yml` is the source of truth. Never hand-edit anything inside `Lanterna.xcodeproj`. After changing `project.yml`, run `xcodegen generate`.
- Local Swift packages:
  - `Packages/LanternaKit`: models, MediaSource adapters, networking, Keychain, SwiftData persistence, Trakt sync.
  - `Packages/LanternaPlayer`: PlaybackRouter, Engine A (remux to HLS into AVPlayer), Engine C (FFmpeg-based fallback).
- App targets are thin UI shells over these packages. Shared SwiftUI views live in `Apps/Shared`; platform-specific views in `Apps/iOS` and `Apps/tvOS`.
- SPM dependencies pinned to exact versions. Record every dependency and its license in `docs/dependencies.md`.
- Persistence: SwiftData, local only. Cross-device sync goes through Trakt. No CloudKit.

## Player architecture (decided)

`PlaybackRouter` probes each stream (container, video codec and profile, audio codecs, subtitle types, Dolby Vision profile) and picks an engine. Log every routing decision with the probe result.

**Engine A (primary): on-device remux to HLS, played in `AVPlayerViewController`.**
- FFmpeg demuxes the remote file through a custom AVIO context doing HTTP range requests.
- Video: stream copy (H.264, HEVC, Dolby Vision profiles 5 and 8.x). Never transcode video.
- Audio: copy AAC, AC3, EAC3 (including Atmos JOC). Transcode DTS, DTS-HD, and TrueHD to EAC3 5.1.
- Subtitles: SRT and ASS to WebVTT renditions. PGS is not supported in A; selecting a PGS track reroutes to Engine C.
- fMP4 segments generated on demand from Matroska Cues, served by a localhost HTTP server as a VOD playlist so duration and seeking are known up front.
- Engine A must keep every native tvOS feature working: transport bar, info panel (chapters, audio, subtitles), Siri rewind, clickpad scrubbing with thumbnails, frame-rate and dynamic-range matching, Dolby Vision and Atmos passthrough, PiP, Now Playing.

**Engine C (fallback): FFmpeg-based renderer (KSPlayer MEPlayer is the leading candidate; confirm in P0).**
- Used for: Hi10P, AV1 on hardware without AV1 decode, PGS subtitles, VC-1, anything A fails to probe or open.
- Must implement by hand: Now Playing (`MPNowPlayingInfoCenter`), display criteria matching (`AVDisplayManager`), PiP where the renderer allows, and a custom transport bar that copies native tvOS behavior as closely as possible.

Engine A and C should share one FFmpeg build.

## Signing and distribution constraints

The tvOS app is signed with a free, dedicated Apple ID by atvloadly on the Pi. The iOS app is sideloaded through AltStore.

- 7-day profiles, refreshed automatically. Maximum 3 active sideloaded apps per Apple ID.
- Do not use entitlements a free Personal Team cannot get: iCloud/CloudKit, Push Notifications, Associated Domains, Sign in with Apple. App Groups are unverified; do not depend on them until tested.
- No app extensions in v1 (Top Shelf is deferred). Each extension consumes an App ID and complicates re-signing.
- The signer rewrites the bundle ID. Never hardcode bundle ID, team ID, or a Keychain access group. Use the default Keychain access group.
- Distribution artifact is an unsigned IPA: `make ipa-tvos` and `make ipa-ios`.

## Secrets

- TorBox API key, AIOStreams manifest URL (it embeds encrypted config), TMDB key, and Trakt tokens go in Keychain only.
- Never log them, never write them to UserDefaults or SwiftData, never commit them. Redact them in all logs and test fixtures.
- tvOS has no web view and typing on a remote is miserable. Credentials reach the Apple TV through (a) a QR pairing flow from the iPhone over the local network, or (b) Trakt's device-code login.
- Commit only `.env.example`.

## Commands

```
xcodegen generate
xcodebuild -scheme Lanterna-tvOS -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' build
xcodebuild -scheme Lanterna-iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild test -scheme Lanterna-tvOS -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
swift test --package-path Packages/LanternaKit
make ipa-tvos
make ipa-ios
```

If a simulator name does not exist, run `xcrun simctl list devices available` and pick the closest match. Do not guess.

Player work must be verified on the real Apple TV, not the simulator. The simulator does not exercise hardware decode, HDR or Dolby Vision mode switching, or audio passthrough.

## Workflow

1. Phase order: P0 player spike, then P1 LanternaKit, P2 tvOS UI, P3 iOS UI plus TorBox library and Jellyfin, P4 subscribed services, P5 sync. Details and gates are in `docs/phases.md`.
2. The replica skills drive the feature work. Steering for each step is in `docs/replica-steering.md`. Ignore defaults in those skills that assume web stacks, Playwright, Postgres, payments, or deploying to a domain.
3. Run `/replica-recon` before P1, but no `/replica-build` work starts until the P0 gate is recorded in `docs/p0-results.md`.
4. Tests: XCTest for the packages; XCUITest with `XCUIRemote` for tvOS flows. Recorded AIOStreams, TorBox, and TMDB responses live in `Tests/Fixtures` with all secrets and file URLs scrubbed.
5. Report honestly. If a build or test fails, show the output. If a step was skipped, say so.

## Style

- User-facing copy: short, plain, no em dashes.
- Accent color amber `#E8A23C`. This is also the tvOS focus ring color.
