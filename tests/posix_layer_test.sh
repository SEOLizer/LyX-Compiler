#!/usr/bin/env bash
# tests/posix_layer_test.sh — #1246.
#
# 21 Namen standen in den Funktionstabellen der Unit-Doku und existierten
# nicht. Entscheidung des Projekts: umsetzen, nicht streichen — die
# POSIX-Ebene ist keine Erfindung, sie fehlte als Schicht. Die Systemaufrufe
# stellt der Compiler längst als Builtins bereit.
#
# Geprüft wird die WIRKUNG, nicht die Auflösbarkeit: ein Wrapper, der nur
# existiert und 0 zurückgibt, wäre bei einem reinen "übersetzt"-Test grün —
# und genau das war der Zustand vorher bei `extern fn fork(): int64;` ohne
# link-Klausel (#1179): der Aufruf band nichts und lieferte still 0.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 60 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Alle 21 Namen sind auflösbar — die Grundlage, mehr nicht
# ===========================================================================

alle="pthread_cond_init pthread_cond_destroy pthread_cond_signal pthread_cond_wait
pthread_exit pthread_getspecific pthread_key_create pthread_key_delete
pthread_mutex_destroy pthread_mutex_init pthread_mutex_lock pthread_mutex_unlock
pthread_setspecific _exit fork execve execvp waitpid kill
PdfAddPageSized SvgNewViewBox"
fehlt=""
for s in $alle; do
  printf 'import std.thread;\nimport std.process;\nimport std.pdf;\nimport std.svg;\nfn main(): int64 { var x: int64 := %s as int64; return 0; }\n' "$s" > "$TMP/s.lyx"
  "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" >/dev/null 2>&1 || fehlt="$fehlt $s"
done
if [ -z "$fehlt" ]; then ok "alle 21 dokumentierten Namen sind vorhanden"
else no "alle 21 dokumentierten Namen sind vorhanden" "fehlen:$fehlt"; fi

# ===========================================================================
# Mutex: die Zustandsuebergaenge, nicht nur der Rueckgabewert
# ===========================================================================

# EBUSY beim Zerstoeren eines GEHALTENEN Mutex ist der Beleg, dass der Zustand
# wirklich im Speicher steht — ein Wrapper, der immer 0 liefert, faellt hier auf.
out "pthread_mutex: init, lock, EBUSY, unlock, destroy" 'import std.io;
import std.thread;
fn main(): int64 {
  var m: int64 := alloc(8);
  PrintStr(IntToStr(pthread_mutex_init(m, 0))); PrintStr(" ");
  PrintStr(IntToStr(pthread_mutex_lock(m))); PrintStr(" ");
  PrintStr(IntToStr(pthread_mutex_destroy(m))); PrintStr(" ");
  PrintStr(IntToStr(pthread_mutex_unlock(m))); PrintStr(" ");
  PrintLn(IntToStr(pthread_mutex_destroy(m)));
  return 0;
}' "0 0 16 0 0"

out "pthread_mutex_trylock scheitert am gehaltenen Mutex" 'import std.io;
import std.thread;
fn main(): int64 {
  var m: int64 := alloc(8);
  pthread_mutex_init(m, 0);
  PrintStr(IntToStr(pthread_mutex_trylock(m))); PrintStr(" ");
  PrintLn(IntToStr(pthread_mutex_trylock(m)));
  return 0;
}' "0 16"

# Nullzeiger und nicht umgesetzte Attribute werden GEMELDET, nicht geschluckt.
out "Nullzeiger und Attribute werden abgewiesen" 'import std.io;
import std.thread;
fn main(): int64 {
  var m: int64 := alloc(8);
  PrintStr(IntToStr(pthread_mutex_init(0, 0))); PrintStr(" ");
  PrintStr(IntToStr(pthread_mutex_init(m, 1))); PrintStr(" ");
  PrintLn(IntToStr(pthread_cond_init(0, 0)));
  return 0;
}' "-1 -1 -1"

# ===========================================================================
# TLS ueber die POSIX-Namen
# ===========================================================================

out "pthread_key_create, setspecific, getspecific" 'import std.io;
import std.thread;
fn main(): int64 {
  var kb: int64 := alloc(8);
  PrintStr(IntToStr(pthread_key_create(kb, 0))); PrintStr(" ");
  var k: int64 := peek64(kb);
  pthread_setspecific(k, 4711);
  PrintStr(IntToStr(pthread_getspecific(k))); PrintStr(" ");
  PrintLn(IntToStr(pthread_key_delete(k)));
  return 0;
}' "0 4711 0"

# Ein Destruktor wird NICHT zugesagt: er ist nicht umgesetzt, also wird die
# Anforderung gemeldet statt stillschweigend ignoriert.
out "Destruktor beim Schluessel wird gemeldet" 'import std.io;
import std.thread;
fn main(): int64 {
  var kb: int64 := alloc(8);
  PrintLn(IntToStr(pthread_key_create(kb, 12345)));
  return 0;
}' "-1"

# ===========================================================================
# Prozesse: fork/waitpid/kill/_exit wirken wirklich
# ===========================================================================

