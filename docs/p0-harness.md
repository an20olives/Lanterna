# P0 harness: build spec (M0 steps 4 and 5)

The player stack is done and tested (`Packages/LanternaPlayer`, `Packages/LanternaKit`). This is the remaining M0 work: a debug tvOS screen that runs the spike on the real Apple TV, plus the app wiring and IPA. Read `docs/p0-player-spike.md` for what is measured and the gates.

## Constraints (from CLAUDE.md)

- Xcode 16.4, tvOS/iOS 18.0 deployment target, 18.5 SDK. No OS 26 APIs.
- XcodeGen: edit `project.yml`, run `xcodegen generate`. Never edit `Lanterna.xcodeproj`.
- TorBox key in Keychain only (`KeychainStore`, key `.torboxAPIKey`). Never log URLs; use `Redactor` from LanternaKit for anything URL-shaped.
- User-facing copy: short, plain, no em dashes. Accent `#E8A23C`.
- The TV is on tvOS 26, so the harness runs from an IPA via atvloadly with no debugger. It must report results on its own.

## 1. Wiring

- `project.yml`: targets already list `Apps/Shared`, `Apps/iOS`, `Apps/tvOS`, `Tests/UITests-tvOS` and packages `LanternaKit`, `LanternaPlayer`. Make those directories exist with real sources. Add `PlayerCore` and `LanternaPlayer` products as needed (`- package: LanternaPlayer` with `product: LanternaPlayer`).
- iOS app: a placeholder `@main` App with one screen ("Lanterna" title, "Player spike runs on Apple TV"). It only has to build.
- tvOS app: `@main` App whose root is the harness (below).
- `Tests/UITests-tvOS`: one smoke test that launches the app and checks the setup screen appears.
- Verify: `xcodebuild -scheme Lanterna-tvOS -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' build`, the iOS equivalent on `iPhone 16 Pro`, then `make ipa-tvos` and `make ipa-ios`. Show any failures in full.

## 2. Harness screens (Apps/tvOS)

1. **Setup.** If no TorBox key in Keychain: one secure text field ("TorBox API key"), Save. tvOS offers iPhone keyboard entry automatically. Remove key button for re-entry.
2. **Library.** `TorBoxClient.list(.torrents)`, `.usenet`, `.webDownloads`. Show ready items (`isReady`) and their `videoFiles` (short name, size in GB). Errors shown plainly with Try Again.
3. **File.** On select: `TorBoxClient.downloadLink` (fresh link, in memory only), then `PlaybackRouter().prepare(url:context:)` with `RoutingContext(preferences: eng/eng, subtitles off, forced on; hardware: PlaybackRouter.hardwareCapabilities(); transcodeTarget: picker ALAC/FLAC/AAC 5.1; forcedEngine: from buttons)`. Show `record.probeSummary`, the decision (engine + reasons), and buttons: **Play Auto**, **Play A**, **Play C**, **Seek test**. Each button re-prepares (links are cheap; remux sessions are per play).
4. **Player.** Present `router.makeSession(for:)`'s `viewController` full screen. Listen to `events`:
   - `.firstFrame(ms)` → TTFF.
   - `.failed` before first frame on A → automatic `router.reroute(prepared, to: .engineAFailedOpen, at: 0)` and record both.
   - For `EngineASession`, set `onImageSubtitleRequest` → `reroute(..., to: .userSelectedImageSubtitle, at:, subtitleTrack:)`.
   - Sample memory every second (`task_vm_info.phys_footprint`), keep the peak.
   - On Menu/close: `stop()`, collect `diagnostics()`, go to Observations.
5. **Seek test.** Plays, waits for first frame, then 10 seeks to random positions between 5% and 90% of duration (seeded so A and C get the same positions), each via `session.seek(to:)`. Records latencies; median and p90 via `Stats`.
6. **Observations.** Large focusable choices: DV or HDR mode on the TV (Yes / No / Not applicable), Atmos on receiver (Yes / No / NA), Subtitles (Yes / Degraded / No / NA), native features checklist for A (transport bar, info panel tracks, chapters, Siri rewind, scrub thumbnails, PiP), A/V drift after 10 min (free text optional, or None / Slight / Bad). Save.
7. **Results.** Table of runs. Plus a LAN endpoint: `TinyHTTPServer(bind: .allInterfaces(port: 8765))` serving `GET /p0/results.json` while the app is open; show the TV's IP and the URL on screen. JSON contains file short name, probe, decision, engine actually played, TTFF, seeks, median, p90, peak memory MB, diagnostics, observations. No URLs, no keys (test this).

Persist runs as JSON in the Caches directory (may be purged; the LAN export is the real record).

## 3. Results template

Create `docs/p0-results.md` with the table header from `docs/p0-player-spike.md` (one row per stream per engine) and a "Routing decision" and "Gate" section left blank for the owner to fill from the JSON.

## Done when

- Both app targets build in the simulator, the tvOS UI smoke test passes, both IPAs build.
- Package tests still pass: `cd Packages/LanternaPlayer && xcodebuild test -scheme LanternaPlayer-Package -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -derivedDataPath .build/xcode` and `swift test --package-path Packages/LanternaKit`.
- Committed, with the owner told how to install via atvloadly (`ops/atvloadly-pi.md`) and fetch results with curl.
