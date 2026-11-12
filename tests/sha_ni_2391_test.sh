#!/usr/bin/env bash
# #2391 — SHA-NI-Schnellweg fuer SHA-256.
#
# Das Hindernis des Issues: die Entwicklungsmaschine (i5-8250U, Kaby Lake R)
# hat KEIN SHA-NI, der Schnellweg ist dort nicht ausfuehrbar. GEMESSEN
# emuliert `qemu-x86_64 -cpu max` ihn aber korrekt (`-cpu EPYC-Rome`
# ebenfalls, `-cpu Icelake-Server` NICHT — das CPU-Modell entscheidet).
# Damit ist der Verhaltensnachweis hier fuehrbar. Die MESSUNG (Abschnitt 6)
# braucht echte Hardware und laeuft darum nur nativ: eine emulierte Zeit ist
# fuer Geschwindigkeit wertlos. Auf einer CPU ohne SHA-NI prueft derselbe
# Abschnitt die Nullprobe — beide Wege fahren dort denselben Code und muessen
# gleich schnell sein; eine Sonde, die dort einen Unterschied findet, misst
# sich selbst.
#
# Vier Nachweise:
#   1. NIST-Vektoren ueber den Schnellweg, unter qemu. Darunter ein Fall mit
#      ZWEI Bloecken in einem Aufruf — ein Einblockfall waere auch von einer
#      Fassung erfuellt, die den Blockzaehler ignoriert.
#   2. Beide Wege gegeneinander: Hardware und erzwungener Softwareweg muessen
#      Byte fuer Byte denselben Hash liefern. Ohne den Umschalter
#      (SHA256ForceSoftware) waere der Softwareweg auf einer SHA-NI-CPU nicht
#      mehr erreichbar und eine Regression dort blind.
#   3. Ohne SHA-NI darf NICHTS ausgefuehrt werden, was es braucht: nativ muss
#      derselbe Hash herauskommen, und der Schnellweg darf nicht greifen.
#   5. Erschoepfend ueber die Laengen 0..320: Schnellweg gegen Softwareweg,
#      und `Sha256Update` stueckweise gegen `SHA256` in einem Zug. Letzteres
#      prueft die ZWEITE Mehrblockstelle — `Sha256Update` rechnet die
#      Blockzahl selbst (#2391 Punkt 2).
#   6. Messung: ist der Schnellweg ueberhaupt schneller? Bis #2391 Punkt 1
#      war das unbelegt, und es war sein ganzer Zweck.
#   4. Am Erzeugnis: die Zahl der emittierten SHA-NI-Befehle je Aufrufstelle
#      gegen die verifizierte Vorlage, und die K-Tabelle nur EINMAL im
#      Datensegment (nicht je Aufrufstelle).
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP $1"; SKIP=$((SKIP+1)); }

QEMU=""
command -v qemu-x86_64 >/dev/null 2>&1 && QEMU="qemu-x86_64 -cpu max"
HAT_SHANI=0
grep -qm1 " sha_ni" /proc/cpuinfo 2>/dev/null && HAT_SHANI=1

# ── 1./3. NIST-Vektoren ─────────────────────────────────────────────────────
if "$LYXC" --std-path=. tests/sha_ni_2391/kat.lyx -o "$TMP/kat" >"$TMP/b1.log" 2>&1; then
  ok "kat_uebersetzt"
  nativ=$("$TMP/kat" 2>&1)
  if [ "$HAT_SHANI" = "1" ]; then
    # Diese CPU hat SHA-NI: der Schnellweg MUSS laufen und stimmen.
    if echo "$nativ" | grep -q '^ALL PASS$' && echo "$nativ" | grep -q '^PASS abc$'; then
      ok "kat_nativ_schnellweg"
    else
      bad "kat_nativ_schnellweg"; echo "$nativ" | head -6
    fi
  else
    # Ohne SHA-NI muss der Test sich selbst ueberspringen, nicht abstuerzen.
    if echo "$nativ" | grep -q '^SKIP: diese CPU hat kein SHA-NI'; then
      ok "kat_nativ_meldet_fehlendes_shani"
    else
      bad "kat_nativ_meldet_fehlendes_shani"; echo "$nativ" | head -6
    fi
  fi
  # Unter qemu mit zugesagtem SHA-NI
  if [ -n "$QEMU" ]; then
    q=$($QEMU "$TMP/kat" 2>&1 | grep -v "TCG doesn't support")
    n=$(echo "$q" | grep -c '^PASS ')
    if [ "$n" -eq 3 ] && echo "$q" | grep -q '^ALL PASS$'; then
      ok "kat_qemu_3_nist_vektoren"
    else
      bad "kat_qemu_3_nist_vektoren (PASS=$n)"; echo "$q" | head -8
    fi
  else
    skip "kat_qemu (qemu-x86_64 fehlt)"
  fi
