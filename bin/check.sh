#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/check.sh -- make check
#
#  Boot headless and exit non-zero if no login prompt arrived.
#
#  The transcript lands in build/copal-vm-check.log. This is the one to put
#  in front of anything automated, since it is the only VM target whose exit
#  status is worth believing.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make check "$@"
