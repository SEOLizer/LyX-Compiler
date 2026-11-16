#!/usr/bin/env bash
# tests/lyu_arch_lyxos_2536_test.sh — lyxos hat eine EIGENE .lyu-Kennung (#2536).
#
# Befund: lyxos wurde auf LYU_ARCH_X86_64 abgebildet ("eine eigene Kennung gibt
# das Format nicht her", #1982). Zwei Wirkungen, am Erzeugnis gemessen:
#
#  1. Der Verzeichnisname kommt aus genau dieser Abbildung. Ein lyxos-Bau suchte
#     in `units/x86_64/` und fand einen unter `units/lyxos/` ausgelieferten Baum
#     NIE -- 483 Units lagen da, die Meldung war "Modul nicht gefunden". Beide
#     Baeume wollten dieselbe Ebene, der zweite ueberschrieb den ersten.
#  2. Die Objektcode-Weiche (lyxc.lyx) fragt `== LYU_ARCH_X86_64` und griff
#     damit AUCH fuer lyxos: eine lyxos-.lyu bekam mit --with-objcode ein
#     x86-64-ELF mitgegeben (e_machine 62) -- genau das falsche Abbild, das der
#     Kommentar an der Weiche ausschliesst ("wuerde auf dem Geraet abstuerzen
#     statt beim Uebersetzen zu scheitern").
#
# GEPRUEFT WIRD AM ERZEUGNIS: das arch-Byte an Versatz 6 und die Anwesenheit
# eines ELF-Abbilds in der Datei. Dazu BEIDE Seiten der Aufloesung -- dass der
# richtige Baum genommen wird UND dass der falsche nicht still durchgeht.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

printf 'unit m;\npub fn f(): int64 { return 7; }\n' > "$TMP/m.lyx"

# kopf <lyu> -> "<arch> <elf-machine oder ->"
kopf() {
  python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'\x7fELF')
m = str(int.from_bytes(d[i+18:i+20], 'little')) if i >= 0 else '-'
print(d[6], m)
PY
}

echo "--- 1. arch-Byte je Ziel, und kein x86-Abbild in einer IR-.lyu ---"
# erwartet: name|ziel|arch|elf  (elf '-' = keines, 62 = EM_X86_64)
for z in "linux||0|62" "lyxos|--target=lyxos|8|-" "arm64|--target=arm64|1|-"; do
  nm="${z%%|*}"; r="${z#*|}"; ziel="${r%%|*}"; r="${r#*|}"; ea="${r%%|*}"; ee="${r##*|}"
  ( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $ziel --with-objcode \
      --compile-unit "$TMP/m.lyx" -o "$TMP/$nm.lyu" ) >"$TMP/$nm.log" 2>&1
  if [ ! -s "$TMP/$nm.lyu" ]; then
    pr no "$nm: keine .lyu: $(grep -m1 -iE 'error' "$TMP/$nm.log" | cut -c1-70)"; continue
  fi
  got="$(kopf "$TMP/$nm.lyu")"
  [ "$got" = "$ea $ee" ] && pr ok "$nm: arch=$ea, Objektabbild=$ee" \
    || pr no "$nm: '$got', erwartet '$ea $ee'"
done

echo "--- 2. Der Name der Ebene steht EINMAL (LyuArchName) ---"
# #2552: an der WIRKUNG gemessen, nicht an der Schreibweise. Vorher stand hier
# ein grep auf 'if a == 8 { return "lyxos"c; }'. Seit die LYU_ARCH_*-Kennungen
# in lyu_reader liegen, nennt LyuArchName sie beim Namen -- der grep wurde rot,
# obwohl der Name richtig herauskam. Ein Test auf die Schreibweise haelt die
# Schreibweise fest, nicht das Verhalten.
_ui="$("$LYXC" --unit-info "$TMP/lyxos.lyu" 2>&1 || true)"
if printf '%s' "$_ui" | grep -qE '^[[:space:]]*Target:[[:space:]]+lyxos$'; then
  pr ok "LyuArchName fuehrt 8 -> lyxos (--unit-info: Target: lyxos)"
else
  pr no "LyuArchName kennt die lyxos-Ebene nicht"
fi
# Beide Seiten: ein anderes Ziel darf dort NICHT lyxos melden.
_ui2="$("$LYXC" --unit-info "$TMP/arm64.lyu" 2>&1 || true)"
if printf '%s' "$_ui2" | grep -qE '^[[:space:]]*Target:[[:space:]]+arm64$'; then
  pr ok "und arm64 meldet arm64, nicht lyxos"
else
  pr no "arm64 meldet nicht arm64"
fi
# Das Makefile muss denselben Namen annehmen, sonst liegt der Baum, wo niemand sucht.
if grep -qE '^[[:space:]]+lyxos\)[[:space:]]+z="--target=lyxos"' "$ROOT/Makefile"; then
  pr ok "Makefile nimmt den Baumnamen lyxos an"
