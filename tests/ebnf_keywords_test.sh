#!/usr/bin/env bash
# tests/ebnf_keywords_test.sh — Keyword-Liste in ebnf.md gegen den Compiler.
#
# ebnf.md trug lange die Version 0.9.5B und war entsprechend abgedriftet: 19
# reservierte Woerter fehlten (darunter `type`, `in`, `is`, `pool`, `parallel`,
# `interface`), und fuenf gelistete waren gar nicht reserviert (`Self`, `flat`,
# `packed`, `check`, `limit`). Wer sich auf die Doku verliess, stiess erst beim
# Uebersetzen darauf — und die Fehlermeldung nennt den Bezeichner nicht einmal,
# sondern scheitert an der naechsten Konstruktion (siehe LX-27, `pool`).
#
# Der Test prueft jedes in ebnf.md gelistete Wort direkt am Compiler: als
# Variablenname eingesetzt muss ein reserviertes Wort einen Fehler ausloesen,
# ein nicht gelistetes darf es nicht. Damit kann die Liste nicht mehr
# unbemerkt von der Sprache abweichen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Reserviert laut ebnf.md, Abschnitt 2.1
# Zeilenumbrueche zu Leerzeichen: der Mustervergleich unten sucht " wort ".
DOC_KW=$(awk '/^## 2\.1 Reserved Keywords/,/^Zwei Sonderfaelle/' "$ROOT/ebnf.md" \
         | sed -n '/^```text$/,/^```$/p' | sed '1d;$d' | tr '\n' ' ')

# Im Lexer eingetragen (Quelle der Wahrheit fuer die Vollstaendigkeit)
LEX_KW=$(grep -oE '_lexMatchKw\(src, start, len, "[a-zA-Z_]+"\)' "$ROOT/src/lexer.lyx" \
         | grep -oE '"[a-zA-Z_]+"' | tr -d '"' | sort -u)

is_reserved() {   # 1 = Compiler lehnt als Bezeichner ab
  printf 'fn main(): int64 { var %s: int64 := 1; return %s; }' "$1" "$1" > "$TMP/k.lyx"
  if timeout 30 "$LYXC" "$TMP/k.lyx" -o "$TMP/k" >/dev/null 2>&1; then echo 0; else echo 1; fi
}

fails=0; checked=0

# 1. Jedes dokumentierte Wort muss reserviert sein.
for kw in $DOC_KW; do
  checked=$((checked+1))
  if [ "$(is_reserved "$kw")" -eq 0 ]; then
    echo "FAIL '$kw' steht in ebnf.md 2.1, ist aber als Bezeichner verwendbar"
    fails=$((fails+1))
  fi
done

# 2. Jedes Lexer-Keyword muss dokumentiert sein — sonst fehlt es in der Doku.
#    `char` ist der bekannte Sonderfall: in der Tabelle, aber nicht reserviert.
for kw in $LEX_KW; do
  case " $DOC_KW " in *" $kw "*) continue ;; esac
  [ "$kw" = "char" ] && continue
  if [ "$(is_reserved "$kw")" -eq 1 ]; then
    echo "FAIL '$kw' ist reserviert, fehlt aber in ebnf.md 2.1"
    fails=$((fails+1))
  fi
done

if [ "$fails" -eq 0 ]; then
  echo "PASS ebnf.md 2.1: $checked Keywords, alle gegen den Compiler bestaetigt"
  exit 0
fi
echo "Ergebnis: $fails Abweichung(en) zwischen ebnf.md und Compiler"
exit 1
