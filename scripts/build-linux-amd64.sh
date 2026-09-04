#!/usr/bin/env bash
# Build the trimmed FFmpeg for the selected native platform.
#
# Linux output is fully static (including glibc). macOS output statically links
# the codec libraries while retaining the normal dependency on Apple system
# libraries. In both cases rerinku-onboard embeds the executable and seeds it
# into ~/.rerinku/bin at runtime.
#
# Switches (environment variables, all default to 0 unless noted):
#   WITH_X265=1     add the libx265 H.265 *encoder* (+~5 MB; decoding H.265
#                   never needs it, the native hevc decoder is always built)
#   WITH_ALSA=0     drop the ALSA input device (default 1: UVC cameras with a
#                   USB microphone capture audio through "-f alsa"; without it
#                   the SDK falls back to video-only and WebRTC start waits
#                   for the announced audio track to time out)
#   DISABLE_ASM=1   drop all assembly (only for toolchains without nasm)
#   SMOKE=0         skip scripts/smoke.sh after the build (default 1)
#   FORCE_SMOKE=1   rerun validation even when the cached binary is current
#   JOBS=n          parallelism (default: online CPUs)
#
# RERINKU_BUILD_PLATFORM is an internal switch used by build-macos.sh. The
# public default remains linux-amd64 for compatibility with existing CI.
#
# Output: dist/<variant>/ffmpeg
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="${VERSIONS_FILE:-$project_dir/packaging/versions.env}"
build_platform="${RERINKU_BUILD_PLATFORM:-linux-amd64}"
case "$build_platform" in
	linux-amd64)
		target_os=linux
		target_arch=amd64
		default_with_alsa=1
		default_cc=gcc
		;;
	darwin-arm64|darwin-amd64)
		target_os=darwin
		target_arch="${build_platform#darwin-}"
		default_with_alsa=0
		default_cc=clang
		;;
	*)
		echo "unsupported native build platform: $build_platform" >&2
		exit 2
		;;
esac
jobs="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 2)}"
with_x265="${WITH_X265:-0}"
with_alsa="${WITH_ALSA:-$default_with_alsa}"
disable_asm="${DISABLE_ASM:-0}"
smoke="${SMOKE:-1}"
force_smoke="${FORCE_SMOKE:-0}"

if [[ "$target_os" == "darwin" && "$with_alsa" == "1" ]]; then
	echo "WITH_ALSA=1 is not supported on macOS" >&2
	exit 2
fi

# shellcheck disable=SC1090
source "$lock_file"

asm_enabled=0
if [[ "$disable_asm" != "1" ]]; then
	if [[ "$target_arch" == "arm64" ]] || command -v nasm >/dev/null 2>&1; then
		asm_enabled=1
	fi
fi

variant="$build_platform"
[[ "$with_x265" == "1" ]] && variant+="-x265"
[[ "$with_alsa" != "1" ]] && variant+="-noalsa"
# macOS never has ALSA, so keep the canonical path exactly darwin-<arch>.
[[ "$target_os" == "darwin" ]] && variant="${variant%-noalsa}"

build_dir="$project_dir/.build/build/$variant"
dep_build_dir="$project_dir/.build/build/deps-$build_platform"
src_dir="$project_dir/.build/src"
prefix="$project_dir/.build/prefix/$build_platform"
dist_dir="$project_dir/dist/$variant"
pkgconfig="$prefix/lib/pkgconfig"

mkdir -p "$build_dir" "$dep_build_dir" "$prefix" "$dist_dir"

export PKG_CONFIG_PATH="$pkgconfig"
export CFLAGS="-Os -ffunction-sections -fdata-sections"
export CXXFLAGS="$CFLAGS"
if [[ "$target_os" == "darwin" ]]; then
	export LDFLAGS="-Wl,-dead_strip"
else
	export LDFLAGS="-Wl,--gc-sections"
fi

