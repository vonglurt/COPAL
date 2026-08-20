#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/fresh-img.sh BOARD -- make fresh-img-BOARD
#
#  Build build/copal-BOARD.img from nothing.
#
#  bin/img.sh with the image deleted first. The same relationship bin/fresh.sh
#  has to bin/image.sh.
#
#      bin/fresh-img.sh pc
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
exec make "fresh-img-$board" "$@"
