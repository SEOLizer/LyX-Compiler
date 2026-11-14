#!/bin/bash
# #2449: Drei Deklarationsarten, die eine Unit quellpflichtig liessen, stehen
# jetzt in der .lyu. Gemessen mit der Methode des Issues (je Unit
# `import X; fn main()` gegen einen reinen .lyu-Baum) fiel die Zahl der
# quellpflichtigen Units von 192 auf 1:
#
#   @cap/@capabilities an einer `extern fn`   50 Faelle (std/net/dns.lyx u. a.)
#   `pub con X: int64 := "..."c as int64`     15 Faelle (std/cloud/cf/*)
#   `fn(...)`-Typ (Alias und Parameter)        4 Faelle (std/semarti/*, numeric)
#
# GEPRUEFT WIRD AM WERT, nicht am Vorhandensein einer Zeile: eine
# wiederhergestellte Deklaration kann syntaktisch richtig und inhaltlich falsch
# sein. Dazu die Gegenprobe fuer die absichtlichen Auslassungen.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/d4" "$T/nur/d4" "$T/leer"

# --- Unit mit allen drei Arten ------------------------------------------------
cat > "$T/src/d4/alles.lyx" <<'LYX'
unit d4.alles;
@cap(system.time)
extern fn time(tloc: int64): int64 link "libc.so.6";
pub con HOST: int64 := "api.example.test"c as int64;
pub type Wandler = fn(int64): int64;
pub fn Zweimal(x: int64): int64 { return x * 2; }
pub fn Wende(f: fn(int64): int64, x: int64): int64 { return f(x); }
pub fn Jetzt(): int64 { return time(0); }
LYX

"$LYXC" --std-path="$T/src" --with-objcode --compile-unit "$T/src/d4/alles.lyx" \
    -o "$T/nur/d4/alles.lyu" > "$T/bau.log" 2>&1 || {
  echo "FAIL Unit nicht uebersetzbar: $(grep -i error "$T/bau.log" | head -2)"
  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }

INFO="$("$LYXC" --unit-info "$T/nur/d4/alles.lyu" 2>&1)"

# 1) Capability-Angabe steht in der wiederhergestellten Deklaration.
if printf '%s' "$INFO" | grep -q '@capabilities(\[system.time\])'; then
  pr ok "die Capability-Angabe steht in der .lyu"
else
  pr no "keine Capability-Angabe: $(printf '%s' "$INFO" | grep -i 'extern fn time' | head -1)"
fi

# 2) Die Konstante traegt Text UND den Cast.
if printf '%s' "$INFO" | grep -q 'pub con HOST: int64 := "api.example.test"c as int64'; then
  pr ok "pchar-Cast-Konstante steht samt Cast in der .lyu"
else
  pr no "Konstante falsch beschrieben: $(printf '%s' "$INFO" | grep -i 'con HOST' | head -1)"
fi

# 3) fn-Typ als Alias und als Parameter.
if printf '%s' "$INFO" | grep -q 'pub type Wandler = fn(int64): int64' \
   && printf '%s' "$INFO" | grep -qE 'Wende.*fn\(int64\): int64'; then
  pr ok "fn-Typ steht als Alias und als Parameter in der .lyu"
else
  pr no "fn-Typ fehlt: $(printf '%s' "$INFO" | grep -iE 'Wandler|Wende' | head -2)"
fi

