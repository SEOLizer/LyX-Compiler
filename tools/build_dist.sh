  # KEIN zweiter Versuch gegen einen Quellenbaum mehr: das Paket traegt keine
  # stdlib-Quellen. Ein Beispiel, dem die .lyu nicht reicht ("Quelle der
  # importierten Unit nicht lesbar", "stammt aus einer .lyu ohne Objektcode"),
  # ist damit ROT und nennt genau diese Meldung — das ist die Lage im
  # ausgelieferten Baum, und sie soll dastehen, wie sie ist.
#!/usr/bin/env bash
# tools/build_dist.sh — Auslieferbaum je Backend unter build/<backend>/.
#
# Je Backend entsteht ein vollstaendiger, in sich geschlossener Baum:
#
#   build/<backend>/bin/lyxc[.exe]              Compiler FUER DIESES ZIEL
#   build/<backend>/include/lyx/units/std/**    vorkompilierte Standardbibliothek
#   build/<backend>/include/lyx/units/data/**   vorkompilierte Datenunits
#   build/<backend>/bin/lbfdump, lpm, …         Hilfswerkzeuge FUER DIESES ZIEL
#   build/<backend>/WERKZEUGE-STATUS.txt        welche davon uebersetzt haben
#   build/<backend>/LICENSE                     Volltext der LPCL (englisch,
#                                               massgeblich)
#   build/<backend>/LICENSE.es                  spanische Uebersetzung
#   build/<backend>/LIZENZEN.txt                welche Lizenz fuer welchen Teil gilt
#   build/<backend>/share/lyx/pci.ids           Datendateien
#   build/<backend>/VERSION                     Version, Datum, Backend, Commit
#   build/<backend>/INSTALL.md                  wie der Baum installiert wird
#   build/<backend>/examples/**                 Beispielquellen (Auswahl aus
#                                               tools/dist_examples.txt — die
#                                               Messprogramme aus examples/
#                                               gehen NICHT mit)
#   build/<backend>/EXAMPLES-STATUS.txt         welche davon fuer DIESES Ziel uebersetzen
#   build/<backend>/UNITS-FEHLER.txt            nur wenn Units fehlen
#
# Der Compiler ist zielabhaengig, die Units sind es in ihrer WIRKUNG nicht.
# Gemessen am 2026-11-10 mit lyxc 1.2.34B:
#
#   * `std/math.lyx --compile-unit` ergibt fuer linux und fuer win64 zwei
#     VERSCHIEDENE Dateien (4.156 vs 325.794 Bytes, sha256 5494579e… vs
#     cf5d5d47…) — die win64-Form traegt rund 80x mehr Bytes, der ganze
#     win64-Unit-Baum 261 MB gegen 2,5 MB.
#   * Das ERZEUGNIS ist davon unberuehrt: ein win64-PE, aus dem linux-Baum
#     uebersetzt, ist bytegleich mit demselben PE aus dem win64-Baum. Geprueft
#     an 40 Programmen aus examples/ (14 uebersetzbar, 14 bytegleich, 0
#     abweichend) und an usemath/usecircle unter wine (gleiche Ausgabe).
#   * Der zielweise gebaute win64-Baum ist zudem UNVOLLSTAENDIG: 16 von 500
#     Units scheitern an #2459, #2460 und #1678. std.circle fehlt dort, laesst
#     sich aber aus dem Host-Baum heraus auf win64 anstandslos benutzen
#     (gemessen: Ausgabe 5 unter wine).
#
# Darum werden die Units mit dem HOST-Ziel uebersetzt (UNITS_ZIEL=host, Vorgabe):
# vollstaendig, klein, und am Erzeugnis nachweislich dasselbe. Wer die
# zielweise Form braucht oder die Messung wiederholen will, setzt
# UNITS_ZIEL=ziel — dann gilt die Ausnahmeliste
# tools/dist_units_ausnahmen_<backend>.txt.
#
# ACHTUNG — die Messung oben gilt nur fuer x86-64-Ziele (#2472). Sie verglich
# linux gegen win64, BEIDE x86-64, und war damit blind fuer den Punkt, der
# wirklich zielabhaengig ist: das TYPLAYOUT. `StringBuilder` ist auf x86-64
# 32 Bytes gross (Typwort 1), auf arm64 24 (Typwort 0); der Codegen prueft das
# beim Import einer .lyu und bricht zu Recht ab. Gemessen am Beispielbaum von
# linux-arm64: mit Host-Units 40 von 87 uebersetzbar, mit zielweisen Units 62 —
# die 22 Unterschiede sind genau die 11 StringBuilder- und 6
# EthernetHeader-Layoutmeldungen plus Folgefehler.
#
# Fuer arm64, riscv64, macos-arm64 und lyxos ist UNITS_ZIEL=host also FALSCH,
# und die Baeume liefern Beispiele mit, die mit ihrem eigenen Unit-Baum nicht
# uebersetzen. Die Umstellung haengt an je einer begruendeten Ausnahmeliste
# (fuer arm64: 16 von 500 Units) und ist in #2472 beschrieben.
#
# Aufruf:
#   tools/build_dist.sh                 # alle Backends aus BACKENDS
#   tools/build_dist.sh win64           # nur dieses
#   tools/build_dist.sh win64 linux-x86_64
#
# Umgebung:
#   LYXC=<pfad>   Host-Compiler (Vorgabe ./lyxc) — uebersetzt Compiler UND Units
#   JOBS=<n>      parallele Unit-Uebersetzungen (Vorgabe: nproc)
#   NUR_UNITS=1   den Compiler fuer das Ziel nicht bauen (schneller Durchlauf)
#   UNITS_ZIEL=host|ziel
#                 host (Vorgabe): Units mit dem Host-Ziel uebersetzen — klein,
#                 vollstaendig, Erzeugnis nachweislich gleich (s. oben).
#                 ziel: Units mit --target=<backend> uebersetzen; dann greift
#                 die Ausnahmeliste, und der Baum ist bei win64 unvollstaendig.
#
# Rueckgabe: 0 nur, wenn fuer jedes Backend der Compiler steht und JEDE Unit
# uebersetzt ist, die nicht in tools/dist_units_ausnahmen_<backend>.txt mit
# Begruendung eingetragen ist. Eine stillschweigend fehlende .lyu waere genau
# der stille Default, den CLAUDE.md verbietet.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LYXC="${LYXC:-$ROOT/lyxc}"
JOBS="${JOBS:-$(nproc)}"
NUR_UNITS="${NUR_UNITS:-0}"
UNITS_ZIEL="${UNITS_ZIEL:-host}"
AUS="$ROOT/build"

