#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/all.sh -- make all
#
#  Cache, build every board, and register both UTM machines.
#
#  Serial by necessity: every board's boot partition carries the same label,
#  so two builds cannot be mounted at once. This is the long one.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make all "$@"
