#!/usr/bin/env bash
# tests/lyu_ressourcen_test.sh — #1971: Bibliotheken bringen ihre Ressourcen mit.
#
# Bis 1.2.16A trug nur das ERZEUGNIS Ressourcen. Eine .lyu hatte zwar einen
# Ressourcenabschnitt, aber beim Import las ihn niemand: auf x86 fehlte die
# Ressource still (ResLen = -1), auf den IR-Zielen wurde `@resource` gleich
# abgewiesen ("bisher nur mit --target=x86_64"), und fuer --target=lyxos gab
# es keine Tabelle.
#
# Gemessen wird der INHALT, byteweise, mit einer Datei, die ein NULLBYTE in der
# Mitte traegt (sonst misst der Test die Laengenbehaftung nicht):
#   * .lyu allein, .lyx allein, .lyx UND .lyu nebeneinander (die .lyx gewinnt,
#     die Ressource kommt aus der Quelle — gemessen mit einer VERALTETEN .lyu,
#     die andere Bytes traegt), auf x86_64, arm64 und riscv;
#   * Name einheitsqualifiziert (`demo.icons:logo`) und als Kurzname;
#   * eine .lyu, die selbst eine Quell-Unit mit Ressource importiert und in
#     ihrem Code ResLen ruft (std.res als Kopie in der .lyu);
#   * @embed in einer Funktion einer .lyu;
#   * lyxos: eigener Seitentyp im LBF, gelesen mit lbf_dump aus dem Repo
#     (Tabelle, CRC32C, Bytes), dazu die Wirkung einer Beschaedigung.
# Gegenseiten: gleicher Kurzname aus zwei Units wird mit BEIDEN Herkuenften
# gemeldet; eine nicht importierte Unit liefert nichts; eine .lyu ueber 64 MB
# wird laut abgewiesen (schreiben und lesen).
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
    x86_64) ( ulimit -v 4000000; timeout 60 "$2" ) 2>&1 ;;
    arm64)  ( ulimit -v 4000000; timeout 60 "$QEMU_ARM64" "$2" ) 2>&1 ;;
    riscv)  ( ulimit -v 4000000; timeout 60 "$QEMU_RISCV64" "$2" ) 2>&1 ;;
  esac
}
uebersetze() {  # log, args...
  local log="$1"; shift
  ( cd "$ROOT" && ulimit -v 8000000 && timeout 300 "$LYXC" "$@" ) >"$log" 2>&1
}

# --- Bibliothek mit Ressource -------------------------------------------------
mkdir -p "$TMP/q/demo" "$TMP/alt/demo"
printf 'AB\0CD-ENDE' > "$TMP/q/demo/logo.bin"
cat > "$TMP/q/demo/icons.lyx" <<'EOF'
unit demo.icons;
@resource("logo", "logo.bin");
pub con ICON_N: int64 := 1;
EOF
# Dieselbe Unit mit anderen Bytes — daraus die VERALTETE .lyu.
printf 'ALT!' > "$TMP/alt/demo/logo.bin"
cp "$TMP/q/demo/icons.lyx" "$TMP/alt/demo/icons.lyx"

cat > "$TMP/prog.lyx" <<'EOF'
import demo.icons;
import std.res;
import std.io;
fn main(): int64 {
  var p: pchar := ResFind("logo");
  var n: int64 := ResLen("demo.icons:logo");
  PrintStr(IntToStr(n)); PrintStr(" ");
  var i: int64 := 0;
  while (i < n) { PrintStr(IntToStr(StrCharAt(p, i) & 255)); PrintStr(","); i := i + 1; }
  PrintStr(" "); PrintStr(ResName(0)); PrintStr(" "); PrintLn(IntToStr(ICON_N));
  return 0;
}
EOF
SOLL="10 65,66,0,67,68,45,69,78,68,69, demo.icons:logo 1"

