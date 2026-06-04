#!/usr/bin/env python3
"""
gen_lic_secret.py — WP-LIC-13 / WP-16: Neue Master-Secret-Werte erzeugen.

WP-16.1: Das rohe Secret S wird NICHT auf stdout ausgegeben (kein Scrollback,
         keine Shell-History). Stattdessen wird es in eine Datei mit
         exklusiven 600-Permissions geschrieben.

WP-16.2: Direktausgabe nur mit explizitem --show-secret auf stderr + Warnung.

Verwendung:
  python3 tools/gen_lic_secret.py [Optionen]

Optionen:
  --secret-file PATH   Pfad für die Secret-Datei
                       (Standard: ~/.lyx/master.secret)
  --show-secret        Gibt das Secret ZUSÄTZLICH auf stderr aus (mit Warnung)
  --force              Überschreibt eine vorhandene Secret-Datei ohne Rückfrage
"""

import os
import sys
import stat
import struct
import argparse
import datetime


# ---------------------------------------------------------------------------
# Kryptographie-Hilfsfunktionen
# ---------------------------------------------------------------------------

def rand_int64():
    """Kryptographisch zufälligen int64-Wert erzeugen (os.urandom)."""
    raw = os.urandom(8)
    val = struct.unpack('<Q', raw)[0]   # unsigned 64-bit
    if val >= 2**63:                    # als signed int64 ausgeben
        val -= 2**64
    return val


def to_hex16(v):
    """Signed int64 als 16-stelligen Hex-String."""
    if v < 0:
        v += 2**64
    return f"0x{v:016x}"


def xor64(a, b):
    """XOR zweier signed int64-Werte."""
    ua = a if a >= 0 else a + 2**64
    ub = b if b >= 0 else b + 2**64
    r  = ua ^ ub
    return r if r < 2**63 else r - 2**64


# ---------------------------------------------------------------------------
# WP-16.1: Secret sicher in Datei schreiben
# ---------------------------------------------------------------------------

def write_secret_file(secret_values, path, force=False):
    """
    Schreibt das Master-Secret in path mit Permissions 600.
    Bricht ab wenn die Datei bereits existiert (--force überschreibt).
    """
    # Verzeichnis anlegen falls nötig
    dir_path = os.path.dirname(os.path.abspath(path))
    if dir_path:
        os.makedirs(dir_path, exist_ok=True)

    abs_path = os.path.abspath(path)

    if os.path.exists(abs_path) and not force:
        print(
            f"FEHLER: {abs_path} existiert bereits.\n"
            "Verwende --force um zu überschreiben.",
            file=sys.stderr,
        )
        sys.exit(1)

    # WP-16.1: Datei mit 600-Permissions atomar erstellen
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    try:
        fd = os.open(abs_path, flags, 0o600)
    except OSError as e:
        print(f"FEHLER: Konnte {abs_path} nicht erstellen: {e}", file=sys.stderr)
        sys.exit(1)

    with os.fdopen(fd, 'w') as f:
        f.write("# Lyx Master Secret — VERTRAULICH\n")
        f.write("# NIEMALS committen! NIEMALS per E-Mail/Chat senden!\n")
        f.write("# Erzeugt von: tools/gen_lic_secret.py\n")
        f.write(f"# Datum:       {datetime.datetime.now().isoformat(timespec='seconds')}\n")
        f.write("#\n")
        f.write("# Format: S<i> = <hex>  (4 × int64, XOR-Basis für lic_secret.lyx)\n")
        f.write("#\n")
        for i, v in enumerate(secret_values):
            f.write(f"S{i} = {to_hex16(v)}\n")

    # Permissions explizit setzen (manche Systeme ignorieren den open-Mode)
    os.chmod(abs_path, 0o600)

    # Sanity-Check
    actual = stat.S_IMODE(os.stat(abs_path).st_mode)
    if actual != 0o600:
        print(
            f"WARNUNG: Permissions {oct(actual)} statt 0o600 — "
            "Dateisystem unterstützt ggf. keine Unix-Permissions.",
            file=sys.stderr,
        )


# ---------------------------------------------------------------------------
# WP-16.2: Optionale Direktausgabe mit starker Warnung (auf stderr)
# ---------------------------------------------------------------------------

