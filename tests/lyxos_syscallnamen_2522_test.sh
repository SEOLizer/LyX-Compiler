#!/usr/bin/env bash
# tests/lyxos_syscallnamen_2522_test.sh — #2522: Zielweichen fuer Linux-eigene
# Syscall-Namen, damit die std-Units sich fuer lyxos vorkompilieren lassen.
#
# BEFUND. 14 std-Units liessen sich mit `--compile-unit --target=lyxos` nicht
# uebersetzen: sie rufen einen Syscall, den LyxOS nicht hat ("unbekannter Name
# im Aufruf: sys_listxattr"). Gemessen am 2026-11-15 mit 1.2.40B waren es
# 23 von 492 roten Units, davon 14 dieser Namensklasse. Je Unit meldet lyxc
# nur den ERSTEN unbekannten Namen; die vollstaendige Liste (46 Namen) kam aus
# einer Probe je Name, nicht aus dem Iterieren der Fehlschlaege.
#
# WAS DIESER TEST PRUEFT, und warum in dieser Form:
#
#  1. Die 14 Units uebersetzen fuer lyxos UND fuer Linux. Vor dem Fix war die
#     lyxos-Haelfte rot -- die Zusicherung ist also nicht leer.
#
#  2. BEIDE SEITEN. Ein Test, der nur zeigt, dass es auf lyxos -ENOSYS gibt,
#     waere auch von einer Unit erfuellt, die den Linux-Aufruf verloren hat.
#     Deshalb wird auf Linux die WIRKUNG gemessen: GetEUID() liefert dort die
#     echte EUID des Testlaufs (id -u), nicht -38.
#
#  3. Die lyxos-Haelfte am ERZEUGNIS, nicht am Quelltext: ein lyxos-Programm,
#     das die Weiche nimmt, muss emittieren (die Nummernpruefung sitzt in
#     emit_lyxos und wird von --compile-unit nie erreicht, #2524).
#
#  4. Kein stilles Verwerfen von Argumenten: Umount(target, flags) bildet auf
#     LyxOS auf sys_umount(name) ab, das keine flags kennt. flags != 0 muss
#     deshalb -ENOSYS liefern und nicht stillschweigend ohne MNT_DETACH
#     aushaengen.
#
#  5. sys_power ist zielgebunden: auf lyxos uebersetzbar, auf x86 mit genannter
#     Ursache abgewiesen (die Gegenrichtung, sonst waere eine zu weite
#     Zielliste auch erfuellt).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
LYXC_TIMEOUT="${LYXC_TIMEOUT:-180}"
. "$ROOT/tests/lib/lyxc_guard.sh"   # #1294: Grenze um jeden lyxc-Aufruf
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

UNITS=(std/process_ext.lyx std/fs_ext.lyx std/inotify.lyx std/ipc_sysv.lyx
       std/mmap_ext.lyx std/mqueue.lyx std/net/epoll.lyx std/net/socket.lyx
       std/ns.lyx std/security_ext.lyx std/signals.lyx std/sysadmin.lyx
       std/thread.lyx std/xattr.lyx)

# ── 1. Die 14 Units uebersetzen fuer BEIDE Ziele ───────────────────────────
rotLyxos=""; rotLinux=""
for u in "${UNITS[@]}"; do
  (cd "$ROOT" && "$LYXC" --std-path="$ROOT" --target=lyxos \
      --compile-unit "$u" >"$TMP/u.log" 2>&1) || rotLyxos="$rotLyxos $u"
  (cd "$ROOT" && "$LYXC" --std-path="$ROOT" \
      --compile-unit "$u" >"$TMP/l.log" 2>&1) || rotLinux="$rotLinux $u"
done
[ -z "$rotLyxos" ] && ok "alle ${#UNITS[@]} Units vorkompilieren fuer --target=lyxos" \
                   || no "lyxos-Vorkompilierung" "rot:$rotLyxos"
[ -z "$rotLinux" ] && ok "dieselben ${#UNITS[@]} Units vorkompilieren weiter fuer Linux" \
                   || no "Linux-Vorkompilierung" "rot:$rotLinux"

