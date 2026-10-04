# P0: Player spike

Goal: decide, with numbers, how much of real-world TorBox content Engine A (remux to HLS into AVPlayerViewController) can carry, and confirm Engine C as the fallback. Nothing is built on top of the player until this is done.

Run everything on the physical Apple TV. The simulator is not valid evidence for this phase.

## Test corpus (10 streams, pulled from AIOStreams)

| # | Profile | Why it is in the set |
|---|---|---|
| 1 | 4K HEVC Dolby Vision P8.1 MKV, TrueHD Atmos | Hardest common case: DV mode switch plus audio transcode |
| 2 | 4K HEVC Dolby Vision P5 WEB-DL MKV, EAC3 Atmos | Streaming-service rip; audio should copy with Atmos intact |
| 3 | 4K HEVC HDR10 MKV, DTS-HD MA | HDR switch plus DTS transcode |
| 4 | 1080p H.264 MKV, AC3, ASS subtitles | Styled subtitle conversion |
| 5 | 1080p HEVC MKV, EAC3, PGS subtitles | Must reroute to Engine C when PGS is selected |
| 6 | 1080p H.264 MP4, AAC | Control case; should play with zero remux work |
| 7 | 1080p H.264 Hi10P MKV (anime) | Expected to fail A and route to C |
| 8 | 1080p AV1 MKV | Expected to route to C unless the hardware decodes AV1 |
| 9 | 720p H.264 MKV, multiple audio tracks | Track switching inside the native info panel |
| 10 | 4K HEVC MKV with chapters, 2h+ runtime | Chapter list and long-seek behavior |

## Measurements per stream, per engine

- Time to first frame (TTFF)
- Seek latency for 10 random seeks: median and p90
- A/V sync drift after 10 minutes
- HDR and Dolby Vision mode switch on the TV: yes or no
- Atmos indicator on the receiver or TV: yes or no
- Subtitles render correctly: yes, degraded, or no
- Native features present (A only): transport bar, info panel tracks, chapters, Siri rewind, scrub thumbnails, PiP
- Peak memory and any thermal or dropped-frame warnings

## Gates

- Engine A is primary if it plays at least 7 of 10 with TTFF under 4s, seek median under 2s, and seek p90 under 4s.
- Engine C must play 10 of 10.
- If A misses the gate, record why. If seeking is the failure, try segment pre-generation around the playhead before giving up. If it still misses, C becomes primary and the native-feel requirement downgrades to "as close as possible."

## Implementation notes for Engine A (verify each in the spike)

- Demux: libavformat with a custom AVIOContext backed by URLSession range requests. Confirm TorBox download links honor Range headers (inference: they should).
- Playlist: build a VOD HLS playlist from Matroska Cues so total duration and segment boundaries are known before playback starts. Files without Cues fall back to C.
- Segments: fMP4 cut on video keyframes, produced on request, cached a few segments ahead of the playhead.
- Dolby Vision: the dvcC/dvvC configuration record must survive into fMP4 or the TV will not switch to DV. Highest-risk item in A.
- Audio: copy AAC/AC3/EAC3. Transcode DTS, DTS-HD, and TrueHD to EAC3 5.1 (TrueHD Atmos loses its Atmos objects; accepted).
- Subtitles: SRT and ASS to segmented WebVTT renditions in the master playlist.
- Server: localhost only, bound to 127.0.0.1, random port, per-session token in the path.

## Candidate libraries (from training data; versions and licenses not yet verified)

- KSPlayer: ships an FFmpeg-based engine (MEPlayer) with tvOS support. Candidate for Engine C and the shared FFmpeg build. Expected to be GPL, which is fine for personal use.
- VLCKit (TVVLCKit): LGPL alternative for Engine C if KSPlayer fails on tvOS 26.
- FFmpegKit: archived upstream; do not adopt it.

Record the results in `docs/p0-results.md`, one row per stream per engine, plus the routing decision.
