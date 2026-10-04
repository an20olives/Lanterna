# Replica skills: steering for a native Apple app

The replica skills assume web stacks by default (Next.js, Postgres, Playwright, payments, deploy to a domain). Paste the steering block with each command.

## 1. /replica-recon

```
/replica-recon Target: Prism (https://prismhub.app), the media hub app for iPhone, iPad, Mac, and Apple TV. Use public sources only: the website, the App Store listing (screenshots and release notes), and public video walkthroughs. Map every screen and flow for iPhone and Apple TV separately, including the tvOS focus behavior where visible. Mark the subscribed-services feature as a manual declaration plus a lookup archive, not an API. In features.csv, add these rows as must-haves even if Prism lacks them: AIOStreams addon source, TorBox library, PlaybackRouter with two engines. Mark Mac and iPad as out of scope.
```

## 2. /replica-architect

```
/replica-architect Constraints are fixed in CLAUDE.md; do not propose alternatives to them. Native Swift 6 / SwiftUI, iOS and tvOS only, XcodeGen, packages LanternaKit and LanternaPlayer, no server, no database other than on-device SwiftData, no payments, no auth beyond per-source credentials in Keychain. Produce: the MediaSource protocol and the adapter list, the SwiftData schema, the PlaybackRouter interface and probe model, the QR pairing protocol between iPhone and Apple TV, and a build order that starts with whatever P0 needs. Respect every free-provisioning signing limit in CLAUDE.md.
```

## 3. /replica-design

```
/replica-design Build tokens for SwiftUI, not CSS. Dark-first. Accent amber #E8A23C, also the focus ring. Include tvOS focus states (scale, shadow, parallax) for posters, buttons, and rows; iOS 26 Liquid Glass materials for chrome. Icon: layered tvOS parallax stack in three layers (ink-to-aubergine gradient background, soft amber light cone, aperture) plus an Icon Composer export for iOS. Run contrast.py on the tokens.
```

## 4. /replica-build

Run per phase, after the P0 gate. Point it at `docs/phases.md` and the current phase only.

## 5. /replica-backend

```
/replica-backend There is no server. "Backend" here means the source adapters: AIOStreams (Stremio addon protocol), TorBox API, TMDB (including watch providers), Trakt (device-code OAuth), and Jellyfin over Tailscale. Secrets in Keychain only. Skip auth providers, databases, payments, and email entirely.
```

## 6. /replica-test

```
/replica-test Replace Playwright with XCTest for the packages and XCUITest with XCUIRemote for tvOS flows. Use recorded fixtures in Tests/Fixtures with secrets and file URLs scrubbed. Player tests that need hardware are listed as manual checks against docs/p0-player-spike.md, not faked in the simulator.
```

## 7. /replica-diff

Run as-is against `replica/features.csv`.

## 8. /replica-entrepreneur (optional, cheap)

Run on Prism's public reviews. Use the top complaints as P2 to P5 acceptance criteria.

## 9. /replica-brand

The name is settled (Lanterna). Run only the sweep:

```
python3 replica-brand/sweep.py . --avoid "Prism" --avoid "prismhub"
```

## 10 and 11. /replica-launch, /replica-deploy

Skip both. Distribution is `make ipa-tvos` and `make ipa-ios`, then atvloadly and AltStore (see `ops/atvloadly-pi.md`).
