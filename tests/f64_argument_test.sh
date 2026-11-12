#!/usr/bin/env bash
# tests/f64_argument_test.sh — ganzzahliges Literal an einem Gleitkomma-
# Parameter (#2219).
#
# Bis 1.2.19E ging das Literal als BITMUSTER ins Register. Die Ganzzahl 3 ist
# als double eine Denormalzahl nahe null, deshalb lieferte `eins(5)` 0.00 und
# `mittel(3, 4.0)` 2.00 — die Haelfte des anderen Summanden, ohne Meldung.
#
# Die Rechnung stand im Haus schon zweimal: `cg_retToF64` bei der Rueckgabe
# (#2004) und `cg_emitMixedToF64` bei gemischter Arithmetik (#1212, dort
# lautete der Befund "`10 - 2.5` ergab -1.75"). Die Argumentuebergabe war die
# fehlende dritte Stelle.
#
# Geprueft wird auf ALLEN drei ausfuehrbaren Zielen, und das ist hier nicht
# Fleiss, sondern noetig: der Schnellweg (x86) und der IR-Weg haben getrennte
# Argumentuebergaben. Nach dem x86-Fix lieferte dasselbe Programm auf x86
# 5.00 und auf arm64 weiter 0.000000 — gemessen, bevor der IR-Weg nachgezogen
# wurde. Ein Test nur auf x86 waere dafuer blind gewesen.
#
# Die Faelle decken bewusst die Wege ab, auf denen Argumente verschieden
# eingesammelt werden: bis sechs Argumente, mehr als sechs (eigener Pfad),
# benannte Argumente (eigene Ordnung), faltbarer Ausdruck und Vorzeichen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
. "$(dirname "$0")/lib/qemu.sh"   # #2048

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# alle NAME ERWARTET QUELLE — x86-64, arm64 und riscv mit derselben Erwartung.
# Die Erwartung ist die x86-Schreibweise von FloatToStr; die IR-Ziele nutzen
# src.std.io und schreiben mehr Nachkommastellen, deshalb wird dort nur der
# Zahlenwert verglichen (auf zwei Stellen gerundet).
alle() {
  local name="$1" erwartet="$2" quelle="$3" got
  printf '%s\n' "$quelle" > "$TMP/c.lyx"

  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c.x86" >"$TMP/c.log" 2>&1); then
    no "$name [x86_64]" "uebersetzt nicht: $(sed -n '1,3p' "$TMP/c.log" | tr '\n' ' ')"; return
  fi
  got=$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/c.x86" 2>/dev/null | tr '\n' ' ' )
  got="${got% }"
  if [ "$got" = "$erwartet" ]; then ok "$name [x86_64] ($got)"
  else no "$name [x86_64]" "'$got' erwartet '$erwartet'"; fi

  # IR-Weg: dieselbe Quelle, aber src.std.io und gerundeter Vergleich.
  printf '%s\n' "${quelle/import std.io;/import src.std.io;}" > "$TMP/i.lyx"
  local ziel qemu
  for ziel in arm64 riscv; do
    if [ "$ziel" = "arm64" ]; then qemu="$QEMU_ARM64"; else qemu="$QEMU_RISCV64"; fi
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=$ziel "$TMP/i.lyx" -o "$TMP/c.$ziel" >"$TMP/i.log" 2>&1); then
      no "$name [$ziel]" "uebersetzt nicht: $(sed -n '1,3p' "$TMP/i.log" | tr '\n' ' ')"; continue
    fi
    if [ -z "$qemu" ]; then ok "$name [$ziel] (nur uebersetzt — qemu fehlt)"; continue; fi
    got=$( ulimit -c 0; cd "$TMP" && timeout 60 "$qemu" "$TMP/c.$ziel" 2>/dev/null \
           | awk '{ printf "%.2f ", $1 }' )
    got="${got% }"
    if [ "$got" = "$erwartet" ]; then ok "$name [$ziel] ($got)"
    else no "$name [$ziel]" "'$got' erwartet '$erwartet'"; fi
  done
}

# --- der gemeldete Fall ------------------------------------------------------
alle "#2219: einzelnes Literal" "5.00" 'import std.io;
fn eins(a: f64): f64 { return a; }
fn main(): int64 { var r: f64 := eins(5); PrintLn(FloatToStr(r, 2)); return 0; }'

