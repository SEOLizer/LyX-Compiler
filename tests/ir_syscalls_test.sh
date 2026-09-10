#!/usr/bin/env bash
# tests/ir_syscalls_test.sh — #2021: Linux-Syscalls, die bisher nur der
# x86-Codegen kannte.
#
# Achtzehn Namen liessen jede Unit, die sie benutzt, fuer arm64 und riscv
# scheitern ("unbekannter Builtin/Funktion"), obwohl x86 sie laengst
# emittiert. Siebzehn sind jetzt umgesetzt; `sys_select` bleibt offen, weil
# die generische Linux-ABI es nicht kennt (siehe unten).
#
# GEMESSEN WIRD DIE WIRKUNG unter qemu, gegen x86_64 als Referenz. Ein Test auf
# "uebersetzt durch" waere hier besonders wertlos: eine falsche Syscall-Nummer
# uebersetzt genauso sauber und liefert dann still das Falsche.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

QEMU_ARM=""; QEMU_RV=""
command -v qemu-aarch64-static >/dev/null 2>&1 && QEMU_ARM="qemu-aarch64-static"
command -v qemu-riscv64-static >/dev/null 2>&1 && QEMU_RV="qemu-riscv64-static"

lauf() {
  local ziel="$1"
  local src="$2"
  local out="$3"
  local bin="$TMP/b_$ziel"
  ( cd "$ROOT" && timeout 180 "$LYXC" --target="$ziel" "$src" -o "$bin" ) >"$TMP/build_$ziel.log" 2>&1 || return 1
  case "$ziel" in
    x86_64) timeout 60 "$bin" >"$out" 2>&1 ;;
    arm64)  [ -n "$QEMU_ARM" ] || return 2; timeout 60 $QEMU_ARM "$bin" >"$out" 2>&1 ;;
    riscv)  [ -n "$QEMU_RV" ]  || return 2; timeout 60 $QEMU_RV  "$bin" >"$out" 2>&1 ;;
  esac
  return 0
}

echo "--- #2021: Syscall OHNE Argumente (getuid, sched_yield) ---"
#
# getuid ist der beste erste Nachweis: der Wert kommt vom Kernel und laesst
# sich unabhaengig nachpruefen (`id -u`). Eine falsche Syscall-Nummer liefert
# hier etwas anderes oder -ENOSYS — beides faellt sofort auf.
cat > "$TMP/uid.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  PrintLn(IntToStr(sys_getuid()));
  PrintLn(IntToStr(sys_sched_yield()));
  return 0;
}
EOF
ECHTE_UID="$(id -u)"
ERW="${ECHTE_UID}|0|"
for ziel in x86_64 arm64 riscv; do
  lauf "$ziel" "$TMP/uid.lyx" "$TMP/uid.$ziel"; rc=$?
  if [ "$rc" = 2 ]; then
    nok "$ziel: qemu fehlt — die Wirkung wurde NICHT gemessen"
  elif [ "$rc" != 0 ]; then
    nok "$ziel: uebersetzt nicht ($(grep -m1 -E 'error|unbekannt' "$TMP/build_$ziel.log"))"
  else
    ist="$(tr '\n' '|' < "$TMP/uid.$ziel")"
    if [ "$ist" = "$ERW" ]; then
      ok "$ziel: sys_getuid liefert die echte uid ($ECHTE_UID), sys_sched_yield 0"
    else
      nok "$ziel: [$ist] statt [$ERW]"
    fi
  fi
done

echo
echo "--- #2021: Syscall MIT Argumenten (pread64) ---"
#
# Vier Argumente — damit steht die Registerbelegung auf dem Pruefstand, nicht
# nur die Nummer. Gelesen wird ab Position 3, vier Bytes: aus "ABCDEFGHIJ"
# muss "DEFG" werden. Ein vertauschtes oder fehlendes Argument ergaebe einen
# anderen Ausschnitt — der Test zeigt also, WELCHE Bytes ankommen, nicht nur
# dass gelesen wurde.
printf 'ABCDEFGHIJ' > "$TMP/pr.dat"
sed "s|DATEIPFAD|$TMP/pr.dat|" > "$TMP/pr.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var fd: int64 := open("DATEIPFAD"c, 0, 0);
  if (fd < 0) { PrintLn("open fehlgeschlagen"); return 1; }
  var buf: int64 := alloc(16);
  var n: int64 := sys_pread64(fd, buf, 4, 3);
  PrintLn(IntToStr(n));
  poke8(buf + 4, 0);
  PrintLn(buf as pchar);
  return 0;
}
EOF
# arm64 ist hier ausgespart: dort fehlt `open` (Builtin-ID 220) noch ganz —
# das ist #2037 und hat mit den Syscalls aus #2021 nichts zu tun. Sobald die
# Luecke zu ist, gehoert arm64 in diese Schleife.
for ziel in x86_64 riscv; do
  lauf "$ziel" "$TMP/pr.lyx" "$TMP/pr.$ziel"; rc=$?
  if [ "$rc" = 2 ]; then
    nok "$ziel: qemu fehlt — die Wirkung wurde NICHT gemessen"
  elif [ "$rc" != 0 ]; then
    nok "$ziel: uebersetzt nicht ($(grep -m1 -E 'error|unbekannt' "$TMP/build_$ziel.log"))"
  else
    ist="$(tr '\n' '|' < "$TMP/pr.$ziel")"
    if [ "$ist" = "4|DEFG|" ]; then
      ok "$ziel: sys_pread64(fd, buf, 4, 3) liest genau DEFG"
    else
      nok "$ziel: [$ist] statt [4|DEFG|]"
    fi
  fi