for ziel in x86_64 arm64 riscv; do
  d="$TMP/$ziel"; mkdir -p "$d/nur/demo" "$d/beide/demo"
  if ! uebersetze "$d/cu.log" --compile-unit --target=$ziel --std-path="$ROOT" "$TMP/q/demo/icons.lyx" -o "$d/nur/demo/icons.lyu"; then
    nok "$ziel: --compile-unit mit @resource scheitert: $(grep -v Copyright "$d/cu.log" | grep -m1 -i 'error\|lyxc:')"; continue
  fi
  # 1. NUR die .lyu im Suchpfad
  if uebersetze "$d/b1.log" --target=$ziel --std-path="$ROOT" -I "$d/nur" "$TMP/prog.lyx" -o "$d/p1"; then
    ist="$(lauf $ziel "$d/p1")"
    if [ "$ist" = "$SOLL" ]; then ok "$ziel: Ressource aus der .lyu allein, Bytes gleich (Nullbyte in der Mitte)"
    else nok "$ziel: .lyu allein: erwartet '$SOLL', bekommen '$ist'"; fi
  else nok "$ziel: .lyu allein uebersetzt nicht: $(grep -v Copyright "$d/b1.log" | grep -m1 -i 'error\|lyxc:')"; fi
  # 2. .lyx und eine VERALTETE .lyu nebeneinander: die .lyx gewinnt
  cp "$TMP/q/demo/icons.lyx" "$TMP/q/demo/logo.bin" "$d/beide/demo/"
  if uebersetze "$d/cua.log" --compile-unit --target=$ziel --std-path="$ROOT" "$TMP/alt/demo/icons.lyx" -o "$d/beide/demo/icons.lyu" \
     && uebersetze "$d/b2.log" --target=$ziel --std-path="$ROOT" -I "$d/beide" "$TMP/prog.lyx" -o "$d/p2"; then
    ist="$(lauf $ziel "$d/p2")"
    if [ "$ist" = "$SOLL" ]; then ok "$ziel: .lyx und .lyu nebeneinander — Ressource vorhanden, aus der Quelle"
    else nok "$ziel: .lyx+.lyu: erwartet '$SOLL', bekommen '$ist'"; fi
  else nok "$ziel: .lyx+.lyu uebersetzt nicht: $(grep -v Copyright "$d/b2.log" "$d/cua.log" | grep -m1 -i 'error\|lyxc:')"; fi
  # 3. nur die Quelle
  if uebersetze "$d/b3.log" --target=$ziel --std-path="$ROOT" -I "$TMP/q" "$TMP/prog.lyx" -o "$d/p3"; then
    ist="$(lauf $ziel "$d/p3")"
    if [ "$ist" = "$SOLL" ]; then ok "$ziel: Ressource aus der Quell-Unit (Pfad relativ zur Unit)"
    else nok "$ziel: Quelle: erwartet '$SOLL', bekommen '$ist'"; fi
  else nok "$ziel: Quelle uebersetzt nicht: $(grep -v Copyright "$d/b3.log" | grep -m1 -i 'error\|lyxc:')"; fi
done

# --unit-info listet die Ressource
if ( cd "$ROOT" && "$LYXC" --unit-info "$TMP/x86_64/nur/demo/icons.lyu" ) 2>&1 | grep -q "logo	10 Byte"; then
  ok "--unit-info nennt die Ressource mit Groesse"
else nok "--unit-info nennt die Ressource nicht"; fi

