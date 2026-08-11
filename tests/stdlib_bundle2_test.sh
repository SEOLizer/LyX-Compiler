#!/usr/bin/env bash
# tests/stdlib_bundle2_test.sh — #1260, #1263, #1267 und #1191.
#
# Vier Defekte der Standardbibliothek, alle desselben Zuschnitts wie im ersten
# Buendel: veroeffentlichte API, die uebersetzt, laeuft und etwas anderes tut
# als zugesagt.
#
# #1260 std.crypto.aes: VIER voneinander unabhaengige Fehler.
#       (a) Die Key Expansion drehte das Wort nach RECHTS statt nach links —
#           ab RK1 wich jeder Rundenschluessel ab.
#       (b) AES-256 las w[i-4] statt w[i-8]; Nk ist dort acht.
#       (c) InvShiftRows tauschte in Zeile 2 ueber Kreuz — (2,14)/(6,10) statt
#           (2,10)/(6,14). Zeile 2 wird um zwei gedreht und ist damit ihre
#           eigene Umkehrung. Dieser Fehler steckte NUR in der Entschluesselung:
#           nach (a) und (b) stimmte das Chiffrat gegen FIPS-197, der Roundtrip
#           aber immer noch nicht.
#       (d) Der Rundenschluessel wurde in ein 64-Zeichen-String-LITERAL
#           geschrieben — 176 bzw. 240 Byte gehoerten dorthin.
#       Geprueft wird gegen FIPS-197 (A.1 Schluesselplan, C.1 und C.3
#       Chiffrate), nicht gegen die eigene Ausgabe: Encrypt und Decrypt waren
#       vorher auch zueinander inkonsistent, ein reiner Roundtrip-Test haette
#       (a) und (b) daher gefunden, (c) aber ebenso wenig wie umgekehrt.
#
# #1263 std.crypto.pqc: Jede Parametertabelle fing einen unbekannten Level mit
#       den Werten der GROESSTEN Variante ab. `MLDSAKeyGen(seed, 45, …)` galt
#       als Erfolg (rc=0) und schrieb 2592/4864 statt 1312/2528 Byte.
#
# #1267 std.signals: Auf x86-64 gibt es keinen Restorer, den rt_sigaction von
#       sich aus benutzt — ohne sa_restorer UND SA_RESTORER springt der Kernel
#       nach dem Handler eine Null an. Der Kommentar im Quelltext behauptete
#       das Gegenteil ("Kernel nutzt vDSO").
#
# #1191 std.fs zog per `extern fn time … link "libc.so.6"` die libc herein und
#       machte JEDES Programm, das die Unit importiert, dynamisch gelinkt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 120 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# Hexausgabe, in jedem AES-Programm gebraucht.
HEX='fn hexOut(b: pchar, n: int64): void {
  var h: pchar := alloc(n * 2 + 2) as pchar;
  var i: int64 := 0;
  while (i < n) {
    var v: int64 := StrCharAt(b, i);
    var hi: int64 := (v >> 4) & 15;
    var lo: int64 := v & 15;
    if (hi < 10) { StrSetChar(h, i*2, 48 + hi); } else { StrSetChar(h, i*2, 87 + hi); }
    if (lo < 10) { StrSetChar(h, i*2+1, 48 + lo); } else { StrSetChar(h, i*2+1, 87 + lo); }
    i := i + 1;
  }
  StrSetChar(h, n*2, 0);
  PrintLn(h);
}'

# ===========================================================================
# #1260 — AES gegen FIPS-197
# ===========================================================================

# FIPS-197 Appendix A.1: Schluessel 000102…0f, RK1 = d6aa74fd…
# Der Schluesselplan wird getrennt geprueft, weil er die Wurzel von (a) und (b)
# ist — ein Test nur auf dem Chiffrat wuerde nicht sagen, WO es klemmt.
out "AES-128 Schluesselplan RK1 (FIPS-197 A.1)" "import std.io;
import std.crypto.aes;
$HEX
fn main(): int64 {
  var key: pchar := alloc(32) as pchar;
  var i: int64 := 0;
  while (i < 16) { StrSetChar(key, i, i); i := i + 1; }
  StrSetChar(key, 16, 0);
  var ek: pchar := alloc(256) as pchar;
  AES128KeyExpand(key, ek);
  var rk1: pchar := alloc(32) as pchar;
  i := 0; while (i < 16) { StrSetChar(rk1, i, StrCharAt(ek, 16 + i)); i := i + 1; }
  hexOut(rk1, 16);
  return 0;
}" "d6aa74fdd2af72fadaa678f1d6ab76fe"