else
  pr no "Makefile kennt LYU_BAEUME=lyxos nicht"
fi

echo "--- 3. Die Zuordnung steht EINMAL und nennt lyxos ---"
# #2552: Bis 1.2.41C waren lyxc._lyuArchFuerZiel und ir_lower._irLyuArchFuerZiel
# zwei getrennte Aufzaehlungen derselben Sache, und dieser Test forderte beide
# ein ("BEIDE Aufzaehlungen"). Damit schrieb er die Doppelung fest: wer sie
# beseitigt, machte ihn rot, obwohl die Zuordnung richtig blieb. Jetzt steht sie
# als ZielLyuArch in src/backend/ziel_modell.lyx. Geprueft wird, dass SIE lyxos
# kennt und dass keine der beiden Aufrufstellen wieder eine eigene Liste
# aufbaut -- die Wirkung selbst haengt in Teil 1 am arch-Byte.
_zm="$ROOT/src/backend/ziel_modell.lyx"
grep -q "LYX_TC_LYXOS)[[:space:]]*{[[:space:]]*return LYU_ARCH_LYXOS" "$_zm" \
  && pr ok "ZielLyuArch kennt lyxos" || pr no "ZielLyuArch fehlt lyxos"
grep -q "return ZielLyuArch(self.target)" "$ROOT/src/lyxc.lyx" \
  && pr ok "lyxc._lyuArchFuerZiel fragt die eine Stelle" \
  || pr no "lyxc._lyuArchFuerZiel hat wieder eine eigene Aufzaehlung"
grep -q "return ZielLyuArch(zielCode)" "$ROOT/src/ir_lower.lyx" \
  && pr ok "ir_lower._irLyuArchFuerZiel fragt die eine Stelle" \
  || pr no "ir_lower._irLyuArchFuerZiel hat wieder eine eigene Aufzaehlung"
echo "--- 4. Aufloesung: der eigene Baum wird genommen, der fremde NICHT still ---"
mkdir -p "$TMP/baum/lyxos/std" "$TMP/baum/x86_64/std" "$TMP/leer"
( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos \
    --compile-unit "$TMP/m.lyx" -o "$TMP/baum/lyxos/std/m.lyu" ) >/dev/null 2>&1
( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --with-objcode \
    --compile-unit "$TMP/m.lyx" -o "$TMP/baum/x86_64/std/m.lyu" ) >/dev/null 2>&1
printf 'import std.m;\nfn main(): int64 { return f(); }\n' > "$TMP/leer/p.lyx"
if [ -s "$TMP/baum/lyxos/std/m.lyu" ] && [ -s "$TMP/baum/x86_64/std/m.lyu" ]; then
  ( cd "$TMP/leer" && timeout 200 "$LYXC" --std-path="$TMP/baum" --target=lyxos \
      p.lyx -o p.lbf ) >"$TMP/auf.log" 2>&1
  [ -s "$TMP/leer/p.lbf" ] && pr ok "lyxos-Bau nimmt units/lyxos/ (Erzeugnis entsteht)" \
    || pr no "lyxos-Bau findet units/lyxos/ nicht: $(grep -m1 -iE 'error|warning' "$TMP/auf.log" | cut -c1-70)"
  # Gegenprobe: ohne die eigene Ebene darf er die x86-Ebene nicht STILL nehmen.
  # Geprueft wird die WIRKUNG (kein Erzeugnis), nicht der Wortlaut der Meldung:
  # ein Test am Wortlaut wird rot, sobald die Meldung besser wird.
  rm -rf "$TMP/baum/lyxos"
  ( cd "$TMP/leer" && timeout 200 "$LYXC" --std-path="$TMP/baum" --target=lyxos \
      p.lyx -o p2.lbf ) >"$TMP/geg.log" 2>&1
  [ -s "$TMP/leer/p2.lbf" ] && pr no "lyxos-Bau nahm die x86-Ebene und erzeugte etwas" \
    || pr ok "ohne units/lyxos/ entsteht kein Erzeugnis"
else
  pr no "Vorbereitung: eine der beiden .lyu fehlt"; pr no "Gegenprobe nicht erreichbar"
fi

echo "--- 5. Der flache Rueckfall gilt weiter (keine Verschaerfung) ---"
# Eine .lyu ohne Objektabschnitt ist architekturunabhaengig; der flache Pfad
# bleibt gueltig. Haette die neue Ebene ihn verdraengt, waere das eine
# Verschaerfung ohne Befund -- bestehende Baeume liegen flach.
mkdir -p "$TMP/flach/std" "$TMP/leer2"
( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos \
    --compile-unit "$TMP/m.lyx" -o "$TMP/flach/std/m.lyu" ) >/dev/null 2>&1
