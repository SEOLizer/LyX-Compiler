#!/usr/bin/env bash
# tests/nurlyxos_2427_test.sh — #2427: die Liste der zielgebundenen Builtins
# wahr halten.
#
# BEFUND. Die 110 LyxOS-Kernelaufrufe sind in sema zielunabhaengig
# registriert. Auf einem anderen Ziel scheiterte der Aufruf erst spaet und mit
# einer Meldung, die die Ursache nicht nennt — auf x86 "undefined function
# 'sys_rdtsc' — no codegen implementation found", auf arm64 sogar nur
# "Builtin-ID 214 wird im Linux-Zweig nicht behandelt", ohne den Namen. Seit
# #2427 steht die Auskunft in src/backend/builtin_ziele.lyx und ein Gate am
# Anfang von `lowerCall` weist den Aufruf ab, bevor eine ID vergeben wird.
#
# WOHER DIE LISTE KOMMT: gemessen, nicht abgeschrieben. Je Name ein
# Uebersetzungsversuch auf x86, arm64 und lyxos; aufgenommen wurde, was auf
# lyxos uebersetzt und auf den beiden anderen nicht. Geurteilt nach
# EXIT-CODE — `lyxc` meldet auch als "sema error (line N)", ohne `error:`.
#
# WAS DIESER TEST NICHT LEISTET, und das ist eine echte Grenze: ob ein
# gelisteter Name OHNE das Gate auf x86 funktionieren wuerde, laesst sich mit
# dem Gate nicht mehr messen — es weist ihn vorher ab. Die Liste kann also
# nicht gegen "zu weit" geprueft werden, indem man ihre Eintraege einzeln
# nachmisst. Deshalb prueft Teil 3 die GEGENRICHTUNG an Namen, die NICHT in
# der Liste stehen: waere die Liste zu weit gefasst, traefe sie auch die, und
# der Test wird rot. Ein Test, der nur zeigt, dass die gelisteten Namen
# abgewiesen werden, waere auch von einer Liste mit allen 484 Namen erfuellt
# (#1823).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
LISTE="$ROOT/src/backend/builtin_ziele.lyx"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Namen aus der Liste lesen — aus der QUELLE, nicht aus einer Kopie daneben.
mapfile -t NAMEN < <(grep -oE '_bzEq\(nm, nl, "[A-Za-z_0-9]+"c' "$LISTE" \
                     | sed 's/.*"\(.*\)"c/\1/')
if [ "${#NAMEN[@]}" -eq 0 ]; then
  no "Liste lesen" "keine Namen in $LISTE gefunden"
  echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
echo "gelesen: ${#NAMEN[@]} zielgebundene Namen aus src/backend/builtin_ziele.lyx"

uebersetzt() { # $1 = Name, $2 = --target (leer = x86), $3 = Argumentliste
  printf 'unit main;\nfn main(): int64 { %s(%s); return 0; }\n' "$1" "$3" > "$TMP/n.lyx"
  (cd "$ROOT" && timeout 60 "$LYXC" --std-path="$ROOT" "$TMP/n.lyx" $2 \
     -o "$TMP/n.out" >"$TMP/u.log" 2>&1)
}

# Die Stelligkeit steht nirgends — sie gehoert auch nicht in die Liste, denn
# fuer die Frage "welches Ziel kennt den Namen" ist sie belanglos. Der Test
# muss sie aber treffen: mit null Argumenten scheitert `sys_udp_open(1)` auch
# auf lyxos, und daraus "lyxos kennt den Namen nicht" zu lesen waere falsch
# (beim ersten Lauf genau so passiert). Gesucht wird deshalb die erste
# Argumentform, die lyxos annimmt; mit DERSELBEN wird dann x86 geprueft.
ARGFORMEN=("" "1" "1, 1" "1, 1, 1" "1, 1, 1, 1")
lyxos_args() { # $1 = Name; Ausgabe: Argumentliste, oder Rueckgabe 1
  local a
  for a in "${ARGFORMEN[@]}"; do
    if uebersetzt "$1" "--target=lyxos" "$a"; then printf '%s' "$a"; return 0; fi
  done
  return 1
}

