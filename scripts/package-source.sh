#!/usr/bin/env bash
# Package the complete corresponding source of a release, as the GPL requires
# for the binaries it ships:
#
#   package-source.sh <tag> [out-dir]      (out-dir defaults to release/)
#
# rerinku-ffmpeg-<tag>-source.tar.xz holds the upstream source archives of
# FFmpeg and every library the executables link (the Linux build is the
# superset of the other platforms'), exactly as pinned by packaging/versions.env,
# and this repository at HEAD: the scripts that configure, build and test them.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag="${1:?usage: package-source.sh <tag> [out-dir]}"
out_dir="${2:-$project_dir/release}"

# shellcheck disable=SC1091
source "$project_dir/packaging/versions.env"

name="rerinku-ffmpeg-$tag-source"
stamp="$(git -C "$project_dir" log -1 --format=%cI)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$name"
mkdir -p "$stage/upstream" "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

# The upstream archives, downloaded and checked against the pinned checksums.
if ! DOWNLOAD_DIR="$work/dl" SRC_DIR="$work/src" WITH_ALSA=1 WITH_LINUX_HWACCEL=1 WITH_X265=0 \
	"$project_dir/scripts/fetch.sh" >"$work/fetch.log" 2>&1; then
	cat "$work/fetch.log" >&2
	exit 1
fi
cp "$work"/dl/* "$stage/upstream/"
# x264 has no release tarballs: archive the pinned commit.
git -C "$work/src/x264" archive --format=tar --prefix="x264-${X264_REF:0:12}/" "$X264_REF" |
	xz -9 >"$stage/upstream/x264-${X264_REF:0:12}.tar.xz"

# The build scripts at this release, and the license.
git -C "$project_dir" archive --format=tar --prefix=rerinku-ffmpeg/ HEAD | tar -x -C "$stage"
install -m 0644 "$project_dir/licenses/GPL-3.0.txt" "$stage/COPYING.GPLv3"

cat >"$stage/README" <<TEXT
Corresponding source of rerinku-ffmpeg $tag (FFmpeg $FFMPEG_VERSION).

upstream/        the source archives of FFmpeg and the libraries linked into it,
                 and of meson, which builds libva and libdrm (x264 is the
                 archive of commit $X264_REF); their checksums are pinned in
                 rerinku-ffmpeg/packaging/versions.env
rerinku-ffmpeg/  the scripts that configure, build and test the executables
                 (README.md there explains how to run them)

FFmpeg is not patched: the executables are made by the configure options and
build steps in rerinku-ffmpeg/scripts/build-linux-amd64.sh, which trim FFmpeg
to the components Rerinku View uses.
TEXT

find "$stage" -exec touch -d "$stamp" {} +
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$work" -cf - "$name" |
	xz -6 -T0 >"$out_dir/$name.tar.xz"
echo "$out_dir/$name.tar.xz"
