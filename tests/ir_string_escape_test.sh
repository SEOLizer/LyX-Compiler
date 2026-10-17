#!/usr/bin/env bash
# tests/ir_string_escape_test.sh — #2130: Escapes in Zeichenketten-Literalen
# auf dem IR-Weg.
#
# Bis 1.2.15A kannte die Auswertung im IR (_strLitInternieren und eine
# zweite Kopie im PrintStr-Zweig) nur \n \t \r \\ \" \0. `\'` und `\xHH`
# fehlten, und der Catch-all reichte den Backslash UNVERAENDERT durch:
# "\x41B\tC" ergab auf arm64/riscv die Bytes 92 120 52 49 66 9 67 statt
# 65 66 9 67, die ANSI-Sequenzen aus std/crt.lyx kamen als sichtbares
# "\x1b[31m" an. Massstab ist x86 (cg_addStr, #1285).
#
# Gemessen werden die BYTES (peek8, Byte fuer Byte bis zur Null) auf x86_64,
# arm64 und riscv — jede Escape-Art, `c`-Literal, Modulkonstante, Local,
# PrintStr/Print-Ausgabe, ein Nullbyte im Inhalt (die Laenge im Vorspann,
# #1968, muss die AUSGEWERTETE sein) und std/crt.lyx. Gegenseite: eine
# unbekannte Sequenz wird auf beiden Wegen laut abgewiesen. lyxos: Bytes als
# Rueckgabewert ueber den lokalen LBF-Lader (nur peek8, nicht allokierend).
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

lauf() {  # ziel, binary
  case "$1" in
    linux) timeout 30 "$2" ;;
    arm64) timeout 30 "$QEMU_ARM64" "$2" ;;
    riscv) timeout 30 "$QEMU_RISCV64" "$2" ;;
  esac
}

pruefe() {  # name, datei, soll-ausgabe
  local t
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$2" -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>/dev/null | od -An -tu1 | tr -s ' \n' ' ' | sed 's/^ //;s/ $//')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = "0" ]; then ok "$1 [$t]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3]"; fi
  done
}

# zeig(s, n): n Bytes ab s als Zahlen, durch Leerzeichen getrennt, dann '|'.
# Mit n = ausgewertete Laenge + 1 wird die Null am Ende mitgemessen — steht
# dort etwas anderes, war die Laenge im Vorspann falsch.
cat > "$TMP/arten.lyx" <<'EOF'
con K: pchar := "\x1b[0m\'";
fn zeig(s: pchar, n: int64) {
  var i: int64 := 0;
  while i < n { PrintInt(peek8((s as int64) + i)); Print(" "); i := i + 1; }
  Print("|");
}
fn main(): int64 {
  zeig("\x41B\tC", 5);
  zeig("a\nb\rc\\d\"e\'f", 12);
  zeig("\x1b[31m", 6);
  zeig("\x7F\xff\X4a\xA0"c, 5);
  zeig(K, 6);
  var p: pchar := "q\x42\0z";
  zeig(p, 5);
  zeig("A\x00B\x43", 5);
  Print("\n");
  PrintStr("\x41\x42\t\n");
  Print("\x43\x44\'\n");
  return 0;
}
EOF
# Erwartung als Text, damit sie lesbar bleibt; verglichen wird die od-Form
# der Ausgabe (Ziffern, Leerzeichen und '|' als ASCII-Codes).
SOLL_TEXT='65 66 9 67 0 |97 10 98 13 99 92 100 34 101 39 102 0 |27 91 51 49 109 0 |127 255 74 160 0 |27 91 48 109 39 0 |113 66 0 122 0 |65 0 66 67 0 |'
SOLL="$( { printf '%s\n' "$SOLL_TEXT"; printf 'AB\t\nCD'"'"'\n'; } | od -An -tu1 | tr -s ' \n' ' ' | sed 's/^ //;s/ $//')"
pruefe "jede Escape-Art, c-Literal, con, Local, Nullbyte, PrintStr/Print" "$TMP/arten.lyx" "$SOLL"

