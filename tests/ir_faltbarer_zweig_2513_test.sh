#!/bin/bash
# #2513: Ein faltbarer `if` senkt nur den genommenen Zweig.
#
# Lage vorher: die Gates fuer Syscall-NAME und Aufruf-GESTALT sitzen in
# ir_lower vor jeder Senkung und sahen beide Zweige. Damit war
#
#   if TARGET_OS == OS_LYXOS { <lyxos-Form> } else { <Linux-Form> }
#
# nicht uebersetzbar -- obwohl der Compiler genau diese Fassung in seiner
# eigenen Fehlermeldung empfiehlt. 77 von 492 std-Units liessen sich fuer
# --target=lyxos nicht vorkompilieren (Verteilung in #2522).
#
# GEMESSEN WIRD DIE WIRKUNG, NICHT DAS VORHANDENSEIN: jede Probe wird
# uebersetzt und ihr Rueckgabewert gelesen. Und BEIDE SEITEN:
#
#   * der TOTE Zweig darf nicht mehr scheitern (sonst ist nichts gewonnen),
#   * der ERREICHBARE Falschaufruf muss weiter scheitern (sonst ist aus dem
#     Fix ein stiller Default geworden -- genau die Lage aus #2482).
cd "$(dirname "$0")/.." || exit 1
P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }

LYXC="${LYXC:-./lyxc}"   # Gegenprobe: LYXC=<alter Compiler> macht 1-3 und 6 rot
if [ ! -x "$LYXC" ]; then echo "SKIP: ./lyxc fehlt"; exit 0; fi
# #1294: Ressourcengrenze um jeden lyxc-Aufruf (tests/lyxc_guard_test.sh wacht).
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# rc NICHT hinter einer Pipe lesen: dort kaeme der des letzten Gliedes.
uebersetze() {   # $1 = datei, $2 = ziel -> rc
  "$LYXC" --std-path=. --target="$2" \
      --compile-unit "$1" -o "$T/out.lyu" > "$T/log" 2>&1
  return $?
}

# 1) Toter Zweig mit der ANDEREN Aufrufgestalt: beide Ziele muessen gruen sein.
cat > "$T/zweig.lyx" <<'EOF'
unit zweig;

pub fn SendeIrgendwie(fd: int64, buf: int64, n: int64): int64 {
  if TARGET_OS == OS_LYXOS {
    return sys_sendto(fd, buf, n, 0);
  } else {
    return sys_sendto(fd, buf, n, 0, 0, 0);
  }
}
EOF
if uebersetze "$T/zweig.lyx" lyxos; then
  ok "lyxos: die Linux-Form im toten else-Zweig blockiert nicht mehr"
else
  bad "lyxos: toter else-Zweig" "$(grep -m1 'lyxc: --target' "$T/log")"
fi
if uebersetze "$T/zweig.lyx" arm64; then
  ok "arm64: die lyxos-Form im toten then-Zweig blockiert nicht mehr"
else
  bad "arm64: toter then-Zweig" "$(grep -m1 'lyxc: --target' "$T/log")"
fi

# 2) Auch ein NAME, den das Ziel nicht kennt, darf im toten Zweig stehen --
#    das ist die zweite der beiden Gates (nicht nur die Gestalt).
cat > "$T/name.lyx" <<'EOF'
unit name;

pub fn NurAufLinux(a: int64): int64 {
  if TARGET_OS == OS_LYXOS {
    return 0;
  } else {
    return sys_arch_prctl(a, 0);
  }
}
EOF
if uebersetze "$T/name.lyx" lyxos; then
  ok "lyxos: ein zielfremder NAME im toten Zweig blockiert nicht mehr"
else
  bad "lyxos: zielfremder Name im toten Zweig" "$(grep -m1 'lyxc:' "$T/log")"
fi

# 3) GEGENSEITE: erreichbar falsche Gestalt muss weiter abgewiesen werden.
cat > "$T/bad.lyx" <<'EOF'
unit bad;

pub fn SendeFalsch(fd: int64, buf: int64, n: int64): int64 {
  return sys_sendto(fd, buf, n, 0, 0, 0);
}
EOF
if uebersetze "$T/bad.lyx" lyxos; then
  bad "Gegenseite Gestalt" "ein erreichbarer 6-Argument-sendto wurde angenommen"
else
  if grep -q "erwartet auf LyxOS genau 4 Argument" "$T/log"; then
    ok "lyxos: erreichbar falsche Argumentzahl wird weiter benannt abgewiesen"
  else
    bad "Gegenseite Gestalt" "abgewiesen, aber mit anderer Meldung"
  fi
fi

# 4) GEGENSEITE: erreichbar zielfremder Name muss weiter abgewiesen werden.
cat > "$T/badname.lyx" <<'EOF'
unit badname;

pub fn RufFremd(a: int64): int64 {
  return sys_arch_prctl(a, 0);
}
EOF
if uebersetze "$T/badname.lyx" lyxos; then
  bad "Gegenseite Name" "ein erreichbarer zielfremder Name wurde angenommen"
else
  ok "lyxos: erreichbar zielfremder Name wird weiter abgewiesen"
fi

# 5) Die Faltung darf nicht an TARGET_OS haengen: eine gewoehnliche
#    Modulkonstante waehlt denselben Weg. Sonst waere die Regel eine
#    Sonderbehandlung und beim naechsten Fall wieder offen.
cat > "$T/con.lyx" <<'EOF'
unit con_zweig;

con AUF_LYXOS: int64 := 0;

pub fn Waehle(fd: int64, buf: int64, n: int64): int64 {
  if AUF_LYXOS == 1 {
    return sys_sendto(fd, buf, n, 0, 0, 0);
  } else {
    return 0;
  }
}
EOF
if uebersetze "$T/con.lyx" lyxos; then
  ok "eine gewoehnliche con waehlt denselben Weg -- keine Sonderbehandlung"
else
  bad "con-Zweig" "$(grep -m1 'lyxc:' "$T/log")"
fi

# 6) Die WIRKUNG am Bestand: eine Unit, die std.net.socket nur mittelbar
#    importiert, liess sich vorher nicht fuer lyxos vorkompilieren (70 solche
#    Faelle). Gemessen an einer echten Datei, nicht an einer Nachbildung.
if [ -f std/cloud/cf/kv.lyx ]; then
  if uebersetze std/cloud/cf/kv.lyx lyxos; then
    ok "std/cloud/cf/kv.lyx laesst sich fuer lyxos vorkompilieren"
  else
    bad "Bestand" "std/cloud/cf/kv.lyx: $(grep -m1 'lyxc:' "$T/log")"
  fi
else
  echo "SKIP std/cloud/cf/kv.lyx fehlt"
fi

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "OK: faltbarer Zweig wird nicht gesenkt, die Gates bleiben beidseitig scharf (#2513)"
