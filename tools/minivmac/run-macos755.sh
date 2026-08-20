#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
# run-macos755.sh -- ready-made System 7.5.5 disk. Nothing to install.
#
# macOS755.dsk is a 2 GB HFS volume -- the largest a classic Mac can address,
# since HFS tops out at 65536 allocation blocks. It boots straight up.
set -eu
. "$(dirname "$0")/lib-profile.sh"
require_bits
say "Profile: System 7.5.5 -- ready to boot"
profile_init macos755

IMG="${MACOS755_IMG:-$HERE/macOS755.dsk}"
if [ ! -e "$IMG" ] && [ -e "$HERE/macOS755.dsk.zip" ]; then
    say "Unpacking macOS755.dsk.zip (2 GB extracted -- this takes a while)"
    AVAIL=$(df -m "$HERE" | awk 'NR==2 {print $4}')
    [ "$AVAIL" -lt 2200 ] && die "only ${AVAIL} MB free; need ~2.1 GB"
    unzip -o -j "$HERE/macOS755.dsk.zip" 'macOS755.dsk' -d "$HERE"
fi
[ -e "$IMG" ] || die "no macOS755.dsk and no zip to unpack"
add_disk "$IMG"
[ -e "$HERE/shared.dsk" ] && add_disk "$HERE/shared.dsk"

note "System 7.5.5 on a 4 MB Mac Plus is tight but works; if it is unhappy,"
note "Control-S raises the emulated CPU speed."
launch "$@"
