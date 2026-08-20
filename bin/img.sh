#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/img.sh BOARD -- make img-BOARD
#
#  Write BOARD to build/copal-BOARD.img instead of a card.
#
#  Named for the board so several can coexist -- copal-zero2.img beside
#  copal-pc.img -- rather than colliding on one name. No disk is touched and
#  nothing is erased.
#
#      bin/img.sh pc          bin/img.sh zero2
#
#  With no BOARD this prints the list.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1

if [ $# -lt 1 ]; then
    printf 'usage: %s BOARD [VAR=value ...]\n\n' "$(basename "$0")" >&2
    ./copal --targets 2>/dev/null | sed 's/^/  /' >&2
    exit 2
fi

board=$1
shift
exec make "img-$board" "$@"
