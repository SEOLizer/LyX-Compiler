#!/usr/bin/env bash
# #1705 — Ein struct-Parameter, der im Rumpf beschrieben wird, muss `ref` sein.
#
# Warum: struct-Parameter werden kopiert. Schreibt eine Funktion in ein Feld
# eines solchen Parameters, landet die Aenderung in der Kopie und der Aufrufer
# sieht nichts — ohne Warnung, ohne Fehler. Gefunden an `MySQLFetchRow`, das
# `res.current_row` erhoehte: `while (row > 0) { row := MySQLFetchRow(res); }`
# lief endlos, weil die Zeilennummer beim Aufrufer nie weiterrueckte. Der Test
# stand daraufhin als "Timeout, dienstabhaengig" in known-red.txt — die
# Fehldeutung kostete mehr als der Fix.
#
# Klassen sind ausgenommen: sie sind Referenztypen, dort ist Schreiben ohne
# `ref` gewollt und richtig. Geprueft werden nur Typen, die als
# `type X = struct` deklariert sind.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'PY'
import re, glob, sys

structs = set()
for p in glob.glob('std/**/*.lyx', recursive=True) + glob.glob('src/std/**/*.lyx', recursive=True):
    q = open(p, encoding='utf-8', errors='replace').read()
    for m in re.finditer(r'(?:pub\s+)?type\s+(\w+)\s*=\s*struct', q):
        structs.add(m.group(1))

treffer = []
for p in sorted(glob.glob('std/**/*.lyx', recursive=True)):
    lines = open(p, encoding='utf-8', errors='replace').read().split('\n')
    for i, l in enumerate(lines):
        m = re.match(r'\s*(pub\s+)?fn\s+(\w+)\s*\(([^)]*)\)', l)
        if not m:
            continue
        byval = []
        for prm in m.group(3).split(','):
            pm = re.match(r'^(\w+)\s*:\s*(\w+)$', prm.strip())
            if pm and pm.group(2) in structs:
                byval.append((pm.group(1), pm.group(2)))
        if not byval:
            continue
        j = i + 1
        body = []
        while j < len(lines) and not re.match(r'\s*(pub\s+)?fn\s+\w+\s*\(', lines[j]):
            body.append(lines[j]); j += 1
        b = '\n'.join(body)
        for v, t in byval:
            if re.search(r'\b' + v + r'\.\w+\s*(:=|\+=|-=|\*=|/=)', b):
                treffer.append(f"{p}:{i+1} {m.group(2)}({v}: {t}) schreibt in {v}, nimmt ihn aber als Wert")

print(f"{len(structs)} struct-Typen geprueft")
if treffer:
    print(f"FAIL {len(treffer)} Funktion(en) schreiben in einen kopierten struct-Parameter:")
    for t in treffer:
        print("  " + t)
    sys.exit(1)
print("PASS kein struct-Parameter wird als Wert beschrieben")
PY
rc=$?
if [ "$rc" -eq 0 ]; then echo "Ergebnis: 1 PASS, 0 FAIL"; else echo "Ergebnis: 0 PASS, 1 FAIL"; fi
exit $rc
