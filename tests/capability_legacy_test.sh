#!/usr/bin/env bash
# tests/capability_legacy_test.sh — #1340, Schritt 1: das Legacy-Gate.
#
# README.md:179 und capabilities.md:21 sagen zu: ohne `@capabilities` laeuft ein
# Programm ohne jede Einschraenkung. Zwei Stellen hielten sich nicht daran und
# behandelten "gar nicht annotiert" wie "@capabilities([])":
#
#   * das LCBS-Pruning (cap_shouldStrip) warf jede Unit weg, deren Bedarf sich
#     mit der leeren Wurzelmenge nicht schnitt,
#   * Regel 1 (ComputeNoGrant) meldete jede deklarierte Capability als im
#     Parent fehlend.
#
# Solange keine Unit in std/ deklariert, faellt das nicht auf — deshalb ist der
# Zustand heute stabil. Mit der ERSTEN Deklaration waere jedes Programm ohne
# Annotation betroffen, einschliesslich src/lyxc.lyx. Dieser Test haelt das
# Gate fest, BEVOR die 421 Units annotiert werden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/p/paket"
cat > "$TMP/p/paket/mituc.lyx" <<'EOF'
@capabilities([fs.read])
unit paket.mituc;
pub fn Wert(): int64 { return 33; }
EOF

baut_und_rechnet() {   # Name, Quelldatei, erwarteter Rueckgabewert
  if ! (cd "$TMP/p" && "$LYXC" -I . "$2" -o "$TMP/p/a.out") >"$TMP/a.log" 2>&1; then
    no "$1" "$(grep -m1 -iE 'sema error|parse error' "$TMP/a.log")"
    return
  fi
  "$TMP/p/a.out"; local rc=$?
  if [ "$rc" = "$3" ]; then ok "$1 (= $3)"; else no "$1" "rc=$rc statt $3"; fi
}

# --- Der Kern: unannotiert heisst unbeschraenkt -----------------------------
# Ohne das Gate wird paket.mituc weggeworfen und der Fehler erscheint als
# `undefined function 'Wert'` — an der Nutzung statt an der Ursache.
cat > "$TMP/p/ohne.lyx" <<'EOF'
import paket.mituc;
fn main(): int64 { return Wert(); }
EOF
baut_und_rechnet "unannotiertes Programm nutzt annotierte Unit" ohne.lyx 33

# --- Wo die Durchsetzung greift: am `grant` -------------------------------
#
# GEAENDERT mit dem #1340-Pilot: das Pruning greift nur noch, wenn der Import
# ein `grant` traegt. Vorher genuegte ein @capabilities am Programm, und jede
# Unit, die etwas deklarierte, verschwand daraus.
#
# Der Grund steht in tests/ffi_link_caps_test.sh: ein Programm darf sich eng
# annotieren (`@capabilities([system.exit])`) und trotzdem std.fs importieren —
# die Eindaemmung macht dann seccomp zur Laufzeit (SIGSYS). Wuerde schon der
# Bau scheitern, koennte man dieses Programm nicht mehr uebersetzen, sobald
# std.fs seinen Bedarf deklariert. Annotationen an stdlib-Units waeren damit
# keine Ergaenzung, sondern ein Bruch.
#
# Ohne grant: die Unit bleibt, das Programm rechnet.
cat > "$TMP/p/leer.lyx" <<'EOF'
@capabilities([])
import paket.mituc;
fn main(): int64 { return Wert(); }
EOF
(cd "$TMP/p" && "$LYXC" -I . leer.lyx -o "$TMP/p/leer.out" >/dev/null 2>&1)
if [ -x "$TMP/p/leer.out" ]; then
  "$TMP/p/leer.out" >/dev/null 2>&1
  if [ $? -eq 33 ]; then
    ok "@capabilities([]) ohne grant: Unit bleibt, Eindaemmung ist Sache der Laufzeit"
  else
    no "@capabilities([]) ohne grant" "Programm laeuft, liefert aber nicht 33"
  fi
else
  no "@capabilities([]) ohne grant" "uebersetzt nicht — das Pruning greift ohne grant"
fi

