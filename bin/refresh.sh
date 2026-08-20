#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/refresh.sh -- make refresh
#
#  Rewrite only the generated files on an existing card.
#
#  The rest of the card is left alone. Uses MODEL=vm unless told otherwise:
#
#      bin/refresh.sh MODEL=zero2
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make refresh "$@"
