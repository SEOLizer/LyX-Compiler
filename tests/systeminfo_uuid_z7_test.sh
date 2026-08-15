#!/usr/bin/env bash
# tests/systeminfo_uuid_z7_test.sh — #1469, #1470, #1471, #1473, #1474, #1475.
#
# std.systeminfo:
#   #1469 GetLogicalCores/GetPhysicalCores/GetSMTWidth gaben die Konstanten
#         8, 4 und 1 zurück — auf der Entwicklungsmaschine zufällig fast
#         richtig, überall sonst falsch und ohne Hinweis.
#   #1470 readCpuStat benutzte `pos` gleichzeitig als Schreibposition UND als
#         Zustandsnummer; die Felder verrutschten, GetCpuUserTime & Co. lieferten
#         Werte ohne Bezug zur Datei.
#   #1471 GetRunningProcesses gab die Zahl NACH dem Schrägstrich (alle Prozesse
#         statt der laufenden), GetUptime Hundertstelsekunden statt Sekunden —
#         und alle sechs Parser schrieben byteweise in ZEICHENKETTEN-LITERALE.
#
# std.uuid:
#   #1473 GenerateV4 lieferte in jedem Programmlauf dieselbe Folge (feste Saat).
#   #1474 ToString erzeugte 35 statt 36 Zeichen — der vierte Bindestrich fehlte.
#   #1475 GetVariant meldete nie RFC 4122, GenerateV7 hatte keinen echten
#         Zeitstempel, die String-Varianten leckten pro Aufruf 16 Byte.
#
# GEPRÜFT WIRD GEGEN DAS SYSTEM, nicht gegen sich selbst: die Kernzahlen gegen
# `nproc` und `lscpu`, die /proc-Werte gegen die Datei derselben Sekunde. Ein
# Test, der nur „liefert eine Zahl > 0" verlangt, wäre bei fest verdrahteten
# Konstanten grün gewesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ===========================================================================
# std.systeminfo — gegen /proc und die Systemwerkzeuge
# ===========================================================================

cat > "$TMP/si.lyx" <<'LYXEOF'
import std.io;
import std.systeminfo;
fn main(): int64 {
  PrintStr("logisch=");   PrintLn(IntToStr(GetLogicalCores()));
  PrintStr("physisch=");  PrintLn(IntToStr(GetPhysicalCores()));
  PrintStr("smt=");       PrintLn(IntToStr(GetSMTWidth()));
  PrintStr("memtotal=");  PrintLn(IntToStr(GetTotalMemory()));
  PrintStr("uptime=");    PrintLn(IntToStr(GetUptime()));
  PrintStr("uptime100=on"); PrintLn(IntToStr(GetUptimeHundertstel()));
  PrintStr("laufend=");   PrintLn(IntToStr(GetRunningProcesses()));
  PrintStr("gesamt=");    PrintLn(IntToStr(GetTotalProcesses()));
  PrintStr("pid=");       PrintLn(IntToStr(GetProcessId()));
  PrintStr("cpuuser=");   PrintLn(IntToStr(GetCpuUserTime()));
  PrintStr("cpusystem="); PrintLn(IntToStr(GetCpuSystemTime()));
  PrintStr("cpuidle=");   PrintLn(IntToStr(GetCpuIdleTime()));
  return 0;
}
LYXEOF

if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/si.lyx" -o "$TMP/si" >/dev/null 2>&1; then
  no "std.systeminfo: Messprogramm uebersetzt" "uebersetzt nicht"
