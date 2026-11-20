#!/bin/bash
# Build fastrpc-diting: Qualcomm's FastRPC userspace (BSD-3-Clause) at the
# pinned commit, for adsprpcd (the ADSP audio PD that loads the voice call's
# dynamic modules). Ubuntu does not package it. Natively on an arm64 host,
# in the arm64 buildd chroot (qemu-user) elsewhere; libyaml is a build and
# runtime dependency, so it is in Depends.
. "$(dirname "$0")/lib.sh"
need dpkg-deb autoreconf libtoolize make gcc

PKG=fastrpc-diting
SRC="$DITING_TOP/references/fastrpc"
[ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" = "$FASTRPC_COMMIT" ] ||
	die "need $SRC at $FASTRPC_COMMIT (make sources)"
build_native() {
	(cd "$b/src" && sh ./autogen.sh && ./configure --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu &&
		make -j"$(nproc)" && make install DESTDIR="$b/root") > "$OUT/logs/fastrpc-build.log" 2>&1
}
build_emulated() {
	# arm64 buildd chroot under qemu-user (as the other emulated package
	# builds): the bare cross toolchain cannot satisfy the libyaml build
	# dependency, the chroot installs it with apt.
	. "$UD/scripts/lib-buildd.sh"
	buildd_setup
	sudo rm -rf "$CH/build/fastrpc" "$CH/build/fastrpc-root"
	sudo mkdir -p "$CH/build/fastrpc"
	sudo cp -a "$b/src/." "$CH/build/fastrpc/"
	inch apt-get -y -q install --no-install-recommends autoconf automake libtool \
		pkg-config libyaml-dev libbsd-dev gcc make libc6-dev > /dev/null
	inch sh -ec 'cd /build/fastrpc && sh ./autogen.sh &&
		./configure --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu &&
		make -j"$(nproc)" && make install DESTDIR=/build/fastrpc-root' \
		> "$OUT/logs/fastrpc-build.log" 2>&1
	sudo cp -a "$CH/build/fastrpc-root/." "$b/root/"
}
PKG_VERSION="0.0~git$(git -C "$SRC" show -s --format=%cd --date=format:%Y%m%d HEAD).$(git -C "$SRC" rev-parse --short=7 HEAD)-1"

b="$WORK/fastrpc"
rm -rf "$b"
mkdir -p "$b/src" "$b/root" "$OUT/debs" "$OUT/logs"
git -C "$SRC" archive HEAD | tar -x -C "$b/src"
if [ "$(dpkg --print-architecture)" = arm64 ]; then
	log "building fastrpc $FASTRPC_COMMIT (native arm64)"
	build_native
else
	log "building fastrpc $FASTRPC_COMMIT (arm64 buildd chroot under qemu)"
	build_emulated
fi ||
	{ tail -30 "$OUT/logs/fastrpc-build.log"; die "fastrpc build failed"; }
# runtime only: no headers, static or libtool archives
rm -rf "$b/root/usr/include" "$b/root/usr/lib/aarch64-linux-gnu/pkgconfig" \
	"$b/root/usr/share/fastrpc_test" "$b/root/usr/bin/fastrpc_test" \
	"$b/root/usr/lib/aarch64-linux-gnu/fastrpc_test"
# upstream systemd units are not used: device-xiaomi-diting starts adsprpcd
rm -rf "$b/root/usr/lib/systemd" "$b/root/lib/systemd"
find "$b/root" \( -name '*.la' -o -name '*.a' \) -delete
mkdir -p "$b/root/DEBIAN" "$b/root/usr/share/doc/$PKG"
cp "$b/src/LICENSE.txt" "$b/root/usr/share/doc/$PKG/copyright" 2>/dev/null ||
	cp "$b/src"/LICENSE* "$b/root/usr/share/doc/$PKG/copyright"
echo "$FASTRPC_URL $FASTRPC_COMMIT" > "$b/root/usr/share/doc/$PKG/SOURCE"
cat > "$b/root/DEBIAN/control" <<C
Package: $PKG
Version: $PKG_VERSION
Architecture: arm64
Maintainer: ubuntu-diting local build <ubuntu-diting@localhost>
Depends: libc6, libyaml-0-2, libbsd0
Section: libs
Priority: optional
Homepage: https://github.com/qualcomm/fastrpc
Description: Qualcomm FastRPC userspace for Xiaomi diting (local build)
 libadsprpc, libcdsprpc, libsdsprpc and the adsprpcd/cdsprpcd daemons from
 Qualcomm's FastRPC project at commit ${FASTRPC_COMMIT:0:12}. On diting,
 adsprpcd hosts the ADSP audio PD that loads the voice call modules.
C
mkdir -p "$b/root/DEBIAN"
printf '#!/bin/sh\nset -e\n[ "$1" = configure ] && ldconfig || true\n' > "$b/root/DEBIAN/postinst"
printf '#!/bin/sh\nset -e\n[ "$1" = remove ] && ldconfig || true\n' > "$b/root/DEBIAN/postrm"
chmod 755 "$b/root/DEBIAN/postinst" "$b/root/DEBIAN/postrm"
chmod -R u=rwX,go=rX "$b/root/usr"
deb="$OUT/debs/${PKG}_${PKG_VERSION}_arm64.deb"
dpkg-deb --root-owner-group -Zxz --build "$b/root" "$deb" >/dev/null
log "wrote $deb"
dpkg-deb -c "$deb" | awk '{print $6}' | grep -v '/$'