# --- eigene Ressource des Programms auf dem IR-Weg --------------------------
printf 'eins\0zwei' > "$TMP/eigen.bin"
cat > "$TMP/eigen.lyx" <<'EOF'
import std.res;
import std.io;
@resource("eigen", "eigen.bin");
fn main(): int64 {
  PrintStr(IntToStr(ResCount())); PrintStr(" "); PrintStr(ResName(0)); PrintStr(" ");
  PrintStr(IntToStr(ResLen("eigen"))); PrintStr(" ");
  PrintLn(IntToStr(StrCharAt(ResFind("eigen"), 5) & 255));
  return 0;
}
EOF
for ziel in arm64 riscv; do
  if uebersetze "$TMP/e_$ziel.log" --target=$ziel --std-path="$ROOT" "$TMP/eigen.lyx" -o "$TMP/e_$ziel"; then
    ist="$(lauf $ziel "$TMP/e_$ziel")"
    if [ "$ist" = "1 eigen 9 122" ]; then ok "$ziel: @resource im Programm selbst (ohne Unit-Vorsatz)"
    else nok "$ziel: eigene Ressource: erwartet '1 eigen 9 122', bekommen '$ist'"; fi
  else nok "$ziel: @resource im Programm abgewiesen: $(grep -v Copyright "$TMP/e_$ziel.log" | grep -m1 -i 'error\|lyxc:')"; fi
done

# --- .lyu, die selbst eine Quell-Unit mit Ressource importiert ---------------
mkdir -p "$TMP/u/demo" "$TMP/unur/demo"
cat > "$TMP/u/demo/nutzer.lyx" <<'EOF'
unit demo.nutzer;
import demo.icons;
import std.res;
pub fn LogoLaenge(): int64 { return ResLen("logo"); }
pub fn LogoByte(i: int64): int64 { return StrCharAt(ResFind("demo.icons:logo"), i) & 255; }
pub fn Bild(): pchar { return @embed("bild.txt"); }
pub fn BildLen(): int64 { return @embed_len("bild.txt"); }
EOF
printf 'BILD\0DATEN' > "$TMP/u/demo/bild.txt"
cat > "$TMP/nutzer.lyx" <<'EOF'
import demo.nutzer;
import std.io;
fn main(): int64 {
  PrintStr(IntToStr(LogoLaenge())); PrintStr(" "); PrintStr(IntToStr(LogoByte(3))); PrintStr(" ");
  PrintStr(IntToStr(BildLen())); PrintStr(" "); PrintLn(IntToStr(StrCharAt(Bild(), 6) & 255));
  return 0;
}
EOF
for ziel in arm64 riscv; do
  if uebersetze "$TMP/n_$ziel.log" --compile-unit --target=$ziel --std-path="$ROOT" -I "$TMP/q" "$TMP/u/demo/nutzer.lyx" -o "$TMP/unur/demo/nutzer.lyu" \
     && uebersetze "$TMP/nb_$ziel.log" --target=$ziel --std-path="$ROOT" -I "$TMP/unur" "$TMP/nutzer.lyx" -o "$TMP/np_$ziel"; then
    ist="$(lauf $ziel "$TMP/np_$ziel")"
    if [ "$ist" = "10 67 10 65" ]; then ok "$ziel: .lyu bringt Ressource ihres Quell-Imports und @embed mit, std.res darin findet sie"
    else nok "$ziel: .lyu mit Quell-Import: erwartet '10 67 10 65', bekommen '$ist'"; fi
  else nok "$ziel: .lyu mit Quell-Import uebersetzt nicht: $(grep -hv Copyright "$TMP/n_$ziel.log" "$TMP/nb_$ziel.log" 2>/dev/null | grep -m1 -i 'error\|lyxc:')"; fi
done

