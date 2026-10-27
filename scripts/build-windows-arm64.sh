#!/usr/bin/env bash
# Cross-build the trimmed FFmpeg for Windows on ARM (arm64) from Linux x86-64.
#
# The toolchain is llvm-mingw, pinned in packaging/versions.env and fetched
# under .build/toolchains/ on first use (no root needed). Accepts the same
# switches as build-linux-amd64.sh, except WITH_ALSA.
#
# Output: dist/windows-arm64/ffmpeg.exe
set -euo pipefail
exec env RERINKU_BUILD_PLATFORM=windows-arm64 \
	"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-linux-amd64.sh" "$@"
