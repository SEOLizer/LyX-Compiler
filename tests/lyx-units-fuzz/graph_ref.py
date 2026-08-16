#!/usr/bin/env python3
"""Unabhaengige Referenz fuer std.graph.

Liest die Ausgabe von tests/graph_fuzz.lyx und rechnet Dijkstra, Bellman-Ford,
Breitensuche, Komponenten, Spannbaum, starke Komponenten und topologische
Sortierung mit heapq/deque eigenstaendig nach.

Aus der Lyx-Ausgabe werden nur GRAPH UND KANTEN uebernommen; jedes verglichene
Ergebnis wird hier neu gerechnet.
"""
import sys
from heapq import heappush, heappop
from collections import deque


def q(x):
    return -1 if x < 0 else int(x * 1000 + 0.5)


def build(n, edges, directed):
    adj = [[] for _ in range(n)]
    for u, v, w in edges:
        adj[u].append((v, w))
        if not directed:
            adj[v].append((u, w))
    return adj


def dijkstra(n, adj, s):
    INF = float("inf")
    d = [INF] * n
    d[s] = 0.0
    pq = [(0.0, s)]
    done = [False] * n
    while pq:
        du, u = heappop(pq)
        if done[u]:
            continue
        done[u] = True
        for v, w in adj[u]:
            if du + w < d[v]:
                d[v] = du + w
                heappush(pq, (d[v], v))
    return [-1 if x == INF else x for x in d]


def bfs(n, adj, s):
    d = [-1] * n
    d[s] = 0
    qq = deque([s])
    while qq:
        u = qq.popleft()
        for v, _ in adj[u]:
            if d[v] < 0:
                d[v] = d[u] + 1
                qq.append(v)
    return d


def components(n, adj):
    comp = [-1] * n
    c = 0
    for s in range(n):
        if comp[s] < 0:
            qq = deque([s])
            comp[s] = c
            while qq:
                u = qq.popleft()
                for v, _ in adj[u]:
                    if comp[v] < 0:
                        comp[v] = c
                        qq.append(v)
            c += 1
    return c, comp


def mst(n, edges):
    par = list(range(n))

    def find(x):
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x

    tot, cnt = 0.0, 0
    for u, v, w in sorted(edges, key=lambda e: e[2]):
        a, b = find(u), find(v)
        if a != b:
            par[a] = b
            tot += w
            cnt += 1
    return cnt, tot


def scc_count(n, edges):
    """Kosaraju, nur die Anzahl und die Zuordnung als Mengen"""
    adj = [[] for _ in range(n)]
    rev = [[] for _ in range(n)]
    for u, v, _ in edges:
        adj[u].append(v)
        rev[v].append(u)

    seen = [False] * n
    order = []
    for s in range(n):
        if seen[s]:
            continue
        stack = [(s, iter(adj[s]))]
        seen[s] = True
        while stack:
            u, it = stack[-1]
            adv = next(it, None)
            if adv is None:
                stack.pop()
                order.append(u)
            elif not seen[adv]:
                seen[adv] = True
                stack.append((adv, iter(adj[adv])))

    comp = [-1] * n
    c = 0
    for s in reversed(order):
        if comp[s] < 0:
            stack = [s]
            comp[s] = c
            while stack:
                u = stack.pop()
                for w in rev[u]:
                    if comp[w] < 0:
                        comp[w] = c
                        stack.append(w)
            c += 1
    return c, comp


def toposort_count(n, edges):
    indeg = [0] * n
    adj = [[] for _ in range(n)]
    for u, v, _ in edges:
        adj[u].append(v)
        indeg[v] += 1
    qq = deque(i for i in range(n) if indeg[i] == 0)
    cnt = 0
    while qq:
        u = qq.popleft()
        cnt += 1
        for v in adj[u]:
            indeg[v] -= 1
            if indeg[v] == 0:
                qq.append(v)
    return cnt


def maxflow(n, edges, s, t):
    """Dinic-freie Referenz: Edmonds-Karp auf einer Kapazitaetsmatrix"""
    cap = [[0.0] * n for _ in range(n)]
    for u, v, w in edges:
        cap[u][v] += w
    total = 0.0
    while True:
        par = [-1] * n
        par[s] = s
        qq = deque([s])
        while qq and par[t] < 0:
            u = qq.popleft()
            for v in range(n):
                if par[v] < 0 and cap[u][v] > 1e-12:
                    par[v] = u
                    qq.append(v)
        if par[t] < 0:
            return total
        # Engstelle
        bott = float("inf")
        v = t
        while v != s:
            u = par[v]
            bott = min(bott, cap[u][v])
            v = u
        v = t
        while v != s:
            u = par[v]
            cap[u][v] -= bott
            cap[v][u] += bott
            v = u
        total += bott


