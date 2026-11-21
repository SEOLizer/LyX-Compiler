#!/usr/bin/env bash
# #2599: Ein Lyx-Programm auf dem GERÄT laufen lassen und sein Urteil einsammeln.
#
# WARUM ES DIESEN TEST GIBT. Bis hierher wurde fuer lyxos nur UEBERSETZT:
# `make test-lyxos` ist ein "Integrations-Kompilierungstest", und
# `test-lyxos-units` sagt es im Kommentar ("der erzeugte Code laeuft nicht auf
# dem Buildhost"). Der lokale LBF-Lader taugt nicht als Ersatz: LyxOS liefert
# Syscall-Ergebnisse in rdx, Linux in rax, und alles Allokierende faultet
# darueber. Damit war jede Aussage ueber lyxos eine Aussage ueber den
# UEBERSETZER, nie ueber das laufende Programm -- und Abnahmekriterium 8 aus
# #2096 nicht beantwortbar.
#
# WIE ES GEHT, OHNE DAS FREMDE REPO ANZUFASSEN. Das Abbild und QEMU gehoeren
# zu `lyx-os`, dort darf dieses Projekt nur LESEN. Also: Abbild in den
# Kratzbereich KOPIEREN, in der Kopie das Pruefprogramm einspielen, die Kopie
# booten. Eingespielt wird mit `mcopy` (mtools, kein root) in die
# EFI-Partition bei Offset 1048576 -- dieselbe Stelle, die `bootloader/build.sh`
# benutzt.
#
# WARUM DAS PROGRAMM ALS /vega.elf LANDET. Der Kernel berechnet ein
# `boot_target` und DRUCKT es, benutzt es aber nicht: gebootet wird fest
# `SchedBootCompositor("/vega.elf")`. Umbenennen hilft also nichts. Der Lader
# dahinter (`SchedSpawnProcess`) probiert aber LBF ZUERST (`is_lbf(path)`, dann
# ELF), und der Dateiname ist belanglos -- im Abbild liegt schon heute ein
# `taskmgr.lbf`, und ein Lauf von Hand zeigte `lbf /bin/lyxc.elf`. Unser LBF
# unter dem Namen `vega.elf` wird also geladen und ausgefuehrt.
#
# GEMESSEN, nicht angenommen (2026-11-21): der Boot schreibt 296 Zeilen
# Kernelausgabe, danach stehen die drei Marken des Programms da, mit der
# gerechneten Summe. Die Laderzeile davor lautet
# `lbf sect blk=2 n=2 typ=3 prot=3 seiten=0..2 schreibbar / pages=3 entry=4194304`.
#
# WAS DIESER TEST NICHT TUT: er baut das Abbild nicht. Entsteht dort etwas
# Neues, muss `lyx-os` es bauen; dieser Test nimmt, was da liegt, und sagt
# SKIP, wenn nichts da ist. Dieselbe Trennung wie beim Syscallraum (#1795): wir
# lesen den fremden Stand, wir erzeugen ihn nicht.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-./lyxc}"
case "$LYXC" in /*) ;; *) LYXC="$PWD/${LYXC#./}";; esac
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+ -- $2}"; FAIL=$((FAIL+1)); }
ende() { echo ""; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" = "0" ] || exit 1; exit 0; }
skip() { echo "SKIP: $1"; echo ""; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }

# ── Voraussetzungen: jede einzeln benannt ─────────────────────────────────
# Ein SKIP, der nicht sagt WAS fehlt, kostet beim naechsten Mal dieselbe
# Suche von vorn.
[ -x "$LYXC" ] || skip "kein $LYXC -- make bootstrap"
command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 fehlt"
command -v mcopy >/dev/null 2>&1 || skip "mcopy fehlt (Paket mtools)"

LYXOS_REPO="${LYXOS_REPO:-$HOME/PhpstormProjects/lyx-os}"
DISK_ORIG="$LYXOS_REPO/bootloader/lyx_boot.img"
DATA_ORIG="$LYXOS_REPO/bootloader/data.img"
[ -r "$DISK_ORIG" ] || skip "kein LyxOS-Abbild unter $DISK_ORIG (LYXOS_REPO setzen)"
[ -r "$DATA_ORIG" ] || skip "keine data.img neben dem Abbild"

OVMF_CODE=""
for d in /usr/share/OVMF /usr/share/ovmf /usr/share/qemu; do
  for n in OVMF_CODE_4M.fd OVMF_CODE.fd ovmf/OVMF_CODE.fd; do
    [ -r "$d/$n" ] && [ -z "$OVMF_CODE" ] && OVMF_CODE="$d/$n"
  done
done
[ -n "$OVMF_CODE" ] || skip "keine OVMF-Firmware gefunden (Paket ovmf)"
OVMF_VARS="$(dirname "$OVMF_CODE")/$(basename "$OVMF_CODE" | sed 's/CODE/VARS/')"
[ -r "$OVMF_VARS" ] || skip "OVMF_VARS neben $OVMF_CODE fehlt"

# Das Abbild ist 256 MB, data.img 64 MB. Auf /tmp liegt eine NUTZERWEITE
# Quota, die `df` nicht zeigt und die sich mit den Nachbarsitzungen teilt --
# darum wird der Platz GETASTET und nicht gerechnet.
TMP="$(mktemp -d)" || skip "kein Kratzverzeichnis"
trap 'rm -rf "$TMP"' EXIT
if ! dd if=/dev/zero of="$TMP/platz" bs=1M count=400 status=none 2>/dev/null; then
  rm -f "$TMP/platz"
  skip "weniger als 400 MB Luft -- das Abbild (256 MB) plus data.img (64 MB) passt nicht"
fi
rm -f "$TMP/platz"

# ── Ein Lauf auf dem Geraet ───────────────────────────────────────────────
# fahre <lbf> <serial-ziel> -> rc von QEMU
#
# Das Abbild wird JE LAUF frisch aus dem Original kopiert: der erste Boot
# schreibt hinein (Variablen, Zeitstempel), und ein zweiter Lauf auf dem
# benutzten Abbild wuerde messen, was der erste hinterlassen hat.
fahre() {
  local lbf="$1" ziel="$2"
  cp "$DISK_ORIG" "$TMP/disk.img" || return 90
  cp "$OVMF_VARS" "$TMP/vars.fd"  || return 91
  mcopy -o -i "$TMP/disk.img@@1048576" "$lbf" ::/vega.elf 2>"$TMP/mcopy.log" || return 92
  [ "$(mtype -i "$TMP/disk.img@@1048576" ::/vega.elf 2>/dev/null | head -c4)" = "LYX!" ] || return 93
  : > "$ziel"
  timeout "$GRENZE" qemu-system-x86_64 \
      $KVM -smp 4 -machine pc -m 512M \
      -drive if=pflash,format=raw,unit=0,file="$OVMF_CODE",readonly=on \
      -drive if=pflash,format=raw,unit=1,file="$TMP/vars.fd" \
      -drive file="$TMP/disk.img",format=raw,if=ide,index=0 \
      -drive file="$TMP/data.img",format=raw,if=ide,index=1 \
      -display none -serial "file:$ziel" -no-reboot \
      >"$TMP/qemu.log" 2>&1
  return $?
}

# KVM wenn moeglich: mit reiner Softwareemulation (TCG) kam der Boot in 150 s
# nur bis `sched init ok` und die Marken fehlten -- das sah wie ein
# Fehlschlag aus und war eine zu kurze Frist.
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then KVM="-enable-kvm -cpu host"; else KVM="-cpu qemu64"; fi
GRENZE="${LYXOS_GERAET_GRENZE:-300}"
cp "$DATA_ORIG" "$TMP/data.img" || { no "data.img kopieren" "fehlgeschlagen"; ende; }

# rc 124 ist der ERWARTETE Fall: das Programm endet, die Maschine laeuft
# weiter, und der Zeitdeckel beendet sie. rc 0 heisst, sie hat sich gehalten.
lauf_ok() { [ "$1" = "124" ] || [ "$1" = "0" ]; }

# ── Stufe 0: laeuft Lyx-Code auf dem Geraet, kommt die Ausgabe an? ────────
if ! "$LYXC" --target=lyxos --std-path="$ROOT" tests/lyxos_geraet/probe0.lyx \
      -o "$TMP/probe0.lbf" >"$TMP/bau0.log" 2>&1; then
  no "Stufe 0 uebersetzt nicht fuer lyxos" "$(grep -m1 -iE 'error' "$TMP/bau0.log")"
  ende
fi
if [ "$(head -c4 "$TMP/probe0.lbf")" = "LYX!" ]; then
  ok "Stufe 0: probe0.lbf uebersetzt und traegt die LBF-Magie"
else
  no "Stufe 0" "keine LYX!-Magie -- kein LBF"; ende
fi

fahre "$TMP/probe0.lbf" "$TMP/s0.txt"; RC0=$?
if lauf_ok "$RC0"; then
  ok "Stufe 0: QEMU lief und wurde beendet (rc=$RC0)"
else
  no "Stufe 0: QEMU" "rc=$RC0 -- $(tail -2 "$TMP/qemu.log" | tr '\n' ' ')"; ende
fi
Z0="$(wc -l < "$TMP/s0.txt" 2>/dev/null || echo 0)"
if [ "$Z0" -gt 20 ]; then
  ok "Stufe 0: die serielle Leitung traegt Ausgabe zum Wirt ($Z0 Zeilen)"
else
  no "Stufe 0: serielle Leitung" "nur $Z0 Zeilen -- kam der Boot ueberhaupt los?"; ende
fi

# Drei getrennte Bedingungen, damit der Bericht sagt WIE weit es kam.
if grep -q 'LYXOS-PROBE-START-7F3A' "$TMP/s0.txt"; then
  ok "Stufe 0: das Programm ist auf dem Geraet angelaufen"
else
  no "Stufe 0: Anlauf" "Startmarke fehlt"
  echo "  letzte Zeilen:"; tail -5 "$TMP/s0.txt" | sed 's/^/    /'; ende
fi
if grep -q 'LYXOS-PROBE-SUMME 500500' "$TMP/s0.txt"; then
  ok "Stufe 0: gerechnet wurde auf dem Geraet, und richtig (1..1000 = 500500)"
else
  no "Stufe 0: Rechnung" "$(grep -m1 'LYXOS-PROBE-SUMME' "$TMP/s0.txt" || echo '(keine Summenzeile)')"
fi
if grep -q 'LYXOS-PROBE-ENDE-7F3A' "$TMP/s0.txt"; then
  ok "Stufe 0: der Durchlauf war vollstaendig"
else
  no "Stufe 0: Vollstaendigkeit" "Endmarke fehlt"
fi

# ── Stufe 1: ein ECHTER Test auf dem Geraet (RFC 8448, #2096 Kriterium 5) ─
# Die Vektoren werden NICHT kopiert, sondern aus ihrem Test herausgezogen.
# Eine zweite Abschrift waere eine zweite Quelle, die driftet -- genau das
# Muster, das in diesem Repo schon mehrfach auseinandergelaufen ist. Faellt
# die Auszugsstelle weg, scheitert das hier LAUT und nicht still.
RFCQ="tests/tls13_rfc8448_test.sh"
if [ ! -f "$RFCQ" ]; then
  no "Stufe 1" "$RFCQ fehlt -- die Vektoren sind nicht auffindbar"; ende
fi
awk '/cat > .*s\.lyx/{f=1;next} /^LYXEOF$/{f=0} f' "$RFCQ" > "$TMP/rfc.lyx"
ZR="$(wc -l < "$TMP/rfc.lyx")"
if [ "$ZR" -lt 100 ]; then
  no "Stufe 1" "Auszug aus $RFCQ ergab nur $ZR Zeilen -- das Heredoc-Muster passt nicht mehr"; ende
fi
ok "Stufe 1: RFC-8448-Programm aus $RFCQ gezogen ($ZR Zeilen, eine Quelle)"

if ! "$LYXC" --target=lyxos --std-path="$ROOT" "$TMP/rfc.lyx" \
      -o "$TMP/rfc.lbf" >"$TMP/bau1.log" 2>&1; then
  no "Stufe 1 uebersetzt nicht fuer lyxos" "$(grep -m1 -iE 'error|gibt es nur' "$TMP/bau1.log")"
  ende
fi
ok "Stufe 1: uebersetzt fuer --target=lyxos"

fahre "$TMP/rfc.lbf" "$TMP/s1.txt"; RC1=$?
if lauf_ok "$RC1"; then
  ok "Stufe 1: QEMU lief und wurde beendet (rc=$RC1)"
else
  no "Stufe 1: QEMU" "rc=$RC1"; ende
fi

# Das Urteil des Programms selbst. `fails 0` ist seine Schlusszeile; die
# Einzelzeilen daneben belegen, dass es WIRKLICH gerechnet hat und nicht nur
# eine Null gedruckt hat.
if grep -q '^fails 0' "$TMP/s1.txt"; then
  ok "Stufe 1: RFC 8448 auf dem GERAET bytegenau -- fails 0"
else
  gef="$(grep -m1 '^fails' "$TMP/s1.txt" || echo '(keine fails-Zeile)')"
  no "Stufe 1: RFC 8448" "$gef"
  echo "  letzte Zeilen der Geraeteausgabe:"; tail -6 "$TMP/s1.txt" | sed 's/^/    /'
fi
for marke in 'x25519-geheimnis-client ok' 'master-secret ok' 'verify-data ok' 'gekippter-record-abgewiesen 1'; do
  if grep -q "$marke" "$TMP/s1.txt"; then
    ok "Stufe 1: $marke"
  else
    no "Stufe 1" "'$marke' fehlt in der Geraeteausgabe"
  fi
done

ende
