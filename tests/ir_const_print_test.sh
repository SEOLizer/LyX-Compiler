#!/usr/bin/env bash
# tests/ir_const_print_test.sh — #2019, #2022, #2025: was der IR-Weg bei
# String-Konstanten und bei Print konnte und was nicht.
#
# Alle drei Punkte haben dieselbe Bauart: der x86-Codegen nimmt den Schnellweg
# direkt vom AST und kann es laengst, der gemeinsame IR-Weg (arm64, riscv,
# lyxos, arm-cm4, xtensa) nicht. Aufgefallen ist es erst, als fuer #2014 die
# stdlib fuer arm64 vorkompiliert wurde — `make precompile-units` baut heute
# ausschliesslich x86_64, und DORT entsteht gar kein IR.
#
# GEMESSEN WIRD DIE WIRKUNG, nicht die Uebersetzbarkeit. Ein Test auf
# "uebersetzt durch" waere bei #2019 auch von einer Fassung erfuellt, die die
# Konstante still auf 0 setzt — das waere der stille Default und schlimmer als
# der laute Abbruch davor. Deshalb laeuft jedes Programm unter qemu und der
# TEXT wird verglichen, zeichenweise, gegen x86_64 als Referenz.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# qemu ist Voraussetzung fuer die Wirkungsmessung. Fehlt es, wird der Test
# NICHT still gruen: dann misst er nichts und muss das sagen.
QEMU_ARM=""; QEMU_RV=""
command -v qemu-aarch64-static >/dev/null 2>&1 && QEMU_ARM="qemu-aarch64-static"
command -v qemu-riscv64-static >/dev/null 2>&1 && QEMU_RV="qemu-riscv64-static"

# lauf <ziel> <quelle> <ausgabe-datei> → 0 = gebaut und gelaufen
lauf() {
  local ziel="$1"
  local src="$2"
  local out="$3"
  local bin="$TMP/b_$ziel"
  ( cd "$ROOT" && timeout 180 "$LYXC" --target="$ziel" "$src" -o "$bin" ) >"$TMP/build_$ziel.log" 2>&1 || return 1
  case "$ziel" in
    x86_64) timeout 60 "$bin" >"$out" 2>&1 ;;
    arm64)  [ -n "$QEMU_ARM" ] || return 2; timeout 60 $QEMU_ARM "$bin" >"$out" 2>&1 ;;
    riscv)  [ -n "$QEMU_RV" ]  || return 2; timeout 60 $QEMU_RV  "$bin" >"$out" 2>&1 ;;
  esac
  return 0
}

echo "--- #2019: String-Konstanten auf Modulebene ---"
#
# `pub con S: pchar := "…"` liess sich fuer KEIN IR-Ziel uebersetzen: der
# Konstantenfalter rechnet ganzzahlig und meldete "laesst sich nicht zur
# Uebersetzungszeit ausrechnen". 41 stdlib-Units hingen daran (Pfad- und
# Host-Konstanten in std/cloud/**, std/hardware/pci_*, std/net/whois).
#
# Der Wert wird NICHT als Global-Init abgelegt (das sind rohe 8 Byte in .data,
# eine Adresse steht dort erst beim Erzeugen fest), sondern wie im x86-Weg als
# Paar Name→Datenoffset; beim Zugriff wird die ADRESSE geladen.
cat > "$TMP/konst.lyx" <<'EOF'
unit main;
import std.io;
con HOST: pchar := "api.example.com";
con PFAD: pchar := "/sys/bus/pci/devices";
con ESC:  pchar := "a\tb\nc";
fn main(): int64 {
  PrintLn(HOST);
  PrintLn(PFAD);
  PrintLn(ESC);
  PrintLn(IntToStr(StrLen(HOST)));
  return 0;
}
EOF

if ! lauf x86_64 "$TMP/konst.lyx" "$TMP/konst.x86"; then
  nok "das Pruefprogramm uebersetzt nicht einmal fuer x86_64"; sed -n '1,5p' "$TMP/build_x86_64.log"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
# Die Referenz selbst muss stimmen — sonst vergleicht der Test zwei Fehler.
# Zeile 3 der QUELLE ist "a\tb\nc" — das sind ZWEI Ausgabezeilen. Die
# Laenge steht deshalb auf Zeile 5, nicht auf 4; beim ersten Anlauf stand
# hier 4 und der Test meldete einen Fehler, den es nicht gab.
if [ "$(sed -n '1p' "$TMP/konst.x86")" = "api.example.com" ] \
   && [ "$(sed -n '5p' "$TMP/konst.x86")" = "15" ]; then
  ok "x86_64 liefert die erwarteten Werte (Referenz belastbar)"
