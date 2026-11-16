#!/usr/bin/env bash
# tests/lyxos_dienste_2544_test.sh — Hintergrunddienste auf lyxos (#2544) und
# die Graph-Stelligkeit (#2529).
#
# Drei Befunde, ein Tanz:
#
# 1. #2544: `nanosleep` zeigte auf sleep_ticks (25) statt auf sys_nanosleep
#    (358). Damit war die Zusage des Aufrufs dreifach gebrochen: es wurde ZU
#    KURZ geschlafen (sleep_ticks setzt die Weckmarke auf CD_TICK_COUNT +
#    ticks, der laufende Tick ist schon angebrochen -- gemessen 297 ms fuer
#    300 ms), `rem` wurde nie geschrieben, und die Rueckgabe war immer 0, auch
#    bei unlesbarer Adresse. Fuer einen Dienst ist das erste der Knackpunkt:
#    wer darauf eine Warteschleife baut, bekommt die Schleife ohne Pause.
#
# 2. #2544: fuer sys_sig_post (359) und sys_sig_poll (360) gab es keine
#    Builtins -- die Grundlage fuer Steuercodes zwischen Straengen fehlte.
#
# 3. #2529: der Emitter verdrahtete fuer sys_graph_edge_add (2064) und
#    sys_graph_query (2066) je FUENF Argumente. Der Kernel nimmt vier, und bei
#    2066 gibt es das von uns geglaubte `rel_type` gar nicht -- es waere als
#    `depth` gelesen worden. Die Gestaltpruefung (#2482) wies beide ab.
#
# GEPRUEFT WIRD AM ERZEUGNIS: die Syscallnummer als Bytefolge
# `48 B8 <nr als imm64>` (mov rax, nr), dazu die geladenen Argumentregister
# DAHINTER -- emitVfsSyscall legt erst die Nummer, dann die Argumente.
# „Uebersetzt" genuegt nicht: #1789 ist der Fall, wo ein Opcode in der Liste
# stand und der Rumpf trotzdem falsch war.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

bau() {  # name, rumpf -> $TMP/<name>.lbf
  printf 'unit main;\n%s\n' "$2" > "$TMP/$1.lyx"
  ( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/$1.lyx" -o "$TMP/$1.lbf" ) >"$TMP/$1.log" 2>&1
}

# nummer_mit_argumenten <lbf> <nr> -> druckt die Zahl geladener Argumentregister
# oder "fehlt", wenn die Nummer nicht im Erzeugnis steht.
nummer_mit_argumenten() {
  python3 - "$1" "$2" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
nr = int(sys.argv[2])
pat = bytes([0x48, 0xB8]) + nr.to_bytes(8, 'little')      # mov rax, imm64
i = d.find(pat)
if i < 0:
    print("fehlt"); raise SystemExit
seg = d[i+10:i+10+48]                                      # Argumentlader folgen
regs = [b'\x48\x8b\x7d', b'\x48\x8b\x75', b'\x48\x8b\x55', b'\x4c\x8b\x55', b'\x4c\x8b\x45']
print(sum(1 for r in regs if r in seg))
PY
}

pruefe_nr() {  # name, nr, erwartete Argumentzahl
  local got; got=$(nummer_mit_argumenten "$TMP/$1.lbf" "$2")
  if [ "$got" = "$3" ]; then echo "PASS $1: Nummer $2 mit $got Argument(en)"; PASS=$((PASS+1));
  else echo "FAIL $1: Nummer $2 -> $got, erwartet $3"; FAIL=$((FAIL+1)); fi
}

fehlt_nr() {  # name, nr  -- die Nummer DARF nicht vorkommen
  if [ "$(nummer_mit_argumenten "$TMP/$1.lbf" "$2")" = "fehlt" ]; then
    echo "PASS $1: Nummer $2 kommt nicht mehr vor"; PASS=$((PASS+1))
  else
    echo "FAIL $1: Nummer $2 steht weiter im Erzeugnis"; FAIL=$((FAIL+1))
  fi
}

echo "--- 1. nanosleep geht auf 358, nicht auf 25 ---"
bau ns 'fn main(): int64 { var ts: int64 := 0; var rem: int64 := 0; return nanosleep(ts, rem); }'
if [ -f "$TMP/ns.lbf" ]; then
  pruefe_nr ns 358 2        # (ts, rem) -- rem wird NICHT mehr verworfen
  fehlt_nr  ns 25           # sleep_ticks
else
  echo "FAIL ns: uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/ns.log" | cut -c1-80)"; FAIL=$((FAIL+2))
fi

# Ohne `rem` muss der zweite Slot ausdruecklich 0 tragen: ein ungesetzter Slot
# waere eine Muelladresse, in die der Kernel schreibt (er prueft a1 != 0).
echo "--- 2. nanosleep ohne rem uebersetzt und bleibt zweistellig ---"
bau ns1 'fn main(): int64 { var ts: int64 := 0; return nanosleep(ts); }'
if [ -f "$TMP/ns1.lbf" ]; then pruefe_nr ns1 358 2
else echo "SKIP ns1: einstelliger Aufruf wird abgewiesen -- dann ist der Fall nicht erreichbar"; fi

echo "--- 3. clock_nanosleep schlaeft ueber 358 und hat keine Flickstelle mehr ---"
# #2544: der Block trug zwei von Hand gerechnete rel8-Weiten, und die zweite
# war falsch (JLE sprang 15 Byte, zu ueberspringen waren 37) -- ein ABSTIME auf
# einen vergangenen Zeitpunkt fuehrte Muell aus. Jetzt CMOV statt Sprung.
bau cn 'fn main(): int64 { var ts: int64 := 0; var rem: int64 := 0; return sys_clock_nanosleep(0, 1, ts, rem); }'
if [ -f "$TMP/cn.lbf" ]; then
  if python3 -c "
