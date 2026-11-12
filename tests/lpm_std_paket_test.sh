#!/usr/bin/env bash
# tests/lpm_std_paket_test.sh — #2448.
#
# Seit #2447 liefert das Debian-Paket keinen Lyx-Quellcode mehr; bezogen werden
# die Quellen als LPM-Paket `std`. Dieser Test wacht ueber die Teile, die dabei
# still kaputtgehen koennen -- und er braucht dafuer KEIN lpm und keine
# Registry, denn das Wesentliche steht im Erzeugnis des Generators.
#
# Was hier geprueft wird und warum:
#
#   1. Der Generator exportiert ALLE Units und KEINE .lyu. Eine fehlende Unit
#      faellt beim Verbraucher erst beim Import auf; eine mitexportierte .lyu
#      brachte die Doppelablage zurueck, die #2447 beendet hat (der Resolver
#      zieht .lyx vor .lyu).
#   2. Die Dateizahl bleibt unter PK_MAX_FILES. Seit lpm 0.1.3 ist die Grenze
#      4096 (lpm/core/pack.lyx:50), bei 503 Dateien also reichlich Luft; in
#      0.1.2 waren es 512, und neun Dateien Abstand. Der Test meldet den
#      Abstand weiter, damit es nicht wieder unvermittelt zuschlaegt.
#   3. Die Fassung ist ein reines X.Y.Z. SvParse (lpm/core/semver.lyx:24) liest
#      X.Y.Z und verwirft den Rest STILL: aus "1.2.34B" wird 1.2.34. Wer die
#      Compilerfassung als Paketfassung nimmt, veroeffentlicht zwei Bauten
#      unter einer Nummer.
#   4. [build.units] traegt die EINSTUFIGEN std-Units, und keinen Schluessel
#      zweimal. Zwei Dinge sind dabei gemessen worden, nicht angenommen:
#
#      a) `lpm resolve <paket>.<unit>` schneidet am LETZTEN '/' (cmdUnitPath,
#         lpm/cli/commands.lyx): "std.net.http" sucht Paket "std/net" mit
#         Schluessel "http", nicht Paket "std" mit "net.http". Gemessen an
#         einer Probe -- `resolve <paket>.fs` liefert den Pfad,
#         `resolve <paket>.net.types` meldet "fuehrt 'types' nicht unter
#         [build.units]". Die 364 mehrstufigen Units gehoeren deshalb NICHT
#         in den Abschnitt: ein wirkungsloser Eintrag behauptet eine
#         Zusicherung, die es nicht gibt. Ueber LYX_STD_PATH sind sie alle
#         erreichbar, dort zaehlt der Pfad.
#      b) Die Units unter data/ heissen `import data.core` und gehoeren zum
#         Paketnamen "data". Im ersten Anlauf standen sie mit drin, und
#         "data/io.lyx" bekam denselben Schluessel "io" wie "std/io.lyx" --
#         ein doppelter Schluessel, von dem einer still gewinnt.
#
# Der Teil, der lpm braucht (packen, Reproduzierbarkeit, Bezug aus dem Cache),
# laeuft nur, wenn lpm da ist, und sagt sonst SKIP. Gemessen beim Anlegen gegen
# lpm 0.1.4: Paket 2,7 MB, zweimal gepackt derselbe SHA256, aus dem Cache
# uebersetzt und ausgefuehrt -- auch std.net.tls, dessen extern-fn-Deklarationen
# ohne massgeblichen Baum an der FFI-Sandbox scheitern (#2202).
#
# Er bekommt dafuer ein EIGENES Heimatverzeichnis: lpm leitet den Cache aus HOME
# ab (lpm/core/cache.lyx:48, HOME aus envp in lpm/cli/commands.lyx:84). Ohne das
# schriebe der Test in den echten ~/.lpm/cache des Benutzers. Dazu --offline,
# damit er nicht an der Registry haengt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
nok()  { echo "FAIL $1"; FAIL=$((FAIL+1)); }
skip() { echo "UEBERSPRUNGEN $1"; }

cd "$ROOT" || exit 1
echo "--- #2448: LPM-Paket std ---"

GEN="tools/lpm_std_paket.sh"
[ -x "$GEN" ] || { nok "$GEN fehlt oder ist nicht ausfuehrbar"; echo "1 FAIL"; exit 1; }

n_soll="$(find std data -name '*.lyx' | wc -l)"

# --- 1-4: am Erzeugnis des Generators, ohne lpm ------------------------------
# Der Export laeuft auch ohne lpm bis zum Packen; dafuer wird der Aufruf
# abgefangen. Geprueft wird, was im Exportverzeichnis liegt.
if command -v lpm >/dev/null; then
  if (ulimit -v 8000000; bash "$GEN" --export "$TMP/exp" --outdir "$TMP/out") >"$TMP/gen.log" 2>&1; then
    ok "Generator laeuft durch"
  else
    nok "Generator scheitert: $(grep -m1 -i fehler "$TMP/gen.log" | cut -c1-120)"
  fi