# ── 1. Jeder gelistete Name uebersetzt auf lyxos ───────────────────────────
# Diese Haelfte ist vom Gate UNBERUEHRT (dort feuert es nicht) und damit die
# eigentliche Zusicherung: der Name gehoert wirklich zu lyxos. Stimmte sie
# nicht, waere der Eintrag eine Behauptung.
fehlt=""
declare -A ARGS
for n in "${NAMEN[@]}"; do
  if a="$(lyxos_args "$n")"; then ARGS["$n"]="$a"; else fehlt="$fehlt $n"; fi
done
if [ -z "$fehlt" ]; then
  ok "alle ${#NAMEN[@]} gelisteten Namen uebersetzen mit --target=lyxos"
else
  no "Liste enthaelt Namen, die lyxos nicht kennt" "$(echo $fehlt | cut -c1-200)"
  echo "    Entweder gehoert der Name nicht in die Liste, oder er ist auf lyxos"
  echo "    kaputt — dann ist das ein eigener Defekt und kein Listenfehler."
fi

# ── 2. Jeder gelistete Name wird auf x86 MIT GENANNTER URSACHE abgewiesen ──
# Geprueft wird nicht "scheitert", sondern "scheitert mit dieser Meldung":
# ein Name, der aus einem anderen Grund scheitert, hat das Gate nie erreicht,
# und genau so sah der Defekt vorher aus.
ohneGrund=""
for n in "${NAMEN[@]}"; do
  [ -z "${ARGS[$n]+x}" ] && continue   # oben schon als Listenfehler gemeldet
  if uebersetzt "$n" "" "${ARGS[$n]}"; then
    ohneGrund="$ohneGrund $n(uebersetzt)"
  elif ! grep -q "gibt es nur mit --target=lyxos" "$TMP/u.log"; then
    ohneGrund="$ohneGrund $n(andere-Meldung)"
  fi
done
if [ -z "$ohneGrund" ]; then
  ok "alle ${#NAMEN[@]} nennen auf x86 die Ursache statt 'undefined function'"
else
  no "Namen ohne genannte Ursache" "$(echo $ohneGrund | cut -c1-200)"
fi

# ── 3. Gegenrichtung: die Liste ist nicht zu weit ──────────────────────────
# Namen, die es ueberall gibt, duerfen NICHT getroffen werden. Ohne diese
# Haelfte waere eine Liste mit allen 484 Namen genauso "erfuellt" — und jedes
# Programm waere unuebersetzbar.
# Die Kontrollaufrufe stehen mit ECHTER Stelligkeit da, nicht als `name()`.
# Gemessen (Gegenprobe 3, `StrLen` in die Liste eingetragen): mit null
# Argumenten scheitert `StrLen()` schon an der Stelligkeit in sema, lange vor
# dem Gate in `lowerCall` — und genau diesen Fall uebergeht die Pruefung
# unten bewusst. Damit war sie praktisch leer: sie konnte gar nicht rot
# werden. Ein Aufruf, der OHNE Gate uebersetzt, ist die Voraussetzung dafuer,
# dass "wird vom Gate gefangen" ueberhaupt messbar ist.
KONTROLLEN=(
  'PrintLn("x"c)'
  'PrintStr("x"c)'
  'StrLen("ab"c)'
  'IntToStr(7)'
  'StrConcat("a"c, "b"c)'
  'open("/tmp/lyxk"c, 0, 0)'
  'close(1)'
  'write(1, "x"c, 1)'
  'mkdir("/tmp/lyxk"c, 493)'
  'unlink("/tmp/lyxk"c)'
  'rmdir("/tmp/lyxk"c)'
  'truncate("/tmp/lyxk"c, 0)'
  'lseek(1, 0, 0)'
  'peek8(0)'
  'exit(0)'
)
# Geprueft wird auf x86 UND auf arm64, und arm64 ist der wichtigere Fall.
# Gemessen (Gegenprobe 1, `PrintLn` in der Liste): auf x86 sitzt das Gate nur
# an der undefined-function-Meldestelle — ein Name, den codegen_x86 selbst
# umsetzt, erreicht sie nie und wird dort gar nicht gefangen. Das Gate, das
# legitimen Code brechen KANN, ist das in ir_lower, und es trifft arm64 und
# riscv. Eine zu weite Liste waere also durch eine x86-Pruefung allein
# hindurchgelaufen.
getroffen=""
leer=""
for c in "${KONTROLLEN[@]}"; do
  for z in "" "--target=arm64"; do
    printf 'unit main;\nfn main(): int64 { %s; return 0; }\n' "$c" > "$TMP/k.lyx"
    if (cd "$ROOT" && timeout 60 "$LYXC" --std-path="$ROOT" "$TMP/k.lyx" $z \
          -o "$TMP/k.out" >"$TMP/u.log" 2>&1); then
      :
    elif grep -q "gibt es nur mit --target=lyxos" "$TMP/u.log"; then
      getroffen="$getroffen ${c%%(*}${z:+(arm64)}"
    else
      # Scheitert aus einem anderen Grund -> dieser Kontrollfall kann das Gate
      # nicht messen und waere eine stille Luecke in dieser Pruefung.
      leer="$leer ${c%%(*}${z:+(arm64)}"
    fi
  done
