#!/bin/bash
# Non-destructive verification of all generated artifacts. Runs only on the
# host; does not need or touch the phone. Exit status != 0 on any FAIL.
. "$(dirname "$0")/lib.sh"
fail=0 n=0
pass() { echo "PASS $*"; n=$((n + 1)); }
bad()  { echo "FAIL $*"; fail=1; n=$((n + 1)); }
skip() { echo "SKIP $*"; }
t() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else bad "$d"; fi; }

echo "== kernel"
t "kernel.lock commit matches tag in checkout" \
	test "$(git -C "$KERNEL_GIT" rev-parse "$KERNEL_TAG^{commit}" 2>/dev/null)" = "$KERNEL_COMMIT"
if [ -f "$KERNEL_SRC/Makefile" ]; then
	v="$(sed -n 's/^VERSION = //p;s/^PATCHLEVEL = //p;s/^SUBLEVEL = //p' "$KERNEL_SRC/Makefile" | paste -sd.)"
	t "source Makefile version $v = $KERNEL_VERSION" test "$v" = "$KERNEL_VERSION"
	t "source tree matches lock+patches+config" test "$(cat "$KERNEL_SRC/.diting-stamp")" = "$(patches_digest)"
fi
img="$OUT/kernel/Image-$KERNEL_RELEASE"
if [ -f "$img" ]; then
	t "Image is arm64 (ARMd magic)" test "$(od -An -tx1 -j56 -N4 "$img" | tr -d ' ')" = 41524d64
	t "kernel release string in Image" grep -qa "Linux version $KERNEL_RELEASE " "$img"
	t "Diting DTB built" test -s "$OUT/kernel/$(basename "$KERNEL_DTB")"
	t "DTB compatible xiaomi,diting" sh -c "fdtget -ts '$OUT/kernel/$(basename "$KERNEL_DTB")' / compatible | grep -q xiaomi,diting"
	deb="$(ls "$OUT"/debs/linux-image-"$KERNEL_RELEASE"_*.deb 2>/dev/null | head -1)"
	if [ -n "$deb" ]; then
		c="$(dpkg-deb -c "$deb")"
		t "linux-image deb has /lib/modules/$KERNEL_RELEASE" grep -q "lib/modules/$KERNEL_RELEASE/kernel/" <<<"$c"
		t "linux-image deb has modules from one release only" test "$(grep -o 'lib/modules/[^/]*/' <<<"$c" | sort -u | wc -l)" = 1
		t "linux-image deb ships the Diting DTB" grep -q "linux-image-$KERNEL_RELEASE/$KERNEL_DTB" <<<"$c"
		t "linux-image deb ships config and System.map" grep -q "boot/config-$KERNEL_RELEASE" <<<"$c"
		t "built-in UFS QCOM driver" grep -qx 'CONFIG_SCSI_UFS_QCOM=y' "$OUT/kernel/config-$KERNEL_RELEASE"
	else bad "linux-image-$KERNEL_RELEASE deb missing"; fi
else skip "kernel not built"; fi

echo "== device package"
dp="$(ls "$OUT"/debs/device-xiaomi-diting_*_all.deb 2>/dev/null | head -1)"
if [ -n "$dp" ]; then
	t "device package metadata" dpkg-deb -I "$dp"
	c="$(dpkg-deb -c "$dp")"
	for f in usr/sbin/diting-mkbootimg etc/kernel/postinst.d/zz-diting-bootimg \
		usr/share/initramfs-tools/scripts/init-top/diting-debug etc/diting/bootimg.conf \
		usr/lib/diting/diting-bt-setup usr/lib/systemd/system/diting-bt-setup.service; do
		t "device package contains $f (executable or config)" grep -q "\./$f" <<<"$c"
	done
	# Every boot image built on the server leaves the Bluetooth controller
	# unconfigured; only the service bound to hci0 gives it its address then.
	t "diting-bt-setup.service executable in the package" grep -q "^-rwxr-xr-x.*\./usr/lib/diting/diting-bt-setup\$" <<<"$c"
	# A file missing from the package must cost one FAIL, not abort the run
	# (verify.sh runs under set -euo pipefail).
	in_deb() { dpkg-deb --fsys-tarfile "$dp" | tar -xO "./$1" 2>/dev/null || true; }
	pt="$(in_deb usr/lib/systemd/system-preset/10-diting.preset)"
	un="$(in_deb usr/lib/systemd/system/diting-bt-setup.service)"
	t "preset enables diting-bt-setup.service" grep -qx 'enable diting-bt-setup.service' <<<"$pt"
	t "diting-bt-setup.service is bound to the hci0 device unit" \
		grep -qx 'BindsTo=sys-subsystem-bluetooth-devices-hci0.device' <<<"$un"
	t "diting-bt-setup.service has a start timeout" grep -qx 'TimeoutStartSec=[0-9][0-9a-z.]*' <<<"$un"
	if command -v lintian >/dev/null; then
		lintian --no-tag-display-limit "$dp" > "$OUT/logs/lintian-device.txt" 2>&1 || true
		echo "INFO lintian: $(grep -c '^E:' "$OUT/logs/lintian-device.txt") errors, $(grep -c '^W:' "$OUT/logs/lintian-device.txt") warnings (output/logs/lintian-device.txt)"
	fi
