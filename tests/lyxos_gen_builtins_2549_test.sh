#!/bin/bash
# #2549: Die Kernelnummern, die aus Lyx erreichbar sein sollen, kommen aus der
# erzeugten Tabelle — und sie kommen WIRKLICH an.
#
# Vorgeschichte. Eine LyxOS-Nummer aus Lyx aufrufbar zu machen kostete VIER
# Handgriffe (sema._regBuiltin, Namensauflistung in ir_lower, Verteiler in
# emit_lyxos, Liste in builtin_ziele). Von 222 Nummern mit lesbarer Gestalt
# erreichte die Handarbeit 105; 117 waren nicht aufrufbar. Vier Aufzaehlungen
# derselben Sache sind das Muster, das hier mehrfach auseinandergelaufen ist
# (#2432, #2450, #2463). Seit 1.2.44D stehen die Daten einmal in
# src/backend/lyxos/lyxos_builtins.lyx, erzeugt von
# tools/lyxos_builtins_erzeugen.py, und die vier Stellen fragen sie ab.
#
# GEPRUEFT WIRD DIE WIRKUNG AM ERZEUGNIS, nicht das Vorhandensein der Tabelle:
# je Argumentzahl-Klasse ein Aufruf, dessen Syscallnummer als Bytemuster im
# Erzeugnis stehen MUSS. Dazu beide Gegenproben, denn ein Test, der nur zeigt,
# dass der richtige Aufruf uebersetzt, waere auch von einem Compiler erfuellt,
# der jede Gestalt durchlaesst:
#   - ein Aufruf mit falscher Argumentzahl muss LAUT scheitern,
#   - derselbe Aufruf auf einem anderen Ziel muss als zielgebunden gemeldet
#     werden, nicht als Compilerluecke.
#
# Die Stichproben werden AUS DER TABELLE GEZOGEN, nicht hier eingetragen:
# waechst die Tabelle, prueft dieser Test die neue Auswahl, und kein Eintrag
# wird durch ein veraltetes Testdatum konserviert.
cd "$(dirname "$0")/.." || exit 1
P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }

GEN="src/backend/lyxos/lyxos_builtins.lyx"
ABI="src/backend/lyxos/lyxos_abi.lyx"
ERZ="tools/lyxos_builtins_erzeugen.py"
# Der Compiler ist ueberschreibbar (tests/lyxc_umgebung_test.sh haelt das
# wahr), und der Pfad muss ABSOLUT sein: die Stichproben uebersetzen in einem
# eigenen Verzeichnis.
LYXC="${LYXC:-./lyxc}"
case "$LYXC" in /*) ;; *) LYXC="$PWD/${LYXC#./}";; esac
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294

if [ ! -x "$LYXC" ]; then
  echo "SKIP: ./lyxc fehlt -- make bootstrap"
  echo ""
  echo "Ergebnis: 0 PASS, 0 FAIL"
  exit 0
fi

# 1) Die erzeugte Datei liegt im Repo und nennt ihre Herkunft.
if [ -f "$GEN" ] && grep -q "ERZEUGT von tools/lyxos_builtins_erzeugen.py" "$GEN"; then
  ok "die erzeugte Tabelle liegt im Repo und nennt ihr Erzeugungsskript"
else
  bad "Tabelle" "$GEN fehlt oder nennt sein Skript nicht"
fi

# 2) Sie passt zu ihrer Quelle. Ohne das urteilt der Compiler nach dem
#    aelteren von zwei Staenden.
if python3 -I "$ERZ" --pruefen >/dev/null 2>&1; then
  ok "die erzeugte Tabelle stimmt mit work/lyxos/syscall-argc.txt ueberein"
else
  bad "Stand" "neu erzeugen: $ERZ"
fi

# 3) Die Tabelle ist nicht leer, und ihre Anzahl stimmt mit den Eintraegen.
ANZ=$(sed -n 's/^  return \([0-9]*\);$/\1/p' "$GEN" | head -1)
EINTR=$(grep -c '^  if (i == [0-9]*) { return "' "$GEN")
if [ "${ANZ:-0}" -gt 0 ] && [ "$ANZ" = "$EINTR" ]; then
  ok "LyxosGenAnzahl ($ANZ) stimmt mit der Zahl der Namenseintraege"
else
  bad "Anzahl" "LyxosGenAnzahl=$ANZ, Namenseintraege=$EINTR"
fi

# 4) Dieselbe Argumentzahl in beiden Tabellen. Es sind zwei Aufzaehlungen
#    derselben Sache (#2482 und #2549); laufen sie auseinander, prueft der
#    Compiler gegen eine Zahl und laedt nach der anderen.
UNEIN=0
while IFS=$'\t' read -r idx nr ac; do
  [ -z "$nr" ] && continue
  ERW=$(grep -m1 "^  if (nr == $nr) { return " "$ABI" | sed 's/.*return \([0-9-]*\).*/\1/')
  [ -z "$ERW" ] && continue
  if [ "$ERW" != "$ac" ]; then
    UNEIN=$((UNEIN+1))
    [ "$UNEIN" -le 3 ] && echo "  uneinig: Nummer $nr -- lyxos_builtins $ac, lyxos_abi $ERW"
  fi
