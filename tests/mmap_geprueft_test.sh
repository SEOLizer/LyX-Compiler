#!/usr/bin/env bash
# #1947: Eine fehlgeschlagene Speicheranforderung muss MELDEN, nicht abstuerzen.
#
# `push(a, x)` fordert Speicher per mmap an — einmal beim Anlegen des Arrays
# (cg_emitEmptyDynArray) und danach bei jedem Wachstumsschritt
# (cg_genArrayPush). Bis 1.1.19B wurde der Rueckgabewert an BEIDEN Stellen
# ungeprueft als Adresse benutzt. Schlug die Anforderung fehl, lief
# `-ENOMEM` (0xFFFFFFFFFFFFFFF4) als Zeiger weiter und der naechste
# Schreibzugriff traf ihn: SIGSEGV, rc 139.
#
# Warum das mehr ist als ein haesslicher Abbruch: der Absturz sagt nichts. Er
# sieht aus wie ein Codegen-Fehler, und genau dafuer wurde er auch gehalten —
# die Fehlschlaege in tests/kurzsprung_test.sh galten lange als flackernd und
# als Folge eines zu knappen Deckels (#1915). Der Deckel loeste sie aus, die
# fehlende Pruefung war die Ursache. Ein groesserer Deckel verschiebt die
# Grenze nur.
#
# GEMESSEN WIRD DIE WIRKUNG, in BEIDE Richtungen:
#   * unter knappem Deckel: definierter Exit und eine Meldung, die den Grund
#     nennt — nicht 139,
#   * mit reichlich Speicher: das Programm rechnet unveraendert richtig.
# Ohne die zweite Haelfte waere der Test auch von einem Compiler erfuellt, der
# jede Anforderung ablehnt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# #2050: Auf dem CI-Runner stuerzte dieses Programm in manchen Laeufen mit
# SIGSEGV ab — auch mit reichlich Speicher, in allen Ausfuehrungen eines Laufs
# zugleich, und im naechsten Lauf desselben Commits nicht mehr. Lokal war das
# zunaechst nicht nachzustellen (520 Uebersetzungen mit demselben Kompilat,
# wechselnde Umgebungsgroessen, ASLR aus, acht emulierte CPU-Modelle).
#
# Gefunden hat es DIESE Funktion, beim ersten Probelauf: ihr strace zeigte
# `munmap(alt, 133195639373840) = EINVAL` — eine Adresse als Laenge. Die
# Laenge stand im falschen Register (rdx statt rsi). Gewoehnlich scheitert der
# Aufruf daran folgenlos; im Legacy-Adresslayout (`ulimit -s unlimited`)
# gelingt er und gibt den eben angelegten neuen Block mit frei. Siehe die
# beiden #2050-Pruefungen unten.
#
# Die Funktion bleibt stehen. Dass der Runner im Legacy-Layout lief, ist die
# naheliegende Erklaerung, aber nicht gemessen — sie gibt `ulimit -s` mit
# aus. Stuerzt das Programm noch einmal ab, endet der Lauf nicht wieder ohne
# Befund. Am Urteil aendert sie nichts: der Test bleibt rot.
DIAGNOSE_FERTIG=0
diagnose() {
  [ "$DIAGNOSE_FERTIG" = 1 ] && return 0
  DIAGNOSE_FERTIG=1
  echo "=== #2050 DIAGNOSE (Absturz des Testprogramms) ==="
  echo "Kompilat:  $(sha256sum < "$TMP/gross" | cut -c1-64)  ($(stat -c %s "$TMP/gross") Byte)"
  echo "Compiler:  $(sha256sum < "$ROOT/lyxc" | cut -c1-64)"
  # Dasselbe Programm noch einmal uebersetzen: weicht die Pruefsumme ab, ist
  # die UEBERSETZUNG auf diesem Rechner nicht deterministisch — dann liegt der
  # Fehler im Compiler und nicht im Lauf.
  if ( cd "$ROOT" && timeout 180 "$LYXC" --std-path="$ROOT" "$TMP/gross.lyx" -o "$TMP/gross2" ) >/dev/null 2>&1; then
    echo "Kompilat2: $(sha256sum < "$TMP/gross2" | cut -c1-64)  (zweite Uebersetzung)"
  else
    echo "Kompilat2: die zweite Uebersetzung scheiterte"
  fi
  echo "Kernel:    $(uname -r)"
  echo "CPU:       $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //')  ($(nproc 2>/dev/null) Kerne)"
  echo "Speicher:  $(grep -m1 MemTotal /proc/meminfo 2>/dev/null | tr -s ' ')"
  local k
  for k in vm/overcommit_memory vm/max_map_count vm/mmap_min_addr vm/legacy_va_layout \
           kernel/randomize_va_space kernel/core_pattern; do
    echo "sysctl:    $k = $(cat "/proc/sys/$k" 2>/dev/null || echo '?')"
  done
  echo "ulimit:    stack=$(ulimit -s) as=$(ulimit -v) core=$(ulimit -c) data=$(ulimit -d)"
  # Wie oft? Zwanzig Laeufe ohne jeden Deckel. 20 von 20 heisst: das Kompilat
  # laeuft auf diesem Rechner nie; dazwischen heisst: es haengt am Lauf.
  local i ab=0 codes=""
  for i in $(seq 1 20); do
    timeout 120 "$TMP/gross" >/dev/null 2>&1; local r=$?
    [ "$r" -ne 0 ] && { ab=$((ab+1)); codes="$codes $r"; }
  done
  echo "Wiederholung ohne Deckel: $ab von 20 Laeufen scheitern (rc:${codes:- -})"
  # Ohne ASLR — trennt "haengt an der Adresslage" von allem anderen.
  if command -v setarch >/dev/null 2>&1; then
    ab=0
    for i in $(seq 1 10); do setarch "$(uname -m)" -R timeout 120 "$TMP/gross" >/dev/null 2>&1 || ab=$((ab+1)); done
    echo "Wiederholung ohne ASLR:   $ab von 10 Laeufen scheitern"
  fi
  # Die Kernelmeldung nennt Zugriffsadresse, Befehlszeiger und Stapelzeiger.
  # `dmesg` ist meist gesperrt; auf dem Runner geht es ueber sudo ohne
  # Kennwort. Scheitert beides, steht hier nichts — das ist dann der Befund.
  local km=""
  km="$(dmesg 2>/dev/null | grep -a 'segfault at' | tail -3)"
  [ -z "$km" ] && km="$(sudo -n dmesg 2>/dev/null | grep -a 'segfault at' | tail -3)"
  if [ -n "$km" ]; then printf 'Kernel:    %s\n' "$km"; else echo "Kernel:    keine segfault-Zeile lesbar (dmesg gesperrt)"; fi
  # Die letzten Systemaufrufe vor dem Signal, falls strace da ist.
  if command -v strace >/dev/null 2>&1; then
    echo "strace (letzte 25 Zeilen):"
    timeout 120 strace -f "$TMP/gross" 2>&1 >/dev/null | tail -25 | sed 's/^/    /'
  else
    echo "strace:    nicht installiert"
  fi
  echo "=== Ende DIAGNOSE ==="
}

