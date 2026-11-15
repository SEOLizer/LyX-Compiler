#!/bin/bash
# #2524: lyxc liess sich nicht fuer --target=lyxos uebersetzen.
#
# src/herkunft.lyx loest einen offenen Deskriptor ueber /proc/self/fd auf. Das
# ist linuxeigen; LyxOS hat kein procfs und kein readlink. Der Aufruf wurde
# aber fuer JEDES Ziel mitgesenkt, und Builtin-ID 40 (sys_readlink) zeigt in
# emit_lyxos auf die Entwurfsnummer 0x0214 = 532, die im Kernel nicht belegt
# ist. Der Selbstbau brach deshalb ab -- zu Recht: eine erfundene Nummer
# meldet auf LyxOS stillen Erfolg mit 0 Byte (.r3_unknown), und die
# Herkunftspruefung haette mit einem leeren Puffer weitergearbeitet.
#
# GEMESSEN WIRD BEIDES:
#   * src.herkunft laesst sich fuer lyxos senken (vorher nicht),
#   * der LINUX-Weg loest weiter wirklich kanonisch auf (sonst waere die
#     Vertrauenspruefung aus #2202 stillschweigend abgeschaltet -- ein
#     Uebersetzungserfolg allein belegt das NICHT).
cd "$(dirname "$0")/.." || exit 1
P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }

LYXC="${LYXC:-./lyxc}"   # Gegenprobe NUR im alten BAUM: die Aenderung liegt in src/
if [ ! -x "$LYXC" ]; then echo "SKIP: ./lyxc fehlt"; exit 0; fi
# #1294: Ressourcengrenze um jeden lyxc-Aufruf (tests/lyxc_guard_coverage_test.sh wacht).
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# 1) Ein Programm, das HerkunftKanonisch aufruft, muss sich fuer lyxos
#    EMITTIEREN lassen. Nicht `--compile-unit`: das Gate sitzt in
#    emit_lyxos (Nummernpruefung, #1734) und wird beim Vorkompilieren einer
#    Unit gar nicht erreicht -- ein Test darauf waere vor dem Fix gruen
#    gewesen und haette nichts gemessen.
cat > "$T/ruf.lyx" <<'EOF'
import src.herkunft;
import src.std.io;
import src.std.alloc;

fn main(): int64 {
  var b: int64 := alloc(4096);
  var n: int64 := HerkunftKanonisch(1, b, 4096);
  if (n <= 0) { return 1; }
  return 0;
}
EOF
"$LYXC" "$T/ruf.lyx" --std-path=. -I src --target=lyxos -o "$T/ruf.lbf" \
    > "$T/lyxos.log" 2>&1
if [ $? -eq 0 ]; then
  ok "ein Aufrufer von HerkunftKanonisch laesst sich fuer lyxos emittieren"
else
  bad "lyxos-Emission" "$(grep -m1 -E 'error:|lyxc:' "$T/lyxos.log")"
fi

# 2) Und zwar ohne dass der zielfremde Aufruf nur anders numeriert wurde:
#    die Meldung von damals darf in keiner Fassung wiederkehren.
if grep -q "Builtin-ID 40" "$T/lyxos.log"; then
  bad "Builtin 40" "sys_readlink kommt weiter in den lyxos-Befehlsstrom"
else
  ok "sys_readlink kommt nicht mehr in den lyxos-Befehlsstrom"
fi

# 3) Die Ziele, die procfs haben, bleiben unberuehrt.
for z in x86_64 arm64; do
  "$LYXC" --std-path=. -I src --target="$z" --compile-unit src/herkunft.lyx \
      -o "$T/h_$z.lyu" > "$T/$z.log" 2>&1
  if [ $? -eq 0 ]; then
    ok "$z: src/herkunft.lyx unveraendert uebersetzbar"
  else
    bad "$z" "$(grep -m1 -E 'error:|lyxc:' "$T/$z.log")"
  fi
done

# 4) WIRKUNG auf Linux, nicht bloss Uebersetzbarkeit: der kanonische Pfad muss
#    weiter herauskommen. Ein Test, der nur das Uebersetzen prueft, waere auch
#    von einem HerkunftKanonisch erfuellt, das ueberall -1 liefert -- und damit
#    haette #2524 die Vertrauenspruefung aus #2202 abgeschaltet.
cat > "$T/hk.lyx" <<'EOF'
import src.herkunft;
import src.std.io;
import src.std.alloc;

fn main(): int64 {
  var fd: int64 := open("Makefile"c, 0, 0);
  if (fd < 0) { PrintStrLn("OPENFAIL"c); return 1; }
  var b: int64 := alloc(4096);
  var n: int64 := HerkunftKanonisch(fd, b, 4096);
  close(fd);
  if (n <= 0) { PrintStrLn("KANON=-1"c); return 2; }
  PrintStr("KANON="c); PrintStrLn(b as pchar);
  return 0;
}
EOF
if "$LYXC" "$T/hk.lyx" --std-path=. -I src -o "$T/hk" > "$T/hk_bau.log" 2>&1; then
  AUS="$("$T/hk" 2>&1)"
  case "$AUS" in
    KANON=/*Makefile)
      ok "Linux: HerkunftKanonisch liefert weiter den absoluten Pfad"
      ;;
    KANON=-1)
      bad "Linux-Wirkung" "HerkunftKanonisch liefert -1 -- Vertrauenspruefung waere abgeschaltet"
      ;;
    *)
      bad "Linux-Wirkung" "unerwartete Ausgabe: $AUS"
      ;;
  esac
else
  bad "Linux-Wirkung" "Probe uebersetzt nicht: $(grep -m1 -E 'error' "$T/hk_bau.log")"
fi

# 5) Gegenseite: fail-closed bleibt fail-closed. Ein Deskriptor, den es nicht
#    gibt, darf keinen Pfad ergeben -- sonst waere aus der Weiche ein stiller
#    Default geworden.
cat > "$T/hk2.lyx" <<'EOF'
import src.herkunft;
import src.std.io;
import src.std.alloc;

fn main(): int64 {
  var b: int64 := alloc(4096);
  var n: int64 := HerkunftKanonisch(0 - 5, b, 4096);
  if (n == 0 - 1) { PrintStrLn("ZU"c); return 0; }
  PrintStrLn("OFFEN"c);
  return 1;
}
EOF
if "$LYXC" "$T/hk2.lyx" --std-path=. -I src -o "$T/hk2" > "$T/hk2_bau.log" 2>&1; then
  if [ "$("$T/hk2" 2>&1)" = "ZU" ]; then
    ok "ungueltiger Deskriptor bleibt fail-closed (-1)"
  else
    bad "fail-closed" "ein ungueltiger Deskriptor ergab einen Pfad"
  fi
else
  bad "fail-closed" "Probe uebersetzt nicht"
fi

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "OK: Ziel ohne procfs senkt kein readlink, Linux-Weg unveraendert (#2524)"
