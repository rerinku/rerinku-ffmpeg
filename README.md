# rerinku-ffmpeg

Minimal FFmpeg builds for `rerinku-onboard`.

FFmpeg and every dependency are locked in `packaging/versions.env`
(FFmpeg 9.0.1 "Lei" as of 2026-09-04).

The executable is trimmed with `--disable-everything` and re-enables only what
the product actually invokes. The authoritative list of those invocations is
`scripts/smoke.sh`: it replays the exact command lines from `rerinku-cli`,
`rerinku-media` and `rerinku-onboard` against a built binary, and the build
fails if any of them stops working.

| Product path | Source | FFmpeg components |
|---|---|---|
| Live MJPEG -> H.264 (WebRTC) | `rerinku-cli/internal/transcode/h264.go` | mjpeg demuxer/decoder, libx264, h264_metadata bsf, h264 muxer |
| Live H.265 -> H.264 (planned, see below) | same shape with `-f hevc` | hevc demuxer/parser/decoder |
| Audio -> Opus / G.711 RTP (WebRTC) | `rerinku-cli/internal/transcode/opus.go` | pcm_s16le/pcm_alaw/pcm_mulaw/aac demuxers+decoders, libopus, pcm_alaw/pcm_mulaw encoders, aresample, rtp muxer, udp |
| Audio -> AAC ADTS (HLS recordings) | `rerinku-media/transcode/aac.go` | ogg demuxer + libopus decoder, aac encoder, adts muxer |
| MJPEG recording -> H.264 fMP4 | `rerinku-media/recording/ffmpeg.go` | libx264, mp4 muxer |
| Recording thumbnails (H.264/H.265 fMP4 -> JPEG) | `rerinku-onboard/internal/recording/thumbnail.go` | mov demuxer, h264/hevc decoders, scale, mjpeg encoder, image2pipe |
| Recording storyboards (-> WebP) | `rerinku-onboard/internal/recording/storyboard.go` | tpad/fps/scale/pad/tile filters, libwebp, webp muxer |
| Device snapshot (raw H.264 -> JPEG) | `rerinku-onboard/internal/device/framegrab.go` | h264 demuxer/decoder, mjpeg encoder |
| UVC USB microphone capture | `rerinku-cli/internal/uvc/audio_linux.go` | alsa input device (static alsa-lib), pcm_s16le encoder + muxer |

## Build

```sh
./scripts/build-linux-amd64.sh    # dist/linux-amd64/ffmpeg
./scripts/build-macos.sh          # dist/darwin-arm64/ffmpeg (or darwin-amd64)
```

Linux output is one fully static executable (glibc linked in). macOS output
statically links the codec libraries and only dynamically links Apple system
libraries. `rerinku-onboard` embeds the matching platform build and seeds it
into `~/.rerinku/bin/ffmpeg` on every start; the server never uses a system
ffmpeg.

Switches:

| Variable | Effect |
|---|---|
| `WITH_X265=1` | Add the libx265 H.265 **encoder** (+5 MB). Decoding H.265 never needs it: the native `hevc` decoder is always built. Needs `libstdc++-<gccver>-dev`. |
| `WITH_ALSA=0` | Drop the `alsa` input device (default on: built from a static alsa-lib). Without it UVC cameras with a USB microphone go video-only, and because the device still advertises audio, WebRTC start waits 8 s for the missing audio track. |
| `DISABLE_ASM=1` | No assembly (only for hosts without `nasm`; several times slower) |
| `SMOKE=0` | Skip the functional smoke test after the build |
| `FORCE_SMOKE=1` | Re-run the smoke test even when build inputs are unchanged |
| `JOBS=n` | Parallelism |

Switches are reflected in the variant name (`linux-amd64-x265`, `linux-amd64-noalsa`, ...).
Dependencies are rebuilt automatically when their configure arguments change.
The Linux build fails if the result is not fully statically linked.

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
- The glibc static build may warn about `getaddrinfo`; the product only ever
  targets numeric loopback addresses, so this is harmless. A musl build in a
  container is the portable long-term answer (see the optimisation doc).
- H.265 support in this binary means: decode for thumbnails, storyboards,
  snapshots and browser transcoding. Encoding to H.265 is an opt-in variant.

Sources:

- FFmpeg download page: https://ffmpeg.org/download.html
- x264 source: https://code.videolan.org/videolan/x264.git
- x265 source: https://github.com/Multicorewareinc/x265.git
- Opus downloads: https://opus-codec.org/downloads/
- libwebp releases: https://storage.googleapis.com/downloads.webmproject.org/releases/webp/index.html
- alsa-lib: https://www.alsa-project.org/files/pub/lib/