else
  nok "x86_64 liefert Unerwartetes: $(tr '\n' '|' < "$TMP/konst.x86")"
fi

for ziel in arm64 riscv; do
  lauf "$ziel" "$TMP/konst.lyx" "$TMP/konst.$ziel"; rc=$?
  if [ "$rc" = 2 ]; then
    nok "$ziel: qemu fehlt — die Wirkung wurde NICHT gemessen"
  elif [ "$rc" != 0 ]; then
    nok "$ziel: String-Konstante uebersetzt nicht ($(grep -m1 -E 'error|laesst' "$TMP/build_$ziel.log"))"
  elif diff -q "$TMP/konst.x86" "$TMP/konst.$ziel" >/dev/null; then
    ok "$ziel: String-Konstanten zeichengleich mit x86_64 (inkl. Escapes und StrLen)"
  else
    nok "$ziel: Ausgabe weicht ab: $(tr '\n' '|' < "$TMP/konst.$ziel")"
  fi
done

# GEGENPROBE: eine Konstante, deren Anfangswert wirklich nicht ausrechenbar
# ist, muss WEITERHIN abgewiesen werden. Ohne diese Haelfte waere der Test
# auch von einer Fassung erfuellt, die die Pruefung einfach entfernt.
# Eine Modul-VARIABLE als Anfangswert: der Parser laesst das durch (anders
# als einen Funktionsaufruf, den er selbst schon abweist — der erreicht den
# Falter gar nicht und taugt hier nicht als Probe), der Falter kann es nicht
# ausrechnen, denn `var` hat zur Uebersetzungszeit keinen Wert.
cat > "$TMP/unfaltbar.lyx" <<'EOF'
unit u;
pub var Y: int64 := 5;
pub con X: int64 := Y;
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --target=arm64 "$TMP/unfaltbar.lyx" -o /dev/null ) >"$TMP/uf.log" 2>&1; then
  nok "eine nicht ausrechenbare Konstante ging durch — die Pruefung ist weg statt erweitert"
else
  if grep -q "laesst sich nicht zur Uebersetzungszeit" "$TMP/uf.log"; then
    ok "nicht ausrechenbare Konstante wird weiterhin abgewiesen"
  else
    nok "abgewiesen, aber mit anderer Begruendung: $(grep -m1 -E 'error|lyxc:' "$TMP/uf.log")"
  fi
fi

echo
echo "--- #2022: Print-Typbestimmung steigt in den linken Operanden ab ---"
#
# `ip & 0xFF` ging, `ip >> 24` ging, `(ip >> 24) & 0xFF` nicht — und
# `ip * (ip + 1)` ging wieder, weil die Verschachtelung dort RECHTS steht.
# Es lag also nicht an Klammern und nicht an der Argumentzahl, sondern daran,
# dass nur EINE Ebene geprueft wurde. std/net/dns.lyx gab jede IP so aus.
for expr in 'ip' 'ip & 0xFF' 'ip >> 24' '(ip >> 24) & 0xFF' 'ip + 1 + 2' \
            '(ip + 1) & 1' 'ip & 1 & 2' '(ip >> 2) >> 3' 'ip * (ip + 1)' \
            '((ip >> 8) & 0xFF) + 1'; do
  printf 'unit t;\nimport std.io;\npub fn zeig(ip: int64) { Print(%s); }\n' "$expr" > "$TMP/t.lyx"
  if ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --target=arm64 "$TMP/t.lyx" -o /dev/null ) >"$TMP/t.log" 2>&1; then
    ok "Print($expr)"
  else
    nok "Print($expr) — $(grep -m1 -E 'kann den Typ|error' "$TMP/t.log")"
  fi
done

