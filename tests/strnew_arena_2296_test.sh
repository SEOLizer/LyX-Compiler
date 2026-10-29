#!/usr/bin/env bash
# tests/strnew_arena_2296_test.sh — #2296: StrNew, StrSub und das Feld von
# StrSplit belegen aus der Bump-Arena, nicht mehr je Aufruf ein eigenes mmap.
#
# Bis 1.2.24E war `StrNew(n)` ein rohes `mmap(0, n, ...)`. Eine Anforderung
# von 32 Byte belegte damit eine ganze SEITE, und `StrFree` ist ein No-op —
# der Speicher kam nie zurueck. Gemessen an 20000 Aufrufen mit beschriebenem
# Puffer: 77 MB, also 4 KiB je Aufruf. Fuer ein kurzes Programm
# verschmerzbar, fuer einen Dauerlaeufer ein Verlust von ein bis zwei
# Megabyte JE ANFRAGE.
#
# Jetzt dieselbe Arena wie `new`, die Verkettung (1.2.3F) und IntToStr
# (#2225): 2,5 MB fuer dieselben 20000 Aufrufe. `StrFree` bleibt ein No-op —
# bei einer Arena IST das die richtige Umsetzung (src/std/alloc.lyx).
#
# ZWEI MESSFALLEN, beide hier eingebaut:
#
#   1. Der Verlust zeigt sich NUR, wenn der Puffer auch BESCHRIEBEN wird.
#      Ein Lauf, der bloss belegt und freigibt, meldete 392 KiB statt 77 MB:
#      RSS zaehlt beruehrte Seiten, und Linux fuehrt aufeinanderfolgende
#      anonyme Mappings mit gleichen Flags zu EINER Abbildung zusammen. Der
#      Verlust ist echt, aber ein naiver Messlauf sieht ihn nicht.
#   2. Eine Arena gibt WIEDERVERWENDETEN Speicher, `mmap` gibt Nullseiten.
#      Ohne Nullen waere der Umbau eine stille Semantikaenderung fuer jeden,
#      der den frischen Puffer schon als leere Zeichenkette liest. Geprueft
#      wird deshalb ausdruecklich, dass er genullt ankommt — und zwar
#      NACHDEM vorige Puffer vollgeschrieben wurden, sonst sind die Nullen
#      nur die des frischen Blocks.
#
# Die Speichergrenze wird nur auf x86 geprueft: dort sitzt die Aenderung.
# Auf dem IR-Weg wird `StrNew` zu IRO_ALLOC, also dem allgemeinen
# Allokator — das ist eine eigene Frage (im Issue benannt) und wird hier
# WEDER geprueft noch als Luecke zugesichert. Die WERTE dagegen muessen
# ueberall stimmen.

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

fall() { # name erwartet [ziele]   (Quelle auf stdin)
  local name="$1" erw="$2" ziele="${3:-$ZIELE}"
  cat > "$TMP/$name.lyx"
  local z
  for z in $ziele; do
    local opt="" q=""
    [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
    [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/$name.lyx" -o "$TMP/$name.$z" >"$TMP/$name.$z.log" 2>&1); then
      no "$name $z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$name.$z.log")"; continue
    fi
    local got
    got=$( cd "$TMP" && timeout 120 $q "$TMP/$name.$z" 2>&1 | tr '\n' ' ' ); got="${got% }"
    if [ "$got" = "$erw" ]; then ok "$name $z: $got"; else no "$name $z" "'$got' erwartet '$erw'"; fi
  done
}

# ------------------------------------------------------------------
# A. Die WIRKUNG: der Speicher bleibt flach.
#
# 20000 Aufrufe je 32 Byte sind rund 640 KB Nutzdaten. Mit dem alten Weg
# waren es 77 MB. Die Grenze liegt bei 16 MB — weit ueber dem neuen Wert
# (2,5 MB gemessen) und weit unter dem alten, also in beide Richtungen
# tragfaehig und nicht von der Maschine abhaengig.
#
# Der Puffer wird BESCHRIEBEN, sonst sieht der Lauf den Verlust nicht
# (Messfalle 1 oben).
# ------------------------------------------------------------------
cat > "$TMP/viele.lyx" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var i: int64 := 0; var n: int64 := 0;
  while (i < 20000) {
    var s: pchar := StrNew(32);
    StrSetChar(s, 0, 65); StrSetChar(s, 1, 0);
    n := n + StrLen(s);
    StrFree(s);
    i := i + 1;
  }
  PrintInt(n); PrintStr("\n"c);
  return 0;
}
LYX
if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/viele.lyx" -o "$TMP/viele" >"$TMP/viele.log" 2>&1); then
  no "speicher" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/viele.log")"
