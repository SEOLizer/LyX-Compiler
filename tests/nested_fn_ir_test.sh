#!/usr/bin/env bash
# tests/nested_fn_ir_test.sh — #2020: verschachtelte Funktionen im IR-Weg.
#
# Eine `fn` im Rumpf einer anderen `fn` kannte nur der x86-Schnellweg. Im
# IR-Weg fiel die Deklaration durch die ganze if-Kette von lowerStmt und wurde
# STILL verworfen; der Rumpf entstand nie, und der Aufruf endete in
# "unbekannter Builtin/Funktion: w4". 14 stdlib-Units waren dadurch fuer
# arm64 unbaubar — zwoelf davon, weil sie std/cloud/aws/sigv4.lyx importieren.
#
# DIE ENTSCHEIDENDE MESSUNG stand vor der Umsetzung: darf eine verschachtelte
# Funktion auf die Umgebung zugreifen? sema sagt nein, fuer lokale Variablen
# UND fuer Parameter (sema.lyx:4483). Damit ist sie nichts als eine
# Modulfunktion, die weiter innen steht — Hochziehen genuegt, ein Static Link
# ist nicht noetig. Diese Sperre wird hier mitgeprueft: faellt sie, ist das
# Hochziehen still falsch, und dieser Test muss rot werden.
#
# GEMESSEN WIRD DER WERT, nicht die Uebersetzbarkeit. Eine Funktion, die an
# die falsche Stelle gebunden wird, uebersetzt sauber und rechnet Unsinn.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

QEMU_ARM=""; QEMU_RV=""
command -v qemu-aarch64-static >/dev/null 2>&1 && QEMU_ARM="qemu-aarch64-static"
command -v qemu-riscv64-static >/dev/null 2>&1 && QEMU_RV="qemu-riscv64-static"

# Uebersetzt fuer $1 und gibt die Ausgabe zurueck; rc 2 = qemu fehlt.
lauf() {
  local ziel="$1" src="$2" out="$3"
  local bin="$TMP/b_${ziel}_$(basename "$src" .lyx)"
  ( cd "$ROOT" && timeout 240 "$LYXC" --target="$ziel" "$src" -o "$bin" ) >"$TMP/build_$ziel.log" 2>&1 || return 1
  case "$ziel" in
    x86_64) timeout 60 "$bin" >"$out" 2>&1 ;;
    arm64)  [ -n "$QEMU_ARM" ] || return 2; timeout 60 $QEMU_ARM "$bin" >"$out" 2>&1 ;;
    riscv)  [ -n "$QEMU_RV" ]  || return 2; timeout 60 $QEMU_RV  "$bin" >"$out" 2>&1 ;;
  esac
  return 0
}

# $1 Beschreibung, $2 Quelle, $3 erwartete Ausgabe (mit | statt Zeilenende)
alle_ziele() {
  local was="$1" src="$2" erw="$3"
  for ziel in x86_64 arm64 riscv; do
    lauf "$ziel" "$src" "$TMP/aus.$ziel"; local rc=$?
    if [ "$rc" = 2 ]; then
      nok "$was [$ziel]: qemu fehlt — die Wirkung wurde NICHT gemessen"
    elif [ "$rc" != 0 ]; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/build_$ziel.log"))"
    else
      local ist; ist="$(tr '\n' '|' < "$TMP/aus.$ziel")"
      if [ "$ist" = "$erw" ]; then ok "$was [$ziel] = $erw"
      else nok "$was [$ziel]: [$ist] statt [$erw]"; fi
    fi
  done
}

# Wie alle_ziele, aber ohne x86_64 — fuer den einen Fall, den der
# x86-Schnellweg noch falsch rechnet (#2044).
ir_ziele() {
  local was="$1" src="$2" erw="$3"
  for ziel in arm64 riscv; do
    lauf "$ziel" "$src" "$TMP/aus.$ziel"; local rc=$?
    if [ "$rc" = 2 ]; then
      nok "$was [$ziel]: qemu fehlt — die Wirkung wurde NICHT gemessen"
    elif [ "$rc" != 0 ]; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/build_$ziel.log"))"
    else
      local ist; ist="$(tr '\n' '|' < "$TMP/aus.$ziel")"
      if [ "$ist" = "$erw" ]; then ok "$was [$ziel] = $erw"
      else nok "$was [$ziel]: [$ist] statt [$erw]"; fi
    fi
  done
}

