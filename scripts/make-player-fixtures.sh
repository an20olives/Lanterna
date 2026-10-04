#!/usr/bin/env bash
# Regenerates the synthetic media fixtures for LanternaPlayer's EngineATests.
# Test patterns and sine tones only: no real content. Requires ffmpeg with libx264 and libx265.
set -euo pipefail
OUT="$(cd "$(dirname "$0")/.." && pwd)/Packages/LanternaPlayer/Tests/EngineATests/Fixtures"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$OUT"

cat > "$TMP/subs.srt" <<'SRT'
1
00:00:01,000 --> 00:00:03,000
<i>Hello</i> from Lanterna

2
00:00:07,500 --> 00:00:09,000
Second cue & more
SRT

cat > "$TMP/subs.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 180

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\i1}Styled{\i0} line\Nsecond row
ASS

cat > "$TMP/chapters.txt" <<'CH'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=6000
title=Opening
[CHAPTER]
TIMEBASE=1/1000
START=6000
END=12000
title=Ending
CH

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
VIDEO=(-f lavfi -i "testsrc2=size=320x180:rate=24000/1001:duration=12")
TONE=(-f lavfi -i "sine=frequency=440:sample_rate=48000:duration=12")
X265=(-c:v libx265 -x265-params "keyint=48:min-keyint=48:scenecut=0:log-level=error" -tag:v hvc1)

# HEVC 10-bit, AC3 5.1, SRT, chapters. Keyframe every 48 frames (~2 s). Cues written (seekable output).
ff "${VIDEO[@]}" "${TONE[@]}" -i "$TMP/subs.srt" -i "$TMP/chapters.txt" \
  -map 0:v -map 1:a -map 2 -map_chapters 3 "${X265[@]}" -pix_fmt yuv420p10le \
  -c:a ac3 -ac 6 -b:a 384k -c:s srt -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng \
  hevc10-ac3-srt.mkv

# H.264, DTS 5.1, ASS.
ff "${VIDEO[@]}" "${TONE[@]}" -i "$TMP/subs.ass" -map 0:v -map 1:a -map 2 \
  -c:v libx264 -g 48 -keyint_min 48 -sc_threshold 0 -c:a dca -strict -2 -ac 6 -c:s ass \
  h264-dts-ass.mkv

# HEVC, TrueHD 5.1 plus a second EAC3 5.1 track.
ff "${VIDEO[@]}" "${TONE[@]}" -map 0:v -map 1:a -map 1:a "${X265[@]}" \
  -c:a:0 truehd -strict -2 -ac:a:0 6 -c:a:1 eac3 -ac:a:1 6 \
  hevc-truehd-eac3.mkv

# MP4, H.264 + AAC: the A-direct control case.
ff "${VIDEO[@]}" "${TONE[@]}" -map 0:v -map 1:a -c:v libx264 -g 48 -c:a aac -ac 2 -movflags +faststart \
  h264-aac.mp4

# Matroska written to a pipe: not seekable, so no Cues.
ff "${VIDEO[@]}" "${TONE[@]}" -map 0:v -map 1:a -c:v libx264 -g 48 -c:a ac3 -f matroska pipe:1 > h264-nocues.mkv

ls -la "$OUT"