def show_secret_with_warning(secret_values):
    """Gibt das Secret auf stderr aus, eingerahmt von deutlichen Warnungen."""
    border = "=" * 72
    print(border, file=sys.stderr)
    print("  !! SICHERHEITSWARNUNG — MASTER SECRET AUF DEM BILDSCHIRM !!",
          file=sys.stderr)
    print(border, file=sys.stderr)
    print("  Dieses Secret erscheint jetzt im Terminal-Scrollback und kann",
          file=sys.stderr)
    print("  in Shell-History, CI-Logs oder Screen-Recordings landen.",
          file=sys.stderr)
    print("  Lösche das Terminalfenster nach Gebrauch.", file=sys.stderr)
    print(border, file=sys.stderr)
    print(file=sys.stderr)
    for i, v in enumerate(secret_values):
        print(f"  S{i} = {to_hex16(v)}", file=sys.stderr)
    print(file=sys.stderr)
    print(border, file=sys.stderr)
    print("  Bewahre das Secret im Passwort-Manager auf (z.B. pass, KeePass).",
          file=sys.stderr)
    print(border, file=sys.stderr)


# ---------------------------------------------------------------------------
# Hauptprogramm
# ---------------------------------------------------------------------------

def main():
    default_path = os.path.join(
        os.path.expanduser("~"), ".lyx", "master.secret"
    )

    parser = argparse.ArgumentParser(
        description="Lyx Master-Secret erzeugen (WP-16: sicherer Umgang mit Credentials)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--secret-file",
        default=default_path,
        metavar="PATH",
        help=f"Pfad für die Secret-Datei (Standard: {default_path})",
    )
    parser.add_argument(
        "--show-secret",
        action="store_true",
        help="Secret ZUSÄTZLICH auf stderr anzeigen (mit Sicherheitswarnung)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Vorhandene Secret-Datei überschreiben",
    )
    args = parser.parse_args()

    print("Generiere neues Master-Secret ...")
    print()

    # Secret S erzeugen (4 × int64) — wird NICHT auf stdout ausgegeben
    S = [rand_int64() for _ in range(4)]

    # Masken N erzeugen
    N = [rand_int64() for _ in range(4)]

    # Maskierte Werte P = S XOR N
    P = [xor64(s, n) for s, n in zip(S, N)]

    # Verifikation
    for i in range(4):
        assert xor64(P[i], N[i]) == S[i], f"Verifikation fehlgeschlagen i={i}"

    # WP-16.1: Secret sicher in Datei schreiben
    write_secret_file(S, args.secret_file, force=args.force)
    print(f"Secret gespeichert: {os.path.abspath(args.secret_file)}")
    print("Permissions: 600 (nur für dich lesbar)")
    print()

    # Lyx-Konstanten auf stdout (P und N — enthalten das Secret NICHT im Klartext)
    order = [
        ("_LYC_CHK_VECTOR", "P0 = S0 ^ N0", P[0]),
        ("_LYC_PARSE_SALT", "N1 = Maske S1", N[1]),
        ("_LYC_CG_FPRINT",  "P2 = S2 ^ N2", P[2]),
        ("_LYC_VER_STAMP",  "N3 = Maske S3", N[3]),
        ("_LYC_BUILD_ID_A", "N0 = Maske S0", N[0]),
        ("_LYC_EMIT_SEED",  "P1 = S1 ^ N1", P[1]),
        ("_LYC_CG_ID_LOW",  "N2 = Maske S2", N[2]),
        ("_LYC_VER_XSUM",   "P3 = S3 ^ N3", P[3]),
    ]

    print("Ersetze die con-Definitionen in src/crypto/lic_secret.lyx:")
    print()
    for name, comment, val in order:
        print(f"con {name}: int64 := {to_hex16(val)};  // {comment}")

    print()
    print(
        f"WICHTIG: Das Secret liegt in: {os.path.abspath(args.secret_file)}\n"
        "         Übertrage es in einen Passwort-Manager und lösche die Datei\n"
        "         danach (oder behalte sie nur lokal, nie im Repo)."
    )

    # WP-16.2: Optionale Direktanzeige auf stderr
    if args.show_secret:
        print(file=sys.stderr)
        show_secret_with_warning(S)


if __name__ == "__main__":
    main()
