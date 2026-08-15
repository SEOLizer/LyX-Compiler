#!/usr/bin/env bash
# tests/cli_schalter_z6_test.sh — #1523, #1524, #1526, #1527.
#
# Vier Meldungen über Schalter, die Erfolg melden und etwas anderes tun als
# versprochen — der teuerste Fall ist #1523, wo das Ansehen der IR das
# ERGEBNIS kaputtmachte.
#
#   #1523 --ir-source-map/--provenance schickten die Übersetzung über die
#         IR-Strecke; das Programm lief danach nicht mehr (keine Ausgabe,
#         Exit 42) — bei rc=0 und ohne jede Meldung.
#   #1524 --mcdc-report zählte zusammengesetzte Bedingungen als eine: `a && b
#         && c` galt als eine Bedingung, gemeldet wurde immer "min 2".
#   #1526 --arch=xtensa erzeugte x86-64, --format=pe erzeugte ELF,
#         --android-api=99 wurde angenommen, --seccomp-trap blieb folgenlos,
#         --trace wurde nie gelesen.
#   #1527 --config endete mit rc=1, verschluckte einen Zeilenumbruch und hängte
#         die komplette Hilfe an.
#
# GEPRÜFT WIRD DIE WIRKUNG, nicht die Annahme: das erzeugte Programm wird
# ausgeführt (#1523), das Dateiformat mit `file` gelesen (#1526), die Zahl der
# Bedingungen verglichen (#1524), Zeilenzahl und Exitcode gemessen (#1527).
# Ein Test auf "rc == 0" wäre bei allen vier vor dem Fix grün gewesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/h.lyx" <<'EOF'
fn main(): int64 {
  PrintLn("hallo");
  return 0;
}
EOF

# ===========================================================================
# #1523 — Diagnose darf das Ergebnis nicht kaputtmachen
# ===========================================================================

# Für jeden der drei Schalter: die Übersetzung muss gelingen, die Diagnose
# erscheinen UND das Programm danach laufen. Vor dem Fix lief es nicht mehr.
for sw in --ir-source-map --provenance --dump-ir; do
  rm -f "$TMP/p"
  msg="$(timeout 180 "$LYXC" "$sw" --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    no "#1523: $sw uebersetzt" "rc=$rc"
    no "#1523: $sw Programm laeuft" "nicht uebersetzt"
    continue
  fi
  ok "#1523: $sw uebersetzt"
  got="$(timeout 20 "$TMP/p" 2>&1)"; prc=$?
  if [ "$got" = "hallo" ] && [ "$prc" -eq 0 ]; then ok "#1523: $sw Programm laeuft"
  else no "#1523: $sw Programm laeuft" "'$got' rc=$prc"; fi
done

# Die Diagnose selbst muss weiterhin etwas ausgeben — sonst wäre der Fix nur
# ein Abschalten des Schalters.
msg="$(timeout 180 "$LYXC" --provenance --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/p" 2>&1)"
if echo "$msg" | grep -q "PROVENANCE"; then ok "#1523: --provenance gibt weiter aus"
else no "#1523: --provenance gibt weiter aus" "keine Provenance-Ausgabe"; fi

msg="$(timeout 180 "$LYXC" --dump-ir --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/p" 2>&1)"
if echo "$msg" | grep -q "IR dump"; then ok "#1523: --dump-ir gibt weiter aus"
else no "#1523: --dump-ir gibt weiter aus" "kein IR-Dump"; fi

# Das erzeugte Programm muss dasselbe sein wie ohne den Schalter: die Diagnose
# schaut zu, sie baut nicht.
timeout 180 "$LYXC" --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/a" >/dev/null 2>&1
timeout 180 "$LYXC" --dump-ir --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/b" >/dev/null 2>&1
if [ -f "$TMP/a" ] && [ -f "$TMP/b" ] && cmp -s "$TMP/a" "$TMP/b"; then
  ok "#1523: Diagnose aendert das Programm nicht"
else
  no "#1523: Diagnose aendert das Programm nicht" "Dateien unterscheiden sich"
fi

# ===========================================================================
# #1524 — MC/DC zählt jede Bedingung
# ===========================================================================

cat > "$TMP/mc.lyx" <<'EOF'
fn Eins(a: int64): int64 { if (a > 0) { return 1; } return 0; }
fn Zwei(a: int64, b: int64): int64 { if (a > 0 && b > 0) { return 1; } return 0; }
fn Drei(a: int64, b: int64, c: int64): int64 { if (a > 0 && b > 0 && c > 0) { return 1; } return 0; }
fn Vier(a: int64, b: int64, c: int64, d: int64): int64 {
  if ((a > 0 || b > 0) && (c > 0 || d > 0)) { return 1; } return 0;
}
fn main(): int64 { return 0; }
EOF