# ── eine Unit uebersetzen (von xargs aufgerufen) ─────────────────────────────
# Argumente: <quelle.lyx>. Umgebung: LYXC, ZIEL, UNIT_DST, LOGDIR.
if [ "${1:-}" = "--eine-unit" ]; then
  q="$2"
  rel="${q#*/}"                      # std/foo/bar.lyx -> foo/bar.lyx
  pfx="${q%%/*}"                     # std | data
  ziel="$UNIT_DST/$pfx/${rel%.lyx}.lyu"
  [ -s "$ziel" ] && exit 0            # in einer frueheren Runde schon gebaut
  mkdir -p "$(dirname "$ziel")"
  log="$LOGDIR/$(echo "$q" | tr / _).log"
  # ZIEL ist leer, wenn die Units fuer das Host-Ziel gebaut werden.
  if "$LYXC" --std-path="$ROOT" ${ZIEL:+--target="$ZIEL"} --compile-unit "$q" -o "$ziel" >"$log" 2>&1; then
    rm -f "$log"
    exit 0
  fi
  rm -f "$ziel"                      # halbe Datei ist schlimmer als keine
  exit 1
fi

# ── ein Beispiel uebersetzen (von xargs aufgerufen) ──────────────────────────
# Argumente: <quelle.lyx>. Umgebung: LYXC, ROOT, ZIEL, FORMAT, BSP_LOG, BSP_UNITS.
if [ "${1:-}" = "--ein-beispiel" ]; then
  q="$2"
  log="$BSP_LOG/$(echo "${q#examples/}" | tr / _).log"
  # AUS EINEM NEUTRALEN VERZEICHNIS uebersetzen, nicht aus dem Repo: der
  # Import-Resolver bevorzugt das Arbeitsverzeichnis vor --std-path, und die
  # so geladene std/net/socket.lyx liegt dann NICHT unter dem angegebenen
  # Baum. Sie gilt damit als fremde Herkunft, und die FFI-Sandbox macht
  # fail-closed zu (#2202). Erster Lauf: 209 von 346 Beispielen "rot", alle
  # mit derselben Meldung — ein Befund ueber mein Messverfahren, nicht ueber
  # die Beispiele. Ein ausgelieferter Baum steht nirgends neben einem std/.
  if ( cd "$BSP_LOG" && timeout 120 "$LYXC" --std-path="$BSP_UNITS" \
         ${ZIEL:+--target="$ZIEL"} ${FORMAT:+--format="$FORMAT"} \
         "$ROOT/$q" -o /dev/null ) >"$log" 2>&1; then
    rm -f "$log"; exit 0
  fi
  # KEIN zweiter Versuch gegen einen Quellenbaum: das Paket traegt keine
  # stdlib-Quellen mehr. Ein Beispiel, dem die .lyu nicht reicht ("Quelle der
  # importierten Unit nicht lesbar", "stammt aus einer .lyu ohne Objektcode"),
  # ist damit ROT und nennt genau diese Meldung — das ist die Lage im
  # ausgelieferten Baum, und sie soll dastehen, wie sie ist.
  exit 1
fi

# ── Backend-Tabelle ──────────────────────────────────────────────────────────
# name|--target=|--format=|Binaername|Compiler selbst baubar (ja/nein)
BACKEND_TABELLE=(
  "linux-x86_64|linux|elf|lyxc|ja"
  "win64|win64|pe|lyxc.exe|ja"
  "linux-arm64|arm64|elf|lyxc|ja"
  "linux-riscv64|riscv|elf|lyxc|ja"
  "macos-x86_64|macosx64|macho|lyxc|ja"
  "macos-arm64|macos-arm64|macho|lyxc|ja"
  "lyxos|lyxos|elf|lyxc|nein"
)
# Vorgabe: nur die zwei Ziele, die hier gemessen laufen. Die uebrigen baut man
# namentlich — ungemessen in die Vorgabe zu nehmen hiesse, ihren Zustand zu
# behaupten statt zu kennen.
BACKENDS_VORGABE="linux-x86_64 win64"

zeile_fuer() {
  local name="$1" z
  for z in "${BACKEND_TABELLE[@]}"; do
    [ "${z%%|*}" = "$name" ] && { echo "$z"; return 0; }
  done
  return 1
}

alle_backends() {
  local z
  for z in "${BACKEND_TABELLE[@]}"; do echo "${z%%|*}"; done
}

# ── Vorbedingungen ───────────────────────────────────────────────────────────
if [ ! -x "$LYXC" ]; then
  echo "FEHLER: Host-Compiler $LYXC fehlt. Erst 'make bootstrap' (nie 'make clean')." >&2
  exit 1
fi

VERSION="$("$LYXC" --version 2>/dev/null | head -1 | awk '{print $2}')"
[ -n "$VERSION" ] || { echo "FEHLER: $LYXC --version liefert keine Version." >&2; exit 1; }

# Der Compiler muss zum Quellstand passen. Die .lyu tragen den Codegen dessen,
# der sie erzeugt hat; ein alter ./lyxc liefert also stillschweigend Units von
# gestern in ein Paket von heute. Die Version steckt im Binary, der Vergleich
# gegen das Makefile ist damit eine Aussage ueber die Herkunft des Binarys.
MAKE_VERSION="$(awk -F':=' '/^VERSION[[:space:]]*:=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$ROOT/Makefile")"
if [ -n "$MAKE_VERSION" ] && [ "$VERSION" != "$MAKE_VERSION" ]; then
  echo "FEHLER: $LYXC meldet $VERSION, der Quellstand steht auf $MAKE_VERSION." >&2
  echo "Erst 'make bootstrap' (nie 'make clean'), dann erneut." >&2
  echo "Wer bewusst mit einem aelteren Compiler ausliefert: DIST_VERSION_EGAL=1." >&2
  [ "${DIST_VERSION_EGAL:-0}" = "1" ] || exit 1
  echo "WARNUNG: DIST_VERSION_EGAL=1 — Paket entsteht mit $VERSION." >&2