# Mit `grant []`: hier hat der Aufrufer eine Schranke gezogen, hier wird geprueft.
cat > "$TMP/p/grant.lyx" <<'EOF'
@capabilities([])
import paket.mituc grant [];
fn main(): int64 { return Wert(); }
EOF
AUS=$(cd "$TMP/p" && "$LYXC" -I . grant.lyx -o "$TMP/p/grant.out" 2>&1)
if [ -x "$TMP/p/grant.out" ] && "$TMP/p/grant.out" >/dev/null 2>&1; then
  no "grant [] zieht die Schranke" "die Unit kommt durch, obwohl nichts gewaehrt ist"
else
  ok "grant [] zieht die Schranke"
fi
# Und der Ausfall muss die URSACHE nennen, nicht nur die Folge.
if echo "$AUS" | grep -q "wegen fehlender Capabilities entfernt"; then
  ok "der Ausfall nennt das Pruning als Ursache"
else
  no "der Ausfall nennt das Pruning als Ursache" "nur '$(echo "$AUS" | grep -m1 -i 'sema error')'"
fi

# --- Die Meldung muss die fehlende Capability NENNEN ----------------------
#
# #1340: DetectBreakingChange vergleicht nur die Parameter von Capabilities,
# die in BEIDEN Mengen stehen — ob das grant den deklarierten Bedarf ueberhaupt
# abdeckt, prueft es nicht. Ein `grant []` ging damit durch, das Modul flog
# still aus dem Programm, und beim Aufrufer kam `undefined function` an der
# NUTZUNG an. Die Ursache stand zwei Ebenen tiefer.
#
# ComputeGrantGap schliesst die Luecke: die Meldung steht am grant und sagt,
# welche Capability fehlt.
AUS=$(cd "$TMP/p" && "$LYXC" -I . grant.lyx -o "$TMP/p/gap.out" 2>&1)
case "$AUS" in
  *"grant fuehrt nicht, was das Modul deklariert"*"fs.read"*)
    ok "die Meldung nennt die fehlende Capability" ;;
  *"undefined function"*)
    no "die Meldung nennt die fehlende Capability" \
       "meldet nur das fehlende Symbol — die Ursache steht woanders" ;;
  *)
    no "die Meldung nennt die fehlende Capability" "$(echo "$AUS" | grep -m1 -i 'sema error')" ;;
esac

# Und ein unvollstaendiges grant faellt genauso auf wie ein leeres.
cat > "$TMP/p/teil.lyx" <<'EOF'
@capabilities([fs.read, fs.write])
import paket.zwei grant [fs.read];
fn main(): int64 { return Zwei(); }
EOF
mkdir -p "$TMP/p/paket"
cat > "$TMP/p/paket/zwei.lyx" <<'EOF'
@capabilities([fs.read, fs.write])
unit paket.zwei;
pub fn Zwei(): int64 { return 7; }
EOF
AUS=$(cd "$TMP/p" && "$LYXC" -I . teil.lyx -o "$TMP/p/teil.out" 2>&1)
case "$AUS" in
  *"grant fuehrt nicht, was das Modul deklariert"*"fs.write"*)
    ok "unvollstaendiges grant nennt die fehlende Capability" ;;
  *) no "unvollstaendiges grant" "$(echo "$AUS" | grep -m1 -i 'sema error')" ;;
esac

# --- Mit passender Capability geht es --------------------------------------
cat > "$TMP/p/passend.lyx" <<'EOF'
@capabilities([fs.read])
import paket.mituc;
fn main(): int64 { return Wert(); }
EOF
baut_und_rechnet "annotiertes Programm mit passender Capability" passend.lyx 33

# --- Und der Bestand: lyxc selbst hat kein @capabilities --------------------
# Das ist der Fall, der bei der ersten std-Deklaration zuerst umfaellt.
if grep -q "^@capabilities" "$ROOT/src/lyxc.lyx"; then
  echo "SKIP src/lyxc.lyx traegt inzwischen @capabilities — der Fall unten ist gegenstandslos"
else
  ok "src/lyxc.lyx traegt weiterhin kein @capabilities (Legacy-Fall bleibt gedeckt)"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
