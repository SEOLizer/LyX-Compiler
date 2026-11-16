#!/usr/bin/env bash
# tests/win64_syscall_abweisen_2519_test.sh — #2519: win64 weist rohe
# Linux-Syscalls AB, statt sie still ins PE zu uebernehmen.
#
# BEFUND. Ein Linux-Syscall uebersetzte fuer --target=win64 und landete als
# `0F 05` im PE. Windows hat keine Linux-Syscall-ABI; der Befehl trifft dort
# einen fremden NT-Dienst. arm64, riscv und lyxos weisen denselben Aufruf
# benannt ab (src/ir_lower.lyx) -- nur der x86-Weg, ueber den win64 laeuft,
# nahm ihn mit. Es gab eine Pruefung (wxb_pruefeSyscalls), aber sie ZAEHLTE
# bloss und warnte: "57 rohe Linux-Syscalls" ist keine Handlungsanweisung, und
# das Erzeugnis entstand trotzdem.
#
# GEMESSEN beim Beheben, und das hat den Entwurf bestimmt: von 166 sys_-Namen
# des x86-Wegs lassen 159 einen rohen Syscall durch; nur SIEBEN sind auf Win32
# umgeleitet (write, read, open, close, lseek, seek, exit_group -- dazu mmap
# und munmap, die keine sys_-Namen sind). Eine Sperre auf das `sys_`-Praefix
# haette also die sieben mitgerissen; die Sperre gehoert an die EMISSION, wo
# die Umgeleiteten nie ankommen.
#
# WARUM ES EINE NACHSICHT GIBT. `lyxc` selbst laesst fuer win64 62 Syscalls
# stehen (stat, fork, execve, wait4, getdents64, clock_gettime, getrandom ...).
# Ein harter Fehler ohne Ausweg haette `make dist-win64` unmoeglich gemacht --
# ein Fehler, der das Bauen des Compilers verhindert, ist keine Verbesserung.
# `--win64-syscalls=warnen` ist deshalb Buchfuehrung ueber eine offene Luecke,
# nicht deren Abschwaechung: wer ihn setzt, bekommt die NUMMERN und weiss, was
# auf dem Geraet fehlschlaegt.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

bau() {   # <datei> <zusatzschalter...> -> Ausgabe in $TMP/m.log, Erzeugnis $TMP/o.exe
  rm -f "$TMP/o.exe"
  ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" --target=win64 "$@" \
      "$TMP/$1" -o "$TMP/o.exe" ) >"$TMP/m.log" 2>&1
}