alle "#2219: Literal links und rechts" "3.50 3.50" 'import std.io;
fn mittel(a: f64, b: f64): f64 { var s: f64 := a + b; return s / 2.0; }
fn main(): int64 {
  var r1: f64 := mittel(3, 4.0);
  var r2: f64 := mittel(4.0, 3);
  PrintLn(FloatToStr(r1, 2));
  PrintLn(FloatToStr(r2, 2));
  return 0;
}'

# --- die Wege, auf denen Argumente verschieden eingesammelt werden -----------

# `cg_istSicherGanz` erfasst auch faltbare Ausdruecke, nicht nur Literale.
alle "#2219: faltbarer Ausdruck" "5.00" 'import std.io;
fn eins(a: f64): f64 { return a; }
fn main(): int64 { var r: f64 := eins(2 + 3); PrintLn(FloatToStr(r, 2)); return 0; }'

alle "#2219: Vorzeichen" "-4.00" 'import std.io;
fn eins(a: f64): f64 { return a; }
fn main(): int64 { var r: f64 := eins(0 - 4); PrintLn(FloatToStr(r, 2)); return 0; }'

# f32 zaehlt mit: cg_isFloatTypeName kennt beide Breiten (#1127).
alle "#2219: f32-Parameter" "7.00" 'import std.io;
fn f32f(a: f32): f32 { return a; }
fn main(): int64 { var r: f64 := f32f(7) as f64; PrintLn(FloatToStr(r, 2)); return 0; }'

# Benannte Argumente nehmen eine eigene Ordnung (cg_orderCallArgs) — und
# zugleich die Stelle, an der die Wandlung jetzt sitzt.
alle "#2219: benannte Argumente" "9.00" 'import std.io;
fn benannt(x: f64, y: f64): f64 { return x - y; }
fn main(): int64 { var r: f64 := benannt(y: 1, x: 10); PrintLn(FloatToStr(r, 2)); return 0; }'

# Mehr als sechs Argumente gehen einen eigenen Pfad (Stapel statt Register).
# Mit nur kurzen Aufrufen waere dieser Pfad ungeprueft geblieben.
alle "#2219: acht Argumente" "36.00" 'import std.io;
fn acht(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64): f64 {
  return a + b + c + d + e + f + g + h;
}
fn main(): int64 { var r: f64 := acht(1, 2, 3, 4, 5, 6, 7, 8);
  PrintLn(FloatToStr(r, 2)); return 0; }'

# Gemischte Signatur: die Ganzzahl am int64-Parameter darf NICHT gewandelt
# werden. Ein Test nur mit reinen f64-Signaturen waere blind dafuer, dass die
# Wandlung zu weit greift.
alle "#2219: gemischte Signatur" "6.00" 'import std.io;
fn gemischt(n: int64, x: f64): f64 { return x * (n as f64); }
fn main(): int64 { var r: f64 := gemischt(3, 2); PrintLn(FloatToStr(r, 2)); return 0; }'

# --- die Gegenprobe: die laute Ablehnung muss bleiben -----------------------
#
# Eine ganzzahlige VARIABLE ist kein Literal und wird von sema abgewiesen.
# Wuerde die Wandlung diese Meldung mit verschlucken, waere aus einem
# gemeldeten Fehler ein stiller geworden — die schlechtere Haelfte des Tauschs.
cat > "$TMP/v.lyx" <<'LYXEOF'
import std.io;
fn eins(a: f64): f64 { return a; }
fn main(): int64 { var k: int64 := 5; PrintLn(FloatToStr(eins(k), 2)); return 0; }
LYXEOF
if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/v.lyx" -o "$TMP/v" >"$TMP/v.log" 2>&1); then
  no "#2219: ganzzahlige Variable bleibt abgewiesen" "uebersetzt durch — die sema-Meldung ist verlorengegangen"
else
  if grep -q 'f64 erwartet' "$TMP/v.log"; then
    ok "#2219: ganzzahlige Variable bleibt abgewiesen (sema meldet es)"
  else
    no "#2219: ganzzahlige Variable bleibt abgewiesen" "abgewiesen, aber mit anderer Meldung: $(sed -n '2,3p' "$TMP/v.log" | tr '\n' ' ')"
  fi
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
