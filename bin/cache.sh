#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/cache.sh -- make cache
#
#  Download every architecture's payload and build nothing.
#
#  Serial by necessity: every board's boot partition carries the same label,
#  so two builds cannot be mounted at once. This is the long one.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make cache "$@"