else
  # RSS-Spitze aus `rusage` nach dem Lauf (/usr/bin/time, %M in KiB).
  # NICHT durch Abtasten von /proc/<pid>/status: mit der Arena laeuft das
  # Programm nur wenige Millisekunden, und die Abtastung verpasst es — der
  # erste Entwurf dieses Tests meldete deshalb "Lauf zu kurz" und pruefte
  # gar nichts. rusage haelt die Spitze unabhaengig von der Laufzeit.
  SPITZE=0
  if [ -x /usr/bin/time ]; then
    SPITZE=$(/usr/bin/time -f '%M' -o "$TMP/viele.rss" "$TMP/viele" > "$TMP/viele.out" 2>"$TMP/viele.err"; cat "$TMP/viele.rss" 2>/dev/null)
    [ -z "$SPITZE" ] && SPITZE=0
  else
    echo "HINWEIS: /usr/bin/time fehlt — Speichergrenze entfaellt"
    "$TMP/viele" > "$TMP/viele.out" 2>&1
  fi
  AUS=$(head -1 "$TMP/viele.out")
  if [ "$AUS" != "20000" ]; then
    no "speicher" "Programm rechnet falsch: '$AUS' erwartet '20000'"
  elif [ "$SPITZE" -eq 0 ]; then
    echo "HINWEIS: RSS nicht abgetastet (Lauf zu kurz) — Speichergrenze entfaellt"
  elif [ "$SPITZE" -lt 16384 ]; then
    ok "speicher: RSS-Spitze ${SPITZE} KiB bei 20000 Aufrufen (Grenze 16384)"
  else
    no "speicher" "RSS-Spitze ${SPITZE} KiB bei 20000 Aufrufen — ueber der Grenze von 16384, der Verlust ist zurueck"
  fi
fi

# ------------------------------------------------------------------
# B. Der Puffer kommt GENULLT (Messfalle 2). Erst 200 Puffer voll
#    beschreiben, dann neue holen und pruefen — frische Nullen eines
#    unbenutzten Blocks wuerden hier nichts belegen.
# ------------------------------------------------------------------
fall genullt "nicht-genullt: 0" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var i: int64 := 0;
  while (i < 200) {
    var v: pchar := StrNew(64);
    var k: int64 := 0;
    while (k < 64) { StrSetChar(v, k, 88); k := k + 1; }
    i := i + 1;
  }
  var nz: int64 := 0;
  i := 0;
  while (i < 200) {
    var s: pchar := StrNew(64);
    if (StrLen(s) != 0) { nz := nz + 1; }
    var j: int64 := 0;
    while (j < 64) { StrSetChar(s, j, 88); j := j + 1; }
    i := i + 1;
  }
  PrintStr("nicht-genullt: "c); PrintInt(nz); PrintStr("\n"c);
  return 0;
}
LYX

# ------------------------------------------------------------------
# C. Zwei Puffer sind VERSCHIEDEN. Bei mmap war das selbstverstaendlich;
#    eine Arena, die zweimal dieselbe Stelle liefert, waere ein stiller
#    Datenverlust — und ohne diese Probe unsichtbar, weil jeder einzelne
#    Puffer fuer sich richtig aussieht.
# ------------------------------------------------------------------
fall verschieden "AB CD 1" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: pchar := StrNew(16);
  var b: pchar := StrNew(16);
  StrSetChar(a, 0, 65); StrSetChar(a, 1, 66); StrSetChar(a, 2, 0);
  StrSetChar(b, 0, 67); StrSetChar(b, 1, 68); StrSetChar(b, 2, 0);
  PrintStr(a); PrintStr(" "c); PrintStr(b); PrintStr(" "c);
  var ungleich: int64 := 0;
  if ((a as int64) != (b as int64)) { ungleich := 1; }
  PrintInt(ungleich); PrintStr("\n"c);
  return 0;
}
LYX

# ------------------------------------------------------------------
# D. Groesser als ein Arena-Block (64 KiB). Die Belegung muss sich dann
#    einen eigenen, grossen Block holen; beschrieben werden beide Enden,
#    damit ein zu kleiner Block auffaellt statt still zu ueberschreiben.
# ------------------------------------------------------------------
fall gross "90 91 199999" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var n: int64 := 200000;
  var s: pchar := StrNew(n);
  StrSetChar(s, 0, 90);
  StrSetChar(s, n - 1, 91);
  PrintInt(StrCharAt(s, 0)); PrintStr(" "c);
  PrintInt(StrCharAt(s, n - 1)); PrintStr(" "c);
  PrintInt(n - 1); PrintStr("\n"c);
  return 0;
}
LYX

# ------------------------------------------------------------------
# E. Gegenprobe: IntToStr bleibt unberuehrt. Es liegt seit #2225 auf
#    derselben Arena; wer StrNew umbaut, darf es nicht mitreissen.
# ------------------------------------------------------------------
fall inttostr_unberuehrt "88890" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var i: int64 := 0; var n: int64 := 0;
  while (i < 20000) { var s: pchar := IntToStr(i); n := n + StrLen(s); i := i + 1; }
  PrintInt(n); PrintStr("\n"c);
  return 0;
}
LYX

