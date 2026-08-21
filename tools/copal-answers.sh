#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  COPAL ALPINE LINUX -- collect the answers an unattended install needs.
#
# `make answers` asks the handful of questions that would otherwise stop the
# install dead an hour in, and writes them to answers.txt in the project root.
# copal-prep.sh sources that file at build time and copies the COPAL_* values
# onto the card, where copal-init.sh reads them back.
#
# THE PASSWORD IS NOT STORED. What is stored is its SHA-512 crypt hash -- the
# same string /etc/shadow holds -- so the file, and every image built from it,
# can be read by anyone without giving up the password. Stage 1 applies it with
# `chpasswd -e`, which takes an already-hashed value.
#
# The default is 'hunter2', which is a joke, and deliberately so: these VMs are
# ephemeral and rebuilt constantly, and automated testing needs a password it
# already knows. Set a real one here for anything that outlives an afternoon --
# that is the whole point of this being a file you can edit.
#
# Usage:
#   tools/copal-answers.sh              ask, then write answers.txt
#   tools/copal-answers.sh --show       print the current answers, no password
#   tools/copal-answers.sh --force      overwrite without confirming
set -euo pipefail

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANSWERS="$ROOT/answers.txt"
CRYPT="$ROOT/tools/sha512-crypt.py"
FORCE=0
SHOW=0
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        --show)  SHOW=1 ;;
        -h|--help) sed -n '5,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument '$a'. See --help." ;;
    esac
done

if [ "$SHOW" -eq 1 ]; then
    [ -f "$ANSWERS" ] || die "no answers.txt yet. Run: make answers"
    # The hash is a hash, but printing it invites shoulder-surfing a offline
    # crack, so it is shown as its presence only.
    sed "s/^\\(COPAL_ROOT_PW_HASH=\\).*/\\1<set>/" "$ANSWERS"
    exit 0
fi

[ -x "$CRYPT" ] || die "missing $CRYPT"
python3 "$CRYPT" --selftest >/dev/null 2>&1 \
    || die "sha512-crypt self-test failed -- refusing to write a hash I cannot trust"

if [ -f "$ANSWERS" ] && [ "$FORCE" -eq 0 ]; then
    info "answers.txt already exists."
    note "Its current values are the defaults below -- press Enter to keep each."
fi

# Existing answers become the defaults, so re-running this to change one thing
# does not mean retyping the rest.
#
# PARSED, not sourced, and that distinction is load-bearing. Sourcing a file
# whose hash line reads COPAL_ROOT_PW_HASH="$6$rounds=..." expands $6 as a
# positional parameter, and under `set -u` that is not a warning, it is the end
# of the script -- which is exactly how this was found. Parsing also means a
# file hand-edited into either quoting style still reads correctly.
get_answer() {  # <variable name>
    [ -f "$ANSWERS" ] || return 0
    sed -n "s/^$1=[\"']\{0,1\}\(.*\)/\1/p" "$ANSWERS" \
        | sed "s/[\"']\{0,1\}[[:space:]]*$//" | head -1
}
if [ -f "$ANSWERS" ]; then
    COPAL_GIT_NAME=$(get_answer COPAL_GIT_NAME)
    COPAL_GIT_EMAIL=$(get_answer COPAL_GIT_EMAIL)
    COPAL_USER=$(get_answer COPAL_USER)
    COPAL_HOSTNAME=$(get_answer COPAL_HOSTNAME)
    COPAL_TIMEZONE=$(get_answer COPAL_TIMEZONE)
    COPAL_KEYMAP=$(get_answer COPAL_KEYMAP)
    COPAL_ROOT_PW_HASH=$(get_answer COPAL_ROOT_PW_HASH)
    COPAL_AUTO=$(get_answer COPAL_AUTO)
fi

# The hostname pool -- 300 oceans, seas, lakes and rivers -- lives in
# copal-prep.sh, and is LIFTED from there rather than copied. Two copies of a
# 300-word list is two lists that drift, and the reason the pool exists at all
# is that a fixed default stops being unique the moment there is a second
# machine on the network. Sourcing copal-prep.sh outright is not an option: it
# would run a disk-writing script to ask a question. So the two functions are
# cut out by name and evaluated on their own.
#
# If that extraction ever fails -- the functions renamed, copal-prep.sh moved
# -- the fallback is a fixed name and a note saying so, not a broken prompt.
PREP="$ROOT/copal-prep.sh"
if [ -r "$PREP" ] \
   && _pool=$(sed -n '/^hostname_pool() {/,/^}/p;/^random_hostname() {/,/^}/p' "$PREP") \
   && [ -n "$_pool" ]; then
    eval "$_pool"
else
    random_hostname() { printf 'copal\n'; }
    note "could not read the hostname pool from copal-prep.sh -- using 'copal'"
fi

ask() {  # <prompt> <default> <variable name>
    local _p="$1" _d="$2" _v="$3" _r=""
    if [ -n "$_d" ]; then
        printf '  %s [%s]: ' "$_p" "$_d" >&2
    else
        printf '  %s: ' "$_p" >&2
    fi
    IFS= read -r _r || true
    [ -n "$_r" ] || _r="$_d"
    printf -v "$_v" '%s' "$_r"
}

printf '\n\033[1mCopal -- answers for an unattended install\033[0m\n\n'
note "Anything answered here stops being a question during the install."
note "Enter alone keeps the value in brackets."
note "The hostname offered is picked at random from 300 oceans, seas, lakes"
note "and rivers -- a fixed name stops being unique at the second machine."
note "Once answers.txt exists its own hostname is the default, not a new one."
printf '\n'

