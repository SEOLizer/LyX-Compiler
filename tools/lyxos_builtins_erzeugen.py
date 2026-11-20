#!/usr/bin/env python3
"""Erzeugt src/backend/lyxos/lyxos_builtins.lyx — die Syscalls, die der
Kernel hat und das Backend bisher nicht erreicht.

#2549. Der LyxOS-Kernel fuehrt 222 Nummern mit lesbarer Signatur; davon
erreichte das Backend 105. Die restlichen 117 waren aus Lyx nicht aufrufbar:
nicht falsch, sondern nicht vorhanden. Handarbeit kommt dagegen nicht an —
`lyx-os` committet an einem Tag mehrfach, und jede Nummer braucht VIER
Stellen (sema-Registrierung, ir_lower-Namensauflistung, emit_lyxos-Verteiler,
builtin_ziele). Darum eine Mechanik statt 117 x 4 Handgriffen: dieses Skript
schreibt die DATEN, die vier Stellen fragen sie zur Laufzeit.

Die Datenkette, EINE Richtung:

  lyx-os kernel/ring3.lyx
    -> (dessen tools/sync_syscalls.py) doku/syscalls_ist.md
    -> (tools/lyxos_syscall_abgleich.sh --schreiben) work/lyxos/syscall-argc.txt
    -> (dieses Skript) src/backend/lyxos/lyxos_builtins.lyx

AUFGENOMMEN wird eine Nummer genau dann, wenn
  (a) sie in work/lyxos/syscall-argc.txt steht (Kernel kennt sie, Gestalt
      lesbar), und
  (b) das Backend sie noch NICHT emittiert, und
  (c) ihr Name noch nicht fuer einen anderen Builtin vergeben ist.

(b) wird am Quelltext von emit_lyxos.lyx GERECHNET, nicht geschaetzt: die
direkten Zweige `id == N { self.emitVfsSyscall(NR, ...) }` ebenso wie die
zwoelf gerechneten Bereiche `BASIS + (id - OFFSET)` samt ihrer einen
Korrektur (`id >= 164` ueberspringt die Kernel-Luecke 123). Wer einen Bereich
uebersieht, haelt erreichbare Nummern fuer fehlend — in der ersten Messung zu
#2549 waren es 22 zuviel.

(c) ist kein Schoenheitsgrund: ein zweiter Builtin gleichen Namens waere
unaufloesbar, und welche der beiden Nummern gemeint ist, kann dieses Skript
nicht wissen. Die Faelle werden einzeln benannt (siehe AUSSCHLUESSE unten),
nicht stillschweigend verworfen.

Aufruf:
  tools/lyxos_builtins_erzeugen.py            # erzeugen
  tools/lyxos_builtins_erzeugen.py --pruefen  # nur vergleichen, nichts schreiben
"""
import os
import re
import sys

WURZEL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARGC = os.path.join(WURZEL, "work/lyxos/syscall-argc.txt")
EMIT = os.path.join(WURZEL, "src/backend/lyxos/emit_lyxos.lyx")
SEMA = os.path.join(WURZEL, "src/sema.lyx")
IRL = os.path.join(WURZEL, "src/ir_lower.lyx")
ZIEL = os.path.join(WURZEL, "src/backend/lyxos/lyxos_builtins.lyx")

# Erste Builtin-ID dieses Blocks. Die Handvergabe reicht bis 545; 600 laesst
# Luft, und der Block liegt zusammenhaengend, damit der Verteiler in
# emit_lyxos EINE Bereichsabfrage ist und keine Aufzaehlung.
ID_BASIS = 600


def zahl(t):
    t = t.strip()
    return int(t, 16) if t.lower().startswith("0x") else int(t)


