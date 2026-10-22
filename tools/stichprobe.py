#!/usr/bin/env python3
"""tools/stichprobe.py — Stichproben-Profiler fuer lyxc-Erzeugnisse (#2174).

perf braucht auf vielen Rechnern root (perf_event_paranoid >= 2); lyxc-Binaries
haben keine Symboltabelle, wohl aber DWARF, wenn sie mit --debug gebaut sind.
Dieses Werkzeug startet das Programm als Kind unter ptrace (erlaubt bei
ptrace_scope <= 1), haelt es alle INTERVALL Sekunden an und liest rip sowie
die Ruecksprungadresse bei [rbp+8]. Danach bildet gdb die Adressen ueber DWARF
auf Funktionsnamen ab.

  python3 tools/stichprobe.py [--intervall 0.005] [--top 30] PROGRAMM [ARGS...]

Beispiel (wo verbringt der Compiler seine Zeit?):
  ./lyxc --debug src/lyxc.lyx -o /tmp/lyxc_dbg
  python3 tools/stichprobe.py /tmp/lyxc_dbg src/lyxc.lyx -o /tmp/x

Ausgabe: Anteil der Proben je Funktion (Selbstzeit) und je Rufer. Eine
Stichprobe misst, sie veraendert das Programm nicht; die Genauigkeit haengt an
der Zahl der Proben (bei 5 ms und 16 s Laufzeit rund 3000).
"""
import collections, ctypes, os, signal, subprocess, sys, tempfile, time

def proben(intervall, argv):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.ptrace.restype = ctypes.c_long
    libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
    TRACEME, PEEKDATA, CONT, GETREGS = 0, 2, 7, 12
    pid = os.fork()
    if pid == 0:
        libc.ptrace(TRACEME, 0, None, None)
        os.execv(argv[0], argv)
    os.waitpid(pid, 0)
    regs = (ctypes.c_ulonglong * 27)()
    selbst, rufer, n = collections.Counter(), collections.Counter(), 0
    libc.ptrace(CONT, pid, None, None)
    while True:
        time.sleep(intervall)
        try:
            os.kill(pid, signal.SIGSTOP)
        except ProcessLookupError:
            break
        _, st = os.waitpid(pid, 0)
        if os.WIFEXITED(st) or os.WIFSIGNALED(st):
            break
        sig = os.WSTOPSIG(st)
        if libc.ptrace(GETREGS, pid, None, ctypes.byref(regs)) == 0:
            selbst[regs[16]] += 1        # rip
            n += 1
            ra = libc.ptrace(PEEKDATA, pid, ctypes.c_void_p(regs[4] + 8), None)   # [rbp+8]
            if ra not in (-1, 0):
                rufer[ra & 0xffffffffffffffff] += 1
        libc.ptrace(CONT, pid, None, ctypes.c_void_p(0 if sig == signal.SIGSTOP else sig))
    return selbst, rufer, n

GDB_SKRIPT = r'''
import gdb, collections, os
z = {"S": collections.Counter(), "R": collections.Counter()}
cache = {}
def name(a):
    if a not in cache:
        try:
            b = gdb.block_for_pc(a)
            while b and not b.function: b = b.superblock
            cache[a] = b.function.name if b and b.function else "?"
        except Exception:
            cache[a] = "?"
    return cache[a]
for zeile in open(os.environ["STICHPROBE_DATEI"]):
    k, a, c = zeile.split()
    z[k][name(int(a, 16))] += int(c)
for k in ("S", "R"):
    for f, c in z[k].most_common(): print(k, c, f)
'''

def main():
    args = sys.argv[1:]
    intervall, top = 0.005, 30
    while args and args[0].startswith("--"):
        if args[0] == "--intervall": intervall = float(args[1]); args = args[2:]
        elif args[0] == "--top": top = int(args[1]); args = args[2:]
        else: sys.exit(__doc__)
    if not args: sys.exit(__doc__)
    args[0] = os.path.abspath(args[0])
    selbst, rufer, n = proben(intervall, args)
    if n == 0: sys.exit("keine Proben (Programm zu kurz?)")
    with tempfile.TemporaryDirectory() as d:
        dat = os.path.join(d, "proben"); skr = os.path.join(d, "abbild.py")
        with open(dat, "w") as f:
            for a, c in selbst.items(): f.write(f"S {a:#x} {c}\n")
            for a, c in rufer.items(): f.write(f"R {a:#x} {c}\n")
        open(skr, "w").write(GDB_SKRIPT)
        aus = subprocess.run(["gdb", "-batch", "-ex", f"source {skr}", args[0]],
                             env=dict(os.environ, STICHPROBE_DATEI=dat),
                             capture_output=True, text=True).stdout
    tab = {"S": [], "R": []}
    for zeile in aus.splitlines():
        t = zeile.split(" ", 2)
        if len(t) == 3 and t[0] in tab: tab[t[0]].append((int(t[1]), t[2]))
    print(f"{n} Proben, Intervall {intervall*1000:.1f} ms")
    for k, titel in (("S", "Selbstzeit"), ("R", "Rufer ([rbp+8], grob)")):
        print(f"\n{titel}:")
        for c, f in tab[k][:top]: print(f"{100*c/n:6.1f}%  {f}")

if __name__ == "__main__":
    main()
