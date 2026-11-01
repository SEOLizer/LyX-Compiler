#!/usr/bin/env python3
"""tools/gen_bench_netz.py — Benchmark 1 der Suite: grosse Codebasis mit Funktionsnetz (#2332).

    tools/gen_bench_netz.py -f FUNKTIONEN -m MODULE -w DATENSAETZE -o VERZEICHNIS

Erzeugt dieselbe Rechnung in drei Darstellungen:

  Lyx   netz.lyx + netz_h.lyx + netz_k<0..M-1>.lyx   (unit/import, pub fn)
  C     netz.c   + netz_h.c   + netz_k<0..M-1>.c + netz.h
  Spec  netz_spec.json                               (Tabelle aller Funktionen)

Die Spec ist die UNABHAENGIGE Referenz: tools/bench_netz_ref.py wertet sie
deutend aus, statt denselben Algorithmus ein drittes Mal zu uebersetzen. Eine
dritte Uebersetzung ist nicht automatisch unabhaengig (work/vorabcheck-2332.md).

Aufbau des Netzes
-----------------
F Funktionen auf M Module, je Modul ein zusammenhaengender Block von
B = ceil(F/M) Funktionen. Jede Funktion ruft bis zu zwei Nachfolger mit
HOEHEREM Index (c1 = i+1, c2 = i+B+1) — der Aufrufgraph ist damit azyklisch
und ueberschreitet Modulgrenzen. Dazu acht gemeinsam genutzte Hilfsfunktionen
in netz_h, die jede Funktion benutzt.

Ob ein Nachfolger gerufen wird, entscheidet der Datenwert `d` zur Laufzeit; in
jeder Ebene wird `d` nach rechts geschoben. Damit laufen verschiedene
Datensaetze verschiedene Pfade, die Tiefe ist durch die 64 Bit von `d`
begrenzt (kein Stackueberlauf), und JEDE Funktion ist erreichbar, weil main
alle F Funktionen je Datensatz unmittelbar aufruft. Eine Sprungtabelle oder
eine if-Kette als Verteiler gibt es bewusst nicht: sie wuerde die Messung
dominieren und zwischen den Sprachen unterschiedlich uebersetzt.

Arithmetikvertrag (belegt in tests/arith_vertrag_test.sh)
---------------------------------------------------------
Alles uint64 modulo 2^64; `>>` auf uint64 ist logisch; Rotation ueber
rotl (Lyx) bzw. Schieben-Verodern (C, wird von GCC zu `rol` zusammengezogen).
Die Pruefsumme wird als ZWEI 32-Bit-Haelften ausgegeben, weil es in der
stdlib keine vorzeichenlose Dezimalausgabe gibt.

Namen: die Knoten heissen kn<i>, nicht f<i> — f32/f64 sind Typnamen in Lyx
und ein `f32(...)` ist ein Parse error.

Zufall: splitmix64 mit festem Seed — gleicher Strom in allen Darstellungen.
"""
import argparse, json, os

M64 = (1 << 64) - 1
GOLD = 0x9E3779B97F4A7C15
MUL1 = 0x6364136223846793
MUL2 = 0xBF58476D1CE4E5B9
MUL3 = 0x94D049BB133111EB
SEED = 0x0123456789ABCDEF


def konst(i, j):
    """Konstanten aus dem Index — damit kein Compiler zwei Rumpfe als denselben erkennt."""
    v = (i * GOLD + j * MUL1) & M64
    v ^= v >> 29
    return v & M64


def netz(F, M):
    """Tabelle aller Funktionen: Modul, Konstanten, Rotation, Helfer, Nachfolger."""
    B = (F + M - 1) // M
    fns = []
    for i in range(F):
        c1 = i + 1
        c2 = i + B + 1
        fns.append({
            "i": i,
            "modul": i // B,
            "k1": konst(i, 1),
            "k2": konst(i, 2) | 1,          # ungerade: Multiplikation bleibt umkehrbar
            "k3": konst(i, 3),
            "rot": (i * 7 + 13) % 63 + 1,   # 1..63, nie 0 und nie 64
            "h": i % 8,
            "bit1": 1 << (i % 61),
            "bit2": 1 << ((i * 5 + 17) % 61),
            "c1": c1 if c1 < F else None,
            "c2": c2 if c2 < F else None,
        })
    return B, fns


