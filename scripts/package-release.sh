#!/usr/bin/env bash
# Package one platform's FFmpeg for a release.
#
#   package-release.sh <platform> <tag> [out-dir]      (out-dir defaults to release/)
#
# platform: linux-amd64, windows-amd64, darwin-arm64 or darwin-amd64 (the
# directory under dist/ the build left the executable in).
#
# The archive rerinku-ffmpeg-<tag>-<platform>.tar.gz (.zip for Windows) holds
# the executable, the GPL text, NOTICE.md (components, licenses, where the
# source is) and BUILDINFO. Needs GNU tar, gzip and, for Windows, zip.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform="${1:?usage: package-release.sh <platform> <tag> [out-dir]}"
tag="${2:?usage: package-release.sh <platform> <tag> [out-dir]}"
out_dir="${3:-$project_dir/release}"

# shellcheck disable=SC1091
source "$project_dir/packaging/versions.env"

case "$platform" in
	linux-amd64) exe=ffmpeg; archive=tar; os=linux ;;
	darwin-arm64 | darwin-amd64) exe=ffmpeg; archive=tar; os=darwin ;;
	windows-amd64) exe=ffmpeg.exe; archive=zip; os=windows ;;
	*)
		echo "unknown platform: $platform" >&2
		exit 2
		;;
esac

binary="$project_dir/dist/$platform/$exe"
if [[ ! -f "$binary" ]]; then
	echo "no executable at $binary: build it first" >&2
	exit 2
fi

commit="${GITHUB_SHA:-$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo unknown)}"
stamp="$(git -C "$project_dir" log -1 --format=%cI 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
name="rerinku-ffmpeg-$tag-$platform"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$name"
mkdir -p "$stage" "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

install -m 0755 "$binary" "$stage/$exe"
install -m 0644 "$project_dir/licenses/GPL-3.0.txt" "$stage/COPYING.GPLv3"

row() { # row NAME VERSION LICENSE URL [SHA256]
	# The backticks are Markdown, not command substitution.
	# shellcheck disable=SC2016
	if [[ -n "${5:-}" ]]; then
		printf '| %s | %s | %s | %s (sha256 `%s`) |\n' "$1" "$2" "$3" "$4" "$5"
	else
		printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4"
	fi
}

{
	cat <<TEXT
# FFmpeg for Rerinku View

FFmpeg $FFMPEG_VERSION, built by the rerinku-ffmpeg project for $platform
(release \`$tag\`, commit \`$commit\`).

## License

This executable is configured with \`--enable-gpl --enable-version3\` and
statically links x264, so it is licensed under the GNU General Public License,
version 3. The license text is in \`COPYING.GPLv3\`.

The complete corresponding source is published next to this archive, on the
same release page, as \`rerinku-ffmpeg-$tag-source.tar.xz\`: the upstream source
archives of everything listed below, at the versions below, and the scripts
that configure, build and test the executable. No source file of FFmpeg or of
the libraries is modified, except that the build script changes
\`shared_library(\` to \`library(\` in libva's \`va/meson.build\` (Linux) so that
libva can be linked statically. The configure line of this executable is
printed by \`ffmpeg -version\`.

## Components linked into the executable

| Component | Version | License | Source |
|---|---|---|---|
TEXT
	row FFmpeg "$FFMPEG_VERSION" "GPL-3.0-or-later as configured (LGPL-2.1-or-later code base)" "$FFMPEG_URL" "$FFMPEG_SHA256"
	row x264 "commit \`$X264_REF\`" GPL-2.0-or-later "$X264_REPO"
	row Opus "$OPUS_VERSION" BSD-3-Clause "$OPUS_URL" "$OPUS_SHA256"
	row libwebp "$LIBWEBP_VERSION" BSD-3-Clause "$LIBWEBP_URL" "$LIBWEBP_SHA256"
	case "$os" in
		linux)
			row alsa-lib "$ALSA_LIB_VERSION" LGPL-2.1-or-later "$ALSA_LIB_URL" "$ALSA_LIB_SHA256"
			row libva "$LIBVA_VERSION" MIT "$LIBVA_URL" "$LIBVA_SHA256"
			row libdrm "$LIBDRM_VERSION" MIT "$LIBDRM_URL" "$LIBDRM_SHA256"
			row "nv-codec-headers (headers only)" "$NV_CODEC_HEADERS_VERSION" MIT "$NV_CODEC_HEADERS_URL" "$NV_CODEC_HEADERS_SHA256"
			cat <<'TEXT'

The executable links glibc dynamically and loads the system's VA-API drivers
and, on NVIDIA machines, the driver's `libcuda` and `libnvcuvid` at run time;
none of them is part of this distribution.
TEXT
			;;
		windows)
			cat <<'TEXT'

The executable also contains the mingw-w64 C runtime (permissive licenses),
linked statically, and imports only Windows system DLLs.
TEXT
			;;
		darwin)
			cat <<'TEXT'

The executable uses Apple's system frameworks (such as VideoToolbox), which are
not part of this distribution.
TEXT
			;;
	esac
} >"$stage/NOTICE.md"

{
	echo "release=$tag"
	echo "platform=$platform"
	echo "commit=$commit"
	echo "ffmpeg=$FFMPEG_VERSION"
	if command -v sha256sum >/dev/null 2>&1; then
		echo "sha256=$(sha256sum "$binary" | awk '{print $1}')"
	else
		echo "sha256=$(shasum -a 256 "$binary" | awk '{print $1}')"
	fi
} >"$stage/BUILDINFO"

# Same inputs, same archive: fixed order, owner, modes and times.
chmod 0644 "$stage/NOTICE.md" "$stage/BUILDINFO"
chmod 0755 "$stage"
find "$stage" -exec touch -d "$stamp" {} +
case "$archive" in
	tar)
		tar --sort=name --owner=0 --group=0 --numeric-owner -C "$work" -cf - "$name" |
			gzip -9 -n >"$out_dir/$name.tar.gz"
		echo "$out_dir/$name.tar.gz"
		;;
	zip)
		rm -f "$out_dir/$name.zip"
		(cd "$work" && find "$name" | LC_ALL=C sort | zip -q -X -9 "$out_dir/$name.zip" -@)
		echo "$out_dir/$name.zip"
		;;
esac
