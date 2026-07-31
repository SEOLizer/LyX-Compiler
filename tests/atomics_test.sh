#!/usr/bin/env bash
# tests/atomics_test.sh — echte Atomarität in std/thread.lyx.
#
# AtomicAdd und CAS lasen früher mit peek64 und schrieben mit poke64, waren also
# trotz des Namens ein Read-Modify-Write mit Rennen: zwei Threads konnten
# denselben Ausgangswert lesen, und einer der beiden Zuwächse ging verloren.
# Ebenso der Mutex — `if (peek32(p) == 0) { poke32(p, 1) }` ist ein
# nicht-atomares Test-and-Set, bei dem beide Seiten "gewinnen" können.
#
# Ursache dahinter: die atomic_*- und fence_*-Builtins waren in sema
# registriert, aber NUR im lyxos-Backend emittiert. Auf dem ELF-Pfad endete
# jeder Aufruf in "no codegen implementation found" — die stdlib konnte sie also
# gar nicht verwenden. Sie sind jetzt auch in codegen_x86.lyx implementiert.
#
# Geprüft wird zweierlei:
#   1. Semantik jeder Operation (Rückgabewert UND Wirkung im Speicher)
#   2. dass tatsächlich sperrende Instruktionen emittiert werden — ohne
#      `lock`-Präfix wäre die Semantik einthreadig identisch und der Test
#      grün, obwohl nichts atomar ist. Deshalb der Byte-Nachweis.
#
# Der Nebenläufigkeitsteil steht in tests/thread_concurrency_test.lyx: er ist
# erst möglich, seit ThreadCreate wirklich einen Kindthread startet (Issue #992).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------- Semantik ---
cat > "$TMP/sem.lyx" <<'EOF'
import std.thread;
fn main(): int64 {
  var a: Atomic := AtomicNew(40);
  if (AtomicLoad(a) != 40)      { return 1; }
  if (AtomicAdd(a, 2) != 42)    { return 2; }   // liefert NEUEN Wert
  if (AtomicLoad(a) != 42)      { return 3; }
  AtomicStore(a, 7);
  if (AtomicLoad(a) != 7)       { return 4; }
  if (CAS(a, 7, 99) != 1)       { return 5; }   // Erfolg
  if (AtomicLoad(a) != 99)      { return 6; }
  if (CAS(a, 7, 123) != 0)      { return 7; }   // muss scheitern
  if (AtomicLoad(a) != 99)      { return 8; }   // und nichts geschrieben haben
  if (AtomicAdd(a, 0 - 99) != 0){ return 9; }   // negatives Delta
  AtomicFree(a);

  var m: Mutex := MutexNew();
  MutexLock(m);
  if (MutexTryLock(m) != 0)     { return 10; }  // gehalten -> belegt
  MutexUnlock(m);
  if (MutexTryLock(m) != 1)     { return 11; }  // frei -> Erfolg
  MutexUnlock(m);
  MutexFree(m);
  return 42;
}
EOF
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/sem.lyx" -o "$TMP/sem" >/dev/null 2>&1); then
  timeout 10 "$TMP/sem" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 42 ]; then ok "Semantik von Atomic und Mutex"; else no "Semantik" "exit=$rc (Nummer = fehlgeschlagene Prüfung)"; fi
else
  no "Semantik" "compile fehlgeschlagen"
fi

# ------------------------------------------------- Builtins direkt aufrufbar ---
cat > "$TMP/bi.lyx" <<'EOF'
import std.alloc;
fn main(): int64 {
  var p: int64 := alloc(8);
  poke64(p, 40);
  if (atomic_fetch_add(p, 2) != 40) { return 1; }  // liefert ALTEN Wert
  if (atomic_load(p) != 42)         { return 2; }
  if (atomic_store(p, 7) != 42)     { return 3; }  // liefert ALTEN Wert
  if (atomic_cas(p, 7, 99) != 7)    { return 4; }  // liefert ALTEN Wert
  if (atomic_load(p) != 99)         { return 5; }
  fence_mfence(); fence_sfence(); fence_lfence();
  return 42;
}
EOF
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/bi.lyx" -o "$TMP/bi" >/dev/null 2>&1); then
  timeout 10 "$TMP/bi" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 42 ]; then ok "atomic_*/fence_* Builtins auf dem ELF-Pfad"; else no "Builtins" "exit=$rc"; fi