# --------------------------------------------------------------------- Lyx
def schreibe_lyx(out, F, M, W, B, fns):
    kopf = ('@description("Benchmark 1: Funktionsnetz, %d Funktionen, %d Module (#2332)")\n'
            '@author("Andreas Röne")\n@copyright("2026 Andreas Röne")\n' % (F, M))

    with open(os.path.join(out, "netz_h.lyx"), "w") as f:
        f.write("// generiert von tools/gen_bench_netz.py — NICHT von Hand aendern.\n")
        f.write("unit netz_h;\n\n")
        for j in range(8):
            f.write(
                "pub fn h%d(x: uint64, d: uint64): uint64 {\n"
                "  var a: uint64 := x ^ %d;\n"
                "  a := a * %d + %d;\n"
                "  a := a ^ (a >> %d);\n"
                "  return a + (d & %d);\n"
                "}\n" % (j, konst(j, 11), MUL2 | 1, konst(j, 12), 17 + j, 0xFFFF))

    for k in range(M):
        eigene = [fn for fn in fns if fn["modul"] == k]
        if not eigene:
            continue
        nachbarn = sorted({fns[c]["modul"] for fn in eigene for c in (fn["c1"], fn["c2"])
                           if c is not None} - {k})
        with open(os.path.join(out, "netz_k%d.lyx" % k), "w") as f:
            f.write("// generiert von tools/gen_bench_netz.py — NICHT von Hand aendern.\n")
            f.write("unit netz_k%d;\n" % k)
            f.write("import netz_h;\n")
            for n in nachbarn:
                f.write("import netz_k%d;\n" % n)
            f.write("\n")
            for fn in eigene:
                f.write(rumpf_lyx(fn))

    with open(os.path.join(out, "netz.lyx"), "w") as f:
        f.write("// generiert von tools/gen_bench_netz.py — NICHT von Hand aendern.\n")
        f.write(kopf)
        f.write("import std.io;\nimport std.string;\n")
        for k in range(M):
            if any(fn["modul"] == k for fn in fns):
                f.write("import netz_k%d;\n" % k)
        f.write("""
// splitmix64 — gleicher Strom wie in der C-Fassung und in der Referenz.
fn naechste(z0: uint64): uint64 {
  var z: uint64 := z0;
  z := z ^ (z >> 30);
  z := z * %d;
  z := z ^ (z >> 27);
  z := z * %d;
  return z ^ (z >> 31);
}

fn main(): int64 {
  var argc: int64 := GetArgC();
  var argv: pchar := GetArgV();
  var wdh: int64 := %d;
  if (argc > 1) {
    var s: pchar := ArgvGet(argv, 1);
    var v: int64 := StrToInt(s);
    if (v > 0) { wdh := v; }
  }
  var zustand: uint64 := %d;
  var acc: uint64 := 1;
  var w: int64 := 0;
  while (w < wdh) {
    zustand := zustand + %d;
    var d: uint64 := naechste(zustand);
""" % (MUL2, MUL3, W, SEED, GOLD))
        for fn in fns:
            f.write("    acc := acc ^ kn%d(acc, d);\n" % fn["i"])
        f.write("""    w += 1;
  }
  // Zwei 32-Bit-Haelften: es gibt keine vorzeichenlose Dezimalausgabe.
  PrintStr("checksum_hi="c);
  PrintLn((acc >> 32) as int64);
  PrintStr("checksum_lo="c);
  PrintLn((acc & 4294967295) as int64);
  return 0;
}
""")


def rumpf_lyx(fn):
    z = ["pub fn kn%d(x: uint64, d: uint64): uint64 {\n" % fn["i"],
         "  var a: uint64 := x ^ %d;\n" % fn["k1"],
         "  a := a * %d + %d;\n" % (MUL1 | 1, fn["k2"]),
         "  a := a ^ (a >> 29);\n",
         "  a := a + h%d(a, d);\n" % fn["h"]]
    if fn["c1"] is not None:
        z.append("  if ((d & %d) != 0) { a := a + kn%d(a, d >> 1); }\n" % (fn["bit1"], fn["c1"]))
    if fn["c2"] is not None:
        z.append("  if ((d & %d) != 0) { a := a ^ kn%d(a, d >> 2); }\n" % (fn["bit2"], fn["c2"]))
    z.append("  a := rotl(a as int64, %d) as uint64;\n" % fn["rot"])
    z.append("  return a + %d;\n}\n" % fn["k3"])
    return "".join(z)