else
  bad "kat_uebersetzt"; tail -5 "$TMP/b1.log"
fi

# ── 2. Beide Wege gegeneinander ─────────────────────────────────────────────
if "$LYXC" --std-path=. tests/sha_ni_2391/beide_wege.lyx -o "$TMP/bw" >"$TMP/b2.log" 2>&1; then
  ok "beide_wege_uebersetzt"
  for umg in nativ qemu; do
    if [ "$umg" = "qemu" ]; then
      [ -n "$QEMU" ] || { skip "beide_wege_qemu (qemu fehlt)"; continue; }
      out=$($QEMU "$TMP/bw" 2>&1 | grep -v "TCG doesn't support")
    else
      out=$("$TMP/bw" 2>&1)
    fi
    hw=$(echo "$out" | sed -n 's/^abc  hw: //p')
    sw=$(echo "$out" | sed -n 's/^abc  sw: //p')
    erw="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    if [ "$hw" = "$erw" ] && [ "$sw" = "$erw" ] && echo "$out" | grep -q '^GLEICH$'; then
      ok "beide_wege_${umg}_identisch"
    else
      bad "beide_wege_${umg}_identisch"; echo "$out" | head -10
    fi
  done
else
  bad "beide_wege_uebersetzt"; tail -5 "$TMP/b2.log"
fi

# ── 4. Erzeugnis: Befehlszahlen und EINE K-Tabelle ──────────────────────────
# kat.lyx ruft sha256_compress dreimal; der Builtin ist eingesetzt, die Zahlen
# sind also je Aufrufstelle durch drei zu teilen. Die Sollwerte stammen aus
# einer Assembler-Fassung, die beide NIST-Vektoren bitgleich liefert.
if [ -f "$TMP/kat" ]; then
  hx=$(xxd -p "$TMP/kat" | tr -d '\n')
  zahl() { grep -o "$1" <<<"$hx" | wc -l; }
  r2=$(zahl 0f38cb); m1=$(zahl 0f38cc); m2=$(zahl 0f38cd)
  if [ "$r2" = "96" ] && [ "$m1" = "36" ] && [ "$m2" = "36" ]; then
    ok "erzeugnis_32_rnds2_12_msg1_12_msg2_je_aufrufstelle"
  else
    bad "erzeugnis_befehlszahlen (rnds2=$r2/96 msg1=$m1/36 msg2=$m2/36)"
  fi
  # K-Tabelle: die ersten vier Konstanten als Block, little-endian
  kblk="982f8a4291443771cffbc0b5a5dbb5e9"
  kn=$(grep -o "$kblk" <<<"$hx" | wc -l)
  if [ "$kn" = "1" ]; then
    ok "erzeugnis_k_tabelle_einmal"
  else
    bad "erzeugnis_k_tabelle_einmal (gefunden ${kn}x, erwartet 1)"
  fi
fi


