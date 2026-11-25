#!/bin/bash
# Put SSH public keys into a downloaded rootfs image, in a container: on the
# host nothing runs as root and nothing is mounted. For the owner image of
# a CI build (ci/BUILD.md): its account is locked and sshd accepts keys
# only, and the runner has no key to put in, so the image cannot be logged
# in to until a key is in ~/.ssh/authorized_keys. The public image takes a
# key the same way. A local step, run on the machine the artifact was
# downloaded to: the workflow neither runs this script nor ships it.
# Nothing here flashes or boots the phone.
#
#   add-ssh-key.sh [--user NAME] DEST KEYFILE...
#
# Run it in the directory with the image: boot.img, vendor_boot.img,
# flash-diting.sh, and the root filesystem as rootfs.img.xz.NNN (xz parts,
# as the CI artifact ships it) or as rootfs.img (Android sparse, as a
# release archive ships it). DEST, which must not exist or be empty and
# needs about 10 GB, becomes the directory to run flash-diting.sh in: those
# three files and the rootfs image, with the public key lines of the
# KEYFILEs (~/.ssh/id_*.pub) in the authorized_keys of the image's user
# (ubuntu; --user). Keys that are in the image stay, and no key is written
# twice.
#
# On the host, only docker runs: one container with no network and not as
# root (the user's own uid), this directory and the directory with the
# image mounted read-only, DEST read-write, the keys on standard input. In
# the container this script runs again (--inside) and the image is never
# mounted: its files are read and written with debugfs (e2fsprogs), and the
# filesystem is checked with e2fsck before and after. When docker itself
# needs sudo, root makes only DEST, as the user's. Needs docker, about
# 10 GB, and once the network to build the small image diting-add-key
# (Debian with e2fsprogs, android-sdk-libsparse-utils and xz-utils).
# ADD_KEY_IMAGE names another image with those tools instead, the builder
# image of the artifacts for one.
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | sed -n '$d; s/^# \{0,1\}//p'; }
tools="debugfs e2fsck simg2img img2simg xz sha256sum awk cat cp"

