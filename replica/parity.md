## Parity: 65.4 / 100

features 65.4  (91 counted, must-haves 29 of 41 done)

Not shippable yet: 12 must-have features are not done.

## By area, weakest first
- pairing                       30.0  (3 features)
- player                        47.5  (27 features)
- sources                       53.1  (7 features)
- home                          53.8  (6 features)
- library                       60.0  (6 features)
- ios                           60.0  (3 features)
- tvos                          65.6  (6 features)
- detail                        68.4  (9 features)
- search                        80.0  (2 features)
- settings                      88.9  (4 features)
- sync                          92.3  (5 features)
- streams                       94.4  (8 features)
- services                     100.0  (5 features)

## Missing, in build order
- [must] pairing: First-run setup on Apple TV without typing, partial  (QR pairing or Trakt device code | Built: QR receiver and Trakt code exist; first-run screen routes to them)
- [must] player: Audio and subtitle track switching in player, partial  (Grouped by language; preferred first | Built: Native menus on A, KSPlayer menus on C)
- [must] player: Engine A: DV P5 and P8.x stream copy with DV mode switch, partial  (Highest-risk item; verify on real Apple TV | Built: dvcC/dvvC kept in init segment (unit tested); TV mode switch unverified)
- [must] player: Engine A: EAC3 Atmos copy, partial  (Built: Copied with JOC channel signalling; TV unverified)
- [must] player: Engine A: HDR10 and HLG with mode switch, partial  (Built: colr/hvcC and VIDEO-RANGE written; simulator cannot verify; mdcv/clli not written)
- [must] player: Engine A: frame-rate and dynamic-range matching, partial  (Wait for mode switch before first frame | Built: appliesPreferredDisplayCriteriaAutomatically; TV unverified)
- [must] player: Engine A: native tvOS transport bar info panel chapters Siri rewind scrub thumbnails, partial  (AVPlayerViewController | Built: AVPlayerViewController with chapters and custom menu; TV unverified)
- [must] player: Engine C: Hi10P AV1 VC-1 PGS and probe failures, partial  (Prism plays these in its own engine | Built: KSPlayer MEPlayer; plays 8-bit in simulator, Hi10P crashed the simulator renderer)
- [must] player: Now Playing and remote fast-forward and rewind commands, partial  (Engine A gets most of this free | Built: Engine A via AVKit; Engine C via KSPlayer)
- [must] player: Up Next countdown card and auto-play next episode, partial  (Configurable 15 to 90 s before end | Built: Card and auto-advance built; not UI tested)
- [must] sources: Jellyfin source over Tailscale via HTTPS, partial  (TMDB-first matching by ProviderIds; title+year fallback stays unmatched if ambiguous | Built: Auth, Quick Connect, library, streams, progress built against fixtures; no live server run)
- [must] tvos: tvOS focus: Menu returns to top not out of app, partial  (Built: Not verified on device)
- [should] detail: Trailers row, no  (TMDB video keys; no Prism resolver)
- [should] home: Custom shelves from filters (genre year rating language), no  (Cap 20 | Built: Config supports presets; no editor)
- [should] home: Hero carousel (optional), no
- [should] player: External subtitles from AIOStreams subtitle resource, no  (Prism uses OpenSubtitles and SubDL | Built: AIOStreams subtitle API implemented, not wired into the player)
- [should] player: Pre-resolve next episode stream near end, no
- [should] player: Quiet reconnect on brief network drop, no
- [should] player: Skip Intro button from server markers, no  (Jellyfin segment markers; no Prism database)
- [should] player: Subtitle appearance (font size delay position), no
- [should] sources: Jellyfin remote address fallback, no  (Try primary then remote automatically | Built: Remote URL is stored; automatic fallback not built)
- [should] sources: Server badge on posters for owned titles, no
- [should] tvos: tvOS focus: cancel stream search restores focus, no
- [should] tvos: tvOS focus: down from show artwork lands on current episode, no
- [should] detail: Cast row and person page, partial  (Built: Cast row only; no person page)
- [should] detail: Context menus on posters, partial  (Long-press on tvOS | Built: Continue Watching card only)
- [should] home: See All grid with filter and sort, partial  (tvOS ends every shelf with See All | Built: Paged grid with client-side sort; no filter sheet)
- [should] library: Media Library browse (own files only), partial  (Sort Title Year Recently Added | Built: List with play; no sort menu)
- [should] player: Default audio keeps file's own track; skip commentary and AD, partial  (Built: Routing keeps the file's default; commentary filter not applied)
- [should] player: Forced subtitles auto-select, partial  (Metadata only | Built: Forced preference feeds routing)
- [should] player: PiP on iPhone, partial  (Built: AVPlayerViewController default plus playback audio session; untested)
- [should] search: Search history and genre browse grid, partial  (Built: Recent searches; no genre grid)
- [should] sources: Jellyfin playback progress reporting, partial  (Sessions/Playing | Built: Reports start, progress, stop; fixtures only)
- [should] sync: Continue Watching remove and hidden-shows restore, partial  (Built: Remove with 30 day hide; no restore screen)
- [could] detail: Ratings strip and reviews, no
- [could] detail: Thumbs up down and personal ratings, no
- [could] home: Shelves from public TMDB Trakt MDBList Letterboxd lists, no  (Trakt lists first)
- [could] ios: Liquid Glass chrome, no  (Blocked until the build Mac has Xcode 26; use system materials meanwhile | Built: Blocked on Xcode 26)
- [could] ios: OLED true black mode, no  (Dark-first anyway)
- [could] library: Custom lists editable (Trakt lists), no
- [could] library: Downloads for offline (iPhone), no
- [could] library: Release notifications, no  (Local only; no push entitlement)
- [could] pairing: Play on Apple TV from iPhone, no
- [could] pairing: iPhone remote control of Apple TV playback, no  (Prism Companion Remote)
- [could] player: DV Profile 7 to 8.1 metadata rewrite, no  (Prism does this frame by frame; not in Lanterna plan; add a P7 file to P0 corpus | Built: Not planned for v1)
- [could] player: External player handoff (Infuse VLC), no
- [could] player: Playback speed 0.5x to 2x, no
- [could] player: Recap skip, no
- [could] player: Stats for nerds overlay, no  (Useful during P0 | Built: Diagnostics and the P0 lab exist)
- [could] settings: Settings search, no
- [could] sources: Jellyfin trickplay thumbnails for scrub, no
- [could] streams: Copy stream URL, no  (Must redact in logs)
- [could] player: AirPlay from iPhone, partial  (Built: AVPlayerViewController default; untested)

