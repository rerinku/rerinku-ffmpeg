# rerinku-ffmpeg

A minimal FFmpeg for Rerinku View: one small executable per platform, built
with `--disable-everything` and only the components the product actually runs.

| | |
|---|---|
| Decode | H.264, H.265, MJPEG, AAC, Opus, G.711, PCM. Hardware: VA-API and NVDEC (Linux), D3D11VA (Windows), VideoToolbox (macOS) |
| Encode | H.264 (libx264; VA-API and NVENC on Linux), AAC, Opus, G.711, WebP, MJPEG, raw video. H.265 encoding is opt-in |
| Containers | MP4/fMP4, raw H.264/HEVC, Ogg, ADTS, RTP, WebP, PCM, image pipe. ALSA capture on Linux |
| Filters | scale, fps, tpad, pad, tile, aresample, VA-API scale and upload |

`scripts/smoke.sh` replays every FFmpeg command line the product issues against
the binary, and the build fails if one stops working. To add or drop a
component, change `smoke.sh` first.

## Build

```sh
make linux-container   # release builds, x86-64 and ARM64, in Debian 11 containers (needs docker; ARM64 uses QEMU on x86-64)
make linux             # against this host's glibc
make windows           # x64 (mingw-w64) and ARM64 (llvm-mingw, fetched on first use)
make macos             # on macOS
make smoke BIN=dist/linux-amd64/ffmpeg
```

Output goes to `dist/<platform>/ffmpeg`; sources, objects and test fixtures go
to `.build/`. Every build runs the smoke test afterwards, except Windows, whose
binary cannot run on the Linux host: run `scripts/smoke.sh` on Windows before
releasing.

| Platform | Output | Notes |
|---|---|---|
| Linux x86-64 | `dist/linux-amd64/ffmpeg` | Needs glibc 2.29 or newer when built by `linux-container`. Only glibc is linked dynamically (GPU drivers are loaded with `dlopen`, which a static glibc cannot do); musl/Alpine is not supported |
| Linux ARM64 | `dist/linux-arm64/ffmpeg` | Same as x86-64; built natively on ARM64, or in the ARM64 container under QEMU on x86-64 (binfmt_misc) |
| Windows x64 | `dist/windows-amd64/ffmpeg.exe` | Imports only Windows system DLLs |
| Windows ARM64 | `dist/windows-arm64/ffmpeg.exe` | Built with the llvm-mingw pinned in `versions.env`; imports only Windows system DLLs and the UCRT |
| macOS | `dist/darwin-arm64/ffmpeg`, `dist/darwin-amd64/ffmpeg` | Codec libraries linked statically |

### Switches

Environment variables, passed to any build target:

| Variable | Effect |
|---|---|
| `WITH_X265=1` | Add the libx265 H.265 encoder (+5 MB). Needs `libstdc++-<gcc version>-dev` |
| `WITH_HWACCEL=0` | Leave out the hardware decoding APIs |
| `WITH_ALSA=0` | Leave out ALSA capture (Linux). USB-microphone UVC cameras then stream video only |
| `DISABLE_ASM=1` | No assembly, for hosts without `nasm` (several times slower) |
| `SMOKE=0` | Skip the smoke test after the build |
| `FORCE_SMOKE=1` | Run the smoke test even when nothing changed |
| `JOBS=n` | Parallel jobs |

Switches show up in the output name (`linux-amd64-x265`, `linux-amd64-noalsa`, ...).
A rebuild is skipped when no input changed.

### Requirements

- Debian/Ubuntu: `build-essential nasm pkg-config curl git cmake ninja-build python3 bc xz-utils`;
  `gcc-mingw-w64-x86-64` for Windows (plus `g++-mingw-w64-x86-64` with `WITH_X265=1`)
- macOS: Xcode Command Line Tools, `pkg-config cmake ninja python3 bc xz`
- A full `ffmpeg` on `PATH`, only to generate the smoke-test fixtures

## Releases

Pushing a tag `v*` builds every platform and publishes a GitHub Release
(`.github/workflows/release.yml`) with:

- `rerinku-ffmpeg-<tag>-<platform>.tar.gz` / `.zip`: the executable, `COPYING.GPLv3`, `NOTICE.md`
- `rerinku-ffmpeg-<tag>-source.tar.xz`: the complete corresponding source (see License)
- `SHA256SUMS`

```sh
git tag v9.0.1-1 && git push origin v9.0.1-1   # v<FFmpeg version>-<n>
```

Run the workflow by hand from the Actions tab to build and package without publishing.

## Layout

```
.github/     release workflow
scripts/     build-*.sh per platform, fetch.sh (sources), smoke.sh, size-report.sh,
             package-*.sh and release-notes.sh (used by the release workflow)
packaging/   versions.env (pinned sources), linux-build.Dockerfile (release container)
licenses/    GPL text shipped with the binaries
dist/        build output (not committed)
.build/      sources, objects, fixtures (not committed)
```

FFmpeg and every dependency are pinned in `packaging/versions.env` and verified
by checksum.

## License

The binaries are GPL-3.0: FFmpeg is configured with `--enable-gpl --enable-version3`
and libx264 (and libx265) are GPL. Each release publishes them together with the
complete corresponding source (`rerinku-ffmpeg-<tag>-source.tar.xz`: the upstream
archives of FFmpeg and every linked library, plus these scripts). FFmpeg itself is
not patched.
