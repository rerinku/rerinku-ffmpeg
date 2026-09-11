#!/usr/bin/env bash
# Functional smoke test for a trimmed FFmpeg binary.
#
# Every case replays one of the exact command lines that rerinku-cli /
# rerinku-media / rerinku-onboard issue in production, so a green run means the
# trimmed component list is sufficient for the product. Keep this file in sync
# with those call sites:
#
#   rerinku-cli/internal/transcode/h264.go        live MJPEG -> H.264 (WebRTC)
#   rerinku-cli/internal/transcode/opus.go        audio -> Opus / G.711 RTP
#   rerinku-media/transcode/aac.go                audio -> AAC ADTS (HLS)
#   rerinku-media/recording/ffmpeg.go             MJPEG recording -> H.264 fMP4
#   rerinku-onboard/internal/recording/thumbnail.go   fMP4 -> JPEG thumbnail
#   rerinku-onboard/internal/recording/storyboard.go  fMP4 -> WebP storyboard
#   rerinku-onboard/internal/device/framegrab.go      raw H.264 -> JPEG
#   rerinku-media/transcode/rawvideo.go           raw H.264/H.265 -> yuv420p frames
#   rerinku-cli/internal/uvc/audio_linux.go       ALSA capture (optional)
#
# Usage: scripts/smoke.sh [path/to/ffmpeg]
set -uo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ffmpeg="${1:-$project_dir/dist/linux-amd64/ffmpeg}"
fixtures="${FIXTURES_DIR:-$project_dir/.build/fixtures}"
work="${SMOKE_WORK_DIR:-$project_dir/.build/smoke}"

timeout_command=""
if command -v timeout >/dev/null 2>&1; then
	timeout_command=timeout
elif command -v gtimeout >/dev/null 2>&1; then
	timeout_command=gtimeout
fi

run_with_timeout() {
	if [[ -n "$timeout_command" ]]; then
		"$timeout_command" 90 "$@"
	else
		"$@"
	fi
}

now_seconds() {
	# Python 3.9 on macOS may use a per-process monotonic clock epoch. Each
	# invocation is a new process, so use wall time for these short diagnostics.
	python3 -c 'import time; print(time.time())'
}

if [[ ! -x "$ffmpeg" ]]; then
	echo "not executable: $ffmpeg" >&2
	exit 2
fi
ffmpeg="$(cd "$(dirname "$ffmpeg")" && pwd)/$(basename "$ffmpeg")"
FIXTURES_DIR="$fixtures" "$project_dir/scripts/make-fixtures.sh" >/dev/null

rm -rf "$work"
mkdir -p "$work"
cd "$work"

pass=0
fail=0
skip=0
failed_names=()

hex_at() {
	# hex_at FILE OFFSET LENGTH -> lowercase hex
	od -An -tx1 -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n'
}

check_magic() {
	local file="$1" offset="$2" want="$3"
	[[ -s "$file" ]] || return 1
	[[ "$(hex_at "$file" "$offset" $(( ${#want} / 2 )))" == "$want" ]]
}

check_contains() {
	local file="$1" needle="$2"
	[[ -s "$file" ]] && grep -q -a -F -- "$needle" "$file"
}

report() {
	local status="$1" name="$2" elapsed="$3" note="${4:-}"
	printf '%-5s %-28s %6ss  %s\n' "$status" "$name" "$elapsed" "$note"
}

# run NAME CHECK-FUNCTION OUTPUT-FILE [-- ffmpeg args...]
run_case() {
	local name="$1" check="$2" output="$3"
	shift 3
	[[ "${1:-}" == "--" ]] && shift
	local log="$work/$name.log"
	local start end elapsed
	start=$(now_seconds)
	run_with_timeout "$ffmpeg" -hide_banner -loglevel error -nostdin "$@" >"$output" 2>"$log"
	local rc=$?
	end=$(now_seconds)
	elapsed=$(printf '%.2f' "$(echo "$end - $start" | bc)")
	if [[ $rc -eq 0 ]] && "$check" "$output"; then
		pass=$((pass + 1))
		report PASS "$name" "$elapsed" "$(du -h "$output" | cut -f1)"
	else
		fail=$((fail + 1))
		failed_names+=("$name")
		report FAIL "$name" "$elapsed" "rc=$rc $(head -c 300 "$log" | tr '\n' ' ')"
	fi
}

