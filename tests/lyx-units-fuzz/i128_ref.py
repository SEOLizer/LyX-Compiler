#!/usr/bin/env python3
"""Unabhaengige Referenz fuer std.i128.

Liest die Ausgabe von tests/i128_fuzz.lyx und rechnet alles mit Pythons
beliebig grossen Ganzzahlen nach. Python kennt keine 128-Bit-Grenze und keine
Uebertraege — es kann den Fehler, den die Unit machen koennte, also nicht
teilen.

Die 128-Bit-Werte kommen als Dezimalzeichenkette herein; damit wird die
Ausgabefunktion der Unit gleich mitgeprueft.
"""
import sys

M64 = (1 << 64) - 1
M128 = (1 << 128) - 1


def s64(x):
    """Bitmuster -> int64 mit Vorzeichen, wie PrintInt es ausgibt"""
    x &= M64
    return x - (1 << 64) if x >> 63 else x


def u64(x):
    return x & M64


def s128(x):
    x &= M128
    return x - (1 << 128) if x >> 127 else x


def main(path):
    fails = checks = 0
    counts = {}

    def bump(k):
        counts[k] = counts.get(k, 0) + 1

    def cmp(kind, what, got, want):
        nonlocal fails, checks
        checks += 1
        if got != want:
            fails += 1
            print(f"FAIL {kind} {what}: lyx={got} ref={want}")

    for ln in open(path):
        f = ln.split()
        if not f:
            continue
        kind, v = f[0], f[1:]

        if kind == "MUL":
            x, y = s64(int(v[0])), s64(int(v[1]))
            gotHi, gotLo, gotFull, gotHiS = int(v[2]), int(v[3]), int(v[4]), int(v[5])
            bump("MUL")
            ux, uy = u64(x), u64(y)
            p = ux * uy
            cmp("MUL", f"{ux}*{uy} hi", gotHi, s64(p >> 64))
            cmp("MUL", f"{ux}*{uy} lo", gotLo, s64(p & M64))
            cmp("MUL", f"{ux}*{uy} full", gotFull, p)
            # vorzeichenbehaftet
            ps = x * y
            cmp("MUL", f"{x}*{y} hiS", gotHiS, s64((ps >> 64) & M64))

        elif kind == "OPS":
            a, b = int(v[0]), int(v[1])
            add, sub, mul, neg = (int(v[i]) for i in (2, 3, 4, 5))
            cu, cs, pop, hi = (int(v[i]) for i in (6, 7, 8, 9))
            bump("OPS")
            cmp("OPS", "add", add, (a + b) & M128)
            cmp("OPS", "sub", sub, (a - b) & M128)
            cmp("OPS", "mul", mul, (a * b) & M128)
            cmp("OPS", "neg", neg, (-a) & M128)
            cmp("OPS", "cmpU", cu, (a > b) - (a < b))
            sa, sb = s128(a), s128(b)
            cmp("OPS", "cmpS", cs, (sa > sb) - (sa < sb))
            cmp("OPS", "popcount", pop, bin(a).count("1"))
            cmp("OPS", "highest", hi, -1 if a == 0 else a.bit_length() - 1)

        elif kind == "DIV":
            a, b, q, r = (int(x) for x in v[:4])
            bump("DIV")
            if b == 0:
                continue
            cmp("DIV", f"{a}/{b} q", q, a // b)
            cmp("DIV", f"{a}/{b} r", r, a % b)
            # Rueckprobe, die ohne Division auskommt
            checks += 1
            if q * b + r != a:
                fails += 1
                print(f"FAIL DIV reassemble {q}*{b}+{r} != {a}")

        elif kind == "SHIFT":
            a, n = int(v[0]), int(v[1])
            shl, shr, sar = (int(x) for x in v[2:5])
            bump("SHIFT")
            cmp("SHIFT", f"{a}<<{n}", shl, (a << n) & M128 if n < 128 else 0)
            cmp("SHIFT", f"{a}>>{n} logisch", shr, (a >> n) if n < 128 else 0)
            # arithmetisch: auf dem vorzeichenbehafteten Wert, Ergebnis wieder
            # als Bitmuster
            sa = s128(a)
            want = (sa >> n) if n < 128 else (-1 if sa < 0 else 0)
            cmp("SHIFT", f"{a}>>{n} arithmetisch", sar, want & M128)

        elif kind == "MULDIV":
            x, y, d, ok, got = (int(t) for t in v[:5])
            bump("MULDIV")
            ux, uy, ud = u64(s64(x)), u64(s64(y)), u64(s64(d))
            if ud == 0:
                continue
            exact = (ux * uy) // ud
            fits = exact <= M64
            cmp("MULDIV", f"{ux}*{uy}/{ud} ok", ok, 1 if fits else 0)
            if fits:
                cmp("MULDIV", f"{ux}*{uy}/{ud}", s64(got), s64(exact))

        elif kind == "AVG":
            x, y, got = (int(t) for t in v[:3])
            bump("AVG")
            ux, uy = u64(s64(x)), u64(s64(y))
            cmp("AVG", f"avg({ux},{uy})", s64(got), s64((ux + uy) // 2))

    summary = " ".join(f"{k}={n}" for k, n in sorted(counts.items()))
    print(f"cases: {summary}")
    print(f"checks={checks} fails={fails} ref=python-bigint")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
