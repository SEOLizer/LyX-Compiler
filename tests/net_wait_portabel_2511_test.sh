#!/bin/bash
# #2511 / #2512: Die stdlib wartet portabel, und der x86-eigene Rest steht
# getrennt.
#
# `select` gibt es in der generischen Linux-ABI NICHT -- arm64 und riscv
# kennen nur `pselect6` (Nr. 72) mit einem sechsten Argument. Drei Units
# riefen `sys_select` und waren deshalb fuer diese Ziele nicht
# vorkompilierbar; `std/security_ext.lyx` rief `sys_arch_prctl`, das x86-eigen
# ist, und riss die ganze Unit mit.
#
# GEPRUEFT WIRD DIE WIRKUNG, nicht "uebersetzt": ein Aufruf, der sofort
# zurueckkehrt, wuerde jede Uebersetzungspruefung erfuellen und trotzdem
# nicht warten. Gemessen werden daher drei Zustaende -- leer, mit Daten, und
# eine Zeitgrenze, die wirklich verstreicht -- und zwar auf allen drei
# Architekturen.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
. "$ROOT/tests/lib/qemu.sh"   # #2048: Emulatornamen an EINER Stelle
ulimit -c 0 2>/dev/null   # geplante Abbrueche schreiben keinen Speicherabzug
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }

cat > "$TMP/w.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
import std.net.wait;
fn main(): int64 {
    var fds: int64 := alloc(16);
    if (sys_pipe(fds) < 0) { PrintLn("pipe fehlt"); return 9; }
    var rfd: int64 := peek32(fds) & 0xFFFFFFFF;
    var wfd: int64 := peek32(fds + 4) & 0xFFFFFFFF;
    var set: int64 := alloc(128);
    var i: int64 := 0;
    while (i < 128) { poke8(set + i, 0); i := i + 1; }
    poke8(set + (rfd / 8), 1 << (rfd - (rfd / 8) * 8));
    var tv: int64 := alloc(16); poke64(tv, 0); poke64(tv + 8, 0);
    PrintStr("leer="); PrintInt(SelectTimeval(rfd + 1, set, 0, 0, tv)); PrintLn("");
    var buf: int64 := alloc(8); poke8(buf, 88);
    sys_write(wfd, buf as pchar, 1);
    i := 0; while (i < 128) { poke8(set + i, 0); i := i + 1; }
    poke8(set + (rfd / 8), 1 << (rfd - (rfd / 8) * 8));
    PrintStr("daten="); PrintInt(SelectTimeval(rfd + 1, set, 0, 0, tv)); PrintLn("");
    sys_read(rfd, buf as pchar, 1);
    i := 0; while (i < 128) { poke8(set + i, 0); i := i + 1; }
    poke8(set + (rfd / 8), 1 << (rfd - (rfd / 8) * 8));
    poke64(tv, 0); poke64(tv + 8, 300000);
    PrintStr("wartend="); PrintInt(SelectTimeval(rfd + 1, set, 0, 0, tv)); PrintLn("");
    return 0;
}
EOF

pruefe() { # $1 = Beschriftung, $2 = Starter (leer = direkt), $3.. = lyxc-Schalter
  local name="$1"; local starter="$2"; shift 2
  local bin="$TMP/w_$name"
  if ! timeout 300 "$LYXC" --std-path="$ROOT" "$@" "$TMP/w.lyx" -o "$bin" >"$TMP/$name.log" 2>&1; then
    bad "$name: uebersetzt" "$(grep -m1 -E 'error|gibt es' "$TMP/$name.log")"
    bad "$name: Wirkung" "kein Erzeugnis"; return
  fi
  ok "$name: uebersetzt"
  local t0 t1 aus
  t0=$(date +%s%N)
  if [ -n "$starter" ]; then aus=$($starter "$bin" 2>&1); else aus=$("$bin" 2>&1); fi
  t1=$(date +%s%N)
  local ms=$(( (t1 - t0) / 1000000 ))
  if [ "$(echo "$aus" | grep -c '^leer=0$')" = 1 ] &&
     [ "$(echo "$aus" | grep -c '^daten=1$')" = 1 ] &&
     [ "$(echo "$aus" | grep -c '^wartend=0$')" = 1 ] && [ "$ms" -ge 250 ]; then
    ok "$name: leer=0, daten=1, Zeitgrenze verstrichen (${ms} ms >= 250)"
  else
    bad "$name: Wirkung" "Ausgabe '$(echo "$aus" | tr '\n' ' ')' nach ${ms} ms"
  fi
}

