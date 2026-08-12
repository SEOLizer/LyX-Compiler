#!/usr/bin/env bash
# tests/backend_opcodes_test.sh — #1339, #1363.
#
# #1339: Die Opcode-Dispatcher der IR-Backends sind flache Listen aus
# `if op == X { … }` — ohne else, ohne Default. Ein Opcode, den keine Zeile
# trifft, erzeugte GAR NICHTS und verschwand lautlos. Betroffen war unter
# anderem IRO_PANIC: ein `panic("…")` war auf arm64, riscv, xtensa und arm-cm4
# ein No-op, das Programm lief nach der erkannten Verletzung weiter.
#
# Jetzt nennt jedes Backend die Opcodes, die es behandelt, und weist alles
# andere beim Uebersetzen laut ab. Die Liste kann veralten — aber in die
# ungefaehrliche Richtung: ein neuer, nicht eingetragener Opcode laesst den
# Lauf scheitern, statt still zu verschwinden.
#
# #1363: `VerifyIntegrity()` war dokumentiert und im IR vorhanden
# (IRO_VERIFY_INTEGRITY), im Frontend aber nicht angebunden — jeder Aufruf
# endete in `undefined function`.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ===========================================================================
# #1339 — panic verschwindet nicht mehr
# ===========================================================================

printf 'fn main(): int64 { panic("kaputt"); return 0; }\n' > "$TMP/panic.lyx"

# arm64 kann panic jetzt: Abbruch per exit(1), wie IRO_THROW seit #1281.
rm -f "$TMP/p_arm64"
if "$LYXC" --std-path="$ROOT" "$TMP/panic.lyx" --target=arm64 -o "$TMP/p_arm64" >/dev/null 2>&1; then
  ok "panic uebersetzt fuer arm64"
else
  no "panic uebersetzt fuer arm64" "abgewiesen"
fi

# Der Beweis, dass der Abbruch WIRKLICH im Code steht: die Exit-Sequenz
# (mov x8,#93; svc #0) muss auftauchen. Ein Test auf "uebersetzt" waere auch
# gruen gewesen, als panic ein No-op war.
if [ -f "$TMP/p_arm64" ] && od -An -tx1 "$TMP/p_arm64" | tr -d ' \n' | grep -q '010000d4'; then
  ok "arm64-Binary enthaelt die SVC-Abbruchsequenz"
else
  no "arm64-Binary enthaelt die SVC-Abbruchsequenz" "kein SVC #0 im Code"
fi

# Auf den Zielen ohne Zeichenketten-Opcode faellt panic beim Uebersetzen auf,
# statt spurlos zu verschwinden. Die Meldung muss den Opcode nennen — sonst
# steht der Nutzer vor demselben Raetsel wie vorher.
for t in riscv arm-cm4 esp32; do
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/panic.lyx" --target=$t -o "$TMP/p_$t" 2>&1)"
  case "$msg" in
    *"kennt Opcode"*"#1339"*) ok "$t meldet den unbehandelten Opcode" ;;
    *) no "$t meldet den unbehandelten Opcode" "$(echo "$msg" | head -1)" ;;
  esac
done

# Gegenprobe, und die ist die wichtigere: was diese Backends koennen, muessen
# sie weiterhin koennen. Eine Sperre, die alles abweist, waere sonst ebenso
# gruen wie eine, die richtig unterscheidet.
printf 'fn main(): int64 { var a: int64 := 2; var b: int64 := a * 3 + 1; if b > 5 { return b; } return 0; }\n' > "$TMP/rechnen.lyx"
for t in riscv arm-cm4 esp32 arm64; do
  rm -f "$TMP/r_$t"
  if "$LYXC" --std-path="$ROOT" "$TMP/rechnen.lyx" --target=$t -o "$TMP/r_$t" >/dev/null 2>&1; then
    ok "$t uebersetzt Rechnen und Verzweigung weiterhin"
  else
    no "$t uebersetzt Rechnen und Verzweigung weiterhin" "$("$LYXC" --std-path="$ROOT" "$TMP/rechnen.lyx" --target=$t -o "$TMP/r_$t" 2>&1 | head -1)"
  fi
done

# Die Liste im Backend muss zum Dispatcher passen. Geprueft wird das an der
# Quelle: jeder `op == IRO_*`-Vergleich im Dispatcher muss in der Liste stehen.
# Driftet sie, faellt es hier auf und nicht beim Anwender.
for b in "src/backend/riscv_linux.lyx:rv" "src/backend/xtensa.lyx:xt" \
         "src/backend/arm_cm_backend.lyx:cm" "src/backend/arm64/emit_arm64.lyx:a64"; do
  datei="${b%%:*}"; praefix="${b##*:}"
  fehlend="$(python3 - "$ROOT/$datei" "$praefix" <<'PY'
