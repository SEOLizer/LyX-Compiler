#!/usr/bin/env bash
# tests/import_cycle_message_test.sh — #1134: Meldung bei zyklischem Import.
#
# Der Zyklus wurde erkannt, die Meldung gab aber statt der Unit-Namen den
# gesamten restlichen DATEIINHALT aus:
#
#   sema error: zyklischer Import erkannt: za;
#   pub fn B(): int64 { return 2; }
#    → zb;
#   pub fn A(): int64 { return 1; }
#    → …
#
# Ursache: die Namen im Capability-Graphen zeigen in den Quelltext und sind
# NICHT nullterminiert. `PrintStr` lief daher bis zum naechsten NUL, also bis
# zum Dateiende. Bei einer Unit mit einigen hundert Zeilen war die Meldung
# unbrauchbar; dass Name und Inhalt "gegeneinander verschoben" wirkten, kam
# daher, dass die Zeiger in verschiedene Quelltexte zeigen.
#
# Behoben: Namen mit ihrer LAENGE schreiben, und statt zweier Namen plus "…"
# die ganze KETTE melden (`za → zb → za`) — dafuer fuehrt der DFS jetzt den
# Weg der grauen Knoten mit.
#
# Geprueft wird die MELDUNG: eine Zeile, geschlossene Kette, kein Quelltext.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# --- Zwei Units, gegenseitiger Import ------------------------------------
mkdir -p "$TMP/a"
cat > "$TMP/a/za.lyx" <<'EOF'
unit za;
import zb;
pub fn A(): int64 { return 1; }
EOF
cat > "$TMP/a/zb.lyx" <<'EOF'
unit zb;
import za;
pub fn B(): int64 { return 2; }
EOF
cat > "$TMP/a/main.lyx" <<'EOF'
import src.std.io;
import za;
fn main(): int64 { PrintLn(A()); return 0; }
EOF
msg="$(cd "$TMP/a" && "$LYXC" --std-path="$ROOT" main.lyx -o "$TMP/a/m" 2>&1)"
zeile="$(printf '%s\n' "$msg" | grep -i "zyklischer Import" || true)"

if [ -n "$zeile" ]; then ok "Zyklus wird gemeldet"; else no "Zyklus wird gemeldet" "keine Meldung"; fi

# Der Quelltext darf nicht in der Meldung stehen — daran krankte sie.
case "$msg" in
  *"pub fn A()"*|*"pub fn B()"*) no "kein Quelltext in der Meldung" "Dateiinhalt erscheint" ;;
  *) ok "kein Quelltext in der Meldung" ;;
esac

# Jedes Kettenglied ist ein reiner Unit-Name. Der alte Zustand haengte an den
# Namen den Dateirest, das erste Glied hiess also z.B. "za;" — genau daran
# scheitert diese Pruefung, waehrend eine blosse "enthaelt za"-Pruefung gruen
# geblieben waere.
kette_roh="${zeile#*erkannt: }"
schlecht=""
printf '%s' "$kette_roh" | awk -F' → ' '{for (i=1;i<=NF;i++) print $i}' > "$TMP/glieder.txt"
while IFS= read -r g; do
  case "$g" in
    *[!a-zA-Z0-9_.]*) schlecht="$schlecht [$g]" ;;
    "") schlecht="$schlecht [leer]" ;;
  esac
done < "$TMP/glieder.txt"
if [ -z "$schlecht" ]; then ok "jedes Kettenglied ist ein reiner Unit-Name"
else no "jedes Kettenglied ist ein reiner Unit-Name" "$schlecht"; fi

# Die Kette nennt beide Units und ist geschlossen (erster Name == letzter).
kette="${zeile#*erkannt: }"
case "$kette" in
  *za*) ok "Kette nennt za" ;;
  *) no "Kette nennt za" "$kette" ;;
esac
case "$kette" in
  *zb*) ok "Kette nennt zb" ;;
  *) no "Kette nennt zb" "$kette" ;;
esac
erster="$(printf '%s' "$kette" | awk -F' → ' '{print $1}')"
letzter="$(printf '%s' "$kette" | awk -F' → ' '{print $NF}')"
if [ -n "$erster" ] && [ "$erster" = "$letzter" ]; then ok "Kette ist geschlossen ($erster … $letzter)"
else no "Kette ist geschlossen" "'$erster' vs '$letzter'"; fi

