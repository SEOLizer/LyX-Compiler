#!/usr/bin/env bash
# tests/sema_reste_2151_test.sh — #2151: sema und Zielkonstanten.
#
# Bis 1.2.16C:
#   (1) Eine void-Funktion als Wert (`var x: int64 := nichts();`,
#       `x := nichts()`, `return nichts();` in einer Funktion mit Wert) ging
#       ohne Meldung durch.
#   (2) Doppelte Felder/Methoden in einem Typ wurden nur im Wurzelmodul
#       gemeldet — in einer importierten Unit galt still die erste. (Die
#       Pruefung fand beim ersten Selbstbau fuenf Dopplungen im Compiler.)
#   (3) --debug auf einem IR-Ziel erzeugte kein DWARF, ohne Meldung.
#   (4) TARGET_OS war auf lyxos OS_LINUX, TARGET_ARCH auf esp32 ARCH_X86_64
#       (stiller Default in cfg_osCode/cfg_archCode).
#   (5) `Box<Unbekannt>` fuer einen generischen Typ einer anderen Unit wurde
#       nur in DEREN Datei gemeldet ("unknown return type").
#   (6) In IRLower gab es _fieldTypeNodeIn zweimal (strukturell, hier nicht
#       messbar — erfasst ueber (2) am Selbstbau).
#
# Jede Verschaerfung wird mit ihrer Gegenseite gemessen: was gueltig ist,
# muss weiter uebersetzen.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

baue() {  # datei ausgabe [optionen...] — im Verzeichnis der Datei
  local d f o; d="$(dirname "$1")"; f="$(basename "$1")"; o="$2"; shift 2
  ( cd "$d" && timeout 240 "$LYXC" --std-path="$ROOT" "$@" "$f" -o "$o" ) >"$o.log" 2>&1
}

# abgewiesen name datei muster [optionen]
abgewiesen() {
  local n="$1" f="$2" m="$3"; shift 3
  if baue "$f" "$TMP/x" "$@"; then nok "$n: uebersetzt"
  elif grep -q -- "$m" "$TMP/x.log"; then ok "$n: laut abgewiesen"
  else nok "$n: $(grep -m1 -iE 'error|fehler' "$TMP/x.log")"; fi
}
# angenommen name datei [optionen]
angenommen() {
  local n="$1" f="$2"; shift 2
  if baue "$f" "$TMP/y" "$@"; then ok "$n: uebersetzt"
  else nok "$n: $(grep -m1 -iE 'error|fehler' "$TMP/y.log")"; fi
}

# --- (1) void als Wert ----------------------------------------------------------
printf 'fn nichts(): void { }\nfn main(): int64 {\n  var x: int64 := nichts();\n  return 0;\n}\n' > "$TMP/v1.lyx"
abgewiesen "void als Anfangswert" "$TMP/v1.lyx" "liefert keinen Wert (void)"
printf 'fn nichts(): void { }\nfn main(): int64 {\n  var x: int64 := 1;\n  x := nichts();\n  return x;\n}\n' > "$TMP/v2.lyx"
abgewiesen "void in einer Zuweisung" "$TMP/v2.lyx" "liefert keinen Wert (void)"
printf 'fn nichts(): void { }\nfn zahl(): int64 { return nichts(); }\nfn main(): int64 { return zahl(); }\n' > "$TMP/v3.lyx"
abgewiesen "return void in Funktion mit Wert" "$TMP/v3.lyx" "liefert keinen Wert (void)"
# Gegenseite: void-Aufruf als Anweisung und `return nichts();` in einer void-Funktion
printf 'fn nichts(): void { }\nfn weiter(): void { return nichts(); }\nfn main(): int64 {\n  nichts(); weiter();\n  var x: int64 := 3;\n  return x - 3;\n}\n' > "$TMP/v4.lyx"
angenommen "void als Anweisung, return in void-Funktion" "$TMP/v4.lyx"