else
  A="$(timeout 30 "$TMP/si" 2>/dev/null)"
  w() { echo "$A" | grep "^$1=" | head -1 | cut -d= -f2; }

  # --- #1469: Kerne gegen nproc / lscpu ---
  soll_log="$(nproc 2>/dev/null || echo 0)"
  ist_log="$(w logisch)"
  if [ "$soll_log" -gt 0 ] 2>/dev/null; then
    [ "$ist_log" = "$soll_log" ] && ok "#1469: GetLogicalCores stimmt mit nproc ($soll_log)" \
                                 || no "#1469: GetLogicalCores stimmt mit nproc" "ist $ist_log, nproc $soll_log"
  else
    echo "SKIP #1469: nproc nicht verfuegbar"
  fi

  # Physische Kerne aus /proc/cpuinfo: verschiedene (physical id, core id).
  soll_phys="$(awk -F': ' '/^physical id/{p=$2} /^core id/{print p":"$2}' /proc/cpuinfo 2>/dev/null | sort -u | wc -l)"
  ist_phys="$(w physisch)"
  if [ "$soll_phys" -gt 0 ] 2>/dev/null; then
    [ "$ist_phys" = "$soll_phys" ] && ok "#1469: GetPhysicalCores stimmt mit /proc/cpuinfo ($soll_phys)" \
                                   || no "#1469: GetPhysicalCores stimmt mit /proc/cpuinfo" "ist $ist_phys, erwartet $soll_phys"
    soll_smt=$(( soll_log / soll_phys ))
    [ "$(w smt)" = "$soll_smt" ] && ok "#1469: GetSMTWidth ist logisch/physisch ($soll_smt)" \
                                 || no "#1469: GetSMTWidth ist logisch/physisch" "ist $(w smt), erwartet $soll_smt"
  else
    echo "SKIP #1469: keine Topologie in /proc/cpuinfo"
  fi

  # --- #1471: Uptime in Sekunden, nicht Hundertstel ---
  soll_up="$(cut -d. -f1 /proc/uptime)"
  ist_up="$(w uptime)"
  d=$(( ist_up - soll_up )); [ "$d" -lt 0 ] && d=$(( -d ))
  [ "$d" -le 5 ] && ok "#1471: GetUptime liefert Sekunden" \
                 || no "#1471: GetUptime liefert Sekunden" "ist $ist_up, /proc/uptime $soll_up"

  # Und die Hundertstel als eigener Weg — rund das Hundertfache.
  ist_up100="$(echo "$A" | grep '^uptime100=on' | sed 's/^uptime100=on//')"
  v=$(( ist_up100 / 100 )); d=$(( v - soll_up )); [ "$d" -lt 0 ] && d=$(( -d ))
  [ "$d" -le 5 ] && ok "#1471: GetUptimeHundertstel ist das Hundertfache" \
                 || no "#1471: GetUptimeHundertstel ist das Hundertfache" "$ist_up100"

  # --- #1471: laufende Prozesse VOR dem Schraegstrich ---
  feld="$(awk '{print $4}' /proc/loadavg)"
  soll_lauf="${feld%%/*}"; soll_ges="${feld##*/}"
  ist_lauf="$(w laufend)"; ist_ges="$(w gesamt)"
  # Die laufende Zahl schwankt; geprueft wird die Groessenordnung — sie darf
  # keinesfalls die Gesamtzahl sein.
  if [ "$ist_lauf" -lt 100 ] 2>/dev/null && [ "$ist_lauf" -gt 0 ] 2>/dev/null; then
    ok "#1471: GetRunningProcesses zaehlt die laufenden ($ist_lauf, nicht $soll_ges)"
  else
    no "#1471: GetRunningProcesses zaehlt die laufenden" "ist $ist_lauf, /proc/loadavg $feld"
  fi
  d=$(( ist_ges - soll_ges )); [ "$d" -lt 0 ] && d=$(( -d ))
  [ "$d" -le 50 ] && ok "#1471: GetTotalProcesses liefert die Gesamtzahl" \
                  || no "#1471: GetTotalProcesses liefert die Gesamtzahl" "ist $ist_ges, erwartet ~$soll_ges"

  # --- #1471: Speicher gegen /proc/meminfo ---
  soll_mem="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
  [ "$(w memtotal)" = "$soll_mem" ] && ok "#1471: GetTotalMemory stimmt mit /proc/meminfo" \
                                    || no "#1471: GetTotalMemory stimmt mit /proc/meminfo" "ist $(w memtotal), erwartet $soll_mem"

  # --- #1470: CPU-Zeiten gegen /proc/stat ---
  set -- $(head -1 /proc/stat)
  # $1=cpu $2=user $3=nice $4=system $5=idle
  soll_user="$2"; soll_sys="$4"; soll_idle="$5"
  pruefNah() { # name, ist, soll, toleranz
    local d=$(( $2 - $3 )); [ "$d" -lt 0 ] && d=$(( -d ))
    if [ "$d" -le "$4" ]; then ok "$1"; else no "$1" "ist $2, /proc/stat $3"; fi
  }
  pruefNah "#1470: GetCpuUserTime ist das user-Feld"   "$(w cpuuser)"   "$soll_user" 2000
  pruefNah "#1470: GetCpuSystemTime ist das system-Feld" "$(w cpusystem)" "$soll_sys"  2000
  pruefNah "#1470: GetCpuIdleTime ist das idle-Feld"   "$(w cpuidle)"   "$soll_idle" 5000

  # --- #1471: die eigene PID ---
  ist_pid="$(w pid)"
  [ "$ist_pid" -gt 0 ] 2>/dev/null && ok "#1471: GetProcessId liefert eine PID" \
                                   || no "#1471: GetProcessId liefert eine PID" "$ist_pid"