# Identity. The git config on this Mac is the best guess available, and is
# what copal-prep.sh already falls back to when there is no answers file.
_def_name="${COPAL_GIT_NAME:-$(git config --global --get user.name 2>/dev/null || true)}"
_def_email="${COPAL_GIT_EMAIL:-$(git config --global --get user.email 2>/dev/null || true)}"
ask "Name for git commits"   "$_def_name"                 COPAL_GIT_NAME
ask "Email for git commits"  "$_def_email"                COPAL_GIT_EMAIL
ask "Login name in the guest" "${COPAL_USER:-user}"       COPAL_USER
ask "Hostname"               "${COPAL_HOSTNAME:-$(random_hostname)}" COPAL_HOSTNAME
ask "Timezone"               "${COPAL_TIMEZONE:-US/Pacific}" COPAL_TIMEZONE
ask "Keymap"                 "${COPAL_KEYMAP:-us us}"     COPAL_KEYMAP

# The password. Read twice with echo off, never written anywhere in the clear,
# and never passed as an argument -- an argument is visible in ps to every
# process on the machine, so it goes to the hasher on stdin.
printf '\n'
note "Root password. Also becomes '$COPAL_USER's, as it does today."
if [ -n "${COPAL_ROOT_PW_HASH:-}" ]; then
    note "A password is already on file. Enter alone keeps it; type a new one"
    note "to replace it. There is no way to display the old one."
else
    note "Enter alone sets it to 'hunter2' -- a joke, and fine for a VM that is"
    note "rebuilt every day. Wrong for anything that outlives an afternoon."
fi
# What Enter alone does depends on whether a password is already on file, so
# the prompt says which -- on the line being typed at, not three lines above
# it where it scrolls out of view behind the notes.
if [ -n "${COPAL_ROOT_PW_HASH:-}" ]; then
    _pw_hint="Enter = keep current"
else
    _pw_hint="Enter = hunter2"
fi
_pw="" _pw2=""
while :; do
    printf '  Password [%s] (not echoed): ' "$_pw_hint" >&2
    IFS= read -rs _pw || true; printf '\n' >&2
    if [ -z "$_pw" ]; then
        if [ -n "${COPAL_ROOT_PW_HASH:-}" ]; then
            info "Keeping the password already in answers.txt."
            _pw=""
            break
        fi
        _pw="hunter2"
        info "Using the default: hunter2"
        break
    fi
    printf '  Again: ' >&2
    IFS= read -rs _pw2 || true; printf '\n' >&2
    [ "$_pw" = "$_pw2" ] && break
    printf '\033[33m  They did not match. Again.\033[0m\n' >&2
done

if [ -n "$_pw" ]; then
    COPAL_ROOT_PW_HASH=$(printf '%s\n' "$_pw" | python3 "$CRYPT" --rounds 656000)
    _pw="" _pw2=""
fi
[ -n "${COPAL_ROOT_PW_HASH:-}" ] || die "no password hash produced"

# SINGLE quotes, always, and this is not stylistic. A SHA-512 crypt hash
# begins "$6$rounds=..." -- inside double quotes the shell expands $6 as a
# positional parameter, which under `set -u` aborts copal-prep.sh outright and
# under setup-alpine on the card silently truncates the hash to "$rounds=...",
# locking the account. Names with an apostrophe are handled the POSIX way:
# close the quote, escape the apostrophe, reopen.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Written 0600 before anything goes in it, so there is no window where the
# file exists and is world-readable.
umask 077
: > "$ANSWERS"
cat > "$ANSWERS" <<EOF
# Copal -- answers for an unattended install.  Written by: make answers
#
# Edit this by hand or re-run 'make answers'; either way copal-prep.sh picks it
# up on the next build. Changing anything here means rebuilding the image for
# it to take effect -- these values are baked onto the card, not read at boot.
#
# COPAL_ROOT_PW_HASH is a SHA-512 crypt hash, the same string /etc/shadow
# holds. The password itself is not here and cannot be recovered from this.
# Replace it by running 'make answers' again, not by editing this line.
#
# This file is listed in .gitignore. Keep it that way.

COPAL_GIT_NAME=$(sq "${COPAL_GIT_NAME}")
COPAL_GIT_EMAIL=$(sq "${COPAL_GIT_EMAIL}")
COPAL_USER=$(sq "${COPAL_USER}")
COPAL_HOSTNAME=$(sq "${COPAL_HOSTNAME}")
COPAL_TIMEZONE=$(sq "${COPAL_TIMEZONE}")
COPAL_KEYMAP=$(sq "${COPAL_KEYMAP}")
COPAL_ROOT_PW_HASH=$(sq "${COPAL_ROOT_PW_HASH}")

# 1 = do not stop to ask anything the values above can answer.
COPAL_AUTO=$(sq "${COPAL_AUTO:-1}")
EOF
chmod 600 "$ANSWERS"

info "Wrote $ANSWERS (mode 600)"
note ""
note "  git identity   ${COPAL_GIT_NAME} <${COPAL_GIT_EMAIL}>"
note "  user           ${COPAL_USER}"
note "  hostname       ${COPAL_HOSTNAME}"
note "  root password  stored as a SHA-512 hash, not recoverable"
note ""
note "The next 'make alldebug' builds images that install without stopping."
