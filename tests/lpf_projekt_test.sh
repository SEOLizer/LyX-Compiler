#!/usr/bin/env bash
# tests/lpf_projekt_test.sh — Projektdatei *.lpf.
#
# `lyxc projekt.lpf` liest Quelle, Ziel, Ausgabe, Include-Pfade, Schalter und
# LPM-Pakete aus einer Datei. Gemessen wird die WIRKUNG: es entsteht das
# richtige Erzeugnis am richtigen Ort, mit den Schaltern aus der Datei — und
# ohne den jeweiligen Eintrag scheitert derselbe Bau.
#
# Die Gegenproben sind der eigentliche Inhalt: ein Test, der nur zeigt, dass
# eine gueltige Projektdatei uebersetzt, waere auch von einem Compiler erfuellt,
# der die Datei GAR NICHT liest und die Standardwerte nimmt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

mkdir -p "$TMP/p/apps" "$TMP/p/lib" "$TMP/p/build"
printf 'fn main(): int64 { PrintLn("aus dem Projekt"c); return 7; }\n' > "$TMP/p/apps/demo.lyx"
printf 'unit hilf;\npub fn Zahl(): int64 { return 9; }\n' > "$TMP/p/lib/hilf.lyx"
printf 'import hilf;\nfn main(): int64 { return Zahl(); }\n' > "$TMP/p/apps/nutzt.lyx"

ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
no()   { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# --- Grundfall: Quelle, Ziel, Ausgabe aus der Datei ------------------------
cat > "$TMP/p/demo.lpf" <<'L'
# Kommentar
[projekt]
quelle  = "apps/demo.lyx"
ziel    = "linux"
ausgabe = "build/demo"
L
if (cd "$TMP/p" && timeout 120 "$LYXC" --std-path="$ROOT" demo.lpf >"$TMP/d.log" 2>&1); then
  if [ -x "$TMP/p/build/demo" ]; then
    "$TMP/p/build/demo" >/dev/null 2>&1
    [ $? -eq 7 ] && ok "quelle_ziel_ausgabe" || no "quelle_ziel_ausgabe" "falscher Rueckgabewert"
  else
    no "quelle_ziel_ausgabe" "build/demo fehlt — `ausgabe` wurde nicht angewandt"
  fi
else
  no "quelle_ziel_ausgabe" "$(grep -im1 'error\|nicht' "$TMP/d.log")"
fi

# --- Aus fremdem Arbeitsverzeichnis: relative Pfade zaehlen von der .lpf ---
# Ohne diese Regel uebersetzt dieselbe Datei je nach Aufrufort etwas anderes.
rm -f "$TMP/p/build/demo"
if (cd "$TMP" && timeout 120 "$LYXC" --std-path="$ROOT" p/demo.lpf >"$TMP/f.log" 2>&1) && [ -x "$TMP/p/build/demo" ]; then
  ok "relative_pfade_zaehlen_von_der_datei"
else
  no "relative_pfade_zaehlen_von_der_datei" "$(grep -im1 'error\|nicht' "$TMP/f.log")"
fi

# --- Include-Pfad aus [include] -------------------------------------------
cat > "$TMP/p/inc.lpf" <<'L'
[projekt]
quelle  = "apps/nutzt.lyx"
ausgabe = "build/nutzt"

[include]
pfade = ["lib"]
L
if (cd "$TMP/p" && timeout 120 "$LYXC" --std-path="$ROOT" inc.lpf >"$TMP/i.log" 2>&1) && [ -x "$TMP/p/build/nutzt" ]; then
  "$TMP/p/build/nutzt" >/dev/null 2>&1
  [ $? -eq 9 ] && ok "include_pfad_wirkt" || no "include_pfad_wirkt" "falscher Rueckgabewert"
else
  no "include_pfad_wirkt" "$(grep -im1 'error\|nicht gefunden' "$TMP/i.log")"
fi

# Gegenprobe: OHNE [include] darf derselbe Bau NICHT gelingen.
cat > "$TMP/p/ohne.lpf" <<'L'
[projekt]
quelle  = "apps/nutzt.lyx"
ausgabe = "build/nutzt2"
L
if (cd "$TMP/p" && timeout 120 "$LYXC" --std-path="$ROOT" ohne.lpf >"$TMP/o.log" 2>&1); then
  no "ohne_include_scheitert" "uebersetzte trotzdem — der Include-Pfad kam von woanders"
else
  ok "ohne_include_scheitert"
fi

# --- Kommandozeile ueberstimmt die Datei ----------------------------------
# Ohne diesen Vorrang waere ein Gegenversuch nur durch Aendern der Datei
# moeglich.
if (cd "$TMP/p" && timeout 200 "$LYXC" --std-path="$ROOT" demo.lpf --target=arm64 -o build/demo.a64 >"$TMP/c.log" 2>&1); then
  if file "$TMP/p/build/demo.a64" 2>/dev/null | grep -q "aarch64"; then
    ok "kommandozeile_ueberstimmt_datei"
  else
    no "kommandozeile_ueberstimmt_datei" "kein aarch64-Erzeugnis — Datei hat gewonnen"
  fi
else
  no "kommandozeile_ueberstimmt_datei" "$(grep -im1 'error' "$TMP/c.log")"
fi

# --- Schalter aus [schalter] laufen durch denselben Parser -----------------
# Gemessen an einem Schalter mit sichtbarer Wirkung: --map-file legt
# <ausgabe>.map an.
cat > "$TMP/p/sch.lpf" <<'L'
[projekt]
quelle  = "apps/demo.lyx"
ausgabe = "build/demo_map"

[schalter]
liste = ["--map-file"]
L
rm -f "$TMP/p/build/demo_map.map"
if (cd "$TMP/p" && timeout 120 "$LYXC" --std-path="$ROOT" sch.lpf >"$TMP/s.log" 2>&1) && [ -s "$TMP/p/build/demo_map.map" ]; then
  ok "schalter_wirken"
else
  no "schalter_wirken" "keine .map-Datei — [schalter] blieb wirkungslos"
fi

# --- Meldungen statt stiller Annahme --------------------------------------
meldet() {  # name, inhalt, erwarteter Meldungsteil
  printf '%s\n' "$2" > "$TMP/p/bad.lpf"
  if (cd "$TMP/p" && timeout 120 "$LYXC" --std-path="$ROOT" bad.lpf >"$TMP/b.log" 2>&1); then
    no "$1" "uebersetzte klaglos"
  else
    case "$(cat "$TMP/b.log")" in
      *"$3"*) ok "$1" ;;
      *) no "$1" "andere Meldung: $(grep -im1 'lpf\|error' "$TMP/b.log")" ;;
    esac
  fi
}

