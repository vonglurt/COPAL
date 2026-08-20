#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/auto.sh -- make auto
#
#  Build the VM image from nothing, unattended.
#
#  script(1) supplies a tty and every step gate is answered with Enter. The
#  transcript is build/copal-prep-auto.log, and the verdict is read out of
#  that transcript rather than taken from an exit status.
#
#  IMAGES ONLY, and safe only because of that -- the two typed ERASE
#  confirmations exist for cards and are skipped when the target is a file.
#  Never point this at a device.
#
#  One caveat: the three `sudo fdisk -e` calls get no password this way, so
#  the MBR type bytes stay unset. The image boots regardless, but it is not
#  byte-identical to an attended build.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make auto "$@"
