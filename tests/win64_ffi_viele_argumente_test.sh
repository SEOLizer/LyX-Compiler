#!/usr/bin/env bash
# tests/win64_ffi_viele_argumente_test.sh — #2467: FFI-Aufrufe auf win64 ab
# dem fuenften Argument.
#
# BEFUND: bis 1.2.35C brach der Codegen bei mehr als vier FFI-Argumenten ab
# ("mehr als vier Argumente sind auf win64 nicht umgesetzt (#1674)"). 198 der
# 213 roten win64-Beispiele hingen allein daran — X11/GLX, sqlite und jede
# Netzprobe ueber std/net/socket (select hat fuenf Argumente).
#
# Die Microsoft-Konvention legt die Argumente 5..n in den ARGUMENTBEREICH des
# Aufrufers ([rsp+0x20] aufwaerts). Dieser Bereich und der 32-Byte-
# Schattenspeicher der vier Registerargumente sind EIN Block, nicht zwei —
# genau daran entscheidet sich, ob die Rechnung stimmt.
#
# Gemessen wird in zwei Ebenen:
#   1. am ERZEUGNIS, dass der Bereich die richtige Groesse hat und die
#      Argumente 5 und 6 in die richtigen Plaetze geschrieben werden
#      (deterministisch, braucht kein Windows);
#   2. unter wine der WERT, den die gerufene Funktion zurueckgibt. Ein Test,
#      der nur "uebersetzt wieder" prueft, waere auch von einer Fassung
#      erfuellt, die die Argumente vertauscht (#1789).
#
# WINE UND SEINE GRENZE: wine fuehrt den Prozess auf dem Linux-Kern aus, taugt
# also nicht als Nachweis fuer Windows-Dienste (siehe #2461). Fuer die
# Argumentuebergabe ist es dennoch aussagekraeftig: msvcrt.dll wird ueber die
# echte Win64-Konvention gerufen, ein falsch gelegtes Argument faellt dort auf.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

bau() { # bau <quelle> <ziel>
  "$LYXC" --std-path="$ROOT" --target=win64 --format=pe "$1" -o "$2" > "$TMP/log" 2>&1
}

# ---------------------------------------------------------------- Programme

# Sechs Argumente: vier in Registern, zwei im Argumentbereich.
cat > "$TMP/sechs.lyx" <<'LYX'
import src.std.io;

@capabilities([ffi.libc])
extern fn _snprintf(buf: pchar, n: int64, fmt: pchar, a: int64, b: int64, c: int64): int64 link "msvcrt.dll";

fn main(): int64 {
  var buf: pchar := alloc(64) as pchar;
  var n: int64 := _snprintf(buf, 64, "%d-%d-%d"c, 7, 8, 9);
  PrintStr(buf); PrintStr("\n"c);
  PrintInt(n); PrintStr("\n"c);
  return 0;
}
LYX

# Neun Argumente: die Positionen ab 7 kommen nicht aus einem Register, sondern
# aus dem Bereich, den der allgemeine Aufrufpfad vorher gepusht hat. Das ist
# ein ANDERER Quellweg als bei 5 und 6 und braucht darum eine eigene Probe.
cat > "$TMP/neun.lyx" <<'LYX'
import src.std.io;

@capabilities([ffi.libc])
extern fn _snprintf(buf: pchar, n: int64, fmt: pchar, a: int64, b: int64, c: int64, d: int64, e: int64, f: int64): int64 link "msvcrt.dll";

fn main(): int64 {
  var buf: pchar := alloc(64) as pchar;
  var n: int64 := _snprintf(buf, 64, "%d.%d.%d.%d.%d.%d"c, 11, 22, 33, 44, 55, 66);
  PrintStr(buf); PrintStr("\n"c);
  PrintInt(n); PrintStr("\n"c);
  return 0;
}
LYX

# Ein Gleitkommawert AB Position 5 liegt im Stapelplatz, nicht in xmm.
cat > "$TMP/gleit.lyx" <<'LYX'
import src.std.io;

@capabilities([ffi.libc])
extern fn _snprintf(buf: pchar, n: int64, fmt: pchar, a: int64, d: f64): int64 link "msvcrt.dll";

fn main(): int64 {
  var buf: pchar := alloc(64) as pchar;
  var x: f64 := 2.5;
  var n: int64 := _snprintf(buf, 64, "%d|%.3f"c, 5, x);
  PrintStr(buf); PrintStr("\n"c);
  return 0;
}
LYX

