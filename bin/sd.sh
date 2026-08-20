#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/sd.sh BOARD -- make sd-BOARD
#
#  Write a physical card for BOARD.
#
#  copal-prep.sh picks the disk and asks for both typed ERASE confirmations,
#  and nothing here skips either of them -- that is the entire safety model
#  for this path.
#
#      bin/sd.sh zero2        bin/sd.sh pi4        bin/sd.sh pc
#
#  BOARD is any name copal-prep.sh takes. pizero2 and pizero work too, since
#  that is what fingers type. With no BOARD this prints the list.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1

if [ $# -lt 1 ]; then
    printf 'usage: %s BOARD [VAR=value ...]\n\n' "$(basename "$0")" >&2
    ./copal --targets 2>/dev/null | sed 's/^/  /' >&2
    exit 2
fi

board=$1
shift
exec make "sd-$board" "$@"
