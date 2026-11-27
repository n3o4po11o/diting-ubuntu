#!/bin/bash
# Tests of the scripts in this directory against stand-ins for make and
# docker. Runs in seconds inside the builder image (bash 5, GNU grep, zstd
# and shellcheck), which is what the lint job of .github/workflows/build.yml
# does:
#
#   docker run --rm -v "$PWD:/src" -w /src diting-builder:<rev> \
#       ubuntu-diting/ci/tests.sh /src /tmp/ci-tests
#
# SRCTREE is the checkout, WORKDIR a directory for the throwaway trees. The
# exit status is 0 when every check passed; a failing check prints FAIL.
set -uo pipefail
SRC="$1"
W="$2"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*" >&2; }
check() { if "$@"; then ok "${checkdesc:-$*}"; else bad "${checkdesc:-$*}"; fi; }
expect() { checkdesc="output contains: $1"; check grep -qF -- "$1" "$W/out.txt"; }
noexpect() {
	checkdesc="output does not contain: $1"
	if grep -qF -- "$1" "$W/out.txt"; then bad "$checkdesc"; else ok "$checkdesc"; fi
}
absent() { checkdesc="does not exist: ${1#"$W/"}"; check test ! -e "$1"; }
present() { checkdesc="exists: ${1#"$W/"}"; check test -e "$1"; }
rc_is() { checkdesc="exit status $1 (got $2)"; check test "$2" = "$1"; }
rc_not() { checkdesc="exit status is not $1 (got $2)"; check test "$2" != "$1"; }

# ---------------------------------------------------------------- stand-ins
mkdir -p "$W/bin"
cat > "$W/bin/make" <<'MK'
#!/bin/bash
# Stand-in for make: records its targets, prints like the scripts do, and
# leaves behind what the real stage leaves behind, the build logs under
# output/logs included. Fails the stage FAIL_STAGE. Sleeps in SLEEP_STAGE.
T="${TEST_TOP:?}"
U="$T/ubuntu-diting"
build_log() { mkdir -p "$U/output/logs"; echo "$2" >>"$U/output/logs/$1"; }
for t in "$@"; do
	echo "$t" >>"$T/make.log"
	[ -z "${FORCE_ROOTFS:-}" ] || echo "$t" >>"$T/make.forced"
	echo "make: entering the $t stage"
	case "$t" in
	check-host) ;;
	sources)  # the kernel, and nothing else
		mkdir -p "$T/kernel/upstream" "$T/kernel/.gnupg"
		echo x >"$T/kernel/upstream/f" ;;
	kernel)
		mkdir -p "$U/work/kernel-src" "$U/work/kernel-obj" "$U/output/debs" "$U/output/kernel"
		for i in $(seq 1 50); do build_log kernel-build.log "  CC [M] line $i"; done
		head -c 200K /dev/zero >"$U/output/debs/linux-image-7.2.10-diting_7.2.10-52_arm64.deb"
		head -c 100K /dev/zero >"$U/output/kernel/Image-7.2.10-diting" ;;
	packages)
		mkdir -p "$U/output/debs"
		build_log device-pkg-build.log "dpkg-buildpackage: info: package device-xiaomi-diting"
		echo x >"$U/output/debs/device-xiaomi-diting_0.7.34_all.deb" ;;
	rootfs)
		mkdir -p "$U/work/build-chroot-resolute-arm64" "$U/work/rootfs" "$U/output"
		build_log modemmanager-build.log "  CC src/mm-base-modem"
		build_log phosh-build.log "  CC libphosh"
		echo x >"$U/work/rootfs/f"
		echo x >"$U/work/build-chroot-resolute-arm64/f"
		head -c 300K /dev/zero >"$U/output/ubuntu-diting-rootfs-resolute-arm64.img" ;;
	sensors)
		mkdir -p "$U/work/sensors-chroot"
		build_log sensors-build.log "ninja: entering directory"
		echo x >"$U/work/sensors-chroot/f" ;;
	libcamera)
		mkdir -p "$U/work/libcamera-chroot"
		build_log libcamera-build.log "ninja: 80/540"
		echo x >"$U/work/libcamera-chroot/f" ;;
	phoc) mkdir -p "$U/work/phoc-chroot"; echo x >"$U/work/phoc-chroot/f" ;;
	release)
		n=ubuntu-diting-20261124
		r="$U/output/release/$n"
		mkdir -p "$r" "$U/work/rootfs-public"
		echo x >"$U/work/rootfs-public/f"
		head -c 1M /dev/urandom >"$r/rootfs.img"
		echo boot >"$r/boot.img"
		echo vendor_boot >"$r/vendor_boot.img"
		for f in flash-diting.sh INSTALL.md BUILD-INFO PACKAGES.tsv; do echo "$f" >"$r/$f"; done
		(cd "$r" && sha256sum boot.img vendor_boot.img rootfs.img flash-diting.sh >SHA256SUMS)
		head -c 200K /dev/urandom >"$U/output/release/$n.tar.xz.000"
		(cd "$U/output/release" && sha256sum "$n.tar.xz.000" >"$n.SHA256SUMS")
		head -c 300K /dev/zero >"$U/output/ubuntu-diting-rootfs-resolute-arm64-public.img" ;;
	owner-release)
		o="$U/output/owner"
		mkdir -p "$o" "$U/work/rootfs"
		head -c 400K /dev/urandom >"$o/rootfs.img"
		echo boot >"$o/boot.img"
		echo vendor_boot >"$o/vendor_boot.img"
		for f in BUILD-INFO PACKAGES.tsv; do echo "$f" >"$o/$f"; done ;;
	verify)
		echo "verify: 1 checks, all passed" >"$U/output/MANIFEST.txt"
		: >"$U/output/MANIFEST.sha256"
		: >"$U/output/rootfs-packages-resolute-public.tsv" ;;
	esac
	if [ "$t" = "${FAIL_STAGE:-}" ]; then
		build_log "$t-build.log" "building $t"
		build_log "$t-build.log" "error: simulated failure in $t"
		echo "stub make fails on $t" >&2
		exit 3
	fi
	if [ "$t" = "${SLEEP_STAGE:-}" ]; then sleep "${SLEEP_SECONDS:-3}"; fi