# Gegenprobe: VIER Argumente brauchen nur den Schattenspeicher. Ohne diese
# Probe waere auch eine Fassung gruen, die jedem Aufruf einen zu grossen
# Bereich gibt.
cat > "$TMP/vier.lyx" <<'LYX'
@capabilities([ffi.libc])
extern fn f4(a: int64, b: int64, c: int64, d: int64): int64 link "msvcrt.dll";

fn main(): int64 { return f4(1, 2, 3, 4); }
LYX

# ---------------------------------------------------------------- Uebersetzen

for q in sechs neun gleit vier; do
  if bau "$TMP/$q.lyx" "$TMP/$q.exe"; then
    ok "uebersetzt: $q.lyx"
  else
    no "uebersetzt: $q.lyx" "$(grep -m1 -i 'error' "$TMP/log")"
  fi
done

# Die alte Meldung darf nirgends mehr auftauchen.
if bau "$TMP/neun.lyx" "$TMP/neun.exe" && ! grep -q "nicht umgesetzt (#1674)" "$TMP/log"; then
  ok "die Abbruchmeldung aus #1674 ist weg"
else
  no "Abbruchmeldung" "$(grep -m1 '1674' "$TMP/log")"
fi

# ---------------------------------------------------------------- Erzeugnis

hex() { xxd -p "$1" | tr -d '\n'; }

# sechs Argumente -> zwei Stapelplaetze -> Bereich 32 + 2*8 = 48 = 0x30.
h=$(hex "$TMP/sechs.exe")
if [ "$(grep -o '4883ec30' <<<"$h" | wc -l)" -ge 1 ]; then
  ok "sechs Argumente: sub rsp, 0x30 (32 Schatten + 2*8)"
else
  no "sechs Argumente: Bereichsgroesse" "48 83 EC 30 fehlt"
fi
if [ "$(grep -o '4c89442420' <<<"$h" | wc -l)" -ge 1 ]; then
  ok "Argument 5 wird nach [rsp+0x20] geschrieben"
else
  no "Argument 5" "4C 89 44 24 20 fehlt"
fi
if [ "$(grep -o '4c894c2428' <<<"$h" | wc -l)" -ge 1 ]; then
  ok "Argument 6 wird nach [rsp+0x28] geschrieben"
else
  no "Argument 6" "4C 89 4C 24 28 fehlt"
fi
# Die Umschichtung in die MS-Register, von hinten nach vorn.
for pr in "4989c9:mov r9, rcx (Argument 3)" "4989d0:mov r8, rdx (Argument 2)"; do
  p="${pr%%:*}"; t="${pr#*:}"
  if grep -q "$p" <<<"$h"; then ok "Umschichtung: $t"; else no "Umschichtung: $t" "$p fehlt"; fi
done

# Gegenprobe: vier Argumente, also 32 Byte und KEIN Schreiben nach [rsp+0x20].
h4=$(hex "$TMP/vier.exe")
if grep -q '4883ec20' <<<"$h4"; then
  ok "vier Argumente: sub rsp, 0x20 (nur Schattenspeicher)"
else
  no "vier Argumente: Bereichsgroesse" "48 83 EC 20 fehlt"
fi

# ---------------------------------------------------------------- Wirkung

if command -v wine > /dev/null 2>&1; then
  a=$(cd "$TMP" && WINEDEBUG=-all timeout 120 wine sechs.exe 2>/dev/null | tr -d '\r')
  if [ "$(echo "$a" | sed -n 1p)" = "7-8-9" ] && [ "$(echo "$a" | sed -n 2p)" = "5" ]; then
    ok "wine: sechs Argumente kommen vollstaendig und in der Reihenfolge an"
  else
    no "wine: sechs Argumente" "erhalten [$(echo "$a" | tr '\n' '|')], erwartet [7-8-9|5]"
  fi

  b=$(cd "$TMP" && WINEDEBUG=-all timeout 120 wine neun.exe 2>/dev/null | tr -d '\r')
  if [ "$(echo "$b" | sed -n 1p)" = "11.22.33.44.55.66" ] && [ "$(echo "$b" | sed -n 2p)" = "17" ]; then
    ok "wine: neun Argumente, auch die aus dem gepushten Bereich"
  else
    no "wine: neun Argumente" "erhalten [$(echo "$b" | tr '\n' '|')]"
  fi

  c=$(cd "$TMP" && WINEDEBUG=-all timeout 120 wine gleit.exe 2>/dev/null | tr -d '\r\n')
  if [ "$c" = "5|2.500" ]; then
    ok "wine: f64 im Stapelplatz kommt als Zahl an, nicht als Bitmuster"
  else
    no "wine: f64 im Stapelplatz" "erhalten [$c], erwartet [5|2.500]"
  fi
else
  echo "SKIP wine nicht vorhanden — die Byteproben oben laufen trotzdem"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
