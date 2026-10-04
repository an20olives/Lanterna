# P0 results

Filled in by the owner from the harness JSON (`curl http://<tv-ip>:8765/p0/results.json`). See `docs/p0-player-spike.md` for the corpus and gates. One row per stream per engine. Simulator runs do not count.

| # | Stream | Engine | Routing reasons | TTFF (ms) | Seek median (ms) | Seek p90 (ms) | A/V drift (10 min) | DV/HDR switch | Atmos | Subtitles | Native features (A) | Peak mem (MB) | Dropped frames / stalls | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 4K HEVC DV P8.1 MKV, TrueHD Atmos | A | | | | | | | | | | | | |
| 1 | | C | | | | | | | | | n/a | | | |
| 2 | 4K HEVC DV P5 WEB-DL MKV, EAC3 Atmos | A | | | | | | | | | | | | |
| 2 | | C | | | | | | | | | n/a | | | |
| 3 | 4K HEVC HDR10 MKV, DTS-HD MA | A | | | | | | | | | | | | |
| 3 | | C | | | | | | | | | n/a | | | |
| 4 | 1080p H.264 MKV, AC3, ASS | A | | | | | | | | | | | | |
| 4 | | C | | | | | | | | | n/a | | | |
| 5 | 1080p HEVC MKV, EAC3, PGS | A | | | | | | | | | | | | |
| 5 | | C | | | | | | | | | n/a | | | |
| 6 | 1080p H.264 MP4, AAC | A | | | | | | | | | | | | |
| 6 | | C | | | | | | | | | n/a | | | |
| 7 | 1080p H.264 Hi10P MKV | A | | | | | | | | | | | | |
| 7 | | C | | | | | | | | | n/a | | | |
| 8 | 1080p AV1 MKV | A | | | | | | | | | | | | |
| 8 | | C | | | | | | | | | n/a | | | |
| 9 | 720p H.264 MKV, multiple audio | A | | | | | | | | | | | | |
| 9 | | C | | | | | | | | | n/a | | | |
| 10 | 4K HEVC MKV, chapters, 2h+ | A | | | | | | | | | | | | |
| 10 | | C | | | | | | | | | n/a | | | |

## Routing decision

(Which engine is primary, and why. Fill in after the table.)

## Gate

- Engine A: plays at least 7 of 10 with TTFF under 4 s, seek median under 2 s, seek p90 under 4 s: (pass / fail, count)
- Engine C: plays 10 of 10: (pass / fail, count)
- If A missed: why, and whether segment pre-generation was tried:
- Decision recorded on (date):

## Simulator findings (not gate evidence)

Run on 2026-10-04 in the tvOS 18.5 simulator on the build Mac, using synthetic files served over localhost and the owner's 30 GB Toy Story 4K remux (HEVC Main10 HDR10, DTS 5.1, 34 chapters, no subtitle tracks). The simulator has no HDR display, no hardware decode and no passthrough, so none of this counts toward the gate. It is here so the first on-TV run knows where to look.

| Case | Result in the simulator |
|---|---|
| H.264 + AAC MP4, Auto | A-direct, plays, TTFF about 0.6 to 0.8 s |
| HEVC 8-bit + AC3 MKV | A (audio copied), plays, TTFF about 0.5 s, 10 seeks median 183 ms, p90 222 ms |
| H.264 + FLAC MKV | A, FLAC to ALAC, plays |
| HEVC 10-bit SDR MKV | A, plays |
| HEVC 10-bit HDR10 MKV (synthetic and Toy Story) | A fails to open (AVFoundation -11868 / CoreMedia -17223), reroutes to C as designed. Forcing `VIDEO-RANGE=SDR` changes the error to -12927, so it is not just the range label. Likely a simulator limit; confirm on the TV |
| Toy Story, 4K HEVC Main10 HDR10, DTS 5.1 | Routed to A (DTS to ALAC), A failed to open as above, Engine C played it. **Peak memory about 6 GB** in the simulator, which would be fatal on an Apple TV. Check on the TV first |
| Hi10P H.264 MKV | Routed to C. The simulator aborted inside C's Metal renderer (`MetalRender.textures`, simulator buffer limits). Confirm on the TV |
| Engine C, 8-bit MKV | Plays. TTFF about 580 to 650 ms. Seek median about 1.2 s, p90 about 2 s on a 4 minute file |

Known gaps seen in the logs:

- Engine A's video init segment carries `colr` and `hvcC` but not `mdcv` or `clli` (HDR10 mastering metadata). The TV should still switch to HDR10 from `colr`, but static metadata is not passed on. Check the TV's HDR info panel.
- The master playlist for the Toy Story file: `CODECS="hvc1.2.4.H153.B0,alac"`, `VIDEO-RANGE=PQ`, 3840x2160, 23.976 fps, ALAC audio group.