fi
DATUM="$(date +%Y-%m-%d)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unbekannt)"

mapfile -t UNIT_QUELLEN < <( { find std -name '*.lyx'; find data -name '*.lyx'; } | sort )
[ "${#UNIT_QUELLEN[@]}" -gt 0 ] || { echo "FEHLER: keine Unit-Quellen gefunden." >&2; exit 1; }

# ── Hilfswerkzeuge ───────────────────────────────────────────────────────────
# Je Backend werden sie FUER DIESES ZIEL uebersetzt und liegen neben dem
# Compiler in bin/. Format: <name im Paket>|<quelle>. Eine Quelle ausserhalb
# des Repos wird ueber eine Variable gefunden, damit das Paket nicht still
# an einem fremden Pfad haengt: lpm lebt in einem eigenen Projekt (#2448),
# LPM_SRC zeigt darauf. Fehlt es, faellt lpm aus dem Paket — laut, nicht still.
LPM_SRC="${LPM_SRC:-$(cd "$ROOT/.." 2>/dev/null && pwd)/lyx-lpm}"
WERKZEUGE=(
  "lbfdump|$ROOT/src/tools/lbf_dump.lyx"
  "lbfimport|$ROOT/src/tools/lbf_import.lyx"
  "lbfloader|$ROOT/src/tools/lbf_loader.lyx"
  "lbfrun|$ROOT/src/tools/lbf_run.lyx"
  "lyxcpu|$ROOT/src/tools/lyx_cpu.lyx"
  "cpufeatures|$ROOT/src/tools/cpu_features_dump.lyx"
  "lpm|$LPM_SRC/main.lyx"
)

# ── Beispiele auswaehlen ─────────────────────────────────────────────────────
# Ausgeliefert wird NUR, was in tools/dist_examples.txt steht. examples/ im
# Quellbaum enthaelt daneben die Messprogramme alter Fehlersuchen (239 von 346
# Dateien tragen test/debug/crash im Namen); in einem Paket sind die eine
# stille Enttaeuschung, weil der Nutzer ein halbes Probeprogramm fuer ein
# Beispiel haelt.
#
# Die Auswahl wird GEPRUEFT, nicht gefiltert: jede .lyx unter examples/ muss
# entweder in dist_examples.txt stehen, als Messprogramm erkennbar sein
# (test/debug/crash im Dateinamen) oder in dist_examples_ausgeschlossen.txt
# mit Grund gefuehrt werden. Alles andere bricht ab — sonst faellt ein neues
# Beispiel still aus der Auslieferung.
BSP_LISTE="$ROOT/tools/dist_examples.txt"
BSP_AUS_LISTE="$ROOT/tools/dist_examples_ausgeschlossen.txt"
[ -f "$BSP_LISTE" ] || { echo "FEHLER: $BSP_LISTE fehlt." >&2; exit 1; }
[ -f "$BSP_AUS_LISTE" ] || { echo "FEHLER: $BSP_AUS_LISTE fehlt." >&2; exit 1; }

entkommentiert() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }

mapfile -t DIST_BSP < <(entkommentiert "$BSP_LISTE")
[ "${#DIST_BSP[@]}" -gt 0 ] || { echo "FEHLER: $BSP_LISTE nennt kein Beispiel." >&2; exit 1; }

bsp_fehlt=0
for b in "${DIST_BSP[@]}"; do
  [ -f "$ROOT/examples/$b" ] || { echo "FEHLER: $BSP_LISTE nennt examples/$b — Datei fehlt." >&2; bsp_fehlt=1; }
done
[ "$bsp_fehlt" -eq 0 ] || exit 1

# Abdeckung: jede Datei im Quellbaum muss einer der drei Gruppen angehoeren.
mapfile -t BSP_UNBEKANNT < <(
  { entkommentiert "$BSP_LISTE"; entkommentiert "$BSP_AUS_LISTE"; } | LC_ALL=C sort -u > "$ROOT/.bsp_bekannt.$$"
  ( cd "$ROOT/examples" && find . -name '*.lyx' | sed 's|^\./||' | grep -vE '[^/]*(test|debug|crash)[^/]*\.lyx$' | LC_ALL=C sort ) \
    | LC_ALL=C comm -23 - "$ROOT/.bsp_bekannt.$$"
  rm -f "$ROOT/.bsp_bekannt.$$"
)
if [ "${#BSP_UNBEKANNT[@]}" -gt 0 ]; then
  echo "FEHLER: unter examples/ liegen Dateien, die weder ausgeliefert noch ausgeschlossen sind:" >&2
  printf '  %s\n' "${BSP_UNBEKANNT[@]}" >&2
  echo "Entweder in tools/dist_examples.txt aufnehmen oder in" >&2
  echo "tools/dist_examples_ausgeschlossen.txt mit Grund eintragen." >&2
  exit 1
fi
echo "Beispiele: ${#DIST_BSP[@]} ausgeliefert (Auswahl aus tools/dist_examples.txt)"

