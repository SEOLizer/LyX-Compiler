#!/usr/bin/env bash
# tests/builtin_shadow_test.sh — Compiler-Builtins, die Namen aus Units verdecken.
#
# Ein in sema registriertes Builtin gewinnt gegen eine gleichnamige Deklaration
# in einer importierten Unit. Die Unit-Fassung ist dann stillschweigend
# wirkungslos. Diese Fehlerklasse hat das Projekt mehrfach getroffen:
#
#   free            Builtin war ein No-op und verdeckte std/alloc.lyx; damit war
#                   JEDE Freigabe wirkungslos (Issue #995). Aufgelöst, indem das
#                   Builtin entfernt wurde — es gibt zwei Allokatoren, und ein
#                   globales free kann nur einen von beiden richtig bedienen.
#   PrintStrLn u.a. als Builtin registriert, von keinem Backend emittiert:
#                   Aufruf ohne Import bestand sema und starb erst im Codegen
#                   (tests/no_phantom_builtins_test.sh).
#   O_CREAT u.a.    POSIX-Flag-Namen werden zur Compile-Zeit ersetzt und
#                   überschreiben eigene pub-con-Definitionen.
#   MAP_ANON        std/audio.lyx deklarierte 32, das Builtin liefert 34 — wer
#                   die Konstante aus der Unit las, bekam still den anderen Wert.
#
# Der Test verhindert die Klasse nicht, aber er macht sie sichtbar: er listet
# alle Kollisionen und vergleicht sie mit der unten gepflegten Liste. Eine NEUE
# Kollision lässt den Test fehlschlagen; verschwindet eine bekannte, meldet er
# das ebenfalls, damit die Liste nicht verwahrlost.
#
# Für die bekannten Fälle gilt: dort IST das Builtin die Implementierung, und
# die Unit-Fassung ist die Alternative für Ziele ohne dieses Builtin. Das ist
# gewollt — aber es muss eine bewusste Entscheidung bleiben, keine Überraschung.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]

# Bekannte, bewusst in Kauf genommene Kollisionen.
# Bei diesen ist das Builtin die eigentliche Implementierung; die gleichnamige
# Unit-Fassung dient Zielen, die das Builtin nicht haben.
EXPECTED_FN = {
    # Ein-/Ausgabe: Builtin emittiert inline, src/std/io.lyx ist die
    # Lyx-Fassung fuer den Selbstbau und den lyxos-Pfad.
    "EPrintStr", "EPrintStrLn", "Print", "PrintBool", "PrintChar", "PrintFloat",
    "PrintInt", "PrintLn", "PrintStr", "Printf", "FloatToStr",
    "FileReadAll", "FileSize", "FileWriteAll",
    # Zeichenketten: dito.
    "StrConcat", "StrCopy", "StrEndsWith", "StrFind", "StrLen", "StrSplit",
    "StrStartsWith", "StrSub", "StrTrim",
    # Sonstiges
    "ArgvGetStr",
}
EXPECTED_CON = {
    # mmap-Flags: als Builtin-Konstanten registriert, in mehreren Units
    # zusaetzlich deklariert. Die Werte MUESSEN uebereinstimmen -- genau hier
    # lag der MAP_ANON-Fehler (Unit 32 vs. Builtin 34).
    "FD_NONE", "MAP_ANON", "MAP_ANONYMOUS", "MAP_PRIVATE",
    "PROT_READ", "PROT_RW", "PROT_WRITE",
}

sema = open(os.path.join(root, "src/sema.lyx"), encoding="utf-8").read()
builtin_fn  = set(re.findall(r'_regBuiltin\("([^"]+)"\)', sema))
builtin_con = set(re.findall(r'_regBuiltinCon\("([^"]+)"\)', sema))

# Historische Sicherungskopien, nicht im Makefile referenziert.
DEAD = ("lyxc_backup", "lyxc_original", "lyxc_stage1", "lyxc_test")

pub_fn, pub_con = {}, {}
for sub in ("std", "src"):
    for dp, _, fns in os.walk(os.path.join(root, sub)):
        for fn in fns:
            if not fn.endswith(".lyx"):
                continue
            p = os.path.join(dp, fn)
            if any(d in p for d in DEAD):
                continue
            rel = os.path.relpath(p, root)
            txt = open(p, encoding="utf-8").read()
            for m in re.finditer(r'^\s*pub\s+fn\s+(\w+)', txt, re.M):
                pub_fn.setdefault(m.group(1), set()).add(rel)
            for m in re.finditer(r'^\s*pub\s+con\s+(\w+)', txt, re.M):
                pub_con.setdefault(m.group(1), set()).add(rel)

found_fn  = set(pub_fn)  & builtin_fn
found_con = set(pub_con) & builtin_con

fails = []

for kind, found, expected, table in (
    ("Funktion",  found_fn,  EXPECTED_FN,  pub_fn),
    ("Konstante", found_con, EXPECTED_CON, pub_con),
):
    for name in sorted(found - expected):
        where = ", ".join(sorted(table[name])[:3])
        fails.append(f"NEUE Kollision ({kind}): '{name}' — {where}")
    for name in sorted(expected - found):
        fails.append(
            f"bekannte Kollision ({kind}) '{name}' besteht nicht mehr — "
            f"aus der Liste in diesem Test entfernen")

if fails:
    print("FAIL Builtin-Verdeckung:")
    for f in fails:
        print("   ", f)
    print()
    print("Eine neue Kollision heisst: das Builtin gewinnt, die Unit-Fassung ist")
    print("wirkungslos. Entweder ist das gewollt (dann hier eintragen und im")
    print("Quelltext vermerken) oder das Builtin gehoert entfernt.")
    sys.exit(1)

print(f"PASS {len(found_fn)} Funktions- und {len(found_con)} Konstanten-Kollisionen, alle bekannt")
PY
