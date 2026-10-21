#!/usr/bin/env bash
# tests/symlink_builtins_test.sh — #2156: Pfad-Metadaten als Builtins.
#
# Bis 1.2.16D:
#   * x86: `sys_readlink` kannte sema, der Codegen nicht ("no codegen
#     implementation found"); `sys_lstat`, `sys_readlinkat` und
#     `sys_newfstatat` kannte niemand.
#   * arm64/riscv: auch stat/lstat/readlink/symlink/sys_stat/sys_fstat
#     meldeten "Builtin-ID … wird im Linux-Zweig nicht behandelt" — die
#     Zweige waren LyxOS-Aufrufe. Die generische Linux-ABI hat nur die
#     *at-Formen; ir_lower setzt AT_FDCWD (und fuer lstat
#     AT_SYMLINK_NOFOLLOW) ein (linux_syscalls.lyx, IDs 547-550).
#
# Gemessen an einem echten Symlink, auf x86_64, arm64 und riscv: die Laenge
# und der Text des Ziels, -EINVAL fuer eine gewoehnliche Datei, -ENOENT fuer
# einen fehlenden Pfad, und der DATEITYP aus dem stat-Puffer — lstat sieht
# den Link (10), stat folgt ihm (8). Ein Ergebnis "0" allein haette auch ein
# stat ohne NOFOLLOW bestanden.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

mkdir -p "$TMP/d"
echo hallo > "$TMP/d/ziel.txt"
ln -s ziel.txt "$TMP/d/link"

lauf() {
  case "$1" in
    linux) ( cd "$TMP/d" && timeout 30 "$2" ) ;;
    arm64) ( cd "$TMP/d" && timeout 30 "$QEMU_ARM64" "$2" ) ;;
    riscv) ( cd "$TMP/d" && timeout 30 "$QEMU_RISCV64" "$2" ) ;;
  esac
}
pruefe() {  # name datei soll
  local t
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$2" -o "$TMP/p" ) >"$TMP/p.log" 2>&1; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/p.log"))"; continue
    fi
    local aus
    aus="$(lauf $t "$TMP/p" 2>&1 | tr '\n' '|')"
    if [ "$aus" = "$3" ]; then ok "$1 [$t]: [$aus]"; else nok "$1 [$t]: [$aus] statt [$3]"; fi
  done
}

cat > "$TMP/rl.lyx" <<'LYX'
import std.alloc;
fn main(): int64 {
  var buf: int64 := alloc(256);
  var n: int64 := sys_readlink("link", buf, 255);
  poke8(buf + n, 0);
  Print("readlink=", n, " "); PrintStr(buf as pchar); Print("|");
  // Ergebnisse ueber Variablen: Print bestimmt den Typ eines Builtin-Aufrufs
  // auf dem IR-Weg nicht (laut, eigener Punkt) — hier geht es um den Aufruf.
  var n2: int64 := sys_readlink("ziel.txt", buf, 255);
  var n3: int64 := sys_readlinkat(0 - 100, "link", buf, 255);
  var n4: int64 := readlink("link", buf, 255);
  var n5: int64 := sys_readlink("gibtsnicht", buf, 255);
  Print("datei=", n2, "|at=", n3, "|alt=", n4, "|fehlt=", n5, "\n");
  return 0;
}
LYX
pruefe "readlink/readlinkat" "$TMP/rl.lyx" "readlink=8 ziel.txt|datei=-22|at=8|alt=8|fehlt=-2|"

cat > "$TMP/st.lyx" <<'LYX'
import std.alloc;
// Dateityp aus st_mode: x86-64 legt es bei +24 ab, die generische ABI
// (arm64, riscv) bei +16.
fn art(st: int64): int64 {
  var off: int64 := 16;
  if (TARGET_ARCH == ARCH_X86_64) { off := 24; }
  return (peek32(st + off) >> 12) & 15;
}
fn main(): int64 {
  var st: int64 := alloc(256);
  var r1: int64 := sys_lstat("link", st);   Print(r1, ":", art(st), " ");
  var r2: int64 := sys_stat("link", st);    Print(r2, ":", art(st), " ");
  var r3: int64 := lstat("link", st);       Print(r3, ":", art(st), " ");
  var r4: int64 := stat("link", st);        Print(r4, ":", art(st), " ");
  var r5: int64 := sys_newfstatat(0 - 100, "link", st, 256); Print(r5, ":", art(st), " ");
  var r6: int64 := sys_newfstatat(0 - 100, "link", st, 0);   Print(r6, ":", art(st), " ");
  var r7: int64 := sys_lstat("gibtsnicht", st);
  Print("fehlt=", r7, "\n");
  return 0;
}
LYX
pruefe "lstat folgt dem Link nicht, stat schon" "$TMP/st.lyx" "0:10 0:8 0:10 0:8 0:10 0:8 fehlt=-2|"

cat > "$TMP/sym.lyx" <<'LYX'
import std.alloc;
fn main(): int64 {
  var buf: int64 := alloc(256);
  var r: int64 := symlink("ziel.txt", "neu");
  var n: int64 := readlink("neu", buf, 255);
  poke8(buf + n, 0);
  Print(r, " ", n, " "); PrintStr(buf as pchar); Print("\n");
  return 0;
}
LYX
# symlink legt eine Datei an — je Ziel einzeln messen und aufraeumen.
for t in linux arm64 riscv; do
  rm -f "$TMP/d/neu" "$TMP/p"
  if ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$TMP/sym.lyx" -o "$TMP/p" ) >"$TMP/p.log" 2>&1; then
    aus="$(lauf $t "$TMP/p" 2>&1 | tr '\n' '|')"
    if [ "$aus" = "0 8 ziel.txt|" ]; then ok "symlink [$t]: [$aus]"; else nok "symlink [$t]: [$aus]"; fi
  else nok "symlink [$t]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/p.log"))"; fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
