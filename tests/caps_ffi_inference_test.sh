#!/usr/bin/env bash
# tests/caps_ffi_inference_test.sh — #1173 und #1174.
#
# #1173: `@capabilities([fs.read(path: "/tmp")])` wirkte als Ja/Nein. Es entstand
# EINE Landlock-Regel fuer "/", der genannte Pfad ging nicht in die Rechnung ein
# — ein Zugriff ausserhalb gelang also trotzdem. Gemessen wird deshalb die
# VERWEIGERUNG zur Laufzeit, nicht die Uebersetzbarkeit.
#
# #1174: `var a := Mk();` verlor den Klassen- bzw. struct-Typ. Feldzugriff ergab
# still 0, Methodenaufrufe wurden abgewiesen, die Operator-Ueberladung entfiel.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

lyxc_run() { ( ulimit -v $(( 4 * 1024 * 1024 )); timeout 60 "$LYXC" "$@" ); }
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! lyxc_run --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$(lyxc_run --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then ok "$1 (abgewiesen)"
  else no "$1" "nicht abgewiesen — '$(echo "$got" | tail -1)'"; fi
}

KOPF='import src.std.io;'

# ===========================================================================
# #1174 — Typinferenz aus der Funktionsrueckgabe
# ===========================================================================

out "Feldzugriff nach inferierter Klassenrueckgabe" "$KOPF
type V = class { x: int64; };
fn Mk(v: int64): V { var t: V := new V(); t.x := v; return t; }
fn main(): int64 {
    var mit: V := Mk(10);
    PrintLn(IntToStr(mit.x));
    var ohne := Mk(10);
    PrintLn(IntToStr(ohne.x));
    return 0;
}" "10
10"

out "Methodenaufruf auf inferierter Klasse" "$KOPF
type V = class { x: int64; fn Get(): int64 { return self.x; } };
fn Mk(v: int64): V { var t: V := new V(); t.x := v; return t; }
fn main(): int64 { var a := Mk(7); PrintLn(IntToStr(a.Get())); return 0; }" "7"

out "Operator-Ueberladung auf inferierter Klasse" "$KOPF
type V = class {
    x: int64;
    fn Add(o: V): V { var r: V := new V(); r.x := self.x + o.x; return r; }
};
fn Mk(v: int64): V { var t: V := new V(); t.x := v; return t; }
fn main(): int64 {
    var a := Mk(10);
    var b := Mk(2);
    var c := a + b;
    PrintLn(IntToStr(c.x));
    return 0;
}" "12"

out "struct-Rueckgabe behaelt den Typ" "$KOPF
type S = struct { a: int64; };
fn MkS(): S { var s: S; s.a := 7; return s; }
fn main(): int64 { var s := MkS(); PrintLn(IntToStr(s.a)); return 0; }" "7"

# Gegenproben: die Faelle, die schon vorher stimmten, bleiben unveraendert.
out "primitive Rueckgabe unveraendert" "$KOPF
fn F(): int64 { return 42; }
fn G(): pchar { return \"hallo\"c; }
fn main(): int64 { var n := F(); PrintLn(IntToStr(n)); var s := G(); PrintLn(s); return 0; }" "42
hallo"

out "new V() traegt den Typ weiterhin" "$KOPF
type V = class { x: int64; fn Get(): int64 { return self.x; } };
fn main(): int64 { var a := new V(); a.x := 5; PrintLn(IntToStr(a.Get())); return 0; }" "5"

# ===========================================================================
# #1173 — Landlock-Regel je Pfad
# ===========================================================================
# Gemessen wird die VERWEIGERUNG zur Laufzeit. Landlock gibt es erst ab Kernel
# 5.13; fehlt es, ueberspringt der erzeugte Code die Absicherung vollstaendig
# und der Test koennte nichts belegen — deshalb die Vorpruefung.

if ! grep -q landlock /sys/kernel/security/lsm 2>/dev/null; then
  echo "SKIP #1173: Kernel ohne Landlock (/sys/kernel/security/lsm) — Verweigerung nicht messbar"
else
  echo "hallo" > /tmp/lyx_caps_test_datei.txt
  printf '%s\n' '@capabilities([fs.read(path: "/tmp"), system.exit, system.memory.heap])
import src.std.fs;
import src.std.io;
fn main(): int64 {
    var f: int64 := FileOpen("/tmp/lyx_caps_test_datei.txt"c, 0);
    if (f >= 0) { PrintLn("innen offen"); } else { PrintLn("innen verweigert"); }
    var g: int64 := FileOpen("/etc/hostname"c, 0);
    if (g >= 0) { PrintLn("aussen offen"); } else { PrintLn("aussen verweigert"); }
    return 0;
}' > "$TMP/ll.lyx"
  if lyxc_run --std-path="$ROOT" "$TMP/ll.lyx" -o "$TMP/ll" >/dev/null 2>&1; then
    got="$("$TMP/ll" 2>&1)"
    if [ "$got" = "innen offen
aussen verweigert" ]; then ok "fs.read(path:) beschraenkt auf den genannten Pfad"
    else no "fs.read(path:)" "'$got'"; fi
  else
    no "fs.read(path:)" "uebersetzt nicht"
  fi

  # Gegenprobe: OHNE path bleibt es bei der breiten Regel. Ohne diese Probe
  # waere eine Sandbox, die pauschal alles verbietet, ebenso gruen.
  printf '%s\n' '@capabilities([fs.read, system.exit, system.memory.heap])
import src.std.fs;
import src.std.io;
fn main(): int64 {
    var g: int64 := FileOpen("/etc/hostname"c, 0);
    if (g >= 0) { PrintLn("aussen offen"); } else { PrintLn("aussen verweigert"); }
    return 0;
}' > "$TMP/ll2.lyx"
  if lyxc_run --std-path="$ROOT" "$TMP/ll2.lyx" -o "$TMP/ll2" >/dev/null 2>&1; then
    got2="$("$TMP/ll2" 2>&1)"
    if [ "$got2" = "aussen offen" ]; then ok "fs.read ohne path bleibt unveraendert breit"
    else no "fs.read ohne path" "'$got2'"; fi
  else
    no "fs.read ohne path" "uebersetzt nicht"
  fi
  rm -f /tmp/lyx_caps_test_datei.txt
fi

# Die Warnung aus #1108 gilt fuer `path:` nicht mehr — sie waere jetzt selbst
# falsch. Fuer eine Capability, die weiterhin nicht durchgesetzt wird
# (fs.perm), muss sie stehen bleiben.
printf '%s\n' '@capabilities([fs.read(path: "/tmp"), system.exit, system.memory.heap])
import src.std.io;
fn main(): int64 { return 0; }' > "$TMP/w1.lyx"
if lyxc_run --std-path="$ROOT" "$TMP/w1.lyx" -o "$TMP/w1" 2>&1 | grep -q "NICHT durchgesetzt"; then
  no "keine Warnung mehr fuer fs.read(path:)" "Warnung steht noch"
else
  ok "keine Warnung mehr fuer fs.read(path:)"
fi

printf '%s\n' '@capabilities([fs.perm(path: "/tmp"), system.exit, system.memory.heap])
import src.std.io;
fn main(): int64 { return 0; }' > "$TMP/w2.lyx"
if lyxc_run --std-path="$ROOT" "$TMP/w2.lyx" -o "$TMP/w2" 2>&1 | grep -q "NICHT durchgesetzt"; then
  ok "Warnung bleibt fuer fs.perm(path:) — dort wirkt sie weiterhin nicht"
else
  no "Warnung fuer fs.perm(path:)" "fehlt jetzt ebenfalls"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
