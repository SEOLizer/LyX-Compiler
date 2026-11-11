#!/usr/bin/env bash
# tools/build_dist.sh — Auslieferbaum je Backend unter build/<backend>/.
#
# Je Backend entsteht ein vollstaendiger, in sich geschlossener Baum:
#
#   build/<backend>/bin/lyxc[.exe]              Compiler FUER DIESES ZIEL
#   build/<backend>/include/lyx/units/std/**    vorkompilierte Standardbibliothek
#   build/<backend>/include/lyx/units/data/**   vorkompilierte Datenunits
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
  # Zweiter Versuch gegen den Quellenbaum — aber NUR fuer den einen Grund, der
  # ihn rechtfertigt. Ein zweiter Versuch "auf gut Glueck" wuerde jeden echten
  # Fehler zweimal zeigen und die Ursachen vermischen.
  # Zwei Meldungen, dieselbe Ursache: die .lyu reicht dem Codegen nicht. Die
  # zweite ("stammt aus einer .lyu ohne Objektcode") kam in der ersten Fassung
  # nicht in den zweiten Versuch und stand mit 43 Faellen als "rot" da,
  # obwohl der Quellenbaum sie traegt.
  if grep -qE "Quelle der importierten Unit nicht lesbar|stammt aus einer \.lyu ohne Objektcode" "$log"; then
    if ( cd "$BSP_LOG" && timeout 120 "$LYXC" --std-path="$BSP_SRC" \
           ${ZIEL:+--target="$ZIEL"} ${FORMAT:+--format="$FORMAT"} \
           "$ROOT/$q" -o /dev/null ) >"$log.quelle" 2>&1; then
      mv "$log.quelle" "$log.nurquelle"; rm -f "$log"; exit 0
    fi
    # Auch mit Quellen rot: dann ist der Quellenbedarf nicht die Ursache.
    mv "$log.quelle" "$log"
  fi
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
DATUM="$(date +%Y-%m-%d)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unbekannt)"

mapfile -t UNIT_QUELLEN < <( { find std -name '*.lyx'; find data -name '*.lyx'; } | sort )
[ "${#UNIT_QUELLEN[@]}" -gt 0 ] || { echo "FEHLER: keine Unit-Quellen gefunden." >&2; exit 1; }

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
    echo "  [1/3] Compiler uebersprungen (NUR_UNITS=1)"
  elif [ "$selbstbaubar" != "ja" ]; then
    echo "  [1/3] Compiler: fuer $name nicht vorgesehen (nur Units)"
  else
    echo "  [1/3] Compiler uebersetzen ($binname) — dauert Minuten"
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
  echo "  [2/3] ${#UNIT_QUELLEN[@]} Units uebersetzen (UNITS_ZIEL=$UNITS_ZIEL, JOBS=$JOBS)"
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

  # 3) Datendateien und Begleitpapiere
  echo "  [3/3] Datendateien und Begleitpapiere"
  cp share/pci.ids "$D/share/lyx/pci.ids"
  cp share/pci.ids.LICENSE "$D/share/lyx/pci.ids.LICENSE"

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
  echo "  [4/4] Beispiele pruefen und mitliefern"
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
  # Quellenbaum neben den Vorkompilaten. Begruendung in INSTALL.md: manche
  # .lyu beschreiben nicht alle Symbole ihrer Unit, der Codegen liest dann die
  # .lyx. Getrennt gehalten, weil der Resolver .lyx VOR .lyu nimmt — lagen
  # beide im selben Baum, waeren die Vorkompilate totes Gewicht.
  # Gemessen (examples/ml/nn_auto_mpg.lyx, 3 Laeufe): mit .lyu 0,03 s, mit
  # Quellen 0,09 s. Darum bleibt der Unit-Baum der Vorgabeweg.
  rm -rf "$D/src-std"
  mkdir -p "$D/src-std"
  cp -r "$ROOT/std"  "$D/src-std/std"
  cp -r "$ROOT/data" "$D/src-std/data"

  local BSP; BSP=()
  for b in "${DIST_BSP[@]}"; do BSP+=("examples/$b"); done
  local BSP_LOG; BSP_LOG="$(mktemp -d)"
  export BSP_LOG LYXC ROOT
  export BSP_UNITS="$D/include/lyx/units"
  export BSP_SRC="$D/src-std"
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
    echo "# QUELLE = uebersetzt mit --std-path=<baum>/src-std statt mit dem"
    echo "#          Unit-Baum: manche .lyu beschreiben nicht alle Symbole ihrer"
    echo "#          Unit, der Codegen liest dann die .lyx. Kein Fehler des"
    echo "#          Beispiels, und mit diesem Baum lauffaehig."
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
    include/lyx/units/std/**.lyu    vorkompilierte Standardbibliothek
    include/lyx/units/data/**.lyu   vorkompilierte Datenunits
    share/lyx/pci.ids               Datendatei (std/hardware/pci_ids.lyx liest sie zur Laufzeit)

Quelltexte der Standardbibliothek liegen bewusst nicht im Baum — sie kommen
aus dem LPM-Paket \`std\` (#2448). Der Import-Resolver bevorzugt .lyx vor .lyu;
mitgelieferte Quellen wuerden die Vorkompilate aushebeln.

Die Units sind mit dem Host-Ziel vorkompiliert (UNITS_ZIEL=host). Das ist
gemessen, nicht angenommen: ein Erzeugnis fuer $target ist bytegleich,
unabhaengig davon, mit welchem Ziel die .lyu gebaut wurden (40 Programme aus
examples/, 14 uebersetzbar, 14 bytegleich, 0 abweichend).

## Zwei Baeume, und wann welcher

    include/lyx/units/   Vorkompilate (.lyu) -- der Vorgabeweg, schneller
    src-std/             Quelltexte der stdlib (.lyx) -- fuer den Rest

Manche .lyu beschreiben nicht alle Symbole ihrer Unit; der Codegen liest dann
die .lyx und bricht sonst ab mit "Quelle der importierten Unit nicht lesbar".
Das betrifft vor allem Units mit FFI-Externs (std.net.socket, std.db.sqlite,
die Qt-Units). Fuer solche Programme:

    lyxc --std-path=<baum>/src-std prog.lyx -o prog

Beide Baeume stammen aus demselben Commit, koennen also nicht auseinander
laufen. Getrennt gehalten sind sie, weil der Import-Resolver .lyx VOR .lyu
nimmt: lagen sie im selben Verzeichnis, waeren die Vorkompilate nie benutzt.
Gemessen an examples/ml/nn_auto_mpg.lyx, je drei Laeufe: mit .lyu 0,03 s, mit
Quellen 0,09 s.

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
