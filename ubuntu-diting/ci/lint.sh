#!/bin/bash
# What the lint job of .github/workflows/build.yml runs: shellcheck over the
# shell scripts of the Makefile's lint target, of this directory and of
# release/ (the scripts shipped with the images). An error-level finding
# fails. Meant to run in the builder image, so that the result depends on
# the shellcheck version pinned there and not on the host:
#
#   docker run --rm -v "$PWD:/src" -w /src diting-builder:<rev> ubuntu-diting/ci/lint.sh
#
# The Makefile's target cannot be used as it is: it hands the Python programs
# of packages/device-xiaomi-diting/src to shellcheck, which rejects them, so
# it fails on every tree. Here the shell scripts are told by their shebang.
set -euo pipefail

UD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$UD/packages/device-xiaomi-diting"
shebang='^#!([^ ]*/)?(env +)?(ba|da|k)?sh( |$)'

grep -rIlE "$shebang" \
	"$UD"/ci "$UD"/scripts "$UD"/release \
	"$D"/src "$D"/initramfs-tools/hooks "$D"/initramfs-tools/scripts/init-top \
	"$D"/etc/zz-diting-bootimg |
	sort | xargs -r shellcheck -x -S error