# ------------------------------------------------------------------
# F. Dieselbe Wirkung fuer StrSub und fuer das Feld von StrSplit.
#
# StrSub belegte im Helfer `_lyx_strsub` je Aufruf eine Seite (gemessen
# 80000 KiB fuer 20000 Aufrufe). StrSplit ruft diesen Helfer JE FELD auf
# und holte sein Feld-Array zusaetzlich per eigenem mmap — nach dem Umbau
# von StrSub allein blieb es deshalb bei 8,4 MB. Beide Stellen liegen
# jetzt auf der Arena.
#
# Grenzen wie oben weit gefasst: gemessen 640 KiB bzw. 896 KiB, vorher
# 80000 bzw. 71936 KiB.
# ------------------------------------------------------------------
speichergrenze() { # name, grenze-in-KiB, erwartete-ausgabe   (Quelle auf stdin)
  local name="$1" grenze="$2" erw="$3"
  cat > "$TMP/$name.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/$name.lyx" -o "$TMP/$name" >"$TMP/$name.log" 2>&1); then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$name.log")"; return
  fi
  if [ ! -x /usr/bin/time ]; then
    echo "HINWEIS: /usr/bin/time fehlt — $name entfaellt"; return
  fi
  local sp aus
  sp=$(/usr/bin/time -f '%M' -o "$TMP/$name.rss" "$TMP/$name" > "$TMP/$name.out" 2>"$TMP/$name.err"; cat "$TMP/$name.rss" 2>/dev/null)
  [ -z "$sp" ] && sp=0
  aus=$(head -1 "$TMP/$name.out")
  if [ "$aus" != "$erw" ]; then
    no "$name" "rechnet falsch: '$aus' erwartet '$erw'"
  elif [ "$sp" -lt "$grenze" ]; then
    ok "$name: RSS-Spitze ${sp} KiB (Grenze ${grenze})"
  else
    no "$name" "RSS-Spitze ${sp} KiB — ueber der Grenze von ${grenze}, der Verlust ist zurueck"
  fi
}

speichergrenze strsub_speicher 16384 200000 <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var q: pchar := "abcdefghijklmnopqrstuvwxyz"c;
  var i: int64 := 0; var n: int64 := 0;
  while (i < 20000) { var s: pchar := StrSub(q, 0, 10); n := n + StrLen(s); i := i + 1; }
  PrintInt(n); PrintStr("\n"c);
  return 0;
}
LYX

speichergrenze strsplit_speicher 16384 16000 <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var q: pchar := "a,bb,ccc,dddd,e,ff,ggg,h"c;
  var i: int64 := 0; var n: int64 := 0;
  while (i < 2000) { var t: pchar[] = StrSplit(q, ","c); n := n + len(t); i := i + 1; }
  PrintInt(n); PrintStr("\n"c);
  return 0;
}
LYX

# Die WERTE von StrSub und StrSplit auf allen Zielen — der Umbau fasst den
# Helfer an, der die Teilkette kopiert und nullterminiert.
fall strsub_werte "cde abcdefgh h" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var q: pchar := "abcdefgh"c;
  PrintStr(StrSub(q, 2, 3)); PrintStr(" "c);
  PrintStr(StrSub(q, 0, 8)); PrintStr(" "c);
  PrintStr(StrSub(q, 7, 1)); PrintStr("\n"c);
  return 0;
}
LYX

# Das Feld von StrSplit wird nur bis `count` gefuellt; Kopf und Rest las der
# Bestand als NULLEN, weil mmap Nullseiten lieferte. Die Arena gibt
# wiederverwendeten Speicher — deshalb wird dort genullt, und deshalb steht
# hier eine Probe darauf. Zweimal hintereinander, damit der zweite Aufruf
# BENUTZTEN Speicher bekommt; ein fehlendes Nullen faellt erst dort auf.
#
# NUR x86: `StrSplit` liefert auf arm64 und riscv eine LEERE Liste (len 0),
# und zwar unveraendert auch mit dem Vorgaengerstand — ein eigener,
# vorbestehender Defekt, als #2305 gefuehrt. Hier wird er WEDER geprueft
# NOCH zugesichert: sonst wuerde dieser Test rot, sobald er behoben ist.
fall strsplit_werte "3=a|bb|ccc 3=a|bb|ccc" "x86" <<'LYX'
unit main;
import std.io;
fn zeig(q: pchar) {
  var t: pchar[] = StrSplit(q, ","c);
  PrintInt(len(t)); PrintStr("="c);
  var i: int64 := 0;
  while (i < len(t)) {
    if (i > 0) { PrintStr("|"c); }
    PrintStr(t[i]);
    i := i + 1;
  }
}
fn main(): int64 {
  zeig("a,bb,ccc"c); PrintStr(" "c);
  zeig("a,bb,ccc"c);
  PrintStr("\n"c);
  return 0;
}
LYX

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