# Der WERT muss stimmen, nicht nur die Uebersetzbarkeit: ein Test auf
# "uebersetzt" waere auch von einer Fassung erfuellt, die den Typ RAET.
cat > "$TMP/ip.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var ip: int64 := 0xC0A80105;
  PrintLn(IntToStr((ip >> 24) & 0xFF));
  PrintLn(IntToStr((ip >> 16) & 0xFF));
  PrintLn(IntToStr(((ip >> 8) & 0xFF) + 1));
  return 0;
}
EOF
if lauf x86_64 "$TMP/ip.lyx" "$TMP/ip.x86"; then
  for ziel in arm64 riscv; do
    lauf "$ziel" "$TMP/ip.lyx" "$TMP/ip.$ziel"; rc=$?
    if [ "$rc" = 2 ]; then
      nok "$ziel: qemu fehlt — der Wert wurde NICHT gemessen"
    elif [ "$rc" != 0 ]; then
      nok "$ziel: verschachtelter Ausdruck uebersetzt nicht"
    elif diff -q "$TMP/ip.x86" "$TMP/ip.$ziel" >/dev/null; then
      ok "$ziel: verschachtelte Ausdruecke liefern dieselben Werte wie x86_64"
    else
      nok "$ziel: Werte weichen ab: $(tr '\n' '|' < "$TMP/ip.$ziel")"
    fi
  done
else
  nok "das IP-Pruefprogramm uebersetzt nicht fuer x86_64"
fi

# GEGENPROBE zur Aufzaehlung: ein f64-Ausdruck darf NICHT als Ganzzahl
# durchrutschen. Genau davor warnt der Kommentar an der Fundstelle — die
# Rekursion darf nicht zu "alles, was ich nicht erkenne, ist eine Zahl" werden.
cat > "$TMP/f64.lyx" <<'EOF'
unit f;
import std.io;
pub fn zeig(x: f64) { Print((x * 2.0) + 1.0); }
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --target=arm64 "$TMP/f64.lyx" -o /dev/null ) >"$TMP/f64.log" 2>&1; then
  nok "ein f64-Ausdruck ging als Ganzzahl durch — die Rekursion raet"
else
  ok "f64 in verschachteltem Ausdruck wird weiterhin abgewiesen"
fi

echo
echo "--- #2025: Print mit mehreren Argumenten faellt LAUT aus, nicht still ---"
#
# Saemtliche Print-Zweige des IR-Wegs lesen nur arg0. `Print(a, ".", b)` gab
# auf arm64 nur `7` aus, auf riscv gar nichts — ohne Meldung. In std/crt.lyx
# steht `Print("\x1b[", row, ";", col, "H")`; daraus wurde die halbe
# Steuersequenz. Das ist noch nicht behoben (#2025), aber es faellt nicht mehr
# still aus: ein halb ausgegebener Text sieht wie eine Ausgabe aus.
cat > "$TMP/multi.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var a: int64 := 7;
  var b: int64 := 9;
  Print(a, ".", b);
  PrintLn("");
  return 0;
}
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" --target=arm64 "$TMP/multi.lyx" -o "$TMP/multi.bin" ) >"$TMP/multi.log" 2>&1; then
  nok "Print(a, \".\", b) uebersetzte fuer arm64 — gibt es die Mehrfachausgabe jetzt wirklich? Dann #2025 schliessen und diesen Test auf den TEXT umstellen"
else
  if grep -q "mehreren Argumenten" "$TMP/multi.log"; then
    ok "Mehrfachargumente werden benannt abgewiesen (#2025), statt still zu verschwinden"
  else
    nok "abgewiesen, aber ohne den Grund zu nennen: $(grep -m1 -E 'error|lyxc:' "$TMP/multi.log")"
  fi
fi

# x86_64 ist von der Sperre NICHT betroffen — dort war die Mehrfachausgabe
# immer richtig, und eine Verschaerfung, die den Schnellweg mitnimmt, waere
# eine Regression fuer bestehende Programme.
if lauf x86_64 "$TMP/multi.lyx" "$TMP/multi.x86" && [ "$(sed -n '1p' "$TMP/multi.x86")" = "7.9" ]; then
  ok "x86_64 gibt weiterhin alle Argumente aus (7.9)"
else
  nok "x86_64 Mehrfachausgabe beschaedigt: $(tr '\n' '|' < "$TMP/multi.x86" 2>/dev/null)"
fi