# RTP cases send to a loopback UDP listener exactly like the product does;
# the listener dumps every datagram to OUTPUT so the check can inspect it.
# run_rtp_case NAME OUTPUT INPUT PKT_SIZE [-- ffmpeg args before the destination...]
run_rtp_case() {
	local name="$1" output="$2" input="$3" pkt_size="$4"
	shift 4
	[[ "${1:-}" == "--" ]] && shift
	local log="$work/$name.log"
	local portfile="$work/$name.port"
	rm -f "$portfile"
	python3 - "$output" "$portfile" <<'PY' &
import socket, sys, time
out, portfile = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 0))
open(portfile, "w").write(str(s.getsockname()[1]))
s.settimeout(1.0)
deadline = time.time() + 60
with open(out, "wb") as f:
    got = False
    while time.time() < deadline:
        try:
            data, _ = s.recvfrom(65536)
        except socket.timeout:
            if got:
                break
            continue
        got = True
        f.write(data)
PY
	local listener=$!
	for _ in $(seq 1 50); do
		[[ -s "$portfile" ]] && break
		sleep 0.1
	done
	local port
	port="$(cat "$portfile")"
	local start end elapsed
	start=$(now_seconds)
	run_with_timeout "$ffmpeg" -hide_banner -loglevel error -nostdin "$@" \
		-f rtp "rtp://127.0.0.1:$port?pkt_size=$pkt_size" <"$input" >/dev/null 2>"$log"
	local rc=$?
	end=$(now_seconds)
	wait "$listener"
	elapsed=$(printf '%.2f' "$(echo "$end - $start" | bc)")
	if [[ $rc -eq 0 ]] && is_rtp "$output"; then
		pass=$((pass + 1))
		report PASS "$name" "$elapsed" "$(du -h "$output" | cut -f1)"
	else
		fail=$((fail + 1))
		failed_names+=("$name")
		report FAIL "$name" "$elapsed" "rc=$rc $(head -c 300 "$log" | tr '\n' ' ')"
	fi
}

# Same as run_case but with stdin from a fixture (the product always pipes).
run_pipe_case() {
	local name="$1" check="$2" output="$3" input="$4"
	shift 4
	[[ "${1:-}" == "--" ]] && shift
	local log="$work/$name.log"
	local start end elapsed
	start=$(now_seconds)
	run_with_timeout "$ffmpeg" -hide_banner -loglevel error -nostdin "$@" <"$input" >"$output" 2>"$log"
	local rc=$?
	end=$(now_seconds)
	elapsed=$(printf '%.2f' "$(echo "$end - $start" | bc)")
	if [[ $rc -eq 0 ]] && "$check" "$output"; then
		pass=$((pass + 1))
		report PASS "$name" "$elapsed" "$(du -h "$output" | cut -f1)"
	else
		fail=$((fail + 1))
		failed_names+=("$name")
		report FAIL "$name" "$elapsed" "rc=$rc $(head -c 300 "$log" | tr '\n' ' ')"
	fi
}

is_annexb_with_aud() { check_magic "$1" 0 "00000001" && grep -q -a -c $'\x00\x00\x00\x01\x09' "$1"; }
is_annexb() { check_magic "$1" 0 "00000001" || check_magic "$1" 0 "000001"; }
is_fmp4() { check_magic "$1" 4 "66747970" && check_contains "$1" "moof"; }
is_adts() { [[ "$(hex_at "$1" 0 1)" == "ff" ]] && [[ "$(hex_at "$1" 1 1)" =~ ^f[0-9a-f]$ ]]; }
is_jpeg() { check_magic "$1" 0 "ffd8ff"; }
is_webp() { check_magic "$1" 0 "52494646" && check_magic "$1" 8 "57454250"; }
is_rtp() { [[ -s "$1" ]] && [[ "$(hex_at "$1" 0 1)" == "80" ]]; }
is_nonempty() { [[ -s "$1" ]]; }