else
  no "atomic_*/fence_* Builtins auf dem ELF-Pfad" "compile fehlgeschlagen — Phantom-Builtin?"
fi

# ------------------------------------------------------- Byte-Nachweis lock ---
# Ohne diese Prüfung wäre der Test auch dann grün, wenn die Operationen als
# schlichte Lade-/Speicherbefehle emittiert würden.
hex=$(xxd -p "$TMP/bi" 2>/dev/null | tr -d '\n')
check_bytes() { # name, hexmuster
  if echo "$hex" | grep -q "$2"; then ok "$1"; else no "$1" "Bytefolge $2 fehlt"; fi
}
check_bytes "lock xadd [rdi],rax emittiert"     "f0480fc107"
check_bytes "lock cmpxchg [rdi],rdx emittiert"  "f0480fb117"
check_bytes "xchg [rdi],rax emittiert"          "488707"
check_bytes "mfence emittiert"                  "0faef0"
check_bytes "sfence emittiert"                  "0faef8"
check_bytes "lfence emittiert"                  "0faee8"

# Auch die stdlib muss die sperrenden Formen tragen, nicht nur der Direktaufruf.
hexs=$(xxd -p "$TMP/sem" 2>/dev/null | tr -d '\n')
if echo "$hexs" | grep -q "f0480fc107" && echo "$hexs" | grep -q "f0480fb117"; then
  ok "std/thread.lyx nutzt die sperrenden Formen"
else
  no "std/thread.lyx nutzt die sperrenden Formen" "lock-Praefixe fehlen — peek/poke-Fassung zurueck?"
fi

# ------------------------------------------------ echte Nebenlaeufigkeit ---
# Der eigentliche Beweis: vier Threads erhoehen denselben Zaehler. Ohne echte
# lock-Instruktionen gehen Zuwaechse verloren.
rm -f "$TMP/conc"
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$ROOT/tests/thread_concurrency_test.lyx" -o "$TMP/conc" >/dev/null 2>&1); then
  timeout 180 "$TMP/conc" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 42 ]; then ok "vier Threads, Atomics und Mutex"; else no "Nebenlaeufigkeit" "exit=$rc"; fi
else
  no "vier Threads, Atomics und Mutex" "compile fehlgeschlagen"
fi

# --------------------------------------------- Kind-Stacks werden freigegeben ---
# ThreadJoin gab den 2-MB-Stack des Threads nicht frei. Unter einem VM-Limit
# scheiterte ThreadCreate dadurch reproduzierbar (bei 1 GB ab dem 509. Thread).
# Das Limit ist der eigentliche Test: ohne Freigabe reicht der Adressraum nicht.
cat > "$TMP/leak.lyx" <<'EOF'
import std.thread;
fn tw(a: int64): int64 { return 0; }
fn main(): int64 {
  var i: int64 := 0;
  while (i < 400) {
    var t: Thread := ThreadCreate(tw, 0);
    if (t.handle == 0) { return 1; }   // Stack konnte nicht alloziert werden
    ThreadJoin(t);
    i := i + 1;
  }
  return 42;
}
EOF
rm -f "$TMP/leak"
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/leak.lyx" -o "$TMP/leak" >/dev/null 2>&1); then
  # 400 Threads x 2 MB = 800 MB, wenn nichts freigegeben wird; Limit 384 MB.
  # Die Marge ist bewusst nicht knapper: der Adressraum des Prozesses enthaelt
  # neben den Stacks noch Arena und Bibliotheken, ein zu enges Limit macht den
  # Test wackelig statt aussagekraeftig.
  ( ulimit -v 393216 && timeout 120 "$TMP/leak" ) >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 42 ]; then ok "ThreadJoin gibt den Kind-Stack frei"; else no "ThreadJoin gibt den Kind-Stack frei" "exit=$rc unter ulimit -v 256M"; fi
else
  no "ThreadJoin gibt den Kind-Stack frei" "compile fehlgeschlagen"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
