#!/usr/bin/env bash
# tests/runde_f_test.sh — #1912, #1916, #1917
#
# Drei Faelle, die alle dieselbe Form haben: etwas wurde angenommen und tat
# nichts, oder eine Zahl war an zwei Stellen verschieden vergeben.
#
#   #1912  `ui.notify` — der Name fehlte, und das Bit, um das der Kernel bat
#          (0x200), ist bei uns seit #1797 `audio.mic`. Gemessen wird deshalb
#          am ERZEUGNIS, nicht an der Tabelle: jedes Bit einzeln.
#   #1916  `@integrity` vor `unit` war ein stiller No-op — byte-gleiches
#          Erzeugnis. `scrubbed` wirkt dort jetzt (der Sweep ist ohnehin
#          programmweit), `software_lockstep` wird abgewiesen.
#   #1917  `@integrity` auf einem IR-Ziel war ebenfalls ein stiller No-op:
#          arm64 und riscv64 lieferten byte-gleiche Erzeugnisse. Jetzt wird
#          gemeldet, statt zu schweigen.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# CAPS-TLV (Tag 5, Laenge 8) aus einem LBF-Erzeugnis lesen.
capbits() { python3 - "$1" <<'PY'
import sys,struct
d=open(sys.argv[1],'rb').read()
for i in range(len(d)-11):
    if d[i]==5 and struct.unpack_from('<H',d,i+1)[0]==8:
        v=struct.unpack_from('<Q',d,i+3)[0]
        if v < (1<<32):
            print(v); break
else:
    print(-1)
PY
}

bits_von() { # capability-name -> CAPS-Bits am Erzeugnis
  printf 'unit main;\n@capabilities([%s])\nimport std.io;\nfn main(): int64 { return 0; }\n' "$1" > "$TMP/c.lyx"
  "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" --target=lyxos -o "$TMP/c.lbf" >/dev/null 2>&1 || { echo "-2"; return; }
  capbits "$TMP/c.lbf"
}

echo "=== #1912: ui.notify ==="

b=$(bits_von "ui.notify")
if [ "$b" = "2048" ]; then ok "ui.notify setzt Bit 0x800"; else no "ui.notify setzt Bit 0x800" "CAPS=$b"; fi

# DIE Pruefung, die den Fall traegt: 0x200 ist NICHT frei. Der Kernel hatte
# darum gebeten; waere sie ein zweites Mal vergeben worden, bekaeme jedes
# Programm mit Mikrofonrecht still PLEDGE_NOTIFY dazu. Dritter Fall dieser Art
# nach #1755 (0x10 gegen ki.embed) und #1759 (0x80 gegen system.config).
m=$(bits_von "audio.mic")
if [ "$m" = "512" ]; then ok "audio.mic haelt 0x200 (deshalb ist es fuer ui.notify nicht frei)"
else no "audio.mic haelt 0x200" "CAPS=$m"; fi
c=$(bits_von "system.config")
if [ "$c" = "128" ]; then ok "system.config haelt 0x80 (der Name fuer config.write existiert)"
else no "system.config haelt 0x80" "CAPS=$c"; fi

# Und die Bits sind PAARWEISE verschieden — ohne diese Zeile waere der Test
# auch von drei gleichen Rueckgaben erfuellt.
if [ "$b" != "$m" ] && [ "$b" != "$c" ] && [ "$m" != "$c" ]; then
  ok "die drei Bits sind verschieden"
else no "die drei Bits sind verschieden" "$b / $m / $c"; fi

# Unter Linux gibt der Name nichts frei, muss aber uebersetzen — sonst liesse
# sich dasselbe Programm nicht auf beiden Zielen bauen.
cat > "$TMP/u.lyx" <<'EOF'
unit main;
@capabilities([system.exit, ui.notify])
import std.io;
fn main(): int64 { PrintLn(IntToStr(7)); return 0; }
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/u.lyx" -o "$TMP/u" >/dev/null 2>&1 && [ "$("$TMP/u")" = "7" ]; then
  ok "ui.notify uebersetzt und laeuft unter Linux"
else no "ui.notify uebersetzt und laeuft unter Linux" "rc=$?"; fi