echo "binary: $ffmpeg"
"$ffmpeg" -hide_banner -version | sed -n '1,2p' | cut -c1-100
echo

# --- rerinku-cli/internal/transcode/h264.go: live MJPEG -> H.264 --------------
run_pipe_case live-mjpeg-h264 is_annexb_with_aud out.h264 "$fixtures/video.mjpeg" -- \
	-fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0 \
	-use_wallclock_as_timestamps 1 -f mjpeg -i pipe:0 -map 0:v:0 -an \
	-c:v libx264 -preset:v superfast -tune:v zerolatency \
	-pix_fmt yuv420p -profile:v baseline -level:v 3.1 \
	-g 30 -keyint_min 30 -sc_threshold 0 -bf 0 -x264-params repeat-headers=1 \
	-bsf:v h264_metadata=aud=insert -flush_packets 1 -f h264 pipe:1

# --- rerinku-media/recording/ffmpeg.go: MJPEG recording -> H.264 fMP4 ---------
run_pipe_case record-mjpeg-fmp4 is_fmp4 out.mp4 "$fixtures/video.mjpeg" -- \
	-fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0 \
	-use_wallclock_as_timestamps 1 -f mjpeg -i pipe:0 -map 0:v:0 -an \
	-c:v libx264 -preset:v superfast -tune:v zerolatency \
	-pix_fmt yuv420p -g 30 -keyint_min 30 -sc_threshold 0 -bf 0 \
	-movflags +frag_keyframe+empty_moov+default_base_moof \
	-flush_packets 1 -f mp4 pipe:1

# --- rerinku-cli/internal/transcode/opus.go: audio -> Opus / G.711 RTP --------
# The product sends RTP to a loopback UDP port; writing the RTP muxer output to
# a file exercises the same muxer + packetizer without a listener.
opus_rtp() {
	local name="$1" input="$2" fmt="$3" rate="$4" ch="$5"
	run_rtp_case "$name" "$name.rtp" "$input" 1200 -- \
		-f "$fmt" -ar "$rate" -ac "$ch" -i pipe:0 -map 0:a:0 -vn \
		-c:a libopus -application lowdelay -frame_duration 20 -b:a 32000 \
		-ar 48000 -ac 1 -flush_packets 1
}
opus_rtp opus-s16le-8k "$fixtures/audio8k.s16le" s16le 8000 1
opus_rtp opus-alaw-8k "$fixtures/audio8k.alaw" alaw 8000 1
opus_rtp opus-mulaw-8k "$fixtures/audio8k.mulaw" mulaw 8000 1
opus_rtp opus-s16le-48k "$fixtures/audio48k.s16le" s16le 48000 2

run_rtp_case g711-alaw-rtp g711.rtp "$fixtures/audio48k.s16le" 172 -- \
	-f s16le -ar 48000 -ac 2 -i pipe:0 -map 0:a:0 -vn -c:a pcm_alaw \
	-ar 8000 -ac 1 -flush_packets 1
run_rtp_case g711-mulaw-rtp g711u.rtp "$fixtures/audio48k.s16le" 172 -- \
	-f s16le -ar 48000 -ac 2 -i pipe:0 -map 0:a:0 -vn -c:a pcm_mulaw \
	-ar 8000 -ac 1 -flush_packets 1

