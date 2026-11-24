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
	echo "make: entering the $t stage"
	case "$t" in
	check-host) ;;
	sources)
		mkdir -p "$T/references/x" "$T/kernel/upstream" "$T/kernel/.gnupg"
		echo x >"$T/references/x/f"
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
run) shift ;;
*) echo "stand-in docker: unsupported: $*" >&2; exit 9 ;;
esac
declare -A env mounts
wd=/ image=""
while [ $# -gt 0 ]; do
	case "$1" in
	--rm | --init | --privileged | --network=host) shift ;;
	-v) c="${2#*:}"; c="${c%:*}"; mounts["$c"]="${2%%:*}"; shift 2 ;;
	-w) wd="$2"; shift 2 ;;
	-e) env["${2%%=*}"]="${2#*=}"; shift 2 ;;
	-*) echo "stand-in docker: unsupported option: $1" >&2; exit 9 ;;
	*) image="$1"; shift; break ;;
	esac
done
[ "$image" = "diting-builder:${REV:?}" ] || { echo "stand-in docker: unexpected image: $image" >&2; exit 9; }
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
chmod +x "$W/bin/"*

# ---------------------------------------------------------------- trees
ALL="check-host sources kernel packages rootfs sensors libcamera phoc release verify"
new_tree() { # a tree like the repository, with the scripts under test
	local t="$W/t" u
	rm -rf "$t"
	u="$t/ubuntu-diting"
	mkdir -p "$u/ci" "$u/scripts" "$u/config" "$t/kernel/config" "$t/tools/src"
	cp "$SRC"/ubuntu-diting/ci/{build-fromzero.sh,run-stage.sh,run-pack.sh,pack-artifacts.sh,Dockerfile} "$u/ci/"
	cp "$SRC"/ubuntu-diting/scripts/lib.sh "$u/scripts/"
	cp "$SRC"/ubuntu-diting/config/{diting.conf,kernel.lock} "$u/config/"
	cp "$SRC"/kernel/config/diting.config "$t/kernel/config/"
	cp "$SRC/.gitignore" "$t/"
	git -C "$t" init -q
	git -C "$t" add -A
	git -C "$t" -c user.name=t -c user.email=t@t commit -qm "test tree"
	export TEST_TOP="$t" U="$u"
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
checkdesc="status.tsv has ten lines, all 0"; check test "$(grep -c -P "	0	" "$W/logs/status.tsv")" = 10
expect "# all stages passed"
expect "make: entering the rootfs stage"
order "==> kernel: make kernel" "make: entering the kernel stage" "ok kernel" "==> packages: make packages"
expect "kernel-build.log: 50 lines"

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
for s in kernel packages rootfs sensors libcamera phoc release verify; do
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

echo "== 10. ci/lint.sh on the real tree (the lint job's command)"
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
# One step per stage, the ten of them in order, --resume from the second on.
calls="$(grep -E '^[[:space:]]+run: .*ci/run-stage\.sh' "$WF" | sed -E 's/^[[:space:]]+run: [^ ]*run-stage\.sh[[:space:]]*//' | tr '\n' ';')"
expected="check-host sources;"
for s in kernel packages rootfs sensors libcamera phoc release verify; do expected="$expected--resume $s;"; done
checkdesc="the ten stages, one step each, in order, --resume after the first (got: $calls)"
check test "$calls" = "$expected"
checkdesc="the workflow packs once, with run-pack.sh"; check test "$(grep -c 'ci/run-pack\.sh' "$WF")" -eq 1

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
