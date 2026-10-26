# rerinku-ffmpeg

Minimal FFmpeg builds for `rerinku-view`.

FFmpeg and every dependency are locked in `packaging/versions.env`
(FFmpeg 9.0.1 "Lei" as of 2026-09-04).

The executable is trimmed with `--disable-everything` and re-enables only what
the product actually invokes. The authoritative list of those invocations is
`scripts/smoke.sh`: it replays the exact command lines from `rerinku-cli`,
`rerinku-media` and `rerinku-view` against a built binary, and the build
fails if any of them stops working.

| Product path | Source | FFmpeg components |
|---|---|---|
| Live MJPEG -> H.264 (WebRTC) | `rerinku-cli/internal/transcode/h264.go` | mjpeg demuxer/decoder, libx264, h264_metadata bsf, h264 muxer |
| Live H.265 -> H.264 (planned, see below) | same shape with `-f hevc` | hevc demuxer/parser/decoder |
| Audio -> Opus / G.711 RTP (WebRTC) | `rerinku-cli/internal/transcode/opus.go` | pcm_s16le/pcm_alaw/pcm_mulaw/aac demuxers+decoders, libopus, pcm_alaw/pcm_mulaw encoders, aresample, rtp muxer, udp |
| Audio -> AAC ADTS (HLS recordings) | `rerinku-media/transcode/aac.go` | ogg demuxer + libopus decoder, aac encoder, adts muxer |
| MJPEG recording -> H.264 fMP4 | `rerinku-media/recording/ffmpeg.go` | libx264, mp4 muxer |
| Recording thumbnails (H.264/H.265 fMP4 -> JPEG) | `rerinku-view/internal/recording/thumbnail.go` | mov demuxer, h264/hevc decoders, scale, mjpeg encoder, image2pipe |
| Recording storyboards (-> WebP) | `rerinku-view/internal/recording/storyboard.go` | tpad/fps/scale/pad/tile filters, libwebp, webp muxer |
| Device snapshot (raw H.264 -> JPEG) | `rerinku-view/internal/device/framegrab.go` | h264 demuxer/decoder, mjpeg encoder |
| UVC USB microphone capture | `rerinku-cli/internal/uvc/audio_linux.go` | alsa input device (static alsa-lib), pcm_s16le encoder + muxer |
| On-device analytics decode (hardware first) | `rerinku-media/transcode/rawvideo.go`, `hwaccel.go` | h264/hevc decoders, rawvideo encoder+muxer; hardware builds add `h264/hevc_vaapi` + `scale_vaapi`, `h264/hevc_nvdec`, `h264/hevc_d3d11va` or `h264/hevc_videotoolbox`, and `hwdownload` |
| Live H.265 -> H.264 for browsers without H.265 | `rerinku-media/transcode/h264.go`, `hwencode.go` | hevc demuxer/decoder, libx264, h264_metadata + dump_extra bsfs; Linux hardware builds add the `h264_vaapi` and `h264_nvenc` encoders and `hwupload` |

## Build

```sh
./scripts/build-linux-amd64-container.sh  # dist/linux-amd64/ffmpeg   (release build, needs docker)
./scripts/build-linux-amd64.sh            # dist/linux-amd64/ffmpeg   (same, against this host's glibc)
./scripts/build-windows-amd64.sh          # dist/windows-amd64/ffmpeg.exe
./scripts/build-macos.sh                  # dist/darwin-arm64/ffmpeg (or darwin-amd64)
```

One executable per platform. `rerinku-view` embeds it (the native release
and the Docker image alike) and seeds it into `~/.rerinku/bin/ffmpeg` on every
start; the server never uses a system ffmpeg.

### Hardware encoding (Linux)

Live transcoding (a browser that cannot decode a camera's H.265 gets an H.264
copy) encodes on the GPU when it can: the Linux build carries `h264_vaapi`
(Intel, AMD) and `h264_nvenc` (NVIDIA, through the same nv-codec-headers). With
a VA-API decoder the pictures never leave the GPU (decode, `scale_vaapi`,
encode); software-decoded pictures go up with `hwupload`. `dump_extra`
repeats SPS/PPS before every keyframe, which the hardware encoders write only
once. onboard test-encodes each GPU before using its encoder and falls back
to libx264 when it fails. Windows and macOS still encode with libx264.