import sys
d=open('$TMP/cn.lbf','rb').read()
nr=(358).to_bytes(8,'little')
raise SystemExit(0 if bytes([0x48,0xB8])+nr in d else 1)"; then
    echo "PASS cn: schlaeft ueber 358"; PASS=$((PASS+1))
  else echo "FAIL cn: 358 fehlt"; FAIL=$((FAIL+1)); fi
  fehlt_nr cn 25
  for z in "48 0F 45 CA:CMOVNE rcx,rdx" "4C 0F 4E E0:CMOVLE r12,rax"; do
    by=${z%%:*}; nm=${z##*:}
    if python3 -c "
d=open('$TMP/cn.lbf','rb').read()
raise SystemExit(0 if bytes(int(x,16) for x in '$by'.split()) in d else 1)"; then
      echo "PASS cn: $nm vorhanden"; PASS=$((PASS+1))
    else echo "FAIL cn: $nm fehlt -- ohne CMOV ist die Verzweigung zurueck"; FAIL=$((FAIL+1)); fi
  done
  # Die alten Flickstellen duerfen nicht wieder auftauchen.
  if python3 -c "
d=open('$TMP/cn.lbf','rb').read()
raise SystemExit(1 if bytes([0x4D,0x85,0xE4,0x7E]) in d else 0)"; then
    echo "PASS cn: kein TEST r12,r12 + JLE mehr"; PASS=$((PASS+1))
  else echo "FAIL cn: die handgerechnete JLE-Weite ist zurueck"; FAIL=$((FAIL+1)); fi
else
  echo "FAIL cn: uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/cn.log" | cut -c1-80)"; FAIL=$((FAIL+5))
fi

echo "--- 4. Steuercodes: sys_sig_post (359, zwei Arg) und sys_sig_poll (360, null) ---"
bau sg 'fn main(): int64 { var r: int64 := sys_sig_post(0, 7); var c: int64 := sys_sig_poll(); return r + c; }'
if [ -f "$TMP/sg.lbf" ]; then
  pruefe_nr sg 359 2
  pruefe_nr sg 360 0
else
  echo "FAIL sg: uebersetzt nicht: $(grep -m1 -iE 'error|unbekannt' "$TMP/sg.log" | cut -c1-80)"; FAIL=$((FAIL+2))
fi

echo "--- 5. Aritaet wird auf BEIDEN Seiten geprueft ---"
# Ein Test, der nur die richtige Zahl akzeptiert, waere auch von einer Fassung
# ohne jede Pruefung erfuellt. Deshalb zu wenige UND zu viele.
aritaet() {  # name, rumpf, erwartete Zahl in der Meldung
  printf 'unit main;\n%s\n' "$2" > "$TMP/a.lyx"
  local m
  m=$( ( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/a.lyx" -o "$TMP/a.lbf" ) 2>&1 \
       | grep -oE "erwartet auf LyxOS genau [0-9]+ Argument" | head -1 )
  if [ "$m" = "erwartet auf LyxOS genau $3 Argument" ]; then
    echo "PASS $1 (meldet $3)"; PASS=$((PASS+1))
  else
    echo "FAIL $1: Meldung '$m', erwartet '… genau $3 Argument'"; FAIL=$((FAIL+1))
  fi
}
aritaet post_zu_wenig  'fn main(): int64 { return sys_sig_post(0); }'       2
aritaet post_zu_viel   'fn main(): int64 { return sys_sig_post(0, 7, 9); }' 2
aritaet poll_zu_viel   'fn main(): int64 { return sys_sig_poll(1); }'       0

echo "--- 6. #2529: Graph-Nummern mit VIER Argumenten, kein fuenftes ---"
bau gq 'fn main(): int64 { return sys_graph_query(0, 0, 0, 0); }'
if [ -f "$TMP/gq.lbf" ]; then pruefe_nr gq 2066 4
else echo "FAIL gq: uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/gq.log" | cut -c1-90)"; FAIL=$((FAIL+1)); fi
bau ge 'fn main(): int64 { return sys_graph_edge_add(1, 2, 3, 0); }'
if [ -f "$TMP/ge.lbf" ]; then pruefe_nr ge 2064 4
else echo "FAIL ge: uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/ge.log" | cut -c1-90)"; FAIL=$((FAIL+1)); fi

echo "--- 7. Gegenprobe: 2061/2062 bleiben abgewiesen (#2530, kernelseitig offen) ---"
# Diese Luecke soll OFFEN bleiben, solange der Kernel keine Inferenz hat. Ein
# Test, der sie als behoben annimmt, waere falsch -- und einer, der die
# Ablehnungsmeldung als Nachweis nimmt, wird rot, sobald sie zugeht. Geprueft
# wird deshalb nur, dass KEIN Erzeugnis entsteht.
printf 'unit main;\nfn main(): int64 { return sys_sem_annotate(0, 0, 0); }\n' > "$TMP/se.lyx"
if ( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/se.lyx" -o "$TMP/se.lbf" ) >/dev/null 2>&1; then
  echo "FAIL se: sys_sem_annotate uebersetzt -- 2061 ist im Kernel nicht belegt (#2530)"; FAIL=$((FAIL+1))
else
  echo "PASS se: sys_sem_annotate wird weiter abgewiesen (#2530)"; PASS=$((PASS+1))
fi

echo
echo "lyxos_dienste_2544_test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