done
MK
cat > "$W/bin/docker" <<'DK'
#!/bin/bash
# Stand-in for docker: "run" executes the command on the host, with the bind
# mounts, the working directory and the environment translated to host paths.
case "${1:-}" in
save) echo "fake image archive of ${2:-}"; exit 0 ;;
image) echo "sha256:fake"; exit 0 ;;
info) exit 0 ;;
build) cat >/dev/null; exit 0 ;;	# add-ssh-key.sh builds its small image; this container has the tools
run) shift ;;
*) echo "stand-in docker: unsupported: $*" >&2; exit 9 ;;
esac
declare -A env mounts
wd=/ image="" opts=""
while [ $# -gt 0 ]; do
	case "$1" in
	--rm | --init | --privileged | --network=host | -i) opts="$opts $1"; shift ;;
	--network | --user) opts="$opts $1 $2"; shift 2 ;;
	-v) c="${2#*:}"; c="${c%:*}"; mounts["$c"]="${2%%:*}"; opts="$opts -v $2"; shift 2 ;;
	-w) wd="$2"; shift 2 ;;
	-e) env["${2%%=*}"]="${2#*=}"; shift 2 ;;
	-*) echo "stand-in docker: unsupported option: $1" >&2; exit 9 ;;
	*) image="$1"; shift; break ;;
	esac
