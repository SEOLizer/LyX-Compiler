#!/usr/bin/env bash
# tests/cpu_describe_2397_test.sh — Statusmodell, Identitaet, Topologie, Caches (#2397).
#
# Jede Abfrage im Bestand gab eine nackte Ganzzahl zurueck, und "unbekannt"
# war davon nicht unterscheidbar (0 oder -1 im Bericht). Geprueft wird hier
# deshalb BEIDES: die WERTE gegen unabhaengige Quellen (lscpu, sysfs) UND das
# Statusmodell, also dass ein fehlender Wert als Status erscheint und nicht
# als Zahl.
#
# Werte, nicht Vorhandensein (Regel "Invariantentest ist blind"): auf dem
# i5-8250U sind das 2 Threads je Kern, 4 Kerne, L1d 32768, L2 262144,
# L3 6291456, Zeilenlaenge 64 — jeweils gegen /sys/.../cache/index*/ bzw.
# lscpu gegengelesen, nicht gegen fest eingetragene Zahlen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

cat > "$TMP/d.lyx" <<'EOF'
unit main;
import std.io;
import std.cpu.status;
import std.cpu.identity;
import std.cpu.topology;
import std.cpu.cache;

fn z(name: pchar, t: int64): int64 {
  PrintStr(name); PrintStr("=");
  if (CpuWertDa(t) != 0) { PrintStrLn(IntToStr(CpuWert(t))); }
  else { PrintStr("STATUS:"); PrintStrLn(CpuStatusName(CpuStatus(t))); }
  return 0;
}

fn main(): int64 {
  // Statusmodell: ein frischer Traeger ist NICHT 0, sondern not_implemented.
  var f: int64 := CpuWertNeu();
  PrintStr("frisch="); PrintStrLn(CpuStatusName(CpuStatus(f)));
  PrintStr("frisch_da="); PrintLn(CpuWertDa(f));
  PrintStr("frisch_oder="); PrintLn(CpuWertOder(f, 0 - 7));
  CpuWertFehlt(f, CPU_ST_PERMISSION_DENIED, "probe"c);
  PrintStr("verweigert="); PrintStrLn(CpuStatusName(CpuStatus(f)));
  PrintStr("errno13="); PrintStrLn(CpuStatusName(CpuStatusAusErrno(0 - 13)));
  PrintStr("errno2="); PrintStrLn(CpuStatusName(CpuStatusAusErrno(0 - 2)));
  PrintStr("errno99="); PrintStrLn(CpuStatusName(CpuStatusAusErrno(0 - 99)));

  PrintStr("vendor="); PrintStrLn(CpuVendor());
  PrintStr("brand="); PrintStrLn(CpuMarkenname());
  PrintStr("familie="); PrintLn(CpuFamilie());
  PrintStr("modell="); PrintLn(CpuModell());
  PrintStr("stepping="); PrintLn(CpuStepping());
  var ua: int64 := CpuWertNeu(); CpuMikroarchitektur(ua);
  PrintStr("uarch_status="); PrintStrLn(CpuStatusName(CpuStatus(ua)));
  PrintStr("uarch="); PrintStrLn(CpuQuelle(ua));

  var a: int64 := CpuWertNeu(); CpuThreadsJeKern(a);  z("threads_je_kern"c, a);
  var b: int64 := CpuWertNeu(); CpuThreadsJePaket(b); z("threads_je_paket"c, b);
  var c: int64 := CpuWertNeu(); CpuKerneJePaket(c);   z("kerne"c, c);
  var h: int64 := CpuWertNeu(); CpuIstHybrid(h);      z("hybrid"c, h);
  var k: int64 := CpuWertNeu(); CpuKerntyp(k);        z("kerntyp"c, k);

  PrintStr("cache_anzahl="); PrintLn(CpuCacheAnzahl());
  var zl: int64 := CpuWertNeu(); CpuZeilenlaenge(zl); z("l1d_zeile"c, zl);
  var l1: int64 := CpuWertNeu(); CpuCacheGroesseEbene(1, l1); z("l1_groesse"c, l1);
  var l2: int64 := CpuWertNeu(); CpuCacheGroesseEbene(2, l2); z("l2_groesse"c, l2);
  var l3: int64 := CpuWertNeu(); CpuCacheGroesseEbene(3, l3); z("l3_groesse"c, l3);
  var l9: int64 := CpuWertNeu(); CpuCacheGroesseEbene(9, l9); z("l9_groesse"c, l9);
  var cx: int64 := CpuWertNeu(); CpuCacheGroesse(99, cx);     z("cache99"c, cx);
  return 0;
}
EOF

if ! ( cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/d.lyx" -o "$TMP/d" ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/b.log")"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"
AUS="$( cd "$TMP" && timeout 60 ./d 2>&1 )" || { no "laeuft" "rc=$?"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1; }
hol() { printf '%s\n' "$AUS" | sed -n "s/^$1=//p" | head -1; }

