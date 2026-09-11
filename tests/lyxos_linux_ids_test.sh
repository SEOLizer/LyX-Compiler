#!/usr/bin/env bash
# tests/lyxos_linux_ids_test.sh — #2024: die IDs 172...198 gab es nur fuer
# lyxos, und ihre Stelligkeitspruefungen griffen auch beim Ziel arm64/riscv.
#
# 63 der 97 stdlib-Fehlschlaege gingen darauf zurueck — der groesste Posten.
#
# DIE ENTSCHEIDUNG, die das Issue offenliess: die Linux-Formen bekommen EIGENE
# IDs (472...493). Dieselbe ID kann nicht zwei Stelligkeiten tragen — `sendto`
# nimmt unter LyxOS vier Argumente, unter Linux sechs. ir_lower waehlt nach
# Ziel.
#
# GEMESSEN WIRD DIE WIRKUNG, und zwar mit unabhaengig nachpruefbaren Werten:
# `uname` muss "Linux" liefern, `access` auf eine vorhandene Datei 0 und auf
# eine fehlende -2 (ENOENT). Das ENOENT ist der eigentliche Nachweis — es
# zeigt, dass der Aufruf ausgefuehrt wird UND den Pfad sieht. Eine falsche
# Syscall-Nummer uebersetzt genauso sauber und liefert dann still das Falsche.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

QEMU_ARM=""; QEMU_RV=""
command -v qemu-aarch64-static >/dev/null 2>&1 && QEMU_ARM="qemu-aarch64-static"
command -v qemu-riscv64-static >/dev/null 2>&1 && QEMU_RV="qemu-riscv64-static"

lauf() {
  local ziel="$1"
  local src="$2"
  local out="$3"
  local bin="$TMP/b_$ziel"
  ( cd "$ROOT" && timeout 180 "$LYXC" --target="$ziel" "$src" -o "$bin" ) >"$TMP/build_$ziel.log" 2>&1 || return 1
  case "$ziel" in
    x86_64) timeout 60 "$bin" >"$out" 2>&1 ;;
    arm64)  [ -n "$QEMU_ARM" ] || return 2; timeout 60 $QEMU_ARM "$bin" >"$out" 2>&1 ;;
    riscv)  [ -n "$QEMU_RV" ]  || return 2; timeout 60 $QEMU_RV  "$bin" >"$out" 2>&1 ;;
  esac
  return 0
}

echo "--- #2024: uname und access liefern nachpruefbare Werte ---"
cat > "$TMP/u.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var buf: int64 := alloc(512);
  PrintLn(IntToStr(sys_uname(buf)));
  PrintLn(buf as pchar);
  PrintLn(IntToStr(sys_access("/etc/hostname"c, 0)));
  PrintLn(IntToStr(sys_access("/gibt/es/ganz/sicher/nicht"c, 0)));
  return 0;
}
EOF
# Nachgerechnet: uname gibt 0 und legt als ERSTES Feld den Systemnamen ab
# ("Linux"); access auf eine vorhandene Datei 0, auf eine fehlende -2 (ENOENT).
ERW="0|Linux|0|-2|"
for ziel in x86_64 arm64 riscv; do
  lauf "$ziel" "$TMP/u.lyx" "$TMP/u.$ziel"; rc=$?
  if [ "$rc" = 2 ]; then
    nok "$ziel: qemu fehlt — die Wirkung wurde NICHT gemessen"
  elif [ "$rc" != 0 ]; then
    nok "$ziel: uebersetzt nicht ($(grep -m1 -E 'error|unbekannt|erwartet' "$TMP/build_$ziel.log"))"
  else
    ist="$(tr '\n' '|' < "$TMP/u.$ziel")"
    if [ "$ist" = "$ERW" ]; then
      ok "$ziel: uname liefert Linux, access 0 bzw. -2 (ENOENT)"
    else
      nok "$ziel: [$ist] statt [$ERW]"
    fi
  fi
done

echo
echo "--- #2024: access wird zu faccessat(AT_FDCWD, …) ---"
#
# Der ENOENT-Fall oben zeigt schon, dass der Pfad ankommt. Hier zusaetzlich ein
# RELATIVER Pfad: nur mit AT_FDCWD als dirfd wirkt er wie bei access. Stuende
# dort eine andere Zahl, faende der Aufruf die Datei nicht.
cat > "$TMP/rel.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  PrintLn(IntToStr(sys_access("marke.txt"c, 0)));
  return 0;
}
EOF
echo x > "$TMP/marke.txt"
for ziel in x86_64 arm64 riscv; do
  bin="$TMP/rel_$ziel"
  if ( cd "$ROOT" && timeout 180 "$LYXC" --target="$ziel" "$TMP/rel.lyx" -o "$bin" ) >"$TMP/rel.log" 2>&1; then
    case "$ziel" in
      x86_64) aus="$( cd "$TMP" && timeout 60 "$bin" 2>&1 )" ;;
      arm64)  [ -n "$QEMU_ARM" ] && aus="$( cd "$TMP" && timeout 60 $QEMU_ARM "$bin" 2>&1 )" || aus="KEINQEMU" ;;
      riscv)  [ -n "$QEMU_RV" ]  && aus="$( cd "$TMP" && timeout 60 $QEMU_RV  "$bin" 2>&1 )" || aus="KEINQEMU" ;;
    esac
    if [ "$aus" = "0" ]; then
      ok "$ziel: relativer Pfad wird gefunden (AT_FDCWD stimmt)"
    else
      nok "$ziel: relativer Pfad ergab '$aus' statt 0"
    fi
  else
    nok "$ziel: das Pruefprogramm uebersetzt nicht"
  fi
