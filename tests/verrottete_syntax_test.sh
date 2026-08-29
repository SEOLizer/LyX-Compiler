#!/usr/bin/env bash
# tests/verrottete_syntax_test.sh — Schreibweisen, die es NICHT gibt (#1819).
#
# In `tests/suite-broken.txt` lagen Dateien aus einer aelteren Sprachstufe.
# Sechs davon liessen sich nicht portieren, weil das Konstrukt in Lyx nie
# existierte oder bewusst entfernt wurde. Sie sind geloescht — und dieser Test
# haelt fest, WARUM: jedes Konstrukt muss LAUT abgewiesen werden.
#
# Ohne diesen Waechter waere die Erkenntnis mit den Dateien verschwunden, und
# der naechste Anlauf schriebe sie wieder hin. Gemessen wird die WIRKUNG (die
# Uebersetzung scheitert), nicht der genaue Wortlaut der Meldung — der darf
# sich aendern.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

weist_ab() {  # name, quelle, erwarteter Meldungsteil
  printf '%s\n' "$2" > "$TMP/t.lyx"
  if timeout 60 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t.out" >"$TMP/t.log" 2>&1; then
    echo "FAIL $1: uebersetzt klaglos — das Konstrukt gibt es nicht, also muss es gemeldet werden"
    FAIL=$((FAIL+1)); return
  fi
  case "$(cat "$TMP/t.log")" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: andere Meldung als erwartet ($3): $(head -1 "$TMP/t.log")"; FAIL=$((FAIL+1)) ;;
  esac
}

# `importC "hdr.h" link "lib"` gab es nie. Heute: `extern fn ... link "..."`,
# und `lyxc --include <hdr.h>` liest den Header.
weist_ab "importC_gibt_es_nicht" \
  'importC "string.h" link "libc.so.6";
fn main(): int64 { return 0; }' "unexpected top-level token"

# Generische TYPEN sind nicht vorgesehen (ebnf.md §12: TypeParamClause steht
# nur an Funktionen). Generische FUNKTIONEN gibt es seit #1009.
weist_ab "generischer_typ_wird_abgewiesen" \
  'pub type Pair<T> = struct { a: T; b: T; };
fn main(): int64 { return 0; }' "top-level"

# `parallel` ist seit SIMD ein Schluesselwort und taugt nicht als Bezeichner.
weist_ab "parallel_ist_schluesselwort" \
  'type parallel = int64;
fn main(): int64 { return 0; }' "parallel"

# `pool` ist seit Langem reserviert.
weist_ab "pool_ist_schluesselwort" \
  'fn main(): int64 { var pool: int64 := 1; return pool; }' "pool"

# Pascal-Form `if <Bedingung> then <Anweisung>` gab es in Lyx nie.
weist_ab "if_then_gibt_es_nicht" \
  'fn main(): int64 { if true then Print("x"c); return 0; }' "if-branch requires a block"

# Formatierung nach Pascal-Art (`Print(x:0:2)`) gibt es nicht — die Grammatik
# kennt keinen FormatSpec. Zahlen formatiert man ueber std.string.
weist_ab "doppelpunkt_formatierung_gibt_es_nicht" \
  'fn main(): int64 { var pi: f64 := 3.14; Print(pi:0:2); return 0; }' "benannte Argumente"

# `asm` kennt eine FESTE Mnemonic-Liste (System- und Portbefehle). Ein
# allgemeiner Assembler ist es nicht: `mov`/`syscall` werden abgewiesen. Zwei
# Testdateien versuchten damit direkte Syscalls; dafuer gibt es die Builtins.
weist_ab "asm_kennt_keine_allgemeinen_befehle" \
  'fn main(): int64 { asm { "mov rax, 60" "syscall" } return 0; }' "Mnemonic"

# Gegenprobe: was es GIBT, muss weiterhin gehen — sonst misst der Test nur,
# dass der Compiler ueberhaupt meckert.
printf 'extern fn strlen(s: pchar): int64 link "libc.so.6";\nfn main(): int64 { return strlen("abcd"c); }\n' > "$TMP/ok.lyx"
if timeout 60 "$LYXC" --std-path="$ROOT" "$TMP/ok.lyx" -o "$TMP/ok" >"$TMP/ok.log" 2>&1; then
  timeout 20 "$TMP/ok" >/dev/null 2>&1
  if [ $? -eq 4 ]; then echo "PASS extern_fn_geht_weiterhin"; PASS=$((PASS+1));
  else echo "FAIL extern_fn_geht_weiterhin: falscher Rueckgabewert"; FAIL=$((FAIL+1)); fi
else
  echo "FAIL extern_fn_geht_weiterhin: $(grep -im1 error "$TMP/ok.log")"; FAIL=$((FAIL+1))
fi

printf 'fn main(): int64 { asm { "nop" } return 7; }\n' > "$TMP/asmok.lyx"
if timeout 60 "$LYXC" --std-path="$ROOT" "$TMP/asmok.lyx" -o "$TMP/asmok" >"$TMP/asmok.log" 2>&1; then
  timeout 20 "$TMP/asmok" >/dev/null 2>&1
  if [ $? -eq 7 ]; then echo "PASS asm_mit_bekannter_mnemonic_geht"; PASS=$((PASS+1));
  else echo "FAIL asm_mit_bekannter_mnemonic_geht: falscher Rueckgabewert"; FAIL=$((FAIL+1)); fi
else
  echo "FAIL asm_mit_bekannter_mnemonic_geht: $(grep -im1 error "$TMP/asmok.log")"; FAIL=$((FAIL+1))
fi

echo "== verrottete_syntax_test: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
