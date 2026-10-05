# Lanterna

A personal media hub for Apple TV, iPhone and Mac. One owner, sideloaded only, never on the App Store.

Lanterna browses titles from TMDB, finds streams through an AIOStreams (Stremio addon) config backed by a debrid service, plays your own TorBox and Jellyfin libraries, and keeps watch progress in sync across devices through Trakt.

## What it does

- **Browse**: Home with a featured strip, shelves you can edit, Continue Watching, Search, Library (watchlist, favorites, history, Coming Soon), movie, show and person pages.
- **Play**: a router probes each stream and picks an engine. Engine A remuxes MKV to fMP4 HLS on the device and plays it in the native tvOS player (Dolby Vision, HDR10, Atmos passthrough, chapters). Engine C falls back to an FFmpeg renderer for what Engine A cannot carry (Hi10P, AV1, PGS subtitles).
- **Sources**: AIOStreams, TorBox, Jellyfin (over Tailscale), TMDB, Trakt. Subscribed streaming services open in their own apps.
- **Setup without typing**: QR pairing sends credentials from an iPhone to the Apple TV over the local network, end to end encrypted.

## Layout

```
Apps/            SwiftUI shells: Shared, iOS, tvOS (plus the P0 player lab), macOS
Packages/
  LanternaKit/     models, sources, networking, Keychain, SwiftData, Trakt sync, pairing
  LanternaPlayer/  PlaybackRouter, Engine A (remux to HLS), Engine C (KSPlayer)
Tests/           XCUITest flows for tvOS
docs/            phases, P0 spike results, status, dependencies
replica/         recon and architecture notes for the feature target
```

## Build

Xcode 16.4 (Swift 6.1, iOS and tvOS 18.5 SDKs) and [XcodeGen](https://github.com/yonaskolb/XcodeGen). `project.yml` is the source of truth; never edit `Lanterna.xcodeproj`.

```bash
xcodegen generate
swift test --package-path Packages/LanternaKit
xcodebuild test -scheme Lanterna-tvOS -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
make ipa-tvos   # build/Lanterna-tvOS.ipa, unsigned
make app-macos  # build/Lanterna.app, ad hoc signed; make install-macos copies it to /Applications
make ipa-ios    # build/Lanterna-iOS.ipa, unsigned
```

Install the unsigned IPAs with atvloadly (Apple TV) and AltStore (iPhone); see `ops/atvloadly-pi.md`.

## Secrets

Credentials live in the Keychain only. For local development, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) to seed them on first launch. Never commit that file or an IPA built with it.

## Status

See `docs/status.md`. The player stack and the app are working on a real Apple TV; the formal P0 measurements in `docs/p0-results.md` are still being collected.

## Licenses

Dependencies and their licenses are listed in `docs/dependencies.md`. KSPlayer and the FFmpeg build it uses are GPL-3.0, which is fine for a personal build but means distributing binaries would require releasing the source under the same terms.
