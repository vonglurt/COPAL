#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/distclean.sh -- make distclean
#
#  Remove all of that, and the download cache with it.
#
#  Everything bin/clean.sh takes, plus build/cache. The next build fetches
#  the Alpine payloads again, so this costs bandwidth on top of a rebuild.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make distclean "$@"
