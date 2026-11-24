# Build environment for ubuntu-diting: the Debian 13 host toolchain of
# docs/BUILD.md in one image, so that a build can be repeated later.
#
#   docker build -t diting-builder:$REV --build-arg VCS_REF=$REV ubuntu-diting/ci
#   docker run --rm --privileged --network=host \
#       -v "$REPO:/src" -v "$LOGS:/logs" -w /src/ubuntu-diting \
#       -e JOBS="$(nproc)" -e FROMZERO_LOGDIR=/logs \
#       diting-builder:$REV ci/build-fromzero.sh
#
# --privileged: build-rootfs.sh and the package chroots bind-mount /proc,
# /sys and /dev and chroot into them. --network=host: apt and git use the
# host's resolver and network as they are. The base image is pinned by the
# multi-arch index digest; /usr/share/diting-builder-packages.tsv inside the
# image lists what it contains.
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

ARG DEBIAN_FRONTEND=noninteractive
ARG VCS_REF=unknown

# scripts/check-host.sh and docs/BUILD.md, plus what the scripts need in a
# container: sudo (they call it; as root it asks for no password), and the
# kernel package's build dependencies, which bindeb-pkg enforces through the
# dpkg database on a Debian host (build-essential:native among them; the
# individual gcc and make are not enough). Also meson/ninja for hexagonrpcd,
# the autotools and libyaml for fastrpc on arm64, img2simg for `make release`.
RUN apt-get update && apt-get install -y --no-install-recommends \
		ca-certificates sudo tzdata \
		build-essential bc bison flex binutils libssl-dev libelf-dev libdw-dev dwarves \
		python3 kmod cpio rsync xz-utils zstd lz4 patch \
		git gnupg curl \
		device-tree-compiler mkbootimg android-sdk-libsparse-utils \
		dpkg-dev debhelper fakeroot debootstrap ubuntu-keyring \
		e2fsprogs alsa-utils m4 \
		meson ninja-build autoconf automake libtool pkg-config libyaml-dev libbsd-dev \
		shellcheck \
# Other architectures: the kernel is cross-built and the arm64 chroots run
# under qemu-user (lib-buildd.sh needs the host's binfmt_misc entry).
	&& if [ "$(dpkg --print-architecture)" != arm64 ]; then \
		apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu qemu-user-static binfmt-support; \
	fi \
	&& rm -rf /var/lib/apt/lists/* \
# The checkout is bind-mounted from the host and owned by another user.
	&& git config --system --add safe.directory '*'

# What the image contains, for the build record.
RUN dpkg-query -W -f='${Package}\t${Version}\n' > /usr/share/diting-builder-packages.tsv

LABEL org.opencontainers.image.title="diting-builder" \
	org.opencontainers.image.description="Build environment for ubuntu-diting (Debian 13, docs/BUILD.md)" \
	org.opencontainers.image.revision="${VCS_REF}"

WORKDIR /src/ubuntu-diting
CMD ["bash"]
