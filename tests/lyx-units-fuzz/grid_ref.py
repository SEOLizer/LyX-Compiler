#!/usr/bin/env python3
"""Unabhaengige Referenz fuer std.grid.

Liest die Ausgabe von tests/grid_fuzz.lyx und rechnet BFS, Dijkstra, A* und
Bresenham eigenstaendig nach (collections.deque, heapq). Vergleicht Feld fuer
Feld. Nichts wird aus der Lyx-Ausgabe uebernommen ausser Gitter und Aufgabe.
"""
import sys, math
from collections import deque
from heapq import heappush, heappop

R2 = math.sqrt(2.0)


def neighbours(cells, w, h, x, y, diag):
    out = []
    for dx, dy in ((1, 0), (0, 1), (-1, 0), (0, -1)):
        nx, ny = x + dx, y + dy
        if 0 <= nx < w and 0 <= ny < h and cells[ny * w + nx] > 0:
            out.append((nx, ny))
    if diag:
        for dx, dy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
            nx, ny = x + dx, y + dy
            if not (0 <= nx < w and 0 <= ny < h) or cells[ny * w + nx] <= 0:
                continue
            # kein Schnitt durch Mauerecken
            if cells[y * w + (x + dx)] <= 0 or cells[(y + dy) * w + x] <= 0:
                continue
            out.append((nx, ny))
    return out


def bfs(cells, w, h, sx, sy, diag):
    d = [-1] * (w * h)
    if cells[sy * w + sx] <= 0:
        return d
    d[sy * w + sx] = 0
    q = deque([(sx, sy)])
    while q:
        x, y = q.popleft()
        for nx, ny in neighbours(cells, w, h, x, y, diag):
            if d[ny * w + nx] < 0:
                d[ny * w + nx] = d[y * w + x] + 1
                q.append((nx, ny))
    return d


def dijkstra(cells, w, h, sx, sy, diag):
    d = [-1.0] * (w * h)
    if cells[sy * w + sx] <= 0:
        return d
    d[sy * w + sx] = 0.0
    pq = [(0.0, sx, sy)]
    done = [False] * (w * h)
    while pq:
        dv, x, y = heappop(pq)
        if done[y * w + x]:
            continue
        done[y * w + x] = True
        for nx, ny in neighbours(cells, w, h, x, y, diag):
            step = float(cells[ny * w + nx])
            if nx != x and ny != y:
                step *= R2
            nd = dv + step
            j = ny * w + nx
            if d[j] < 0 or nd < d[j]:
                d[j] = nd
                heappush(pq, (nd, nx, ny))
    return d


def bresenham(x0, y0, x1, y1):
    pts = []
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx - dy
    cx, cy = x0, y0
    while True:
        pts.append((cx, cy))
        if cx == x1 and cy == y1:
            break
        e2 = 2 * err
        if e2 > -dy:
            err -= dy
            cx += sx
        if e2 < dx:
            err += dx
            cy += sy
    return pts


def q(v):
    return -1 if v < 0 else int(v * 1000000.0 + 0.5)


def main(path):
    lines = open(path).read().splitlines()
    blocks, cur = [], {}
    for ln in lines:
        if not ln.strip():
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

    fails = 0
    checks = 0
    for b in blocks:
        cse, w, h, sx, sy, gx, gy, dg = b["CASE"]
        diag = dg == 1
        cells = b["CELLS"]

        def bad(what, got, want):
            nonlocal fails
            fails += 1
            print(f"FAIL case={cse} {what}\n  lyx={got}\n  ref={want}")

        checks += 1
        want = bfs(cells, w, h, sx, sy, diag)
        got = b["BFS"]
        if got != want:
            bad("bfs", got, want)

        checks += 1
        want = [q(v) for v in dijkstra(cells, w, h, sx, sy, diag)]
        got = b["DIJ"]
        if got != want:
            bad("dijkstra", got, want)

        # A*: die Referenz liefert die optimalen Kosten aus Dijkstra; der Pfad
        # aus Lyx muss dieselben Kosten haben, begehbar und zusammenhaengend
        # sein und an den richtigen Enden liegen.
        checks += 1
        dref = dijkstra(cells, w, h, sx, sy, diag)
        truth = dref[gy * w + gx]
        a = b["ASTAR"]
        k = a[0]
        if truth < 0:
            if k != -1:
                bad("astar-unreachable", k, -1)
        else:
            if k < 1:
                bad("astar-missing", k, f"cost {truth}")
            else:
                cost = a[1]
                pts = [(a[2 + 2 * i], a[3 + 2 * i]) for i in range(k)]
                if cost != q(truth):
                    bad("astar-cost", cost, q(truth))
                elif pts[0] != (sx, sy) or pts[-1] != (gx, gy):
                    bad("astar-ends", pts, f"{(sx,sy)}..{(gx,gy)}")
                else:
                    for i, (x, y) in enumerate(pts):
                        if cells[y * w + x] <= 0:
                            bad("astar-blocked", (x, y), "walkable")
                            break
                        if i:
                            ddx = abs(x - pts[i - 1][0])
                            ddy = abs(y - pts[i - 1][1])
                            if ddx + ddy == 0 or ddx > 1 or ddy > 1 or (
                                    not diag and ddx + ddy != 1):
                                bad("astar-step", (pts[i - 1], (x, y)), "adjacent")
                                break

        checks += 1
        want = bresenham(sx, sy, gx, gy)
        L = b["LINE"]
        gotpts = [(L[1 + 2 * i], L[2 + 2 * i]) for i in range(L[0])]
        if gotpts != want:
            bad("line", gotpts, want)

    print(f"cases={len(blocks)} checks={checks} fails={fails}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
