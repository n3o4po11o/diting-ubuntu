#!/bin/bash
# Reproducible kernel builds for the iris encoder experiments. Runs on the
# build server (inside tmux) on top of the committed formal series:
#
#   exp-build.sh formal            kernel/patches only, default cmdline
#   exp-build.sh exp TAG [opts]    kernel/patches + experimental patches/scripts
#
#     -p PREFIX    apply kernel/patches-experimental/PREFIX-*.patch in name
#                  order; "all" means every EXPERIMENT-*.patch; a path means
#                  that patch file (e.g. a cherry-picked upstream commit).
#                  Fuzz is 0, a rejected hunk aborts the build.
#     -x PREFIX    leave these out of -p all
#     -s SCRIPT    apply kernel/patches-experimental/SCRIPT <kernel-src>;
#                  repeatable, run after the patches in the order given
#     -n           dry run: export, verify, apply, report; no build
#
# Both modes start by re-exporting kernel/patches into work/kernel-src and
# checking that the tree really is the formal series: prepare-kernel.sh trusts
# .diting-stamp, so an edited tree would otherwise be rebuilt as "formal".
# An experimental tree never keeps its stamp: the next plain `make kernel`
# re-exports the formal tree. Experimental packages and images are moved to
# output/experimental/TAG and the formal ones (output/.formal-backup, written
# by `formal`) are put back, so `make rootfs` cannot pick up an experimental
# module.
#
# Experimental images always carry modprobe.blacklist=qcom_iris: with the
# encoder registered, any application that opens the encoder node can reset
# the phone, so an experimental module is loaded by hand after boot.
#
# Log: output/logs/exp-formal-<date>.log, output/logs/exp-<TAG>-<date>.log
# shellcheck source=../../ubuntu-diting/scripts/lib.sh
. "$(dirname "$0")/../../ubuntu-diting/scripts/lib.sh"

E="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob

usage() {
	# shellcheck disable=SC2016
	sed -n '2,/^\. "\$(dirname/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
	exit 1
}

# label|file under kernel-src|pattern: what the experiment patches and
# scripts leave in the tree
markers=(
	"encoder registered|drivers/media/platform/qcom/iris/iris_platform_vpu2.c|no_encoder = false"
	"encoder buffer tables|drivers/media/platform/qcom/iris/iris_hfi_gen2.c|sm8450_enc_op_int_buf_tbl"
	"subscribe/delivery|drivers/media/platform/qcom/iris/iris_hfi_gen2_command.c|HFI_CMD_DELIVERY_MODE"
	"firmware log|drivers/media/platform/qcom/iris/iris_hfi_gen2_command.c|fwlog_level"
	"interframe PC skip|drivers/media/platform/qcom/iris/iris_hfi_gen2_command.c|skip_interframe_pc"
	"ARP at fixed IOVA|drivers/media/platform/qcom/iris/iris_buffer.c|iris_alloc_arp_buffer"
	"SMMU probe tool|drivers/media/platform/qcom/iris/iris_buffer.c|arp_smmu_write"
	"SID alias|drivers/media/platform/qcom/iris/iris_buffer.c|arp_sid_alias"
	"hw clock control|drivers/clk/qcom/videocc-sm8450.c|hw_clk_ctrl = true"
	"DT SID 0x2184 (hangs boot)|arch/arm64/boot/dts/qcom/sm8450.dtsi|0x2184 0x400"
	"DT core reset|arch/arm64/boot/dts/qcom/sm8450.dtsi|VIDEO_CC_MVS0C_CLK_ARES>"
)
# module_param names of the experiment scripts, looked up in the built module
module_symbols=(fwlog_level arp_smmu_write arp_sid_alias)

count() { grep -c "$2" "$KERNEL_SRC/$1" 2>/dev/null || true; }

report_markers() {
	local m
	for m in "${markers[@]}"; do
		IFS='|' read -r label file pat <<<"$m"
		printf '  %-28s %s\n' "$label:" "$(count "$file" "$pat")"
	done
	printf '  %-28s %s\n' "any EXPERIMENT comment:" \
		"$(grep -r EXPERIMENT "$KERNEL_SRC/drivers/media/platform/qcom/iris" \
			"$KERNEL_SRC/drivers/clk/qcom/videocc-sm8450.c" | wc -l)"
}

# The export is only the formal series if none of the experiments is in it.
assert_formal() {
	local m bad=0 n
	for m in "${markers[@]}"; do
		IFS='|' read -r label file pat <<<"$m"
		n="$(count "$file" "$pat")"
		if [ "$n" != 0 ]; then warn "$label: $n match(es) in $file"; bad=1; fi
	done
	n="$(count drivers/media/platform/qcom/iris/iris_platform_vpu2.c 'no_encoder = true')"
	if [ "$n" != 1 ]; then warn "encoder switch not found once in iris_platform_vpu2.c"; bad=1; fi
	n="$(count arch/arm64/boot/dts/qcom/sm8450.dtsi 'rpmhpd_opp_nom>,')"
	if [ "$n" -lt 1 ]; then warn "patch 0111 (MXC corner) not in the DT"; bad=1; fi
	[ "$bad" = 0 ] || die "work/kernel-src is not the formal series after the export"
}

