#!/usr/bin/env bash
# tests/manpage_test.sh — die Handbuchseite und ihr Weg in mandb.
#
# Eine Handbuchseite fällt still aus. Sie kann am falschen Ort liegen, ungepackt
# sein, eine NAME-Zeile im falschen Format haben oder Schalter beschreiben, die
# es nicht mehr gibt — in allen vier Fällen baut das Paket fehlerfrei, und erst
# der Benutzer merkt, dass 'man lyxc' oder 'apropos lyxc' nichts liefert.
#
# Geprüft wird deshalb der WEG, nicht nur die Anwesenheit der Datei:
# übersetzt sie? liest lexgrog die NAME-Zeile, aus der mandb den whatis-Eintrag
# bildet? nimmt ein echter mandb-Lauf sie in seinen Index auf? und beschreibt
# sie dieselben Schalter, die der Compiler heute annimmt?

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
MAN_SRC="$ROOT/man/lyxc.1"
MAN_PKG="$ROOT/lyx-compiler/usr/share/man/man1/lyxc.1.gz"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ── Quelle ───────────────────────────────────────────────────────────────────

if [ -f "$MAN_SRC" ]; then ok "man/lyxc.1 vorhanden"
else no "man/lyxc.1 vorhanden" "fehlt"; echo "--- 0 PASS, 1 FAIL"; exit 1; fi

if command -v groff >/dev/null; then
  gw="$(LC_ALL=C groff -man -Tutf8 -ww -z "$MAN_SRC" 2>&1)"
  if [ -z "$gw" ]; then ok "uebersetzt ohne groff-Warnung"
  else no "uebersetzt ohne groff-Warnung" "$(echo "$gw" | head -3)"; fi
else echo "SKIP groff nicht vorhanden"; fi

# Genau diese Zeile wird zum whatis-Eintrag. Format: 'name \- beschreibung'.
if command -v lexgrog >/dev/null; then
  if lexgrog "$MAN_SRC" 2>/dev/null | grep -q 'lyxc *- '; then
    ok "NAME-Zeile ist fuer whatis/apropos lesbar"
  else
    no "NAME-Zeile ist fuer whatis/apropos lesbar" "$(lexgrog "$MAN_SRC" 2>&1 | head -1)"
  fi
else echo "SKIP lexgrog nicht vorhanden"; fi

# Roff-Quellen sind ASCII. Ein Umlaut im Klartext wird je nach Locale zu Müll
# statt zu einem Umlaut — deshalb die Umschreibung im Text.
if LC_ALL=C grep -qP '[^\x00-\x7F]' "$MAN_SRC" 2>/dev/null; then
  no "reines ASCII" "$(LC_ALL=C grep -nP '[^\x00-\x7F]' "$MAN_SRC" | head -1)"
else ok "reines ASCII"; fi

# ── Deckung: beschreibt die Seite, was der Compiler annimmt? ─────────────────
# Das ist der eigentliche Verfallsschutz. Ein neuer Schalter ohne Eintrag macht
# diesen Test rot, statt die Seite ein Jahr später falsch dastehen zu lassen.

