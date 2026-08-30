#!/bin/bash
# #1795: der erlaubte Syscall-Raum des lyxos-Backends muss dem entsprechen,
# was LyxOS wirklich behandelt.
#
# Die Menge steht an zwei Orten, und beide muessen zusammenpassen:
#
#   work/lyxos/syscall-ist.txt              — abgeglichener Stand (erzeugt aus
#                                             Dispatcher-Tabelle + Bootloader)
#   lyxosNummerBelegt() in emit_lyxos.lyx   — was der Compiler zulaesst
#
# Warum eine eigene Pruefung: eine erfundene Nummer stuerzt NICHT ab. Der
# Bootloader liefert fuer Unbekanntes still 0 und meldet Erfolg
# (.r3_unknown) — deshalb sind die 106 Phantasienummern aus #1734 nie
# aufgefallen, deshalb lief `free()` jahrelang gegen 0x0101 ins Nichts und
# deshalb emittierte der EVENT_LOOP-Startcode ein sys_event_loop_init, das es
# nicht gibt. Kein Programmlauf kann das melden. Diese Pruefung kann es.
#
# Der Abgleich gegen das LyxOS-Repo laeuft zusaetzlich, wenn es da ist
# (LYXOS_REPO). Ohne das Repo bleibt die Pruefung der beiden Repo-Stellen
# gegeneinander — die ist der Teil, der bei jedem Lauf greifen muss.

cd "$(dirname "$0")/.." || exit 1
STAND="work/lyxos/syscall-ist.txt"
QUELLE="src/backend/lyxos/emit_lyxos.lyx"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

for f in "$STAND" "$QUELLE"; do
    if [ ! -f "$f" ]; then echo "FAIL: $f fehlt"; exit 1; fi
done

# --- Erwartete Menge aus dem abgelegten Stand ------------------------------
awk '!/^#/ && NF >= 2 { for (n = $1; n <= $2; n++) print n }' "$STAND" | sort -n > "$TMP/soll.txt"

# --- Zugelassene Menge aus lyxosNummerBelegt() -----------------------------
# Rumpf zwischen der Signatur und der schliessenden Klammer, dann die beiden
# Zeilenformen `if nr >= A && nr <= B` und `if nr == N`.
awk '
  /fn lyxosNummerBelegt\(/ { drin = 1; next }
  drin && /^    }/         { drin = 0 }
  drin                      { print }
' "$QUELLE" > "$TMP/rumpf.txt"

if [ ! -s "$TMP/rumpf.txt" ]; then
    echo "FAIL: lyxosNummerBelegt() in $QUELLE nicht gefunden — wurde sie umbenannt?"
    exit 1
fi

awk '
  match($0, /nr >= *([0-9]+) *&& *nr <= *([0-9]+)/, m) { for (n = m[1]; n <= m[2]; n++) print n; next }
  match($0, /nr == *([0-9]+)/, m)                      { print m[1] }
' "$TMP/rumpf.txt" | sort -n -u > "$TMP/ist.txt"

pruefe() {  # Name, Bedingung-Ergebnisdatei, Meldung
    if [ ! -s "$2" ]; then
        echo "PASS $1"; PASS=$((PASS + 1))
    else
        echo "FAIL $1: $(wc -l < "$2") Nummern"
        echo "  $(tr '\n' ' ' < "$2")"
        echo "  $3"
        FAIL=$((FAIL + 1))
    fi
}

echo "-- lyxosNummerBelegt() gegen $STAND --"
# comm vergleicht LEXIKALISCH — die Zahlen deshalb so sortiert hineingeben
# und erst fuer die Meldung wieder numerisch ordnen.
sort "$TMP/ist.txt"  > "$TMP/ist.lex";  sort "$TMP/soll.txt" > "$TMP/soll.lex"
comm -13 "$TMP/ist.lex" "$TMP/soll.lex" | sort -n > "$TMP/fehlt.txt"
comm -23 "$TMP/ist.lex" "$TMP/soll.lex" | sort -n > "$TMP/zuviel.txt"

pruefe "kein belegter Aufruf wird abgewiesen" "$TMP/fehlt.txt" \
       "LyxOS behandelt sie, der Compiler weist sie ab — Laeufe in lyxosNummerBelegt() nachziehen."
# Diese Richtung ist die gefaehrliche: eine zugelassene, aber unbehandelte
# Nummer wird still zu 0 und meldet Erfolg.
pruefe "keine unbehandelte Nummer ist zugelassen" "$TMP/zuviel.txt" \
       "Der Compiler laesst sie durch, LyxOS behandelt sie nicht — sie wuerde still 0 liefern."

# --- Rohe Emissionsstellen: gehen an der Pruefung vorbei -------------------
# emitVfsSyscall prueft die Nummer; `emitMovRaxImm(N); ... emitSyscall()`
# nicht. Genau dort standen 0x0101 (free) und 0x0020 (EVENT_LOOP). Solche
# Stellen sind erlaubt, ihre Nummern muessen aber im Stand stehen.
python3 - "$QUELLE" "$TMP/soll.txt" > "$TMP/roh.txt" <<'PY'
import re, sys
zeilen = open(sys.argv[1]).read().split("\n")
soll = set(int(x) for x in open(sys.argv[2]))
for i, l in enumerate(zeilen):
    m = re.search(r'emitMovRaxImm\((0x[0-9A-Fa-f]+|\d+)\)', l)
    if not m:
        continue
    # Bis zum naechsten rax-Ladebefehl oder zum naechsten Builtin-Zweig
    # schauen: steht dazwischen ein SYSCALL? Ein weiter gefasstes Fenster
    # zieht den Nachbarzweig herein und macht aus der eingebackenen
    # ABI-Version (0x0000000100000000, Builtin 58) eine Syscall-Nummer.
    folgt = []
    for z in zeilen[i+1:i+26]:
        if 'emitMovRaxImm(' in z or 'else if id ==' in z:
            break
        folgt.append(z)
    if 'emitSyscall()' not in "\n".join(folgt):
        continue          # keine Syscall-Nummer, nur ein Wert in rax
    nr = int(m.group(1), 0)
    if nr not in soll:
        print(f"{sys.argv[1]}:{i+1}: rohe Syscall-Nummer {nr} steht nicht im Ist-Stand")
PY
pruefe "rohe Emissionsstellen nennen nur belegte Nummern" "$TMP/roh.txt" \
       "Diese Stellen umgehen lyxosNummerBelegt() — die Nummer muss trotzdem existieren."

# --- Abgleich gegen das LyxOS-Repo, falls vorhanden ------------------------
echo "-- Abgleich gegen das LyxOS-Repo --"
ABGLEICH=$(tools/lyxos_syscall_abgleich.sh 2>&1); RC=$?
if [ "$RC" = "2" ]; then
    echo "UEBERSPRUNGEN: LyxOS-Repo nicht da (LYXOS_REPO setzen). Die Pruefungen"
    echo "  oben liefen; nur der Abgleich gegen den Kernel fehlt."
elif [ "$RC" = "0" ]; then
    echo "PASS Stand deckt sich mit Dispatcher-Tabelle und Bootloader"
    PASS=$((PASS + 1))
else
    echo "FAIL Stand weicht vom LyxOS-Repo ab:"
    echo "$ABGLEICH" | sed 's/^/  /'
    FAIL=$((FAIL + 1))
fi

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: lyxos-Syscall-Ist-Stand"
exit 0