else
  skip "lpm nicht installiert — Generator nicht gefahren (Teil 1-4 messen am Export)"
fi

if [ -d "$TMP/exp" ]; then
  n_lyx="$(find "$TMP/exp" -name '*.lyx' | wc -l)"
  if [ "$n_lyx" -eq "$n_soll" ]; then
    ok "alle $n_soll Units exportiert"
  else
    nok "nur $n_lyx von $n_soll Units exportiert"
  fi

  n_lyu="$(find "$TMP/exp" -name '*.lyu' | wc -l)"
  if [ "$n_lyu" -eq 0 ]; then
    ok "keine .lyu im Quellpaket"
  else
    nok "$n_lyu .lyu im Quellpaket — die Doppelablage aus #2447 waere zurueck"
  fi

  # Grenzen aus lpm/core/pack.lyx, Stand 0.1.3 (vorher 512 bzw. 4).
  PKF=4096; PKT=8
  n_dat="$(find "$TMP/exp" -type f | wc -l)"
  luft=$((PKF - n_dat))
  if [ "$n_dat" -le "$PKF" ]; then
    if [ "$luft" -lt 50 ]; then
      ok "$n_dat Dateien, aber nur $luft unter PK_MAX_FILES ($PKF) — knapp"
    else
      ok "$n_dat Dateien, $luft Luft bis PK_MAX_FILES ($PKF)"
    fi
  else
    nok "$n_dat Dateien — ueber PK_MAX_FILES ($PKF), lpm pack scheitert mit PK_ERR_LIMIT"
  fi

  tief="$(cd "$TMP/exp" && find . -type f | awk -F/ '{print NF-1}' | sort -rn | head -1)"
  if [ "${tief:-0}" -le "$PKT" ]; then
    ok "Verzeichnistiefe $tief (PK_DEPTH_MAX $PKT)"
  else
    nok "Verzeichnistiefe $tief — lpm packt bis $PKT"
  fi

  v="$(grep -m1 '^version' "$TMP/exp/lyx.toml" | sed 's/.*"\(.*\)".*/\1/')"
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*)
        rest="${v##*.}"
        case "$rest" in
          *[!0-9]*) nok "Fassung '$v' hat einen Suffix — SvParse verwirft ihn STILL" ;;
          *)        ok "Fassung '$v' ist ein reines X.Y.Z" ;;
        esac ;;
    *)  nok "Fassung '$v' ist kein X.Y.Z" ;;
  esac

  # [build.units]: vorhanden, genau die einstufigen std-Units, keine Dublette,
  # und nichts aus data/.
  # Nur die Zeilen IM Abschnitt: die Kopfzeilen (name, version, ...) haben
  # dieselbe Form und machten aus 130 Units 136 Eintraege.
  units_zeilen() { awk '/^\[build\.units\]/{s=1;next} /^\[/{s=0} s&&/=/{print $1}' "$1"; }
  n_key="$(units_zeilen "$TMP/exp/lyx.toml" | wc -l)"
  n_eins="$(find std -maxdepth 1 -name '*.lyx' | wc -l)"
  if [ "$n_key" -eq "$n_eins" ]; then
    ok "[build.units] traegt alle $n_eins einstufigen std-Units"
  else
    nok "[build.units] hat $n_key Eintraege, erwartet $n_eins"
  fi

  dopp="$(units_zeilen "$TMP/exp/lyx.toml" | sort | uniq -d)"
  if [ -z "$dopp" ]; then
    ok "kein Schluessel zweimal in [build.units]"
  else
    nok "doppelte Schluessel: $(echo $dopp | tr '\n' ' ')— einer gewinnt still"
  fi

  if awk '/^\[build\.units\]/{s=1;next} /^\[/{s=0} s&&/"data\//{f=1} END{exit !f}' "$TMP/exp/lyx.toml"; then
    nok "data/-Units unter [build.units] — sie gehoeren zum Paketnamen 'data'"
  else
    ok "keine data/-Units unter [build.units]"
  fi
else
  skip "kein Export vorhanden — Teil 1-4 nicht messbar"
fi

# --- 5. Bezug aus dem Cache: uebersetzen UND ausfuehren ----------------------
# Die Wirkung, nicht das Vorhandensein. Ein Test, der nur das Entpacken prueft,
# waere auch von einem Paket erfuellt, dessen Units nicht uebersetzen.
# Jedes .lxpkg, nicht "std-*": der Name steckt im Dateinamen, und das Muster
# "std-*" fand "lyx-std-dev-0.1.0.lxpkg" nicht mehr -- Teil 5 wurde dann als
# UEBERSPRUNGEN gemeldet, was wie "kein lpm da" aussieht und keine Luecke.
pkg="$(find "$TMP/out" -name '*.lxpkg' 2>/dev/null | head -1)"
if [ -z "$pkg" ] || ! command -v lpm >/dev/null; then
  skip "kein Paket gebaut (lpm fehlt) — Bezug aus dem Cache nicht gemessen"
