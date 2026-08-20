#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/configure.sh -- make configure
#
#  Report what this Mac has and what it is missing.
#
#  Ends in a verdict. The required tools all ship with macOS, so a miss means
#  something is genuinely wrong with the host; qemu and UTM are wanted only by
#  the paths that use them and are reported without being fatal.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make configure "$@"
