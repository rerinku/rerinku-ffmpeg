#!/usr/bin/env bash
set -euo pipefail

binary="${1:-dist/linux-amd64/ffmpeg}"

if [[ ! -x "$binary" ]]; then
	echo "not executable: $binary" >&2
	exit 2
fi

echo "binary: $binary"
ls -lh "$binary"
file "$binary" | cut -c1-160
if command -v ldd >/dev/null 2>&1; then
	ldd "$binary" 2>&1 | head -5 || true
fi
if command -v size >/dev/null 2>&1; then
	size "$binary"
fi
if command -v xz >/dev/null 2>&1; then
	printf 'xz -9 compressed: %s bytes\n' "$(xz -9 -c "$binary" | wc -c)"
fi

# A cross-built binary cannot be run here; the size numbers above still apply,
# but the component listing below needs the target platform.
if ! "$binary" -hide_banner -version >/dev/null 2>&1; then
	echo
	echo "component listing skipped: $binary cannot run on this host"
	exit 0
fi

echo
"$binary" -hide_banner -version | sed -n '1,3p'
echo
echo "encoders:"
"$binary" -hide_banner -encoders 2>/dev/null | grep -E 'libx264|libx265|libopus| aac | mjpeg |libwebp|pcm_alaw|pcm_mulaw' || true
echo
echo "decoders:"
"$binary" -hide_banner -decoders 2>/dev/null | grep -E ' h264 | hevc | mjpeg | aac | opus |libopus|pcm_' || true
echo
echo "formats:"
"$binary" -hide_banner -formats 2>/dev/null | grep -E ' h264 | hevc | mjpeg | aac | ogg | s16le | alaw | mulaw | mov,| mp4 | image2pipe | webp | rtp ' || true
echo
echo "filters:"
"$binary" -hide_banner -filters 2>/dev/null | grep -E ' (scale|fps|pad|tile|tpad|format|aresample|aformat) ' | awk '{print $2}' | tr '\n' ' '
echo
echo "devices:"
"$binary" -hide_banner -devices 2>/dev/null | grep -E 'alsa' || echo "(none)"
