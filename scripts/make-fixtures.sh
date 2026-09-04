#!/usr/bin/env bash
# Generate the media fixtures that scripts/smoke.sh feeds through the trimmed
# FFmpeg. The fixtures are produced by a *full* FFmpeg (host or docker) because
# the trimmed build intentionally has no test sources, no ogg muxer, etc.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${FIXTURES_DIR:-$project_dir/.build/fixtures}"
full="${FULL_FFMPEG:-ffmpeg}"

if ! command -v "$full" >/dev/null 2>&1; then
	echo "need a full ffmpeg to generate fixtures; set FULL_FFMPEG=/path/to/ffmpeg" >&2
	exit 2
fi

mkdir -p "$out"
cd "$out"

if [[ -f .ready ]]; then
	echo "fixtures ready under $out"
	exit 0
fi

ff() { "$full" -hide_banner -loglevel error -nostdin -y "$@"; }

# UVC cameras usually emit 4:2:2 JPEG; keep that so the yuv420p conversion is
# really exercised by the libx264 paths.
ff -f lavfi -i testsrc2=size=640x480:rate=15 -t 2 \
	-c:v mjpeg -pix_fmt yuvj422p -q:v 5 -f mjpeg video.mjpeg

ff -f lavfi -i testsrc2=size=640x480:rate=15 -t 2 \
	-c:v libx264 -preset veryfast -profile:v baseline -pix_fmt yuv420p -g 15 -f h264 video.h264

ff -f lavfi -i testsrc2=size=640x480:rate=15 -t 2 \
	-c:v libx265 -preset veryfast -pix_fmt yuv420p -g 15 -x265-params log-level=none -f hevc video.hevc

# Fragmented MP4 like the pure-Go recorder writes (init + moof/mdat runs).
ff -f lavfi -i testsrc2=size=640x480:rate=15 -t 4 \
	-c:v libx264 -preset veryfast -pix_fmt yuv420p -g 15 \
	-movflags +frag_keyframe+empty_moov+default_base_moof -f mp4 h264.mp4

ff -f lavfi -i testsrc2=size=640x480:rate=15 -t 4 \
	-c:v libx265 -preset veryfast -pix_fmt yuv420p -g 15 -tag:v hvc1 -x265-params log-level=none \
	-movflags +frag_keyframe+empty_moov+default_base_moof -f mp4 hevc.mp4

# 10-bit HEVC: some cameras emit Main10; keep it as a regression guard.
ff -f lavfi -i testsrc2=size=640x480:rate=15 -t 2 \
	-c:v libx265 -preset veryfast -pix_fmt yuv420p10le -g 15 -tag:v hvc1 -x265-params log-level=none \
	-movflags +frag_keyframe+empty_moov+default_base_moof -f mp4 hevc10.mp4

ff -f lavfi -i sine=frequency=440:sample_rate=8000 -t 2 -ac 1 -c:a pcm_s16le -f s16le audio8k.s16le
ff -f lavfi -i sine=frequency=440:sample_rate=8000 -t 2 -ac 1 -c:a pcm_alaw -f alaw audio8k.alaw
ff -f lavfi -i sine=frequency=440:sample_rate=8000 -t 2 -ac 1 -c:a pcm_mulaw -f mulaw audio8k.mulaw
ff -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -ac 2 -c:a pcm_s16le -f s16le audio48k.s16le
ff -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -ac 2 -c:a aac -b:a 96k -f adts audio48k.aac
ff -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -ac 1 -c:a libopus -b:a 32k -f ogg audio48k.ogg

touch .ready
ls -la "$out"
echo "fixtures ready under $out"