done
case "$image" in "diting-builder:${REV:-}" | diting-add-key) ;; *) echo "stand-in docker: unexpected image: $image" >&2; exit 9 ;; esac	# REV is not set when add-ssh-key.sh is run straight
[ -z "$opts" ] || echo "docker options:$opts" >>"${TEST_TOP:?}/docker.log"
echo "docker run: stages=${env[STAGES]:-} args=[$*]" >>"${TEST_TOP:?}/docker.log"
map() {
	local p
	for p in "${!mounts[@]}"; do
		case "$1" in
		"$p") printf '%s' "${mounts[$p]}"; return ;;
		"$p"/*) printf '%s%s' "${mounts[$p]}" "${1#"$p"}"; return ;;
		esac
	done
	printf '%s' "$1"
}
wd="$(map "$wd")"
args=()
for a in "$@"; do args+=("$(map "$a")"); done
for k in "${!env[@]}"; do export "$k=$(map "${env[$k]}")"; done
if [ "${args[0]}" = cat ]; then echo "stub-package 1.0"; exit 0; fi
[ "${args[0]}" != bash ] || args=("${args[@]:1}")	# a command given to bash: -c …, or a script
cd "$wd" && exec bash "${args[@]}"
DK
chmod +x "$W/bin/"*

# ---------------------------------------------------------------- trees
ALL="check-host sources kernel packages rootfs sensors libcamera phoc release owner-release verify"
new_tree() { # a tree like the repository, with the scripts under test
	local t="$W/t" u
	rm -rf "$t"
	u="$t/ubuntu-diting"
	mkdir -p "$u/ci" "$u/scripts" "$u/config" "$u/release" "$t/kernel/config" "$t/tools/src"
	cp "$SRC"/ubuntu-diting/ci/{build-fromzero.sh,run-stage.sh,run-pack.sh,pack-artifacts.sh,Dockerfile} "$u/ci/"
	cp "$SRC"/ubuntu-diting/scripts/lib.sh "$u/scripts/"
	cp "$SRC"/ubuntu-diting/release/{flash-diting.sh,add-ssh-key.sh} "$u/release/"
	cp "$SRC"/ubuntu-diting/config/{diting.conf,kernel.lock} "$u/config/"
	cp "$SRC"/kernel/config/diting.config "$t/kernel/config/"
	cp "$SRC/.gitignore" "$t/"
	git -C "$t" init -q
	git -C "$t" add -A
	git -C "$t" -c user.name=t -c user.email=t@t commit -qm "test tree"
	export TEST_TOP="$t" U="$u"
	: >"$t/make.log"
	: >"$t/make.forced"
	: >"$t/docker.log"
}
driver() { # driver [--env VAR=value]... -- [driver arguments]...
	local e=() a=()
	while [ "${1:-}" = --env ]; do e+=("$2"); shift 2; done
	[ "${1:-}" = -- ] && shift
	a=("$@")
	(cd "$TEST_TOP" && env PATH="$W/bin:$PATH" REV=test FROMZERO_LOGDIR="$W/logs" "${e[@]}" \
		"$TEST_TOP/ubuntu-diting/ci/build-fromzero.sh" "${a[@]}" >"$W/out.txt" 2>&1)
}
stage_step() { # stage_step [--resume] STAGES...: ci/run-stage.sh, as a step of the workflow
	local a=()
	if [ "${1:-}" = --resume ]; then a+=(--resume); shift; fi
	a+=("$@")
	(cd "$TEST_TOP" && env PATH="$W/bin:$PATH" REV=test "$TEST_TOP/ubuntu-diting/ci/run-stage.sh" "${a[@]}" >"$W/out.txt" 2>&1)
}
packer() { # ci/run-pack.sh
	rm -rf "$W/g"
	(cd "$TEST_TOP" && env PATH="$W/bin:$PATH" REV=test \
		"$TEST_TOP/ubuntu-diting/ci/run-pack.sh" "$W/g/stage" "$W/g/dest" >"$W/out.txt" 2>&1)
}
# shellcheck disable=SC2016  # $1 and $2 belong to the inner shell
made() { checkdesc="make ran exactly: $*"; check bash -c 'tr "\n" " " <"$1" | grep -qxF -- "$2"' _ "$TEST_TOP/make.log" "$(printf '%s ' "$@")"; }
# shellcheck disable=SC2086  # one word per stage
made_all() { made $ALL; }
status_ok() { checkdesc="status.tsv has '$1 0'"; check grep -P -q "^$1	0	" "$W/logs/status.tsv"; }
order() { # order TEXT...: the texts appear in this order in the output
	local n=0 i line
	for i in "$@"; do
		line="$(grep -nF -- "$i" "$W/out.txt" | head -1 | cut -d: -f1)"
		[ -n "$line" ] && [ "$line" -gt "$n" ] || return 1
		n="$line"
	done
}

echo "== 1. the driver, all stages in one call"
new_tree
driver
rc_is 0 "$?"
present "$W/logs/DONE"
made_all
checkdesc="status.tsv has eleven lines, all 0"; check test "$(grep -c -P "	0	" "$W/logs/status.tsv")" = 11
expect "# all stages passed"
expect "make: entering the rootfs stage"
order "==> kernel: make kernel" "make: entering the kernel stage" "ok kernel" "==> packages: make packages"
expect "kernel-build.log: 50 lines"
order "==> release: make release" "ok release" "==> owner-release: FORCE_ROOTFS=1 make owner-release" "ok owner-release" "==> verify: make verify"
checkdesc="only the owner image's rootfs is built from zero (FORCE_ROOTFS on: $(tr '\n' ' ' <"$TEST_TOP/make.forced"))"
check test "$(cat "$TEST_TOP/make.forced")" = owner-release

echo "== 2. the driver, only some stages (a package for the phone)"
new_tree
driver --env "STAGES=sources packages verify"
rc_is 0 "$?"
made sources packages verify
absent "$W/logs/DONE"
expect "# these stages passed; not passed yet: check-host kernel rootfs sensors libcamera phoc release owner-release"

echo "== 3. the driver, the build in parts, then resumed to the end"
new_tree
driver --env "STAGES=check-host sources kernel packages rootfs"
rc_is 0 "$?"
absent "$W/logs/DONE"
for s in sensors libcamera phoc; do
	driver --env "STAGES=$s" -- --resume
	rc_is 0 "$?"
	absent "$W/logs/DONE"
done
expect "# these stages passed; not passed yet: release owner-release verify"
driver --env "STAGES=release owner-release verify" -- --resume
rc_is 0 "$?"
present "$W/logs/DONE"
made_all
for s in $ALL; do status_ok "$s"; done

echo "== 4. the driver, a failed stage and the resume after it"
new_tree
driver --env "FAIL_STAGE=kernel" --env "STAGES=check-host sources kernel"
rc_not 0 "$?"
absent "$W/logs/DONE"
checkdesc="status.tsv records kernel with rc 3"; check grep -P -q "^kernel	3	" "$W/logs/status.tsv"
expect "# stopped at a failed stage"
expect "stub make fails on kernel"
expect "::error::stage kernel failed (rc=3,"
expect "--- last 40 lines of output/logs/kernel-build.log ---"
expect "error: simulated failure in kernel"
driver --env "STAGES=kernel" -- --resume
rc_is 0 "$?"
status_ok kernel
made check-host sources kernel kernel
checkdesc="the driver log keeps the failure"; check grep -q "FAILED kernel (rc=3" "$W/logs/driver.log"

echo "== 5. the driver: guards"
new_tree
driver --env "STAGES=nonsense"
rc_is 2 "$?"
expect "unknown stage 'nonsense'"
driver --env "FROMZERO_HEARTBEAT=0"
rc_is 2 "$?"
expect "FROMZERO_HEARTBEAT must be a number of seconds"
driver --env "STAGES=check-host kernel" # the kernel stage creates work/
rc_is 0 "$?"
driver --env "STAGES=sources" # no longer from zero, and no --resume: refused
rc_not 0 "$?"
expect "not a from-zero tree"
made check-host kernel
driver --env "STAGES=check-host kernel" -- --resume
rc_is 0 "$?"
expect "skip kernel (done)"
made check-host kernel

echo "== 6. the driver: progress lines while a stage runs"
new_tree
driver --env "FROMZERO_HEARTBEAT=1" --env "SLEEP_STAGE=kernel" --env "STAGES=check-host sources kernel"
rc_is 0 "$?"
expect "make: entering the kernel stage"
expect "[kernel: 0m,"
expect "kernel-build.log: 50 lines, last:   CC [M] line 50"
order "==> kernel: make kernel" "[kernel: 0m," "ok kernel"

echo "== 7. the driver: a cancelled run stops the stage"
new_tree
(
	cd "$TEST_TOP" && exec env PATH="$W/bin:$PATH" REV=test FROMZERO_LOGDIR="$W/logs" \
		FROMZERO_HEARTBEAT=1 SLEEP_STAGE=kernel SLEEP_SECONDS=40 "STAGES=check-host sources kernel" \
		"$TEST_TOP/ubuntu-diting/ci/build-fromzero.sh"
) >"$W/out.txt" 2>&1 &
pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	grep -q "make: entering the kernel stage" "$W/out.txt" && break
	sleep 0.5
done
sleep 1
kill -TERM "$pid"
wait "$pid"
rc_is 130 "$?"
expect "cancelled while the stage 'kernel' was running"
sleep 1
checkdesc="the processes of the stage are gone"; check test -z "$(pgrep -f 'sleep 40' || true)"
absent "$W/logs/DONE"

echo "== 8. run-stage.sh: the build as steps"
new_tree
stage_step check-host sources
rc_is 0 "$?"
made check-host sources
expect "==> diting-builder:test on"
present "$U/output/fromzero/status.tsv"
stage_step --resume kernel
rc_is 0 "$?"
made check-host sources kernel
calls="$(sed -n 's/^docker run: stages=//p' "$TEST_TOP/docker.log" | tr '\n' ';')"
checkdesc="two calls: from zero, then with --resume"
check test "$calls" = "check-host sources args=[ci/build-fromzero.sh];kernel args=[ci/build-fromzero.sh --resume];"
stage_step kernel # not from zero any more, and no --resume
rc_not 0 "$?"
expect "not a from-zero tree"
made check-host sources kernel

echo "== 9. run-pack.sh: nothing to pack before the last stage, then the artifacts"
new_tree
stage_step check-host sources
packer
rc_not 0 "$?"
expect "not every stage passed"
checkdesc="nothing was packed"; check test -z "$(ls -A "$W/g/dest" 2>/dev/null || true)"
for s in kernel packages rootfs sensors libcamera phoc release owner-release verify; do
	stage_step --resume "$s"
	rc_is 0 "$?"
done
made_all
present "$U/output/fromzero/DONE"
packer
rc_is 0 "$?"
checkdesc="the artifact directory verifies against its SHA256SUMS"
# shellcheck disable=SC2016  # $1 belongs to the inner shell
check bash -c 'cd "$1" && sha256sum -c --quiet SHA256SUMS' _ "$W/g/dest"
present "$W/g/dest/diting-builder-test.tar.zst"
checkdesc="the saved image is the zstd of what docker save wrote"
check test "$(zstd -dc "$W/g/dest/diting-builder-test.tar.zst")" = "fake image archive of diting-builder:test"
checkdesc="BUILD-INFO names the builder image"
check grep -q "^builder_image=diting-builder:test id=sha256:fake$" "$W/g/dest/BUILD-INFO"
checkdesc="builder-packages.tsv is what the image listed"; check test "$(cat "$W/g/dest/builder-packages.tsv")" = "stub-package 1.0"
noexpect "local_change="
# shellcheck disable=SC2016  # $1 and $2 belong to the inner shell
xz_of() { checkdesc="$3 is the xz of ${1#"$U/"}"; check bash -c 'xz -dc "$2" | cmp -s - "$1"' _ "$1" "$2" "$3"; }
xz_of "$U/output/release/ubuntu-diting-20261124/rootfs.img" "$W/g/dest/rootfs.img.xz.000" "rootfs.img.xz.000"
for f in boot.img vendor_boot.img BUILD-INFO PACKAGES.tsv flash-diting.sh; do
	present "$W/g/dest/owner/$f"
done
# The key goes in on the machine the artifact is downloaded to: the workflow
# does not ship release/add-ssh-key.sh (section 11: nor name it).
absent "$W/g/dest/owner/add-ssh-key.sh"
xz_of "$U/output/owner/rootfs.img" "$W/g/dest/owner/rootfs.img.xz.000" "owner/rootfs.img.xz.000"
absent "$W/g/dest/owner/rootfs.img.xz.001"
checkdesc="owner/ verifies against the SHA256SUMS of its own"
# shellcheck disable=SC2016  # $1 belongs to the inner shell
check bash -c 'cd "$1" && sha256sum -c --quiet SHA256SUMS' _ "$W/g/dest/owner"
checkdesc="SHA256SUMS of the artifact has no owner/ line: it would fail where owner/ is not"
# shellcheck disable=SC2016  # $1 belongs to the inner shell
check bash -c '! grep -q "^owner/" "$1"' _ "$W/g/dest/SHA256SUMS"
checkdesc="the owner's flash script is the release one"
check cmp -s "$W/g/dest/owner/flash-diting.sh" "$SRC/ubuntu-diting/release/flash-diting.sh"
rm -rf "$U/output/owner"
checkdesc="pack-artifacts.sh without the owner image is refused"
# shellcheck disable=SC2016  # $1, $2 and $3 belong to the inner shell
check bash -c '! DITING_NOTHP=0 bash "$1" "$2" 2>"$3"' _ "$U/ci/pack-artifacts.sh" "$W/g/dest2" "$W/out.txt"
expect "no owner image"
absent "$W/g/dest2/owner"
absent "$W/g/dest2/rootfs.img.xz.000"

echo "== 10. ci/lint.sh on the real tree (the lint job's command)"
(cd "$SRC" && bash "$SRC/ubuntu-diting/ci/lint.sh" >"$W/out.txt" 2>&1)
rc=$?
rc_is 0 "$rc"
[ "$rc" = 0 ] || cat "$W/out.txt" >&2
checkdesc="shellcheck is the one of the image"
check test "$(shellcheck --version | sed -n 's/^version: //p')" = 0.10.0
# Not the generated trees of .gitignore: on a checkout that has built
# already they hold the kernel source with its thousands of scripts, which
# took this scan from seconds to a quarter of an hour.
(cd "$SRC" && grep -rIlE '^#!([^ ]*/)?(env +)?(ba|da|k)?sh( |$)' --exclude-dir=.git \
	--exclude-dir=upstream --exclude-dir=references --exclude-dir=build --exclude-dir=.gnupg \
	--exclude-dir=device-data --exclude-dir=venv --exclude-dir=work --exclude-dir=output . | sort |
	xargs shellcheck -x -S error -f gcc 2>/dev/null | grep " error: " | cut -d: -f1 | sort | uniq -c) >"$W/outside.txt"
