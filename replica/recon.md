# Recon map: Prism (iPhone and Apple TV)

Scope: the whole media-hub loop on iPhone and Apple TV: discover, pick a stream, play, track progress, resume on the other device. Mac and iPad are out of scope.
For: one owner, sideloaded only (Lanterna). Not a product for sale.
Date: 2026-10-04
Method: public sources only, read by hand in a browser. No account, no binary, no network capture, no source code. Prism's ToS (section 7) forbids reverse engineering and decompiling; nothing here relies on either.

## Sources

| # | source | URL | notes |
| --- | --- | --- | --- |
| 1 | marketing site | https://prismhub.app/ | Pitch, three ways to watch, player feature list, platform screenshots, pricing |
| 2 | docs index | https://prismhub.app/docs | 15 pages, mostly config formats |
| 3 | docs: overview | https://prismhub.app/docs/overview | Supported sources; "does not accept arbitrary streaming, catalog, or subtitle endpoints" |
| 4 | docs: source setup | https://prismhub.app/docs/addon-basics | URL slug and "retired sources" text show addon support existed and was removed |
| 5 | docs: playback sources | https://prismhub.app/docs/streaming | Shared stream picker, Your Services, no-streams path, Live TV (M3U, Xtream) |
| 6 | docs: lists and showcases | https://prismhub.app/docs/catalogs | Shelf, list, Showcase model |
| 7 | docs: subtitles | https://prismhub.app/docs/subtitles | Embedded, source files, OpenSubtitles, AI subtitles |
| 8 | docs: media servers | https://prismhub.app/docs/media-servers | Jellyfin integration contract, what is stored, TMDB-first matching |
| 9 | docs: Apple TV picture and sound | https://prismhub.app/docs/apple-tv-setup | Display criteria, DV profiles, audio path. Directly relevant to P0 |
| 10 | changelog | https://prismhub.app/changelog | 25 releases, Feb to Aug 2026. Best source for screens and states |
| 11 | release notes: The Player Update | https://prismhub.app/changelog/the-player-update | KSPlayer replaced by AVPlayer-based engine; stream card redesign |
| 12 | FAQ | https://prismhub.app/faq | ~80 answers; tvOS focus behavior, Continue Watching rules, remote pairing, Your Services |
| 13 | roadmap | https://prismhub.app/roadmap | 4 open ideas, nothing in progress |
| 14 | terms of service | https://prismhub.app/tos | No-reverse-engineering clause; no non-compete clause |
| 15 | App Store listing | https://apps.apple.com/gb/app/prism-movie-tv-hub/id6757183420 | **Gone** ("can't be found", 2026-10-04). Site says "temporarily unavailable". No store screenshots or release notes available |
| 16 | public walkthrough videos | none found | Web search found no Prism walkthroughs; Google search hit a CAPTCHA and was abandoned. Gap: tvOS screens below are inferred from text, not seen |

Reference screenshots (marketing mockups only) are in `replica/screens/`. The only public Apple TV image is the movie detail page.

## Core loop

Open the app on the Apple TV, pick something from Home or Continue Watching, choose a stream (or let it auto-pick), and it plays with the TV switched into the right HDR mode and frame rate. Progress syncs so the iPhone knows where you stopped.

## Platform shape (seen and read)

| | iPhone | Apple TV |
| --- | --- | --- |
| Navigation | Bottom tab bar: Home, Library, Settings, plus a separate round Search button (iOS 26 tab bar search role). Seen in screenshot | Top tab bar: Search, Home, Library, Settings (Profiles tab when used). Top nav is the default; sidebar optional (changelog 1.0 b157). Seen in screenshot |
| Editing | Shelves, lists, network shares, stream source order editable here | Cannot edit shelves, manage lists, or download. Can add servers, enter keys, set PINs (FAQ) |
| Input | Touch, context menus on long-press, pinch to fill | Siri Remote; long-press on cards for menus; on-screen keyboard or iPhone keyboard |
| Player chrome | Custom SwiftUI controls (screenshot): close, PiP, AirPlay, volume, ±10 s, music-ID, stats, info, speed, subtitles | Not shown publicly. Changelog references transport/timeline, info panel, Menu button behavior, Now Playing commands |

## Screens

