#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/vm.sh -- make vm
#
#  Boot the VM with the serial console on this terminal.
#
#  Builds build/copal-vm.img first if it is absent. Ctrl-A X quits, Ctrl-A C
#  for the QEMU monitor.
#
#  An existing image is never rebuilt here. After changing copal-prep.sh it is
#  bin/fresh.sh that you want.
#
#      bin/vm.sh MEM=4096 CPUS=4
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make vm "$@"
