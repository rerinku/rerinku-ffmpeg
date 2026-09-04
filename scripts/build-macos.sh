#!/usr/bin/env bash
# Build the trimmed FFmpeg natively for the current macOS architecture.
#
# Output:
#   Apple Silicon: dist/darwin-arm64/ffmpeg
#   Intel:         dist/darwin-amd64/ffmpeg
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "build-macos.sh must run on macOS" >&2
	exit 2
fi

case "$(uname -m)" in
	arm64) platform=darwin-arm64 ;;
	x86_64) platform=darwin-amd64 ;;
	*)
		echo "unsupported macOS architecture: $(uname -m)" >&2
		exit 2
		;;
esac

RERINKU_BUILD_PLATFORM="$platform" WITH_ALSA=0 \
	"$project_dir/scripts/build-linux-amd64.sh"
