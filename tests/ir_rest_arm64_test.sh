#!/usr/bin/env bash
# tests/ir_rest_arm64_test.sh — die Restposten des IR-Wegs:
#   #2039  Print mit einem FELDZUGRIFF als Argument
#   #2042  EPrintFloat
#   #2043  eine IMPORTIERTE `extern fn`
#   #2045  clock_gettime als LyxOS-ID 211 fuer alle Ziele
#   #2047  eine ANNOTIERTE `extern fn` (beim Schreiben von #2043 gefunden)
#
# Alle vier sind dieselbe Klasse: eine Aufzaehlung im Lowerer kennt eine
# Herkunft nicht, oder eine zweite Stelle wurde nicht nachgezogen. Der
# x86-Schnellweg konnte jeden dieser Faelle laengst.
#
# GEMESSEN WIRD DIE WIRKUNG, nicht die Uebersetzbarkeit. Bei #2039 ist das
# besonders wichtig: was der Lowerer nicht bestimmen kann, darf er nicht
# RATEN — ein f64-Feld als Ganzzahl auszugeben waere ein falsches Ergebnis
# ohne Meldung. Deshalb steht neben jeder Prueflung die Gegenprobe.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
QEMU_ARM="$QEMU_ARM64"; QEMU_RV="$QEMU_RISCV64"

# $1 Beschreibung, $2 Quelle, $3 Erwartung (| statt Zeilenende), $4 Strom: out|err
alle_ziele() {
  local was="$1" src="$2" erw="$3" strom="${4:-out}"
  for ziel in x86_64 arm64 riscv; do
    local bin="$TMP/b_${ziel}"
    if ! ( cd "$ROOT" && timeout 300 "$LYXC" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
      continue
    fi
    local pre=""
    case "$ziel" in
      arm64) [ -n "$QEMU_ARM" ] || { nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; }; pre="$QEMU_ARM" ;;
      riscv) [ -n "$QEMU_RV" ]  || { nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; }; pre="$QEMU_RV" ;;
    esac
    local ist
    if [ "$strom" = "err" ]; then ist="$(timeout 60 $pre "$bin" 2>&1 1>/dev/null | tr '\n' '|')"
    else                          ist="$(timeout 60 $pre "$bin" 2>/dev/null   | tr '\n' '|')"; fi
    if [ "$ist" = "$erw" ]; then ok "$was [$ziel] = $erw"
    else nok "$was [$ziel]: [$ist] statt [$erw]"; fi
  done
}

echo "--- #2039: Print mit einem Feldzugriff ---"
#
# Das Feld ist `pchar`, die Auskunft steht in der Struktdeklaration —
# _printArt hat sie nur nie gelesen. Geprueft werden BEIDE Arten am selben
# Objekt: ein pchar-Feld muss als TEXT herauskommen, ein int64-Feld als ZAHL.
# Ein Zweig, der pauschal "Zeichenkette" oder pauschal "Zahl" sagt, faellt
# an genau einer der beiden Zeilen auf.
cat > "$TMP/feld.lyx" <<'EOF'
unit main;
import std.io;
type R = struct { s: pchar; n: int64; }
fn main(): int64 {
  var r: R;
  r.s := "Text"; r.n := 42;
  Print(r.s); PrintLn(""c);
  Print(r.n); PrintLn(""c);
  return 0;
}
EOF
alle_ziele "pchar-Feld als Text, int64-Feld als Zahl" "$TMP/feld.lyx" "Text|42|"