sha256_stream() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum
	else
		shasum -a 256
	fi
}

# Avoid even fetching/checking sources on the common no-change path. The
# fingerprint covers every input that can affect the native executable; the
# detailed per-library hashes below remain the fallback when it changes.
compiler="${CC:-$default_cc}"
build_inputs_hash="$({
	printf '%s\n' \
		"platform=$build_platform" \
		"with_x265=$with_x265" \
		"with_alsa=$with_alsa" \
		"asm_enabled=$asm_enabled" \
		"cc=$compiler" \
		"macosx_deployment_target=${MACOSX_DEPLOYMENT_TARGET:-}" \
		"sdkroot=${SDKROOT:-}"
	"$compiler" --version 2>/dev/null | head -n 1 || true
	cat "$lock_file" "$project_dir/scripts/build-linux-amd64.sh" "$project_dir/scripts/fetch.sh"
} | sha256_stream | awk '{print $1}')"
build_inputs_file="$build_dir/.build-inputs"

if [[ "$force_smoke" != "1" && -x "$dist_dir/ffmpeg" && -f "$build_inputs_file" ]] &&
	[[ "$(cat "$build_inputs_file")" == "$build_inputs_hash" ]]; then
	echo "FFmpeg inputs unchanged; using cached binary: $dist_dir/ffmpeg"
	exit 0
fi

WITH_X265="$with_x265" WITH_ALSA="$with_alsa" "$project_dir/scripts/fetch.sh"

dependencies_rebuilt=0
ffmpeg_rebuilt=0

# All dependencies install into one shared prefix, so what matters is which
# configuration is *currently installed* there, not which ones were ever built.
# Each dependency records the hash of its configure arguments after install;
# a mismatch (changing flags, bumping the lock) triggers a rebuild.
dep_hash() {
	printf '%s\n' "$@" | sha256_stream | cut -c1-16
}
dep_installed() {
	# dep_installed NAME HASH -> 0 when NAME is installed with exactly HASH
	[[ -f "$dep_build_dir/.$1-installed" && "$(cat "$dep_build_dir/.$1-installed")" == "$2" ]]
}
dep_mark() {
	printf '%s\n' "$2" >"$dep_build_dir/.$1-installed"
}

build_x264() {
	# Only progressive 8-bit 4:2:0 is ever produced (every caller forces
	# -pix_fmt yuv420p), so the 10-bit / 4:2:2 / 4:4:4 / interlaced paths are
	# dead weight.
	local configure_args=(
		--prefix="$prefix"
		--enable-static
		--disable-cli
		--disable-opencl
		--disable-lavf
		--disable-swscale
		--disable-avs
		--disable-ffms
		--disable-gpac
		--disable-lsmash
		--disable-interlaced
		--bit-depth=8
		--chroma-format=420
	)
	[[ "$asm_enabled" != "1" ]] && configure_args+=(--disable-asm)
	local hash
	hash="$(dep_hash "$X264_REF" "$CFLAGS" "${configure_args[@]}")"
	dep_installed x264 "$hash" && return 0
	dependencies_rebuilt=1
	rm -f "$dep_build_dir/.x264-installed"
	pushd "$src_dir/x264" >/dev/null
	make distclean >/dev/null 2>&1 || true
	./configure "${configure_args[@]}"
	make -j"$jobs"
	make install
	popd >/dev/null
	dep_mark x264 "$hash"
}

