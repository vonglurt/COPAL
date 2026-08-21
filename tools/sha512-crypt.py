#!/usr/bin/env python3
"""sha512-crypt, because macOS cannot do it.

`make answers` needs to turn a typed password into the $6$ hash that
/etc/shadow wants, on the Mac, before the image is built. Every obvious way to
do that is missing or broken here:

    openssl passwd -6      LibreSSL 3.3.6 -- "unknown option '-6'"
    python3 -c 'crypt...'  macOS crypt(3) has no SHA-512; it silently falls
                           back to DES and returns a 13-character hash whose
                           first characters happen to look like "$6..."
    mkpasswd               not on macOS; it is Debian's whois package
    passlib                not installed, and not worth a dependency

So the algorithm is implemented here, from Ulrich Drepper's specification. It
is fiddly but entirely deterministic, and the test vectors at the bottom are
his -- run this file directly to check them. If they pass, the output is
byte-identical to what Alpine's own crypt would have produced.

Usage:  sha512-crypt.py [--rounds N] [--salt S]      password on stdin
        sha512-crypt.py --selftest
"""
import base64
import hashlib
import os
import sys

# crypt(3) uses its own base64 alphabet and its own little-endian bit order.
B64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
ROUNDS_DEFAULT = 5000
ROUNDS_MIN = 1000
ROUNDS_MAX = 999999999


def _b64_from_24bit(b2, b1, b0, n):
    w = (b2 << 16) | (b1 << 8) | b0
    return "".join(B64[(w >> (6 * i)) & 0x3F] for i in range(n))


def sha512_crypt(password, salt=None, rounds=ROUNDS_DEFAULT):
    """Return the $6$ hash of password. salt is at most 16 chars from B64."""
    if isinstance(password, str):
        password = password.encode("utf-8")
    if salt is None:
        salt = "".join(B64[c & 0x3F] for c in os.urandom(16))
    salt = salt[:16]
    explicit_rounds = rounds != ROUNDS_DEFAULT
    rounds = max(ROUNDS_MIN, min(ROUNDS_MAX, rounds))
    s = salt.encode("ascii")

    # Digest B: password, salt, password.
    b = hashlib.sha512(password + s + password).digest()

    # Digest A: password, salt, then B repeated for the length of the
    # password, then one byte per bit of the password length -- B for a 1 bit
    # and the password itself for a 0, taken from the low bit upwards.
    a = hashlib.sha512()
    a.update(password + s)
    plen = len(password)
    a.update(b * (plen // 64) + b[: plen % 64])
    n = plen
    while n:
        a.update(b if n & 1 else password)
        n >>= 1
    a = a.digest()

    # DP: the password repeated once per character, hashed. DS likewise for
    # the salt, but repeated 16 + the first byte of A times.
    dp = hashlib.sha512(password * plen).digest()
    p = dp * (plen // 64) + dp[: plen % 64]
    ds = hashlib.sha512(s * (16 + a[0])).digest()
    sq = ds * (len(s) // 64) + ds[: len(s) % 64]

    # The stretch. Alternate which of P and S goes in, and on which side.
    c = a
    for i in range(rounds):
        h = hashlib.sha512()
        h.update(p if i & 1 else c)
        if i % 3:
            h.update(sq)
        if i % 7:
            h.update(p)
        h.update(c if i & 1 else p)
        c = h.digest()

    # The output permutation -- not the digest order, a fixed shuffle.
    order = [
        (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
        (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
        (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13), (56, 14, 35),
        (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19),
        (62, 20, 41),
    ]
    out = "".join(_b64_from_24bit(c[x], c[y], c[z], 4) for x, y, z in order)
    out += _b64_from_24bit(0, 0, c[63], 2)

    prefix = "$6$"
    if explicit_rounds:
        prefix += "rounds=%d$" % rounds
    return prefix + salt + "$" + out


# Drepper's published vectors, verbatim. These are the whole warrant for
# trusting the code above.
VECTORS = [
    ("Hello world!", "saltstring", ROUNDS_DEFAULT,
     "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJu"
     "esI68u4OTLiBFdcbYEdFCoEOfaS35inz1"),
    ("Hello world!", "saltstringsaltstring", 10000,
     "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sb"
     "HbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v."),
    ("This is just a test", "toolongsaltstring", 5000,
     "$6$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7"
     "oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0"),
]


def selftest():
    ok = True
    for pw, salt, rounds, want in VECTORS:
        got = sha512_crypt(pw, salt, rounds)
        mark = "ok  " if got == want else "FAIL"
        if got != want:
            ok = False
        print("%s  %-22r rounds=%d" % (mark, pw, rounds))
        if got != want:
            print("      want %s\n      got  %s" % (want, got))
    return 0 if ok else 1


def main(argv):
    if "--selftest" in argv:
        return selftest()
    salt, rounds = None, ROUNDS_DEFAULT
    i = 1
    while i < len(argv):
        if argv[i] == "--salt":
            salt = argv[i + 1]; i += 2
        elif argv[i] == "--rounds":
            rounds = int(argv[i + 1]); i += 2
        else:
            sys.stderr.write("unknown argument %r\n" % argv[i])
            return 2
    pw = sys.stdin.readline().rstrip("\n")
    if not pw:
        sys.stderr.write("sha512-crypt: empty password on stdin\n")
        return 2
    print(sha512_crypt(pw, salt, rounds))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
