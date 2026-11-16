#!/bin/bash
# #1724 -- die IR-Strecke muss Importe dort finden, wo der Hauptaufloeser sie
# findet.
#
# `_irLeseImport` kannte nur drei Stufen: Arbeitsverzeichnis, -I und
# --std-path. Der Hauptaufloeser (sema._leseDatei) hat seit 1.0.18D eine
# vierte, den Installationspfad /usr/include/lyx/units. Ohne sie meldete die
# IR-Strecke "Import nicht lesbar, seine Funktionen fehlen: std.fs" und zwei
# Zeilen spaeter "unbekannter Builtin/Funktion: FileExists" -- eine Meldung,
# die auf einen fehlenden Builtin zeigt, obwohl bloss die Unit nicht gefunden
# wurde. Zwei Stellen beantworteten dieselbe Frage verschieden.
#
# Der Test laeuft bewusst aus einem FREMDEN Arbeitsverzeichnis und OHNE
# --std-path -- genau die Bedingung, unter der es brach. Aus dem Repo heraus
# gemessen faellt der Fehler nicht auf, weil dort schon die erste Stufe
# greift.
#
# GEPRUEFT WIRD DIE AUFLOESUNG, NICHT DIE UEBERSETZUNG (#1943). Bis 1.1.19D
# verlangte dieser Test, dass das Programm durchlaeuft -- und uebersetzte damit
# die INSTALLIERTE Unit unter /usr/include/lyx/units. Die gehoert nicht zum
# Repo und ist per Definition aelter als das, was hier bearbeitet wird: jede
# Verschaerfung im Compiler machte den Test rot, bis jemand neu installiert.
# Gemessen wurde damit die Ausstattung des Rechners, nicht der Compiler.
#
# Die Frage des Tests ist aber eine andere: FINDET die IR-Strecke den Import
# ueber die vierte Stufe? Das beantwortet `--trace-imports` mit der
# Aufloesungszeile, unabhaengig davon, ob die dort liegende Fassung unter den
# heutigen Regeln noch uebersetzt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1${2:+ -- $2}"; F=$((F+1)); }

# #2518: Dieser Test SKIPte, wenn kein Paket installiert war -- auf der CI also
# immer. Damit war die vierte Aufloesestufe dort DAUERHAFT ungepruefft, und ein
# Defekt darin blieb gruen: genau so ist die Luecke aus #2484 (cg_lyuPfadZu
# kannte den Installationspfad nicht) der CI entgangen und nur lokal
# aufgefallen. Ein SKIP, der eine ganze Stufe verdeckt, meldet nicht
# "ungepruefft", sondern "gruen" -- dieselbe Art stiller Default, den die
# Projektregeln sonst verbieten.
#
# Gemessen wird deshalb gegen den PAKETBAUM IM REPO. Der liegt in jedem
# Checkout (lyx-compiler/usr/include/lyx/units, 503 .lyu) und braucht weder
# eine Installation noch Rechte; `--units-install-dir` zeigt den Compiler
# darauf. Eine echte Installation wird weiterhin benutzt, wenn es sie gibt --
# dann misst der Test beides.
INS_DIR=""
# Mit IR_IMPORTPFAD_ERZWINGE_REPO=1 wird der Repo-Baum genommen, auch wenn eine
# Installation da ist. Nur so ist der CI-Zweig auf einem Rechner MIT
# installiertem Paket pruefbar -- sonst waere er hier dauerhaft ungemessen, und
# das ist genau der Fehler, den dieser Test behebt.
if [ -n "${IR_IMPORTPFAD_ERZWINGE_REPO:-}" ] && [ -d "$ROOT/lyx-compiler/usr/include/lyx/units" ]; then
  INS_DIR="$ROOT/lyx-compiler/usr/include/lyx/units"
  INS_SCHALTER="--units-install-dir=$INS_DIR"
elif [ -d /usr/include/lyx/units/std ] || [ -n "$(find /usr/include/lyx/units -maxdepth 2 -type d -name std 2>/dev/null | head -1)" ]; then
  INS_DIR="/usr/include/lyx/units"          # echte Installation
  INS_SCHALTER=""
elif [ -d "$ROOT/lyx-compiler/usr/include/lyx/units" ]; then
  INS_DIR="$ROOT/lyx-compiler/usr/include/lyx/units"
  INS_SCHALTER="--units-install-dir=$INS_DIR"
else
  echo "FAIL: weder eine Installation noch der Paketbaum im Repo vorhanden --"
  echo "      die vierte Stufe ist damit WIRKLICH nicht pruefbar, und das ist"
  echo "      ein Befund, kein Grund zum Ueberspringen (#2518)."
  echo "Ergebnis: 0 PASS, 1 FAIL"
  exit 1
fi
echo "    vierte Stufe gemessen gegen: $INS_DIR"

cat > "$TMP/t.lyx" <<'EOF'
import std.fs;
fn main(): int64 { return FileExists("/tmp") as int64; }
EOF

# Aus dem TMP-Verzeichnis heraus, ohne --std-path: nur der Installationspfad
# kann std.fs noch liefern.
cd "$TMP" || exit 1

