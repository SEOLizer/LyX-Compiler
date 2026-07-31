#!/usr/bin/env bash
# tests/free_arity_test.sh — jeder free-Aufruf muss die Form free(ptr, size) haben.
#
# Hintergrund (Issue #995): `free` ist im Compiler als Builtin registriert, das
# nichts tut ("no-op in bootstrap ... leaks are acceptable"). Dieses Builtin
# verdeckt zugleich `pub fn free(ptr, size)` aus std/alloc.lyx, das munmap
# aufruft — damit ist jede Freigabe im Projekt wirkungslos. Belegt: 1000x
# alloc(2 MB) + free(2 MB) scheitert unter `ulimit -v 262144` beim 127.
# Durchlauf, dieselbe Schleife mit munmap läuft durch.
#
# Voraussetzung für die Umstellung des Builtins auf munmap ist, dass ALLE
# Aufrufstellen zwei Argumente übergeben. Bei nur einem stünde Müll in rsi, und
# ein zu großes munmap räumt fremde Mappings ab — deutlich schlimmer als das
# Leck. Dieser Test hält den erreichten Zustand fest, damit keine
# einargumentige Form zurückkommt und die Umstellung blockiert.
#
# Geprüft wird mit Klammer-Balance, nicht per Regex: ein Muster wie
# `free\([^,)]*\)` bricht an inneren Klammern ab und zählt `free(peek64(h), n)`
# fälschlich als einargumentig.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]

def args_of(s, idx):
    """Argumente ab der oeffnenden Klammer bei idx, klammer-balanciert."""
    depth = 0; cur = ''; args = []
    for ch in s[idx:]:
        if ch == '(':
            depth += 1
            if depth == 1: continue
        elif ch == ')':
            depth -= 1
            if depth == 0:
                args.append(cur); break
        if depth >= 1:
            if ch == ',' and depth == 1:
                args.append(cur); cur = ''; continue
            cur += ch
    return args

# Historische Sicherungskopien, nicht im Makefile referenziert.
DEAD = ('lyxc_backup', 'lyxc_original', 'lyxc_stage1', 'lyxc_test')

bad = []
for sub in ('src', 'std'):
    for dp, _, fns in os.walk(os.path.join(root, sub)):
        for fn in fns:
            if not fn.endswith('.lyx'): continue
            p = os.path.join(dp, fn)
            if any(d in p for d in DEAD): continue
            rel = os.path.relpath(p, root)
            with open(p, encoding='utf-8') as fh:
                for i, line in enumerate(fh):
                    code = line.split('//')[0]
                    if 'free_mem' in code or 'libc_free' in code or 'pub fn free' in code:
                        continue
                    for m in re.finditer(r'(?<![\w_])free\s*\(', code):
                        a = args_of(code, m.end() - 1)
                        if len(a) == 1 and a[0].strip():
                            bad.append(f"{rel}:{i+1}: free({a[0].strip()})")

if bad:
    print(f"FAIL {len(bad)} einargumentige free-Aufrufe:")
    for b in bad[:25]:
        print("   ", b)
    if len(bad) > 25:
        print(f"    ... und {len(bad) - 25} weitere")
    sys.exit(1)

print("PASS alle free-Aufrufe in src/ und std/ nutzen free(ptr, size)")
PY
