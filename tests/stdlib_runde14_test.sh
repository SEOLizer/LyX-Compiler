#!/bin/bash
# Runde 14 — stdlib-Verhalten (#1634, #1657, #1640, #1641)
#
# Jeder Abschnitt prueft den WEG, nicht nur ein plausibles Ergebnis:
#   * #1634: gezaehlt wird, dass Punktdateien DA sind und `.`/`..` FEHLEN.
#     Ein reiner Zaehltest waere auch mit dem alten Verhalten erklaerbar.
#   * #1657: Bitmuster gegen die IEEE-754-Referenz, nicht formatierte Zahlen —
#     eine Abweichung von 1 ULP sieht formatiert identisch aus.
#   * #1640: acht f64 gegen eine echte C-Bibliothek, dazu die gemischte
#     Signatur und ein zweiter Aufruf (waechst der Stapel, faellt er auf).
#   * #1641: gemessen wird die ZEIT gegen einen Server, der nie antwortet.
#     Vorher lief das unbegrenzt.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
WURZEL="$(pwd)"
LYXC_ABS="$(cd "$(dirname "$LYXC")" && pwd)/$(basename "$LYXC")"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pruefe() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (erwartet '$3', erhalten '$2')"; fi; }

# ---------------------------------------------------------------- #1634
mkdir -p "$TMP/dot"
: > "$TMP/dot/sichtbar.txt"; : > "$TMP/dot/.versteckt"; : > "$TMP/dot/.config"
mkdir -p "$TMP/dot/.unterordner"
cat > "$TMP/dir.lyx" <<EOF
import std.fs;
import std.io;
fn main(): int64 {
  var d: int64 := DirList("$TMP/dot");
  var n: int64 := DirEntryCount(d);
  PrintLn("n=" + IntToStr(n));
  var i: int64 := 0;
  while (i < n) { PrintStr("e="); PrintLn(DirEntryName(d, i)); i := i + 1; }
  DirFree(d);
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/dir.lyx" -o "$TMP/dir" > "$TMP/dir.log" 2>&1; then
  bad "#1634 uebersetzt"; grep -E "error" "$TMP/dir.log" | head -3
else
  ok "#1634 uebersetzt"
  if timeout 60 "$TMP/dir" > "$TMP/dir.out" 2>&1; then
    n=$(grep "^n=" "$TMP/dir.out" | cut -d= -f2)
    # LC_ALL=C: die Standardsortierung uebergeht fuehrende Punkte, damit haengt
    # die Reihenfolge an der Spracheinstellung des Laufs.
    eintraege=$(grep "^e=" "$TMP/dir.out" | cut -d= -f2 | LC_ALL=C sort | tr '\n' ' ')
    pruefe "#1634 Anzahl (drei Dateien + ein Verzeichnis)" "$n" "4"
    pruefe "#1634 Punktdateien sind dabei, . und .. nicht" \
           "$eintraege" ".config .unterordner .versteckt sichtbar.txt "
  else
    bad "#1634 laeuft"; head -3 "$TMP/dir.out"
  fi
fi

# ---------------------------------------------------------------- #1657
cat > "$TMP/flt.lyx" <<'EOF'
import std.io;
import std.alloc;
fn bits(d: f64): int64 { var c: int64 := alloc(8); pokef64(c, d); return peek64(c); }
fn main(): int64 {
  PrintLn("e300=" + IntToStr(bits(1.0e300)));
  PrintLn("e308=" + IntToStr(bits(1.0e308)));
  PrintLn("max=" + IntToStr(bits(1.7976931348623157e308)));
  PrintLn("gross=" + IntToStr(bits(9.87654321e250)));
  PrintLn("klein=" + IntToStr(bits(1.0e-300)));
  PrintLn("eins=" + IntToStr(bits(1.0)));
  PrintLn("wurzel2=" + IntToStr(bits(1.4142135623730951)));
  PrintLn("zehntel=" + IntToStr(bits(0.1)));
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/flt.lyx" -o "$TMP/flt" > "$TMP/flt.log" 2>&1; then
  bad "#1657 uebersetzt"; grep -E "error" "$TMP/flt.log" | head -3
else
  ok "#1657 uebersetzt"
  if timeout 60 "$TMP/flt" > "$TMP/flt.out" 2>&1; then
    # Referenz: die Bitmuster des naechstgelegenen double. Fest eingetragen,
    # damit der Test keine Fremdsprache braucht.
    b() { grep "^$1=" "$TMP/flt.out" | head -1 | cut -d= -f2; }
    pruefe "#1657 1.0e300 bitgenau"               "$(b e300)"    "9094988921128908188"
    pruefe "#1657 1.0e308 bitgenau"               "$(b e308)"    "9214871658872686752"
    pruefe "#1657 groesster double bleibt endlich" "$(b max)"     "9218868437227405311"
    pruefe "#1657 9.87654321e250 bitgenau"        "$(b gross)"   "8361942968457934682"
    pruefe "#1657 1.0e-300 bitgenau"              "$(b klein)"   "118622047889322841"
    pruefe "#1657 1.0 unveraendert"               "$(b eins)"    "4607182418800017408"
    pruefe "#1657 Wurzel 2 unveraendert"          "$(b wurzel2)" "4609047870845172685"
    pruefe "#1657 0.1 unveraendert"               "$(b zehntel)" "4591870180066957722"
  else
    bad "#1657 laeuft"
  fi
fi

# ---------------------------------------------------------------- #1640
if ! command -v gcc > /dev/null 2>&1; then
  echo "HINWEIS: gcc fehlt — #1640 (FFI mit acht f64) uebersprungen"
else
  gcc -shared -fPIC -o "$TMP/libargsum.so" tests/data/runde14/argsum.c 2>"$TMP/gcc.log"
  if [ ! -f "$TMP/libargsum.so" ]; then
    bad "#1640 Testbibliothek gebaut"; head -3 "$TMP/gcc.log"
  else
    cat > "$TMP/ffi.lyx" <<'EOF'
import std.io;
@cap(ui.display)
extern fn f8(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64): f64 link "./libargsum.so";
@cap(ui.display)
extern fn f6(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64): f64 link "./libargsum.so";
@cap(ui.display)
extern fn mix(n: int64, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64): f64 link "./libargsum.so";
@cap(ui.display)
extern fn ganz8(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64): int64 link "./libargsum.so";
fn main(): int64 {
  PrintLn("f8=" + FloatToStr(f8(1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0), 1));
  PrintLn("f6=" + FloatToStr(f6(1.0,1.0,1.0,1.0,1.0,1.0), 1));
  PrintLn("mix=" + FloatToStr(mix(7, 1.0,1.0,1.0,1.0,1.0,1.0,1.0), 1));
  PrintLn("ganz8=" + IntToStr(ganz8(1,1,1,1,1,1,1,1)));
  PrintLn("wieder=" + FloatToStr(f8(2.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0), 1));
  return 0;
}
EOF
    # Die Bibliothek wird als "./libargsum.so" gebunden, also muss aus $TMP
    # heraus uebersetzt und gestartet werden.
    if ! (cd "$TMP" && "$LYXC_ABS" --std-path="$WURZEL" ffi.lyx -o ffi) > "$TMP/ffi.log" 2>&1; then
      bad "#1640 uebersetzt (acht Gleitkommaargumente)"; grep -E "error" "$TMP/ffi.log" | head -3
    else
      ok "#1640 uebersetzt (acht Gleitkommaargumente)"
      if (cd "$TMP" && timeout 60 ./ffi) > "$TMP/ffi.out" 2>&1; then
        v() { grep "^$1=" "$TMP/ffi.out" | head -1 | cut -d= -f2; }
        pruefe "#1640 acht f64 in xmm0-7"        "$(v f8)"     "36.0"
        pruefe "#1640 sechs f64 unveraendert"    "$(v f6)"     "21.0"
        pruefe "#1640 gemischt int + sieben f64" "$(v mix)"    "7028.0"
        pruefe "#1640 acht Ganzzahlen unveraendert" "$(v ganz8)" "36"
        pruefe "#1640 zweiter Aufruf (Stapel bleibt)" "$(v wieder)" "2.0"
      else
        bad "#1640 laeuft"; head -3 "$TMP/ffi.out"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------- #1641
cat > "$TMP/dns.lyx" <<'EOF'
import std.io;
import std.net.dns;
import std.alloc;
fn main(): int64 {
  var res: int64 := alloc(128);
  // 203.0.113.1 aus TEST-NET-3 antwortet nie — genau der Fall, der vorher
  // unbegrenzt blockierte.
  var ip: int64 := (203 << 24) | (0 << 16) | (113 << 8) | 1;
  if (DNSResolve("beispiel.test" as int64, 13, ip, res)) { PrintLn("antwort"); }
  else { PrintLn("aufgegeben"); }
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/dns.lyx" -o "$TMP/dns" > "$TMP/dns.log" 2>&1; then
  bad "#1641 uebersetzt"; grep -E "error" "$TMP/dns.log" | head -3
else
  ok "#1641 uebersetzt"
  start=$(date +%s)
  timeout 30 "$TMP/dns" > "$TMP/dns.out" 2>&1
  rc=$?
  dauer=$(( $(date +%s) - start ))
  if [ "$rc" -eq 124 ]; then
    bad "#1641 gibt auf statt zu haengen (nach ${dauer}s abgeschnitten)"
  else
    ok "#1641 gibt auf statt zu haengen (${dauer}s)"
    pruefe "#1641 meldet den Fehlschlag" "$(cat "$TMP/dns.out")" "aufgegeben"
    # #1918: Hier stand zusaetzlich eine UNTERGRENZE von 4 s — die Annahme,
    # der Fehlschlag muesse lange dauern. Das ist keine Zusicherung der
    # Bibliothek, sondern eine Eigenschaft des Resolvers: antwortet er sofort
    # mit "gibt es nicht", ist der Fall nach 2 s erledigt, und die Bibliothek
    # hat sich dabei voellig richtig verhalten. Im vollen Lauf ist der Test
    # daran geflackert.
    #
    # Geblieben ist die OBERgrenze, und die traegt die Aussage: `std.dns` gibt
    # auf, statt zu haengen. Ein schneller Fehlschlag ist kein Defekt; ein
    # unbegrenzter waere einer.
    if [ "$dauer" -le 12 ]; then
      ok "#1641 wartet nicht unbegrenzt (${dauer}s, Grenze 12 s)"
    else
      bad "#1641 wartet nicht unbegrenzt" "gemessen ${dauer}s"
    fi
  fi
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
