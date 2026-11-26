#!/bin/bash
# On the phone, as root: bring /lib/modules/<release> in step with a kernel
# that was built after its configuration changed, when only the boot image is
# written and the package is not installed.
#
# usage: phone-modules-sync.sh METADATA_TARBALL [RELEASE]
#
# The tarball holds modules.builtin, modules.builtin.modinfo and modules.order
# of the new build; take them out of its package:
#     ar p linux-image-*.deb data.tar.xz |
#         tar -xJ -C DIR --strip-components=4 ./lib/modules/<release>/modules.builtin \
#             ./lib/modules/<release>/modules.builtin.modinfo ./lib/modules/<release>/modules.order
#
# Every .ko on the phone that the new kernel has built in is moved away: the
# kernel refuses to load a module of a name it has built in ("exports
# duplicate symbol"), and while the file is there a dependency line on it
# stops modprobe from loading what needs it. (2026-11-26: libarc4 had become
# built in, mac80211.ko still depended on libarc4.ko, and Wi-Fi never came
# up.) Then the lists of the new build are put in place and depmod runs.
# The files moved away and the old lists are kept in a tarball in /var/tmp.
set -eu

[ "$(id -u)" = 0 ] || { echo "$(basename "$0"): run as root" >&2; exit 1; }
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $(basename "$0") METADATA_TARBALL [RELEASE]" >&2; exit 2; }
release=${2:-$(uname -r)}
K=/lib/modules/$release
[ -d "$K/kernel" ] || { echo "$(basename "$0"): $K/kernel is not there" >&2; exit 1; }

t="$(mktemp -d /var/tmp/modules-sync.XXXXXX)"
trap 'rm -rf "$t"' EXIT
tar -xzf "$1" -C "$t"
for f in modules.builtin modules.builtin.modinfo modules.order; do
	[ -s "$t/$f" ] || { echo "$(basename "$0"): $f is not in $1" >&2; exit 1; }
done

# Kernel module by kernel module: is its file here? Then it is one too many.
: >"$t/stale"
n=0
while read -r mod; do
	[ -e "$K/$mod" ] && printf '%s\n' "${K#/}/$mod" >>"$t/stale" && n=$((n + 1))
done <"$t/modules.builtin"
[ "$n" -lt 200 ] || { echo "$(basename "$0"): $n modules became built in, more than this handles; install the package" >&2; exit 1; }

echo "modules the new kernel has built in whose files are here: $n"
[ "$n" -gt 0 ] && sed "s|^$K/||" "$t/stale" | tr '\n' ' ' && echo

# Paths are relative to /, as tar wants them.
lists=$(cd / && ls "$K"/modules.builtin "$K"/modules.builtin.modinfo "$K"/modules.order \
	"$K"/modules.dep "$K"/modules.alias "$K"/modules.symbols "$K"/modules.devname \
	"$K"/modules.softdep "$K"/modules.builtin.bin 2>/dev/null | sed 's|^/||' || true)
backup=/var/tmp/modules-tree-backup-$(date +%Y%m%d-%H%M%S).tgz
# shellcheck disable=SC2046
tar -czf "$backup" -C / $(cat "$t/stale") $lists
echo "backup: $backup ($(tar -tzf "$backup" | wc -l) entries)"

sed 's|^|/|' "$t/stale" | xargs -r rm -f
install -m 644 "$t/modules.builtin" "$t/modules.builtin.modinfo" "$t/modules.order" "$K/"
depmod -a "$release"

echo "modules.dep: $(wc -l <"$K/modules.dep") modules; built-in list: $(wc -l <"$K/modules.builtin") entries"
bad=0
while read -r mod deps; do
	for d in $deps; do
		[ -e "$K/$d" ] || { echo "$mod depends on $d, which is not there" >&2; bad=$((bad + 1)); }
	done
done <"$K/modules.dep"
[ "$bad" = 0 ] || { echo "$(basename "$0"): $bad dangling dependencies" >&2; exit 1; }
echo "no dependency points at a file that is gone"