IDs S01 to S29 are iPhone. S30 to S59 are Apple TV. Rows marked **(Lanterna)** have no Prism equivalent and come from the steering prompt or CLAUDE.md.

### iPhone

| ID | screen | route / how to reach | purpose | key components | states seen |
| --- | --- | --- | --- | --- | --- |
| S01 | Launch and welcome tour | first launch | brand moment, short tour | animated logo, tour pages | first run, returning (spinner in own slot) |
| S02 | Home | tab: Home | discovery and resume | hero carousel with progress dots and "Go to Show" + add, Continue Watching row (still, S/E, "24m left", ••• menu, progress bar), shelves that peek from the side | loading (preloaded posters), filled, partial-failure keeps last good copy, empty shelf placeholder |
| S03 | Search | Search button | find titles and people | search field, recent searches (ignores 1-2 char), result rows Movies / Shows / Cast, genre browse grid | empty (browse grid), typing, results, no results, AI error retry |
| S04 | See All / genre grid | See All on any shelf, genre tile | browse a full list | poster grid, sort menu (Release Date, Title, Rating, Year, asc/desc), genre filter, Availability → On Server, Minimum Ratings | loading more on scroll, filtered, empty |
| S05 | Movie detail | tap poster | decide and play | parallax hero, title logo, rating, year, runtime, certification, genres, overview, Play, watchlist +, favorite, thumbs up/down, trailers row (inline), cast row, reviews, ratings strip, watch providers row, ••• menu | loading, filled, unreleased ("hasn't aired yet" card), custom poster chosen |
| S06 | Show detail | tap poster | pick season and episode | as S05 plus Smart Resume Play, season picker, episode cards (still, rating, runtime, progress), Mark up to Here, Mark as Watched | resuming, next unwatched, specials (Season 0), ghost season hidden |
| S07 | Person page | tap cast | filmography | portrait hero, bio, credits grid | loading progressively |
| S08 | Stream picker | Play or Choose Stream | choose a source | grouped sections in user-set order: Media Servers, Network Shares, Providers, Your Services; stream card: title line, badge strip (resolution, HDR/DV, audio, Atmos), size, runtime, release group, cached check, Direct Play label; auto-select overlay "Checking 3 of 12 sources..." | searching, results, unavailable cards (labelled, excluded from auto-select), source in cooldown, Relay warning |
| S09 | No streams found | S08 with zero results | not a dead end | message, "Open in <service>" cards, Request button, existing requests list | no sources configured (setup prompt), nothing found, unreleased |
| S10 | Player | stream picked | watch | close, PiP, AirPlay, volume, ±10 s, play/pause, timeline with scrub thumbnails and buffer bar, speed, audio/subtitle menu, Adjust Subtitles, stats overlay, info sheet, Skip Intro pill, Next Episode countdown card, double-tap edges to skip, pinch to fill | loading (optional progress %), playing, buffering, paused, error with real reason, quiet reconnect, resume within ~15 s without reload |
| S11 | Library | tab: Library | your stuff | Media Library (Movies, Shows counts), Movie Watchlist, TV Watchlist, Favorites, custom lists, History, Coming Soon, Downloads | empty per section, filled, cached-then-fresh |
| S12 | Media Library | Library → Media Library | browse own server files | grid, search, sort Title / Year / Recently Added | syncing, sync error with retry, empty |
| S13 | Coming Soon | Library | next 14 days | day groups, poster collages, back to today | empty, filled |
| S14 | History | Library → History → See All | full watch history | grid, filters (type, genre, year/month watched, rating, favorites), sort by date | empty, filled |
| S15 | Downloads | Library → Downloads | offline playback | download rows with stream details, progress, retry/delete in bulk | queued, downloading, failed, low space warning |
| S16 | Settings root | tab: Settings | everything else | searchable settings list, grouped sections | search results jump to section |
| S17 | Media Servers | Settings → Media Servers | connect Jellyfin/Plex/Emby | server list, add sheet (URL, remote address, sign-in or Quick Connect), libraries picker, diagnostics, collections import | connecting, http warning, unreachable with Retry, syncing, sync failed |
| S18 | Your Services | Settings → Your Services | declare subscriptions | service list with logos, region picker, Show When Playing toggle, Saved for Other Regions | none selected, selected, region changed |
| S19 | Streams settings | Settings → Streams | control picking | source order (drag), filters and requirements (resolution, DV, Atmos, size), sort, auto-select, Prefer Your Library, source limits | default, customized |
| S20 | Library Sync | Settings → Accounts & Sync | pick sync source, sign in | source picker (Trakt, SIMKL, MDBList, iCloud), account card with stats, import flow | signed out, signing in, failed sign-in recovery screen, synced |
| S21 | Home Screen editor | Settings → Home Screen | build shelves | shelf list (reorder, hide), Add Shelf (presets, filters, Build from Your Servers), Showcases, hero toggle; hard cap 20 shelves | default, customized |
| S22 | Lists & Catalogs | Settings → Lists & Catalogs | add public lists | paste URL (TMDB, Trakt, MDBList, Letterboxd), server collections | valid, invalid URL, list preview |
| S23 | Player and subtitle settings | Settings → Video Player / Subtitles | defaults | audio track default, subtitle languages, font, styling, forced subs, dim in HDR, online subtitle sources | default, customized |
| S24 | Apple TV Remote | Settings → Apple TV Remote; Now Playing bar | pair with and control Apple TV | code entry, device list, remote (play/pause, scrub with previews, tracks, mute app, Up Next) | not found (Local Network help), connecting, connected, playing |
| S25 | Profiles | person icon | multi-user | up to 5 profiles, PIN | (skip for Lanterna) |
| S26 | AIOStreams source **(Lanterna)** | Settings → Sources | add AIOStreams manifest URL | URL field or paste, manifest preview (name, catalogs, resources), enable toggle | invalid URL, unreachable, valid |
| S27 | TorBox library **(Lanterna)** | Library → TorBox | browse own torrents, usenet, web downloads | grouped list, status (cached, downloading), play, TMDB match | empty, loading, error, key missing |
| S28 | Send to Apple TV (QR pairing) **(Lanterna)** | Settings → Pair Apple TV | push credentials to tvOS | camera scanner, consent list of what is sent, result | camera denied, scanning, sending, sent, failed |
| S29 | Engine and routing log **(Lanterna)** | Settings → Diagnostics | see why a stream used A or C | list of probe results and decisions | empty, filled |