def bipartite_size(n, edges, half):
    """groesste Zuordnung per Kuhn — anderes Verfahren als Dinic"""
    adj = [[] for _ in range(half)]
    for u, v, _ in edges:
        a, b = (u, v) if u < half else (v, u)
        if a < half <= b:
            adj[a].append(b)
    match = [-1] * n

    def try_kuhn(u, seen):
        for v in adj[u]:
            if v in seen:
                continue
            seen.add(v)
            if match[v] < 0 or try_kuhn(match[v], seen):
                match[v] = u
                match[u] = v
                return True
        return False

    cnt = 0
    for u in range(half):
        if match[u] < 0 and try_kuhn(u, set()):
            cnt += 1
    return cnt


def same_partition(a, b):
    """Zwei Zuordnungen beschreiben dieselbe Zerlegung?"""
    if len(a) != len(b):
        return False
    m1, m2 = {}, {}
    for x, y in zip(a, b):
        if x in m1 and m1[x] != y:
            return False
        if y in m2 and m2[y] != x:
            return False
        m1[x] = y
        m2[y] = x
    return True


def main(path):
    fails = checks = cases = 0
    cur = {}
    blocks = []
    for ln in open(path):
        f = ln.split()
        if not f:
            continue
        if f[0] == "G":
            if cur:
                blocks.append(cur)
            cur = {}
        cur[f[0]] = [int(x) for x in f[1:]]
    if cur:
        blocks.append(cur)

    def cmp(kind, what, got, want):
        nonlocal fails, checks
        checks += 1
        if got != want:
            fails += 1
            print(f"FAIL {kind} {what}: lyx={got} ref={want}")

    for b in blocks:
        cases += 1
        tid, n, dd, ec = b["G"]
        directed = dd == 1
        raw = b["E"]
        edges = [(raw[3 * i], raw[3 * i + 1], raw[3 * i + 2]) for i in range(ec)]
        adj = build(n, edges, directed)

        cmp("DIJ", f"case{tid}", b["DIJ"], [q(x) for x in dijkstra(n, adj, 0)])
        cmp("BF", f"case{tid}", b["BF"], [q(x) for x in dijkstra(n, adj, 0)])
        cmp("BFS", f"case{tid}", b["BFS"], bfs(n, adj, 0))

        if not directed:
            c, comp = components(n, adj)
            got = b["COMP"]
            cmp("COMP", f"case{tid} count", got[0], c)
            checks += 1
            if not same_partition(got[1:], comp):
                fails += 1
                print(f"FAIL COMP case{tid} partition: lyx={got[1:]} ref={comp}")
            cnt, tot = mst(n, edges)
            cmp("MST", f"case{tid}", b["MST"], [cnt, q(tot)])
        else:
            c, comp = scc_count(n, edges)
            got = b["SCC"]
            cmp("SCC", f"case{tid} count", got[0], c)
            checks += 1
            if not same_partition(got[1:], comp):
                fails += 1
                print(f"FAIL SCC case{tid} partition: lyx={got[1:]} ref={comp}")
            cmp("TOPO", f"case{tid}", b["TOPO"][0], toposort_count(n, edges))

        if "FLOW" in b:
            got = b["FLOW"]
            cmp("FLOW", f"case{tid}", got[0], q(maxflow(n, edges, 0, n - 1)))
            # Quellseite muss mindestens die Quelle enthalten und darf die
            # Senke nicht enthalten, solange Fluss moeglich war
            checks += 1
            if not (1 <= got[1] <= n):
                fails += 1
                print(f"FAIL FLOW case{tid} cut size {got[1]} out of range")

        if "MATCH" in b:
            half, size = b["MATCH"][0], b["MATCH"][1]
            mt = b["MATCH"][2:]
            want = bipartite_size(n, edges, half)
            cmp("MATCH", f"case{tid} size", size, want)
            # Gegenseitigkeit und Seitenwechsel
            checks += 1
            bad = 0
            pairs = 0
            for i, pr in enumerate(mt):
                if pr >= 0:
                    pairs += 1
                    if mt[pr] != i:
                        bad += 1
                    if (i < half) == (pr < half):
                        bad += 1
            if bad or pairs != 2 * size:
                fails += 1
                print(f"FAIL MATCH case{tid} inconsistent: bad={bad} pairs={pairs} size={size}")

    print(f"cases={cases} checks={checks} fails={fails} ref=python-heapq")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
