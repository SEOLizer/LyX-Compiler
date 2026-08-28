#!/bin/bash
# #1715, #1716, #1717, #1718 — das lyxos-Ziel kam ueber das erste
# String-Literal nicht hinaus.
#
# Geprueft wird jeweils die Stelle, an der es vorher brach:
#   #1715  emitBuiltinCall kannte 1, 2 und 20…256; alles dazwischen lief in
#          die Bremse. Schon `import std.alloc` reichte, denn std/alloc.lyx
#          meldet seine Fehler mit EPrintStr (ID 13).
#   #1716  Print/PrintLn waren an NK_LIT_STR gebunden. Jede Variable, Zahl
#          und jeder Ausdruck fiel durch bis zur Abbruchmeldung, die dann
#          PrintLn als "unbekannt" nannte — die falsche Faehrte.
#   #1717  StrNew war ein Compiler-Builtin, das nur der x86-Schnellweg
#          erzeugte; readlink und sys_clock_gettime waren unter anderem
#          Namen gelistet.
#   #1718  loest sich in #1715 auf: alloc/free brauchten nie einen eigenen
#          Weg, es fehlte nur ID 13 fuer die Fehlermeldung der Unit.
#
# Der Bau muss ausserdem den nativen LYX!-Container liefern, nicht ELF —
# sonst geht das Ergebnis am LX-34-Loader vorbei.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; F=$((F+1)); }

# baut <name> <quelltext> — uebersetzt gegen --target=lyxos und prueft LYX!
baut() {
  local name="$1"; local src="$2"
  printf '%s\n' "$src" > "$TMP/t.lyx"
  local log="$TMP/t.log"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.out" >"$log" 2>&1; then
    bad "$name" "$(grep -iE 'error|unbekannt' "$log" | head -1)"
    return
  fi
  local magic
  magic=$(head -c4 "$TMP/t.out" 2>/dev/null)
  if [ "$magic" != "LYX!" ]; then
    bad "$name" "kein LYX!-Container (Magic: $magic)"
    return
  fi
  ok "$name"
}

# bricht <name> <quelltext> <erwarteter Textteil> — muss scheitern, und zwar
# mit der richtigen Auskunft. Ein Abbruch mit falscher Begruendung ist
# schlimmer als keiner: er schickt die Suche in die falsche Richtung.
bricht() {
  local name="$1"; local src="$2"; local erwartet="$3"
  printf '%s\n' "$src" > "$TMP/t.lyx"
  local log="$TMP/t.log"
  if timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.out" >"$log" 2>&1; then
    bad "$name" "uebersetzt, obwohl es scheitern sollte"
    return
  fi
  if grep -qF "$erwartet" "$log"; then ok "$name"; else
    bad "$name" "andere Meldung: $(grep -iE 'error|unbekannt|kann den Typ' "$log" | head -1)"
  fi
}

# --- #1715 / #1718 -----------------------------------------------------------
baut "#1715 import std.alloc mit alloc/free" \
'import std.alloc;
fn main(): int64 { var p: int64 := alloc(8); free(p, 8); return 0; }'

baut "#1715 EPrintStrLn (ID 13 + 14)" \
'fn main(): int64 { EPrintStrLn("fehler"); return 0; }'

baut "#1715 StrLen (ID 15)" \
'fn main(): int64 { var s: pchar := "abcd"; return StrLen(s); }'

baut "#1715 exit (ID 3)" \
'fn main(): int64 { exit(2); return 0; }'

# --- #1716 -------------------------------------------------------------------
baut "#1716 PrintLn mit String-Literal" \
'fn main(): int64 { PrintLn("hallo"); return 0; }'

baut "#1716 PrintLn mit pchar-Variable" \
'fn main(): int64 { var s: pchar := "x"; PrintLn(s); return 0; }'

baut "#1716 PrintLn mit Zahl" \
'fn main(): int64 { PrintLn(7); return 0; }'

baut "#1716 PrintLn mit Ausdruck" \
'fn main(): int64 { var a: int64 := 2; var b: int64 := 3; PrintLn(a + b); return 0; }'

baut "#1716 Print mit pchar-Variable" \
'fn main(): int64 { var s: pchar := "x"; Print(s); return 0; }'

