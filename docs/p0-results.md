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