echo
echo "--- #2026: String-Konstante mit CAST (\"…\"c as int64) ---"
#
# `con H: int64 := "…"c as int64` war auf dem x86-SCHNELLWEG STILL 0 —
# cg_collectCons prueft auf das Literal, nicht auf den Cast DARUM, und
# cg_evalConExpr rechnet ganzzahlig. In std/cloud/cf/transport.lyx steht so
# CF_API_HOST, der Zielhost jedes Cloudflare-Aufrufs: er war 0. 15 Units.
#
# Der Fix trennt zwei Dinge, die conIsPchar zusammen steuerte: die LADEART
# (Wert ist ein Datenoffset → LEA) und die TYPFRAGE (gilt als pchar). Bei
# `int64` gilt nur die erste — `PrintLn(H)` muss die ZAHL ausgeben.
cat > "$TMP/cast.lyx" <<'EOF'
unit main;
import std.io;
con S: pchar := "text-als-pchar";
con H: int64 := "adresse"c as int64;
con Z: int64 := 42;
fn main(): int64 {
  PrintLn(S);
  PrintLn(IntToStr(StrLen(S)));
  PrintLn(IntToStr(Z));
  PrintLn(H as pchar);
  PrintLn(IntToStr(StrLen(H as pchar)));
  return 0;
}
EOF
ERW="text-als-pchar|14|42|adresse|7|"
if lauf x86_64 "$TMP/cast.lyx" "$TMP/cast.x86"; then
  IST="$(tr '\n' '|' < "$TMP/cast.x86")"
  if [ "$IST" = "$ERW" ]; then
    ok "x86_64: Cast-Konstante traegt die Adresse, pchar-con bleibt Text, Zahl bleibt Zahl"
  else
    nok "x86_64: erwartet [$ERW], bekommen [$IST]"
  fi
  for ziel in arm64 riscv; do
    lauf "$ziel" "$TMP/cast.lyx" "$TMP/cast.$ziel"; rc=$?
    if [ "$rc" = 2 ]; then
      nok "$ziel: qemu fehlt — die Wirkung wurde NICHT gemessen"
    elif [ "$rc" != 0 ]; then
      nok "$ziel: Cast-Konstante uebersetzt nicht ($(grep -m1 -E 'error|kann den Typ' "$TMP/build_$ziel.log"))"
    elif diff -q "$TMP/cast.x86" "$TMP/cast.$ziel" >/dev/null; then
      ok "$ziel: gleiches Ergebnis wie x86_64 — die beiden Wege stimmen ueberein"
    else
      nok "$ziel: weicht ab: [$(tr '\n' '|' < "$TMP/cast.$ziel")]"
    fi
  done
else
  nok "das Cast-Pruefprogramm uebersetzt nicht fuer x86_64"
fi

# An der ECHTEN Quelle messen, nicht nur am Nachbau: CF_API_HOST war der
# Auesloeser. Ein Test am eigenen Minimalbeispiel haette den Fix belegt,
# ohne zu zeigen, dass die stdlib-Konstante wirklich stimmt.
cat > "$TMP/cf.lyx" <<'EOF'
unit main;
import std.io;
import std.cloud.cf.transport;
fn main(): int64 {
  PrintLn(CF_API_HOST as pchar);
  PrintLn(IntToStr(StrLen(CF_API_HOST as pchar)));
  return 0;
}
EOF
if lauf x86_64 "$TMP/cf.lyx" "$TMP/cf.x86"; then
  if [ "$(sed -n '1p' "$TMP/cf.x86")" = "api.cloudflare.com" ] && [ "$(sed -n '2p' "$TMP/cf.x86")" = "18" ]; then
    ok "CF_API_HOST aus der stdlib ist api.cloudflare.com (war 0)"
  else
    nok "CF_API_HOST falsch: [$(tr '\n' '|' < "$TMP/cf.x86")]"
  fi
else
  nok "std.cloud.cf.transport laesst sich nicht einbinden"
fi

# GEGENPROBE: ein Cast auf f64 als Print-Argument darf NICHT als Ganzzahl
# durchgehen. Der neue NK_CAST-Zweig liest den Zieltyp — er darf daraus nicht
# "alles, was ich nicht als pchar erkenne, ist eine Zahl" machen.
printf 'unit fc;\nimport std.io;\npub fn f(x: int64) { Print(x as f64); }\n' > "$TMP/fc.lyx"
if ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --target=arm64 "$TMP/fc.lyx" -o /dev/null ) >"$TMP/fc.log" 2>&1; then
  nok "Print(x as f64) ging als Ganzzahl durch — der Cast-Zweig raet"
else
  ok "Cast auf f64 wird weiterhin abgewiesen"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