if [ -x "$LYXC" ]; then
  "$LYXC" --help 2>&1 | grep -oE '^\s+--?[a-zA-Z0-9-]+' | tr -d ' ' | sort -u > "$TMP/flags.txt"
  # Im roff-Quelltext steht jeder Schalter mit maskierten Bindestrichen.
  sed 's/\\-/-/g' "$MAN_SRC" > "$TMP/man.txt"
  # Als ganzes Wort suchen: '--mcdc' steckt in '--mcdc-report'. Mit einer
  # Teilstring-Suche galt ein gelöschter Schalter als beschrieben, solange ein
  # längerer Verwandter in der Seite stand — der Test wäre grün geblieben.
  fehlt=""
  while read -r f; do
    grep -qE -- "$(printf '%s' "$f" | sed 's/[.[\*^$]/\\&/g')([^a-zA-Z0-9-]|$)" "$TMP/man.txt" \
      || fehlt="$fehlt $f"
  done < "$TMP/flags.txt"
  if [ -z "$fehlt" ]; then
    ok "alle $(wc -l < "$TMP/flags.txt") Schalter aus --help sind beschrieben"
  else
    no "alle Schalter aus --help sind beschrieben" "nicht in der Seite:$fehlt"
  fi

  # Und andersherum: die Seite darf keinen Schalter erfinden. Geprüft wird
  # gegen den Parser, nicht gegen --help — auch ein undokumentierter, aber
  # angenommener Schalter darf in der Seite stehen.
  grep -oE '^\.B[IR]? +\\-\\-[a-z0-9-]+' "$MAN_SRC" | grep -oE '\\-\\-[a-z0-9-]+' \
    | sed 's/\\-/-/g' | sort -u > "$TMP/manflags.txt"
  erfunden=""
  while read -r f; do
    grep -qF -- "\"$f" "$ROOT/src/lyxc.lyx" || erfunden="$erfunden $f"
  done < "$TMP/manflags.txt"
  if [ -z "$erfunden" ]; then
    ok "kein erfundener Schalter in der Seite"
  else
    no "kein erfundener Schalter in der Seite" "kommt im Parser nicht vor:$erfunden"
  fi

  # Die Version im Kopf der Seite ist der Stand, gegen den sie geprueft wurde.
  v="$("$LYXC" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[A-Z]*')"
  if grep -q "lyxc $v" "$MAN_SRC"; then ok "Kopfzeile nennt $v"
  else no "Kopfzeile nennt $v" "$(grep -m1 '^\.TH' "$MAN_SRC")"; fi
else
  echo "SKIP ./lyxc nicht gebaut — Schalterdeckung ungeprueft"
fi

# ── Paketbaum ────────────────────────────────────────────────────────────────

if [ -f "$MAN_PKG" ]; then ok "Seite liegt in usr/share/man/man1/"
else no "Seite liegt in usr/share/man/man1/" "fehlt — tools/make_deb.sh legt sie an"; fi

if [ -f "$MAN_PKG" ]; then
  if gzip -t "$MAN_PKG" 2>/dev/null; then ok "gepackte Seite ist gueltiges gzip"
  else no "gepackte Seite ist gueltiges gzip" "gzip -t schlaegt fehl"; fi

  m="$(stat -c '%a' "$MAN_PKG")"
  if [ "$m" = "644" ]; then ok "Modus 644"; else no "Modus 644" "ist $m"; fi

  if zcat "$MAN_PKG" | diff -q - "$MAN_SRC" >/dev/null; then
    ok "Paketkopie ist inhaltsgleich mit man/lyxc.1"
  else
    no "Paketkopie ist inhaltsgleich mit man/lyxc.1" "veraltet — tools/make_deb.sh laufen lassen"
  fi

  # Der Abschluss: nimmt ein echter mandb-Lauf die Seite auf, und findet
  # whatis sie danach? Ohne diesen Schritt belegt der Test nur, dass eine
  # Datei am richtigen Ort liegt.
  if command -v mandb >/dev/null && command -v whatis >/dev/null; then
    mkdir -p "$TMP/man/man1"
    cp "$MAN_PKG" "$TMP/man/man1/"
    mandb -c -u --no-purge "$TMP/man" >/dev/null 2>&1
    if whatis -M "$TMP/man" lyxc 2>/dev/null | grep -q 'lyxc'; then
      ok "mandb indiziert die Seite, whatis findet sie"
    else
      no "mandb indiziert die Seite, whatis findet sie" "whatis liefert nichts"
    fi
  else echo "SKIP mandb/whatis nicht vorhanden"; fi
fi

# ── Begleitende Pflichtdateien ───────────────────────────────────────────────

DOC="$ROOT/lyx-compiler/usr/share/doc/lyx-compiler"
if [ -f "$DOC/copyright" ]; then ok "copyright vorhanden (Policy 12.5)"
else no "copyright vorhanden (Policy 12.5)" "fehlt"; fi

# Die Vorlage kam mit Platzhaltern aus einem Beispiel-Paket. Sie sind einmal
# durchgerutscht; dieser Test haelt fest, dass sie es nicht wieder tun.
if grep -qE 'mein-tool|dein-nutzername|FIXME|TODO' "$DOC/copyright" 2>/dev/null; then
  no "copyright ohne Platzhalter" "$(grep -nE 'mein-tool|dein-nutzername|FIXME|TODO' "$DOC/copyright" | head -1)"
else ok "copyright ohne Platzhalter"; fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
