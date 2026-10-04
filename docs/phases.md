# Phases and gates

| Phase | Scope | Gate (must be true to move on) |
|---|---|---|
| P0 | Player spike: Engine A vs Engine C on the real Apple TV | `docs/p0-results.md` filled in; engine strategy confirmed or changed |
| P1 | LanternaKit: MediaSource protocol, AIOStreams client, TMDB, Keychain, SwiftData models | Catalogs, meta, and streams resolve in tests against recorded fixtures and the live manifest |
| P2 | tvOS UI: home rows, detail, source picker, player hookup, Siri Remote focus | Browse to play using only the Siri Remote, both engines reachable |
| P3 | iOS UI, TorBox library, Jellyfin source, QR pairing to Apple TV | Same library visible on both devices; credentials reach tvOS without typing |
| P4 | Subscribed services: settings, TMDB provider tags, deep links | Every service the owner pays for opens the right title, or the gap is logged per service |
| P5 | Trakt sync: history, watchlist, continue watching | Start on iPhone, resume on Apple TV within 10 seconds of the stop point |

After P5: `/replica-test` full pass, then `/replica-diff` against `replica/features.csv`. Target parity 85+ with every must-have done.
