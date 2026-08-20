#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/utm.sh -- make utm
#
#  Register the aarch64 machine with UTM and start it.
#
#  Creates the VM only if there is not one already, and never replaces one;
#  running it twice is safe and destroys nothing.
#
#  The machine lives in UTM's own container, not in this checkout: it survives
#  clean, distclean, and deleting the repository. Removing it is
#  utm/utm-vm.sh delete --target aarch64, which no make target does for you.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make utm "$@"
