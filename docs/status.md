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

## Added after the first pass

Hero carousel, shelf editor (filters, TMDB lists, Trakt lists), person page, trailers row (opens the YouTube app), Skip Intro and recap skip from Jellyfin media segments, external subtitles from the stream source (served by Engine A as an extra rendition, passed to KSPlayer on C), subtitle size, colour, background and timing, Jellyfin remote-address fallback, Settings search, TorBox account check (`Settings > Sources and keys`, or `scripts/torbox-check.sh`).

## Polish pass (from on-TV testing)

Opaque stream picker, edge-to-edge rows that no longer clip focus rings, a rounded hero card that lands focus from the tab bar, scrolling text on focused items, trailers that play in the player (Apple's iTunes preview URLs; the YouTube row appears only when no preview exists), the app icon (`scripts/make-icons.py`), clearer stream cards.

## Third pass

- **Custom lists** (`Settings > Home screen > My lists`, "Add to list" on any detail page), **MDBList** and **Letterboxd** public lists as shelves (MDBList by keyless JSON, Letterboxd by reading the list page and matching title and year on TMDB; fragile if Letterboxd changes its markup).
- **Release notifications** on iPhone and Mac: local notifications at 9 am on the day of a watchlist or favourite title's next episode or release. Off by default (`Settings > Home screen`).
- **Subtitle position** (`Settings > Video player`): lifts subtitles off the bottom edge. Engine A via CoreMedia text markup, Engine C via KSPlayer's margin. Not yet seen on a real subtitled stream.
- **Jellyfin trickplay**: scrub thumbnails published to AVPlayer as an HLS image playlist on Engine A. Unit tested; needs a Jellyfin 10.9+ server and the real Apple TV to confirm the thumbnails show.
- **Downloads** (iPhone and Mac): background URLSession, files in Application Support, offline playback through a loopback file server so the normal remux path is reused. Verified in the simulator for an MP4 (download, then play from disk); the MKV path is unit tested only.
- **macOS app** (`Lanterna-macOS`, `make app-macos`, `make install-macos`): Engine A in an `AVPlayerView`, Engine C in an `NSHostingController`, sandboxed, ad hoc signed. Builds and the packages' tests pass, but the window has not been looked at: the session that built it had no display. Expect layout fixes.
- Fixes: the BrowseToPlay UI test no longer races the detail page's focus, iPhone stream picker layout and tint, playback retry stops when cancelled, zero first-party compiler warnings.

## Not done

MDBList and Letterboxd need no key but have no editor beyond a path field. Downloads have no queue limits or storage screen. Mac: no menu commands, no keyboard shortcuts, no pairing sender, hero strip uses the Apple TV layout. See the Missing list in `replica/parity.md`.

## Blocked on you

1. **TorBox renewal.** Streams now resolve to TorBox's CDN, but the plan expires 2026-10-05 23:26 UTC and is not auto-renewing.
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
make app-macos       # build/Lanterna.app + build/Lanterna-macOS.zip, ad hoc signed
make install-macos   # copies it to /Applications
scripts/push-tv.sh   # build, sign with the Personal Team, install on the Apple TV with devicectl
swift test --package-path Packages/LanternaKit
cd Packages/LanternaPlayer && xcodebuild test -scheme LanternaPlayer-Package -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -derivedDataPath .build/xcode
xcodebuild test -scheme Lanterna-tvOS -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

Debug launch arguments: `-route <screen>` (opens one screen directly inside the tab bar, e.g. `tab/library`, `settings/sources`, `detail/movie/603`, `picker/603`, `person/6384`), `-lab` (open the P0 lab), `-dev-media-url <base>` (serve test files as streams), `-uitest-reset` (clean Keychain and in-memory store), `-autorun-url`, `-autorun-mode`, `-autorun-seconds` (headless lab runs).
