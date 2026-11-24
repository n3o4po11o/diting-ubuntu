#!/bin/bash
# Tests of the scripts in this directory against stand-ins for make, docker
# and sudo. Runs in seconds inside the builder image (bash 5, GNU grep, zstd
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

# ---------------------------------------------------------------- stubs
mkdir -p "$W/bin"
cat > "$W/bin/make" <<'MK'
#!/bin/bash
# Stub of make: records its targets and creates what the real stage leaves
# behind, so that there is something to delete. Fails the stage FAIL_STAGE.
T="${TEST_TOP:?}"
U="$T/ubuntu-diting"
for t in "$@"; do
	echo "$t" >>"$T/make.log"
	case "$t" in
	check-host) ;;
	sources)
		mkdir -p "$T/references/x" "$T/kernel/upstream" "$T/kernel/.gnupg"
		echo x >"$T/references/x/f"
		echo x >"$T/kernel/upstream/f" ;;
	kernel)
		mkdir -p "$U/work/kernel-src" "$U/work/kernel-obj" "$U/output/debs" "$U/output/kernel"
		head -c 200K /dev/zero >"$U/output/debs/linux-image-7.2.10-diting_7.2.10-52_arm64.deb"
		head -c 100K /dev/zero >"$U/output/kernel/Image-7.2.10-diting" ;;
	packages)
		mkdir -p "$U/output/debs"
		echo x >"$U/output/debs/device-xiaomi-diting_0.7.34_all.deb" ;;
	rootfs)
		mkdir -p "$U/work/build-chroot-resolute-arm64" "$U/work/rootfs" "$U/output"
		echo x >"$U/work/rootfs/f"
		echo x >"$U/work/build-chroot-resolute-arm64/f"
		head -c 300K /dev/zero >"$U/output/ubuntu-diting-rootfs-resolute-arm64.img" ;;
	sensors) mkdir -p "$U/work/sensors-chroot"; echo x >"$U/work/sensors-chroot/f" ;;
	libcamera) mkdir -p "$U/work/libcamera-chroot"; echo x >"$U/work/libcamera-chroot/f" ;;
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
	verify)
		echo "verify: 1 checks, all passed" >"$U/output/MANIFEST.txt"
		: >"$U/output/MANIFEST.sha256"
		: >"$U/output/rootfs-packages-resolute-public.tsv" ;;
	esac
	[ "$t" != "${FAIL_STAGE:-}" ] || { echo "stub make fails on $t" >&2; exit 3; }
done
MK
cat > "$W/bin/docker" <<'DK'
#!/bin/bash
# Stub of docker: "run" executes the command on the host, with the bind
# mounts, the working directory and the environment translated to host paths.
case "${1:-}" in
save) echo "fake image archive of ${2:-}"; exit 0 ;;
image) echo "sha256:fake"; exit 0 ;;
run) shift ;;
*) echo "stub docker: unsupported: $*" >&2; exit 9 ;;
esac
declare -A env mounts
wd=/ image=""
while [ $# -gt 0 ]; do
	case "$1" in
	--rm | --privileged | --network=host) shift ;;
	-v) c="${2#*:}"; c="${c%:*}"; mounts["$c"]="${2%%:*}"; shift 2 ;;
	-w) wd="$2"; shift 2 ;;
	-e) env["${2%%=*}"]="${2#*=}"; shift 2 ;;
	-*) echo "stub docker: unsupported option: $1" >&2; exit 9 ;;
	*) image="$1"; shift; break ;;
	esac
done
[ "$image" = "diting-builder:${REV:?}" ] || { echo "stub docker: unexpected image: $image" >&2; exit 9; }
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
cd "$wd" && exec bash "${args[@]}"
DK
cat > "$W/bin/sudo" <<'SU'
#!/bin/bash
# Stub of sudo: the tests already run as root in the container.
exec "$@"
SU
chmod +x "$W/bin/"*

