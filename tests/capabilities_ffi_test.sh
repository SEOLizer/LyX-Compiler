#!/usr/bin/env bash
# tests/capabilities_ffi_test.sh — #1198/#1347, #1359, #1180, #1276, #1348.
#
# Fünf Meldungen an derselben Stelle: das Capability-Tor. Alle fünf sind
# Sperren, die zu viel sperren — und dabei die Absicht des Benutzers
# missachten, nicht nur seine Schreibweise.
#
# #1198/#1347: `process.signal` steht in der Registry, war aber nicht
# schreibbar, weil `signal` als Schluesselwort lext und der Pfadparser nur
# TK_IDENT durchliess.
#
# #1359: Die FFI-Sandbox verlangte @capabilities([...]) und ignorierte genau
# diese Schreibweise — an extern fn landete nur @cap(path). Eine Sperre,
# deren Meldung einen Schluessel nennt, der nicht passt.
#
# #1180: Die Signaturregel zaehlte `usize` als Groessenparameter, `int64`
# aber nicht: `int64` ist ein Bezeichner, kein Schluesselwort. Damit galt
# f(pchar, pchar, int64) als "ohne Groessenlimit".
#
# #1276: fcntl fehlte im seccomp-Filter vollstaendig — gehaertete Programme
# mit Dateisperren starben an SIGSYS.
#
# #1348: TLS braucht fs.meta fuer den CA-Store. Fehlt es, stirbt der
# Handshake ohne Meldung; der Compiler sagt es jetzt beim Uebersetzen.
#
# Jede Pruefung hat ihre Gegenprobe: eine Sperre, die alles durchlaesst,
# waere ebenso gruen wie eine, die alles blockiert.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

baut() { # name, quelltext
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  out="$("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1)"
  if [ -f "$TMP/p" ]; then ok "$1"; else no "$1" "$(echo "$out" | grep -i error | head -1)"; fi
}

weist_ab() { # name, quelltext, textstueck
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  out="$("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1)"
  if [ -f "$TMP/p" ]; then no "$1" "uebersetzt, statt zu melden"; return; fi
  case "$out" in *"$3"*) ok "$1" ;; *) no "$1" "Meldung nennt '$3' nicht: $(echo "$out"|head -1)" ;; esac
}

# ===========================================================================
# #1198 / #1347 — Schluesselwoerter als Capability-Pfadsegment
# ===========================================================================

baut "process.signal ist deklarierbar" '@capabilities([system.exit, process.signal])
fn main(): int64 { return 0; }'

# Die Capability muss auch ANKOMMEN, nicht nur durchparsen: der Audit-Kopf
# listet, was der Compiler verstanden hat.
printf '@capabilities([system.exit, process.signal])\nfn main(): int64 { return 0; }\n' > "$TMP/sig.lyx"
aud="$("$LYXC" --std-path="$ROOT" "$TMP/sig.lyx" -o "$TMP/sig" 2>&1)"
case "$aud" in
  *"process.signal"*) ok "process.signal steht im Capability-Audit" ;;
  *) no "process.signal steht im Capability-Audit" "nicht im Audit-Kopf" ;;
esac

# grant muss eine Teilmenge der eigenen Capabilities sein — deshalb steht
# process.signal auch oben. Ohne die Deklaration waere die Ablehnung richtig,
# und der Test wuerde die Parser-Aenderung gar nicht messen.
baut "grant-Klausel mit Schluesselwort-Segment" '@capabilities([system.exit, process.signal])
import std.io grant [process.signal];
fn main(): int64 { return 0; }'

# Gegenprobe: ein Name, den die Registry nicht kennt, bleibt ein Fehler.
weist_ab "unbekannte Capability wird weiter gemeldet" '@capabilities([system.exit, process.gibtsnicht])
fn main(): int64 { return 0; }' "unbekannte Capability"

# ===========================================================================
# #1359 — die FFI-Sperre hat jetzt einen passenden Schluessel
# ===========================================================================

baut "@capabilities([...]) hebt die FFI-Sperre auf" '@capabilities([system.exit])
extern fn abs(i: int64): int64 link "libc.so.6";
fn main(): int64 { return abs(-9); }'

