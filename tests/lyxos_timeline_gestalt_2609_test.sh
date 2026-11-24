#!/usr/bin/env bash
# tests/lyxos_timeline_gestalt_2609_test.sh — hat sys_timeline_query die
# Gestalt des KERNELS? (#2609)
#
# BEFUND. Das lyxos-Backend fuehrte die sechsstellige Form
# sys_timeline_query(from, to, filter_vec, dim, results, max) aus der
# Entwurfsfamilie um die semantische Ablage. Der gebaute Kernel kennt dort
# keine Vektorsuche: ring3.lyx:3103 und :7211 lesen VIER Werte und rufen
# GraphTimelineQuery(a0, a1, tl_phys, a3); doku/syscalls_ist.md sagt dasselbe
# (t_start, t_end, out_uva, out_max). Der Rumpf ist die ABI, nicht der
# Kommentar.
#
# Wer die Zahl nur auf 4 setzt, ohne die BEDEUTUNG mitzuziehen, uebergibt
# filter_vec als out_uva -- der Kernel schlaegt das auf eine Benutzeradresse um
# und schreibt in den Filtervektor. Darum wird hier beides geprueft: dass die
# richtige Form durchgeht UND dass jede andere Zahl laut scheitert.
#
# GEMESSEN WIRD AM ERZEUGNIS, nicht an der Quelle: zwischen dem Laden der
# Nummer (0x090B) und dem `syscall` muessen genau VIER Argumentregister
# gefuellt werden. Eine Tabelle, die 4 sagt, ist keine Aussage darueber, was
# emittiert wird (#1789).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

bau() { # argumentliste -> rc in $RC, Ausgabe in $TMP/log
  printf 'unit main;\nfn main(): int64 { return sys_timeline_query(%s); }\n' "$1" > "$TMP/t.lyx"
  rm -f "$TMP/t.lbf"
  "$LYXC" --std-path=. --target=lyxos "$TMP/t.lyx" -o "$TMP/t.lbf" > "$TMP/log" 2>&1
  RC=$?
}

# ── 1. Die Kernelform uebersetzt ────────────────────────────────────────────
echo "--- vier Argumente (Kernelform) ---"
bau "0,0,0,0"
if [ "$RC" = 0 ] && [ -s "$TMP/t.lbf" ]; then
  pr ok "vier Argumente uebersetzen zu einem LBF"
else
  pr fail "vier Argumente scheitern (rc=$RC): $(head -3 "$TMP/log" | tr '\n' ' ')"
fi

# ── 2. Vier Ladungen im Erzeugnis ───────────────────────────────────────────
if [ ! -s "$TMP/t.lbf" ]; then
  echo "    (uebersprungen: kein Erzeugnis)"
elif ! command -v objdump >/dev/null 2>&1; then
  echo "    (SKIP: objdump fehlt)"
else
  # -z, sonst kuerzt objdump lange Nullfolgen ab und disassembliert den Rest
  # gar nicht; --no-show-raw-insn, sonst zaehlen Byte-Folgezeilen langer
  # Befehle als eigene Befehle (#1370). Ein LBF hat keine Sektionen, darum
  # -D -b binary.
  objdump -D -b binary -m i386:x86-64 -z --no-show-raw-insn "$TMP/t.lbf" 2>/dev/null > "$TMP/dis.txt"
  # Fenster: vom Laden der Nummer bis zum naechsten syscall.
  awk '/movabs \$0x90b,%rax/ { drin = 1 } drin { print } drin && /syscall/ { exit }' \
      "$TMP/dis.txt" > "$TMP/fenster.txt"
  if [ ! -s "$TMP/fenster.txt" ]; then
    pr fail "0x090B wird im Erzeugnis nicht geladen -- emittiert das Backend die Nummer ueberhaupt?"
  else
    LADUNGEN=$(grep -cE 'mov +-0x[0-9a-f]+\(%rbp\),%(rdi|rsi|rdx|r10|r8|r9)$' "$TMP/fenster.txt")
    if [ "$LADUNGEN" = 4 ]; then
      pr ok "genau vier Argumentregister werden gefuellt (rdi, rsi, rdx, r10)"
    else
      pr fail "$LADUNGEN Argumentladungen vor dem syscall, erwartet 4"
      sed 's/^/      /' "$TMP/fenster.txt"
    fi
  fi
fi

# ── 3./4. Jede andere Zahl scheitert LAUT ───────────────────────────────────
# Beide Seiten: zu viele UND zu wenige. Ein Test, der nur die alte
# sechsstellige Form abweist, waere auch von einer Fassung erfuellt, die
# stillschweigend die ersten vier nimmt und den Rest fallen laesst.
echo "--- jede andere Argumentzahl scheitert laut ---"
for n in "0,0,0,0,0,0" "0,0,0" "0,0,0,0,0"; do
  bau "$n"
  anz=$(printf '%s' "$n" | tr -cd ',' | wc -c); anz=$((anz+1))
  if [ "$RC" = 0 ]; then
    pr fail "$anz Argumente uebersetzen stillschweigend"
  elif grep -q "sys_timeline_query erwartet auf LyxOS genau 4 Argument" "$TMP/log"; then
    pr ok "$anz Argumente scheitern mit der benannten Begruendung"
  else
    pr fail "$anz Argumente scheitern, aber ohne benannte Begruendung: $(head -2 "$TMP/log" | tr '\n' ' ')"
  fi
  [ -s "$TMP/t.lbf" ] && pr fail "$anz Argumente hinterlassen trotzdem ein Erzeugnis"
done

# ── 5. Die Zahl steht an beiden Stellen gleich ──────────────────────────────
echo "--- Backend und abgelegter Kernelstand nennen dieselbe Zahl ---"
EMIT_AC=$(grep -oE 'id == 139 \{ lx17ac := [0-9]+' src/backend/lyxos/emit_lyxos.lyx | grep -oE '[0-9]+$')
STAND_AC=$(grep -P '^2315\t' work/lyxos/syscall-argc.txt | cut -f3)
if [ "$EMIT_AC" = "4" ] && [ "$STAND_AC" = "4" ]; then
  pr ok "emit_lyxos (lx17ac=$EMIT_AC) und work/lyxos/syscall-argc.txt ($STAND_AC) stimmen"
else
  pr fail "emit_lyxos sagt '$EMIT_AC', der Stand sagt '$STAND_AC'"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