### Apple TV

| ID | screen | route / how to reach | purpose | key components | states seen |
| --- | --- | --- | --- | --- | --- |
| S30 | Home | tab: Home | discovery and resume | optional hero carousel (or Continue Watching as hero), Continue Watching row, shelves; every non-empty shelf ends with a See All card | loading, filled, empty shelf placeholder, missing-source notice (focusable) |
| S31 | Search | tab: Search | find titles | on-screen keyboard, recent searches (capped so browse grid peeks), result rows | empty, typing, results |
| S32 | Movie detail | select poster | decide and play | full-bleed backdrop, network badge, title logo, rating, year, runtime, cert, genres, overview, Play, + (watchlist), heart (favorite), thumbs, Trailers row, cast, reviews, Parents Guide cards | filled (seen in screenshot), unreleased |
| S33 | Show detail | select poster | resume or pick episode | Smart Resume Play keeps focus; Down lands on the episode being watched; season picker one press up; episode shelf | resuming, next up |
| S34 | Person page | select cast | filmography | portrait, predictable focus path, progressive loading | loading |
| S35 | See All grid | See All card | browse full shelf | grid, Filter & Sort sheet (Availability → On Server, Done) | loading more, filtered |
| S36 | Stream picker | Play or Choose Stream | choose a source | same groups and cards as S08; Up Next variant shows series, S/E, episode title, air date | searching, results, unavailable, cancel restores focus |
| S37 | No streams found | S36 empty | fall back | Open in service cards, request | as S09 |
| S38 | Player | stream picked | watch | transport bar, info panel (poster/still, description, rating, badges 4K/DV/Atmos/CC), audio and subtitle menus, chapters, Siri rewind, clickpad scrub with thumbnails, Skip Intro pill, Up Next countdown card, stats | mode-switch black frame (expected), buffering, error, resume position; Menu must stay in player |
| S39 | Library | tab: Library | your stuff | Media Library, watchlists, favorites, history, Coming Soon (no Downloads on tvOS) | as S11 |
| S40 | Settings | tab: Settings | config | servers, Your Services, streams (tag pack choice only), library sync sign-in, subtitles, Companion Remote | |
| S41 | Trakt sign-in (device code) | Settings → Library Sync | sign in without typing | code, URL, QR, waiting state | waiting, success, expired, failed with Try Again |
| S42 | Pairing receiver (QR) **(Lanterna, replaces Prism Web Setup and Companion Remote pairing)** | Settings → Pair iPhone; first-run setup | receive credentials | QR code containing host, port, one-time key; status | waiting, receiving, success, rejected, timed out |
| S43 | Continue Watching card menu | long-press card on Home | manage progress | sync progress from source, reset and remove | |
| S44 | Profiles tab | top tab | multi-user | (skip for Lanterna) | |
| S45 | First-run setup **(Lanterna)** | first launch with no sources | get to playable fast | "Pair with iPhone" (S42) and "Sign in to Trakt" (S41) | |