# --- rerinku-media/transcode/aac.go: audio -> AAC ADTS -------------------------
aac_adts() {
	local name="$1" input="$2" fmt="$3" rate="$4" ch="$5"
	if [[ -n "$rate" ]]; then
		run_pipe_case "$name" is_adts "$name.aac" "$input" -- \
			-fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0 \
			-f "$fmt" -ar "$rate" -ac "$ch" -i pipe:0 -map 0:a:0 -vn -c:a aac -profile:a aac_low \
			-ar 48000 -ac 2 -b:a 96000 -flush_packets 1 -f adts pipe:1
	else
		run_pipe_case "$name" is_adts "$name.aac" "$input" -- \
			-fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0 \
			-f "$fmt" -i pipe:0 -map 0:a:0 -vn -c:a aac -profile:a aac_low \
			-ar 48000 -ac 2 -b:a 96000 -flush_packets 1 -f adts pipe:1
	fi
}
aac_adts aac-from-s16le-8k "$fixtures/audio8k.s16le" s16le 8000 1
aac_adts aac-from-alaw "$fixtures/audio8k.alaw" alaw 8000 1
aac_adts aac-from-mulaw "$fixtures/audio8k.mulaw" mulaw 8000 1
aac_adts aac-from-opus-ogg "$fixtures/audio48k.ogg" ogg "" ""
# rerinku-media/transcode/aac.go passes AAC through without FFmpeg, and
# rerinku-cli/internal/transcode/opus.go is the only AAC consumer (RTSP camera
# AAC -> Opus for WebRTC). Note the cli currently adds "-ar/-ac" before
# "-f aac -i", which every FFmpeg rejects with "Option sample_rate not found";
# this case uses the corrected shape so the trimmed component list is proven.
run_rtp_case opus-from-aac opus-from-aac.rtp "$fixtures/audio48k.aac" 1200 -- \
	-f aac -i pipe:0 -map 0:a:0 -vn \
	-c:a libopus -application lowdelay -frame_duration 20 -b:a 32000 \
	-ar 48000 -ac 1 -flush_packets 1

# --- rerinku-onboard/internal/recording/thumbnail.go: fMP4 -> JPEG ------------
thumb() {
	local name="$1" input="$2"
	run_pipe_case "$name" is_jpeg "$name.jpg" "$input" -- \
		-f mp4 -i pipe:0 -ss 1.500 -frames:v 1 -an -sn \
		-vf scale=320:-2 -q:v 5 -f image2pipe -vcodec mjpeg pipe:1
}
thumb thumb-h264-mp4 "$fixtures/h264.mp4"
thumb thumb-hevc-mp4 "$fixtures/hevc.mp4"
thumb thumb-hevc10-mp4 "$fixtures/hevc10.mp4"

# --- rerinku-onboard/internal/recording/storyboard.go: fMP4 -> WebP -----------
storyboard() {
	local name="$1" input="$2"
	local filter="tpad=stop_mode=clone:stop_duration=1,fps=1,scale=160:90:force_original_aspect_ratio=decrease,pad=160:90:(ow-iw)/2:(oh-ih)/2,tile=8x8"
	run_pipe_case "$name" is_webp "$name.webp" "$input" -- \
		-y -threads 1 -f mp4 -i pipe:0 -ss 0.000 -t 61 -an -sn \
		-filter_threads 1 -vf "$filter" -frames:v 1 \
		-threads 1 -c:v libwebp -quality 60 -compression_level 4 -f webp "$name.webp"
}
storyboard storyboard-h264 "$fixtures/h264.mp4"
storyboard storyboard-hevc "$fixtures/hevc.mp4"

# --- rerinku-onboard/internal/device/framegrab.go: raw stream -> JPEG ---------
run_pipe_case grab-h264-raw is_jpeg grab.jpg "$fixtures/video.h264" -- \
	-f h264 -i pipe:0 -frames:v 1 -q:v 5 -f image2pipe -vcodec mjpeg pipe:1
# Same call for H.265 devices once framegrab.go passes "-f hevc".
run_pipe_case grab-hevc-raw is_jpeg grab-hevc.jpg "$fixtures/video.hevc" -- \
	-f hevc -i pipe:0 -frames:v 1 -q:v 5 -f image2pipe -vcodec mjpeg pipe:1

# --- rerinku-media/transcode/rawvideo.go: raw stream -> yuv420p frames --------
# Continuous decode for on-device analytics: fixed-size I420 frames on stdout
# (every picture; the host samples by wall clock).
is_i420_frames() { [[ -s "$1" ]] && (( $(stat -c %s "$1") % (320 * 180 * 3 / 2) == 0 )); }
run_pipe_case analytics-h264-rawvideo is_i420_frames frames.yuv "$fixtures/video.h264" -- \
	-fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0 \
	-f h264 -i pipe:0 -an -sn -vf scale=320:180 \
	-f rawvideo -pix_fmt yuv420p pipe:1