## Left out on purpose (not scored)
- Shazam soundtrack recognition: Not needed
- AI on-device subtitles: Not needed
- Showcases and folders with artwork: Not needed for one owner
- Automatic personalized Home: no reason given, add one
- Parents Guide and Ask Prism AI: no reason given, add one
- AI natural-language search and AI shelves: no reason given, add one
- iCloud library sync: Free Personal Team cannot use iCloud
- SIMKL and MDBList sync: no reason given, add one
- Share and backup settings export: no reason given, add one
- Content restrictions and biometric lock: no reason given, add one
- Profiles and PINs: One owner
- Plex Emby Silo servers: Not in source list
- WebDAV network shares: no reason given, add one
- Live TV M3U and Xtream: no reason given, add one
- Seerr content requests: no reason given, add one
- Top Shelf extension: No extensions in v1
- Siri Shortcuts and Spotlight: no reason given, add one
- Mac app: Out of scope per steering
- iPad app: Out of scope per steering
- Subscription paywall and trial: Personal use

## Yours, not in the original (not scored)
- TorBox library (torrents usenet web downloads)
- MediaSource protocol behind every source
- PlaybackRouter with two engines (A remux to HLS; C FFmpeg fallback)
- Engine C: Now Playing display criteria PiP and native-like transport by hand
- PGS selection reroutes A to C at current position
- Cross-device resume within 10 s
- QR pairing iPhone to Apple TV for credentials
