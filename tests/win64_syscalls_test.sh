#!/usr/bin/env bash
# tests/win64_syscalls_test.sh — #1678: keine Linux-Syscalls in PE-Dateien.
#
# Ein `syscall`-Befehl in einer PE-Datei ruft auf Windows einen NT-Dienst mit
# ganz anderer Bedeutung auf, und die Argumente stehen in den falschen
# Registern (Windows nimmt r10, nicht rdi). Beim Freigeben hat genau das Wines
# Buchfuehrung ueber die Speicherbereiche zerstoert:
#
#   create_view: Zusicherung »view->protect & VPROT_SYSTEM« nicht erfuellt
#
# Der win64-Ruecken ersetzte `mmap` durch einen VirtualAlloc-Helfer, fuer
# `munmap` gab es keinen Gegenpart — jedes `free` ueber APOOL_MAX war ein
# Schuss ins Blaue.
#
# Geprueft wird auf ZWEI Wegen, weil beide fuer sich zu wenig sagen:
#   * in den BYTES, weil das deterministisch ist und kein Wine braucht,
#   * unter WINE, weil nur der echte Lader zeigt, dass es auch laeuft.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

# Wie viele rohe Syscalls duerfen noch drinstehen und mit welchen Nummern.
# Stand 1.1.5C: drei, alle nachweislich unerreichbar (siehe unten). Die Zahl
# ist eine SCHRANKE, kein Ziel — sie darf nur sinken. Wer sie erhoehen will,
# braucht einen Grund im Ticket.
ERLAUBT=3

zaehle() {   # Datei -> "gesamt|nr:anzahl,..."
  python3 - "$1" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read()
pos = [i for i in range(len(d) - 1) if d[i] == 0x0F and d[i+1] == 0x05]
c = collections.Counter()
for p in pos:
    nr = None
    if p >= 10 and d[p-10] == 0x48 and d[p-9] == 0xB8:
        nr = int.from_bytes(d[p-8:p], 'little')       # movabs rax, imm64
    elif p >= 5 and d[p-5] == 0xB8:
        nr = int.from_bytes(d[p-4:p], 'little')       # mov eax, imm32
    c[nr] += 1
print("%d|%s" % (len(pos), ",".join("%s:%d" % (k, v) for k, v in sorted(c.items(), key=lambda x: (x[0] is None, x[0])))))
PY
}

baue() {     # Name, Quelle -> $TMP/<name>.exe
  printf '%s' "$2" > "$TMP/$1.lyx"
  "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" --target=win64 --format=pe -o "$TMP/$1.exe" >"$TMP/$1.log" 2>&1
}

# ---------------------------------------------------------------- Programme
# Drei Formen, weil sie unterschiedliche Emissionswege nehmen: die
# Speicherverwaltung der stdlib, der direkte Aufruf und das Array-Wachstum
# (letzteres laedt die Nummer in der KURZFORM `mov eax, 9`, an der der
# Ersetzer bis 1.1.5B vorbeiging).
P_ALLOC='import std.io;
import std.alloc;
fn main(): int64 {
  var i: int64 := 0;
  while (i < 300) { var p: int64 := alloc(1048576); poke64(p, i); free(p, 1048576); i := i + 1; }
  PrintLn("alloc-frei-durch");
  return 0;
}'
P_DIREKT='import std.io;
import std.alloc;
fn main(): int64 {
  var i: int64 := 0;
  while (i < 200) {
    var p: int64 := mmap(0, 1048576, 3, 34, -1, 0);
    poke64(p, i);
    munmap(p, 1048576);
    i := i + 1;
  }
  PrintLn("mmap-munmap-durch");
  return 0;
}'
P_ARRAY='import std.io;
fn main(): int64 {
  var a: int64[];
  var i: int64 := 0;
  while (i < 200) { a.push(i * 3); i := i + 1; }
  PrintLn("a199=" + IntToStr(a[199]));
  return 0;
}'

for fall in "alloc:$P_ALLOC" "direkt:$P_DIREKT" "array:$P_ARRAY"; do
  name="${fall%%:*}"; src="${fall#*:}"
  if ! baue "$name" "$src"; then
    no "$name uebersetzt" "$(grep -iE 'error' "$TMP/$name.log" | head -1)"
    continue
  fi
  ok "$name uebersetzt"

  erg=$(zaehle "$TMP/$name.exe")
  n="${erg%%|*}"; verteilung="${erg#*|}"

  if [ "$n" -le "$ERLAUBT" ]; then
    ok "$name: $n rohe Syscalls (Schranke $ERLAUBT) [$verteilung]"
  else
    no "$name: $n rohe Syscalls, erlaubt sind $ERLAUBT" "$verteilung"
  fi

  # Die beiden Nummern, um die es in #1678 geht, muessen VERSCHWUNDEN sein.
  # Die Gesamtzahl allein genuegt nicht: sie koennte stimmen, waehrend
  # ausgerechnet mmap oder munmap noch drinsteht.
  for nr in 9 11; do
    if echo "$verteilung" | grep -qE "(^|,)$nr:"; then
      no "$name: Syscall $nr steht noch im Code" "$verteilung"
    else
      ok "$name: kein Syscall $nr mehr"
    fi
  done
done

# ---------------------------------------------------------------- Wine
# Die Bytes koennen sauber sein und das Ergebnis trotzdem falsch — der Helfer
# muss auch das Richtige tun. 300 Zyklen zu 1 MB laufen nur durch, wenn der
# Speicher wirklich zurueckgegeben wird.
if command -v wine >/dev/null 2>&1; then
  for fall in "alloc:alloc-frei-durch" "direkt:mmap-munmap-durch" "array:a199=597"; do
    name="${fall%%:*}"; erwartet="${fall#*:}"
    [ -f "$TMP/$name.exe" ] || continue
    aus=$(cd "$TMP" && WINEDEBUG=-all timeout 300 wine "$name.exe" 2>"$TMP/$name.err" | tail -1)
    if [ "$aus" = "$erwartet" ]; then
      ok "wine: $name laeuft durch"
    else
      no "wine: $name laeuft durch" "erhalten '$aus'; $(grep -m1 -iE 'assert|Zusicherung|exception' "$TMP/$name.err")"
    fi
  done
else
  echo "SKIP wine nicht vorhanden"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
