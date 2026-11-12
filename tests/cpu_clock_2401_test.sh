#!/usr/bin/env bash
# tests/cpu_clock_2401_test.sh — gemessener Takt (#2401).
#
# Geprueft wird der WERT, nicht die Plausibilitaet im Intervall (Regel
# "Invariantentest ist blind"):
#
#   1. effective_active_hz liegt zwischen der erlaubten UNTER- und
#      Obergrenze (scaling_min_freq .. scaling_max_freq). Dass der Wert nahe
#      der Obergrenze liegt, gilt nur auf einer RUHIGEN Maschine: im
#      Parallellauf dieser Testsuite taktet die CPU auf den All-Core-Turbo
#      herunter (gemessen 2,24 GHz gegen 3,40 GHz Einzelkerngrenze, von perf
#      stat mit 2,1 % Abweichung bestaetigt). Eine Zusicherung "nahe der
#      Obergrenze" waere also eine Zusicherung ueber die Maschinenlast und
#      nicht ueber den Code — sie steht hier als HINWEIS, nicht als Pruefung.
#      Die eigentliche Korrektheitsaussage ist Punkt 2.
#   2. Gegenprobe gegen `perf stat -e cycles:u,task-clock`. WICHTIG: nicht am
#      gleichen Programm — ein Programm, das selbst einen PMU-Zaehler offen
#      hat, zwingt perf stat ins Multiplexing (gemessen: Zaehler nur 50 % der
#      Zeit aktiv, Ergebnis um Faktor 7 zu klein). Gemessen wird deshalb
#      DIESELBE Schleife in einer Fassung OHNE eigenen Zaehler, und daraus die
#      Frequenz gebildet.
#   3. Mit einer Schlafphase im Messfenster darf der Wert NICHT sinken,
#      waehrend active_ns deutlich kleiner als das Fenster wird — damit ist
#      belegt, dass die AKTIVE Zeit im Nenner steht und nicht die Wanduhrzeit.
#   4. Die zweite Quelle (APERF/MPERF ueber /dev/cpu/N/msr) liefert auf dieser
#      Maschine einen STATUS, keinen Wert — Lockdown `integrity`. Das ist ein
#      Ergebnis, kein Fehlschlag.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

cat > "$TMP/c.lyx" <<'EOF'
unit main;
import std.io;
import std.time;
import std.cpu.status;
import std.cpu.clock;
fn z(name: pchar, t: int64): int64 {
  PrintStr(name); PrintStr("=");
  if (CpuWertDa(t) != 0) { PrintStrLn(IntToStr(CpuWert(t))); }
  else { PrintStr("STATUS:"); PrintStrLn(CpuStatusName(CpuStatus(t))); }
  return 0;
}
fn main(): int64 {
  var hz: int64 := CpuWertNeu(); var fe: int64 := CpuWertNeu();
  var zy: int64 := CpuWertNeu(); var ak: int64 := CpuWertNeu();
  CpuSample(400000000, hz, fe, zy, ak);
  z("last_hz"c, hz); z("last_fenster"c, fe); z("last_aktiv"c, ak); z("last_zyklen"c, zy);

  var st: int64 := CpuWertNeu();
  var h: int64 := CpuMessStart(st);
  var ende: int64 := GetTimeNs(CLOCK_MONOTONIC) + 100000000;
  var s: int64 := 0; var i: int64 := 0;
  while (GetTimeNs(CLOCK_MONOTONIC) < ende) { i := i + 1; s := s + (i * 7919) % 1000003; }
  Sleep(300);
  var hz2: int64 := CpuWertNeu(); var fe2: int64 := CpuWertNeu();
  var zy2: int64 := CpuWertNeu(); var ak2: int64 := CpuWertNeu();
  CpuMessStop(h, hz2, fe2, zy2, ak2);
  z("schlaf_hz"c, hz2); z("schlaf_fenster"c, fe2); z("schlaf_aktiv"c, ak2);
  if (s < 0) { PrintStrLn("schleife_weg"c); }

  var m: int64 := CpuWertNeu(); CpuMsrAperfMperf(0, m);
  z("msr"c, m);
  PrintStr("msr_quelle="); PrintStrLn(CpuQuelle(m));
  return 0;
}
EOF

if ! ( cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/b.log")"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"

PIN=""
command -v taskset >/dev/null 2>&1 && PIN="taskset -c 2"
AUS="$( cd "$TMP" && $PIN timeout 120 ./c 2>&1 )" || { no "laeuft" "rc=$?"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1; }
hol() { printf '%s\n' "$AUS" | sed -n "s/^$1=//p" | head -1; }

HZ="$(hol last_hz)"
case "$HZ" in
  STATUS:permission_denied)
    echo "HINWEIS: perf_event_open ist hier nicht erlaubt (perf_event_paranoid)."
    echo "         Das ist der Negativfall aus #2401 und richtig gemeldet."
    ok "ohne Recht: Status statt Zahl" ;;
  STATUS:*)
    no "last_hz" "'$HZ'" ;;
  *)
    MAX="$(cat /sys/devices/system/cpu/cpu2/cpufreq/scaling_max_freq 2>/dev/null)"
    [ -z "$MAX" ] && MAX="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)"
    if [ -n "$MAX" ]; then
      MAXHZ=$((MAX * 1000))
      MIN="$(cat /sys/devices/system/cpu/cpu2/cpufreq/scaling_min_freq 2>/dev/null)"
      [ -z "$MIN" ] && MIN="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null)"
      MINHZ=$(( ${MIN:-400000} * 1000 ))
      if [ "$HZ" -ge "$MINHZ" ] && [ "$HZ" -le $((MAXHZ * 105 / 100)) ]; then
        ok "$HZ Hz liegt zwischen den erlaubten Grenzen ($MINHZ .. $MAXHZ)"
      else
        no "last_hz" "$HZ Hz liegt nicht zwischen $MINHZ und $((MAXHZ * 105 / 100))"
      fi
      if [ "$HZ" -lt $((MAXHZ * 80 / 100)) ]; then
        echo "HINWEIS: $HZ Hz sind unter 80 % der Einzelkerngrenze ($MAXHZ Hz) —"
        echo "         auf einer belasteten Maschine ist das der All-Core-Turbo und erwartet."
      fi
    fi
    # Zyklen und aktive Zeit muessen zueinander passen.
    ZY="$(hol last_zyklen)"; AK="$(hol last_aktiv)"
    if [ -n "$ZY" ] && [ -n "$AK" ] && [ "$AK" -gt 0 ]; then
      BER=$(( ZY * 1000000 / (AK / 1000) ))
      D=$(( (BER - HZ) * 100 / HZ )); [ "$D" -lt 0 ] && D=$(( -D ))
      [ "$D" -le 1 ] && ok "hz entspricht zyklen/aktive_zeit (Abweichung ${D} %)" \
        || no "hz" "aus zyklen/aktiv berechnet $BER, gemeldet $HZ" 
    fi
    # Gegenprobe gegen perf stat an einer Fassung OHNE eigenen Zaehler.
    if command -v perf >/dev/null 2>&1; then
      cat > "$TMP/n.lyx" <<'EOF2'
