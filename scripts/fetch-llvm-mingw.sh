#!/usr/bin/env bash
# Install the pinned llvm-mingw toolchain (packaging/versions.env) under
# .build/toolchains/ and print its directory. Downloads are checked against
# the pinned SHA-256; nothing is installed system-wide.
#
#   PATH="$(scripts/fetch-llvm-mingw.sh)/bin:$PATH"
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="${VERSIONS_FILE:-$project_dir/packaging/versions.env}"
download_dir="${DOWNLOAD_DIR:-$project_dir/.build/downloads}"
toolchain_root="${TOOLCHAIN_DIR:-$project_dir/.build/toolchains}"

# shellcheck disable=SC1090
source "$lock_file"

if [[ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]]; then
	echo "llvm-mingw is pinned for Linux x86-64 hosts only" >&2
	exit 2
fi

name="$(basename "$LLVM_MINGW_URL" .tar.xz)"
dest="$toolchain_root/$name"
if [[ ! -x "$dest/bin/aarch64-w64-mingw32-clang" ]]; then
	mkdir -p "$download_dir" "$toolchain_root"
	archive="$download_dir/$name.tar.xz"
	if [[ ! -f "$archive" ]]; then
		curl -L --fail --retry 3 -o "$archive.part" "$LLVM_MINGW_URL" >&2
		mv "$archive.part" "$archive"
	fi
	got="$(sha256sum "$archive" | awk '{print $1}')"
	if [[ "$got" != "$LLVM_MINGW_SHA256" ]]; then
		rm -f "$archive"
		echo "sha256 mismatch for $archive: got $got want $LLVM_MINGW_SHA256" >&2
		exit 2
	fi
	rm -rf "$dest.part"
	mkdir -p "$dest.part"
	tar -xf "$archive" -C "$dest.part" --strip-components=1
	mv "$dest.part" "$dest"
fi
printf '%s\n' "$dest"