# ----------------------------------------------------------------------- C
def schreibe_c(out, F, M, W, B, fns):
    with open(os.path.join(out, "netz.h"), "w") as f:
        f.write("/* generiert von tools/gen_bench_netz.py — NICHT von Hand aendern. */\n")
        f.write("#ifndef NETZ_H\n#define NETZ_H\n#include <stdint.h>\n\n")
        f.write("/* Rotation als Schieben-Verodern: die Form, die GCC zu `rol` zusammenzieht.\n"
                "   Lyx nimmt dafuer das Builtin rotl — dieselbe Rechnung. */\n")
        f.write("static inline uint64_t rot64(uint64_t x, int n) {\n"
                "    return (x << n) | (x >> (64 - n));\n}\n\n")
        for j in range(8):
            f.write("uint64_t h%d(uint64_t x, uint64_t d);\n" % j)
        for fn in fns:
            f.write("uint64_t kn%d(uint64_t x, uint64_t d);\n" % fn["i"])
        f.write("\n#endif\n")

    with open(os.path.join(out, "netz_h.c"), "w") as f:
        f.write('/* generiert — NICHT von Hand aendern. */\n#include "netz.h"\n\n')
        for j in range(8):
            f.write("uint64_t h%d(uint64_t x, uint64_t d) {\n"
                    "    uint64_t a = x ^ %dULL;\n"
                    "    a = a * %dULL + %dULL;\n"
                    "    a = a ^ (a >> %d);\n"
                    "    return a + (d & %dULL);\n}\n"
                    % (j, konst(j, 11), MUL2 | 1, konst(j, 12), 17 + j, 0xFFFF))

    for k in range(M):
        eigene = [fn for fn in fns if fn["modul"] == k]
        if not eigene:
            continue
        with open(os.path.join(out, "netz_k%d.c" % k), "w") as f:
            f.write('/* generiert — NICHT von Hand aendern. */\n#include "netz.h"\n\n')
            for fn in eigene:
                f.write(rumpf_c(fn))

    with open(os.path.join(out, "netz.c"), "w") as f:
        f.write('/* generiert — NICHT von Hand aendern. */\n')
        f.write('#include <stdio.h>\n#include <stdlib.h>\n#include "netz.h"\n\n')
        f.write("static uint64_t naechste(uint64_t z) {\n"
                "    z = z ^ (z >> 30);\n    z = z * %dULL;\n"
                "    z = z ^ (z >> 27);\n    z = z * %dULL;\n"
                "    return z ^ (z >> 31);\n}\n\n" % (MUL2, MUL3))
        f.write("int main(int argc, char **argv) {\n"
                "    long long wdh = %d;\n"
                "    if (argc > 1) { long long v = atoll(argv[1]); if (v > 0) wdh = v; }\n"
                "    uint64_t zustand = %dULL, acc = 1;\n"
                "    for (long long w = 0; w < wdh; w++) {\n"
                "        zustand = zustand + %dULL;\n"
                "        uint64_t d = naechste(zustand);\n" % (W, SEED, GOLD))
        for fn in fns:
            f.write("        acc = acc ^ kn%d(acc, d);\n" % fn["i"])
        f.write('    }\n'
                '    printf("checksum_hi=%lld\\n", (long long)(acc >> 32));\n'
                '    printf("checksum_lo=%lld\\n", (long long)(acc & 4294967295ULL));\n'
                '    return 0;\n}\n')


def rumpf_c(fn):
    z = ["uint64_t kn%d(uint64_t x, uint64_t d) {\n" % fn["i"],
         "    uint64_t a = x ^ %dULL;\n" % fn["k1"],
         "    a = a * %dULL + %dULL;\n" % (MUL1 | 1, fn["k2"]),
         "    a = a ^ (a >> 29);\n",
         "    a = a + h%d(a, d);\n" % fn["h"]]
    if fn["c1"] is not None:
        z.append("    if ((d & %dULL) != 0) { a = a + kn%d(a, d >> 1); }\n" % (fn["bit1"], fn["c1"]))
    if fn["c2"] is not None:
        z.append("    if ((d & %dULL) != 0) { a = a ^ kn%d(a, d >> 2); }\n" % (fn["bit2"], fn["c2"]))
    z.append("    a = rot64(a, %d);\n" % fn["rot"])
    z.append("    return a + %dULL;\n}\n" % fn["k3"])
    return "".join(z)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("-f", "--funktionen", type=int, default=2000)
    p.add_argument("-m", "--module", type=int, default=20)
    p.add_argument("-w", "--datensaetze", type=int, default=200)
    p.add_argument("-o", "--out", required=True)
    a = p.parse_args()
    if a.funktionen < 1 or a.module < 1:
        p.error("-f und -m brauchen Zahlen >= 1")
    B, fns = netz(a.funktionen, a.module)
    if B < 6:
        p.error("Block je Modul ist %d Funktionen — zu klein fuer den Aufrufgraphen "
                "(c2 = i+B+1 braucht B >= 6). Weniger Module oder mehr Funktionen." % B)
    os.makedirs(a.out, exist_ok=True)
    schreibe_lyx(a.out, a.funktionen, a.module, a.datensaetze, B, fns)
    schreibe_c(a.out, a.funktionen, a.module, a.datensaetze, B, fns)
    with open(os.path.join(a.out, "netz_spec.json"), "w") as f:
        json.dump({"funktionen": a.funktionen, "module": a.module, "block": B,
                   "datensaetze": a.datensaetze, "seed": SEED, "gold": GOLD,
                   "mul1": MUL1 | 1, "mul2": MUL2, "mul3": MUL3,
                   "helfer": [{"j": j, "k1": konst(j, 11), "mul": MUL2 | 1,
                               "k2": konst(j, 12), "shr": 17 + j, "maske": 0xFFFF}
                              for j in range(8)],
                   "fns": fns}, f)
    print("geschrieben: %s — %d Funktionen, %d Module, Block %d" % (a.out, a.funktionen, a.module, B))


if __name__ == "__main__":
    main()