pruefe host ""
if [ -n "$QEMU_ARM64" ]; then
  pruefe arm64 "$QEMU_ARM64 -L /usr/aarch64-linux-gnu" --target=arm64
else
  echo "HINWEIS: kein arm64-Emulator -- die Wirkung ist hier nicht messbar"
fi
if [ -n "$QEMU_RISCV64" ]; then
  pruefe riscv "$QEMU_RISCV64 -L /usr/riscv64-linux-gnu" --target=riscv
else
  echo "HINWEIS: kein riscv64-Emulator -- die Wirkung ist hier nicht messbar"
fi

# Die vier Units, die es blockierten, muessen fuer beide Ziele uebersetzen.
for u in std/db/postgres.lyx std/net/ssh.lyx std/net/syscalls.lyx std/security_ext.lyx; do
  alle=1
  for t in arm64 riscv; do
    timeout 600 "$LYXC" --std-path="$ROOT" --target=$t --compile-unit "$u" -o "$TMP/u.lyu" >"$TMP/u.log" 2>&1 || alle=0
  done
  if [ "$alle" = 1 ]; then ok "$u ist zielweise vorkompilierbar (arm64 + riscv)"
  else bad "$u" "$(grep -m1 -E 'gibt es|error' "$TMP/u.log")"; fi
done

# Gegenprobe, zweiseitig: `sys_select` und `sys_arch_prctl` muessen auf diesen
# Zielen WEITER laut abgewiesen werden. Ohne diese Haelfte waere der Test auch
# von einem Compiler erfuellt, der beides still auf irgendeine Nummer abbildet
# -- und genau das ist die Fehlfunktion, die die Meldung verhindert.
cat > "$TMP/s.lyx" <<'EOF'
unit main;
fn main(): int64 { return sys_select(0, 0, 0, 0, 0); }
EOF
if timeout 300 "$LYXC" --std-path="$ROOT" --target=arm64 "$TMP/s.lyx" -o "$TMP/s" >"$TMP/s.log" 2>&1; then
  bad "Gegenprobe select" "arm64 hat sys_select still uebersetzt"
else
  grep -q "sys_select gibt es auf diesem Ziel nicht" "$TMP/s.log" \
    && ok "sys_select wird auf arm64 weiter benannt abgewiesen" \
    || bad "Gegenprobe select" "abgewiesen, aber ohne die benannte Meldung"
fi
if timeout 300 "$LYXC" --std-path="$ROOT" --target=arm64 --compile-unit std/security_ext_x86.lyx -o "$TMP/x.lyu" >"$TMP/x.log" 2>&1; then
  bad "Gegenprobe arch_prctl" "security_ext_x86 ist auf arm64 still durchgegangen"
else
  grep -q "sys_arch_prctl gibt es auf diesem Ziel nicht" "$TMP/x.log" \
    && ok "die x86-eigene Unit wird auf arm64 benannt abgewiesen" \
    || bad "Gegenprobe arch_prctl" "abgewiesen, aber ohne die benannte Meldung"
fi

