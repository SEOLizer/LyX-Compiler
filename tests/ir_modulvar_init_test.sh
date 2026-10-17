#!/usr/bin/env bash
# tests/ir_modulvar_init_test.sh — #2123: Anfangswerte von Modulvariablen auf
# dem IR-Weg (arm64, riscv, lyxos; .so: tests/android_shared_lib_test.sh).
#
# Bis 1.2.14C legte der Vorpass in ir_lower.lyx nur ab, was sich zur
# Uebersetzungszeit falten liess; jeder andere Anfangswert blieb STILL 0:
#   - `var s: pchar := "abc"`        Nullzeiger (StrLen -> SIGSEGV)
#   - `var e: f64 := 1.5 * 2.0`      0.0
#   - `var r: TR;` (Struktur)        kein Speicher, `r.b := 5` -> SIGSEGV
#   - `var q: [4]int64;`             kein Speicher, `q[2] := 9` -> SIGSEGV
#   - `var gF: fn(...) := Triple`    Sprung nach 0
#   - `var g := f() + 1`, `var b := a + 1`, Init in einer importierten Unit
# Jetzt entsteht je Unit eine Funktion, und main ruft sie vorab — in
# Abhaengigkeitsreihenfolge (importierte Unit vor dem Importeur).
#
# Teil 1 vergleicht mit x86_64 fuer alles, was der x86-Weg uebersetzt. Teil 2
# misst, was x86 (noch) LAUT abweist — einen Aufruf oder eine andere
# Modulvariable im Anfangswert ("Startwert ist zur Uebersetzungszeit nicht
# bekannt"); dort gilt der ausgerechnete Wert. Die REIHENFOLGE wird am Weg
# gemessen: jeder Anfangswert haengt eine Ziffer an einen Zaehler, 123 heisst
# "einmal, und in dieser Folge".
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

# Uebersetzen im Verzeichnis der Quelle (Importe loesen relativ dazu auf).
baue() {  # quelle, ziel, ausgabe
  ( cd "$(dirname "$1")" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$2" "$1" -o "$3" ) >"$TMP/bl.log" 2>&1
}
lauf() {  # ziel, binary
  case "$1" in
    x86_64) ( ulimit -v 4000000; timeout 30 "$2" ) ;;
    arm64)  ( ulimit -v 4000000; timeout 30 "$QEMU_ARM64" "$2" ) ;;
    riscv)  ( ulimit -v 4000000; timeout 30 "$QEMU_RISCV64" "$2" ) ;;
  esac
}
messe() {  # name, quelle, ziel -> Ausgabe auf stdout ("" bei Fehler)
  rm -f "$TMP/p"
  if ! baue "$2" "$3" "$TMP/p"; then
    echo "UEBERSETZT-NICHT: $(grep -v Copyright "$TMP/bl.log" | grep -m1 -iE 'error|lyxc:')"; return
  fi
  local aus rc
  aus="$(cd "$TMP" && lauf "$3" "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
  echo "$aus rc=$rc"
}

# --- Teil 1: was x86 uebersetzt, muss auf dem IR-Weg dasselbe ergeben -------
cat > "$TMP/xfall.lyx" <<'EOF'
type TR = struct { a: int64; b: int64; };
fn Triple(x: int64): int64 { return x * 3; }
var s: pchar := "abc";
var e: f64 := 1.5 * 2.0;
var r: TR;
var q: [4]int64;
var gF: fn(int64): int64 := Triple;
var k: int64 := 5 * 3;
fn main(): int64 {
  r.b := 5;
  q[2] := 9;
  PrintInt(StrLen(s)); Print(" ");
  PrintInt((e * 10.0) as int64); Print(" ");
  PrintInt(r.b); Print(" ");
  PrintInt(q[2]); Print(" ");
  PrintInt(gF(4)); Print(" ");
  PrintInt(k); Print("\n");
  return 0;
}
EOF
SOLL1="3 30 5 9 12 15| rc=0"
X86="$(messe x86 "$TMP/xfall.lyx" x86_64)"
if [ "$X86" = "$SOLL1" ]; then ok "x86_64 (Referenz): [$X86]"
else nok "x86_64 (Referenz): [$X86] statt [$SOLL1]"; fi
for t in arm64 riscv; do
  ist="$(messe "$t" "$TMP/xfall.lyx" "$t")"
  if [ "$ist" = "$X86" ] && [ "$ist" = "$SOLL1" ]; then ok "Zeichenkette/f64/Struktur/Array/fn-Verweis [$t] == x86: [$ist]"
  else nok "Zeichenkette/f64/Struktur/Array/fn-Verweis [$t]: [$ist], x86 [$X86]"; fi
