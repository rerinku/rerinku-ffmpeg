#!/usr/bin/env bash
# Download and unpack every locked source tree under .build/.
#
# Optional components are only fetched when their switch is on, so a default
# build never clones the x265 tree or downloads alsa-lib:
#   WITH_X265=1   also fetch x265 (H.265 encoder)
#   WITH_ALSA=0   skip alsa-lib (default 1: ALSA capture for UVC USB microphones)
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="${VERSIONS_FILE:-$project_dir/packaging/versions.env}"
download_dir="${DOWNLOAD_DIR:-$project_dir/.build/downloads}"
src_dir="${SRC_DIR:-$project_dir/.build/src}"
with_x265="${WITH_X265:-0}"
with_alsa="${WITH_ALSA:-1}"

# shellcheck disable=SC1090
source "$lock_file"

mkdir -p "$download_dir" "$src_dir"

download() {
	local url="$1"
	local output="$2"
	if [[ ! -f "$output" ]]; then
		curl -L --fail -o "$output" "$url"
	fi
}

verify_sha256() {
	local file="$1"
	local want="$2"
	if [[ -z "$want" ]]; then
		echo "warning: no sha256 locked for $file; recording actual value" >&2
		sha256sum "$file"
		return 0
	fi
	local got
	got="$(sha256sum "$file" | awk '{print $1}')"
	if [[ "$got" != "$want" ]]; then
		echo "sha256 mismatch: $file" >&2
		echo "  got:  $got" >&2
		echo "  want: $want" >&2
		exit 2
	fi
}

extract_tarball() {
	local archive="$1"
	local marker="$2"
	local dest="$3"
	if [[ -f "$marker" ]]; then
		return 0
	fi
	rm -rf "$dest"
	mkdir -p "$dest"
	tar -xf "$archive" -C "$dest" --strip-components=1
	touch "$marker"
}

fetch_tarball() {
	# fetch_tarball NAME VERSION URL SHA256 [ARCHIVE-EXT]
	local name="$1" version="$2" url="$3" sha="$4" ext="${5:-tar.gz}"
	local archive="$download_dir/$name-$version.$ext"
	download "$url" "$archive"
	verify_sha256 "$archive" "$sha"
	extract_tarball "$archive" "$src_dir/.$name-$version.extracted" "$src_dir/$name"
}

fetch_git() {
	# fetch_git NAME REPO REF
	local name="$1" repo="$2" ref="$3"
	if [[ ! -d "$src_dir/$name/.git" ]]; then
		git clone "$repo" "$src_dir/$name"
	fi
	if ! git -C "$src_dir/$name" cat-file -e "$ref^{commit}" 2>/dev/null; then
		git -C "$src_dir/$name" fetch --tags origin
	fi
	git -C "$src_dir/$name" checkout --detach "$ref"
}

fetch_tarball ffmpeg "$FFMPEG_VERSION" "$FFMPEG_URL" "$FFMPEG_SHA256" tar.xz
fetch_tarball opus "$OPUS_VERSION" "$OPUS_URL" "$OPUS_SHA256"
fetch_tarball libwebp "$LIBWEBP_VERSION" "$LIBWEBP_URL" "$LIBWEBP_SHA256"
fetch_git x264 "$X264_REPO" "$X264_REF"

if [[ "$with_x265" == "1" ]]; then
	fetch_git x265 "$X265_REPO" "$X265_REF"
fi

if [[ "$with_alsa" == "1" ]]; then
	fetch_tarball alsa-lib "$ALSA_LIB_VERSION" "$ALSA_LIB_URL" "$ALSA_LIB_SHA256" tar.bz2
fi

echo "sources ready under $src_dir"