echo
echo "--- #2039: ein GEERBTES Feld wird ebenso aufgeloest ---"
#
# _exprTypeNode laeuft die Vererbungskette mit (_fieldTypeNodeIn). Ohne diese
# Haelfte waere der Test auch von einer Fassung erfuellt, die nur die eigenen
# Felder einer Klasse kennt.
cat > "$TMP/erbe.lyx" <<'EOF'
unit main;
import std.io;
type Basis = class { titel: pchar; };
type Abgeleitet = class extends Basis { zahl: int64; };
fn main(): int64 {
  var a: Abgeleitet := new Abgeleitet();
  a.titel := "Geerbt"; a.zahl := 7;
  Print(a.titel); PrintLn(""c);
  Print(a.zahl); PrintLn(""c);
  return 0;
}
EOF
alle_ziele "geerbtes pchar-Feld" "$TMP/erbe.lyx" "Geerbt|7|"

echo
echo "--- #2039 GEGENPROBE: ein f64-Feld wird weiterhin ABGEWIESEN ---"
#
# Die wichtigste Haelfte. Waere die Aufzaehlung durch ein "alles andere ist
# eine Zahl" ersetzt worden, gaebe dieser Fall still eine Ganzzahl aus —
# fehlerfrei uebersetzt, falsches Ergebnis. Genau davor warnt der Kommentar
# an der Fundstelle.
cat > "$TMP/f64.lyx" <<'EOF'
unit main;
import std.io;
type G = struct { w: f64; }
fn main(): int64 { var g: G; g.w := 1.5; Print(g.w); return 0; }
EOF
for ziel in arm64 riscv; do
  if ( cd "$ROOT" && timeout 300 "$LYXC" --target="$ziel" "$TMP/f64.lyx" -o "$TMP/f64.bin" ) >"$TMP/f64.log" 2>&1; then
    nok "$ziel: ein f64-Feld ging durch — wird es als Ganzzahl ausgegeben?"
  elif grep -q "kann den Typ des Arguments nicht bestimmen" "$TMP/f64.log"; then
    ok "$ziel: f64-Feld wird abgewiesen statt geraten"
  else
    nok "$ziel: abgewiesen, aber anders: $(grep -m1 -E '^lyxc:|error' "$TMP/f64.log")"
  fi
done

echo
echo "--- #2042: EPrintFloat schreibt nach STDERR ---"
cat > "$TMP/ef.lyx" <<'EOF'
unit main;
fn main(): int64 { EPrintFloat(1.5); return 0; }
EOF
alle_ziele "EPrintFloat(1.5) auf stderr" "$TMP/ef.lyx" "1.500000" err
# Und die andere Seite: auf stdout darf NICHTS landen. Ohne diese Haelfte
# waere der Test auch von einer Fassung erfuellt, die nach stdout schreibt
# und deren Ausgabe nur zufaellig mitgelesen wird.
alle_ziele "EPrintFloat: stdout bleibt leer" "$TMP/ef.lyx" "" out

echo
echo "--- #2045: clock_gettime liefert eine ECHTE Zeit ---"
#
# Gemessen gegen `date +%s`, mit grosszuegiger Toleranz. Ein Test auf
# "Rueckgabewert 0" waere auch von einem Zweig erfuellt, der nichts tut
# (vgl. #1827) — deshalb wird der WERT geprueft, nicht der Erfolg.
cat > "$TMP/ct.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var b: int64 := alloc(32);
  var rc: int64 := clock_gettime(0, b);
  if (rc != 0) { PrintLn("rc nicht 0"); return 1; }
  PrintLn(IntToStr(peek64(b)));
  return 0;
}
EOF
JETZT="$(date +%s)"
for ziel in x86_64 arm64 riscv; do
  bin="$TMP/ct_$ziel"
  if ! ( cd "$ROOT" && timeout 300 "$LYXC" --target="$ziel" "$TMP/ct.lyx" -o "$bin" ) >"$TMP/ct.log" 2>&1; then
    nok "#2045 [$ziel]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/ct.log"))"; continue
  fi
  case "$ziel" in
    x86_64) w="$(timeout 60 "$bin" 2>/dev/null)" ;;
    arm64)  [ -n "$QEMU_ARM" ] && w="$(timeout 60 $QEMU_ARM "$bin" 2>/dev/null)" || { nok "#2045 [$ziel]: qemu fehlt"; continue; } ;;
    riscv)  [ -n "$QEMU_RV" ]  && w="$(timeout 60 $QEMU_RV  "$bin" 2>/dev/null)" || { nok "#2045 [$ziel]: qemu fehlt"; continue; } ;;
  esac
  case "$w" in
    ''|*[!0-9]*) nok "#2045 [$ziel]: keine Zahl, sondern [$w]"; continue ;;
  esac
  d=$(( w > JETZT ? w - JETZT : JETZT - w ))
  if [ "$d" -le 600 ]; then
    ok "#2045 [$ziel]: Zeit stimmt mit date ueberein (Abweichung ${d}s)"
  else
    nok "#2045 [$ziel]: $w weicht um ${d}s von date ($JETZT) ab"
  fi