# Der Wert muss stimmen — uebersetzt allein hiesse nur, dass sema schweigt.
printf '@capabilities([system.exit])\nextern fn abs(i: int64): int64 link "libc.so.6";\nfn main(): int64 { return abs(-9); }\n' > "$TMP/ffi.lyx"
rm -f "$TMP/ffi"
"$LYXC" --std-path="$ROOT" "$TMP/ffi.lyx" -o "$TMP/ffi" >/dev/null 2>&1
if [ -x "$TMP/ffi" ]; then
  "$TMP/ffi"; rc=$?
  if [ "$rc" -eq 9 ]; then ok "das FFI-Symbol wird tatsaechlich gerufen (abs(-9) = 9)"
  else no "das FFI-Symbol wird tatsaechlich gerufen" "rc=$rc statt 9"; fi
else
  no "das FFI-Symbol wird tatsaechlich gerufen" "uebersetzt nicht"
fi

baut "@cap(path) wirkt weiterhin" '@cap(system.exit)
extern fn abs(i: int64): int64 link "libc.so.6";
fn main(): int64 { return abs(-3); }'

# Fail-Closed bleibt: OHNE Angabe weiter gesperrt, und die Meldung nennt den Weg.
weist_ab "ohne Capability-Angabe bleibt das Symbol gesperrt" 'extern fn abs(i: int64): int64 link "libc.so.6";
fn main(): int64 { return abs(-9); }' "FFI-Sandbox Fail-Closed"

weist_ab "die Meldung nennt die Schreibweise" 'extern fn abs(i: int64): int64 link "libc.so.6";
fn main(): int64 { return abs(-9); }' "@capabilities([system.exit])"

# ===========================================================================
# #1180 — Groessenparameter wird gezaehlt
# ===========================================================================

baut "zwei pchar mit int64-Groesse sind zulaessig" '@cap(system.exit)
extern fn probe(a: pchar, b: pchar, n: int64): int64 link "libc.so.6";
fn main(): int64 { return 0; }'

baut "dasselbe mit usize (war schon vorher zulaessig)" '@cap(system.exit)
extern fn probe(a: pchar, b: pchar, n: usize): int64 link "libc.so.6";
fn main(): int64 { return 0; }'

baut "kurze Schreibweise i64 zaehlt ebenso" '@cap(system.exit)
extern fn probe(a: pchar, b: pchar, n: i64): int64 link "libc.so.6";
fn main(): int64 { return 0; }'

# Die Regel muss weiter beissen, wo sie soll — sonst haette der Fix sie
# schlicht abgeschaltet.
weist_ab "zwei pchar OHNE Groesse bleiben abgewiesen" '@cap(system.exit)
extern fn zwei(a: pchar, b: pchar): int64 link "libc.so.6";
fn main(): int64 { return 0; }' "ohne Größenlimit"

# ===========================================================================
# #1276 — fcntl im seccomp-Filter
# ===========================================================================

cat > "$TMP/fc.lyx" <<'EOF'
@capabilities([system.exit, system.memory.heap, fs.read, fs.write, fs.create])
import std.io;
@cap(fs.read)
extern fn fcntl(fd: int64, cmd: int64, arg: int64): int64 link "libc.so.6";
fn main(): int64 { fcntl(0, 3, 0); PrintLn("fcntl ueberlebt"); return 0; }
EOF
rm -f "$TMP/fc"
"$LYXC" --std-path="$ROOT" "$TMP/fc.lyx" -o "$TMP/fc" >/dev/null 2>&1
if [ -x "$TMP/fc" ]; then
  out="$("$TMP/fc" 2>&1)"; rc=$?
  if [ "$rc" -eq 159 ]; then
    no "fcntl ueberlebt den seccomp-Filter" "SIGSYS (rc=159) — Syscall weiter gesperrt"
  elif [ "$out" = "fcntl ueberlebt" ]; then
    ok "fcntl ueberlebt den seccomp-Filter"
  else
    no "fcntl ueberlebt den seccomp-Filter" "rc=$rc, Ausgabe '$out'"
  fi