echo "     error-level shellcheck findings in the whole tree (lint.sh covers a part of it):"
sed 's/^/       /' "$W/outside.txt"

echo "== 11. the workflow: scripts that exist, stages in order"
WF="$SRC/.github/workflows/build.yml"
# The scripts a run step names are relative to the root of the checkout, not
# to ubuntu-diting/. The first run of the workflow stopped in no time on
# ci/run-on-github.sh, which is ubuntu-diting/ci/run-on-github.sh.
bad_paths="$(grep -oE '[A-Za-z0-9_./$-]+\.sh\b' "$WF" | sort -u | grep -v '\$' |
	while read -r p; do
		if [ ! -e "$SRC/$p" ]; then echo "$p (missing)"
		elif [ ! -x "$SRC/$p" ]; then echo "$p (not executable)"; fi
	done)"
checkdesc="every script path in build.yml exists and is executable (bad: ${bad_paths:-none})"
check test -z "$bad_paths"
echo "     script paths in build.yml: $(grep -oE '[A-Za-z0-9_./$-]+\.sh\b' "$WF" | sort -u | tr '\n' ' ')"
# One step per stage, the eleven of them in order, --resume from the second on.
calls="$(grep -E '^[[:space:]]+run: .*ci/run-stage\.sh' "$WF" | sed -E 's/^[[:space:]]+run: [^ ]*run-stage\.sh[[:space:]]*//' | tr '\n' ';')"
expected="check-host sources;"
for s in kernel packages rootfs sensors libcamera phoc release owner-release verify; do expected="$expected--resume $s;"; done
checkdesc="the eleven stages, one step each, in order, --resume after the first (got: $calls)"
check test "$calls" = "$expected"
checkdesc="the workflow packs once, with run-pack.sh"; check test "$(grep -c 'ci/run-pack\.sh' "$WF")" -eq 1
checkdesc="the owner image is uploaded as an artifact of its own"
# shellcheck disable=SC2016  # ${{ env.REV }} is the workflow's expression, not the shell's
check grep -qx '          name: diting-${{ env.REV }}-owner' "$WF"
# Putting the key in is a local step after the download: the workflow does
# not run the script, so it does not name it either.
checkdesc="the workflow does not name add-ssh-key.sh"
if grep -q 'add-ssh-key' "$WF"; then bad "$checkdesc"; else ok "$checkdesc"; fi