printf 'import std.m;\nfn main(): int64 { return f(); }\n' > "$TMP/leer2/p.lyx"
( cd "$TMP/leer2" && timeout 200 "$LYXC" --std-path="$TMP/flach" --target=lyxos \
    p.lyx -o p.lbf ) >"$TMP/flach.log" 2>&1
[ -s "$TMP/leer2/p.lbf" ] && pr ok "flacher Baum traegt den lyxos-Bau weiter" \
  || pr no "flacher Rueckfall verloren: $(grep -m1 -iE 'error' "$TMP/flach.log" | cut -c1-70)"

echo "--- 6. Der Baumpruefer urteilt in BEIDE Richtungen ---"
# Eine Liste, die nur entschuldigt, verfault. Beide Faelle werden ERZEUGT,
# nicht behauptet: ein Versuchsaufbau, der den Fall nicht herstellt, misst nichts.
P="$ROOT/tools/lyu_baum_pruefen.sh"
if [ -x "$P" ]; then
  if bash "$P" x86_64 >"$TMP/p1.log" 2>&1; then
    pr ok "der vorhandene x86_64-Baum gilt als vollstaendig"
  else
    pr no "x86_64-Baum gilt als unvollstaendig: $(tail -1 "$TMP/p1.log" | cut -c1-70)"
  fi
  # Luecke herstellen: eine .lyu beiseite, die in KEINER Liste steht.
  opfer="$ROOT/lyx-compiler/usr/include/lyx/units/x86_64/std/io.lyu"
  if [ -s "$opfer" ]; then
    mv "$opfer" "$TMP/io.lyu.weg"
    bash "$P" x86_64 >"$TMP/p2.log" 2>&1 && pr no "unerklaerte Luecke blieb unbemerkt" \
      || pr ok "unerklaerte Luecke wird gemeldet"
    mv "$TMP/io.lyu.weg" "$opfer"
  else
    pr no "Vorbereitung: $opfer fehlt"
  fi
  # Ueberholter Eintrag: eine Unit, die SEHR WOHL uebersetzt, in die Liste.
  liste="$ROOT/tools/dist_units_ausnahmen_x86_64.txt"
  hatte=0; [ -f "$liste" ] && hatte=1
  cp -f "$liste" "$TMP/liste.bak" 2>/dev/null
  echo 'std/io.lyx   # absichtlich falscher Eintrag fuer den Test' >> "$liste"
  bash "$P" x86_64 >"$TMP/p3.log" 2>&1 && pr no "ueberholter Eintrag blieb unbemerkt" \
    || pr ok "ueberholter Eintrag wird gemeldet"
  if [ "$hatte" = 1 ]; then cp -f "$TMP/liste.bak" "$liste"; else rm -f "$liste"; fi
else
  pr no "tools/lyu_baum_pruefen.sh fehlt oder ist nicht ausfuehrbar"
  pr no "beide Richtungen nicht pruefbar"; pr no "ueberholter Eintrag nicht pruefbar"
fi

echo "--- 7. LYU_BAEUME bestimmt den INHALT, loescht aber nichts Versioniertes ---"
# Beim Entwickeln dieser Regel geriet ein 274-MB-lyxos-Baum aus einem frueheren
# Lauf in ein `make deb` und liess es an der Plattenquote scheitern: die Liste
# steuerte nur den BAU. Seither raeumt das Ziel nicht gelistete Baeume weg --
# und weil der x86_64-Baum EINGECHECKT ist (503 .lyu), darf das Wegraeumen
# niemals versionierte Dateien treffen. Ein Paketbau, der nebenbei eingecheckte
# Dateien loescht, ist schlimmer als ein zu grosses Paket.
if grep -q "git ls-files" "$ROOT/Makefile"; then
  pr ok "units-baeume prueft vor dem Entfernen auf versionierte Dateien"
else
  pr no "units-baeume entfernt Baeume ohne Pruefung auf versionierte Dateien"
fi
# Die WIRKUNG, nicht die Zeile: ein nicht gelisteter Baum MIT versionierten
# Dateien muss den Lauf abbrechen, statt zu loeschen.
if ( cd "$ROOT" && timeout 300 make units-baeume LYU_BAEUME="lyxos" ) >"$TMP/prune.log" 2>&1; then
  pr no "Lauf ging durch, obwohl er den eingecheckten x86_64-Baum haette loeschen muessen"
else
  if [ "$(cd "$ROOT" && git status --short lyx-compiler/usr/include/lyx/units/ 2>/dev/null | grep -c '^ D')" = "0" ]; then
    pr ok "bricht ab und loescht keine versionierte Datei"
  else
    pr no "hat versionierte Dateien geloescht"
  fi
fi

echo
echo "lyu_arch_lyxos_2536_test: PASS=$PASS FAIL=$FAIL"
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
