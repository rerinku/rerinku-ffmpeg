# Minimal FFmpeg builds for rerinku-view. See README.md.
#
# Switches are environment variables or make variables, e.g.
#   make linux WITH_X265=1

.DEFAULT_GOAL := help
.PHONY: help linux linux-container windows macos smoke size clean

# The binary smoke and size look at.
BIN ?= dist/linux-amd64/ffmpeg

help:
	@echo "make linux-container  release build of Linux x86-64 in a Debian 11 container (needs docker)"
	@echo "make linux            Linux x86-64 against this host's glibc"
	@echo "make windows          Windows x64, cross-built with mingw-w64"
	@echo "make macos            macOS, on macOS"
	@echo "make smoke [BIN=...]  run the functional test against a binary (default: $(BIN))"
	@echo "make size  [BIN=...]  print the size report of a binary"
	@echo "make clean            remove dist/ and .build/ (sources, objects, fixtures)"

linux:
	./scripts/build-linux-amd64.sh

linux-container:
	./scripts/build-linux-amd64-container.sh

windows:
	./scripts/build-windows-amd64.sh

macos:
	./scripts/build-macos.sh

smoke:
	./scripts/smoke.sh "$(BIN)"

size:
	./scripts/size-report.sh "$(BIN)"

clean:
	rm -rf dist .build