echo "== 12. release/add-ssh-key.sh: its part for the container, on small images made here"
# This container has the tools of the image add-ssh-key.sh builds (e2fsprogs,
# android-sdk-libsparse-utils, xz-utils) and no docker. The part that runs in
# the container (--inside) runs here, for real, on small ext4 images; the part
# for the host runs with the docker stand-in, which plays the container by
# running the command as it is. As any user: the owners the small images
# start with want root or uid 1000, and the script sets its own either way.
new_tree
# Three keys made for these tests; the private halves were thrown away.
KEY1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJac11WmIZewZIskiOqj6NASt8ynMEK+o5QyFlNNSapQ ci-test-key-1'
KEY2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA8/i3NTWW1gV4CRtVC3+2r+PhzmoLjLQrZFRo3US7Y0 ci-test-key-2'
KEY3='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDSaUCdShXWGnjQzJwSSVfsrscUZQKYs/2BUYzUiwrW9 ci-test-key-3'
K="$W/k"; rm -rf "$K"
# Called with --inside straight, DEST has to be there: in the script it is the host part that makes it.
mkdir -p "$K/keys" "$K/a/flash" "$K/c/flash" "$K/d/flash" "$K/e/flash"
printf '%s\n' "$KEY2" >"$K/keys/k2.pub"; printf '%s\n' "$KEY3" >"$K/keys/k3.pub"
add="$U/release/add-ssh-key.sh"
plain() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }
small_image() { # small_image DIR ssh|nossh: a 16 MB ext4 image with ubuntu (1000), as the sparse DIR/src/rootfs.img
	mkdir -p "$1/root/etc" "$1/root/home/ubuntu" "$1/src"
	printf 'root:x:0:0:root:/root:/bin/bash\nubuntu:x:1000:1000::/home/ubuntu:/bin/bash\n' >"$1/root/etc/passwd"
	printf 'root:x:0:\nubuntu:x:1000:\n' >"$1/root/etc/group"
	printf 'root:*:20000:0:99999:7:::\nubuntu:!:20000:0:99999:7:::\n' >"$1/root/etc/shadow"
	printf 'KERNEL_RELEASE=test\nBUILD_DATE=test\n' >"$1/root/etc/diting-build"
	if [ "$2" = ssh ]; then
		mkdir -p "$1/root/home/ubuntu/.ssh"
		printf '%s\n' "$KEY1" >"$1/root/home/ubuntu/.ssh/authorized_keys"
		chown 1000:1000 "$1/root/home/ubuntu/.ssh" "$1/root/home/ubuntu/.ssh/authorized_keys" 2>/dev/null || true
		chmod 700 "$1/root/home/ubuntu/.ssh"; chmod 600 "$1/root/home/ubuntu/.ssh/authorized_keys"
	fi
	chown 1000:1000 "$1/root/home/ubuntu" 2>/dev/null || true; chmod 750 "$1/root/home/ubuntu"
	truncate -s 16M "$1/ext4.img"
	mkfs.ext4 -q -F -b 4096 -d "$1/root" "$1/ext4.img"
	img2simg "$1/ext4.img" "$1/src/rootfs.img"
	for f in boot.img vendor_boot.img flash-diting.sh; do echo "$f" >"$1/src/$f"; done
	chmod 755 "$1/src/flash-diting.sh"
	(cd "$1/src" && sha256sum boot.img vendor_boot.img rootfs.img flash-diting.sh >SHA256SUMS)
}
fs() { debugfs -R "$1" "$2" 2>/dev/null; }	# kept in variables by the callers: under pipefail, `cmd | grep -q` fails when cmd is still writing
keys_of() { fs "cat /home/ubuntu/.ssh/authorized_keys" "$1"; }
mode_of() { awk '/^Inode:/{for (i = 1; i < NF; i++) if ($i == "Mode:") print $(i + 1)}'; }
own_of() { awk '/^User:/{print $2, $4}'; }
inode_is() { # inode_is RAW PATH TYPE MODE UID GID: this type, this mode, this owner
	local st; st="$(fs "stat $2" "$1")"
	[[ "$st" == *"Type: $3"* ]] && [ "$(mode_of <<<"$st")" = "$4" ] && [ "$(own_of <<<"$st")" = "$5 $6" ]
}
five="SHA256SUMS boot.img flash-diting.sh rootfs.img vendor_boot.img "
verifies() { (cd "$1" && sha256sum -c --ignore-missing --quiet SHA256SUMS); }

echo "-- a. the owner image as the CI artifact ships it (xz parts): one key in it, one new"
small_image "$K/a" ssh
mkdir -p "$K/a/parts"; (cd "$K/a/src" && cp boot.img vendor_boot.img flash-diting.sh "$K/a/parts/" && xz -T0 -c rootfs.img | split -b 100k -d -a 3 - "$K/a/parts/rootfs.img.xz.")
(cd "$K/a/parts" && sha256sum boot.img vendor_boot.img rootfs.img.xz.* flash-diting.sh >SHA256SUMS)
printf '%s\n' "$KEY2" | bash "$add" --inside ubuntu "$K/a/parts" "$K/a/flash" >"$W/out.txt" 2>&1
rc_is 0 "$?"
simg2img "$K/a/flash/rootfs.img" "$K/a/check.raw" 2>/dev/null
checkdesc="authorized_keys: the key of the image, then the new one"; check test "$(keys_of "$K/a/check.raw")" = "$(printf '%s\n%s' "$KEY1" "$KEY2")"
checkdesc="authorized_keys in the image is a regular file, 0600, 1000:1000"; check inode_is "$K/a/check.raw" /home/ubuntu/.ssh/authorized_keys regular 0600 1000 1000
checkdesc=".ssh in the image is a directory, 0700, 1000:1000"; check inode_is "$K/a/check.raw" /home/ubuntu/.ssh directory 0700 1000 1000
checkdesc="the changed image is a clean ext4 filesystem"
# shellcheck disable=SC2016  # $1 and $2 belong to the inner shell
check bash -c 'e2fsck -fn "$1" >/dev/null 2>&1' _ "$K/a/check.raw"
checkdesc="the flash directory has exactly the five files"
check test "$(cd "$K/a/flash" && find . -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" = "$five"
checkdesc="the flash directory verifies against its SHA256SUMS"; check verifies "$K/a/flash"
checkdesc="the summary line"; check plain "$W/out.txt" | grep -q '1 key(s) put in, 0 already there; authorized_keys has 2'
checkdesc="it says the account has no password"; check grep -q "has no password" "$W/out.txt"