# #2511: pselect6 muss hinter derselben Capability liegen wie select
# (io.wait). Ohne die Freigabe in seccomp_gen faellt jedes gehaertete
# Programm beim ersten Warten in SIGSYS -- und zwar erst zur Laufzeit, auf
# dem Geraet. Gemessen wird die WIRKUNG: das Programm wartet und kehrt
# zurueck, statt getoetet zu werden.
cat > "$TMP/c.lyx" <<'EOF'
@capabilities([io.wait])
unit main;
import std.io;
import std.alloc;
import std.net.wait;
fn main(): int64 {
    // Null Deskriptoren, nur die Zeitgrenze: das ist ein reines Warten und
    // braucht AUSSER pselect6 keinen weiteren Syscall. Eine Probe mit Pipe
    // waere an `pipe` gescheitert -- und haette dann nicht mehr gemessen,
    // was sie messen soll (so herum erst gemessen: SIGSYS mit
    // si_syscall=__NR_pipe, nicht pselect6).
    var tv: int64 := alloc(16); poke64(tv, 0); poke64(tv + 8, 200000);
    PrintStr("ergebnis="); PrintInt(SelectTimeval(0, 0, 0, 0, tv)); PrintLn("");
    return 0;
}
EOF
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >"$TMP/c.log" 2>&1 && [ -x "$TMP/c" ]; then
  t0=$(date +%s%N); aus="$("$TMP/c" 2>&1)"; rc=$?; t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  if [ "$rc" = 0 ] && [ "$(echo "$aus" | grep -c '^ergebnis=0$')" = 1 ] && [ "$ms" -ge 150 ]; then
    ok "unter @capabilities([io.wait]) wartet pselect6 ${ms} ms und kehrt zurueck (kein SIGSYS)"
  else
    bad "io.wait" "rc=$rc, Ausgabe '$(echo "$aus" | tr '\n' ' ')' nach ${ms} ms (rc 159 = SIGSYS: Freigabe fehlt)"
  fi
else
  bad "io.wait" "$(grep -m1 -E 'error' "$TMP/c.log")"
fi

# Zweite Haelfte: OHNE io.wait muss dasselbe Warten scheitern. Ein Test, der
# nur belegt, dass das Recht den Aufruf freigibt, waere auch von einer
# pauschalen Freigabe erfuellt -- und dann sagt @capabilities nichts mehr.
sed 's/@capabilities(\[io.wait\])/@capabilities([system.exit])/' "$TMP/c.lyx" > "$TMP/d.lyx"
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/d.lyx" -o "$TMP/d" >"$TMP/d.log" 2>&1 && [ -x "$TMP/d" ]; then
  # Eigene Shell und ulimit -c 0: der Lauf endet planmaessig mit SIGSYS --
  # ohne das schreibt er einen Speicherabzug (ins Arbeitsverzeichnis) und die
  # aufrufende Shell meldet den Abbruch auf stderr.
  # Die MELDENDE Shell schreibt den Abbruch nach stderr, nicht der Lauf
  # selbst -- deshalb die Klammer mit eigener Umleitung. Sonst sieht ein
  # planmaessiges SIGSYS im Protokoll wie ein Fehlschlag aus.
  # Den Rueckgabewert ueber die AUSGABE der inneren Shell holen: ein
  # planmaessiges SIGSYS meldet sonst die aufrufende Shell auf ihr eigenes
  # stderr, und im Protokoll sieht das wie ein Fehlschlag aus.
  rc=$(bash -c 'ulimit -c 0; "$1" >/dev/null 2>&1; echo $?' _ "$TMP/d" 2>/dev/null)
  if [ "$rc" = 0 ]; then
    bad "Gegenprobe io.wait" "lief OHNE das Recht durch -- die Freigabe ist pauschal"
  else
    ok "ohne io.wait scheitert dasselbe Warten (rc=$rc)"
  fi
else
  bad "Gegenprobe io.wait" "$(grep -m1 -E 'error' "$TMP/d.log")"
fi

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "OK: portables Warten, x86-Teil getrennt (#2511, #2512)"