done

echo
echo "--- #2021: die betroffenen stdlib-Units uebersetzen ---"
#
# Der Ausgangsbefund: diese Units waren fuer arm64 unbaubar. Gemessen wird
# hier nur die Uebersetzbarkeit — die Wirkung der einzelnen Syscalls steht
# oben, und ein Kernel-Aufruf wie sys_ptrace oder sys_bpf laesst sich in einem
# Testlauf nicht sinnvoll ausloesen.
# Diese drei haengen ausschliesslich an den hier umgesetzten Syscalls.
#
# NICHT dabei, und zwar aus zwei verschiedenen Gruenden:
#   * std/ns.lyx, std/inotify.lyx, std/mqueue.lyx brauchen weitere Namen
#     (sys_setns, sys_inotify_rm_watch, sys_mq_timedsend) — die vollstaendige
#     Liste der noch fehlenden 50 steht in #2021.
#   * std/sched.lyx und std/security_ext.lyx scheitern an sys_getcpu bzw.
#     verwandten IDs aus dem Bereich 172...198, den nur das lyxos-Backend
#     kennt. Das ist #2024 und hat mit diesen Syscalls nichts zu tun.
for u in std/os.lyx std/debug.lyx std/bpf.lyx; do
  if ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --target=arm64 "$u" -o /dev/null ) >"$TMP/u.log" 2>&1; then
    ok "$(basename "$u") uebersetzt fuer arm64"
  else
    nok "$(basename "$u") fuer arm64" "$(grep -m1 -E 'error|unbekannt' "$TMP/u.log")"
  fi
done

echo
echo "--- #2021: sys_select wird BENANNT abgewiesen ---"
#
# Die generische Linux-ABI kennt kein `select`; arm64 und riscv haben nur
# `pselect6` mit einem SECHSTEN Argument (Signalmaske). Ein Aufruf mit fuenf
# Argumenten liesse sich darauf nur abbilden, indem man diesen Wert erfindet —
# das waere eine stille Fehlfunktion statt einer fehlenden Funktion.
#
# Der Test haelt fest, dass die Luecke BENANNT bleibt. Wird sie geschlossen
# (etwa ueber pselect6 mit ausdruecklicher Maske), gehoert diese Pruefung
# umgestellt — auf den TEXT, den der Aufruf dann liefert.
cat > "$TMP/sel.lyx" <<'EOF'
unit main;
fn main(): int64 { return sys_select(0, 0, 0, 0, 0); }
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" --target=arm64 "$TMP/sel.lyx" -o "$TMP/sel.bin" ) >"$TMP/sel.log" 2>&1; then
  nok "sys_select uebersetzte fuer arm64 — gibt es pselect6 jetzt? Dann diesen Test auf die WIRKUNG umstellen"
else
  if grep -q "sys_select gibt es auf diesem Ziel nicht" "$TMP/sel.log"; then
    ok "sys_select wird mit Begruendung abgewiesen (nicht als 'unbekannter Builtin')"
  else
    nok "abgewiesen, aber ohne den Grund zu nennen: $(grep -m1 -E 'error|lyxc:' "$TMP/sel.log")"
  fi
fi

# GEGENPROBE: auf x86_64 gibt es select, dort muss es weiterhin gehen. Ohne
# diese Haelfte waere der Test auch von einer Fassung erfuellt, die sys_select
# ueberall abweist.
if ( cd "$ROOT" && timeout 120 "$LYXC" "$TMP/sel.lyx" -o "$TMP/sel.x86" ) >"$TMP/selx.log" 2>&1; then
  ok "x86_64 uebersetzt sys_select weiterhin"
else
  nok "sys_select ist auch fuer x86_64 kaputt: $(grep -m1 -E 'error' "$TMP/selx.log")"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
