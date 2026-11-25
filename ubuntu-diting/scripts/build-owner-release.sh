#!/bin/bash
# Pack the owner image from the owner rootfs (ROOTFS_PROFILE=owner
# build-rootfs.sh). `make owner-release` builds that rootfs first; run it
# after `make sensors libcamera phoc`, so that the image has every local
# package (the owner rootfs of `make rootfs` alone is only the base of those
# three builds). What comes out is what build-release.sh makes for the
# public image, in output/owner/ instead of a release archive: the boot
# images that the kernel package generated inside the rootfs, the root
# filesystem as an Android sparse image, the package list. Not compressed
# here: ci/pack-artifacts.sh does that for the CI artifact. The account is
# locked and sshd accepts keys only, and a CI runner has no key to put in,
# so the image cannot be logged in to until release/add-ssh-key.sh puts one
# in: a local step, on the machine the artifact is downloaded to.
#
#   build-owner-release.sh      (into output/owner/)
. "$(dirname "$0")/lib.sh"
need img2simg python3

ROOT="$WORK/rootfs"
IMG="$OUT/ubuntu-diting-rootfs-$UBUNTU_SUITE-arm64.img"
DIR="$OUT/owner"

[ -f "$IMG" ] || die "missing $IMG (ROOTFS_PROFILE=owner make rootfs)"
[ -f "$ROOT/etc/diting-build" ] || die "missing $ROOT (owner rootfs tree)"
boot="$ROOT/boot/diting/boot-$KERNEL_RELEASE.img"
vboot="$ROOT/boot/diting/vendor_boot-$KERNEL_RELEASE.img"
[ -f "$boot" ] && [ -f "$vboot" ] || die "no boot images for $KERNEL_RELEASE in $ROOT/boot/diting"

log "checking the boot images"
if [ -d "$DEVICE_DATA/images" ]; then
	"$UD/scripts/verify-boot-image.sh" "$boot" "$vboot" || die "boot image check failed"
else
	warn "no stock images in $DEVICE_DATA/images: header comparison skipped"
fi
grep -q "root=PARTLABEL=userdata" <<<"$(python3 "$UD/scripts/bootimg_info.py" "$vboot")" ||
	die "vendor_boot command line does not mount userdata"

rm -rf "$DIR" && mkdir -p "$DIR"
cp "$boot" "$DIR/boot.img"
cp "$vboot" "$DIR/vendor_boot.img"
log "sparse image of $IMG"
img2simg "$IMG" "$DIR/rootfs.img"
cp "$ROOT/etc/diting-build" "$DIR/BUILD-INFO"
cp "$OUT/rootfs-packages-$UBUNTU_SUITE.tsv" "$DIR/PACKAGES.tsv"
log "owner image in $DIR (UNTESTED ON DEVICE; release/add-ssh-key.sh puts the SSH key in when the build host had none)"