# FIPS-197 C.1 / C.3. Der IV ist null, der erste CBC-Block entspricht damit ECB
# und ist direkt mit dem Vektor des Standards vergleichbar.
out "AES-128 und AES-256 Chiffrat (FIPS-197 C.1 / C.3)" "import std.io;
import std.crypto.aes;
$HEX
fn main(): int64 {
  var i: int64 := 0;
  var key: pchar := alloc(32) as pchar;
  while (i < 16) { StrSetChar(key, i, i); i := i + 1; }
  StrSetChar(key, 16, 0);
  var k2: pchar := alloc(48) as pchar;
  i := 0; while (i < 32) { StrSetChar(k2, i, i); i := i + 1; }
  StrSetChar(k2, 32, 0);
  var iv: pchar := alloc(32) as pchar;
  i := 0; while (i < 16) { StrSetChar(iv, i, 0); i := i + 1; }
  var pt: pchar := alloc(32) as pchar;
  i := 0; while (i < 16) { StrSetChar(pt, i, i * 17); i := i + 1; }
  var ct: pchar := alloc(64) as pchar;
  AES128CBCEncrypt(key, iv, pt, 16, ct);
  hexOut(ct, 16);
  var ct2: pchar := alloc(64) as pchar;
  AES256CBCEncrypt(k2, iv, pt, 16, ct2);
  hexOut(ct2, 16);
  return 0;
}" "69c4e0d86a7b0430d8cdb78070b4c55a
8ea2b7ca516745bfeafc49904b496089"

# Der Roundtrip ueber mehrere Bloecke prueft (c) und zugleich die
# CBC-Verkettung und das Entfernen des Paddings — 40 Byte Klartext werden auf
# 48 aufgefuellt und muessen als 40 zurueckkommen.
out "AES-128/256 CBC-Roundtrip ueber drei Bloecke" "import std.io;
import std.crypto.aes;
$HEX
fn main(): int64 {
  var i: int64 := 0;
  var key: pchar := alloc(32) as pchar;
  while (i < 16) { StrSetChar(key, i, i); i := i + 1; }
  StrSetChar(key, 16, 0);
  var k2: pchar := alloc(48) as pchar;
  i := 0; while (i < 32) { StrSetChar(k2, i, i); i := i + 1; }
  StrSetChar(k2, 32, 0);
  var iv: pchar := alloc(32) as pchar;
  i := 0; while (i < 16) { StrSetChar(iv, i, 0); i := i + 1; }
  var lang: pchar := alloc(64) as pchar;
  i := 0; while (i < 40) { StrSetChar(lang, i, 65 + (i % 26)); i := i + 1; }
  StrSetChar(lang, 40, 0);
  var e1: pchar := alloc(128) as pchar;
  var n1: int64 := AES128CBCEncrypt(key, iv, lang, 40, e1);
  var d1: pchar := alloc(128) as pchar;
  PrintLn(IntToStr(AES128CBCDecrypt(key, iv, e1, n1, d1)));
  hexOut(d1, 40);
  var e2: pchar := alloc(128) as pchar;
  var n2: int64 := AES256CBCEncrypt(k2, iv, lang, 40, e2);
  var d2: pchar := alloc(128) as pchar;
  PrintLn(IntToStr(AES256CBCDecrypt(k2, iv, e2, n2, d2)));
  hexOut(d2, 40);
  return 0;
}" "40
4142434445464748494a4b4c4d4e4f505152535455565758595a4142434445464748494a4b4c4d4e
40
4142434445464748494a4b4c4d4e4f505152535455565758595a4142434445464748494a4b4c4d4e"

