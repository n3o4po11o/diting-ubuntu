#!/bin/bash
# Build mobile-config-firefox (postmarketOS' Firefox configuration, not in
# Ubuntu) from the pinned upstream commit, in the arm64 buildd chroot.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib-buildd.sh"
need git

UPSTREAM="$DITING_TOP/references/mobile-config-firefox"
have_ref mobile-config-firefox "$MOBILE_CONFIG_FIREFOX_URL" "$MOBILE_CONFIG_FIREFOX_COMMIT"
src="$WORK/mobile-config-firefox-pkg"
rm -rf "$src" && mkdir -p "$src"
git -C "$UPSTREAM" archive "$MOBILE_CONFIG_FIREFOX_COMMIT" | tar -x -C "$src"
cp -a "$UD/packages/mobile-config-firefox/debian" "$src/debian"

buildd_setup
buildd_build "$src" mobile-config-firefox
