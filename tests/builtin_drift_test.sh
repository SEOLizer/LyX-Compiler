#!/usr/bin/env bash
# #1717 — Namensdrift zwischen sema und dem IR-Lowerer.
#
# sema registriert die Builtins (`_regBuiltin`), der Lowerer erkennt sie am
# Namen (`seq(fname, fnlen, "...")`). Beide Listen sind handgepflegt und
# wissen nichts voneinander. Ein Name, der nur in sema steht, uebersetzt auf
# dem x86-Schnellweg klaglos — dort erzeugt codegen_x86 ihn direkt — und
# bricht auf JEDEM IR-Ziel mit "unbekannter Builtin/Funktion".
#
# Auffaellt es immer nur beim ERSTEN fehlenden Namen: wer eine Luecke
# schliesst, sieht sofort die naechste. Einzeln gemeldet ergaebe das eine
# Kette von Tickets. Dieser Test macht stattdessen den ganzen Rueckstand auf
# einmal sichtbar und haelt ihn fest.
#
# tests/builtin-drift-allow.txt fuehrt den gemessenen Stand. Der Test wird rot,
# wenn ein Name dazukommt (neue Drift) UND wenn einer wegfaellt, ohne dass die
# Datei nachgezogen wurde (die Liste soll nicht veralten).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'PY'
import re, sys

sema  = set(re.findall(r'_regBuiltin\("([A-Za-z_0-9]+)"', open('src/sema.lyx', encoding='utf-8', errors='replace').read()))
lower = set(re.findall(r'seq\(fname, fnlen, "([A-Za-z_0-9]+)"', open('src/ir_lower.lyx', encoding='utf-8', errors='replace').read()))
ist   = sema - lower

erlaubt = set()
for zeile in open('tests/builtin-drift-allow.txt', encoding='utf-8', errors='replace'):
    zeile = zeile.split('#', 1)[0].strip()
    if zeile:
        erlaubt.add(zeile)

neu       = sorted(ist - erlaubt)
verschw   = sorted(erlaubt - ist)

print(f"sema: {len(sema)} Builtins, ir_lower: {len(lower)} Namen, Rueckstand: {len(ist)}")

fehler = 0
if neu:
    print(f"FAIL {len(neu)} neue(r) Name(n) in sema, die der Lowerer nicht kennt:")
    for n in neu:
        print("  " + n)
    print("  Entweder in src/ir_lower.lyx lowern oder — mit Begruendung —")
    print("  in tests/builtin-drift-allow.txt aufnehmen.")
    fehler = 1
else:
    print("PASS keine neue Drift")

if verschw:
    print(f"FAIL {len(verschw)} Eintrag/Eintraege in der Liste sind inzwischen gelowered:")
    for n in verschw:
        print("  " + n)
    print("  Aus tests/builtin-drift-allow.txt streichen, sonst veraltet die Liste.")
    fehler = 1
else:
    print("PASS kein veralteter Eintrag")

sys.exit(fehler)
PY
rc=$?
if [ "$rc" -eq 0 ]; then echo "Ergebnis: 2 PASS, 0 FAIL"; else echo "Ergebnis: FAIL"; fi
exit $rc
