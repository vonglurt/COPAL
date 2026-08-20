#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/fresh.sh -- make fresh
#
#  Delete the VM image and build it again from nothing.
#
#  THIS DESTROYS build/copal-vm.img. It is also the one to run after changing
#  copal-prep.sh: nothing else notices that the script and the image have
#  diverged, because make will not spend a card-sized file and an install on
#  a guess.
#
#  An interrupted install resumes from the middle rather than starting over,
#  so a half-finished image boots into the middle of stage 1 and skips what
#  came before. Build fresh whenever the result is meant to mean something.
#
#      bin/fresh.sh MODEL=vmx86
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make fresh "$@"