build_x265() {
	local x265_build="$dep_build_dir/x265"
	# ENABLE_PIC must stay ON: the non-PIC x265 assembly crashes at runtime in
	# this link (asm=false works), PIC is fine.
	local cmake_args=(
		-DCMAKE_BUILD_TYPE=MinSizeRel
		-DCMAKE_INSTALL_PREFIX="$prefix"
		-DENABLE_SHARED=OFF
		-DENABLE_CLI=OFF
		-DENABLE_LIBNUMA=OFF
		-DENABLE_HDR10_PLUS=OFF
		-DENABLE_TESTS=OFF
		-DENABLE_PIC=ON
		-DHIGH_BIT_DEPTH=OFF
		-DENABLE_ASSEMBLY="$([[ "$asm_enabled" == "1" ]] && echo ON || echo OFF)"
		-DCMAKE_C_FLAGS="$CFLAGS"
		-DCMAKE_CXX_FLAGS="$CXXFLAGS"
	)
	local hash
	hash="$(dep_hash "$X265_REF" "${cmake_args[@]}")"
	dep_installed x265 "$hash" && return 0
	dependencies_rebuilt=1
	rm -f "$dep_build_dir/.x265-installed"
	rm -rf "$x265_build"
	mkdir -p "$x265_build"
	cmake -S "$src_dir/x265/source" -B "$x265_build" -G Ninja "${cmake_args[@]}"
	cmake --build "$x265_build" --parallel "$jobs"
	cmake --install "$x265_build"
	# x265.pc lists -lgcc_s, which does not exist as a static archive and breaks
	# "-static" links; libgcc/libstdc++ are pulled in explicitly below anyway.
	if [[ "$target_os" == "darwin" ]]; then
		sed -i '' 's/ -lgcc_s//g' "$pkgconfig/x265.pc"
	else
		sed -i 's/ -lgcc_s//g' "$pkgconfig/x265.pc"
	fi
	dep_mark x265 "$hash"
}

build_opus() {
	local configure_args=(
		--prefix="$prefix"
		--enable-static
		--disable-shared
		--disable-doc
		--disable-extra-programs
	)
	local hash
	hash="$(dep_hash "$OPUS_VERSION" "$CFLAGS" "${configure_args[@]}")"
	dep_installed opus "$hash" && return 0
	dependencies_rebuilt=1
	rm -f "$dep_build_dir/.opus-installed"
	pushd "$src_dir/opus" >/dev/null
	make distclean >/dev/null 2>&1 || true
	./configure "${configure_args[@]}"
	make -j"$jobs"
	make install
	popd >/dev/null
	dep_mark opus "$hash"
}

build_libwebp() {
	# Only the still-image encoder is used (storyboards); no mux/demux/decoder.
	local configure_args=(
		--prefix="$prefix"
		--enable-static
		--disable-shared
		--disable-gif
		--disable-jpeg
		--disable-png
		--disable-tiff
		--disable-wic
		--disable-sdl
		--disable-gl
		--disable-neon
		--disable-libwebpmux
		--disable-libwebpdemux
	)
	local hash
	hash="$(dep_hash "$LIBWEBP_VERSION" "$CFLAGS" "${configure_args[@]}")"
	dep_installed libwebp "$hash" && return 0
	dependencies_rebuilt=1
	rm -f "$dep_build_dir/.libwebp-installed"
	pushd "$src_dir/libwebp" >/dev/null
	make distclean >/dev/null 2>&1 || true
	./configure "${configure_args[@]}"
	make -j"$jobs"
	make install
	popd >/dev/null
	dep_mark libwebp "$hash"
}

build_alsa() {
	# FFmpeg's alsa input only needs the PCM + control API.
	local configure_args=(
		--prefix="$prefix"
		--enable-static
		--disable-shared
		--disable-python
		--disable-old-symbols
		--disable-ucm
		--disable-topology
		--disable-alisp
		--disable-rawmidi
		--disable-hwdep
		--disable-seq
		--disable-mixer
	)
	local hash
	hash="$(dep_hash "$ALSA_LIB_VERSION" "$CFLAGS" "${configure_args[@]}")"
	dep_installed alsa "$hash" && return 0
	dependencies_rebuilt=1
	rm -f "$dep_build_dir/.alsa-installed"
	pushd "$src_dir/alsa-lib" >/dev/null
	make distclean >/dev/null 2>&1 || true
	./configure "${configure_args[@]}"
	make -j"$jobs"
	make install
	popd >/dev/null
	dep_mark alsa "$hash"
}