# ---- in the container: --inside USER SRC DEST, the keys on standard input
if [ "${1:-}" = --inside ]; then
	[ $# -eq 4 ] || die "--inside needs USER SRC DEST"
	user="$2" src="$3" dest="$4"
	for t in $tools; do command -v "$t" >/dev/null || die "the image of this container has no $t"; done
	add=()
	while IFS= read -r line || [ -n "$line" ]; do add+=("$line"); done	# the keys, one a line
	[ ${#add[@]} -gt 0 ] || die "no key came on standard input"
	raw="$dest/.raw.img"	# the root filesystem as ext4: the only file that is changed
	sparse="$dest/.sparse.img"	# the xz parts, joined
	new="$dest/.authorized_keys"	# what goes into the image

	if [ -f "$src/SHA256SUMS" ]; then
		log "checking SHA256SUMS"
		(cd "$src" && sha256sum -c --ignore-missing --quiet SHA256SUMS) ||
			die "$src does not match its SHA256SUMS: download it again"
	fi
	log "ext4 image of the root filesystem"
	if [ -f "$src/rootfs.img" ]; then
		simg2img "$src/rootfs.img" "$raw"
	else
		ls "$src"/rootfs.img.xz.[0-9][0-9][0-9] >/dev/null 2>&1 ||
			die "no rootfs.img and no rootfs.img.xz.NNN in $src"
		# the parts are one xz stream cut by bytes: through stdin
		(cd "$src" && cat rootfs.img.xz.[0-9][0-9][0-9]) | xz -dc -T0 >"$sparse"
		simg2img "$sparse" "$raw"
		rm -f "$sparse"
	fi
	fs_check() { # e2fsck changes nothing; its output only when it fails
		local out
		if ! out="$(e2fsck -fn "$raw" 2>&1)"; then printf '%s\n' "$out" >&2; die "$raw is not a clean ext4 filesystem"; fi
	}
	fs_check
	fs_read() { debugfs -R "$1" "$raw" 2>/dev/null || true; }	# nothing when there is no such file
	fs_edit() { # debugfs, changing the image; debugfs's last words when it fails
		local out
		out="$(debugfs -w -R "$1" "$raw" 2>&1)" || die "debugfs $1: $(tail -n 3 <<<"$out" | tr '\n' ' ')"
	}
	mode_of() { awk '/^Inode:/{for (i = 1; i < NF; i++) if ($i == "Mode:") print $(i + 1)}'; }
	own_of() { awk '/^User:/{print $2, $4}'; }

	acct="$(fs_read 'cat /etc/passwd' | awk -F: -v u="$user" '$1 == u { print $3, $4, $6; exit }')"
	[ -n "$acct" ] || die "no user '$user' in the image (--user names the account to take the key)"
	read -r uid gid home <<<"$acct"
	# both go into the commands for debugfs, which has no quoting
	[[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || die "the ids of $user in the image are not numbers"
	[[ "$home" =~ ^/[A-Za-z0-9._/+-]+$ ]] || die "the home directory of $user in the image is '$home', not a plain path"
	dir="$home/.ssh"
	file="$dir/authorized_keys"
	st="$(fs_read "stat $dir")"
	if [ -z "$st" ]; then
		log "making $dir"
		fs_edit "mkdir $dir"
	elif [[ "$st" != *"Type: directory"* ]]; then
		die "$dir in the image is not a directory"
	fi
	st="$(fs_read "stat $file")"
	[[ -z "$st" || "$st" == *"Type: regular"* ]] || die "$file in the image is not a regular file"
	old="$(fs_read "cat $file")"	# nothing when there is no file

	printf '%s' "$old" >"$new"
	[ -z "$old" ] || printf '\n' >>"$new"
	added=0
	for line in "${add[@]}"; do
		grep -qxF -- "$line" "$new" && continue
		printf '%s\n' "$line" >>"$new"
		added=$((added + 1))
	done
	if [ "$added" -gt 0 ]; then
		log "$user: $added key(s) into $file"
		[ -z "$st" ] || fs_edit "rm $file"
		fs_edit "write $new $file"
		fs_edit "sif $file mode 0100600"
		fs_edit "sif $file uid $uid"
		fs_edit "sif $file gid $gid"
		fs_edit "sif $dir mode 040700"	# the type is part of the mode: 0400000 a directory, 0100000 a regular file
		fs_edit "sif $dir uid $uid"
		fs_edit "sif $dir gid $gid"
		fs_check
		cmp -s "$new" <(fs_read "cat $file") || die "the keys are not in the image as they were written"
		st="$(fs_read "stat $file")"
		[[ "$st" == *"Type: regular"* ]] && [ "$(mode_of <<<"$st")" = 0600 ] && [ "$(own_of <<<"$st")" = "$uid $gid" ] ||
			die "$file in the image is not a regular file of 0600 and $user's"
		st="$(fs_read "stat $dir")"
		[[ "$st" == *"Type: directory"* ]] && [ "$(mode_of <<<"$st")" = 0700 ] && [ "$(own_of <<<"$st")" = "$uid $gid" ] ||
			die "$dir in the image is not a directory of 0700 and $user's"
	fi
	total="$(grep -c . "$new")"
	nopass=
	grep -q "^$user:[!*]" <(fs_read 'cat /etc/shadow') && nopass=1
	fs_read 'cat /etc/diting-build' | sed -n 's/^KERNEL_RELEASE=/image: kernel /p;s/^BUILD_DATE=/image: built /p'

	log "Android sparse image"
	img2simg "$raw" "$dest/rootfs.img"
	rm -f "$raw" "$new"
	for f in boot.img vendor_boot.img flash-diting.sh; do cp "$src/$f" "$dest/"; done
	(cd "$dest" && sha256sum boot.img vendor_boot.img rootfs.img flash-diting.sh >SHA256SUMS)
	log "$added key(s) put in, $(( ${#add[@]} - added )) already there; authorized_keys has $total"
	log "to flash: cd $dest && ./flash-diting.sh"
	if [ -n "$nopass" ]; then
		echo "    $user has no password, so the screen cannot be unlocked yet (the PIN that"
		echo "    flash-diting.sh mentions is the public image's). Log in over the USB network"
		echo "    (ssh $user@172.16.42.1), then set one: sudo passwd $user"
	fi
	exit 0
fi

# ---- on the host
case "${1:-}" in -h | --help) usage; exit 0 ;; esac
# The arguments are read before anything is run, so that a wrong call
# prints the usage and changes nothing.
args() {
	user=ubuntu
	while [ $# -gt 0 ]; do
		case "$1" in
		--user) [ $# -ge 2 ] || die "--user needs a name"; user="$2"; shift 2 ;;
		--) shift; break ;;
		-*) die "unknown option '$1'" ;;
		*) break ;;
		esac
	done
	[ $# -ge 2 ] || { usage >&2; exit 2; }
	case "$1" in /*) dest="$1" ;; *) dest="$PWD/$1" ;; esac
	shift
	keys=("$@")
}
args "$@"
src="$PWD"
if [ -e "$dest" ] && { [ ! -d "$dest" ] || [ -n "$(ls -A "$dest")" ]; }; then
	die "$dest exists and is not an empty directory: one image per directory"
fi
for f in boot.img vendor_boot.img flash-diting.sh; do
	[ -f "$src/$f" ] || die "no $f in $src: run this in the directory with the image"
done
[ -f "$src/rootfs.img" ] || ls "$src"/rootfs.img.xz.[0-9][0-9][0-9] >/dev/null 2>&1 ||
	die "no rootfs.img and no rootfs.img.xz.NNN in $src"
command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "docker does not answer for this user: is the daemon running, is the user in the docker group?"

# A public key line: TYPE BASE64 [COMMENT], and the decoded key names the
# same TYPE. A damaged or truncated key is refused: sshd would ignore it.
key_line() {
	local type="${1%% *}" blob
	[ "$type" != "$1" ] || return 1
	blob="${1#* }"; blob="${blob%% *}"
	case "$type" in ssh-* | ecdsa-* | sk-*) ;; *) return 1 ;; esac
	# the decoded key: its length, its type, then at least one field
	[ "$(printf '%s' "$blob" | base64 -d 2>/dev/null | wc -c)" -ge $((${#type} + 9)) ] &&
		[ "$(printf '%s' "$blob" | base64 -d 2>/dev/null | dd bs=1 skip=4 count="${#type}" 2>/dev/null)" = "$type" ]
}
add=()
for k in "${keys[@]}"; do
	n=0
	# the last line may have no newline
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		[[ "$line" =~ ^[[:space:]]*$ ]] && continue
		key_line "$line" || die "not a public key line in $k: ${line:0:60}"
		add+=("$line"); n=$((n + 1))
	done <"$k"
	[ "$n" -gt 0 ] || die "no public key in $k (the .pub file of ssh-keygen)"
done

finish() {
	rc=$?
	[ "$rc" = 0 ] || [ ! -e "$dest" ] || echo "incomplete: $dest (remove it before trying again)" >&2
}
trap finish EXIT
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
[ -f "$self" ] || die "cannot find this script ($self)"
uid="${SUDO_UID:-$(id -u)}" gid="${SUDO_GID:-$(id -g)}"
image="${ADD_KEY_IMAGE:-diting-add-key}"
# The container must have the tools. The image is built here, once, when
# its name is the one of this script.
has_tools() { [ "$(docker run --rm --network none "$image" bash -c "command -v $tools" 2>/dev/null | grep -c /)" -eq "$(wc -w <<<"$tools")" ]; }
if ! { docker image inspect "$image" >/dev/null 2>&1 && has_tools; }; then
	[ -z "${ADD_KEY_IMAGE:-}" ] || die "ADD_KEY_IMAGE=$image has not the tools: $tools"
	log "building the image $image, once (Debian with e2fsprogs, android-sdk-libsparse-utils, xz-utils)"
	docker build -q -t "$image" - <<'EOF'
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
		e2fsprogs android-sdk-libsparse-utils xz-utils \
	&& rm -rf /var/lib/apt/lists/*
EOF
	has_tools || die "the image $image has not the tools: $tools"
fi

if [ ! -e "$dest" ]; then
	mkdir -p "$dest"
	# When docker needs sudo, the directory this run made is the user's: the
	# container runs as the user and has to write in it. A DEST that was
	# there is left whose it is.
	[ "$(id -u)" != 0 ] || [ -z "${SUDO_UID:-}" ] || chown "$uid:$gid" "$dest"
fi
log "in a container, as uid $uid: nothing runs as root on this machine and nothing is mounted"
printf '%s\n' "${add[@]}" | docker run --rm -i --network none --user "$uid:$gid" \
	-v "$src:/src:ro" -v "$dest:/out" -v "$(dirname "$self"):/tool:ro" \
	"$image" bash "/tool/$(basename "$self")" --inside "$user" /src /out