import re,sys
s=open(sys.argv[1],encoding='utf-8').read(); pre=sys.argv[2]
i=s.index("fn %s_opBehandelt" % pre); j=s.index("return 0;", i)
liste=set(re.findall(r'op == ([A-Za-z0-9_]+)', s[i:j]))
k=s.index("fn emitInstr("); m=s.index("\n  fn ", k+10)
disp=set(re.findall(r'op == ([A-Za-z0-9_]+)', s[k:m]))
print(" ".join(sorted(disp - liste)))
PY
)"
  if [ -z "$fehlend" ]; then ok "$(basename "$datei"): Liste deckt den Dispatcher"
  else no "$(basename "$datei"): Liste deckt den Dispatcher" "nicht eingetragen: $fehlend"; fi
done

# ===========================================================================
# #1363 — VerifyIntegrity ist angebunden
# ===========================================================================

lauf() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/v.lyx"; rm -f "$TMP/v"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/v.lyx" -o "$TMP/v" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/v" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

lauf "VerifyIntegrity ist aufrufbar und meldet Uebereinstimmung" 'import std.io;
@redundant var thrust: int64;
@redundant var hoehe: int64;
fn main(): int64 {
  thrust := 42;
  hoehe := 7;
  PrintLn(IntToStr(VerifyIntegrity()));
  return 0;
}' "0"

# Der Rueckschreibvorgang (scrubbing) darf den Wert nicht antasten.
lauf "die Werte ueberstehen die Pruefung unveraendert" 'import std.io;
@redundant var thrust: int64;
fn main(): int64 {
  thrust := 42;
  var x: int64 := VerifyIntegrity();
  PrintStr(IntToStr(thrust)); PrintStr(" "); PrintLn(IntToStr(x));
  return 0;
}' "42 0"

# Ohne @redundant-Variablen gibt es nichts zu pruefen — und das Ergebnis ist 0,
# nicht etwa ein Fehler.
lauf "ohne redundante Variablen liefert die Pruefung 0" 'import std.io;
var normal: int64;
fn main(): int64 { normal := 5; PrintLn(IntToStr(VerifyIntegrity())); return 0; }' "0"

# Der Weg, nicht nur das Ergebnis: die Pruefung MUSS alle drei Kopien lesen und
# den Mehrheitswert bilden. Belegt wird das an den Bytes — `setne r8b`
# (41 0F 95 C0) und `cmove rcx, rdx` (48 0F 44 CA) stehen genau dafuer. Ein
# Groessenvergleich taugt hier nicht: die ELF-Datei ist seitenweise aufgefuellt,
# der Zuwachs verschwindet in der Auffuellung.
printf 'import std.io;\n@redundant var a: int64;\n@redundant var b: int64;\nfn main(): int64 { a := 1; b := 2; return 0; }\n' > "$TMP/ohne.lyx"
printf 'import std.io;\n@redundant var a: int64;\n@redundant var b: int64;\nfn main(): int64 { a := 1; b := 2; return VerifyIntegrity(); }\n' > "$TMP/mit.lyx"
"$LYXC" --std-path="$ROOT" "$TMP/ohne.lyx" -o "$TMP/ohne" >/dev/null 2>&1
"$LYXC" --std-path="$ROOT" "$TMP/mit.lyx"  -o "$TMP/mit"  >/dev/null 2>&1
if [ -f "$TMP/ohne" ] && [ -f "$TMP/mit" ]; then
  hexmit="$(od -An -tx1 "$TMP/mit"  | tr -d ' \n')"
  hexohne="$(od -An -tx1 "$TMP/ohne" | tr -d ' \n')"
  # Je Variable EIN `setne r8b` (A!=B), ein `setne r9b` (B!=C) und ein cmove.
  n_setne=$(printf '%s' "$hexmit" | grep -o '410f95c0' | wc -l)
  n_cmove=$(printf '%s' "$hexmit" | grep -o '480f44ca' | wc -l)
  if [ "$n_setne" -ge 2 ] && [ "$n_cmove" -ge 2 ]; then
    ok "der Aufruf erzeugt Pruefcode fuer beide Variablen ($n_setne setne, $n_cmove cmove)"
  else
    no "der Aufruf erzeugt Pruefcode fuer beide Variablen" "$n_setne setne, $n_cmove cmove — erwartet je >=2 (eine Variable ohne Pruefung?)"
  fi
  if printf '%s' "$hexohne" | grep -q '480f44ca'; then
    no "ohne den Aufruf steht kein Pruefcode im Binary" "cmove auch ohne VerifyIntegrity vorhanden"
  else
    ok "ohne den Aufruf steht kein Pruefcode im Binary"
  fi
else
  no "der Aufruf erzeugt Pruefcode fuer beide Variablen" "eine der Uebersetzungen scheiterte"
fi

# NICHT geprueft, und das gehoert gesagt: dass eine VERFAELSCHTE Kopie erkannt
# und repariert wird. Lyx kennt die Adressnahme nur fuer Locals (`@ident`), eine
# redundante GLOBALE laesst sich aus der Sprache heraus nicht gezielt
# beschaedigen — genau das ist ja der Zweck des Voters. Der Rueckschreibpfad ist
# damit nur durch Lesen des erzeugten Codes belegt, nicht durch einen Lauf.

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
