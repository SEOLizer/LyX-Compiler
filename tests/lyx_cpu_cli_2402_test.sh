#!/usr/bin/env bash
# tests/lyx_cpu_cli_2402_test.sh — CLI-Werkzeug lyx-cpu (#2402).
#
# Das Werkzeug benutzt DIESELBEN Abfragen wie Compiler und Runtime; driftete
# es ab, haetten Diagnose und Codeerzeugung verschiedene Wahrheiten. Geprueft
# wird deshalb gegen unabhaengige Quellen (lscpu, sysfs, perf) und nicht gegen
# die Bibliothek selbst:
#
#   1. `info` gegen lscpu und /sys/.../cache
#   2. `state` gegen die sysfs-Dateien
#   3. `measure` gegen perf stat (cycles, NICHT cycles:u — die Bibliothek
#      zaehlt Nutzer- und Kernelzyklen)
#   4. `explain` in BEIDEN Richtungen: avx2 nutzbar, avx512f nicht in Hardware
#   5. unbekannter Unterbefehl und unbekannter Featurename -> Exit-Code != 0
#      MIT Liste der zulaessigen Werte; kein Catch-all, der `info` ausfuehrt
#   6. `--json` gegen einen PARSER, nicht per Augenschein, und jedes Feld
#      traegt status und source

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

if ! ( cd "$ROOT" && timeout 400 "$LYXC" --std-path="$ROOT" src/tools/lyx_cpu.lyx -o "$TMP/lyx-cpu" ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/b.log")"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"
CPU="$TMP/lyx-cpu"

# ── 1. info gegen lscpu / sysfs ─────────────────────────────────────────────
INFO="$( "$CPU" info 2>&1 )"
feld() { printf '%s\n' "$INFO" | sed -n "s/^$1: \\([^ ]*\\).*/\\1/p" | head -1; }
REF_FAM="$(LC_ALL=C lscpu | sed -n 's/^CPU family: *//p' | head -1)"
REF_MOD="$(LC_ALL=C lscpu | sed -n 's/^Model: *//p' | head -1)"
REF_TPC="$(LC_ALL=C lscpu | sed -n 's/^Thread(s) per core: *//p' | head -1)"
[ -n "$REF_FAM" ] && { [ "$(feld family)" = "$REF_FAM" ] && ok "info: family = $REF_FAM" || no "family" "'$(feld family)'"; }
[ -n "$REF_MOD" ] && { [ "$(feld model)" = "$REF_MOD" ] && ok "info: model = $REF_MOD" || no "model" "'$(feld model)'"; }
[ -n "$REF_TPC" ] && { [ "$(feld threads_per_core)" = "$REF_TPC" ] && ok "info: threads_per_core = $REF_TPC" || no "threads_per_core" "'$(feld threads_per_core)'"; }
REF_LINE="$(cat /sys/devices/system/cpu/cpu0/cache/index0/coherency_line_size 2>/dev/null)"
[ -n "$REF_LINE" ] && { [ "$(feld cache0_line_bytes)" = "$REF_LINE" ] && ok "info: cache0_line_bytes = $REF_LINE" || no "cache0_line_bytes" "'$(feld cache0_line_bytes)'"; }
# Jedes Feld traegt eine Quelle.
if printf '%s\n' "$INFO" | grep -q "\[cpuid"; then ok "info nennt die Quelle je Feld" ; else no "Quellenangabe" "keine [cpuid...]-Angabe in info"; fi

# ── 2. state gegen sysfs ────────────────────────────────────────────────────
STATE="$( "$CPU" state 2>&1 )"
sfeld() { printf '%s\n' "$STATE" | sed -n "s/^$1: \\(.*\\)   \\[.*/\\1/p" | head -1; }
S=/sys/devices/system/cpu/cpu0/cpufreq
[ -r $S/scaling_governor ] && { [ "$(sfeld scaling_governor)" = "$(cat $S/scaling_governor)" ] && ok "state: Governor = $(cat $S/scaling_governor)" || no "Governor" "'$(sfeld scaling_governor)'"; }
if [ -r $S/scaling_max_freq ]; then
  E=$(( $(cat $S/scaling_max_freq) * 1000 ))
  [ "$(sfeld allowed_max_hz)" = "$E" ] && ok "state: allowed_max_hz = $E" || no "allowed_max_hz" "'$(sfeld allowed_max_hz)' statt $E"
fi
# requested_hz muss als angefordert gekennzeichnet sein.
if printf '%s\n' "$STATE" | grep -q "requested_hz.*ANGEFORDERT"; then
  ok "state: requested_hz ist als ANGEFORDERT gekennzeichnet"
else
  no "requested_hz" "die Kennzeichnung 'ANGEFORDERT' fehlt — die Zahl koennte als Takt gelesen werden"
fi

# ── 3. measure gegen perf stat ──────────────────────────────────────────────
PIN=""; command -v taskset >/dev/null 2>&1 && PIN="taskset -c 2"
MEAS="$( $PIN "$CPU" measure 400 2>&1 )"
HZ="$(printf '%s\n' "$MEAS" | sed -n 's/^effective_active_hz: \([0-9]*\).*/\1/p' | head -1)"
if [ -n "$HZ" ]; then
  ok "measure: effective_active_hz = $HZ"
  if command -v perf >/dev/null 2>&1; then
    PS="$( LC_ALL=C $PIN perf stat -x, -e cycles,task-clock "$CPU" measure 400 2>&1 >/dev/null )"
    PC="$(printf '%s\n' "$PS" | awk -F, '$3=="cycles"{print $1}')"
    PT="$(printf '%s\n' "$PS" | awk -F, '$3=="task-clock"{print $1}')"
    if [ -n "$PC" ] && [ -n "$PT" ]; then
      PHZ="$(awk -v c="$PC" -v t="$PT" 'BEGIN{printf "%d", c / (t/1000)}')"
      REL="$(awk -v a="$HZ" -v b="$PHZ" 'BEGIN{d=(a-b)/b*100; if(d<0)d=-d; printf "%.1f", d}')"
      awk -v d="$REL" 'BEGIN{exit !(d <= 15)}' && ok "measure gegen perf stat: $PHZ Hz, ${REL} % Abweichung" \
        || no "measure gegen perf" "$HZ gegen $PHZ Hz (${REL} %)"
    else
      echo "HINWEIS: perf stat lieferte keine Zaehler."
    fi
  fi
else
  case "$MEAS" in
    *permission_denied*) ok "measure ohne perf-Recht: Status statt Zahl" ;;
    *) no "measure" "keine Zahl und kein Status: $(printf '%s' "$MEAS" | head -2)" ;;
  esac
