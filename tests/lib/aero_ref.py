#!/usr/bin/env python3
"""Unabhaengige Referenz fuer std.aero.

Rechnet dieselben Groessen wie die Lyx-Units NEU und vergleicht sie mit der
Ausgabe des Pruefprogramms. Die Formeln stehen hier ein zweites Mal und
ausdruecklich anders geschrieben, damit ein Denkfehler nicht in beiden
Fassungen steckt: die Lyx-Unit rechnet den Druck ueber PowF64 auf das
Temperaturverhaeltnis, hier steht die Exponentialform.

Aufruf:  aero_ref.py <ausgabe-der-sonde>
Rueckgabe 0 = alles im Rahmen, 1 = mindestens eine Abweichung.
"""
import math
import sys

# ── ICAO-Standardatmosphaere ────────────────────────────────────────────────
T0 = 288.15
P0 = 101325.0
RHO0 = 1.225
L = 0.0065
G = 9.80665
R = 287.05287
KAPPA = 1.4
H_TROPO = 11000.0
T_TROPO = 216.65

FT = 0.3048
NM = 1852.0
KT = NM / 3600.0


def isa_t(h):
    return T0 - L * h if h <= H_TROPO else T_TROPO


def isa_p(h):
    if h <= H_TROPO:
        # Exponentialform ueber den Logarithmus — bewusst anders geschrieben
        # als die Potenzform in der Unit.
        return P0 * math.exp((G / (R * L)) * math.log(1.0 - L * h / T0))
    p_tropo = P0 * math.exp((G / (R * L)) * math.log(1.0 - L * H_TROPO / T0))
    return p_tropo * math.exp(-G * (h - H_TROPO) / (R * T_TROPO))


def isa_rho(h):
    return isa_p(h) / (R * isa_t(h))


def a_of_t(t):
    return math.sqrt(KAPPA * R * t)


A0 = a_of_t(T0)


def cas_to_mach(cas_kt, h_m):
    cas = cas_kt * KT
    qc = P0 * ((1.0 + 0.2 * (cas / A0) ** 2) ** 3.5 - 1.0)
    p = isa_p(h_m)
    return math.sqrt(5.0 * ((qc / p + 1.0) ** (2.0 / 7.0) - 1.0))


def cas_to_tas(cas_kt, h_m, oat_c):
    m = cas_to_mach(cas_kt, h_m)
    return m * a_of_t(oat_c + 273.15) / KT


def dichtehoehe(hp_m, oat_c):
    rho = isa_p(hp_m) / (R * (oat_c + 273.15))
    exp = 1.0 / (G / (R * L) - 1.0)
    return (T0 / L) * (1.0 - (rho / RHO0) ** exp)


# ── Flugleistung ────────────────────────────────────────────────────────────

def sinkrate_fpm(gs_kt, winkel_grad):
    # ft/min = kt * (NM/ft) / 60 * tan
    return gs_kt * (NM / FT) / 60.0 * math.tan(math.radians(winkel_grad))


def kurvenradius_nm(tas_kt, bank_grad):
    v = tas_kt * KT
    return (v * v / (G * math.tan(math.radians(bank_grad)))) / NM


def kurvenrate(tas_kt, bank_grad):
    v = tas_kt * KT
    return math.degrees(G * math.tan(math.radians(bank_grad)) / v)


def vorhalt_nm(tas_kt, bank_grad, dpsi):
    return kurvenradius_nm(tas_kt, bank_grad) * math.tan(math.radians(abs(dpsi) / 2.0))


def tod_strecke_nm(h1_ft, h2_ft, ld, tas_kt, wind_kt):
    dh_nm = (h1_ft - h2_ft) * FT / NM
    still = ld * dh_nm
    return still * (tas_kt + wind_kt) / tas_kt


def punkt_gleicher_zeit(d_nm, tas, wind):
    vh, vz = tas + wind, tas - wind
    return d_nm * vz / (vh + vz)