done

echo
echo "--- #2043: eine IMPORTIERTE extern fn wird gefunden ---"
#
# Der aufschlussreiche Teil war, dass DIESELBE Funktion einmal ging und
# einmal nicht: std/net/tls.lyx deklariert SSL_shutdown selbst und
# uebersetzte, std/net/mongo.lyx ruft sie ueber den Import und scheiterte.
# Gleiche Funktion, andere HERKUNFT. Beide gehoeren deshalb geprueft.
for u in std/net/tls.lyx std/net/mongo.lyx; do
  if ( cd "$ROOT" && timeout 420 "$LYXC" --compile-unit --target=arm64 "$u" -o /dev/null ) >"$TMP/u.log" 2>&1; then
    ok "$(basename "$u") uebersetzt fuer arm64"
  else
    nok "$(basename "$u") fuer arm64: $(grep -m1 -E '^lyxc:|error' "$TMP/u.log")"
  fi
done

echo
echo "--- #2043: der Bibliotheksname kommt aus der RICHTIGEN Quelle ---"
#
# Die Spanne der Bibliothek zeigt in den Quelltext der DEKLARIERENDEN Unit.
# Wird sie mit der eigenen Quelle gelesen, entsteht ein plausibler, aber
# falscher Name — ein stiller Default. Geprueft am Erzeugnis: der Name muss
# als Zeichenkette darin stehen.
#
# `labs` und nicht `abs`/`ceil`: die beiden sind Builtins, der Aufruf erreichte
# die extern-Deklaration gar nicht und der Test haette nichts gemessen.
#
# Der Fuellkommentar in haupt.lyx sorgt dafuer, dass an der Spanne aus
# bib/ffi.lyx in der EIGENEN Quelle anderer Text steht.
mkdir -p "$TMP/w/bib"
cat > "$TMP/w/bib/ffi.lyx" <<'EOF'
unit bib.ffi;
@capabilities([system.exit])
pub extern fn labs(i: int64): int64 link "libc.so.6";
EOF
cat > "$TMP/w/haupt.lyx" <<'EOF'
unit main;
import bib.ffi;
// Fueller: an derselben Stelle steht hier etwas anderes — "libfalsch.so.9" xx
fn main(): int64 { return labs(-9); }
EOF
if ( cd "$TMP/w" && timeout 300 "$LYXC" --std-path="$ROOT" --target=arm64 haupt.lyx -o ffi.bin ) >"$TMP/ffi.log" 2>&1; then
  if [ "$(strings -a "$TMP/w/ffi.bin" 2>/dev/null | grep -E '^lib.*\.so' | tr '\n' ' ')" = "libc.so.6 " ] \
     && strings -a "$TMP/w/ffi.bin" | grep -qx "labs"; then
    ok "importierte extern fn: genau 'libc.so.6' und das Symbol 'labs' stehen im Erzeugnis"
  else
    nok "uebersetzt, aber im Erzeugnis steht [$(strings -a "$TMP/w/ffi.bin" | grep -E '\.so' | tr '\n' ' ')] — falsche Quelle gelesen?"
  fi