# --- Gegenseite: gleicher Kurzname aus zwei Units -----------------------------
mkdir -p "$TMP/q/zwei"
printf 'XY' > "$TMP/q/zwei/logo.bin"
printf 'unit zwei.icons;\n@resource("logo", "logo.bin");\npub con Z_N: int64 := 2;\n' > "$TMP/q/zwei/icons.lyx"
printf 'import demo.icons;\nimport zwei.icons;\nimport std.res;\nfn main(): int64 { return ResLen("zwei.icons:logo"); }\n' > "$TMP/koll.lyx"
for ziel in x86_64 arm64; do
  if uebersetze "$TMP/k_$ziel.log" --target=$ziel --std-path="$ROOT" -I "$TMP/q" "$TMP/koll.lyx" -o "$TMP/k_$ziel"; then
    nok "$ziel: zwei Units mit Kurzname 'logo' uebersetzen klaglos"
  elif grep -q "Kurzname 'logo'" "$TMP/k_$ziel.log" && grep -q "demo.icons" "$TMP/k_$ziel.log" && grep -q "zwei.icons" "$TMP/k_$ziel.log"; then
    ok "$ziel: gleicher Kurzname aus zwei Units — laut, mit beiden Herkuenften"
  else nok "$ziel: Kollision ohne beide Herkuenfte: $(grep -v Copyright "$TMP/k_$ziel.log" | head -2)"; fi
done
# Ohne die zweite Unit uebersetzt dasselbe Programm (die Meldung haengt an der
# Kollision, nicht am Namen).
printf 'import zwei.icons;\nimport std.res;\nimport std.io;\nfn main(): int64 { PrintLn(IntToStr(ResLen("logo"))); return 0; }\n' > "$TMP/einzeln.lyx"
if uebersetze "$TMP/ez.log" --target=arm64 --std-path="$ROOT" -I "$TMP/q" "$TMP/einzeln.lyx" -o "$TMP/ez" && [ "$(lauf arm64 "$TMP/ez")" = "2" ]; then
  ok "arm64: derselbe Kurzname aus nur EINER Unit ist erlaubt"
else nok "arm64: Kurzname aus einer Unit: $(grep -v Copyright "$TMP/ez.log" | head -1)"; fi

# --- Gegenseite: nicht importierte Unit --------------------------------------
cat > "$TMP/ohne.lyx" <<'EOF'
import std.res;
import std.io;
fn main(): int64 {
  PrintStr(IntToStr(ResLen("logo"))); PrintStr(" ");
  if (ResFind("demo.icons:logo") == 0 as pchar) { PrintLn("null"); } else { PrintLn("da"); }
  return 0;
}
EOF
for ziel in x86_64 arm64; do
  if uebersetze "$TMP/o_$ziel.log" --target=$ziel --std-path="$ROOT" -I "$TMP/q" "$TMP/ohne.lyx" -o "$TMP/o_$ziel"; then
    ist="$(lauf $ziel "$TMP/o_$ziel")"
    if [ "$ist" = "-1 null" ]; then ok "$ziel: Ressource einer nicht importierten Unit ist nicht sichtbar"
    else nok "$ziel: nicht importiert: erwartet '-1 null', bekommen '$ist'"; fi
  else nok "$ziel: Programm ohne Import uebersetzt nicht"; fi
done

