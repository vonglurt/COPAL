#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/menu.sh -- make menu
#
#  Open ./copal, the front door.
#
#  A flow chart, a target menu, and a per-target briefing covering equipment,
#  CPU, minimum requirements and expected use. It writes nothing and touches
#  no disk. This is the one to run first.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make menu "$@"
