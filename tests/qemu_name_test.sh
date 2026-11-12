#!/usr/bin/env bash
# tests/qemu_name_test.sh — #2048: der Emulator wird unter BEIDEN Paketnamen
# gefunden, und kein Testskript sucht wieder selbst.
#
# `qemu-user-static` nennt das Programm `qemu-aarch64-static`, der Nachfolger
# `qemu-user` (ab qemu 10) `qemu-aarch64`. Zwoelf Skripte kannten nur den
# alten Namen; auf einem Rechner mit `qemu-user` war der Emulator da, wurde
# nicht gefunden, und die Wirkung auf arm64/riscv blieb still ungemessen —
# die meisten Skripte melden das als Hinweis und bleiben gruen.
#
# Gemessen wird ohne installiertes qemu: ein leeres Verzeichnis mit
# Platzhaltern unter genau EINEM der beiden Namen steht vorn im PATH. So
# laeuft die Pruefung auf jedem Rechner gleich, auch auf einem ohne Emulator.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/tests/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# $1 Verzeichnis, danach die Namen der Platzhalter
stelle() {
  local d="$1"; shift
  mkdir -p "$d"
  local n
  for n in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$d/$n"; chmod +x "$d/$n"; done
}

# Die drei Variablen so ausgeben, wie sie ein Skript nach dem Einbinden sieht.
# PATH enthaelt NUR das Platzhalterverzeichnis — ein auf dem Rechner
# installiertes qemu darf das Ergebnis nicht faerben. `command -v` und
# `printf` sind Builtins und brauchen keinen PATH.
gefunden() {
  ( PATH="$1"; . "$LIB"; printf '%s|%s|%s' "$QEMU_ARM64" "$QEMU_RISCV64" "$QEMU_XTENSA" )
}

pruefe() {  # Beschreibung, Ist, Soll
  if [ "$2" = "$3" ]; then ok "$1"; else nok "$1: [$2] statt [$3]"; fi
}

echo "--- der Emulator wird unter jedem der beiden Namen gefunden ---"
stelle "$TMP/alt" qemu-aarch64-static qemu-riscv64-static qemu-xtensa-static
stelle "$TMP/neu" qemu-aarch64 qemu-riscv64 qemu-xtensa
stelle "$TMP/beide" qemu-aarch64-static qemu-aarch64 qemu-riscv64-static qemu-riscv64
mkdir -p "$TMP/leer"

pruefe "nur qemu-user-static (alte Namen)" "$(gefunden "$TMP/alt")" \
       "qemu-aarch64-static|qemu-riscv64-static|qemu-xtensa-static"
# Der Fall, um den es geht: vor #2048 fanden zwoelf Skripte hier nichts.
pruefe "nur qemu-user (neue Namen)" "$(gefunden "$TMP/neu")" \
       "qemu-aarch64|qemu-riscv64|qemu-xtensa"
pruefe "beide da: die -static-Form gewinnt, xtensa fehlt" "$(gefunden "$TMP/beide")" \
       "qemu-aarch64-static|qemu-riscv64-static|"
# Die andere Seite: ohne Emulator muss die Variable LEER sein. Ein Skript, das
# auf `[ -n "$QEMU_ARM64" ]` prueft, wuerde sonst ein Programm starten, das es
# nicht gibt — oder, schlimmer, das arm64-Binary direkt.
pruefe "kein Emulator: alle drei leer" "$(gefunden "$TMP/leer")" "||"

echo
echo "--- kein Testskript sucht selbst ---"
#
# Die Suche stand in 27 Skripten in fuenf Formen. Kommt ein neues dazu, das
# wieder `command -v qemu-…` schreibt, kennt es mit hoher Wahrscheinlichkeit
# nur einen der beiden Namen. Erlaubt ist der Name nur noch als TEXT — in
# Kommentaren und in Meldungen.
selbst="$(grep -nE 'qemu-(aarch64|riscv64|xtensa)' "$ROOT"/tests/*.sh \
          | grep -v "^$ROOT/tests/qemu_name_test.sh:" \
          | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
          | grep -vE '^[^:]+:[0-9]+:.*echo "[^"]*qemu-(aarch64|riscv64|xtensa)' || true)"
if [ -z "$selbst" ]; then
  ok "kein Skript unter tests/ nennt einen Emulator ausserhalb von Kommentar und Meldung"
else
  nok "diese Stellen suchen oder rufen den Emulator am Namen vorbei an lib/qemu.sh:"
  printf '%s\n' "$selbst" | sed "s|^$ROOT/||; s/^/    /"
fi

# Und umgekehrt: wer eine der Variablen benutzt, muss die Datei auch einbinden
# — sonst ist die Variable leer und der Test misst still nichts.
ohne=""
for f in "$ROOT"/tests/*.sh; do
  [ "$f" = "$ROOT/tests/qemu_name_test.sh" ] && continue
  if grep -qE '\$\{?QEMU_(ARM64|RISCV64|XTENSA)' "$f" && ! grep -qE '^\. .*lib/qemu\.sh' "$f"; then
    ohne="$ohne ${f#"$ROOT"/}"
  fi
done
if [ -z "$ohne" ]; then
  ok "jedes Skript, das QEMU_ARM64/RISCV64/XTENSA benutzt, bindet lib/qemu.sh ein"
else
  nok "benutzen die Variablen, binden lib/qemu.sh aber nicht ein:$ohne"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
