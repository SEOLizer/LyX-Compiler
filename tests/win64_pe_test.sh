#!/bin/bash
# win64/PE — Import-Tabelle, Relokationen, Aufrufkonvention (#1671, #1672, #1674)
#
# Gemessen wird unter wine, weil nur der echte Lader zeigt, ob die Datei
# akzeptiert wird und der Aufruf ankommt. Ohne wine wird uebersprungen — ein
# Test, der ohne Laufzeit gruen meldet, misst nichts.
#
#   * #1671: `extern fn ... link "x.dll"` muss in der Import-Tabelle stehen UND
#     der Aufruf muss ankommen. Beides wird geprueft: die Tabelle mit objdump,
#     die Wirkung im Programmlauf.
#   * #1672: eine Relokationstabelle groesser als eine Seite darf die Datei
#     nicht unbrauchbar machen. Geprueft mit einem Programm, das genug
#     absolute Zeiger erzeugt (700 Klassen mit virtueller Methode).
#   * #1674: Argumente muessen nach Microsoft-x64 ankommen — ein Aufruf OHNE
#     Argumente war schon vorher richtig und taugt allein nicht als Nachweis.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pruefe() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (erwartet '$3', erhalten '$2')"; fi; }

if ! command -v wine > /dev/null 2>&1; then
  echo "HINWEIS: wine fehlt — win64-Laufzeitpruefungen uebersprungen"
  echo "0 PASS, 0 FAIL"
  exit 0
fi
export WINEDEBUG=-all

lauf() {   # lauf <name>; Ausgabe in $TMP/<name>.out
  ( cd "$TMP" && timeout 90 wine "./$1.exe" ) > "$TMP/$1.out" 2>"$TMP/$1.err"
}

