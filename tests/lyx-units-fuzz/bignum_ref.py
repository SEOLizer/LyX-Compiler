#!/usr/bin/env python3
"""Unabhaengige Referenz fuer std.bignum.

Liest die Ausgabe von tests/bignum_fuzz.lyx und rechnet alles mit Pythons
Ganzzahlen nach — die sind von Haus aus beliebig gross und kennen weder
Woerter noch Uebertraege, koennen den Fehler also nicht teilen.

Aus der Lyx-Ausgabe werden nur die OPERANDEN uebernommen; jedes verglichene
Ergebnis wird hier neu gerechnet.
"""
import sys
import math


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

        if kind == "OPS":
            a, b = int(v[0]), int(v[1])
            add, sub, mul, neg = (int(v[i]) for i in (2, 3, 4, 5))
            c, bits = int(v[6]), int(v[7])
            bump("OPS")
            cmp("OPS", f"{a}+{b}", add, a + b)
            cmp("OPS", f"{a}-{b}", sub, a - b)
            cmp("OPS", f"{a}*{b}", mul, a * b)
            cmp("OPS", f"-{a}", neg, -a)
            cmp("OPS", f"cmp({a},{b})", c, (a > b) - (a < b))
            cmp("OPS", f"bitlen({a})", bits, abs(a).bit_length())

        elif kind == "DIV":
            a, b, q, r = (int(x) for x in v[:4])
            bump("DIV")
            if b == 0:
                continue
            # Richtung null, Rest mit dem Vorzeichen des Zaehlers — wie in C
            wq = abs(a) // abs(b)
            if (a < 0) != (b < 0):
                wq = -wq
            wr = abs(a) % abs(b)
            if a < 0:
                wr = -wr
            cmp("DIV", f"{a}/{b} q", q, wq)
            cmp("DIV", f"{a}/{b} r", r, wr)
            checks += 1
            if q * b + r != a:
                fails += 1
                print(f"FAIL DIV reassemble {q}*{b}+{r} != {a}")
            checks += 1
            if abs(r) >= abs(b):
                fails += 1
                print(f"FAIL DIV remainder too large: |{r}| >= |{b}|")

        elif kind == "MOD":
            a, b, got = (int(x) for x in v[:3])
            bump("MOD")
            if b == 0:
                continue
            # immer nichtnegativ, im Bereich [0, |b|)
            want = abs(a) % abs(b)
            if a < 0 and want != 0:
                want = abs(b) - want
            cmp("MOD", f"{a} mod {b}", got, want)
            checks += 1
            if not (0 <= got < abs(b)):
                fails += 1
                print(f"FAIL MOD out of range: {got} not in [0,{abs(b)})")

        elif kind == "GCD":
            a, b, got = (int(x) for x in v[:3])
            bump("GCD")
            cmp("GCD", f"gcd({a},{b})", got, math.gcd(a, b))

        elif kind == "SHL":
            a, n, got = int(v[0]), int(v[1]), int(v[2])
            bump("SHL")
            # der Betrag wird geschoben, das Vorzeichen bleibt
            want = abs(a) << n
            if a < 0:
                want = -want
            cmp("SHL", f"{a}<<{n}", got, want)

        elif kind == "SHR":
            a, n, got = int(v[0]), int(v[1]), int(v[2])
            bump("SHR")
            want = abs(a) >> n
            if a < 0 and want != 0:
                want = -want
            cmp("SHR", f"{a}>>{n}", got, want)

        elif kind == "POWMOD":
            b, e, m, got = (int(x) for x in v[:4])
            bump("POWMOD")
            if m == 0:
                continue
            cmp("POWMOD", f"pow({b},{e},{m})", got, pow(b, e, m))

    summary = " ".join(f"{k}={n}" for k, n in sorted(counts.items()))
    print(f"cases: {summary}")
    print(f"checks={checks} fails={fails} ref=python-bigint")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
