#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
# run-sys6.sh -- System 6 profile: build your own disks from blanks.
#
# System 6 boots from a floppy and is small enough that a 400K/800K image
# holds a working system, so this is the route for making disks by hand.
# You need a bootable System 6 disk image; Gryphel's recipe walks through
# producing one:  https://www.gryphel.com/c/minivmac/recipes/sys6util/
set -eu
. "$(dirname "$0")/lib-profile.sh"
require_bits
say "Profile: System 6 -- roll your own disks"
profile_init sys6

BOOT="${SYS6_BOOT:-$HERE/sys6boot.dsk}"
if [ -e "$BOOT" ]; then
    add_disk "$BOOT"
else
    warn "no bootable System 6 image at $BOOT"
    note "Put one there, or set SYS6_BOOT=/path/to/image.dsk"
    note "Recipe: https://www.gryphel.com/c/minivmac/recipes/sys6util/"
    note "Gryphel's blanks-*.zip (already downloaded) has empty 400K/800K images."
fi

# A scratch floppy and a small hard disk to build onto.
make_blank "$HERE/sys6-work.dsk" 20
add_disk "$HERE/sys6-work.dsk" || true
[ -e "$HERE/shared.dsk" ] && add_disk "$HERE/shared.dsk"
launch "$@"
