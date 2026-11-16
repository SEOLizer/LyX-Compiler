#!/usr/bin/env bash
# tests/tanz3_abi_scrub_test.sh — zwei Befunde, ein Test.
#
# #2560: Der erlaubte LyxOS-Nummernraum steht an DREI Stellen, und nur zwei
#   kommen aus dem Abgleichwerkzeug: work/lyxos/syscall-ist.txt und
#   work/lyxos/syscall-argc.txt werden erzeugt, `lyxosNummerBelegt` in
#   src/backend/lyxos/emit_lyxos.lyx ist HANDARBEIT -- dazu zwei Meldungstexte,
#   die dem Nutzer den Bereich nennen. lyxos_syscall_ist_test vergleicht den
#   abgelegten Stand gegen das Kernel-Repo; dass die HANDGEPFLEGTE Zahl dazu
#   passt, hat bisher nichts geprueft. Genau diese Luecke liess `make test`
#   einen ganzen Tag bei Makefile:312 abbrechen.
#
# #2477: `@integrity(mode: scrubbed)` mit einem Intervall unter der Sweep-Dauer
#   STAPELTE die Durchgaenge: der naechste SIGALRM traf ein, bevor der vorige
#   fertig war, und das Programm kam nicht voran. Gemessen auf dieser Maschine
#   mit 30-Millionen-Schleife: `interval: 5` brauchte 14 061 ms, `interval: 200`
#   fuer dieselbe Arbeit 33 ms -- Faktor 426. Jetzt ueberspringt ein
#   ueberlappender Alarm seinen Durchgang.
#
# GEMESSEN WIRD ALS VERHAELTNIS, nicht als absolute Zeit: eine Zeitschwelle
# haengt an der Last der Maschine, das Verhaeltnis zweier Laeufe im selben Test
# nicht. Dazu die Struktur, damit ein Rueckfall auffaellt, und die ZUSAGE der
# Pruefung bleibt Sache von integrity_test (dort drei Faelle, u. a. rc 136).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

echo "--- #2560: die HANDGEPFLEGTE Obergrenze deckt sich mit dem abgelegten Stand ---"
# Der abgelegte Stand ist die Quelle (Werkzeug), die Zahl im Emitter die
# Handarbeit. Weichen sie ab, laesst der Compiler entweder eine Nummer durch,
# die es nicht gibt, oder weist eine ab, die der Kernel hat.
ist="$ROOT/work/lyxos/syscall-ist.txt"
emit="$ROOT/src/backend/lyxos/emit_lyxos.lyx"
if [ -f "$ist" ] && [ -f "$emit" ]; then
  # Zeile "300 <max> A" im abgelegten Stand
  stand="$(awk '$1 == "300" { print $2; exit }' "$ist")"
  # Obergrenze in lyxosNummerBelegt
  code="$(grep -oE 'nr >= 300 && nr <= [0-9]+' "$emit" | grep -oE '[0-9]+$' | head -1)"
  if [ -n "$stand" ] && [ "$stand" = "$code" ]; then
    pr ok "Obergrenze 300..$code deckt sich mit work/lyxos/syscall-ist.txt"
  else
    pr no "Obergrenze: Emitter sagt '$code', abgelegter Stand '$stand' -- tools/lyxos_syscall_abgleich.sh --schreiben und lyxosNummerBelegt nachziehen"
  fi
  # Die zwei Meldungstexte nennen denselben Bereich. Ein Nutzer, dem ein
  # falscher Bereich genannt wird, sucht an der falschen Stelle.
  n_text="$(grep -c "300-$code," "$emit")"
  if [ "$n_text" -ge 2 ]; then
    pr ok "beide Meldungstexte nennen 300-$code"
  else
    pr no "nur $n_text von 2 Meldungstexten nennen 300-$code"
  fi
else
  pr no "work/lyxos/syscall-ist.txt oder emit_lyxos.lyx fehlt"; pr no "Meldungstexte nicht pruefbar"
fi