# ── ein Backend bauen ────────────────────────────────────────────────────────
backend_bauen() {
  local name="$1"
  local z target format binname selbstbaubar
  z="$(zeile_fuer "$name")" || { echo "FEHLER: unbekanntes Backend '$name'. Bekannt: $(alle_backends | tr '\n' ' ')" >&2; return 1; }
  IFS='|' read -r _ target format binname selbstbaubar <<<"$z"

  local D="$AUS/$name"
  echo "=== Backend $name (--target=$target --format=$format) -> $D"
  rm -rf "$D"
  mkdir -p "$D/bin" "$D/include/lyx/units" "$D/share/lyx"

  local fehler=0

  # 1) Compiler fuer das Ziel
  if [ "$NUR_UNITS" = "1" ]; then
    echo "  [1/5] Compiler uebersprungen (NUR_UNITS=1)"
  elif [ "$selbstbaubar" != "ja" ]; then
    echo "  [1/5] Compiler: fuer $name nicht vorgesehen (nur Units)"
  else
    echo "  [1/5] Compiler uebersetzen ($binname) — dauert Minuten"
    if "$LYXC" --std-path="$ROOT" --target="$target" --format="$format" \
         src/lyxc.lyx -o "$D/bin/$binname" >"$D/bin/.bau.log" 2>&1; then
      chmod 755 "$D/bin/$binname"
      # Die Warnung ueber rohe Linux-Syscalls (#1678) ist ein offener Defekt
      # und gehoert in den Baum, nicht ins Lograuschen.
      grep -i 'warning' "$D/bin/.bau.log" > "$D/COMPILER-WARNUNGEN.txt" 2>/dev/null
      [ -s "$D/COMPILER-WARNUNGEN.txt" ] || rm -f "$D/COMPILER-WARNUNGEN.txt"
      mv "$D/bin/.bau.log" "$D/bin/compiler-bau.log"
      echo "        $(stat -c%s "$D/bin/$binname") Bytes"
    else
      echo "        FEHLGESCHLAGEN: $(grep -m1 -i error "$D/bin/.bau.log")"
      mv "$D/bin/.bau.log" "$D/bin/compiler-bau.log"
      fehler=1
    fi
  fi

  # 2) Units fuer das Ziel. Eine Unit, deren Import noch kein .lyu hat, kommt
  #    erst im naechsten Lauf durch — und mit `xargs -P` ist die Reihenfolge
  #    nicht festgelegt, zwei feste Passes reichen also nicht: im Probelauf
  #    (2026-11-10) blieben nach Pass 2 noch 12 Units offen, die beim dritten
  #    Lauf anstandslos durchkamen. Deshalb wird gefahren, BIS KEIN FORTSCHRITT
  #    mehr entsteht. Das Abbruchkriterium ist der Fortschritt, nicht eine
  #    geratene Rundenzahl; nur die Obergrenze schuetzt vor einer Endlosrunde.
  echo "  [2/5] ${#UNIT_QUELLEN[@]} Units uebersetzen (UNITS_ZIEL=$UNITS_ZIEL, JOBS=$JOBS)"
  local MARKE; MARKE="$(mktemp)"            # Zeitmarke fuer die Frischepruefung
  local LOGDIR; LOGDIR="$(mktemp -d)"
  export LYXC ROOT
  if [ "$UNITS_ZIEL" = "ziel" ]; then export ZIEL="$target"; else export ZIEL=""; fi
  export UNIT_DST="$D/include/lyx/units"
  export LOGDIR

  local runde=0 vorher=-1 jetzt=0
  while [ "$runde" -lt 8 ]; do
    runde=$((runde+1))
    rm -f "$LOGDIR"/*.log
    printf '%s\0' "${UNIT_QUELLEN[@]}" \
      | xargs -0 -P "$JOBS" -n1 "$0" --eine-unit >/dev/null 2>&1
    jetzt=$(find "$D/include/lyx/units" -name '*.lyu' | wc -l)
    echo "        Runde $runde: $jetzt/${#UNIT_QUELLEN[@]} .lyu"
    [ "$jetzt" -eq "${#UNIT_QUELLEN[@]}" ] && break
    [ "$jetzt" -eq "$vorher" ] && break      # kein Fortschritt — der Rest ist echt
    vorher="$jetzt"
  done

  # Zusicherung: JEDE .lyu ist in DIESEM Lauf entstanden. Der Baum wird zwar
  # oben mit `rm -rf "$D"` geleert, aber darauf allein darf die Aussage
  # "mit der aktuellen Compilerversion gebaut" nicht ruhen — faellt das rm
  # einmal weg oder zeigt UNIT_DST woandershin, griffe das
  # `[ -s "$ziel" ] && exit 0` der Unit-Funktion und liefe still auf
  # Altbestand hinaus. Gemessen wird gegen die Marke, nicht geglaubt.
  local n_alt
  n_alt=$(find "$D/include/lyx/units" -name '*.lyu' ! -newer "$MARKE" | wc -l)
  if [ "$n_alt" -gt 0 ]; then
    echo "FEHLER: $n_alt .lyu stammen nicht aus diesem Lauf (aelter als $(date -r "$MARKE" +%T))." >&2
    find "$D/include/lyx/units" -name '*.lyu' ! -newer "$MARKE" | head -5 >&2
    return 1
  fi

  # Die Ausnahmeliste gilt nur fuer den zielweisen Bau: im Host-Modus gibt es
  # die zielbedingten Luecken nicht, und eine fehlende Unit waere dort ein
  # echter Befund, den keine Liste entschuldigen darf.
  local ausnahmen=/dev/null
  [ "$UNITS_ZIEL" = "ziel" ] && ausnahmen="$ROOT/tools/dist_units_ausnahmen_$name.txt"
  local fehlerliste="$D/UNITS-FEHLER.txt"
  local n_fehler=0 n_ausgenommen=0
  : > "$fehlerliste"
  local q rel pfx lyu grund
  for q in "${UNIT_QUELLEN[@]}"; do
    rel="${q#*/}"; pfx="${q%%/*}"
    lyu="$D/include/lyx/units/$pfx/${rel%.lyx}.lyu"
    [ -s "$lyu" ] && continue
    grund="$(sed -n "s|^$q[[:space:]]*#[[:space:]]*||p" "$ausnahmen" 2>/dev/null | head -1)"
    if [ -n "$grund" ]; then
      n_ausgenommen=$((n_ausgenommen+1))
      echo "AUSGENOMMEN $q — $grund" >> "$fehlerliste"
    else
      n_fehler=$((n_fehler+1))
      # Die Fehlerzeile steht WEIT hinten: davor liegt der LCBS-Audit-Block.
      # Ein `head -c 300` sah nur das Banner und meldete darum fuer jede
      # gescheiterte Unit "kein Log" — erst greppen, dann kuerzen.
      echo "FEHLER      $q — $(grep -m1 -i '^error' "$LOGDIR/$(echo "$q" | tr / _).log" 2>/dev/null | cut -c1-200 || true)" >> "$fehlerliste"
    fi
  done
  rm -rf "$LOGDIR"
  local n_ok; n_ok=$(find "$D/include/lyx/units" -name '*.lyu' | wc -l)
  echo "        $n_ok .lyu, $n_ausgenommen ausgenommen, $n_fehler ungeklaert"
  [ -s "$fehlerliste" ] || rm -f "$fehlerliste"
  [ "$n_fehler" -eq 0 ] || fehler=1

  # 2b) Hilfswerkzeuge fuer DIESES Ziel. Sie gehoeren zum Paket wie der
  #     Compiler: ein lbfdump vom Host nuetzt auf einem arm64-Geraet nichts.
  echo "  [3/5] Hilfswerkzeuge fuer $target uebersetzen"
  local wkz_log; wkz_log="$D/bin/.werkzeuge.log"
  local n_wkz_ok=0 n_wkz_rot=0 eintrag wname wquelle wziel
  {
    echo "# Hilfswerkzeuge, uebersetzt fuer $target ($name), Stand $DATUM, lyxc $VERSION"
    echo "#"
    echo "# Sie liegen in bin/ neben dem Compiler und sind FUER DIESES ZIEL gebaut."
    echo
  } > "$D/WERKZEUGE-STATUS.txt"
  for eintrag in "${WERKZEUGE[@]}"; do
    wname="${eintrag%%|*}"; wquelle="${eintrag#*|}"
    wziel="$D/bin/$wname"
    [ "$format" = "pe" ] && wziel="$wziel.exe"
    if [ ! -f "$wquelle" ]; then
      printf 'FEHLT  %-14s Quelle nicht gefunden: %s\n' "$wname" "$wquelle" >> "$D/WERKZEUGE-STATUS.txt"
      n_wkz_rot=$((n_wkz_rot+1)); continue
    fi
    if ( cd "$(dirname "$wquelle")" && timeout 300 "$LYXC" --std-path="$ROOT" \
           -I "$(dirname "$wquelle")" -I "$ROOT" \
           --target="$target" --format="$format" "$wquelle" -o "$wziel" ) >"$wkz_log" 2>&1; then
      printf 'OK     %-14s %s Bytes\n' "$wname" "$(stat -c%s "$wziel")" >> "$D/WERKZEUGE-STATUS.txt"
      n_wkz_ok=$((n_wkz_ok+1))
    else
      rm -f "$wziel"                      # halbe Datei ist schlimmer als keine
      printf 'ROT    %-14s %s\n' "$wname" \
        "$(grep -m1 -iE '^error|^lyxc:|sema error|Parse error' "$wkz_log" | cut -c1-140)" \
        >> "$D/WERKZEUGE-STATUS.txt"
      n_wkz_rot=$((n_wkz_rot+1))
    fi
  done
  rm -f "$wkz_log"
  echo "        $n_wkz_ok/${#WERKZEUGE[@]} Werkzeuge gebaut, $n_wkz_rot nicht (siehe WERKZEUGE-STATUS.txt)"
  # Ein nicht uebersetzbares Werkzeug macht den Lauf NICHT rot — der Grund
  # steht je Werkzeug im Status, und er gehoert dem Werkzeug, nicht dem Paket.

  # 3) Datendateien und Begleitpapiere
  echo "  [4/5] Datendateien und Begleitpapiere"
  cp share/pci.ids "$D/share/lyx/pci.ids"
  cp share/pci.ids.LICENSE "$D/share/lyx/pci.ids.LICENSE"

  # Lizenzen. Ein Paket, das Binaries und fremde Daten ausliefert, muss sagen,
  # unter welchen Bedingungen — und zwar im Paket, nicht nur im Repo.
  # LICENSE ist der Volltext der LPCL; LIZENZEN.txt sagt je Bestandteil,
  # welche Lizenz gilt und wo ihr Text steht.
  cp "$ROOT/LICENSE" "$D/LICENSE"
  # Uebersetzungen der Lizenz. Sie sind Lesehilfen, nicht die Rechtsgrundlage:
  # Abschnitt 10(c) des Originals erklaert die ENGLISCHE Fassung fuer
  # massgeblich. Fehlt eine Uebersetzung im Repo, faellt sie aus dem Paket —
  # das ist kein Fehler, nur ein Paket ohne diese Lesehilfe.
  for sprache in es de fr; do
    [ -f "$ROOT/LICENSE.$sprache" ] && cp "$ROOT/LICENSE.$sprache" "$D/LICENSE.$sprache"
  done
  local lpm_lizenz="unbekannt" lpm_version=""
  if [ -f "$LPM_SRC/lyx.toml" ]; then
    lpm_lizenz="$(awk -F'"' '/^license[[:space:]]*=/ {print $2; exit}' "$LPM_SRC/lyx.toml")"
    lpm_version="$(awk -F'"' '/^version[[:space:]]*=/ {print $2; exit}' "$LPM_SRC/lyx.toml")"
    [ -n "$lpm_lizenz" ] || lpm_lizenz="unbekannt"
  fi
  {
    echo "Lizenzen der Bestandteile dieses Pakets"
    echo "======================================="
    echo
    echo "lyxc $VERSION, Backend $name, gebaut am $DATUM aus Commit $COMMIT."
    echo
    echo "1) Compiler, Standardbibliothek, Beispiele und die Werkzeuge aus"
    echo "   diesem Repository (lbfdump, lbfimport, lbfloader, lbfrun, lyxcpu,"
    echo "   cpufeatures)"
    echo
    echo "   Lyx Proprietary & Community License (LPCL), Version 1.0 (2026)"
    echo "   Copyright (c) 2026 Andreas Roene. All rights reserved."
    echo "   Volltext: LICENSE in diesem Verzeichnis (englisch, massgeblich)."
    if ls "$D"/LICENSE.?? >/dev/null 2>&1; then
      echo "   Uebersetzungen als Lesehilfe:"
      local uebersetzung
      for uebersetzung in "$D"/LICENSE.??; do
        case "${uebersetzung##*.}" in
          es) echo "     LICENSE.es — espanol (traduccion no vinculante)" ;;
          de) echo "     LICENSE.de — Deutsch (unverbindliche Uebersetzung)" ;;
          fr) echo "     LICENSE.fr — francais (traduction non contraignante)" ;;
          *)  echo "     ${uebersetzung##*/}" ;;
        esac
      done
      echo "   Bei Abweichungen gilt die englische Fassung (Abschnitt 10(c))."
    fi
    echo
    echo "   Kurz: kostenlos fuer Privatpersonen und Bildungseinrichtungen;"
    echo "   die kommerzielle Verwertung bleibt dem Autor vorbehalten. Es gilt"
    echo "   allein der Text in LICENSE, nicht diese Zusammenfassung."
    echo
    echo "2) lpm (Paketmanager)${lpm_version:+, Version $lpm_version}"
    echo
    if [ -f "$D/bin/lpm" ] || [ -f "$D/bin/lpm.exe" ]; then
      echo "   Lizenz: $lpm_lizenz (eigenes Projekt, #2448)"
      echo "   Copyright (c) 2026 Andreas Roene."
      if [ -f "$LPM_SRC/LICENSE" ]; then
        echo "   Volltext: LICENSE.lpm in diesem Verzeichnis."
      else
        echo "   Ein Lizenz-Volltext liegt dem lpm-Projekt nicht bei; die"
        echo "   Angabe stammt aus seiner lyx.toml ($LPM_SRC/lyx.toml)."
      fi
    else
      echo "   In diesem Paket NICHT enthalten (siehe WERKZEUGE-STATUS.txt)."
    fi
    echo
    echo "3) share/lyx/pci.ids — Datendatei des PCI-ID-Projekts, NICHT vom"
    echo "   Lyx-Autor. Eigene Lizenz und Herkunft:"
    echo "   share/lyx/pci.ids.LICENSE in diesem Verzeichnis."
    echo
    echo "Erzeugnisse, die mit diesem Compiler uebersetzt werden, sind nicht"
    echo "Gegenstand dieser Aufzaehlung; was fuer sie gilt, steht in LICENSE."
  } > "$D/LIZENZEN.txt"
  [ -f "$LPM_SRC/LICENSE" ] && cp "$LPM_SRC/LICENSE" "$D/LICENSE.lpm"

  cat > "$D/VERSION" <<EOF