# #2484: Das Paket liefert die Units ARCHITEKTURGEBUNDEN aus (units/<arch>/std,
# seit #2499). Die Frage nach der vierten Stufe zerfaellt damit in zwei:
#
#   a) Wird der Import ueberhaupt AUFGELOEST? Das entscheidet sema und haengt
#      nicht am Ziel -- deshalb weiter mit --target=lyxos gemessen.
#   b) Kann die IR-Strecke die gefundene Datei auch BENUTZEN? Das kann sie nur
#      fuer das Ziel, dessen Baum installiert ist. Bis 1.2.39B verlangte diese
#      Pruefung Benutzbarkeit unter --target=lyxos, obwohl das Paket keinen
#      lyxos-Baum enthaelt: sie konnte nicht gruen werden, und die Ursache war
#      nicht der Compiler, sondern die Prämisse der Pruefung.
log="$TMP/l"
# #2518/#2536: gemessen mit dem STANDARDZIEL, nicht mit --target=lyxos. Die
# alte Fassung begruendete lyxos damit, dass die Aufloesung "nicht am Ziel
# haengt". Das stimmte, solange alle Baeume unter units/x86_64 lagen; seit
# #2536 hat lyxos eine EIGENE Kennung und damit ein eigenes Verzeichnis
# (units/lyxos). Ein Baum mit nur x86_64 -- und das ist der Paketbaum -- kann
# einen lyxos-Import also nicht bedienen. Die vierte STUFE wird dadurch nicht
# schwaecher geprueft: sie ist genau dann erreicht, wenn weder
# Arbeitsverzeichnis noch -I noch --std-path etwas liefern.
timeout 300 "$LYXC" $INS_SCHALTER --trace-imports "$TMP/t.lyx" -o "$TMP/t.out" >"$log" 2>&1

# 1. Der Import wird ueberhaupt aufgeloest -- und zwar ueber den
#    INSTALLATIONSPFAD, denn die drei Stufen davor koennen hier nicht greifen.
if grep -q "^\[import\] std\.fs -> $INS_DIR/" "$log"; then
  ok "std.fs wird ohne --std-path ueber den Installationspfad gefunden"
else
  bad "Import ohne --std-path" "$(grep -E '^\[import\] std\.fs' "$log" | head -1)"
fi

# 2. Fuer das Ziel, dessen Baum installiert ist, darf die Meldung aus #1724
#    nicht kommen. Sie zeigte auf einen fehlenden Builtin, obwohl bloss die
#    Unit nicht gefunden wurde. Gemessen wird ohne --target, also fuer den
#    Host -- genau die Architektur, die das Paket hier abgelegt hat.
#
#    Genau DAS war bis 1.2.39B rot, und zwar an einer vierten Stelle:
#    `cg_lyuPfadZu` zaehlte nur -I und --std-path auf, nicht die Installation.
hlog="$TMP/lh"
timeout 300 "$LYXC" --trace-imports "$TMP/t.lyx" -o "$TMP/t.host" >"$hlog" 2>&1
if grep -q 'Import nicht lesbar' "$hlog"; then
  bad "Host-Ziel" "meldet weiterhin 'Import nicht lesbar'"
else
  ok "fuer das installierte Ziel keine Meldung 'Import nicht lesbar'"
fi

# 3. Die WIRKUNG, nicht bloss die Abwesenheit einer Meldung (#1943 verlangte
#    zu Recht, die installierte Unit nicht zu uebersetzen -- aber ein Paket,
#    das seine eigenen Units nicht benutzbar macht, ist genau der Defekt aus
#    #2484). Gemessen wird der RUECKGABEWERT: FileExists("/tmp") ist wahr,
#    also 1. Ein Erzeugnis, das blosses Vorhandensein prueft, waere blind
#    gegen eine Unit, die 0 zurueckgibt.
if [ -x "$TMP/t.host" ]; then
  "$TMP/t.host"; rc=$?
  if [ "$rc" -eq 1 ]; then
    ok "das Erzeugnis aus der installierten .lyu liefert FileExists(/tmp) = 1"
  else
    bad "Wirkung" "Rueckgabe $rc, erwartet 1"
  fi
else
  bad "Wirkung" "kein Erzeugnis entstanden"
fi

# 4. Gegenprobe, zweiseitig: fuer ein Ziel OHNE Baum darf KEIN Erzeugnis
#    entstehen. Ohne diese Haelfte waere Pruefung 2 auch von einem Compiler
#    erfuellt, der jeden Import irgendwie bedient.
#
#    Eigener Lauf, weil Pruefung 1-3 jetzt das Standardziel nehmen. Geurteilt
#    wird an der WIRKUNG (kein Erzeugnis, rc != 0), nicht am Wortlaut: die alte
#    Fassung grepte 'Import nicht lesbar' und waere rot geworden, sobald die
#    Meldung besser wird -- und sie trifft je nach Baum auch gar nicht zu
#    (ein Baum ohne lyxos-Zweig scheitert schon in sema mit "Modul nicht
#    gefunden", was genauso laut ist).
log2="$TMP/l2"
timeout 300 "$LYXC" --target=lyxos $INS_SCHALTER "$TMP/t.lyx" -o "$TMP/t.lyxos" >"$log2" 2>&1
rc2=$?
if [ ! -s "$TMP/t.lyxos" ] && [ "$rc2" -ne 0 ]; then
  ok "fuer ein Ziel ohne passenden Baum (lyxos) entsteht kein Erzeugnis (rc=$rc2)"
else
  bad "Gegenprobe" "lyxos lieferte ein Erzeugnis (rc=$rc2), obwohl kein lyxos-Baum da ist"
fi

echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