echo "--- Fehlgeschlagene Speicheranforderung meldet, statt abzustuerzen (#1947) ---"

# Genug Wachstum, damit die Anforderung unter einem knappen Deckel wirklich
# scheitert: 3 Mio. Eintraege sind 24 MB, und beim Verdoppeln liegen alter und
# neuer Block gleichzeitig.
cat > "$TMP/gross.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var a: Array<int64>;
  var i: int64 := 0;
  while (i < 3000000) { push(a, i); i := i + 1; }
  PrintLn(IntToStr(len(a)));
  return 0;
}
EOF

if ! ( cd "$ROOT" && timeout 180 "$LYXC" --std-path="$ROOT" "$TMP/gross.lyx" -o "$TMP/gross" ) >"$TMP/build.log" 2>&1; then
  nok "das Pruefprogramm uebersetzt nicht"; sed -n '1,5p' "$TMP/build.log"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

# --- Richtung 1: knapper Deckel → Meldung statt Absturz ----------------------
#
# 30 MB reichen fuer den Programmstart, aber nicht fuer die wachsende Ablage.
aus="$( ulimit -v 30000; timeout 120 "$TMP/gross" 2>&1 >/dev/null )"
rc="$(  ulimit -v 30000; timeout 120 "$TMP/gross" >/dev/null 2>&1; echo $? )"

if [ "$rc" = "139" ]; then
  nok "unter knappem Deckel: Segfault (rc=139) — der Rueckgabewert wird wieder ungeprueft benutzt"
  diagnose
elif [ "$rc" = "0" ]; then
  nok "unter knappem Deckel lief das Programm durch — der Deckel greift nicht, der Test misst nichts"
else
  ok "unter knappem Deckel: definierter Abbruch (rc=$rc), kein Segfault"
fi

if printf '%s' "$aus" | grep -q "Speicheranforderung fehlgeschlagen"; then
  ok "die Meldung nennt den Grund"
else
  nok "keine Meldung ueber die fehlgeschlagene Anforderung (ausgegeben: '$(printf '%s' "$aus" | head -1)')"
fi

# --- Richtung 2: genug Speicher → unveraendert richtig ------------------------
#
# Ohne diese Haelfte waere der Test auch von einem Compiler erfuellt, der jede
# Anforderung ablehnt.
gut="$( ulimit -v 4194304; timeout 120 "$TMP/gross" 2>/dev/null )"
grc="$( ulimit -v 4194304; timeout 120 "$TMP/gross" >/dev/null 2>&1; echo $? )"
if [ "$grc" = "0" ] && [ "$gut" = "3000000" ]; then
  ok "mit reichlich Speicher rechnet dasselbe Programm richtig (3000000)"