echo "-- b. the part for the host, on the directory that was made: three keys, the source as it was"
n="$(grep -c '^docker run' "$TEST_TOP/docker.log" 2>/dev/null || true)"
(cd "$K/a/flash" && printf '%s\n' "$KEY3" "$KEY2" | env PATH="$W/bin:$PATH" bash "$add" "$K/a/flash2" "$K/keys/k3.pub" "$K/keys/k2.pub") >"$W/out.txt" 2>&1
rc_is 0 "$?"
simg2img "$K/a/flash2/rootfs.img" "$K/a/check2.raw" 2>/dev/null
checkdesc="authorized_keys: three keys, the one that was there not repeated"; check test "$(keys_of "$K/a/check2.raw")" = "$(printf '%s\n%s\n%s' "$KEY1" "$KEY2" "$KEY3")"
checkdesc="the summary line"; check plain "$W/out.txt" | grep -q '1 key(s) put in, 1 already there; authorized_keys has 3'
checkdesc="the source still has its five files and verifies"
# shellcheck disable=SC2016  # $1 and $2 belong to the inner shell
check bash -c 'cd "$1" && [ "$(find . -mindepth 1 -maxdepth 1 -printf "%f\n" | LC_ALL=C sort | tr "\n" " ")" = "$2" ] && sha256sum -c --ignore-missing --quiet SHA256SUMS' _ "$K/a/flash" "$five"
checkdesc="the second flash directory verifies"; check verifies "$K/a/flash2"
checkdesc="two containers were asked for: the probe and the work"
check test "$(grep -c '^docker run' "$TEST_TOP/docker.log")" = "$((n + 2))"
checkdesc="the working container: no network, the user, read-only but /out"
check grep -qF -- "--rm -i --network none --user $(id -u):$(id -g) -v $K/a/flash:/src:ro -v $K/a/flash2:/out -v $U/release:/tool:ro" "$TEST_TOP/docker.log"
checkdesc="nothing privileged was asked for"
# shellcheck disable=SC2016  # $1 and $2 belong to the inner shell
check bash -c '! grep -q -- "--privileged" "$1"' _ "$TEST_TOP/docker.log"

echo "-- c. an image whose user has no .ssh yet"
small_image "$K/c" nossh
printf '%s\n' "$KEY2" | bash "$add" --inside ubuntu "$K/c/src" "$K/c/flash" >"$W/out.txt" 2>&1
rc_is 0 "$?"
simg2img "$K/c/flash/rootfs.img" "$K/c/check.raw" 2>/dev/null
checkdesc="authorized_keys was made, with the key in it"; check test "$(keys_of "$K/c/check.raw")" = "$KEY2"
checkdesc=".ssh was made: a directory, 0700, 1000:1000"; check inode_is "$K/c/check.raw" /home/ubuntu/.ssh directory 0700 1000 1000
checkdesc="authorized_keys: a regular file, 0600, 1000:1000"; check inode_is "$K/c/check.raw" /home/ubuntu/.ssh/authorized_keys regular 0600 1000 1000
checkdesc="the changed image is a clean ext4 filesystem"
# shellcheck disable=SC2016  # $1 and $2 belong to the inner shell
check bash -c 'e2fsck -fn "$1" >/dev/null 2>&1' _ "$K/c/check.raw"
expect "making /home/ubuntu/.ssh"

echo "-- d. refused, and nothing of the image changed"
n="$(grep -c '^docker run' "$TEST_TOP/docker.log" 2>/dev/null || true)"
printf 'ssh-ed25519 AAAA not-a-key\n' >"$K/keys/junk.pub"
(cd "$K/c/src" && env PATH="$W/bin:$PATH" bash "$add" "$K/flash-x" "$K/keys/junk.pub") >"$W/out.txt" 2>&1
rc_not 0 "$?"
expect "not a public key line"
checkdesc="no container was asked for"; check test "$(grep -c '^docker run' "$TEST_TOP/docker.log")" = "$n"
absent "$K/flash-x"
small_image "$K/d" ssh; echo changed >>"$K/d/src/boot.img"
printf '%s\n' "$KEY2" | bash "$add" --inside ubuntu "$K/d/src" "$K/d/flash" >"$W/out.txt" 2>&1
rc_not 0 "$?"
expect "does not match its SHA256SUMS: download it again"
absent "$K/d/flash/rootfs.img"
printf '%s\n' "$KEY2" | bash "$add" --inside nosuch "$K/c/src" "$K/e/flash" >"$W/out.txt" 2>&1
rc_not 0 "$?"
expect "no user 'nosuch' in the image"
rm -rf "$K"

