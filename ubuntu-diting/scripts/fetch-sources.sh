#!/bin/bash
# Fetch the locked upstream stable kernel, and nothing else: this is `make
# sources`, the first step of every build.
#
# The other trees under references/ are not fetched here. What a build needs
# (the AudioReach topology, fastrpc, hexagonrpc, libssc, ...) is fetched by
# that build when it gets there (need_ref in lib.sh). What is only read by
# hand is fetched one at a time, by name:
#
#   fetch-sources.sh --ref sm8450-fdt [NAME...]   make reference NAME=sm8450-fdt
#   fetch-sources.sh --references                 make references: all of those
#   fetch-sources.sh --all                        the kernel and every tree
#
# Never resets or modifies an existing checkout of the kernel or of a tree
# that is only read. An existing checkout of a build input is put on its
# pinned commit, as its build would put it.
. "$(dirname "$0")/lib.sh"
need git gpg

fetch_kernel() {
	if [ ! -d "$KERNEL_GIT/.git" ]; then
		log "cloning $KERNEL_TAG from $KERNEL_GIT_URL"
		git clone --depth 1 -b "$KERNEL_TAG" "$KERNEL_GIT_URL" "$KERNEL_GIT"
	fi
	git -C "$KERNEL_GIT" cat-file -e "$KERNEL_TAG_OBJECT" 2>/dev/null ||
		git -C "$KERNEL_GIT" fetch --depth 1 origin tag "$KERNEL_TAG"
	[ "$(git -C "$KERNEL_GIT" rev-parse "$KERNEL_TAG")" = "$KERNEL_TAG_OBJECT" ] ||
		die "tag $KERNEL_TAG does not resolve to locked tag object $KERNEL_TAG_OBJECT"
	[ "$(git -C "$KERNEL_GIT" rev-parse "$KERNEL_TAG^{commit}")" = "$KERNEL_COMMIT" ] ||
		die "tag $KERNEL_TAG does not point to locked commit $KERNEL_COMMIT"

	# Verify the signed tag with a private keyring holding the signer key.
	export GNUPGHOME="$KERNEL_DIR/.gnupg"
	mkdir -p "$KERNEL_DIR"
	[ -d "$GNUPGHOME" ] || mkdir -m 700 "$GNUPGHOME"
	gpg --list-keys "$KERNEL_TAG_SIGNER_FPR" >/dev/null 2>&1 ||
		gpg --auto-key-locate clear,wkd --locate-keys gregkh@kernel.org torvalds@kernel.org >/dev/null
	local status
	status="$(LC_ALL=C git -C "$KERNEL_GIT" verify-tag --raw "$KERNEL_TAG" 2>&1 || true)"
	grep -q "^\[GNUPG:\] VALIDSIG $KERNEL_TAG_SIGNER_FPR " <<<"$status" ||
		die "signature verification of $KERNEL_TAG failed:\n$status"
	log "kernel $KERNEL_TAG: signature by $KERNEL_TAG_SIGNER_FPR verified"
}

# The trees that are only read: community and vendor sources to compare with.
# A line each: name, URL, and the branch where not the default one.
references() {
	cat <<EOF
sm8450-linux https://github.com/sm8450-mainline/linux next
sm8450-fdt https://github.com/sm8450-mainline/fdt
sm8450-pmaports-archive https://github.com/sm8450-mainline/pmaports
pmaports-current https://gitlab.postmarketos.org/postmarketOS/pmaports.git
lineage-diting https://github.com/LineageOS/android_device_xiaomi_diting
lineage-sm8450-common https://github.com/LineageOS/android_device_xiaomi_sm8450-common
xiaomi-sm8475-dev-diting https://github.com/Xiaomi-SM8475-Development/android_device_xiaomi_diting
EOF
}

fetch_ref() { # dir url [branch]
	local dir="$DITING_TOP/references/$1"
	if [ -d "$dir/.git" ]; then
		log "reference $1 present at $(git -C "$dir" rev-parse --short HEAD) (not updated)"
	else
		log "cloning reference $1"
		git clone -q ${3:+-b "$3"} --filter=blob:none "$2" "$dir"
	fi
}

# The trees a build needs, each at the commit pinned in config/diting.conf.
inputs() {
	printf '%s\n' audioreach-topology ar-audioreach-graphservices fastrpc hexagonrpc \
		libssc iio-sensor-proxy libva-v4l2-stateful mobile-config-firefox
}

input() { # name
	case "$1" in
	audioreach-topology) need_ref "$1" "$AUDIOREACH_TOPOLOGY_URL" "$AUDIOREACH_TOPOLOGY_COMMIT" ;;
	ar-audioreach-graphservices) need_ref "$1" "$AUDIOREACH_GRAPHSERVICES_URL" "$AUDIOREACH_GRAPHSERVICES_COMMIT" ;;
	fastrpc) need_ref "$1" "$FASTRPC_URL" "$FASTRPC_COMMIT" ;;
	hexagonrpc) need_ref "$1" "$HEXAGONRPC_URL" "$HEXAGONRPC_COMMIT" ;;
	libssc) need_ref "$1" "$LIBSSC_URL" "$LIBSSC_COMMIT" ;;
	iio-sensor-proxy) need_ref "$1" "$IIO_SENSOR_PROXY_URL" "$IIO_SENSOR_PROXY_COMMIT" ;;
	libva-v4l2-stateful) have_ref "$1" "$LIBVA_V4L2_URL" "$LIBVA_V4L2_COMMIT" ;;
	mobile-config-firefox) have_ref "$1" "$MOBILE_CONFIG_FIREFOX_URL" "$MOBILE_CONFIG_FIREFOX_COMMIT" ;;
	*) die "no source named $1 (--help lists them)" ;;
	esac
}

fetch_one() { # name: a tree that is only read, else a build input
	local line
	line="$(references | awk -v n="$1" '$1 == n')"
	if [ -n "$line" ]; then
		# shellcheck disable=SC2086  # one line of the table: name url [branch]
		fetch_ref $line
	else
		input "$1"
	fi
}

usage() {
	cat <<EOF
usage: fetch-sources.sh                 the locked kernel, signature-checked (make sources)
       fetch-sources.sh --ref NAME...   only these trees (make reference NAME=NAME)
       fetch-sources.sh --references    the trees that are only read (make references)
       fetch-sources.sh --all           the kernel and every tree
names:
$(references | cut -d' ' -f1; inputs)
EOF
	exit "${1:-1}"
}

case "${1:-}" in
	"" | --kernel-only) fetch_kernel ;;  # --kernel-only: what the default is now
	--ref)
		shift
		[ $# -gt 0 ] || usage
		for name in "$@"; do fetch_one "$name"; done ;;
	--references)
		while read -r name url branch; do fetch_ref "$name" "$url" "$branch"; done < <(references) ;;
	--all)
		fetch_kernel
		while read -r name url branch; do fetch_ref "$name" "$url" "$branch"; done < <(references)
		for name in $(inputs); do input "$name"; done ;;
	--help | -h) usage 0 ;;
	*) echo "unknown argument: $1" >&2; usage ;;
esac
