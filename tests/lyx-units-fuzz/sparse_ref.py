#!/usr/bin/env python3
"""Unabhaengige Referenz fuer std.sparse.

Liest die Ausgabe von tests/sparse_fuzz.lyx, baut die Vektoren als dichte
numpy-Felder (und, wenn vorhanden, zusaetzlich als scipy.sparse) und rechnet
Skalarprodukt, Kosinus, Winkel, Abstaende, Normen, Jaccard, Summe und
elementweises Produkt eigenstaendig nach.

Aus der Lyx-Ausgabe wird ausschliesslich das VEKTORPAAR uebernommen; jede
verglichene Zahl wird hier neu gerechnet.
"""
import sys
import numpy as np

try:
    from scipy import sparse as sp
    HAVE_SCIPY = True
except ImportError:
    HAVE_SCIPY = False

SCALE = 1_000_000_000


def q(x):
    v = float(x) * SCALE
    n = int(abs(v) + 0.5)
    return -n if v < 0 else n


def pairs(vals):
    """[nnz, i0, v0, i1, v1, ...] -> (indices, werte)"""
    nnz = vals[0]
    idx = [vals[1 + 2 * k] for k in range(nnz)]
    val = [vals[2 + 2 * k] / SCALE for k in range(nnz)]
    return idx, val


def dense(idx, val, n):
    d = np.zeros(n)
    for i, v in zip(idx, val):
        d[i] = v
    return d


def main(path):
    blocks, cur = [], None
    for ln in open(path):
        ln = ln.strip()
        if not ln:
            continue
        key, _, rest = ln.partition(" ")
        vals = [int(t) for t in rest.split()]
        if key == "CASE":
            if cur:
                blocks.append(cur)
            cur = {}
        cur[key] = vals
    if cur:
        blocks.append(cur)

    fails = checks = 0

    def cmp(cse, what, got, want, tol=2):
        nonlocal fails, checks
        checks += 1
        if abs(got - want) > tol:
            fails += 1
            print(f"FAIL case={cse} {what}: lyx={got} ref={want}")

    for b in blocks:
        cse, n = b["CASE"]
        ai, av = pairs(b["A"])
        bi, bv = pairs(b["B"])

        # Sortierung ist Vorbedingung der Unit — hier gleich mitgeprueft
        checks += 1
        if ai != sorted(set(ai)) or bi != sorted(set(bi)):
            fails += 1
            print(f"FAIL case={cse} indices not strictly ascending")

        a = dense(ai, av, n)
        bb = dense(bi, bv, n)

        dot, cos, ang, euc, man, nrm, l1, linf, jac, ovl = b["SCAL"]

        ref_dot = float(a @ bb)
        cmp(cse, "dot", dot, q(ref_dot))

        na, nb = np.linalg.norm(a), np.linalg.norm(bb)
        ref_cos = 0.0 if na < 1e-12 or nb < 1e-12 else float(
            np.clip(ref_dot / (na * nb), -1.0, 1.0))
        cmp(cse, "cosine", cos, q(ref_cos))
        cmp(cse, "angular", ang, q(float(np.arccos(np.clip(ref_cos, -1, 1)))), 4)
        cmp(cse, "euclid", euc, q(float(np.linalg.norm(a - bb))))
        cmp(cse, "manhattan", man, q(float(np.abs(a - bb).sum())))
        cmp(cse, "norm", nrm, q(float(na)))
        cmp(cse, "normL1", l1, q(float(np.abs(a).sum())))
        cmp(cse, "normInf", linf, q(float(np.abs(a).max() if len(a) else 0.0)))

        sa, sb = set(ai), set(bi)
        cmp(cse, "overlap", ovl, len(sa & sb), 0)
        ref_jac = 1.0 if not (sa | sb) else len(sa & sb) / len(sa | sb)
        cmp(cse, "jaccard", jac, q(ref_jac))

        si, sv = pairs(b["SUM"])
        checks += 1
        want = a + bb
        got = dense(si, sv, n)
        if not np.allclose(got, want, atol=2e-9):
            fails += 1
            print(f"FAIL case={cse} sum")
        checks += 1
        if si != sorted(si):
            fails += 1
            print(f"FAIL case={cse} sum indices unsorted")

        pi, pv = pairs(b["PROD"])
        checks += 1
        want = a * bb
        got = dense(pi, pv, n)
        if not np.allclose(got, want, atol=2e-9):
            fails += 1
            print(f"FAIL case={cse} hadamard")
        # nur der Schnitt darf Eintraege haben
        checks += 1
        if set(pi) - (sa & sb):
            fails += 1
            print(f"FAIL case={cse} hadamard support")

        if HAVE_SCIPY:
            # zweiter, voellig anderer Rechenweg: CSR-Matrizen
            A = sp.csr_matrix(a)
            B = sp.csr_matrix(bb)
            checks += 1
            if abs(float(A.multiply(B).sum()) - ref_dot) > 1e-9:
                fails += 1
                print(f"FAIL case={cse} scipy dot mismatch")

    src = "numpy + scipy.sparse" if HAVE_SCIPY else "numpy"
    print(f"cases={len(blocks)} checks={checks} fails={fails} ref={src}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