else
  nok "mit reichlich Speicher: rc=$grc, Ausgabe '$gut' (erwartet 0 und 3000000)"
  # Stuerzt es auch OHNE Speichermangel ab, sagt die Meldung im ersten Fall
  # ("wird wieder ungeprueft benutzt") das Falsche: dann ist es kein
  # fehlender Vergleich, sondern #2050.
  [ "$grc" -ge 128 ] 2>/dev/null && diagnose
fi

# --- #2050: Legacy-Adresslayout -----------------------------------------------
#
# Mit unbegrenztem Stapel teilt der Kernel Speicher von UNTEN zu: der neue
# Block liegt dann OBERHALB des alten. Beim Wachsen wird der alte freigegeben
# — und bis 1.2.10A mit einer Adresse als Laenge (rsi kam ungesetzt aus dem
# `rep movsb`, die echte Laenge stand in rdx). In diesem Layout passte die
# Summe in den Adressraum, munmap gelang und nahm den neuen Block mit:
# SIGSEGV beim naechsten Zugriff, schon nach dem ERSTEN Wachstumsschritt.
#
# Das war der "flackernde" Absturz auf dem CI-Runner. Gemessen wird genau
# diese Lage; ohne den Fix ist der Fall rot (rc 139).
leg="$( ulimit -s unlimited 2>/dev/null; timeout 120 "$TMP/gross" 2>/dev/null )"
lrc="$( ulimit -s unlimited 2>/dev/null; timeout 120 "$TMP/gross" >/dev/null 2>&1; echo $? )"
if [ "$(ulimit -s unlimited 2>/dev/null; ulimit -s)" != "unlimited" ]; then
  # Ohne das Recht, die Grenze zu heben, laeuft das Programm im gewoehnlichen
  # Layout und der Fall misst nichts — das als Erfolg zu verbuchen waere
  # genau die Art PASS, die #2048 abgeschafft hat.
  nok "#2050: 'ulimit -s unlimited' ist hier nicht setzbar — das Legacy-Layout wurde NICHT gemessen"
elif [ "$lrc" = "0" ] && [ "$leg" = "3000000" ]; then
  ok "#2050: im Legacy-Layout (ulimit -s unlimited) rechnet das Programm richtig"
else
  nok "#2050: im Legacy-Layout rc=$lrc, Ausgabe '$leg' — munmap gibt wieder zu viel frei?"
  [ "$lrc" -ge 128 ] 2>/dev/null && diagnose
fi

# --- #2050: der alte Block wird wirklich freigegeben --------------------------
#
# Die andere Haelfte desselben Fehlers, und die haeufigere: im gewoehnlichen
# Layout scheiterte munmap mit EINVAL und gab NICHTS frei. Kein Absturz, also
# auch kein Test, der es bemerkt haette — das Array hielt still jeden Block,
# den es je hatte.
#
# Gemessen am Bedarf: das Programm braucht am Ende einen Block von 32 MB und
# waehrend des letzten Wachsens den alten von 16 MB daneben, zusammen 48 MB.
# Ohne Freigabe kommen alle frueheren dazu, zusammen 64 MB. Der Deckel liegt
# dazwischen: mit Freigabe reicht er (nachgemessen ab 50000), ohne nicht
# (nachgemessen bis 60000).
frei="$( ulimit -v 56000; timeout 120 "$TMP/gross" 2>/dev/null )"
frc="$(  ulimit -v 56000; timeout 120 "$TMP/gross" >/dev/null 2>&1; echo $? )"
if [ "$frc" = "0" ] && [ "$frei" = "3000000" ]; then
  ok "#2050: unter 56 MB laeuft das Programm durch — die alten Bloecke werden freigegeben"
else
  nok "#2050: unter 56 MB rc=$frc — die alten Bloecke bleiben stehen (munmap ohne Wirkung)"
  [ "$frc" -ge 128 ] 2>/dev/null && diagnose
fi

# --- Beide Stellen tragen die Pruefung ---------------------------------------
#
# Die Anforderung steht an zwei Stellen: beim Anlegen und beim Wachsen. Fehlt
# sie an einer, faellt genau der eine Pfad wieder stumm aus — die Klasse
# "zweite Stelle nicht nachgezogen".
n="$(grep -c 'cg_emitMmapGeprueft' "$ROOT/src/codegen_x86.lyx")"
if [ "$n" -ge 3 ]; then
  ok "beide Anforderungsstellen rufen die Pruefung (Definition + $((n-1)) Aufrufe)"
else
  nok "nur $((n-1)) Aufrufstelle(n) von cg_emitMmapGeprueft — eine Anforderung bleibt ungeprueft"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
