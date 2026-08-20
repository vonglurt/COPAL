#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/space.sh -- make space
#
#  Say what is here, what it costs, and what removes it.
#
#  Removes nothing itself. Sizes are du and never ls, because the images are
#  sparse: a 64 GB image occupies about 550 MB fresh and 15-25 GB after a
#  full fifteen-stage run.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make space "$@"
