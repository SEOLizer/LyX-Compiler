#!/usr/bin/env bash
# tests/builtin_id_test.sh — die Builtin-ID als gemeinsamer Schluessel.
#
# Die ID in IRO_CALL_BUILTIN ist ein globaler Namensraum ueber alle Backends,
# vergeben wurde sie aber pro Backend-Zweig ad hoc. `Printf` und `mem_barrier()`
# trugen beide die 10: auf Linux-ARM64 emittierte Printf eine Speicherbarriere
# und gab nichts aus, auf Windows-ARM64 landete mem_barrier im Printf-Helfer —
# in beiden Faellen ohne Meldung, weil der Aufruf einen falschen, aber
# vorhandenen Handler traf (#1037).
#
# Eine ID muss an DREI Stellen zusammenpassen. Jede hat hier eine Pruefung:
#
#   1. ir_lower gegen src/backend/_builtin_ids.md — jede vergebene ID steht in
#      der Belegungsliste und nennt ihren Aufrufer.
#   2. ir_lower gegen sich selbst — keine ID traegt zwei verschiedene
#      Operationen (#2432).
#   3. ir_lower gegen die BACKENDS — was gesenkt wird, emittiert das Backend
#      oder steht als bewusste Luecke in tests/builtin-backend-allow.txt
#      (#2450).
#   4. Jedes Backend meldet eine unbehandelte ID laut, statt sie zu verwerfen.
#
# WIE DIE IDs ERHOBEN WERDEN. Nicht jede Vergabe steht als Zahl im Aufruf:
# `ghash_blocks`/`rdrand64`/`rdseed64` legen die ID in eine lokale Variable
# (`ghId := 564` …), und die Linux-Syscalls gehen ueber Hilfsfunktionen
# (`_lscRuf(LSC_GETUID, …)`). Genau diese zwei Formen hat die Handerhebung
# beim Bauen von #2391 gebraucht — ein Test, der nur die Zahl im Aufruf sieht,
# haette die Kollision 567 wieder nicht gefunden. Erhoben werden deshalb:
#   (A) die Zahl als fuenftes Argument,
#   (B) eine lokale Variable, aufgeloest ueber ihre Zuweisungen im selben
#       Lowering-Block, und `LSC_*` ueber src/backend/linux_syscalls.lyx,
#   (C) der Parameter `id` einer Hilfsfunktion, aufgeloest ueber ihre
#       Aufrufstellen.
#
# WAS DIESER TEST NICHT LEISTET. Als "behandelt" gilt, dass die Zahl im Rumpf
# von emitBuiltinCall vorkommt. Ob der Zweig sie auch ERREICHT und richtig
# emittiert, sagt das nicht — eine ID, die nur noch im Rumpf eines anderen
# Zweigs steht, zaehlt mit (gemessen: das Streichen von `|| id == 402` aus der
# Bedingung blieb gruen, weil 402 im Rumpf weiterlebt). Das ist dieselbe
# Grenze wie bei jeder Vorhandensein-Pruefung (#1789: `xt_opBehandelt` fuehrte
# IRO_DIV, der Rumpf war `MOVI T0, 0`). Gefunden wird der Fall, um den es geht:
# eine ID, die das Backend GAR NICHT nennt (#2450). Dass ein genannter Zweig
# das Richtige tut, zeigt nur Ausfuehrung — dafuer gibt es die Suiten unter
# qemu (arm64, riscv).
#
# NAMENSQUELLE ist der naechststehende `self.seq(fname, fnlen, "…")`. Eine
# Senkung, die ihre Builtin-Aufrufe in eine HILFSMETHODE auslagert, hat dort
# keinen solchen Vergleich (#2305: `_spStrLen`, `_spStrSub`, … der
# StrSplit-Senkung). Damit die Zuordnung nicht am zufaellig letzten Namen der
# Datei haengt, zaehlt dort ein ausdruecklicher Vermerk
#
#   // LOWERING: <Name>
#
# als Namensquelle. Er ersetzt keine Pruefung: fehlt er, greift wieder der
# naechststehende seq-Name, und ein nicht eingetragener Aufrufer bleibt rot.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'PY'
import re, sys, collections

def rd(p): return open(p, encoding='utf-8', errors='replace').read()

IR   = 'src/ir_lower.lyx'
DOC  = 'src/backend/_builtin_ids.md'
LSCF = 'src/backend/linux_syscalls.lyx'

PASS = []; FAIL = []
def ok(t): PASS.append(t); print("PASS " + t)
def no(t, d): FAIL.append(t); print("FAIL " + t + ": " + d)

