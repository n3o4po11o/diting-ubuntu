#!/bin/bash
# Build cellular-settings (packages/cellular-settings: Rust and GTK 4) as a
# deb for arm64. Where this runs decides how; the dependencies are
# config/packages-cellular-settings.list in every case.
#  - In the image of ci/Dockerfile.cellular-settings (ci/cellular-settings.sh):
#    dpkg-buildpackage right there, in an Ubuntu of the suite on arm64. The
#    cargo target directory is kept in work/, so a second build compiles
#    what changed only.
#  - On a host with docker: the same, in that container
#    (ci/cellular-settings.sh once make cellular-settings).
#  - Without docker, as in the builder of the from-zero build: the arm64
#    buildd chroot of the other local packages (lib-buildd.sh).
# The .deb lands in output/debs/, the build log in output/logs/.
. "$(dirname "$0")/lib.sh"

P="$UD/packages/cellular-settings"
name=cellular-settings

# the words of the list: "#" starts a comment
deps=()
while read -r p; do
	[ -n "$p" ] && deps+=("$p")
done < <(sed 's/#.*//' "$UD/config/packages-$name.list" | tr -s ' \t' '\n')
[ ${#deps[@]} -gt 0 ] || die "empty config/packages-$name.list"

in_image() { [ -e /etc/cellular-settings-builder ]; }

have_docker() {
	# $DOCKER may be more than one word ("sudo docker"): run it as such.
	# lib.sh does not define it (ci/ffmpeg.sh and ci/cellular-settings.sh
	# do), and the from-zero builder runs without docker and without it.
	# shellcheck disable=SC2086
	${DOCKER:-docker} info >/dev/null 2>&1
}

if in_image; then
	need dpkg-buildpackage cargo
	src="$WORK/$name-pkg"
	target="$WORK/cargo-target/$name"
	mkdir -p "$WORK" "$OUT/debs" "$OUT/logs"
	log "building $name in the container"
	# dpkg-buildpackage writes the .deb beside the source directory: no stale
	# one from an earlier build may be taken for this one
	rm -f "$WORK/$name"_*.deb
	rm -rf "$src" && mkdir -p "$src"
	cp -a "$P/." "$src/"
	(cd "$src" && CARGO_TARGET_DIR="$target" dpkg-buildpackage -b -us -uc) \
		> "$OUT/logs/$name-build.log" 2>&1 ||
		{ tail -30 "$OUT/logs/$name-build.log"; die "dpkg-buildpackage failed (log: $OUT/logs/$name-build.log)"; }
	deb="$(ls -t "$WORK/$name"_*.deb 2>/dev/null | head -1)"
	[ -n "$deb" ] || die "dpkg-buildpackage wrote no .deb beside $src"
	need file
	file "$target/release/cellular-settings" | grep -q "ELF 64-bit.*AARCH64\|ELF 64-bit.*aarch64" ||
		die "the binary is not an arm64 executable: $(file "$target/release/cellular-settings")"
	cp "$deb" "$OUT/debs/"
	log "wrote $OUT/debs/$(basename "$deb")"
elif have_docker; then
	"$UD/ci/cellular-settings.sh" build
	"$UD/ci/cellular-settings.sh" up
	exec "$UD/ci/cellular-settings.sh" once make "$name"
else
	. "$(dirname "$0")/lib-buildd.sh"
	src="$WORK/$name-pkg"
	rm -rf "$src" && mkdir -p "$src"
	cp -a "$P/." "$src/"
	buildd_setup
	buildd_build "$src" "$name" "${deps[@]}"
fi
