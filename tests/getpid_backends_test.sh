#!/usr/bin/env bash
# tests/getpid_backends_test.sh — getpid auf allen IR-Zielen (#2343).
#
# Warum es diesen Test gibt: ir_lower vergibt die Builtin-ID 65 fuer JEDES
# IR-Ziel, der Linux-Zweig von arm64 und riscv kannte sie aber nicht. Jede
# Unit mit getpid war damit fuer diese Ziele unuebersetzbar — auch
# src/std/os.lyx. Gemeldet wurde es laut ("Builtin-ID 65 wird nicht
# behandelt"), aufgefallen ist es trotzdem erst, als lyxc selbst getpid
# benutzte. Eine Aufzaehlung, die ein Ziel vergisst, ist der haeufigste
# Fehler in diesem Compiler.
#
# Geprueft wird der WERT, nicht das Vorhandensein eines Befehls: das Programm
# gibt seine eigene Prozessnummer aus, und sie muss der entsprechen, die die
# Shell fuer denselben Prozess sieht. Ein `> 0`-Vergleich waere ein
# Invariantentest — er wuerde auch von einem Rumpf erfuellt, der eine
# beliebige Zahl liefert.
#
# Unter qemu-user ist die Prozessnummer des Gastes die des qemu-Prozesses,
# der Vergleich traegt dort also genauso.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
export LYXC
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

. "$(dirname "$0")/lib/qemu.sh"   # #2048

cat > "$TMP/p.lyx" <<'EOF'
import src.std.io;
fn main(): int64 {
  var p: int64 := getpid();
  PrintLn(p);
  return 0;
}
EOF

# Die Prozessnummer des eigenen Laufs: der Prozess wird im Hintergrund
# gestartet, die Shell kennt seine Nummer, und das Programm gibt seine
# eigene aus. Beide muessen uebereinstimmen.
messe() { # $1 = Startbefehl (vollstaendig), gibt "gesehen gemeldet" aus
  local befehl="$1"
  # `exec`, damit die Hintergrund-Subshell SELBST zum Programm wird. Ohne das
  # ist $! die Nummer der Subshell und das Programm ihr Kind -- der Vergleich
  # ging dann auf allen drei Zielen um genau 1 daneben, was nach einem
  # Backend-Fehler aussah und keiner war.
  ( eval "exec $befehl" > "$TMP/aus.txt" 2>"$TMP/err.txt" & echo $! > "$TMP/pid.txt"; wait )
  echo "$(cat "$TMP/pid.txt") $(tr -dc '0-9\n' < "$TMP/aus.txt" | head -1)"
}

pruefe() { # $1 = Zielname, $2 = Startbefehl
  read -r gesehen gemeldet <<<"$(messe "$2")"
  if [ -z "$gemeldet" ]; then
    no "$1 getpid liefert einen Wert" "keine Ausgabe: $(head -1 "$TMP/err.txt")"
  elif [ "$gesehen" != "$gemeldet" ]; then
    no "$1 getpid liefert die eigene Prozessnummer" "Programm meldet $gemeldet, die Shell sieht $gesehen"
  else
    ok "$1 getpid liefert die eigene Prozessnummer ($gemeldet)"
  fi
}

# ── x86-64: das Ziel, das immer lief. Es ist die Gegenprobe zum Messaufbau:
#    schlaegt es hier fehl, ist der Vergleich falsch, nicht das Backend.
if "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p_x86" >"$TMP/c_x86.log" 2>&1; then
  ok "x86-64 uebersetzt"
  pruefe "x86-64" "\"$TMP/p_x86\""
else
  no "x86-64 uebersetzt" "$(tail -2 "$TMP/c_x86.log" | tr '\n' ' ')"
fi

# ── arm64
if "$LYXC" --std-path="$ROOT" --target=arm64 "$TMP/p.lyx" -o "$TMP/p_arm" >"$TMP/c_arm.log" 2>&1; then
  ok "arm64 uebersetzt"
  if [ -n "$QEMU_ARM64" ]; then
    pruefe "arm64" "\"$QEMU_ARM64\" \"$TMP/p_arm\""
  else
    echo "SKIP arm64 ausfuehren: qemu-aarch64 fehlt"
  fi
else
  no "arm64 uebersetzt" "$(tail -2 "$TMP/c_arm.log" | tr '\n' ' ')"
fi

# ── riscv
if "$LYXC" --std-path="$ROOT" --target=riscv64 "$TMP/p.lyx" -o "$TMP/p_rv" >"$TMP/c_rv.log" 2>&1; then
  ok "riscv64 uebersetzt"
  if [ -n "$QEMU_RISCV64" ]; then
    pruefe "riscv64" "\"$QEMU_RISCV64\" \"$TMP/p_rv\""
  else
    echo "SKIP riscv64 ausfuehren: qemu-riscv64 fehlt"
  fi
else
  no "riscv64 uebersetzt" "$(tail -2 "$TMP/c_rv.log" | tr '\n' ' ')"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