echo "== 13. sources: the kernel alone by make sources, a tree when it is needed"
# Two trees on disk stand in for the remote ones: one with two commits, the
# pinned one first, and one of another history.
R="$W/remotes"
rm -rf "$R"
mkdir -p "$R/input" "$R/other"
git -C "$R/input" init -q
git -C "$R/input" config uploadpack.allowFilter true
echo one >"$R/input/f"
git -C "$R/input" add f
git -C "$R/input" -c user.name=t -c user.email=t@t commit -qm one
one="$(git -C "$R/input" rev-parse HEAD)"
echo two >"$R/input/f"
git -C "$R/input" -c user.name=t -c user.email=t@t commit -qam two
git -C "$R/other" init -q
echo other >"$R/other/f"
git -C "$R/other" add f
git -C "$R/other" -c user.name=t -c user.email=t@t commit -qm other
new_tree
S="$TEST_TOP/ubuntu-diting/scripts"
# lib.sh under test is the one in the tree; DITING_NOTHP=0 keeps it from
# putting the command under its no-THP wrapper. $S, $R and $one are expanded
# by the inner shell, which has them in its environment.
# shellcheck disable=SC2016
LIB='. "$S/lib.sh";'
(cd "$TEST_TOP" && S="$S" DITING_NOTHP=0 bash -c "$LIB need_ref t-input 'file://$R/input' $one" >"$W/out.txt" 2>&1)
rc_is 0 "$?"
expect "cloning t-input"
checkdesc="need_ref: the tree is at the pinned commit, an older one than the clone's own head"
check test "$(git -C "$TEST_TOP/references/t-input" rev-parse HEAD)" = "$one"
checkdesc="need_ref: with that commit's file"
check test "$(cat "$TEST_TOP/references/t-input/f")" = one
(cd "$TEST_TOP" && S="$S" DITING_NOTHP=0 bash -c "$LIB need_ref t-input 'file://$R/input' $one" >"$W/out.txt" 2>&1)
rc_is 0 "$?"
noexpect "cloning"
checkdesc="need_ref: a tree that is there is left alone"
check test "$(git -C "$TEST_TOP/references/t-input" rev-parse HEAD)" = "$one"
# A checkout made by hand, on another commit, is put on the pinned one.
git clone -q "file://$R/input" "$TEST_TOP/references/t-hand"
checkdesc="made by hand: on the newer commit"
check test "$(git -C "$TEST_TOP/references/t-hand" rev-parse HEAD)" != "$one"
(cd "$TEST_TOP" && S="$S" DITING_NOTHP=0 bash -c "$LIB need_ref t-hand 'file://$R/input' $one" >"$W/out.txt" 2>&1)
rc_is 0 "$?"
noexpect "cloning"
checkdesc="need_ref: an existing checkout is put on the pinned commit"
check test "$(git -C "$TEST_TOP/references/t-hand" rev-parse HEAD)" = "$one"
# have_ref needs the commit to be there, not to be checked out.
(cd "$TEST_TOP" && S="$S" DITING_NOTHP=0 bash -c "$LIB have_ref t-arch 'file://$R/input' $one" >"$W/out.txt" 2>&1)
rc_is 0 "$?"
checkdesc="have_ref: the tree stays on the commit the clone made"
check test "$(git -C "$TEST_TOP/references/t-arch" rev-parse HEAD)" != "$one"
# A tree of another history does not have the commit: said, and not used.
(cd "$TEST_TOP" && S="$S" DITING_NOTHP=0 bash -c "$LIB need_ref t-other 'file://$R/other' $one" >"$W/out.txt" 2>&1)
rc_not 0 "$?"
expect "has no commit"
# The command line: a tree by name, the names, and nothing fetched for a wrong call.
cp "$SRC"/ubuntu-diting/scripts/fetch-sources.sh "$S/"
(cd "$TEST_TOP" && DITING_NOTHP=0 bash "$S/fetch-sources.sh" --ref nosuchtree >"$W/out.txt" 2>&1)
rc_not 0 "$?"
expect "no source named nosuchtree"
absent "$TEST_TOP/kernel/upstream"
(cd "$TEST_TOP" && DITING_NOTHP=0 bash "$S/fetch-sources.sh" --ref >"$W/out.txt" 2>&1)
rc_not 0 "$?"
expect "usage: fetch-sources.sh"
(cd "$TEST_TOP" && DITING_NOTHP=0 bash "$S/fetch-sources.sh" --help >"$W/out.txt" 2>&1)
rc_is 0 "$?"
# seven trees that are only read, nine that a build needs; the sixteenth
# name is ffmpeg, which 7daa6ed added without this count, and the
# seventeenth qcom-va-driver
checkdesc="the names of the seven trees that are only read and of the nine a build needs"
check test "$(grep -cE '^[a-z0-9-]+$' "$W/out.txt")" -eq 17
# What the requirement comes down to, where it is written down.
F="$SRC/ubuntu-diting/scripts/fetch-sources.sh"
checkdesc="fetch-sources.sh without an argument fetches the kernel and nothing else"
check grep -qE '^	"" \| --kernel-only\) fetch_kernel ;;' "$F"
checkdesc="the Makefile says so"
check grep -q '^## sources *fetch the locked kernel only' "$SRC/ubuntu-diting/Makefile"
checkdesc="no build script sends anyone to make sources any more"
if grep -l '(make sources)' "$SRC"/ubuntu-diting/scripts/build-*.sh >/dev/null 2>&1; then bad "$checkdesc"; else ok "$checkdesc"; fi
checkdesc="every tree a build asks for is one fetch-sources.sh knows"
missing=""
for n in $(grep -hoE '^(need_ref|have_ref) [a-z0-9-]+' "$SRC"/ubuntu-diting/scripts/build-*.sh | cut -d' ' -f2 | sort -u); do
	grep -qx "$n" "$W/out.txt" || missing="$missing $n"
done
check test -z "$missing"
rm -rf "$R"