# ── Statusmodell ────────────────────────────────────────────────────────────
[ "$(hol frisch)" = "not_implemented" ] && ok "frischer Traeger meldet not_implemented, nicht 0" \
  || no "frischer Traeger" "'$(hol frisch)'"
[ "$(hol frisch_da)" = "0" ] && ok "CpuWertDa() = 0 ohne Wert" || no "CpuWertDa" "'$(hol frisch_da)'"
[ "$(hol frisch_oder)" = "-7" ] && ok "CpuWertOder() gibt den ausdruecklichen Ersatz" \
  || no "CpuWertOder" "'$(hol frisch_oder)'"
[ "$(hol verweigert)" = "permission_denied" ] && ok "CpuWertFehlt tragt den Status" \
  || no "CpuWertFehlt" "'$(hol verweigert)'"
[ "$(hol errno13)" = "permission_denied" ] && ok "EACCES -> permission_denied" || no "errno13" "'$(hol errno13)'"
[ "$(hol errno2)" = "unsupported" ] && ok "ENOENT -> unsupported" || no "errno2" "'$(hol errno2)'"
# Ein UNBEKANNTER Fehler darf nicht als bekannter Zustand erscheinen.
[ "$(hol errno99)" = "not_implemented" ] && ok "unbekanntes errno bleibt not_implemented" \
  || no "errno99" "'$(hol errno99)' — ein unbekannter Fehler wurde als bekannter Zustand gedeutet"

# ── Identitaet gegen lscpu ──────────────────────────────────────────────────
REF_VENDOR="$(LC_ALL=C lscpu | sed -n 's/^Vendor ID: *//p' | head -1)"
REF_FAM="$(LC_ALL=C lscpu | sed -n 's/^CPU family: *//p' | head -1)"
REF_MOD="$(LC_ALL=C lscpu | sed -n 's/^Model: *//p' | head -1)"
REF_STEP="$(LC_ALL=C lscpu | sed -n 's/^Stepping: *//p' | head -1)"
REF_NAME="$(grep -m1 'model name' /proc/cpuinfo | sed 's/^model name[^:]*: *//')"
for p in "vendor:$REF_VENDOR" "familie:$REF_FAM" "modell:$REF_MOD" "stepping:$REF_STEP" "brand:$REF_NAME"; do
  n="${p%%:*}"; w="${p#*:}"
  if [ -z "$w" ]; then echo "HINWEIS: keine Referenz fuer $n"; continue; fi
  # Beide Seiten ohne Rand-Leerzeichen vergleichen: der Markenname aus CPUID
  # ist herstellerabhaengig links oder rechts aufgefuellt (Intel vorn, AMD
  # hinten), /proc/cpuinfo liefert ihn schon beschnitten.
  ist="$(printf '%s' "$(hol "$n")" | sed 's/^ *//; s/ *$//')"
  soll="$(printf '%s' "$w" | sed 's/^ *//; s/ *$//')"
  if [ "$ist" = "$soll" ]; then ok "$n = '$soll' (gegen lscpu/proc)"; else no "$n" "'$ist' statt '$soll'"; fi
done
[ "$(hol uarch_status)" = "ok" ] && ok "Mikroarchitektur erkannt: $(hol uarch)" \
  || echo "HINWEIS: Mikroarchitektur nicht in der Tabelle ($(hol uarch_status)) — der Default-Zweig scheitert damit richtig laut"

# ── Topologie gegen lscpu ───────────────────────────────────────────────────
REF_TPC="$(LC_ALL=C lscpu | sed -n 's/^Thread(s) per core: *//p' | head -1)"
REF_CPS="$(LC_ALL=C lscpu | sed -n 's/^Core(s) per socket: *//p' | head -1)"
# Threads je Kern kommt aus der x2APIC-Topologie (CPUID.0xB). Fehlt das Blatt
# — auf dem CI-Laeufer EPYC 7763 in der VM ist es so —, meldet die Bibliothek
# STATUS:unsupported, und das ist die richtige Antwort und keine erfundene
# Zahl. Geprueft wird deshalb: entweder die Zahl stimmt mit lscpu, oder es
# steht ein STATUS da. Eine 0 oder ein leerer Wert faellt weiterhin durch.
TPC_IST="$(hol threads_je_kern)"
case "$TPC_IST" in
  STATUS:*)
    echo "HINWEIS: threads_je_kern = $TPC_IST — CPUID.0xB fehlt (VM);"
    echo "         lscpu sagt ${REF_TPC:-?}. Siehe #2413 (AMD-Herkunft 0x8000001E fehlt)."
    ok "threads_je_kern meldet einen Status statt einer erfundenen Zahl" ;;
  *)
    if [ -n "$REF_TPC" ]; then
      [ "$TPC_IST" = "$REF_TPC" ] && ok "threads_je_kern = $REF_TPC" \
        || no "threads_je_kern" "'$TPC_IST' statt $REF_TPC"
    fi ;;