echo "--- #2020: eine verschachtelte Funktion rechnet richtig ---"
#
# Die Ziffernzerlegung ist mit Absicht keine Rundung: 2026 muss als 2/0/2/6
# herauskommen. Ein vertauschtes Argument oder eine falsch gebundene Funktion
# liefert hier eine ANDERE Ziffernfolge, nicht nur eine andere Zahl.
cat > "$TMP/eine.lyx" <<'EOF'
unit main;
import std.io;
fn zerlege(n: int64): int64 {
  fn ziffer(v: int64, stelle: int64): int64 {
    var i: int64 := 0;
    while (i < stelle) { v := v / 10; i := i + 1; }
    return v - ((v / 10) * 10);
  }
  PrintLn(IntToStr(ziffer(n, 3)));
  PrintLn(IntToStr(ziffer(n, 2)));
  PrintLn(IntToStr(ziffer(n, 1)));
  PrintLn(IntToStr(ziffer(n, 0)));
  return 0;
}
fn main(): int64 { return zerlege(2026); }
EOF
alle_ziele "Ziffern von 2026" "$TMP/eine.lyx" "2|0|2|6|"

echo
echo "--- #2020: Geschwister rufen sich gegenseitig ---"
#
# Das ist der Fall, an dem eine zu einfache Umsetzung auffaellt: `zwei` ruft
# `eins`, und beide stehen eine Ebene innen. Wer nur den Namen der AEUSSEREN
# Funktion als Gueltigkeitsbereich kennt, findet `eins` von `zwei` aus nicht.
cat > "$TMP/geschwister.lyx" <<'EOF'
unit main;
import std.io;
fn aussen(): int64 {
  fn eins(n: int64): int64 { return n * 2; }
  fn zwei(n: int64): int64 { return eins(n) + 1; }
  return zwei(10);
}
fn main(): int64 { PrintLn(IntToStr(aussen())); return 0; }
EOF
alle_ziele "zwei(10) ueber eins(10)" "$TMP/geschwister.lyx" "21|"

echo
echo "--- #2020: zwei aeussere Funktionen mit GLEICHNAMIGEN inneren ---"
#
# Der Grund, warum die inneren Funktionen einen eindeutigen Namen bekommen
# ("Aussen@nib"). Stuenden beide unter `nib` im funcBuffer, entschiede die
# Reihenfolge, welche gilt — fehlerfrei uebersetzt, falsches Ergebnis.
# std/hardware/bluetooth_ext.lyx und bluetooth_gatts.lyx haben wirklich beide
# eine `nib` — allerdings in VERSCHIEDENEN Units, dort stossen sie nicht
# zusammen. Der Fall ist heute also latent, nicht akut.
#
# x86_64 ist hier AUSGESPART: dort tragen innere Funktionen ihren blanken
# Namen als Marke, die zweite `nib` trifft die erste, und das Programm
# liefert 11|11 statt 11|21 — fehlerfrei uebersetzt, falsches Ergebnis.
# Das ist #2044 und gehoert nicht zu #2020. Sobald es behoben ist, gehoert
# x86_64 in diese Pruefung (dann `alle_ziele` statt `ir_ziele`).
cat > "$TMP/gleichnamig.lyx" <<'EOF'
unit main;
import std.io;
fn ersteR(): int64 {
  fn nib(n: int64): int64 { return n + 10; }
  return nib(1);
}
fn zweiteR(): int64 {
  fn nib(n: int64): int64 { return n + 20; }
  return nib(1);
}
fn main(): int64 { PrintLn(IntToStr(ersteR())); PrintLn(IntToStr(zweiteR())); return 0; }
EOF
ir_ziele "gleichnamige innere bleiben getrennt" "$TMP/gleichnamig.lyx" "11|21|"

