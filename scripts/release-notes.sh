#!/usr/bin/env bash
# Print the Markdown body of a GitHub release.
#
#   release-notes.sh <tag> [assets-dir]    (assets-dir defaults to release/)
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag="${1:?usage: release-notes.sh <tag> [assets-dir]}"
assets="${2:-$project_dir/release}"

# shellcheck disable=SC1091
source "$project_dir/packaging/versions.env"
commit="${GITHUB_SHA:-$(git -C "$project_dir" rev-parse HEAD)}"

cat <<TEXT
FFmpeg $FFMPEG_VERSION, trimmed and built for Rerinku View. Commit \`${commit:0:7}\`.

## Downloads

| Platform | File |
|---|---|
TEXT
for entry in \
	"linux-amd64|tar.gz|Linux x86-64 (glibc 2.29 or newer)" \
	"linux-arm64|tar.gz|Linux ARM64 (glibc 2.29 or newer)" \
	"windows-amd64|zip|Windows x64" \
	"windows-arm64|zip|Windows ARM64" \
	"darwin-arm64|tar.gz|macOS, Apple silicon" \
	"darwin-amd64|tar.gz|macOS, Intel"; do
	IFS='|' read -r platform ext label <<<"$entry"
	file="rerinku-ffmpeg-$tag-$platform.$ext"
	[[ -f "$assets/$file" ]] && echo "| $label | \`$file\` |"
done

cat <<TEXT

\`SHA256SUMS\` lists the checksum of every file. Each archive contains the
executable, \`COPYING.GPLv3\`, \`NOTICE.md\` and \`BUILDINFO\`.

## License and source code

These executables are licensed under the GNU General Public License, version 3:
FFmpeg is configured with \`--enable-gpl --enable-version3\` and links x264
statically. The complete corresponding source is attached to this release as
\`rerinku-ffmpeg-$tag-source.tar.xz\`: the upstream source archives of FFmpeg and
every library linked into it, at the versions pinned in
\`packaging/versions.env\`, and the scripts of this repository at this tag that
configure, build and test them. FFmpeg itself is not patched.

To rebuild, unpack the source archive and see \`rerinku-ffmpeg/README.md\`.
TEXT