build_ffmpeg() {
	local ffbuild="$build_dir/ffmpeg"
	local extra_ldflags extra_libs
	if [[ "$target_os" == "darwin" ]]; then
		extra_ldflags="-L$prefix/lib -Wl,-dead_strip"
		extra_libs="-lpthread -lm"
	else
		extra_ldflags="-static -L$prefix/lib -Wl,--gc-sections"
		extra_libs="-lpthread -lm -ldl"
	fi

	# Component lists mirror the exact command lines in scripts/smoke.sh.
	# pcm_s16le encoder + muxer: UVC microphone capture ("-f alsa ... -c:a
	# pcm_s16le -f s16le pipe:1" in rerinku-cli/internal/uvc/audio_linux.go).
	local encoders="libx264,libopus,aac,mjpeg,libwebp,pcm_alaw,pcm_mulaw,pcm_s16le"
	# Opus is decoded through libopus (already linked for encoding) instead of
	# the native decoder and its tables.
	local decoders="h264,hevc,mjpeg,aac,libopus,pcm_s16le,pcm_alaw,pcm_mulaw"
	# FFmpeg 9 names the raw PCM demuxers pcm_*; "s16le" would be ignored.
	local demuxers="h264,hevc,mjpeg,aac,ogg,pcm_s16le,pcm_alaw,pcm_mulaw,mov"
	local muxers="h264,adts,rtp,image2pipe,webp,mp4,pcm_s16le"
	local parsers="h264,hevc,mjpeg,aac"
	local bsfs="h264_metadata"
	# aresample/aformat are inserted implicitly by the CLI for every -ar/-ac
	# change (8 kHz G.711 -> 48 kHz Opus, mono -> stereo AAC).
	local filters="scale,fps,pad,tile,tpad,format,null,anull,aresample,aformat"
	local configure_args=(
		--prefix="$prefix"
		--bindir="$dist_dir"
		--pkg-config-flags="--static"
		--extra-cflags="-I$prefix/include -ffunction-sections -fdata-sections"
		--cc="${CC:-$default_cc}"
		--enable-gpl
		--enable-version3
		--enable-static
		--disable-shared
		--disable-debug
		--disable-doc
		--disable-ffplay
		--disable-ffprobe
		--disable-autodetect
		--disable-everything
		--enable-small
		--disable-swscale-alpha
		--disable-pixelutils
		--disable-dwt
		--disable-lsp
		--enable-network
		--enable-protocol=file,pipe,udp,rtp
		--enable-libx264
		--enable-libopus
		--enable-libwebp
	)
	if [[ "$with_x265" == "1" ]]; then
		configure_args+=(--enable-libx265)
		encoders+=",libx265"
		muxers+=",hevc"
		if [[ "$target_os" == "darwin" ]]; then
			extra_libs+=" -lc++"
		else
			extra_libs+=" -lstdc++"
		fi
		# x265 is C++: the static link needs libstdc++.a, which Debian keeps in
		# libstdc++-<ver>-dev. If the toolchain cannot find it,
		# scripts/fetch-static-libstdcxx.sh drops that package under
		# .build/hostlibs without root and this picks it up.
		local stdcxx stdcxx_dir="${STDCXX_LIB_DIR:-}"
		if [[ "$target_os" == "linux" ]]; then
			stdcxx="$("${CC:-$default_cc}" -print-file-name=libstdc++.a)"
		fi
		if [[ "$target_os" == "linux" && ( "$stdcxx" == "libstdc++.a" || ! -e "$stdcxx" ) ]]; then
			if [[ -z "$stdcxx_dir" ]]; then
				stdcxx="$(find "$project_dir/.build/hostlibs/extract" -name 'libstdc++.a' 2>/dev/null | head -1)"
				[[ -n "$stdcxx" ]] && stdcxx_dir="$(dirname "$stdcxx")"
			fi
			if [[ -z "$stdcxx_dir" || ! -e "$stdcxx_dir/libstdc++.a" ]]; then
				echo "WITH_X265=1 needs libstdc++.a: install libstdc++-<gccver>-dev, run scripts/fetch-static-libstdcxx.sh, or set STDCXX_LIB_DIR" >&2
				exit 2
			fi
			extra_ldflags="-L$stdcxx_dir $extra_ldflags"
		fi
	fi
	if [[ "$with_alsa" == "1" ]]; then
		configure_args+=(--enable-alsa --enable-indev=alsa)
	else
		configure_args+=(--disable-avdevice)
	fi
	[[ "$asm_enabled" != "1" ]] && configure_args+=(--disable-x86asm)
	configure_args+=(
		--extra-ldflags="$extra_ldflags"
		--extra-libs="$extra_libs"
		--enable-encoder="$encoders"
		--enable-decoder="$decoders"
		--enable-demuxer="$demuxers"
		--enable-muxer="$muxers"
		--enable-parser="$parsers"
		--enable-bsf="$bsfs"
		--enable-filter="$filters"
	)
	local build_hash
	build_hash="$(dep_hash "$FFMPEG_VERSION" "$X264_REF" "$OPUS_VERSION" "$LIBWEBP_VERSION" \
		"$with_x265" "$with_alsa" "$asm_enabled" "$CFLAGS" "$LDFLAGS" "${configure_args[@]}")"
	if [[ "$dependencies_rebuilt" != "1" && -x "$dist_dir/ffmpeg" ]] && dep_installed ffmpeg "$build_hash"; then
		echo "FFmpeg is up to date: $dist_dir/ffmpeg"
		return 0
	fi
	rm -f "$dep_build_dir/.ffmpeg-installed"

	rm -rf "$ffbuild"
	mkdir -p "$ffbuild"
	pushd "$ffbuild" >/dev/null
	"$src_dir/ffmpeg/configure" "${configure_args[@]}"
	make -j"$jobs" ffmpeg
	make install-progs
	popd >/dev/null
	dep_mark ffmpeg "$build_hash"
	ffmpeg_rebuilt=1
}

