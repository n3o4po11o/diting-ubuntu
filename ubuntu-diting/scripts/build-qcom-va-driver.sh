#!/bin/bash
# Build qcom-va-driver: the VA-API driver with an encoder over the iris video
# core (docs/VIDEO_ENCODE.md) - upstream qcom-va-driver at the commit pinned
# in config/diting.conf, plus packages/qcom-va-driver/patches/*.patch - as two
# local Debian packages, in the arm64 buildd chroot (lib-buildd.sh). Needs sudo.
#
#   make qcom-va-driver                       (needs sudo, for the chroot)
#   ci/ffmpeg.sh make qcom-va-driver          in the privileged container on the build server (ci/FFMPEG.md)
#
# What comes out, in output/debs/:
#   qcom-va-driver_*.deb          qcom_drv_video.so, and msm_drv_video.so as a
#                                 link to it: the name libva derives from the
#                                 msm DRM driver, so this is the default driver
#                                 (encoder and decoders) and no program needs
#                                 LIBVA_DRIVER_NAME. libva-v4l2-stateful keeps
#                                 the v4l2 name for snap Chromium's own copy.
#   qcom-va-driver-tests_*.deb    the hardware tests of upstream, for the phone;
#                                 they open the default driver
# The build log is output/logs/qcom-va-driver-build.log.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib-buildd.sh"
need git tar

UPSTREAM="$DITING_TOP/references/qcom-va-driver"
UPSTREAM_COMMIT="$QCOM_VA_DRIVER_COMMIT"
PKG="$UD/packages/qcom-va-driver"

have_ref qcom-va-driver "$QCOM_VA_DRIVER_URL" "$UPSTREAM_COMMIT"

shopt -s nullglob
patches=("$PKG"/patches/*.patch)
shopt -u nullglob

log "preparing source (upstream ${UPSTREAM_COMMIT:0:7} + ${#patches[@]} patch(es))"
src="$WORK/qcom-va-driver-pkg"
rm -rf "$src" && mkdir -p "$src"
git -C "$UPSTREAM" archive --format=tar "$UPSTREAM_COMMIT" | tar -x -C "$src"
rm -rf "$src/debian"
cp -a "$PKG/debian" "$src/debian"
if [ ${#patches[@]} -gt 0 ]; then
	mkdir -p "$src/debian/patches"
	for p in "${patches[@]}"; do
		cp "$p" "$src/debian/patches/"
		basename "$p" >> "$src/debian/patches/series"
	done
fi

buildd_setup
buildd_build "$src" qcom-va-driver meson ninja-build pkgconf libva-dev libdrm-dev quilt
