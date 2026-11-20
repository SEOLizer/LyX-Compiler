#!/usr/bin/env bash
# #2594: Der Fehlerwert von mmap ist auf LyxOS 0, nicht -1.
#
# BEFUND. `src/std/lyxos/lyxrt.lyx` prueft `base < 0` -- die POSIX-Form
# (MAP_FAILED = -1). LyxOS beantwortet eine abgelehnte Anforderung aber mit
# 0, und zwar an VIER Stellen in BEIDEN Dispatchern (kernel/ring3.lyx:
# `zu_gross` und `fehlt > 0`, je in handle_r3_syscall und SchedVfsStep, alle
# `result := 0`). Die Pruefung traf also nie: `_rt_base` wurde 0, die Arena
# galt als gueltig, `rt_alloc` gab `0 + _rt_off` zurueck, und der erste
# Zugriff endete in einer Ausnahme #0E -- ohne die vorgesehene Meldung.
# Gemessen in QEMU mit 512 MB (Issue #2594).
#
# ES WAR NICHT EINE STELLE. Dieselbe Pruefung stand an 41 weiteren Stellen in
# 12 Units des lyxos-Baums. Eine von 42 zu beheben waere genau das Muster, vor
# dem die Arbeitsregeln warnen ("die zweite Stelle wurde nicht nachgezogen").
#
# WARUM NICHT IM EMITTER NORMALISIEREN. `mmap` senkt auf lyxos zu IRO_ALLOC,
# die Ebene gibt es also. Wer dort 0 in -1 umschreibt, bricht aber JEDE Stelle,
# die auf `== 0` prueft -- und die gibt es im Bestand mehrfach
# (std/net/https.lyx, std/net/dns.lyx, std/audio/playback.lyx und weitere).
# `<= 0` traegt beide Konventionen; das ist der Grund fuer die lokale Form.
#
# WAS DIESER TEST PRUEFT, und was nicht:
#   1. Die Klasse bleibt geschlossen: keine mmap-Rueckgabe im lyxos-Baum wird
#      mit `< 0` geprueft. Das ist ein Waechter, denn die naechste neue Stelle
#      wuerde den Fehler sonst wieder einbauen.
#   2. `<= 0` trifft den POSIX-Fehlerwert WEITER: eine abgewiesene Anforderung
#      auf Linux wird erkannt. Ohne diese Gegenprobe waere eine Aenderung
#      denkbar, die den einen Fall behebt und den anderen bricht.
#   3. NICHT geprueft wird der Lauf auf dem Geraet -- dafuer braucht es LyxOS.
#      Der lokale LBF-Lader taugt nicht (Syscall-Ergebnis in rax statt rdx,
#      Allokierendes faultet). Der Gerätenachweis steht im Issue.
cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
case "$LYXC" in /*) ;; *) LYXC="$PWD/${LYXC#./}";; esac
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+ -- $2}"; FAIL=$((FAIL+1)); }

if [ ! -x "$LYXC" ]; then
  echo "SKIP: kein $LYXC -- make bootstrap"
  echo ""
  echo "Ergebnis: 0 PASS, 0 FAIL"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 1. Waechter: keine `< 0`-Pruefung einer mmap-Rueckgabe im lyxos-Baum ---
# Gesucht wird die Zuweisung `name: int64 := mmap(` und danach in den drei
# Folgezeilen eine Pruefung `name < 0`. Drei Zeilen, weil zwischen Aufruf und
# Pruefung im Bestand eine Leerzeile oder ein Kommentar stehen kann.
offen=$(python3 -I - <<'PY'
import os, re
aus = set()
f = "tools/dist_units_ausnahmen_lyxos.txt"
if os.path.exists(f):
    for l in open(f):
        l = l.strip()
        if l and not l.startswith("#"):
            aus.add(l.split()[0])

ziele = ["src/std/lyxos/lyxrt.lyx"]
for wurzel, _, dateien in os.walk("."):
    if "/.git" in wurzel:
        continue
    if not (wurzel.startswith("./std") or wurzel.startswith("./data")):
        continue
    for d in sorted(dateien):
        if d.endswith(".lyx"):
            rel = os.path.join(wurzel, d)[2:]
            if rel not in aus:
                ziele.append(rel)

treffer = []
for rel in ziele:
    try:
        z = open(rel, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        continue
    for i, l in enumerate(z):
        m = re.search(r'(\w+)\s*:\s*int64\s*:=\s*mmap\(', l)
        if not m:
            continue
        name = m.group(1)
        for j in range(i + 1, min(i + 4, len(z))):
            if re.search(r'\b' + re.escape(name) + r'\s*<\s*0\b', z[j]):
                treffer.append(f"{rel}:{j+1} ({name})")
print(" ".join(treffer))
PY
)
if [ -z "$offen" ]; then
  ok "keine mmap-Rueckgabe im lyxos-Baum wird mit '< 0' geprueft"
else
  no "offene Stellen" "$offen"
fi

# Gegenprobe zum Waechter: findet er ueberhaupt etwas? Ein Waechter, der nie
# anspricht, ist kein Waechter. Hier wird die FEHLERHAFTE Form in einer
# Wegwerfdatei im Suchraum erzeugt und danach wieder entfernt.
mkdir -p std/zz_2594_probe_tmp
cat > std/zz_2594_probe_tmp/probe.lyx <<'LYXP'
unit std.zz_2594_probe_tmp.probe;
pub fn p(): int64 {
  var base: int64 := mmap(0, 4096, 3, 34, -1, 0);
  if base < 0 { return -1; }
  return base;
}
LYXP
gefunden=$(python3 -I - <<'PY'
import re
z = open("std/zz_2594_probe_tmp/probe.lyx", encoding="utf-8").read().split("\n")
n = 0
for i, l in enumerate(z):
    m = re.search(r'(\w+)\s*:\s*int64\s*:=\s*mmap\(', l)
    if not m:
        continue
    for j in range(i + 1, min(i + 4, len(z))):
        if re.search(r'\b' + re.escape(m.group(1)) + r'\s*<\s*0\b', z[j]):
            n += 1
print(n)
PY
)
rm -rf std/zz_2594_probe_tmp
if [ "$gefunden" = "1" ]; then
  ok "der Waechter erkennt die fehlerhafte Form (an einer eingesetzten Probe)"
else
  no "Waechter" "erkennt die eingesetzte fehlerhafte Form nicht ($gefunden Treffer)"
fi

# --- 2. Wirkung: '<= 0' erkennt den POSIX-Fehlerwert weiter -----------------
# Eine Anforderung, die der Linux-Kernel ablehnt (absurde Groesse), muss als
# Fehlschlag erkannt werden. Damit ist belegt, dass die Umstellung den
# bisherigen Fall NICHT gebrochen hat -- die haeufigste Art, einen Fix zu
# verderben.
cat > "$TMP/mm.lyx" <<'LYXM'
import std.io;
fn main(): int64 {
  // 2^62 Byte fordert kein Kernel aus; Linux gibt -1, LyxOS gaebe 0.
  var p: int64 := mmap(0, 4611686018427387904, 3, 34, -1, 0);
  if p <= 0 { PrintLn("ABGELEHNT-ERKANNT"c); return 0; }
  PrintLn("DURCHGELASSEN"c);
  return 1;
}
LYXM
if "$LYXC" --std-path="$PWD" "$TMP/mm.lyx" -o "$TMP/mm" >"$TMP/mm.log" 2>&1; then
  out=$("$TMP/mm" 2>&1); rc=$?
  if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q "ABGELEHNT-ERKANNT"; then
    ok "'<= 0' erkennt die abgelehnte Anforderung auch auf Linux (-1)"
  else
    no "Wirkung" "rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ')"
  fi
else
  no "Wirkung" "Probe uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/mm.log")"
fi

# --- 3. Die Meldung steht noch da und ist erreichbar ------------------------
# Ein Fix, der die Pruefung richtigstellt und dabei die Meldung verliert,
# waere derselbe stille Default in neuer Form.
if grep -q 'lyxrt: fatal: mmap failed' src/std/lyxos/lyxrt.lyx; then
  ok "die laute Meldung in rt_alloc ist erhalten"
else
  no "Meldung" "'lyxrt: fatal: mmap failed' fehlt in src/std/lyxos/lyxrt.lyx"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
