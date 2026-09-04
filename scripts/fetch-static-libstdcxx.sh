#!/usr/bin/env bash
# libx265 is C++, so a fully static build (STATIC_LINK=1 WITH_X265=1) needs
# libstdc++.a. Debian/Ubuntu ship it in libstdc++-<gccver>-dev, which is often
# not installed. This fetches that package into .build/hostlibs without root and
# without touching the system; build-linux-amd64.sh picks the archive up from
# there when the toolchain cannot find one itself.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hostlibs="$project_dir/.build/hostlibs"
cc="${CC:-gcc}"

found="$("$cc" -print-file-name=libstdc++.a)"
if [[ "$found" != "libstdc++.a" && -f "$found" ]]; then
	echo "toolchain already provides $found"
	exit 0
fi

if [[ -n "$(find "$hostlibs/extract" -name 'libstdc++.a' 2>/dev/null | head -1)" ]]; then
	echo "already fetched under $hostlibs/extract"
	exit 0
fi

if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
	echo "no apt-get/dpkg on this host; install the static libstdc++ for your distro and set STDCXX_LIB_DIR" >&2
	exit 2
fi

gcc_major="$("$cc" -dumpversion | cut -d. -f1)"
mkdir -p "$hostlibs"
cd "$hostlibs"
apt-get download "libstdc++-${gcc_major}-dev"
for deb in libstdc++-*-dev_*.deb; do
	dpkg -x "$deb" extract
done
# The package's libstdc++.so is a relative symlink into the system library
# directory; inside the extract tree it dangles, so point it at the runtime
# library the host already has (dynamic builds link against that).
while IFS= read -r link; do
	target="$(readlink "$link")"
	[[ -e "$link" ]] && continue
	runtime="/usr/lib/x86_64-linux-gnu/$(basename "$target")"
	[[ -e "$runtime" ]] && ln -sf "$runtime" "$link"
done < <(find extract -name 'libstdc++.so' -type l)
find extract -name 'libstdc++.a' -o -name 'libstdc++.so'
