#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
# run-sys7.sh -- System 7.0.1 profile: install onto a hard disk image.
#
# Apple's System_7.0.1.smi.bin is a Self Mounting Image, which needs a running
# System 7 to open -- the chicken-and-egg problem Gryphel's recipe solves:
#   https://www.gryphel.com/c/minivmac/recipes/sys7inst/
# Boot something that already runs, use ImportFl to bring the .smi.bin inside,
# then run Apple's installer onto disk1.
set -eu
. "$(dirname "$0")/lib-profile.sh"
require_bits
say "Profile: System 7.0.1 -- install onto a hard disk"
profile_init sys7

# disk1 is the install target. Unformatted images cannot boot, so the Mac
# falls through to the boot floppy and offers to initialise this one.
make_blank "$HERE/sys7-hd.dsk" 200
add_disk "$HERE/sys7-hd.dsk"

BOOT="${SYS7_BOOT:-$HERE/sys7boot.dsk}"
if [ -e "$BOOT" ]; then
    add_disk "$BOOT"
else
    warn "no bootable image at $BOOT -- nothing will boot yet"
    note "Set SYS7_BOOT=/path/to/bootable.dsk, or follow the recipe above."
fi
[ -e "$HERE/System_7.0.1.smi.bin" ] \
    && note "System_7.0.1.smi.bin is here; import it with ImportFl once booted"
[ -e "$HERE/shared.dsk" ] && add_disk "$HERE/shared.dsk"
launch "$@"
