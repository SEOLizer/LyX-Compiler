#!/usr/bin/env python3
"""
gen_lic_secret.py — WP-LIC-13: Neue Master-Secret-Werte für lic_secret.lyx erzeugen.

Verwendung:
  python3 tools/gen_lic_secret.py

Gibt einen fertigen Ersatz für src/crypto/lic_secret.lyx-Konstanten aus.
Das echte Secret S wird NICHT ausgegeben — nur die gemischten Werte P und N.
"""
import os, struct, textwrap

def rand_int64():
    """Kryptographisch zufälligen int64-Wert erzeugen."""
    raw = os.urandom(8)
    val = struct.unpack('<Q', raw)[0]  # unsigned 64-bit
    if val >= 2**63:                   # als signed ausgeben
        val -= 2**64
    return val

def to_hex16(v):
    """Signed int64 als 16-stelligen Hex-String (mit Vorzeichen-Korrektur)."""
    if v < 0:
        v += 2**64
    return f"0x{v:016x}"

def xor64(a, b):
    """XOR zweier signed int64-Werte."""
    ua = a if a >= 0 else a + 2**64
    ub = b if b >= 0 else b + 2**64
    r = ua ^ ub
    return r if r < 2**63 else r - 2**64

print("Generiere neues Master-Secret...")
print()

# Erzeuge Secret S (4 × int64) — wird NICHT gespeichert
S = [rand_int64() for _ in range(4)]

# Erzeuge Masken N (4 × int64) — werden gespeichert
N = [rand_int64() for _ in range(4)]

# Berechne maskierte Werte P = S XOR N — werden gespeichert
P = [xor64(s, n) for s, n in zip(S, N)]

# Verifikation
for i in range(4):
    assert xor64(P[i], N[i]) == S[i], f"Verifikation fehlgeschlagen für i={i}"

# Ausgabe der Konstanten in zufälliger Reihenfolge
# (P0 und N0 stehen nie direkt nebeneinander)
order = [
    ("_LYC_CHK_VECTOR",  "P0 = S0 ^ N0", P[0]),
    ("_LYC_PARSE_SALT",  "N1 = Maske S1", N[1]),
    ("_LYC_CG_FPRINT",   "P2 = S2 ^ N2", P[2]),
    ("_LYC_VER_STAMP",   "N3 = Maske S3", N[3]),
    ("_LYC_BUILD_ID_A",  "N0 = Maske S0", N[0]),
    ("_LYC_EMIT_SEED",   "P1 = S1 ^ N1", P[1]),
    ("_LYC_CG_ID_LOW",   "N2 = Maske S2", N[2]),
    ("_LYC_VER_XSUM",    "P3 = S3 ^ N3", P[3]),
]

print("Ersetze die con-Definitionen in src/crypto/lic_secret.lyx:")
print()
for name, comment, val in order:
    print(f"con {name}: int64 := {to_hex16(val)};  // {comment}")

print()
print("Secret S (NIEMALS committen, NIEMALS ausgeben):")
for i, v in enumerate(S):
    print(f"  S{i} = {to_hex16(v)}")

print()
print("WICHTIG: Das Secret S sicher aufbewahren (z.B. Passwort-Manager).")
print("         Nur P und N kommen in den Code.")
