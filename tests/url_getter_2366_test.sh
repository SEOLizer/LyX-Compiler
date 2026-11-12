#!/usr/bin/env bash
# tests/url_getter_2366_test.sh — std.url liefert BESTANDTEILE, nicht den Rest (#2366).
#
# Bis 1.2.31J gaben GetScheme, GetHostname, GetPath, GetQuery, GetFragment,
# GetUsername und GetPassword einen Zeiger in die uebergebene URL zurueck
# (`return url + pos;`) und schnitten nicht ab. `GetHostname` lieferte damit
# "example.com/a/b?x=1#oben" statt "example.com" — richtig war nur der jeweils
# LETZTE Bestandteil einer URL. Deshalb genuegt es hier nicht, Praefixe zu
# pruefen: gemessen wird auf GLEICHHEIT, und zusaetzlich, dass der Wert den
# nachfolgenden Bestandteil NICHT enthaelt. Ein Praefixtest waere auch von der
# alten Fassung erfuellt gewesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+ — $2}"; FAIL=$((FAIL+1)); }

cat > "$TMP/u.lyx" <<'EOF'
import std.io;
import std.string;
import std.url;

fn z(name: pchar, w: pchar): int64 {
  PrintStr(name); PrintStr("=["c); PrintStr(w); PrintStrLn("]"c); return 0;
}

fn main(): int64 {
  // Vollbestueckte URL: Schema, Anmeldedaten, Host, Port, Pfad, Query, Fragment.
  var u: pchar := "https://bob:geheim@example.com:8443/a/b?x=1&y=2#oben"c;
  z("scheme"c, GetScheme(u));
  z("user"c,   GetUsername(u));
  z("pass"c,   GetPassword(u));
  z("host"c,   GetHostname(u));
  PrintStr("port="c); PrintLn(GetPort(u));
  z("path"c,   GetPath(u));
  z("query"c,  GetQuery(u));
  z("frag"c,   GetFragment(u));
  z("qp_x"c,   URLQueryGet(u, "x"c));
  z("qp_y"c,   URLQueryGet(u, "y"c));

  // Ohne Anmeldedaten, ohne Port, ohne Query, ohne Fragment.
  var v: pchar := "http://example.com/nur/pfad"c;
  z("v_host"c,  GetHostname(v));
  z("v_path"c,  GetPath(v));
  z("v_query"c, GetQuery(v));
  z("v_frag"c,  GetFragment(v));
  z("v_user"c,  GetUsername(v));

  // '?' NACH dem '#' ist keine Query.
  var w: pchar := "https://example.com#frag?nichtquery"c;
  z("w_query"c, GetQuery(w));
  z("w_frag"c,  GetFragment(w));
  z("w_path"c,  GetPath(w));

  // Ohne Schema beginnt die URL mit dem Host (#2366: vorher las die
  // Zerlegung ab Versatz 2 und schnitt zwei Zeichen des Hosts ab).
  var h: pchar := "example.com/pfad"c;
  z("h_scheme"c, GetScheme(h));
  z("h_host"c,   GetHostname(h));
  z("h_path"c,   GetPath(h));

  // Die Positionsfunktionen bleiben der Weg OHNE Kopie.
  PrintStr("pos_host="c); PrintLn(URLHostAnfang(u));
  PrintStr("pos_hostende="c); PrintLn(URLHostEnde(u));
  PrintStr("pos_pfad="c); PrintLn(URLPfadAnfang(u));
  PrintStr("pos_query="c); PrintLn(URLQueryAnfang(u));
  PrintStr("pos_frag="c); PrintLn(URLFragmentAnfang(u));

  // Die Bestandteile duerfen die uebergebene URL nicht verbiegen: nach allen
  // Abfragen muss sie unveraendert sein (eigene Zeichenkette, kein Schreiben
  // in den Eingabepuffer).
  z("original"c, u);
  return 0;
}
EOF

if ! ( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/u.lyx" -o "$TMP/u" ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/b.log")"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"

AUS="$( ulimit -c 0; cd "$TMP" && timeout 60 ./u 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then
  no "laeuft" "rc=$rc"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
hol() { echo "$AUS" | sed -n "s/^$1=\[\(.*\)\]$/\1/p" | head -1; }
holz() { echo "$AUS" | sed -n "s/^$1=//p" | head -1; }

pruef() { # name sollwert
  local ist; ist="$(hol "$1")"
  if [ "$ist" = "$2" ]; then ok "$1 = '$2'"; else no "$1" "'$ist' statt '$2'"; fi
}

pruef scheme   "https"
pruef user     "bob"
pruef pass     "geheim"
pruef host     "example.com"
pruef path     "/a/b"
pruef query    "x=1&y=2"
pruef frag     "oben"
pruef qp_x     "1"
pruef qp_y     "2"
pruef v_host   "example.com"
pruef v_path   "/nur/pfad"
pruef v_query  ""
pruef v_frag   ""
pruef v_user   ""
pruef w_query  ""
pruef w_frag   "frag?nichtquery"
pruef w_path   ""
pruef h_scheme ""
pruef h_host   "example.com"
pruef h_path   "/pfad"
pruef original "https://bob:geheim@example.com:8443/a/b?x=1&y=2#oben"

[ "$(holz port)" = "8443" ] && ok "port = 8443" || no "port" "'$(holz port)'"

# Zweite Seite der Messung: kein Wert darf den FOLGENDEN Bestandteil enthalten.
# Das ist die Pruefung, die die alte Fassung gerissen haette.
for paar in "host:/" "host:?" "host::" "path:?" "path:#" "query:#" "user::" "user:@" "pass:@" "scheme::"; do
  n="${paar%%:*}"; z="${paar#*:}"
  case "$(hol "$n")" in
    *"$z"*) no "$n enthaelt '$z'" "'$(hol "$n")' — die Funktion schneidet nicht ab" ;;
    *) ok "$n enthaelt kein '$z'" ;;
  esac
done

# Die Positionsfunktionen muessen zu den Werten passen: der Host beginnt bei
# 19 ("https://bob:geheim@"), endet bei 30, der Pfad bei 35, die Query bei 40,
# das Fragment bei 48.
for erw in "pos_host:19" "pos_hostende:30" "pos_pfad:35" "pos_query:40" "pos_frag:48"; do
  n="${erw%%:*}"; w="${erw#*:}"
  if [ "$(holz "$n")" = "$w" ]; then ok "$n = $w"; else no "$n" "'$(holz "$n")' statt $w"; fi
done

# Keine der Funktionen darf wieder einen Zeiger ins Original zurueckgeben.
if grep -nE "^\s*return url \+ " "$ROOT/std/url.lyx" >/dev/null; then
  no "Zeiger ins Original" "in std/url.lyx steht wieder ein 'return url + ...'"
else
  ok "kein 'return url + ...' mehr in std/url.lyx"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