### tvOS focus behavior (from changelog and FAQ; not seen on video)

- Focused posters scale up and need clearance; Prism fixed clipping across Home, Search, Library, See All (1.0.2).
- Provider logos must not zoom independently of their card when focused (1.0.2).
- Returning from a detail page restores the previously focused row even if Home refreshed in the background (1.0.5).
- Menu deep in a Home shelf returns to the top of Home, not out of the app (1.0.5). Menu from the tab bar returns to the first Home card (1.0.2).
- Show detail: Down from artwork lands on the current episode; season picker is one press up (b94/95, b157).
- Cancelling a stream search returns focus to where it was (b93).
- Hold-to-seek should not be interrupted by focus changes (1.0.4). Timeline seek commits with one Select press (1.0.1).
- Opening audio or subtitle menus must not leave controls unresponsive or swallow Menu (1.0.5). Back after changing a track stays in the player (b91).
- Card focus is lighter while scrolling for performance; keep Home to about 10 shelves on Apple TV (FAQ).
- Now Playing fast-forward and rewind commands from third-party remotes must be handled (1.0.5).

## Flows

Click counts are remote presses or taps on the happy path. They are the numbers to beat.

```
F01 Resume on Apple TV from Continue Watching (the core loop)
    S30 Home -> select Continue Watching card -> S38 Player (Quick Play, stream auto-selected)
    happy path clicks: 1 (focus lands on first card) to 2
    edge: next episode not aired (air-date chip, no stream search), saved stream gone, progress arrives after player opens (must not start at 0:00), title logo and Skip Intro must still load on Quick Play

F02 Browse to play a new movie on Apple TV
    S30 Home -> move to shelf -> select poster -> S32 detail -> Play -> S36 picker (or auto-select) -> S38
    happy path clicks: 4 with auto-select, 5 with manual pick
    edge: no streams (S37 with Open in service), all sources rate limited (cooldown), only C-routable streams, DV title on non-DV chain (tone-map, no failure)

F03 Start an episode of a show on Apple TV
    S33 show detail -> Play (Smart Resume) -> S36 -> S38
    happy path clicks: 2 to 3
    edge: absolute numbering vs TMDB seasons, Season 0 specials, TMDB and TVDB numbering differ

F04 Binge: next episode
    S38 near end -> Up Next countdown card (15 to 90 s before end, configurable) -> next episode auto-plays with stream pre-resolved
    happy path clicks: 0 (auto) or 1
    edge: next episode not downloaded/available, intro skip lands on dialogue start

F05 Skip intro
    S38 -> Skip Intro pill appears during intro -> Select
    happy path clicks: 1
    edge: no marker data, inaccurate crowdsourced marker, auto-skip off by default

F06 Change audio or subtitle track
    S38 -> swipe down / info panel -> Audio or Subtitles -> pick
    happy path clicks: 3
    edge: PGS selected (Lanterna: reroute to Engine C at current position), forced subtitles, wrong-dub default avoided (Default keeps file's own audio), commentary tracks excluded from auto-pick

F07 Open a title in a subscribed service
    S32 detail -> Play -> S36 shows "Open in <service>" card -> select -> service app opens (exact episode, title page, or show page depending on service)
    happy path clicks: 3
    edge: service app not installed, provider data stale or region-wrong, service supports only show-level links

F08 Declare subscribed services (iPhone)
    S16 Settings -> S18 Your Services -> tick services -> pick region
    happy path clicks: 3 + one per service
    edge: region change keeps selections under "Saved for Other Regions"

F09 Add an AIOStreams source (Lanterna, iPhone)
    S16 -> S26 -> paste manifest URL -> preview -> Save -> sent to Apple TV via F11
    happy path clicks: 4
    edge: URL invalid, manifest unreachable, URL contains secrets (Keychain only, never logged)

F10 Pair Apple TV and send credentials (Lanterna, replaces Prism Web Setup)
    tvOS S45 or S42 shows QR -> iPhone S28 scan -> confirm what is sent -> tvOS confirms
    happy path clicks: tvOS 1, iPhone 3
    edge: different VLAN (no Bonjour), camera denied, Local Network permission denied, QR expired, app not foreground on tvOS

F11 Sign in to Trakt on Apple TV
    S40 -> S41 shows code and QR -> approve on phone -> success
    happy path clicks: tvOS 2 plus phone approval
    edge: code expired, network failure (distinct recovery screen), account already linked to another app (free tier one-app limit)

F12 Start on iPhone, resume on Apple TV
    iPhone S10 play -> pause/close (progress scrobbled) -> Apple TV S30 Continue Watching shows it -> F01
    happy path clicks: 1 on TV
    gate (P5): resume within 10 s of stop point
    edge: progress not yet synced at cold launch (show cached first), conflicting progress

F13 Add to watchlist
    S05/S32 -> + (morph and haptic on iPhone)
    happy path clicks: 1
    edge: Trakt free-tier 250-item watchlist cap

F14 Play from TorBox library (Lanterna, iPhone and tvOS)
    S27 -> pick item -> files -> S08/S36 -> player
    happy path clicks: 3
    edge: item still downloading, multi-file torrent (season pack), unmatched to TMDB

F15 Connect Jellyfin and play
    S17 -> add server (https via Caddy over Tailscale) -> sign in -> pick libraries -> sync -> titles show server badge -> play
    happy path clicks: 6
    edge: http blocked off-LAN (ATS), Tailscale hostname needs https, items without TMDB ProviderIds stay unmatched, server unreachable keeps last index

F16 Build a Home shelf (iPhone)
    S21 -> Add Shelf -> preset or filters or public list URL -> save -> appears on both devices
    happy path clicks: 4
    edge: 20-shelf cap, list removed (shelf removed with it)
```