# std/crt.lyx — die ANSI-Sequenzen, an denen der Fehler sichtbar war.
cat > "$TMP/crt.lyx" <<'EOF'
import std.crt;
fn main(): int64 {
  // Ueber eine Variable: Print(f()) auf ein importiertes Ergebnis kann der
  // IR-Weg (noch) nicht typisieren — das ist nicht Gegenstand dieses Tests.
  var a: pchar := FgSequence(red);
  var b: pchar := BgSequence(blue);
  Print(a); Print(b);
  return 0;
}
EOF
CRT_SOLL="$(printf '\033[31m\033[44m' | od -An -tu1 | tr -s ' \n' ' ' | sed 's/^ //;s/ $//')"
pruefe "std/crt.lyx FgSequence/BgSequence" "$TMP/crt.lyx" "$CRT_SOLL"

# Gegenseite: unbekannte Sequenz und \x ohne zwei Hexziffern laut abweisen,
# auf beiden Codegen-Wegen (x86 direkt, arm64 ueber ir_lower).
printf 'fn main(): int64 { Print("a\\qb"); return 0; }\n' > "$TMP/unb.lyx"
printf 'fn main(): int64 { Print("a\\x4"); return 0; }\n' > "$TMP/hex.lyx"
for f in unb hex; do
  for t in linux arm64; do
    ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$TMP/$f.lyx" -o "$TMP/k" ) >"$TMP/k.log" 2>&1; rc=$?
    if [ "$rc" != "0" ] && grep -qE "Escape-Sequenz|Hexziffern" "$TMP/k.log"; then ok "$f [$t]: laut abgewiesen"
    else nok "$f [$t]: rc=$rc, keine Meldung ($(head -c 200 "$TMP/k.log"))"; fi
  done
done

# --- lyxos: Bytes als Rueckgabewert ueber den lokalen LBF-Lader -------------
lyxos_rc() {  # quelle -> Exit-Code von main
  rm -f "$TMP/e.lyxnative" "$TMP/er"
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=lyxos "$1" -o "$TMP/e.lyxnative" ) >/dev/null 2>&1 || { echo "UEBERSETZT-NICHT"; return; }
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/e.lyxnative"c); return 111; }' "$TMP" > "$TMP/er.lyx"
  ( cd "$ROOT" && timeout 240 "$LYXC" "$TMP/er.lyx" -o "$TMP/er" ) >/dev/null 2>&1 || { echo "LADER-UEBERSETZT-NICHT"; return; }
  ( ulimit -v 4000000; timeout 10 "$TMP/er" >/dev/null 2>&1 ); echo $?
}
# Byte 0 ('A' = 65; vorher '\' = 92), Byte 2 (Tab = 9; vorher '4' = 52) und
# die Laenge bis zur Null (4; vorher 7).
cat > "$TMP/lx1.lyx" <<'EOF'
fn main(): int64 { var s: pchar := "\x41B\tC"; return peek8(s as int64); }
EOF
cat > "$TMP/lx2.lyx" <<'EOF'
fn main(): int64 { var s: pchar := "\x41B\tC"; return peek8((s as int64) + 2); }
EOF
cat > "$TMP/lx3.lyx" <<'EOF'
fn main(): int64 {
  var s: pchar := "\x41B\tC"c;
  var n: int64 := 0;
  while peek8((s as int64) + n) != 0 { n := n + 1; }
  return n;
}
EOF
r="$(lyxos_rc "$TMP/lx1.lyx")"; [ "$r" = "65" ] && ok "lyxos \\x41 [$r]" || nok "lyxos \\x41: [$r] statt [65]"
r="$(lyxos_rc "$TMP/lx2.lyx")"; [ "$r" = "9" ] && ok "lyxos \\t nach \\x41 [$r]" || nok "lyxos \\t nach \\x41: [$r] statt [9]"
r="$(lyxos_rc "$TMP/lx3.lyx")"; [ "$r" = "4" ] && ok "lyxos Laenge c-Literal [$r]" || nok "lyxos Laenge c-Literal: [$r] statt [4]"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
