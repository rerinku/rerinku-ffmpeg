#!/usr/bin/env bash
# Release build of the Linux FFmpeg: build-linux-amd64.sh inside an old-glibc
# container, so the executable runs on every distribution from that glibc on.
#
# The Linux FFmpeg links glibc dynamically — the VA drivers and NVIDIA's
# libraries are the system's, loaded with dlopen — and everything else
# statically (see build-linux-amd64.sh). The glibc it was linked against is its
# floor: built on Debian 11 it needs glibc 2.29, below what onboard itself
# needs, so it runs wherever onboard runs (natively, and in onboard's Debian
# Docker image).
#
#   BASE_IMAGE=debian:bullseye   build image base (decides the glibc floor)
#   JOBS, SMOKE, FORCE_SMOKE      passed through to build-linux-amd64.sh
#
# Objects and dependencies go to a build root of their own
# (.build/container-<image>), so libraries compiled on a newer host never leak
# newer glibc symbols in; downloads and the output are shared:
#   dist/linux-amd64/ffmpeg
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_image="${BASE_IMAGE:-debian:bullseye}"
image_tag="$(tr ':/' '--' <<<"$base_image")"
image="rerinku-ffmpeg-build:$image_tag"

docker build --quiet -t "$image" --build-arg BASE_IMAGE="$base_image" \
	-f "$project_dir/packaging/linux-build.Dockerfile" "$project_dir/packaging" >/dev/null

mkdir -p "$project_dir/.build/downloads" "$project_dir/dist"
docker run --rm \
	-u "$(id -u):$(id -g)" \
	-v "$project_dir:/src" -w /src \
	-e HOME=/tmp \
	-e BUILD_ROOT="/src/.build/container-$image_tag" \
	-e DOWNLOAD_DIR=/src/.build/downloads \
	-e JOBS -e SMOKE -e FORCE_SMOKE \
	"$image" ./scripts/build-linux-amd64.sh