lyxc $VERSION
Backend:  $name
Ziel:     --target=$target --format=$format
Gebaut:   $DATUM
Commit:   $COMMIT
Units:    $n_ok .lyu (von ${#UNIT_QUELLEN[@]} Quellen)
EOF

  install_anleitung "$name" "$target" "$binname" > "$D/INSTALL.md"

  # 4) Beispiele. Sie werden MITGELIEFERT UND GEPRUEFT: jedes wird fuer dieses
  #    Ziel uebersetzt, und das Ergebnis steht in EXAMPLES-STATUS.txt. Ein
  #    Beispielordner, in dem die Haelfte nicht uebersetzt, ist sonst eine
  #    stille Enttaeuschung — der Nutzer haelt den Fehler fuer seinen eigenen.
  echo "  [5/5] Beispiele pruefen und mitliefern"
  rm -rf "$D/examples"
  mkdir -p "$D/examples"
  local b
  for b in "${DIST_BSP[@]}"; do
    mkdir -p "$D/examples/$(dirname "$b")"
    cp "$ROOT/examples/$b" "$D/examples/$b"
  done
  # Datendateien, die ein Beispiel zur Laufzeit liest (ml/*.csv u. ae.).
  ( cd "$ROOT/examples" && find . -type f ! -name '*.lyx' -print0 ) \
    | ( cd "$D/examples" && xargs -0 -r -I{} sh -c 'mkdir -p "$(dirname "{}")" && cp "$0/examples/{}" "{}"' "$ROOT" )
  # KEIN Quellenbaum im Paket. Die stdlib wird ausschliesslich als .lyu
  # ausgeliefert; ihre Quelltexte kommen aus dem LPM-Paket `std` (#2448).
  # Frueher lag hier eine Kopie unter src-std/, auf die der Beispiel-Schritt
  # zurueckfiel — damit trug jedes Paket die stdlib zweimal, einmal als
  # Vorkompilat und einmal als .lyx. Ein Beispiel, das die .lyu nicht reicht,
  # ist jetzt ROT und nennt den Grund, statt still aus Quellen zu bauen.
  rm -rf "$D/src-std"

  local BSP; BSP=()
  for b in "${DIST_BSP[@]}"; do BSP+=("examples/$b"); done
  local BSP_LOG; BSP_LOG="$(mktemp -d)"
  export BSP_LOG LYXC ROOT
  export BSP_UNITS="$D/include/lyx/units"
  if [ "$selbstbaubar" = "ja" ]; then export FORMAT="$format"; else export FORMAT=""; fi
  # Die Beispiele werden fuer DIESES Backend uebersetzt — unabhaengig davon,
  # mit welchem Ziel die Units gebaut wurden. Vorher erbte dieser Schritt das
  # leere $ZIEL aus dem Unit-Schritt (UNITS_ZIEL=host setzt ZIEL=""), uebersetzte
  # also fuer den HOST und schrieb das Ergebnis als "uebersetzt fuer $target"
  # in EXAMPLES-STATUS.txt. Sichtbar wurde es daran, dass arm64, riscv64,
  # macos-x86_64, macos-arm64 und lyxos dieselbe Zahl meldeten wie linux
  # (43 OK / 37 QUELLE / 7 ROT) — ein Messwert ueber den Host, nicht ueber das Ziel.
  export ZIEL="$target"
  printf '%s\0' "${BSP[@]}" | xargs -0 -P "$JOBS" -n1 "$0" --ein-beispiel >/dev/null 2>&1

  local n_ok_b=0 n_rot_b=0 n_quelle_b=0
  {
    echo "# Beispiele, uebersetzt fuer $target ($name), Stand $DATUM, lyxc $VERSION"
    echo "# Auswahl aus tools/dist_examples.txt; Messprogramme sind nicht dabei."
    echo "#"
    echo "# OK     = uebersetzt mit diesem Baum, so wie er ist"
    echo "# QUELLE = kommt nicht mehr vor: das Paket traegt keine stdlib-Quellen."
    echo "# ROT    = uebersetzt nicht; der Grund steht dahinter. Auf win64 sind"
    echo "#          das meist #2459, #2460 oder #1678 — dieselben Beispiele"
    echo "#          gehen fuer linux durch."
    echo
  } > "$D/EXAMPLES-STATUS.txt"
  local lg grund
  for b in "${BSP[@]}"; do
    lg="$BSP_LOG/$(echo "${b#examples/}" | tr / _).log"
    if [ -f "$lg.nurquelle" ]; then
      printf 'QUELLE %s\n' "${b#examples/}" >> "$D/EXAMPLES-STATUS.txt"
      n_quelle_b=$((n_quelle_b+1))
    elif [ -f "$lg" ]; then
      grund="$(grep -m1 -iE '^error|^lyxc:|sema error|Parse error' "$lg" | cut -c1-160)"
      [ -n "$grund" ] || grund="$(tail -1 "$lg" | cut -c1-160)"
      printf 'ROT    %-51s %s\n' "${b#examples/}" "$grund" >> "$D/EXAMPLES-STATUS.txt"
      n_rot_b=$((n_rot_b+1))
    else
      printf 'OK    %s\n' "${b#examples/}" >> "$D/EXAMPLES-STATUS.txt"
      n_ok_b=$((n_ok_b+1))
    fi
  done
  rm -rf "$BSP_LOG"
  {
    echo
    echo "# $n_ok_b von $((n_ok_b + n_rot_b + n_quelle_b)) uebersetzen fuer $target,"
    echo "# $n_quelle_b brauchen zusaetzlich die stdlib-Quellen, $n_rot_b scheitern."
  } >> "$D/EXAMPLES-STATUS.txt"
  echo "        $n_ok_b/$((n_ok_b + n_rot_b + n_quelle_b)) Beispiele uebersetzen, $n_quelle_b brauchen Quellen, $n_rot_b rot"
  # Ein rotes Beispiel macht den Lauf NICHT rot: die Ursachen sind bekannte,
  # je eigene Issues (#2459, #2460, #1678). Sichtbar muss es sein, nicht
  # blockierend.

  if [ "$fehler" -eq 0 ]; then echo "  == $name fertig"; else echo "  == $name MIT FEHLERN (siehe $D/UNITS-FEHLER.txt)"; fi
  return "$fehler"
}

# ── Installationsanleitung je Backend ────────────────────────────────────────
install_anleitung() {
  local name="$1" target="$2" binname="$3"
  cat <<EOF
# lyxc $VERSION — Auslieferbaum $name

Gebaut am $DATUM aus Commit $COMMIT.

## Inhalt

    bin/$binname                    Compiler fuer dieses Ziel
    bin/lbfdump, bin/lpm, …         Hilfswerkzeuge fuer dieses Ziel
    include/lyx/units/std/**.lyu    vorkompilierte Standardbibliothek
    include/lyx/units/data/**.lyu   vorkompilierte Datenunits
    share/lyx/pci.ids               Datendatei (std/hardware/pci_ids.lyx liest sie zur Laufzeit)
    LICENSE                         Volltext der Lyx-Lizenz (LPCL 1.0, englisch)
    LICENSE.es                      spanische Uebersetzung (unverbindlich)
    LIZENZEN.txt                    welche Lizenz fuer welchen Bestandteil gilt

Die Units sind mit dem Host-Ziel vorkompiliert (UNITS_ZIEL=host). Das ist
gemessen, nicht angenommen: ein Erzeugnis fuer $target ist bytegleich,
unabhaengig davon, mit welchem Ziel die .lyu gebaut wurden (40 Programme aus
examples/, 14 uebersetzbar, 14 bytegleich, 0 abweichend).

## Lizenz

Compiler, Standardbibliothek, Beispiele und die Werkzeuge aus diesem
Repository stehen unter der Lyx Proprietary & Community License (LPCL 1.0),
Volltext in \`LICENSE\` (englisch, massgeblich); \`LICENSE.es\` ist eine
unverbindliche spanische Uebersetzung. \`lpm\` hat eine eigene Lizenz, \`share/lyx/pci.ids\`
stammt aus dem PCI-ID-Projekt und hat wieder eine andere —
\`LIZENZEN.txt\` sagt je Bestandteil, welche gilt und wo ihr Text steht.

## Werkzeuge in bin/

Neben dem Compiler liegen die Hilfswerkzeuge, ebenfalls fuer $target gebaut:
\`lbfdump\` (LBF/LYX!-Container lesen und pruefen), \`lbfimport\`,
\`lbfloader\`, \`lbfrun\`, \`lyxcpu\`, \`cpufeatures\` und der Paketmanager
\`lpm\`. Welche davon fuer dieses Ziel uebersetzt haben, steht mit Groesse
bzw. Fehlergrund in \`WERKZEUGE-STATUS.txt\`.

## Nur Vorkompilate, keine stdlib-Quellen

Das Paket traegt die Standardbibliothek ausschliesslich als \`.lyu\` unter
\`include/lyx/units/\`. Quelltexte liegen bewusst nicht bei — sie kommen aus
dem LPM-Paket \`std\` (#2448), und der Import-Resolver bevorzugt .lyx vor
.lyu, mitgelieferte Quellen wuerden die Vorkompilate aushebeln.

Manche .lyu beschreiben nicht alle Symbole ihrer Unit; ein Programm, das so
eine Unit braucht, bricht ab mit "Quelle der importierten Unit nicht lesbar"
oder "stammt aus einer .lyu ohne Objektcode". Das betrifft vor allem Units mit
FFI-Externs (std.net.socket, std.db.sqlite, die Qt-Units). Solche Programme
brauchen die stdlib-Quellen aus dem LPM-Paket; \`EXAMPLES-STATUS.txt\` nennt
sie mit genau dieser Meldung.

## Beispiele

Der Anfang ist \`examples/hello_world.lyx\`:

    lyxc examples/hello_world.lyx -o hello_world && ./hello_world

\`examples/\` enthaelt die Beispielprogramme, \`EXAMPLES-STATUS.txt\` sagt fuer
JEDES, ob es mit diesem Baum uebersetzt (OK), den Quellenbaum braucht
(QUELLE) oder fuer dieses Ziel nicht uebersetzt (ROT, mit Grund). Geprueft
beim Bau des Baums, nicht behauptet.

Ausgeliefert ist eine Auswahl (tools/dist_examples.txt im Quellbaum): die
Mess- und Bisektionsprogramme alter Fehlersuchen bleiben im Quellbaum.
EOF

  case "$name" in
    linux-arm64|linux-riscv64|macos-arm64|lyxos)
      cat <<EOF

## Beispiele und Units: bekannte Luecke auf diesem Ziel (#2472)

Die mitgelieferten .lyu sind mit dem HOST-Ziel (x86-64) vorkompiliert. Das
Typlayout haengt aber am Ziel: \`StringBuilder\` ist auf x86-64 32 Bytes gross
(Typwort 1), auf arm64 24 (Typwort 0). Der Codegen prueft das beim Import und
bricht ab mit

    error: .lyu: Layout von 'StringBuilder' weicht ab:
      Datei Groesse 32 Typwort 1, dieses Ziel Groesse 24 Typwort 0

Darum scheitern auf diesem Ziel mehr Beispiele, als es muesste —
\`EXAMPLES-STATUS.txt\` nennt je Datei den Grund. Gemessen an linux-arm64: mit
diesen Units uebersetzen 40 von 87 Beispielen, mit zielweise gebauten Units 62.

Wer den Baum heute schon zielweise braucht, baut ihn im Quellbaum neu:

    UNITS_ZIEL=ziel tools/build_dist.sh $name

Dann sind 16 von 500 Units unuebersetzbar und der Baum unvollstaendig; genau
das ist der offene Teil von #2472.
EOF
      ;;
  esac

  if [ "$name" = "win64" ]; then
    cat <<'EOF'

## Installation unter Windows

Baum an einen festen Platz legen, z. B.:

    C:\Program Files\lyx\bin\lyxc.exe
    C:\Program Files\lyx\include\lyx\units\...
    C:\Program Files\lyx\share\lyx\...

Dann \`bin\` in \`PATH\` aufnehmen. Beim Aufruf gehoeren ZWEI Angaben dazu:

    lyxc.exe --std-path="C:\Program Files\lyx\include\lyx\units" ^
             --target=win64 --format=pe prog.lyx -o prog.exe

\`--target=win64 --format=pe\` ist nicht optional: auch die Windows-Binary
erzeugt ohne diese Angabe ein **Linux-ELF**, nicht eine .exe. Das Ziel haengt
am Schalter, nicht daran, auf welchem System der Compiler laeuft (gemessen:
ohne Schalter beginnt das Erzeugnis mit 7f 45 4c 46 statt mit MZ). Fuer einen
Installer lohnt daher eine Wrapper-Datei \`lyxc.cmd\`, die beides vorbelegt.

Alle Pfade im Baum sind relativ; fuer Inno Setup, WiX oder MSI reicht es, das
Verzeichnis als Ganzes zu uebernehmen und PATH zu setzen.

## Was unter Windows NOCH NICHT traegt

Drei gemessene Luecken, alle als Issue gefuehrt:

* **#2459** — ein geschachtelter Feldzugriff (\`r.min.x\`, \`q.x.lo\`) scheitert
  unter \`--target=win64\` mit "error: #2134: Feld nicht aufloesbar"; fuer linux
  uebersetzt dieselbe Quelle. Das trifft nicht nur die Standardbibliothek,
  sondern JEDES Programm mit zweistufigem Feldzugriff. Die groesste der drei
  Luecken.
* **#2460** — \`mulhi\`/\`umulhi\` fehlen in der ir_lower-Aufzaehlung, deshalb
  uebersetzt auf win64 keine Unit aus std/crypto und auch std/net/tls13 nicht.
  Kein TLS, kein RSA, kein Ed25519.
* **#1678** — im erzeugten Code stehen rohe Linux-Syscalls (beim Bau dieses
  Compilers gemeldet, siehe COMPILER-WARNUNGEN.txt). Nur mmap und munmap haben
  einen Windows-Ersatz. Unter wine traegt das, weil wine die Linux-Seite
  mitbringt; auf echtem Windows trifft jeder uebrige Aufruf einen fremden
  NT-Dienst.

Gegen wine ist der Baum geprueft (lyxc.exe uebersetzt und das Erzeugnis gibt
den erwarteten Wert aus). Auf echtem Windows ist er NICHT geprueft, und #1678
steht dem im Weg. Wer daraus eine Installation baut, sollte das wissen.
EOF
  else
    cat <<EOF

## Installation (unixartig)

    install -Dm755 bin/$binname          /usr/local/bin/lyxc
    mkdir -p /usr/include/lyx /usr/share/lyx
    cp -r include/lyx/units               /usr/include/lyx/
    cp -r share/lyx/.                     /usr/share/lyx/

Fuer x86-64-Linux gibt es den fertigen Weg \`make deb\` (dpkg-Paket
\`lyx-compiler\`); dieser Baum ist die backendneutrale Form daneben.
EOF
  fi
}

# ── Hauptlauf ────────────────────────────────────────────────────────────────
if [ $# -gt 0 ]; then WUNSCH=("$@"); else read -r -a WUNSCH <<<"$BACKENDS_VORGABE"; fi

mkdir -p "$AUS"
GESAMT=0
for b in "${WUNSCH[@]}"; do
  backend_bauen "$b" || GESAMT=1
done

echo
echo "Auslieferbaeume unter $AUS/:"
for b in "${WUNSCH[@]}"; do
  [ -d "$AUS/$b" ] && printf '  %-16s %s\n' "$b" "$(du -sh "$AUS/$b" | cut -f1)"
done
if [ "$GESAMT" -eq 0 ]; then echo "Ergebnis: vollstaendig"; else echo "Ergebnis: MIT FEHLERN"; fi
exit "$GESAMT"
