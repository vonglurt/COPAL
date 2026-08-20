#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/image.sh -- make image
#
#  Build the VM image only if it is absent.
#
#  Never rebuilds an existing one, so this is the safe one to put in front of
#  something else. bin/fresh.sh is how you ask for a new image.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make image "$@"