## Components

| component | variants | states | used on |
| --- | --- | --- | --- |
| Poster card | portrait, landscape (title logo), ranked number, collage (artless) | default, focused (tvOS scale, shadow, parallax), pressed, loading, missing art, server badge, watched | S02-S07, S30-S35 |
| Continue Watching card | movie, episode | progress bar, time left, air-date chip (amber), Today badge, menu | S02, S30 |
| Hero carousel | movie, show, Continue Watching hero | auto-advance with progress indicator, paused (Reduce Motion), disabled | S02, S30 |
| Shelf (row) | poster, landscape, cinematic, ranked; See All tail card (tvOS) | loading, filled, partial failure, empty placeholder | S02, S30 |
| Title header | movie, show | logo or text fallback, metadata line, ratings strip, award badge | S05, S06, S32, S33 |
| Action button row | Play, Resume, watchlist +, favorite heart, thumbs, ••• | default, focused, toggled (morph), disabled | detail pages |
| Season picker | menu (iOS), focus row (tvOS) | selected, specials, ghost hidden | S06, S33 |
| Episode card | still, number, title, rating, runtime, progress | watched, in progress, unaired | S06, S33 |
| Stream card | media server, share, provider (AIOStreams), TorBox, Your Services | badge strip, cached check, Direct Play, unavailable, selected | S08, S36 |
| Badge | resolution, HDR10, DV, HDR10+, HLG, Atmos, codec, CC, release group | | stream card, info panel |
| Auto-select overlay | | "Checking n of m sources", cancel | S08, S36 |
| Player chrome | Engine A: native AVPlayerViewController. Engine C: custom transport copying tvOS | loading, playing, buffering, paused, error, scrubbing with thumbnail | S10, S38 |
| Skip Intro pill / Next Episode card | | countdown ring draining | S10, S38 |
| Track menu | audio, subtitles | grouped by language, preferred first, source labelled | S10, S38 |
| Settings row | toggle, picker, navigation, destructive | default, disabled, hidden when dependency off | S16-S23, S40 |
| Device code panel | Trakt | waiting, expired, success | S41 |
| QR panel | pairing | waiting, receiving, success, expired | S42 |
| Context menu | poster, person, Continue Watching card | | all |
| Empty state | per screen | illustration plus one action | all lists |
| Error screen | network, account, source | plain reason plus Try Again | S20, S41, S37 |
| Tab bar | iOS bottom with search role, tvOS top | | root |

