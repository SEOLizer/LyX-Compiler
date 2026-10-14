#!/usr/bin/env bash
# tests/ldap_rdn_test.sh — #2071: LDAPGetRDNAt liefert die Komponente, nach
# der gefragt wird, auf x86_64, arm64 und riscv.
#
# Bis 1.2.12A war der Index um eins verschoben: "cn=admin,dc=example,dc=com"
# lieferte fuer 0, 1, 2 der Reihe nach dc=example, dc=com, cn=admin — die
# letzte Komponente fiel auf die erste zurueck. Das einzige Beispiel, das die
# Funktion rief (examples/ldap_test.lyx), pruefte nur `rdn != 0` und druckte
# den Zeiger als Zahl; der falsche WERT kam in keinem Lauf vor.
#
# Deshalb wird hier jede Komponente als Text verglichen, nicht ihr
# Vorhandensein — und zusaetzlich, dass LDAPGetRDNAt und LDAPCountRDNs
# dieselbe Zerlegung meinen: Index Count-1 gibt es, Index Count nicht.
set -uo pipefail
ulimit -c 0   # ein Absturz unter qemu legt sonst eine .core-Datei ins Repo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# Jede Zeile: "<dn>|<index> -> <ergebnis>". (0) = Rueckgabe 0, [] umschliesst
# den Text, damit eine leere Komponente sichtbar ist.
cat > "$TMP/rdn.lyx" <<'EOF'
import std.net.ldap;
import std.io;

fn zeige(dn: pchar, index: int64) {
  Print(dn); Print("|"); PrintInt(index); Print(" -> ");
  var r: int64 := LDAPGetRDNAt(dn, index);
  if (r == 0) { PrintLn("(0)"); }
  else { Print("["); Print(r as pchar); PrintLn("]"); }
}

// Index Count-1 muss es geben, Index Count nicht.
fn passt(dn: pchar) {
  var n: int64 := LDAPCountRDNs(dn);
  Print(dn); Print(" count="); PrintInt(n);
  var letzte: int64 := LDAPGetRDNAt(dn, n - 1);
  var dahinter: int64 := LDAPGetRDNAt(dn, n);
  if (letzte != 0 && dahinter == 0) { PrintLn(" passt"); }
  else { PrintLn(" PASST NICHT"); }
}

pub fn main(): int64 {
  zeige("cn=admin,dc=example,dc=com", 0);
  zeige("cn=admin,dc=example,dc=com", 1);
  zeige("cn=admin,dc=example,dc=com", 2);
  zeige("cn=admin,dc=example,dc=com", 3);
  zeige("cn=admin,dc=example,dc=com", 0 - 1);
  zeige("cn=x", 0);
  zeige("cn=x", 1);
  zeige("a,,b", 0);
  zeige("a,,b", 1);
  zeige("a,,b", 2);
  zeige("ab,", 0);
  zeige("ab,", 1);
  zeige("ab,", 2);
  passt("cn=admin,dc=example,dc=com");
  passt("cn=x");
  passt("a,,b");
  passt("ab,");
  return 0;
}
EOF

cat > "$TMP/soll" <<'EOF'
cn=admin,dc=example,dc=com|0 -> [cn=admin]
cn=admin,dc=example,dc=com|1 -> [dc=example]
cn=admin,dc=example,dc=com|2 -> [dc=com]
cn=admin,dc=example,dc=com|3 -> (0)
cn=admin,dc=example,dc=com|-1 -> (0)
cn=x|0 -> [cn=x]
cn=x|1 -> (0)
a,,b|0 -> [a]
a,,b|1 -> []
a,,b|2 -> [b]
ab,|0 -> [ab]
ab,|1 -> []
ab,|2 -> (0)
cn=admin,dc=example,dc=com count=3 passt
cn=x count=1 passt
a,,b count=3 passt
ab, count=2 passt
EOF

for ziel in x86_64 arm64 riscv; do
  pre=""
  case "$ziel" in
    arm64) pre="$QEMU_ARM64" ;;
    riscv) pre="$QEMU_RISCV64" ;;
  esac
  # Aus der Repo-Wurzel: der Resolver bevorzugt das CWD (std/ statt Paketbaum).
  if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" --target="$ziel" "$TMP/rdn.lyx" -o "$TMP/rdn_$ziel" ) >"$TMP/bl.log" 2>&1; then
    nok "[$ziel] uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
  fi
  if [ "$ziel" != "x86_64" ] && [ -z "$pre" ]; then
    nok "[$ziel] qemu fehlt — NICHT gemessen"; continue
  fi
  ( timeout 60 $pre "$TMP/rdn_$ziel" > "$TMP/ist_$ziel" 2>&1; echo $? > "$TMP/rc_$ziel" ) 2>/dev/null
  rc="$(cat "$TMP/rc_$ziel")"
  # Bei einem Absturz trotzdem die bis dahin gelieferten Zeilen vergleichen —
  # sie zeigen, an welchem Fall es kippt. (Die alte Fassung endete mit rc 139.)
  [ "$rc" = "0" ] && ok "[$ziel] endet mit rc 0" || nok "[$ziel] endet mit rc=$rc"
  # Zeile fuer Zeile, damit die Meldung sagt, WELCHER Fall abweicht.
  n=0; abw=0
  while IFS= read -r soll; do
    n=$((n+1))
    ist="$(sed -n "${n}p" "$TMP/ist_$ziel")"
    if [ "$ist" = "$soll" ]; then ok "[$ziel] $soll"
    else nok "[$ziel] soll \"$soll\", ist \"$ist\""; abw=1; fi
  done < "$TMP/soll"
  extra="$(sed -n "$((n+1)),\$p" "$TMP/ist_$ziel")"
  [ -z "$extra" ] || nok "[$ziel] ueberzaehlige Ausgabe: $(echo "$extra" | head -1)"
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