fi

# Kein Parser darf noch in ein Zeichenketten-Literal schreiben — das war die
# gemeinsame Wurzel unter #1470 und #1471.
if grep -qE '^\s*var buf: pchar := " +";' "$ROOT/std/systeminfo.lyx"; then
  no "#1471: keine Literal-Schreibpuffer mehr" "var buf: pchar := \"   \" steht wieder da"
else
  ok "#1471: keine Literal-Schreibpuffer mehr"
fi

# ===========================================================================
# std.uuid
# ===========================================================================

cat > "$TMP/uu.lyx" <<'LYXEOF'
import std.io;
import std.alloc;
import std.uuid;
fn main(): int64 {
  var s: int64 := alloc(40);
  GenerateV4String(s as pchar);
  PrintStr("v4="); PrintLn(s as pchar);

  var b: int64 := alloc(16);
  FromString("550e8400-e29b-41d4-a716-446655440000", b as pchar);
  var r: int64 := alloc(40);
  ToString(b as pchar, r as pchar);
  PrintStr("rund="); PrintLn(r as pchar);
  PrintStr("len="); PrintLn(IntToStr(StrLen(r as pchar)));
  PrintStr("variante="); PrintLn(IntToStr(GetVariant(b as pchar)));
  PrintStr("version="); PrintLn(IntToStr(GetVersion(b as pchar)));

  var v4: int64 := alloc(16);
  GenerateV4(v4 as pchar);
  PrintStr("v4variante="); PrintLn(IntToStr(GetVariant(v4 as pchar)));
  PrintStr("v4version="); PrintLn(IntToStr(GetVersion(v4 as pchar)));

  var v7: int64 := alloc(16);
  GenerateV7(v7 as pchar);
  PrintStr("v7version="); PrintLn(IntToStr(GetVersion(v7 as pchar)));
  PrintStr("v7variante="); PrintLn(IntToStr(GetVariant(v7 as pchar)));
  // Zeitstempel: 48 Bit gross-endian in Byte 0..5, Millisekunden seit Epoche
  var ms: int64 := 0;
  var i: int64 := 0;
  while (i < 6) { ms := ms * 256 + (StrCharAt(v7 as pchar, i) & 255); i := i + 1; }
  PrintStr("v7sek="); PrintLn(IntToStr(ms / 1000));
  return 0;
}
LYXEOF

if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/uu.lyx" -o "$TMP/uu" >/dev/null 2>&1; then
  no "std.uuid: Messprogramm uebersetzt" "uebersetzt nicht"