echo
echo "--- #2020: die Sperre gegen den Zugriff auf die Umgebung HAELT ---"
#
# BEIDE SEITEN. Der Test oben zeigt, dass das Hochziehen rechnet; er waere
# aber auch von einer Fassung erfuellt, die heimlich eine Umgebung mitgibt und
# damit etwas zusichert, was die Sprache nicht hat. Faellt eine dieser beiden
# Abweisungen weg, ist das Hochziehen nicht mehr gleichwertig — dann muss
# dieser Test rot werden und nicht der Nutzer es merken.
for was in lokal param; do
  if [ "$was" = "lokal" ]; then
    cat > "$TMP/sperre.lyx" <<'EOF'
unit main;
fn aussen(): int64 { var v: int64 := 1; fn innen(): int64 { return v; } return innen(); }
fn main(): int64 { return aussen(); }
EOF
  else
    cat > "$TMP/sperre.lyx" <<'EOF'
unit main;
fn aussen(p: int64): int64 { fn innen(): int64 { return p; } return innen(); }
fn main(): int64 { return aussen(1); }
EOF
  fi
  for ziel in x86_64 arm64; do
    if ( cd "$ROOT" && timeout 240 "$LYXC" --target="$ziel" "$TMP/sperre.lyx" -o "$TMP/sp" ) >"$TMP/sp.log" 2>&1; then
      nok "Zugriff auf die Umgebung ($was) ging fuer $ziel durch — das Hochziehen ist damit still falsch"
    elif grep -q "verschachtelte Funktion darf keine lokale Variable" "$TMP/sp.log"; then
      ok "Zugriff auf die Umgebung ($was) wird fuer $ziel abgewiesen"
    else
      nok "($was/$ziel) abgewiesen, aber mit anderer Begruendung: $(grep -m1 -E 'error' "$TMP/sp.log")"
    fi
  done
done

echo
echo "--- #2020: von AUSSEN bleibt die innere Funktion unerreichbar ---"
#
# Gegenprobe zum Hochziehen: es macht die Funktion NICHT modulweit sichtbar.
# Ohne diese Haelfte waere der Test auch von einer Fassung erfuellt, die alle
# inneren Funktionen einfach auf Modulebene kippt.
cat > "$TMP/aussen.lyx" <<'EOF'
unit main;
fn traeger(): int64 { fn innen(): int64 { return 3; } return innen(); }
fn fremd(): int64 { return innen(); }
fn main(): int64 { return fremd(); }
EOF
for ziel in x86_64 arm64; do
  if ( cd "$ROOT" && timeout 240 "$LYXC" --target="$ziel" "$TMP/aussen.lyx" -o "$TMP/au" ) >"$TMP/au.log" 2>&1; then
    nok "$ziel: eine innere Funktion ist von aussen aufrufbar geworden"
  elif grep -q "undefined function" "$TMP/au.log"; then
    ok "$ziel: der Aufruf von aussen bleibt abgewiesen"
  else
    nok "$ziel: abgewiesen, aber anders: $(grep -m1 -E 'error' "$TMP/au.log")"
  fi
done

echo
echo "--- #2020: die betroffenen stdlib-Units uebersetzen fuer arm64 ---"
#
# Die drei Units mit echten verschachtelten Funktionen, dazu zwei der zwoelf,
# die nur ueber den Import von sigv4 mithingen — der Fehler trat dort auf,
# obwohl sie selbst keine verschachtelte Funktion enthalten.
for u in std/cloud/aws/sigv4.lyx std/hardware/bluetooth_ext.lyx \
         std/hardware/bluetooth_gatts.lyx std/cloud/s3.lyx std/cloud/dynamodb.lyx; do
  if ( cd "$ROOT" && timeout 420 "$LYXC" --compile-unit --target=arm64 "$u" -o /dev/null ) >"$TMP/u.log" 2>&1; then
    ok "$(basename "$u") uebersetzt fuer arm64"
  else
    nok "$(basename "$u") fuer arm64: $(grep -m1 -E '^lyxc:|error' "$TMP/u.log")"
  fi
done