# ── LSC_*-Konstanten (Linux-Syscall-Tabelle, #2021) ────────────────────────
lscsrc = rd(LSCF)
LSC = {m.group(1): int(m.group(2))
       for m in re.finditer(r'pub con (LSC_\w+):\s*int64\s*:=\s*(\d+)', lscsrc)}

# ── Erhebung der vergebenen IDs aus ir_lower ───────────────────────────────
L = rd(IR).split('\n')
CALL = re.compile(r'irAddInstrDirect\(IRO_CALL_BUILTIN,\s*-?[A-Za-z0-9_]+,\s*-?[A-Za-z0-9_]+,\s*-1,\s*([A-Za-z0-9_]+)\)')
SEQ  = re.compile(r'self\.seq\(fname,\s*fnlen,\s*"([A-Za-z_0-9]+)"')
LOW  = re.compile(r'//\s*LOWERING:\s*(\S+)')

def name_at(i):
    """Naechster Name oberhalb von Zeile i (0-basiert), hoechstens bis zum
    Anfang der umgebenden Funktion. Ohne diese Grenze erbt eine Senkung ohne
    eigenen seq-Vergleich den zuletzt genannten Namen einer voellig anderen
    Funktion — die Zuordnung saehe vollstaendig aus und waere erfunden."""
    for j in range(i, -1, -1):
        m = LOW.search(L[j])
        if m: return m.group(1)
        m = SEQ.search(L[j])
        if m: return m.group(1)
        if re.match(r'\s*fn\s+\w+\s*\(', L[j]): return '?'
    return '?'

def block_starts(i):
    """Anfaenge der umgebenden Bloecke, von innen nach aussen bis zur Funktion.

    Eine feste Weite trifft es nicht: `a3id := 220` steht IM Block des
    Aufrufs, `frOp := 400` eine Ebene darueber (die Weiche setzt, das `if
    (frOp >= 0)` ruft). Der ganze Funktionsrumpf waere zu weit — dann zaehlt
    jedes `x := 0` einer fremden Schleife mit. Gesucht wird deshalb von innen
    nach aussen, und die erste Ebene mit einer Zuweisung gewinnt."""
    tiefe = 0
    for j in range(i, -1, -1):
        tiefe += L[j].count('}') - L[j].count('{')
        if tiefe < 0:
            yield j
            tiefe = 0
        if re.match(r'\s*fn\s+\w+\s*\(', L[j]):
            yield j
            return
    yield 0

# Hilfsfunktionen, deren fuenftes Argument der Parameter `id` ist (Form C).
helpers = set()
for i, ln in enumerate(L):
    m = CALL.search(ln)
    if not m or m.group(1) != 'id': continue
    for j in range(i, -1, -1):
        mf = re.match(r'\s*fn\s+(\w+)\s*\(\s*id\s*:', L[j])
        if mf: helpers.add(mf.group(1)); break
        if re.match(r'\s*fn\s+\w+\s*\(', L[j]): break

ids = collections.defaultdict(set)   # id -> {Namen}
def add(i, nr, nm=None):
    ids[nr].add(nm or name_at(i))

for i, ln in enumerate(L):
    m = CALL.search(ln)
    if not m: continue
    a = m.group(1)
    if a.isdigit():                                   # (A)
        add(i, int(a))
    elif a in LSC:                                    # (B), Konstante
        add(i, LSC[a])
    elif a == 'id':                                   # (C) im Rumpf, s. u.
        continue
    else:                                             # (B), lokale Variable
        gefunden = 0
        for s in block_starts(i):
          for j in range(s, i + 1):
            # `var x: int64 := 564` und `x := 565` — die Typangabe steht dazwischen.
            # Abschliessendes ';' verlangt: `var frOp: int64 := 0 - 1;` ist eine
            # Sentinel-Vorbelegung, keine ID-Vergabe.
            for mz in re.finditer(r'\b' + re.escape(a) + r'\s*(?::\s*\w+\s*)?:=\s*(\d+)\s*;', L[j]):
                # Steht auf derselben Zeile ein seq()-Vergleich VOR der
                # Zuweisung, ist er ihre Bedingung und damit ihr Name
                # (`if self.seq(…, "cpu_xgetbv") { ciId := 254; }`). Die
                # Vorbelegung links davon gehoert dagegen zum Blocknamen —
                # sonst traegt die Vorgabe-ID den Namen ihrer Ausnahme.
                nm = None
                for ms in SEQ.finditer(L[j]):
                    if ms.start() < mz.start(): nm = ms.group(1)
                add(j, int(mz.group(1)), nm or name_at(j))
                gefunden += 1
          if gefunden: break
        if gefunden == 0:
            no("ID nicht aufloesbar", f"{IR}:{i+1}: Variable '{a}' ohne Zuweisung im Block")

