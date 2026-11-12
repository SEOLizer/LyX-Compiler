#!/usr/bin/env python3
"""#1339: Springt der Befehl vor einer inline abgelegten Zeichenkette genau
ueber sie hinweg?

Die Zeichenkette liegt im Codestrom; davor steht ein Sprung. Ist seine Weite
um zwei Byte falsch, laeuft der Prozessor in die Bytes hinein — beim
Uebersetzen faellt das nie auf, und ausfuehren laesst sich das Ergebnis auf
dem Buildhost nicht (kein qemu-user). Deshalb wird hier gerechnet.
"""
import sys, struct

datei, arch = sys.argv[1], sys.argv[2]
d = open(datei, 'rb').read()
i = d.find(b'hallo')
if i < 0:
    print("Zeichenkette nicht im Code gefunden", file=sys.stderr)
    sys.exit(1)
total = d.find(b'\x00', i) - i + 1     # Bytes samt abschliessender 0

if arch == 'cm':
    padded = total + (total & 1)                       # auf gerade Laenge
    b = struct.unpack('<H', d[i-2:i])[0]
    if (b >> 11) != 0x1C:
        print("kein unbedingter Sprung vor der Zeichenkette: 0x%04X" % b, file=sys.stderr)
        sys.exit(1)
    erwartet = (padded - 2) // 2
    ist = b & 0x7FF
else:
    padded = total + ((4 - (total & 3)) & 3)           # auf 4 Byte
    w = struct.unpack('<I', d[i-4:i])[0]
    if arch == 'rv':
        ist = (((w >> 21) & 0x3FF) * 2) | (((w >> 20) & 1) << 11)
    else:
        ist = (w & 0x3FFFFFF) * 4                      # arm64 B
    erwartet = 4 + padded

if ist != erwartet:
    print("Sprungweite %d, erwartet %d (Zeichenkette %d Byte, aufgefuellt %d)"
          % (ist, erwartet, total, padded), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