done

echo
echo "--- #2024: die LyxOS-Seite bleibt unberuehrt ---"
#
# DIE WICHTIGSTE GEGENPROBE. Die Stelligkeitspruefungen der LyxOS-ABI sind
# richtig — sie galten nur am falschen Ort. Ein `sendto` mit SECHS Argumenten
# ist die Linux-Form und muss fuer lyxos weiterhin abgewiesen werden; ohne
# diese Haelfte waere der Test auch von einer Fassung erfuellt, die die
# Pruefungen einfach geloescht hat.
cat > "$TMP/s6.lyx" <<'EOF'
unit main;
fn main(): int64 { return sys_sendto(1, 0, 0, 0, 0, 0); }
EOF
if ( cd "$ROOT" && timeout 180 "$LYXC" --target=lyxos --std-path="$ROOT" "$TMP/s6.lyx" -o "$TMP/s6.lbf" ) >"$TMP/s6.log" 2>&1; then
  nok "sendto mit sechs Argumenten ging fuer lyxos durch — die LyxOS-Stelligkeit wird nicht mehr geprueft"
else
  if grep -q "erwartet auf LyxOS genau 4" "$TMP/s6.log"; then
    ok "lyxos weist sendto mit sechs Argumenten weiterhin ab (LyxOS-ABI: vier)"
  else
    nok "lyxos-Abweisung mit anderer Begruendung: $(grep -m1 -E 'error|lyxc:' "$TMP/s6.log")"
  fi
fi

# Und die Linux-Form mit sechs Argumenten muss fuer arm64 GEHEN — das ist die
# andere Haelfte derselben Frage.
if ( cd "$ROOT" && timeout 180 "$LYXC" --target=arm64 "$TMP/s6.lyx" -o "$TMP/s6.arm" ) >"$TMP/s6a.log" 2>&1; then
  ok "arm64 uebersetzt sendto mit sechs Argumenten (Linux-Form)"
else
  nok "arm64 lehnt die Linux-Form ab: $(grep -m1 -E 'error|erwartet' "$TMP/s6a.log")"
fi

echo
echo "--- #2024: udp_open/udp_close werden BENANNT abgewiesen ---"
#
# Sie sind LyxOS-eigen (dort ein einziger Aufruf, unter Linux socket+bind) und
# werden in der GESAMTEN stdlib von niemandem benutzt. Eine Naeherung zu bauen,
# die keiner braucht, waere die schlechtere Wahl — aber die Meldung muss den
# Grund nennen, nicht "unbekannter Builtin".
cat > "$TMP/udp.lyx" <<'EOF'
unit main;
fn main(): int64 { return sys_udp_close(0); }
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" --target=arm64 "$TMP/udp.lyx" -o "$TMP/udp.bin" ) >"$TMP/udp.log" 2>&1; then
  nok "sys_udp_close uebersetzte fuer arm64 — gibt es die Abbildung jetzt? Dann diesen Test auf die WIRKUNG umstellen"
else
  if grep -q "gibt es auf diesem Ziel nicht" "$TMP/udp.log"; then
    ok "sys_udp_close wird mit Begruendung abgewiesen"
  else
    nok "abgewiesen, aber ohne den Grund zu nennen: $(grep -m1 -E 'error|lyxc:' "$TMP/udp.log")"
  fi
fi

echo
echo "--- #2024: betroffene stdlib-Units uebersetzen ---"
# std/fs_ext.lyx haengt zusaetzlich an sys_sendfile — einem der 50 Namen aus
# #2021, die noch fehlen. Es gehoert hier erst hinein, wenn die zu sind.
# std/security_ext.lyx ist NICHT dabei: es haengt an sys_arch_prctl, das es in
# der generischen ABI nicht gibt und das deshalb benannt abgewiesen wird.
for u in std/sched.lyx std/net/dns.lyx std/hardware/bluetooth_gattc.lyx; do
  if ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --target=arm64 "$u" -o /dev/null ) >"$TMP/u2.log" 2>&1; then
    ok "$(basename "$u") uebersetzt fuer arm64"
  else
    nok "$(basename "$u") fuer arm64: $(grep -m1 -E 'error|unbekannt|erwartet' "$TMP/u2.log")"
  fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