echo
echo "== 14. the helper of Cellular Settings that writes /etc/diting/modem-mode"
# The file is sourced as shell code, by root, once a minute: --check must
# accept what diting-modem-setup reads and nothing else. --check writes
# nothing and runs as anyone; the writing itself is tried on the phone.
H="$SRC/ubuntu-diting/packages/cellular-settings/src/cellular-settings-write-modem-mode"
good='allowed="3g|4g|5g"
preferred="5g"
usage="data"
service_domain="ps-only"'
printf '%s\n' "$good" | sh "$H" --check >"$W/out.txt" 2>"$W/err.txt"
rc_is 0 "$?"
checkdesc="--check prints a good file back as it is"
check test "$(cat "$W/out.txt")" = "$good"
checkdesc="--check says nothing of a good file"
check test ! -s "$W/err.txt"
rm -f "$W/err.txt"
refused() { # refused <what> <file>: --check exits with 1 and prints nothing of the file
	checkdesc="--check refuses: $1"
	if printf '%s\n' "$2" | sh "$H" --check >"$W/out.txt" 2>&1; then bad "$checkdesc"; else ok "$checkdesc"; fi
	expect "cellular-settings-write-modem-mode:"
}
refused "an empty file" ""
refused "a command substitution" 'allowed="$(id)"'
refused "a variable the script does not read" 'allowed="4g"
evil="x"'
refused "a value without quotes" 'allowed=4g'
refused "a technology the script does not know" 'allowed="4g|6g"'
refused "a hyphen inside a technology" 'allowed="4-g"'
refused "a preferred technology that is not allowed" 'allowed="4g"
preferred="5g"'
refused "a technology twice" 'allowed="4g|4g"'
refused "an empty technology" 'allowed="4g||5g"'
refused "allowed given twice" 'allowed="4g"
allowed="5g"'
refused "no allowed at all" 'usage="data"'
refused "two assignments on one line" 'allowed="4g" usage="data"'
refused "a second command on the line" 'allowed="4g"; id'
refused "a usage that is no word of the script" 'allowed="4g"
usage="data|voice"'
refused "a service domain that is no word of the script" 'allowed="4g"
service_domain="ps"'
refused "a line that is not ASCII" '# 中文'
refused "a carriage return" $'allowed="4g"\r'
for d in cs-only ps-only cs-ps cs-attach ps-detach; do
	printf 'allowed="4g"\nservice_domain="%s"\n' "$d" | sh "$H" --check >/dev/null 2>&1
	checkdesc="--check accepts service_domain=\"$d\""
	rc_is 0 "$?"
done
if [ "$(id -u)" != 0 ]; then
	printf '%s\n' "$good" | sh "$H" >"$W/out.txt" 2>&1
	rc_not 0 "$?"
	expect "not root"
	sh "$H" --delete >"$W/out.txt" 2>&1
	rc_not 0 "$?"
	expect "not root"
fi

echo
echo "== 15. build-cellular-settings.sh: which way it builds, by where it runs"
# Three hosts run the script: its own image, a host with docker, and the
# builder of the from-zero build, which has neither. The image is tried on
# the phone; these two are tried here, with stand-ins for docker and for
# the chroot library, which must not run here (it would debootstrap). The
# third way was first run on 2026-11-27, and died on the way:
# "DOCKER: unbound variable" before the chroot, in a tree without docker.
new_tree
cp "$SRC"/ubuntu-diting/scripts/build-cellular-settings.sh "$U/scripts/"
cp "$SRC"/ubuntu-diting/config/packages-cellular-settings.list "$U/config/"
mkdir -p "$U/packages/cellular-settings"
echo x >"$U/packages/cellular-settings/Cargo.toml"
cat >"$U/scripts/lib-buildd.sh" <<'LB'
# Stand-in for the chroot library: records what it is asked for
CH=stand-in
buildd_setup() { echo "buildd_setup" >>"${TEST_TOP:?}/buildd.log"; }
buildd_build() { echo "buildd_build $*" >>"${TEST_TOP:?}/buildd.log"; }
LB
cat >"$U/ci/cellular-settings.sh" <<'CS'
#!/bin/bash
echo "cellular-settings.sh $*" >>"${TEST_TOP:?}/driver.log"
CS
chmod +x "$U/ci/cellular-settings.sh"
: >"$TEST_TOP/buildd.log"
: >"$TEST_TOP/driver.log"
words="$(sed 's/#.*//' "$SRC/ubuntu-diting/config/packages-cellular-settings.list" | tr -s ' \t' '\n' | grep . | tr '\n' ' ')"
words="${words% }"
# a PATH with the tools the scripts need up to that point, and no docker
# (the host's may be anywhere in its PATH)
mkdir -p "$W/nodocker"
for t in bash dirname sed tr uname nproc cp rm mkdir; do
	p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$W/nodocker/$t"
done
cellular() { # cellular [--env VAR=value]...: the script, in the throwaway tree
	local e=() a=()
	while [ "${1:-}" = --env ]; do e+=("$2"); shift 2; done
	(cd "$TEST_TOP" && env PATH="$W/nodocker" "${e[@]}" \
		"$TEST_TOP/ubuntu-diting/scripts/build-cellular-settings.sh" >"$W/out.txt" 2>&1)
}
{ echo buildd_setup; echo "buildd_build $U/work/cellular-settings-pkg cellular-settings $words"; } >"$W/want.txt"
cellular
rc_is 0 "$?"
checkdesc="without docker and without \$DOCKER: the chroot, with the words of the list"
check cmp -s "$W/want.txt" "$TEST_TOP/buildd.log"
noexpect "unbound variable"
present "$U/work/cellular-settings-pkg/Cargo.toml"
checkdesc="without docker: the container driver is not run"
check test ! -s "$TEST_TOP/driver.log"
: >"$TEST_TOP/buildd.log"
cellular --env "DOCKER=sudo -n docker"
rc_is 0 "$?"
checkdesc="with \$DOCKER naming a docker that is not there: the chroot all the same"
check cmp -s "$W/want.txt" "$TEST_TOP/buildd.log"
noexpect "unbound variable"
: >"$TEST_TOP/buildd.log"
(cd "$TEST_TOP" && env PATH="$W/bin:$W/nodocker" \
	"$TEST_TOP/ubuntu-diting/scripts/build-cellular-settings.sh" >"$W/out.txt" 2>&1)
rc_is 0 "$?"
printf 'cellular-settings.sh build\ncellular-settings.sh up\ncellular-settings.sh once make cellular-settings\n' >"$W/want.txt"
checkdesc="with docker: its container is built, started, and builds in tmux there"
check cmp -s "$W/want.txt" "$TEST_TOP/driver.log"
checkdesc="with docker: nothing is asked of the chroot"
check test ! -s "$TEST_TOP/buildd.log"
rm -rf "$W/nodocker"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
