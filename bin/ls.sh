#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/ls.sh -- the index of this folder
#
#  List every shortcut in this folder and what it runs.
#
#  Each one's name, the make target behind it, and the summary line out of
#  its own header. Nothing is described twice: this reads the scripts, so a
#  shortcut that changes its summary says so here by itself, and a new one
#  appears without anybody editing a list.
set -eu
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

B='\033[1m'; D='\033[2m'; C='\033[36m'; Z='\033[0m'
[ -t 1 ] || { B=''; D=''; C=''; Z=''; }

printf '\n%bCopal Linux -- bin/%b  %bshortcuts to the make targets%b\n\n' "$B" "$Z" "$D" "$Z"

for f in "$HERE"/*.sh; do
    name=$(basename "$f")
    # "#  bin/vm.sh -- make vm"  ->  runs="make vm".  ls.sh runs no target and
    # falls through to the dash.
    runs=$(sed -n 's/^#  bin\/[A-Za-z0-9._-]*\( BOARD\)\{0,1\} -- \(make .*\)$/\2/p' "$f" | head -1)
    [ -n "$runs" ] || runs='--'
    # The summary line: the first prose line under the header line. Matched
    # once and only on the header, since later paragraphs open with a
    # "bin/..." cross-reference too and would otherwise win.
    desc=$(awk 'seen == 0 && /^#  bin\/[A-Za-z0-9._-]*.* -- / { seen = 1; next }
                seen == 1 && /^#$/  { next }
                seen == 1 && /^#  / { sub(/^#  /, ""); print; exit }' "$f")
    printf '  %b%-17s%b %b%-20s%b %s\n' "$C" "$name" "$Z" "$D" "$runs" "$Z" "$desc"
done

printf '\n  %bEvery one takes the same variables the make target does:%b\n' "$D" "$Z"
printf '  %bbin/vm.sh MEM=4096 CPUS=4   bin/fresh.sh MODEL=vmx86   bin/refresh.sh MODEL=zero2%b\n\n' "$D" "$Z"
