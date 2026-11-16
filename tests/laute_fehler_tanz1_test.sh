#!/usr/bin/env bash
# tests/laute_fehler_tanz1_test.sh — zwei stille Defaults, die jetzt melden.
#
# #2539: Die Unterdrueckung der CAPS-Warnung prueft ein 6-Zeichen-PRAEFIX auf
#   "system". Das traf jeden system-Namen, also auch die fuenf, die KEINE
#   impliziten Rechte sind (system.admin, .namespace, .tty, .env,
#   .unsafe.format_string). Gemessen schwiegen alle elf deklarierbaren
#   system-Namen. Dieselbe Klasse wie #1823 (`process` traf `process.exit` und
#   setzte PLEDGE_EXEC) und #1826 (`audio`).
#
# #2535: `mmap`/`StrNew` mit einer Groesse, die zur Uebersetzungszeit <= 0 ist,
#   uebersetzte still. Der Laufzeitwaechter in emitAlloc gibt dort 0 zurueck --
#   richtig fuer variable Werte, ein stiller Default fuer konstante. Auf LyxOS
#   ist eine NEGATIVE Groesse zudem ein interner Befehl (#1861), keine
#   Allokation.
#
# BEIDE Seiten werden geprueft. Ein Test, der nur zeigt, dass die falschen
# Faelle melden, waere auch von einer Fassung erfuellt, die ALLES meldet --
# und die waere genauso falsch, nur in die andere Richtung.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

# cap_meldet <name> -> "ja" wenn die CAPS-Warnung kommt
cap_meldet() {
  printf 'unit main;\n@capabilities([%s])\nfn main(): int64 { return 0; }\n' "$1" > "$TMP/c.lyx"
  if ( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos \
        "$TMP/c.lyx" -o "$TMP/c.lbf" ) 2>&1 | grep -qE "setzt kein Bit in der CAPS-TLV"; then
    echo ja
  else
    echo nein
  fi
}

echo "--- #2539 Teil 1: die fuenf IMPLIZITEN Rechte bleiben stumm ---"
# #1755: jedes LBF-Programm hat sie ohnehin, eine Zusage darauf ist also keine
# unerfuellte Zusage.
for n in system.exit system.memory.heap system.memory.stack system.rand system.time; do
  [ "$(cap_meldet $n)" = "nein" ] && pr ok "$n bleibt stumm" || pr no "$n meldet, ist aber implizit"
done
# system.config hat ein BIT (0x80, #1797) und erreicht die Stelle nie.
[ "$(cap_meldet system.config)" = "nein" ] && pr ok "system.config bleibt stumm (hat ein Bit)" \
  || pr no "system.config meldet, hat aber ein Bit"

echo "--- #2539 Teil 2: die fuenf OHNE Bit melden jetzt ---"
for n in system.admin system.namespace system.tty system.env system.unsafe.format_string; do
  [ "$(cap_meldet $n)" = "ja" ] && pr ok "$n meldet" || pr no "$n schweigt weiter (Praefix zurueck?)"
done

echo "--- #2539 Teil 3: die Praefixpruefung ist weg ---"
# Die Wirkung haengt oben; hier die Struktur, damit ein Rueckfall auffaellt.
if grep -qE '_capMatch\(capPtr2, capLen2, "system"c, 6\)' "$ROOT/src/lyxc.lyx"; then
  pr no "die 6-Zeichen-Praefixpruefung auf system steht wieder da"
else
  pr ok "keine Praefixpruefung auf system mehr"
fi

echo "--- #2535: konstante Groesse <= 0 meldet, gueltige nicht ---"
# erw: ja = Warnung erwartet
gr_test() {  # name, ausdruck, erwartung
  printf 'unit main;\nfn main(): int64 { return %s; }\n' "$2" > "$TMP/g.lyx"
  local got=nein
  if ( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos \
        "$TMP/g.lyx" -o "$TMP/g.lbf" ) 2>&1 | grep -qE "^warning:.*erreicht den Kernel nicht"; then
    got=ja
  fi
  if [ "$got" = "$3" ]; then pr ok "$1 (Warnung=$got)"; else pr no "$1: Warnung=$got, erwartet $3"; fi
}
gr_test "mmap(.., 0, ..)"      "mmap(0, 0, 3, 34, 0-1, 0)"      ja
gr_test "mmap(.., -4096, ..)"  "mmap(0, 0-4096, 3, 34, 0-1, 0)" ja
gr_test "mmap(.., 4096, ..)"   "mmap(0, 4096, 3, 34, 0-1, 0)"   nein
gr_test "StrNew(0)"            "StrNew(0)"                      ja
gr_test "StrNew(16)"           "StrNew(16)"                     nein

echo "--- #2535: die Warnung ist eine WARNUNG, kein Fehler ---"
# Der Aufruf ist nicht ungueltig, nur wirkungslos. Ein Fehler wuerde
# Bestandscode brechen, der ein mmap(0, 0, ...) als Platzhalter stehen hat.
printf 'unit main;\nfn main(): int64 { return mmap(0, 0, 3, 34, 0-1, 0); }\n' > "$TMP/w.lyx"
( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos \
    "$TMP/w.lyx" -o "$TMP/w.lbf" ) >/dev/null 2>&1
[ -s "$TMP/w.lbf" ] && pr ok "Erzeugnis entsteht trotz Warnung" \
  || pr no "kein Erzeugnis -- die Warnung ist zum Fehler geworden"

echo "--- #2535: eine VARIABLE Groesse warnt nicht ---"
# Dort ist der Laufzeitwaechter richtig und die 0 die einzige sinnvolle Antwort.
printf 'unit main;\nfn main(): int64 { var n: int64 := 0; return mmap(0, n, 3, 34, 0-1, 0); }\n' > "$TMP/v.lyx"
if ( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos \
      "$TMP/v.lyx" -o "$TMP/v.lbf" ) 2>&1 | grep -qE "^warning:.*erreicht den Kernel nicht"; then
  pr no "variable Groesse warnt -- die Faltung nimmt `var` fuer konstant"
else
  pr ok "variable Groesse warnt nicht"
fi

echo
echo "laute_fehler_tanz1_test: PASS=$PASS FAIL=$FAIL"
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
