#!/usr/bin/env bash
# tests/cpu_power_2400_test.sh — Governor, Boost, EPP, Taktgrenzen (#2400).
#
# Die vier Taktfelder bedeuten verschiedene Dinge und werden hier EINZELN
# gegen ihre Quelle geprueft — ein Test, der nur "eine Zahl kommt zurueck"
# prueft, waere auch von einer Fassung erfuellt, die viermal dieselbe Datei
# liest:
#
#   nominal_hz     base_frequency bzw. CPUID.16h  (Hardware-Basis)
#   allowed_min_hz scaling_min_freq
#   allowed_max_hz scaling_max_freq
#   requested_hz   scaling_cur_freq — der ANGEFORDERTE Zustand, nicht der Takt
#
# Dazu: der Boost-Zustand kommt aus zwei Quellen mit UMGEKEHRTER Bedeutung
# (intel_pstate/no_turbo vs. cpufreq/boost), und die Messbedingungen muessen
# bei zwei Abrufen ohne Aenderung gleich sein.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

cat > "$TMP/p.lyx" <<'EOF'
unit main;
import std.io;
import std.cpu.status;
import std.cpu.power;
fn z(name: pchar, t: int64): int64 {
  PrintStr(name); PrintStr("=");
  if (CpuWertDa(t) != 0) { PrintStrLn(IntToStr(CpuWert(t))); }
  else { PrintStr("STATUS:"); PrintStrLn(CpuStatusName(CpuStatus(t))); }
  return 0;
}
fn main(): int64 {
  PrintStr("treiber="); PrintStrLn(CpuTreiber(0));
  PrintStr("governor="); PrintStrLn(CpuGovernor(0));
  PrintStr("epp="); PrintStrLn(CpuEnergiePraeferenz(0));
  var b: int64 := CpuWertNeu(); CpuBoostFrei(b);           z("boost"c, b);
  PrintStr("boost_quelle="); PrintStrLn(CpuQuelle(b));
  var n: int64 := CpuWertNeu(); CpuNominalHz(0, n);        z("nominal"c, n);
  var mn: int64 := CpuWertNeu(); CpuErlaubtMinHz(0, mn);   z("min"c, mn);
  var mx: int64 := CpuWertNeu(); CpuErlaubtMaxHz(0, mx);   z("max"c, mx);
  var rq: int64 := CpuWertNeu(); CpuAngefordertHz(0, rq);  z("requested"c, rq);
  PrintStr("requested_quelle="); PrintStrLn(CpuQuelle(rq));
  // Zweiter Thread: die Dateien sind je CPU da, der Pfad muss mitwandern.
  var mx7: int64 := CpuWertNeu(); CpuErlaubtMaxHz(7, mx7); z("max7"c, mx7);
  PrintStr("max7_quelle="); PrintStrLn(CpuQuelle(mx7));
  var m1: int64 := CpuMessbedingungen(0);
  var m2: int64 := CpuMessbedingungen(0);
  PrintStr("bedingungen_gleich="); PrintLn(CpuMessbedingungenGleich(m1, m2));
  PrintStr("unterschied="); PrintStrLn(CpuMessbedingungenUnterschied(m1, m2));
  // Kuenstlich veraenderte Bedingungen muessen auffallen.
  poke64(m2 + 24, peek64(m2 + 24) + 1);
  PrintStr("verfaelscht_gleich="); PrintLn(CpuMessbedingungenGleich(m1, m2));
  PrintStr("verfaelscht_feld="); PrintStrLn(CpuMessbedingungenUnterschied(m1, m2));
  return 0;
}
EOF

if ! ( cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/b.log")"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"
AUS="$( cd "$TMP" && timeout 60 ./p 2>&1 )" || { no "laeuft" "rc=$?"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1; }
hol() { printf '%s\n' "$AUS" | sed -n "s/^$1=//p" | head -1; }
S="/sys/devices/system/cpu/cpu0/cpufreq"

[ "$(hol treiber)" = "$(cat $S/scaling_driver 2>/dev/null)" ] && ok "Treiber = $(hol treiber)" \
  || no "Treiber" "'$(hol treiber)' statt '$(cat $S/scaling_driver 2>/dev/null)'"
[ "$(hol governor)" = "$(cat $S/scaling_governor 2>/dev/null)" ] && ok "Governor = $(hol governor)" \
  || no "Governor" "'$(hol governor)'"
if [ -r "$S/energy_performance_preference" ]; then
  [ "$(hol epp)" = "$(cat $S/energy_performance_preference)" ] && ok "EPP = $(hol epp)" || no "EPP" "'$(hol epp)'"
fi

# Die drei sysfs-Taktfelder einzeln, in Hz (sysfs liefert kHz).
for p in "min:scaling_min_freq" "max:scaling_max_freq" "requested:scaling_cur_freq"; do
  n="${p%%:*}"; f="${p#*:}"
  r="$(cat $S/$f 2>/dev/null)"
  [ -z "$r" ] && { echo "HINWEIS: $f nicht lesbar"; continue; }
  v="$(hol "$n")"
  if [ "$n" = "requested" ]; then
    # scaling_cur_freq aendert sich zwischen den Abrufen; nur die Groessen-
    # ordnung pruefen, dafuer den Namen und die Quelle genau.
    if [ -n "$v" ] && [ "$v" -ge 100000000 ] && [ "$v" -le 10000000000 ]; then
      ok "requested_hz plausibel in Hz ($v)"
    else no "requested_hz" "'$v'"; fi
    case "$(hol requested_quelle)" in
      *ANGEFORDERT*) ok "requested_hz ist als ANGEFORDERT gekennzeichnet" ;;
      *) no "requested_quelle" "'$(hol requested_quelle)' nennt den Zustand nicht als angefordert" ;;
    esac
  else
    if [ "$v" = "$((r * 1000))" ]; then ok "$n = $v Hz (= $f * 1000)"; else no "$n" "'$v' statt $((r * 1000))"; fi
  fi
done

# nominal_hz: base_frequency hat Vorrang, und es ist NICHT dasselbe wie
# cpuinfo_max_freq — das ist der Punkt der Trennung.
if [ -r "$S/base_frequency" ]; then
  B="$(cat $S/base_frequency)"
  [ "$(hol nominal)" = "$((B * 1000))" ] && ok "nominal_hz = base_frequency ($((B * 1000)) Hz)" \
    || no "nominal_hz" "'$(hol nominal)' statt $((B * 1000))"
  CM="$(cat $S/cpuinfo_max_freq 2>/dev/null)"
  if [ -n "$CM" ] && [ "$B" != "$CM" ]; then
    [ "$(hol nominal)" != "$((CM * 1000))" ] && ok "nominal_hz ist nicht cpuinfo_max_freq (die beiden sind verschieden)" \
      || no "nominal_hz" "entspricht cpuinfo_max_freq — die Quellen sind vertauscht"
  fi
else
  echo "HINWEIS: base_frequency fehlt; nominal_hz kommt dann aus CPUID.16h."
fi

# Boost: Quelle und Bedeutung.
case "$(hol boost)" in
  0|1) ok "Boost-Freigabe = $(hol boost) (Quelle: $(hol boost_quelle))" ;;
  STATUS:*) echo "HINWEIS: keine Boost-Quelle auf dieser Maschine ($(hol boost))" ;;
  *) no "Boost" "'$(hol boost)'" ;;
esac
if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
  NT="$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
  ERW=1; [ "$NT" = "1" ] && ERW=0
  [ "$(hol boost)" = "$ERW" ] && ok "no_turbo=$NT wird richtig INVERTIERT gemeldet ($ERW)" \
    || no "Boost-Invertierung" "no_turbo=$NT, gemeldet $(hol boost)"
fi

# Pfad je CPU: cpu7 muss cpu7 lesen.
case "$(hol max7_quelle)" in
  *scaling_max_freq*) ok "Pfad fuer CPU 7 zeigt auf scaling_max_freq" ;;
  *) no "max7_quelle" "'$(hol max7_quelle)'" ;;
esac

[ "$(hol bedingungen_gleich)" = "1" ] && ok "zwei Abrufe ohne Aenderung sind gleich" \
  || no "Messbedingungen" "zwei unmittelbare Abrufe unterscheiden sich ('$(hol unterschied)')"
[ "$(hol verfaelscht_gleich)" = "0" ] && ok "eine geaenderte Bedingung fällt auf" \
  || no "Messbedingungen" "eine geaenderte Bedingung fiel NICHT auf"
case "$(hol verfaelscht_feld)" in
  *Governor*) ok "und das geaenderte Feld wird benannt: $(hol verfaelscht_feld)" ;;
  *) no "Unterschied" "'$(hol verfaelscht_feld)' nennt nicht den Governor" ;;
esac

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