echo "--- #2560: die zehn neuen Nummern stehen mit Argumentzahl im Stand ---"
argc="$ROOT/work/lyxos/syscall-argc.txt"
fehlt=0
for nr in 364 365 366 367 368 369 370 371 372 373; do
  grep -qE "^$nr[[:space:]]" "$argc" 2>/dev/null || fehlt=$((fehlt+1))
done
[ "$fehlt" -eq 0 ] && pr ok "364..373 haben eine Argumentzahl" \
  || pr no "$fehlt der zehn neuen Nummern fehlen in syscall-argc.txt"

echo "--- #2477: die Wiedereintrittssperre steht im Handler ---"
# Struktur, damit ein Rueckfall auffaellt; die WIRKUNG steht darunter.
if grep -q 'cg_e8(0x83); self.cg_e8(0x7F); self.cg_e8(0x30)' "$ROOT/src/codegen_x86.lyx"; then
  pr ok "Handler prueft den Merker bei [rdi+48]"
else
  pr no "keine Merkerpruefung im Scrub-Handler -- stapelt wieder?"
fi

echo "--- #2477: ein kurzes Intervall bremst, es blockiert nicht ---"
# A/B im selben Lauf: dieselbe Arbeit mit kurzem und mit langem Intervall.
# Vor dem Fix war das Verhaeltnis 426 (14 061 ms gegen 33 ms); erwartet wird
# jetzt eine einstellige Groessenordnung. Die Schranke ist bewusst weit (20),
# damit Last die Aussage nicht kippt -- 426 liegt weit darueber, 2,5 weit
# darunter.
mach() {   # interval -> Laufzeit in ms, oder -1
  printf '@integrity(mode: scrubbed, interval: %s)\nunit main;\nfn main(): int64 {\n  var i: int64 := 0;\n  var s: int64 := 0;\n  while (i < 30000000) { s := s + i; i := i + 1; }\n  return s %% 7;\n}\n' "$1" > "$TMP/s$1.lyx"
  ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s$1.lyx" -o "$TMP/s$1.bin" ) >"$TMP/c$1.log" 2>&1
  [ -s "$TMP/s$1.bin" ] || { echo -1; return; }
  # Vorbedingung: der Scrub muss ueberhaupt AKTIV sein. Ohne diese Pruefung
  # misst der Test ein Programm ohne @integrity und meldet alles gruen --
  # genau so ist mir die erste Messung zu diesem Issue misslungen (das
  # Attribut muss VOR `unit` stehen).
  grep -q METASAF2 "$TMP/s$1.bin" 2>/dev/null || { echo -2; return; }
  local a=$(date +%s%N)
  ( cd "$TMP" && timeout 120 "./s$1.bin" ) >/dev/null 2>&1
  echo $(( ($(date +%s%N) - a) / 1000000 ))
}
t_kurz="$(mach 5)"
t_lang="$(mach 200)"
if [ "$t_kurz" = "-2" ] || [ "$t_lang" = "-2" ]; then
  pr no "Scrub war nicht aktiv (kein METASAF2) -- Versuchsaufbau untauglich"
elif [ "$t_kurz" -lt 0 ] || [ "$t_lang" -lt 0 ]; then
  pr no "eines der Programme uebersetzte nicht: $(grep -m1 -iE 'error' "$TMP/c5.log" "$TMP/c200.log" 2>/dev/null | cut -c1-70)"
else
  [ "$t_lang" -lt 1 ] && t_lang=1
  v=$(( t_kurz / t_lang ))
  if [ "$v" -lt 20 ]; then
    pr ok "interval 5 gegen 200: ${t_kurz} ms gegen ${t_lang} ms, Faktor ${v} (vor dem Fix 426)"
  else
    pr no "interval 5 gegen 200: ${t_kurz} ms gegen ${t_lang} ms, Faktor ${v} -- die Durchgaenge stapeln wieder"
  fi
fi

echo
echo "tanz3_abi_scrub_test: PASS=$PASS FAIL=$FAIL"
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
