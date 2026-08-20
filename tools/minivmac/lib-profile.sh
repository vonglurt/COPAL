#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
# lib-profile.sh -- shared by the run-*.sh launchers. Not run directly.
#
# Each profile gets its own directory containing the emulator binary, the ROM,
# and symlinks named disk1.dsk, disk2.dsk... in mount order. Mini vMac mounts
# those automatically at startup and boots the first one with a System Folder.
#
# Everything is co-located inside the profile directory on purpose: Mini vMac
# looks for its disk images alongside the application, so linking the binary in
# rather than calling it by path avoids depending on which of the two it uses.

HERE="$(cd "$(dirname "$0")" && pwd)"
ROM="$HERE/vMac.ROM"
BIN="${MINIVMAC_BIN:-$HERE/minivmac}"

say()  { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_bits() {
    [ -f "$ROM" ] || die "no vMac.ROM in $HERE -- run ../fetch-minivmac.sh --rom <file>"
    if [ ! -x "$BIN" ]; then
        cat >&2 <<EOF
error: no Mini vMac binary at $BIN

Build it first:
    cd $HERE
    tar xzf minivmac-*.src.tgz
    cd minivmac                       # the archive has its own top directory
    gcc setup/tool.c -o setup_t
    ./setup_t -t larm > setup.sh      # larm on the Pi; lx64 on an Intel Mac
    . ./setup.sh
    make
    cp minivmac $HERE/

Or set MINIVMAC_BIN=/path/to/minivmac.
EOF
        exit 1
    fi
}

# profile_init <name>  -- make a clean profile dir with the binary and ROM
profile_init() {
    PROFILE="$HERE/profiles/$1"
    mkdir -p "$PROFILE"
    # Relink from scratch each launch so a changed disk list cannot leave a
    # stale diskN.dsk behind, which would silently mount the wrong thing.
    rm -f "$PROFILE"/disk[0-9].dsk
    ln -sf "$ROM" "$PROFILE/vMac.ROM"
    ln -sf "$BIN" "$PROFILE/minivmac"
    DISKNUM=0
}

# add_disk <path> -- attach as the next diskN.dsk
add_disk() {
    [ -e "$1" ] || { warn "missing disk image: $1"; return 1; }
    DISKNUM=$((DISKNUM + 1))
    ln -sf "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" "$PROFILE/disk$DISKNUM.dsk"
    note "disk$DISKNUM.dsk -> $(basename "$1")  ($(du -h "$1" | cut -f1))"
}

# make_blank <path> <megabytes> -- an unformatted image; the Mac offers to
# initialise it on first boot, which is how it gets an HFS filesystem.
make_blank() {
    [ -f "$1" ] && return 0
    dd if=/dev/zero of="$1" bs=1048576 count="$2" 2>/dev/null
    note "created $(basename "$1") (${2} MB, unformatted)"
}

launch() {
    say "Starting Mini vMac"
    note "profile: $PROFILE"
    cat <<'KEYS'

    Control-H  list commands      Control-R  reset      Control-Q  quit
    Control-S  CPU speed          Control-M  magnify    Control-F  full screen

    Insert a floppy while running: DRAG the .dsk onto the window.
    (Control-O is Mac/Windows only -- there is no open dialog on Linux.)
    Eject from inside the Mac: drag to Trash, or Command-E. Command is Alt.

KEYS
    cd "$PROFILE" || die "cannot enter $PROFILE"
    exec ./minivmac "$@"
}