clean_export() {
	rm -f "$KERNEL_SRC/.diting-stamp"
	"$UD/scripts/prepare-kernel.sh"
}

image_deb() {
	local d=("$OUT"/debs/linux-image-"$KERNEL_RELEASE"_*-"$KERNEL_DEB_REVISION"_arm64.deb)
	[ "${#d[@]}" = 1 ] ||
		die "expected one kernel package linux-image-${KERNEL_RELEASE}_*-${KERNEL_DEB_REVISION}_arm64.deb in $OUT/debs, found ${#d[@]}"
	printf '%s\n' "${d[0]}"
}

build_kernel() { # $1: file the package must be newer than; $2: "clean" = no experiment symbol allowed
	local deb t ko s n bad=0
	log "make kernel"
	make -C "$UD" kernel
	deb="$(image_deb)"
	[ "$deb" -nt "$1" ] || die "kernel package was not rebuilt: $deb"
	t="$(mktemp -d)"
	dpkg-deb -x "$deb" "$t"
	ko="$(find "$t/lib/modules" -name qcom-iris.ko -print -quit)"
	if [ -z "$ko" ]; then rm -rf "$t"; die "qcom-iris.ko not found in $(basename "$deb")"; fi
	log "qcom-iris.ko in $(basename "$deb"), experiment symbols:"
	for s in "${module_symbols[@]}"; do
		n="$(strings "$ko" | grep -c "$s" || true)"
		printf '  %-16s %s\n' "$s:" "$n"
		[ "$n" = 0 ] || bad=1
	done
	rm -rf "$t"
	if [ "${2:-}" = clean ] && [ "$bad" = 1 ]; then
		die "the formal module carries experiment code: work/kernel-src was not clean"
	fi
}

build_boot() { # $1: DITING_ROOT_CMDLINE override or empty (the diting.conf default); $2: cmdline text that must be present or empty
	local name="diting-ubuntu-$KERNEL_RELEASE-rootfs" vc
	# An empty override would disable the root mount: the default is used only
	# when the variable is unset.
	if [ -n "$1" ]; then
		BOOT_MODE=rootfs DITING_ROOT_CMDLINE="$1" make -C "$UD" boot
	else
		env -u DITING_ROOT_CMDLINE BOOT_MODE=rootfs make -C "$UD" boot
	fi
	vc="$(python3 "$UD/scripts/bootimg_info.py" "$OUT/boot/vendor_boot-$name.img" |
		sed -n 's/^vendor_cmdline=//p')"
	case "$vc" in *root=*) ;; *) die "vendor_cmdline has no root=: '$vc'" ;; esac
	if [ -n "$2" ]; then
		case "$vc" in *"$2"*) ;; *) die "vendor_cmdline lacks '$2': '$vc'" ;; esac
	fi
	log "vendor_cmdline: $vc"
}

# The cmdline of a test image: the project default plus the iris blacklist.
debug_cmdline() {
	local t out="" seen=0 list
	for t in $DITING_ROOT_CMDLINE; do
		case "$t" in
		modprobe.blacklist=*)
			list="${t#modprobe.blacklist=}"
			case ",$list," in
			*,qcom_iris,*) ;;
			*) t="$t,qcom_iris" ;;
			esac
			seen=1 ;;
		esac
		out="${out:+$out }$t"
	done
	if [ "$seen" = 0 ]; then out="${out:+$out }modprobe.blacklist=qcom_iris"; fi
	case "$out" in
	*root=*) ;;
	*) die "DITING_ROOT_CMDLINE has no root=; an override must keep the whole default cmdline" ;;
	esac
	printf '%s\n' "$out"
}