# ---------------------------------------------------------------- #1671/#1674
cat > "$TMP/ffi.lyx" <<'EOF'
unit Main;
import std.io;
import std.alloc;
@cap(ui.display)
extern fn GetTickCount(): int64 link "kernel32.dll";
@cap(ui.display)
extern fn lstrlenA(s: pchar): int64 link "kernel32.dll";
@cap(ui.display)
extern fn lstrcpynA(ziel: int64, quelle: pchar, n: int64): int64 link "kernel32.dll";
@cap(system.memory.heap)
extern fn VirtualAlloc(adr: int64, groesse: int64, art: int64, schutz: int64): int64 link "kernel32.dll";
fn main(): int64 {
  if (GetTickCount() > 0) { PrintLn("null-arg=1"); } else { PrintLn("null-arg=0"); }
  PrintLn("ein-arg=" + IntToStr(lstrlenA("abc")));
  PrintLn("ein-arg2=" + IntToStr(lstrlenA("abcdefgh")));
  var buf: int64 := alloc(32);
  lstrcpynA(buf, "hallowelt", 5);
  PrintLn("drei-arg=" + IntToStr(lstrlenA(buf as pchar)));
  var p: int64 := VirtualAlloc(0, 4096, 12288, 4);
  if (p != 0) { PrintLn("vier-arg=1"); } else { PrintLn("vier-arg=0"); }
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/ffi.lyx" --target=win64 --format=pe -o "$TMP/ffi.exe" > "$TMP/ffi.log" 2>&1; then
  bad "#1671 uebersetzt"; grep -E "error" "$TMP/ffi.log" | head -3
else
  ok "#1671 uebersetzt"
  # Die Tabelle selbst — der Aufruf koennte theoretisch auch anders ankommen.
  if command -v objdump > /dev/null 2>&1; then
    if objdump -x "$TMP/ffi.exe" 2>/dev/null | grep -q "GetTickCount"; then
      ok "#1671 eigene Funktion steht in der Import-Tabelle"
    else
      bad "#1671 eigene Funktion steht in der Import-Tabelle"
    fi
  fi
  lauf ffi
  if [ -s "$TMP/ffi.out" ]; then
    v() { grep "^$1=" "$TMP/ffi.out" | head -1 | cut -d= -f2 | tr -d '\r'; }
    pruefe "#1671 Aufruf kommt an (ohne Argumente)" "$(v null-arg)" "1"
    pruefe "#1674 ein Argument"                     "$(v ein-arg)"  "3"
    pruefe "#1674 ein Argument, laenger"            "$(v ein-arg2)" "8"
    pruefe "#1674 drei Argumente"                   "$(v drei-arg)" "4"
    pruefe "#1674 vier Argumente"                   "$(v vier-arg)" "1"
  else
    bad "#1671/#1674 Programm laeuft unter wine"; head -3 "$TMP/ffi.err"
  fi
fi

# ---------------------------------------------------------------- #1676
# Zwei DLLs. Der Nachweis zu #1671 hatte nur EINE geprueft (alles kernel32) —
# und genau deshalb blieb unentdeckt, dass die zweite Gruppe an der Stelle der
# ersten landete. Ab hier gehoeren zwei DLLs zum Nachweis.
cat > "$TMP/zwei.lyx" <<'EOF'
unit Main;
import std.io;
@cap(ui.display)
extern fn lstrlenA(s: pchar): int64 link "kernel32.dll";
@cap(ui.display)
extern fn GetSystemMetrics(i: int64): int64 link "user32.dll";
fn main(): int64 {
  PrintLn("len=" + IntToStr(lstrlenA("abcde")));
  var b: int64 := GetSystemMetrics(0);
  if (b > 0) { PrintLn("breite-ok=1"); } else { PrintLn("breite-ok=0"); }
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/zwei.lyx" --target=win64 --format=pe -o "$TMP/zwei.exe" > "$TMP/zwei.log" 2>&1; then
  bad "#1676 uebersetzt"; grep -E "error" "$TMP/zwei.log" | head -3
else
  ok "#1676 uebersetzt"
  if command -v objdump > /dev/null 2>&1; then
    # Jede Gruppe muss ihren EIGENEN Namen tragen. Vorher zeigten beide auf
    # dieselbe RVA, und der Name der zweiten fehlte in der Datei ganz.
    if objdump -p "$TMP/zwei.exe" 2>/dev/null | grep -q "GetSystemMetrics"; then
      ok "#1676 Name der zweiten DLL steht in der Datei"
    else
      bad "#1676 Name der zweiten DLL steht in der Datei"
    fi
    doppelt=$(objdump -p "$TMP/zwei.exe" 2>/dev/null | grep -cE "^\s+[0-9a-f]+\s+0\s+lstrlenA")
    pruefe "#1676 lstrlenA steht genau einmal in den Gruppen" "$doppelt" "1"
  fi
  lauf zwei
  if [ -s "$TMP/zwei.out" ]; then
    z() { grep "^$1=" "$TMP/zwei.out" | head -1 | cut -d= -f2 | tr -d '\r'; }
    pruefe "#1676 erste DLL"  "$(z len)"        "5"
    pruefe "#1676 zweite DLL" "$(z breite-ok)"  "1"
  else
    bad "#1676 Programm laeuft unter wine"; head -3 "$TMP/zwei.err"
  fi
fi

# ---------------------------------------------------------------- #1677
cat > "$TMP/env.lyx" <<'EOF'
unit Main;
import std.env;
import std.io;
fn main(): int64 {
  var v: pchar := EnvLookupRaw("PATH");
  PrintLn("erreicht=1");
  if (v != 0 as pchar) { PrintLn("path=1"); } else { PrintLn("path=0"); }
  var f: pchar := EnvLookupRaw("GIBTESNICHTXYZ");
  if (f == 0 as pchar) { PrintLn("fehlt=1"); } else { PrintLn("fehlt=0"); }
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/env.lyx" --target=win64 --format=pe -o "$TMP/env.exe" > "$TMP/env.log" 2>&1; then
  bad "#1677 uebersetzt"; grep -E "error" "$TMP/env.log" | head -3
else
  ok "#1677 uebersetzt"
  lauf env
  if [ -s "$TMP/env.out" ]; then
    ev() { grep "^$1=" "$TMP/env.out" | head -1 | cut -d= -f2 | tr -d '\r'; }
    pruefe "#1677 EnvLookupRaw kehrt zurueck" "$(ev erreicht)" "1"
    pruefe "#1677 PATH wird gefunden"         "$(ev path)"     "1"
    # Gegenprobe: eine Variable, die es nicht gibt, muss 0 liefern — sonst
    # koennte der Block-Durchlauf einfach irgendetwas zurueckgeben.
    pruefe "#1677 Unbekanntes bleibt unbekannt" "$(ev fehlt)"  "1"
  else
    bad "#1677 Programm laeuft unter wine"; head -3 "$TMP/env.err"
  fi
fi

# ---------------------------------------------------------------- #1672
{
  echo "import std.io;"
  i=0; while [ $i -lt 700 ]; do
    echo "type K$i = class { v: int64; fn Create(): void { self.v := $i; } virtual fn W(): int64 { return $i; } }"
    i=$((i+1))
  done
  echo "fn main(): int64 {"
  echo "  var s: int64 := 0;"
  i=0; while [ $i -lt 700 ]; do
    echo "  var o$i: K$i := new K$i(); s := s + o$i.W();"
    i=$((i+1))
  done
  echo '  PrintLn("summe=" + IntToStr(s));'
  echo "  return 0;"
  echo "}"
} > "$TMP/viel.lyx"

if ! "$LYXC" --std-path=. "$TMP/viel.lyx" --target=win64 --format=pe -o "$TMP/viel.exe" > "$TMP/viel.log" 2>&1; then
  bad "#1672 uebersetzt"; grep -E "error" "$TMP/viel.log" | head -3
else
  ok "#1672 uebersetzt"
  # Erst nachweisen, dass die Tabelle wirklich ueber einer Seite liegt —
  # sonst prueft der Test den Fall gar nicht.
  if command -v objdump > /dev/null 2>&1; then
    # Zeile: "Entry 5 <RVA> <Groesse> Base Relocation Directory [.reloc]"
    # Feld 4 ist die GROESSE; Feld 3 waere die Adresse gewesen.
    rsz=$(objdump -x "$TMP/viel.exe" 2>/dev/null | grep "Base Relocation Directory" | awk '{print $4}')
    rdec=$((16#${rsz:-0}))
    if [ "$rdec" -gt 4096 ]; then
      ok "#1672 Relokationstabelle ist groesser als eine Seite ($rdec Byte)"
    else
      bad "#1672 Testfall trifft den Fall nicht (nur $rdec Byte)"
    fi
  fi
  lauf viel
  # 0+1+…+699 = 244650
  pruefe "#1672 Datei startet und rechnet" "$(grep '^summe=' "$TMP/viel.out" 2>/dev/null | cut -d= -f2 | tr -d '\r')" "244650"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
