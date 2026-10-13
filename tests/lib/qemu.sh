# tests/lib/qemu.sh — die User-Mode-Emulatoren fuer arm64, riscv64 und xtensa
# finden, EINMAL und unter beiden Namen.
#
# #2048: `qemu-user-static` liefert `qemu-aarch64-static`; das Paket gibt es
# ab qemu 10 nicht mehr, der Nachfolger `qemu-user` nennt dasselbe Programm
# `qemu-aarch64`. Die Suche stand in 27 Skripten einzeln, in fuenf Formen —
# zwoelf davon kannten nur den alten Namen. Auf einem Rechner mit `qemu-user`
# liefen sie durch, ohne die Wirkung zu messen: der Emulator war da, wurde
# nur nicht gefunden, und die meisten Skripte melden das als HINWEIS und
# bleiben gruen.
#
# Verwendung — EINE Zeile:
#
#     . "$(dirname "$0")/lib/qemu.sh"
#
# Danach stehen bereit (Programmname, oder LEER, wenn keiner da ist):
#
#     QEMU_ARM64     qemu-aarch64-static | qemu-aarch64
#     QEMU_RISCV64   qemu-riscv64-static | qemu-riscv64
#     QEMU_XTENSA    qemu-xtensa-static  | qemu-xtensa
#
# Die `-static`-Form steht vorn: sie braucht keine Bibliotheken des Wirts und
# ist auf dem CI-Runner die installierte.
#
# Ob ein FEHLENDER Emulator rot ist oder nur ein Hinweis, entscheidet weiter
# jedes Skript selbst — diese Datei vereinheitlicht die Suche, nicht das
# Urteil.
#
# tests/qemu_name_test.sh wacht darueber, dass kein Skript wieder selbst sucht.

_qemu_finde() {
  local n
  for n in "$@"; do
    if command -v "$n" >/dev/null 2>&1; then printf '%s' "$n"; return 0; fi
  done
  return 0
}

QEMU_ARM64="$(_qemu_finde qemu-aarch64-static qemu-aarch64)"
QEMU_RISCV64="$(_qemu_finde qemu-riscv64-static qemu-riscv64)"
QEMU_XTENSA="$(_qemu_finde qemu-xtensa-static qemu-xtensa)"