meldet "fehlende_quelle_meldet" '[projekt]
ziel = "linux"' "kein \`quelle"

meldet "unbekannter_abschnitt_meldet" '[projekt]
quelle = "apps/demo.lyx"
[incldue]
pfade = ["lib"]' "unbekannter Abschnitt"

meldet "unbekannter_schluessel_meldet" '[projekt]
quelle = "apps/demo.lyx"
zeil = "linux"' "unbekannter Schluessel"

# Auch in den Listenabschnitten: ein Tippfehler im SCHLUESSEL verschluckte
# sonst die ganze Liste.
meldet "unbekannter_listenschluessel_meldet" '[projekt]
quelle = "apps/demo.lyx"

[include]
bananen = ["lib"]' "unbekannter Schluessel"

meldet "quelle_zeigt_ins_leere_meldet" '[projekt]
quelle = "apps/gibtsnicht.lyx"' "zeigt auf eine Datei, die es nicht gibt"

meldet "nicht_aufloesbares_paket_meldet" '[projekt]
quelle = "apps/demo.lyx"

[pakete]
gibtsganzsichernicht = "9.9.9"' "Paket nicht aufloesbar"

# --- Englische Schluessel sind gleichwertig -------------------------------
cat > "$TMP/p/en.lpf" <<'L'
[project]
source = "apps/demo.lyx"
target = "linux"
output = "build/demo_en"

[include]
paths = ["lib"]

[flags]
flags = ["-O1"]
L
if (cd "$TMP/p" && timeout 120 "$LYXC" --std-path="$ROOT" en.lpf >"$TMP/e.log" 2>&1) && [ -x "$TMP/p/build/demo_en" ]; then
  ok "englische_schluessel"
else
  no "englische_schluessel" "$(grep -im1 'error\|unbekannt' "$TMP/e.log")"
fi

echo "== lpf_projekt_test: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