# --- lyxos: Ressourcenseiten im LBF ------------------------------------------
mkdir -p "$TMP/lxnur/demo"
if uebersetze "$TMP/lxc.log" --compile-unit --target=lyxos --std-path="$ROOT" "$TMP/q/demo/icons.lyx" -o "$TMP/lxnur/demo/icons.lyu" \
   && uebersetze "$TMP/lx.log" --target=lyxos --std-path="$ROOT" -I "$TMP/lxnur" "$TMP/prog.lyx" -o "$TMP/p.lbf" \
   && uebersetze "$TMP/ld.log" --std-path="$ROOT" src/tools/lbf_dump.lyx -o "$TMP/lbf_dump"; then
  "$TMP/lbf_dump" "$TMP/p.lbf" > "$TMP/dump.txt" 2>&1
  if grep -q "demo.icons:logo  10 bytes  CRC32C 0x[0-9a-f]* (OK)" "$TMP/dump.txt" && grep -q "\.res " "$TMP/dump.txt"; then
    ok "lyxos: lbf_dump listet die Ressourcentabelle (eigener Seitentyp, CRC32C geprueft)"
  else nok "lyxos: lbf_dump zeigt keine Ressource: $(grep -A3 Resources "$TMP/dump.txt" | head -3)"; fi
  if "$TMP/lbf_dump" --res demo.icons:logo "$TMP/p.lbf" > "$TMP/aus.bin" && cmp -s "$TMP/aus.bin" "$TMP/q/demo/logo.bin"; then
    ok "lyxos: Bytes der Ressource aus dem LBF gleich der Datei"
  else nok "lyxos: Bytes aus dem LBF weichen ab"; fi
  if [ "$("$TMP/lbf_dump" --verify-only "$TMP/p.lbf")" = "OK" ]; then ok "lyxos: LBF mit Ressourcenseiten besteht --verify-only"
  else nok "lyxos: LBF mit Ressourcenseiten ist laut --verify-only kaputt"; fi
  # Die Bytes stehen zusaetzlich im Abbild (std.res zur Laufzeit).
  if grep -c "$(printf 'CD-ENDE')" "$TMP/p.lbf" >/dev/null; then ok "lyxos: Bytes auch im Programmabbild (std.res)"; else nok "lyxos: Bytes fehlen im Abbild"; fi
  # Gegenseite: ein Byte im Ressourcenstrom kippen -> CRC meldet es.
  off=$(grep -obUaP "CD-ENDE" "$TMP/p.lbf" | tail -1 | cut -d: -f1)
  cp "$TMP/p.lbf" "$TMP/kaputt.lbf"
  printf 'X' | dd of="$TMP/kaputt.lbf" bs=1 seek="$off" conv=notrunc 2>/dev/null
  "$TMP/lbf_dump" --res demo.icons:logo "$TMP/kaputt.lbf" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ] && [ "$("$TMP/lbf_dump" --verify-only "$TMP/kaputt.lbf")" = "CORRUPT" ]; then
    ok "lyxos: beschaedigte Ressource wird gemeldet (rc 2, CORRUPT)"
  else nok "lyxos: beschaedigte Ressource bleibt unbemerkt (rc $rc)"; fi
else nok "lyxos/lbf_dump uebersetzt nicht: $(grep -hv Copyright "$TMP/lxc.log" "$TMP/lx.log" "$TMP/ld.log" 2>/dev/null | grep -m1 -i 'error\|lyxc:')"; fi

# --- Gegenseite: Groessenschranke 64 MB ---------------------------------------
mkdir -p "$TMP/gross/demo"
truncate -s 67108865 "$TMP/gross/demo/riesig.bin"
printf 'unit demo.gross;\n@resource("riesig", "riesig.bin");\npub con G: int64 := 1;\n' > "$TMP/gross/demo/gross.lyx"
if uebersetze "$TMP/g.log" --compile-unit --std-path="$ROOT" "$TMP/gross/demo/gross.lyx" -o "$TMP/gross.lyu"; then
  nok "eine Ressource ueber 64 MB landet in einer .lyu"
elif grep -q "64 MB" "$TMP/g.log"; then ok "Ressource ueber 64 MB: --compile-unit weist laut ab"
else nok "Ressource ueber 64 MB: falsche Meldung: $(grep -v Copyright "$TMP/g.log" | head -1)"; fi
mkdir -p "$TMP/glyu/demo"
cp "$TMP/x86_64/nur/demo/icons.lyu" "$TMP/glyu/demo/icons.lyu"
truncate -s 67108865 "$TMP/glyu/demo/icons.lyu"
if uebersetze "$TMP/gl.log" --std-path="$ROOT" -I "$TMP/glyu" "$TMP/prog.lyx" -o "$TMP/gl"; then
  nok "eine .lyu ueber 64 MB wird gelesen"
elif grep -q "groesser als 64 MB" "$TMP/gl.log"; then ok ".lyu ueber 64 MB: der Leser weist laut ab"
else nok ".lyu ueber 64 MB: falsche Meldung: $(grep -v Copyright "$TMP/gl.log" | head -1)"; fi

echo "lyu_ressourcen: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