done < <(python3 -I - "$GEN" <<'PY'
import re, sys
s = open(sys.argv[1]).read()


def block(fn):
    # Jede Funktion EINZELN schneiden: dieselbe Zeilenform kommt in mehreren
    # vor, ein Muster ueber die ganze Datei mischt Nummer und Argumentzahl.
    t = s.split("pub fn " + fn, 1)[1].split("\n}", 1)[0]
    return dict((int(a), int(b)) for a, b in re.findall(
        r'if \(i == (\d+)\) \{ return (\d+); \}', t))


nrs = block("LyxosGenNrFuerIdx")
acs = block("LyxosGenArgcFuerIdx")
for i in sorted(nrs):
    if i in acs:
        print(f"{i}\t{nrs[i]}\t{acs[i]}")
PY
)
if [ "$UNEIN" = "0" ]; then
  ok "Argumentzahl stimmt in lyxos_builtins und lyxos_abi ueberein"
else
  bad "Argumentzahl" "$UNEIN Nummern uneinig"
fi

# 5) Die Wirkung: je Argumentzahl-Klasse eine Stichprobe aus der Tabelle.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PROBEN=$(python3 -I - "$GEN" <<'PY'
import re, sys
s = open(sys.argv[1]).read()


def block(fn, muster):
    t = s.split("pub fn " + fn, 1)[1].split("\n}", 1)[0]
    return dict(re.findall(muster, t))


nm = dict((int(a), b) for a, b in block(
    "LyxosGenNameFuerIdx", r'if \(i == (\d+)\) \{ return "([^"]+)"c; \}').items())
nrs = dict((int(a), int(b)) for a, b in block(
    "LyxosGenNrFuerIdx", r'if \(i == (\d+)\) \{ return (\d+); \}').items())
acs = dict((int(a), int(b)) for a, b in block(
    "LyxosGenArgcFuerIdx", r'if \(i == (\d+)\) \{ return (\d+); \}').items())
# Erste Stichprobe je Argumentzahl-Klasse.
gesehen = {}
for i in sorted(nm):
    ac = acs.get(i)
    if ac is None or ac in gesehen:
        continue
    gesehen[ac] = True
    print(f"{nm[i]}\t{nrs[i]}\t{ac}")
PY
)
if [ -z "$PROBEN" ]; then
  bad "Stichproben" "keine aus der Tabelle gewinnbar"
fi