else skip "device package not built"; fi

echo "== rootfs"
rimg="$OUT/ubuntu-diting-rootfs-$UBUNTU_SUITE-arm64.img"
# prefer the public image: it is the artifact that gets flashed
[ -f "${rimg%.img}-public.img" ] && rimg="${rimg%.img}-public.img"
if [ -f "$rimg" ]; then
	rd() { debugfs -R "cat $1" "$rimg" 2>/dev/null; }
	# debugfs does not follow symlinks, and /etc/os-release is one
	osr="$(rd /usr/lib/os-release)"
	t "os-release ID=ubuntu" grep -qx 'ID=ubuntu' <<<"$osr"
	t "os-release VERSION_CODENAME=$UBUNTU_SUITE" grep -qx "VERSION_CODENAME=$UBUNTU_SUITE" <<<"$osr"
	t "os-release VERSION_ID=$UBUNTU_VERSION_ID" grep -qx "VERSION_ID=\"$UBUNTU_VERSION_ID\"" <<<"$osr"
	st="$(rd /var/lib/dpkg/status)"
	dpkg_arch="$(awk '/^Package: dpkg$/{f=1;next} f&&/^Package:/{f=0} f&&/^Architecture:/{print;exit}' <<<"$st")"
	t "dpkg architecture arm64 (dpkg itself)" test "$dpkg_arch" = "Architecture: arm64"
	t "systemd-sysv installed (systemd is init)" grep -qx 'Package: systemd-sysv' <<<"$st"
	# the initramfs fsck hook copies these from the rootfs; a missing
	# e2fsprogs here means the next initramfs silently loses root fsck
	t "e2fsprogs installed (root fsck binaries source)" grep -qx 'Package: e2fsprogs' <<<"$st"
	t "local linux-image-$KERNEL_RELEASE installed" grep -qx "Package: linux-image-$KERNEL_RELEASE" <<<"$st"
	t "device-xiaomi-diting installed" grep -qx 'Package: device-xiaomi-diting' <<<"$st"
	t "cellular-settings installed" grep -qx 'Package: cellular-settings' <<<"$st"
	# Cellular Settings: its program, the helper that writes the file for the
	# next boot (polkit runs it as root: it must stay executable), its launcher,
	# its polkit action, and the Chinese catalog
	t "/usr/bin/cellular-settings is in the image, mode 755" sh -c "debugfs -R 'stat /usr/bin/cellular-settings' '$rimg' 2>&1 | grep -q 'Type: regular.*Mode:  *0755 '"
	t "/usr/libexec/cellular-settings-write-modem-mode is in the image, mode 755" sh -c "debugfs -R 'stat /usr/libexec/cellular-settings-write-modem-mode' '$rimg' 2>&1 | grep -q 'Type: regular.*Mode:  *0755 '"
	t "cellular-settings launcher is in the image" sh -c "debugfs -R 'stat /usr/share/applications/io.github.n3o4po11o.cellular-settings.desktop' '$rimg' 2>&1 | grep -q 'Type: regular'"
	t "cellular-settings polkit action is in the image" sh -c "debugfs -R 'stat /usr/share/polkit-1/actions/io.github.n3o4po11o.cellular-settings.policy' '$rimg' 2>&1 | grep -q 'Type: regular'"
	t "cellular-settings Chinese catalog is in the image" sh -c "debugfs -R 'stat /usr/share/locale/zh_CN/LC_MESSAGES/cellular-settings.mo' '$rimg' 2>&1 | grep -q 'Type: regular'"
	t "no generic Ubuntu kernel installed" sh -c '! grep -q "^Package: linux-image-.*-generic"' <<<"$st"
	t "no apk/OpenRC in rootfs" sh -c '! grep -qE "^Package: (apk-tools|openrc)$"' <<<"$st"
	t "apt sources signed official ports archive" sh -c "debugfs -R 'cat /etc/apt/sources.list.d/ubuntu.sources' '$rimg' 2>/dev/null | grep -q 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'"
	t "initramfs for $KERNEL_RELEASE present" sh -c "debugfs -R 'stat /boot/initrd.img-$KERNEL_RELEASE' '$rimg' 2>&1 | grep -q 'Type: regular'"
	t "modules.dep for $KERNEL_RELEASE present" sh -c "debugfs -R 'stat /usr/lib/modules/$KERNEL_RELEASE/modules.dep' '$rimg' 2>&1 | grep -q 'Type: regular'"
	# The VA-API driver opens only /dev/video0 or /dev/video-dec0: without this
	# rule the browsers decode in software whenever the cameras register first
	t "udev rule naming the iris decoder /dev/video-dec0 is in the image" sh -c "debugfs -R 'stat /usr/lib/udev/rules.d/70-diting-iris-decoder.rules' '$rimg' 2>&1 | grep -q 'Type: regular'"
	t "on-device boot images generated by hook" sh -c "debugfs -R 'ls /boot/diting' '$rimg' 2>/dev/null | grep -q 'vendor_boot-$KERNEL_RELEASE.img'"
	# The ffmpeg and ffprobe (make ffmpeg) are files, not a package: dpkg's
	# status does not list them. They are linked against the libraries of
	# the release; every package of those has to be installed in the image.
	for b in ffmpeg ffprobe; do
		# debugfs prints the mode as a four-digit octal number: "Mode:  0755"
		t "/usr/local/bin/$b is in the image, mode 755" sh -c "debugfs -R 'stat /usr/local/bin/$b' '$rimg' 2>&1 | grep -q 'Type: regular.*Mode:  *0755 '"
	done
	vf="$(mktemp -d)"
	if debugfs -R "dump /usr/local/bin/ffmpeg $vf/ffmpeg" "$rimg" >/dev/null 2>&1 && [ -s "$vf/ffmpeg" ]; then
		# an ELF executable for AArch64 with an interpreter: dynamically linked
		t "/usr/local/bin/ffmpeg is an arm64 executable" python3 - "$vf/ffmpeg" <<'PY'