esac
# Kerne je Paket: die Zahl kommt aus der x2APIC-Topologie (CPUID.0xB) und ist
# die HARDWARE-Sicht. In einer VM beschreibt CPUID die Topologie des WIRTS,
# waehrend lscpu zaehlt, was der Gast sieht — gemessen auf dem CI-Laeufer
# (EPYC 9V45, 4 vCPUs): CPUID 16 Threads je Paket, also 8 Kerne; lscpu sagt
# 2 Kerne je Sockel. Beides ist richtig, es sind verschiedene Fragen.
#
# Geprueft wird deshalb die INNERE Stimmigkeit (Threads je Paket = Kerne *
# Threads je Kern) — die gilt immer — und der Abgleich mit lscpu nur dort, wo
# der Gast die ganze Maschine sieht.
TJP="$(hol threads_je_paket)"; TJK="$(hol threads_je_kern)"; KER="$(hol kerne)"
# Jede der drei Zahlen kann ein STATUS sein; dann ist die Rechnung nicht
# anwendbar (und `[ "$TJK" -gt 0 ]` wuerde mit einem Syntaxfehler abbrechen).
ist_zahl() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
if ist_zahl "$TJP" && ist_zahl "$TJK" && ist_zahl "$KER" && [ "$TJK" -gt 0 ]; then
  if [ $(( KER * TJK )) = "$TJP" ]; then
    ok "innere Stimmigkeit: $KER Kerne x $TJK Threads = $TJP Threads je Paket"
  else
    no "Topologie" "$KER x $TJK != $TJP — die drei Zahlen passen nicht zueinander"
  fi
fi
REF_SOCK="$(LC_ALL=C lscpu | sed -n 's/^Socket(s): *//p' | head -1)"
REF_LOG="$(LC_ALL=C lscpu | sed -n 's/^CPU(s): *//p' | head -1)"
if [ -n "$REF_CPS" ] && [ -n "$REF_SOCK" ] && [ -n "$REF_LOG" ] && ist_zahl "$TJP"; then
  if [ $(( REF_SOCK * TJP )) = "$REF_LOG" ]; then
    [ "$KER" = "$REF_CPS" ] && ok "kerne_je_paket = $REF_CPS (gegen lscpu)" \
      || no "kerne" "'$KER' statt $REF_CPS"
  else
    echo "HINWEIS: CPUID beschreibt $TJP Threads je Paket, der Gast sieht $REF_LOG"
    echo "         bei $REF_SOCK Sockel — eine VM mit beschnittener Topologie."
    echo "         Der Abgleich mit lscpu entfaellt, die innere Stimmigkeit gilt."
  fi
fi

# ── Caches gegen sysfs ──────────────────────────────────────────────────────
sysfsgr() { # Ebene Typ -> Groesse in Byte
  for d in /sys/devices/system/cpu/cpu0/cache/index*/; do
    [ "$(cat "$d/level" 2>/dev/null)" = "$1" ] || continue
    t="$(cat "$d/type" 2>/dev/null)"
    [ "$t" = "$2" ] || [ "$t" = "Unified" ] || continue
    s="$(cat "$d/size" 2>/dev/null)"
    case "$s" in *K) echo $(( ${s%K} * 1024 ));; *M) echo $(( ${s%M} * 1048576 ));; *) echo "${s%%[!0-9]*}";; esac
    return
  done
}
REF_LINE="$(cat /sys/devices/system/cpu/cpu0/cache/index0/coherency_line_size 2>/dev/null)"
[ -n "$REF_LINE" ] && { [ "$(hol l1d_zeile)" = "$REF_LINE" ] && ok "Zeilenlaenge = $REF_LINE (sysfs)" || no "Zeilenlaenge" "'$(hol l1d_zeile)' statt $REF_LINE"; }
for lvl in 1 2 3; do
  r="$(sysfsgr $lvl Data)"
  [ -z "$r" ] && continue
  v="$(hol l${lvl}_groesse)"
  if [ "$v" = "$r" ]; then ok "L$lvl = $r Byte (sysfs)"; else no "L$lvl" "'$v' statt $r"; fi
done

# ── Die Gegenseite: nicht vorhandene Angaben sind Status, nicht Zahl ────────
case "$(hol l9_groesse)" in
  STATUS:*) ok "Ebene 9 gibt es nicht -> $(hol l9_groesse)" ;;
  *) no "Ebene 9" "'$(hol l9_groesse)' — eine erfundene Zahl statt eines Status" ;;
esac
case "$(hol cache99)" in
  STATUS:*) ok "Unterblatt 99 gibt es nicht -> $(hol cache99)" ;;
  *) no "Unterblatt 99" "'$(hol cache99)'" ;;
esac
case "$(hol kerntyp)" in
  STATUS:*|[0-9]*) ok "Kerntyp: $(hol kerntyp) (auf nicht-hybriden Teilen ein Status)" ;;
  *) no "Kerntyp" "'$(hol kerntyp)'" ;;
esac

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