done

# --- Teil 2: Aufruf, andere Modulvariable, importierte Units ----------------
# Der Fall aus dem Issue, woertlich.
cat > "$TMP/issue.lyx" <<'EOF'
fn f(): int64 { return 41; }
var g: int64 := f() + 1;
var s: pchar := "abc";
fn main(): int64 { PrintInt(g); Print(" "); PrintInt(StrLen(s)); Print("\n"); return 0; }
EOF
# Aus einer anderen Modulvariablen (gefaltet UND zur Laufzeit), f64 aus
# einem Aufruf.
cat > "$TMP/kette.lyx" <<'EOF'
fn half(): f64 { return 0.5; }
fn sieben(): int64 { return 7; }
var a: int64 := 7;
var b: int64 := a + 1;
var c: int64 := sieben();
var d: int64 := c * 10 + b;
var hf: f64 := half() * 3.0;
fn main(): int64 {
  PrintInt(b); Print(" "); PrintInt(d); Print(" "); PrintInt((hf * 10.0) as int64); Print("\n");
  return 0;
}
EOF
# Reihenfolge ueber Units: haupt importiert ub VOR ua, ub importiert ua.
# Erwartet: basis (keine), ua, ub, haupt — gSeq = 123, jede Unit genau einmal.
mkdir -p "$TMP/mi"
cat > "$TMP/mi/basis.lyx" <<'EOF'
unit mi.basis;
pub var gSeq: int64 := 0;
pub fn Mark(k: int64): int64 { gSeq := gSeq * 10 + k; return gSeq; }
EOF
cat > "$TMP/mi/ua.lyx" <<'EOF'
unit mi.ua;
import mi.basis;
fn seed(): int64 { return 20; }
pub var aOrd: int64 := Mark(1);
pub var aBase: int64 := seed() * 2;
var aPriv: pchar := "ua";
pub fn APrivLen(): int64 { return StrLen(aPriv); }
EOF
cat > "$TMP/mi/ub.lyx" <<'EOF'
unit mi.ub;
import mi.basis;
import mi.ua;
pub var bOrd: int64 := Mark(2);
pub var bVal: int64 := aBase + 2;
EOF
cat > "$TMP/haupt.lyx" <<'EOF'
import mi.ub;
import mi.ua;
import mi.basis;
var mOrd: int64 := Mark(3);
var mVal: int64 := bVal * 10;
fn main(): int64 {
  PrintInt(gSeq); Print(" ");
  PrintInt(aOrd); Print(" "); PrintInt(bOrd); Print(" "); PrintInt(mOrd); Print(" ");
  PrintInt(mVal); Print(" "); PrintInt(APrivLen()); Print("\n");
  return 0;
}
EOF
for t in arm64 riscv; do
  ist="$(messe "$t" "$TMP/issue.lyx" "$t")"
  [ "$ist" = "42 3| rc=0" ] && ok "Issue woertlich [$t]: [$ist]" || nok "Issue woertlich [$t]: [$ist] statt [42 3| rc=0]"
  ist="$(messe "$t" "$TMP/kette.lyx" "$t")"
  [ "$ist" = "8 78 15| rc=0" ] && ok "Modulvariable/Aufruf/f64 [$t]: [$ist]" || nok "Modulvariable/Aufruf/f64 [$t]: [$ist] statt [8 78 15| rc=0]"
  ist="$(messe "$t" "$TMP/haupt.lyx" "$t")"
  [ "$ist" = "123 1 12 123 420 2| rc=0" ] && ok "Importe, Reihenfolge [$t]: [$ist]" \
    || nok "Importe, Reihenfolge [$t]: [$ist] statt [123 1 12 123 420 2| rc=0]"
done

