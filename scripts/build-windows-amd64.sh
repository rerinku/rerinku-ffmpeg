#!/usr/bin/env bash
# Cross-build the trimmed FFmpeg for Windows x64 from Linux (mingw-w64).
#
# There is no native Windows build path: the toolchain here is
# x86_64-w64-mingw32-*, installed on Debian/Ubuntu with
#   sudo apt install gcc-mingw-w64-x86-64 [g++-mingw-w64-x86-64 for WITH_X265=1]
#
# Accepts the same switches as build-linux-amd64.sh, except WITH_ALSA (ALSA is
# Linux-only; Windows has no local UVC capture at all).
#
# Output: dist/windows-amd64/ffmpeg.exe
set -euo pipefail
exec env RERINKU_BUILD_PLATFORM=windows-amd64 \
	"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-linux-amd64.sh" "$@"