# ---------------------------------------------------------------- trees
ALL="check-host sources kernel packages rootfs sensors libcamera phoc release verify"
new_tree() { # a tree like the repository, with the scripts under test
	local t="$W/t" u
	rm -rf "$t"
	u="$t/ubuntu-diting"
	mkdir -p "$u/ci" "$u/scripts" "$u/config" "$t/kernel/config" "$t/tools/src"
	cp "$SRC"/ubuntu-diting/ci/{build-fromzero.sh,run-on-github.sh,pack-artifacts.sh,Dockerfile} "$u/ci/"
	cp "$SRC"/ubuntu-diting/scripts/lib.sh "$u/scripts/"
	cp "$SRC"/ubuntu-diting/config/{diting.conf,kernel.lock} "$u/config/"
	cp "$SRC"/kernel/config/{diting.config,kernel.lock} "$t/kernel/config/"
	cp "$SRC/.gitignore" "$t/"
	git -C "$t" init -q
	git -C "$t" add -A
	git -C "$t" -c user.name=t -c user.email=t@t commit -qm "test tree"
	export TEST_TOP="$t"
	: >"$t/make.log"
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
runner() { # runner [--env VAR=value]...
	local e=()
	while [ "${1:-}" = --env ]; do e+=("$2"); shift 2; done
	rm -rf "$W/g"
	(cd "$TEST_TOP" && env PATH="$W/bin:$PATH" REV=test "${e[@]}" \
		"$TEST_TOP/ubuntu-diting/ci/run-on-github.sh" "$W/g/logs" "$W/g/stage" "$W/g/dest" >"$W/out.txt" 2>&1)
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
checkdesc="status.tsv has ten lines, all 0"; check test "$(grep -c -P "	0	" "$W/logs/status.tsv")" = 10
expect "# all stages passed"

echo "== 2. the driver, only some stages (a package for the phone)"
new_tree
driver --env "STAGES=sources packages verify"
rc_is 0 "$?"
made sources packages verify
absent "$W/logs/DONE"
expect "# these stages passed; not passed yet: check-host kernel rootfs sensors libcamera phoc release"

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
expect "# these stages passed; not passed yet: release verify"
driver --env "STAGES=release verify" -- --resume
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

echo "== 6. run-on-github.sh, the whole build"
new_tree
runner
rc_is 0 "$?"
made_all
present "$W/g/logs/DONE"
calls="$(grep 'args=\[ci/build-fromzero.sh' "$TEST_TOP/docker.log" | sed -n 's/^docker run: stages=//p' | tr '\n' ';')"
checkdesc="five build calls: the stages, and --resume only after the first"
check test "$calls" = "check-host sources kernel packages rootfs args=[ci/build-fromzero.sh];sensors args=[ci/build-fromzero.sh --resume];libcamera args=[ci/build-fromzero.sh --resume];phoc args=[ci/build-fromzero.sh --resume];release verify args=[ci/build-fromzero.sh --resume];"
U="$TEST_TOP/ubuntu-diting"
checkdesc="the kernel tree and the owner image go after rootfs, before sensors"
check order "ok rootfs" "deleted: kernel-src kernel-obj ubuntu-diting-rootfs-resolute-arm64.img" "==> sensors: make sensors"
checkdesc="each chroot copy goes before the next of the three"
check order "ok sensors" "deleted: sensors-chroot" "==> libcamera" "ok libcamera" "deleted: libcamera-chroot" "==> phoc" "ok phoc" "deleted: phoc-chroot rootfs references"
checkdesc="the public tree goes after release and verify"
check order "ok verify" "deleted: rootfs-public"
checkdesc="the regenerable rest goes after packing"
check order "artifacts in $W/g/dest" "deleted: output work upstream .gnupg references"
for p in "$U/output" "$U/work" "$TEST_TOP/kernel/upstream" "$TEST_TOP/kernel/.gnupg" "$TEST_TOP/references"; do absent "$p"; done
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

echo "== 7. run-on-github.sh, a stage fails"
new_tree
runner --env "FAIL_STAGE=libcamera"
rc_not 0 "$?"
absent "$W/g/logs/DONE"
made check-host sources kernel packages rootfs sensors libcamera
absent "$U/work/sensors-chroot"
present "$U/work/libcamera-chroot"
present "$U/work/rootfs"
checkdesc="nothing was packed"; check test -z "$(ls -A "$W/g/dest")"

echo "== 8. ci/lint.sh on the real tree (the lint job's command)"
(cd "$SRC" && bash "$SRC/ubuntu-diting/ci/lint.sh" >"$W/out.txt" 2>&1)
rc=$?
rc_is 0 "$rc"
[ "$rc" = 0 ] || cat "$W/out.txt" >&2
checkdesc="shellcheck is the one of the image"
check test "$(shellcheck --version | sed -n 's/^version: //p')" = 0.10.0
(cd "$SRC" && grep -rIlE '^#!([^ ]*/)?(env +)?(ba|da|k)?sh( |$)' --exclude-dir=.git . | sort |
	xargs shellcheck -x -S error -f gcc 2>/dev/null | grep " error: " | cut -d: -f1 | sort | uniq -c) >"$W/outside.txt"
echo "     error-level shellcheck findings in the whole tree (lint.sh covers a part of it):"
sed 's/^/       /' "$W/outside.txt"

echo "== 9. the workflow names scripts that exist in the checkout"
# The scripts a run step names are relative to the root of the checkout, not
# to ubuntu-diting/. The first run of the workflow stopped in no time on
# ci/run-on-github.sh, which is ubuntu-diting/ci/run-on-github.sh.
bad_paths="$(grep -oE '[A-Za-z0-9_./$-]+\.sh\b' "$SRC/.github/workflows/build.yml" | sort -u |
	grep -v '\$' | while read -r p; do
		if [ ! -e "$SRC/$p" ]; then echo "$p (missing)"
		elif [ ! -x "$SRC/$p" ]; then echo "$p (not executable)"; fi
	done)"
checkdesc="every script path in build.yml exists and is executable (bad: ${bad_paths:-none})"
check test -z "$bad_paths"
echo "     script paths in build.yml: $(grep -oE '[A-Za-z0-9_./$-]+\.sh\b' "$SRC/.github/workflows/build.yml" | sort -u | tr '\n' ' ')"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
