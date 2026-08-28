#!/usr/bin/env bash
# tests/net_resolver_test.sh — #1330.
#
# GetHostByName schickte JEDE Anfrage an Google DNS (8.8.8.8). Damit war
#   * "127.0.0.1"  — eine Adresse in Textform wurde als Name abgefragt,
#   * "localhost"  — oeffentliches DNS kennt den Namen nicht,
#   * jeder Name im eigenen Netz
# nicht aufloesbar, und jede Verbindung verriet ihr Ziel nach draussen.
# Aufgefallen an std.db.redis: ein Redis auf demselben Rechner — der Regelfall
# fuer Cache und Queue — war ueber die Unit nicht erreichbar.
#
# Der Fix sitzt in GetHostByName, nicht in redis: literale Adresse,
# /etc/hosts, der Nameserver aus /etc/resolv.conf, Google erst als Rueckfall.
# Damit gilt er fuer alle sechzehn Aufrufstellen der stdlib.
#
# GEPRUEFT WIRD OHNE NETZ NACH DRAUSSEN. Die drei lokalen Stufen sind genau
# die, die vorher fehlten; ein Test gegen einen oeffentlichen Namen waere auch
# vor dem Fix gruen gewesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/r.lyx" <<'EOF'
import std.io;
import std.net.dns;
// ACHTUNG bei den Negativfaellen: was NICHT als Literal durchgeht, faellt in
// GetHostByName bis zur echten Namensanfrage durch — und misst dann den
// Resolver der Maschine, nicht unseren Parser.
//
// `1.2.3` stand hier und hat den Test wandern lassen: systemd-resolved
// (127.0.0.53) beantwortet die Kurzform selbst mit 1.2.0.3 (inet_aton-Auslegung),
// waehrend der Test 0.0.0.0 erwartete. Je nach Zustand des Stub-Resolvers war
// derselbe Test gruen oder rot, ohne dass sich am Compiler etwas geaendert
// haette. Der Fall ist deshalb raus.
//
// Uebrig bleiben zwei Negativfaelle, die kein Resolver beantwortet: ein
// ungueltiges Oktett (999) und fuenf Teile.
fn Z(h: pchar): void {
  var ip: int64 := GetHostByName(h as int64);
  PrintStr(IntToStr((ip >> 24) & 255)); PrintStr(".");
  PrintStr(IntToStr((ip >> 16) & 255)); PrintStr(".");
  PrintStr(IntToStr((ip >> 8) & 255)); PrintStr(".");
  PrintStr(IntToStr(ip & 255)); PrintStr(" ");
}
fn main(): int64 {
  Z("127.0.0.1"c);
  Z("10.20.30.40"c);
  Z("255.255.255.255"c);
  Z("999.1.1.1"c);
  Z("1.2.3.4.5"c);
  PrintLn("");
  return 0;
}
EOF

if "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1; then
  got="$(timeout 30 "$TMP/r" 2>&1)"
  soll="127.0.0.1 10.20.30.40 255.255.255.255 0.0.0.0 0.0.0.0 "
  if [ "$got" = "$soll" ]; then ok "#1330: literale IPv4 ohne Namensanfrage"
  else no "#1330: literale IPv4 ohne Namensanfrage" "'$got' erwartet '$soll'"; fi
else
  no "#1330: literale IPv4 ohne Namensanfrage" "uebersetzt nicht"
fi

# localhost steht in jeder /etc/hosts. Fehlt die Datei, sagt der Test das,
# statt einen gruenen Haken fuer nichts zu setzen.
if [ -r /etc/hosts ] && grep -qE '^[[:space:]]*127\.' /etc/hosts; then
  erw="$(awk '$1 ~ /^127\./ { for (i=2;i<=NF;i++) if ($i=="localhost") { print $1; exit } }' /etc/hosts)"
  printf 'import std.io;\nimport std.net.dns;\nfn main(): int64 {\n  var ip: int64 := GetHostByName("localhost"c as int64);\n  PrintStr(IntToStr((ip >> 24) & 255)); PrintStr(".");\n  PrintStr(IntToStr((ip >> 16) & 255)); PrintStr(".");\n  PrintStr(IntToStr((ip >> 8) & 255)); PrintStr(".");\n  PrintLn(IntToStr(ip & 255));\n  return 0;\n}\n' > "$TMP/l.lyx"
  if [ -n "$erw" ] && "$LYXC" --std-path="$ROOT" "$TMP/l.lyx" -o "$TMP/l" >/dev/null 2>&1; then
    got="$(timeout 30 "$TMP/l" 2>&1)"
    if [ "$got" = "$erw" ]; then ok "#1330: localhost kommt aus /etc/hosts"
    else no "#1330: localhost kommt aus /etc/hosts" "'$got' erwartet '$erw'"; fi
  else
    no "#1330: localhost kommt aus /etc/hosts" "uebersetzt nicht oder kein Eintrag"
  fi
else
  echo "SKIP /etc/hosts ohne 127er-Eintrag — nichts zu messen"
fi

# ===========================================================================
# Der gemeldete Fall: Redis auf demselben Rechner
# ===========================================================================

if command -v redis-cli >/dev/null 2>&1 && redis-cli -p 6379 ping 2>/dev/null | grep -q PONG; then
  printf 'import std.io;\nimport std.db.redis;\nfn Z(h: pchar): void {\n  var c: RedisConn := RedisConnect(h, 6379);\n  if (c.fd < 0) { PrintStr("kein-fd "); return; }\n  if (RedisPing(c)) { PrintStr("pong "); } else { PrintStr("stumm "); }\n  RedisClose(c);\n}\nfn main(): int64 { Z("127.0.0.1"c); Z("localhost"c); PrintLn(""); return 0; }\n' > "$TMP/rd.lyx"
  if "$LYXC" --std-path="$ROOT" "$TMP/rd.lyx" -o "$TMP/rd" >/dev/null 2>&1; then
    got="$(timeout 30 "$TMP/rd" 2>&1)"
    if [ "$got" = "pong pong " ]; then ok "#1330: Redis auf 127.0.0.1 und localhost erreichbar"
    else no "#1330: Redis auf 127.0.0.1 und localhost erreichbar" "'$got'"; fi
  else
    no "#1330: Redis auf 127.0.0.1 und localhost erreichbar" "uebersetzt nicht"
  fi
else
  echo "SKIP kein Redis auf 6379 — der gemeldete Fall laesst sich nicht messen"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