def erreichte_nummern(quelle):
    """Jede Syscallnummer, die emit_lyxos.lyx heute emittiert."""
    text = open(quelle).read()
    zeilen = text.split("\n")
    treffer = set()

    direkt = re.compile(
        r"id == (\d+)\s*\{\s*self\."
        r"(emitVfsSyscallAB|emitVfsSyscall|emitBlockSyscall)"
        r"\((0x[0-9A-Fa-f]+|\d+)\s*,"
    )
    for zeile in zeilen:
        for m in direkt.finditer(zeile):
            treffer.add(zahl(m.group(3)))

    # emitUnlinkFlach traegt die Nummer im eigenen Rumpf (#1742).
    m = re.search(r"fn emitUnlinkFlach\b.*?emitVfsSyscall\((\d+)", text, re.S)
    if m:
        treffer.add(int(m.group(1)))

    # Roher Weg: Nummer direkt nach rax, dann syscall.
    for m in re.finditer(r"emitMovRaxImm\((0x[0-9A-Fa-f]+|\d+)\)", text):
        treffer.add(zahl(m.group(1)))

    # Gerechnete Bereiche.
    bereich = re.compile(r"id >= (\d+) && id <= (\d+)")
    for i, zeile in enumerate(zeilen):
        mb = bereich.search(zeile)
        if not mb:
            continue
        von, bis = int(mb.group(1)), int(mb.group(2))
        block = "\n".join(zeilen[i:i + 120])
        mf = re.search(
            r"var (lx[0-9A-Za-z]+)nr: int64 := (0x[0-9A-Fa-f]+|\d+) \+ \(id - (\d+)\)",
            block,
        )
        if not mf:
            continue
        name, basis, off = mf.group(1), zahl(mf.group(2)), int(mf.group(3))
        korr = re.findall(
            r"if id >= (\d+) \{ " + re.escape(name) + r"nr := "
            + re.escape(name) + r"nr \+ (\d+); \}",
            block,
        )
        for idw in range(von, bis + 1):
            nr = basis + (idw - off)
            for ab, plus in korr:
                if idw >= int(ab):
                    nr += int(plus)
            treffer.add(nr)
    return treffer


def vergebene_namen():
    """Namen, die schon ein Builtin besetzt — sema-Registrierung oder
    ir_lower-Auflistung. Beide, weil beide den Namen binden."""
    namen = set()
    for m in re.finditer(r'_regBuiltin\("([^"]+)"', open(SEMA).read()):
        namen.add(m.group(1))
    for m in re.finditer(
        r'self\.seq\(fname, fnlen, "([^"]+)"', open(IRL).read()
    ):
        namen.add(m.group(1))
    return namen


def herkunft():
    for zeile in open(ARGC):
        m = re.match(
            r"^# NICHT von Hand pflegen\. Quelle \(nur gelesen\), Stand (.*):$",
            zeile.rstrip("\n"),
        )
        if m:
            return m.group(1)
    return "unbekannt"