else
  # Name und Fassung aus dem Manifest, nicht aus dem Dateinamen geraten: der
  # Name ist seit dem 2026-11-09 "lyx-std-dev" (siehe Kopf des Generators), und
  # ein Test, der "std" annimmt, prueft dann etwas anderes als das Erzeugnis.
  nm="$(grep -m1 '^name' "$TMP/exp/lyx.toml" | sed 's/.*"\(.*\)".*/\1/')"
  v="$(grep -m1 '^version' "$TMP/exp/lyx.toml" | sed 's/.*"\(.*\)".*/\1/')"
  # EIGENES Heimatverzeichnis: lpm leitet seinen Cache aus HOME ab
  # (lpm/core/cache.lyx:48, lpm/cli/commands.lyx:84 liest HOME aus envp).
  # Ohne das schriebe dieser Test in den echten ~/.lpm/cache des Benutzers --
  # ein Test hat ausserhalb seines Arbeitsverzeichnisses nichts zu suchen.
  # --offline dazu: der Cache-Treffer genuegt, und ein Netzzugriff machte den
  # Test von der Registry abhaengig.
  mkdir -p "$TMP/home"
  if HOME="$TMP/home" lpm --offline cache add "$pkg" "$nm" "$v" >"$TMP/add.log" 2>&1; then
    cachedir="$TMP/home/.lpm/cache/$nm/$v"
    printf 'import std.io;\nimport std.string;\nfn main(): int64 { PrintLn(StrConcat("a"c, "b"c)); return 0; }\n' \
      > "$TMP/p.lyx"
    if ( cd "$TMP" && ulimit -v 4000000; LYX_STD_PATH="$cachedir" "$LYXC" "$TMP/p.lyx" -o "$TMP/p" ) >"$TMP/c.log" 2>&1; then
      aus="$( (ulimit -v 2000000; "$TMP/p") 2>/dev/null | head -1)"
      if [ "$aus" = "ab" ]; then
        ok "aus dem Cache uebersetzt und ausgefuehrt (LYX_STD_PATH), Ausgabe stimmt"
      else
        nok "aus dem Cache uebersetzt, Ausgabe '$aus' statt 'ab'"
      fi
    else
      nok "uebersetzt nicht gegen den Cache: $(grep -m1 -iE 'error' "$TMP/c.log" | cut -c1-110)"
    fi
    # [build.units] an der WIRKUNG pruefen, nicht an der Form: ein Eintrag,
    # den `lpm resolve` nicht findet, ist eine Behauptung ohne Deckung.
    rp="$( cd "$TMP" && HOME="$TMP/home" lpm --offline resolve "$nm.fs" --entry 2>/dev/null | tail -1)"
    case "$rp" in
      */std/fs.lyx) ok "lpm resolve $nm.fs liefert $rp" ;;
      *)            nok "lpm resolve $nm.fs liefert '$rp' statt eines Pfads auf std/fs.lyx" ;;
    esac
    # Gegenprobe zum NAMEN: unter "lyx-std-dev" darf `resolve std.fs` NICHT
    # treffen -- lpm bildet den Importnamen auf den Paketnamen ab. Ohne diese
    # Haelfte bliebe unklar, ob der Treffer oben am Namen oder am Zufall liegt.
    if [ "$nm" != "std" ]; then
      if ( cd "$TMP" && HOME="$TMP/home" lpm --offline resolve "std.fs" --entry ) >/dev/null 2>&1; then
        nok "resolve std.fs trifft, obwohl das Paket '$nm' heisst"
      else
        ok "resolve std.fs trifft nicht — der Paketname bindet (Paket heisst '$nm')"
      fi
    fi
    # Und die Gegenseite: eine mehrstufige Unit ist ueber resolve NICHT
    # erreichbar. Ohne diese Haelfte koennte der Abschnitt stillschweigend
    # unvollstaendig sein und der Test waere zufrieden.
    if ( cd "$TMP" && HOME="$TMP/home" lpm --offline resolve "$nm.net.types" --entry ) >/dev/null 2>&1; then
      ok "lpm resolve std.net.types geht jetzt auch — Eintraege nachziehen"
    else
      ok "mehrstufige Units bleiben resolve-fremd (erwartet, siehe Kopf)"
    fi

    # std.net.tls: extern fn ohne @capabilities geht nur im MASSGEBLICHEN Baum
    # (#2202). Faellt der Cache nicht darunter, scheitert genau das.
    printf 'import std.io;\nimport std.net.tls;\nfn main(): int64 { return 0; }\n' > "$TMP/t.lyx"
    if ( cd "$TMP" && ulimit -v 4000000; LYX_STD_PATH="$cachedir" "$LYXC" "$TMP/t.lyx" -o "$TMP/t" ) >"$TMP/t.log" 2>&1; then
      ok "std.net.tls uebersetzt aus dem Cache (FFI-Vertrauen greift, #2202)"
    else
      nok "std.net.tls scheitert: $(grep -m1 -iE 'error' "$TMP/t.log" | cut -c1-110)"
    fi
  else
    nok "lpm cache add scheitert: $(tail -1 "$TMP/add.log" | cut -c1-110)"
  fi
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