# (C): Aufrufstellen der Hilfsfunktionen
for h in sorted(helpers):
    pat = re.compile(r'\b' + re.escape(h) + r'\(\s*([A-Za-z0-9_]+)\s*,')
    for i, ln in enumerate(L):
        if re.match(r'\s*fn\s+' + re.escape(h) + r'\s*\(', ln): continue
        m = pat.search(ln)
        if not m: continue
        a = m.group(1)
        if a.isdigit(): add(i, int(a))
        elif a in LSC:  add(i, LSC[a])

print(f"erhoben: {len(ids)} Builtin-IDs aus {IR} "
      f"({len(helpers)} Hilfsfunktion(en): {', '.join(sorted(helpers)) or '—'})")

# ── 1. Belegungsliste ──────────────────────────────────────────────────────
doc = rd(DOC)
zeilen = {}
for m in re.finditer(r'^\|\s*(\d+)\s*\|(.*)$', doc, re.M):
    zeilen[int(m.group(1))] = m.group(2)
bereiche = []
for m in re.finditer(r'^## Bereich\s+(\d+)\s*…\s*(\d+)', doc, re.M):
    bereiche.append((int(m.group(1)), int(m.group(2))))

fehlt = []
for nr in sorted(ids):
    z = zeilen.get(nr)
    if z is None:
        # Ein Bereichsabschnitt deckt den Block ab — aber nur unterhalb 400.
        # Ab 400 wird jede ID einzeln vergeben, dort gilt keine Sammelzeile:
        # genau da entstand die Beinahe-Kollision 567 (#2432).
        if nr < 400 and any(a <= nr <= b for a, b in bereiche): continue
        fehlt.append(f"{nr}({'/'.join(sorted(ids[nr]))}): keine Zeile")
        continue
    # Den AUFRUFERNAMEN prueft diese Stelle nur im allgemeinen Block (< 20).
    # Dort steht je Senkung ein seq()-Vergleich, die Zuordnung ist eindeutig.
    # Darueber wird die ID haeufig ueber eine Weiche vergeben
    # (`var ghId := 564; if seq("rdrand64") { ghId := 565; }`), und welcher
    # Name zu welchem Zweig gehoert, ist aus dem Text nicht sicher ablesbar.
    # Ein Namensabgleich waere dort eine Behauptung — geprueft wird deshalb
    # nur, DASS die ID belegt ist. Die Namen stehen in der Meldung, damit man
    # die Stelle findet.
    if nr < 20:
        for nm in sorted(ids[nr]):
            if nm != '?' and not re.search(r'`' + re.escape(nm) + r'[`(]', z):
                fehlt.append(f"{nr}: '{nm}' nicht als Aufrufer eingetragen")
if fehlt:
    no("Belegungsliste unvollstaendig", "; ".join(fehlt))
    print("    Entweder ist die ID doppelt vergeben (echte Kollision, umnummerieren),")
    print("    oder der Aufrufer nutzt dieselbe Operation zu Recht — dann in")
    print(f"    {DOC} in die Spalte 'Lowering von' eintragen.")
else:
    ok(f"alle {len(ids)} Zuordnungen stehen in {DOC}")

# ── 2. ID-Eindeutigkeit (#2432) ────────────────────────────────────────────
geteilt = set()
for z in open('tests/builtin-id-geteilt.txt', encoding='utf-8', errors='replace'):
    z = z.split('#', 1)[0].strip()
    if z: geteilt.add(int(z))

koll = sorted(nr for nr in ids if len(ids[nr]) > 1 and nr not in geteilt)
tot  = sorted(nr for nr in geteilt if len(ids.get(nr, ())) < 2)
if koll:
    no(f"{len(koll)} ID(s) doppelt vergeben",
       "; ".join(f"{nr}: {', '.join(sorted(ids[nr]))}" for nr in koll))
    print("    Das Backend fuehrt den erstpassenden Zweig aus — kein Abbruch,")
    print("    kein Hinweis, ein falsches Ergebnis. Entweder umnummerieren oder,")
    print("    wenn beide dieselbe Operation brauchen, in")
    print("    tests/builtin-id-geteilt.txt mit Begruendung eintragen.")
elif tot:
    no(f"{len(tot)} Eintrag/Eintraege in builtin-id-geteilt.txt sind nicht mehr geteilt",
       ", ".join(str(x) for x in tot))
    print("    Streichen, sonst deckt die Liste eine kuenftige Kollision zu.")
else:
    ok(f"jede der {len(ids)} IDs traegt genau eine Operation "
       f"({len(geteilt)} bewusst geteilt)")