baut "#1716 PrintLn mit int-Nutzerfunktion" \
'fn f(): int64 { return 3; }
fn main(): int64 { PrintLn(f()); return 0; }'

baut "#1716 PrintLn mit pchar-Nutzerfunktion" \
'fn g(): pchar { return "hi"; }
fn main(): int64 { PrintLn(g()); return 0; }'

# --- #1717 -------------------------------------------------------------------
baut "#1717 StrNew" \
'fn main(): int64 { var s: pchar := StrNew(16); return 0; }'

# ---------------------------------------------------------------------------
# Die Meldung selbst ist Teil des Vertrags: bleibt ein Typ unbestimmbar, darf
# nicht "unbekannter Builtin/Funktion: PrintLn" dastehen — der Name ist ja
# behandelt. Genau diese Fehlleitung war der Kern von #1716.
# ---------------------------------------------------------------------------
bricht "#1716 unbestimmbarer Typ nennt nicht faelschlich den Namen" \
'fn h(): f64 { return 1.0; }
fn main(): int64 { PrintLn(h()); return 0; }' \
'kann den Typ des Arguments nicht bestimmen'

# ---------------------------------------------------------------------------
# #1832: StrConcat (ID 7) wurde nicht behandelt — "error: lyxos: Builtin-ID 7
# wird nicht behandelt". Damit war jedes Programm, das Text zusammensetzt,
# nicht als LBF baubar; bei einer Oberflaeche ist das der Normalfall
# ("Klicks: " + Zahl).
#
# WARUM HIER NICHT AUSGEFUEHRT WIRD: der lokale Lader (src.tools.lbf.loader)
# fuehrt das Abbild unter LINUX aus. LyxOS liefert das Ergebnis eines Syscalls
# in rdx, Linux in rax — jedes Builtin, das Speicher anfordert, bekommt hier
# also Muell als Pufferadresse und segfaultet. Deshalb pruefen die
# Laderfaelle oben nur Ganzzahlen.
#
# Gemessen wird darum am ERZEUGNIS. "ID behandelt" allein waere zu wenig
# (#1789: IRO_DIV stand in der Liste, der Rumpf war MOVI T0, 0) — geprueft
# werden die Bytes, die die Arbeit tun: beide Kopierschleifen und der
# abschliessende Nullabschluss.
# ---------------------------------------------------------------------------
bytes_da() {  # name, quelltext, hex-muster, klartext
  printf '%s\n' "$2" > "$TMP/b.lyx"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/b.lyx" -o "$TMP/b.out" >"$TMP/b.log" 2>&1; then
    bad "$1" "$(grep -iE 'error|Builtin-ID' "$TMP/b.log" | head -1)"; return
  fi
  if xxd -p "$TMP/b.out" | tr -d '\n' | grep -q "$3"; then
    echo "PASS $1"; P=$((P+1))
  else
    bad "$1" "$4 fehlt im Erzeugnis"
  fi
}

SRC_CONCAT='fn main(): int64 { var r: pchar := StrConcat("ab"c, "cde"c); return StrLen(r); }'

# Uebersetzt ueberhaupt wieder — das war der gemeldete Abbruch.
baut "#1832 StrConcat uebersetzt fuer lyxos" "$SRC_CONCAT"
# Erste Kopierschleife: CMP rcx,r13 / JGE / MOV al,[rsi+rcx] / MOV [rdi+rcx],al
bytes_da "#1832 erste Kopierschleife steht im Erzeugnis" "$SRC_CONCAT" \
  "4c39e97d0b8a040e88040f" "die Schleife ueber den linken Teil"
# Zweite Schleife laeuft gegen r14 statt r13 — waere sie eine Kopie der
# ersten, kaeme der rechte Teil nie an.
bytes_da "#1832 zweite Kopierschleife zaehlt gegen r14" "$SRC_CONCAT" \
  "4c39f17d0b8a040e88040f" "die Schleife ueber den rechten Teil"
# Nullabschluss hinter beiden Teilen: ohne ihn liefe jedes StrLen weiter.
bytes_da "#1832 Ergebnis wird null-terminiert" "$SRC_CONCAT" \
  "c6040f004c89e0" "der Nullabschluss"

echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
