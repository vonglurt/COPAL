#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/lint.sh -- make lint
#
#  Syntax-check the scripts, generated and shortcuts included.
#
#  sh -n on copal-prep.sh, copal-vm.sh, fetch-minivmac.sh, and on the
#  copal-init.sh that exists only as a heredoc until a card is written -- a
#  syntax error in that one survives every check that reads copal-prep.sh
#  alone, and lands on the hardware.
#
#  It also checks that every shortcut in this folder still names a real make
#  target, so bin/ cannot quietly rot into a list of things that used to work.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make lint "$@"