# ── 2. Linux-Seite an der WIRKUNG: GetEUID liefert die echte EUID ──────────
cat > "$TMP/euid.lyx" <<'LYX'
unit main;
import std.process_ext;
fn main(): int64 { return GetEUID(); }
LYX
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/euid.lyx" \
      -o "$TMP/euid" >"$TMP/e.log" 2>&1); then
  "$TMP/euid"; got=$?
  # Der Rueckgabewert kommt als EXIT-CODE zurueck, und der ist ein Byte:
  # eine UID 1000 erscheint als 232. Erwartet wird deshalb id -u modulo 256
  # (erster Lauf verglich gegen 1000 und war rot -- der Test lag falsch,
  # nicht die Unit).
  want=$(( $(id -u) % 256 ))
  if [ "$got" -eq "$want" ]; then
    ok "Linux-Zweig unberuehrt: GetEUID() == $want (echte EUID mod 256, nicht -ENOSYS)"
  else
    no "Linux-Zweig" "GetEUID() lieferte $got, erwartet $want"
  fi
else
  no "Linux-Zweig" "GetEUID-Programm uebersetzt nicht: $(tail -2 "$TMP/e.log")"
fi

# ── 3. lyxos-Seite am ERZEUGNIS: die Weiche emittiert ──────────────────────
cat > "$TMP/lx.lyx" <<'LYX'
unit main;
import std.process_ext;
import std.xattr;
import std.sysadmin;
fn main(): int64 {
  var a: int64 := GetEUID();
  var b: int64 := XattrList("/x"c, 0, 0);
  var c: int64 := Umount("/mnt"c, 1);
  return a + b + c;
}
LYX
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" --target=lyxos \
      "$TMP/lx.lyx" -o "$TMP/lx.lbf" >"$TMP/x.log" 2>&1) && [ -s "$TMP/lx.lbf" ]; then
  ok "lyxos-Programm mit drei genommenen Weichen emittiert ein LBF"
else
  no "lyxos-Erzeugnis" "$(grep -m1 -iE 'error|unbekannt|wuerde' "$TMP/x.log")"
fi

# ── 4. flags werden NICHT stillschweigend verworfen ────────────────────────
# Gemessen wird am Quelltext der Unit, weil die Wirkung (ein echtes umount)
# nur auf dem Geraet pruefbar ist: die Weiche muss flags != 0 ABWEISEN, statt
# sys_umount ohne MNT_DETACH aufzurufen.
if grep -A6 'pub fn Umount' "$ROOT/std/sysadmin.lyx" | grep -q 'flags != 0'; then
  ok "Umount weist flags != 0 auf lyxos ab (kein stilles Verwerfen)"
else
  no "Umount-flags" "kein 'flags != 0'-Zweig -- MNT_FORCE/MNT_DETACH fielen still weg"
fi

# ── 5. sys_power ist zielgebunden: lyxos ja, x86 mit genannter Ursache nein ─
printf 'unit main;\nfn main(): int64 { return sys_power(0); }\n' > "$TMP/pw.lyx"
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" --target=lyxos \
      "$TMP/pw.lyx" -o "$TMP/pw.lbf" >"$TMP/p1.log" 2>&1); then
  ok "sys_power uebersetzt mit --target=lyxos (Kernelnummer 210)"
else
  no "sys_power lyxos" "$(grep -m1 -iE 'error|unbekannt' "$TMP/p1.log")"
fi
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" \
      "$TMP/pw.lyx" -o "$TMP/pw.out" >"$TMP/p2.log" 2>&1); then
  no "sys_power x86" "uebersetzt auf x86 -- Linux hat den Namen nicht"
elif grep -q 'gibt es nur mit --target=lyxos' "$TMP/p2.log"; then
  ok "sys_power wird auf x86 mit genannter Ursache abgewiesen"
else
  no "sys_power x86" "andere Meldung: $(grep -m1 -iE 'error' "$TMP/p2.log")"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
