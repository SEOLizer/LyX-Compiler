#!/bin/bash
# #1720 Block B — die stdlib-Grundlagen auf der IR-Strecke.
#
# Geprueft wird beides: dass sie gegen --target=lyxos UEBERSETZEN und dass sie
# auf x86 das Richtige RECHNEN. Nur zu bauen sagt hier fast nichts — eine
# vertauschte Sprungrichtung in StrEq liefert konstant 0 oder 1, und beides
# sieht in einem Bau-Test gleich aus.
#
# Die Faelle sind so gewaehlt, dass sie genau das aufdecken: leere Ketten,
# Praefix laenger als die Kette, Fehlversuch mit Neustart bei StrFind.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; F=$((F+1)); }

# --- 1: uebersetzt gegen lyxos ------------------------------------------------
for fall in \
  'var v: int64 := 0; var s: pchar := ArgvGetStr(v, 0); return 0;|ArgvGetStr' \
  'IMPORTALLOC|var b: int64 := alloc(8); buf_put_byte(b,0,65); return buf_get_byte(b,0);|buf_put/get_byte' \
  'return ioctl(1, 0, 0);|ioctl' \
  'var s: pchar := FloatToStr(1.5); return 0;|FloatToStr' \
  'return StrEq("a","a");|StrEq' \
  'return StrStartsWith("abc","ab");|StrStartsWith' \
  'return StrFind("abc","b");|StrFind' \
  'var s: pchar := StrTrim("  a  "); return 0;|StrTrim' \
  'return FileSize("/etc/hostname");|FileSize' \
  'var b: pchar := FileReadAll("/etc/hostname"); return 0;|FileReadAll' ; do
  src="${fall%%|*}"; name="${fall##*|}"
  # Ein Fall braucht std.alloc: `alloc` ohne Import scheitert auf JEDEM Ziel
  # (#1718), das waere ein Fehler des Testfalls und kein Befund.
  kopf=""
  if [ "$src" = "IMPORTALLOC" ]; then
    kopf="import std.alloc;"
    rest="${fall#IMPORTALLOC|}"; src="${rest%%|*}"
  fi
  printf '%s\nfn main(): int64 { %s }\n' "$kopf" "$src" > "$TMP/t.lyx"
  if timeout 300 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.out" >"$TMP/l" 2>&1 \
     && [ "$(head -c4 "$TMP/t.out")" = "LYX!" ]
  then ok "lyxos: $name"
  else bad "lyxos: $name" "$(grep -oE 'unbekannter Builtin.*|Builtin-ID [0-9]+ .*' "$TMP/l" | head -1)"; fi
done

# --- 2: und sie rechnen richtig ----------------------------------------------
cat > "$TMP/r.lyx" <<'EOF'
import std.io;
import std.alloc;
fn main(): int64 {
  var s: int64 := 0;
  if (StrEq("ab","ab") == 1)             { s := s + 1; }
  if (StrEq("ab","abc") == 0)            { s := s + 2; }
  if (StrEq("","") == 1)                 { s := s + 4; }
  if (StrStartsWith("abcdef","abc") == 1){ s := s + 8; }
  if (StrStartsWith("abc","abcdef") == 0){ s := s + 16; }
  if (StrFind("abcdef","cd") == 2)       { s := s + 32; }
  if (StrFind("aaab","aab") == 1)        { s := s + 64; }
  if (StrFind("ab","abc") == 0 - 1)      { s := s + 128; }
  if (StrFind("abc","") == 0)            { s := s + 256; }
  var b: int64 := alloc(32);
  buf_put_byte(b,0,32); buf_put_byte(b,1,9); buf_put_byte(b,2,97);
  buf_put_byte(b,3,98); buf_put_byte(b,4,32); buf_put_byte(b,5,0);
  if (buf_get_byte(b,2) == 97)           { s := s + 512; }
  if (StrLen(StrTrim(b as pchar)) == 2)  { s := s + 1024; }
  if (FileSize("/gibts/nicht") == 0 - 1) { s := s + 2048; }
  if (FileReadAll("/gibts/nicht") == 0 as pchar) { s := s + 4096; }
  PrintInt(s); PrintStr("\n");
  return 0;
}
EOF
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r.out" >"$TMP/l" 2>&1; then
  got="$("$TMP/r.out" 2>&1 | tr -d '\r\n')"
  if [ "$got" = "8191" ]; then ok "alle dreizehn Faelle rechnen richtig (8191)"
  else bad "Rechnung" "Summe $got statt 8191 — ein Fall liefert das Falsche"; fi
else
  bad "Rechnung" "uebersetzt nicht: $(grep -i error "$TMP/l" | head -1)"
fi

# --- 3: Dateigroesse gegen die Wirklichkeit ----------------------------------
if [ -r /etc/hostname ]; then
  echt=$(stat -c%s /etc/hostname)
  printf 'import std.io;\nfn main(): int64 { PrintInt(FileSize("/etc/hostname")); PrintStr("\\n"); return 0; }\n' > "$TMP/g.lyx"
  if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/g.lyx" -o "$TMP/g.out" >"$TMP/l" 2>&1; then
    got="$("$TMP/g.out" 2>&1 | tr -d '\r\n')"
    if [ "$got" = "$echt" ]; then ok "FileSize stimmt mit der echten Groesse ueberein ($echt)"
    else bad "FileSize" "$got statt $echt"; fi
  else bad "FileSize" "uebersetzt nicht"; fi
else
  echo "SKIP: /etc/hostname nicht lesbar"
fi

echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
