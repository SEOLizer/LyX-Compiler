#!/usr/bin/env python3
"""tools/bench_netz_ref.py — unabhaengige Referenz zu Benchmark 1 (#2332).

    tools/bench_netz_ref.py netz_spec.json [DATENSAETZE]

Wertet die Funktionstabelle aus netz_spec.json DEUTEND aus: keine generierten
Rumpfe, kein uebersetzter Code, sondern ein Auswerter ueber der Tabelle. Damit
ist die Referenz eine andere DARSTELLUNG derselben Rechnung — eine dritte
Uebersetzung desselben Algorithmus waere nicht automatisch unabhaengig
(work/vorabcheck-2332.md, Punkt 7).

Langsam und absichtlich: die Referenz wird mit wenigen Datensaetzen AUSSERHALB
jeder Zeitmessung gegen die uebersetzten Fassungen gehalten. Ausgabe wie dort:
checksum_hi/checksum_lo als zwei 32-Bit-Haelften.
"""
import json, sys

M64 = (1 << 64) - 1


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    spec = json.load(open(sys.argv[1]))
    wdh = int(sys.argv[2]) if len(sys.argv) > 2 else spec["datensaetze"]
    fns = spec["fns"]
    helfer = spec["helfer"]
    mul1, mul2, mul3, gold = spec["mul1"], spec["mul2"], spec["mul3"], spec["gold"]
    sys.setrecursionlimit(10000)

    def h(j, x, d):
        c = helfer[j]
        a = (x ^ c["k1"]) & M64
        a = (a * c["mul"] + c["k2"]) & M64
        a ^= a >> c["shr"]
        return (a + (d & c["maske"])) & M64

    def f(i, x, d):
        fn = fns[i]
        a = (x ^ fn["k1"]) & M64
        a = (a * mul1 + fn["k2"]) & M64
        a ^= a >> 29
        a = (a + h(fn["h"], a, d)) & M64
        if fn["c1"] is not None and (d & fn["bit1"]) != 0:
            a = (a + f(fn["c1"], a, d >> 1)) & M64
        if fn["c2"] is not None and (d & fn["bit2"]) != 0:
            a = (a ^ f(fn["c2"], a, d >> 2)) & M64
        r = fn["rot"]
        a = ((a << r) | (a >> (64 - r))) & M64
        return (a + fn["k3"]) & M64

    def naechste(z):
        z = (z ^ (z >> 30)) & M64
        z = (z * mul2) & M64
        z = (z ^ (z >> 27)) & M64
        z = (z * mul3) & M64
        return (z ^ (z >> 31)) & M64

    zustand, acc = spec["seed"], 1
    for _ in range(wdh):
        zustand = (zustand + gold) & M64
        d = naechste(zustand)
        for i in range(len(fns)):
            acc ^= f(i, acc, d)
            acc &= M64
    print("checksum_hi=%d" % (acc >> 32))
    print("checksum_lo=%d" % (acc & 0xFFFFFFFF))
    return 0


if __name__ == "__main__":
    sys.exit(main())
