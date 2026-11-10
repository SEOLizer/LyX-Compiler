#!/usr/bin/env bash
# tests/win64_datei_api_test.sh — #2461: Datei- und Konsolenausgabe auf win64
# gehen ueber die Win32-API, nicht ueber rohe Linux-Syscalls.
#
# BEFUND, der zu diesem Test fuehrte (gemessen am 2026-11-10 auf Windows 11):
# `lyxc.exe --version` gab "lyxc Build:" aus — die beiden PrintStr-Teile kamen
# an, die beiden PrintStrLn-Teile nicht. `--help` gab GAR NICHTS aus.
# Ursache: PrintStr ist ein Builtin und ging ueber den win64-Helfer
# (GetStdHandle + WriteFile); PrintStrLn ist eine Bibliotheksfunktion
# (std/io.lyx) und rief write() — den rohen Linux-Syscall, der auf Windows
# einen fremden NT-Dienst trifft.
#
# WARUM WINE NICHT GENUEGT: wine fuehrt den Prozess auf dem LINUX-Kern aus, der
# rohe Syscall funktioniert dort. Jeder wine-Test war gruen, waehrend auf
# echtem Windows nichts ankam. Dieser Test misst deshalb zweierlei:
#   1. am ERZEUGNIS, dass die Nummern 0,1,2,3,8 nicht mehr im Code stehen
#      (deterministisch, braucht kein Windows),
#   2. unter wine die WIRKUNG, dass die Helfer auch das Richtige tun.
# Punkt 1 ist der Teil, der die Windows-Luecke wirklich bewacht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------- Programme

# Die Form, an der es auf Windows gescheitert ist: PrintStr kam an,
# PrintStrLn nicht. Der Test prueft beide Richtungen — ein Test nur auf
# PrintStrLn waere auch von einer Fassung erfuellt, die PrintStr kaputt macht.
cat > "$TMP/konsole.lyx" <<'LYX'
import src.std.io;
fn main(): int64 {
  PrintStr("C1 "c);
  PrintStrLn("C2"c);
  PrintStr("C3 "c);
  PrintStr("C4"c);
  PrintStrLn(""c);
  return 0;
}
LYX

# open/write/lseek/read/close in einem Durchgang. Gemessen wird der INHALT,
# den das Programm zurueckliest — nicht, dass die Datei entsteht. Eine Datei
# entsteht auch dann, wenn write nichts schreibt (#1827 steht fuer genau
# diesen Irrtum).
cat > "$TMP/datei.lyx" <<'LYX'
import src.std.io;
fn main(): int64 {
  var fd: int64 := open("w2461.txt"c, 577, 493);
  if (fd < 0) { PrintStrLn("OPEN-FEHLER"c); return 1; }
  var n: int64 := write(fd, "HALLO-2461"c, 10);
  if (n != 10) { PrintStrLn("WRITE-FEHLER"c); return 1; }
  close(fd);

  var fd2: int64 := open("w2461.txt"c, 0, 0);
  if (fd2 < 0) { PrintStrLn("REOPEN-FEHLER"c); return 1; }
  var pos: int64 := lseek(fd2, 6, 0);
  if (pos != 6) { PrintStrLn("LSEEK-FEHLER"c); return 1; }
  var buf: int64 := alloc(16);
  var m: int64 := read(fd2, buf as pchar, 4);
  if (m != 4) { PrintStrLn("READ-FEHLER"c); return 1; }
  poke8(buf + 4, 0);
  close(fd2);
  PrintStrLn(buf as pchar);
  return 0;
}
LYX

baue() {   # Name -> $TMP/<name>.exe
  "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" --target=win64 --format=pe \
          -o "$TMP/$1.exe" >"$TMP/$1.log" 2>&1
}

# ---------------------------------------------------------------- 1) Bytes
# Zahl UND Nummern. Die Gesamtzahl allein liesse offen, ob ausgerechnet
# write noch drinsteht.
zaehle_nr() {   # Datei, Nummer -> Anzahl
  python3 - "$1" "$2" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read(); nr = int(sys.argv[2]); n = 0
for p in range(len(d) - 1):
    if d[p] != 0x0F or d[p+1] != 0x05: continue
    if p >= 10 and d[p-10] == 0x48 and d[p-9] == 0xB8:
        if int.from_bytes(d[p-8:p], 'little') == nr: n += 1
    elif p >= 5 and d[p-5] == 0xB8:
        if int.from_bytes(d[p-4:p], 'little') == nr: n += 1
print(n)
PY
}

for name in konsole datei; do
  if ! baue "$name"; then
    no "$name uebersetzt" "$(grep -m1 -iE 'error|lyxc:' "$TMP/$name.log")"
    continue
  fi
  ok "$name uebersetzt"
  for nr in 0 1 2 3 8; do
    c=$(zaehle_nr "$TMP/$name.exe" "$nr")
    if [ "$c" = "0" ]; then
      ok "$name: kein roher Syscall $nr im Erzeugnis"
    else
      no "$name: Syscall $nr steht noch $c mal im Erzeugnis (#2461)"
    fi
  done
done

# Die Importe muessen auch wirklich in der Datei stehen — ein Aufruf in eine
# nicht importierte Funktion waere ein Sprung ins Leere.
for fn in CreateFileA ReadFile WriteFile CloseHandle SetFilePointerEx GetStdHandle; do
  if grep -q "$fn" "$TMP/datei.exe" 2>/dev/null; then
    ok "Import $fn steht in der PE"
  else
    no "Import $fn fehlt in der PE"
  fi
done

# ---------------------------------------------------------------- 2) Wirkung
if command -v wine >/dev/null 2>&1; then
  aus=$(cd "$TMP" && WINEDEBUG=-all timeout 120 wine konsole.exe 2>/dev/null | tr -d '\r')
  erw=$(printf 'C1 C2\nC3 C4\n')
  if [ "$aus" = "$erw" ]; then
    ok "wine: PrintStr und PrintStrLn geben beide aus"
  else
    no "wine: Konsolenausgabe" "erhalten [$(echo "$aus" | tr '\n' '|')]"
  fi

  aus2=$(cd "$TMP" && WINEDEBUG=-all timeout 120 wine datei.exe 2>/dev/null | tr -d '\r\n')
  if [ "$aus2" = "2461" ]; then
    ok "wine: open/write/lseek/read/close liefern den geschriebenen Inhalt"
  else
    no "wine: Datei-Durchgang" "erhalten [$aus2], erwartet [2461]"
  fi
  # Gegenprobe am Dateisystem: die Datei muss die zehn Bytes tragen.
  if [ "$(cat "$TMP/w2461.txt" 2>/dev/null)" = "HALLO-2461" ]; then
    ok "wine: die Datei traegt die geschriebenen Bytes"
  else
    no "wine: Dateiinhalt" "[$(cat "$TMP/w2461.txt" 2>/dev/null)]"
  fi
else
  echo "SKIP wine nicht vorhanden — die Byteprobe oben laeuft trotzdem"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
