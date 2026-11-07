#!/usr/bin/env bash
# #2391 — SHA-NI-Schnellweg fuer SHA-256.
#
# Das Hindernis des Issues: die Entwicklungsmaschine (i5-8250U, Kaby Lake R)
# hat KEIN SHA-NI, der Schnellweg ist dort nicht ausfuehrbar. GEMESSEN
# emuliert `qemu-x86_64 -cpu max` ihn aber korrekt (`-cpu EPYC-Rome`
# ebenfalls, `-cpu Icelake-Server` NICHT — das CPU-Modell entscheidet).
# Damit ist der Verhaltensnachweis hier fuehrbar; Takte braucht echte
# Hardware und sind NICHT Gegenstand dieses Tests.
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

echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ] || exit 1