# 4) WIRKUNG: nur aus der .lyu uebersetzen und RECHNEN. Aus einem leeren
#    Verzeichnis, weil der Resolver das Arbeitsverzeichnis vor --std-path
#    bevorzugt -- im Repo faende er die Quelle und der Test waere gruen, ohne
#    die .lyu geprueft zu haben.
# Ohne std-Import: `peek8` ist ein Builtin. Zwei `--std-path` schlagen sich
# gegenseitig, und ein std-Import wuerde hier nur den Aufbau verkomplizieren --
# geprueft werden soll die .lyu dieser Unit, nicht die Suchpfadlogik.
cat > "$T/p.lyx" <<'LYX'
import d4.alles;
fn main(): int64 {
  var w: Wandler := Zweimal;
  if (Wende(w, 20) != 40) { return 1; }
  if (peek8(HOST) != 97) { return 2; }       // 'a' aus "api.example.test"
  if (peek8(HOST + 4) != 101) { return 3; }  // 'e' aus "api.example.test"
  if (Jetzt() <= 0) { return 4; }
  return 0;
}
LYX
rm -f "$T/p"
( cd "$T/leer" && "$LYXC" --std-path="$T/nur" -I"$T/nur" "$T/p.lyx" -o "$T/p" ) > "$T/p.log" 2>&1
if [ -x "$T/p" ]; then
  "$T/p"; RC=$?
  case "$RC" in
    0) pr ok "nur aus der .lyu: fn-Zeiger rechnet (40), Konstante zeigt auf den Text, time() liefert > 0" ;;
    1) pr no "fn-Zeiger ueber die .lyu-Grenze rechnet falsch" ;;
    2) pr no "die Konstante zeigt nicht auf den Text (erstes Zeichen nicht 'a')" ;;
    3) pr no "die Konstante zeigt auf einen anderen Text (Zeichen 5 nicht 'e')" ;;
    4) pr no "der FFI-Aufruf time() liefert nichts" ;;
    *) pr no "Programm bricht ab (rc=$RC)" ;;
  esac
else
  pr no "uebersetzt nicht nur mit der .lyu: $(grep -i error "$T/p.log" | head -2)"
fi

# 5) ZWEI SEITEN: was absichtlich NICHT beschrieben wird, laesst die Unit
#    quellpflichtig. Eine Capability-Angabe MIT Argument ist so ein Fall --
#    ginge das Argument verloren, waere die Bindung eine andere.
mkdir -p "$T/src/d5" "$T/nur/d5"
cat > "$T/src/d5/arg.lyx" <<'LYX'
unit d5.arg;
@capabilities([network.tcp.connect(host: "example.test", port: 443)])
extern fn connect(s: int64, a: int64, l: int64): int64 link "libc.so.6";
pub fn Mach(s: int64): int64 { return connect(s, 0, 0); }
LYX
if "$LYXC" --std-path="$T/src" --with-objcode --compile-unit "$T/src/d5/arg.lyx" \
       -o "$T/nur/d5/arg.lyu" > "$T/bau5.log" 2>&1; then
  I5="$("$LYXC" --unit-info "$T/nur/d5/arg.lyu" 2>&1)"
  if printf '%s' "$I5" | grep -q "extern fn connect"; then
    pr no "eine Angabe MIT Argument wurde beschrieben -- das Argument ginge verloren"
  else
    pr ok "eine Capability-Angabe mit Argument wird nicht beschrieben (bleibt quellpflichtig)"
  fi
else
  pr ok "Unit mit argumentbehafteter Angabe liefert keine Beschreibung (laut)"
fi

# 6) Der Bestand: die Methode des Issues auf die drei Wurzeln, die vorher
#    zusammen 65 der 72 Faelle trugen.
if [ -d lyx-compiler/usr/include/lyx/units/x86_64/std ]; then
  P="$ROOT/lyx-compiler/usr/include/lyx/units/x86_64"
  rest=""
  for u in std.net.dns std.cloud.cf.transport std.semarti.registry std.numeric; do
    printf 'import %s;\nfn main(): int64 { return 0; }\n' "$u" > "$T/w.lyx"
    rm -f "$T/w"
    ( cd "$T/leer" && "$LYXC" --std-path="$P" -I"$P" "$T/w.lyx" -o "$T/w" ) > "$T/w.log" 2>&1
    [ -x "$T/w" ] || rest="$rest $u"
  done
  if [ -z "$rest" ]; then
    pr ok "std.net.dns, std.cloud.cf.transport, std.semarti.registry und std.numeric uebersetzen aus dem Paketbaum"
  else
    pr no "weiter quellpflichtig:$rest"
  fi
else
  echo "SKIP 6: kein Paketbaum im Checkout"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: Capability-Angabe, pchar-Cast-Konstante und fn-Typ stehen in der .lyu (#2449)"