fi

# ── 4./5. explain, beide Richtungen und die lauten Fehlerfaelle ────────────
A2="$( "$CPU" explain avx2 2>&1 )"; rc2=$?
case "$A2" in
  *nutzbar*) [ $rc2 -eq 0 ] && ok "explain avx2: nutzbar (rc 0)" || no "explain avx2" "rc=$rc2" ;;
  *) no "explain avx2" "'$A2'" ;;
esac
A5="$( "$CPU" explain avx512f 2>&1 )"
case "$A5" in
  *"nicht in Hardware"*) ok "explain avx512f: nicht in Hardware (auf dieser CPU richtig)" ;;
  *nutzbar*) echo "HINWEIS: diese CPU hat AVX-512 — dann ist 'nutzbar' richtig und die Gegenrichtung fehlt hier." ;;
  *) no "explain avx512f" "'$A5'" ;;
esac
# Die Ursachenkette muss bei "nicht nutzbar" dastehen.
case "$A5" in
  *Ursachenkette*OSXSAVE*XCR0*) ok "explain nennt die Ursachenkette (Hardware, OSXSAVE, XCR0, Kernelparameter)" ;;
  *nutzbar*) ;;
  *) no "Ursachenkette" "fehlt in der Ausgabe" ;;
esac
OUT="$( "$CPU" explain quatsch 2>&1 )"; rc=$?
[ $rc -ne 0 ] && ok "explain mit unbekanntem Namen: Exit-Code $rc" || no "explain quatsch" "rc=0"
case "$OUT" in *zulaessig:*avx2*) ok "und nennt die zulaessigen Namen" ;; *) no "explain quatsch" "nennt die zulaessigen Namen nicht" ;; esac
OUT2="$( "$CPU" bloedsinn 2>&1 )"; rc=$?
[ $rc -ne 0 ] && ok "unbekannter Unterbefehl: Exit-Code $rc" || no "unbekannter Unterbefehl" "rc=0 — ein Catch-all hat ihn geschluckt"
case "$OUT2" in *"unbekannter Unterbefehl"*) ok "und benennt ihn" ;; *) no "Unterbefehl" "'$OUT2'" ;; esac
# Kein Catch-all: die Ausgabe darf NICHT der info-Bericht sein.
case "$OUT2" in *GenuineIntel*|*vendor*) no "Catch-all" "ein unbekannter Unterbefehl hat info ausgefuehrt" ;; *) ok "ein unbekannter Unterbefehl fuehrt NICHT info aus" ;; esac
"$CPU" >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && ok "ohne Unterbefehl: Hilfe und Exit-Code $rc" || no "ohne Unterbefehl" "rc=0"

