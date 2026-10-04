# Status: 2026-10-04 overnight build (P0 to P5)

Built without the P0 gate being recorded, at the owner's request. Everything below was verified on the simulator or in package tests only. Nothing has run on the Apple TV or iPhone.

## What exists

| Phase | Built | Verified how |
|---|---|---|
| P0 | Player stack, P0 lab (`Settings > Player lab`, or launch with `-lab`), LAN results at `:8765/p0/results.json` | 21 EngineA tests, router tests, simulator runs (see `p0-results.md`) |
| P1 LanternaKit | `MediaSource`, TMDB, AIOStreams, TorBox, Jellyfin, Trakt, SwiftData schema v1, stores, outbox, `SourceRegistry`, `StreamSelector`, `DeviceConfig` | 104 tests; one real AIOStreams response recorded as a fixture; TMDB, Jellyfin and Trakt fixtures are hand-written from public docs |
| P2 tvOS | Tab bar, Home with Continue Watching and shelves, See All, movie and show detail with Smart Resume, stream picker with auto-select, Search, Library (watchlist, favorites, history, Coming Soon, Media Library), Settings, diagnostics, Up Next, amber focus ring | 2 XCUITests with `XCUIRemote`: first-run screen, and browse to play to Continue Watching |
| P3 | QR pairing protocol and transport (iPhone sender, Apple TV receiver), Jellyfin Quick Connect relay, iPhone app on the same shared UI | Protocol and loopback tests. Camera scan and a real two-device run are untested |
| P4 | Your Services, TMDB watch providers cache, `DeepLinkArchive.json`, "Open in" cards | Archive logic tested. Every service is app-launch only; titles cannot deep link yet (logged per service in the archive) |
| P5 | Trakt device-code sign-in, scrobble outbox, pull before show, watchlist and history sync | Two-device test against a fake Trakt: resume within 10 s |

Parity against `replica/features.csv`: 65.4 of 100 (`replica/parity.md`). Every remaining must-have is "built, unverified on the TV".

## Not done

Skip Intro and recap, hero carousel, shelf editor, trailers, person page, external subtitles in the player, subtitle appearance, Jellyfin remote-address fallback, Jellyfin trickplay, custom lists, downloads, release notifications, Settings search. See the Missing list in `replica/parity.md`.

## Blocked on you

1. **Debrid account.** Every AIOStreams stream currently redirects to a "Payment required" placeholder. Renew TorBox (or point the config at a working debrid) and rerun a stream check.
2. **TMDB read token** and **Trakt client ID and secret**. Without TMDB the app shows placeholder titles. Put them in `Config/Local.xcconfig` (see `Local.xcconfig.example`) or paste them in Settings > Sources and keys.
3. **P0 on the Apple TV**, using the corpus in `p0-player-spike.md`. Start with the Toy Story file and the open questions in `p0-results.md`.

## Things most likely to need fixing on the TV

- HDR10 files failed to open on Engine A in the simulator and fell back to C. Check whether the TV switches to HDR10 on A. The init segment has `colr` but no `mdcv` or `clli`.
- Peak memory was about 6 GB on the 4K Toy Story file in the simulator (Engine C).
- Hi10P on Engine C crashed the simulator's Metal renderer.
- Menu from the player returns to Home instead of the detail page.
- tvOS stores SwiftData in Caches (purgeable by design). Confirm the store survives between launches.

## Commands

```
make ipa-tvos        # build/Lanterna-tvOS.ipa, unsigned
make ipa-ios         # build/Lanterna-iOS.ipa, unsigned
swift test --package-path Packages/LanternaKit
cd Packages/LanternaPlayer && xcodebuild test -scheme LanternaPlayer-Package -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -derivedDataPath .build/xcode
xcodebuild test -scheme Lanterna-tvOS -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

Debug launch arguments: `-lab` (open the P0 lab), `-dev-media-url <base>` (serve test files as streams), `-uitest-reset` (clean Keychain and in-memory store), `-autorun-url`, `-autorun-mode`, `-autorun-seconds` (headless lab runs).
