#!/usr/bin/env bash
# tests/profile_schalter_test.sh — #1370: --profile misst jede Funktion.
#
# Der Schalter setzte bis 1.1.6D nur ein Feld, das niemand las; seit #1098
# wurde er wenigstens laut abgewiesen. Die Maschinerie gab es laengst als
# Builtins (profile_enter/-leave/-report, WP-BC-40) — sie musste nur an jede
# Funktion statt an von Hand gestreute Aufrufe.
#
# Zwei Dinge muessen gleichzeitig stimmen, und beide werden geprueft:
# der Bericht muss ERSCHEINEN, und das Programm muss WEITER RECHNEN. Eine
# Messung, die den Rueckgabewert frisst, waere schlimmer als keine — die
# Austrittsmessung benutzt rax, in dem der Rueckgabewert steht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

cat > "$TMP/p.lyx" <<'EOF'
type Zaehler = class {
  wert: int64;
  fn Rauf(n: int64): int64 { self.wert := self.wert + n; return self.wert; }
};
fn fib(n: int64): int64 {
  if (n < 2) { return n; }
  return fib(n - 1) + fib(n - 2);
}
fn main(): int64 {
  var z: Zaehler := new Zaehler();
  z.Rauf(5);
  z.Rauf(6);
  if (fib(10) != 55) { return 1; }
  return z.wert;
}
EOF

# --- ohne Schalter: nichts aendert sich ------------------------------------
if "$LYXC" "$TMP/p.lyx" -o "$TMP/ohne" >"$TMP/ohne.log" 2>&1; then
  AUS=$("$TMP/ohne" 2>&1); RC=$?
  if [ "$RC" = "11" ]; then ok "ohne --profile: rechnet (= 11)"
  else no "ohne --profile: rechnet" "rc=$RC"; fi
  if echo "$AUS" | grep -q "PROFILE"; then
    no "ohne --profile: kein Bericht" "es kommt einer, obwohl nicht angefordert"
  else
    ok "ohne --profile: kein Bericht"
  fi
else
  no "ohne --profile uebersetzt" "$(grep -m1 -i error "$TMP/ohne.log")"
fi

# --- mit Schalter ----------------------------------------------------------
if ! "$LYXC" --profile "$TMP/p.lyx" -o "$TMP/mit" >"$TMP/mit.log" 2>&1; then
  no "--profile uebersetzt" "$(grep -m1 -iE 'error|nicht umgesetzt' "$TMP/mit.log")"
  echo "----"; echo "$PASS PASS, $FAIL FAIL"; exit 1
fi
ok "--profile uebersetzt"

AUS=$("$TMP/mit" 2>&1); RC=$?

# Der Rueckgabewert muss die Messung ueberleben — sie benutzt rax.
if [ "$RC" = "11" ]; then ok "mit --profile: Rueckgabewert bleibt (= 11)"
else no "mit --profile: Rueckgabewert bleibt" "rc=$RC statt 11 — frisst die Austrittsmessung rax?"; fi

# Freie Funktion, Methode und main muessen einzeln auftauchen.
for name in fib Zaehler_Rauf main; do
  if echo "$AUS" | grep -q "\[PROFILE\] $name:"; then ok "Bericht nennt $name"
  else no "Bericht nennt $name" "$(echo "$AUS" | grep PROFILE | tr '\n' ' ')"; fi
done

# Die Zahlen muessen stimmen, nicht nur dastehen: fib(10) ruft sich 177 mal
# auf (naive Rekursion), Rauf zweimal, main einmal. Ein Bericht mit falschen
# Zaehlern waere schlimmer als keiner — er saehe richtig aus.
pruefe_zahl() {   # Name, erwartete Aufrufe
  local n
  n=$(echo "$AUS" | grep "\[PROFILE\] $1:" | sed 's/.*\] [^:]*: \([0-9]*\) calls.*/\1/')
  if [ "$n" = "$2" ]; then ok "$1 wird $2 mal gezaehlt"
  else no "$1 wird $2 mal gezaehlt" "gezaehlt: ${n:-nichts}"; fi
}
pruefe_zahl fib 177
pruefe_zahl Zaehler_Rauf 2
pruefe_zahl main 1

# Zyklen muessen groesser als null sein — sonst misst der Zaehler nichts.
if echo "$AUS" | grep -q "\[PROFILE\] fib: 177 calls, 0 cycles"; then
  no "die Zyklen werden gemessen" "0 Zyklen fuer 177 Aufrufe"
else
  ok "die Zyklen werden gemessen"
fi

# --- der Schalter wird nicht mehr abgewiesen -------------------------------
if grep -q "NICHT UMGESETZT" <<< "$("$LYXC" --help 2>&1 | grep -- --profile)"; then
  no "--help nennt --profile als umgesetzt" "steht noch als nicht umgesetzt"
else
  ok "--help nennt --profile als umgesetzt"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