echo
echo "--- #2020: eine ECHTE stdlib-Funktion mit innerer fn rechnet richtig ---"
#
# `_gs_uuid16_str` aus std/hardware/bluetooth_gatts.lyx, WOERTLICH uebernommen
# (die Funktion ist nicht `pub`, also von aussen nicht rufbar — umgeschrieben
# waere sie nicht mehr dieselbe Fundstelle).
#
# Die innere `nib` traegt eine BEDINGUNG: Ziffern bekommen +48, Buchstaben +55.
# Wird sie falsch gebunden oder gar nicht erzeugt, stehen an den vier Stellen
# andere Zeichen — der Fehler faellt als falscher Text auf, nicht als Absturz.
# 0x2A37 ist die Bluetooth-UUID fuer die Herzfrequenzmessung.
#
# NACHGERECHNET, nicht abgelesen: `nib` gibt Buchstaben n+55, also GROSS
# ("A" = 10+55 = 65). Der feste Schwanz der Zeichenkette steht dagegen klein
# in der Quelle ("f9b34fb"), der Text ist also gemischt. Mein erster
# Erwartungswert war durchgehend klein — falsch war die Erwartung, nicht die
# Unit; alle drei Ziele stimmten von Anfang an ueberein.
#
# Nicht genommen: SigV4DateNow (die andere echte Fundstelle). Sie haengt an
# clock_gettime, das der IR-Weg als LyxOS-Builtin 211 emittiert — auf arm64
# und riscv nicht behandelt. Das ist ein FREMDER offener Defekt (#2045) und
# hat mit verschachtelten Funktionen nichts zu tun; ein Test, der daran
# haengt, misst nicht mehr, was er behauptet.
cat > "$TMP/uuid.lyx" <<'EOF'
unit main;
import std.io;
fn _gs_uuid16_str(uuid: int64, outBuf: int64) {
  var h: [4]int64;
  h[0] := (uuid >> 12) & 0xF;
  h[1] := (uuid >> 8)  & 0xF;
  h[2] := (uuid >> 4)  & 0xF;
  h[3] :=  uuid        & 0xF;
  fn nib(n: int64): int64 { if (n < 10) { return n+48; } return n+55; }
  poke8(outBuf+ 0,48);poke8(outBuf+ 1,48);poke8(outBuf+ 2,48);poke8(outBuf+ 3,48);
  poke8(outBuf+ 4, nib(h[0]));
  poke8(outBuf+ 5, nib(h[1]));
  poke8(outBuf+ 6, nib(h[2]));
  poke8(outBuf+ 7, nib(h[3]));
  poke8(outBuf+ 8,45);
  poke8(outBuf+ 9,48);poke8(outBuf+10,48);poke8(outBuf+11,48);poke8(outBuf+12,48);
  poke8(outBuf+13,45);
  poke8(outBuf+14,49);poke8(outBuf+15,48);poke8(outBuf+16,48);poke8(outBuf+17,48);
  poke8(outBuf+18,45);
  poke8(outBuf+19,56);poke8(outBuf+20,48);poke8(outBuf+21,48);poke8(outBuf+22,48);
  poke8(outBuf+23,45);
  poke8(outBuf+24,48);poke8(outBuf+25,48);poke8(outBuf+26,56);poke8(outBuf+27,48);
  poke8(outBuf+28,53);poke8(outBuf+29,102);poke8(outBuf+30,57);poke8(outBuf+31,98);
  poke8(outBuf+32,51);poke8(outBuf+33,52);poke8(outBuf+34,102);poke8(outBuf+35,98);
  poke8(outBuf+36,0);
}
fn main(): int64 {
  var b: int64 := alloc(64);
  _gs_uuid16_str(0x2A37, b);
  PrintLn(b as pchar);
  _gs_uuid16_str(0x180D, b);
  PrintLn(b as pchar);
  return 0;
}
EOF
alle_ziele "UUID 0x2A37/0x180D als Text" "$TMP/uuid.lyx" \
  "00002A37-0000-1000-8000-00805f9b34fb|0000180D-0000-1000-8000-00805f9b34fb|"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
