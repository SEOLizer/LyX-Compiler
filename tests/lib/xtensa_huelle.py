#!/usr/bin/env python3
"""tests/lib/xtensa_huelle.py — Xtensa-Pruefhuelle (#1786).

 nimmt den .text eines --target=esp32-Erzeugnisses und
macht daraus ein Linux-User-ELF, das unter qemu-xtensa-static laeuft.

Warum: das Backend erzeugt ein ESP32-Abbild fuer IRAM 0x40080000. Der
User-Mode-Emulator reicht nur bis 0x3fffffff, und ein blankes Abbild hat
ohnehin keinen Weg, ein Ergebnis zu melden. Die Huelle legt denselben Code an
eine niedrige Adresse und stellt einen Rumpf davor, der main ruft und den
Rueckgabewert per exit-Syscall meldet.

Xtensa-Linux-Konvention (empirisch an qemu 8.2 ermittelt):
  Syscall-Nummer in a2, Argumente in a6, a3, a4, a5 — write = 13, exit = 118.

Der Code selbst wird NICHT veraendert: Aufrufe sind PC-relativ, Literale
ebenso. Geprueft wird damit der Emitter, nicht der Ladeort.
"""
import struct, sys, os

BASE = 0x00400000
HDR  = 0x1000

def movi(r, imm):
    imm &= 0xFFF
    return bytes([(r << 4) | 2, 0xA0 | ((imm >> 8) & 0xF), imm & 0xFF])

def call0(delta):
    # CALL0: Ziel relativ zu (PC & ~3) + 4, in Wortschritten
    off18 = delta >> 2
    return bytes([((off18 & 3) << 6) | 5, (off18 >> 2) & 0xFF, (off18 >> 10) & 0xFF])

def mov(dst, src):          # OR ar, as, at  (ar = as | as)
    return bytes([(src << 4) | 0, (dst << 4) | src, 0x20])

SYSCALL = bytes([0x00, 0x50, 0x00])

def wrap(text, main_off, out):
    # Rumpf: SP setzen, main rufen, Ergebnis nach a6, exit(118)
    stub  = movi(1, 0)                      # a1 (SP) — wird gleich ersetzt
    stub  = b""
    # a1 = Stapelspitze: der Lader setzt sie bereits, also unangetastet lassen.
    stub += b""                             # kein Prolog noetig
    stub_len = 3 + 3 + 3 + 3                # call0 + mov + movi + syscall
    # CALL0 rechnet ab (PC & ~3) + 4
    pc = BASE + HDR
    ziel = BASE + HDR + stub_len + main_off
    delta = ziel - ((pc & ~3) + 4)
    stub  = call0(delta)
    stub += mov(6, 2)                       # a6 = Rueckgabewert von main
    stub += movi(2, 118)                    # a2 = exit
    stub += SYSCALL
    assert len(stub) == stub_len, (len(stub), stub_len)

    code = stub + text
    eh = struct.pack('<4sBBBBQ HHI III I HHHHHH', b'\x7fELF', 1, 1, 1, 0, 0,
                     2, 94, 1, BASE + HDR, 52, 0, 0x100, 52, 32, 1, 40, 0, 0)
    ph = struct.pack('<IIIIIIII', 1, HDR, BASE + HDR, BASE + HDR,
                     len(code), len(code), 7, 0x1000)
    buf = eh + ph
    buf += b'\0' * (HDR - len(buf)) + code
    open(out, 'wb').write(buf)
    os.chmod(out, 0o755)

if __name__ == '__main__':
    quelle, ziel = sys.argv[1], sys.argv[2]
    roh = open(quelle, 'rb').read()
    entry = struct.unpack('<I', roh[24:28])[0]
    main_off = entry - 0x40080000
    wrap(roh[HDR:], main_off, ziel)
    print("main-Offset %d, %d Byte Code" % (main_off, len(roh) - HDR))
