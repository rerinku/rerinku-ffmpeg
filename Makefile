# Minimal FFmpeg builds for rerinku-view. See README.md.
#
# Switches are environment variables or make variables, e.g.
#   make linux WITH_X265=1

.DEFAULT_GOAL := help
.PHONY: help linux linux-container linux-container-amd64 linux-container-arm64 windows windows-amd64 windows-arm64 macos smoke size clean

# The binary smoke and size look at.
BIN ?= dist/linux-amd64/ffmpeg

help:
	@echo "make linux-container  release builds of Linux x86-64 and ARM64 in Debian 11 containers (needs docker;"
	@echo "                      ARM64 runs under QEMU on an x86-64 host: linux-container-amd64 / -arm64 for one)"
	@echo "make linux            Linux, this host's architecture, against this host's glibc"
	@echo "make windows          Windows x64 and ARM64, cross-built (windows-amd64 / windows-arm64 for one)"
	@echo "make macos            macOS, on macOS"
	@echo "make smoke [BIN=...]  run the functional test against a binary (default: $(BIN))"
	@echo "make size  [BIN=...]  print the size report of a binary"
	@echo "make clean            remove dist/ and .build/ (sources, objects, fixtures)"

linux:
	RERINKU_BUILD_PLATFORM=linux-$$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/') ./scripts/build-linux-amd64.sh

linux-container: linux-container-amd64 linux-container-arm64

linux-container-amd64:
	PLATFORM=amd64 ./scripts/build-linux-amd64-container.sh

linux-container-arm64:
	PLATFORM=arm64 ./scripts/build-linux-amd64-container.sh

windows: windows-amd64 windows-arm64

windows-amd64:
	./scripts/build-windows-amd64.sh

windows-arm64:
	./scripts/build-windows-arm64.sh

macos:
	./scripts/build-macos.sh

smoke:
	./scripts/smoke.sh "$(BIN)"

size:
	./scripts/size-report.sh "$(BIN)"

clean:
	rm -rf dist .build