save_formal() {
	local d
	rm -rf "$DITING_BACKUP"
	mkdir -p "$DITING_BACKUP/debs" "$DITING_BACKUP/boot"
	for d in "$OUT"/debs/linux-*.deb "$OUT"/boot/*; do
		cp -pr "$d" "$DITING_BACKUP/$(basename "$(dirname "$d")")/"
	done
	log "formal packages and images saved to ${DITING_BACKUP#"$UD/"}"
}

# Experimental results go to output/experimental/TAG, the formal ones come back.
isolate() { # $1: tag
	local dest="$OUT/experimental/$1" f
	mkdir -p "$dest"
	f=("$OUT"/debs/linux-*.deb "$OUT"/boot/*)
	if [ "${#f[@]}" -gt 0 ]; then mv "${f[@]}" "$dest/"; fi
	f=("$DITING_BACKUP"/debs/* "$DITING_BACKUP"/boot/*)
	for f in "${f[@]}"; do cp -pr "$f" "$OUT/$(basename "$(dirname "$f")")/"; done
	warn "experimental artifacts in ${dest#"$UD/"}; output/debs and output/boot hold the formal build again"
}

# shellcheck disable=SC2329  # installed as an EXIT trap
on_exit() {
	local rc=$? d
	rm -f "$KERNEL_SRC/.diting-stamp"
	if [ "$rc" != 0 ]; then
		d=("$OUT"/debs/linux-image-"$KERNEL_RELEASE"_*-"$KERNEL_DEB_REVISION"_arm64.deb)
		if [ "${#d[@]}" = 1 ] && [ "${d[0]}" -nt "$ref" ] && [ -d "$DITING_BACKUP/debs" ]; then
			warn "the run failed after an experimental package was built"
			isolate "$tag-failed"
		fi
		if [ "$applied" = 1 ]; then
			warn "the tree lost its stamp: the next make kernel re-exports the formal series"
		fi
	fi
	exit "$rc"
}

cmd_formal() {
	clean_export
	assert_formal
	build_kernel "$ref" clean
	build_boot "" ""
	make -C "$UD" verify
	save_formal
	log "formal build done"
}

cmd_exp() {
	local want_p=() skip=() want_s=() dry=0 p f base s patches=() cmdline
	local -A seen=()
	while getopts "p:x:s:n" opt; do
		case "$opt" in
		p) want_p+=("$OPTARG") ;;
		x) skip+=("$OPTARG") ;;
		s) want_s+=("$OPTARG") ;;
		n) dry=1 ;;
		*) usage ;;
		esac
	done
	[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "TAG must be a file name fragment"

	for p in "${want_p[@]}"; do
		if [ -f "$p" ]; then
			f=("$p")
		elif [ -f "$DITING_TOP/$p" ]; then
			f=("$DITING_TOP/$p")
		elif [ "$p" = all ]; then
			f=("$E"/EXPERIMENT-*.patch)
		else
			f=("$E/$p"-*.patch)
		fi
		[ "${#f[@]}" -gt 0 ] || die "no patch for '$p'"
		for pf in "${f[@]}"; do
			base="$(basename "$pf")"
			for s in "${skip[@]}"; do
				if [[ "$base" == *"-$s"-* ]]; then continue 2; fi
			done
			if [ -z "${seen[$pf]:-}" ]; then patches+=("$pf"); fi
			seen[$pf]=1
		done
	done
	for s in "${want_s[@]}"; do
		[ -f "$E/$s" ] || die "no script '$s' in kernel/patches-experimental"
	done
	[ "${#patches[@]}" -gt 0 ] || [ "${#want_s[@]}" -gt 0 ] || die "nothing to apply: use -p and/or -s"

	if [ "$dry" = 0 ]; then
		f=("$DITING_BACKUP"/debs/linux-image-"$KERNEL_RELEASE"_*-"$KERNEL_DEB_REVISION"_arm64.deb)
		[ "${#f[@]}" = 1 ] || die "no formal kernel package in $DITING_BACKUP; run 'exp-build.sh formal' once"
		if [ "$(sha256_of "${f[0]}")" != "$(sha256_of "$(image_deb)")" ]; then
			warn "output/debs does not hold the formal package; it is replaced with the backup afterwards"
		fi
		cmdline="$(debug_cmdline)"
	fi

	clean_export
	assert_formal
	applied=1
	for p in "${patches[@]}"; do
		log "patch $(basename "$p")"
		patch -d "$KERNEL_SRC" -p1 --batch --fuzz=0 --no-backup-if-mismatch < "$p" ||
			die "$(basename "$p") does not apply cleanly (fuzz 0)"
	done
	for s in "${want_s[@]}"; do
		log "script $s"
		python3 "$E/$s" "$KERNEL_SRC"
	done
	leftovers="$(find "$KERNEL_SRC" \( -name '*.rej' -o \( -name '*.orig' -newer "$ref" \) \) 2>/dev/null)"
	[ -z "$leftovers" ] || die "patch leftovers: $(echo "$leftovers" | tr '\n' ' ')"
	log "markers in the tree:"
	report_markers
	if [ "$dry" = 1 ]; then
		log "dry run: nothing built"
		return 0
	fi

	build_kernel "$ref" ""
	build_boot "$cmdline" "modprobe.blacklist=qcom_iris"
	make -C "$UD" verify
	isolate "$tag"
	log "exp $tag done"
}

# ---------------------------------------------------------------- main --------
mode="${1:-}"
tag=""
case "$mode" in
formal) [ "$#" = 1 ] || usage ;;
exp)
	[ "$#" -ge 2 ] || usage
	tag="$2"
	shift 2 # what is left are the options of cmd_exp
	;;
*) usage ;;
esac

DITING_BACKUP="$OUT/.formal-backup"
ref="$(mktemp)"
applied=0 # set as soon as patches or scripts change the tree
trap 'rm -f "$ref"' EXIT
mkdir -p "$OUT/logs"
logf="$OUT/logs/exp-${tag:-$mode}-$(date +%Y%m%d-%H%M%S).log"

run() {
	log "log: ${logf#"$UD/"}"
	case "$mode" in
	formal) cmd_formal ;;
	exp)
		# From here on the tree is not formal any more, whatever happens.
		trap on_exit EXIT
		cmd_exp "$@"
		;;
	esac
}
status=0
run "$@" 2>&1 | tee -a "$logf" || status=$?
exit "$status"