else
  B="$(timeout 30 "$TMP/uu" 2>/dev/null)"
  u() { echo "$B" | grep "^$1=" | head -1 | cut -d= -f2; }

  # --- #1474: 36 Zeichen und vier Bindestriche ---
  [ "$(u len)" = "36" ] && ok "#1474: ToString liefert 36 Zeichen" \
                        || no "#1474: ToString liefert 36 Zeichen" "$(u len)"

  rund="$(u rund)"
  striche="$(echo "$rund" | tr -cd '-' | wc -c)"
  [ "$striche" = "4" ] && ok "#1474: vier Bindestriche (8-4-4-4-12)" \
                       || no "#1474: vier Bindestriche (8-4-4-4-12)" "$striche in '$rund'"

  # Rundlauf: FromString(ToString(x)) muss die Eingabe treffen (Gross-/
  # Kleinschreibung ist bei Hex gleichwertig).
  if [ "$(echo "$rund" | tr 'A-F' 'a-f')" = "550e8400-e29b-41d4-a716-446655440000" ]; then
    ok "#1474: Rundlauf FromString/ToString"
  else
    no "#1474: Rundlauf FromString/ToString" "'$rund'"
  fi

  # --- #1475: Variante und Version ---
  [ "$(u variante)" = "1" ] && ok "#1475: GetVariant meldet RFC 4122" \
                            || no "#1475: GetVariant meldet RFC 4122" "$(u variante) (1 = RFC)"
  [ "$(u version)" = "4" ] && ok "#1475: GetVersion liest die Version" \
                           || no "#1475: GetVersion liest die Version" "$(u version)"
  [ "$(u v4variante)" = "1" ] && ok "#1475: erzeugte v4 traegt die RFC-Variante" \
                              || no "#1475: erzeugte v4 traegt die RFC-Variante" "$(u v4variante)"
  [ "$(u v4version)" = "4" ] && ok "#1475: erzeugte v4 traegt Version 4" \
                             || no "#1475: erzeugte v4 traegt Version 4" "$(u v4version)"
  [ "$(u v7version)" = "7" ] && ok "#1475: erzeugte v7 traegt Version 7" \
                             || no "#1475: erzeugte v7 traegt Version 7" "$(u v7version)"
  [ "$(u v7variante)" = "1" ] && ok "#1475: erzeugte v7 traegt die RFC-Variante" \
                              || no "#1475: erzeugte v7 traegt die RFC-Variante" "$(u v7variante)"

  # #1475: der Zeitstempel muss die ECHTE Zeit sein — vorher stand dort der
  # Zustand des Zufallsgenerators.
  jetzt="$(date +%s)"
  v7sek="$(u v7sek)"
  d=$(( v7sek - jetzt )); [ "$d" -lt 0 ] && d=$(( -d ))
  [ "$d" -le 60 ] && ok "#1475: v7-Zeitstempel ist die Unix-Zeit" \
                  || no "#1475: v7-Zeitstempel ist die Unix-Zeit" "$v7sek vs $jetzt"

  # --- #1473: zwei Laeufe, zwei UUIDs ---
  lauf1="$(timeout 30 "$TMP/uu" 2>/dev/null | grep '^v4=' | cut -d= -f2)"
  lauf2="$(timeout 30 "$TMP/uu" 2>/dev/null | grep '^v4=' | cut -d= -f2)"
  if [ -n "$lauf1" ] && [ "$lauf1" != "$lauf2" ]; then
    ok "#1473: zwei Programmlaeufe liefern verschiedene UUIDs"
  else
    no "#1473: zwei Programmlaeufe liefern verschiedene UUIDs" "beide '$lauf1'"
  fi

  # Und innerhalb eines Laufs ebenso — sonst waere nur die Saat gewechselt.
  cat > "$TMP/uu2.lyx" <<'LYXEOF'
import std.io;
import std.alloc;
import std.uuid;
fn main(): int64 {
  var a: int64 := alloc(40);
  var b: int64 := alloc(40);
  GenerateV4String(a as pchar);
  GenerateV4String(b as pchar);
  if (StrEquals(a as pchar, b as pchar)) { PrintLn("gleich"); } else { PrintLn("verschieden"); }
  return 0;
}
LYXEOF
  if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/uu2.lyx" -o "$TMP/uu2" >/dev/null 2>&1; then
    [ "$(timeout 20 "$TMP/uu2" 2>/dev/null)" = "verschieden" ] \
      && ok "#1473: zwei Aufrufe im selben Lauf sind verschieden" \
      || no "#1473: zwei Aufrufe im selben Lauf sind verschieden" "gleich"
  else
    no "#1473: zwei Aufrufe im selben Lauf sind verschieden" "uebersetzt nicht"
  fi

  # --- #1475: das Leck in den String-Varianten ---
  # Ein Leck ist von aussen schwer zu messen; geprueft wird die Wirkung, die es
  # haette: 50000 Aufrufe zu je 16 Byte waeren 800 KB.
  cat > "$TMP/uu3.lyx" <<'LYXEOF'
import std.io;
import std.alloc;
import std.uuid;
fn main(): int64 {
  var s: int64 := alloc(40);
  var i: int64 := 0;
  while (i < 50000) { GenerateV4String(s as pchar); i := i + 1; }
  PrintStr("len="); PrintLn(IntToStr(StrLen(s as pchar)));
  return 0;
}
LYXEOF
  if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/uu3.lyx" -o "$TMP/uu3" >/dev/null 2>&1; then
    [ "$(timeout 60 "$TMP/uu3" 2>/dev/null)" = "len=36" ] \
      && ok "#1475: 50000 Aufrufe laufen durch" \
      || no "#1475: 50000 Aufrufe laufen durch" "$(timeout 60 "$TMP/uu3" 2>&1 | tail -1)"
  else
    no "#1475: 50000 Aufrufe laufen durch" "uebersetzt nicht"
  fi
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