done
if [ -n "$leer" ]; then
  no "Kontrollaufruf uebersetzt ohnehin nicht" "$(echo $leer | cut -c1-200)"
  echo "    Ein Kontrollfall, der aus anderem Grund scheitert, kann nicht zeigen,"
  echo "    dass das Gate ihn nicht faengt — die Aufrufform gehoert richtiggestellt."
elif [ -z "$getroffen" ]; then
  ok "kein zielneutraler Kontrollaufruf wird vom Gate gefangen (x86 und arm64, ${#KONTROLLEN[@]} Faelle)"
else
  no "Liste ist zu weit" "$getroffen werden abgewiesen, obwohl zielneutral"
fi

# ── 4. Auf lyxos faengt das Gate nichts ────────────────────────────────────
# Die Umkehrung von Teil 2: waere die Zielbedingung falsch herum, wuerde
# lyxos seine eigenen Aufrufe abweisen — und das Ziel, fuer das sie gedacht
# sind, waere das einzige, auf dem sie nicht gehen.
probe="${NAMEN[0]}"
if uebersetzt "$probe" "--target=lyxos" "${ARGS[$probe]:-}"; then
  ok "das Gate feuert auf lyxos nicht ($probe)"
else
  no "Gate feuert auf lyxos" "$probe wird auf seinem eigenen Ziel abgewiesen"
fi

# ── 5. Die Liste ist nicht zu ENG ──────────────────────────────────────────
# Die Teile 1-4 pruefen nur, was in der Liste STEHT. Ein neuer zielgebundener
# Builtin, der fehlt, faellt dabei nicht auf — und bekaeme wieder die Meldung,
# gegen die #2427 angetreten ist. Deshalb hier der Durchgang ueber ALLE in
# sema registrierten Namen: wer auf lyxos uebersetzt und auf x86 nicht (und
# zwar aus einem anderen Grund als dem Gate), gehoert in die Liste.
#
# Erhoben wird aus sema selbst, nicht aus einer Kopie daneben.
mapfile -t ALLE < <(grep -oE '_regBuiltin\("[A-Za-z_0-9]+"' "$ROOT/src/sema.lyx" \
                    | sed 's/.*"\(.*\)"/\1/' | sort -u)
inListe() { local x; for x in "${NAMEN[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

nachzutragen=""
for n in "${ALLE[@]}"; do
  inListe "$n" && continue
  a="$(lyxos_args "$n")" || continue          # lyxos kennt ihn nicht -> nicht zielgebunden
  uebersetzt "$n" "" "$a" && continue          # x86 kennt ihn auch -> zielneutral
  grep -q "gibt es nur mit --target=lyxos" "$TMP/u.log" && continue   # Gate (kann nicht sein, s.o.)
  nachzutragen="$nachzutragen $n"
done
if [ -z "$nachzutragen" ]; then
  ok "kein zielgebundener Name fehlt in der Liste (${#ALLE[@]} geprueft)"
else
  no "Liste ist zu eng" "$(echo $nachzutragen | cut -c1-300)"
  echo "    Diese Namen uebersetzen mit --target=lyxos und auf x86 nicht. Ohne"
  echo "    Eintrag in src/backend/builtin_ziele.lyx bekommen sie wieder die"
  echo "    Meldung aus #2427, die die Ursache nicht nennt."
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