# ── Erwartungswerte ─────────────────────────────────────────────────────────
# Name -> (Wert, zusaetzliche Toleranz).
#
# DIE GRENZE SETZT DIE AUSGABE, NICHT DIE PHYSIK. Die Sonde gibt mit PrintF64
# sechs Nachkommastellen aus; 288,15 erscheint dort als "288.149999". Eine
# Toleranz von 1e-9 misst deshalb nicht die Rechnung, sondern den Drucker —
# gemessen wurden Differenzen bis 1,4e-6 allein aus der Darstellung.
#
# Deshalb gilt eine Grundtoleranz von 2e-6 ABSOLUT, dazu ein relativer Anteil
# von 1e-8 fuer grosse Werte (bei 100000 Pa waeren 2e-6 absolut schaerfer als
# die Ausgabe hergibt). Die Werte in der Tabelle sind ZUSAETZLICHE Toleranz
# fuer Groessen, die aus einer Bisektion oder Integration kommen und deshalb
# von sich aus ungenauer sind.
#
# Wer diese Zahlen enger stellt, misst wieder die Ausgabe. Wer sie weiter
# stellt, muss dazusagen, warum.
GRUND_ABS = 2e-6
GRUND_REL = 1e-8

ERWARTET = {
    "isa_t_0":           (isa_t(0.0), 0.0),
    "isa_p_0":           (isa_p(0.0), 0.0),
    "isa_rho_0":         (isa_rho(0.0), 0.0),
    "isa_t_11000":       (isa_t(11000.0), 0.0),
    "isa_p_11000":       (isa_p(11000.0), 0.0),
    "isa_p_20000":       (isa_p(20000.0), 0.0),
    "isa_rho_5000":      (isa_rho(5000.0), 0.0),
    "a_sl_kt":           (A0 / KT, 0.0),
    "mach_300_10668":    (cas_to_mach(300.0, 10668.0), 0.0),
    "tas_300_10668":     (cas_to_tas(300.0, 10668.0, -50.0), 0.0),
    # Die Dichtehoehe ist von Natur aus ungenauer, und zwar NACHGEMESSEN:
    # h = (T0/L)·(1 - x) mit x = (rho/rho0)^(1/4,2559). Bei Meereshoehe ist
    # x ~ 0,976, die Differenz 1-x also ~0,024 — zwei Stellen Ausloeschung —
    # und der Vorfaktor 44331 verstaerkt den Rest. Ein relativer Fehler von
    # 1e-8 in der Potenz wird so zu 4,4e-4 in Metern. Genau diese Groesse
    # wurde zwischen Lyx und Python gemessen (0,00043 bei 525,46 m).
    #
    # PowF64 selbst ist nicht schuld: auf Anzeigegenauigkeit stimmen beide
    # ueberein (0.975962 hier wie dort). Die Toleranz bildet die Ausloeschung
    # ab, nicht eine Schwaeche der Bibliothek.
    "dichtehoehe_0_30":  (dichtehoehe(0.0, 30.0), 1e-3),
    "sinkrate_140_3":    (sinkrate_fpm(140.0, 3.0), 0.0),
    "radius_250_25":     (kurvenradius_nm(250.0, 25.0), 0.0),
    "rate_250_25":       (kurvenrate(250.0, 25.0), 0.0),
    "vorhalt_250_25_90": (vorhalt_nm(250.0, 25.0, 90.0), 0.0),
    "tod_35000_3000":    (tod_strecke_nm(35000.0, 3000.0, 17.0, 280.0, 30.0), 0.0),
    "etp_1000_450_50":   (punkt_gleicher_zeit(1000.0, 450.0, 50.0), 0.0),
}


def main():
    if len(sys.argv) < 2:
        print("Aufruf: aero_ref.py <ausgabedatei>")
        return 2
    werte = {}
    for zeile in open(sys.argv[1]):
        zeile = zeile.strip()
        if "=" not in zeile:
            continue
        name, _, wert = zeile.partition("=")
        name = name.strip()
        try:
            werte[name] = float(wert.strip())
        except ValueError:
            continue

    fehler = 0
    geprueft = 0
    for name, (soll, tol) in ERWARTET.items():
        if name not in werte:
            print(f"FEHLT   {name}")
            fehler += 1
            continue
        ist = werte[name]
        abw = abs(ist - soll)
        geprueft += 1
        erlaubt = max(GRUND_ABS, abs(soll) * GRUND_REL) + tol
        if abw > erlaubt:
            print(f"ABWEICHUNG {name}: Lyx={ist!r} Referenz={soll!r} "
                  f"Differenz={abw:.6g} erlaubt={erlaubt:g}")
            fehler += 1

    if fehler:
        print(f"{fehler} Abweichung(en) bei {len(ERWARTET)} Groessen")
        return 1
    print(f"{geprueft} Groessen gegen die Referenz gehalten, keine Abweichung")
    return 0


if __name__ == "__main__":
    sys.exit(main())