mc="$(timeout 180 "$LYXC" --mcdc --mcdc-report --std-path="$ROOT" "$TMP/mc.lyx" -o "$TMP/m" 2>&1)"
pruef_mc() { # funktion, erwartete bedingungen, erwartete testfaelle
  zeile="$(echo "$mc" | grep -E "  $1: " | head -1)"
  if echo "$zeile" | grep -q "$2 conditions" && echo "$zeile" | grep -q "min $3 test"; then
    ok "#1524: $1 hat $2 Bedingungen, $3 Testfaelle"
  else
    no "#1524: $1 hat $2 Bedingungen, $3 Testfaelle" "${zeile:-keine Zeile}"
  fi
}
pruef_mc Eins 1 2
pruef_mc Zwei 2 3
pruef_mc Drei 3 4
pruef_mc Vier 4 5

if echo "$mc" | grep -q "Total minimum test cases required: 14"; then
  ok "#1524: Gesamtzahl 14"
else
  no "#1524: Gesamtzahl 14" "$(echo "$mc" | grep -i total | head -1)"
fi

# ===========================================================================
# #1526 — Schalter mit Wirkung oder mit Meldung
# ===========================================================================

# --arch=xtensa muss beim Xtensa-Backend landen. Das lehnt Zeichenketten
# derzeit ausdrücklich ab (#1339) — genau diese Meldung ist der Nachweis, dass
# der Schalter angekommen ist. Vorher entstand still ein x86-64-ELF.
rm -f "$TMP/x"
msg="$(timeout 180 "$LYXC" --arch=xtensa --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/x" 2>&1)"
if echo "$msg" | grep -qi "xtensa"; then ok "#1526: --arch=xtensa erreicht das Xtensa-Backend"
else no "#1526: --arch=xtensa erreicht das Xtensa-Backend" "$(echo "$msg"|tail -1)"; fi
if [ -f "$TMP/x" ] && file -b "$TMP/x" | grep -q "x86-64"; then
  no "#1526: --arch=xtensa erzeugt kein x86-64" "es entstand ein x86-64-ELF"
else
  ok "#1526: --arch=xtensa erzeugt kein x86-64"
fi

# Ein unbekannter Wert muss gemeldet werden, nicht auf die Vorgabe zurückfallen.
rm -f "$TMP/q"
msg="$(timeout 180 "$LYXC" --arch=quatsch --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/q" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$msg" | grep -qi "unbekannter Wert"; then
  ok "#1526: unbekannter --arch-Wert wird gemeldet"
else
  no "#1526: unbekannter --arch-Wert wird gemeldet" "rc=$rc"
fi

# --format=pe und --format=macho müssen das Format wirklich liefern.
rm -f "$TMP/pe"
timeout 180 "$LYXC" --format=pe --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/pe" >/dev/null 2>&1
if [ -f "$TMP/pe" ] && file -b "$TMP/pe" | grep -qi "PE32+"; then ok "#1526: --format=pe erzeugt PE"
else no "#1526: --format=pe erzeugt PE" "$(file -b "$TMP/pe" 2>/dev/null)"; fi

rm -f "$TMP/mo"
timeout 180 "$LYXC" --format=macho --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/mo" >/dev/null 2>&1
if [ -f "$TMP/mo" ] && file -b "$TMP/mo" | grep -qi "Mach-O"; then ok "#1526: --format=macho erzeugt Mach-O"
else no "#1526: --format=macho erzeugt Mach-O" "$(file -b "$TMP/mo" 2>/dev/null)"; fi

# Format und Ziel können sich widersprechen — dann muss es gesagt werden.
msg="$(timeout 180 "$LYXC" --target=linux-riscv64 --format=pe --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/k" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$msg" | grep -qi "widerspricht"; then
  ok "#1526: --format gegen --target wird gemeldet"
else
  no "#1526: --format gegen --target wird gemeldet" "rc=$rc"
fi

# ELF bleibt die Vorgabe und darf sich nicht bewegt haben.
rm -f "$TMP/e"
timeout 180 "$LYXC" --format=elf --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/e" >/dev/null 2>&1
if [ -f "$TMP/e" ] && file -b "$TMP/e" | grep -q "ELF 64-bit" && [ "$(timeout 20 "$TMP/e")" = "hallo" ]; then
  ok "#1526: --format=elf unveraendert"
else
  no "#1526: --format=elf unveraendert" "$(file -b "$TMP/e" 2>/dev/null)"
fi

# --android-api: gültige Stufe durch, erfundene gemeldet.
timeout 180 "$LYXC" --android-api=30 --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/a30" >/dev/null 2>&1
if [ -f "$TMP/a30" ]; then ok "#1526: --android-api=30 wird angenommen"
else no "#1526: --android-api=30 wird angenommen" "kein Ergebnis"; fi

msg="$(timeout 180 "$LYXC" --android-api=99 --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/a99" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$msg" | grep -qi "unbekannter Wert"; then
  ok "#1526: --android-api=99 wird gemeldet"
