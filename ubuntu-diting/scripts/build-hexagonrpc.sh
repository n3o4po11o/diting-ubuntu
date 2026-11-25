#!/bin/bash
# shellcheck disable=SC2016 # single-quoted maintainer scripts expand $1 themselves
# Build hexagonrpcd-diting: hexagonrpcd (GPL-3.0-or-later) at the pinned
# upstream commit plus packages/hexagonrpc/patches (the sensor registry
# methods from z3ntu/hexagonrpc, ported). It serves the sensor DSP's files
# (registry, sensor configs, DSP libraries). Native arm64 build.
. "$(dirname "$0")/lib.sh"
need dpkg-deb meson ninja gcc git

PKG=hexagonrpcd-diting
need_ref hexagonrpc "$HEXAGONRPC_URL" "$HEXAGONRPC_COMMIT"
SRC="$DITING_TOP/references/hexagonrpc"
PATCHES="$UD/packages/hexagonrpc/patches"
cross_args=()
if [ "$(dpkg --print-architecture)" != arm64 ]; then
	command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 ||
		die "on a non-arm64 host, hexagonrpc is cross-built and needs aarch64-linux-gnu-gcc"
	crossfile="$WORK/hexagonrpc-cross.ini"
	cat > "$crossfile" <<X
[binaries]
c = 'aarch64-linux-gnu-gcc'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
X
	cross_args=(--cross-file "$crossfile")
	log "cross-building hexagonrpcd with aarch64-linux-gnu-gcc"
fi
# Cross-compiled test binaries cannot run on the host (no arm64 loader).
run_tests() {
	if [ ${#cross_args[@]} -gt 0 ]; then
		warn "cross build: skipping meson test (binaries are arm64)"
		return 0
	fi
	meson test -C build
}
patches=("$PATCHES"/*.patch)
n_patches=${#patches[@]}
PKG_VERSION="0.5~git$(git -C "$SRC" show -s --format=%cd --date=format:%Y%m%d HEAD).$(git -C "$SRC" rev-parse --short=7 HEAD)+diting$n_patches-1"

b="$WORK/hexagonrpc"
rm -rf "$b"
mkdir -p "$b/src" "$b/root" "$OUT/debs" "$OUT/logs"
git -C "$SRC" archive HEAD | tar -x -C "$b/src"
log "building hexagonrpc $HEXAGONRPC_COMMIT + $n_patches patches"
for p in "${patches[@]}"; do
	patch -d "$b/src" -p1 --no-backup-if-mismatch -s < "$p" || die "patch $(basename "$p") failed"
done
(cd "$b/src" && meson setup "${cross_args[@]}" --prefix=/usr --libdir=lib/aarch64-linux-gnu --buildtype=release build &&
	ninja -C build && run_tests && DESTDIR="$b/root" meson install -C build) \
	> "$OUT/logs/hexagonrpc-build.log" 2>&1 ||
	{ tail -30 "$OUT/logs/hexagonrpc-build.log"; die "hexagonrpc build failed"; }
# runtime only; upstream systemd units are not used: device-xiaomi-diting
# starts hexagonrpcd for the sensor DSP (diting-sensors.service)
rm -rf "$b/root/usr/include" "$b/root/usr/lib/aarch64-linux-gnu/pkgconfig" \
	"$b/root/usr/lib/aarch64-linux-gnu/libhexagonrpc.so" "$b/root/usr/lib/aarch64-linux-gnu/systemd"
gzip -9n "$b/root/usr/share/man/man1/hexagonrpcd.1"
mkdir -p "$b/root/DEBIAN" "$b/root/usr/share/doc/$PKG"
cp "$b/src/COPYING" "$b/root/usr/share/doc/$PKG/copyright"
{ echo "$HEXAGONRPC_URL $HEXAGONRPC_COMMIT"; printf '%s\n' "${patches[@]##*/}"; } \
	> "$b/root/usr/share/doc/$PKG/SOURCE"
cat > "$b/root/DEBIAN/control" <<C
Package: $PKG
Version: $PKG_VERSION
Architecture: arm64
Maintainer: ubuntu-diting local build <ubuntu-diting@localhost>
Depends: libc6
Provides: hexagonrpcd
Conflicts: hexagonrpcd
Replaces: hexagonrpcd
Section: misc
Priority: optional
Homepage: https://github.com/linux-msm/hexagonrpc
Description: FastRPC file server for Qualcomm DSPs, Xiaomi diting build (local)
 hexagonrpcd and libhexagonrpc from linux-msm/hexagonrpc at commit
 ${HEXAGONRPC_COMMIT:0:12}, with the sensor registry methods (fwrite, fremove,
 fopen_with_env_fd, fclose_fd) from z3ntu/hexagonrpc. On diting it serves
 the sensor DSP's registry and configuration.
C
printf '#!/bin/sh\nset -e\n[ "$1" = configure ] && ldconfig || true\n' > "$b/root/DEBIAN/postinst"
printf '#!/bin/sh\nset -e\n[ "$1" = remove ] && ldconfig || true\n' > "$b/root/DEBIAN/postrm"
chmod 755 "$b/root/DEBIAN/postinst" "$b/root/DEBIAN/postrm"
chmod -R u=rwX,go=rX "$b/root/usr"
deb="$OUT/debs/${PKG}_${PKG_VERSION}_arm64.deb"
rm -f "$OUT/debs/${PKG}"_*.deb
dpkg-deb --root-owner-group -Zxz --build "$b/root" "$deb" >/dev/null
log "wrote $deb"
dpkg-deb -c "$deb" | awk '{print $6}' | grep -v '/$'