# ── 3. Backend-Abdeckung (#2450) ───────────────────────────────────────────
BE = [('arm64',  'src/backend/arm64/emit_arm64.lyx'),
      ('riscv',  'src/backend/riscv_linux.lyx'),
      ('arm_cm', 'src/backend/arm_cm_backend.lyx'),
      ('xtensa', 'src/backend/xtensa.lyx'),
      ('lyxos',  'src/backend/lyxos/emit_lyxos.lyx')]

# IstLinuxSys(id) — welche IDs der gemeinsame Linux-Zweig abdeckt.
b = lscsrc[lscsrc.index('pub fn IstLinuxSys'):]
b = b[:b.index('\npub fn ', 1)]
lsc_set = set()
for m in re.finditer(r'id\s*>=\s*(LSC_\w+)\s*&&\s*id\s*<=\s*(LSC_\w+)', b):
    lsc_set.update(range(LSC[m.group(1)], LSC[m.group(2)] + 1))
for m in re.finditer(r'id\s*==\s*(LSC_\w+)', b):
    lsc_set.add(LSC[m.group(1)])

def rumpf(path, fname):
    Z = rd(path).split('\n'); out = []; i = 0
    while i < len(Z):
        m = re.match(r'^(\s*)fn\s+(\w+)\s*\(', Z[i])
        if m and m.group(2) == fname:
            ind = len(m.group(1)); j = i + 1
            while j < len(Z):
                m2 = re.match(r'^(\s*)fn\s+\w+\s*\(', Z[j])
                if m2 and len(m2.group(1)) <= ind: break
                j += 1
            out.append('\n'.join(Z[i:j])); i = j; continue
        i += 1
    return '\n'.join(out)

cov = {}
for n, p in BE:
    t = rumpf(p, 'emitBuiltinCall')
    if not t:
        no("Backend ohne emitBuiltinCall", f"{n} ({p})"); cov[n] = set(); continue
    s = set(int(m.group(1)) for m in re.finditer(r'\bid\s*==\s*(\d+)', t))
    for m in re.finditer(r'\bid\s*>=\s*(\d+)\s*&&\s*id\s*<=\s*(\d+)', t):
        s.update(range(int(m.group(1)), int(m.group(2)) + 1))
    if 'IstLinuxSys(id)' in t: s |= lsc_set
    cov[n] = s

ist = {}
for nr in ids:
    m = [n for n, _ in BE if nr not in cov[n]]
    if m: ist[nr] = ','.join(m)

erlaubt = {}
for z in open('tests/builtin-backend-allow.txt', encoding='utf-8', errors='replace'):
    z = z.split('#', 1)[0].rstrip('\n')
    if not z.strip(): continue
    sp = z.split('\t')
    if len(sp) != 3:
        no("builtin-backend-allow.txt", f"Zeile nicht dreispaltig: {z!r}"); continue
    erlaubt[int(sp[0])] = sp[2].strip()

neu  = sorted(nr for nr in ist if nr not in erlaubt or erlaubt[nr] != ist[nr])
weg  = sorted(nr for nr in erlaubt if nr not in ist)
if neu:
    no(f"{len(neu)} neue Backend-Luecke(n)",
       "; ".join(f"{nr}({'/'.join(sorted(ids[nr]))}): {ist[nr]}"
                 + (f" [Liste: {erlaubt[nr]}]" if nr in erlaubt else "") for nr in neu[:12]))
    print("    Die ID wird gesenkt, aber das Backend kennt sie nicht — der Aufruf")
    print("    bricht dort ab (#2450). Entweder emittieren oder die Luecke mit")
    print("    Begruendung in tests/builtin-backend-allow.txt eintragen.")
elif weg:
    no(f"{len(weg)} Eintrag/Eintraege in builtin-backend-allow.txt sind zugegangen",
       ", ".join(str(x) for x in weg[:12]))
    print("    Streichen, sonst veraltet die Liste und deckt die naechste Luecke zu.")
else:
    ok(f"Backend-Abdeckung wie gemessen ({len(ist)} bewusste Luecke(n))")

# ── 4. Kein stiller Durchfall ──────────────────────────────────────────────
mindest = {'arm64': 2, 'riscv': 1, 'arm_cm': 1, 'xtensa': 1, 'lyxos': 1}
stumm = []
for n, p in BE:
    t = rd(p)
    z = len(re.findall(r'_builtinUnsupported\w*\(id', t)) \
      + len(re.findall(r'"error: ' + n.replace('_', '-') + r': Builtin-ID ', t))
    if z < mindest[n]: stumm.append(f"{n}: {z} Meldezweig(e)")
if stumm:
    no("unbehandelte ID faellt still durch", "; ".join(stumm))
else:
    ok("jedes Backend meldet eine unbehandelte ID laut")

print(f"Ergebnis: {len(PASS)} PASS, {len(FAIL)} FAIL")
sys.exit(1 if FAIL else 0)
PY