# Der Kern: das Kind beendet sich mit einem BESTIMMTEN Status, und der Elter
# liest genau diesen. Ein fork(), das nur 0 liefert (der alte Zustand), fiele
# hier durch — dann liefe kein Kind, und waitpid haette nichts zu melden.
out "fork, _exit und waitpid tragen den Status" 'import std.io;
import std.process;
import std.thread;
fn main(): int64 {
  var pid: int64 := fork();
  if (pid == 0) { _exit(23); }
  var st: int64 := alloc(8);
  var w: int64 := waitpid(pid, st, 0);
  if (w == pid) { PrintStr("richtiges Kind "); } else { PrintStr("falsches Kind "); }
  PrintLn(IntToStr((peek64(st) >> 8) & 255));
  return 0;
}' "richtiges Kind 23"

out "kill beendet ein laufendes Kind" 'import std.io;
import std.process;
import std.thread;
fn main(): int64 {
  var pid: int64 := fork();
  if (pid == 0) { var i: int64 := 0; while (i < 2000000000) { i := i + 1; } _exit(0); }
  var r: int64 := kill(pid, 9);
  var st: int64 := alloc(8);
  waitpid(pid, st, 0);
  PrintStr(IntToStr(r)); PrintStr(" ");
  PrintLn(IntToStr(peek64(st) & 127));
  return 0;
}' "0 9"

# execvp findet ein Programm ohne Pfadangabe. Das Kind ersetzt sich selbst;
# kehrt execvp zurueck, ist es gescheitert.
out "execvp findet /bin/true ohne Pfadangabe" 'import std.io;
import std.process;
import std.thread;
fn main(): int64 {
  var pid: int64 := fork();
  if (pid == 0) {
    var argv: int64 := alloc(16);
    poke64(argv, "true"c as int64);
    poke64(argv + 8, 0);
    execvp("true"c, argv);
    _exit(99);
  }
  var st: int64 := alloc(8);
  waitpid(pid, st, 0);
  PrintLn(IntToStr((peek64(st) >> 8) & 255));
  return 0;
}' "0"

# Gegenprobe: ein Name, den es nirgends gibt, kehrt zurueck — und das Kind
# meldet es. Ohne diese Pruefung waere ein execvp, das immer scheitert und
# schweigt, ebenso gruen.
out "execvp meldet ein unauffindbares Programm" 'import std.io;
import std.process;
import std.thread;
fn main(): int64 {
  var pid: int64 := fork();
  if (pid == 0) {
    var argv: int64 := alloc(16);
    poke64(argv, "gibtesnicht_xyz"c as int64);
    poke64(argv + 8, 0);
    execvp("gibtesnicht_xyz"c, argv);
    _exit(99);
  }
  var st: int64 := alloc(8);
  waitpid(pid, st, 0);
  PrintLn(IntToStr((peek64(st) >> 8) & 255));
  return 0;
}' "99"

# ===========================================================================
# sys_exit / sys_exit_group — beide waren in sema registriert und im Codegen
# nicht umgesetzt (#1246, dieselbe Luecke wie #1363)
# ===========================================================================

printf 'fn main(): int64 { sys_exit(7); return 0; }\n' > "$TMP/e1.lyx"
rm -f "$TMP/e1"
if "$LYXC" --std-path="$ROOT" "$TMP/e1.lyx" -o "$TMP/e1" >/dev/null 2>&1; then
  "$TMP/e1"; rc=$?
  if [ "$rc" -eq 7 ]; then ok "sys_exit setzt den Rueckgabewert"; else no "sys_exit setzt den Rueckgabewert" "rc=$rc"; fi
else
  no "sys_exit setzt den Rueckgabewert" "uebersetzt nicht"
fi

printf 'fn main(): int64 { sys_exit_group(8); return 0; }\n' > "$TMP/e2.lyx"
rm -f "$TMP/e2"
if "$LYXC" --std-path="$ROOT" "$TMP/e2.lyx" -o "$TMP/e2" >/dev/null 2>&1; then
  "$TMP/e2"; rc=$?
  if [ "$rc" -eq 8 ]; then ok "sys_exit_group setzt den Rueckgabewert"; else no "sys_exit_group setzt den Rueckgabewert" "rc=$rc"; fi
else
  no "sys_exit_group setzt den Rueckgabewert" "uebersetzt nicht"
fi

# ===========================================================================
# PDF und SVG
# ===========================================================================

out "PdfAddPageSized legt eine Seite an" 'import std.io;
import std.pdf;
fn main(): int64 {
  var doc: int64 := PdfNew();
  var p: int64 := PdfAddPageSized(doc, 200.0, 400.0);
  if (p >= 0) { PrintLn("seite ok"); } else { PrintLn("fehlgeschlagen"); }
  return 0;
}' "seite ok"

out "SvgNewViewBox setzt das viewBox-Attribut" 'import std.io;
import std.svg;
fn main(): int64 {
  var doc: int64 := SvgNewViewBox(100.0, 50.0, 0.0, 0.0, 200.0, 100.0);
  if (doc == 0) { PrintLn("kein Dokument"); return 1; }
  var s: pchar := SvgToString(doc);
  if (StrContains(s, "viewBox") != 0) { PrintLn("viewBox vorhanden"); } else { PrintLn("viewBox fehlt"); }
  return 0;
}' "viewBox vorhanden"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