# Gegenprobe zu (d): der Ueberlauf war daran sichtbar, dass fremde Daten
# hinter dem Puffer zerstoert wurden. Ein Wert direkt neben dem Schluesselplan
# muss die Expansion unveraendert ueberstehen.
out "die Key Expansion schreibt nicht ueber ihren Puffer hinaus" "import std.io;
import std.crypto.aes;
fn main(): int64 {
  var ek: pchar := alloc(256) as pchar;
  var nachbar: pchar := alloc(32) as pchar;
  var i: int64 := 0;
  while (i < 16) { StrSetChar(nachbar, i, 200); i := i + 1; }
  var k2: pchar := alloc(48) as pchar;
  i := 0; while (i < 32) { StrSetChar(k2, i, i); i := i + 1; }
  StrSetChar(k2, 32, 0);
  PrintLn(IntToStr(AES256KeyExpand(k2, ek)));
  var heil: int64 := 1;
  i := 0;
  while (i < 16) { if (StrCharAt(nachbar, i) != 200) { heil := 0; } i := i + 1; }
  PrintLn(IntToStr(heil));
  return 0;
}" "240
1"

# ===========================================================================
# #1263 — Level-Pruefung der PQC-Verfahren
# ===========================================================================
# Geprueft wird der ABBRUCH, nicht nur die Meldung: ein Aufruf, der meldet und
# dann doch schreibt, waere sonst ebenso gruen.

pqc_rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 60 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then no "$1" "Exit 0 — der falsche Wert galt als Erfolg"; return; fi
  if echo "$got" | grep -q "$3"; then ok "$1 (abgebrochen)"
  else no "$1" "andere Meldung — '$got'"; fi
}

pqc_rejects "ML-DSA weist einen unbekannten Level ab" 'import std.io;
import std.crypto.pqc.mldsa;
fn main(): int64 {
  var seed: int64 := alloc(32);
  var pk: int64 := alloc(MLDSA44_PK);
  var sk: int64 := alloc(MLDSA44_SK);
  MLDSAKeyGen(seed, 45, pk, sk);
  PrintLn("haette nicht kommen duerfen");
  return 0;
}' "unbekannter Level"

pqc_rejects "ML-KEM weist ein unbekanntes k ab" 'import std.io;
import std.crypto.pqc.mlkem;
fn main(): int64 {
  var seed: int64 := alloc(64);
  var pk: int64 := alloc(800);
  var sk: int64 := alloc(1632);
  MLKEMKeyGen(seed, 5, pk, sk);
  PrintLn("haette nicht kommen duerfen");
  return 0;
}' "unbekanntes k"

# Gegenprobe: die genormten Varianten muessen unveraendert durchlaufen — sonst
# waere die Pruefung zu weit gefasst. Signieren und Verifizieren in einem Zug,
# damit nicht nur die Pruefung, sondern der ganze Weg gemessen wird.
out "alle drei ML-DSA-Level signieren und verifizieren weiter" 'import std.io;
import std.crypto.pqc.mldsa;
fn one(level: int64, pkN: int64, skN: int64, sigN: int64): void {
  var seed: int64 := alloc(32);
  var pk: int64 := alloc(pkN);
  var sk: int64 := alloc(skN);
  MLDSAKeyGen(seed, level, pk, sk);
  var msg: int64 := alloc(8);
  var sig: int64 := alloc(sigN);
  MLDSASign(sk, level, msg, 8, sig);
  PrintLn(IntToStr(MLDSAVerify(pk, level, msg, 8, sig, sigN)));
}
fn main(): int64 {
  one(44, MLDSA44_PK, MLDSA44_SK, MLDSA44_SIG);
  one(65, MLDSA65_PK, MLDSA65_SK, MLDSA65_SIG);
  one(87, MLDSA87_PK, MLDSA87_SK, MLDSA87_SIG);
  return 0;
}' "1
1
1"

