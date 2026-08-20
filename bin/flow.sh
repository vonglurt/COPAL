#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/flow.sh -- make flow
#
#  Print the flow chart alone.
#
#  The same chart bin/menu.sh opens with, without the menu around it.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make flow "$@"
