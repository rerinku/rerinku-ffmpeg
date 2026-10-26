# Toolchain for the Linux FFmpeg release build (scripts/build-linux-amd64-container.sh).
# The base decides the oldest glibc the binary runs on; nothing from it ends up
# in the binary besides that glibc dependency.
ARG BASE_IMAGE=debian:bullseye
FROM ${BASE_IMAGE}
# Debian 11 is past its LTS and its pools are being withdrawn from
# deb.debian.org. Official images list snapshot.debian.org at the image's own
# date (commented out): use those, which also pins the toolchain.
RUN if grep -q '^# deb http://snapshot' /etc/apt/sources.list 2>/dev/null; then \
		sed -i -e 's|^deb http://deb.debian.org|# deb http://deb.debian.org|' \
			-e 's|^# deb http://snapshot|deb http://snapshot|' /etc/apt/sources.list; \
	fi \
	&& apt-get -o Acquire::Check-Valid-Until=false update \
	&& DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends \
		build-essential nasm pkg-config ninja-build curl ca-certificates git python3 python3-distutils \
		xz-utils bzip2 file binutils \
	&& rm -rf /var/lib/apt/lists/*