out "alle drei ML-KEM-Varianten einigen sich weiter auf dasselbe Geheimnis" 'import std.io;
import std.crypto.pqc.mlkem;
fn one(k: int64): void {
  var seed: int64 := alloc(64);
  var pk: int64 := alloc(384 * k + 32);
  var sk: int64 := alloc(768 * k + 96);
  MLKEMKeyGen(seed, k, pk, sk);
  var rnd: int64 := alloc(32);
  var ct: int64 := alloc(1600);
  var ss1: int64 := alloc(32);
  var ss2: int64 := alloc(32);
  MLKEMEncapsulate(pk, k, rnd, ct, ss1);
  MLKEMDecapsulate(sk, k, ct, ss2);
  var same: int64 := 1;
  var i: int64 := 0;
  while (i < 32) { if (peek8(ss1 + i) != peek8(ss2 + i)) { same := 0; } i := i + 1; }
  PrintLn(IntToStr(same));
}
fn main(): int64 { one(2); one(3); one(4); return 0; }' "1
1
1"

# ===========================================================================
# #1267 — Signal-Handler
# ===========================================================================
# Geprueft wird der WEG: dass der Handler laeuft UND dass die Ausfuehrung
# danach weitergeht. Vorher starb der Prozess an SIGSEGV, nachdem der Kernel
# eine Null als Restorer angesprungen hatte — ein Test, der nur die Ausgabe
# des Handlers prueft, haette den Rueckweg nicht gemessen.

out "Handler laeuft und die Ausfuehrung geht danach weiter" 'import std.io;
import std.signals;
fn onSig(signo: int64): void { PrintLn("im Handler"); PrintLn(IntToStr(signo)); }
fn main(): int64 {
  SignalSet(SIGUSR1, onSig as int64);
  SignalSendSelf(SIGUSR1);
  PrintLn("nach der Zustellung");
  return 0;
}' "im Handler
10
nach der Zustellung"

# Zwei Zustellungen hintereinander: ein Restorer, der den Sigframe beschaedigt,
# faellt spaetestens beim zweiten Mal auf.
out "mehrere Zustellungen hintereinander" 'import std.io;
import std.signals;
fn onSig(signo: int64): void { PrintLn("x"); }
fn main(): int64 {
  SignalSet(SIGUSR1, onSig as int64);
  SignalSendSelf(SIGUSR1);
  SignalSendSelf(SIGUSR1);
  SignalSendSelf(SIGUSR1);
  PrintLn("fertig");
  return 0;
}' "x
x
x
fertig"

# Gegenprobe: Ignorieren und Standardverhalten duerfen sich nicht mitveraendert
# haben — fuer sie wird bewusst KEIN Restorer gesetzt.
out "SIG_IGN und SIG_DFL unveraendert" 'import std.io;
import std.signals;
fn main(): int64 {
  SignalIgnore(SIGUSR1);
  SignalSendSelf(SIGUSR1);
  PrintLn("ignoriert ueberlebt");
  PrintLn(IntToStr(SignalDefault(SIGUSR1)));
  return 0;
}' "ignoriert ueberlebt
0"

# ===========================================================================
# #1191 — std.fs zieht keine libc mehr herein
# ===========================================================================

printf '%s\n' 'import std.io;
import std.fs;
fn main(): int64 {
  var pb: int64 := alloc(64);
  var fd: int64 := MkTemp(pb);
  if (fd >= 0) { PrintLn("ok"); } else { PrintLn("FEHLER"); }
  return 0;
}' > "$TMP/fs.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/fs.lyx" -o "$TMP/fs" >/dev/null 2>&1; then
  if file "$TMP/fs" | grep -q "statically linked"; then
    ok "ein Programm mit std.fs ist statisch gelinkt"
  else
    no "std.fs statisch" "$(file "$TMP/fs" | grep -o 'dynamically linked')"
  fi
  # Gegenprobe: die Zeitmarke muss weiterhin entstehen, sonst waere die
  # Abhaengigkeit nur entfernt und die Funktion kaputt.
  got="$("$TMP/fs" 2>&1)"
  if [ "$got" = "ok" ]; then ok "MkTemp legt weiterhin eine Datei an"
  else no "MkTemp" "'$got'"; fi
else
  no "std.fs" "uebersetzt nicht"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
