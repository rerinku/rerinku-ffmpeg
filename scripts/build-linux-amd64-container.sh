#!/usr/bin/env bash
# Release build of the Linux FFmpeg: build-linux-amd64.sh inside an old-glibc
# container, so the executable runs on every distribution from that glibc on.
#
# The Linux FFmpeg links glibc dynamically — the VA drivers and NVIDIA's
# libraries are the system's, loaded with dlopen — and everything else
# statically (see build-linux-amd64.sh). The glibc it was linked against is its
# floor: built on Debian 11 it needs glibc 2.29, below what Rerinku View itself
# needs, so it runs wherever Rerinku View runs (natively, and in its Debian
# Docker image).
#
#   PLATFORM=amd64|arm64         which Linux build (default amd64); arm64 on an
#                                x86-64 host runs the container under QEMU
#                                (binfmt_misc), slower but the same build
#   BASE_IMAGE=debian:bullseye   build image base (decides the glibc floor)
#   JOBS, SMOKE, FORCE_SMOKE      passed through to build-linux-amd64.sh
#
# Objects and dependencies go to a build root of their own
# (.build/container-<image>), so libraries compiled on a newer host never leak
# newer glibc symbols in; downloads and the output are shared:
#   dist/linux-<PLATFORM>/ffmpeg
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_image="${BASE_IMAGE:-debian:bullseye}"
platform="${PLATFORM:-amd64}"
case "$platform" in
	amd64 | arm64) ;;
	*) echo "PLATFORM must be amd64 or arm64" >&2; exit 2 ;;
esac
image_tag="$(tr ':/' '--' <<<"$base_image")"
# amd64 keeps its original image and build root, so its cache stays valid.
build_tag="$image_tag"
[[ "$platform" != amd64 ]] && build_tag="$image_tag-$platform"
image="rerinku-ffmpeg-build:$build_tag"

docker build --quiet --platform "linux/$platform" -t "$image" --build-arg BASE_IMAGE="$base_image" \
	-f "$project_dir/packaging/linux-build.Dockerfile" "$project_dir/packaging" >/dev/null

mkdir -p "$project_dir/.build/downloads" "$project_dir/dist"
docker run --rm --platform "linux/$platform" \
	-u "$(id -u):$(id -g)" \
	-v "$project_dir:/src" -w /src \
	-e HOME=/tmp \
	-e BUILD_ROOT="/src/.build/container-$build_tag" \
	-e DOWNLOAD_DIR=/src/.build/downloads \
	-e RERINKU_BUILD_PLATFORM="linux-$platform" \
	-e JOBS -e SMOKE -e FORCE_SMOKE \
	"$image" ./scripts/build-linux-amd64.sh
