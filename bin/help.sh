#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/help.sh -- make help
#
#  Print the full make target list.
#
#  The same thing `make` on its own prints. For what THIS folder holds, run
#  bin/ls.sh or read bin/README.md.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make help "$@"