else
  nok "eine importierte extern fn uebersetzt nicht: $(grep -m1 -E '^lyxc:|error' "$TMP/ffi.log")"
fi

echo
echo "--- #2047: eine ANNOTIERTE extern fn bleibt FFI (zweite Stelle zu #1287) ---"
#
# Beim Schreiben der Pruefung darueber gefunden: mit `@capabilities([...])`
# an der Deklaration legt der Parser die Annotation in c2 ab, und der IR-Weg
# las "c2 != -1" als "hat einen Rumpf". Die Deklaration wurde als LEERE
# Funktion erzeugt, der Aufruf traf sie — uebersetzt fehlerfrei, Erzeugnis
# statisch, Ergebnis der Inhalt eines unbeschriebenen Slots.
#
# "Uebersetzt" beweist hier also nichts (das tat es vorher auch). Gemessen
# wird am Erzeugnis: es muss einen PT_INTERP und einen DT_NEEDED tragen.
# Ausfuehren laesst es sich nur mit einer aarch64-libc, die der Buildhost
# nicht hat.
cat > "$TMP/anno.lyx" <<'EOF'
unit main;
@capabilities([system.exit])
extern fn labs(i: int64): int64 link "libc.so.6";
fn main(): int64 { return labs(-9); }
EOF
if ( cd "$ROOT" && timeout 300 "$LYXC" --target=arm64 "$TMP/anno.lyx" -o "$TMP/anno.bin" ) >"$TMP/anno.log" 2>&1; then
  if readelf -lW "$TMP/anno.bin" 2>/dev/null | grep -q 'INTERP' \
     && readelf -dW "$TMP/anno.bin" 2>/dev/null | grep -q 'libc.so.6'; then
    ok "arm64: annotierte extern fn ergibt ein dynamisches Erzeugnis (INTERP + NEEDED libc.so.6)"
  else
    nok "arm64: annotierte extern fn uebersetzt, aber das Erzeugnis ist STATISCH — leere Funktion statt FFI"
  fi
else
  nok "arm64: annotierte extern fn uebersetzt nicht: $(grep -m1 -E '^lyxc:|error' "$TMP/anno.log")"
fi
# Die andere Seite: riscv hat kein FFI. Dort muss derselbe Fall LAUT scheitern
# — vorher ging er durch, als leere Funktion. Geprueft wird nur, dass kein
# Erzeugnis entsteht, nicht der Wortlaut: kommt riscv-FFI eines Tages, greift
# der erste Zweig und prueft dann das Erzeugnis.
rm -f "$TMP/anno_rv.bin"
if ( cd "$ROOT" && timeout 300 "$LYXC" --target=riscv "$TMP/anno.lyx" -o "$TMP/anno_rv.bin" ) >"$TMP/anno.log" 2>&1; then
  if readelf -dW "$TMP/anno_rv.bin" 2>/dev/null | grep -q 'libc.so.6'; then
    ok "riscv: annotierte extern fn ergibt ein dynamisches Erzeugnis"
  else
    nok "riscv: annotierte extern fn ging durch, Erzeugnis ohne NEEDED — leere Funktion statt FFI"
  fi
else
  ok "riscv: annotierte extern fn wird abgewiesen statt als leere Funktion erzeugt"
fi

echo
echo "--- #2042/#2045: die betroffenen stdlib-Units uebersetzen ---"
for u in std/theorem123.lyx std/cloud/aws/sigv4.lyx; do
  if ( cd "$ROOT" && timeout 420 "$LYXC" --compile-unit --target=arm64 "$u" -o /dev/null ) >"$TMP/s.log" 2>&1; then
    ok "$(basename "$u") uebersetzt fuer arm64"
  else
    nok "$(basename "$u") fuer arm64: $(grep -m1 -E '^lyxc:|error' "$TMP/s.log")"
  fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