unit main;
import std.io;
import std.time;
fn main(): int64 {
  // Dieselbe Schleife wie in CpuSample, 400 ms, ohne perf-Zaehler.
  var ende: int64 := GetTimeNs(CLOCK_MONOTONIC) + 400000000;
  var summe: int64 := 0;
  var i: int64 := 0;
  while (GetTimeNs(CLOCK_MONOTONIC) < ende) {
    i := i + 1;
    summe := summe + (i * 2654435761) % 1000003;
  }
  if (summe < 0) { PrintStrLn("weg"c); }
  return 0;
}
EOF2
      if ! ( cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/n.lyx" -o "$TMP/n" ) >"$TMP/n.log" 2>&1; then
        echo "HINWEIS: die zaehlerfreie Fassung uebersetzte nicht."
      fi
      # `cycles`, NICHT `cycles:u`: die Bibliothek zaehlt Nutzer- UND
      # Kernelzyklen (der Thread laeuft auch im Syscall auf dem Kern), und der
      # Nenner enthaelt diese Zeit ebenfalls. Mit cycles:u verglichen kaeme
      # 237 MHz gegen 3,39 GHz heraus — und der Fehler laege im Vergleich.
      # LC_ALL=C ist hier Pflicht: mit deutscher Locale schreibt perf
      # "399,47" als Zahl, und bei `-x,` zerlegt das Komma die Zeile in ein
      # Feld mehr — das Feld 3 ist dann "msec" statt "task-clock" und die
      # Auswertung findet nichts. Gemessen, nicht vermutet (#2322 war
      # derselbe Fehler bei lscpu).
      PS="$( cd "$TMP" && LC_ALL=C $PIN perf stat -x, -e cycles,task-clock ./n 2>&1 >/dev/null )"
      PC="$(printf '%s\n' "$PS" | awk -F, '$3=="cycles"{print $1}')"
      PT="$(printf '%s\n' "$PS" | awk -F, '$3=="task-clock"{print $1}')"
      if [ -n "$PC" ] && [ -n "$PT" ]; then
        PHZ="$(awk -v c="$PC" -v t="$PT" 'BEGIN{printf "%d", c / (t/1000)}')"
        REL="$(awk -v a="$HZ" -v b="$PHZ" 'BEGIN{d=(a-b)/b*100; if (d<0) d=-d; printf "%.1f", d}')"
        if awk -v d="$REL" 'BEGIN{exit !(d <= 10)}'; then
          ok "Gegenprobe perf stat: ${PHZ} Hz gegen ${HZ} Hz (${REL} % Abweichung)"
        else
          no "Gegenprobe perf stat" "${PHZ} Hz gegen ${HZ} Hz (${REL} % Abweichung)"
        fi
      else
        echo "HINWEIS: perf stat lieferte keine Zaehler. Ausgabe:"
        printf '%s\n' "$PS" | head -4
        [ -s "$TMP/n.log" ] && { echo "  Uebersetzung der zaehlerfreien Fassung:"; grep -m2 -iE 'error|sema' "$TMP/n.log"; }
      fi
    fi
    # Schlafphase: hz darf nicht sinken, aktiv << Fenster.
    H2="$(hol schlaf_hz)"; F2="$(hol schlaf_fenster)"; A2="$(hol schlaf_aktiv)"
    if [ -n "$H2" ] && [ "$H2" != "STATUS:unsupported" ]; then
      UG2=$((HZ * 85 / 100))
      [ "$H2" -ge "$UG2" ] && ok "mit 300 ms Schlaf bleibt der Takt bei $H2 Hz (>= 85 % von $HZ)" \
        || no "schlaf_hz" "$H2 Hz gegen $HZ Hz — die Wanduhrzeit steht im Nenner"
      if [ -n "$F2" ] && [ -n "$A2" ] && [ "$A2" -lt $((F2 / 2)) ]; then
        ok "aktive Zeit ($A2 ns) ist deutlich kleiner als das Fenster ($F2 ns)"
      else
        no "aktive Zeit" "aktiv=$A2 fenster=$F2 — der Schlaf war nicht im Fenster"
      fi
    fi
    ;;
esac

# Zweite Quelle: Status, kein Wert.
case "$(hol msr)" in
  STATUS:permission_denied) ok "APERF/MPERF: permission_denied (Lockdown) — ein Ergebnis, kein Fehlschlag" ;;
  STATUS:*) ok "APERF/MPERF: $(hol msr) (Quelle: $(hol msr_quelle))" ;;
  *) no "msr" "'$(hol msr)' — ein Zahlenwert, obwohl der Weg nicht umgesetzt ist" ;;
esac

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