## Inferred data model

```
Title          tmdb_id, type (movie | show), title, original_title, year, runtime, certification,
               genres, overview, poster_path, backdrop_path, logo_path, imdb_id, tvdb_id
               evidence: S05, S32 screenshot, FAQ "What is TMDB" (TMDB-first everywhere)
               confidence: high

Season / Episode  show_tmdb_id, season_number, episode_number, name, air_date (exact timestamp),
               still_path, runtime, rating
               evidence: S06, changelog "exact timestamps instead of day-only dates", Season 0 fix
               confidence: high

MediaSourceConfig  id, kind (jellyfin | aiostreams | torbox | ...), name, base_url, remote_url,
               enabled, selected_libraries, server_id, user_id; secret in Keychain only
               evidence: docs/media-servers "What Prism stores"
               confidence: high (Prism lists these fields)

ServerItemIndex  source_id, item_id, tmdb_id, imdb_id, type, title, year, genres, date_added
               evidence: FAQ "fewer options" (index keeps title, year, genres, date added)
               confidence: high

StreamCandidate  source_id, title_ref (tmdb + s/e), url (ephemeral), name, size, resolution,
               dynamic_range, video_codec, audio_codecs, atmos, release_group, cached (bool),
               direct_play label, available (bool), unavailable_reason
               evidence: stream card description, "green check when cached", unavailable cards
               confidence: high

StreamProbe (Lanterna)  container, video codec/profile/level, bit depth, DV profile + compat id,
               audio tracks (codec, channels, JOC), subtitle tracks (format, forced, lang),
               has_cues, duration, chosen_engine, reason
               evidence: CLAUDE.md player architecture; Prism FAQ says its player probes before play
               confidence: design, not inferred

PlaybackProgress  title_ref, position_s, duration_s, updated_at, source_of_truth (local | trakt)
               evidence: "tracked to the second", Continue Watching rules
               confidence: high

LibraryEntry   kind (watchlist | favorite | history_play | rating | hidden), title_ref, at, value
               evidence: Library Sync matrix (FAQ)
               confidence: high. Trakt supports favorites (MDBList and SIMKL do not), so Lanterna keeps them

Shelf          id, title, style, order, query (preset | filters | list_ref | server_query), item_count, hidden
               evidence: Home Screen settings, docs/catalogs, 20-shelf cap
               confidence: medium

ListRef        kind (tmdb | trakt | mdblist | letterboxd | server_collection), url or id, name
               evidence: docs/catalogs
               confidence: high

SubscribedService  provider_id (TMDB watch-provider id), name, region, show_when_playing
               evidence: Your Services settings, "Saved for Other Regions"
               confidence: high

WatchAvailability (lookup archive)  tmdb_id, region, provider_id, type (flatrate | free | ads | rent | buy),
               fetched_at; DeepLinkTemplate per provider: scheme, level (episode | title | show | app-only)
               evidence: FAQ "Can Prism open movies and shows in my streaming apps", "the card tells you which"
               confidence: medium (link-level per service is stated; storage is a guess)

IntroMarker    title_ref, start_s, end_s, kind (intro | recap), source (server | community | user)
               evidence: changelog b77-90, 1.0.2
               confidence: medium

PairedDevice (Lanterna)  id, name, platform, paired_at, public key
               evidence: QR pairing requirement in CLAUDE.md
               confidence: design
```

Relationships: Title 1-n Season 1-n Episode; MediaSourceConfig 1-n ServerItemIndex n-1 Title; Title 1-n StreamCandidate (ephemeral, per search); StreamCandidate 1-1 StreamProbe (cached by URL hash); Title 1-n PlaybackProgress; Shelf n-1 ListRef; SubscribedService 1-n WatchAvailability.