import struct, sys
try:
    f = open(sys.argv[1], 'rb'); eh = f.read(64)
    ok = eh[:6] == b'\x7fELF\x02\x01' and struct.unpack_from('<H', eh, 18)[0] == 183
    phoff = struct.unpack_from('<Q', eh, 32)[0]
    size, num = struct.unpack_from('<HH', eh, 54)
    f.seek(phoff); ph = f.read(size * num)
    types = {struct.unpack_from('<I', ph, i * size)[0] for i in range(num)}
    sys.exit(0 if ok and 3 in types else 1)   # PT_INTERP
except (struct.error, OSError):
    sys.exit(1)
PY
		[ ! -f "$OUT/ffmpeg/ffmpeg" ] ||
			t "/usr/local/bin/ffmpeg is the one make ffmpeg built" cmp -s "$vf/ffmpeg" "$OUT/ffmpeg/ffmpeg"
		if [ -f "$OUT/ffmpeg/runtime-packages.txt" ]; then
			ff_missing=0
			while read -r p; do grep -qx "Package: $p" <<<"$st" || ff_missing=$((ff_missing + 1)); done <"$OUT/ffmpeg/runtime-packages.txt"
			t "every package the ffmpeg needs at run time is installed ($(grep -c . "$OUT/ffmpeg/runtime-packages.txt"))" test "$ff_missing" = 0
		fi
	else bad "/usr/local/bin/ffmpeg could not be read from the image"; fi
	rm -rf "$vf"
	t "ext4 filesystem clean" e2fsck -fn "$rimg"