build_x264
[[ "$with_x265" == "1" ]] && build_x265
build_opus
build_libwebp
[[ "$with_alsa" == "1" ]] && build_alsa
build_ffmpeg

if [[ "$ffmpeg_rebuilt" == "1" && "$target_os" == "darwin" ]]; then
	strip -x "$dist_dir/ffmpeg" || true
elif [[ "$ffmpeg_rebuilt" == "1" ]]; then
	strip --strip-all "$dist_dir/ffmpeg" || true
fi

if [[ "$target_os" == "darwin" ]]; then
	if ! file "$dist_dir/ffmpeg" | grep -q 'Mach-O'; then
		echo "$dist_dir/ffmpeg is not a macOS executable" >&2
		exit 2
	fi
else
	if ldd "$dist_dir/ffmpeg" 2>&1 | grep -Eq '=>|ld-linux'; then
		echo "$dist_dir/ffmpeg is not statically linked" >&2
		exit 2
	fi
fi

if [[ "$ffmpeg_rebuilt" != "1" && "$force_smoke" != "1" ]]; then
	printf '%s\n' "$build_inputs_hash" >"$build_inputs_file"
	echo "FFmpeg inputs unchanged; skipped rebuild and smoke test: $dist_dir/ffmpeg"
	exit 0
fi

"$project_dir/scripts/size-report.sh" "$dist_dir/ffmpeg"
if [[ "$smoke" == "1" ]]; then
	echo
	"$project_dir/scripts/smoke.sh" "$dist_dir/ffmpeg"
fi
printf '%s\n' "$build_inputs_hash" >"$build_inputs_file"
