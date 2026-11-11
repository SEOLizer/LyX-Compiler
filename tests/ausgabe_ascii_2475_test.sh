#!/usr/bin/env bash
# tests/ausgabe_ascii_2475_test.sh — #2475: Ausgabe-Strings bleiben ASCII.
#
# BEFUND. Die Ausgabe von lyxc und der stdlib enthielt UTF-8. Auf zwei von drei
# Zielkonsolen kam sie falsch an, aus derselben Ursache mit verschiedenen
# Symptomen:
#
#   Linux-Terminal (UTF-8)   lyxc 1.2.36D — ... Röne      richtig
#   Windows-Konsole (CP850)  lyxc 1.2.36D ÔÇö ... R├Âne   Zeichensalat
#   LyxOS-Konsole            lyxc 1.2.36D  ... Rne        Zeichen FEHLEN
#
# Die dritte Zeile ist die unangenehmere: aus "ungueltiger Pfad" wird
# "ungltiger Pfad" — lesbar genug, um durchzugehen, falsch genug, dass die
# Suche im Quelltext nichts findet. Der LyxOS-Konsolenfont deckt nur
# ASCII 0x20-0x7E und verwirft alles andere stillschweigend (#2474, Befund
# liegt im Kernel).
#
# WAS HIER GEPRUEFT WIRD: dass kein `"..."c`-Literal in src/ und std/ ein
# Zeichen ueber 0x7E traegt. Ohne diesen Waechter schleicht sich das naechste
# `—` beim naechsten Commit wieder ein — die Zeichen entstehen beim Schreiben
# von Prosa, nicht aus Absicht.
#
# KOMMENTARE sind ausdruecklich NICHT betroffen. Sie landen auf keiner Konsole,
# und sie ASCII-frei zu halten haette die Aenderung um ein Vielfaches
# aufgeblaeht, ohne irgendetwas zu beheben. Gemessen wird deshalb nur, was
# zwischen `"` und `"c` steht.
#
# AUSNAHMEN stehen in tests/ausgabe-ascii-allow.txt, mit Begruendung. Es gibt
# sie wirklich: `OdtAddHorizontalRule` schreibt eine waagerechte Linie in ein
# ODT-DOKUMENT, nicht auf eine Konsole. Dort ist der Strich richtig, und ihn
# zu ersetzen wuerde das erzeugte Dokument veraendern.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'PY'
import re, sys, glob, os

pat = re.compile(r'"((?:[^"\\\n]|\\.)*)"c')

# Ausnahmen: "<datei>:<zeile>" oder "<datei>" (ganze Datei), je Zeile.
erlaubt = set()
pfad = 'tests/ausgabe-ascii-allow.txt'
if os.path.exists(pfad):
    for z in open(pfad, encoding='utf-8', errors='replace'):
        z = z.split('#', 1)[0].strip()
        if z:
            erlaubt.add(z)

treffer = []
geprueft = 0
for f in sorted(glob.glob('src/**/*.lyx', recursive=True) +
                glob.glob('std/**/*.lyx', recursive=True)):
    for ln, l in enumerate(open(f, encoding='utf-8', errors='replace'), 1):
        for m in pat.finditer(l):
            geprueft += 1
            s = m.group(1)
            na = sorted(set(c for c in s if ord(c) > 0x7E))
            if not na:
                continue
            if f in erlaubt or f"{f}:{ln}" in erlaubt:
                continue
            treffer.append((f, ln, ''.join(na), s[:60]))

print(f"geprueft: {geprueft} Ausgabe-Strings in src/ und std/, "
      f"{len(erlaubt)} Ausnahme(n) eingetragen")

if treffer:
    print(f"FAIL {len(treffer)} Ausgabe-String(s) mit Zeichen ueber 0x7E:")
    for f, ln, c, s in treffer[:20]:
        print(f"  {f}:{ln}  [{c}]  {s}")
    if len(treffer) > 20:
        print(f"  ... und {len(treffer)-20} weitere")
    print("  Auf der Windows-Konsole wird daraus Zeichensalat (CP850), auf der")
    print("  LyxOS-Konsole verschwindet das Zeichen ersatzlos (#2474).")
    print("  Ersetzen: — -> --   → -> ->   … -> ...   Umlaute ausschreiben.")
    print("  Ist der String DOKUMENTINHALT und keine Meldung, gehoert er mit")
    print("  Begruendung in tests/ausgabe-ascii-allow.txt.")
    sys.exit(1)

print("PASS kein Ausgabe-String traegt ein Zeichen ueber 0x7E")

# Gegenrichtung: die Ausnahmeliste darf nicht veralten. Ein Eintrag, dessen
# Stelle inzwischen ASCII ist, verdeckt beim naechsten Mal einen echten Fall.
tot = []
for e in sorted(erlaubt):
    datei = e.split(':')[0]
    if not os.path.exists(datei):
        tot.append(f"{e} (Datei fehlt)")
        continue
    hat = False
    for ln, l in enumerate(open(datei, encoding='utf-8', errors='replace'), 1):
        for m in pat.finditer(l):
            if any(ord(c) > 0x7E for c in m.group(1)):
                if e == datei or e == f"{datei}:{ln}":
                    hat = True
    if not hat:
        tot.append(f"{e} (dort steht kein Nicht-ASCII mehr)")
if tot:
    print(f"FAIL {len(tot)} veralteter Eintrag in {pfad}:")
    for t in tot:
        print("  " + t)
    print("  Streichen, sonst deckt die Liste den naechsten echten Fall zu.")
    sys.exit(1)

print("PASS kein veralteter Eintrag in der Ausnahmeliste")
print("Ergebnis: 2 PASS, 0 FAIL")
PY