else
  no "fcntl ueberlebt den seccomp-Filter" "uebersetzt nicht"
fi

# Die Freigabe gilt nur mit einer Datei-Capability. Ohne fs.read/fs.write ist
# fcntl weiter gesperrt — sonst waere aus dem Fix eine pauschale Erlaubnis
# geworden.
cat > "$TMP/fc2.lyx" <<'EOF'
@capabilities([system.exit, system.memory.heap])
import std.io;
@cap(system.exit)
extern fn fcntl(fd: int64, cmd: int64, arg: int64): int64 link "libc.so.6";
fn main(): int64 { fcntl(0, 3, 0); PrintLn("nicht erreicht"); return 0; }
EOF
rm -f "$TMP/fc2"
"$LYXC" --std-path="$ROOT" "$TMP/fc2.lyx" -o "$TMP/fc2" >/dev/null 2>&1
if [ -x "$TMP/fc2" ]; then
  "$TMP/fc2" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 159 ]; then ok "ohne Datei-Capability bleibt fcntl gesperrt"
  else no "ohne Datei-Capability bleibt fcntl gesperrt" "rc=$rc statt 159 (SIGSYS)"; fi
else
  no "ohne Datei-Capability bleibt fcntl gesperrt" "uebersetzt nicht"
fi

# ===========================================================================
# #1348 — TLS nennt seine Capabilities beim Uebersetzen
# ===========================================================================

tlsout() { printf '%s\n' "$1" > "$TMP/t.lyx"; "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" 2>&1; }

w="$(tlsout '@capabilities([network.tcp.connect, memory.mmap, fs.read, system.exit])
import std.io;
import std.net.https;
fn main(): int64 { return 0; }')"
case "$w" in
  *"fs.meta"*"CA-Store"*|*"CA-Store"*"fs.meta"*) ok "fehlendes fs.meta wird beim Uebersetzen gemeldet" ;;
  *) no "fehlendes fs.meta wird beim Uebersetzen gemeldet" "keine Warnung" ;;
esac

w2="$(tlsout '@capabilities([network.tcp.connect, memory.mmap, fs.read, fs.meta, system.exit])
import std.io;
import std.net.https;
fn main(): int64 { return 0; }')"
case "$w2" in
  *"CA-Store"*) no "mit fs.meta schweigt die Warnung" "warnt trotzdem" ;;
  *) ok "mit fs.meta schweigt die Warnung" ;;
esac

# Ohne TLS-Import darf die Warnung nie erscheinen — sonst waere sie Rauschen.
w3="$(tlsout '@capabilities([system.exit, fs.read])
import std.io;
fn main(): int64 { return 0; }')"
case "$w3" in
  *"CA-Store"*) no "ohne TLS-Import keine Warnung" "warnt ohne Anlass" ;;
  *) ok "ohne TLS-Import keine Warnung" ;;
esac

# --seccomp-trap: derselbe Filter, aber SIGSYS wird zugestellt statt den
# Prozess vorher zu beenden — damit ist der blockierte Syscall beobachtbar.
printf '%s\n' '@capabilities([system.exit, system.memory.heap])
import std.io;
@cap(system.exit)
extern fn fcntl(fd: int64, cmd: int64, arg: int64): int64 link "libc.so.6";
fn main(): int64 { fcntl(0, 3, 0); return 0; }' > "$TMP/tr.lyx"
rm -f "$TMP/tr"
if "$LYXC" --std-path="$ROOT" "$TMP/tr.lyx" --seccomp-trap -o "$TMP/tr" >/dev/null 2>&1 && [ -x "$TMP/tr" ]; then
  "$TMP/tr" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 159 ]; then ok "--seccomp-trap bleibt fail-closed (SIGSYS)"
  else no "--seccomp-trap bleibt fail-closed (SIGSYS)" "rc=$rc — Syscall durchgelassen?"; fi
else
  no "--seccomp-trap bleibt fail-closed (SIGSYS)" "uebersetzt nicht"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
