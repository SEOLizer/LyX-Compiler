#!/usr/bin/env bash
# tests/backend_abdeckung_test.sh — #2037: decken arm64 und riscv dieselben
# Builtin-IDs ab?
#
# Beide gehen nach derselben generischen Linux-ABI. Trotzdem kannte jedes
# Backend andere Builtins: `open` fehlte arm64 (jedes Dateiprogramm!), `panic`
# fehlte riscv. Kein Entwurfsfehler, sondern gewachsene Ungleichheit — jede ID
# wurde einzeln und je Backend nachgetragen, und es gab keine Stelle, die
# beide gegeneinander haelt.
#
# tests/builtin_id_test.sh prueft, dass keine ID DOPPELT vergeben ist und dass
# jede in _builtin_ids.md steht. Nicht aber, ob die Backends dieselbe Menge
# koennen — genau diese Luecke schliesst dieser Test.
#
# JE ZWEIG VERGLEICHEN, nicht je Datei. Das arm64-Backend hat einen
# Windows- und einen Linux-Zweig; `id == 8` kam in der Datei vor, stand aber
# im Windows-Zweig — `StrCopy` fehlte trotzdem. Eine Messung ueber die ganze
# Datei haette die Luecke uebersehen, und genau das ist bei der ersten Fassung
# von #2037 passiert.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'PY'
import re, sys

def zweige(pfad):
    """IDs je Zweig: alles innerhalb des winMode-Blocks zaehlt als Windows."""
    L = open(pfad, encoding='utf-8', errors='replace').read().split('\n')
    win, lin = set(), set()
    i, n = 0, len(L)
    while i < n:
        if re.match(r'\s*if self\.winMode != 0 \{', L[i]):
            # bis zur schliessenden Klammer auf derselben Einrueckung
            tiefe = len(L[i]) - len(L[i].lstrip())
            j = i + 1
            while j < n and L[j].rstrip() != ' ' * tiefe + '}':
                for m in re.findall(r'id == (\d+)', L[j]):
                    win.add(int(m))
                j += 1
            i = j + 1
            continue
        for m in re.findall(r'id == (\d+)', L[i]):
            lin.add(int(m))
        i += 1
    return win, lin

a_win, a_lin = zweige('src/backend/arm64/emit_arm64.lyx')
r_win, r_lin = zweige('src/backend/riscv_linux.lyx')

print(f"arm64: {len(a_lin)} IDs im Linux-Zweig ({len(a_win)} im Windows-Zweig)")
print(f"riscv: {len(r_lin)} IDs")

# Absichtlich einseitig — hier eintragen, sonst meldet der Waechter sie ewig.
# Jede Zeile braucht einen Grund; "geht schon" ist keiner.
erlaubt_nur_arm64 = set()   # noch keine
erlaubt_nur_riscv = set()   # noch keine

fehlt_arm64 = sorted((r_lin - a_lin) - erlaubt_nur_riscv)
fehlt_riscv = sorted((a_lin - r_lin) - erlaubt_nur_arm64)

fehler = 0
if fehlt_arm64:
    print(f"FAIL {len(fehlt_arm64)} ID(s) kann riscv, der arm64-LINUX-Zweig nicht: {fehlt_arm64}")
    print("  Entweder in src/backend/arm64/emit_arm64.lyx emittieren oder — mit")
    print("  Begruendung — in diesem Test als absichtlich einseitig eintragen.")
    fehler = 1
else:
    print("PASS der arm64-Linux-Zweig deckt alles ab, was riscv kann")

if fehlt_riscv:
    print(f"FAIL {len(fehlt_riscv)} ID(s) kann arm64, riscv nicht: {fehlt_riscv}")
    print("  Entweder in src/backend/riscv_linux.lyx emittieren oder eintragen.")
    fehler = 1
else:
    print("PASS riscv deckt alles ab, was der arm64-Linux-Zweig kann")

# Eine ID, die NUR im Windows-Zweig steht, ist fuer Linux nicht vorhanden —
# auch wenn sie in der Datei vorkommt. Das war der Fall bei StrCopy (8).
nur_win = sorted(a_win - a_lin)
if nur_win:
    offen = [i for i in nur_win if i in r_lin]
    if offen:
        print(f"FAIL {len(offen)} ID(s) stehen bei arm64 NUR im Windows-Zweig, riscv kann sie unter Linux: {offen}")
        fehler = 1
    else:
        print(f"PASS die {len(nur_win)} reinen Windows-IDs haben kein Linux-Gegenstueck bei riscv")

sys.exit(fehler)
PY
rc=$?
echo
if [ "$rc" -eq 0 ]; then echo "Ergebnis: alle Pruefungen gruen"; else echo "Ergebnis: FEHLER"; fi
exit $rc