else skip "rootfs image not built"; fi

echo "== boot images"
found=0
for b in "$OUT"/boot/boot-diting-ubuntu-*.img; do
	[ -f "$b" ] || continue
	found=1
	v="${b/\/boot-/\/vendor_boot-}"
	if "$UD/scripts/verify-boot-image.sh" "$b" "$v" > "$OUT/logs/verify-$(basename "$b").txt" 2>&1; then
		pass "boot pair $(basename "$b")"
	else
		bad "boot pair $(basename "$b") (see output/logs/verify-$(basename "$b").txt)"
	fi
	# Ramdisk content: the root fstab demands a pass-1 fsck and the boot
	# relies on the serial rescue hook, so both must be inside the
	# vendor_boot ramdisk. This catches the build flake where the fsck
	# hook cannot resolve the LABEL=diting-root fstab entry and silently
	# ships an initramfs that dies waiting for a root fsck it cannot run.
	if [ -f "$v" ]; then
		rdlist="$OUT/logs/ramdisk-list-$(basename "$b").txt"
		tmp="$(mktemp -d)"
		if python3 - "$v" "$tmp/rd.zst" <<'PY' 2>/dev/null && zstd -dc "$tmp/rd.zst" 2>/dev/null | cpio -it > "$rdlist" 2>/dev/null
import struct, sys
d = open(sys.argv[1], 'rb').read()
rdsz = struct.unpack('<I', d[0x18:0x1c])[0]
open(sys.argv[2], 'wb').write(d[4096:4096 + rdsz])
PY
		then
			t "ramdisk $(basename "$b") has root fsck binaries" \
				sh -c "grep -q '^usr/sbin/e2fsck\$' '$rdlist' && grep -q '^usr/sbin/fsck\$' '$rdlist'"
			t "ramdisk $(basename "$b") has serial rescue hook" \
				grep -q '^scripts/init-top/diting-debug$' "$rdlist"
		else
			bad "ramdisk $(basename "$b") could not be unpacked for content checks"
		fi
		rm -rf "$tmp"
	fi
done
[ "$found" = 1 ] || skip "no boot images built"

# Manifest: checksums and a human-readable build report
(cd "$OUT" && find . -type f \( -name '*.deb' -o -name '*.img' -o -path './kernel/*' \) \
	-printf '%P\n' | sort | xargs -r sha256sum > MANIFEST.sha256)
# the ffmpeg of the rootfs is in the manifest too when it was built here
[ ! -d "$OUT/ffmpeg" ] || (cd "$OUT" && find ffmpeg -type f | sort | xargs -r sha256sum >> MANIFEST.sha256)
{
	echo "ubuntu-diting build report, $(date -u +%FT%TZ)"
	echo "kernel: $KERNEL_VERSION ($KERNEL_TAG, commit $KERNEL_COMMIT, signer $KERNEL_TAG_SIGNER_FPR)"
	echo "release: $KERNEL_RELEASE; patches:"
	for p in "$KERNEL_PATCHES"/*.patch; do echo "  $(basename "$p") $(sha256_of "$p")"; done
	echo "config fragment: $(sha256_of "$KERNEL_FRAGMENT")"
	echo "ubuntu: $UBUNTU_SUITE from $UBUNTU_MIRROR"
	echo "ffmpeg: $FFMPEG_TAG (commit $FFMPEG_COMMIT) with packages/ffmpeg-diting, linked against $UBUNTU_SUITE, in /usr/local/bin of the rootfs"
	echo "verify: $n checks, $([ $fail = 0 ] && echo all passed || echo FAILURES)"
	echo "device status: UNTESTED ON DEVICE"
} > "$OUT/MANIFEST.txt"

echo "== result: $n checks, $([ $fail = 0 ] && echo all passed || echo FAILURES)"
echo "Note: these are host-side checks only; nothing here proves the phone boots."
exit $fail
