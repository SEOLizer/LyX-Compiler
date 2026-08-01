#!/usr/bin/env bash
# tests/printf_x86_test.sh — #1012: Printf im x86-Codegen.
# Geprueft wird die AUSGABE (nicht nur der Exit-Code) und dass jeder
# Fehlerfall meldet statt etwas Plausibles zu tun.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# out <name> <quelltext> <erwartete-ausgabe>
out() {
  printf "%s" "$2" > "$TMP/c.lyx"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 5 "$TMP/c" 2>&1)"
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# err <name> <quelltext> — muss mit einer error:-Zeile abweisen
err() {
  printf "%s" "$2" > "$TMP/c.lyx"
  got="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if echo "$got" | grep -q "^error:"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen"; FAIL=$((FAIL+1)); fi
}

out "nur_literal"    'fn main(): int64 { Printf("hallo\n"); return 0; }' 'hallo'
out "decimal"        'fn main(): int64 { Printf("n=%d\n", 42); return 0; }' 'n=42'
out "negativ"        'fn main(): int64 { Printf("n=%d\n", 0-7); return 0; }' 'n=-7'
out "string"         'fn main(): int64 { Printf("s=%s\n", "abc"c); return 0; }' 's=abc'
out "zeichen"        'fn main(): int64 { Printf("c=%c\n", 65); return 0; }' 'c=A'
out "prozent"        'fn main(): int64 { Printf("100%%\n"); return 0; }' '100%'
out "mehrere"        'fn main(): int64 { Printf("%d+%d=%d\n", 2, 3, 5); return 0; }' '2+3=5'
out "gemischt"       'fn main(): int64 { Printf("[%s|%d|%c]\n", "x"c, 9, 66); return 0; }' '[x|9|B]'
out "tab_escape"     'fn main(): int64 { Printf("a\tb\n"); return 0; }' "$(printf 'a\tb')"
out "float"          'fn main(): int64 { Printf("f=%f\n", 2.5); return 0; }' 'f=2.500000'

err "zu_wenig_args"  'fn main(): int64 { Printf("%d %d\n", 1); return 0; }'
err "zu_viele_args"  'fn main(): int64 { Printf("%d\n", 1, 2); return 0; }'
err "unbek_spec"     'fn main(): int64 { Printf("%q\n", 1); return 0; }'
err "einzelnes_proz" 'fn main(): int64 { Printf("abc%"); return 0; }'
err "kein_literal"   'fn main(): int64 { var f: pchar := "%d\n"; Printf(f, 1); return 0; }'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