# --- (2) doppelte Methode in einer importierten Unit -----------------------------
mkdir -p "$TMP/dup/lib"
cat > "$TMP/dup/lib/zwei.lyx" <<'EOF'
pub type T = class {
  a: int64;
  fn Wert(): int64 { return 1; }
  fn Wert(): int64 { return 2; }
};
EOF
printf 'import lib.zwei;\nfn main(): int64 { var t: T := new T(); return t.Wert(); }\n' > "$TMP/dup/haupt.lyx"
abgewiesen "doppelte Methode in importierter Unit" "$TMP/dup/haupt.lyx" "bereits deklariert"
mkdir -p "$TMP/dupf/lib"
printf 'pub type U = class {\n  a: int64;\n  a: int64;\n};\n' > "$TMP/dupf/lib/feld.lyx"
printf 'import lib.feld;\nfn main(): int64 { var u: U := new U(); return 0; }\n' > "$TMP/dupf/haupt.lyx"
abgewiesen "doppeltes Feld in importierter Unit" "$TMP/dupf/haupt.lyx" "bereits deklariert"
# Gegenseite: gleichnamige Methode in ZWEI Klassen ist kein Fehler
mkdir -p "$TMP/ok/lib"
cat > "$TMP/ok/lib/zwei.lyx" <<'EOF'
pub type A = class { a: int64; fn Wert(): int64 { return 1; } };
pub type B = class { b: int64; fn Wert(): int64 { return 2; } };
EOF
printf 'import lib.zwei;\nfn main(): int64 { var a: A := new A(); var b: B := new B(); return a.Wert() + b.Wert() - 3; }\n' > "$TMP/ok/haupt.lyx"
angenommen "gleichnamige Methoden in verschiedenen Klassen" "$TMP/ok/haupt.lyx"

# --- (3) --debug auf einem IR-Ziel ------------------------------------------------
printf 'fn main(): int64 { return 0; }\n' > "$TMP/d.lyx"
if baue "$TMP/d.lyx" "$TMP/d" --target=arm64 --debug; then
  if grep -q "keine Debug-Information" "$TMP/d.log"; then ok "--debug auf arm64: Hinweis"
  else nok "--debug auf arm64: kein Hinweis"; fi
else nok "--debug auf arm64: uebersetzt nicht"; fi
if baue "$TMP/d.lyx" "$TMP/d2" --target=arm64; then
  if grep -q "keine Debug-Information" "$TMP/d2.log"; then nok "ohne --debug: Hinweis trotzdem"
  else ok "ohne --debug: kein Hinweis"; fi
else nok "ohne --debug: uebersetzt nicht"; fi

# --- (4) TARGET_OS / TARGET_ARCH ----------------------------------------------------
# Gemessen ueber @if: der falsche Zweig nennt eine Funktion, die es nicht gibt —
# uebersetzt das Programm, wurde der richtige Zweig genommen.
cat > "$TMP/os.lyx" <<'EOF'
fn main(): int64 {
  @if (TARGET_OS == OS_LYXOS) { return 0; } @else { return gibtEsNicht(); }
}
EOF
angenommen "TARGET_OS == OS_LYXOS auf lyxos" "$TMP/os.lyx" --target=lyxos
abgewiesen "TARGET_OS != OS_LYXOS auf linux" "$TMP/os.lyx" "gibtEsNicht"
cat > "$TMP/arch.lyx" <<'EOF'
fn main(): int64 {
  @if (TARGET_ARCH == ARCH_XTENSA && TARGET_BARE) { return 0; } @else { return gibtEsNicht(); }
}
EOF
angenommen "TARGET_ARCH == ARCH_XTENSA auf esp32" "$TMP/arch.lyx" --target=esp32
abgewiesen "TARGET_ARCH != ARCH_XTENSA auf linux" "$TMP/arch.lyx" "gibtEsNicht"

# --- (5) unbekanntes Typargument eines fremden generischen Typs --------------------
mkdir -p "$TMP/gen/lib"
cat > "$TMP/gen/lib/kiste.lyx" <<'EOF'
pub type Box<T> = class {
  v: T;
  fn Hole(): T { return self.v; }
};
EOF
cat > "$TMP/gen/haupt.lyx" <<'EOF'
import lib.kiste;
fn main(): int64 {
  var b: Box<Unbekannt> := new Box<Unbekannt>();
  return 0;
}
EOF
if baue "$TMP/gen/haupt.lyx" "$TMP/g"; then nok "Box<Unbekannt>: uebersetzt"
else
  # Die Meldung muss an der NENNUNG stehen (haupt.lyx, ohne Unit-Praefix, Zeile 3).
  if grep -E "^sema error \(line 3\): unbekannter Typ als Typargument" "$TMP/g.log" | grep -q "Unbekannt"; then
    ok "Box<Unbekannt>: an der Nennung gemeldet"
  else nok "Box<Unbekannt>: $(grep -m2 -iE 'error' "$TMP/g.log" | tr '\n' ' ')"; fi
fi
cat > "$TMP/gen/gut.lyx" <<'EOF'
import lib.kiste;
type Eigen = struct { a: int64; };
fn main(): int64 {
  var b: Box<int64> := new Box<int64>();
  var m: Map<int64, int64>;
  return 0;
}
EOF
angenommen "Box<int64> und Map<int64, int64>" "$TMP/gen/gut.lyx"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