# Das alte "→ …" (Auslassung statt Kette) darf nicht mehr auftauchen.
case "$zeile" in
  *"→ …"*) no "keine Auslassung mehr" "'→ …' steht noch in der Meldung" ;;
  *) ok "keine Auslassung mehr" ;;
esac

# --- Drei Units: die Kette muss alle drei nennen -------------------------
mkdir -p "$TMP/b"
cat > "$TMP/b/ca.lyx" <<'EOF'
unit ca;
import cb;
pub fn A(): int64 { return 1; }
EOF
cat > "$TMP/b/cb.lyx" <<'EOF'
unit cb;
import cc;
pub fn B(): int64 { return 2; }
EOF
cat > "$TMP/b/cc.lyx" <<'EOF'
unit cc;
import ca;
pub fn C(): int64 { return 3; }
EOF
cat > "$TMP/b/main.lyx" <<'EOF'
import src.std.io;
import ca;
fn main(): int64 { PrintLn(A()); return 0; }
EOF
msg3="$(cd "$TMP/b" && "$LYXC" --std-path="$ROOT" main.lyx -o "$TMP/b/m" 2>&1)"
zeile3="$(printf '%s\n' "$msg3" | grep -i "zyklischer Import" || true)"
fehlt=""
for u in ca cb cc; do
  case "$zeile3" in *"$u"*) ;; *) fehlt="$fehlt $u" ;; esac
done
if [ -z "$fehlt" ]; then ok "Dreier-Zyklus nennt alle drei Units"
else no "Dreier-Zyklus nennt alle drei Units" "fehlt:$fehlt ($zeile3)"; fi

glieder="$(printf '%s' "${zeile3#*erkannt: }" | awk -F' → ' '{print NF}')"
if [ "$glieder" = "4" ]; then ok "Dreier-Zyklus hat vier Glieder (geschlossen)"
else no "Dreier-Zyklus hat vier Glieder" "$glieder Glieder: ${zeile3#*erkannt: }"; fi

# --- Unit mit vielen Zeilen: die Meldung bleibt kurz ---------------------
mkdir -p "$TMP/c"
cat > "$TMP/c/gross.lyx" <<'EOF'
unit gross;
import zb2;
pub fn G(): int64 { return 9; }
EOF
cat > "$TMP/c/zb2.lyx" <<'EOF'
unit zb2;
import gross;
pub fn F1(): int64 { return 1; }
pub fn F2(): int64 { return 2; }
pub fn F3(): int64 { return 3; }
pub fn F4(): int64 { return 4; }
pub fn F5(): int64 { return 5; }
EOF
cat > "$TMP/c/main.lyx" <<'EOF'
import src.std.io;
import gross;
fn main(): int64 { PrintLn(G()); return 0; }
EOF
msgG="$(cd "$TMP/c" && "$LYXC" --std-path="$ROOT" main.lyx -o "$TMP/c/m" 2>&1)"
case "$msgG" in
  *"pub fn F5()"*) no "grosse Unit blaeht die Meldung nicht auf" "Dateiinhalt erscheint" ;;
  *) ok "grosse Unit blaeht die Meldung nicht auf" ;;
esac
zeileG="$(printf '%s\n' "$msgG" | grep -i "zyklischer Import" || true)"
lg=${#zeileG}
if [ "$lg" -gt 0 ] && [ "$lg" -lt 120 ]; then ok "Meldung bleibt kurz ($lg Zeichen)"
else no "Meldung bleibt kurz" "$lg Zeichen"; fi

# --- Gegenprobe: ohne Zyklus wird nichts gemeldet ------------------------
mkdir -p "$TMP/d"
cat > "$TMP/d/ok1.lyx" <<'EOF'
unit ok1;
pub fn O(): int64 { return 5; }
EOF
cat > "$TMP/d/main.lyx" <<'EOF'
import src.std.io;
import ok1;
fn main(): int64 { PrintLn(O()); return 0; }
EOF
msgOK="$(cd "$TMP/d" && "$LYXC" --std-path="$ROOT" main.lyx -o "$TMP/d/m" 2>&1)"
case "$msgOK" in
  *"zyklischer Import"*) no "ohne Zyklus keine Meldung" "meldet trotzdem" ;;
  *) ok "ohne Zyklus keine Meldung" ;;
esac
if [ -f "$TMP/d/m" ] && [ "$("$TMP/d/m" 2>&1)" = "5" ]; then ok "Programm ohne Zyklus laeuft"
else no "Programm ohne Zyklus laeuft" "kein Ergebnis 5"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