echo "--- 1. Vorgabe: ein roher Syscall wird ABGEWIESEN und die Nummer genannt ---"
printf 'unit main;\nfn main(): int64 { var a: int64 := sys_socket(0,0,0); return a + sys_getpid(); }\n' > "$TMP/a.lyx"
rm -f "$TMP/o.exe"
( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" --target=win64 "$TMP/a.lyx" -o "$TMP/o.exe" ) >"$TMP/m.log" 2>&1
if [ -s "$TMP/o.exe" ]; then
  pr no "ein PE mit rohem Syscall entstand trotzdem"
else
  pr ok "kein Erzeugnis bei rohem Syscall"
fi
# Die Meldung muss die NUMMERN nennen, nicht bloss zaehlen -- das war der Kern
# des Befunds. 41 = socket, 39 = getpid.
if grep -qE "^error: win64: .* rohe Linux-Syscalls" "$TMP/m.log"; then
  pr ok "meldet als Fehler, nicht als Warnung"
else
  pr no "keine Fehlermeldung: $(grep -m1 -iE 'error|warning' "$TMP/m.log" | cut -c1-70)"
fi
if grep -qE "Nummern:.*\b41\b" "$TMP/m.log" && grep -qE "Nummern:.*\b39\b" "$TMP/m.log"; then
  pr ok "nennt die Nummern (41 socket, 39 getpid)"
else
  pr no "Nummern fehlen in der Meldung: $(grep -m1 'Nummern' "$TMP/m.log" | cut -c1-70)"
fi

echo "--- 2. Mit --win64-syscalls=warnen entsteht das PE, mit Nummernliste ---"
rm -f "$TMP/o.exe"
( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" --target=win64 --win64-syscalls=warnen \
    "$TMP/a.lyx" -o "$TMP/o.exe" ) >"$TMP/w.log" 2>&1
[ -s "$TMP/o.exe" ] && pr ok "mit Nachsicht entsteht ein Erzeugnis" || pr no "auch mit Nachsicht kein Erzeugnis"
grep -qE "^warning: win64: .* rohe Linux-Syscalls" "$TMP/w.log" \
  && pr ok "mit Nachsicht ist es eine Warnung" || pr no "keine Warnung mit Nachsicht"

echo "--- 3. Die SIEBEN umgeleiteten Namen gehen OHNE Nachsicht ---"
# Gegenprobe zur Praefixfalle: eine Sperre auf `sys_` haette genau die hier
# mitgerissen. Sie erreichen die Emission nie, weil wxb_replaceSyscallNr sie
# vorher ersetzt (Nummern 0, 1, 2, 3, 8, 231 und mmap/munmap 9/11).
umgeleitet=0; gebrochen=0
for n in sys_write sys_read sys_open sys_close sys_lseek sys_seek sys_exit_group; do
  printf 'unit main;\nfn main(): int64 { return %s(0,0,0); }\n' "$n" > "$TMP/u.lyx"
  rm -f "$TMP/o.exe"
  ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" --target=win64 \
      "$TMP/u.lyx" -o "$TMP/o.exe" ) >/dev/null 2>&1
  if [ -s "$TMP/o.exe" ]; then umgeleitet=$((umgeleitet+1)); else gebrochen=$((gebrochen+1)); echo "    gebrochen: $n"; fi
done
[ "$gebrochen" -eq 0 ] && pr ok "alle sieben umgeleiteten Namen uebersetzen weiter ($umgeleitet/7)" \
  || pr no "$gebrochen der sieben umgeleiteten Namen werden jetzt abgewiesen"

echo "--- 4. Ein gewoehnliches Programm bleibt unberuehrt ---"
printf 'unit main;\nimport src.std.io;\nfn main(): int64 { PrintLn("hi"); return 0; }\n' > "$TMP/n.lyx"
rm -f "$TMP/o.exe"
( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" --target=win64 \
    "$TMP/n.lyx" -o "$TMP/o.exe" ) >"$TMP/n.log" 2>&1
if [ -s "$TMP/o.exe" ] && ! grep -qE "rohe Linux-Syscalls" "$TMP/n.log"; then
  pr ok "std.io-Programm uebersetzt ohne Meldung"
else
  pr no "std.io-Programm betroffen: $(grep -m1 -iE 'error|warning' "$TMP/n.log" | cut -c1-70)"
fi

echo "--- 5. Ein unbekannter Wert des Schalters scheitert laut ---"
rm -f "$TMP/o.exe"
( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" --target=win64 --win64-syscalls=quatsch \
    "$TMP/n.lyx" -o "$TMP/o.exe" ) >"$TMP/q.log" 2>&1
if [ ! -s "$TMP/o.exe" ] && grep -qE "unbekannter Wert" "$TMP/q.log"; then
  pr ok "--win64-syscalls=quatsch wird benannt abgewiesen"
else
  pr no "unbekannter Wert ging durch"
fi

echo "--- 6. Compiler und Test zaehlen GLEICH (derselbe Verschiebungsfilter) ---"
# #2324: `0F 05` im Bytestrom ist nicht zwingend ein Befehl -- es kann in der
# Weite eines E8/E9/0F-8x-Sprungs liegen. Diese Unterscheidung steht in
# tests/win64_syscalls_test.sh und ist in wxb_pruefeSyscalls nachgezogen.
# Weichen die beiden ab, weist der Compiler entweder grundlos ab oder laesst
# etwas durch -- beides faellt hier auf.
rm -f "$TMP/o.exe"
( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" --target=win64 --win64-syscalls=warnen \
    "$TMP/a.lyx" -o "$TMP/o.exe" ) >"$TMP/v.log" 2>&1
c_compiler="$(grep -oE '^warning: win64: [0-9]+' "$TMP/v.log" | grep -oE '[0-9]+$')"
if [ -s "$TMP/o.exe" ] && [ -n "$c_compiler" ]; then
  c_test="$(python3 - "$TMP/o.exe" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read()
pos = [i for i in range(len(d)-1) if d[i] == 0x0F and d[i+1] == 0x05]
def in_verschiebung(p):
    for k in (1, 2, 3):
        a = p - k
        if a >= 0 and d[a] in (0xE8, 0xE9): return True
        if a >= 1 and d[a-1] == 0x0F and 0x80 <= d[a] <= 0x8F: return True
    return False
c = collections.Counter()
for p in pos:
    nr = None
    if p >= 10 and d[p-10] == 0x48 and d[p-9] == 0xB8: nr = int.from_bytes(d[p-8:p], 'little')
    elif p >= 5 and d[p-5] == 0xB8: nr = int.from_bytes(d[p-4:p], 'little')
    elif in_verschiebung(p): continue
    c[nr] += 1
print(sum(c.values()))
PY
)"
  if [ "$c_compiler" = "$c_test" ]; then
    pr ok "beide zaehlen $c_compiler Syscalls im selben PE"
  else
    pr no "Compiler zaehlt $c_compiler, die Testlogik $c_test -- die Filter laufen auseinander"
  fi
else
  pr no "Vergleich nicht moeglich (kein Erzeugnis oder keine Zahl in der Meldung)"
fi

echo
echo "win64_syscall_abweisen_2519_test: PASS=$PASS FAIL=$FAIL"
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