# --- Teil 3: lyxos ---------------------------------------------------------
# Der lokale LBF-Lader fuehrt das Abbild unter Linux aus; der Rueckgabewert
# von main kommt als Exit-Code. Nur Ganzzahl und nicht allokierend (LyxOS
# liefert Syscall-Ergebnisse in rdx, Linux in rax) — die Zeichenkette wird
# deshalb ueber peek8 gelesen, nicht ueber StrLen.
lyxos_rc() {  # quelle -> Exit-Code von main
  rm -f "$TMP/e.lyxnative" "$TMP/er"
  if ! baue "$1" lyxos "$TMP/e.lyxnative"; then echo "UEBERSETZT-NICHT"; return; fi
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/e.lyxnative"c); return 111; }' "$TMP" > "$TMP/er.lyx"
  ( cd "$ROOT" && timeout 240 "$LYXC" "$TMP/er.lyx" -o "$TMP/er" ) >/dev/null 2>&1 || { echo "LADER-UEBERSETZT-NICHT"; return; }
  ( ulimit -v 4000000; timeout 10 "$TMP/er" >/dev/null 2>&1 ); echo $?
}
cat > "$TMP/lx1.lyx" <<'EOF'
fn f(): int64 { return 41; }
var g: int64 := f() + 1;
fn main(): int64 { return g; }
EOF
cat > "$TMP/lx2.lyx" <<'EOF'
var s: pchar := "HELLO";
fn main(): int64 { return peek8((s as int64) + 1); }
EOF
cat > "$TMP/lx3.lyx" <<'EOF'
import mi.ub;
import mi.ua;
import mi.basis;
var mOrd: int64 := Mark(3);
fn main(): int64 { return gSeq; }
EOF
r="$(lyxos_rc "$TMP/lx1.lyx")"; [ "$r" = "42" ]  && ok "lyxos: Aufruf im Anfangswert (rc $r)" || nok "lyxos: Aufruf im Anfangswert: rc $r statt 42"
r="$(lyxos_rc "$TMP/lx2.lyx")"; [ "$r" = "69" ]  && ok "lyxos: Zeichenkette (rc $r = 'E')" || nok "lyxos: Zeichenkette: rc $r statt 69"
r="$(lyxos_rc "$TMP/lx3.lyx")"; [ "$r" = "123" ] && ok "lyxos: Importe, Reihenfolge (rc $r)" || nok "lyxos: Importe, Reihenfolge: rc $r statt 123"

# --- Teil 4: --compile-unit fuer ein IR-Ziel ---------------------------------
# Eine vorkompilierte Unit hat (noch) keinen Aufrufer fuer ihre Anfangswerte.
# Gemessen wird, dass daraus keine STILLE Null wird: entweder die Meldung, oder
# der Wert kommt im einbindenden Programm richtig an.
mkdir -p "$TMP/cu/demo"
# Eine Zeichenkette: die nimmt auch der x86-Weg, der beim Vorkompilieren
# mitlaeuft — die Frage landet also wirklich beim IR.
cat > "$TMP/cu_u.lyx" <<'EOF'
unit demo.cu;
var s: pchar := "abc";
pub fn G(): int64 { return StrLen(s) + 39; }
EOF
cat > "$TMP/cu_p.lyx" <<'EOF'
import demo.cu;
fn main(): int64 { PrintInt(G()); Print("\n"); return 0; }
EOF
if ( cd "$ROOT" && timeout 240 "$LYXC" --compile-unit --target=arm64 --std-path="$ROOT" "$TMP/cu_u.lyx" -o "$TMP/cu/demo/cu.lyu" ) >"$TMP/cu.log" 2>&1; then
  if ( cd / && timeout 240 "$LYXC" --target=arm64 --std-path="$ROOT" -I "$TMP/cu" "$TMP/cu_p.lyx" -o "$TMP/cu/p" ) >"$TMP/cub.log" 2>&1; then
    ist="$(lauf arm64 "$TMP/cu/p" 2>/dev/null)"
    [ "$ist" = "42" ] && ok "--compile-unit: Wert kommt an ($ist)" || nok "--compile-unit: [$ist] statt 42 — stille Null"
  else nok "--compile-unit: Programm uebersetzt nicht ($(grep -v Copyright "$TMP/cub.log" | head -1))"; fi
else
  grep -q "#2123" "$TMP/cu.log" && ok "--compile-unit: laut abgewiesen" \
    || nok "--compile-unit: Abbruch ohne Meldung ($(grep -v Copyright "$TMP/cu.log" | head -1))"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
