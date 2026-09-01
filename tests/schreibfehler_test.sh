#!/bin/bash
# #1682 — Schlaegt das Schreiben der Ausgabedatei fehl, muss lyxc das am
# EXIT-STATUS zeigen. Vorher endete es mit 0: ein Makefile oder eine CI hielt
# den Lauf fuer erfolgreich und arbeitete mit dem ALTEN Binary weiter.
#
# Der Test prueft deshalb den Status und den Kanal, nicht die Meldung allein —
# eine Meldung auf stdout haben wir schon gehabt, und genau die uebersieht
# jeder Filter. Ein Test, der nur "es steht etwas da" prueft, waere vor dem Fix
# gruen gewesen.
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1"; F=$((F+1)); }

cat > "$TMP/q.lyx" <<'EOF'
import std.io;
fn main(): int64 { PrintLn("x"); return 0; }
EOF

# Uebersetzt der Quelltext ueberhaupt? Sonst misst alles Weitere nichts.
if "$LYXC" --std-path=. "$TMP/q.lyx" -o "$TMP/gut" > "$TMP/gut.out" 2> "$TMP/gut.err"; then
  ok "Erfolgsfall endet mit Status 0"
else
  bad "Erfolgsfall endet mit Status $? (sollte 0 sein)"
fi
if [ -s "$TMP/gut" ]; then ok "Erfolgsfall legt die Datei an"; else bad "Erfolgsfall legt keine Datei an"; fi

# 1) Pfad nicht beschreibbar. Als root waere /root schreibbar — dann ein
#    Verzeichnis ohne Schreibrecht selbst herstellen, statt still zu bestehen.
sperr="$TMP/sperre"; mkdir -p "$sperr"; chmod 555 "$sperr"
ziel="$sperr/raus"
if [ -w "$sperr" ]; then
  echo "SKIP: Verzeichnis bleibt schreibbar (vermutlich root) — Fall 'nicht beschreibbar' nicht pruefbar"
else
  "$LYXC" --std-path=. "$TMP/q.lyx" -o "$ziel" > "$TMP/a.out" 2> "$TMP/a.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "nicht beschreibbarer Pfad: Status $rc"; else bad "nicht beschreibbarer Pfad endet mit 0"; fi
  if [ -s "$TMP/a.err" ] && grep -q "Ausgabedatei" "$TMP/a.err"; then
    ok "Meldung steht auf stderr"
  else
    bad "Meldung nicht auf stderr (stdout: $(grep -c . "$TMP/a.out") Zeilen, stderr: $(grep -c . "$TMP/a.err"))"
  fi
fi
chmod 755 "$sperr"

# 2) Ziel ist ein Verzeichnis.
"$LYXC" --std-path=. "$TMP/q.lyx" -o "$TMP" > "$TMP/b.out" 2> "$TMP/b.err"
rc=$?
if [ "$rc" -ne 0 ]; then ok "Ziel ist ein Verzeichnis: Status $rc"; else bad "Ziel ist ein Verzeichnis, endet aber mit 0"; fi

# 3) ETXTBSY — die Zieldatei laeuft gerade. Das ist der Fall aus dem Bericht:
#    er tritt auf, ohne dass man etwas falsch macht, und die Ursache ist von
#    aussen nicht zu sehen. Deshalb muss die Meldung sie benennen.
cat > "$TMP/lauf.lyx" <<'EOF'
import std.io;
fn main(): int64 { var i: int64 := 0; while (i < 900000000) { i := i + 1; } return 0; }
EOF
#
#    #1911: Diese Pruefung setzte voraus, dass die Umgebung ETXTBSY ueberhaupt
#    erzeugt. Auf dem CI-Runner tut sie das nicht — dort ist das Ziel seit
#    sechs Mergen rot, jedes Mal an diesen beiden Zeilen, und ein roter Lauf,
#    der immer rot ist, wird ueberlesen. Genau deshalb musste #1910 mit
#    `--admin` an der Pruefung vorbei gemergt werden.
#
#    Die Voraussetzung wird jetzt GEMESSEN, statt sie anzunehmen: eine
#    Sonde schreibt selbst in die laufende Datei. Scheitert sie, gilt die
#    Sperre und die eigentliche Pruefung laeuft. Scheitert sie NICHT, sagt der
#    Test das laut und ueberspringt — die Sonde veraendert dabei nichts,
#    denn sie schlaegt im interessanten Fall fehl.
if "$LYXC" --std-path=. "$TMP/lauf.lyx" -o "$TMP/laeuft" > /dev/null 2>&1; then
  chmod +x "$TMP/laeuft"
  "$TMP/laeuft" & busy=$!
  sleep 1
  if ! kill -0 "$busy" 2>/dev/null; then
    echo "UEBERSPRUNGEN ETXTBSY: das Hilfsprogramm lief nicht lange genug (#1911)"
  elif ( printf '' >> "$TMP/laeuft" ) 2>/dev/null; then
    # Die Umgebung laesst das Schreiben in eine laufende Datei zu. Dann kann
    # der Compiler ETXTBSY nicht melden, und die Pruefung misst hier nichts.
    kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null
    echo "UEBERSPRUNGEN ETXTBSY: diese Umgebung sperrt laufende Dateien nicht (#1911)"
    echo "  Ein Schreibzugriff auf die laufende Datei ist durchgegangen — der Fall"
    echo "  ist hier nicht messbar. Auf einem gewoehnlichen Linux-Dateisystem laeuft"
    echo "  die Pruefung; in Containern mit overlayfs greift die Sperre oft nicht."
  else
    "$LYXC" --std-path=. "$TMP/q.lyx" -o "$TMP/laeuft" > "$TMP/c.out" 2> "$TMP/c.err"
    rc=$?
    kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null
    if [ "$rc" -ne 0 ]; then ok "laufende Zieldatei: Status $rc"; else bad "laufende Zieldatei, endet aber mit 0"; fi
    if grep -q "ETXTBSY" "$TMP/c.err"; then
      ok "Meldung nennt ETXTBSY als Anlass"
    else
      bad "Meldung nennt ETXTBSY nicht: $(head -1 "$TMP/c.err")"
    fi
  fi
else
  bad "Hilfsprogramm fuer den ETXTBSY-Fall uebersetzt nicht"
fi

# 4) Kein Writer darf am gemeinsamen Weg vorbei schreiben — sonst kommt der
#    stille Fehlschlag beim naechsten Backend zurueck. Gesucht wird das
#    Oeffnen der AUSGABE, nicht jedes open().
offen=$(grep -l "open(path, 577" src/codegen_x86.lyx src/backend/*.lyx 2>/dev/null | tr '\n' ' ')
if [ -z "$offen" ]; then
  ok "kein Backend oeffnet die Ausgabedatei selbst"
else
  bad "oeffnen die Ausgabedatei selbst statt ueber EmitWriteFile: $offen"
fi

echo "----"
echo "$P PASS, $F FAIL"
[ "$F" -eq 0 ]
