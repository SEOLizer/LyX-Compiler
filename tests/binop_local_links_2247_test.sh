#!/usr/bin/env bash
# tests/binop_local_links_2247_test.sh — #2247: ein einfaches Local LINKS in
# einer kommutativen Operation stellt den Speicheroperanden.
#
# `s := s + peek32(a + i * 4)` ist der Akkumulator jeder Summenschleife. Bis
# 1.2.23B rettete der allgemeine Weg das Local mit push/pop ueber die
# Auswertung der rechten Seite:
#
#   mov %r13,%rax ; push %rax ; movsxd (%r14,%r12,4),%rax
#   pop %rbx      ; add %rbx,%rax ; mov %rax,%r13
#
# Das Paar ist eine Store->Load-Weiterleitung JE GLIED (~5 Takte) und band
# die Schleife an die Latenz: 36 % weniger Befehle (#2247, Schnellweg fuer
# peek*/poke*) brachten dort GAR KEINE Zeit, gemessen sogar 6 % Verlust.
# cg_binOpLocalRechts (#2114) konnte den Fall nicht nehmen, weil es das Local
# nur RECHTS erkannte. Getauscht bleibt `add %r13,%rax` uebrig.
#
# Geprueft wird beides:
#
#   A. am ERZEUGNIS, dass die Sicherung verschwunden ist — eine Summen-
#      funktion darf genau ein push/pop tragen (rbp im Rahmen). Vor dem Fix
#      kam je Glied eines dazu, der Test waere rot gewesen.
#   B. am WERT, dass der Tausch nur dort greift, wo er erlaubt ist. Die
#      Gegenseite ist der wichtigere Teil: MINUS, PERCENT, Schiebungen und
#      LT/LE/GT/GE sind NICHT kommutativ — wer sie mittauscht, dreht das
#      Ergebnis bzw. den Vergleich um. Jeder dieser Faelle hat das Local
#      links, trifft also genau die neue Bedingung.
#
# Dieselben Werte auf arm64 und riscv: die Aenderung sitzt im x86-Codegen,
# die anderen Ziele sind der unveraenderte Gegenstand.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

ZIELE="x86"
[ -n "$QEMU_ARM64" ] && ZIELE="$ZIELE arm64" || echo "HINWEIS: Emulator fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv" || echo "HINWEIS: Emulator fuer riscv fehlt"

fall() { # name erwartet   (Quelle auf stdin)
  local name="$1" erw="$2"
  cat > "$TMP/$name.lyx"
  local z
  for z in $ZIELE; do
    local opt="" q=""
    [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
    [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/$name.lyx" -o "$TMP/$name.$z" >"$TMP/$name.$z.log" 2>&1); then
      no "$name $z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$name.$z.log")"; continue
    fi
    local got
    got=$( cd "$TMP" && timeout 60 $q "$TMP/$name.$z" 2>&1 | tr '\n' ' ' ); got="${got% }"
    if [ "$got" = "$erw" ]; then ok "$name $z: $got"; else no "$name $z" "'$got' erwartet '$erw'"; fi
  done
}

# ------------------------------------------------------------------
# A. Am Erzeugnis: die Summenschleife traegt keine Sicherung mehr.
# ------------------------------------------------------------------
cat > "$TMP/akk.lyx" <<'LYX'
unit main;
import std.io;
fn akk(a: int64, n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) { s := s + peek32(a + i * 4); i += 1; }
  return s;
}
fn main(): int64 {
  var p: int64 := alloc(64);
  var i: int64 := 0;
  while (i < 8) { poke32(p + i * 4, i + 1); i += 1; }
  PrintInt(akk(p, 8)); PrintStr("\n"c);
  return 0;
}
LYX
if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/akk.lyx" -o "$TMP/akk" --map-file >"$TMP/akk.log" 2>&1); then
  no "erzeugnis" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/akk.log")"
elif ! command -v objdump >/dev/null 2>&1; then
  echo "HINWEIS: objdump fehlt, Pruefung am Erzeugnis entfaellt"
else
  # Grenzen von akk aus der Karte. Das Erzeugnis hat keine Abschnittstabelle,
  # also rohes Disassemblieren mit -z (sonst kuerzt objdump Nullfolgen ab).
  # Spalte 1 ist die VIRTUELLE Adresse, Spalte 2 der Versatz IM .text — der
  # Datei-Versatz, den objdump -b binary braucht, ist Adresse minus Ladebasis
  # (statisches ELF, 0x400000). Spalte 2 waere 176 Byte daneben.
  VON=$(awk '$NF=="akk"{printf "%d", strtonum($1) - 4194304}' "$TMP/akk.map" | head -1)
  BIS=$(awk -v v="$VON" '$NF!="akk" && NF>=4 {o=strtonum($1) - 4194304; if (o>v) print o}' \
        "$TMP/akk.map" | sort -n | head -1)
  if [ -z "$VON" ] || [ -z "$BIS" ]; then
    no "erzeugnis" "akk nicht in der Karte gefunden"
  else
    DIS=$(objdump -D -z -b binary -m i386:x86-64 --no-show-raw-insn \
            --start-address="$VON" --stop-address="$BIS" "$TMP/akk" 2>/dev/null)
    NP=$(printf '%s\n' "$DIS" | grep -cE '^[[:space:]]*[0-9a-f]+:[[:space:]]+(push|pop)[[:space:]]')
    # Rahmen: push %rbp beim Eintritt, pop %rbp an jedem Ruecksprung. Lyx
    # erzeugt fuer `return` und das Rumpfende je einen Ausgang, also bis zu
    # drei Vorkommen. Je GLIED eines mehr waere der alte Zustand.
    if [ "$NP" -le 3 ]; then ok "erzeugnis: $NP push/pop in akk (nur Rahmen)"
    else no "erzeugnis" "$NP push/pop in akk — Sicherung je Glied noch da"; fi
  fi