run_pipe_case analytics-hevc-rawvideo is_i420_frames frames-hevc.yuv "$fixtures/video.hevc" -- \
	-fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0 \
	-f hevc -i pipe:0 -an -sn -vf scale=320:180 \
	-f rawvideo -pix_fmt yuv420p pipe:1

# --- planned: live H.265 -> H.264 for browsers (same shape as the MJPEG path) --
run_pipe_case live-hevc-h264 is_annexb_with_aud hevc-to-h264.h264 "$fixtures/video.hevc" -- \
	-fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0 \
	-f hevc -i pipe:0 -map 0:v:0 -an \
	-c:v libx264 -preset:v superfast -tune:v zerolatency \
	-pix_fmt yuv420p -profile:v baseline -level:v 3.1 \
	-g 30 -keyint_min 30 -sc_threshold 0 -bf 0 -x264-params repeat-headers=1 \
	-bsf:v h264_metadata=aud=insert -flush_packets 1 -f h264 pipe:1

# --- rerinku-cli/internal/uvc/audio_linux.go: USB microphone -> raw PCM -------
# The real input is "-f alsa -i hw:X,Y" (needs a device; see alsa-indev below);
# the output half of that command line is exercised with a raw PCM input.
run_pipe_case uvc-mic-pcm-out is_nonempty mic.s16le "$fixtures/audio48k.s16le" -- \
	-thread_queue_size 512 -f s16le -ar 48000 -ac 2 -i pipe:0 -map 0:a:0 -vn \
	-ac 1 -ar 48000 -c:a pcm_s16le -f s16le pipe:1

# --- optional components --------------------------------------------------------
encoders="$("$ffmpeg" -hide_banner -encoders 2>/dev/null)"
if grep -q 'libx265' <<<"$encoders"; then
	run_pipe_case x265-encode is_annexb out.hevc "$fixtures/video.mjpeg" -- \
		-f mjpeg -i pipe:0 -map 0:v:0 -an -c:v libx265 -preset ultrafast \
		-x265-params log-level=none -pix_fmt yuv420p -f hevc pipe:1
else
	skip=$((skip + 1))
	report SKIP x265-encode 0 "libx265 not built in"
fi

if "$ffmpeg" -hide_banner -devices 2>/dev/null | grep -q ' alsa'; then
	# With a USB capture device present, run the real cli command for 1 s.
	mic="$(awk -F'[][]' '/USB-Audio/ {gsub(/ /,"",$1); print "hw:"$1",0"; exit}' /proc/asound/cards 2>/dev/null || true)"
	if [[ -n "$mic" ]]; then
		run_case alsa-indev is_nonempty alsa.s16le -- \
			-thread_queue_size 512 -f alsa -i "$mic" -map 0:a:0 -vn \
			-ac 1 -ar 48000 -c:a pcm_s16le -t 1 -f s16le pipe:1
	else
		pass=$((pass + 1))
		report PASS alsa-indev 0 "alsa input device present (no USB capture device to record from)"
	fi
else
	skip=$((skip + 1))
	report SKIP alsa-indev 0 "no alsa input device (UVC USB microphones fall back to video-only)"
fi

# --- rerinku-onboard/internal/embeddedffmpeg: required encoder probe ----------
missing=()
for enc in libx264 libopus aac libwebp mjpeg; do
	grep -q " $enc " <<<"$encoders" || missing+=("$enc")
done
if ((${#missing[@]} == 0)); then
	pass=$((pass + 1))
	report PASS onboard-probe 0 "libx264 libopus aac libwebp mjpeg"
else
	fail=$((fail + 1))
	failed_names+=(onboard-probe)
	report FAIL onboard-probe 0 "missing: ${missing[*]}"
fi

echo
echo "pass=$pass fail=$fail skip=$skip  (work dir: $work)"
if ((fail > 0)); then
	echo "failed: ${failed_names[*]}"
	exit 1
fi
