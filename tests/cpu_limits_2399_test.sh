#!/usr/bin/env bash
# tests/cpu_limits_2399_test.sh — Prozessgrenzen (#2399).
#
# `GetLogicalCores()` liefert die Kernzahl des RECHNERS, auch wenn der Prozess
# per taskset auf einen Thread festgenagelt ist oder in einem cgroup mit Quota
# laeuft. Geprueft wird deshalb in DREI Laeufen desselben Programms, und
# jeder Lauf prueft auch, WELCHE Grenze gemeldet wird — nicht nur die Zahl:
#
#   1. ohne Einschraenkung      -> Parallelitaet = Hardware, Grenze "hardware"
#   2. taskset -c 0,1           -> Parallelitaet 2,     Grenze "affinitaet"
#   3. systemd-run CPUQuota=150 -> Parallelitaet 2,     Grenze "cgroup-quota"
#
# Dazu die Negativprobe: ohne cgroup-Quota muss das Feld einen STATUS tragen
# und nicht die Kernzahl (das war der stille Default, vor dem #2399 warnt).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

cat > "$TMP/l.lyx" <<'EOF'
unit main;
import std.io;
import std.cpu.status;
import std.cpu.limits;
import std.systeminfo;
fn z(name: pchar, t: int64): int64 {
  PrintStr(name); PrintStr("=");
  if (CpuWertDa(t) != 0) { PrintStrLn(IntToStr(CpuWert(t))); }
  else { PrintStr("STATUS:"); PrintStrLn(CpuStatusName(CpuStatus(t))); }
  return 0;
}
fn main(): int64 {
  PrintStr("hardware="); PrintLn(GetLogicalCores());
  var a: int64 := CpuWertNeu(); CpuErlaubteCpus(a);             z("erlaubt"c, a);
  var q: int64 := CpuWertNeu(); CpuCgroupQuotaHundertstel(q);   z("quota"c, q);
  var p: int64 := CpuWertNeu(); CpuVerfuegbareParallelitaet(p); z("parallel"c, p);
  PrintStr("grenze="); PrintStrLn(CpuGrenzeName(CpuBindendeGrenze()));
  var k: int64 := CpuWertNeu(); CpuAktuellerKern(k);            z("kern"c, k);
  return 0;
}
EOF

if ! ( cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/l.lyx" -o "$TMP/l" ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/b.log")"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"

lauf() { # Praefix... -> Ausgabe in $AUS
  AUS="$( "$@" "$TMP/l" 2>&1 )"
}
hol() { printf '%s\n' "$AUS" | sed -n "s/^$1=//p" | head -1; }

# ── 1. ohne Einschraenkung ──────────────────────────────────────────────────
lauf env
HW="$(hol hardware)"
[ -n "$HW" ] && [ "$HW" -gt 0 ] && ok "Hardware-Threads: $HW" || no "hardware" "'$HW'"
[ "$(hol erlaubt)" = "$HW" ] && ok "ohne Einschraenkung: erlaubt == Hardware ($HW)" \
  || no "erlaubt" "'$(hol erlaubt)' statt $HW"
[ "$(hol parallel)" = "$HW" ] && ok "ohne Einschraenkung: Parallelitaet == $HW" \
  || no "parallel" "'$(hol parallel)'"
[ "$(hol grenze)" = "hardware" ] && ok "bindende Grenze: hardware" || no "grenze" "'$(hol grenze)'"
# Negativprobe: kein Quota -> Status, NICHT die Kernzahl.
case "$(hol quota)" in
  STATUS:*) ok "ohne Quota: $(hol quota) (keine erfundene Zahl)" ;;
  "$HW"|"$((HW * 100))") no "Quota" "meldet die Kernzahl statt eines Status — genau der stille Default aus #2399" ;;
  *) echo "HINWEIS: dieser Lauf hat ein Quota ($(hol quota) Hundertstel) — die Negativprobe entfaellt" ;;
esac

# ── 2. taskset ──────────────────────────────────────────────────────────────
if command -v taskset >/dev/null 2>&1 && [ "$HW" -ge 2 ]; then
  lauf taskset -c 0,1
  [ "$(hol erlaubt)" = "2" ] && ok "taskset -c 0,1: erlaubt = 2" || no "taskset erlaubt" "'$(hol erlaubt)'"
  [ "$(hol parallel)" = "2" ] && ok "taskset -c 0,1: Parallelitaet = 2" || no "taskset parallel" "'$(hol parallel)'"
  [ "$(hol grenze)" = "affinitaet" ] && ok "taskset: bindende Grenze = affinitaet" \
    || no "taskset grenze" "'$(hol grenze)' — die Affinitaet band, wurde aber nicht so benannt"
  # Und der Kern, auf dem es laeuft, muss in der Maske liegen.
  K="$(hol kern)"
  if [ "$K" = "0" ] || [ "$K" = "1" ]; then ok "laufender Kern ($K) liegt in der Maske"
  else no "Kern" "'$K' liegt nicht in {0,1}"; fi
else
  echo "HINWEIS: taskset fehlt oder die Maschine hat unter zwei Threads."
fi

# ── 3. cgroup-Quota ─────────────────────────────────────────────────────────
if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --quiet -p CPUQuota=150% /bin/true >/dev/null 2>&1; then
  AUS="$( systemd-run --user --quiet --pipe --wait -p CPUQuota=150% "$TMP/l" 2>&1 )"
  Q="$(hol quota)"
  if [ "$Q" = "150" ]; then ok "CPUQuota=150%: Quota = 150 Hundertstel Kerne"
  else no "Quota" "'$Q' statt 150"; fi
  [ "$(hol parallel)" = "2" ] && ok "CPUQuota=150%: Parallelitaet = 2 (1,5 aufgerundet)" \
    || no "Quota parallel" "'$(hol parallel)' statt 2"
  [ "$(hol grenze)" = "cgroup-quota" ] && ok "CPUQuota: bindende Grenze = cgroup-quota" \
    || no "Quota grenze" "'$(hol grenze)' — das Quota band, wurde aber nicht so benannt"
else
  echo "HINWEIS: systemd-run --user mit CPUQuota ist hier nicht verfuegbar —"
  echo "         der dritte Lauf (bindende Grenze = Quota) entfaellt."
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
