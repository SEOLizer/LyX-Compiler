#!/usr/bin/env python3
"""Unabhaengige Referenz fuer std.bits.

Liest die Ausgabe von tests/bits_fuzz.lyx und rechnet jede Bitoperation mit
Pythons beliebig langen Ganzzahlen nach — dort gibt es kein Vorzeichenbit und
kein arithmetisches Schieben, also auch nicht den Fehler, den die Lyx-Fassung
machen koennte.

Aus der Lyx-Ausgabe wird nur das WORT uebernommen; alles andere wird hier
neu gerechnet.
"""
import sys

M64 = (1 << 64) - 1


def u(x):
    """int64 (mit Vorzeichen) -> 64-Bit-Muster ohne Vorzeichen"""
    return x & M64


def s(x):
    """64-Bit-Muster -> int64 mit Vorzeichen, wie Lyx es ausgibt"""
    x &= M64
    return x - (1 << 64) if x >> 63 else x


def popcount(v):
    return bin(v).count("1")


def clz(v):
    return 64 if v == 0 else 64 - v.bit_length()


def ctz(v):
    if v == 0:
        return 64
    n = 0
    while not (v >> n) & 1:
        n += 1
    return n


def reverse(v):
    return int(format(v, "064b")[::-1], 2)


def swapbytes(v):
    return int.from_bytes(v.to_bytes(8, "little"), "big")


def pair_shr(hi, lo, n):
    """die 64 Bit ab Stelle n des 128-Bit-Paares (hi:lo)"""
    return (((hi << 64) | lo) >> n) & M64


def pair_shl(hi, lo, n):
    """die oberen 64 Bit des um n nach links geschobenen Paares"""
    return ((((hi << 64) | lo) << n) >> 64) & M64


def rot(v, n, width, left=True):
    """zyklisch drehen innerhalb von `width` Bit"""
    m = (1 << width) - 1
    v &= m
    k = n % width
    if k == 0:
        return v
    if not left:
        k = width - k
    return ((v << k) | (v >> (width - k))) & m


def gray_decode(g):
    v = g
    sh = 32
    while sh:
        v ^= v >> sh
        sh >>= 1
    return v


FIELDS = ("pop parity clz ctz highest lowest reverse swap shr shl "
          "rotl rotr gray graydec mask extract sar shlov y pairshr pairshl "
          "rotl32 rotr32 rotl16 rotl8 wd rotlN rotrN").split()


def main(path):
    fails = checks = 0
    cases = 0

    for ln in open(path):
        ln = ln.strip()
        if not ln.startswith("R "):
            continue
        vals = [int(t) for t in ln.split()[1:]]
        x_signed, n = vals[0], vals[1]
        got = dict(zip(FIELDS, vals[2:]))
        cases += 1

        v = u(x_signed)
        want = {
            "pop": popcount(v),
            "parity": popcount(v) & 1,
            "clz": clz(v),
            "ctz": ctz(v),
            "highest": -1 if v == 0 else v.bit_length() - 1,
            "lowest": -1 if v == 0 else ctz(v),
            "reverse": s(reverse(v)),
            "swap": s(swapbytes(v)),
            "shr": s(v >> n if n < 64 else 0),
            "shl": s((v << n) & M64 if n < 64 else 0),
            "rotl": s(((v << (n % 64)) | (v >> ((64 - n % 64) % 64))) & M64),
            "rotr": s(((v >> (n % 64)) | (v << ((64 - n % 64) % 64))) & M64),
            "gray": s(v ^ (v >> 1)),
            "graydec": s(v),                       # decode(encode(x)) == x
            "mask": s(M64 if n >= 64 else (1 << n) - 1),
            "extract": (v >> (n % 57)) & 0x7F,
            # arithmetisches Schieben mit gesaettigter Weite
            "sar": (x_signed >> n) if n < 64 else (-1 if x_signed < 0 else 0),
            # gehen beim Linksschieben Bits verloren?
            "shlov": 0 if v == 0 else (1 if (n >= 64 or (v >> (64 - n)) != 0) else 0),
            "y": got["y"],                       # nur durchgereicht
            "pairshr": s(pair_shr(v, u(got["y"]), n)),
            "pairshl": s(pair_shl(v, u(got["y"]), n)),
            "rotl32": rot(v, n, 32),
            "rotr32": rot(v, n, 32, left=False),
            "rotl16": rot(v, n, 16),
            "rotl8": rot(v, n, 8),
            "wd": got["wd"],                     # nur durchgereicht
            "rotlN": s(rot(v, n, got["wd"])),
            "rotrN": s(rot(v, n, got["wd"], left=False)),
        }

        for k in FIELDS:
            checks += 1
            if got[k] != want[k]:
                fails += 1
                print(f"FAIL x={x_signed} n={n} {k}: lyx={got[k]} ref={want[k]}")

    print(f"cases={cases} checks={checks} fails={fails} ref=python-int")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