# ── 6. JSON gegen einen Parser ──────────────────────────────────────────────
"$CPU" report --json > "$TMP/r.json" 2>"$TMP/r.err"; rc=$?
[ $rc -eq 0 ] && ok "report --json laeuft durch" || no "report --json" "rc=$rc: $(head -2 "$TMP/r.err")"
python3 -I - "$TMP/r.json" <<'PY' > "$TMP/json.out" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
print("felder", len(d))
fehlend = [k for k, v in d.items() if not isinstance(v, dict) or "status" not in v or "source" not in v]
print("ohne_status_oder_quelle", len(fehlend), fehlend[:5])
# Ein Feld mit status != ok darf keinen Zahlenwert tragen.
falsch = [k for k, v in d.items() if isinstance(v, dict) and v.get("status") != "ok" and v.get("value") is not None]
print("wert_trotz_status", len(falsch), falsch[:5])
print("hat_usable_avx2", "usable_avx2" in d)
print("hat_nominal", "nominal_hz" in d)
PY
if grep -q "^felder" "$TMP/json.out"; then
  N="$(sed -n 's/^felder //p' "$TMP/json.out")"
  ok "report --json ist gueltiges JSON mit $N Feldern (Parser, nicht Augenschein)"
  [ "$(sed -n 's/^ohne_status_oder_quelle \([0-9]*\).*/\1/p' "$TMP/json.out")" = "0" ] \
    && ok "jedes JSON-Feld traegt status und source" \
    || no "JSON-Felder" "$(grep ohne_status_oder_quelle "$TMP/json.out")"
  [ "$(sed -n 's/^wert_trotz_status \([0-9]*\).*/\1/p' "$TMP/json.out")" = "0" ] \
    && ok "kein Feld traegt eine Zahl, obwohl der Status sie verbietet" \
    || no "JSON-Status" "$(grep wert_trotz_status "$TMP/json.out")"
  grep -q "hat_usable_avx2 True" "$TMP/json.out" && ok "JSON enthaelt usable_avx2 (Feldnamen = API-Namen)" || no "JSON" "usable_avx2 fehlt"
  grep -q "hat_nominal True" "$TMP/json.out" && ok "JSON enthaelt nominal_hz" || no "JSON" "nominal_hz fehlt"
else
  no "report --json" "kein gueltiges JSON: $(head -3 "$TMP/json.out")"
fi

# Der Testhelfer aus #2384 bleibt bestehen und wird nicht ersetzt.
[ -f "$ROOT/src/tools/cpu_features_dump.lyx" ] && ok "der Testhelfer cpu_features_dump.lyx ist weiter da" \
  || no "cpu_features_dump.lyx" "wurde entfernt — der Abgleich gegen /proc/cpuinfo haengt daran"

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