echo
echo "=== #1916: @integrity vor unit ==="

cat > "$TMP/us.lyx" <<'EOF'
@integrity(mode: scrubbed, interval: 80)
unit main;
import std.io;
fn main(): int64 { PrintLn(IntToStr(1)); return 0; }
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/us.lyx" -o "$TMP/us" >/dev/null 2>&1; then
  ok "unit-level scrubbed uebersetzt"
  if grep -q "METASAF2" "$TMP/us"; then ok "unit-level scrubbed legt die Hashtabelle an"
  else no "unit-level scrubbed legt die Hashtabelle an" "METASAF2 fehlt"; fi
  iv=$(python3 - "$TMP/us" <<'PY'
import sys,struct
d=open(sys.argv[1],'rb').read(); o=d.find(b'METASAF2')
print(struct.unpack_from('<I',d,o+40)[0] if o>=0 else -1)
PY
)
  if [ "$iv" = "80" ]; then ok "das Intervall der Unit-Form kommt an"; else no "das Intervall der Unit-Form kommt an" "$iv"; fi
  # Gegenprobe: dasselbe Programm OHNE die Zeile hat keine Tabelle. Ohne sie
  # waere der Nachweis von einem Erzeugnis nicht zu unterscheiden, das die
  # Tabelle aus einem anderen Grund traegt.
  tail -n +2 "$TMP/us.lyx" > "$TMP/us0.lyx"
  "$LYXC" --std-path="$ROOT" "$TMP/us0.lyx" -o "$TMP/us0" >/dev/null 2>&1
  if grep -q "METASAF2" "$TMP/us0"; then no "ohne die Zeile keine Tabelle" "METASAF2 steht da"
  else ok "ohne die Zeile keine Tabelle"; fi
else
  no "unit-level scrubbed uebersetzt" "Uebersetzung schlug fehl"
fi

# software_lockstep an der Unit wird ABGEWIESEN: der Vergleich sitzt auf dem
# Rueckgabeausdruck EINER Funktion. An der Unit traefe er auch jede, deren
# Ausdruck sich nicht zweimal rechnen laesst.
cat > "$TMP/ul.lyx" <<'EOF'
@integrity(mode: software_lockstep)
unit main;
fn main(): int64 { return 0; }
EOF
got="$("$LYXC" --std-path="$ROOT" "$TMP/ul.lyx" -o "$TMP/ul" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$got" | grep -q "nicht an der Unit"; then
  ok "unit-level software_lockstep wird abgewiesen"
else no "unit-level software_lockstep wird abgewiesen" "rc=$rc"; fi

echo
echo "=== #1917: @integrity auf IR-Zielen ==="

cat > "$TMP/ls.lyx" <<'EOF'
unit main;
import std.io;
@integrity(mode: software_lockstep)
fn Rechne(a: int64, b: int64): int64 { return a * b + 7; }
fn main(): int64 { PrintLn(IntToStr(Rechne(6,7))); return 0; }
EOF
for t in arm64 riscv64 lyxos; do
  got="$("$LYXC" --std-path="$ROOT" "$TMP/ls.lyx" --target=$t -o "$TMP/x" 2>&1)"; rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$got" | grep -q "nicht umgesetzt"; then
    ok "$t weist @integrity ab"
  else no "$t weist @integrity ab" "rc=$rc"; fi
done

# Die Gegenprobe: auf x86-64 wirkt es unveraendert. Ohne sie waere der Test
# auch von einer Aenderung erfuellt, die das Attribut ueberall abweist.
if "$LYXC" --std-path="$ROOT" "$TMP/ls.lyx" -o "$TMP/lsx" >/dev/null 2>&1 && [ "$("$TMP/lsx")" = "49" ]; then
  ok "x86-64 uebersetzt und rechnet weiterhin"
else no "x86-64 uebersetzt und rechnet weiterhin" "rc=$?"; fi
# Und der Abbruchpfad steht dort im Erzeugnis.
if strings "$TMP/lsx" | grep -q "stimmen nicht ueberein"; then
  ok "x86-64: Lockstep-Abbruchpfad im Erzeugnis"
else no "x86-64: Lockstep-Abbruchpfad im Erzeugnis" "fehlt"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