## Findings that bear on P0 (record these before the spike)

1. **Prism replaced KSPlayer with an AVPlayer-based engine** in July 2026 (source 11). Before that, "the old app steered around" DV and Atmos streams. After, it claims DV profiles 5, 8.1, 8.4, and a frame-by-frame Profile 7 to 8.1 metadata rewrite, plus Atmos (EAC3 and TrueHD), DTS, and DTS-HD MA (sources 9, 12). This is the same bet as Engine A, and someone has shipped it. It is evidence that A is feasible, not proof of how they did it.
2. **TrueHD Atmos claim.** Prism says it plays "Dolby Atmos (EAC3 and TrueHD)". Lanterna's plan transcodes TrueHD to EAC3 5.1 and accepts losing Atmos objects. If Prism keeps TrueHD Atmos through AVPlayer, they found a path we have not. Inference only; P0 should note what the receiver shows for stream #1 under both engines.
3. **Profile 7** is common in UHD Blu-ray remuxes on debrid. The P0 corpus has no P7 file. Consider adding one (expected result: HDR10 base layer in A unless the RPU is rewritten).
4. **Apple TV audio is never bitstreamed.** It decodes to PCM, or sends Dolby MAT for Atmos. A receiver showing "PCM" for a DTS-HD track is expected and is not an engine bug. Atmos indicator on the receiver is the only meaningful audio pass/fail.
5. **Display criteria.** Prism waits for the mode switch to settle before the first frame (the black frame is expected), and falls back to tone-mapping when Match Content is off. TTFF in P0 should be measured with Match Content on and noted as including the mode switch.
6. **Match Dynamic Range vs Match Frame Rate** are reported to apps as one flag. If only frame-rate matching is on, the app is told matching is available but the panel stays SDR. P0 setup must turn both on.
7. Prism's iPhone player uses custom SwiftUI chrome, not the system player UI. Lanterna deliberately differs on tvOS (AVPlayerViewController for Engine A) to keep native transport, info panel, and Siri features.

## Feature matrix

See `features.csv`. Must: 48, should: 32, could: 18, skip: 20 (118 rows).

## Out of scope (cannot or should not be cloned)

- Mac and iPad apps (steering prompt).
- Prism's name, icon, clapperboard launch animation, copy, illustrations, AI-generated rating icons, tag packs, and showcase artwork.
- Subscription and paywall (personal use, no payments).
- iCloud library sync, CloudKit, iCloud KVS settings sync: free Personal Team cannot use iCloud entitlements. Trakt is the sync path.
- Prism's own services: Web Setup encrypted transfer backend, intro-marker database, direct-trailer resolver, setup manifests. Replaced by local QR pairing, server or community markers where available, and TMDB/YouTube trailer keys.
- Profiles and Family Sharing (one owner; tvOS profile switching is free if ever needed).
- Plex, Emby, Silo, WebDAV, SIMKL, MDBList library sync, Seerr requests, Live TV (M3U, Xtream): not in Lanterna's source list.
- Top Shelf, Siri/App Intents, Spotlight (no extensions in v1; intents could come later).
- Subscription APIs for streaming services: none exist. Your Services is a manual declaration plus a TMDB watch-provider lookup archive plus per-service deep-link templates.

## Size

Screens 46 (iPhone 29, Apple TV 16, plus overlays), flows 16, entities 13.

Hard parts:
1. Engine A: on-device remux of MKV to fMP4 HLS with DV configuration records intact, on-demand segments from Cues, localhost server, DTS/TrueHD audio transcode, WebVTT subtitle renditions, and every native tvOS player feature still working.
2. Engine C with a hand-built transport bar that feels native, plus Now Playing, display criteria, and PiP by hand.
3. tvOS focus fidelity across Home, detail, picker, and player (Prism's changelog is mostly focus bugs).
4. Cross-device resume within 10 s via Trakt only (no iCloud), including cold-launch cached progress.
5. Per-service deep links: every service behaves differently and none has an API.

Size: **L** (a quarter), dominated by the player. If P0 shows Engine A misses its gate, the player work grows and the size moves toward XL for native feel.
