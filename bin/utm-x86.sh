#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/utm-x86.sh -- make utm-x86
#
#  Register the x86_64 machine with UTM and start it.
#
#  For this image UTM is not one of two ways to boot it but the only one:
#  copal-vm.sh runs qemu-system-aarch64. Emulated by TCG, so expect it to be
#  slow, and the serial console is on ttyS0 rather than ttyAMA0.
#
#  If utmctl reports "Virtual machine not found" straight after creating the
#  bundle, UTM was already running and has not rescanned its folder. Register
#  it by opening the bundle itself, then run this again:
#
#      open -a UTM ~/Library/Containers/com.utmapp.UTM/Data/Documents/Copal-x86_64.utm
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make utm-x86 "$@"