while IFS=$'\t' read -r name nr ac; do
  [ -z "$name" ] && continue
  # Bytemuster: mov eax, <nr> == B8 + nr als 32 Bit, niedrigstes Byte zuerst.
  MUSTER=$(printf 'b8%02x%02x%02x%02x' $((nr & 255)) $(((nr >> 8) & 255)) \
                                        $(((nr >> 16) & 255)) $(((nr >> 24) & 255)))
  ARGS=""
  k=0
  while [ "$k" -lt "$ac" ]; do
    [ -n "$ARGS" ] && ARGS="$ARGS, "
    ARGS="$ARGS$k"
    k=$((k+1))
  done
  printf 'fn main(): int64 {\n  var r: int64 := %s(%s);\n  return r;\n}\n' \
         "$name" "$ARGS" > "$TMP/ok.lyx"

  if "$LYXC" --target=lyxos --std-path=. "$TMP/ok.lyx" -o "$TMP/ok.lbf" >"$TMP/ok.log" 2>&1 \
     && [ -f "$TMP/ok.lbf" ]; then
    if xxd -p "$TMP/ok.lbf" | tr -d '\n' | grep -q "$MUSTER"; then
      ok "$name (argc $ac) emittiert Syscall $nr"
    else
      bad "$name" "uebersetzt, aber Nummer $nr ($MUSTER) steht nicht im Erzeugnis"
    fi
  else
    bad "$name" "uebersetzt nicht: $(tail -1 "$TMP/ok.log")"
  fi

  # Gegenprobe a: falsche Argumentzahl muss laut scheitern.
  if [ "$ac" -gt 0 ]; then
    FALSCH=$((ac - 1))
  else
    FALSCH=1
  fi
  ARGS2=""
  k=0
  while [ "$k" -lt "$FALSCH" ]; do
    [ -n "$ARGS2" ] && ARGS2="$ARGS2, "
    ARGS2="$ARGS2$k"
    k=$((k+1))
  done
  printf 'fn main(): int64 {\n  var r: int64 := %s(%s);\n  return r;\n}\n' \
         "$name" "$ARGS2" > "$TMP/f.lyx"
  if "$LYXC" --target=lyxos --std-path=. "$TMP/f.lyx" -o "$TMP/f.lbf" >"$TMP/f.log" 2>&1; then
    bad "$name" "Aufruf mit $FALSCH statt $ac Argumenten uebersetzt still"
  elif grep -q "nimmt $ac Argument(e), aufgerufen mit $FALSCH" "$TMP/f.log"; then
    ok "$name mit $FALSCH statt $ac Argumenten scheitert laut und nennt beide Zahlen"
  else
    bad "$name" "scheitert, aber ohne die beiden Zahlen: $(head -1 "$TMP/f.log")"
  fi

  # Gegenprobe b: auf einem anderen Ziel als zielgebunden gemeldet, nicht als
  # Compilerluecke (#2427).
  if "$LYXC" --std-path=. "$TMP/ok.lyx" -o "$TMP/l.elf" >"$TMP/l.log" 2>&1; then
    bad "$name" "uebersetzt auch ohne --target=lyxos"
  elif grep -q "gibt es nur mit --target=lyxos" "$TMP/l.log"; then
    ok "$name wird auf anderem Ziel als zielgebunden gemeldet"
  else
    bad "$name" "scheitert auf anderem Ziel ohne die Zielauskunft: $(head -1 "$TMP/l.log")"
  fi
done <<< "$PROBEN"

# 6) Kein erzeugter Name doppelt vergeben. Ein zweiter Builtin gleichen Namens
#    waere nicht aufloesbar, und welche Nummer gemeint ist, weiss niemand.
DOPP=$(python3 -I - <<'PY'
import re
gen = set(re.findall(r'if \(i == \d+\) \{ return "([^"]+)"c; \}',
                     open("src/backend/lyxos/lyxos_builtins.lyx").read()))
hand = set(re.findall(r'_regBuiltin\("([^"]+)"', open("src/sema.lyx").read()))
hand |= set(re.findall(r'self\.seq\(fname, fnlen, "([^"]+)"',
                       open("src/ir_lower.lyx").read()))
print(" ".join(sorted(gen & hand)))
PY
)
if [ -z "$DOPP" ]; then
  ok "kein erzeugter Name kollidiert mit einem Handbuiltin"
else
  bad "Namen" "doppelt vergeben: $DOPP"
fi

echo ""
echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" = "0" ] || exit 1
