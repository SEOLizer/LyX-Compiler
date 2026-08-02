#!/usr/bin/env bash
# Ganzzahlbreiten: ein Wert, der breiter ist als der deklarierte Typ, muss beim
# Speichern gekuerzt werden. int8(130) ist -126, uint8 250 bleibt 250, die Summe
# wird auf 64 Bit gerechnet: -126 + 250 = 124.
#
# Der Test lief nie: er lag in einem Unterverzeichnis, das die Abdeckungspruefung
# nicht sah (#1112), und zeigte auf tests/lyx/misc/int_widths.lyx — einen Pfad,
# den es nicht mehr gibt. Beim ersten echten Lauf war er rot: die Kuerzung findet
# nicht statt (#1151). Er ist deshalb in tests/known-red.txt gefuehrt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tests/regression/misc/int_widths.lyx"
OUT=/tmp/int_widths_test

if [ ! -x "$ROOT/lyxc" ]; then
  echo "FAIL lyxc fehlt — vorher 'make bootstrap'"
  exit 1
fi

"$ROOT/lyxc" --std-path="$ROOT" "$SRC" -o "$OUT" >/dev/null 2>&1
OUTPUT=$("$OUT" | tr -d '\r')
if [ "$OUTPUT" = "124" ]; then
  echo "PASS int_widths: $OUTPUT"
  exit 0
else
  echo "FAIL int_widths: erwartet 124, bekommen '$OUTPUT'"
  exit 2
fi
