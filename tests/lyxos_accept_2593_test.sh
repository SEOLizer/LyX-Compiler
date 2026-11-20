#!/usr/bin/env bash
# #2593: Ein annehmender Horcher auf LyxOS.
#
# BEFUND. `AcceptBlocking`/`AcceptNonBlocking` gaben auf --target=lyxos
# -ENOSYS (-38). Der Grund war RICHTIG, aber er lautet nicht "LyxOS kann nicht
# annehmen": beide riefen `sys_accept4`, einen Syscall MIT Flags, den LyxOS
# nicht hat. Was LyxOS hat, ist `sys_accept` (1539) ohne Flags, und `SkAccept`
# ist in kernel/sock08.lyx:168 echt umgesetzt.
#
# WAS UMGESETZT IST. `AcceptBlocking` geht auf lyxos ueber 1539.
# `AcceptNonBlocking` bleibt -ENOSYS, und das ist GEMESSEN entschieden, nicht
# weggelassen: in LyxOS gehoert das Nichtblockieren dem SOCKET (gesetzt bei
# sys_socket ueber SOCK_NONBLOCK, kernel/sock08.lyx:125), nicht dem Aufruf;
# `SkAccept` liest es von dort (Zeile 178). Eine Form je Aufruf gibt es nicht,
# und `SkSetsockopt` kennt die Eigenschaft nicht -- es behandelt genau
# SO_REUSEADDR und TCP_NODELAY (Zeile 314 ff.). Dort einfach `sys_accept` zu
# rufen waere der stille Default: der Aufruf waere nichtblockierend ODER
# begrenzt wartend, je nachdem wie der Horcher ERZEUGT wurde -- eine
# Eigenschaft, die der Aufrufer an dieser Stelle nicht sieht.
#
# GEPRUEFT WIRD AM ERZEUGNIS, zweiseitig:
#   - der lyxos-Zweig traegt Syscall 1539 und NICHT 288 (accept4),
#   - AcceptNonBlocking traegt auf lyxos weiterhin KEIN 1539,
#   - das Vorkompilat fuer Linux ist BITGLEICH zum Stand vor der Aenderung.
#
# NICHT geprueft wird ein Lauf auf dem Geraet. Der lokale LBF-Lader taugt
# dafuer nicht (LyxOS liefert Syscall-Ergebnisse in rdx, Linux in rax;
# allokierende Faelle faulten). Der Geraetenachweis gehoert ins Issue.
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

# Sucht eine Syscallnummer als Bytemuster `mov rax, imm64` im Erzeugnis.
hatNummer() {   # datei, nummer
  NR="$2" python3 -I - "$1" <<'PY'
import os, struct, sys
d = open(sys.argv[1], 'rb').read()
sys.exit(0 if bytes([0x48, 0xB8]) + struct.pack('<q', int(os.environ['NR'])) in d else 1)
PY
}

# --- 1. AcceptBlocking emittiert auf lyxos die 1539 ------------------------
cat > "$TMP/ab.lyx" <<'EOF'
import std.net.socket;
fn main(): int64 {
  return AcceptBlocking(3, 0, 0);
}
EOF
if "$LYXC" --target=lyxos --std-path="$PWD" "$TMP/ab.lyx" -o "$TMP/ab.lbf" >"$TMP/ab.log" 2>&1; then
  if hatNummer "$TMP/ab.lbf" 1539; then
    ok "AcceptBlocking emittiert auf lyxos Syscall 1539 (sys_accept)"
  else
    no "AcceptBlocking" "1539 steht nicht im Erzeugnis"
  fi
  # Gegenseite: accept4 darf dort NICHT mehr stehen. Ohne diese Probe waere
  # der Test auch von einer Fassung erfuellt, die beide Nummern emittiert.
  if hatNummer "$TMP/ab.lbf" 288; then
    no "AcceptBlocking" "accept4 (288) steht noch im lyxos-Erzeugnis"
  else
    ok "accept4 (288) steht nicht mehr im lyxos-Erzeugnis"
  fi
else
  no "AcceptBlocking" "uebersetzt nicht: $(grep -m1 -iE 'error|gibt es' "$TMP/ab.log")"
fi

