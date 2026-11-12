#!/usr/bin/env bash
# tests/thread_join_test.sh — #1881: ThreadCreate/ThreadJoin beendete den
# Prozess sporadisch mit 0 statt mit dem Rueckgabewert von main.
#
# Ursache: ThreadCreate legte das Ergebnis von sys_clone in ein Local und las
# es fuer die Weiche Kind/Elternteil gleich wieder aus dem Slot. clone(2) setzt
# im Kind nur rsp neu, rbp bleibt -- der Slot ist fuer beide Threads DIESELBE
# Speicherzelle. Schrieb das Kind seine 0 zwischen Speichern und Lesen des
# Elternteils, nahm auch der Hauptthread den Kindweg und rief sys_exit(0); das
# strace eines Fehllaufs zeigt `<main-tid> exit(0)` direkt nach dem clone.
# Umgekehrt lief das Kind gelegentlich den Elternweg weiter (Haenger, rc 124).
#
# Gemessen wird dreierlei:
#   1. der WEG am Erzeugnis: zwischen dem clone-syscall und dem Aufruf, der
#      die Weiche enthaelt, darf kein Zugriff auf den rbp-Frame liegen. Das ist
#      die Stelle, an der das Rennen entstand -- und anders als der Ausgang
#      ist sie bei jedem Lauf sichtbar, nicht nur in einem von hundert.
#   2. der WERT: das Repro aus dem Issue, 100 Laeufe, jeder muss 42 liefern.
#   3. die Freigabe der Kind-Stacks (der urspruengliche Zweck aus
#      tests/atomics_test.sh): 400 Threads unter 128 MB Adressraum gehen nur,
#      wenn ThreadJoin den 2-MB-Stack zurueckgibt. Gegenprobe: dasselbe
#      Programm OHNE ThreadJoin muss unter demselben Limit scheitern -- sonst
#      waere das Limit gar keine Messung.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

VMLIMIT_KB=131072   # 128 MB: weit unter den 800 MB fuer 400 nicht freigegebene Stacks
LAEUFE=100

uebersetze() { # quelle, ziel
  rm -f "$2"
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" "$1" -o "$2" ) >"$TMP/bl.log" 2>&1 && [ -x "$2" ]
}

# Repro wörtlich aus #1881.
cat > "$TMP/join.lyx" <<'EOF'
import std.io;
import std.thread;
fn tw(a: int64): int64 { return 0; }
fn main(): int64 {
  var i: int64 := 0;
  while (i < 400) {
    var t: Thread := ThreadCreate(tw, 0);
    if (t.handle == 0) { return 1; }
    ThreadJoin(t);
    i := i + 1;
  }
  return 42;
}
EOF

# Gegenprobe: ohne ThreadJoin bleibt jeder Kind-Stack liegen.
cat > "$TMP/nojoin.lyx" <<'EOF'
import std.io;
import std.thread;
fn tw(a: int64): int64 { return 0; }
fn main(): int64 {
  var i: int64 := 0;
  while (i < 400) {
    var t: Thread := ThreadCreate(tw, 0);
    if (t.handle == 0) { return 1; }
    while (ThreadIsRunning(t) == 1) { }
    i := i + 1;
  }
  return 42;
}
EOF

if ! uebersetze "$TMP/join.lyx" "$TMP/join"; then
  nok "Repro uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"
  echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

# ------------------------------------------------------ 1. Weg am Erzeugnis ---
# Der Code beginnt am Einsprungpunkt; die Datei hat keine Sektionstabelle,
# deshalb roh ab dem Einsprung disassemblieren.
entry="$(LC_ALL=C readelf -h "$TMP/join" 2>/dev/null | awk '/Entry point/ {print $NF}')"
if [ -z "$entry" ] || ! command -v objdump >/dev/null; then
  nok "Weiche nach clone: readelf/objdump fehlt — NICHT gemessen"
else
  objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 --start-address="$entry" \
    -z --no-show-raw-insn "$TMP/join" > "$TMP/join.dis" 2>/dev/null
  # Alles zwischen `mov $0x38,%rax; syscall` (clone) und dem naechsten call.
  awk '
    /\$0x38,%rax/            { arm = 1; next }
    arm && /syscall/         { n++; inz = 1; arm = 0; cnt = 0; next }
    { arm = 0 }
    inz && /call/            { inz = 0; calls++; next }
    inz                      { cnt++; print; if (cnt > 12) { inz = 0; lang++ } }
    END { printf "#clone=%d calls=%d lang=%d\n", n, calls, lang }
  ' "$TMP/join.dis" > "$TMP/zwischen.txt"
  stat="$(tail -1 "$TMP/zwischen.txt")"
  frame="$(grep -c '(%rbp)' "$TMP/zwischen.txt")"
  if [ "$frame" -ne 0 ]; then
    nok "Weiche nach clone: $frame Zugriff(e) auf den geteilten rbp-Frame vor der Weiche: $(grep '(%rbp)' "$TMP/zwischen.txt" | head -2 | tr -s ' \t' ' ' | tr '\n' ';')"
  elif [ "$stat" != "#clone=1 calls=1 lang=0" ]; then
    nok "Weiche nach clone: Muster nicht gefunden ($stat) — Codegen geaendert? Messung anpassen"
  else
    ok "Weiche nach clone: kein Zugriff auf den rbp-Frame zwischen syscall und call"
  fi
fi

# ------------------------------------------------------ 2. Wert, 100 Laeufe ---
# Parallel, damit die Threads um die Kerne konkurrieren -- das oeffnet das
# Fenster eher als ein ruhiger Einzellauf. Jeder Lauf unter dem VM-Limit.
seq 1 "$LAEUFE" | xargs -P 8 -I{} bash -c \
  'ulimit -v '"$VMLIMIT_KB"'; ulimit -c 0; timeout 60 "$0" >/dev/null 2>&1; echo $?' "$TMP/join" \
  > "$TMP/rcs.txt"
gut="$(grep -cx 42 "$TMP/rcs.txt")"
if [ "$gut" -eq "$LAEUFE" ]; then
  ok "$LAEUFE von $LAEUFE Laeufen enden mit 42 (400 Threads je Lauf)"
else
  nok "nur $gut von $LAEUFE Laeufen enden mit 42; Ausgaenge: $(sort "$TMP/rcs.txt" | uniq -c | tr -s ' \n' ' ')"
fi

# ------------------------------------------- 3. Kind-Stack wird freigegeben ---
# Erfolg (42) in Teil 2 hiess schon: 400 Threads passten in 128 MB. Hier die
# Gegenseite: ohne Join passen sie NICHT -- das Limit misst also die Freigabe.
if ! uebersetze "$TMP/nojoin.lyx" "$TMP/nojoin"; then
  nok "Gegenprobe ohne Join uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"
else
  ( ulimit -v "$VMLIMIT_KB"; timeout 60 "$TMP/nojoin" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq 1 ]; then
    ok "Gegenprobe: ohne ThreadJoin scheitert ThreadCreate unter $((VMLIMIT_KB / 1024)) MB (rc 1)"
  else
    nok "Gegenprobe: ohne ThreadJoin rc=$rc statt 1 — das Limit misst die Stack-Freigabe nicht"
  fi
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