fi

# ------------------------------------------------------------------
# B. Am Wert: kommutativ wird getauscht, der Rest NICHT.
# ------------------------------------------------------------------

# 1. Kommutative Operationen mit dem Local links, rechte Seite ein Aufruf
#    (peek* und eine eigene Funktion). Der Tausch zieht die rechte Seite vor
#    das Lesen des Locals; am Ergebnis darf sich nichts aendern.
fall kommutativ "36 40320 12 255 170 1 1" <<'LYX'
unit main;
import std.io;
fn geb(i: int64): int64 { return i + 1; }
fn main(): int64 {
  var p: int64 := alloc(64);
  var i: int64 := 0;
  while (i < 8) { poke32(p + i * 4, i + 1); i += 1; }
  var s: int64 := 0;  i := 0;
  while (i < 8) { s := s + peek32(p + i * 4); i += 1; }
  PrintInt(s); PrintStr("\n"c);                 // 1+..+8 = 36
  var m: int64 := 1;  i := 0;
  while (i < 8) { m := m * geb(i); i += 1; }
  PrintInt(m); PrintStr("\n"c);                 // 8! = 40320
  var a: int64 := 0x0F0F;
  PrintInt(a & geb(11)); PrintStr("\n"c);       // 0x0F0F & 12 = 12
  var b: int64 := 0x00F0;
  PrintInt(b | geb(14)); PrintStr("\n"c);       // 0xF0 | 15 = 0xFF = 255
  var c: int64 := 0x00FF;
  PrintInt(c ^ geb(84)); PrintStr("\n"c);       // 0xFF ^ 85 = 0xAA = 170
  var d: int64 := 7;
  if (d == geb(6)) { PrintInt(1); } else { PrintInt(0); }   // 7 == 7
  PrintStr("\n"c);
  if (d != geb(1)) { PrintInt(1); } else { PrintInt(0); }   // 7 != 2
  PrintStr("\n"c);
  return 0;
}
LYX

# 2. Gegenseite: NICHT kommutativ. Jeder Fall hat das Local links und einen
#    Aufruf rechts — ein Tausch wuerde hier sichtbar falsch rechnen bzw. den
#    Vergleich umkehren. Erwartungswerte von Hand gegengerechnet.
fall nicht_kommutativ "7 3 1 80 1 0 0 1 0 1" <<'LYX'
unit main;
import std.io;
fn geb(i: int64): int64 { return i + 1; }
fn main(): int64 {
  var a: int64 := 10;
  PrintInt(a - geb(2)); PrintStr("\n"c);      // 10 - 3 = 7   (getauscht: -7)
  PrintInt(a % geb(6)); PrintStr("\n"c);      // 10 % 7 = 3   (getauscht: 7)
  PrintInt(a / geb(6)); PrintStr("\n"c);      // 10 / 7 = 1   (getauscht: 0)
  PrintInt(a << geb(2)); PrintStr("\n"c);     // 10 << 3 = 80 (getauscht: 3<<10)
  PrintInt(a >> geb(2)); PrintStr("\n"c);     // 10 >> 3 = 1  (getauscht: 0)
  var b: int64 := 3;
  if (b > geb(4)) { PrintInt(1); } else { PrintInt(0); }   // 3 > 5  -> 0
  PrintStr("\n"c);
  if (b >= geb(4)) { PrintInt(1); } else { PrintInt(0); }  // 3 >= 5 -> 0
  PrintStr("\n"c);
  if (b < geb(4)) { PrintInt(1); } else { PrintInt(0); }   // 3 < 5  -> 1
  PrintStr("\n"c);
  var c: int64 := 5;
  if (c < geb(4)) { PrintInt(1); } else { PrintInt(0); }   // 5 < 5  -> 0
  PrintStr("\n"c);
  if (c <= geb(4)) { PrintInt(1); } else { PrintInt(0); }  // 5 <= 5 -> 1
  PrintStr("\n"c);
  return 0;
}
LYX

# 3. Reihenfolge: die rechte Seite darf das Local NICHT mehr lesen koennen,
#    nachdem sie es geaendert hat — genau das schliesst die Bedingung aus
#    (getauscht wird nur ein Local im Register, das keine Adresse hat).
#    Hier bekommt dasselbe Local eine Adresse (@a) und wird von der rechten
#    Seite ueber sie geschrieben: der Wert muss der VOR dem Aufruf sein,
#    denn Lyx wertet links-nach-rechts aus.
fall reihenfolge "11 1" <<'LYX'
unit main;
import std.io;
fn setz(p: int64): int64 { poke64(p, 100); return 1; }
fn main(): int64 {
  var a: int64 := 10;
  var pa: int64 := @a;
  var r: int64 := a + setz(pa);
  PrintInt(r); PrintStr("\n"c);   // 10 + 1 = 11, NICHT 100 + 1
  PrintInt(1); PrintStr("\n"c);
  return 0;
}
LYX

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