# ── 5. Erschoepfend ueber alle Laengen, beide Wege und beide Stellen ────────
if "$LYXC" --std-path=. tests/sha_ni_2391/laengen.lyx -o "$TMP/ln" >"$TMP/b5.log" 2>&1; then
  ok "laengen_uebersetzt"
  for umg in nativ qemu; do
    if [ "$umg" = "qemu" ]; then
      [ -n "$QEMU" ] || { skip "laengen_qemu (qemu fehlt)"; continue; }
      out=$($QEMU "$TMP/ln" 2>&1 | grep -v "TCG doesn't support")
    else
      out=$("$TMP/ln" 2>&1)
    fi
    sn=$(echo "$out" | sed -n 's/^shani_verfuegbar=//p')
    if echo "$out" | grep -q '^ALLE GLEICH$' && [ "$(echo "$out" | sed -n 's/^fehler_wege=//p')" = "0" ]; then
      # Unter qemu MUSS der Schnellweg gelaufen sein, sonst sagt die
      # Gleichheit nur, dass der Softwareweg mit sich selbst uebereinstimmt.
      if [ "$umg" = "qemu" ] && [ "$sn" != "1" ]; then
        bad "laengen_qemu_schnellweg_lief_nicht (shani=$sn)"
      else
        ok "laengen_${umg}_alle_gleich (shani=$sn)"
      fi
    else
      bad "laengen_${umg}_alle_gleich"; echo "$out" | head -8
    fi
  done
else
  bad "laengen_uebersetzt"; tail -5 "$TMP/b5.log"
fi

# ── 6. Messung: Schnellweg gegen Softwareweg ────────────────────────────────
# Nur NATIV. Unter qemu waere jede Zeit wertlos (Emulation belegt
# Korrektheit, nie Geschwindigkeit).
if "$LYXC" --std-path=. tests/sha_ni_2391/takte.lyx -o "$TMP/tk" >"$TMP/b6.log" 2>&1; then
  ok "takte_uebersetzt"
  PIN=""; command -v taskset >/dev/null 2>&1 && PIN="taskset -c 1"
  mout=$(LC_ALL=C $PIN "$TMP/tk" 2>&1)
  echo "$mout" | sed 's/^/    | /'
  if ! echo "$mout" | grep -q '^FERTIG$'; then
    bad "takte_lief_durch"; 
  else
    ok "takte_lief_durch"
    # Faktor und Rauschboden je Laenge als Promille einlesen.
    prom() { echo "$1" | tr -d ' ' | sed -n "s/^$2=\([0-9]*\),\([0-9]*\)$/\1\2/p"; }
    fakt=""; rausch=""
    while IFS= read -r z; do
      v=$(prom "$z" faktor_sw_durch_hw);   [ -n "$v" ] && fakt="$fakt $v"
      v=$(prom "$z" rauschboden_faktor);   [ -n "$v" ] && rausch="$rausch $v"
    done <<<"$mout"
    nf=$(echo $fakt | wc -w)
    if [ "$nf" != "6" ]; then
      bad "takte_sechs_laengen_gemessen (gefunden=$nf)"
    elif [ "$HAT_SHANI" = "1" ]; then
      # Diese CPU kann den Schnellweg. Gemessen an den langen Laengen, wo der
      # Kern und nicht der Aufrufaufwand zaehlt: mindestens Faktor 2,0. Die
      # Schwelle liegt weit ueber jedem Rauschboden, den die Sonde selbst
      # meldet; sie prueft den WERT, nicht die Existenz einer Zahl.
      l16=$(echo $fakt | cut -d" " -f5); l64=$(echo $fakt | cut -d" " -f6)
      if [ "$l16" -ge 2000 ] && [ "$l64" -ge 2000 ]; then
        ok "takte_schnellweg_mindestens_2x (16K=$l16 64K=$l64 Promille)"
      else
        bad "takte_schnellweg_mindestens_2x (16K=$l16 64K=$l64 Promille, erwartet >=2000)"
      fi
    else
      # Keine SHA-NI: beide Wege sind derselbe Code. Jede Abweichung ueber
      # 25 % ist die Sonde selbst, nicht der Unterschied zweier Wege.
      schlecht=0
      for v in $fakt; do
        [ "$v" -lt 750 ] && schlecht=$((schlecht+1))
        [ "$v" -gt 1250 ] && schlecht=$((schlecht+1))
      done
      if [ "$schlecht" = "0" ]; then
        ok "takte_nullprobe_beide_wege_gleich_schnell ($fakt Promille)"
      else
        bad "takte_nullprobe (Faktoren $fakt Promille, erwartet 750..1250)"
      fi
      skip "takte_schnellweg (diese CPU hat kein SHA-NI — Vergleich nicht fuehrbar)"
    fi
  fi
else
  bad "takte_uebersetzt"; tail -5 "$TMP/b6.log"
fi
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ] || exit 1
