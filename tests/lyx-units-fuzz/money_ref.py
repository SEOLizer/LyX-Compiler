#!/usr/bin/env python3
"""Unabhaengige Referenz fuer std.money.

Liest die Ausgabe von tests/money_fuzz.lyx und rechnet jede Operation mit
Pythons decimal-Modul nach — derselben Referenz, an der sich auch Java
BigDecimal und ISO 4217 orientieren. decimal rechnet exakt in Dezimalstellen
und kennt genau die sieben Rundungsarten der Unit.

Aus der Lyx-Ausgabe werden nur die EINGABEN uebernommen; jedes verglichene
Ergebnis wird hier neu gerechnet.
"""
import sys
from decimal import (Decimal, localcontext, ROUND_HALF_UP, ROUND_HALF_EVEN,
                     ROUND_HALF_DOWN, ROUND_UP, ROUND_DOWN, ROUND_FLOOR,
                     ROUND_CEILING)

INVALID = -(2 ** 63)

# Reihenfolge wie MONEY_HALF_UP .. MONEY_CEIL in std/money.lyx
MODES = [ROUND_HALF_UP, ROUND_HALF_EVEN, ROUND_HALF_DOWN,
         ROUND_UP, ROUND_DOWN, ROUND_FLOOR, ROUND_CEILING]
NAMES = "HALF_UP HALF_EVEN HALF_DOWN UP DOWN FLOOR CEIL".split()


def divround(num, den, mode):
    """num/den als ganze Zahl, nach `mode` gerundet"""
    with localcontext() as ctx:
        ctx.prec = 60
        q = Decimal(num) / Decimal(den)
        return int(q.quantize(Decimal(1), rounding=MODES[mode]))


def fmt(v, scale, style):
    """MoneyFormat nachgebaut: 0=plain 1=de 2=en 3=ch"""
    dec, grp = ".", ""
    if style == 1:
        dec, grp = ",", "."
    elif style == 2:
        dec, grp = ".", ","
    elif style == 3:
        dec, grp = ".", "'"

    neg = v < 0
    digits = str(abs(v)).rjust(scale + 1, "0")
    ipart = digits[:len(digits) - scale] if scale else digits
    fpart = digits[len(digits) - scale:] if scale else ""

    if grp:
        out, cnt = [], 0
        for ch in reversed(ipart):
            if cnt and cnt % 3 == 0:
                out.append(grp)
            out.append(ch)
            cnt += 1
        ipart = "".join(reversed(out))

    s = ipart + (dec + fpart if scale else "")
    return ("-" + s) if neg else s


def main(path):
    fails = checks = 0
    counts = {}

    def bump(kind):
        counts[kind] = counts.get(kind, 0) + 1

    def cmp(kind, what, got, want):
        nonlocal fails, checks
        checks += 1
        if got != want:
            fails += 1
            print(f"FAIL {kind} {what}: lyx={got} ref={want}")

    for ln in open(path):
        parts = ln.split()
        if not parts:
            continue
        kind, vals = parts[0], parts[1:]

        if kind == "DIV":
            num, den, mode, got = (int(x) for x in vals)
            bump("DIV")
            cmp("DIV", f"{num}/{den} {NAMES[mode]}", got, divround(num, den, mode))

        elif kind == "TAX":
            gross, rate, mode, gotTax, gotNaive = (int(x) for x in vals)
            bump("TAX")
            # Steuer im Bruttobetrag: gross*rate / (10^4 + rate)
            cmp("TAX", f"{gross}@{rate}", gotTax,
                divround(gross * rate, 10000 + rate, mode))
            # naiver Aufschlag zum Vergleich: gross*rate / 10^4
            cmp("TAX", f"naive {gross}@{rate}", gotNaive,
                divround(gross * rate, 10000, mode))
            # Der naive Aufschlag darf nie KLEINER sein als der korrekte
            # Anteil; bei sehr kleinen Saetzen fallen beide nach der Rundung
            # zusammen, darueber wird die Luecke sichtbar.
            checks += 1
            if gotNaive < gotTax:
                fails += 1
                print(f"FAIL TAX naive smaller: {gotNaive} < {gotTax}")

        elif kind == "SCALE":
            v, fs, ts, mode, got = (int(x) for x in vals)
            bump("SCALE")
            if ts >= fs:
                want = v * 10 ** (ts - fs)
            else:
                want = divround(v, 10 ** (fs - ts), mode)
            cmp("SCALE", f"{v} {fs}->{ts} {NAMES[mode]}", got, want)

        elif kind == "SPLIT":
            total, n = int(vals[0]), int(vals[1])
            shares = [int(x) for x in vals[2:2 + n]]
            bump("SPLIT")
            checks += 1
            if sum(shares) != total:
                fails += 1
                print(f"FAIL SPLIT sum {sum(shares)} != {total}")
            # gleichmaessig: hoechstens ein Cent Unterschied zwischen Anteilen
            checks += 1
            if shares and (max(shares) - min(shares)) > 1:
                fails += 1
                print(f"FAIL SPLIT uneven {shares}")
            # absteigend: die ersten bekommen den Rest
            checks += 1
            if shares != sorted(shares, reverse=(total >= 0)):
                fails += 1
                print(f"FAIL SPLIT order {shares}")

        elif kind == "ALLOC":
            total, n = int(vals[0]), int(vals[1])
            weights = [int(x) for x in vals[2:2 + n]]
            shares = [int(x) for x in vals[2 + n:2 + 2 * n]]
            bump("ALLOC")
            if len(shares) != n:
                checks += 1
                fails += 1
                print(f"FAIL ALLOC missing shares for {total} {weights}")
                continue
            checks += 1
            if sum(shares) != total:
                fails += 1
                print(f"FAIL ALLOC sum {sum(shares)} != {total}")
            # Gewicht null bekommt nichts
            checks += 1
            if any(s != 0 for s, w in zip(shares, weights) if w == 0):
                fails += 1
                print(f"FAIL ALLOC zero weight got money {weights} {shares}")
            # jeder Anteil hoechstens einen Cent ueber dem exakten Wert
            wsum = sum(weights)
            checks += 1
            a = abs(total)
            for s, w in zip(shares, weights):
                exact = Decimal(a * w) / Decimal(wsum)
                if not (exact - 1 < abs(s) <= exact + 1):
                    fails += 1
                    print(f"FAIL ALLOC share {s} off exact {exact}")
                    break

        elif kind == "FMT":
            v, scale, style = (int(x) for x in vals[:3])
            got = vals[3] if len(vals) > 3 else ""
            bump("FMT")
            cmp("FMT", f"{v} s={scale} f={style}", got, fmt(v, scale, style))

    summary = " ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    print(f"cases: {summary}")
    print(f"checks={checks} fails={fails} ref=python-decimal")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
