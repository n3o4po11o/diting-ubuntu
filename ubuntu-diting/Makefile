# Xiaomi Diting: Ubuntu arm64 on upstream stable Linux.
# See README.md. Nothing in here flashes or boots the phone.

S := scripts
SUDO ?= sudo -E

.PHONY: help modemmanager phosh check-host sources reference references check-latest-kernel update-kernel kernel dtbs phoc sensors libcamera \
	dtbs-check packages vaapi qcom-va-driver ffmpeg firmware-setup mobile-config-firefox cellular-settings firmware rootfs release owner-release initramfs boot image verify \
	repro-check qemu-test inspect-device lint clean distclean

help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)

## check-host           verify host tools
check-host:
	$(S)/check-host.sh
## sources              fetch the locked kernel only (signature-checked)
sources:
	$(S)/fetch-sources.sh
## reference NAME=x     fetch one tree under references/ by name (a build fetches what it needs itself)
reference:
	$(S)/fetch-sources.sh --ref $(NAME)
## references          the trees under references/ that are only read, all of them
references:
	$(S)/fetch-sources.sh --references
## check-latest-kernel  compare kernel.lock with kernel.org (read-only)
check-latest-kernel:
	$(S)/check-latest-kernel.sh
## update-kernel        deliberately move kernel.lock to the newest stable
update-kernel:
	$(S)/update-kernel.sh
## kernel               Image, DTBs, modules and linux-*.deb (bindeb-pkg)
kernel:
	$(S)/build-kernel.sh
## dtbs                 build only the Diting DTB
dtbs:
	$(S)/build-dtbs.sh
## dtbs-check           dtbs_check/dt_binding_check for the Diting DTB
dtbs-check:
	$(S)/build-dtbs.sh --check
## packages             device-xiaomi-diting, fastrpc-diting, hexagonrpcd-diting debs (arm64 host)
packages:
	$(S)/build-packages.sh
	$(S)/build-fastrpc.sh
	$(S)/build-hexagonrpc.sh
## vaapi                libva-v4l2-stateful (VA-API driver for the iris decoder; arm64 buildd chroot)
vaapi:
	$(S)/build-libva-v4l2-stateful.sh
## qcom-va-driver     qcom-va-driver, the VA-API encoder over the iris encoder, and its tests; next to vaapi, picked with LIBVA_DRIVER_NAME=qcom (arm64 buildd chroot)
qcom-va-driver:
	$(S)/build-qcom-va-driver.sh
## ffmpeg              ffmpeg + ffprobe with the V4L2 patches, for /usr/local/bin of the rootfs (ci/FFMPEG.md)
ffmpeg:
	$(S)/fetch-sources.sh --ffmpeg
	$(S)/build-ffmpeg.sh
## phosh                Ubuntu phosh + screen stays off on automatic wake-ups (arm64 buildd chroot)
phosh:
	$(S)/build-phosh.sh
## modemmanager         Ubuntu ModemManager + upstream netlink crash fix (arm64 buildd chroot)
modemmanager:
	$(S)/build-modemmanager.sh
## mobile-config-firefox  postmarketOS Firefox mobile UI (not in Ubuntu; arm64 buildd chroot)
mobile-config-firefox:
	$(S)/build-mobile-config-firefox.sh
## firmware-setup       diting-firmware-setup (first-boot firmware extraction; arm64 buildd chroot)
firmware-setup:
	$(S)/build-firmware-setup.sh
## cellular-settings   Cellular Settings, Rust + GTK 4 (ci/Dockerfile.cellular-settings; without docker, the arm64 buildd chroot)
cellular-settings:
	$(S)/build-cellular-settings.sh
## firmware             firmware package from owner-supplied blobs (local only)
firmware:
	$(S)/build-firmware.sh
## sensors              libssc-diting + iio-sensor-proxy 3.9 with SSC (needs an existing rootfs, arm64 host)
sensors:
	$(S)/build-sensors.sh
## libcamera            Ubuntu libcamera + diting sensor support (needs an existing rootfs, arm64 host)
libcamera:
	$(S)/build-libcamera.sh
## phoc                 Ubuntu phoc + refresh-rate fix (needs an existing rootfs, arm64 host)
phoc:
	$(S)/build-phoc.sh
## rootfs               Ubuntu rootfs + ext4 image (needs root, uses sudo; ROOTFS_PROFILE=owner|public)
rootfs: kernel packages vaapi ffmpeg firmware-setup mobile-config-firefox cellular-settings modemmanager phosh
	$(SUDO) $(S)/build-rootfs.sh
## initramfs            regenerate the initramfs inside the rootfs (initramfs-tools)
initramfs:
	$(SUDO) $(S)/build-initramfs.sh
## boot                 boot/vendor_boot/dtbo images (BOOT_MODE=debug|rootfs)
boot:
	$(S)/build-boot-image.sh
## image                full chain: kernel packages rootfs boot
image: rootfs
	$(S)/build-boot-image.sh
	$(S)/verify.sh
## release              public image (no firmware, default PIN) + boot images, packed for download
release:
	ROOTFS_PROFILE=public $(SUDO) $(S)/build-rootfs.sh
	$(S)/build-release.sh
## owner-release       owner image (locked account, build host's SSH key) with every local package:
##                      the rootfs again, after make sensors libcamera phoc (needs root)
owner-release:
	$(SUDO) $(S)/build-rootfs.sh
	$(S)/build-owner-release.sh
## repro-check          second full kernel build, compare bit for bit (slow)
repro-check:
	$(S)/check-reproducible.sh
## qemu-test            boot kernel + rootfs image in QEMU (emulator only, not the phone)
qemu-test:
	$(S)/qemu-test.sh
## verify               non-destructive checks of all generated artifacts
verify:
	$(S)/verify.sh
## inspect-device       read-only adb dump of boot images/partition info
inspect-device:
	$(S)/inspect-device.sh
## lint                 shellcheck + git diff --check
lint:
	shellcheck -x $(S)/*.sh packages/device-xiaomi-diting/src/* packages/cellular-settings/src/cellular-settings-write-modem-mode \
		packages/device-xiaomi-diting/initramfs-tools/hooks/* \
		packages/device-xiaomi-diting/initramfs-tools/scripts/init-top/* \
		packages/device-xiaomi-diting/etc/zz-diting-bootimg
	cd .. && git diff --check
## clean                remove work/ (keeps output/ and downloads)
clean:
	$(SUDO) rm -rf work
## distclean            remove work/ and output/
distclean: clean
	rm -rf output
