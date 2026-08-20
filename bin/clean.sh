#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  bin/clean.sh -- make clean
#
#  Remove the images, logs and generated config. Keeps the cache.
#
#  The EFI variable stores and transcripts go too, along with the generated
#  config carrying the git identity, username and SSH key. Reports what it
#  freed. build/cache survives -- those are checksum-verified Alpine payloads
#  that cost bandwidth rather than CPU to replace -- and so do registered UTM
#  machines, which live in UTM's container and are nobody's business here.
#
#  Run bin/space.sh first if you want to see the bill before paying it.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
exec make clean "$@"
