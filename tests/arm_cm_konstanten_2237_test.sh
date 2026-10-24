#!/usr/bin/env bash
# tests/arm_cm_konstanten_2237_test.sh — arm-cm kuerzt 64-Bit-Konstanten nicht mehr still (#2237).
#
# cm_LI lud `imm & 0xFFFFFFFF` ohne Meldung: XXHash64 uebersetzte fuer
# arm-cm4 und lieferte 98376185. Jetzt dieselbe Regel wie esp32 (xt_li,
# #2149): eine Konstante im Code, die weder vorzeichenbehaftet noch
# vorzeichenlos in 32 Bit passt, wird beim Uebersetzen laut abgewiesen.
#
# Beide Richtungen: die Grenzwerte, die passen (2^32-1, -2^31, 2^31-1, -1),
# uebersetzen und rechnen richtig (qemu, Semihosting); 2^32 und ein 64-Bit-
# Wert werden abgewiesen. Dazu: ein Programm mit `import std.hash`, das nur
# HashDJB2 nutzt, uebersetzt weiter — die Anfangswerte der Modulkonstanten
# (FNV) werden nicht beim Uebersetzen abgewiesen, sondern beim LESEN
# (Merkerwort, #2239, tests/wort32_merker_2239_test.sh). Wuerde dieser Weg
# mit abgewiesen, waere std.hash auf arm-cm4 ganz unbenutzbar.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }
QARM="$(command -v qemu-system-arm || true)"

uebersetze() { (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=arm-cm4 "$1" -o "$2" >"$2.log" 2>&1); }

# Passende Grenzwerte: Ausgabe der unteren 8 Bit, einzeln (eine Summe
# ueber alle vier passte selbst nicht in 32 Bit).
printf 'import std.io;\nfn main(): int64 {\n  var a: int64 := 4294967295; var b: int64 := 0 - 2147483648; var c: int64 := 2147483647; var d: int64 := 0 - 1;\n  PrintInt(a & 255); PrintStr(" "c); PrintInt(b & 255); PrintStr(" "c); PrintInt(c & 255); PrintStr(" "c); PrintInt(d & 255); PrintLn(""c);\n  return 0;\n}\n' > "$TMP/g.lyx"
if uebersetze "$TMP/g.lyx" "$TMP/g"; then
  if [ -z "$QARM" ]; then ok "Grenzwerte uebersetzen (qemu-system-arm fehlt)"
  else
    got="$(timeout 20 "$QARM" -M olimex-stm32-h405 -nographic -semihosting -kernel "$TMP/g" 2>&1 </dev/null | tr -d '\r' | grep -vE 'terminating on signal|^qemu' | head -1)"
    exp="255 0 255 255"
    if [ "$got" = "$exp" ]; then ok "Grenzwerte rechnen richtig ($got)"; else no "Grenzwerte" "'$got' erwartet '$exp'"; fi
  fi
else no "Grenzwerte" "abgewiesen: $(grep -m1 -i error "$TMP/g.log")"; fi

# Nicht darstellbar: abgewiesen, mit Meldung und Issue.
for v in 4294967296 6833185961996073490 "0 - 4294967297"; do
  printf 'fn main(): int64 { var x: int64 := %s; return x & 7; }\n' "$v" > "$TMP/n.lyx"
  if uebersetze "$TMP/n.lyx" "$TMP/n"; then no "$v" "uebersetzt, waere still gekuerzt worden"
  elif grep -q "passt nicht in 32 Bit (#2237)" "$TMP/n.log"; then ok "$v laut abgewiesen"
  else no "$v" "abgewiesen, aber andere Meldung: $(grep -m1 -i error "$TMP/n.log")"; fi
done

# std.hash ohne die 64-Bit-Funktionen bleibt nutzbar.
printf 'import std.io;\nimport std.hash;\nfn main(): int64 { var h: int64 := HashDJB2("abc"); PrintInt(h); PrintLn(""c); return 0; }\n' > "$TMP/h.lyx"
if uebersetze "$TMP/h.lyx" "$TMP/h"; then ok "import std.hash (nur DJB2) uebersetzt"
else no "import std.hash" "$(grep -m1 -i error "$TMP/h.log")"; fi

echo "arm_cm_konstanten_2237: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