### Hardware decoding

On-device analytics decodes on the GPU first (onboard decides; see
`rerinku-view/internal/videodecode`). Every build carries its platform's
API: D3D11VA on Windows and VideoToolbox on macOS, which the OS loads at run
time, and VA-API (Intel, AMD) plus NVDEC (NVIDIA) on Linux.

On Linux the VA drivers (radeonsi, iHD, i965) and NVIDIA's
`libcuda`/`libnvcuvid` are the system's, loaded with `dlopen`, which a fully
static glibc cannot do. So the Linux executable links glibc — and only glibc —
dynamically; x264, opus, libwebp, alsa-lib, libva and libdrm (built from
source) are linked in statically, and NVDEC comes through header-only
nv-codec-headers 11.1 (NVIDIA drivers from 470.57). The glibc it is linked
against is its floor, so releases are built in a Debian 11 container
(`build-linux-amd64-container.sh`, `packaging/linux-build.Dockerfile`): glibc
2.29, below what onboard needs itself. The build prints the floor and fails if
anything but glibc is linked dynamically. A build made directly on a newer
host works there but needs that host's glibc.

Switches:

| Variable | Effect |
|---|---|
| `WITH_X265=1` | Add the libx265 H.265 **encoder** (+5 MB). Decoding H.265 never needs it: the native `hevc` decoder is always built. Needs `libstdc++-<gccver>-dev`. |
| `WITH_HWACCEL=0` | Leave out the hardware decoding APIs (default on). |
| `WITH_ALSA=0` | Drop the `alsa` input device (default on: built from a static alsa-lib). Without it UVC cameras with a USB microphone go video-only, and because the device still advertises audio, WebRTC start waits 8 s for the missing audio track. |
| `DISABLE_ASM=1` | No assembly (only for hosts without `nasm`; several times slower) |
| `SMOKE=0` | Skip the functional smoke test after the build |
| `FORCE_SMOKE=1` | Re-run the smoke test even when build inputs are unchanged |
| `JOBS=n` | Parallelism |

Switches are reflected in the variant name (`linux-amd64-x265`, `linux-amd64-noalsa`, `linux-amd64-nohwaccel`, ...).
Dependencies are rebuilt automatically when their configure arguments change.
`BUILD_ROOT` moves sources, objects and dependencies elsewhere (the container
build uses `.build/container-<image>` so host-built libraries never leak newer
glibc symbols in).

Host requirements (Debian): `build-essential nasm pkg-config curl git cmake
ninja-build python3 bc xz-utils`, plus `libstdc++-14-dev` for `WITH_X265=1`
and a full `ffmpeg` on `PATH` only to generate smoke-test fixtures.

Host requirements (macOS): Xcode Command Line Tools, `pkg-config`, `cmake`,
`ninja`, `python3`, `bc`, `xz`, and a full `ffmpeg` on `PATH` for fixtures.
Homebrew can provide the non-Xcode tools. ALSA is Linux-only and is omitted.

Sources, intermediate objects, fixtures and smoke outputs live under `.build/`.

## Verify

```sh
./scripts/size-report.sh dist/linux-amd64/ffmpeg
./scripts/smoke.sh dist/linux-amd64/ffmpeg
```

## Size

See `docs/OPTIMIZATION.md` for the measured matrix, what each lever bought, and
what is still on the table.

## Notes

- `libx264` is GPL, so the resulting binary is GPL. `libx265` is GPL too.
- Linux no longer has a fully static build: it could not load the system's
  GPU drivers. musl systems (Alpine) are therefore not supported; onboard's
  Docker image is Debian-based for the same reason.
- H.265 support in this binary means: decode for thumbnails, storyboards,
  snapshots and browser transcoding. Encoding to H.265 is an opt-in variant.

Sources:

- FFmpeg download page: https://ffmpeg.org/download.html
- x264 source: https://code.videolan.org/videolan/x264.git
- x265 source: https://github.com/Multicorewareinc/x265.git
- Opus downloads: https://opus-codec.org/downloads/
- libwebp releases: https://storage.googleapis.com/downloads.webmproject.org/releases/webp/index.html
- alsa-lib: https://www.alsa-project.org/files/pub/lib/