else
  no "#1526: --android-api=99 wird gemeldet" "rc=$rc"
fi

# --trace wird abgewiesen statt Erfolg zu melden.
msg="$(timeout 180 "$LYXC" --trace --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/t" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$msg" | grep -qi "nicht umgesetzt"; then
  ok "#1526: --trace wird abgewiesen"
else
  no "#1526: --trace wird abgewiesen" "rc=$rc"
fi

# --seccomp-trap: das Feld fehlte in CompilerConfig, Schreiben und Lesen liefen
# ins Leere. Geprüft wird das ERZEUGNIS (verschiedene Bytes) und die Aussage im
# Audit — die behauptete vorher KILL_PROCESS, obwohl TRAP gewollt war.
cat > "$TMP/sc.lyx" <<'EOF'
@capabilities([network.tcp.connect, system.time])
fn main(): int64 {
  PrintLn("x");
  return 0;
}
EOF
rm -f "$TMP/s1" "$TMP/s2"
a1="$(timeout 180 "$LYXC" --std-path="$ROOT" "$TMP/sc.lyx" -o "$TMP/s1" 2>&1)"
a2="$(timeout 180 "$LYXC" --seccomp-trap --std-path="$ROOT" "$TMP/sc.lyx" -o "$TMP/s2" 2>&1)"
if [ -f "$TMP/s1" ] && [ -f "$TMP/s2" ] && ! cmp -s "$TMP/s1" "$TMP/s2"; then
  ok "#1526: --seccomp-trap aendert den Filter"
else
  no "#1526: --seccomp-trap aendert den Filter" "Programme byte-identisch"
fi
if echo "$a1" | grep -q "SECCOMP_RET_KILL_PROCESS" && echo "$a2" | grep -q "SECCOMP_RET_TRAP"; then
  ok "#1526: Audit nennt die tatsaechliche Rueckgabeart"
else
  no "#1526: Audit nennt die tatsaechliche Rueckgabeart" "$(echo "$a2"|grep -i 'seccomp ('|head -1)"
fi

# --debug-symbols wirkt beim Programm; bei .lyu fehlt die Ablage (#1555) und
# das wird gesagt, statt eine byte-identische Datei zu schreiben.
rm -f "$TMP/d1" "$TMP/d2"
timeout 180 "$LYXC" --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/d1" >/dev/null 2>&1
timeout 180 "$LYXC" --debug-symbols --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/d2" >/dev/null 2>&1
if [ -f "$TMP/d1" ] && [ -f "$TMP/d2" ] && ! cmp -s "$TMP/d1" "$TMP/d2"; then
  ok "#1526: --debug-symbols wirkt auf das Programm"
else
  no "#1526: --debug-symbols wirkt auf das Programm" "byte-identisch"
fi

printf 'unit u;\npub fn F(): int64 { return 1; }\n' > "$TMP/u.lyx"
msg="$(timeout 180 "$LYXC" --compile-unit --debug-symbols --std-path="$ROOT" "$TMP/u.lyx" -o "$TMP/u.lyu" 2>&1)"
if echo "$msg" | grep -q "1555"; then ok "#1526: .lyu-Luecke wird benannt"
else no "#1526: .lyu-Luecke wird benannt" "keine Warnung"; fi

# ===========================================================================
# #1527 — --config
# ===========================================================================

cfg="$(timeout 60 "$LYXC" --config 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "#1527: --config endet mit 0"
else no "#1527: --config endet mit 0" "rc=$rc"; fi

zeilen="$(echo "$cfg" | wc -l)"
if [ "$zeilen" -le 6 ]; then ok "#1527: --config haengt keine Hilfe an ($zeilen Zeilen)"
else no "#1527: --config haengt keine Hilfe an" "$zeilen Zeilen"; fi

# Der verschluckte Zeilenumbruch: `Osafe` und die erste Hilfezeile verschmolzen
# zu "Osafelyxc ...". Die letzte Zeile muss auf Osafe enden.
if echo "$cfg" | grep -qE "Osafe$"; then ok "#1527: Zeilenumbruch nach Osafe"
else no "#1527: Zeilenumbruch nach Osafe" "$(echo "$cfg"|tail -1|cut -c1-50)"; fi

# Gegenprobe: die beiden Nachbarn waren immer richtig und müssen es bleiben.
v="$(timeout 60 "$LYXC" --version 2>&1)"; vrc=$?
b="$(timeout 60 "$LYXC" --build-info 2>&1)"; brc=$?
if [ "$vrc" -eq 0 ] && [ "$brc" -eq 0 ] && [ "$(echo "$b" | wc -l)" -le 6 ]; then
  ok "#1527: --version und --build-info unveraendert"
else
  no "#1527: --version und --build-info unveraendert" "vrc=$vrc brc=$brc"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
