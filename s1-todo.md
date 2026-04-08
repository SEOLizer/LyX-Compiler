# S1 Bootstrap Compiler - Todo List

## Aktueller Stand (2026-04-08)

### STATUS: emitX86 Probleme identifiziert

| Stage | Status | Notes |
|-------|--------|-------|
| Parser | ✅ | Funktioniert |
| Sema | ✅ | Funktioniert |
| Linter | ⚠️ | Übersprungen |
| IR Generation | ❌ | lowerModule produziert 0 Funktionen |
| Code Generation | ❌ | getCodeBuf() gibt 1 zurück |
| Binary Writing | ❌ | size=0, kein Code zu schreiben |

## Debug-Ergebnisse

### IR-Lowering Problem ❌
```
irMod funcLen after lower = 0
irMod instrLen after lower = 0
```
**Problem:** lowerModule() erzeugt keine IR-Funktionen. Die AST→IR Transformation funktioniert nicht.

### emitX86 getCodeBuf() Problem ❌
```
emitX86: emitted code size = 1  (gibt codeLen zurück)
emitX86: using fallback buffer
emitter.getCodeBuf() = 1  (sollte Buffer-Adresse sein)
```
**Problem:** S1 berechnet class field offsets falsch für Emitx86.getCodeBuf()

## Gelöste Issues (Session 2)

| Issue | Status | Lösung |
|-------|--------|--------|
| Sema.Check | ✅ | astRoot = 0 handling fixed |
| Pipeline läuft durch | ✅ | Alle Stages werden aufgerufen |

## Offene Bugs

1. **IR-Lowering funktioniert nicht** - lowerModule erzeugt 0 Funktionen
2. **emitX86 getCodeBuf()** - class field offset Bug in S1

## Nächste Schritte

1. [ ] Debug IR-Lowering - warum werden keine Funktionen erzeugt?
2. [ ] Debug class field offsets in Emitx86
3. [ ] Linter wieder aktivieren
4. [ ] Selbst-Kompilierung testen

## Test-Befehle

```bash
./lyxc bootstrap/lyxc.lyx -o /tmp/lyxc_new
timeout 10 /tmp/lyxc_new test_min_literal.lyx -o /tmp/test_out 2>&1
```

## Letzte Commits

- d8b138d fix(bootstrap): CLI parsing and memory management
- 7df84ea cleanup(bootstrap): remove debug output from lyxc.lyx  
- 198208d fix(bootstrap): enable full pipeline stages
- 8dc625f fix(bootstrap): enable Sema, add s1-todo.md
- 8a6c101 docs: update s1-todo.md with current status