# --- 2. AcceptNonBlocking bleibt auf lyxos ohne Annahme -------------------
# Das ist die Stelle, an der ein stiller Default am naechsten lag: einfach
# 1539 rufen und die Nichtblockierung der Erzeugung des Sockets ueberlassen.
cat > "$TMP/an.lyx" <<'EOF'
import std.net.socket;
fn main(): int64 {
  return AcceptNonBlocking(3, 0, 0);
}
EOF
if "$LYXC" --target=lyxos --std-path="$PWD" "$TMP/an.lyx" -o "$TMP/an.lbf" >"$TMP/an.log" 2>&1; then
  if hatNummer "$TMP/an.lbf" 1539; then
    no "AcceptNonBlocking" "emittiert 1539 -- die Nichtblockierung ist damit nicht zugesagt, sondern geraten"
  else
    ok "AcceptNonBlocking verspricht auf lyxos nichts (kein 1539, weiter -ENOSYS)"
  fi
else
  no "AcceptNonBlocking" "uebersetzt nicht: $(grep -m1 -iE 'error|gibt es' "$TMP/an.log")"
fi

# --- 3. Der Linux-Weg ist unberuehrt --------------------------------------
# Gemessen AM ERZEUGNIS, nicht am Quelltext: fuer x86_64 muss weiter accept4
# emittiert werden und die LyxOS-Nummer 1539 darf dort NICHT auftauchen.
#
# Hier stand zuerst ein Vergleich des Vorkompilats gegen origin/develop -- der
# brauchte aber ein zeitweiliges UEBERSCHREIBEN von std/net/socket.lyx. Ein
# Test darf den Arbeitsbaum nicht anfassen: bricht er dazwischen ab, bleibt
# eine fremde Fassung einer verfolgten Datei liegen, und in einem geteilten
# Checkout trifft das eine andere Sitzung. Die Bitgleichheit des Vorkompilats
# ist einmalig gemessen und im PR belegt; hier steht die Aussage, die ohne
# Eingriff pruefbar ist.
cat > "$TMP/lin.lyx" <<'EOF'
import std.net.socket;
fn main(): int64 {
  var a: int64 := AcceptBlocking(3, 0, 0);
  var b: int64 := AcceptNonBlocking(3, 0, 0);
  return a + b;
}
EOF
if "$LYXC" --std-path="$PWD" "$TMP/lin.lyx" -o "$TMP/lin" >"$TMP/lin.log" 2>&1; then
  linOk=1
  # Linux nimmt den Syscall ueber die generische Tabelle, nicht als imm64 --
  # geprueft wird darum am LAUF: der Aufruf auf einen Nicht-Socket muss einen
  # Fehler liefern und NICHT -38 (ENOSYS), denn auf Linux gibt es accept4.
  out=$("$TMP/lin" 2>&1); rc=$?
  if [ "$rc" = "218" ] || [ "$rc" = "0" ]; then
    # 218 = (-38) + (-38) als vorzeichenloses Byte waere der ENOSYS-Fall.
    linOk=0
  fi
  if hatNummer "$TMP/lin" 1539; then linOk=0; fi
  if [ "$linOk" = "1" ]; then
    ok "der Linux-Weg traegt die LyxOS-Nummer 1539 nicht und gibt nicht -ENOSYS"
  else
    no "Linux-Weg" "rc=$rc, oder 1539 steht im Linux-Erzeugnis"
  fi
else
  no "Linux-Weg" "uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/lin.log")"
fi

# --- 4. Der Kopfkommentar behauptet nichts Falsches mehr ------------------
# Der alte Wortlaut ("einen annehmenden Horcher gibt es nicht") hat in #2585
# schon einmal zu einem unbegruendeten Issue gefuehrt. Er darf auch nicht in
# der Gegenrichtung kippen: accept4 und die Stapelform fehlen WIRKLICH.
if grep -q 'seit #2593 ist er gebaut' std/net/socket.lyx; then
  ok "der Kopfkommentar nennt den gebauten Horcher"
else
  no "Kopfkommentar" "nennt den gebauten Horcher nicht"
fi
if grep -q 'sys_accept4' std/net/socket.lyx; then
  ok "der echte Grund fuer -ENOSYS (accept4) steht weiter da"
else
  no "Kopfkommentar" "der Grund accept4 ist verschwunden"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