def main():
    pruefen = "--pruefen" in sys.argv[1:]

    if not os.path.exists(ARGC):
        print(f"FEHLT: {ARGC} — mit tools/lyxos_syscall_abgleich.sh --schreiben anlegen")
        return 2

    tabelle = []
    for zeile in open(ARGC):
        if zeile.startswith("#") or not zeile.strip():
            continue
        f = zeile.rstrip("\n").split("\t")
        if len(f) >= 3:
            tabelle.append((int(f[0]), f[1], int(f[2])))

    erreicht = erreichte_nummern(EMIT)
    vergeben = vergebene_namen()

    offen = [(nr, nm, ac) for nr, nm, ac in tabelle if nr not in erreicht]
    neu = [(nr, nm, ac) for nr, nm, ac in offen if nm not in vergeben]
    ausgeschlossen = [(nr, nm, ac) for nr, nm, ac in offen if nm in vergeben]

    # Ein Name darf auch innerhalb des neuen Blocks nur einmal vorkommen.
    gesehen = {}
    for nr, nm, ac in neu:
        gesehen.setdefault(nm, []).append(nr)
    doppelt = {nm: v for nm, v in gesehen.items() if len(v) > 1}
    if doppelt:
        print("ABBRUCH: Name mehrfach im neuen Block — nicht entscheidbar:")
        for nm, v in sorted(doppelt.items()):
            print(f"  {nm}: {v}")
        return 3

    # emitVfsSyscall legt bis zu fuenf Argumente in Register; mehr kann dieser
    # Weg nicht, und raten waere hier der stille Default.
    zuviel = [(nr, nm, ac) for nr, nm, ac in neu if ac > 5]
    if zuviel:
        print("ABBRUCH: Argumentzahl > 5, der Registerweg traegt das nicht:")
        for nr, nm, ac in zuviel:
            print(f"  {nr} {nm} argc={ac}")
        return 4

    neu.sort(key=lambda t: t[0])
    stand = herkunft()

    zeilen = []
    a = zeilen.append
    a("// src/backend/lyxos/lyxos_builtins.lyx — die Syscalls, die der Kernel")
    a("// hat und die Handarbeit nicht erreicht hatte (#2549).")
    a("//")
    a("// ERZEUGT von tools/lyxos_builtins_erzeugen.py aus")
    a("// work/lyxos/syscall-argc.txt. NICHT VON HAND PFLEGEN — neu erzeugen,")
    a("// sonst laufen zwei Staende auseinander.")
    a("//")
    a(f"// Stand der Quelle: LyxOS {stand}.")
    a(f"// Von {len(tabelle)} Nummern mit lesbarer Gestalt erreichte das Backend")
    a(f"// {len(tabelle) - len(offen)}; dieser Block traegt {len(neu)} weitere.")
    a("//")
    a("// WOZU. Eine Nummer aus Lyx erreichbar zu machen, kostete VIER")
    a("// Handgriffe: sema._regBuiltin, die Namensauflistung in ir_lower, der")
    a("// Verteiler in emit_lyxos und die Liste in builtin_ziele. Vier")
    a("// Aufzaehlungen derselben Sache sind genau das Muster, das hier schon")
    a("// mehrfach auseinandergelaufen ist (#2432, #2450, #2463). Darum stehen")
    a("// die Daten EINMAL hier, und die vier Stellen fragen sie zur Laufzeit")
    a("// ueber eine Schleife ab. Eine neue Kernelnummer kostet damit einen")
    a("// Lauf dieses Skripts, keinen Eingriff an vier Stellen.")
    a("//")
    a("// WAS HIER NICHT STEHT:")
    a("//   - Nummern, die das Backend schon emittiert. Die haben ihren Weg;")
    a("//     ein zweiter waere eine zweite Stelle fuer dieselbe Sache.")
    a("//   - Nummern ohne lesbare Gestalt in der Kerneltabelle. Fuer die gibt")
    a("//     LyxosArgcFuerNr -1, und die Gestaltpruefung laesst sie durch")
    a("//     (#2482) — eine Argumentzahl zu raten waere der stille Default.")
    a("//   - Namen, die schon ein anderer Builtin traegt. Welche der beiden")
    a("//     Nummern gemeint ist, kann das Skript nicht wissen; es benennt")
    a("//     sie statt sie stillschweigend zu verwerfen:")
    for nr, nm, ac in sorted(ausgeschlossen):
        a(f"//       {nr} {nm} (argc {ac})")
    a("//")
    a(f"// Builtin-IDs: {ID_BASIS} .. {ID_BASIS + len(neu) - 1}, zusammenhaengend,")
    a("// damit der Verteiler in emit_lyxos EINE Bereichsabfrage ist.")
    a("")
    a("unit src.backend.lyxos.lyxos_builtins;")
    a("")
    a("// Erste Builtin-ID dieses Blocks.")
    a(f"pub con LYXOS_GEN_ID_BASIS: int64 := {ID_BASIS};")
    a("")
    a("// Wie viele Nummern dieser Block traegt.")
    a("pub fn LyxosGenAnzahl(): int64 {")
    a(f"  return {len(neu)};")
    a("}")
    a("")
    a("// Name, unter dem der Kernel den Eintrag i fuehrt, oder 0 bei ungueltigem i.")
    a("pub fn LyxosGenNameFuerIdx(i: int64): pchar {")
    for k, (nr, nm, ac) in enumerate(neu):
        a(f'  if (i == {k}) {{ return "{nm}"c; }}')
    a("  return 0 as pchar;")
    a("}")
    a("")
    a("// Namenslaenge des Eintrags i, oder -1. Getrennt gefuehrt, weil der")
    a("// Vergleich in ir_lower die Laenge VOR dem ersten Byte braucht.")
    a("pub fn LyxosGenNameLenFuerIdx(i: int64): int64 {")
    for k, (nr, nm, ac) in enumerate(neu):
        a(f"  if (i == {k}) {{ return {len(nm)}; }}")
    a("  return 0 - 1;")
    a("}")
    a("")
    a("// Syscallnummer des Eintrags i, oder -1.")
    a("pub fn LyxosGenNrFuerIdx(i: int64): int64 {")
    for k, (nr, nm, ac) in enumerate(neu):
        a(f"  if (i == {k}) {{ return {nr}; }}   // {nm}")
    a("  return 0 - 1;")
    a("}")
    a("")
    a("// Argumentzahl, die der Kernel fuer den Eintrag i liest, oder -1.")
    a("// Dieselbe Quelle wie LyxosArgcFuerNr — die beiden muessen")
    a("// uebereinstimmen, und tests/lyxos_gen_builtins_2549_test.sh prueft das.")
    a("pub fn LyxosGenArgcFuerIdx(i: int64): int64 {")
    for k, (nr, nm, ac) in enumerate(neu):
        a(f"  if (i == {k}) {{ return {ac}; }}   // {nm}")
    a("  return 0 - 1;")
    a("}")
    a("")
    a("// Index zum Namen, oder -1. Linearer Vergleich: die Liste ist dreistellig,")
    a("// und eine Streuung waere hier mehr Mechanik als Gewinn.")
    a("fn _lgEq(a: pchar, al: int64, b: pchar, bl: int64): int64 {")
    a("  if (al != bl) { return 0; }")
    a("  var i: int64 := 0;")
    a("  while (i < al) {")
    a("    if (peek8(a as int64 + i) != peek8(b as int64 + i)) { return 0; }")
    a("    i := i + 1;")
    a("  }")
    a("  return 1;")
    a("}")
    a("")
    a("pub fn LyxosGenIdxFuerName(nm: pchar, nl: int64): int64 {")
    a("  var i: int64 := 0;")
    a("  while (i < LyxosGenAnzahl()) {")
    a("    if (_lgEq(nm, nl, LyxosGenNameFuerIdx(i), LyxosGenNameLenFuerIdx(i)) != 0) { return i; }")
    a("    i := i + 1;")
    a("  }")
    a("  return 0 - 1;")
    a("}")
    inhalt = "\n".join(zeilen) + "\n"

    if pruefen:
        alt = open(ZIEL).read() if os.path.exists(ZIEL) else ""
        if alt == inhalt:
            print(f"aktuell: {os.path.relpath(ZIEL, WURZEL)} stimmt mit "
                  f"{os.path.relpath(ARGC, WURZEL)} ueberein ({len(neu)} Nummern)")
            return 0
        print(f"ABWEICHUNG: {os.path.relpath(ZIEL, WURZEL)} passt nicht zu "
              f"{os.path.relpath(ARGC, WURZEL)}")
        import difflib
        d = list(difflib.unified_diff(
            alt.split("\n"), inhalt.split("\n"), "alt", "neu", lineterm=""))
        for zeile in d[2:22]:
            print(zeile)
        print("  Neu erzeugen: tools/lyxos_builtins_erzeugen.py")
        return 1

    with open(ZIEL, "w") as f:
        f.write(inhalt)
    print(f"geschrieben: {os.path.relpath(ZIEL, WURZEL)} "
          f"({len(neu)} Nummern, IDs {ID_BASIS}..{ID_BASIS + len(neu) - 1}, LyxOS {stand})")
    print(f"  ausgeschlossen (Name vergeben): {len(ausgeschlossen)}")
    return 0


sys.exit(main())
