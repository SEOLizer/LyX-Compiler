#!/bin/bash
# #1865: Die Differenz zwischen dem, was der Compiler EMITTIEREN kann, und dem,
# was der seccomp-Filter freigibt, bleibt messbar.
#
# Warum ein eigener Waechter: ein Aufruf ohne Capability stirbt an SIGSYS —
# ohne Meldung, ohne Rueckgabewert, mitten im Programm. Kein Testlauf einer
# einzelnen Unit bemerkt das, solange niemand genau diesen Pfad geht. Diese
# Pruefung bemerkt es beim Bau.
#
# ERHOBEN WIRD AN DER QUELLE, nicht per grep ueber std/:
#
#   emittierbar  src/codegen_x86.lyx —  cg_seq(fname, fnlen, "<name>", n)
#                gefolgt von cg_movRaxImm(<nr>) und 0F 05
#   erlaubt      src/security/seccomp_gen.lyx — ALLE VIER Freigabeformen:
#                  sc_allow_nr(..., SC_SYS_X)     sc_allow_nr(..., <zahl>)
#                  sc_allow_nr_arg1(..., SC_SYS_X, <cmd>)
#                  SC_JMP_JEQ_K ... SC_SYS_X   (handgebaute Filter)
#
# Der Erhebungsbefehl aus der urspruenglichen Meldung sah nur die ERSTE Form
# und traf damit 82 von 111 Stellen — daraus entstand die falsche Behauptung
# in #1869, `fcntl` sei nie freigegeben. Wer diese Pruefung anpasst, prueft
# zuerst, ob er alle vier Formen erfasst.

cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# ── Bewusst NICHT gedeckte Nummern ────────────────────────────────────────
# Jede Zeile braucht eine Begruendung. Wer hier etwas eintraegt, ohne sie zu
# nennen, macht aus dem Waechter eine Formalie.
#
#   96  gettimeofday — `clock_gettime` ist DIE Zeitquelle unter system.time
#                      (#1179). Ein zweiter, immer erlaubter Zeitzugriff
#                      entwertete die Capability.
cat > "$TMP/ausnahmen.txt" <<'EOF'
96
EOF

python3 - "$TMP/emit.txt" <<'PY'
import re, sys
z = open('src/codegen_x86.lyx').read().split('\n')
akt = None; out = {}
for i, l in enumerate(z):
    m = re.search(r'cg_seq\(fname, fnlen, "([a-z0-9_]+)", \d+\)', l)
    if m: akt = m.group(1)
    m2 = re.search(r'cg_movRaxImm\((\d+)\);\s*self\.cg_e8\(0x0F\); self\.cg_e8\(0x05\)', l)
    if m2 and akt: out.setdefault(int(m2.group(1)), set()).add(akt)
with open(sys.argv[1], 'w') as f:
    for nr in sorted(out):
        f.write("%d %s\n" % (nr, ",".join(sorted(out[nr]))))
PY

python3 - "$TMP/allow.txt" <<'PY'
import re, sys
src = open('src/security/seccomp_gen.lyx').read()
konst = dict(re.findall(r'con\s+(SC_SYS_[A-Z0-9_]+)\s*:\s*int64\s*:=\s*(\d+)', src))
erl = set()
muster = [r'sc_allow_nr\(bpfBuf, n, (SC_SYS_[A-Z0-9_]+|\d+)\)',
          r'sc_allow_nr_arg1\(bpfBuf, n, (SC_SYS_[A-Z0-9_]+|\d+),',
          r'SC_JMP_JEQ_K, 0, \d+, (SC_SYS_[A-Z0-9_]+)\)']
for p in muster:
    for m in re.finditer(p, src):
        t = m.group(1)
        erl.add(int(konst.get(t, t)))
with open(sys.argv[1], 'w') as f:
    for n in sorted(erl): f.write("%d\n" % n)
PY

awk '{print $1}' "$TMP/emit.txt" | sort > "$TMP/e"
sort "$TMP/allow.txt" > "$TMP/a"
sort "$TMP/ausnahmen.txt" | grep -v '^$' > "$TMP/x"

ANZ_E=$(wc -l < "$TMP/e"); ANZ_A=$(wc -l < "$TMP/a")
echo "emittierbar: $ANZ_E   mit Filtereintrag: $(comm -12 "$TMP/e" "$TMP/a" | wc -l)"

# ── Richtung 1: nichts Emittierbares faellt durch ─────────────────────────
comm -13 "$TMP/a" "$TMP/e" | sort > "$TMP/luecke"
comm -13 "$TMP/x" "$TMP/luecke" > "$TMP/unerlaubt"
if [ ! -s "$TMP/unerlaubt" ]; then
  echo "PASS jede emittierbare Nummer ist gedeckt oder begruendet"
  PASS=$((PASS + 1))
else
  echo "FAIL $(wc -l < "$TMP/unerlaubt") emittierbare Nummer(n) ohne Capability und ohne Begruendung:"
  join -1 1 -2 1 "$TMP/unerlaubt" <(sort -k1,1 "$TMP/emit.txt") | sed 's/^/    /'
  echo "    Entweder an eine Capability haengen oder mit Begruendung in die"
  echo "    Ausnahmeliste dieses Tests eintragen."
  FAIL=$((FAIL + 1))
fi

# ── Richtung 2: die Ausnahmen sind noch Ausnahmen ─────────────────────────
# Ohne diese Haelfte wuerde der Test auch dann gruen bleiben, wenn jemand die
# Ausnahmeliste mit allem fuellt, was gerade stoert — oder wenn eine Nummer
# laengst freigegeben ist und der Eintrag nur noch Altlast waere.
VERALTET=$(comm -12 "$TMP/x" "$TMP/a")
if [ -z "$VERALTET" ]; then
  echo "PASS jede Ausnahme ist wirklich noch ungedeckt"
  PASS=$((PASS + 1))
else
  echo "FAIL Ausnahme steht in der Liste, ist aber laengst freigegeben: $(echo $VERALTET)"
  echo "    Eintrag entfernen — sonst deckt die Liste etwas zu, das gar nicht offen ist."
  FAIL=$((FAIL + 1))
fi

# ── Richtung 3: die Erhebung selbst muss etwas finden ─────────────────────
# Ein Regex, der ins Leere greift, macht beide Pruefungen oben gruen. Genau so
# ist der urspruengliche Erhebungsbefehl aus #1865 falsch gewesen.
if [ "$ANZ_E" -gt 100 ] && [ "$ANZ_A" -gt 100 ]; then
  echo "PASS beide Erhebungen liefern plausible Mengen ($ANZ_E / $ANZ_A)"
  PASS=$((PASS + 1))
else
  echo "FAIL Erhebung greift ins Leere (emittierbar $ANZ_E, erlaubt $ANZ_A)"
  echo "    Vermutlich hat sich eine Schreibweise im Quelltext geaendert."
  FAIL=$((FAIL + 1))
fi

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: LCBS-Abdeckung"
exit 0
